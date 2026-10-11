//
//  main.swift — test driver for ClaudeCodeCLIBridge
//
//  Runs the real bridge code against fake-claude-cli.py and checks the hard
//  cases: streaming, barge-in, crashes, stalls, usage limits, logout,
//  context rollover with recap, model switching and new conversations.
//  Built and run by scripts/test-claude-bridge.sh.
//

import Foundation

let fakeClaudeExecutablePath = CommandLine.arguments[1]
let fakeClaudeLogPath = CommandLine.arguments[2]

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

/// Every launch and received message the fake CLI has logged so far.
func readFakeClaudeLog() -> [[String: Any]] {
    guard let logText = try? String(contentsOfFile: fakeClaudeLogPath, encoding: .utf8) else { return [] }
    return logText.split(separator: "\n").compactMap { logLine in
        (try? JSONSerialization.jsonObject(with: Data(logLine.utf8))) as? [String: Any]
    }
}

func loggedEvents(named eventName: String) -> [[String: Any]] {
    readFakeClaudeLog().filter { $0["event"] as? String == eventName }
}

func lastUserMessageText() -> String {
    loggedEvents(named: "user").last?["text"] as? String ?? ""
}

func makeBridge(model: VesperClaudeModel = .sonnet) -> ClaudeCodeCLIBridge {
    ClaudeCodeCLIBridge(
        systemPrompt: "test system prompt",
        selectedModel: model,
        claudeExecutablePathOverride: fakeClaudeExecutablePath
    )
}

let recapMarker = "context, not a new question"

func runAllChecks() async {
    let bridge = makeBridge()
    var latestUsageSnapshot: ClaudeSubscriptionUsageSnapshot?
    bridge.onSubscriptionUsageUpdated = { latestUsageSnapshot = $0 }

    // 1. A normal turn: streamed text, usage, flags, environment.
    print("\n— normal turn")
    do {
        var receivedTextDeltas: [String] = []
        let turnResult = try await bridge.sendTurn(
            images: [(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), label: "screen 1 (image dimensions: 4x4 pixels)")],
            userPrompt: "hello there",
            onResponseTextDelta: { receivedTextDeltas.append($0) }
        )
        check(turnResult.fullResponseText.contains("you asked: hello there"), "reply text arrives", turnResult.fullResponseText)
        check(receivedTextDeltas.count > 3 && receivedTextDeltas.joined() == turnResult.fullResponseText,
              "reply streams in pieces, and the pieces add up to the reply", "\(receivedTextDeltas.count) pieces")
        check(turnResult.secondsUntilFirstResponseText != nil, "time to first text is measured")
        check(latestUsageSnapshot?.fiveHourWindowUtilization == 0.42 && latestUsageSnapshot?.isRequestAllowed == true,
              "subscription usage is parsed")

        let startEvent = loggedEvents(named: "start").last ?? [:]
        let commandLineArguments = startEvent["args"] as? [String] ?? []
        check(commandLineArguments.contains("--no-session-persistence") && !commandLineArguments.contains("--bare"),
              "flags: --no-session-persistence present, --bare absent")
        check(commandLineArguments.contains("--tools") && commandLineArguments[commandLineArguments.firstIndex(of: "--tools")! + 1] == "",
              "flags: tools disabled with an empty --tools value")
        check(startEvent["user"] as? String == NSUserName() && startEvent["logname"] as? String == NSUserName(),
              "environment: USER and LOGNAME set (needed for keychain login)")
        let environmentKeys = startEvent["environment_keys"] as? [String] ?? []
        check(!environmentKeys.contains { $0.hasPrefix("CLAUDE") }, "environment: nothing inherited from a parent Claude session",
              environmentKeys.joined(separator: " "))
        check((startEvent["cwd"] as? String ?? "").hasSuffix("Vesper/session"), "working directory is the empty session folder")
        check(loggedEvents(named: "user").last?["image_count"] as? Int == 1, "the screenshot is sent as an image block")
    } catch {
        check(false, "normal turn", "\(error)")
    }

    // 2. Barge-in: interrupting mid-answer, then asking again.
    print("\n— barge-in")
    do {
        var staleTextDeltaCount = 0
        let interruptedTurnTask = Task {
            try await bridge.sendTurn(images: [], userPrompt: "SLOW please", onResponseTextDelta: { _ in staleTextDeltaCount += 1 })
        }
        try await Task.sleep(for: .milliseconds(500))
        let staleTextDeltaCountAtInterrupt = staleTextDeltaCount
        // Exactly what CompanionManager does on a hotkey press.
        bridge.interruptActiveTurn()
        interruptedTurnTask.cancel()

        let interruptedTurnOutcome = await interruptedTurnTask.result
        if case .failure(let interruptionError) = interruptedTurnOutcome {
            check(interruptionError is CancellationError, "the interrupted turn ends with a cancellation")
        } else {
            check(false, "the interrupted turn ends with a cancellation", "it completed instead")
        }
        check(staleTextDeltaCountAtInterrupt > 0, "the slow reply had started streaming before the interrupt")

        var nextTurnTextDeltas: [String] = []
        let nextTurnResult = try await bridge.sendTurn(images: [], userPrompt: "second question", onResponseTextDelta: { nextTurnTextDeltas.append($0) })
        check(nextTurnResult.fullResponseText.contains("second question") && !nextTurnTextDeltas.joined().contains("stale"),
              "the next answer is the right one, with no stale text mixed in", nextTurnResult.fullResponseText)
        check(staleTextDeltaCount == staleTextDeltaCountAtInterrupt,
              "no text from the interrupted answer arrives after the interrupt",
              "\(staleTextDeltaCount - staleTextDeltaCountAtInterrupt) stale pieces")
        check(!loggedEvents(named: "interrupt").isEmpty, "the CLI was told to stop generating")
    } catch {
        check(false, "barge-in", "\(error)")
    }

    // 3. The CLI crashes mid-answer; the next question recovers with a recap.
    print("\n— crash recovery")
    let processCountBeforeCrash = loggedEvents(named: "start").count
    do {
        _ = try await bridge.sendTurn(images: [], userPrompt: "CRASH now", onResponseTextDelta: { _ in })
        check(false, "a crash is reported as an error", "the turn succeeded")
    } catch ClaudeCLIBridgeError.processExitedUnexpectedly(let standardErrorTail) {
        check(standardErrorTail.contains("fake crash"), "a crash is reported, with the CLI's error output", standardErrorTail.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        check(false, "a crash is reported as processExitedUnexpectedly", "\(error)")
    }
    do {
        let recoveredTurnResult = try await bridge.sendTurn(images: [], userPrompt: "after the crash", onResponseTextDelta: { _ in })
        check(recoveredTurnResult.fullResponseText.contains("after the crash"), "the next question gets an answer")
        check(loggedEvents(named: "start").count == processCountBeforeCrash + 1, "a fresh CLI process was started")
        let recoveredUserText = lastUserMessageText()
        check(recoveredUserText.contains(recapMarker) && recoveredUserText.contains("hello there"),
              "the fresh process gets a text recap of the earlier conversation")
    } catch {
        check(false, "recovery after a crash", "\(error)")
    }

    // 4. Usage limit reached.
    print("\n— usage limit")
    do {
        _ = try await bridge.sendTurn(images: [], userPrompt: "LIMITED", onResponseTextDelta: { _ in })
        check(false, "a usage limit is reported", "the turn succeeded")
    } catch ClaudeCLIBridgeError.subscriptionRateLimited(let resetTime) {
        check(resetTime != nil && resetTime! > Date(), "a usage limit is reported with its reset time")
        check(bridge.latestSubscriptionUsage?.isRequestAllowed == false, "usage shows requests are being refused")
    } catch {
        check(false, "a usage limit is reported as subscriptionRateLimited", "\(error)")
    }

    // 5. Logged out.
    print("\n— logged out")
    do {
        _ = try await bridge.sendTurn(images: [], userPrompt: "LOGGEDOUT", onResponseTextDelta: { _ in })
        check(false, "logged out is reported", "the turn succeeded")
    } catch ClaudeCLIBridgeError.notLoggedIn {
        check(true, "logged out is reported as notLoggedIn")
    } catch {
        check(false, "logged out is reported as notLoggedIn", "\(error)")
    }

    // 6. Context grows too large: roll over to a warm fresh process.
    print("\n— context rollover")
    do {
        let processCountBeforeRollover = loggedEvents(named: "start").count
        _ = try await bridge.sendTurn(images: [], userPrompt: "BIG context", onResponseTextDelta: { _ in })
        try await Task.sleep(for: .milliseconds(800))
        check(loggedEvents(named: "start").count == processCountBeforeRollover + 1,
              "a replacement process is started right away, before the next question")
        _ = try await bridge.sendTurn(images: [], userPrompt: "after rollover", onResponseTextDelta: { _ in })
        check(lastUserMessageText().contains(recapMarker), "the first question after rollover carries the recap")
        _ = try await bridge.sendTurn(images: [], userPrompt: "one more", onResponseTextDelta: { _ in })
        check(!lastUserMessageText().contains(recapMarker), "the recap is sent only once")
    } catch {
        check(false, "context rollover", "\(error)")
    }

    // 7. Switching to Opus.
    print("\n— model switch")
    do {
        bridge.switchModel(to: .opus)
        _ = try await bridge.sendTurn(images: [], userPrompt: "on opus now", onResponseTextDelta: { _ in })
        let commandLineArguments = loggedEvents(named: "start").last?["args"] as? [String] ?? []
        let modelIndex = commandLineArguments.firstIndex(of: "--model")
        let fallbackIndex = commandLineArguments.firstIndex(of: "--fallback-model")
        check(modelIndex.map { commandLineArguments[$0 + 1] } == "opus" && fallbackIndex.map { commandLineArguments[$0 + 1] } == "sonnet",
              "the new process runs Opus with Sonnet as fallback")
        check(lastUserMessageText().contains(recapMarker), "the conversation carries over to the new model")
    } catch {
        check(false, "model switch", "\(error)")
    }

    // 8. New conversation forgets everything.
    print("\n— new conversation")
    do {
        bridge.startNewConversation()
        _ = try await bridge.sendTurn(images: [], userPrompt: "fresh start", onResponseTextDelta: { _ in })
        check(!lastUserMessageText().contains(recapMarker), "a new conversation starts without a recap")
    } catch {
        check(false, "new conversation", "\(error)")
    }

    // 8b. The recap holds the user's own words, one entry per hands-on task, no tags.
    print("\n— clean recap")
    do {
        bridge.startNewConversation()
        _ = try await bridge.sendTurn(
            images: [], userPrompt: "(control: hands-on. every tag works.)\nplay some lofi",
            recapUserText: "play some lofi", onResponseTextDelta: { _ in })
        _ = try await bridge.sendTurn(
            images: [], userPrompt: "(hands-on task, step 2 of at most 30. the task: \"play some lofi\".) look again",
            continuesPreviousExchange: true, onResponseTextDelta: { _ in })
        _ = try await bridge.sendTurn(images: [], userPrompt: "BIG context", recapUserText: "a big question", onResponseTextDelta: { _ in })
        _ = try await bridge.sendTurn(images: [], userPrompt: "after the recap", onResponseTextDelta: { _ in })
        let recapText = lastUserMessageText()
        check(recapText.contains("they said: play some lofi"), "the recap has the user's words, not the whole prompt", recapText)
        check(!recapText.contains("(control:") && !recapText.contains("they said: (hands-on task"), "no control lines or step prompts in the recap")
        check(recapText.components(separatedBy: "they said:").count - 1 == 2, "a hands-on task is one entry, not one per step")
        check(!recapText.contains("[POINT"), "no tags in the recap")
    } catch {
        check(false, "clean recap", "\(error)")
    }

    // 8c. Thinking: off by default (environment), switched on only when asked, and only when it changes.
    print("\n— thinking control")
    let interruptCountBeforeThinking = loggedEvents(named: "interrupt").count
    do {
        bridge.startNewConversation()
        _ = try await bridge.sendTurn(images: [], userPrompt: "quick one", onResponseTextDelta: { _ in })
        let startEnvironmentKeys = loggedEvents(named: "start").last?["environment_keys"] as? [String] ?? []
        check(startEnvironmentKeys.contains("MAX_THINKING_TOKENS"), "the CLI starts with thinking off (MAX_THINKING_TOKENS)")
        check(loggedEvents(named: "thinking").isEmpty, "an ordinary turn sends no thinking switch")
        let deepTurn = try await bridge.sendTurn(images: [], userPrompt: "think it through", wantsDeepThinking: true, onResponseTextDelta: { _ in })
        check(deepTurn.fullResponseText.contains("think it through"), "a deep turn still answers normally")
        check((loggedEvents(named: "thinking").last?["max_thinking_tokens"] as? Int ?? 0) > 0, "a deep turn switches thinking on first")
        _ = try await bridge.sendTurn(images: [], userPrompt: "another deep one", wantsDeepThinking: true, onResponseTextDelta: { _ in })
        check(loggedEvents(named: "thinking").count == 1, "staying deep doesn't resend the switch")
        _ = try await bridge.sendTurn(images: [], userPrompt: "back to quick", onResponseTextDelta: { _ in })
        check(loggedEvents(named: "thinking").last?["max_thinking_tokens"] as? Int == 0, "the next ordinary turn switches it off again")
        check(loggedEvents(named: "interrupt").count == interruptCountBeforeThinking, "a thinking switch is never mistaken for an interrupt")
    } catch {
        check(false, "thinking control", "\(error)")
    }

    // 9. No reply at all: give up after the timeout, then keep working.
    print("\n— stalled reply (waits for the 25s timeout)")
    do {
        let stallStartedAt = Date()
        _ = try await bridge.sendTurn(images: [], userPrompt: "STALL", onResponseTextDelta: { _ in })
        check(false, "a stalled reply times out", "the turn succeeded")
        _ = stallStartedAt
    } catch ClaudeCLIBridgeError.noResponseBeforeTimeout {
        check(true, "a stalled reply times out instead of hanging")
    } catch {
        check(false, "a stalled reply times out", "\(error)")
    }
    do {
        let afterStallResult = try await bridge.sendTurn(images: [], userPrompt: "after the stall", onResponseTextDelta: { _ in })
        check(afterStallResult.fullResponseText.contains("after the stall"),
              "the next question still works, and the stalled turn's late result is ignored", afterStallResult.fullResponseText)
    } catch {
        check(false, "a question after a stall", "\(error)")
    }

    // 10. A turn whose process never answers, not even the interrupt (so
    // its result never comes): she must not drop every later reply.
    print("\n— wedged process (waits for the 25s timeout)")
    let wedgedProcessIdentifier = (loggedEvents(named: "start").last?["pid"] as? Int).map { pid_t($0) }
    do {
        _ = try await bridge.sendTurn(images: [], userPrompt: "WEDGED", onResponseTextDelta: { _ in })
        check(false, "a wedged turn times out", "the turn succeeded")
    } catch ClaudeCLIBridgeError.noResponseBeforeTimeout {
        check(true, "a wedged turn times out")
    } catch {
        check(false, "a wedged turn times out", "\(error)")
    }
    do {
        let processCountBeforeRecovery = loggedEvents(named: "start").count
        let afterWedgeResult = try await bridge.sendTurn(images: [], userPrompt: "after the wedge", onResponseTextDelta: { _ in })
        check(afterWedgeResult.fullResponseText.contains("after the wedge"), "the next question is answered, not silently dropped", afterWedgeResult.fullResponseText)
        check(loggedEvents(named: "start").count == processCountBeforeRecovery + 1, "by a fresh process that replaced the wedged one")
        check(lastUserMessageText().contains(recapMarker), "and the conversation carries over through the recap")
    } catch {
        check(false, "a question after a wedged process", "\(error)")
    }
    // The wedged process ignores SIGTERM; the bridge kills it 2 s later.
    try? await Task.sleep(for: .seconds(2.5))
    if let wedgedProcessIdentifier {
        check(kill(wedgedProcessIdentifier, 0) != 0, "a process that ignores SIGTERM is killed, not left running")
    } else {
        check(false, "the wedged process's pid was logged")
    }

    bridge.shutDown()
}

Task { @MainActor in
    await runAllChecks()
    print(failedCheckCount == 0 ? "\n✅ all bridge checks passed" : "\n❌ \(failedCheckCount) bridge check(s) failed")
    exit(failedCheckCount == 0 ? 0 : 1)
}
dispatchMain()
