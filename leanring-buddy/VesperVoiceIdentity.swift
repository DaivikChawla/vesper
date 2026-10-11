//
//  VesperVoiceIdentity.swift
//  leanring-buddy
//
//  "Only my voice": Vesper answers only the person whose voice she learned.
//
//  How: WeSpeaker — the speaker model in FluidAudio's diarizer, on the
//  Neural Engine — turns a clip of speech into a voiceprint: 256 numbers
//  describing the voice, not the words. (CAM++, also in FluidAudio, was
//  measured first and couldn't separate voices: other voices scored 0.52–0.73
//  against an owner at 0.76. WeSpeaker: owner 0.92, others 0.14–0.49.
//  See scripts/test-voice-id.sh.)
//  Setup averages three clips of the owner into one voiceprint. Each time
//  the hotkey is released, the clip is compared with it (cosine similarity).
//  Only the voiceprint is kept — never any audio — in the Keychain, along
//  with the on/off switch. Changing either needs the Mac's password or
//  Touch ID, so only the owner can.
//
//  Cost: one embedding per question (a fraction of a second on the Neural
//  Engine), nothing while idle.
//

import AVFoundation
import FluidAudio
import Foundation
import LocalAuthentication

/// Keeps a 16 kHz mono copy of the current push-to-talk utterance for the
/// voice check. Fed from the microphone tap on the audio thread, read on
/// the main thread, so it guards itself with a lock.
nonisolated final class VesperUtteranceAudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// 30 seconds is plenty for a question and caps memory at ~2 MB.
    private static let maximumSampleCount = Int(sampleRate) * 30

    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: VesperUtteranceAudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!
    private var audioConverter: AVAudioConverter?
    private var recordedSamples: [Float] = []
    private var startedUtteranceCount = 0

    /// Called when recording starts; forgets the previous utterance.
    func beginNewUtterance(inputFormat: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        recordedSamples.removeAll(keepingCapacity: true)
        startedUtteranceCount += 1
    }

    /// Goes up each time recording starts, so a caller can wait until the
    /// samples really belong to a new utterance.
    var utteranceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedUtteranceCount
    }

    /// Called with every microphone buffer while recording.
    func append(_ microphoneBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard recordedSamples.count < Self.maximumSampleCount else { return }
        // The microphone can change mid-question (AirPods connecting): a new
        // input format needs a new converter.
        if let currentConverter = audioConverter, currentConverter.inputFormat != microphoneBuffer.format {
            audioConverter = AVAudioConverter(from: microphoneBuffer.format, to: outputFormat)
        }
        guard let audioConverter else { return }

        let sampleRateRatio = Self.sampleRate / microphoneBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(microphoneBuffer.frameLength) * sampleRateRatio) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return }

        var hasProvidedInput = false
        var conversionError: NSError?
        audioConverter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            // Hand over this one buffer, then say "no more for now" so the
            // converter keeps its state for the next buffer.
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return microphoneBuffer
        }
        guard conversionError == nil, let convertedSamples = convertedBuffer.floatChannelData?[0] else { return }
        recordedSamples.append(contentsOf: UnsafeBufferPointer(start: convertedSamples, count: Int(convertedBuffer.frameLength)))
    }

    func currentUtteranceSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSamples
    }

    /// Only the last `sampleCount` samples — cheap enough to poll often
    /// (e.g. listening for when an answer ends).
    func mostRecentSamples(_ sampleCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recordedSamples.suffix(sampleCount))
    }
}

/// Runs the WeSpeaker model on its own queue: an embedding takes ~50 ms,
/// which would stall the cursor if it ran on the main thread.
nonisolated final class VesperSpeakerEmbeddingModel: @unchecked Sendable {
    static let embeddingLength = 256

    private let diarizerManager: DiarizerManager
    private let modelQueue = DispatchQueue(label: "com.vesper.voice-id.model")

    private init(diarizerManager: DiarizerManager) {
        self.diarizerManager = diarizerManager
    }

    /// Downloads the models the first time (a few MB), then loads them.
    static func load() async throws -> VesperSpeakerEmbeddingModel {
        let diarizerModels = try await DiarizerModels.downloadIfNeeded()
        let diarizerManager = DiarizerManager()
        diarizerManager.initialize(models: diarizerModels)
        return VesperSpeakerEmbeddingModel(diarizerManager: diarizerManager)
    }

    func embedding(ofSamples speechSamples: [Float]) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            modelQueue.async {
                do {
                    continuation.resume(returning: try self.diarizerManager.extractSpeakerEmbedding(from: speechSamples))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class VesperVoiceIdentity {
    enum VerificationResult: Equatable {
        case matched(similarity: Float)
        case rejected(similarity: Float)
        /// Under ~1 second of speech ("yes", "stop") can't be judged, so it passes.
        case tooShortToJudge
        /// The model couldn't load or run; the question is let through and
        /// the panel says the voice check isn't working.
        case unavailable
    }

    /// Clips at or above this similarity to the owner's voiceprint are the
    /// owner. Measured with WeSpeaker: same voice 0.92, other voices
    /// 0.14–0.49. Every check logs its score so this can be tuned from the
    /// owner's real voice.
    static let matchSimilarityThreshold: Float = 0.65
    /// Less speech than this can't be judged reliably, so it's let through
    /// (except when approving a risky action — see verify).
    static let minimumJudgeableSpeechSeconds: Double = 1.0
    /// When a judgement is required anyway, less than this is rejected outright.
    static let minimumSpeechSecondsForAnyJudgement: Double = 0.2
    /// Setup clips need at least this much speech to make a good voiceprint.
    static let minimumEnrollmentSpeechSeconds: Double = 2.5
    static let enrollmentClipCount = 3
    /// Setup clips should each score at least this against the average of
    /// the others; below it, the voiceprint probably won't recognize the owner.
    static let minimumSetupClipAgreement: Float = 0.75

    private static let voiceprintSecretName = "owner-voiceprint"
    /// One voiceprint per microphone (by its name). The same voice sounds
    /// different through AirPods' call-quality mic than through the Mac's,
    /// enough to fall below the threshold, so each mic gets its own.
    private static let voiceprintsByMicrophoneSecretName = "owner-voiceprints-by-microphone"
    private static let onlyOwnerVoiceSwitchSecretName = "only-owner-voice-enabled"

    private var loadedEmbedder: VesperSpeakerEmbeddingModel?
    private var embedderLoadTask: Task<VesperSpeakerEmbeddingModel?, Never>?
    private(set) var lastModelProblemDescription: String?

    // MARK: - Stored State (Keychain)

    var ownerVoiceprint: [Float]? {
        guard let storedVoiceprintText = VesperKeychain.readSecret(named: Self.voiceprintSecretName),
              let storedVoiceprintData = storedVoiceprintText.data(using: .utf8),
              let storedVoiceprint = try? JSONDecoder().decode([Float].self, from: storedVoiceprintData),
              storedVoiceprint.count == VesperSpeakerEmbeddingModel.embeddingLength else {
            return nil
        }
        return storedVoiceprint
    }

    var ownerVoiceprintsByMicrophone: [String: [Float]] {
        guard let storedText = VesperKeychain.readSecret(named: Self.voiceprintsByMicrophoneSecretName),
              let storedData = storedText.data(using: .utf8),
              let storedVoiceprints = try? JSONDecoder().decode([String: [Float]].self, from: storedData) else {
            return [:]
        }
        return storedVoiceprints.filter { $0.value.count == VesperSpeakerEmbeddingModel.embeddingLength }
    }

    var hasOwnerVoiceprint: Bool { ownerVoiceprint != nil || !ownerVoiceprintsByMicrophone.isEmpty }

    /// Whether this microphone has a voiceprint of its own.
    func hasVoiceprint(forMicrophoneNamed microphoneName: String?) -> Bool {
        guard let microphoneName else { return false }
        return ownerVoiceprintsByMicrophone[microphoneName] != nil
    }

    /// The voiceprints a clip from this microphone is judged against: that
    /// mic's own if it has one, otherwise every saved one (best match wins).
    private func voiceprintsToCompare(forMicrophoneNamed microphoneName: String?) -> [[Float]] {
        let voiceprintsByMicrophone = ownerVoiceprintsByMicrophone
        if let microphoneName, let microphoneVoiceprint = voiceprintsByMicrophone[microphoneName] {
            return [microphoneVoiceprint]
        }
        return Array(voiceprintsByMicrophone.values) + [ownerVoiceprint].compactMap { $0 }
    }

    var isOnlyOwnerVoiceEnabled: Bool {
        VesperKeychain.readSecret(named: Self.onlyOwnerVoiceSwitchSecretName) == "on" && hasOwnerVoiceprint
    }

    /// Callers must have confirmed the owner (see authenticateOwner) first.
    func setOnlyOwnerVoiceEnabled(_ isEnabled: Bool) {
        _ = VesperKeychain.saveSecret(isEnabled ? "on" : "off", named: Self.onlyOwnerVoiceSwitchSecretName)
    }

    /// Averages the setup clips' embeddings into one voiceprint and stores
    /// it for the microphone they were recorded on (other mics keep theirs).
    func saveOwnerVoiceprint(fromEnrollmentEmbeddings enrollmentEmbeddings: [[Float]], microphoneName: String?) {
        guard let averagedVoiceprint = Self.averagedUnitVector(of: enrollmentEmbeddings) else { return }
        guard let microphoneName else {
            guard let voiceprintData = try? JSONEncoder().encode(averagedVoiceprint),
                  let voiceprintText = String(data: voiceprintData, encoding: .utf8) else { return }
            _ = VesperKeychain.saveSecret(voiceprintText, named: Self.voiceprintSecretName)
            return
        }
        var voiceprintsByMicrophone = ownerVoiceprintsByMicrophone
        voiceprintsByMicrophone[microphoneName] = averagedVoiceprint
        guard let voiceprintsData = try? JSONEncoder().encode(voiceprintsByMicrophone),
              let voiceprintsText = String(data: voiceprintsData, encoding: .utf8) else { return }
        _ = VesperKeychain.saveSecret(voiceprintsText, named: Self.voiceprintsByMicrophoneSecretName)
    }

    // MARK: - The Model

    /// Loads the speaker model ahead of time (first run downloads a few MB), so the
    /// first real check isn't slow.
    func prepareModelIfNeeded() {
        guard loadedEmbedder == nil, embedderLoadTask == nil else { return }
        embedderLoadTask = Task {
            do {
                let embedder = try await VesperSpeakerEmbeddingModel.load()
                print("🔐 Voice ID: model ready")
                return embedder
            } catch {
                print("⚠️ Voice ID: model failed to load: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func embedder() async -> VesperSpeakerEmbeddingModel? {
        if let loadedEmbedder {
            return loadedEmbedder
        }
        prepareModelIfNeeded()
        let loadedOrFailedEmbedder = await embedderLoadTask?.value
        loadedEmbedder = loadedOrFailedEmbedder
        if loadedOrFailedEmbedder == nil {
            embedderLoadTask = nil
            lastModelProblemDescription = "voice check unavailable — model didn't load"
        } else {
            lastModelProblemDescription = nil
        }
        return loadedOrFailedEmbedder
    }

    /// The voiceprint of one clip (silence around the speech trimmed off),
    /// or nil if the model isn't usable.
    func voiceprint(ofSamples speechSamples: [Float]) async -> [Float]? {
        guard let embedder = await embedder() else { return nil }
        do {
            return try await embedder.embedding(ofSamples: Self.trimmedToSpeech(speechSamples))
        } catch {
            print("⚠️ Voice ID: embedding failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Checking a Question

    /// `mustJudgeEvenIfShort` is for answers that approve something risky
    /// (a send / delete / pay confirmation): a short "yes" isn't waved
    /// through there — it's compared like any clip, and nearly silent clips
    /// are rejected. A short clip can wrongly fail for the owner; they then
    /// answer with a few more words.
    func verify(speechSamples: [Float], microphoneName: String? = nil, mustJudgeEvenIfShort: Bool = false) async -> VerificationResult {
        let comparedVoiceprints = voiceprintsToCompare(forMicrophoneNamed: microphoneName)
        guard !comparedVoiceprints.isEmpty else { return .unavailable }
        let speechSeconds = Self.voicedSeconds(in: speechSamples)
        if speechSeconds < Self.minimumJudgeableSpeechSeconds {
            guard mustJudgeEvenIfShort else { return .tooShortToJudge }
            if speechSeconds < Self.minimumSpeechSecondsForAnyJudgement {
                return .rejected(similarity: 0)
            }
        }
        guard let clipVoiceprint = await voiceprint(ofSamples: speechSamples) else { return .unavailable }
        let similarity = comparedVoiceprints
            .map { comparedVoiceprint in Self.cosineSimilarity(clipVoiceprint, comparedVoiceprint) }
            .max() ?? 0
        return similarity >= Self.matchSimilarityThreshold
            ? .matched(similarity: similarity)
            : .rejected(similarity: similarity)
    }

    // MARK: - Owner Confirmation

    /// Asks for the Mac's password or Touch ID — the same prompt macOS uses
    /// elsewhere. True only if the owner confirmed.
    static func authenticateOwner(reason: String) async -> Bool {
        let authenticationContext = LAContext()
        var policyError: NSError?
        guard authenticationContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            print("⚠️ Voice ID: owner authentication unavailable: \(policyError?.localizedDescription ?? "unknown")")
            return false
        }
        do {
            return try await authenticationContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: - Math

    static func cosineSimilarity(_ firstVector: [Float], _ secondVector: [Float]) -> Float {
        guard firstVector.count == secondVector.count, !firstVector.isEmpty else { return 0 }
        var dotProduct: Float = 0
        var firstLengthSquared: Float = 0
        var secondLengthSquared: Float = 0
        for index in firstVector.indices {
            dotProduct += firstVector[index] * secondVector[index]
            firstLengthSquared += firstVector[index] * firstVector[index]
            secondLengthSquared += secondVector[index] * secondVector[index]
        }
        let lengthProduct = sqrt(firstLengthSquared) * sqrt(secondLengthSquared)
        return lengthProduct > 0 ? dotProduct / lengthProduct : 0
    }

    /// For each vector: its similarity to the average of all the others.
    static func leaveOneOutSimilarities(of vectors: [[Float]]) -> [Float] {
        guard vectors.count >= 2 else { return [] }
        return vectors.indices.map { heldOutIndex in
            let otherVectors = vectors.enumerated().filter { $0.offset != heldOutIndex }.map(\.element)
            guard let othersAverage = averagedUnitVector(of: otherVectors) else { return 0 }
            return cosineSimilarity(vectors[heldOutIndex], othersAverage)
        }
    }

    static func averagedUnitVector(of vectors: [[Float]]) -> [Float]? {
        guard let vectorLength = vectors.first?.count, vectorLength > 0,
              vectors.allSatisfy({ $0.count == vectorLength }) else { return nil }
        var sumVector = [Float](repeating: 0, count: vectorLength)
        for vector in vectors {
            for index in 0..<vectorLength {
                sumVector[index] += vector[index]
            }
        }
        let sumLength = sqrt(sumVector.reduce(0) { $0 + $1 * $1 })
        guard sumLength > 0 else { return nil }
        return sumVector.map { $0 / sumLength }
    }

    /// The clip from its first to its last speech window (plus a little
    /// margin). Pauses before and after speaking are room noise, which
    /// would otherwise be mixed into the voiceprint and blur it.
    static func trimmedToSpeech(_ speechSamples: [Float]) -> [Float] {
        let windowSampleCount = Int(VesperUtteranceAudioRecorder.sampleRate * 0.02)
        guard speechSamples.count >= windowSampleCount else { return speechSamples }
        var firstSpeechWindowStart: Int?
        var lastSpeechWindowEnd = 0
        var windowStart = 0
        while windowStart + windowSampleCount <= speechSamples.count {
            if rootMeanSquare(of: speechSamples[windowStart..<(windowStart + windowSampleCount)]) > speechLoudnessThreshold {
                if firstSpeechWindowStart == nil {
                    firstSpeechWindowStart = windowStart
                }
                lastSpeechWindowEnd = windowStart + windowSampleCount
            }
            windowStart += windowSampleCount
        }
        guard let firstSpeechWindowStart else { return speechSamples }
        let marginSampleCount = windowSampleCount * 5
        let trimmedStart = max(0, firstSpeechWindowStart - marginSampleCount)
        let trimmedEnd = min(speechSamples.count, lastSpeechWindowEnd + marginSampleCount)
        return Array(speechSamples[trimmedStart..<trimmedEnd])
    }

    private static let speechLoudnessThreshold: Float = 0.01

    private static func rootMeanSquare(of sampleWindow: ArraySlice<Float>) -> Float {
        var squareSum: Float = 0
        for sample in sampleWindow {
            squareSum += sample * sample
        }
        return sqrt(squareSum / Float(max(sampleWindow.count, 1)))
    }

    /// Loudness (RMS) of a whole clip — used to measure a room's background
    /// noise before listening for an answer.
    static func loudness(of samples: [Float]) -> Float {
        rootMeanSquare(of: samples[...])
    }

    /// Seconds of the clip that contain sound above background level, in
    /// 20 ms windows — so holding the key in silence doesn't count as speech.
    /// `speechLoudnessThreshold` can be raised for a noisy room.
    static func voicedSeconds(in speechSamples: [Float], speechLoudnessThreshold customThreshold: Float) -> Double {
        let windowSampleCount = Int(VesperUtteranceAudioRecorder.sampleRate * 0.02)
        guard speechSamples.count >= windowSampleCount else { return 0 }
        var voicedWindowCount = 0
        var windowStart = 0
        while windowStart + windowSampleCount <= speechSamples.count {
            if rootMeanSquare(of: speechSamples[windowStart..<(windowStart + windowSampleCount)]) > customThreshold {
                voicedWindowCount += 1
            }
            windowStart += windowSampleCount
        }
        return Double(voicedWindowCount) * 0.02
    }

    /// Same loudness test as trimmedToSpeech, so the two never disagree.
    static func voicedSeconds(in speechSamples: [Float]) -> Double {
        voicedSeconds(in: speechSamples, speechLoudnessThreshold: speechLoudnessThreshold)
    }
}
