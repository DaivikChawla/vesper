//
//  main.swift — silent test driver for VesperSpeechPlaybackEngine
//
//  The real playback engine with fake voices that return silent audio of a
//  set length, so nothing is heard. Checks that sentences start in order,
//  that a finished reply reports it, and that a barge-in during synthesis
//  never lets the interrupted reply start speaking or finish.
//  Built and run by scripts/test-playback-engine.sh.
//

import AVFoundation
import Foundation

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

/// A voice that takes `secondsToSynthesize` and returns `secondsOfAudio` of silence.
final class SilentFakeVoice: VesperSpeechSynthesisProvider {
    let displayName: String
    var isAvailable = true
    var secondsToSynthesize: TimeInterval
    let secondsOfAudio: TimeInterval

    init(displayName: String, secondsToSynthesize: TimeInterval, secondsOfAudio: TimeInterval) {
        self.displayName = displayName
        self.secondsToSynthesize = secondsToSynthesize
        self.secondsOfAudio = secondsOfAudio
    }

    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer] {
        try await Task.sleep(for: .seconds(secondsToSynthesize))
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let frameCount = AVAudioFrameCount(secondsOfAudio * 24_000)
        let silentBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount)!
        silentBuffer.frameLength = frameCount
        return [silentBuffer]
    }
}

func waitUntil(timeoutSeconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

func runAllChecks() async {
    print("— Objective-C exceptions become Swift errors")
    var caughtExceptionError: VesperObjectiveCExceptionError?
    do {
        try VesperObjectiveCExceptions.run("a test call") {
            NSException(name: .internalInconsistencyException, reason: "raised on purpose", userInfo: nil).raise()
        }
    } catch let exceptionError as VesperObjectiveCExceptionError {
        caughtExceptionError = exceptionError
    } catch {}
    check(caughtExceptionError?.exceptionReason == "raised on purpose",
          "an NSException raised inside an audio call is caught and thrown as an error, not a crash")
    var didRunNormally = false
    let normalRunError: Error? = {
        do {
            try VesperObjectiveCExceptions.run("a normal call") { didRunNormally = true }
            return nil
        } catch {
            return error
        }
    }()
    check(didRunNormally && normalRunError == nil, "a call that doesn't raise runs once and throws nothing")

    let kokoro = SilentFakeVoice(displayName: "Kokoro", secondsToSynthesize: 0.05, secondsOfAudio: 0.2)
    let macOSVoice = SilentFakeVoice(displayName: "macOS", secondsToSynthesize: 0.05, secondsOfAudio: 0.2)
    let voiceRouter = VesperVoiceRouter(voiceMode: .kokoro, googleProvider: nil, kokoroProvider: kokoro, systemVoiceProvider: macOSVoice)
    let playbackEngine = VesperSpeechPlaybackEngine(voiceRouter: voiceRouter)

    print("— order and finishing")
    var startedSentences: [String] = []
    var didFinishReply = false
    playbackEngine.beginNewUtterance(onFinished: { didFinishReply = true })
    for sentenceText in ["one.", "two.", "three."] {
        playbackEngine.enqueueSegment(VesperSpeechSegment(spokenText: sentenceText, onStartedPlaying: { startedSentences.append(sentenceText) }))
    }
    playbackEngine.finishUtterance()
    let finishedInTime = await waitUntil(timeoutSeconds: 5) { didFinishReply }
    check(finishedInTime, "a reply reports that it finished")
    check(startedSentences == ["one.", "two.", "three."], "sentences start in order", "\(startedSentences)")

    print("— barge-in during synthesis")
    kokoro.secondsToSynthesize = 0.5
    var interruptedReplyStarted = false
    var interruptedReplyFinished = false
    playbackEngine.beginNewUtterance(onFinished: { interruptedReplyFinished = true })
    playbackEngine.enqueueSegment(VesperSpeechSegment(spokenText: "old reply.", onStartedPlaying: { interruptedReplyStarted = true }))
    try? await Task.sleep(for: .milliseconds(100))
    // The user barges in and a new reply begins while "old reply." is still being synthesized.
    kokoro.secondsToSynthesize = 0.05
    var newReplyStarted = false
    var newReplyFinished = false
    playbackEngine.beginNewUtterance(onFinished: { newReplyFinished = true })
    playbackEngine.enqueueSegment(VesperSpeechSegment(spokenText: "new reply.", onStartedPlaying: { newReplyStarted = true }))
    playbackEngine.finishUtterance()
    let newReplyFinishedInTime = await waitUntil(timeoutSeconds: 5) { newReplyFinished }
    check(newReplyFinishedInTime && newReplyStarted, "the new reply speaks and finishes")
    check(!interruptedReplyStarted, "the interrupted reply's sentence never starts (so its point and actions never run)")
    check(!interruptedReplyFinished, "the interrupted reply never reports finishing")

    print("— stop")
    var stoppedReplyFinished = false
    playbackEngine.beginNewUtterance(onFinished: { stoppedReplyFinished = true })
    playbackEngine.enqueueSegment(VesperSpeechSegment(spokenText: "about to be stopped.", onStartedPlaying: {}))
    playbackEngine.finishUtterance()
    playbackEngine.stopImmediately()
    try? await Task.sleep(for: .seconds(1))
    check(!stoppedReplyFinished && !playbackEngine.isSpeaking, "stopping silences a reply without reporting it finished")
}

Task { @MainActor in
    await runAllChecks()
    print(failedCheckCount == 0 ? "\n✅ all playback engine checks passed" : "\n❌ \(failedCheckCount) playback engine check(s) failed")
    exit(failedCheckCount == 0 ? 0 : 1)
}
dispatchMain()
