//
//  VesperMemoryStore.swift
//  leanring-buddy
//
//  Vesper's long-term memory: a few short notes that last across days,
//  restarts and new conversations. Kept on this Mac only, as a plain text
//  file with one note per line, so the user can read and edit it (the
//  panel's Edit button opens it in TextEdit).
//
//  Cost: the notes are part of the system prompt when a CLI process
//  starts, so the CLI's prompt cache re-reads them on every question at a
//  fraction of the normal token cost. The total is capped (~500 tokens) so
//  memory can never grow into a real expense.
//

import AppKit
import Foundation

final class VesperMemoryStore {
    enum AddNoteResult: Equatable {
        case saved
        case alreadyRemembered
        /// Adding it would pass the size cap; something must be forgotten first.
        case memoryFull
        /// Looks like a password, card number or code — never stored.
        case refusedAsSensitive
        /// Contains a link or a command. Notes go into every future system
        /// prompt, so text on a page must not be able to plant "they like
        /// links via https://..." there.
        case refusedAsLinkOrCommand
    }

    /// Longest single note. Keeps notes to one clear fact each.
    static let maximumNoteCharacterCount = 150
    /// Cap on all notes together: about 550 tokens (~35 short notes). With
    /// the ~160-token memory instructions, that's at most ~17% of even the
    /// smallest question (~4,400 tokens at the start of a conversation) and
    /// ~6% of a typical one — the budget the user agreed to. The prompt
    /// cache makes the real cost a fraction of that. Re-measure if the
    /// memory instructions in the system prompt grow.
    static let maximumTotalCharacterCount = 2_200
    static let minimumForgetSearchLength = 5
    static let maximumNotesForgottenAtOnce = 3

    let memoryFileURL: URL

    init(memoryFileURL: URL = VesperMemoryStore.defaultMemoryFileURL) {
        self.memoryFileURL = memoryFileURL
    }

    static var defaultMemoryFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent("Vesper", isDirectory: true)
            .appendingPathComponent("memory.txt")
    }

    /// Every note, read fresh from disk so edits made in TextEdit count.
    func loadNotes() -> [String] {
        guard let fileContents = try? String(contentsOf: memoryFileURL, encoding: .utf8) else { return [] }
        return fileContents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func addNote(_ noteText: String) -> AddNoteResult {
        // Every kind of line break, the same way loadNotes splits them, so
        // one note can never turn into two.
        let cleanedNote = noteText
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortenedNote = String(cleanedNote.prefix(Self.maximumNoteCharacterCount))
        guard !shortenedNote.isEmpty else { return .alreadyRemembered }

        if Self.looksSensitive(shortenedNote) {
            return .refusedAsSensitive
        }
        if Self.containsLinkOrCommand(shortenedNote) {
            return .refusedAsLinkOrCommand
        }

        var existingNotes = loadNotes()
        if existingNotes.contains(where: { $0.caseInsensitiveCompare(shortenedNote) == .orderedSame }) {
            return .alreadyRemembered
        }
        let totalCharacterCountAfterAdding = existingNotes.reduce(0) { $0 + $1.count } + shortenedNote.count
        if totalCharacterCountAfterAdding > Self.maximumTotalCharacterCount {
            return .memoryFull
        }

        existingNotes.append(shortenedNote)
        saveNotes(existingNotes)
        return .saved
    }

    /// Removes every note containing the given words (case-insensitive).
    /// Returns how many were removed.
    @discardableResult
    func forgetNotes(containing searchText: String) -> Int {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A forget must be specific: "[FORGET:the]" would wipe most notes.
        guard trimmedSearchText.count >= Self.minimumForgetSearchLength else { return 0 }
        let existingNotes = loadNotes()
        let keptNotes = existingNotes.filter { $0.range(of: trimmedSearchText, options: .caseInsensitive) == nil }
        let forgottenNoteCount = existingNotes.count - keptNotes.count
        // Matching many notes at once means the words weren't specific
        // enough — forget nothing rather than wipe memory.
        guard forgottenNoteCount <= Self.maximumNotesForgottenAtOnce else { return 0 }
        if forgottenNoteCount > 0 {
            saveNotes(keptNotes)
        }
        return forgottenNoteCount
    }

    /// Creates the file if needed and opens it in the default text editor.
    func openInTextEditor() {
        if !FileManager.default.fileExists(atPath: memoryFileURL.path) {
            saveNotes([])
        }
        NSWorkspace.shared.open(memoryFileURL)
    }

    private func saveNotes(_ notes: [String]) {
        do {
            try FileManager.default.createDirectory(
                at: memoryFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let fileContents = notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n"
            try fileContents.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Memory: couldn't save notes: \(error.localizedDescription)")
        }
    }

    /// Passwords, card numbers, one-time codes and the like are never kept,
    /// whatever Claude asks for.
    static func looksSensitive(_ noteText: String) -> Bool {
        let sensitiveWordPattern = #"\b(password|passcode|passwd|passphrase|pwd|pw|pin|otp|2fa|mfa|cvv|cvc|ssn|verification code|security code|recovery code|backup code|secret key|api key|private key|seed phrase|account number|routing number|iban)\b"#
        if noteText.range(of: sensitiveWordPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        // Card numbers: 13–19 digits (spaces and dashes allowed) that pass
        // the Luhn checksum every card number carries. Phone numbers with a
        // country code are 12+ digits too, so length alone would refuse them.
        // Every 13–19 digit stretch of a longer run is checked, so a card
        // followed by an expiry ("4111 1111 1111 1111 1226") is still caught.
        let digitRuns = noteText
            .components(separatedBy: CharacterSet(charactersIn: "0123456789 -").inverted)
            .map { runText in Array(runText.filter(\.isNumber)) }
        return digitRuns.contains { digitRun in
            guard digitRun.count >= 13 else { return false }
            for windowLength in 13...min(19, digitRun.count) {
                for windowStart in 0...(digitRun.count - windowLength) {
                    if passesLuhnChecksum(String(digitRun[windowStart..<(windowStart + windowLength)])) {
                        return true
                    }
                }
            }
            return false
        }
    }

    /// Web addresses (with or without http), shell commands, and tag
    /// brackets. Ordinary preferences ("always", "prefers dark mode") pass.
    static func containsLinkOrCommand(_ noteText: String) -> Bool {
        let linkPattern = #"(https?:|www\.|://)"#
        if noteText.range(of: linkPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        // "evil.example" or "fiverr.com/inbox" — any name.ending, except
        // file and framework names people mention ("next.js", "notes.md").
        let nonAddressEndings: Set<String> = ["js", "ts", "py", "md", "txt", "json", "swift", "rb", "go", "rs", "sh", "css", "html", "pdf", "png", "jpg"]
        let addressPattern = try! NSRegularExpression(pattern: #"\b[a-z0-9-]{2,}\.([a-z]{2,})\b"#, options: [.caseInsensitive])
        let addressMatches = addressPattern.matches(in: noteText, range: NSRange(noteText.startIndex..., in: noteText))
        let containsWebAddress = addressMatches.contains { addressMatch in
            guard let endingRange = Range(addressMatch.range(at: 1), in: noteText) else { return false }
            return !nonAddressEndings.contains(noteText[endingRange].lowercased())
        }
        if containsWebAddress {
            return true
        }
        let commandPattern = #"(`|\$\(|&&|\|\s*(sh|bash|zsh)\b|\b(curl|wget|sudo|chmod|osascript)\b|\brm\s+-|\[|\])"#
        return noteText.range(of: commandPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func passesLuhnChecksum(_ digitString: String) -> Bool {
        var checksumTotal = 0
        for (positionFromRight, digitCharacter) in digitString.reversed().enumerated() {
            guard var digitValue = digitCharacter.wholeNumberValue else { return false }
            if positionFromRight % 2 == 1 {
                digitValue *= 2
                if digitValue > 9 { digitValue -= 9 }
            }
            checksumTotal += digitValue
        }
        return checksumTotal % 10 == 0
    }
}
