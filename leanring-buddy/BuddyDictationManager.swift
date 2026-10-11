//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

import AppKit
import AVFoundation
import AudioToolbox
import Combine
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let currentShortcutOption: ShortcutOption = .controlOption
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed = modifierFlags.contains(modifierOnlyFlags)

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

/// Why the microphone couldn't start on the last press, so she can say the
/// right thing instead of "i didn't hear anything".
enum BuddyMicrophoneStartFailure {
    /// No input device at all (e.g. the laptop lid is closed and nothing
    /// else is plugged in).
    case noMicrophoneAvailable
    /// There is a microphone, but the audio engine refused to start it
    /// (seen after Bluetooth headphones switched mode: -10868).
    case audioEngineFailedToStart
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    /// True once the microphone is actually capturing for this session.
    @Published private(set) var isMicrophoneLive = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// Set when the last press couldn't start the microphone; cleared by the
    /// next press. Read by CompanionManager to pick what she says.
    private(set) var lastMicrophoneStartFailure: BuddyMicrophoneStartFailure?
    /// The input device that recorded the latest utterance (logged next to
    /// the voice check's score: a Bluetooth mic scores lower than the one
    /// the voice was set up with). Kept after the session ends on purpose.
    private(set) var microphoneNameForLatestUtterance: String?

    private let transcriptionProvider: any BuddyTranscriptionProvider
    /// Replaced with a fresh engine when starting fails, or before the next
    /// start after the audio setup changed while idle: after a Bluetooth
    /// route change the old engine can hold a stale input unit and fail
    /// every start (-10868) until something else changes the output.
    private var audioEngine = AVAudioEngine()
    private var shouldReplaceAudioEngineBeforeNextStart = false
    /// The start request whose settings currently fill the session state.
    /// A start that was overtaken (a double tap: the first start was still
    /// waiting for the speech model when the second began) sees this no
    /// longer matches and leaves everything to the newer one.
    private var startRequestOwningSessionState: UUID?
    /// The most recent push-to-talk utterance at 16 kHz, for the voice check.
    let utteranceAudioRecorder = VesperUtteranceAudioRecorder()
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        super.init()
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        stopMicrophoneCapture()
        activeTranscriptionSession?.cancel()

        resetSessionState()
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // If the task is cancelled while we are waiting for macOS to bring
            // the app forward, we can safely continue into the permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        guard !isDictationInProgress else { return }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier
        lastMicrophoneStartFailure = nil

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        startRequestOwningSessionState = startRequestIdentifier
        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            submitEmptyTranscriptForCancelledStart()
            return
        }

        do {
            let sessionStartOutcome = try await startRecognitionSession(startRequestIdentifier: startRequestIdentifier)
            guard sessionStartOutcome == .started,
                  startRequestOwningSessionState == startRequestIdentifier else {
                // A newer start owns the session state now: touch nothing.
                print("🎙️ BuddyDictationManager: start overtaken by a newer one — leaving it alone")
                return
            }
            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                stopMicrophoneCapture()
                activeTranscriptionSession?.cancel()
                submitEmptyTranscriptForCancelledStart()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            guard startRequestOwningSessionState == startRequestIdentifier else {
                // Failed after a newer start took over; its state isn't ours to reset.
                return
            }
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            // Don't leak a half-started session or leave the mic tap on.
            stopMicrophoneCapture()
            activeTranscriptionSession?.cancel()
            if Task.isCancelled {
                // Already released: the release found the session starting
                // and left the result to it, so report the failure now or
                // the question would vanish without a word.
                submitEmptyTranscriptForCancelledStart()
            } else {
                resetSessionState()
            }
        }
    }

    /// Released while the speech model was still opening: nothing was
    /// recorded, but the release must still reach the normal path (which
    /// says so) — otherwise the question silently vanishes.
    private func submitEmptyTranscriptForCancelledStart() {
        let submitDraftText = draftCallbacks?.submitDraftText
        resetSessionState()
        submitDraftText?("")
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        stopMicrophoneCapture()
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private enum RecognitionSessionStartOutcome {
        case started
        /// A newer start took over while this one waited; nothing was changed.
        case overtakenByNewerStart
    }

    /// How long to wait before trying a failed microphone start again on a
    /// fresh audio engine — long enough for a Bluetooth route to settle.
    private static let microphoneStartRetryDelayMilliseconds = 200

    private func startRecognitionSession(startRequestIdentifier: UUID) async throws -> RecognitionSessionStartOutcome {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")

        let newTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.latestRecognizedText = transcriptText
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        // While the speech model opened, a second press may have reset the
        // session and started its own. Writing this session into the shared
        // state now would leave the newer one's mic running with nothing to
        // stop it (the privacy dot stays on until the next press).
        guard startRequestOwningSessionState == startRequestIdentifier else {
            newTranscriptionSession.cancel()
            return .overtakenByNewerStart
        }

        self.activeTranscriptionSession = newTranscriptionSession
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        if shouldReplaceAudioEngineBeforeNextStart {
            replaceAudioEngine(reason: "the audio setup changed since the last question")
        }

        do {
            try startMicrophoneCaptureForNewUtterance(feeding: newTranscriptionSession)
        } catch {
            if lastMicrophoneStartFailure == .noMicrophoneAvailable {
                throw error
            }
            // Marked failed now, so if they let go during the retry she
            // says the mic wouldn't start rather than "didn't hear anything".
            lastMicrophoneStartFailure = .audioEngineFailedToStart
            print("⚠️ Mic didn't start (\(error.localizedDescription)) — trying once more on a fresh audio engine")
            try? await Task.sleep(for: .milliseconds(Self.microphoneStartRetryDelayMilliseconds))
            guard startRequestOwningSessionState == startRequestIdentifier else {
                newTranscriptionSession.cancel()
                return .overtakenByNewerStart
            }
            guard !Task.isCancelled else {
                // Released during the retry: the caller's cancelled path
                // cleans up and reports it.
                return .started
            }
            replaceAudioEngine(reason: "the microphone failed to start")
            try startMicrophoneCaptureForNewUtterance(feeding: newTranscriptionSession)
        }

        lastMicrophoneStartFailure = nil
        observeMicrophoneConfigurationChanges()
        isMicrophoneLive = true
        // The Mac's mic when it was chosen over Bluetooth; otherwise the
        // system's default input, which AVAudioEngine records from.
        microphoneNameForLatestUtterance = microphoneChosenInsteadOfBluetooth?.name
            ?? AVCaptureDevice.default(for: .audio)?.localizedName
        print("⏱️ \(VesperTimingLog.stamp()) mic live (\(microphoneNameForLatestUtterance ?? "unknown mic"))")
        return .started
    }

    /// Reads the current input format, starts a fresh voice-check recording
    /// in it, and starts the mic. Throws (and records why) if there's no
    /// microphone or the engine refuses to start.
    private func startMicrophoneCaptureForNewUtterance(feeding transcriptionSession: BuddyStreamingTranscriptionSession) throws {
        // With Bluetooth headphones as the input, record from the Mac's own
        // microphone through a unit bound to it from the start, so the
        // headphones' mic is never opened (see VesperDirectMicrophoneCapture
        // and VesperMicrophoneSelection).
        if let builtInMicrophone = VesperMicrophoneSelection.builtInMicrophoneToUseInsteadOfBluetooth() {
            do {
                try startDirectMicrophoneCapture(of: builtInMicrophone, feeding: transcriptionSession)
                microphoneChosenInsteadOfBluetooth = builtInMicrophone
                return
            } catch {
                print("⚠️ Couldn't record from the Mac's microphone (\(error.localizedDescription)) — using the headphones' mic")
                stopMicrophoneCapture()
            }
        }
        microphoneChosenInsteadOfBluetooth = nil

        isAudioEngineRecordingTheMicrophone = true
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        // No microphone at all (e.g. a closed laptop lid and nothing else
        // plugged in): installing a tap on an empty format raises an
        // exception that would crash the app, so fail like any start error.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            lastMicrophoneStartFailure = .noMicrophoneAvailable
            throw NSError(
                domain: "VesperDictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone is available."]
            )
        }

        // A 16 kHz copy of this utterance for the "only my voice" check.
        utteranceAudioRecorder.beginNewUtterance(inputFormat: inputFormat)
        do {
            try startMicrophoneCapture(feeding: transcriptionSession, inputFormat: inputFormat)
        } catch {
            // Don't leave a tap on an engine that never started.
            stopMicrophoneCapture()
            throw error
        }
    }

    /// The Mac's microphone chosen instead of Bluetooth headphones' for the
    /// current utterance, or nil when recording from the default input.
    private var microphoneChosenInsteadOfBluetooth: VesperMicrophoneSelection.MicrophoneDevice?
    /// Records the Mac's microphone while Bluetooth headphones are the input.
    private var directMicrophoneCapture: VesperDirectMicrophoneCapture?
    /// True once the AVAudioEngine's input has been used for an utterance.
    /// Until then its input node is never touched: merely creating it opens
    /// the default input (AirPods), which is what this path avoids.
    private var isAudioEngineRecordingTheMicrophone = false

    private func startDirectMicrophoneCapture(
        of builtInMicrophone: VesperMicrophoneSelection.MicrophoneDevice,
        feeding transcriptionSession: BuddyStreamingTranscriptionSession
    ) throws {
        let directMicrophoneCapture = try VesperDirectMicrophoneCapture(deviceIdentifier: builtInMicrophone.deviceIdentifier)
        self.directMicrophoneCapture = directMicrophoneCapture
        utteranceAudioRecorder.beginNewUtterance(inputFormat: directMicrophoneCapture.inputFormat)
        let utteranceAudioRecorder = self.utteranceAudioRecorder
        try directMicrophoneCapture.start { [weak self] microphoneBuffer in
            transcriptionSession.appendAudioBuffer(microphoneBuffer)
            self?.updateAudioPowerLevel(from: microphoneBuffer)
            utteranceAudioRecorder.append(microphoneBuffer)
        }
    }

    private func startMicrophoneCapture(feeding transcriptionSession: BuddyStreamingTranscriptionSession, inputFormat: AVAudioFormat) throws {
        // Captured here: the tap runs on the audio thread, which must not
        // read main-actor properties while they're being replaced.
        let utteranceAudioRecorder = self.utteranceAudioRecorder
        let audioEngine = self.audioEngine
        let inputNode = audioEngine.inputNode
        let microphoneTapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            transcriptionSession.appendAudioBuffer(buffer)
            self?.updateAudioPowerLevel(from: buffer)
            utteranceAudioRecorder.append(buffer)
        }
        // installTap and start report some failures (a format mismatch while
        // Bluetooth headphones switch rate) by raising an Objective-C
        // exception. Uncaught, AppKit swallowed it, this task never finished,
        // and the app crashed minutes later. Caught, it's a normal start error.
        try VesperObjectiveCExceptions.run("Starting the microphone") {
            inputNode.removeTap(onBus: 0)
            // nil = whatever the hardware delivers right now. Passing a format
            // read a moment earlier can raise an exception if Bluetooth
            // headphones switch into microphone mode in between. The
            // transcriber and the voice recorder both convert whatever
            // format arrives.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: microphoneTapBlock)
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    /// Stops the mic and removes its tap. Never throws: this runs on the
    /// way out of every session, including after a failed start.
    private func stopMicrophoneCapture() {
        directMicrophoneCapture?.stop()
        directMicrophoneCapture = nil
        // Touching the input node of an engine that never recorded would
        // open the default input (AirPods) just to stop it.
        guard isAudioEngineRecordingTheMicrophone else { return }
        isAudioEngineRecordingTheMicrophone = false
        let audioEngine = self.audioEngine
        do {
            try VesperObjectiveCExceptions.run("Stopping the microphone") {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        } catch {
            print("⚠️ Couldn't stop the microphone cleanly: \(error.localizedDescription)")
        }
    }

    /// Swaps in a brand-new AVAudioEngine. The old one can keep a stale
    /// input unit after a Bluetooth route change, failing every start until
    /// the output changes again. The configuration observer is tied to the
    /// old engine, so it's removed here and added again for the new one once
    /// the mic starts.
    private func replaceAudioEngine(reason: String) {
        print("🎙️ Using a fresh audio engine for the mic (\(reason))")
        stopMicrophoneCapture()
        if let microphoneConfigurationObserver {
            NotificationCenter.default.removeObserver(microphoneConfigurationObserver)
        }
        microphoneConfigurationObserver = nil
        // The old engine is released on a background queue: its teardown can
        // block waiting on its audio queue, and on the main thread that froze
        // the whole app (cursor stuck, hotkey dead).
        let retiredAudioEngineHolder = RetiredAudioEngineHolder(retiredAudioEngine: audioEngine)
        audioEngine = AVAudioEngine()
        shouldReplaceAudioEngineBeforeNextStart = false
        DispatchQueue.global(qos: .utility).async {
            retiredAudioEngineHolder.releaseRetiredAudioEngine()
        }
    }

    private var microphoneConfigurationObserver: NSObjectProtocol?

    /// When the input device changes mid-question (AirPods connect, a USB
    /// mic is unplugged), AVAudioEngine stops by itself and the rest of the
    /// question would be lost. Pick the new device up and keep recording.
    private func observeMicrophoneConfigurationChanges() {
        guard microphoneConfigurationObserver == nil else { return }
        microphoneConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeMicrophoneCaptureOnNewInput()
            }
        }
    }

    private func resumeMicrophoneCaptureOnNewInput() {
        let isStillRecording = (isRecordingFromKeyboardShortcut || isRecordingFromMicrophoneButton) && !isFinalizingTranscript
        // The Mac's-microphone path doesn't use the engine's input at all.
        guard isStillRecording, isAudioEngineRecordingTheMicrophone, let activeTranscriptionSession else {
            // Changed while idle: nothing to do. (This used to rebuild the
            // engine before the next question, which fired on nearly every
            // press — her own speech output changes the audio setup — and
            // made the mic take 0.8–3.3 s to go live, losing the start of
            // the question. A start that actually fails still gets a fresh
            // engine and a retry.)
            return
        }
        let newInputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard newInputFormat.sampleRate > 0, newInputFormat.channelCount > 0 else {
            print("🎙️ Microphone went away mid-question — using what was heard so far")
            return
        }
        do {
            try startMicrophoneCapture(feeding: activeTranscriptionSession, inputFormat: newInputFormat)
            print("🎙️ Microphone changed mid-question — kept recording on the new one")
        } catch {
            print("⚠️ Couldn't restart the microphone after it changed: \(error.localizedDescription)")
        }
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't transcribe that. try again."
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
        let finalTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        stopMicrophoneCapture()
        activeTranscriptionSession?.cancel()

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        // An empty transcript is delivered too, so the companion can tell
        // the user it heard nothing (e.g. the laptop lid is closed, which
        // switches the built-in mic off) instead of silently doing nothing.
        if finalTranscriptText.isEmpty {
            print("🎙️ BuddyDictationManager: heard no words")
        }

        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private func resetSessionState() {
        isMicrophoneLive = false
        pendingStartRequestIdentifier = UUID()
        startRequestOwningSessionState = nil
        // A finalize timer armed for this session must not fire into the
        // next one (it would cut that question off mid-sentence).
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    private func buildTranscriptionKeyterms() -> [String] {
        // Words the on-device recognizer would otherwise mishear — her name
        // first, then the tools and jargon that come up most at a Mac.
        let baseKeyterms = [
            "Vesper",
            "Claude",
            "Claude Code",
            "Anthropic",
            "Xcode",
            "SwiftUI",
            "Swift",
            "GitHub",
            "Terminal",
            "localhost",
            "npm",
            "API"
        ]

        let combinedKeyterms = baseKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    /// Runs on the audio thread (from the mic tap), so it only does math
    /// there and publishes on the main actor.
    nonisolated private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}

/// Carries an AVAudioEngine off the main thread so its (sometimes blocking)
/// teardown happens there.
nonisolated private final class RetiredAudioEngineHolder: @unchecked Sendable {
    private var retiredAudioEngine: AVAudioEngine?

    init(retiredAudioEngine: AVAudioEngine) {
        self.retiredAudioEngine = retiredAudioEngine
    }

    func releaseRetiredAudioEngine() {
        retiredAudioEngine = nil
    }
}
