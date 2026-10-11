//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation
import Speech

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    /// Transcription runs entirely on-device through Apple's speech stack,
    /// so there is no API key to configure and nothing leaves the Mac.
    /// SpeechAnalyzer (macOS 26) is far more accurate than the legacy
    /// SFSpeechRecognizer; the legacy provider remains the fallback on
    /// hardware where SpeechTranscriber isn't available.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider: any BuddyTranscriptionProvider = SpeechTranscriber.isAvailable
            ? SpeechAnalyzerTranscriptionProvider()
            : AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }
}
