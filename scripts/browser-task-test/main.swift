import Foundation

// Tests VesperBrowserTask.swift: the stream rules, the command line and the
// real runner against a fake `claude --chrome`.
// Arguments: <fake claude path> <fake log path> <scratch working directory>

var failureCount = 0

func check(_ condition: Bool, _ testName: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("✅ \(testName)")
    } else {
        failureCount += 1
        print("❌ \(testName)\(detail().isEmpty ? "" : "\n   " + detail())")
    }
}

let fakeClaudePath = CommandLine.arguments[1]
let fakeLogPath = CommandLine.arguments[2]
let scratchWorkingDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[3])

// MARK: - Mail and activity text

check(VesperBrowserTaskRunner.isAboutMail("check my email"), "mail: 'email' is refused")
check(VesperBrowserTaskRunner.isAboutMail("open Gmail and archive"), "mail: 'gmail' is refused")
check(VesperBrowserTaskRunner.isAboutMail("clear my inbox"), "mail: 'inbox' is refused")
check(!VesperBrowserTaskRunner.isAboutMail("play lofi on youtube"), "mail: an ordinary task runs")
check(!VesperBrowserTaskRunner.isAboutMail("find mailchimp pricing"), "mail: 'mailchimp' isn't mail")
check(VesperBrowserTaskStreamMonitor.activityText(forToolNamed: "navigate", input: ["url": "https://www.youtube.com/x"]) == "opening youtube.com", "activity: navigate names the site")
check(VesperBrowserTaskStreamMonitor.activityText(forToolNamed: "computer", input: ["action": "left_click"]) == "clicking", "activity: a click")
check(VesperBrowserTaskStreamMonitor.cleanedSummary("**Done**\n\n[x] ok") == "Done (x) ok", "summary: markdown, brackets and line breaks removed")

// MARK: - Command line

let commandLineArguments = VesperBrowserTaskRunner.commandLineArguments(task: "-rf play")
func argumentValue(after flag: String) -> String? {
    guard let flagIndex = commandLineArguments.firstIndex(of: flag), flagIndex + 1 < commandLineArguments.count else { return nil }
    return commandLineArguments[flagIndex + 1]
}
check(!commandLineArguments.contains("--bare"), "flags: never --bare")
check(commandLineArguments.contains("--chrome"), "flags: --chrome")
check(argumentValue(after: "--permission-mode") == "dontAsk", "flags: dontAsk")
let allowedTools = Set((argumentValue(after: "--allowedTools") ?? "").split(separator: ",").map(String.init))
check(allowedTools.contains("ToolSearch") && allowedTools.contains("mcp__claude-in-chrome__navigate"), "flags: ToolSearch and browser tools allowed")
check(!allowedTools.contains("mcp__claude-in-chrome__javascript_tool") && !allowedTools.contains("mcp__claude-in-chrome__file_upload"), "flags: no javascript or uploads")
check(commandLineArguments.contains("--strict-mcp-config") && argumentValue(after: "--setting-sources") == "" && commandLineArguments.contains("--no-session-persistence"), "flags: no MCP config, settings or sessions")
check(argumentValue(after: "-p")?.hasPrefix("task: -rf play") == true, "flags: the task can't be read as a flag")

// MARK: - The runner against the fake CLI

func loggedLaunches() -> [[String: Any]] {
    guard let logText = try? String(contentsOfFile: fakeLogPath, encoding: .utf8) else { return [] }
    return logText.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

func lastLaunchedProcessIdentifier() -> Int32? {
    (loggedLaunches().last?["pid"] as? Int).map { Int32($0) }
}

func isProcessAlive(_ processIdentifier: Int32) -> Bool {
    kill(processIdentifier, 0) == 0
}

final class ActivityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    func add(_ activityText: String) { lock.lock(); collected.append(activityText); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return collected }
}

func runFake(_ task: String, timeLimitSeconds: TimeInterval = 5, activityCollector: ActivityCollector = ActivityCollector()) async -> (VesperBrowserTaskOutcome, Double) {
    let runner = VesperBrowserTaskRunner(
        executablePathOverride: fakeClaudePath,
        workingDirectoryURL: scratchWorkingDirectoryURL,
        overallTimeLimitSeconds: timeLimitSeconds
    )
    let startedAt = Date()
    let outcome = await runner.run(task: task) { activityText in activityCollector.add(activityText) }
    return (outcome, Date().timeIntervalSince(startedAt))
}

func failure(of outcome: VesperBrowserTaskOutcome) -> VesperBrowserTaskFailure? {
    if case .failed(let failure, _, _) = outcome { return failure }
    return nil
}

do {
    let activityCollector = ActivityCollector()
    let (outcome, _) = await runFake("PLAY lofi", activityCollector: activityCollector)
    if case .finished(let summary, _, let toolCallCount) = outcome {
        check(summary == "Playing lofi hip hop radio. It's in the (Vesper) tab group.", "run: the summary is cleaned", summary)
        check(toolCallCount == 4, "run: counts browser tool calls, not ToolSearch", "\(toolCallCount)")
    } else {
        check(false, "run: a task finishes", "\(outcome)")
    }
    check(activityCollector.all == ["checking the tabs", "opening youtube.com", "reading the page", "clicking"], "run: activity for the island", "\(activityCollector.all)")
    if let launch = loggedLaunches().last {
        let launchEnvironment = launch["env"] as? [String: String] ?? [:]
        check(launchEnvironment["MAX_THINKING_TOKENS"] == "0" && launchEnvironment["USER"] == NSUserName(), "env: thinking off, USER set")
        check(launch["stdin_is_tty"] as? Bool == false, "run: stdin is not a terminal")
        let launchDirectory = (launch["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        check(launchDirectory == scratchWorkingDirectoryURL.resolvingSymlinksInPath().path, "run: in its own working directory")
    }
}

do {
    let (outcome, elapsedSeconds) = await runFake("JS q")
    check(failure(of: outcome) == .usedUnexpectedTool("mcp__claude-in-chrome__javascript_tool") && elapsedSeconds < 2, "run: javascript kills it at once", "\(outcome)")
}

do {
    let (outcome, elapsedSeconds) = await runFake("BASH q")
    check(failure(of: outcome) == .usedUnexpectedTool("Bash") && elapsedSeconds < 2, "run: any non-browser tool kills it", "\(outcome)")
    let processIdentifier = lastLaunchedProcessIdentifier()
    try? await Task.sleep(for: .milliseconds(500))
    check(processIdentifier.map { !isProcessAlive($0) } == true, "run: the process is gone")
}

do {
    let (outcome, _) = await runFake("MAIL q")
    check(failure(of: outcome) == .triedToOpenMail("mail.google.com"), "run: opening mail kills it", "\(outcome)")
}

do {
    let (outcome, _) = await runFake("MANY q")
    check(failure(of: outcome) == .tooManyToolCalls, "run: the 41st tool call kills it", "\(outcome)")
}

do {
    let (outcome, _) = await runFake("STUBBORN q")
    check(failure(of: outcome) == .usedUnexpectedTool("Bash"), "run: a process ignoring SIGTERM is stopped too")
    let processIdentifier = lastLaunchedProcessIdentifier()
    try? await Task.sleep(for: .milliseconds(2800))
    check(processIdentifier.map { !isProcessAlive($0) } == true, "run: ...and SIGKILLed")
}

do {
    let (outcome, elapsedSeconds) = await runFake("HANG q", timeLimitSeconds: 1.5)
    check(failure(of: outcome) == .timedOut && elapsedSeconds >= 1.4 && elapsedSeconds < 3, "run: the time limit stops it", "\(outcome) after \(elapsedSeconds)s")
}

do {
    let (outcome, _) = await runFake("CRASH q")
    check(failure(of: outcome) == .finishedWithoutResult, "run: a crash is a failure", "\(outcome)")
}

do {
    let (outcome, _) = await runFake("ERROR q")
    check(failure(of: outcome) == .cliReportedError("Browser extension is not connected"), "run: the CLI's error is reported", "\(outcome)")
}

do {
    let runner = VesperBrowserTaskRunner(executablePathOverride: fakeClaudePath, workingDirectoryURL: scratchWorkingDirectoryURL, overallTimeLimitSeconds: 10)
    let startedAt = Date()
    let browserTask = Task { await runner.run(task: "HANG for cancel") { _ in } }
    try? await Task.sleep(for: .milliseconds(700))
    let processIdentifier = lastLaunchedProcessIdentifier()
    browserTask.cancel()
    let outcome = await browserTask.value
    check(failure(of: outcome) == .cancelled && Date().timeIntervalSince(startedAt) < 2, "run: cancelling (hotkey / Stop) stops it", "\(outcome)")
    try? await Task.sleep(for: .milliseconds(500))
    check(processIdentifier.map { !isProcessAlive($0) } == true, "run: ...and kills the process")
}

do {
    let browserTask = Task { () -> VesperBrowserTaskOutcome in
        withUnsafeCurrentTask { $0?.cancel() }
        let runner = VesperBrowserTaskRunner(executablePathOverride: fakeClaudePath, workingDirectoryURL: scratchWorkingDirectoryURL)
        return await runner.run(task: "PLAY already cancelled") { _ in }
    }
    check(failure(of: await browserTask.value) == .cancelled, "run: an already-cancelled task never runs")
}

print(failureCount == 0 ? "\n✅ all chrome task tests passed" : "\n❌ \(failureCount) chrome task test(s) failed")
exit(failureCount == 0 ? 0 : 1)
