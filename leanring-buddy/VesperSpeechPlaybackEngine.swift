//
//  VesperSpeechPlaybackEngine.swift
//  leanring-buddy
//
//  Speaks Vesper's replies one segment (roughly one sentence) at a time.
//  Segments can be added while the reply is still streaming in from Claude,
//  so she starts talking before the full answer exists. Segment N+1 is
//  synthesized while segment N plays, so there are no gaps between them.
//
//  This engine is the single owner of speech audio. That gives one place for:
//  - interruption (barge-in stops everything instantly),
//  - output audio level (drives the cursor's glow while she talks),
//  - knowing exactly when each segment starts playing, so the cursor can fly
//    to the element a sentence is about at the moment she says it.
//

// AVFAudio predates Swift concurrency: its buffer types aren't annotated as
// Sendable even though handing a finished buffer to another thread is safe.
@preconcurrency import AVFoundation
import Combine
import Foundation

/// One piece of a reply to speak — usually a sentence.
struct VesperSpeechSegment {
    let spokenText: String
    /// Called on the main actor at the moment this segment starts playing.
    let onStartedPlaying: () -> Void
}

@MainActor
final class VesperSpeechPlaybackEngine: ObservableObject {
    @Published private(set) var isSpeaking = false
    /// 0...1, smoothed. Drives the cursor glow while she's talking.
    @Published private(set) var currentOutputAudioLevel: CGFloat = 0

    /// Every provider's audio is converted to this one format before it is
    /// scheduled, so the player node never needs reconnecting between
    /// segments from different providers.
    private static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    /// Keep the audio hardware awake briefly after speaking in case the next
    /// reply follows right away, then release it.
    private static let idleEngineStopDelaySeconds: TimeInterval = 3

    /// Picks which voice speaks each sentence (Auto / Google / Kokoro modes,
    /// the Auto race, and fallbacks so she never goes silent).
    let voiceRouter: VesperVoiceRouter

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isAudioGraphConfigured = false
    private var engineConfigurationChangeObserver: NSObjectProtocol?
    private var idleEngineStopTask: Task<Void, Never>?

    /// Bumped on every new utterance or stop, so audio callbacks that belong
    /// to an interrupted utterance can recognize themselves and do nothing.
    private var utteranceGeneration = 0
    private var segmentsWaitingForSynthesis: [VesperSpeechSegment] = []
    private var isSynthesisLoopRunning = false
    private var hasReceivedFinalSegment = false
    /// Segments whose audio is scheduled on the player, in playback order.
    /// The first entry is the one currently playing.
    private var scheduledSegmentsInPlaybackOrder: [ScheduledSpeechSegment] = []
    private var onUtteranceFinished: (() -> Void)?
    /// The sentence the synthesis loop is producing audio for right now —
    /// kept so an audio-output change can queue it again instead of losing it.
    private var segmentCurrentlyBeingSynthesized: VesperSpeechSegment?

    init(voiceRouter: VesperVoiceRouter) {
        self.voiceRouter = voiceRouter
    }

    // MARK: - Public API

    /// Loads the voice and starts the audio hardware ahead of time, so the
    /// first sentence of the next reply plays without a cold-start delay.
    /// Cheap when already warm; called at launch and when the voice settings
    /// change. A hotkey press only prewarms the voices (see CompanionManager).
    func prewarm() {
        voiceRouter.prewarmVoices()
        do {
            try startAudioEngineIfNeeded()
            if !isSpeaking {
                scheduleIdleEngineStop()
            }
        } catch {
            print("⚠️ Speech: couldn't prewarm audio output: \(error.localizedDescription)")
        }
    }

    /// Starts a fresh reply, silencing anything still playing.
    /// `onFinished` runs once every segment has played. It does NOT run if the
    /// utterance is interrupted by `stopImmediately()` or a newer utterance.
    func beginNewUtterance(onFinished: @escaping () -> Void) {
        stopImmediately()
        voiceRouter.beginNewReply()
        isSpeaking = true
        onUtteranceFinished = onFinished
    }

    /// Adds the next segment of the current reply. Ignored when no reply is
    /// in progress — anything arriving then belongs to an interrupted one.
    func enqueueSegment(_ speechSegment: VesperSpeechSegment) {
        guard isSpeaking else { return }
        let trimmedSpokenText = speechSegment.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpokenText.isEmpty else {
            // Nothing to say, but a point attached to it should still happen.
            speechSegment.onStartedPlaying()
            return
        }
        segmentsWaitingForSynthesis.append(speechSegment)
        runSynthesisLoopIfNeeded()
    }

    /// Signals that the reply is complete — no more segments are coming.
    func finishUtterance() {
        hasReceivedFinalSegment = true
        finishUtteranceIfEverythingHasPlayed()
    }

    /// Stops all speech right away (barge-in). Does not call `onFinished`.
    func stopImmediately() {
        utteranceGeneration += 1
        segmentCurrentlyBeingSynthesized = nil
        segmentsWaitingForSynthesis.removeAll()
        scheduledSegmentsInPlaybackOrder.removeAll()
        hasReceivedFinalSegment = false
        onUtteranceFinished = nil
        // A player node that was never attached to the engine can't be stopped.
        if isAudioGraphConfigured {
            let playerNode = self.playerNode
            try? VesperObjectiveCExceptions.run("Stopping the speech player") {
                playerNode.stop()
            }
        }
        isSpeaking = false
        currentOutputAudioLevel = 0
    }

    // MARK: - Synthesis

    private func runSynthesisLoopIfNeeded() {
        guard !isSynthesisLoopRunning else { return }
        isSynthesisLoopRunning = true
        let generationAtStart = utteranceGeneration

        Task { [weak self] in
            guard let self else { return }

            while generationAtStart == self.utteranceGeneration, !self.segmentsWaitingForSynthesis.isEmpty {
                let nextSegment = self.segmentsWaitingForSynthesis.removeFirst()
                self.segmentCurrentlyBeingSynthesized = nextSegment
                let playableBuffer = await self.synthesizePlayableBuffer(for: nextSegment.spokenText)
                if generationAtStart == self.utteranceGeneration {
                    self.segmentCurrentlyBeingSynthesized = nil
                }

                // A barge-in may have happened while we were synthesizing;
                // if so this segment belongs to the interrupted reply.
                guard generationAtStart == self.utteranceGeneration else { break }

                if let playableBuffer {
                    self.schedule(playableBuffer, for: nextSegment, generation: generationAtStart)
                } else {
                    // Couldn't produce audio at all — still honor the segment's
                    // point so the cursor behavior stays correct.
                    nextSegment.onStartedPlaying()
                }
            }

            // Single exit point, so the running flag is only ever cleared
            // here. Segments still waiting now belong to a newer utterance
            // that couldn't start its own loop while this one was busy.
            self.isSynthesisLoopRunning = false
            if !self.segmentsWaitingForSynthesis.isEmpty {
                self.runSynthesisLoopIfNeeded()
            } else {
                self.finishUtteranceIfEverythingHasPlayed()
            }
        }
    }

    private func synthesizePlayableBuffer(for spokenText: String) async -> AVAudioPCMBuffer? {
        guard let synthesizedBuffers = await voiceRouter.synthesizeSentence(spokenText) else {
            print("⚠️ Speech: no voice could speak this sentence")
            return nil
        }
        return Self.convertToPlaybackFormat(synthesizedBuffers)
    }

    // MARK: - Playback

    private func schedule(_ playableBuffer: AVAudioPCMBuffer, for speechSegment: VesperSpeechSegment, generation: Int) {
        do {
            try startAudioEngineIfNeeded()
        } catch {
            print("⚠️ Speech: couldn't start audio output: \(error.localizedDescription)")
            speechSegment.onStartedPlaying()
            return
        }

        let scheduledSegment = ScheduledSpeechSegment(
            speechSegment: speechSegment,
            playbackDurationSeconds: Double(playableBuffer.frameLength) / playableBuffer.format.sampleRate
        )

        // .dataPlayedBack fires when the audio has actually left the speakers,
        // not merely when the player has consumed the buffer.
        let segmentFinishedCallback: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleSegmentFinishedPlaying(generation: generation, finishedSegment: scheduledSegment)
                }
            }
        }
        // A buffer the player refuses (it raises) is skipped like a sentence
        // no voice could speak: its point still happens, nothing is queued.
        let playerNode = self.playerNode
        do {
            try VesperObjectiveCExceptions.run("Scheduling a sentence") {
                playerNode.scheduleBuffer(
                    playableBuffer,
                    completionCallbackType: .dataPlayedBack,
                    completionHandler: segmentFinishedCallback
                )
            }
        } catch {
            print("⚠️ Speech: couldn't queue a sentence, skipping it: \(error.localizedDescription)")
            speechSegment.onStartedPlaying()
            return
        }
        // Only once the player has accepted the buffer: a segment in this
        // list that the player never got would hold the reply open until
        // the watchdog gave up on it.
        scheduledSegmentsInPlaybackOrder.append(scheduledSegment)

        if !playerNode.isPlaying {
            do {
                try VesperObjectiveCExceptions.run("Starting the speech player") {
                    playerNode.play()
                }
            } catch {
                print("⚠️ Speech: the player wouldn't start, skipping the sentence: \(error.localizedDescription)")
                scheduledSegmentsInPlaybackOrder.removeAll { $0 === scheduledSegment }
                speechSegment.onStartedPlaying()
                return
            }
        }

        // If nothing was ahead of it, this segment starts right now.
        if scheduledSegmentsInPlaybackOrder.count == 1 {
            markSegmentAsStarted(scheduledSegment)
        }
    }

    /// Only advances if `finishedSegment` is still the one playing: the
    /// watchdog and the player's own callback can both report the same
    /// sentence, and counting it twice would start later sentences early.
    private func handleSegmentFinishedPlaying(generation: Int, finishedSegment: ScheduledSpeechSegment) {
        guard generation == utteranceGeneration,
              scheduledSegmentsInPlaybackOrder.first === finishedSegment else { return }
        scheduledSegmentsInPlaybackOrder.removeFirst()

        if let nextScheduledSegment = scheduledSegmentsInPlaybackOrder.first {
            markSegmentAsStarted(nextScheduledSegment)
        } else {
            finishUtteranceIfEverythingHasPlayed()
        }
    }

    private func markSegmentAsStarted(_ scheduledSegment: ScheduledSpeechSegment) {
        guard !scheduledSegment.hasStartedPlaying else { return }
        scheduledSegment.hasStartedPlaying = true
        scheduledSegment.speechSegment.onStartedPlaying()
        watchForPlaybackThatNeverFinishes(scheduledSegment)
    }

    /// If the output device vanishes mid-sentence, the player may never
    /// report the sentence as played — and she'd stay "speaking" forever,
    /// with the hotkey and the cursor stuck. So a sentence that hasn't
    /// finished well after its length is treated as finished.
    private func watchForPlaybackThatNeverFinishes(_ scheduledSegment: ScheduledSpeechSegment) {
        let generationWhenStarted = utteranceGeneration
        let watchdogSeconds = scheduledSegment.playbackDurationSeconds + 2
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(watchdogSeconds))
            guard let self,
                  self.utteranceGeneration == generationWhenStarted,
                  self.scheduledSegmentsInPlaybackOrder.first === scheduledSegment else { return }
            print("⚠️ Speech: a sentence never finished playing (output gone?) — moving on")
            self.handleSegmentFinishedPlaying(generation: generationWhenStarted, finishedSegment: scheduledSegment)
        }
    }

    private func finishUtteranceIfEverythingHasPlayed() {
        guard isSpeaking,
              hasReceivedFinalSegment,
              segmentsWaitingForSynthesis.isEmpty,
              !isSynthesisLoopRunning,
              scheduledSegmentsInPlaybackOrder.isEmpty else { return }

        isSpeaking = false
        currentOutputAudioLevel = 0
        hasReceivedFinalSegment = false
        let finishedCallback = onUtteranceFinished
        onUtteranceFinished = nil
        finishedCallback?()
        scheduleIdleEngineStop()
    }

    // MARK: - Audio Engine

    /// AVAudioEngine raises Objective-C exceptions for some failures (a
    /// format the output can't take mid-route-change, a node connected
    /// twice). Every call that can raise goes through
    /// `VesperObjectiveCExceptions.run`, so a failure becomes a thrown error
    /// and the sentence is skipped like any other failure instead of the
    /// exception being swallowed and the app crashing later.
    private func startAudioEngineIfNeeded() throws {
        idleEngineStopTask?.cancel()
        idleEngineStopTask = nil

        if !isAudioGraphConfigured {
            try configureAudioGraph()
        }

        if !audioEngine.isRunning {
            let audioEngine = self.audioEngine
            try VesperObjectiveCExceptions.run("Starting the speech output") {
                audioEngine.prepare()
                try audioEngine.start()
            }
        }
    }

    /// Attaches the player and the level tap. Marked configured only once
    /// every step has succeeded; a half-built graph is taken apart again, or
    /// the next attempt would attach the same player twice and raise every
    /// time — leaving her silent for the rest of the run.
    private func configureAudioGraph() throws {
        let audioEngine = self.audioEngine
        let playerNode = self.playerNode
        do {
            try VesperObjectiveCExceptions.run("Attaching the speech player") {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: Self.playbackFormat)
            }
            try installOutputAudioLevelTap()
        } catch {
            try? VesperObjectiveCExceptions.run("Removing a half-built speech player") {
                audioEngine.mainMixerNode.removeTap(onBus: 0)
                if playerNode.engine != nil {
                    audioEngine.detach(playerNode)
                }
            }
            throw error
        }
        if engineConfigurationChangeObserver == nil {
            observeAudioEngineConfigurationChanges()
        }
        isAudioGraphConfigured = true
    }

    private func scheduleIdleEngineStop() {
        idleEngineStopTask?.cancel()
        idleEngineStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleEngineStopDelaySeconds))
            guard !Task.isCancelled, let self, !self.isSpeaking else { return }
            self.audioEngine.stop()
        }
    }

    /// When the output device changes (headphones plugged in, AirPods
    /// connect), AVAudioEngine stops itself. The next segment restarts it.
    /// The audio output changed (common with Bluetooth headphones, which
    /// switch mode when the mic closes at hotkey release). The old player is
    /// gone, so every sentence that hadn't started yet — and its pointing
    /// and quick actions, which run when a sentence starts — is played again
    /// on the new output. Nothing of the reply is dropped or half-run; only
    /// the rest of the sentence that was playing at that instant is lost.
    private func continueReplyOnNewAudioOutput() {
        print("🔊 Speech: audio output changed — continuing the reply on the new output")
        guard isSpeaking else {
            stopImmediately()
            return
        }

        let unplayedSegments = scheduledSegmentsInPlaybackOrder
            .filter { !$0.hasStartedPlaying }
            .map(\.speechSegment)
            + [segmentCurrentlyBeingSynthesized].compactMap { $0 }
            + segmentsWaitingForSynthesis
        let utteranceFinishedCallback = onUtteranceFinished
        let hadReceivedFinalSegment = hasReceivedFinalSegment

        // Drop the old player's queue (bumps the generation, so its late
        // callbacks are ignored), then re-open the same reply — same voice,
        // same finished callback — with the unplayed sentences queued again.
        stopImmediately()
        isSpeaking = true
        onUtteranceFinished = utteranceFinishedCallback
        hasReceivedFinalSegment = hadReceivedFinalSegment
        segmentsWaitingForSynthesis = unplayedSegments
        runSynthesisLoopIfNeeded()
        finishUtteranceIfEverythingHasPlayed()
    }

    private func observeAudioEngineConfigurationChanges() {
        engineConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.continueReplyOnNewAudioOutput()
            }
        }
    }

    private func installOutputAudioLevelTap() throws {
        let mainMixerNode = audioEngine.mainMixerNode
        let outputLevelTapBlock: AVAudioNodeTapBlock = { @Sendable [weak self] tappedBuffer, _ in
            guard let channelSamples = tappedBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(tappedBuffer.frameLength)
            guard frameCount > 0 else { return }

            var summedSquares: Float = 0
            for sampleIndex in 0..<frameCount {
                summedSquares += channelSamples[sampleIndex] * channelSamples[sampleIndex]
            }
            let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
            let normalizedLevel = CGFloat(min(rootMeanSquare * 6.0, 1.0))

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isSpeaking else { return }
                    // Rise instantly, fall gently — reads as a natural pulse.
                    self.currentOutputAudioLevel = max(normalizedLevel, self.currentOutputAudioLevel * 0.8)
                }
            }
        }
        try VesperObjectiveCExceptions.run("Installing the speech level tap") {
            mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: outputLevelTapBlock)
        }
    }

    // MARK: - Format Conversion

    /// Joins a provider's buffers into one and converts it to the playback
    /// format (resampling if needed — the system voice produces 22.05kHz).
    private static func convertToPlaybackFormat(_ sourceBuffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let sourceFormat = sourceBuffers.first?.format else { return nil }
        let totalSourceFrameCount = sourceBuffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalSourceFrameCount > 0,
              let joinedSourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrameCount) else {
            return nil
        }
        for sourceBuffer in sourceBuffers where sourceBuffer.format == sourceFormat {
            appendFrames(of: sourceBuffer, to: joinedSourceBuffer)
        }

        if sourceFormat == playbackFormat {
            return joinedSourceBuffer
        }

        guard let formatConverter = AVAudioConverter(from: sourceFormat, to: playbackFormat) else { return nil }
        let sampleRateRatio = playbackFormat.sampleRate / sourceFormat.sampleRate
        let convertedFrameCapacity = AVAudioFrameCount(Double(totalSourceFrameCount) * sampleRateRatio) + 1_024
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: convertedFrameCapacity) else {
            return nil
        }

        var hasProvidedSourceAudio = false
        var conversionError: NSError?
        formatConverter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedSourceAudio {
                inputStatus.pointee = .endOfStream
                return nil
            }
            hasProvidedSourceAudio = true
            inputStatus.pointee = .haveData
            return joinedSourceBuffer
        }

        if let conversionError {
            print("⚠️ Speech: audio conversion failed: \(conversionError.localizedDescription)")
            return nil
        }
        return convertedBuffer.frameLength > 0 ? convertedBuffer : nil
    }

    private static func appendFrames(of sourceBuffer: AVAudioPCMBuffer, to destinationBuffer: AVAudioPCMBuffer) {
        let bytesPerFrame = Int(sourceBuffer.format.streamDescription.pointee.mBytesPerFrame)
        let destinationByteOffset = Int(destinationBuffer.frameLength) * bytesPerFrame
        let copiedByteCount = Int(sourceBuffer.frameLength) * bytesPerFrame

        let sourceChannelBuffers = UnsafeMutableAudioBufferListPointer(sourceBuffer.mutableAudioBufferList)
        let destinationChannelBuffers = UnsafeMutableAudioBufferListPointer(destinationBuffer.mutableAudioBufferList)
        for (sourceChannelBuffer, destinationChannelBuffer) in zip(sourceChannelBuffers, destinationChannelBuffers) {
            guard let sourceBytes = sourceChannelBuffer.mData,
                  let destinationBytes = destinationChannelBuffer.mData else { continue }
            memcpy(destinationBytes.advanced(by: destinationByteOffset), sourceBytes, copiedByteCount)
        }
        destinationBuffer.frameLength += sourceBuffer.frameLength
    }
}

/// A segment whose audio has been handed to the player.
private final class ScheduledSpeechSegment {
    let speechSegment: VesperSpeechSegment
    /// How long its audio lasts — the playback watchdog's yardstick.
    let playbackDurationSeconds: Double
    var hasStartedPlaying = false

    init(speechSegment: VesperSpeechSegment, playbackDurationSeconds: Double) {
        self.speechSegment = speechSegment
        self.playbackDurationSeconds = playbackDurationSeconds
    }
}
