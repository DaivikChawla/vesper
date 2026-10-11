//
//  VesperVoiceRouter.swift
//  leanring-buddy
//
//  Decides which voice speaks each sentence of a reply.
//
//  Three modes, chosen in the panel:
//  - Auto: Google (preferred — it sounds best) and Kokoro (on-device, fast)
//    race for the first sentence of each reply. Google wins if it answers
//    quickly enough; otherwise Kokoro's version, already made, plays. The
//    winner speaks the whole reply, so the voice never changes mid-reply.
//  - Google: always Google.
//  - Kokoro: always Kokoro.
//
//  No mode ever goes silent: if the chosen voice fails on a sentence, that
//  sentence falls back (to Kokoro in Auto, then the macOS voice).
//

import AVFoundation
import Combine
import Foundation

enum VesperVoiceMode: String, CaseIterable {
    case automatic
    case google
    case kokoro

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto"
        case .google:
            return "Google"
        case .kokoro:
            return "Kokoro"
        }
    }
}

@MainActor
final class VesperVoiceRouter: ObservableObject {
    // MARK: Auto-mode tuning

    /// In Auto, Google is always given at least this long to answer, because
    /// it's the preferred voice. Kokoro typically answers in ~0.2s, so
    /// without this Google would almost never be heard.
    static let autoModeGoogleMinimumWaitSeconds: TimeInterval = 0.7
    /// And once Kokoro is ready, Google gets at most this much extra time.
    static let autoModeGoogleGraceAfterKokoroSeconds: TimeInterval = 0.25
    /// After this many races in a row that Google loses, Auto stops asking
    /// Google for a while — saving free characters and network round trips.
    static let googleConsecutiveLossesBeforeCooldown = 3
    static let googleCooldownSeconds: TimeInterval = 10 * 60

    // MARK: State

    /// What spoke the most recent sentence, for the panel, e.g. "Google · 0.62s".
    @Published private(set) var lastSentenceVoiceDescription: String?

    var voiceMode: VesperVoiceMode
    var googleProvider: VesperSpeechSynthesisProvider?
    var kokoroProvider: VesperSpeechSynthesisProvider?
    let systemVoiceProvider: VesperSpeechSynthesisProvider

    /// The voice speaking the current reply, once chosen by its first sentence.
    private var voiceChosenForCurrentReply: VesperSpeechSynthesisProvider?
    /// Counts replies. A sentence from an interrupted reply can still finish
    /// synthesizing after the next reply began; its result must neither pick
    /// the new reply's voice nor count as a Google race loss.
    private var currentReplyNumber = 0
    private var consecutiveGoogleRaceLosses = 0
    private var googleCooldownEndsAt: Date?

    init(
        voiceMode: VesperVoiceMode,
        googleProvider: VesperSpeechSynthesisProvider?,
        kokoroProvider: VesperSpeechSynthesisProvider?,
        systemVoiceProvider: VesperSpeechSynthesisProvider
    ) {
        self.voiceMode = voiceMode
        self.googleProvider = googleProvider
        self.kokoroProvider = kokoroProvider
        self.systemVoiceProvider = systemVoiceProvider
    }

    // MARK: - Engine API

    /// Called at the start of every reply; the next sentence picks the voice.
    func beginNewReply() {
        currentReplyNumber += 1
        voiceChosenForCurrentReply = nil
    }

    /// Loads the voices the current mode can use.
    func prewarmVoices() {
        switch voiceMode {
        case .automatic:
            googleProvider?.prewarmVoice()
            kokoroProvider?.prewarmVoice()
        case .google:
            googleProvider?.prewarmVoice()
        case .kokoro:
            kokoroProvider?.prewarmVoice()
        }
        systemVoiceProvider.prewarmVoice()
    }

    /// Synthesizes one sentence with the right voice. Returns nil only if
    /// every voice failed, which in practice means the macOS voice failed too.
    func synthesizeSentence(_ sentenceText: String) async -> [AVAudioPCMBuffer]? {
        let sentenceStartedAt = Date()
        let replyNumberAtStart = currentReplyNumber
        /// Voices that already failed this sentence aren't asked again —
        /// a second Google attempt would bill the same characters twice.
        var voiceNamesThatFailedThisSentence = Set<String>()

        // Kokoro unloads after 10 idle minutes and reloads in ~1.5 s. When
        // it's the only voice this reply could use besides the macOS one,
        // wait a little for it rather than speaking the whole reply in the
        // fallback voice. Never waits when Google can speak instead.
        if voiceChosenForCurrentReply == nil,
           let kokoroProvider, !kokoroProvider.isAvailable,
           isKokoroTheOnlyVoiceBeforeTheMacOSVoice {
            let kokoroWaitStartedAt = Date()
            let isKokoroReady = await kokoroProvider.waitUntilAvailableIfReloading(
                maximumSeconds: Self.kokoroReloadMaximumWaitSeconds
            )
            let waitedSeconds = Date().timeIntervalSince(kokoroWaitStartedAt)
            if waitedSeconds > 0.05 {
                print(String(format: "🔊 Voice: waited %.2fs for Kokoro to reload — %@", waitedSeconds,
                             isKokoroReady ? "ready" : "not ready, the macOS voice speaks this reply"))
            }
        }

        if voiceChosenForCurrentReply == nil,
           voiceMode == .automatic,
           let googleProvider, googleProvider.isAvailable, !isGoogleCoolingDown,
           let kokoroProvider, kokoroProvider.isAvailable {
            if let raceWinner = await raceGoogleAgainstKokoro(
                sentenceText,
                googleProvider: googleProvider,
                kokoroProvider: kokoroProvider,
                replyNumberAtStart: replyNumberAtStart
            ) {
                if replyNumberAtStart == currentReplyNumber {
                    voiceChosenForCurrentReply = raceWinner.provider
                }
                return raceWinner.buffers
            }
            // Both failed this sentence — fall through to the fallback order.
            voiceNamesThatFailedThisSentence = [googleProvider.displayName, kokoroProvider.displayName]
        }

        for synthesisProvider in providersInFallbackOrder()
        where synthesisProvider.isAvailable && !voiceNamesThatFailedThisSentence.contains(synthesisProvider.displayName) {
            do {
                let speechBuffers = try await synthesisProvider.synthesizeSpeechAudio(for: sentenceText)
                if voiceChosenForCurrentReply == nil && replyNumberAtStart == currentReplyNumber {
                    voiceChosenForCurrentReply = synthesisProvider
                }
                lastSentenceVoiceDescription = String(
                    format: "%@ · %.2fs", synthesisProvider.displayName, Date().timeIntervalSince(sentenceStartedAt)
                )
                return speechBuffers
            } catch {
                print("⚠️ Voice: \(synthesisProvider.displayName) failed on a sentence, falling back: \(error.localizedDescription)")
            }
        }
        return nil
    }

    // MARK: - Ordering

    private var isGoogleCoolingDown: Bool {
        guard let googleCooldownEndsAt else { return false }
        return googleCooldownEndsAt > Date()
    }

    /// The longest a reply's first sentence waits for Kokoro to reload.
    /// Measured: load + warm-up takes 1.3–2.1 s, and it starts on hotkey
    /// press, well before Claude's first sentence arrives.
    static let kokoroReloadMaximumWaitSeconds: TimeInterval = 1.5

    /// True in Kokoro mode, or in Auto when Google can't speak (no key,
    /// out of budget, cooling down).
    private var isKokoroTheOnlyVoiceBeforeTheMacOSVoice: Bool {
        switch voiceMode {
        case .kokoro:
            return true
        case .automatic:
            let canGoogleSpeak = (googleProvider?.isAvailable ?? false) && !isGoogleCoolingDown
            return !canGoogleSpeak
        case .google:
            return false
        }
    }

    /// The voices to try for a sentence, best first. Once a reply has a
    /// voice, it stays first so the reply keeps one voice.
    private func providersInFallbackOrder() -> [VesperSpeechSynthesisProvider] {
        var orderedProviders: [VesperSpeechSynthesisProvider] = []
        switch voiceMode {
        case .automatic:
            if !isGoogleCoolingDown, let googleProvider {
                orderedProviders.append(googleProvider)
            }
            if let kokoroProvider {
                orderedProviders.append(kokoroProvider)
            }
        case .google:
            if let googleProvider {
                orderedProviders.append(googleProvider)
            }
        case .kokoro:
            if let kokoroProvider {
                orderedProviders.append(kokoroProvider)
            }
        }
        orderedProviders.append(systemVoiceProvider)

        if let voiceChosenForCurrentReply,
           let chosenIndex = orderedProviders.firstIndex(where: { $0 === voiceChosenForCurrentReply }) {
            orderedProviders.remove(at: chosenIndex)
            orderedProviders.insert(voiceChosenForCurrentReply, at: 0)
        }
        return orderedProviders
    }

    // MARK: - The Auto Race

    private func raceGoogleAgainstKokoro(
        _ sentenceText: String,
        googleProvider: VesperSpeechSynthesisProvider,
        kokoroProvider: VesperSpeechSynthesisProvider,
        replyNumberAtStart: Int
    ) async -> (provider: VesperSpeechSynthesisProvider, buffers: [AVAudioPCMBuffer])? {
        let voiceRace = GoogleVersusKokoroRace()

        let raceOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<GoogleVersusKokoroRace.Outcome, Never>) in
            voiceRace.continuation = continuation
            Task {
                do {
                    voiceRace.googleResult = .success(try await googleProvider.synthesizeSpeechAudio(for: sentenceText))
                } catch {
                    voiceRace.googleResult = .failure(error)
                }
                voiceRace.googleFinishedAt = Date()
                voiceRace.decideIfPossible()
            }
            Task {
                do {
                    voiceRace.kokoroResult = .success(try await kokoroProvider.synthesizeSpeechAudio(for: sentenceText))
                } catch {
                    voiceRace.kokoroResult = .failure(error)
                }
                voiceRace.kokoroFinishedAt = Date()
                voiceRace.decideIfPossible()
            }
        }

        // A race from a reply that was interrupted meanwhile says nothing
        // about Google's speed for this one: don't count it either way.
        let isRaceForCurrentReply = replyNumberAtStart == currentReplyNumber

        switch raceOutcome {
        case .google(let speechBuffers):
            if isRaceForCurrentReply {
                consecutiveGoogleRaceLosses = 0
            }
            let googleSeconds = voiceRace.secondsUntilGoogleFinished ?? 0
            lastSentenceVoiceDescription = String(format: "Google · %.2fs", googleSeconds)
            print(String(format: "🔊 Auto voice: Google won in %.2fs%@", googleSeconds,
                         voiceRace.secondsUntilKokoroFinished.map { String(format: " (Kokoro %.2fs)", $0) } ?? ""))
            return (googleProvider, speechBuffers)

        case .kokoro(let speechBuffers):
            if isRaceForCurrentReply {
                consecutiveGoogleRaceLosses += 1
            }
            if isRaceForCurrentReply && consecutiveGoogleRaceLosses >= Self.googleConsecutiveLossesBeforeCooldown {
                googleCooldownEndsAt = Date().addingTimeInterval(Self.googleCooldownSeconds)
                consecutiveGoogleRaceLosses = 0
                print("🔊 Auto voice: Google lost \(Self.googleConsecutiveLossesBeforeCooldown) races in a row — using Kokoro only for \(Int(Self.googleCooldownSeconds / 60)) minutes")
            }
            let kokoroSeconds = voiceRace.secondsUntilKokoroFinished ?? 0
            lastSentenceVoiceDescription = String(format: "Kokoro · %.2fs (Google too slow)", kokoroSeconds)
            let googleOutcomeDescription: String
            switch voiceRace.googleResult {
            case .failure?:
                googleOutcomeDescription = "failed"
            case .success?:
                googleOutcomeDescription = String(format: "took %.2fs", voiceRace.secondsUntilGoogleFinished ?? 0)
            case nil:
                googleOutcomeDescription = "hadn't answered"
            }
            print(String(format: "🔊 Auto voice: Kokoro in %.2fs — Google %@", kokoroSeconds, googleOutcomeDescription))
            return (kokoroProvider, speechBuffers)

        case .neither:
            return nil
        }
    }
}

/// One Auto-mode race. Both voices synthesize the same sentence at once;
/// `decideIfPossible()` runs whenever either finishes (and on a timer) and
/// settles the race as soon as the rules allow:
/// - Google finished successfully → Google.
/// - Kokoro finished → wait until the later of (start + minimum wait) and
///   (Kokoro + grace); if Google still hasn't answered by then → Kokoro.
/// - If one fails, the other wins whenever it finishes.
@MainActor
private final class GoogleVersusKokoroRace {
    enum Outcome {
        case google([AVAudioPCMBuffer])
        case kokoro([AVAudioPCMBuffer])
        case neither
    }

    let startedAt = Date()
    var continuation: CheckedContinuation<Outcome, Never>?
    var googleResult: Result<[AVAudioPCMBuffer], Error>?
    var googleFinishedAt: Date?
    var kokoroResult: Result<[AVAudioPCMBuffer], Error>?
    var kokoroFinishedAt: Date?
    private var decisionTimerTask: Task<Void, Never>?

    var secondsUntilGoogleFinished: TimeInterval? {
        googleFinishedAt?.timeIntervalSince(startedAt)
    }

    var secondsUntilKokoroFinished: TimeInterval? {
        kokoroFinishedAt?.timeIntervalSince(startedAt)
    }

    func decideIfPossible() {
        guard continuation != nil else { return }

        switch (googleResult, kokoroResult) {
        case (.success(let googleBuffers)?, _):
            settle(.google(googleBuffers))

        case (.failure?, .success(let kokoroBuffers)?):
            settle(.kokoro(kokoroBuffers))

        case (.failure?, .failure?):
            settle(.neither)

        case (nil, .success(let kokoroBuffers)?):
            // Kokoro is ready; give Google its remaining allowance.
            let googleDeadline = max(
                startedAt.addingTimeInterval(VesperVoiceRouter.autoModeGoogleMinimumWaitSeconds),
                (kokoroFinishedAt ?? Date()).addingTimeInterval(VesperVoiceRouter.autoModeGoogleGraceAfterKokoroSeconds)
            )
            let secondsUntilDeadline = googleDeadline.timeIntervalSinceNow
            if secondsUntilDeadline <= 0 {
                settle(.kokoro(kokoroBuffers))
            } else if decisionTimerTask == nil {
                decisionTimerTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(secondsUntilDeadline))
                    self?.decisionTimerTask = nil
                    self?.decideIfPossible()
                }
            }

        case (.failure?, nil), (nil, .failure?), (nil, nil):
            // Wait for the other voice; each has its own timeout.
            break
        }
    }

    private func settle(_ outcome: Outcome) {
        decisionTimerTask?.cancel()
        decisionTimerTask = nil
        let pendingContinuation = continuation
        continuation = nil
        pendingContinuation?.resume(returning: outcome)
    }
}
