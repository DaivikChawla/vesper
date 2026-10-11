//
//  VesperIslandController.swift
//  leanring-buddy
//
//  Owns the island's window and decides what it shows (see VesperIsland).
//
//  The window is a small transparent, click-through panel at the top
//  center of one screen — the one the mouse was on when the island
//  appeared — just above the menu bar and below menus. It never takes
//  clicks (her own hands-on clicks must never land on it, and nothing on
//  it is ever a button), never becomes key, and is excluded from her
//  screenshots with the rest of Vesper's windows. When she's idle it's
//  ordered out entirely, so it costs nothing.
//
//  What it shows is recomputed from CompanionManager's published state
//  whenever any of it changes, one run-loop turn later, so a burst of
//  changes (barge-in: speaking → idle → listening) lands as one morph
//  instead of a blink.
//

import AppKit
import Combine
import SwiftUI

/// A question she's waiting on a yes for, as the island shows it.
struct VesperIslandQuestion: Equatable {
    let spokenQuestion: String
    let expiresAt: Date
}

/// A guided walkthrough step she's waiting for the user to click, as the
/// island and the overlay show it.
struct VesperGuidedStepDisplay: Equatable {
    let stepNumber: Int
    let label: String?
    /// Where she pointed (AppKit global coordinates).
    let appKitGlobalPoint: CGPoint
    let displayFrame: CGRect
    /// The element's edges, once Accessibility says (AppKit global).
    var targetGlobalFrame: CGRect?

    /// "click “export”"
    var instructionText: String {
        guard let label, !label.isEmpty else { return "click where i'm pointing" }
        return "click \u{201C}\(label)\u{201D}"
    }
}

/// The island's window: borderless, transparent, click-through.
final class VesperIslandWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar and status items, below menus and the cursor
        // overlay (which sits at screen-saver level, so her cursor can fly
        // over the island).
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The island sits over the menu bar (and the notch); AppKit must not
    /// push it down into the visible area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class VesperIslandController {
    private let companionManager: CompanionManager
    private let model = VesperIslandModel()
    private var islandWindow: VesperIslandWindow?
    private var stateSubscriptions: Set<AnyCancellable> = []

    /// Big enough for the widest, tallest island plus its shadow. The
    /// window is transparent and click-through, so the extra room is free.
    private static let canvasSize = CGSize(width: 640, height: 250)

    /// Whether the window is on screen (including while it retracts).
    private var isWindowOnScreen = false
    private var lastAppliedPresentation: VesperIslandPresentation = .hidden
    private var lastAppliedTint: VesperIslandTint = .normal
    /// Bumped on every show, so a pending retract from before knows it's stale.
    private var retractGeneration = 0
    /// A retract is already counting down: later "nothing to show" refreshes
    /// don't restart its linger (which could keep the island up for seconds).
    private var isRetractScheduled = false
    /// Listening shows a beat after the mic goes live: a quick tap of the
    /// hotkey (or ctrl+option as part of another shortcut) never flashes
    /// the island out and back.
    private var delayedListeningGrowOut: DispatchWorkItem?
    private static let listeningGrowOutDelaySeconds: TimeInterval = 0.15
    private var isRefreshScheduled = false

    /// A task that just ended by itself shows a check (or a cross) briefly.
    private var finishedTaskOutcome: (didSucceed: Bool, shownUntil: Date)?
    /// First launch: "hold ⌃ ⌥ and say hi", shown for a while.
    private var shortcutHintShownUntil: Date?
    private static let shortcutHintSeconds: TimeInterval = 6
    private static let finishedTaskOutcomeSeconds: TimeInterval = 1.4

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func start() {
        subscribeToCompanionState()
        refreshSoon()
    }

    // MARK: - Watching Her State

    private func subscribeToCompanionState() {
        let manager = companionManager
        // Published values fire before they're stored; the refresh reads
        // them a run-loop turn later.
        Publishers.MergeMany(
            manager.$voiceState.map { _ in () }.eraseToAnyPublisher(),
            manager.$currentCaptionText.map { _ in () }.eraseToAnyPublisher(),
            manager.$areCaptionsEnabled.map { _ in () }.eraseToAnyPublisher(),
            manager.$pointedElementLabel.map { _ in () }.eraseToAnyPublisher(),
            manager.$bubbleNoticeText.map { _ in () }.eraseToAnyPublisher(),
            manager.$isControllingScreen.map { _ in () }.eraseToAnyPublisher(),
            manager.$walkthroughStepProgress.map { _ in () }.eraseToAnyPublisher(),
            manager.$handsOnActivityText.map { _ in () }.eraseToAnyPublisher(),
            manager.$handsOnStepNumber.map { _ in () }.eraseToAnyPublisher(),
            manager.$islandQuestion.map { _ in () }.eraseToAnyPublisher(),
            manager.$latestSubscriptionUsage.map { _ in () }.eraseToAnyPublisher(),
            manager.$islandWelcomeText.map { _ in () }.eraseToAnyPublisher(),
            manager.$guidedStepWaitingForClick.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshSoon() }
        .store(in: &stateSubscriptions)

        // The hint appears once, after the first-launch demo.
        manager.$firstLaunchHintText
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.shortcutHintShownUntil = Date().addingTimeInterval(Self.shortcutHintSeconds)
                self.refreshSoon()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.shortcutHintSeconds + 0.05) { [weak self] in
                    self?.refreshSoon()
                }
            }
            .store(in: &stateSubscriptions)

        // A task finished (a check) or was cut short (a cross and a shake).
        manager.$handsOnTaskOutcomeEvent
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomeEvent in self?.showFinishedTaskOutcome(didSucceed: outcomeEvent.didSucceed) }
            .store(in: &stateSubscriptions)

        // Another voice was ignored ("only my voice"): the island shakes its head.
        manager.$voiceRejectionCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.shake() }
            .store(in: &stateSubscriptions)

        // Voice levels: only ever redraw the bars and the glyph's glow.
        manager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioPowerLevel in
                guard let self, self.isWindowOnScreen else { return }
                // Same curve as the cursor's waveform: ignores the noise
                // floor and lifts quiet speech.
                let levelAboveNoiseFloor = max(audioPowerLevel - 0.008, 0)
                let easedMicrophoneLevel = pow(min(levelAboveNoiseFloor * 2.85, 1), 0.76)
                if abs(easedMicrophoneLevel - self.model.microphoneLevel) > 0.01 {
                    self.model.microphoneLevel = easedMicrophoneLevel
                }
            }
            .store(in: &stateSubscriptions)

        manager.speechPlaybackEngine.$currentOutputAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outputAudioLevel in
                guard let self, self.isWindowOnScreen else { return }
                let clampedVoiceLevel = min(max(outputAudioLevel, 0), 1)
                if abs(clampedVoiceLevel - self.model.voiceLevel) > 0.01 {
                    self.model.voiceLevel = clampedVoiceLevel
                }
            }
            .store(in: &stateSubscriptions)

        // Screens plugged in, removed or rearranged: re-seat the island.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isWindowOnScreen, let islandWindow = self.islandWindow else { return }
                let currentScreen = islandWindow.screen ?? Self.screenUnderMouse()
                if let currentScreen {
                    self.place(islandWindow, on: currentScreen)
                }
            }
            .store(in: &stateSubscriptions)
    }

    /// Coalesces a burst of state changes into one refresh.
    private func refreshSoon() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRefreshScheduled = false
            self.refresh()
        }
    }

    // MARK: - Deciding What to Show

    private func refresh() {
        apply(desiredPresentation(), tint: desiredTint())
    }

    private func desiredTint() -> VesperIslandTint {
        if companionManager.isControllingScreen || companionManager.islandQuestion != nil {
            return .inControl
        }
        if companionManager.isSubscriptionKnownToBeResting {
            return .resting
        }
        return .normal
    }

    private func desiredPresentation() -> VesperIslandPresentation {
        let manager = companionManager

        // A question waiting on a yes stays up until it's answered or
        // expires — while she says it, and while she listens for the answer.
        if let islandQuestion = manager.islandQuestion {
            return .asking(
                questionText: islandQuestion.spokenQuestion,
                isListening: manager.voiceState == .listening,
                expiresAt: islandQuestion.expiresAt
            )
        }

        switch manager.voiceState {
        case .listening:
            return .listening

        case .processing:
            if manager.isControllingScreen {
                return .working(activityText: manager.handsOnActivityText ?? "looking at the screen", stepNumber: manager.handsOnStepNumber)
            }
            return .thinking

        case .responding:
            let captionText = manager.currentCaptionText.flatMap { $0.isEmpty ? nil : $0 }
            if manager.isControllingScreen && captionText == nil {
                // Acting between sentences: what she's doing right now.
                return .working(activityText: manager.handsOnActivityText ?? "working", stepNumber: manager.handsOnStepNumber)
            }
            // Captions on: her sentence. Off: only what she's pointing at,
            // as before — the island never shows sentences with captions off.
            let caption = manager.areCaptionsEnabled ? captionText : manager.pointedElementLabel
            return .speaking(
                caption: caption,
                stepText: manager.walkthroughStepProgress?.chipText,
                noticeText: manager.bubbleNoticeText
            )

        case .idle:
            if let finishedTaskOutcome, finishedTaskOutcome.shownUntil > Date() {
                return .finished(didSucceed: finishedTaskOutcome.didSucceed)
            }
            if let bubbleNoticeText = manager.bubbleNoticeText {
                return .notice(text: bubbleNoticeText, kind: manager.bubbleNoticeKind)
            }
            if let guidedStepWaitingForClick = manager.guidedStepWaitingForClick {
                return .guiding(instructionText: guidedStepWaitingForClick.instructionText, stepNumber: guidedStepWaitingForClick.stepNumber)
            }
            if manager.isControllingScreen {
                return .working(activityText: manager.handsOnActivityText ?? "working", stepNumber: manager.handsOnStepNumber)
            }
            if let islandWelcomeText = manager.islandWelcomeText {
                return .welcome(text: islandWelcomeText)
            }
            if let shortcutHintShownUntil, shortcutHintShownUntil > Date() {
                return .shortcutHint(beforeKeysText: "hold", afterKeysText: "and say hi")
            }
            return .hidden
        }
    }

    // MARK: - Showing, Morphing and Retracting

    private var isReduceMotionOn: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func apply(_ presentation: VesperIslandPresentation, tint: VesperIslandTint) {
        guard presentation != .hidden else {
            if let delayedListeningGrowOut {
                // It was only a tap: the island never came out.
                delayedListeningGrowOut.cancel()
                self.delayedListeningGrowOut = nil
                lastAppliedPresentation = .hidden
            }
            retractAfterLingering(previousPresentation: lastAppliedPresentation)
            return
        }

        // Anything new cancels a pending retract.
        retractGeneration += 1
        isRetractScheduled = false

        guard presentation != lastAppliedPresentation || tint != lastAppliedTint || !isWindowOnScreen || !model.isOut else { return }
        let previousPresentation = lastAppliedPresentation
        lastAppliedPresentation = presentation
        lastAppliedTint = tint
        model.isReduceMotionOn = isReduceMotionOn

        if !isWindowOnScreen {
            if presentation.kind == .listening {
                guard delayedListeningGrowOut == nil else { return }
                let listeningGrowOut = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.delayedListeningGrowOut = nil
                    guard !self.isWindowOnScreen else { return }
                    let currentPresentation = self.desiredPresentation()
                    guard currentPresentation != .hidden else {
                        self.lastAppliedPresentation = .hidden
                        return
                    }
                    self.lastAppliedPresentation = currentPresentation
                    self.growOut(with: currentPresentation, tint: self.desiredTint())
                }
                delayedListeningGrowOut = listeningGrowOut
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.listeningGrowOutDelaySeconds, execute: listeningGrowOut)
                return
            }
            delayedListeningGrowOut?.cancel()
            delayedListeningGrowOut = nil
            growOut(with: presentation, tint: tint)
            return
        }

        // Already out: morph from whatever it's showing. A fresh
        // appearance after a retract had begun grows out again.
        let morphAnimation = isReduceMotionOn
            ? VesperIslandStyle.reducedMotionAnimation
            : (model.isOut ? VesperIslandStyle.morphAnimation : VesperIslandStyle.arrivalAnimation)
        withAnimation(morphAnimation) {
            model.presentation = presentation
            model.tint = tint
            model.isOut = true
        }
        if previousPresentation.kind != .asking && presentation.kind == .asking {
            // A question needs them: one small nudge to draw the eye.
            playAttentionNudge()
        }
    }

    /// First appearance: seat the window on the screen with the mouse,
    /// start tucked into the top edge, and grow out on the next frame.
    private func growOut(with presentation: VesperIslandPresentation, tint: VesperIslandTint) {
        let islandWindow = makeIslandWindowIfNeeded()
        guard let screen = Self.screenUnderMouse() else { return }
        place(islandWindow, on: screen)

        var instantTransaction = Transaction()
        instantTransaction.disablesAnimations = true
        withTransaction(instantTransaction) {
            model.presentation = presentation
            model.tint = tint
            model.isOut = false
            model.microphoneLevel = 0
            model.voiceLevel = 0
        }
        islandWindow.alphaValue = 1
        islandWindow.orderFrontRegardless()
        isWindowOnScreen = true

        let generationAtShow = retractGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.retractGeneration == generationAtShow else { return }
            withAnimation(self.isReduceMotionOn ? VesperIslandStyle.reducedMotionAnimation : VesperIslandStyle.arrivalAnimation) {
                self.model.isOut = true
            }
        }
    }

    /// Nothing to show: after a short linger (longer after a caption, so
    /// the last sentence can be read), the island retracts into the edge
    /// and the window leaves the screen.
    private func retractAfterLingering(previousPresentation: VesperIslandPresentation) {
        guard isWindowOnScreen, !isRetractScheduled else { return }
        isRetractScheduled = true
        retractGeneration += 1
        let generationAtRetract = retractGeneration

        let lingerSeconds: TimeInterval
        switch previousPresentation {
        case .speaking(let caption, _, _) where caption?.isEmpty == false:
            lingerSeconds = 1.3
        case .notice, .finished, .welcome, .shortcutHint:
            lingerSeconds = 0.1
        default:
            lingerSeconds = 0.3
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + lingerSeconds) { [weak self] in
            guard let self, self.retractGeneration == generationAtRetract else { return }
            self.lastAppliedPresentation = .hidden
            withAnimation(self.isReduceMotionOn ? VesperIslandStyle.reducedMotionAnimation : VesperIslandStyle.departureAnimation) {
                self.model.isOut = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.retractGeneration == generationAtRetract else { return }
                self.isRetractScheduled = false
                self.islandWindow?.orderOut(nil)
                self.isWindowOnScreen = false
                var instantTransaction = Transaction()
                instantTransaction.disablesAnimations = true
                withTransaction(instantTransaction) {
                    self.model.presentation = .hidden
                }
            }
        }
    }

    private func showFinishedTaskOutcome(didSucceed: Bool) {
        finishedTaskOutcome = (didSucceed, Date().addingTimeInterval(Self.finishedTaskOutcomeSeconds))
        if !didSucceed {
            shake()
        }
        refreshSoon()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedTaskOutcomeSeconds + 0.05) { [weak self] in
            self?.refreshSoon()
        }
    }

    /// A quick horizontal "no". Kept with Reduce Motion (it's small and
    /// it's the only sign a voice was ignored), but gentler.
    private func shake() {
        guard isWindowOnScreen, model.isOut else { return }
        withAnimation(.linear(duration: isReduceMotionOn ? 0.3 : 0.45)) {
            model.shakeCount += 1
        }
    }

    /// One soft swell when a question appears — the only time the island
    /// asks for attention.
    private func playAttentionNudge() {
        guard !isReduceMotionOn else { return }
        // After the morph into the question has mostly landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.model.presentation.kind == .asking else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                self.model.attentionPulseCount += 1
            }
        }
    }

    // MARK: - The Window

    private func makeIslandWindowIfNeeded() -> VesperIslandWindow {
        if let islandWindow { return islandWindow }
        let newIslandWindow = VesperIslandWindow()
        let islandHostingView = NSHostingView(rootView: VesperIslandView(model: model))
        // The island never resizes its window.
        islandHostingView.sizingOptions = []
        islandHostingView.frame = CGRect(origin: .zero, size: Self.canvasSize)
        newIslandWindow.contentView = islandHostingView
        newIslandWindow.setContentSize(Self.canvasSize)
        islandWindow = newIslandWindow
        return newIslandWindow
    }

    /// Seats the window at the top center of `screen` — centered on the
    /// notch when there is one — and tells the view the screen's shape.
    private func place(_ islandWindow: VesperIslandWindow, on screen: NSScreen) {
        let (screenMetrics, islandCenterX) = Self.islandMetrics(for: screen)
        if model.metrics != screenMetrics {
            var instantTransaction = Transaction()
            instantTransaction.disablesAnimations = true
            withTransaction(instantTransaction) {
                model.metrics = screenMetrics
            }
        }
        let windowFrame = CGRect(
            x: (islandCenterX - Self.canvasSize.width / 2).rounded(),
            y: screen.frame.maxY - Self.canvasSize.height,
            width: Self.canvasSize.width,
            height: Self.canvasSize.height
        )
        islandWindow.setFrame(windowFrame, display: false)
    }

    /// A notch: its height and width (the middle of the band the island
    /// never draws into) and its center. No notch: the island's own
    /// proportions, centered on the screen.
    static func islandMetrics(for screen: NSScreen) -> (VesperIslandMetrics, centerX: CGFloat) {
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let topLeftArea = screen.auxiliaryTopLeftArea,
           let topRightArea = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - topLeftArea.width - topRightArea.width
            if notchWidth > 40 {
                let notchCenterX = screen.frame.minX + topLeftArea.width + notchWidth / 2
                return (
                    VesperIslandMetrics(hasHardwareNotch: true, bandHeight: notchHeight, centerGapWidth: notchWidth),
                    notchCenterX
                )
            }
        }
        return (.withoutNotch, screen.frame.midX)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
}
