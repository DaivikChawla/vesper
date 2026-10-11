//
//  main.swift — test driver for typed questions and the recent conversation
//
//  Checks that typed text can never approve a risky confirmation (while the
//  same words spoken still can), how typed text is cleaned, and how the
//  panel's recent exchanges are recorded: tags stripped before capping,
//  hands-on steps joined into one entry, newest first, at most five.
//  Built and run by scripts/test-typed-questions.sh.
//

import Foundation

var failedCheckCount = 0

func check(_ didPass: Bool, _ checkDescription: String, _ detail: String = "") {
    print("\(didPass ? "✅" : "❌") \(checkDescription)\(detail.isEmpty ? "" : " — \(detail)")")
    if !didPass { failedCheckCount += 1 }
}

// Top-level code isn't main-actor isolated, but the app's types are
// (default isolation), so the checks run inside the main actor.
@MainActor
func runAllChecks() {
    // MARK: - Typed text never approves

    for approvalText in ["yes", "yeah send it", "go ahead", "yes please", "ok", "confirm"] {
        check(VesperConfirmationAnswer.classify(approvalText, wasTypedRatherThanSpoken: false) == .approved,
              "spoken \"\(approvalText)\" approves (so the typed check below means something)")
        check(VesperConfirmationAnswer.classify(approvalText, wasTypedRatherThanSpoken: true) == .otherInstruction,
              "typed \"\(approvalText)\" is an instruction, never an approval")
    }
    check(VesperConfirmationAnswer.classify("no", wasTypedRatherThanSpoken: true) == .otherInstruction,
          "typed \"no\" also goes to Claude as an instruction")
    check(VesperConfirmationAnswer.classify("no", wasTypedRatherThanSpoken: false) == .declined,
          "spoken \"no\" still declines")

    // MARK: - Cleaning typed text

    check(VesperTypedQuestion.cleanedQuestionText("   \n  ") == nil, "blank text sends nothing")
    check(VesperTypedQuestion.cleanedQuestionText("  what's this?  ") == "what's this?", "surrounding spaces are trimmed")
    check(VesperTypedQuestion.cleanedQuestionText("line one\nline two") == "line one line two", "line breaks become spaces")
    check(VesperTypedQuestion.cleanedQuestionText(String(repeating: "a", count: 5000))?.count
          == VesperTypedQuestion.maximumTypedQuestionCharacterCount, "a huge paste is capped")

    // MARK: - Recent conversation

    var uncappedReplyTextSoFar: [UUID: String] = [:]
    var recentExchanges: [VesperRecentExchange] = []

    recentExchanges = VesperRecentConversation.recording(
        userText: "where's the settings button?",
        replyText: "[POINT:640,320:settings:screen1] it's this gear, top right. [REMEMBER:likes gears]",
        into: recentExchanges,
        uncappedReplyTextSoFar: &uncappedReplyTextSoFar
    )
    check(recentExchanges.count == 1, "a reply is recorded")
    check(recentExchanges.first?.replyText == "it's this gear, top right.", "tags are stripped from her words",
          recentExchanges.first?.replyText ?? "nil")
    check(recentExchanges.first?.userText == "where's the settings button?", "their words are kept")

    // A tag that sits across the 200-character cap: stripping first means no
    // half tag ("[CLICK:12,3") survives the cut.
    let textBeforeTag = String(repeating: "word ", count: 39)   // 195 characters
    let replyWithTagAtTheCap = textBeforeTag + "[CLICK:1200,340:the send button] and then more words after it"
    recentExchanges = VesperRecentConversation.recording(
        userText: "send it",
        replyText: replyWithTagAtTheCap,
        into: recentExchanges,
        uncappedReplyTextSoFar: &uncappedReplyTextSoFar
    )
    let cappedReplyText = recentExchanges.first?.replyText ?? ""
    check(!cappedReplyText.contains("["), "a tag at the cap never leaves a fragment", cappedReplyText)
    check(cappedReplyText.count <= VesperRecentConversation.maximumCharactersPerSide + 1 && cappedReplyText.hasSuffix("…"),
          "long replies are capped at 200 characters with an ellipsis", "\(cappedReplyText.count)")

    // Hands-on steps (no user text) join the newest exchange, joined in full
    // and capped once — never appended after an "…".
    recentExchanges = VesperRecentConversation.recording(
        userText: "open my inbox",
        replyText: "[OPEN:https://mail.google.com] opening gmail.",
        into: recentExchanges,
        uncappedReplyTextSoFar: &uncappedReplyTextSoFar
    )
    recentExchanges = VesperRecentConversation.recording(
        userText: nil,
        replyText: "[CLICK:100,200:inbox] clicking inbox. [DONE]",
        into: recentExchanges,
        uncappedReplyTextSoFar: &uncappedReplyTextSoFar
    )
    check(recentExchanges.count == 3, "a hands-on step doesn't add an entry", "\(recentExchanges.count)")
    check(recentExchanges.first?.replyText == "opening gmail. clicking inbox.", "the step's words join the task's entry",
          recentExchanges.first?.replyText ?? "nil")

    let longStepText = String(repeating: "step ", count: 30)
    for _ in 0..<3 {
        recentExchanges = VesperRecentConversation.recording(
            userText: nil, replyText: longStepText, into: recentExchanges, uncappedReplyTextSoFar: &uncappedReplyTextSoFar
        )
    }
    let joinedTaskReplyText = recentExchanges.first?.replyText ?? ""
    check(joinedTaskReplyText.filter { $0 == "…" }.count == 1 && joinedTaskReplyText.hasSuffix("…"),
          "a long task is capped once, with one ellipsis at the end", joinedTaskReplyText)
    check(joinedTaskReplyText.count <= VesperRecentConversation.maximumCharactersPerSide + 1, "and stays within the cap")

    for questionNumber in 1...6 {
        recentExchanges = VesperRecentConversation.recording(
            userText: "question \(questionNumber)", replyText: "answer \(questionNumber)",
            into: recentExchanges, uncappedReplyTextSoFar: &uncappedReplyTextSoFar
        )
    }
    check(recentExchanges.count == VesperRecentConversation.maximumExchangeCount, "at most five exchanges are kept")
    check(recentExchanges.first?.userText == "question 6" && recentExchanges.last?.userText == "question 2",
          "newest first, oldest dropped")
    check(uncappedReplyTextSoFar.count == VesperRecentConversation.maximumExchangeCount,
          "full replies are only kept for exchanges still listed", "\(uncappedReplyTextSoFar.count)")

    let exchangesBeforeEmptyReply = recentExchanges
    recentExchanges = VesperRecentConversation.recording(
        userText: nil, replyText: "[DONE]", into: recentExchanges, uncappedReplyTextSoFar: &uncappedReplyTextSoFar
    )
    check(recentExchanges == exchangesBeforeEmptyReply, "a step that was only tags changes nothing")
}

MainActor.assumeIsolated {
    runAllChecks()
}

print(failedCheckCount == 0 ? "\n✅ all typed-question tests passed" : "\n❌ \(failedCheckCount) typed-question check(s) failed")
exit(failedCheckCount == 0 ? 0 : 1)
