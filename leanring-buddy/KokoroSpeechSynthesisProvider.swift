//
//  KokoroSpeechSynthesisProvider.swift
//  leanring-buddy
//
//  Vesper's on-device neural voice: Kokoro 82M ("af_heart", warm, female,
//  American), run through FluidAudio on the Apple Neural Engine. Free,
//  unlimited, and offline — no network delay at all.
//
//  Measured on the user's M2 / 8 GB (2026-09-23): ~190ms per sentence once
//  loaded (330ms worst), ~17x faster than real time; about 540 MB resident
//  while loaded. The first sentence after loading takes ~2.2s, so the model
//  is warmed up with a throwaway sentence right after it loads.
//
//  First launch downloads the model (~174 MB) into ~/.cache/fluidaudio and
//  prepares it for the Neural Engine; until that's done this provider
//  reports itself unavailable and another voice speaks.
//
//  macOS 26.5 has an Apple bug (fixed in 26.6) that can make Kokoro hang or
//  crash inside Apple's BNNS library. A hang is caught here with a
//  per-sentence time limit: the stuck model is abandoned and a fresh one
//  loaded. A crash can only be fixed by updating macOS.
//

@preconcurrency import AVFoundation
import FluidAudio
import Foundation

final class KokoroSpeechSynthesisProvider: VesperSpeechSynthesisProvider {
    /// Normal sentences take ~0.2–0.35s; anything past this is the macOS
    /// 26.5 hang, not slowness.
    private static let sentenceTimeLimitSeconds: TimeInterval = 3
    /// Slightly quicker than Kokoro's default pace — Vesper is sharp.
    private static let speakingSpeed: Float = 1.05

    let displayName = "Kokoro"

    private enum ModelLoadState {
        case notLoaded
        case loading
        case ready
        case failed(reason: String)
    }

    private var kokoroManager = KokoroAneManager()
    private var modelLoadState: ModelLoadState = .notLoaded

    /// Kokoro holds ~460 MB while loaded, on an 8 GB Mac. After this long
    /// without a sentence or a hotkey press it's unloaded; the next press
    /// reloads it (1.3–2.1 s measured), which finishes before Claude's first
    /// sentence arrives. Measured with cleanup() + release: the footprint
    /// fell from ~490–590 MB to 35–104 MB within 10 s.
    private static let idleUnloadAfterSeconds: TimeInterval = 10 * 60
    private var idleUnloadTask: Task<Void, Never>?
    /// Sentences being synthesized right now; the model isn't unloaded
    /// under them.
    private var sentencesBeingSynthesizedCount = 0
    /// Whether the model has loaded at least once this run. Only then is a
    /// reload worth waiting for (the very first load may be a ~174 MB
    /// download that takes minutes).
    private var hasLoadedSuccessfullyBefore = false

    var isAvailable: Bool {
        if case .ready = modelLoadState { return true }
        return false
    }

    var statusDescription: String? {
        switch modelLoadState {
        case .notLoaded:
            return hasLoadedSuccessfullyBefore
                ? "resting after 10 idle minutes (reloads when you talk)"
                : "not loaded"
        case .loading:
            return "loading (first time: downloading ~174 MB)"
        case .ready:
            return "ready, on-device"
        case .failed(let reason):
            return "unavailable: \(reason)"
        }
    }

    /// Loads the model (downloading it the first time) and warms it up.
    /// Safe to call repeatedly; does nothing once loading has started.
    func prewarmVoice() {
        // Switched off for this run after repeated hangs (see below).
        guard hungModelCount < Self.maximumReloadsAfterHangs else { return }
        switch modelLoadState {
        case .ready:
            // Being about to talk counts as use: push the unload back.
            scheduleIdleUnload()
            return
        case .loading:
            return
        case .notLoaded, .failed:
            break
        }
        modelLoadState = .loading
        let managerBeingLoaded = kokoroManager

        Task { [weak self] in
            do {
                try await managerBeingLoaded.initialize()
                // The first synthesis after loading is ~10x slower than the
                // rest; pay that cost now rather than on her first sentence.
                _ = try await managerBeingLoaded.synthesizeDetailed(text: "hi.", speed: Self.speakingSpeed)
                guard let self, self.kokoroManager === managerBeingLoaded else { return }
                self.modelLoadState = .ready
                self.hasLoadedSuccessfullyBefore = true
                self.scheduleIdleUnload()
                print("🔊 Kokoro: ready")
            } catch {
                guard let self, self.kokoroManager === managerBeingLoaded else { return }
                self.modelLoadState = .failed(reason: error.localizedDescription)
                print("⚠️ Kokoro: couldn't load: \(error.localizedDescription)")
            }
        }
    }

    /// Hangs so far this run, and the most reloads allowed after them.
    private var hungModelCount = 0
    private static let maximumReloadsAfterHangs = 2

    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer] {
        guard isAvailable else {
            throw VesperSpeechSynthesisError(message: "Kokoro isn't loaded yet.")
        }

        let managerForThisSentence = kokoroManager
        sentencesBeingSynthesizedCount += 1
        defer {
            sentencesBeingSynthesizedCount -= 1
            scheduleIdleUnload()
        }
        do {
            let audioSamples = try await Self.synthesizeWithTimeLimit(
                sentenceText: sentenceText,
                kokoroManager: managerForThisSentence
            )
            return [try Self.makePCMBuffer(fromSamples: audioSamples)]
        } catch is KokoroSentenceTimedOut {
            // The model is stuck (the macOS 26.5 BNNS bug). Every later call
            // would queue behind it, so abandon it and load a fresh one.
            if kokoroManager === managerForThisSentence {
                hungModelCount += 1
                // A hung model can't be freed (its synthesis never returns),
                // so each reload holds another ~510 MB. After two, stop
                // reloading: on 8 GB that's the difference between a missing
                // voice and a Mac that's swapping.
                if hungModelCount >= Self.maximumReloadsAfterHangs {
                    print("⚠️ Kokoro: hung \(hungModelCount) times — off until Vesper restarts; the other voices take over")
                    modelLoadState = .failed(reason: "stuck twice; restart Vesper to try again")
                } else {
                    print("⚠️ Kokoro: sentence took over \(Int(Self.sentenceTimeLimitSeconds))s — reloading the model")
                    kokoroManager = KokoroAneManager()
                    modelLoadState = .notLoaded
                    prewarmVoice()
                }
            }
            throw VesperSpeechSynthesisError(message: "Kokoro timed out.")
        }
    }

    func waitUntilAvailableIfReloading(maximumSeconds: TimeInterval) async -> Bool {
        guard !isAvailable else { return true }
        // Never loaded this run (maybe still downloading) or switched off
        // after hangs: nothing worth waiting for.
        guard hasLoadedSuccessfullyBefore, hungModelCount < Self.maximumReloadsAfterHangs else { return false }
        if case .failed = modelLoadState { return false }
        prewarmVoice()
        let waitStartedAt = Date()
        while Date().timeIntervalSince(waitStartedAt) < maximumSeconds {
            if isAvailable { return true }
            if case .failed = modelLoadState { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isAvailable
    }

    // MARK: - Idle Unload

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadAfterSeconds))
            guard !Task.isCancelled else { return }
            self?.unloadIfIdle()
        }
    }

    /// Frees the model. cleanup() drops its loaded Core ML models and voice
    /// packs; releasing the manager alone left ~200–490 MB behind in the
    /// measurement. A fresh manager is ready for the next load. Unloading
    /// isn't a hang, so it never counts toward the reload limit.
    private func unloadIfIdle() {
        guard case .ready = modelLoadState, sentencesBeingSynthesizedCount == 0 else { return }
        let managerBeingUnloaded = kokoroManager
        kokoroManager = KokoroAneManager()
        modelLoadState = .notLoaded
        print("🔊 Kokoro: unloaded after \(Int(Self.idleUnloadAfterSeconds / 60)) idle minutes (frees ~460 MB); reloads on the next press")
        Task {
            await managerBeingUnloaded.cleanup()
        }
    }

    /// Runs one synthesis but gives up waiting after the time limit. A task
    /// group can't be used here: it waits for every child to finish, and a
    /// hung synthesis never does. So the result is raced through a
    /// continuation that whichever side finishes first resumes.
    private static func synthesizeWithTimeLimit(
        sentenceText: String,
        kokoroManager: KokoroAneManager
    ) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ResumeOnceBox(continuation: continuation)
            Task {
                do {
                    let synthesisResult = try await kokoroManager.synthesizeDetailed(text: sentenceText, speed: speakingSpeed)
                    resumeOnce.resume(with: .success(synthesisResult.samples))
                } catch {
                    resumeOnce.resume(with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(sentenceTimeLimitSeconds))
                resumeOnce.resume(with: .failure(KokoroSentenceTimedOut()))
            }
        }
    }

    /// Kokoro produces 24 kHz mono Float32 — exactly the playback engine's
    /// format, so no conversion is needed.
    private static func makePCMBuffer(fromSamples audioSamples: [Float]) throws -> AVAudioPCMBuffer {
        guard let kokoroAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              !audioSamples.isEmpty,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: kokoroAudioFormat, frameCapacity: AVAudioFrameCount(audioSamples.count)),
              let channelSamples = pcmBuffer.floatChannelData?[0] else {
            throw VesperSpeechSynthesisError(message: "Kokoro produced no audio.")
        }
        audioSamples.withUnsafeBufferPointer { sampleBuffer in
            channelSamples.update(from: sampleBuffer.baseAddress!, count: audioSamples.count)
        }
        pcmBuffer.frameLength = AVAudioFrameCount(audioSamples.count)
        return pcmBuffer
    }
}

private struct KokoroSentenceTimedOut: Error {}

/// Lets two racing tasks share one continuation; only the first resume counts.
nonisolated private final class ResumeOnceBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<[Float], Error>?
    private let resumeLock = NSLock()

    init(continuation: CheckedContinuation<[Float], Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<[Float], Error>) {
        resumeLock.lock()
        let pendingContinuation = continuation
        continuation = nil
        resumeLock.unlock()
        pendingContinuation?.resume(with: result)
    }
}
