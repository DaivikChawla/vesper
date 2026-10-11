//
//  SpeechAnalyzerTranscriptionProvider.swift
//  leanring-buddy
//
//  Push-to-talk transcription on macOS 26's SpeechAnalyzer + SpeechTranscriber.
//  Fully on-device: no API key, no network, no quota.
//
//  Why this engine: in published benchmarks it beats Whisper Small on
//  accuracy (≈2% vs ≈3.7% word error rate on clean English) and returns the
//  final transcript ≈130ms after the audio ends. Its model runs outside the
//  app's process, so it doesn't count against the app's memory — which
//  matters on an 8 GB Mac that's also running the claude CLI.
//
//  Audio is streamed in while the user holds the hotkey, so by the time they
//  let go most of the transcript already exists; release only finalizes it.
//
//  If the on-device model isn't installed yet, it downloads in the
//  background and the legacy Apple Speech provider covers the meantime.
//

@preconcurrency import AVFoundation
import Foundation
import Speech

final class SpeechAnalyzerTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple on-device (SpeechAnalyzer)"
    let isConfigured = true
    let unavailableExplanation: String? = nil
    /// SpeechAnalyzer runs on-device, but the legacy fallback provider does
    /// need Speech Recognition permission, so it's requested up front once.
    let requiresSpeechRecognitionPermission = true

    /// Used whenever the on-device model isn't installed yet.
    private let legacyFallbackProvider = AppleSpeechTranscriptionProvider()
    private var isModelInstalled = false
    private var modelInstallationTask: Task<Void, Never>?

    init() {
        installOnDeviceModelInBackgroundIfNeeded()
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isModelInstalled else {
            print("🎙️ SpeechAnalyzer model not installed yet — using legacy Apple Speech for this one")
            installOnDeviceModelInBackgroundIfNeeded()
            return try await legacyFallbackProvider.startStreamingSession(
                keyterms: keyterms,
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
        }

        let transcriptionLocale = await Self.resolveTranscriptionLocale()
        let transcriptionSession = SpeechAnalyzerTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        try await transcriptionSession.start(locale: transcriptionLocale, contextualKeyterms: keyterms)
        return transcriptionSession
    }

    /// Downloads the on-device speech model once. It lives in system storage,
    /// so it adds nothing to the app's size and is shared with other apps.
    private func installOnDeviceModelInBackgroundIfNeeded() {
        guard !isModelInstalled, modelInstallationTask == nil else { return }

        modelInstallationTask = Task { [weak self] in
            defer { self?.modelInstallationTask = nil }
            let transcriptionLocale = await Self.resolveTranscriptionLocale()
            let transcriber = SpeechTranscriber(locale: transcriptionLocale, preset: .progressiveTranscription)
            do {
                if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    print("🎙️ Downloading on-device speech model for \(transcriptionLocale.identifier)…")
                    try await installationRequest.downloadAndInstall()
                }
                self?.isModelInstalled = true
                print("🎙️ On-device speech model ready (\(transcriptionLocale.identifier))")
            } catch {
                print("⚠️ Couldn't install the on-device speech model: \(error.localizedDescription)")
            }
        }
    }

    /// The user's own locale if SpeechTranscriber supports it, else US English.
    private static func resolveTranscriptionLocale() async -> Locale {
        if let supportedCurrentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return supportedCurrentLocale
        }
        return Locale(identifier: "en_US")
    }
}

// MARK: - Session

/// One push-to-talk session. Microphone buffers arrive on the audio thread,
/// results arrive on SpeechAnalyzer's own task, so shared state is locked.
nonisolated private final class SpeechAnalyzerTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    /// The dictation manager waits this long for the final transcript after
    /// release before giving up; SpeechAnalyzer normally finishes in ~130ms.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.0

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var speechAnalyzer: SpeechAnalyzer?
    private var analyzerAudioFormat: AVAudioFormat?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsCollectionTask: Task<Void, Never>?
    private var microphoneAudioConverter: AVAudioConverter?

    private let sessionStateLock = NSLock()
    /// Text the transcriber has committed to — it won't change.
    private var finalizedTranscriptText = ""
    /// The transcriber's current best guess for the words still being spoken.
    private var volatileTranscriptText = ""
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func start(locale transcriptionLocale: Locale, contextualKeyterms: [String]) async throws {
        // The preset used in the published benchmark: volatile results while
        // speaking, tuned for low latency.
        let transcriber = SpeechTranscriber(locale: transcriptionLocale, preset: .progressiveTranscription)

        // "Lingering" keeps the model loaded briefly after a session ends, so
        // back-to-back questions don't pay the model load again.
        let speechAnalyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        self.speechAnalyzer = speechAnalyzer

        // Names and jargon the recognizer would otherwise mishear.
        if !contextualKeyterms.isEmpty {
            let analysisContext = AnalysisContext()
            analysisContext.contextualStrings[.general] = contextualKeyterms
            try await speechAnalyzer.setContext(analysisContext)
        }

        let analyzerAudioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerAudioFormat = analyzerAudioFormat
        try await speechAnalyzer.prepareToAnalyze(in: analyzerAudioFormat)

        let (analyzerInputSequence, analyzerInputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        sessionStateLock.withLock {
            self.analyzerInputContinuation = analyzerInputContinuation
        }

        resultsCollectionTask = Task { [weak self] in
            do {
                for try await transcriptionResult in transcriber.results {
                    self?.handle(transcriptionResult)
                }
                self?.deliverFinalTranscriptIfNeeded()
            } catch {
                self?.handleResultsError(error)
            }
        }

        try await speechAnalyzer.start(inputSequence: analyzerInputSequence)
    }

    /// Runs on the audio thread, while `requestFinalTranscript` and `cancel`
    /// clear the continuation from the main thread — so it's read under the
    /// lock. Yielding happens outside the lock; a yield that lands just after
    /// `finish()` is simply dropped.
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        sessionStateLock.lock()
        let currentAnalyzerInputContinuation = analyzerInputContinuation
        sessionStateLock.unlock()
        guard let currentAnalyzerInputContinuation,
              let convertedBuffer = convertToAnalyzerFormat(audioBuffer) else { return }
        currentAnalyzerInputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
    }

    /// Takes the continuation out under the lock (so the audio thread can't
    /// read it half-cleared) and returns it for the caller to finish.
    private func takeAnalyzerInputContinuation() -> AsyncStream<AnalyzerInput>.Continuation? {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        let takenContinuation = analyzerInputContinuation
        analyzerInputContinuation = nil
        return takenContinuation
    }

    func requestFinalTranscript() {
        takeAnalyzerInputContinuation()?.finish()
        guard let speechAnalyzer else {
            deliverFinalTranscriptIfNeeded()
            return
        }
        Task {
            // Flushes the last words; the results loop then ends and delivers.
            try? await speechAnalyzer.finalizeAndFinishThroughEndOfInput()
        }
    }

    func cancel() {
        sessionStateLock.lock()
        isCancelled = true
        sessionStateLock.unlock()

        takeAnalyzerInputContinuation()?.finish()
        resultsCollectionTask?.cancel()
        if let speechAnalyzer {
            Task { await speechAnalyzer.cancelAndFinishNow() }
        }
    }

    // MARK: Results

    private func handle(_ transcriptionResult: SpeechTranscriber.Result) {
        let resultText = String(transcriptionResult.text.characters)

        sessionStateLock.lock()
        if transcriptionResult.isFinal {
            finalizedTranscriptText += resultText
            volatileTranscriptText = ""
        } else {
            volatileTranscriptText = resultText
        }
        let fullTranscriptSoFar = finalizedTranscriptText + volatileTranscriptText
        let shouldReport = !isCancelled
        sessionStateLock.unlock()

        if shouldReport {
            onTranscriptUpdate(fullTranscriptSoFar.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func deliverFinalTranscriptIfNeeded() {
        sessionStateLock.lock()
        guard !hasDeliveredFinalTranscript, !isCancelled else {
            sessionStateLock.unlock()
            return
        }
        hasDeliveredFinalTranscript = true
        let finalTranscript = (finalizedTranscriptText + volatileTranscriptText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sessionStateLock.unlock()

        onFinalTranscriptReady(finalTranscript)
    }

    private func handleResultsError(_ error: Error) {
        sessionStateLock.lock()
        let wasCancelled = isCancelled
        let hasUsableTranscript = !(finalizedTranscriptText + volatileTranscriptText)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sessionStateLock.unlock()

        guard !wasCancelled else { return }
        if hasUsableTranscript {
            deliverFinalTranscriptIfNeeded()
        } else {
            onError(error)
        }
    }

    // MARK: Audio Conversion

    /// Converts a microphone buffer (typically 48kHz float) to the format the
    /// analyzer asked for. One converter is kept for the whole session because
    /// resampling carries state from one buffer to the next.
    private func convertToAnalyzerFormat(_ microphoneBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let analyzerAudioFormat else { return microphoneBuffer }
        if microphoneBuffer.format == analyzerAudioFormat {
            return microphoneBuffer
        }

        if microphoneAudioConverter == nil || microphoneAudioConverter?.inputFormat != microphoneBuffer.format {
            microphoneAudioConverter = AVAudioConverter(from: microphoneBuffer.format, to: analyzerAudioFormat)
        }
        guard let microphoneAudioConverter else { return nil }

        let sampleRateRatio = analyzerAudioFormat.sampleRate / microphoneBuffer.format.sampleRate
        let convertedFrameCapacity = AVAudioFrameCount((Double(microphoneBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: analyzerAudioFormat, frameCapacity: convertedFrameCapacity) else {
            return nil
        }

        var hasProvidedMicrophoneBuffer = false
        var conversionError: NSError?
        let conversionStatus = microphoneAudioConverter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedMicrophoneBuffer {
                // .noDataNow (not .endOfStream) keeps the converter's
                // resampling state ready for the next microphone buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedMicrophoneBuffer = true
            inputStatus.pointee = .haveData
            return microphoneBuffer
        }

        guard conversionStatus != .error, convertedBuffer.frameLength > 0 else { return nil }
        return convertedBuffer
    }
}
