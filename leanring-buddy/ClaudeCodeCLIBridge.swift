//
//  ClaudeCodeCLIBridge.swift
//  leanring-buddy
//
//  Talks to Claude through the user's own locally installed `claude` CLI
//  (Claude Code), so every request runs on their Claude subscription instead
//  of a metered API key. There is no API key anywhere in this app.
//
//  One long-lived `claude -p` process is kept alive and spoken to over
//  stdin/stdout using the CLI's stream-json protocol: each user turn is one
//  JSON line written to stdin, and the reply streams back as JSON lines on
//  stdout. Keeping the process alive avoids paying the ~1.7s CLI boot on
//  every question, and the process remembers the conversation on its own.
//
//  Every flag and environment variable below was verified against the real
//  CLI on this machine before being written down — see
//  scripts/verify-claude-bridge.py, which re-checks them.
//

import Foundation

// MARK: - Model Selection

/// The Claude models Vesper can use, stored as the CLI's model aliases so
/// they keep pointing at the newest Sonnet / Opus without code changes.
enum VesperClaudeModel: String, CaseIterable {
    case sonnet
    case opus

    var displayName: String {
        switch self {
        case .sonnet:
            return "Sonnet"
        case .opus:
            return "Opus"
        }
    }

    /// Maps any previously stored value to a CLI alias. The original app
    /// stored full API model IDs such as "claude-sonnet-4-6", which the CLI
    /// would reject, so anything mentioning "opus" becomes Opus and
    /// everything else falls back to Sonnet (the fastest option measured).
    static func fromStoredPreferenceValue(_ storedPreferenceValue: String?) -> VesperClaudeModel {
        guard let normalizedStoredValue = storedPreferenceValue?.lowercased() else {
            return .sonnet
        }
        if normalizedStoredValue.contains("opus") {
            return .opus
        }
        return .sonnet
    }
}

// MARK: - Subscription Usage

/// A snapshot of the user's Claude subscription usage, parsed from the
/// `rate_limit_event` messages the CLI emits alongside every reply.
/// Utilization values run from 0.0 (unused) to 1.0 (window exhausted).
nonisolated struct ClaudeSubscriptionUsageSnapshot: Equatable, Sendable {
    let rateLimitStatus: String
    let fiveHourWindowUtilization: Double?
    let fiveHourWindowResetsAt: Date?
    let sevenDayWindowUtilization: Double?
    let sevenDayWindowResetsAt: Date?
    /// When the window that is currently limiting the user resets.
    let limitingWindowResetsAt: Date?

    /// The CLI reports "allowed" while requests go through. Any status that
    /// does not start with "allowed" means the subscription is currently
    /// refusing requests, so Vesper should rest until the reset time.
    var isRequestAllowed: Bool {
        rateLimitStatus.hasPrefix("allowed")
    }

    /// The fuller of the two usage windows — what saver mode keys off.
    var highestWindowUtilization: Double {
        max(fiveHourWindowUtilization ?? 0, sevenDayWindowUtilization ?? 0)
    }

    /// The reset time of whichever window is fullest, used when telling the
    /// user when Vesper will be back.
    var resetTimeOfFullestWindow: Date? {
        if let limitingWindowResetsAt {
            return limitingWindowResetsAt
        }
        let fiveHourUtilization = fiveHourWindowUtilization ?? 0
        let sevenDayUtilization = sevenDayWindowUtilization ?? 0
        return sevenDayUtilization > fiveHourUtilization ? sevenDayWindowResetsAt : fiveHourWindowResetsAt
    }
}

// MARK: - Turn Results and Errors

/// The outcome of one completed question → answer turn.
/// Wall-clock stamps for the "⏱️" diagnostic lines, so the gap between
/// hotkey release, transcript, sending, thinking and first text can be read
/// straight from the log.
nonisolated enum VesperTimingLog {
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func stamp() -> String {
        stampFormatter.string(from: Date())
    }
}

struct ClaudeCLITurnResult {
    /// The complete reply text, including any [POINT:...] tags.
    let fullResponseText: String
    /// Seconds from sending the question until the first reply text arrived.
    let secondsUntilFirstResponseText: TimeInterval?
    /// Seconds from sending the question until the reply finished.
    let totalTurnSeconds: TimeInterval
    /// How many tokens of context this turn used (grows with every
    /// screenshot kept in the conversation). Drives context rollover.
    let contextTokenCount: Int
}

enum ClaudeCLIBridgeError: LocalizedError {
    case claudeCLINotFound(searchedPaths: [String])
    case processFailedToStart(underlyingErrorDescription: String)
    case processExitedUnexpectedly(standardErrorTail: String)
    case notLoggedIn
    case subscriptionRateLimited(resetsAt: Date?)
    case noResponseBeforeTimeout
    case claudeReportedError(message: String)

    var errorDescription: String? {
        switch self {
        case .claudeCLINotFound(let searchedPaths):
            return "Couldn't find the claude CLI. Looked in: \(searchedPaths.joined(separator: ", "))"
        case .processFailedToStart(let underlyingErrorDescription):
            return "The claude CLI failed to start: \(underlyingErrorDescription)"
        case .processExitedUnexpectedly(let standardErrorTail):
            return "The claude CLI exited unexpectedly. \(standardErrorTail)"
        case .notLoggedIn:
            return "The claude CLI isn't logged in. Run `claude` in Terminal and log in."
        case .subscriptionRateLimited:
            return "Your Claude subscription's usage limit has been reached."
        case .noResponseBeforeTimeout:
            return "Claude didn't respond in time."
        case .claudeReportedError(let message):
            return message
        }
    }
}

// MARK: - Binary Location

/// Finds the `claude` executable. A GUI app launched from Finder or Xcode
/// gets a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) that does not include
/// the places the CLI is normally installed, so we check absolute paths.
enum ClaudeCLIExecutableLocator {
    static func candidateExecutablePaths() -> [String] {
        let homeDirectoryPath = NSHomeDirectory()
        var candidatePaths: [String] = []

        // An explicit override in Info.plist always wins.
        if let configuredPath = AppBundleConfiguration.stringValue(forKey: "ClaudeCLIPath") {
            candidatePaths.append((configuredPath as NSString).expandingTildeInPath)
        }

        candidatePaths.append(contentsOf: [
            "\(homeDirectoryPath)/.local/bin/claude",        // native installer (this Mac)
            "/opt/homebrew/bin/claude",                      // Homebrew on Apple Silicon
            "/usr/local/bin/claude",                         // Homebrew on Intel / npm global
            "\(homeDirectoryPath)/.claude/local/claude"      // older local installs
        ])
        return candidatePaths
    }

    static func locateExecutablePath() -> String? {
        candidateExecutablePaths().first { candidatePath in
            FileManager.default.isExecutableFile(atPath: candidatePath)
        }
    }
}

// MARK: - Bridge

@MainActor
final class ClaudeCodeCLIBridge {

    // MARK: Tunables

    /// Once a conversation's context passes this many tokens, the next turn
    /// starts a fresh CLI process seeded with a short text-only recap.
    /// Measured: each 1280px screenshot turn adds ~1,460 tokens, so this is
    /// roughly 20 turns. Every screenshot kept in context is re-read (from
    /// cache) on every later turn, which draws down the subscription budget.
    /// Raised from 30k: two-screen turns add ~3k tokens each, so 30k rolled
    /// over every ~9 turns mid-task and she "forgot" what they were doing.
    /// Older screenshots are read from the prompt cache at a fraction of
    /// the normal cost.
    private static let standardContextTokenRolloverThreshold = 45_000
    /// A tighter threshold used in saver mode, when the budget is nearly spent.
    private static let saverModeContextTokenRolloverThreshold = 12_000
    /// The CLI process is shut down after this long without a question, to
    /// give its memory back on an 8 GB machine. It is re-warmed on hotkey press.
    private static let idleShutdownDelaySeconds: TimeInterval = 10 * 60
    /// Exchanges older than this are left out of recaps — after an hour away,
    /// a new question is almost always a new conversation.
    /// Long enough that a conversation survives a restart, a crash or a
    /// night's sleep; New conversation is how the user starts over.
    private static let recapMaximumExchangeAgeSeconds: TimeInterval = 12 * 60 * 60
    private static let recapMaximumExchangeCount = 12
    /// If no reply text has arrived this long after a question, give up.
    private static let firstResponseTextTimeoutSeconds: TimeInterval = 25
    /// If a reply has started but no more text arrives for this long, give up.
    private static let midReplyStallTimeoutSeconds: TimeInterval = 30

    // MARK: Public State

    /// Called on the main actor whenever a fresh usage snapshot arrives.
    var onSubscriptionUsageUpdated: ((ClaudeSubscriptionUsageSnapshot) -> Void)?
    /// Called whenever a new CLI process starts (rollover, idle restart,
    /// crash, model switch): the old context, with any text others wrote,
    /// is gone — only a short recap of their own conversation carries over.
    var onNewProcessStarted: (() -> Void)?

    private(set) var selectedModel: VesperClaudeModel
    private(set) var latestSubscriptionUsage: ClaudeSubscriptionUsageSnapshot?

    /// When true, context rolls over sooner to conserve subscription usage.
    var isSaverModeEnabled = false

    /// When set, called each time a CLI process starts, so the system prompt
    /// can include things that change between processes (her long-term
    /// memory). A process's system prompt is fixed for its whole life.
    var systemPromptProvider: (() -> String)?

    // MARK: Private State

    private let systemPrompt: String
    private let sessionWorkingDirectoryURL: URL
    /// Lets the bridge test point at a fake CLI. The app never sets this.
    private let claudeExecutablePathOverride: String?
    private let standardInputWriteQueue = DispatchQueue(label: "com.vesper.claude-cli.stdin")

    private var runningProcess: RunningClaudeCLIProcess?
    /// When the current CLI process was started — logged with each turn.
    private var currentProcessStartedAt: Date?
    /// Increments every time a new process is spawned, so late callbacks from
    /// a process we already replaced can be recognized and ignored.
    private var currentProcessGeneration = 0

    private var activeTurn: ActiveClaudeTurn?
    /// Replies we have given up on (barge-in or timeout) still finish inside
    /// the CLI and emit their own `result` message. The CLI handles one turn
    /// at a time, so every output line belongs to the oldest unfinished turn:
    /// while this count is above zero, output belongs to an abandoned turn
    /// and is dropped instead of being mistaken for the current answer.
    private var abandonedTurnResultsStillExpected = 0

    private var textOnlyConversationExchanges: [TextOnlyConversationExchange] = []
    /// Set when the conversation moved to a fresh CLI process, so the next
    /// question carries a recap of what was said before.
    private var shouldPrependRecapToNextTurn = false
    private var idleShutdownTask: Task<Void, Never>?

    /// Where the text-only conversation is saved after every turn, so it
    /// survives Vesper quitting, crashing or being rebuilt. Nil (tests) keeps
    /// it in memory only. Never holds screenshots.
    private let conversationFileURL: URL?

    static var defaultConversationFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vesper", isDirectory: true)
            .appendingPathComponent("conversation.json")
    }

    init(
        systemPrompt: String,
        selectedModel: VesperClaudeModel,
        claudeExecutablePathOverride: String? = nil,
        conversationFileURL: URL? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.selectedModel = selectedModel
        self.claudeExecutablePathOverride = claudeExecutablePathOverride
        self.conversationFileURL = conversationFileURL

        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.sessionWorkingDirectoryURL = applicationSupportURL
            .appendingPathComponent("Vesper", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)

        // Writing to the stdin of a CLI process that has already exited would
        // otherwise deliver SIGPIPE and kill the whole app. Ignoring it turns
        // that case into an ordinary write error we can handle.
        signal(SIGPIPE, SIG_IGN)

        restoreSavedConversation()
    }

    // MARK: - Saved Conversation

    /// Picks up the conversation from before a restart: the first question
    /// to the new process carries it as a recap.
    private func restoreSavedConversation() {
        guard let conversationFileURL,
              let savedData = try? Data(contentsOf: conversationFileURL),
              let savedExchanges = try? JSONDecoder().decode([TextOnlyConversationExchange].self, from: savedData) else {
            return
        }
        let oldestKeptDate = Date().addingTimeInterval(-Self.recapMaximumExchangeAgeSeconds)
        textOnlyConversationExchanges = Array(savedExchanges.filter { $0.completedAt >= oldestKeptDate }.suffix(Self.recapMaximumExchangeCount))
        shouldPrependRecapToNextTurn = !textOnlyConversationExchanges.isEmpty
        print("🧠 Restored \(textOnlyConversationExchanges.count) exchange(s) of the last conversation")
    }

    private func saveConversation() {
        guard let conversationFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: conversationFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(textOnlyConversationExchanges).write(to: conversationFileURL, options: .atomic)
        } catch {
            print("⚠️ Couldn't save the conversation: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    /// Starts the CLI process ahead of time so its ~1.7s boot overlaps with
    /// the user speaking. Called when the push-to-talk hotkey goes down.
    func prewarmProcessIfNeeded() {
        if runningProcess == nil {
            do {
                try startProcess()
            } catch {
                // Surfaced properly on the next real turn; prewarming is best-effort.
                print("⚠️ Claude bridge: prewarm failed: \(error.localizedDescription)")
                return
            }
        }
        // Restart the idle clock. If no question follows (an accidental tap,
        // or a limit that's already reached), the process is still released
        // after the idle delay; a real turn cancels this when it's sent.
        scheduleIdleShutdown()
    }

    /// Switches models. The running process is replaced, and the next
    /// question carries a recap so the conversation continues seamlessly.
    func switchModel(to newModel: VesperClaudeModel) {
        guard newModel != selectedModel else { return }
        selectedModel = newModel
        if runningProcess != nil {
            interruptActiveTurnIfAny()
            terminateRunningProcess(preservingConversationThroughRecap: true)
        }
    }

    /// Forgets the conversation entirely — used by "New conversation".
    func startNewConversation() {
        interruptActiveTurnIfAny()
        textOnlyConversationExchanges.removeAll()
        saveConversation()
        shouldPrependRecapToNextTurn = false
        terminateRunningProcess(preservingConversationThroughRecap: false)
    }

    /// Barge-in: drops the reply in progress immediately and tells the CLI to
    /// stop generating it. Synchronous on purpose — reply text already queued
    /// on the main thread must be discarded, not spoken, so the turn has to be
    /// abandoned before any of it is handled.
    func interruptActiveTurn() {
        interruptActiveTurnIfAny()
    }

    /// Stops the CLI process. Called when the app quits.
    func shutDown() {
        cancelIdleShutdown()
        interruptActiveTurnIfAny()
        terminateRunningProcess(preservingConversationThroughRecap: false)
    }

    /// Sends one question (screenshots + transcript) and waits for the reply.
    /// `onResponseTextDelta` receives each new piece of reply text as it
    /// streams in, on the main actor. Cancelling the calling Task interrupts
    /// the turn inside the CLI, which is how barge-in works.
    /// The thinking budget the running process was last told to use. Every
    /// new process starts at 0 (from its environment), and each switch costs
    /// part of the prompt cache, so it's only sent when it changes.
    private var currentThinkingBudgetTokens = 0
    /// Enough to switch Sonnet 5's adaptive thinking back on (for this model
    /// it's a switch, not a real budget).
    static let deepThinkingBudgetTokens = 16_000

    /// `wantsDeepThinking` turns thinking on for this turn (hands-on steps,
    /// "think about it"); otherwise she answers without it, ~2–3 s sooner.
    ///
    /// `recapUserText` is what this turn adds to the recap a fresh session
    /// gets: normally the user's own words (not the whole prompt with its
    /// control line). Hands-on steps pass `continuesPreviousExchange`, so a
    /// whole task collapses into one entry: the request and how it ended.
    func sendTurn(
        images: [(data: Data, label: String)],
        userPrompt: String,
        recapUserText: String? = nil,
        continuesPreviousExchange: Bool = false,
        wantsDeepThinking: Bool = false,
        onResponseTextDelta: @escaping (String) -> Void
    ) async throws -> ClaudeCLITurnResult {
        try Task.checkCancellation()
        cancelIdleShutdown()
        interruptActiveTurnIfAny()

        if runningProcess == nil {
            try startProcess()
        }
        // How warm the CLI was when this question went out: a process
        // started moments ago is still booting (~1.7s), which shows up as a
        // slow first reply.
        if let currentProcessStartedAt {
            print(String(format: "🧠 Sending turn — CLI process started %.1fs ago", Date().timeIntervalSince(currentProcessStartedAt)))
        }
        print("⏱️ \(VesperTimingLog.stamp()) turn sent with \(images.count) image(s)")

        let turnIdentifier = UUID()
        let userMessageLine = try makeUserMessageLine(images: images, userPrompt: userPrompt)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClaudeCLITurnResult, Error>) in
                activeTurn = ActiveClaudeTurn(
                    turnIdentifier: turnIdentifier,
                    userPrompt: userPrompt,
                    recapUserText: recapUserText ?? userPrompt,
                    continuesPreviousExchange: continuesPreviousExchange,
                    continuation: continuation,
                    onResponseTextDelta: onResponseTextDelta,
                    sentAt: Date()
                )
                setThinkingBudgetIfNeeded(wantsDeepThinking ? Self.deepThinkingBudgetTokens : 0)
                writeLineToStandardInput(userMessageLine)
                scheduleFirstResponseTextTimeout(forTurnIdentifier: turnIdentifier)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.abandonTurn(turnIdentifier: turnIdentifier, failWith: CancellationError())
            }
        }
    }

    // MARK: - Process Lifecycle

    private func startProcess() throws {
        currentProcessStartedAt = Date()
        guard let executablePath = claudeExecutablePathOverride ?? ClaudeCLIExecutableLocator.locateExecutablePath() else {
            throw ClaudeCLIBridgeError.claudeCLINotFound(
                searchedPaths: ClaudeCLIExecutableLocator.candidateExecutablePaths()
            )
        }

        try FileManager.default.createDirectory(at: sessionWorkingDirectoryURL, withIntermediateDirectories: true)

        currentProcessGeneration += 1
        let processGeneration = currentProcessGeneration

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = makeCommandLineArguments()
        process.environment = makeProcessEnvironment(executablePath: executablePath)
        // An empty folder, so the CLI never picks up some project's CLAUDE.md.
        process.currentDirectoryURL = sessionWorkingDirectoryURL

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let runningClaudeProcess = RunningClaudeCLIProcess(
            process: process,
            standardInputHandle: standardInputPipe.fileHandleForWriting,
            processGeneration: processGeneration
        )

        // stdout and stderr are both drained continuously from the moment the
        // process starts. If either pipe's ~64KB buffer fills up because
        // nobody is reading it, the CLI blocks and everything hangs.
        let standardOutputLineAccumulator = NewlineDelimitedLineAccumulator()
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] readableHandle in
            let newlyAvailableBytes = readableHandle.availableData
            if newlyAvailableBytes.isEmpty {
                readableHandle.readabilityHandler = nil
                // Queued after every output message, so an exit is only
                // handled once the process's last words have been read.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.noteStandardOutputEnded(processGeneration: processGeneration)
                    }
                }
                return
            }
            let parsedMessages = standardOutputLineAccumulator
                .appendBytesAndExtractCompleteLines(newlyAvailableBytes)
                .map(ClaudeCLIOutputMessage.parse(outputLine:))
            // DispatchQueue.main keeps messages in the order they arrived.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for parsedMessage in parsedMessages {
                        self?.handleOutputMessage(parsedMessage, fromProcessGeneration: processGeneration)
                    }
                }
            }
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { readableHandle in
            let newlyAvailableBytes = readableHandle.availableData
            if newlyAvailableBytes.isEmpty {
                readableHandle.readabilityHandler = nil
                return
            }
            let standardErrorText = String(decoding: newlyAvailableBytes, as: UTF8.self)
            runningClaudeProcess.appendToStandardErrorTail(standardErrorText)
            print("🧠 claude stderr: \(standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            let exitStatus = terminatedProcess.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteProcessExited(processGeneration: processGeneration, exitStatus: exitStatus)
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw ClaudeCLIBridgeError.processFailedToStart(underlyingErrorDescription: error.localizedDescription)
        }

        runningProcess = runningClaudeProcess
        print("🧠 Claude bridge: started \(selectedModel.rawValue) process (pid \(process.processIdentifier))")
        // A fresh process starts with thinking off (MAX_THINKING_TOKENS=0).
        currentThinkingBudgetTokens = 0
        onNewProcessStarted?()
    }

    private func makeCommandLineArguments() -> [String] {
        var commandLineArguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",                      // required by the CLI for stream-json output
            "--include-partial-messages",     // token-level streaming of the reply
            "--tools", "",                    // screen-only companion: no tool round-trips, no file access
            "--model", selectedModel.rawValue,
            "--permission-prompts", "none",
            // Skip loading MCP servers, settings files and plugins. Measured:
            // cuts ~27,600 startup tokens to zero and halves time to first token.
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            // Nothing is written to ~/.claude/projects. Persisted sessions store
            // every screenshot inline, forever; recovery uses our own recap instead.
            "--no-session-persistence",
            "--system-prompt", systemPromptProvider?() ?? systemPrompt
        ]
        // NEVER add --bare: it disables subscription (OAuth / keychain) login
        // entirely and requires an API key, defeating the point of this app.

        if selectedModel == .opus {
            // If Opus is overloaded, answer with Sonnet instead of failing.
            commandLineArguments.append(contentsOf: ["--fallback-model", VesperClaudeModel.sonnet.rawValue])
        }
        return commandLineArguments
    }

    /// Builds the child process environment from scratch rather than
    /// inheriting ours. USER and LOGNAME are required: without them the CLI
    /// cannot find its login in the keychain and reports "Not logged in".
    private func makeProcessEnvironment(executablePath: String) -> [String: String] {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        let executableDirectoryPath = (executablePath as NSString).deletingLastPathComponent
        let currentUserName = NSUserName()

        return [
            "PATH": [executableDirectoryPath, "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
                .joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "USER": currentUserName,
            "LOGNAME": currentUserName,
            "TMPDIR": inheritedEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
            "SHELL": inheritedEnvironment["SHELL"] ?? "/bin/zsh",
            "LANG": inheritedEnvironment["LANG"] ?? "en_US.UTF-8",
            // Sonnet 5 otherwise "thinks" adaptively before harder answers:
            // measured 3.5–4.3 s to the first word instead of ~1.2 s, with
            // answers just as correct. Off by default; switched back on per
            // turn (see thinkingBudgetTokens) for hands-on tasks and when
            // they ask her to think. (CLAUDE_CODE_DISABLE_THINKING does not
            // work for this model — measured on CLI 2.1.281.)
            "MAX_THINKING_TOKENS": "0"
        ]
    }

    /// Stops the running process. When `preservingConversationThroughRecap`
    /// is true, the next question to a new process carries a recap.
    private func terminateRunningProcess(preservingConversationThroughRecap: Bool) {
        guard let runningProcess else { return }
        self.runningProcess = nil
        // Any output still in flight from the old process is now meaningless.
        abandonedTurnResultsStillExpected = 0

        try? runningProcess.standardInputHandle.close()
        if runningProcess.process.isRunning {
            runningProcess.process.terminate()
            // A CLI stuck mid-request may ignore SIGTERM; don't leave it
            // running (and spending usage) in the background.
            let stuckProcess = runningProcess.process
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if stuckProcess.isRunning {
                    print("⚠️ Claude bridge: process ignored SIGTERM, killing it")
                    kill(stuckProcess.processIdentifier, SIGKILL)
                }
            }
        }

        if preservingConversationThroughRecap && !textOnlyConversationExchanges.isEmpty {
            shouldPrependRecapToNextTurn = true
        }
        print("🧠 Claude bridge: stopped process (recap next turn: \(shouldPrependRecapToNextTurn))")
    }

    /// The exit and the end of stdout can arrive in either order. The exit
    /// is handled once both have happened — or a moment after the exit, if
    /// stdout never reports its end — so a final "result" or error the
    /// process printed just before exiting isn't lost.
    private func noteProcessExited(processGeneration: Int, exitStatus: Int32) {
        guard let runningProcess, runningProcess.processGeneration == processGeneration else { return }
        runningProcess.exitStatus = exitStatus
        if runningProcess.hasReachedStandardOutputEnd {
            handleProcessTermination(processGeneration: processGeneration, exitStatus: exitStatus)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.handleProcessTermination(processGeneration: processGeneration, exitStatus: exitStatus)
        }
    }

    private func noteStandardOutputEnded(processGeneration: Int) {
        guard let runningProcess, runningProcess.processGeneration == processGeneration else { return }
        runningProcess.hasReachedStandardOutputEnd = true
        if let exitStatus = runningProcess.exitStatus {
            handleProcessTermination(processGeneration: processGeneration, exitStatus: exitStatus)
        }
    }

    private func handleProcessTermination(processGeneration: Int, exitStatus: Int32) {
        guard processGeneration == runningProcess?.processGeneration else { return }

        let standardErrorTail = runningProcess?.standardErrorTail ?? ""
        print("⚠️ Claude bridge: process exited unexpectedly (status \(exitStatus))")
        runningProcess = nil
        abandonedTurnResultsStillExpected = 0

        if !textOnlyConversationExchanges.isEmpty {
            shouldPrependRecapToNextTurn = true
        }

        if let activeTurn {
            self.activeTurn = nil
            if Self.looksLikeNotLoggedIn(standardErrorTail) {
                activeTurn.continuation.resume(throwing: ClaudeCLIBridgeError.notLoggedIn)
            } else {
                activeTurn.continuation.resume(
                    throwing: ClaudeCLIBridgeError.processExitedUnexpectedly(standardErrorTail: standardErrorTail)
                )
            }
        }
    }

    // MARK: - Idle Shutdown

    private func scheduleIdleShutdown() {
        cancelIdleShutdown()
        idleShutdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleShutdownDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            guard self.activeTurn == nil else { return }
            print("🧠 Claude bridge: idle for \(Int(Self.idleShutdownDelaySeconds / 60)) minutes, releasing process")
            self.terminateRunningProcess(preservingConversationThroughRecap: true)
        }
    }

    private func cancelIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
    }

    // MARK: - Writing Turns

    private func makeUserMessageLine(images: [(data: Data, label: String)], userPrompt: String) throws -> Data {
        var contentBlocks: [[String: Any]] = []

        if shouldPrependRecapToNextTurn, let recapText = makeConversationRecapText() {
            contentBlocks.append(["type": "text", "text": recapText])
        }
        shouldPrependRecapToNextTurn = false

        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": Self.detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }
        contentBlocks.append(["type": "text", "text": userPrompt])

        let userMessage: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": contentBlocks]
        ]
        var userMessageLine = try JSONSerialization.data(withJSONObject: userMessage)
        userMessageLine.append(0x0A)
        return userMessageLine
    }

    /// Writes happen on a background queue: a multi-megabyte screenshot line
    /// can take a moment to push through the pipe, and must never block the UI.
    private func writeLineToStandardInput(_ lineData: Data) {
        guard let standardInputHandle = runningProcess?.standardInputHandle else { return }
        standardInputWriteQueue.async {
            do {
                try standardInputHandle.write(contentsOf: lineData)
            } catch {
                // The process died; its termination handler reports the failure.
                print("⚠️ Claude bridge: stdin write failed: \(error.localizedDescription)")
            }
        }
    }

    private func makeConversationRecapText() -> String? {
        let oldestIncludedDate = Date().addingTimeInterval(-Self.recapMaximumExchangeAgeSeconds)
        let recentExchanges = textOnlyConversationExchanges
            .filter { $0.completedAt >= oldestIncludedDate }
            .suffix(Self.recapMaximumExchangeCount)
        guard !recentExchanges.isEmpty else { return nil }

        let recapLines = recentExchanges.map { exchange in
            "they said: \(exchange.userText)\nyou said: \(exchange.assistantSpokenText)"
        }
        return """
        (context, not a new question: this conversation was moved to a fresh session to save memory. \
        the screenshots from earlier turns are gone, but this is what was said, oldest first.)

        \(recapLines.joined(separator: "\n\n"))

        (end of earlier context. their new question follows, with a fresh screenshot.)
        """
    }

    // MARK: - Handling Output

    private func handleOutputMessage(_ outputMessage: ClaudeCLIOutputMessage, fromProcessGeneration processGeneration: Int) {
        guard processGeneration == runningProcess?.processGeneration else { return }

        switch outputMessage {
        case .responseTextDelta(let textDelta):
            guard abandonedTurnResultsStillExpected == 0, let activeTurn else { return }
            if activeTurn.firstResponseTextArrivedAt == nil {
                activeTurn.firstResponseTextArrivedAt = Date()
            }
            activeTurn.lastResponseActivityAt = Date()
            activeTurn.accumulatedResponseText += textDelta
            activeTurn.onResponseTextDelta(textDelta)

        case .responseActivityWithoutText:
            guard abandonedTurnResultsStillExpected == 0, let activeTurn else { return }
            activeTurn.lastResponseActivityAt = Date()
            activeTurn.hasShownActivityBeforeText = true

        case .subscriptionUsage(let usageSnapshot):
            latestSubscriptionUsage = usageSnapshot
            onSubscriptionUsageUpdated?(usageSnapshot)

        case .turnFinished(let finishedTurn):
            if abandonedTurnResultsStillExpected > 0 {
                abandonedTurnResultsStillExpected -= 1
                return
            }
            completeActiveTurn(with: finishedTurn)

        case .ignored:
            break
        }
    }

    private func completeActiveTurn(with finishedTurn: FinishedClaudeTurn) {
        guard let activeTurn else { return }
        self.activeTurn = nil

        let turnCompletedAt = Date()

        if finishedTurn.isError {
            let errorMessage = finishedTurn.resultText ?? "Claude returned an error."
            let bridgeError: ClaudeCLIBridgeError
            if Self.looksLikeNotLoggedIn(errorMessage) {
                bridgeError = .notLoggedIn
            } else if finishedTurn.apiErrorStatus == 429
                        || latestSubscriptionUsage?.isRequestAllowed == false
                        || errorMessage.lowercased().contains("limit") {
                bridgeError = .subscriptionRateLimited(resetsAt: latestSubscriptionUsage?.resetTimeOfFullestWindow)
            } else {
                bridgeError = .claudeReportedError(message: errorMessage)
            }
            activeTurn.continuation.resume(throwing: bridgeError)
            scheduleIdleShutdown()
            return
        }

        // Prefer the streamed text (what the UI has already seen); fall back
        // to the final result text if partial messages were not delivered.
        let fullResponseText = activeTurn.accumulatedResponseText.isEmpty
            ? (finishedTurn.resultText ?? "")
            : activeTurn.accumulatedResponseText

        let spokenReplyText = Self.shortenedForRecap(Self.removingAllTags(from: fullResponseText))
        if activeTurn.continuesPreviousExchange, let previousExchange = textOnlyConversationExchanges.last {
            // A hands-on step: keep the task's request, and let its latest
            // words ("done, it's playing") stand for how it went.
            textOnlyConversationExchanges[textOnlyConversationExchanges.count - 1] = TextOnlyConversationExchange(
                userText: previousExchange.userText,
                assistantSpokenText: spokenReplyText.isEmpty ? previousExchange.assistantSpokenText : spokenReplyText,
                completedAt: turnCompletedAt
            )
        } else {
            textOnlyConversationExchanges.append(TextOnlyConversationExchange(
                userText: Self.shortenedForRecap(activeTurn.recapUserText),
                assistantSpokenText: spokenReplyText,
                completedAt: turnCompletedAt
            ))
        }
        if textOnlyConversationExchanges.count > Self.recapMaximumExchangeCount {
            textOnlyConversationExchanges.removeFirst(textOnlyConversationExchanges.count - Self.recapMaximumExchangeCount)
        }
        saveConversation()

        let turnResult = ClaudeCLITurnResult(
            fullResponseText: fullResponseText,
            secondsUntilFirstResponseText: activeTurn.firstResponseTextArrivedAt?.timeIntervalSince(activeTurn.sentAt),
            totalTurnSeconds: turnCompletedAt.timeIntervalSince(activeTurn.sentAt),
            contextTokenCount: finishedTurn.contextTokenCount
        )
        activeTurn.continuation.resume(returning: turnResult)

        rollOverContextIfItHasGrownTooLarge(contextTokenCount: finishedTurn.contextTokenCount)
        scheduleIdleShutdown()
    }

    /// Replaces the process with a fresh one once the conversation's context
    /// is large. The replacement boots immediately, while the user is idle,
    /// so it is already warm when they next speak.
    private func rollOverContextIfItHasGrownTooLarge(contextTokenCount: Int) {
        let rolloverThreshold = isSaverModeEnabled
            ? Self.saverModeContextTokenRolloverThreshold
            : Self.standardContextTokenRolloverThreshold
        guard contextTokenCount > rolloverThreshold else { return }

        print("🧠 Claude bridge: context at \(contextTokenCount) tokens (limit \(rolloverThreshold)), rolling over to a fresh process")
        terminateRunningProcess(preservingConversationThroughRecap: true)
        prewarmProcessIfNeeded()
    }

    // MARK: - Interrupting Turns

    /// Watches one turn until it ends: gives up if no reply text arrives in
    /// time, and also if a reply that started goes silent midway (the
    /// network stalls) — otherwise that turn, and the UI waiting on it,
    /// would hang forever.
    private func scheduleFirstResponseTextTimeout(forTurnIdentifier turnIdentifier: UUID) {
        Task { [weak self] in
            // The first check lands exactly at the no-reply timeout, then
            // every couple of seconds for a stall.
            try? await Task.sleep(for: .seconds(Self.firstResponseTextTimeoutSeconds))
            while true {
                guard let self,
                      let activeTurn = self.activeTurn,
                      activeTurn.turnIdentifier == turnIdentifier else { return }
                // Thinking counts as life: only a turn with no activity at all
                // hits the first-reply timeout; a long think is judged by the
                // stall rule below instead.
                if activeTurn.firstResponseTextArrivedAt == nil && !activeTurn.hasShownActivityBeforeText {
                    print("⚠️ Claude bridge: no reply after \(Int(Self.firstResponseTextTimeoutSeconds))s, giving up on this turn")
                    self.abandonTurnAndReplaceProcess(turnIdentifier: turnIdentifier)
                    return
                }
                if Date().timeIntervalSince(activeTurn.lastResponseActivityAt) > Self.midReplyStallTimeoutSeconds {
                    print("⚠️ Claude bridge: reply stalled for \(Int(Self.midReplyStallTimeoutSeconds))s, giving up on this turn")
                    self.abandonTurnAndReplaceProcess(turnIdentifier: turnIdentifier)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Tells the running process to think (or not) from the next turn on,
    /// through the same stdin queue, so it lands before the user line.
    /// Measured: the CLI acks it and the very next turn follows it.
    private func setThinkingBudgetIfNeeded(_ thinkingBudgetTokens: Int) {
        guard thinkingBudgetTokens != currentThinkingBudgetTokens else { return }
        let thinkingRequest: [String: Any] = [
            "type": "control_request",
            "request_id": "vesper-thinking-\(UUID().uuidString)",
            "request": ["subtype": "set_max_thinking_tokens", "max_thinking_tokens": thinkingBudgetTokens]
        ]
        guard var thinkingRequestLine = try? JSONSerialization.data(withJSONObject: thinkingRequest) else { return }
        thinkingRequestLine.append(0x0A)
        writeLineToStandardInput(thinkingRequestLine)
        currentThinkingBudgetTokens = thinkingBudgetTokens
        print("🧠 Thinking \(thinkingBudgetTokens > 0 ? "on" : "off") from this turn")
    }

    /// A turn that timed out: the process may be stuck, or may never send
    /// that turn's result — and while a result is still expected, every
    /// later reply's text is dropped. So rather than trust it, replace the
    /// process; the next question carries a recap and nothing is lost.
    private func abandonTurnAndReplaceProcess(turnIdentifier: UUID) {
        guard let activeTurn, activeTurn.turnIdentifier == turnIdentifier else { return }
        self.activeTurn = nil
        terminateRunningProcess(preservingConversationThroughRecap: true)
        activeTurn.continuation.resume(throwing: ClaudeCLIBridgeError.noResponseBeforeTimeout)
    }

    private func interruptActiveTurnIfAny() {
        guard let activeTurn else { return }
        abandonTurn(turnIdentifier: activeTurn.turnIdentifier, failWith: CancellationError())
    }

    /// Gives up on a turn: tells the CLI to stop generating (so it stops
    /// spending subscription usage), fails the waiting caller, and marks the
    /// turn's eventual `result` message to be ignored when it arrives.
    private func abandonTurn(turnIdentifier: UUID, failWith abandonmentError: Error) {
        guard let activeTurn, activeTurn.turnIdentifier == turnIdentifier else { return }
        self.activeTurn = nil
        abandonedTurnResultsStillExpected += 1

        let interruptRequest: [String: Any] = [
            "type": "control_request",
            "request_id": "vesper-interrupt-\(turnIdentifier.uuidString)",
            "request": ["subtype": "interrupt"]
        ]
        if var interruptRequestLine = try? JSONSerialization.data(withJSONObject: interruptRequest) {
            interruptRequestLine.append(0x0A)
            writeLineToStandardInput(interruptRequestLine)
        }

        activeTurn.continuation.resume(throwing: abandonmentError)
    }

    // MARK: - Helpers

    private static func looksLikeNotLoggedIn(_ text: String) -> Bool {
        let lowercasedText = text.lowercased()
        return lowercasedText.contains("not logged in") || lowercasedText.contains("/login")
    }

    /// Screen captures are JPEG; clipboard images can be PNG. The API rejects
    /// requests whose declared media type doesn't match the actual bytes.
    private static func detectImageMediaType(for imageData: Data) -> String {
        let pngSignaturePrefix: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.count >= 4 && [UInt8](imageData.prefix(4)) == pngSignaturePrefix {
            return "image/png"
        }
        return "image/jpeg"
    }

    /// Every action tag, not only points: a recap full of old
    /// [CLICK:x,y] coordinates could get reused on a screen that moved on.
    static func removingAllTags(from responseText: String) -> String {
        responseText
            // Any all-caps tag, so tags added later (REMIND, SHORTCUT, …)
            // can't leak into a recap and be repeated by Claude.
            .replacingOccurrences(
                of: #"\[[A-Z]{2,14}(:[^\]]*)?\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each side of a recap exchange is capped, so a long answer or a long
    /// dictated message can't make the recap itself expensive.
    private static let recapMaximumCharactersPerSide = 500

    static func shortenedForRecap(_ text: String) -> String {
        text.count > recapMaximumCharactersPerSide
            ? String(text.prefix(recapMaximumCharactersPerSide)) + "…"
            : text
    }
}

// MARK: - Supporting Types

/// The turn currently waiting for a reply. A class so its streaming state
/// can be updated in place as text arrives.
private final class ActiveClaudeTurn {
    let turnIdentifier: UUID
    let userPrompt: String
    let recapUserText: String
    let continuesPreviousExchange: Bool
    let continuation: CheckedContinuation<ClaudeCLITurnResult, Error>
    let onResponseTextDelta: (String) -> Void
    let sentAt: Date
    var firstResponseTextArrivedAt: Date?
    /// Last time reply text arrived; a long silence after the first text
    /// means the reply stalled.
    lazy var lastResponseActivityAt: Date = sentAt
    /// Thinking started streaming before any text.
    var hasShownActivityBeforeText = false
    var accumulatedResponseText = ""

    init(
        turnIdentifier: UUID,
        userPrompt: String,
        recapUserText: String,
        continuesPreviousExchange: Bool,
        continuation: CheckedContinuation<ClaudeCLITurnResult, Error>,
        onResponseTextDelta: @escaping (String) -> Void,
        sentAt: Date
    ) {
        self.turnIdentifier = turnIdentifier
        self.userPrompt = userPrompt
        self.recapUserText = recapUserText
        self.continuesPreviousExchange = continuesPreviousExchange
        self.continuation = continuation
        self.onResponseTextDelta = onResponseTextDelta
        self.sentAt = sentAt
    }
}

private struct TextOnlyConversationExchange: Codable {
    let userText: String
    let assistantSpokenText: String
    let completedAt: Date
}

/// A running CLI process plus the bits needed to talk to it. The stderr tail
/// is written from a background pipe reader, so it is guarded by a lock.
nonisolated private final class RunningClaudeCLIProcess: @unchecked Sendable {
    private static let standardErrorTailMaximumCharacters = 2_000

    let process: Process
    let standardInputHandle: FileHandle
    let processGeneration: Int
    /// Main-actor only: when the process exited, and whether its stdout has
    /// been read to the end.
    var exitStatus: Int32?
    var hasReachedStandardOutputEnd = false
    private var standardErrorTailStorage = ""
    private let standardErrorTailLock = NSLock()

    init(process: Process, standardInputHandle: FileHandle, processGeneration: Int) {
        self.process = process
        self.standardInputHandle = standardInputHandle
        self.processGeneration = processGeneration
    }

    var standardErrorTail: String {
        standardErrorTailLock.lock()
        defer { standardErrorTailLock.unlock() }
        return standardErrorTailStorage
    }

    func appendToStandardErrorTail(_ standardErrorText: String) {
        standardErrorTailLock.lock()
        defer { standardErrorTailLock.unlock() }
        standardErrorTailStorage += standardErrorText
        if standardErrorTailStorage.count > Self.standardErrorTailMaximumCharacters {
            standardErrorTailStorage = String(standardErrorTailStorage.suffix(Self.standardErrorTailMaximumCharacters))
        }
    }
}

/// Splits a byte stream into newline-delimited lines. The CLI writes one JSON
/// object per line, but pipe reads arrive in arbitrary chunks, so one read
/// can hold half a line or several lines at once.
nonisolated private final class NewlineDelimitedLineAccumulator: @unchecked Sendable {
    private var bufferedBytesWithoutNewline = Data()
    private let bufferLock = NSLock()

    func appendBytesAndExtractCompleteLines(_ newlyAvailableBytes: Data) -> [Data] {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        bufferedBytesWithoutNewline.append(newlyAvailableBytes)
        var completeLines: [Data] = []
        while let newlineIndex = bufferedBytesWithoutNewline.firstIndex(of: 0x0A) {
            completeLines.append(Data(bufferedBytesWithoutNewline[bufferedBytesWithoutNewline.startIndex..<newlineIndex]))
            bufferedBytesWithoutNewline.removeSubrange(bufferedBytesWithoutNewline.startIndex...newlineIndex)
        }
        return completeLines
    }
}

/// What a finished turn's `result` message tells us.
nonisolated private struct FinishedClaudeTurn: Sendable {
    let isError: Bool
    let resultText: String?
    let apiErrorStatus: Int?
    let contextTokenCount: Int
}

/// The stdout messages the bridge cares about. Everything else the CLI emits
/// (`system` init — re-sent every turn, `assistant` snapshots, control
/// acknowledgements) is ignored.
nonisolated private enum ClaudeCLIOutputMessage: Sendable {
    case responseTextDelta(String)
    /// Thinking (or another non-text block) is streaming: no words yet, but
    /// the turn is alive and mustn't be timed out as silent.
    case responseActivityWithoutText
    case subscriptionUsage(ClaudeSubscriptionUsageSnapshot)
    case turnFinished(FinishedClaudeTurn)
    case ignored

    static func parse(outputLine: Data) -> ClaudeCLIOutputMessage {
        guard let outputObject = try? JSONSerialization.jsonObject(with: outputLine) as? [String: Any],
              let messageType = outputObject["type"] as? String else {
            return .ignored
        }

        switch messageType {
        case "stream_event":
            // Diagnostics: when each part of the reply starts. A long gap
            // between "thinking" and "text" is time spent reasoning.
            if let streamEvent = outputObject["event"] as? [String: Any],
               streamEvent["type"] as? String == "content_block_start",
               let contentBlock = streamEvent["content_block"] as? [String: Any],
               let contentBlockType = contentBlock["type"] as? String {
                print("⏱️ \(VesperTimingLog.stamp()) claude started a \(contentBlockType) block")
                return contentBlockType == "text" ? .ignored : .responseActivityWithoutText
            }
            guard let streamEvent = outputObject["event"] as? [String: Any],
                  streamEvent["type"] as? String == "content_block_delta",
                  let delta = streamEvent["delta"] as? [String: Any] else {
                return .ignored
            }
            guard delta["type"] as? String == "text_delta", let textDelta = delta["text"] as? String else {
                // Thinking in progress: not text yet, but the turn is alive.
                return .responseActivityWithoutText
            }
            return .responseTextDelta(textDelta)

        case "rate_limit_event":
            guard let rateLimitInfo = outputObject["rate_limit_info"] as? [String: Any] else {
                return .ignored
            }
            return .subscriptionUsage(parseSubscriptionUsage(from: rateLimitInfo))

        case "result":
            let usage = outputObject["usage"] as? [String: Any] ?? [:]
            let uncachedInputTokenCount = usage["input_tokens"] as? Int ?? 0
            let cacheReadTokenCount = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreationTokenCount = usage["cache_creation_input_tokens"] as? Int ?? 0
            let contextTokenCount = uncachedInputTokenCount + cacheReadTokenCount + cacheCreationTokenCount
            // Separated so a slow first question can be traced to a cold
            // prompt cache (large "written") versus the CLI starting up.
            let outputTokenCount = usage["output_tokens"] as? Int ?? 0
            print("🧠 Tokens — fresh \(uncachedInputTokenCount), cache read \(cacheReadTokenCount), cache written \(cacheCreationTokenCount), output \(outputTokenCount)")
            return .turnFinished(FinishedClaudeTurn(
                isError: outputObject["is_error"] as? Bool ?? false,
                resultText: outputObject["result"] as? String,
                apiErrorStatus: outputObject["api_error_status"] as? Int,
                contextTokenCount: contextTokenCount
            ))

        default:
            return .ignored
        }
    }

    private static func parseSubscriptionUsage(from rateLimitInfo: [String: Any]) -> ClaudeSubscriptionUsageSnapshot {
        let usageWindows = rateLimitInfo["unifiedWindows"] as? [String: Any] ?? [:]
        let fiveHourWindow = usageWindows["five_hour"] as? [String: Any]
        let sevenDayWindow = usageWindows["seven_day"] as? [String: Any]

        func dateFromEpochSeconds(_ rawValue: Any?) -> Date? {
            guard let epochSeconds = (rawValue as? NSNumber)?.doubleValue else { return nil }
            return Date(timeIntervalSince1970: epochSeconds)
        }

        return ClaudeSubscriptionUsageSnapshot(
            rateLimitStatus: rateLimitInfo["status"] as? String ?? "allowed",
            fiveHourWindowUtilization: (fiveHourWindow?["utilization"] as? NSNumber)?.doubleValue,
            fiveHourWindowResetsAt: dateFromEpochSeconds(fiveHourWindow?["resetsAt"]),
            sevenDayWindowUtilization: (sevenDayWindow?["utilization"] as? NSNumber)?.doubleValue,
            sevenDayWindowResetsAt: dateFromEpochSeconds(sevenDayWindow?["resetsAt"]),
            limitingWindowResetsAt: dateFromEpochSeconds(rateLimitInfo["resetsAt"])
        )
    }
}
