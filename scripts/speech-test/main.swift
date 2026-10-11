//
//  main.swift — test driver for Vesper's speech output
//
//  Runs the real VesperSpeechPlaybackEngine + SystemSpeechSynthesisProvider
//  and plays speech OUT LOUD through the Mac's speakers. Checks that
//  sentences play in order, that each one reports when it starts (which is
//  what drives pointing and captions), how fast the first word comes out,
//  that the output level moves (drives the cursor glow), and that barge-in
//  stops everything instantly. Built and run by scripts/test-speech-output.sh.
//

import Foundation

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

func waitUntil(timeoutSeconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

func runAllChecks() async {
    let systemSpeechProvider = SystemSpeechSynthesisProvider()
    print("voice: \(systemSpeechProvider.displayName)\(systemSpeechProvider.isUsingLowQualityVoice ? "  (default quality — a Premium voice would sound much better)" : "")")
    // Kokoro mode with no Kokoro loaded: every sentence uses the macOS voice,
    // which is what this test exercises (Kokoro and Google have their own tests).
    let voiceRouter = VesperVoiceRouter(voiceMode: .kokoro, googleProvider: nil, kokoroProvider: nil, systemVoiceProvider: systemSpeechProvider)
    let speechPlaybackEngine = VesperSpeechPlaybackEngine(voiceRouter: voiceRouter)

    // The app warms the voice at launch and on every hotkey press, because
    // macOS loads it lazily (~3.8s the first time). Do the same here.
    print("\n— warming up the voice, as the app does at launch")
    let warmupStartedAt = Date()
    _ = try? await systemSpeechProvider.synthesizeSpeechAudio(for: "hi.")
    print(String(format: "   cold voice load took %.1fs (hidden at launch in the app)", Date().timeIntervalSince(warmupStartedAt)))
    speechPlaybackEngine.prewarm()

    // 1. A three-sentence reply, streamed in the way a Claude reply arrives.
    print("\n— a three-sentence reply")
    let sentences = [
        "hey, this is vesper, testing my voice.",
        "if you can hear this, the audio path works.",
        "and this is the last one."
    ]
    var sentenceStartTimes: [Int: Date] = [:]
    var peakOutputLevel: CGFloat = 0
    var utteranceFinished = false

    let firstSentenceEnqueuedAt = Date()
    speechPlaybackEngine.beginNewUtterance(onFinished: { utteranceFinished = true })
    for (sentenceIndex, sentence) in sentences.enumerated() {
        speechPlaybackEngine.enqueueSegment(VesperSpeechSegment(
            spokenText: sentence,
            onStartedPlaying: { sentenceStartTimes[sentenceIndex] = Date() }
        ))
        // Later sentences arrive a little after the first, like streamed text.
        try? await Task.sleep(for: .milliseconds(150))
    }
    speechPlaybackEngine.finishUtterance()

    let finishedInTime = await waitUntil(timeoutSeconds: 30) {
        peakOutputLevel = max(peakOutputLevel, speechPlaybackEngine.currentOutputAudioLevel)
        return utteranceFinished
    }
    check(finishedInTime, "the reply plays to the end and reports it's finished")
    check(sentenceStartTimes.count == 3, "every sentence reports when it starts playing", "\(sentenceStartTimes.count) of 3")
    if let firstStart = sentenceStartTimes[0], let secondStart = sentenceStartTimes[1], let thirdStart = sentenceStartTimes[2] {
        check(firstStart < secondStart && secondStart < thirdStart, "sentences play in order")
        let firstWordSeconds = firstStart.timeIntervalSince(firstSentenceEnqueuedAt)
        check(firstWordSeconds < 0.3, "first word plays quickly once the voice is warm",
              String(format: "%.0f ms", firstWordSeconds * 1000))
    }
    check(peakOutputLevel > 0.05, "output level moves while she talks (drives the glow)", String(format: "peak %.2f", peakOutputLevel))
    check(!speechPlaybackEngine.isSpeaking, "not speaking after the reply ends")

    // 2. Barge-in: stop mid-sentence; nothing later may play.
    print("\n— interrupting her")
    var interruptedUtteranceFinished = false
    var laterSentenceStarted = false
    speechPlaybackEngine.beginNewUtterance(onFinished: { interruptedUtteranceFinished = true })
    speechPlaybackEngine.enqueueSegment(VesperSpeechSegment(
        spokenText: "this is a long sentence that is going to be cut off halfway through, so you should only hear the start of it.",
        onStartedPlaying: {}
    ))
    speechPlaybackEngine.enqueueSegment(VesperSpeechSegment(
        spokenText: "you should never hear this sentence.",
        onStartedPlaying: { laterSentenceStarted = true }
    ))
    speechPlaybackEngine.finishUtterance()
    try? await Task.sleep(for: .milliseconds(1200))
    speechPlaybackEngine.stopImmediately()
    try? await Task.sleep(for: .milliseconds(1500))
    check(!laterSentenceStarted, "after an interrupt, no later sentence plays")
    check(!interruptedUtteranceFinished, "an interrupted reply doesn't report 'finished' (so the cursor logic isn't confused)")
    check(!speechPlaybackEngine.isSpeaking, "not speaking after the interrupt")

    // 3. Text that arrives after an interrupt must be ignored, not spoken.
    speechPlaybackEngine.enqueueSegment(VesperSpeechSegment(
        spokenText: "stale text that should be ignored.",
        onStartedPlaying: { laterSentenceStarted = true }
    ))
    try? await Task.sleep(for: .milliseconds(800))
    check(!laterSentenceStarted, "text arriving after an interrupt is ignored")

    // 4. She can speak again right after being interrupted.
    print("\n— speaking again after an interrupt")
    var recoveredUtteranceFinished = false
    speechPlaybackEngine.beginNewUtterance(onFinished: { recoveredUtteranceFinished = true })
    speechPlaybackEngine.enqueueSegment(VesperSpeechSegment(spokenText: "and i'm back.", onStartedPlaying: {}))
    speechPlaybackEngine.finishUtterance()
    let recoveredInTime = await waitUntil(timeoutSeconds: 10) { recoveredUtteranceFinished }
    check(recoveredInTime, "a new reply plays normally after an interrupt")
}

Task { @MainActor in
    await runAllChecks()
    print(failedCheckCount == 0 ? "\n✅ all speech checks passed" : "\n❌ \(failedCheckCount) speech check(s) failed")
    exit(failedCheckCount == 0 ? 0 : 1)
}
dispatchMain()
