//
//  VesperRecentConversation.swift
//  leanring-buddy
//
//  The last few exchanges shown in the panel ("Recent"), so something she
//  said can be read again or copied. Kept in memory only, never on disk.
//  Action tags are stripped (a [CLICK:640,320] means nothing to a reader)
//  and each side is capped, so the panel stays compact.
//

import Foundation

struct VesperRecentExchange: Identifiable, Equatable {
    let id: UUID
    /// What they said or typed.
    let userText: String
    /// What she replied, without tags. A hands-on task's later steps are
    /// added to the same exchange.
    let replyText: String
}

enum VesperRecentConversation {
    static let maximumExchangeCount = 5
    static let maximumCharactersPerSide = 200

    /// Tags come out before the cap: capping first could cut a tag in half,
    /// and a half tag ("[CLICK:12,3") no longer looks like a tag.
    static func cleanedForDisplay(_ text: String) -> String {
        let textWithoutTags = ClaudeCodeCLIBridge.removingAllTags(from: text)
        let singleLineText = textWithoutTags
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cappedForDisplay(singleLineText)
    }

    private static func cappedForDisplay(_ text: String) -> String {
        text.count > maximumCharactersPerSide
            ? String(text.prefix(maximumCharactersPerSide)).trimmingCharacters(in: .whitespaces) + "…"
            : text
    }

    /// Past the cap, more text changes nothing on screen (it only moves the
    /// "…"), so a long task's reply isn't kept in full. Tags are already
    /// gone, so this can't cut one in half.
    private static func keptForLaterJoins(_ replyTextWithoutTags: String) -> String {
        String(replyTextWithoutTags.prefix(maximumCharactersPerSide + 1))
    }

    /// The list after a reply finishes, newest first.
    ///
    /// `userText` is the question that started this exchange; nil means the
    /// reply continues the newest exchange (a hands-on step, a lookup's
    /// follow-up), so a whole task is one entry. `uncappedReplyTextSoFar`
    /// holds each exchange's full reply, so a continuation is joined onto
    /// the whole text and capped once, never onto a string ending in "…".
    static func recording(
        userText: String?,
        replyText: String,
        into exchangesNewestFirst: [VesperRecentExchange],
        uncappedReplyTextSoFar: inout [UUID: String]
    ) -> [VesperRecentExchange] {
        let replyTextWithoutTags = ClaudeCodeCLIBridge.removingAllTags(from: replyText)
        var updatedExchanges = exchangesNewestFirst

        if userText == nil, let newestExchange = updatedExchanges.first {
            guard !replyTextWithoutTags.isEmpty else { return updatedExchanges }
            let earlierReplyText = uncappedReplyTextSoFar[newestExchange.id] ?? newestExchange.replyText
            let joinedReplyText = earlierReplyText.isEmpty
                ? replyTextWithoutTags
                : earlierReplyText + " " + replyTextWithoutTags
            uncappedReplyTextSoFar[newestExchange.id] = keptForLaterJoins(joinedReplyText)
            updatedExchanges[0] = VesperRecentExchange(
                id: newestExchange.id,
                userText: newestExchange.userText,
                replyText: cleanedForDisplay(joinedReplyText)
            )
            return updatedExchanges
        }

        let displayedUserText = cleanedForDisplay(userText ?? "")
        let displayedReplyText = cleanedForDisplay(replyTextWithoutTags)
        guard !displayedUserText.isEmpty || !displayedReplyText.isEmpty else { return updatedExchanges }

        let newExchange = VesperRecentExchange(id: UUID(), userText: displayedUserText, replyText: displayedReplyText)
        uncappedReplyTextSoFar[newExchange.id] = keptForLaterJoins(replyTextWithoutTags)
        updatedExchanges.insert(newExchange, at: 0)
        if updatedExchanges.count > maximumExchangeCount {
            updatedExchanges.removeLast(updatedExchanges.count - maximumExchangeCount)
        }
        // Full replies are only kept for exchanges still on the list.
        let keptExchangeIDs = Set(updatedExchanges.map(\.id))
        uncappedReplyTextSoFar = uncappedReplyTextSoFar.filter { keptExchangeIDs.contains($0.key) }
        return updatedExchanges
    }
}
