//
//  VesperComputerControl.swift
//  leanring-buddy
//
//  What Vesper is allowed to do on the Mac, and the pieces that do it.
//
//  Two levels, chosen in the panel:
//  - Quick actions: open apps and websites, control Apple Music, change the
//    volume. Run instantly from tags in her reply — no extra Claude turns.
//  - Hands-on: everything above, plus clicking, typing, key presses and
//    scrolling, one step at a time: she acts, looks at the screen again,
//    and decides the next step, until the task is done.
//
//  Clicks and keystrokes are posted as CGEvents (needs the Accessibility
//  permission Vesper already has for the push-to-talk shortcut). Every
//  posted event is marked, so the push-to-talk monitor never mistakes one
//  of her own key presses for the user's hotkey.
//

import AppKit
import CoreAudio
import CoreGraphics
import Foundation

enum VesperControlMode: String, CaseIterable {
    case off
    case quickActions
    case handsOn

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .quickActions: return "Quick"
        case .handsOn: return "Hands-on"
        }
    }

    var allowsQuickActions: Bool { self != .off }
    var allowsHandsOnActions: Bool { self == .handsOn }
}

/// What happens once she has finished speaking a reply: whether to run
/// the hands-on actions it contained, and whether to look at the screen
/// again and ask Claude for another step afterwards. [DONE] only stops the
/// asking — actions in the same reply ("[CLICK:send][DONE]") still run.
struct VesperHandsOnReplyPlan: Equatable {
    let shouldRunHandsOnActions: Bool
    let shouldAskForNextStep: Bool

    static func make(
        controlMode: VesperControlMode,
        handsOnActionCount: Int,
        didUseAnyAction: Bool,
        didDeclareTaskFinished: Bool
    ) -> VesperHandsOnReplyPlan {
        guard controlMode.allowsHandsOnActions else {
            return VesperHandsOnReplyPlan(shouldRunHandsOnActions: false, shouldAskForNextStep: false)
        }
        return VesperHandsOnReplyPlan(
            shouldRunHandsOnActions: handsOnActionCount > 0,
            shouldAskForNextStep: didUseAnyAction && !didDeclareTaskFinished
        )
    }
}

/// Marks CGEvents that Vesper posts herself.
enum VesperPostedEventMarker {
    /// Stored in the event's `eventSourceUserData` field ("VESP" in ASCII).
    nonisolated static let eventSourceUserDataValue: Int64 = 0x5645_5350

    nonisolated static func isPostedByVesper(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == eventSourceUserDataValue
    }
}

// MARK: - Quick Actions

/// Runs quick actions (open, music, volume) through `/usr/bin/open` and
/// `osascript`. Returns a short line for her to say when something failed,
/// or nil when it worked.
/// The keyboard's media keys (play/pause, next, previous), which macOS
/// sends to whatever app is "now playing".
enum VesperMediaKeys {
    static let playPauseKey: Int32 = 16      // NX_KEYTYPE_PLAY
    static let nextTrackKey: Int32 = 17      // NX_KEYTYPE_NEXT
    static let previousTrackKey: Int32 = 18  // NX_KEYTYPE_PREVIOUS
    static let brightnessUpKey: Int32 = 2    // NX_KEYTYPE_BRIGHTNESS_UP
    static let brightnessDownKey: Int32 = 3  // NX_KEYTYPE_BRIGHTNESS_DOWN

    /// A key press: down, then up, as system-defined events.
    static func press(_ mediaKey: Int32) {
        for isKeyDown in [true, false] {
            let keyStateBits: Int32 = isKeyDown ? 0xA : 0xB
            let mediaKeyEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyStateBits) << 8),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((mediaKey << 16) | (keyStateBits << 8)),
                data2: -1
            )
            mediaKeyEvent?.cgEvent?.post(tap: .cghidEventTap)
        }
        print("⚡ Media key \(mediaKey)")
    }

    /// Whether some app other than Vesper is sending sound out right now
    /// (system sound daemons don't count; browsers' and Safari's audio
    /// helpers do).
    static func isAnotherAppPlayingSound() -> Bool {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let appleProcessesThatPlayMedia = ["com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.Safari", "com.apple.QuickTimePlayerX", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]
        var processListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processListSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &processListAddress, 0, nil, &processListSize) == noErr else { return false }
        var processObjects = [AudioObjectID](repeating: 0, count: Int(processListSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processListAddress, 0, nil, &processListSize, &processObjects) == noErr else { return false }

        for processObject in processObjects {
            var isRunningOutput: UInt32 = 0
            var runningOutputSize = UInt32(MemoryLayout<UInt32>.size)
            var runningOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(processObject, &runningOutputAddress, 0, nil, &runningOutputSize, &isRunningOutput) == noErr, isRunningOutput != 0 else { continue }

            var processIdentifier: pid_t = 0
            var processIdentifierSize = UInt32(MemoryLayout<pid_t>.size)
            var processIdentifierAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(processObject, &processIdentifierAddress, 0, nil, &processIdentifierSize, &processIdentifier)
            guard processIdentifier != ownProcessIdentifier else { continue }

            var bundleIdentifierReference: Unmanaged<CFString>?
            var bundleIdentifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleIdentifierAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(processObject, &bundleIdentifierAddress, 0, nil, &bundleIdentifierSize, &bundleIdentifierReference)
            let bundleIdentifier = bundleIdentifierReference?.takeRetainedValue() as String? ?? ""
            let isSystemSoundDaemon = bundleIdentifier.hasPrefix("com.apple.") && !appleProcessesThatPlayMedia.contains(where: { bundleIdentifier.hasPrefix($0) })
            // Audio routers (Boom 3D on this Mac, SoundSource, eqMac…) send
            // sound out all the time — every app's audio passes through them.
            let lowercasedBundleIdentifier = bundleIdentifier.lowercased()
            let isAudioRouter = ["globaldelight", "rogueamoeba", "eqmac", "backgroundmusic", "loopback", "soundsource"].contains { lowercasedBundleIdentifier.contains($0) }
            if !isSystemSoundDaemon && !isAudioRouter {
                return true
            }
        }
        return false
    }
}

enum VesperQuickActionRunner {
    static func perform(_ quickAction: VesperAction) async -> String? {
        switch quickAction {
        case .open:
            // Opening needs the site checks first: prepareOpen, then runPreparedOpen.
            return nil
        case .music(let musicCommand):
            return await runMusicCommand(musicCommand)
        case .volume(let volumeChange):
            return await changeVolume(volumeChange)
        case .arrangeWindow, .hideApplication, .focusApplication, .quitApplication:
            return await VesperWindowControl.perform(quickAction)
        default:
            return nil
        }
    }

    /// What an [OPEN:...] target turned out to be.
    enum OpenTarget: Equatable {
        case website(URL)
        case application(name: String)
        /// Anything else (file://, custom schemes...). Refused, so text on a
        /// web page can never talk her into opening something odd.
        case unsupported
    }

    static func classifyOpenTarget(_ target: String) -> OpenTarget {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedTarget = trimmedTarget.lowercased()

        if lowercasedTarget.hasPrefix("http://") || lowercasedTarget.hasPrefix("https://") {
            guard let websiteURL = URL(string: trimmedTarget), websiteURL.host?.isEmpty == false else {
                return .unsupported
            }
            return .website(websiteURL)
        }
        // App names never contain a colon; anything else with one is a
        // scheme (file:, x-apple.systempreferences:, smb://...).
        if lowercasedTarget.contains(":") {
            return .unsupported
        }

        // "youtube.com" or "fiverr.com/inbox" — a bare web address.
        let looksLikeBareWebAddress = !trimmedTarget.contains(" ")
            && !lowercasedTarget.hasSuffix(".app")
            && trimmedTarget.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if looksLikeBareWebAddress, let websiteURL = URL(string: "https://" + trimmedTarget) {
            return .website(websiteURL)
        }

        // A name, never a path: "/Users/me/Downloads/x.app/" or "~/…" would
        // make `open -a` launch any bundle on disk.
        if trimmedTarget.contains("/") || trimmedTarget.contains("~") || trimmedTarget.hasPrefix(".") {
            return .unsupported
        }
        let applicationName = trimmedTarget.hasSuffix(".app") ? String(trimmedTarget.dropLast(4)) : trimmedTarget
        return applicationName.isEmpty ? .unsupported : .application(name: applicationName)
    }

    /// An [OPEN:...] that has passed its checks, ready to run.
    struct PreparedOpen: Equatable {
        /// The website to open, or nil to open just the app.
        let websiteURL: URL?
        /// The installed app to open it in (or to open), found by name.
        let applicationURL: URL?
        /// The site to remember once the user says yes to it.
        let siteDomainToApprove: String?
    }

    enum OpenPreparation: Equatable {
        case ready(PreparedOpen)
        /// An unknown site: she asks by domain before opening it.
        case needsConfirmation(PreparedOpen, spokenQuestion: String)
        /// Refused or not found; the line is what she says.
        case failed(spokenLine: String)
    }

    /// Decides what an [OPEN:...] tag may do, before anything runs. Websites
    /// go through VesperOpenLinkPolicy; app names (the target, or the
    /// " | app" part) must be apps in the standard Applications folders.
    static func prepareOpen(
        target: String,
        inApplicationNamed applicationName: String?,
        approvedSiteDomains: Set<String>,
        isConversationTainted: Bool
    ) -> OpenPreparation {
        var applicationURLForWebsite: URL?
        if let applicationName {
            guard let locatedApplicationURL = VesperApplicationLocator.applicationURL(named: applicationName) else {
                print("⚡ Quick action: refused or couldn't find app \"\(applicationName)\"")
                return .failed(spokenLine: "i couldn't find an app called \(applicationName.lowercased()).")
            }
            applicationURLForWebsite = locatedApplicationURL
        }

        switch classifyOpenTarget(target) {
        case .website(let websiteURL):
            switch VesperOpenLinkPolicy.decision(
                for: websiteURL,
                approvedSiteDomains: approvedSiteDomains,
                isConversationTainted: isConversationTainted
            ) {
            case .openNow(let websiteURLToOpen):
                return .ready(PreparedOpen(websiteURL: websiteURLToOpen, applicationURL: applicationURLForWebsite, siteDomainToApprove: nil))
            case .needsConfirmation(let websiteURLToOpen, let siteHost):
                return .needsConfirmation(
                    PreparedOpen(websiteURL: websiteURLToOpen, applicationURL: applicationURLForWebsite, siteDomainToApprove: siteHost),
                    spokenQuestion: "want me to open \(siteHost)? it's a site i haven't opened for you before. say yes and i'll open it."
                )
            case .refused:
                return .failed(spokenLine: "i only open websites and apps, not that.")
            }

        case .application(let targetApplicationName):
            guard let targetApplicationURL = VesperApplicationLocator.applicationURL(named: targetApplicationName) else {
                return .failed(spokenLine: "i couldn't find an app called \(targetApplicationName.lowercased()).")
            }
            return .ready(PreparedOpen(websiteURL: nil, applicationURL: targetApplicationURL, siteDomainToApprove: nil))

        case .unsupported:
            print("⚡ Quick action: refused to open \(target)")
            return .failed(spokenLine: "i only open websites and apps, not that.")
        }
    }

    /// Runs an [OPEN:...] that has passed prepareOpen (and, if it asked,
    /// the user's yes). Returns a line to say if it failed.
    static func runPreparedOpen(_ preparedOpen: PreparedOpen) async -> String? {
        var openArguments: [String] = []
        if let applicationURL = preparedOpen.applicationURL {
            // A full path, so `open` can't pick some other bundle by name.
            openArguments += ["-a", applicationURL.path]
        }
        if let websiteURL = preparedOpen.websiteURL {
            openArguments.append(websiteURL.absoluteString)
        }
        guard !openArguments.isEmpty else { return nil }
        print("⚡ Quick action: open \(preparedOpen.websiteURL?.absoluteString ?? "")\(preparedOpen.applicationURL.map { " in \($0.lastPathComponent)" } ?? "")")
        let openResult = await VesperProcessRunner.run(executablePath: "/usr/bin/open", arguments: openArguments)
        guard openResult.exitStatus != 0 else { return nil }
        if preparedOpen.websiteURL == nil {
            return "that app wouldn't open."
        }
        return preparedOpen.applicationURL != nil ? "i couldn't open that in that app." : "that link wouldn't open."
    }

    private static func runMusicCommand(_ musicCommand: VesperMusicCommand) async -> String? {
        print("⚡ Quick action: music \(musicCommand)")
        // Play, pause, next and previous are the Mac's media keys, so they
        // work on whatever is playing — YouTube in Chrome, Spotify, Music —
        // not only the Music app. The play key toggles, so "pause" only
        // presses it when another app is actually playing sound (and
        // "play" only when nothing is), so it never starts something.
        switch musicCommand {
        case .play:
            guard !VesperMediaKeys.isAnotherAppPlayingSound() else { return "it's already playing." }
            VesperMediaKeys.press(VesperMediaKeys.playPauseKey)
            return nil
        case .pause:
            guard VesperMediaKeys.isAnotherAppPlayingSound() else { return "nothing's playing." }
            VesperMediaKeys.press(VesperMediaKeys.playPauseKey)
            return nil
        case .nextTrack:
            VesperMediaKeys.press(VesperMediaKeys.nextTrackKey)
            return nil
        case .previousTrack:
            VesperMediaKeys.press(VesperMediaKeys.previousTrackKey)
            return nil
        case .playSearchResult(let searchQuery):
            // The query is passed as an argument, never pasted into the
            // script, so a song name can't break or change the script.
            // Music's scripting only reaches the user's library (including
            // songs added from Apple Music), not the whole catalog.
            let playSearchScript = """
            on run argv
                set searchText to item 1 of argv
                tell application "Music"
                    if exists (user playlist searchText) then
                        play user playlist searchText
                        return "playlist"
                    end if
                    set matchingTracks to (search library playlist 1 for searchText)
                    if (count of matchingTracks) is 0 then return "not found"
                    play item 1 of matchingTracks
                    return "track"
                end tell
            end run
            """
            let scriptOutput = await runAppleScript(playSearchScript, arguments: [searchQuery])
            if scriptOutput == nil {
                return "music wouldn't play that."
            }
            if scriptOutput == "not found" {
                return "\(searchQuery.lowercased()) isn't in your music library."
            }
            return nil
        }
    }

    private static func changeVolume(_ volumeChange: VesperVolumeChange) async -> String? {
        print("⚡ Quick action: volume \(volumeChange)")
        let volumeScript: String
        switch volumeChange {
        case .setLevel(let percent):
            volumeScript = "set volume output volume \(percent) without output muted"
        case .up:
            volumeScript = "set volume output volume ((output volume of (get volume settings)) + 10) without output muted"
        case .down:
            volumeScript = "set volume output volume ((output volume of (get volume settings)) - 10)"
        case .mute:
            volumeScript = "set volume with output muted"
        case .unmute:
            volumeScript = "set volume without output muted"
        }
        return await runAppleScript(volumeScript) == nil ? "the volume wouldn't budge." : nil
    }

    /// Runs AppleScript through osascript. Returns its trimmed output, or nil on failure.
    private static func runAppleScript(_ scriptSource: String, arguments scriptArguments: [String] = []) async -> String? {
        let scriptResult = await VesperProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", scriptSource] + scriptArguments
        )
        guard scriptResult.exitStatus == 0 else {
            print("⚠️ AppleScript failed (\(scriptResult.exitStatus)): \(scriptResult.standardError)")
            return nil
        }
        return scriptResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a short-lived command-line tool without blocking the main thread.
enum VesperProcessRunner {
    struct ProcessResult {
        let exitStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Exit status reported when a tool took longer than its time limit.
    nonisolated static let timedOutExitStatus: Int32 = -2
    /// Quick actions finish in well under a second. Longer means stuck — a
    /// first-time Automation prompt nobody answered, or a hung osascript —
    /// and waiting would leave her "busy" with the cursor away from home.
    nonisolated static let defaultTimeoutSeconds: Double = 5

    nonisolated static func run(executablePath: String, arguments: [String], timeoutSeconds: Double = defaultTimeoutSeconds) async -> ProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            process.standardOutput = standardOutputPipe
            process.standardError = standardErrorPipe
            // Exit and timeout race; whichever is first answers, once.
            let singleResumption = SingleResumption(continuation: continuation)
            // Both pipes are read while the tool runs, not after it exits: a
            // pipe holds only 64 KB, and a tool that prints more (a shortcut
            // that outputs an image) would block on the full pipe, never
            // exit, and be misreported as timed out.
            let outputReading = DispatchGroup()
            let standardOutputCollector = PipeOutputCollector()
            let standardErrorCollector = PipeOutputCollector()
            standardOutputCollector.startReading(standardOutputPipe.fileHandleForReading, trackedBy: outputReading)
            standardErrorCollector.startReading(standardErrorPipe.fileHandleForReading, trackedBy: outputReading)
            process.terminationHandler = { finishedProcess in
                // The readers finish at end of file, normally right after
                // exit. A background child that inherited the pipe could keep
                // it open, so don't wait on them for more than a second.
                _ = outputReading.wait(timeout: .now() + 1)
                singleResumption.resume(returning: ProcessResult(
                    exitStatus: finishedProcess.terminationStatus,
                    standardOutput: String(decoding: standardOutputCollector.collectedData, as: UTF8.self),
                    standardError: String(decoding: standardErrorCollector.collectedData, as: UTF8.self)
                ))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // Close our copies of the write ends so the readers see end
                // of file and finish instead of waiting forever.
                try? standardOutputPipe.fileHandleForWriting.close()
                try? standardErrorPipe.fileHandleForWriting.close()
                singleResumption.resume(returning: ProcessResult(exitStatus: -1, standardOutput: "", standardError: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                guard process.isRunning else { return }
                print("⚠️ \((executablePath as NSString).lastPathComponent) took over \(Int(timeoutSeconds))s — stopped it")
                process.terminate()
                singleResumption.resume(returning: ProcessResult(exitStatus: timedOutExitStatus, standardOutput: "", standardError: "timed out"))
            }
        }
    }

    /// Reads one pipe to its end on a background queue, keeping the bytes.
    nonisolated private final class PipeOutputCollector: @unchecked Sendable {
        private var bytesReadSoFar = Data()
        private let bytesLock = NSLock()

        var collectedData: Data {
            bytesLock.lock()
            defer { bytesLock.unlock() }
            return bytesReadSoFar
        }

        func startReading(_ pipeReadHandle: FileHandle, trackedBy outputReading: DispatchGroup) {
            outputReading.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let allBytes = pipeReadHandle.readDataToEndOfFile()
                self.bytesLock.lock()
                self.bytesReadSoFar = allBytes
                self.bytesLock.unlock()
                outputReading.leave()
            }
        }
    }

    /// Resumes a continuation at most once, from any thread.
    nonisolated private final class SingleResumption: @unchecked Sendable {
        private let continuation: CheckedContinuation<ProcessResult, Never>
        private var hasResumed = false
        private let resumptionLock = NSLock()

        init(continuation: CheckedContinuation<ProcessResult, Never>) {
            self.continuation = continuation
        }

        func resume(returning processResult: ProcessResult) {
            resumptionLock.lock()
            let shouldResume = !hasResumed
            hasResumed = true
            resumptionLock.unlock()
            if shouldResume {
                continuation.resume(returning: processResult)
            }
        }
    }
}

// MARK: - Key Combinations

/// A parsed [KEY:...] value like "cmd+shift+t" or "return".
struct VesperKeyCombination: Equatable {
    enum Modifier: String, CaseIterable {
        case command
        case shift
        case option
        case control
    }

    let virtualKeyCode: CGKeyCode
    /// The main key's normalized name, e.g. "return", "l", "down".
    let keyName: String
    let modifiers: Set<Modifier>

    init?(parsing keyCombinationText: String) {
        let keyParts = keyCombinationText
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let mainKeyText = keyParts.last else { return nil }

        var parsedModifiers = Set<Modifier>()
        for modifierText in keyParts.dropLast() {
            switch modifierText {
            case "cmd", "command", "⌘": parsedModifiers.insert(.command)
            case "shift", "⇧": parsedModifiers.insert(.shift)
            case "option", "opt", "alt", "⌥": parsedModifiers.insert(.option)
            case "ctrl", "control", "⌃": parsedModifiers.insert(.control)
            default: return nil
            }
        }

        let normalizedKeyName = Self.keyNameAliases[mainKeyText] ?? mainKeyText
        guard let virtualKeyCode = Self.virtualKeyCodesByKeyName[normalizedKeyName] else { return nil }
        self.virtualKeyCode = virtualKeyCode
        self.keyName = normalizedKeyName
        self.modifiers = parsedModifiers
    }

    var isReturnOrEnter: Bool { keyName == "return" || keyName == "enter" }

    /// Return, plus ctrl+M, ctrl+J and ctrl+O, which terminals and many text
    /// fields treat as Return — so they can't slip a send past the Return rules.
    var submitsLikeReturn: Bool {
        isReturnOrEnter || (modifiers == [.control] && ["m", "j", "o"].contains(keyName))
    }

    /// A key that types a character (a letter, digit or punctuation mark).
    var isCharacterKey: Bool { keyName.count == 1 }

    /// Modifiers in a fixed order, then the key: "command+shift+t".
    var normalizedShortcutName: String {
        let orderedModifiers: [Modifier] = [.command, .control, .option, .shift]
        let modifierNames = orderedModifiers.filter(modifiers.contains).map(\.rawValue)
        return (modifierNames + [keyName]).joined(separator: "+")
    }

    /// How she says it in a question: "command shift t".
    var spokenDescription: String {
        normalizedShortcutName.replacingOccurrences(of: "+", with: " ")
    }

    /// Keys that only move focus or the caret — never type anything.
    var isNavigationKey: Bool {
        ["tab", "left", "right", "up", "down", "escape", "home", "end", "pageup", "pagedown"].contains(keyName)
            && !modifiers.contains(.command)
    }

    var cgEventFlags: CGEventFlags {
        var eventFlags = CGEventFlags()
        if modifiers.contains(.command) { eventFlags.insert(.maskCommand) }
        if modifiers.contains(.shift) { eventFlags.insert(.maskShift) }
        if modifiers.contains(.option) { eventFlags.insert(.maskAlternate) }
        if modifiers.contains(.control) { eventFlags.insert(.maskControl) }
        return eventFlags
    }

    private static let keyNameAliases: [String: String] = [
        "enter": "enter", "ret": "return", "esc": "escape", "backspace": "delete",
        "del": "forwarddelete", "forward delete": "forwarddelete", "arrowup": "up",
        "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
        "pgup": "pageup", "pgdn": "pagedown", "spacebar": "space"
    ]

    /// macOS virtual key codes (US ANSI layout positions).
    private static let virtualKeyCodesByKeyName: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53, "enter": 76,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}

// MARK: - Posting Events

/// Posts mouse and keyboard events. A protocol so tests can record what
/// would have been done instead of touching the real screen.
protocol VesperScreenEventPosting: AnyObject {
    func click(atAppKitGlobalPoint appKitGlobalPoint: CGPoint, clickKind: VesperClickKind) async
    func typeText(_ textToType: String) async
    func pressKeyCombination(_ keyCombination: VesperKeyCombination) async
    func scroll(direction: VesperScrollDirection, atAppKitGlobalPoint appKitGlobalPoint: CGPoint?) async
}

enum VesperScreenCoordinates {
    /// AppKit's global coordinates start at the bottom-left of the primary
    /// screen; CGEvent and Accessibility use the top-left. Flips between them.
    static func quartzPoint(fromAppKitGlobalPoint appKitGlobalPoint: CGPoint) -> CGPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: appKitGlobalPoint.x, y: primaryScreenHeight - appKitGlobalPoint.y)
    }
}

final class SystemScreenEventPoster: VesperScreenEventPosting {
    /// Typing is sent in small chunks; many apps drop longer unicode events.
    private static let typingChunkCharacterLimit = 16

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    func click(atAppKitGlobalPoint appKitGlobalPoint: CGPoint, clickKind: VesperClickKind) async {
        let quartzPoint = VesperScreenCoordinates.quartzPoint(fromAppKitGlobalPoint: appKitGlobalPoint)
        let mouseButton: CGMouseButton = clickKind == .right ? .right : .left
        let mouseDownType: CGEventType = clickKind == .right ? .rightMouseDown : .leftMouseDown
        let mouseUpType: CGEventType = clickKind == .right ? .rightMouseUp : .leftMouseUp

        post(CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint, mouseButton: mouseButton))
        await pause(milliseconds: 60)

        let clickCount = clickKind == .double ? 2 : 1
        for clickNumber in 1...clickCount {
            let mouseDownEvent = CGEvent(mouseEventSource: eventSource, mouseType: mouseDownType, mouseCursorPosition: quartzPoint, mouseButton: mouseButton)
            let mouseUpEvent = CGEvent(mouseEventSource: eventSource, mouseType: mouseUpType, mouseCursorPosition: quartzPoint, mouseButton: mouseButton)
            // The click state tells apps "this is the second click of a
            // double-click" rather than two separate clicks.
            mouseDownEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            mouseUpEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            post(mouseDownEvent)
            await pause(milliseconds: 40)
            post(mouseUpEvent)
            if clickNumber < clickCount {
                await pause(milliseconds: 80)
            }
        }
    }

    func typeText(_ textToType: String) async {
        var remainingCharacters = Substring(textToType)
        // Checked every chunk, so the hotkey stops long text mid-way.
        while !remainingCharacters.isEmpty && !Task.isCancelled {
            let chunkCharacters = remainingCharacters.prefix(Self.typingChunkCharacterLimit)
            remainingCharacters = remainingCharacters.dropFirst(chunkCharacters.count)
            let chunkUTF16 = Array(String(chunkCharacters).utf16)

            let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
            let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
            keyDownEvent?.keyboardSetUnicodeString(stringLength: chunkUTF16.count, unicodeString: chunkUTF16)
            keyUpEvent?.keyboardSetUnicodeString(stringLength: chunkUTF16.count, unicodeString: chunkUTF16)
            // No modifiers, even if the user happens to be holding one.
            keyDownEvent?.flags = []
            keyUpEvent?.flags = []
            post(keyDownEvent)
            post(keyUpEvent)
            await pause(milliseconds: 25)
        }
    }

    func pressKeyCombination(_ keyCombination: VesperKeyCombination) async {
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCombination.virtualKeyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCombination.virtualKeyCode, keyDown: false)
        keyDownEvent?.flags = keyCombination.cgEventFlags
        keyUpEvent?.flags = keyCombination.cgEventFlags
        post(keyDownEvent)
        await pause(milliseconds: 30)
        post(keyUpEvent)
    }

    func scroll(direction: VesperScrollDirection, atAppKitGlobalPoint appKitGlobalPoint: CGPoint?) async {
        if let appKitGlobalPoint {
            let quartzPoint = VesperScreenCoordinates.quartzPoint(fromAppKitGlobalPoint: appKitGlobalPoint)
            post(CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint, mouseButton: .left))
            await pause(milliseconds: 60)
        }

        // About two thirds of a screen, in a few pixel steps so pages that
        // animate scrolling keep up.
        let scrollStepPixels: Int32 = 120
        let scrollStepCount = 5
        let verticalStep: Int32 = direction == .up ? scrollStepPixels : (direction == .down ? -scrollStepPixels : 0)
        let horizontalStep: Int32 = direction == .left ? scrollStepPixels : (direction == .right ? -scrollStepPixels : 0)
        for _ in 0..<scrollStepCount where !Task.isCancelled {
            post(CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: verticalStep,
                wheel2: horizontalStep,
                wheel3: 0
            ))
            await pause(milliseconds: 30)
        }
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        // Mouse events would otherwise carry whatever modifiers the user is
        // holding right now — e.g. ctrl+option (the stop hotkey) turning a
        // click into a ctrl-click that opens a context menu.
        let mouseEventTypes: Set<CGEventType> = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        if mouseEventTypes.contains(event.type) {
            event.flags = []
        }
        event.setIntegerValueField(.eventSourceUserData, value: VesperPostedEventMarker.eventSourceUserDataValue)
        event.post(tap: .cghidEventTap)
    }

    private func pause(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}
