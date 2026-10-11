//
//  VesperSpeechSynthesisProvider.swift
//  leanring-buddy
//
//  Turns a sentence of text into audio. Providers only synthesize — they
//  never play anything themselves. All playback goes through
//  VesperSpeechPlaybackEngine, so there is exactly one place that handles
//  interruption, audio levels (which drive Vesper's glow), and knowing when
//  each sentence starts playing (which drives pointing and captions).
//

import AVFoundation
import Foundation

protocol VesperSpeechSynthesisProvider: AnyObject {
    var displayName: String { get }
    /// False when the provider can't be used right now (no key configured,
    /// every key used up, free budget spent). The engine then skips it.
    var isAvailable: Bool { get }
    /// A short status line for the panel, e.g. "key 2 of 5 · ~7,300 credits left".
    var statusDescription: String? { get }

    /// Synthesizes one sentence and returns its audio as PCM buffers, in
    /// whatever format the provider produces. The playback engine converts.
    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer]

    /// Loads the voice (or opens the network connection) ahead of time so
    /// the first real sentence is fast.
    func prewarmVoice()

    /// For a voice that unloads itself while idle (Kokoro): starts reloading
    /// it if needed and waits up to `maximumSeconds` for it. Returns whether
    /// it's available now. Voices that never unload don't wait.
    func waitUntilAvailableIfReloading(maximumSeconds: TimeInterval) async -> Bool
}

extension VesperSpeechSynthesisProvider {
    var statusDescription: String? { nil }
    func prewarmVoice() {}
    func waitUntilAvailableIfReloading(maximumSeconds: TimeInterval) async -> Bool { isAvailable }
}

// MARK: - Compressed Audio Decoding

/// Decodes a complete compressed audio file (MP3 from cloud voices, or WAV)
/// held in memory into PCM buffers. Cloud voices are fetched as MP3 because
/// it's ~12x smaller than raw PCM, which matters on a slow connection.
nonisolated enum CompressedSpeechAudioDecoder {
    static func decodeAudioFileData(_ encodedAudioData: Data) throws -> [AVAudioPCMBuffer] {
        // AVAudioFile reads from disk, so the bytes go through a temp file.
        // The extension tells Core Audio which decoder to use.
        let temporaryAudioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-speech-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(forAudioData: encodedAudioData))
        try encodedAudioData.write(to: temporaryAudioFileURL)
        defer { try? FileManager.default.removeItem(at: temporaryAudioFileURL) }

        let decodedAudioFile = try AVAudioFile(forReading: temporaryAudioFileURL)
        let totalFrameCount = AVAudioFrameCount(decodedAudioFile.length)
        guard totalFrameCount > 0,
              let decodedBuffer = AVAudioPCMBuffer(pcmFormat: decodedAudioFile.processingFormat, frameCapacity: totalFrameCount) else {
            throw VesperSpeechSynthesisError(message: "The voice service returned empty audio.")
        }
        try decodedAudioFile.read(into: decodedBuffer)
        return [decodedBuffer]
    }

    /// Recognizes WAV ("RIFF") and MP3 (an ID3 tag or an MPEG frame sync).
    private static func fileExtension(forAudioData audioData: Data) -> String {
        let leadingBytes = [UInt8](audioData.prefix(4))
        if leadingBytes.starts(with: Array("RIFF".utf8)) {
            return "wav"
        }
        return "mp3"
    }
}

struct VesperSpeechSynthesisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - macOS System Voice

/// Vesper's default voice: macOS's built-in speech synthesizer. Instant,
/// free, offline, and costs no app memory. Quality depends heavily on which
/// voice is installed — the Premium / Enhanced voices (a one-time download
/// in System Settings → Accessibility → Spoken Content → Manage Voices)
/// sound far more natural than the defaults.
final class SystemSpeechSynthesisProvider: NSObject, VesperSpeechSynthesisProvider {
    /// Female en-US voices in order of preference when several are installed
    /// at the same quality level.
    private static let preferredFemaleVoiceNames = ["Zoe", "Ava", "Allison", "Susan", "Samantha"]

    /// Slightly quicker than the system default — Vesper is sharp and direct.
    private static let speakingRate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.06

    let isAvailable = true

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let selectedVoice: AVSpeechSynthesisVoice?

    var displayName: String {
        guard let selectedVoice else { return "System voice" }
        // Enhanced/Premium voices already carry their quality in the name,
        // e.g. "Allison (Enhanced)".
        if selectedVoice.name.contains("(") {
            return selectedVoice.name
        }
        return "\(selectedVoice.name) (\(Self.qualityDescription(for: selectedVoice.quality)))"
    }

    /// True when only a default-quality voice is installed, so the panel can
    /// suggest downloading a Premium voice.
    var isUsingLowQualityVoice: Bool {
        (selectedVoice?.quality ?? .default) == .default
    }

    override init() {
        self.selectedVoice = Self.chooseBestFemaleEnglishVoice()
        super.init()
        print("🔊 System speech: using voice \(displayName)")
    }

    /// Measured: macOS loads the voice lazily, so the very first synthesis
    /// takes ~3.8s while every later one takes ~25–50ms. Synthesizing a
    /// throwaway word at launch (and again on each hotkey press, which costs
    /// ~30ms once warm) keeps that 3.8s out of her first answer.
    func prewarmVoice() {
        Task { [weak self] in
            _ = try? await self?.synthesizeSpeechAudio(for: "hi.")
        }
    }

    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: sentenceText)
        utterance.voice = selectedVoice
        utterance.rate = Self.speakingRate
        utterance.prefersAssistiveTechnologySettings = false

        let synthesisCollector = SpeechBufferCollector()
        return try await withCheckedThrowingContinuation { continuation in
            synthesisCollector.continuation = continuation
            // @Sendable keeps this callback off the main actor: the synthesizer
            // invokes it on its own background queue.
            speechSynthesizer.write(utterance) { @Sendable audioBuffer in
                synthesisCollector.receive(audioBuffer)
            }
            // A sentence normally takes well under a second.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                synthesisCollector.failIfStillWaiting()
            }
        }
    }

    private static func chooseBestFemaleEnglishVoice() -> AVSpeechSynthesisVoice? {
        let candidateVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language == "en-US"
                && voice.gender == .female
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
        }

        func preferenceRank(of voice: AVSpeechSynthesisVoice) -> Int {
            let nameIndex = preferredFemaleVoiceNames.firstIndex { voice.name.hasPrefix($0) }
            return nameIndex ?? preferredFemaleVoiceNames.count
        }

        let bestVoice = candidateVoices.max { firstVoice, secondVoice in
            if firstVoice.quality != secondVoice.quality {
                return firstVoice.quality.rawValue < secondVoice.quality.rawValue
            }
            // Lower rank is more preferred, so it should compare as "greater".
            return preferenceRank(of: firstVoice) > preferenceRank(of: secondVoice)
        }
        return bestVoice ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func qualityDescription(for voiceQuality: AVSpeechSynthesisVoiceQuality) -> String {
        switch voiceQuality {
        case .premium:
            return "Premium"
        case .enhanced:
            return "Enhanced"
        default:
            return "Default"
        }
    }
}

/// Gathers the buffers AVSpeechSynthesizer hands back for one utterance. The
/// synthesizer signals the end of an utterance with an empty buffer.
nonisolated private final class SpeechBufferCollector: @unchecked Sendable {
    var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?
    private var collectedBuffers: [AVAudioPCMBuffer] = []
    private let collectorLock = NSLock()

    func receive(_ audioBuffer: AVAudioBuffer) {
        collectorLock.lock()
        defer { collectorLock.unlock() }

        guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else { return }

        if pcmBuffer.frameLength == 0 {
            let finishedContinuation = continuation
            continuation = nil
            if collectedBuffers.isEmpty {
                finishedContinuation?.resume(throwing: VesperSpeechSynthesisError(message: "System voice produced no audio."))
            } else {
                finishedContinuation?.resume(returning: collectedBuffers)
            }
            return
        }
        collectedBuffers.append(pcmBuffer)
    }

    /// Ends the wait with an error if the synthesizer never signalled the
    /// end — otherwise the speech engine would wait forever and every later
    /// reply would be silent.
    func failIfStillWaiting() {
        collectorLock.lock()
        defer { collectorLock.unlock() }
        guard let waitingContinuation = continuation else { return }
        continuation = nil
        waitingContinuation.resume(throwing: VesperSpeechSynthesisError(message: "System voice took too long."))
    }
}
