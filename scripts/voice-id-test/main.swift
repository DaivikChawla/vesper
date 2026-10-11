//
//  main.swift — test driver for "only my voice"
//
//  Uses different macOS voices as stand-ins for different people: learns
//  one voice from three clips (like setup), then checks new clips of that
//  voice and of other voices. Also measures model load and per-check time,
//  and checks the microphone recorder's resampling and the speech timer.
//  Synthetic voices are only a sanity check — real tuning comes from the
//  scores Vesper logs on the owner's own voice.
//  Built and run by scripts/test-voice-id.sh.
//

import AVFoundation
import Foundation

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

let clipsDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

/// Reads a 16 kHz mono float clip made by `say`.
func loadClip(named clipName: String) -> [Float] {
    let clipFile = try! AVAudioFile(forReading: clipsDirectory.appendingPathComponent(clipName + ".wav"))
    let clipBuffer = AVAudioPCMBuffer(pcmFormat: clipFile.processingFormat, frameCapacity: AVAudioFrameCount(clipFile.length))!
    try! clipFile.read(into: clipBuffer)
    return Array(UnsafeBufferPointer(start: clipBuffer.floatChannelData![0], count: Int(clipBuffer.frameLength)))
}

let voiceIdentity = VesperVoiceIdentity()

print("— model")
let modelLoadStartedAt = Date()
let firstVoiceprint = await voiceIdentity.voiceprint(ofSamples: loadClip(named: "owner-1"))
let modelLoadSeconds = Date().timeIntervalSince(modelLoadStartedAt)
check(firstVoiceprint?.count == 256, "model loads and makes a 256-number voiceprint", String(format: "first check incl. load %.2fs", modelLoadSeconds))

var checkDurations: [Double] = []
func timedVoiceprint(_ clipName: String) async -> [Float] {
    await timedVoiceprint(rawSamples: loadClip(named: clipName))
}
func timedVoiceprint(rawSamples clipSamples: [Float]) async -> [Float] {
    let checkStartedAt = Date()
    let clipVoiceprint = await voiceIdentity.voiceprint(ofSamples: clipSamples)!
    checkDurations.append(Date().timeIntervalSince(checkStartedAt))
    return clipVoiceprint
}

print("— setup (three clips of the owner)")
let ownerVoiceprint = VesperVoiceIdentity.averagedUnitVector(of: [
    firstVoiceprint!,
    await timedVoiceprint("owner-2"),
    await timedVoiceprint("owner-3")
])!

let setupClipAgreement = VesperVoiceIdentity.leaveOneOutSimilarities(of: [
    firstVoiceprint!,
    await timedVoiceprint("owner-2"),
    await timedVoiceprint("owner-3")
])
check(
    (setupClipAgreement.min() ?? 0) >= VesperVoiceIdentity.minimumSetupClipAgreement,
    "three clips of one voice agree, so setup doesn't warn",
    setupClipAgreement.map { String(format: "%.2f", $0) }.joined(separator: ", ")
)
let mixedSetupAgreement = VesperVoiceIdentity.leaveOneOutSimilarities(of: [
    firstVoiceprint!,
    await timedVoiceprint("owner-2"),
    await timedVoiceprint("other-daniel")
])
check(
    (mixedSetupAgreement.min() ?? 1) < VesperVoiceIdentity.minimumSetupClipAgreement,
    "a setup clip from someone else is caught, so setup warns",
    mixedSetupAgreement.map { String(format: "%.2f", $0) }.joined(separator: ", ")
)

print("— checks")
let threshold = VesperVoiceIdentity.matchSimilarityThreshold
for ownerClipName in ["owner-4", "owner-5"] {
    let similarity = VesperVoiceIdentity.cosineSimilarity(await timedVoiceprint(ownerClipName), ownerVoiceprint)
    check(similarity >= threshold, "the owner's new sentence is accepted", String(format: "%@ similarity %.2f", ownerClipName, similarity))
}
for otherClipName in ["other-daniel", "other-karen", "other-moira", "other-rishi", "other-fred", "other-tessa"] {
    let similarity = VesperVoiceIdentity.cosineSimilarity(await timedVoiceprint(otherClipName), ownerVoiceprint)
    check(similarity < threshold, "another voice is rejected", String(format: "%@ similarity %.2f", otherClipName, similarity))
}
let averageCheckMilliseconds = checkDurations.reduce(0, +) / Double(checkDurations.count) * 1000
check(averageCheckMilliseconds < 250, "a check is fast once loaded", String(format: "average %.0f ms per clip", averageCheckMilliseconds))

print("— real-world clip shapes")
let owner4Samples = loadClip(named: "owner-4")
let owner5Samples = loadClip(named: "owner-5")
// Someone waits a beat before and after speaking, with a little room noise.
var roomNoiseGenerator = SystemRandomNumberGenerator()
let roomNoise = (0..<24_000).map { _ in Float.random(in: -0.004...0.004, using: &roomNoiseGenerator) }
let paddedOwnerClip = roomNoise + owner4Samples + roomNoise
let paddedSimilarity = VesperVoiceIdentity.cosineSimilarity(await timedVoiceprint(rawSamples: paddedOwnerClip), ownerVoiceprint)
check(paddedSimilarity >= threshold, "owner with 1.5s pauses before and after is accepted", String(format: "similarity %.2f", paddedSimilarity))
check(VesperVoiceIdentity.trimmedToSpeech(paddedOwnerClip).count < paddedOwnerClip.count - 40_000, "the pauses are trimmed off before checking")
// A long question, and the recorder's 30-second maximum.
let longOwnerClip = Array(repeating: owner4Samples + owner5Samples, count: 2).flatMap { $0 }
let longSimilarity = VesperVoiceIdentity.cosineSimilarity(await timedVoiceprint(rawSamples: longOwnerClip), ownerVoiceprint)
check(longSimilarity >= threshold, "a long question is checked, not skipped", String(format: "%.0fs, similarity %.2f", Double(longOwnerClip.count) / 16_000, longSimilarity))
let maximumOwnerClip = Array(Array(repeating: owner4Samples + owner5Samples, count: 6).flatMap { $0 }.prefix(16_000 * 30))
let maximumLengthVoiceprint = await voiceIdentity.voiceprint(ofSamples: maximumOwnerClip)
check(maximumLengthVoiceprint != nil, "a 30-second question (the recorder's maximum) doesn't fail")
if let maximumLengthVoiceprint {
    let maximumSimilarity = VesperVoiceIdentity.cosineSimilarity(maximumLengthVoiceprint, ownerVoiceprint)
    check(maximumSimilarity >= threshold, "and is still recognized", String(format: "similarity %.2f", maximumSimilarity))
}
let longOtherClip = Array(repeating: loadClip(named: "other-karen") + loadClip(named: "other-karen"), count: 3).flatMap { $0 }
let longOtherSimilarity = VesperVoiceIdentity.cosineSimilarity(await timedVoiceprint(rawSamples: longOtherClip), ownerVoiceprint)
check(longOtherSimilarity < threshold, "a long question from someone else is still rejected", String(format: "similarity %.2f", longOtherSimilarity))

print("— speech timer")
check(VesperVoiceIdentity.voicedSeconds(in: [Float](repeating: 0, count: 32_000)) == 0, "silence counts as no speech")
let ownerSentenceSeconds = VesperVoiceIdentity.voicedSeconds(in: loadClip(named: "owner-4"))
check(ownerSentenceSeconds > 1.0, "a spoken sentence counts as speech", String(format: "%.1fs", ownerSentenceSeconds))
let shortReplySeconds = VesperVoiceIdentity.voicedSeconds(in: loadClip(named: "short-yes"))
check(shortReplySeconds < VesperVoiceIdentity.minimumJudgeableSpeechSeconds, "a one-word \"yes\" is too short to judge, so it passes", String(format: "%.1fs", shortReplySeconds))

print("— microphone recorder")
let microphoneFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
let utteranceRecorder = VesperUtteranceAudioRecorder()
utteranceRecorder.beginNewUtterance(inputFormat: microphoneFormat)
for _ in 0..<(48_000 / 1024) {
    let microphoneBuffer = AVAudioPCMBuffer(pcmFormat: microphoneFormat, frameCapacity: 1024)!
    microphoneBuffer.frameLength = 1024
    utteranceRecorder.append(microphoneBuffer)
}
let resampledCount = utteranceRecorder.currentUtteranceSamples().count
check(abs(resampledCount - 16_000) < 800, "one second of 48 kHz audio becomes ~16,000 samples", "\(resampledCount)")
utteranceRecorder.beginNewUtterance(inputFormat: microphoneFormat)
check(utteranceRecorder.currentUtteranceSamples().isEmpty, "a new utterance starts empty")

print(failedCheckCount == 0 ? "\n✅ all voice ID checks passed" : "\n❌ \(failedCheckCount) voice ID check(s) failed")
exit(failedCheckCount == 0 ? 0 : 1)
