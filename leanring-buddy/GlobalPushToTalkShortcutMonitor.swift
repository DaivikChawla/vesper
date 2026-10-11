//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Sent when "/" is pressed during the hotkey hold (ctrl+option+/):
    /// open the panel with its "Type to Vesper" field focused.
    let typedQuestionRequestPublisher = PassthroughSubject<Void, Never>()
    /// The "/" key on an ANSI keyboard (kVK_ANSI_Slash).
    private static let slashKeyCode: Int64 = 44

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    /// True when the last release was really another key pressed during
    /// the hold (ctrl+option+arrow is a system shortcut, not a question):
    /// that press is dropped quietly.
    private(set) var wasLastReleaseCausedByAnotherKey = false

    /// A hold longer than this is a missed release (sleep, a lock screen,
    /// secure input), not a question: the mic is closed.
    private static let maximumHoldSeconds: Double = 120
    private var holdLimitWorkItem: DispatchWorkItem?
    private var keyboardStateObservers: [(center: NotificationCenter, observer: NSObjectProtocol)] = []

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        observeMomentsWhenAReleaseCanBeMissed()
    }

    /// After sleep, a lock screen or a switch of user, the key-up may never
    /// have reached the tap. Check the real keyboard then.
    private func observeMomentsWhenAReleaseCanBeMissed() {
        guard keyboardStateObservers.isEmpty else { return }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for notificationName in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            let observer = workspaceNotificationCenter.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resynchronizeWithKeyboardState(reason: notificationName.rawValue)
                }
            }
            keyboardStateObservers.append((workspaceNotificationCenter, observer))
        }
        let distributedNotificationCenter = DistributedNotificationCenter.default()
        let unlockObserver = distributedNotificationCenter.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resynchronizeWithKeyboardState(reason: "screen unlocked")
            }
        }
        keyboardStateObservers.append((distributedNotificationCenter, unlockObserver))
    }

    /// If the hotkey is recorded as held but the keyboard says it isn't,
    /// the release was missed: send it now, so the mic doesn't stay on.
    private func resynchronizeWithKeyboardState(reason: String) {
        guard isShortcutCurrentlyPressed,
              let modifierOnlyFlags = BuddyPushToTalkShortcut.currentShortcutOption.modifierOnlyFlags else { return }
        let currentModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        if !currentModifierFlags.contains(modifierOnlyFlags) {
            print("⌨️ Hotkey release was missed (\(reason)) — releasing now")
            publishRelease(causedByAnotherKey: false)
        }
    }

    private func publishRelease(causedByAnotherKey: Bool) {
        holdLimitWorkItem?.cancel()
        holdLimitWorkItem = nil
        isShortcutCurrentlyPressed = false
        wasLastReleaseCausedByAnotherKey = causedByAnotherKey
        shortcutTransitionPublisher.send(.released)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        holdLimitWorkItem?.cancel()
        holdLimitWorkItem = nil
        for (notificationCenter, observer) in keyboardStateObservers {
            notificationCenter.removeObserver(observer)
        }
        keyboardStateObservers = []

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            // While the tap was off, the release may have gone by unseen.
            resynchronizeWithKeyboardState(reason: "event tap was re-enabled")
            return Unmanaged.passUnretained(event)
        }

        // Key presses Vesper posts herself during hands-on control must
        // never look like the user pressing (or releasing) the hotkey.
        if VesperPostedEventMarker.isPostedByVesper(event) {
            return Unmanaged.passUnretained(event)
        }

        // Another key pressed during the hold: it's a shortcut like
        // ctrl+option+arrow, not a question. Drop the press quietly.
        if eventType == .keyDown && isShortcutCurrentlyPressed {
            print("⌨️ Another key during the hotkey hold — cancelling quietly")
            publishRelease(causedByAnotherKey: true)
            // ctrl+option+/ is the one such key that means something to
            // Vesper: type a question instead of saying it. The voice hold
            // is still cancelled quietly above, like any other key.
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.slashKeyCode {
                print("⌨️ ctrl+option+/ — opening the typed question field")
                typedQuestionRequestPublisher.send()
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            wasLastReleaseCausedByAnotherKey = false
            shortcutTransitionPublisher.send(.pressed)
            let holdLimitWorkItem = DispatchWorkItem { [weak self] in
                guard let self, self.isShortcutCurrentlyPressed else { return }
                print("⌨️ Hotkey held over \(Int(Self.maximumHoldSeconds))s — treating it as released")
                self.publishRelease(causedByAnotherKey: false)
            }
            self.holdLimitWorkItem?.cancel()
            self.holdLimitWorkItem = holdLimitWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumHoldSeconds, execute: holdLimitWorkItem)
        case .released:
            publishRelease(causedByAnotherKey: false)
        }

        return Unmanaged.passUnretained(event)
    }
}
