//
//  VesperResponseStreamParser.swift
//  leanring-buddy
//
//  Turns Claude's reply, as it streams in, into speakable segments.
//
//  Each segment is (roughly) one sentence plus the tags that came right
//  before it. Vesper is told to put a tag immediately before the sentence
//  it's about, so when that sentence starts playing the cursor flies to the
//  element she's describing — "click file, [POINT] then export [POINT]"
//  moves the cursor step by step as she talks. [HIGHLIGHT] works the same
//  way for an area: a rectangle is drawn around it while its sentence plays.
//  [CIRCLE], [UNDERLINE] and [ARROW] are her drawings ("ink"): her cursor
//  draws them on the screen while their sentence plays.
//
//  Besides [POINT], she can write action tags — [OPEN:...], [MUSIC:...],
//  [VOLUME:...] (quick actions) and [CLICK:...], [TYPE:...], [KEY:...],
//  [SCROLL:...], [DONE] (hands-on control). The parser only recognizes them;
//  CompanionManager decides whether the current control mode allows them.
//
//  Tags are never spoken. A tag that arrives split across chunks (for
//  example "...look here [CLI" then "CK:10,20:save]") is held back until it
//  can be recognized, so its characters never leak into speech.
//

import CoreGraphics
import Foundation

/// A parsed [POINT:x,y:label:screenN] tag.
struct VesperPointTag: Equatable {
    /// Pixel coordinate in the screenshot Claude saw (top-left origin).
    let screenshotPixel: CGPoint
    /// Short name of the element, e.g. "save button".
    let elementLabel: String?
    /// 1-based screen number when the element is on a non-primary screen.
    let screenNumber: Int?
}

/// A parsed [HIGHLIGHT:x1,y1,x2,y2:label:screenN] tag: an area she draws a
/// rounded rectangle around while she talks about it (a panel, a paragraph,
/// a row of buttons). [POINT] is for single controls.
struct VesperHighlightTag: Equatable {
    /// The area in the screenshot Claude saw (top-left origin, pixels),
    /// with its corners put in order whichever way round Claude wrote them.
    let screenshotRect: CGRect
    /// Short name of the area, e.g. "sidebar".
    let areaLabel: String?
    /// 1-based screen number when the area is on a non-primary screen.
    let screenNumber: Int?
}

/// A parsed drawing tag — [CIRCLE:x1,y1,x2,y2], [UNDERLINE:x1,y1,x2,y2]
/// or [ARROW:x1,y1,x2,y2] (each with an optional :label and :screenN).
/// Her cursor draws it in light while its sentence plays (see VesperInk).
struct VesperInkTag: Equatable {
    enum Kind: Equatable {
        /// Circles one thing; the numbers are its corners.
        case encircle
        /// Underlines text; the numbers are the text's corners.
        case underline
        /// An arrow from the first point to the second — order matters.
        case arrow
    }

    let kind: Kind
    /// The first corner (or the arrow's tail), screenshot pixels, top-left origin.
    let firstScreenshotPixel: CGPoint
    /// The opposite corner (or the arrow's tip).
    let secondScreenshotPixel: CGPoint
    let label: String?
    /// 1-based screen number when it's on a non-primary screen.
    let screenNumber: Int?

    /// For circles and underlines: the area between the two corners,
    /// whichever way round they were written.
    var screenshotRect: CGRect {
        CGRect(
            x: min(firstScreenshotPixel.x, secondScreenshotPixel.x),
            y: min(firstScreenshotPixel.y, secondScreenshotPixel.y),
            width: abs(secondScreenshotPixel.x - firstScreenshotPixel.x),
            height: abs(secondScreenshotPixel.y - firstScreenshotPixel.y)
        )
    }
}

enum VesperMusicCommand: Equatable {
    case play
    case pause
    case nextTrack
    case previousTrack
    /// Plays the first song or playlist in the user's library matching the query.
    case playSearchResult(searchQuery: String)
}

enum VesperVolumeChange: Equatable {
    case setLevel(percent: Int)
    case up
    case down
    case mute
    case unmute
}

enum VesperClickKind: Equatable {
    case single
    case double
    case right
}

enum VesperScrollDirection: String, Equatable {
    case up
    case down
    case left
    case right
}

/// What a [LOOKUP:kind:query] reads. Each is local or keyless, and its
/// result goes back to Claude as a follow-up turn (see VesperLookups).
enum VesperLookupKind: String, Equatable, CaseIterable {
    case weather
    case files
    case screenText = "screen-text"
    case windowText = "window-text"
    case clipboard
    case battery
    case wifi
}

struct VesperLookupRequest: Equatable {
    let kind: VesperLookupKind
    /// The city for weather, the file name for files; empty for the rest.
    let query: String
}

/// Where a [WINDOW:...] tag puts a window (see VesperWindowControl).
enum VesperWindowArrangement: String, Equatable, CaseIterable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    /// Fills the screen, minus the menu bar and Dock — not a separate
    /// full-screen Space.
    case fullscreen
    case center
    case nextScreen = "next-screen"
}

/// Something Vesper can do on the Mac, parsed from a tag in her reply.
enum VesperAction: Equatable {
    // Quick actions — run instantly, no extra Claude turns.
    /// A website (http/https) or an app name, optionally opened in a specific app.
    case open(target: String, inApplicationNamed: String?)
    case music(VesperMusicCommand)
    case volume(VesperVolumeChange)
    /// One of their Shortcuts, by name — only ones allowed in the panel run.
    case runShortcut(name: String)
    /// Moves and resizes the front window (or the named app's window).
    case arrangeWindow(VesperWindowArrangement, applicationName: String?)
    /// Hides a running app, like cmd+H.
    case hideApplication(name: String)
    /// Brings an app to the front, opening it if it isn't running.
    case focusApplication(name: String)
    /// Quits a running app normally, so its own "save changes?" prompts appear.
    case quitApplication(name: String)

    // Hands-on control — run after she finishes speaking, then she looks again.
    case click(screenshotPixel: CGPoint, elementLabel: String?, screenNumber: Int?, clickKind: VesperClickKind)
    case typeText(String)
    /// A key combination as written, e.g. "cmd+l" or "return".
    case pressKeys(String)
    case scroll(direction: VesperScrollDirection, screenshotPixel: CGPoint?, screenNumber: Int?)
    /// Something is still loading: wait this long, then look again.
    case waitForScreen(seconds: Double)
    /// The multi-step task is finished — stop looking at the screen again.
    case finishTask

    // Long-term memory — works in every control mode.
    case rememberNote(String)
    /// Forgets every note containing these words.
    case forgetNotes(String)

    // Calendar and Reminders — local, run once she has finished speaking.
    /// A reminder in the Reminders app; with a time, she also says it out loud then.
    case createReminder(text: String, dueDate: Date?)
    /// A calendar event with no invitees, in the default calendar.
    case createCalendarEvent(title: String, startDate: Date, durationMinutes: Int)
    /// A timer she says out loud when it's up, through the same local
    /// scheduler as spoken reminders — no EventKit, no Claude request.
    case startTimer(durationSeconds: Int, label: String?)

    // Lookups — read-only, in every control mode; run after she speaks,
    // and the results go back to Claude for the actual answer.
    case lookUp(VesperLookupRequest)
    /// A question that needs current web info, researched by a separate
    /// one-shot CLI process after she speaks (see VesperWebResearch).
    case researchOnWeb(question: String)
    /// Something to do inside the user's Chrome (search a site, fill a
    /// form), done by Claude in Chrome after she speaks (VesperBrowserTask).
    case browserTask(task: String)

    var isQuickAction: Bool {
        switch self {
        case .open, .music, .volume, .runShortcut,
             .arrangeWindow, .hideApplication, .focusApplication, .quitApplication:
            return true
        default:
            return false
        }
    }

    var isMemoryAction: Bool {
        switch self {
        case .rememberNote, .forgetNotes:
            return true
        default:
            return false
        }
    }

    /// Reminders, events and timers: local, allowed in Quick and Hands-on,
    /// and run once she has finished saying what she's adding.
    var isCalendarAction: Bool {
        switch self {
        case .createReminder, .createCalendarEvent, .startTimer:
            return true
        default:
            return false
        }
    }
}

/// One piece of the reply to speak, with the point and actions (if any)
/// that came right before it.
struct VesperResponseSegment: Equatable {
    let spokenText: String
    let pointTag: VesperPointTag?
    var actions: [VesperAction] = []
    /// An area to draw a rectangle around while this segment plays.
    var highlightTag: VesperHighlightTag? = nil
    /// Drawings her cursor makes while this segment plays, in reply order.
    var inkTags: [VesperInkTag] = []
    /// A guided step: point at this, then wait for the user to click it
    /// before the next step ([GUIDE:x,y:label]).
    var guideTag: VesperPointTag? = nil
}

final class VesperResponseStreamParser {
    /// The first segment is split early (at a comma or dash) once it has this
    /// many words without reaching a sentence end, so speech starts sooner.
    /// Tried 4 (to start one-sentence replies sooner): the short fragments
    /// made the voice sound choppy, with odd intonation — reverted to 8.
    private static let firstSegmentEarlySplitMinimumWordCount = 8
    /// Any segment is split at a comma or space once it gets this long, so
    /// no single synthesis request is huge (local neural voices have limits).
    private static let maximumSegmentWordCount = 40

    /// Every tag name the parser recognizes. Anything in brackets that isn't
    /// one of these (like "array [1]") is ordinary text and gets spoken.
    private static let recognizedTagNames = [
        "POINT", "GUIDE", "HIGHLIGHT", "CIRCLE", "UNDERLINE", "ARROW", "OPEN", "MUSIC", "VOLUME",
        "CLICK", "DOUBLECLICK", "RIGHTCLICK", "TYPE", "KEY", "SCROLL", "WAIT", "DONE",
        "REMEMBER", "FORGET", "REMIND", "EVENT", "SHORTCUT", "TIMER", "LOOKUP", "RESEARCH", "BROWSER",
        "WINDOW", "HIDE", "FOCUS", "QUIT"
    ]

    /// The opening of any recognized tag: "[POINT:" or "[DONE]".
    private static let recognizedTagOpeningPattern = #"\[(?:\#(recognizedTagNames.joined(separator: "|")))[:\]]"#

    /// Matches any complete recognized tag. The content after the first colon
    /// is everything up to the closing bracket (so typed text can contain
    /// colons, but not a closing bracket) — and never runs into another
    /// tag: in "[TYPE:hello and more prose [POINT:1,2:x]" an unclosed TYPE
    /// must not swallow the prose and the point tag and type them.
    private static let anyTagPattern = try! NSRegularExpression(
        pattern: #"\[(\#(recognizedTagNames.joined(separator: "|")))(?::((?:(?!\#(recognizedTagOpeningPattern))[^\]]){0,\#(maximumTagContentLength)}))?\]"#
    )
    /// An unclosed tag's opening and whatever follows it up to the next tag,
    /// like "[TYPE:hello and more prose " above. Never spoken, never run.
    private static let brokenTagOpeningPattern = try! NSRegularExpression(
        pattern: #"\[(?:\#(recognizedTagNames.joined(separator: "|"))):(?:(?!\#(recognizedTagOpeningPattern))[^\]])*"#
    )
    /// A tag's content is capped: an unclosed "[TYPE:" must not swallow the
    /// rest of the reply (and then type it) when a "]" finally appears.
    private static let maximumTagContentLength = 600

    /// "x,y", optionally followed by ":label" and/or ":screenN".
    /// Coordinates may be slightly negative or have decimals ("-3,412.5"):
    /// Claude does that for things at a screen's edge, and dropping the tag
    /// would lose the point — or end a hands-on task with no action.
    private static let coordinateContentPattern = try! NSRegularExpression(
        pattern: #"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?::([^:]*?))?(?::screen(\d+))?\s*$"#
    )

    /// "x1,y1,x2,y2", optionally followed by ":label" and/or ":screenN".
    /// Same number format as coordinateContentPattern.
    private static let areaContentPattern = try! NSRegularExpression(
        pattern: #"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?::([^:]*?))?(?::screen(\d+))?\s*$"#
    )

    /// Text received but not yet emitted as part of a segment.
    private var unemittedText = ""
    /// A point tag waiting for the next segment to attach to.
    private var pointTagForNextSegment: VesperPointTag?
    /// A highlight tag waiting for the next segment to attach to.
    private var highlightTagForNextSegment: VesperHighlightTag?
    /// Drawing tags waiting for the next segment to attach to, in reply order.
    private var inkTagsForNextSegment: [VesperInkTag] = []
    /// A guided step waiting for the next segment to attach to.
    private var guideTagForNextSegment: VesperPointTag?
    /// Action tags waiting for the next segment to attach to, in reply order.
    private var actionsForNextSegment: [VesperAction] = []
    private var hasEmittedFirstSegment = false

    /// Feeds newly streamed text in; returns any segments that are now complete.
    func appendTextDelta(_ textDelta: String) -> [VesperResponseSegment] {
        unemittedText += textDelta
        return extractCompleteSegments(isEndOfReply: false)
    }

    /// Call once the reply is complete; returns whatever is left.
    func finish() -> [VesperResponseSegment] {
        var finalSegments = extractCompleteSegments(isEndOfReply: true)

        // A reply that ends mid-tag (e.g. "...export [POINT:12,") can never
        // complete it, so drop the fragment rather than speak it.
        let remainingTextWithoutBrokenTag = Self.textBeforePossiblePartialTag(in: unemittedText)
        let remainingSpokenText = Self.normalizedSpokenText(remainingTextWithoutBrokenTag)
        unemittedText = ""
        if !remainingSpokenText.isEmpty || pointTagForNextSegment != nil || highlightTagForNextSegment != nil
            || !inkTagsForNextSegment.isEmpty || guideTagForNextSegment != nil || !actionsForNextSegment.isEmpty {
            // Tags with no text after them (the old "tag at the end" habit,
            // or a silent hands-on step) still happen — as an empty segment,
            // which fires right away.
            finalSegments.append(makeSegment(spokenText: remainingSpokenText))
        }
        return finalSegments
    }

    // MARK: - Segmenting

    private func extractCompleteSegments(isEndOfReply: Bool) -> [VesperResponseSegment] {
        var completedSegments: [VesperResponseSegment] = []

        while true {
            // A tag at the front of the pending text belongs to the text
            // that follows it.
            if consumeLeadingTag() {
                continue
            }

            // Only look at text that can't be the start of an unfinished tag.
            // At the end of the reply nothing more is coming, so everything
            // is segmented (finish() then drops any broken tag fragment).
            let safeToSegmentText = isEndOfReply
                ? unemittedText
                : Self.textBeforePossiblePartialTag(in: unemittedText)

            // A tag in the middle of the text ends the segment before it.
            if let nextTagRange = Self.rangeOfFirstTag(in: safeToSegmentText) {
                let textBeforeTag = String(safeToSegmentText[..<nextTagRange.lowerBound])
                if !Self.normalizedSpokenText(textBeforeTag).isEmpty {
                    completedSegments.append(makeSegment(spokenText: textBeforeTag))
                }
                unemittedText.removeFirst(textBeforeTag.count)
                continue
            }

            // At the end of the reply, a broken tag fragment must not be
            // split into sentences and spoken — leave it for finish().
            let segmentableText = isEndOfReply
                ? Self.textBeforePossiblePartialTag(in: safeToSegmentText)
                : safeToSegmentText
            guard let segmentEndIndex = segmentBoundary(in: segmentableText) else {
                break
            }
            let segmentText = String(segmentableText[..<segmentEndIndex])
            unemittedText.removeFirst(segmentText.count)
            if !Self.normalizedSpokenText(segmentText).isEmpty {
                completedSegments.append(makeSegment(spokenText: segmentText))
            }
        }

        return completedSegments
    }

    private func makeSegment(spokenText: String) -> VesperResponseSegment {
        let segment = VesperResponseSegment(
            spokenText: Self.normalizedSpokenText(spokenText),
            pointTag: pointTagForNextSegment,
            actions: actionsForNextSegment,
            highlightTag: highlightTagForNextSegment,
            inkTags: inkTagsForNextSegment,
            guideTag: guideTagForNextSegment
        )
        pointTagForNextSegment = nil
        highlightTagForNextSegment = nil
        inkTagsForNextSegment = []
        guideTagForNextSegment = nil
        actionsForNextSegment = []
        hasEmittedFirstSegment = true
        return segment
    }

    /// If the pending text starts with a complete tag, removes it and
    /// remembers it for the next segment. Returns true if one was consumed.
    private func consumeLeadingTag() -> Bool {
        let leadingWhitespaceCount = unemittedText.prefix { $0.isWhitespace }.count
        let textAfterWhitespace = String(unemittedText.dropFirst(leadingWhitespaceCount))
        guard textAfterWhitespace.hasPrefix("["),
              let tagRange = Self.rangeOfFirstTag(in: textAfterWhitespace),
              tagRange.lowerBound == textAfterWhitespace.startIndex else {
            return false
        }

        let tagText = String(textAfterWhitespace[tagRange])
        rememberTagForNextSegment(tagText)
        unemittedText.removeFirst(leadingWhitespaceCount + tagText.count)
        return true
    }

    private func rememberTagForNextSegment(_ tagText: String) {
        if tagText.hasPrefix("[CIRCLE") || tagText.hasPrefix("[UNDERLINE") || tagText.hasPrefix("[ARROW") {
            // A malformed drawing is dropped: never spoken, never drawn.
            if let inkTag = Self.parseInkTag(tagText) {
                inkTagsForNextSegment.append(inkTag)
            }
        } else if tagText.hasPrefix("[GUIDE") {
            // A malformed guide is dropped: never spoken, never followed.
            if let guideTag = Self.parseGuideTag(tagText) {
                guideTagForNextSegment = guideTag
            }
        } else if tagText.hasPrefix("[HIGHLIGHT") {
            // A malformed highlight is dropped: never spoken, never drawn.
            if let highlightTag = Self.parseHighlightTag(tagText) {
                highlightTagForNextSegment = highlightTag
            }
        } else if tagText.hasPrefix("[POINT") {
            // [POINT:none] parses to nil and simply doesn't point.
            if let pointTag = Self.parsePointTag(tagText) {
                pointTagForNextSegment = pointTag
            }
        } else if let action = Self.parseActionTag(tagText) {
            actionsForNextSegment.append(action)
        }
    }

    /// Finds where the next segment ends: after a sentence-ending mark
    /// followed by whitespace, or at a line break. Very long segments, and a
    /// long first segment, split earlier at a comma or dash.
    private func segmentBoundary(in text: String) -> String.Index? {
        var wordCount = 0
        var lastSoftBreakEndIndex: String.Index?
        var previousCharacter: Character?
        var characterIndex = text.startIndex

        while characterIndex < text.endIndex {
            let character = text[characterIndex]
            let nextIndex = text.index(after: characterIndex)

            if character.isWhitespace, let previousCharacter, !previousCharacter.isWhitespace {
                wordCount += 1
            }

            if character == "\n" {
                return nextIndex
            }

            let isFollowedByWhitespace = nextIndex < text.endIndex && text[nextIndex].isWhitespace
            if ".!?".contains(character) && isFollowedByWhitespace {
                return nextIndex
            }

            if (character == "," || character == "—" || character == ";") && isFollowedByWhitespace {
                lastSoftBreakEndIndex = nextIndex
                let shouldSplitFirstSegmentEarly = !hasEmittedFirstSegment
                    && wordCount >= Self.firstSegmentEarlySplitMinimumWordCount
                if shouldSplitFirstSegmentEarly {
                    return nextIndex
                }
            }

            if wordCount >= Self.maximumSegmentWordCount {
                return lastSoftBreakEndIndex ?? characterIndex
            }

            previousCharacter = character
            characterIndex = nextIndex
        }
        return nil
    }

    /// Everything before the earliest "[" that is (or might still become) an
    /// unfinished recognized tag, like "[CLI" or "[TYPE:hello. wor". The
    /// earliest one matters: typed text can itself contain "[".
    private static func textBeforePossiblePartialTag(in text: String) -> String {
        var searchStartIndex = text.startIndex
        while let openBracketIndex = text[searchStartIndex...].firstIndex(of: "[") {
            let textFromBracket = text[openBracketIndex...]
            // Longer than any tag can be: it's text, not a tag in progress.
            let isTooLongToBeTag = textFromBracket.count > maximumTagContentLength + 20
            if !isTooLongToBeTag && !textFromBracket.contains("]") && couldBecomeRecognizedTag(textFromBracket) {
                return String(text[..<openBracketIndex])
            }
            searchStartIndex = text.index(after: openBracketIndex)
        }
        return text
    }

    /// True for "[", "[CL", "[CLICK", "[CLICK:12,3" — text that more
    /// streamed characters could complete into a recognized tag.
    private static func couldBecomeRecognizedTag(_ textFromBracket: Substring) -> Bool {
        recognizedTagNames.contains { tagName in
            let tagOpening = "[" + tagName
            return tagOpening.hasPrefix(textFromBracket) || textFromBracket.hasPrefix(tagOpening + ":")
        }
    }

    // MARK: - Tag Parsing

    private static func rangeOfFirstTag(in text: String) -> Range<String.Index>? {
        let searchRange = NSRange(text.startIndex..., in: text)
        guard let tagMatch = anyTagPattern.firstMatch(in: text, range: searchRange) else { return nil }
        return Range(tagMatch.range, in: text)
    }

    /// Splits "[NAME:content]" into its name and content (nil when there's no colon).
    private static func tagNameAndContent(_ tagText: String) -> (tagName: String, tagContent: String?)? {
        let searchRange = NSRange(tagText.startIndex..., in: tagText)
        guard let tagMatch = anyTagPattern.firstMatch(in: tagText, range: searchRange),
              let tagNameRange = Range(tagMatch.range(at: 1), in: tagText) else {
            return nil
        }
        let tagContent = Range(tagMatch.range(at: 2), in: tagText).map { String(tagText[$0]) }
        return (String(tagText[tagNameRange]), tagContent)
    }

    /// "2026-09-24T15:00" (or with seconds, or a space instead of "T") in
    /// the Mac's time zone. A date alone means 9 am that day.
    static func parseLocalDateTime(_ dateTimeText: String) -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        for dateFormat in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            dateFormatter.dateFormat = dateFormat
            if let parsedDate = dateFormatter.date(from: dateTimeText) {
                return parsedDate
            }
        }
        dateFormatter.dateFormat = "yyyy-MM-dd"
        if let dayOnly = dateFormatter.date(from: dateTimeText) {
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: dayOnly)
        }
        return nil
    }

    /// Parses one complete point tag. Returns nil for [POINT:none].
    static func parsePointTag(_ tagText: String) -> VesperPointTag? {
        guard let (tagName, tagContent) = tagNameAndContent(tagText),
              tagName == "POINT",
              let tagContent,
              let coordinates = parseCoordinateContent(tagContent) else {
            return nil
        }
        return VesperPointTag(
            screenshotPixel: coordinates.screenshotPixel,
            elementLabel: coordinates.elementLabel,
            screenNumber: coordinates.screenNumber
        )
    }

    /// Parses one complete [GUIDE:x,y:label:screenN] tag — the same shape
    /// as a point tag.
    static func parseGuideTag(_ tagText: String) -> VesperPointTag? {
        guard let (tagName, tagContent) = tagNameAndContent(tagText),
              tagName == "GUIDE",
              let tagContent,
              let coordinates = parseCoordinateContent(tagContent) else {
            return nil
        }
        return VesperPointTag(
            screenshotPixel: coordinates.screenshotPixel,
            elementLabel: coordinates.elementLabel,
            screenNumber: coordinates.screenNumber
        )
    }

    /// Parses one complete drawing tag ([CIRCLE], [UNDERLINE], [ARROW]).
    /// Returns nil unless it has four numbers (plus an optional label and
    /// screen); a circle or underline of zero size is dropped too.
    static func parseInkTag(_ tagText: String) -> VesperInkTag? {
        guard let (tagName, tagContent) = tagNameAndContent(tagText),
              let tagContent,
              let areaContent = parseAreaContent(tagContent) else {
            return nil
        }
        let inkKind: VesperInkTag.Kind
        switch tagName {
        case "CIRCLE": inkKind = .encircle
        case "UNDERLINE": inkKind = .underline
        case "ARROW": inkKind = .arrow
        default: return nil
        }
        let firstScreenshotPixel = CGPoint(x: areaContent.numbers[0], y: areaContent.numbers[1])
        let secondScreenshotPixel = CGPoint(x: areaContent.numbers[2], y: areaContent.numbers[3])
        if inkKind == .arrow {
            // An arrow needs somewhere to go.
            guard hypot(secondScreenshotPixel.x - firstScreenshotPixel.x, secondScreenshotPixel.y - firstScreenshotPixel.y) >= 4 else { return nil }
        } else {
            guard abs(secondScreenshotPixel.x - firstScreenshotPixel.x) >= 2 else { return nil }
        }
        return VesperInkTag(
            kind: inkKind,
            firstScreenshotPixel: firstScreenshotPixel,
            secondScreenshotPixel: secondScreenshotPixel,
            label: areaContent.label,
            screenNumber: areaContent.screenNumber
        )
    }

    /// "x1,y1,x2,y2", optionally ":label" and/or ":screenN" — the numbers
    /// in the order written.
    private static func parseAreaContent(_ tagContent: String) -> (numbers: [Double], label: String?, screenNumber: Int?)? {
        let searchRange = NSRange(tagContent.startIndex..., in: tagContent)
        guard let areaMatch = areaContentPattern.firstMatch(in: tagContent, range: searchRange) else { return nil }
        let numbers: [Double] = (1...4).compactMap { captureGroupIndex in
            Range(areaMatch.range(at: captureGroupIndex), in: tagContent).flatMap { Double(tagContent[$0]) }
        }
        guard numbers.count == 4 else { return nil }
        var label = Range(areaMatch.range(at: 5), in: tagContent)
            .map { String(tagContent[$0]).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var screenNumber = Range(areaMatch.range(at: 6), in: tagContent)
            .flatMap { Int(tagContent[$0]) }
        // "x1,y1,x2,y2:screen2" with no label: the label group swallows
        // "screen2" (same as for points), so read it as the screen number.
        if screenNumber == nil, let possibleScreenLabel = label,
           possibleScreenLabel.lowercased().hasPrefix("screen"),
           let labelScreenNumber = Int(possibleScreenLabel.dropFirst("screen".count)) {
            screenNumber = labelScreenNumber
            label = nil
        }
        return (numbers, label, screenNumber)
    }

    /// Parses one complete highlight tag. Returns nil unless it has four
    /// numbers (plus an optional label and screen).
    static func parseHighlightTag(_ tagText: String) -> VesperHighlightTag? {
        guard let (tagName, tagContent) = tagNameAndContent(tagText),
              tagName == "HIGHLIGHT",
              let tagContent else {
            return nil
        }
        let searchRange = NSRange(tagContent.startIndex..., in: tagContent)
        guard let areaMatch = areaContentPattern.firstMatch(in: tagContent, range: searchRange) else { return nil }
        let cornerCoordinates: [Double] = (1...4).compactMap { captureGroupIndex in
            Range(areaMatch.range(at: captureGroupIndex), in: tagContent).flatMap { Double(tagContent[$0]) }
        }
        guard cornerCoordinates.count == 4 else { return nil }

        var areaLabel = Range(areaMatch.range(at: 5), in: tagContent)
            .map { String(tagContent[$0]).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var screenNumber = Range(areaMatch.range(at: 6), in: tagContent)
            .flatMap { Int(tagContent[$0]) }
        // "x1,y1,x2,y2:screen2" with no label: the label group swallows
        // "screen2" (same as for points), so read it as the screen number.
        if screenNumber == nil, let possibleScreenLabel = areaLabel,
           possibleScreenLabel.lowercased().hasPrefix("screen"),
           let labelScreenNumber = Int(possibleScreenLabel.dropFirst("screen".count)) {
            screenNumber = labelScreenNumber
            areaLabel = nil
        }

        // Corners written either way round ("bottom-right first") make the same area.
        let screenshotRect = CGRect(
            x: min(cornerCoordinates[0], cornerCoordinates[2]),
            y: min(cornerCoordinates[1], cornerCoordinates[3]),
            width: abs(cornerCoordinates[2] - cornerCoordinates[0]),
            height: abs(cornerCoordinates[3] - cornerCoordinates[1])
        )
        return VesperHighlightTag(screenshotRect: screenshotRect, areaLabel: areaLabel, screenNumber: screenNumber)
    }

    /// Parses one complete action tag. Malformed tags return nil — they are
    /// still never spoken, they just don't do anything.
    static func parseActionTag(_ tagText: String) -> VesperAction? {
        guard let (tagName, tagContent) = tagNameAndContent(tagText) else { return nil }
        let trimmedContent = tagContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch tagName {
        case "OPEN":
            // "https://youtube.com" or "Music", optionally "... | Google Chrome".
            let contentParts = trimmedContent.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let target = contentParts.first, !target.isEmpty else { return nil }
            let applicationName = contentParts.count > 1 && !contentParts[1].isEmpty ? contentParts[1] : nil
            return .open(target: target, inApplicationNamed: applicationName)

        case "MUSIC":
            let lowercasedContent = trimmedContent.lowercased()
            switch lowercasedContent {
            case "play": return .music(.play)
            case "pause", "stop": return .music(.pause)
            case "next", "skip": return .music(.nextTrack)
            case "previous", "back": return .music(.previousTrack)
            default:
                guard lowercasedContent.hasPrefix("play:") else { return nil }
                let searchQuery = String(trimmedContent.dropFirst("play:".count)).trimmingCharacters(in: .whitespaces)
                return searchQuery.isEmpty ? .music(.play) : .music(.playSearchResult(searchQuery: searchQuery))
            }

        case "VOLUME":
            switch trimmedContent.lowercased() {
            case "up": return .volume(.up)
            case "down": return .volume(.down)
            case "mute": return .volume(.mute)
            case "unmute": return .volume(.unmute)
            default:
                guard let percent = Int(trimmedContent.replacingOccurrences(of: "%", with: "")) else { return nil }
                return .volume(.setLevel(percent: max(0, min(100, percent))))
            }

        case "CLICK", "DOUBLECLICK", "RIGHTCLICK":
            guard let coordinates = parseCoordinateContent(trimmedContent) else { return nil }
            let clickKind: VesperClickKind = tagName == "DOUBLECLICK" ? .double : (tagName == "RIGHTCLICK" ? .right : .single)
            return .click(
                screenshotPixel: coordinates.screenshotPixel,
                elementLabel: coordinates.elementLabel,
                screenNumber: coordinates.screenNumber,
                clickKind: clickKind
            )

        case "TYPE":
            // Typed text keeps its own spacing, but never a line break: in
            // chat boxes a line break sends the message, which must only
            // ever happen through a confirmed [KEY:return].
            // Control characters are dropped too: some (like U+0003) act as
            // "insert newline" in Mac text boxes, which can send a message.
            let textWithoutLineBreaks = String(String.UnicodeScalarView(
                (tagContent ?? "").unicodeScalars.map { unicodeScalar in
                    CharacterSet.newlines.contains(unicodeScalar) ? " " : unicodeScalar
                }.filter { unicodeScalar in
                    !CharacterSet.controlCharacters.contains(unicodeScalar)
                }
            ))
            return textWithoutLineBreaks.isEmpty ? nil : .typeText(textWithoutLineBreaks)

        case "KEY":
            return trimmedContent.isEmpty ? nil : .pressKeys(trimmedContent.lowercased())

        case "SCROLL":
            // "down", or "down:640,400" / "down:640,400:screen2" to scroll a
            // specific spot.
            let contentParts = trimmedContent.split(separator: ":", maxSplits: 1).map(String.init)
            guard let directionText = contentParts.first,
                  let direction = VesperScrollDirection(rawValue: directionText.lowercased()) else {
                return nil
            }
            let coordinates = contentParts.count > 1 ? parseCoordinateContent(contentParts[1]) : nil
            return .scroll(
                direction: direction,
                screenshotPixel: coordinates?.screenshotPixel,
                screenNumber: coordinates?.screenNumber
            )

        case "WAIT":
            // "[WAIT]" or "[WAIT:5]" — seconds, kept between 1 and 10.
            let requestedSeconds = Double(trimmedContent.replacingOccurrences(of: "s", with: "")) ?? 3
            return .waitForScreen(seconds: min(max(requestedSeconds, 1), 10))

        case "DONE":
            return .finishTask

        case "REMEMBER":
            return trimmedContent.isEmpty ? nil : .rememberNote(trimmedContent)

        case "FORGET":
            return trimmedContent.isEmpty ? nil : .forgetNotes(trimmedContent)

        case "SHORTCUT":
            return trimmedContent.isEmpty ? nil : .runShortcut(name: trimmedContent)

        case "REMIND":
            // "call mum | 2026-09-24T15:00" — the time is optional.
            let reminderParts = trimmedContent.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let reminderText = reminderParts.first, !reminderText.isEmpty else { return nil }
            let dueDate = reminderParts.count > 1 ? parseLocalDateTime(reminderParts[1]) : nil
            return .createReminder(text: reminderText, dueDate: dueDate)

        case "EVENT":
            // "dentist | 2026-09-25T10:00 | 30" — minutes default to an hour.
            let eventParts = trimmedContent.split(separator: "|", maxSplits: 2).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard eventParts.count >= 2,
                  !eventParts[0].isEmpty,
                  let startDate = parseLocalDateTime(eventParts[1]) else { return nil }
            let requestedMinutes = eventParts.count > 2 ? Int(eventParts[2].filter(\.isNumber)) ?? 60 : 60
            return .createCalendarEvent(title: eventParts[0], startDate: startDate, durationMinutes: min(max(requestedMinutes, 5), 24 * 60))

        case "TIMER":
            // "10m | tea", "90s", "1h30m" — the label is optional.
            let timerParts = trimmedContent.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let durationText = timerParts.first,
                  let durationSeconds = parseTimerDurationSeconds(durationText) else { return nil }
            let timerLabel = timerParts.count > 1 && !timerParts[1].isEmpty ? timerParts[1] : nil
            return .startTimer(durationSeconds: durationSeconds, label: timerLabel)

        case "LOOKUP":
            // "weather:paris", "files:tax return", "screen-text", "weather".
            let lookupParts = trimmedContent.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let kindText = lookupParts.first else { return nil }
            // "screen text" and "screen_text" mean the same as "screen-text".
            let normalizedKindText = kindText.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-")
            guard let lookupKind = VesperLookupKind(rawValue: normalizedKindText) else { return nil }
            let lookupQuery = lookupParts.count > 1 ? String(lookupParts[1].prefix(100)) : ""
            if lookupKind == .files && lookupQuery.isEmpty { return nil }
            return .lookUp(VesperLookupRequest(kind: lookupKind, query: lookupQuery))

        case "RESEARCH":
            // "latest macos version". Vetted later (VesperWebResearchQuestionFilter).
            guard !trimmedContent.isEmpty else { return nil }
            return .researchOnWeb(question: trimmedContent)

        case "BROWSER":
            // "find a lofi playlist on youtube and play it".
            guard !trimmedContent.isEmpty else { return nil }
            return .browserTask(task: trimmedContent)

        case "WINDOW":
            // "left-half", or "left-half | Safari" for an app not in front.
            let windowParts = trimmedContent.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let arrangementText = windowParts.first else { return nil }
            let normalizedArrangementText = arrangementText.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-")
            let arrangementAliases = ["left": "left-half", "right": "right-half", "maximize": "fullscreen", "full-screen": "fullscreen", "centre": "center"]
            guard let arrangement = VesperWindowArrangement(rawValue: arrangementAliases[normalizedArrangementText] ?? normalizedArrangementText) else {
                return nil
            }
            let applicationName = windowParts.count > 1 && !windowParts[1].isEmpty ? windowParts[1] : nil
            return .arrangeWindow(arrangement, applicationName: applicationName)

        case "HIDE":
            return trimmedContent.isEmpty ? nil : .hideApplication(name: trimmedContent)

        case "FOCUS":
            return trimmedContent.isEmpty ? nil : .focusApplication(name: trimmedContent)

        case "QUIT":
            return trimmedContent.isEmpty ? nil : .quitApplication(name: trimmedContent)

        default:
            return nil
        }
    }

    /// The longest timer she'll set. Anything longer is a reminder's job.
    static let maximumTimerSeconds = 24 * 60 * 60

    /// One "number + unit" piece of a duration, like "1h" or "30 min".
    private static let timerDurationPartPattern = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)\b"#
    )

    /// "10m", "90s", "1h30m", "1h 30m", "10 min", "2 minutes", "1.5h" → seconds.
    /// A bare number ("10") means minutes. Nil for anything else, for zero,
    /// or for more than a day, so a garbled tag never sets a strange timer.
    static func parseTimerDurationSeconds(_ durationText: String) -> Int? {
        let lowercasedDurationText = durationText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowercasedDurationText.isEmpty else { return nil }
        if let bareMinutes = Double(lowercasedDurationText) {
            guard bareMinutes.isFinite else { return nil }
            let bareSeconds = Int((bareMinutes * 60).rounded())
            return (1...maximumTimerSeconds).contains(bareSeconds) ? bareSeconds : nil
        }

        // "1h30m" has no break between its parts, so "\b" alone can't find
        // them: split digits from a preceding unit letter first ("1h 30m").
        let spacedDurationText = lowercasedDurationText.replacingOccurrences(
            of: #"([a-z])(\d)"#, with: "$1 $2", options: .regularExpression
        )
        let searchRange = NSRange(spacedDurationText.startIndex..., in: spacedDurationText)
        let durationPartMatches = timerDurationPartPattern.matches(in: spacedDurationText, range: searchRange)
        guard !durationPartMatches.isEmpty else { return nil }

        // Every word must belong to a "number + unit" part (with "and" or
        // commas between them), so "10m of pasta" isn't read as ten minutes.
        let textOutsideDurationParts = timerDurationPartPattern.stringByReplacingMatches(
            in: spacedDurationText, range: searchRange, withTemplate: " "
        )
        let leftoverWords = textOutsideDurationParts
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .filter { $0 != "and" }
        guard leftoverWords.isEmpty else { return nil }

        var totalSeconds = 0.0
        for durationPartMatch in durationPartMatches {
            guard let amountRange = Range(durationPartMatch.range(at: 1), in: spacedDurationText),
                  let unitRange = Range(durationPartMatch.range(at: 2), in: spacedDurationText),
                  let amount = Double(spacedDurationText[amountRange]) else { return nil }
            let unitText = spacedDurationText[unitRange]
            if unitText.hasPrefix("h") {
                totalSeconds += amount * 3600
            } else if unitText.hasPrefix("m") {
                totalSeconds += amount * 60
            } else {
                totalSeconds += amount
            }
        }
        let roundedTotalSeconds = Int(totalSeconds.rounded())
        return (1...maximumTimerSeconds).contains(roundedTotalSeconds) ? roundedTotalSeconds : nil
    }

    private static func parseCoordinateContent(_ coordinateContent: String) -> (screenshotPixel: CGPoint, elementLabel: String?, screenNumber: Int?)? {
        let searchRange = NSRange(coordinateContent.startIndex..., in: coordinateContent)
        guard let coordinateMatch = coordinateContentPattern.firstMatch(in: coordinateContent, range: searchRange),
              let xRange = Range(coordinateMatch.range(at: 1), in: coordinateContent),
              let yRange = Range(coordinateMatch.range(at: 2), in: coordinateContent),
              let pixelX = Double(coordinateContent[xRange]),
              let pixelY = Double(coordinateContent[yRange]) else {
            return nil
        }

        var elementLabel = Range(coordinateMatch.range(at: 3), in: coordinateContent)
            .map { String(coordinateContent[$0]).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var screenNumber = Range(coordinateMatch.range(at: 4), in: coordinateContent)
            .flatMap { Int(coordinateContent[$0]) }

        // "x,y:screen2" with no label: the label group swallows "screen2", so
        // it would click on the wrong monitor. Read it as the screen number.
        if screenNumber == nil, let possibleScreenLabel = elementLabel,
           possibleScreenLabel.lowercased().hasPrefix("screen"),
           let labelScreenNumber = Int(possibleScreenLabel.dropFirst("screen".count)) {
            screenNumber = labelScreenNumber
            elementLabel = nil
        }

        return (CGPoint(x: pixelX, y: pixelY), elementLabel, screenNumber)
    }

    /// Collapses runs of whitespace and trims — what the voice should say.
    private static func normalizedSpokenText(_ text: String) -> String {
        let textWithoutBrokenTags = brokenTagOpeningPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        return textWithoutBrokenTags.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
