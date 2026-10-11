//
//  GoogleChirpSpeechSynthesisProvider.swift
//  leanring-buddy
//
//  Vesper's preferred voice: Google Cloud Text-to-Speech "Chirp 3 HD", the
//  most natural-sounding option the user compared. Called directly over
//  REST with the user's own API key (kept in the Keychain).
//
//  Google gives 1,000,000 Chirp 3 HD characters free every month; beyond
//  that it charges. Vesper counts every character it sends per calendar
//  month and stops using Google at 950,000, so it can't run up a bill — the
//  playback engine then uses Kokoro instead.
//
//  Audio is requested as MP3 (~12x smaller than raw PCM), which matters on
//  a slow connection.
//

import AVFoundation
import Foundation

final class GoogleChirpSpeechSynthesisProvider: VesperSpeechSynthesisProvider {
    /// The female Chirp 3 HD voices (Vesper's voice is female).
    static let femaleVoiceNames = [
        "Aoede", "Kore", "Leda", "Zephyr", "Achernar", "Autonoe", "Callirrhoe",
        "Despina", "Erinome", "Gacrux", "Laomedeia", "Pulcherrima", "Sulafat", "Vindemiatrix"
    ]
    static let defaultVoiceName = "Aoede"
    /// Stops short of Google's 1,000,000 free characters, leaving headroom
    /// for any difference in how Google counts characters.
    static let monthlyCharacterLimit = 950_000
    /// A sentence that takes longer than this is given to Kokoro instead,
    /// so a slow network never stalls her.
    private static let requestTimeoutSeconds: TimeInterval = 4

    let displayName = "Google"

    private let apiKey: String
    let voiceName: String
    private let apiBaseURL: URL
    private let persistentStore: UserDefaults
    private let urlSession: URLSession
    /// Set when Google rejects the key or the API isn't enabled — a problem
    /// the user has to fix, so retrying every sentence would only add delay.
    private(set) var configurationProblemDescription: String?

    init(
        apiKey: String,
        voiceName: String,
        apiBaseURL: URL = URL(string: "https://texttospeech.googleapis.com")!,
        persistentStore: UserDefaults = .standard
    ) {
        self.apiKey = apiKey
        self.voiceName = voiceName
        self.apiBaseURL = apiBaseURL
        self.persistentStore = persistentStore

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = Self.requestTimeoutSeconds * 2
        sessionConfiguration.urlCache = nil
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    var isAvailable: Bool {
        !apiKey.isEmpty
            && configurationProblemDescription == nil
            && charactersUsedThisMonth < Self.monthlyCharacterLimit
    }

    var statusDescription: String? {
        if apiKey.isEmpty {
            return "no API key yet"
        }
        if let configurationProblemDescription {
            return configurationProblemDescription
        }
        if charactersUsedThisMonth >= Self.monthlyCharacterLimit {
            return "free monthly characters used up"
        }
        let thousandsUsed = Double(charactersUsedThisMonth) / 1000
        return String(format: "%@ · %.0fk of %.0fk free characters this month",
                      voiceName, thousandsUsed, Double(Self.monthlyCharacterLimit) / 1000)
    }

    /// Opens the HTTPS connection ahead of time (costs no characters), so
    /// the first sentence doesn't also pay for the TLS handshake.
    func prewarmVoice() {
        guard isAvailable else { return }
        var connectionWarmupRequest = URLRequest(url: apiBaseURL)
        connectionWarmupRequest.httpMethod = "HEAD"
        urlSession.dataTask(with: connectionWarmupRequest).resume()
    }

    func synthesizeSpeechAudio(for sentenceText: String) async throws -> [AVAudioPCMBuffer] {
        guard isAvailable else {
            throw VesperSpeechSynthesisError(message: "Google voice isn't available: \(statusDescription ?? "unknown")")
        }

        var synthesisRequest = URLRequest(url: apiBaseURL.appendingPathComponent("v1/text:synthesize"))
        synthesisRequest.httpMethod = "POST"
        synthesisRequest.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        synthesisRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        synthesisRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": ["text": sentenceText],
            "voice": ["languageCode": "en-US", "name": "en-US-Chirp3-HD-\(voiceName)"],
            "audioConfig": ["audioEncoding": "MP3", "sampleRateHertz": 24_000]
        ])

        // Characters are counted as soon as the request is sent: Google bills
        // for requests it receives, even ones whose answer arrives too late.
        recordCharactersSent(sentenceText.count)

        let (responseData, response) = try await urlSession.data(for: synthesisRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            throw handleFailure(statusCode: statusCode, responseData: responseData)
        }

        guard let responseObject = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
              let base64AudioContent = responseObject["audioContent"] as? String,
              let mp3AudioData = Data(base64Encoded: base64AudioContent) else {
            throw VesperSpeechSynthesisError(message: "Google returned no audio.")
        }
        return try CompressedSpeechAudioDecoder.decodeAudioFileData(mp3AudioData)
    }

    /// Problems the user must fix (bad key, API or billing not enabled, bad
    /// voice name) disable Google until the key or voice is changed. Busy or
    /// flaky responses only fail this one sentence.
    private func handleFailure(statusCode: Int, responseData: Data) -> Error {
        let responseObject = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        let googleError = responseObject?["error"] as? [String: Any]
        let errorMessage = googleError?["message"] as? String
            ?? String(decoding: responseData.prefix(300), as: UTF8.self)

        switch statusCode {
        case 400:
            // Only a bad voice (or language) is a setup problem that affects
            // every sentence. Other 400s — e.g. one sentence that's too long —
            // fail just that sentence, so Google stays on for the rest.
            let lowercasedErrorMessage = errorMessage.lowercased()
            if lowercasedErrorMessage.contains("voice") || lowercasedErrorMessage.contains("language") {
                configurationProblemDescription = "Google rejected the voice name"
            }
        case 401, 403:
            if errorMessage.lowercased().contains("billing") {
                configurationProblemDescription = "billing isn't enabled on the Google Cloud project"
            } else if errorMessage.lowercased().contains("has not been used") || errorMessage.lowercased().contains("disabled") {
                configurationProblemDescription = "Text-to-Speech API isn't enabled on the project"
            } else {
                configurationProblemDescription = "Google rejected the API key"
            }
        default:
            break
        }
        print("🔊 Google voice error \(statusCode): \(errorMessage)")
        return VesperSpeechSynthesisError(message: "Google error \(statusCode): \(errorMessage)")
    }

    // MARK: - Monthly Character Budget

    private var monthlyUsageStorageKey: String {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"
        return "googleChirpCharactersSent-\(monthFormatter.string(from: Date()))"
    }

    var charactersUsedThisMonth: Int {
        persistentStore.integer(forKey: monthlyUsageStorageKey)
    }

    private func recordCharactersSent(_ characterCount: Int) {
        persistentStore.set(charactersUsedThisMonth + characterCount, forKey: monthlyUsageStorageKey)
    }
}
