//
//  main.swift — test driver for GoogleChirpSpeechSynthesisProvider
//
//  Runs the real provider against fake-google-tts-server.py: success and
//  what's sent, the monthly free-character budget, configuration errors
//  (API disabled, billing, bad voice), a busy response, and a slow network.
//  Silent, no real Google account, no Xcode build.
//  Built and run by scripts/test-google-voice.sh.
//

@preconcurrency import AVFoundation
import Foundation

let fakeServerBaseURL = URL(string: CommandLine.arguments[1])!
let fakeServerStateDirectory = CommandLine.arguments[2]

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

/// A private UserDefaults domain per provider, so tests never touch the app's real counters.
func makeIsolatedStore() -> UserDefaults {
    let suiteName = "vesper-google-voice-test-\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

func makeProvider(apiKey: String, store: UserDefaults = makeIsolatedStore()) -> GoogleChirpSpeechSynthesisProvider {
    GoogleChirpSpeechSynthesisProvider(apiKey: apiKey, voiceName: "Aoede", apiBaseURL: fakeServerBaseURL, persistentStore: store)
}

func runAllChecks() async {
    // 1. No key yet.
    print("\n— no key")
    let providerWithoutKey = makeProvider(apiKey: "")
    check(!providerWithoutKey.isAvailable && providerWithoutKey.statusDescription == "no API key yet",
          "without a key Google is skipped", providerWithoutKey.statusDescription ?? "")

    // 2. A successful sentence.
    print("\n— a successful sentence")
    let workingProvider = makeProvider(apiKey: "key-ok")
    let sentence = "hey, i'm vesper."
    do {
        let speechBuffers = try await workingProvider.synthesizeSpeechAudio(for: sentence)
        check((speechBuffers.first?.frameLength ?? 0) > 5_000, "audio comes back and decodes",
              "\(speechBuffers.first?.frameLength ?? 0) frames at \(Int(speechBuffers.first?.format.sampleRate ?? 0)) Hz")
        let lastRequest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fakeServerStateDirectory + "/last-request.json")))) as? [String: Any]
        let requestedVoice = (lastRequest?["voice"] as? [String: Any])?["name"] as? String
        let requestedEncoding = (lastRequest?["audioConfig"] as? [String: Any])?["audioEncoding"] as? String
        let requestedText = (lastRequest?["input"] as? [String: Any])?["text"] as? String
        check(requestedVoice == "en-US-Chirp3-HD-Aoede", "asks for the chosen Chirp 3 HD voice", requestedVoice ?? "none")
        check(requestedEncoding == "MP3", "asks for compressed MP3 (smaller on a slow connection)", requestedEncoding ?? "none")
        check(requestedText == sentence, "sends the sentence text")
        check(workingProvider.charactersUsedThisMonth == sentence.count, "counts characters toward the free month",
              "\(workingProvider.charactersUsedThisMonth) counted")
        check(workingProvider.statusDescription?.contains("of 950k free characters") == true,
              "status shows the month's usage", workingProvider.statusDescription ?? "")
    } catch {
        check(false, "a successful sentence", "\(error)")
    }

    // 3. The free-month budget stops Google before it could charge.
    print("\n— monthly budget")
    let nearlySpentStore = makeIsolatedStore()
    let monthFormatter = DateFormatter()
    monthFormatter.dateFormat = "yyyy-MM"
    nearlySpentStore.set(GoogleChirpSpeechSynthesisProvider.monthlyCharacterLimit - 5,
                         forKey: "googleChirpCharactersSent-\(monthFormatter.string(from: Date()))")
    let nearlySpentProvider = makeProvider(apiKey: "key-ok", store: nearlySpentStore)
    check(nearlySpentProvider.isAvailable, "just under the limit, Google is still used")
    _ = try? await nearlySpentProvider.synthesizeSpeechAudio(for: sentence)
    check(!nearlySpentProvider.isAvailable && nearlySpentProvider.statusDescription == "free monthly characters used up",
          "once past 950,000 characters Google stops for the month", nearlySpentProvider.statusDescription ?? "")

    // 4. Configuration problems disable Google with a helpful status.
    print("\n— configuration problems")
    for (apiKey, expectedStatusFragment, problemName) in [
        ("key-api-disabled", "isn't enabled", "the Text-to-Speech API isn't enabled"),
        ("key-billing", "billing", "billing isn't enabled"),
        ("key-bad", "rejected the voice name", "Google rejects the voice name")
    ] {
        let misconfiguredProvider = makeProvider(apiKey: apiKey)
        do {
            _ = try await misconfiguredProvider.synthesizeSpeechAudio(for: sentence)
            check(false, "\(problemName): reported", "it succeeded")
        } catch {
            check(!misconfiguredProvider.isAvailable && (misconfiguredProvider.statusDescription ?? "").contains(expectedStatusFragment),
                  "\(problemName): Google is set aside and the panel says why", misconfiguredProvider.statusDescription ?? "")
        }
    }

    // 5. A busy response fails one sentence but keeps Google.
    print("\n— busy / slow")
    let busyProvider = makeProvider(apiKey: "key-busy")
    do {
        _ = try await busyProvider.synthesizeSpeechAudio(for: sentence)
        check(false, "a busy response fails that sentence", "it succeeded")
    } catch {
        check(busyProvider.isAvailable, "a busy (429) response fails that sentence only; Google stays on")
    }

    // 6. A slow network gives up in time.
    let slowProvider = makeProvider(apiKey: "key-slow")
    let slowStartedAt = Date()
    do {
        _ = try await slowProvider.synthesizeSpeechAudio(for: sentence)
        check(false, "a slow response times out", "it succeeded")
    } catch {
        let waitedSeconds = Date().timeIntervalSince(slowStartedAt)
        check(waitedSeconds < 6.5 && slowProvider.isAvailable,
              "a slow response gives up within the time limit and Google stays on",
              String(format: "gave up after %.1fs", waitedSeconds))
    }
}

Task { @MainActor in
    await runAllChecks()
    print(failedCheckCount == 0 ? "\n✅ all Google voice checks passed" : "\n❌ \(failedCheckCount) Google voice check(s) failed")
    exit(failedCheckCount == 0 ? 0 : 1)
}
dispatchMain()
