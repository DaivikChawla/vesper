//
//  VesperTypedQuestions.swift
//  leanring-buddy
//
//  Questions typed into the panel ("Type to Vesper", or ctrl+option+/)
//  instead of spoken. They go through the same pipeline as a spoken
//  question — screenshot, Claude, speech, pointing and actions — but skip
//  speech recognition and the voice check.
//
//  The one rule that matters for safety: typed text never approves a
//  pending risky confirmation (send / delete / pay…). A typed "yes" is
//  passed to Claude as an instruction instead, so something typed or
//  pasted into the panel — or a stray Return — can't click Send.
//

import Foundation

enum VesperTypedQuestion {
    /// Typed text is capped like tag content, so a huge paste can't make
    /// one turn expensive.
    static let maximumTypedQuestionCharacterCount = 2000

    /// The text to send, or nil when there's nothing worth sending.
    /// Line breaks become spaces: a typed question is one line, like a
    /// spoken one.
    static func cleanedQuestionText(_ typedText: String) -> String? {
        let singleLineText = typedText
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLineText.isEmpty else { return nil }
        return String(singleLineText.prefix(maximumTypedQuestionCharacterCount))
    }
}

extension VesperConfirmationAnswer {
    /// How an answer to "say yes and i'll do it" is read. Only a spoken
    /// answer can approve (and only after the voice check, when that's on);
    /// typed text always becomes an instruction for Claude — even "yes".
    static func classify(_ answerText: String, wasTypedRatherThanSpoken: Bool) -> VesperConfirmationAnswer {
        if wasTypedRatherThanSpoken {
            return .otherInstruction
        }
        return classify(answerText)
    }
}
