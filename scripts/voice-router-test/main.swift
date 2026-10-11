//
//  main.swift — test driver for VesperVoiceRouter
//
//  Checks which voice speaks each sentence, using fake voices whose speed
//  and failures are controlled exactly. Silent: nothing is played.
//  Built and run by scripts/test-voice-router.sh.
//

@preconcurrency import AVFoundation
import Foundation

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

/// A voice that answers after a set delay (or fails), and counts its calls.
final class FakeVoice: VesperSpeechSynthesisProvider {
    let displayName: String
    var isAvailable = true
    var secondsPerSentence: TimeInterval
    var shouldFail = false
    private(set) var sentencesRequested = 0
    /// Each fake voice returns a buffer of a distinct length, so the test can
    /// tell which voice produced it.
    let signatureFrameCount: AVAudioFrameCount

    init(displayName: String, secondsPerSentence: TimeInterval, signatureFrameCount: AVAudioFrameCount) {
        self.displayName = displayName
        self.secondsPerSentence = secondsPerSentence
        self.signatureFrameCount = signatureFrameCount
    }

    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer] {
        sentencesRequested += 1
        try await Task.sleep(for: .seconds(secondsPerSentence))
        if shouldFail {
            throw VesperSpeechSynthesisError(message: "\(displayName) failed on purpose")
        }
        let silentBuffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!,
            frameCapacity: signatureFrameCount
        )!
        silentBuffer.frameLength = signatureFrameCount
        return [silentBuffer]
    }
}

/// A Kokoro that unloaded while idle: unavailable until waited for, then
/// ready after `secondsUntilReloaded` (if the wait lasts that long).
final class ReloadingFakeKokoro: VesperSpeechSynthesisProvider {
    let displayName = "Kokoro"
    var isAvailable = false
    let secondsUntilReloaded: TimeInterval
    private(set) var waitRequestCount = 0

    init(secondsUntilReloaded: TimeInterval) {
        self.secondsUntilReloaded = secondsUntilReloaded
    }

    func waitUntilAvailableIfReloading(maximumSeconds: TimeInterval) async -> Bool {
        waitRequestCount += 1
        try? await Task.sleep(for: .seconds(min(secondsUntilReloaded, maximumSeconds)))
        if secondsUntilReloaded <= maximumSeconds {
            isAvailable = true
        }
        return isAvailable
    }

    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer] {
        let silentBuffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!,
            frameCapacity: 222
        )!
        silentBuffer.frameLength = 222
        return [silentBuffer]
    }
}

/// Which fake voice produced a sentence, from its buffer's signature length.
func speakerName(of speechBuffers: [AVAudioPCMBuffer]?, voices: [FakeVoice]) -> String {
    guard let frameCount = speechBuffers?.first?.frameLength else { return "nobody" }
    return voices.first { $0.signatureFrameCount == frameCount }?.displayName ?? "unknown"
}

/// Times one sentence through the router and reports who spoke it.
func speak(_ router: VesperVoiceRouter, voices: [FakeVoice], newReply: Bool = true) async -> (speaker: String, seconds: TimeInterval) {
    if newReply {
        router.beginNewReply()
    }
    let startedAt = Date()
    let speechBuffers = await router.synthesizeSentence("a test sentence.")
    return (speakerName(of: speechBuffers, voices: voices), Date().timeIntervalSince(startedAt))
}

func runAllChecks() async {
    let google = FakeVoice(displayName: "Google", secondsPerSentence: 0.3, signatureFrameCount: 111)
    let kokoro = FakeVoice(displayName: "Kokoro", secondsPerSentence: 0.2, signatureFrameCount: 222)
    let macOSVoice = FakeVoice(displayName: "macOS", secondsPerSentence: 0.05, signatureFrameCount: 333)
    let allVoices = [google, kokoro, macOSVoice]
    let router = VesperVoiceRouter(voiceMode: .automatic, googleProvider: google, kokoroProvider: kokoro, systemVoiceProvider: macOSVoice)

    // --- Auto mode races ---
    print("\n— Auto mode")
    var outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Google" && outcome.seconds < 0.45,
          "Google answering in 0.3s (Kokoro 0.2s) wins: Google is preferred",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))

    google.secondsPerSentence = 0.65
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Google", "Google at 0.65s still wins (within the 0.7s allowance)",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))

    // Two more slow answers would trigger the cooldown, so reset it by winning after.
    google.secondsPerSentence = 2.0
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Kokoro" && outcome.seconds < 0.85,
          "Google at 2s loses: Kokoro speaks after the 0.7s allowance, not 2s later",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))

    google.secondsPerSentence = 0.1
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Google", "a quick Google wins again (and resets the loss streak)")

    kokoro.secondsPerSentence = 1.5
    google.secondsPerSentence = 1.0
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Google", "when Kokoro is the slow one, Google wins as soon as it answers",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))
    kokoro.secondsPerSentence = 0.2

    google.secondsPerSentence = 0.2
    google.shouldFail = true
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Kokoro", "Google failing hands the reply to Kokoro")
    google.shouldFail = false

    kokoro.shouldFail = true
    google.secondsPerSentence = 1.2
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Google", "Kokoro failing means waiting for Google, even past the allowance",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))
    kokoro.shouldFail = false

    google.shouldFail = true
    kokoro.shouldFail = true
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "macOS", "both failing falls back to the macOS voice — never silent")
    google.shouldFail = false
    kokoro.shouldFail = false

    // --- One voice per reply ---
    print("\n— one voice for the whole reply")
    google.secondsPerSentence = 2.0
    let firstSentence = await speak(router, voices: allVoices)
    google.secondsPerSentence = 0.05
    let secondSentence = await speak(router, voices: allVoices, newReply: false)
    check(firstSentence.speaker == "Kokoro" && secondSentence.speaker == "Kokoro",
          "once Kokoro starts a reply, it finishes it even if Google speeds up",
          "\(firstSentence.speaker), then \(secondSentence.speaker)")
    let googleCallsBefore = google.sentencesRequested
    _ = await speak(router, voices: allVoices, newReply: false)
    check(google.sentencesRequested == googleCallsBefore, "later sentences of the reply don't ask Google at all")

    // --- Cooldown after repeated losses ---
    print("\n— Google cooldown")
    google.secondsPerSentence = 0.1
    _ = await speak(router, voices: allVoices) // a win resets the streak
    google.secondsPerSentence = 2.0
    for _ in 1...3 {
        _ = await speak(router, voices: allVoices)
    }
    let googleCallsBeforeCooldown = google.sentencesRequested
    google.secondsPerSentence = 0.05
    outcome = await speak(router, voices: allVoices)
    check(outcome.speaker == "Kokoro" && google.sentencesRequested == googleCallsBeforeCooldown,
          "after 3 losses in a row, Auto stops asking Google for a while",
          "\(outcome.speaker); Google asked \(google.sentencesRequested - googleCallsBeforeCooldown) more times")

    // --- Fixed modes ---
    print("\n— fixed modes")
    let freshGoogle = FakeVoice(displayName: "Google", secondsPerSentence: 1.5, signatureFrameCount: 111)
    let freshVoices = [freshGoogle, kokoro, macOSVoice]
    let googleModeRouter = VesperVoiceRouter(voiceMode: .google, googleProvider: freshGoogle, kokoroProvider: nil, systemVoiceProvider: macOSVoice)
    outcome = await speak(googleModeRouter, voices: freshVoices)
    check(outcome.speaker == "Google", "Google mode waits for Google, however slow",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))
    freshGoogle.shouldFail = true
    outcome = await speak(googleModeRouter, voices: freshVoices)
    check(outcome.speaker == "macOS", "Google mode falls back to the macOS voice if Google fails")
    freshGoogle.isAvailable = false
    outcome = await speak(googleModeRouter, voices: freshVoices)
    check(outcome.speaker == "macOS", "Google mode without a key uses the macOS voice")

    let kokoroModeRouter = VesperVoiceRouter(voiceMode: .kokoro, googleProvider: google, kokoroProvider: kokoro, systemVoiceProvider: macOSVoice)
    let googleCallsBeforeKokoroMode = google.sentencesRequested
    outcome = await speak(kokoroModeRouter, voices: allVoices)
    check(outcome.speaker == "Kokoro" && google.sentencesRequested == googleCallsBeforeKokoroMode,
          "Kokoro mode uses Kokoro and never contacts Google")
    kokoro.isAvailable = false
    outcome = await speak(kokoroModeRouter, voices: allVoices)
    check(outcome.speaker == "macOS", "Kokoro mode before Kokoro has loaded uses the macOS voice")
    kokoro.isAvailable = true

    // --- Barge-in: a sentence from an interrupted reply finishing late ---
    print("\n— stale sentence after a barge-in")
    let staleGoogle = FakeVoice(displayName: "Google", secondsPerSentence: 1.0, signatureFrameCount: 111)
    let staleKokoro = FakeVoice(displayName: "Kokoro", secondsPerSentence: 0.2, signatureFrameCount: 222)
    let staleVoices = [staleGoogle, staleKokoro, macOSVoice]
    let bargeInRouter = VesperVoiceRouter(voiceMode: .automatic, googleProvider: staleGoogle, kokoroProvider: staleKokoro, systemVoiceProvider: macOSVoice)
    bargeInRouter.beginNewReply()
    let interruptedSentence = Task { await bargeInRouter.synthesizeSentence("the interrupted reply.") }
    try? await Task.sleep(for: .milliseconds(100))
    bargeInRouter.beginNewReply()   // the user barged in; a new reply begins
    staleGoogle.secondsPerSentence = 0.1
    _ = await interruptedSentence.value   // Kokoro wins that stale race late
    outcome = await speak(bargeInRouter, voices: staleVoices, newReply: false)
    check(outcome.speaker == "Google", "a stale sentence finishing late doesn't choose the new reply's voice", outcome.speaker)

    // --- Auto with only one voice configured ---
    print("\n— Auto with one voice missing")
    let autoWithoutGoogle = VesperVoiceRouter(voiceMode: .automatic, googleProvider: nil, kokoroProvider: kokoro, systemVoiceProvider: macOSVoice)
    outcome = await speak(autoWithoutGoogle, voices: allVoices)
    check(outcome.speaker == "Kokoro", "Auto without a Google key uses Kokoro")
    let autoWithoutKokoro = VesperVoiceRouter(voiceMode: .automatic, googleProvider: freshGoogle, kokoroProvider: nil, systemVoiceProvider: macOSVoice)
    freshGoogle.isAvailable = true
    freshGoogle.shouldFail = false
    freshGoogle.secondsPerSentence = 0.3
    outcome = await speak(autoWithoutKokoro, voices: freshVoices)
    check(outcome.speaker == "Google", "Auto while Kokoro is still loading uses Google")

    // --- Kokoro reloading after an idle unload ---
    print("\n— Kokoro reloading after being unloaded while idle")
    let quicklyReloadingKokoro = ReloadingFakeKokoro(secondsUntilReloaded: 0.5)
    let quickReloadRouter = VesperVoiceRouter(voiceMode: .kokoro, googleProvider: nil, kokoroProvider: quicklyReloadingKokoro, systemVoiceProvider: macOSVoice)
    outcome = await speak(quickReloadRouter, voices: allVoices)
    check(outcome.speaker == "Kokoro" && outcome.seconds < 1.0,
          "Kokoro mode waits for a Kokoro that's back in 0.5s instead of using the macOS voice",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))
    let slowlyReloadingKokoro = ReloadingFakeKokoro(secondsUntilReloaded: 3)
    let slowKokoroRouter = VesperVoiceRouter(voiceMode: .kokoro, googleProvider: nil, kokoroProvider: slowlyReloadingKokoro, systemVoiceProvider: macOSVoice)
    outcome = await speak(slowKokoroRouter, voices: allVoices)
    check(outcome.speaker == "macOS" && outcome.seconds >= 1.4 && outcome.seconds < 2.0,
          "a Kokoro that needs 3s is waited for at most ~1.5s, then the macOS voice speaks",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))
    let reloadingKokoroWithGoogle = ReloadingFakeKokoro(secondsUntilReloaded: 0.5)
    let readyGoogle = FakeVoice(displayName: "Google", secondsPerSentence: 0.1, signatureFrameCount: 111)
    let autoRouterWithGoogle = VesperVoiceRouter(voiceMode: .automatic, googleProvider: readyGoogle, kokoroProvider: reloadingKokoroWithGoogle, systemVoiceProvider: macOSVoice)
    outcome = await speak(autoRouterWithGoogle, voices: allVoices)
    check(outcome.speaker == "Google" && reloadingKokoroWithGoogle.waitRequestCount == 0,
          "Auto with Google ready never waits for a reloading Kokoro",
          String(format: "%@ in %.2fs", outcome.speaker, outcome.seconds))
}

Task { @MainActor in
    await runAllChecks()
    print(failedCheckCount == 0 ? "\n✅ all voice router checks passed" : "\n❌ \(failedCheckCount) voice router check(s) failed")
    exit(failedCheckCount == 0 ? 0 : 1)
}
dispatchMain()
