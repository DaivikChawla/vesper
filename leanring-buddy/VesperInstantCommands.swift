//
//  VesperInstantCommands.swift
//  leanring-buddy
//
//  The fast lane: plain commands that need no thinking — "set a timer for
//  ten minutes", "volume down", "pause the music", "what time is it",
//  "open music", "open bluetooth settings", "play hk on youtube", "new tab",
//  "dark mode on", "left half", "lock my screen" — are recognized on the
//  Mac and done at once, with a short spoken reply (or none), instead of a
//  3–5 s round trip to Claude with a screenshot. The user: with hands-on
//  off, commands like these shouldn't go to Claude at all.
//
//  Only exact, unambiguous phrasings match; anything else (or anything
//  with more to it, like "pause and tell me what this is") goes to Claude
//  as before. So a miss costs nothing, and a match saves seconds and a
//  request.
//
//  (A model deciding the lane was measured first: Apple's on-device model
//  took 7.6–25 s per decision on this 8 GB Mac. Patterns take microseconds.)
//
//  Plain text matching — no AppKit — so scripts/test-instant-commands.sh
//  checks it directly.
//

import Foundation

/// A command done on the Mac without Claude.
nonisolated enum VesperInstantCommand: Equatable {
    case startTimer(durationSeconds: Int, label: String?)
    case changeVolume(VesperVolumeChange)
    case controlMusic(VesperMusicCommand)
    case tellTime
    case tellDate
    case tellBattery
    /// "open music", "open youtube in safari", "open bluetooth settings":
    /// what the name means (a Settings page, a website, an installed app)
    /// is decided on the Mac; a name that means nothing known goes to
    /// Claude after all.
    case open(targetName: String, browserName: String?)
    /// A results page: "google tsx", "search youtube for lofi".
    case searchWeb(query: String, site: VesperInstantSearchSite)
    /// "play hk on youtube": the top result, found and opened on the Mac.
    case playOnYouTube(query: String)
    /// "new tab", "open chrome new tab".
    case newTab(browserName: String?)
    case pressShortcut(VesperInstantShortcut)
    case scroll(VesperScrollDirection)
    case arrangeWindow(VesperWindowArrangement)
    case quitApplication(name: String)
    case hideApplication(name: String)
    /// nil toggles.
    case setDarkMode(isOn: Bool?)
    case setWiFi(isOn: Bool)
    case changeBrightness(isUp: Bool)
    case lockScreen
    case sleepDisplay
    case takeScreenshot

    /// Everything that acts on the Mac needs control on; words don't.
    var needsQuickActions: Bool {
        switch self {
        case .tellTime, .tellDate, .tellBattery: return false
        default: return true
        }
    }
}

nonisolated enum VesperInstantSearchSite: String, Equatable {
    case google
    case youtube
}

/// Keyboard shortcuts for the front app (browser tabs and pages mostly).
nonisolated enum VesperInstantShortcut: String, Equatable {
    case closeTab
    case reopenClosedTab
    case nextTab
    case previousTab
    case goBack
    case goForward
    case reload
    case zoomIn
    case zoomOut
    case scrollToTop
    case scrollToBottom
    case minimizeWindow

    /// The keys, in VesperKeyCombination's spelling.
    var keyCombinationText: String {
        switch self {
        case .closeTab: return "cmd+w"
        case .reopenClosedTab: return "cmd+shift+t"
        case .nextTab: return "ctrl+tab"
        case .previousTab: return "ctrl+shift+tab"
        case .goBack: return "cmd+["
        case .goForward: return "cmd+]"
        case .reload: return "cmd+r"
        case .zoomIn: return "cmd+="
        case .zoomOut: return "cmd+-"
        case .scrollToTop: return "cmd+up"
        case .scrollToBottom: return "cmd+down"
        case .minimizeWindow: return "cmd+m"
        }
    }
}

nonisolated enum VesperInstantCommands {
    /// The command in what they said, or nil when it should go to Claude.
    static func command(in spokenText: String) -> VesperInstantCommand? {
        let normalizedText = normalized(spokenText)
        guard !normalizedText.isEmpty, normalizedText.split(separator: " ").count <= 12 else { return nil }

        if let timerCommand = timerCommand(in: normalizedText) { return timerCommand }
        if let volumeCommand = volumeCommand(in: normalizedText) { return volumeCommand }
        if let musicCommand = musicCommand(in: normalizedText) { return musicCommand }
        if let systemCommand = systemCommand(in: normalizedText) { return systemCommand }
        if let browserCommand = browserCommand(in: normalizedText) { return browserCommand }
        if let windowCommand = windowCommand(in: normalizedText) { return windowCommand }
        // Last: "open …" is the widest pattern, so the specific ones above
        // ("open a new tab", "open youtube and play …") win first.
        if let openCommand = openCommand(in: normalizedText) { return openCommand }
        if matches(normalizedText, #"^(what time is it( now| right now)?|what('s| is) the time( now| right now)?|tell me the time|time)$"#) {
            return .tellTime
        }
        if matches(normalizedText, #"^(what('s| is) (the |today's )?date( today)?|what day is (it|today)|what's today)$"#) {
            return .tellDate
        }
        if matches(normalizedText, #"^((how much |what('s| is) (my |the )?)?battery( (left|level|percentage|percent|status|at))?|how much battery (do i have|is left|have i got)( left)?|how much charge (do i have|is left))$"#) {
            return .tellBattery
        }
        return nil
    }

    // MARK: Open, Search and YouTube

    /// Words that mean "something on screen", never an app or site name:
    /// those requests need Claude to look.
    private static let pointingTargetWords: Set<String> = [
        "this", "that", "it", "these", "those", "here", "there", "file", "folder", "link", "document", "page",
        "first", "second", "third", "last", "latest", "one", "image", "photo", "video", "email", "mail", "message", "chat", "tab", "window"
    ]
    private static let browserNamePattern = #"(google chrome|chrome|safari|arc|firefox|brave|edge|microsoft edge|opera)"#

    private static func openCommand(in normalizedText: String) -> VesperInstantCommand? {
        let openPattern = #"^(?:open|launch|start|run|fire up|bring up|pull up|switch to|go to)\s+(?:up\s+)?(?:the\s+|my\s+)?(.+?)(?:\s+app)?(?:\s+(?:in|on|with)\s+"# + browserNamePattern + #")?$"#
        guard let captures = firstMatchCaptures(normalizedText, openPattern), let targetName = captures.first ?? nil else { return nil }
        let targetWords = targetName.split(separator: " ").map(String.init)
        // "open fiverr and check my messages" is a task, not a name.
        guard !targetWords.isEmpty, targetWords.count <= 4,
              !targetWords.contains("and"), !targetWords.contains("then"), !targetWords.contains("to"),
              targetWords.allSatisfy({ !pointingTargetWords.contains($0) }) else { return nil }
        return .open(targetName: targetName, browserName: captures.count > 1 ? captures[1] : nil)
    }

    private static func searchCommand(in normalizedText: String) -> VesperInstantCommand? {
        let searchPatterns: [(pattern: String, queryGroup: Int, siteGroup: Int?)] = [
            (#"^(?:search|look up|find)\s+(?:for\s+)?(.+?)\s+on\s+(google|youtube|you tube)$"#, 0, 1),
            (#"^search\s+(?:on\s+)?(google|youtube|you tube)\s+for\s+(.+)$"#, 1, 0),
            (#"^(?:open\s+)?(google|youtube|you tube)\s+(?:and\s+)?search\s+(?:for\s+)?(.+)$"#, 1, 0),
            (#"^google\s+(.+)$"#, 0, nil)
        ]
        for searchPattern in searchPatterns {
            guard let captures = firstMatchCaptures(normalizedText, searchPattern.pattern),
                  searchPattern.queryGroup < captures.count, let query = captures[searchPattern.queryGroup], !query.isEmpty else { continue }
            // "google chrome" is the browser, not a search.
            if searchPattern.siteGroup == nil && matches(query, #"^(chrome|docs|drive|sheets|slides|maps|meet|calendar)$"#) { continue }
            let siteText = searchPattern.siteGroup.flatMap { $0 < captures.count ? captures[$0] : nil } ?? "google"
            return .searchWeb(query: query, site: siteText.contains("tube") ? .youtube : .google)
        }
        return nil
    }

    private static func playOnYouTubeCommand(in normalizedText: String) -> VesperInstantCommand? {
        let playPatterns = [
            #"^(?:play|put on|play me|start)\s+(?:the\s+)?(.+?)\s+(?:on|in|from)\s+(?:youtube|you tube|yt)$"#,
            #"^(?:open|go to)\s+(?:youtube|you tube)\s+(?:and\s+)?(?:play|put on|start)\s+(.+)$"#,
            #"^(?:youtube|you tube)\s+play\s+(.+)$"#
        ]
        for playPattern in playPatterns {
            guard let captures = firstMatchCaptures(normalizedText, playPattern), let query = captures.first ?? nil else { continue }
            let cleanedQuery = query
                .replacingOccurrences(of: #"^(?:a|the|some|me)\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+(?:video|song|music video)$"#, with: "", options: .regularExpression)
            guard !cleanedQuery.isEmpty, cleanedQuery.split(separator: " ").count <= 9 else { continue }
            return .playOnYouTube(query: cleanedQuery)
        }
        return nil
    }

    // MARK: Browser and Pages

    private static func browserCommand(in normalizedText: String) -> VesperInstantCommand? {
        if let playCommand = playOnYouTubeCommand(in: normalizedText) { return playCommand }
        if let searchCommand = searchCommand(in: normalizedText) { return searchCommand }
        // "new tab", "open a new tab", "new tab in safari", "open chrome new tab", "open chrome and open a new tab".
        if let captures = firstMatchCaptures(normalizedText, #"^(?:open\s+|make\s+|give me\s+)?(?:a\s+)?new\s+tab(?:\s+in\s+"# + browserNamePattern + #")?$"#) {
            return .newTab(browserName: captures.first ?? nil)
        }
        if let captures = firstMatchCaptures(normalizedText, #"^(?:open|launch)\s+"# + browserNamePattern + #"\s+(?:and\s+)?(?:open\s+)?(?:a\s+)?new\s+tab$"#) {
            return .newTab(browserName: captures.first ?? nil)
        }
        let shortcutPatterns: [(pattern: String, shortcut: VesperInstantShortcut)] = [
            (#"^close\s+(?:this\s+|the\s+|current\s+|that\s+)?tab$"#, .closeTab),
            (#"^(?:reopen|restore|bring back|undo close)\s+(?:the\s+)?(?:last\s+)?(?:closed\s+)?tab$"#, .reopenClosedTab),
            (#"^(?:go to\s+|switch to\s+)?(?:the\s+)?next\s+tab$"#, .nextTab),
            (#"^(?:go to\s+|switch to\s+)?(?:the\s+)?(?:previous|last)\s+tab$"#, .previousTab),
            (#"^(?:go\s+)?back(?:\s+a\s+page|\s+one\s+page)?$"#, .goBack),
            (#"^(?:go\s+)?forward(?:\s+a\s+page|\s+one\s+page)?$"#, .goForward),
            (#"^(?:reload|refresh)(?:\s+(?:the|this))?(?:\s+(?:page|tab|site))?$"#, .reload),
            (#"^zoom\s+in$"#, .zoomIn),
            (#"^zoom\s+out$"#, .zoomOut),
            (#"^(?:scroll|go|jump)\s+(?:all the way\s+)?(?:up\s+)?to\s+the\s+top(?:\s+of\s+the\s+page)?$"#, .scrollToTop),
            (#"^(?:scroll|go|jump)\s+(?:all the way\s+)?(?:down\s+)?to\s+the\s+bottom(?:\s+of\s+the\s+page)?$"#, .scrollToBottom)
        ]
        for shortcutPattern in shortcutPatterns where matches(normalizedText, shortcutPattern.pattern) {
            return .pressShortcut(shortcutPattern.shortcut)
        }
        if let captures = firstMatchCaptures(normalizedText, #"^scroll\s+(up|down)(?:\s+a\s+bit|\s+a\s+little)?$"#),
           let directionText = captures.first ?? nil, let direction = VesperScrollDirection(rawValue: directionText) {
            return .scroll(direction)
        }
        return nil
    }

    // MARK: Windows and Apps

    private static func windowCommand(in normalizedText: String) -> VesperInstantCommand? {
        let windowWords = #"(?:it|this|the window|this window|that)"#
        if let captures = firstMatchCaptures(normalizedText, #"^(?:(?:put|move|snap|send)\s+"# + windowWords + #"\s+(?:to\s+|on\s+)?(?:the\s+)?)?(left|right)\s+(?:half|side)(?:\s+of\s+the\s+screen)?$"#),
           let sideText = captures.first ?? nil {
            return .arrangeWindow(sideText == "left" ? .leftHalf : .rightHalf)
        }
        if matches(normalizedText, #"^(?:make\s+"# + windowWords + #"\s+)?(?:full\s?screen|maximi[sz]ed?)(?:\s+"# + windowWords + #")?$"#)
            || matches(normalizedText, #"^maximi[sz]e\s+"# + windowWords + #"$"#) {
            return .arrangeWindow(.fullscreen)
        }
        if matches(normalizedText, #"^cent(?:er|re)\s+"# + windowWords + #"$"#) {
            return .arrangeWindow(.center)
        }
        if matches(normalizedText, #"^(?:move|send|put)\s+"# + windowWords + #"\s+to\s+(?:the\s+)?(?:other|next|second)\s+(?:screen|monitor|display)$"#) {
            return .arrangeWindow(.nextScreen)
        }
        if matches(normalizedText, #"^minimi[sz]e(?:\s+"# + windowWords + #")?$"#) {
            return .pressShortcut(.minimizeWindow)
        }
        if let captures = firstMatchCaptures(normalizedText, #"^(?:quit|close)\s+(?:the\s+)?(.+?)(?:\s+app)?$"#),
           let applicationName = captures.first ?? nil, isPlausibleApplicationName(applicationName) {
            return .quitApplication(name: applicationName)
        }
        if let captures = firstMatchCaptures(normalizedText, #"^hide\s+(?:the\s+)?(.+?)(?:\s+app)?$"#),
           let applicationName = captures.first ?? nil, isPlausibleApplicationName(applicationName) {
            return .hideApplication(name: applicationName)
        }
        return nil
    }

    /// One to three words, none of them about something on screen.
    private static func isPlausibleApplicationName(_ applicationName: String) -> Bool {
        let nameWords = applicationName.split(separator: " ").map(String.init)
        return !nameWords.isEmpty && nameWords.count <= 3
            && nameWords.allSatisfy { !pointingTargetWords.contains($0) && $0 != "and" && $0 != "all" && $0 != "everything" }
    }

    // MARK: System

    private static func systemCommand(in normalizedText: String) -> VesperInstantCommand? {
        // Dark mode.
        if let captures = firstMatchCaptures(normalizedText, #"^(?:turn|switch|put)\s+(on|off)\s+(?:the\s+)?dark\s+mode$"#)
            ?? firstMatchCaptures(normalizedText, #"^(?:turn|switch|put)\s+(?:the\s+)?dark\s+mode\s+(on|off)$"#)
            ?? firstMatchCaptures(normalizedText, #"^dark\s+mode\s+(on|off)$"#),
           let stateText = captures.first ?? nil {
            return .setDarkMode(isOn: stateText == "on")
        }
        if let captures = firstMatchCaptures(normalizedText, #"^(enable|disable)\s+dark\s+mode$"#), let verb = captures.first ?? nil {
            return .setDarkMode(isOn: verb == "enable")
        }
        if let captures = firstMatchCaptures(normalizedText, #"^(?:(?:switch|change|go)\s+(?:to\s+)?|use\s+|turn\s+on\s+)?(dark|light)\s+mode$"#),
           let modeText = captures.first ?? nil {
            return .setDarkMode(isOn: modeText == "dark")
        }
        if matches(normalizedText, #"^toggle\s+(?:the\s+)?(?:dark|light)\s+mode$"#) {
            return .setDarkMode(isOn: nil)
        }
        // Wi-Fi.
        let wifiWord = #"(?:the\s+)?wi[- ]?fi"#
        if let captures = firstMatchCaptures(normalizedText, #"^(?:turn|switch)\s+(on|off)\s+"# + wifiWord + #"$"#)
            ?? firstMatchCaptures(normalizedText, #"^(?:turn|switch)\s+"# + wifiWord + #"\s+(on|off)$"#)
            ?? firstMatchCaptures(normalizedText, #"^wi[- ]?fi\s+(on|off)$"#),
           let stateText = captures.first ?? nil {
            return .setWiFi(isOn: stateText == "on")
        }
        if let captures = firstMatchCaptures(normalizedText, #"^(enable|disable)\s+"# + wifiWord + #"$"#), let verb = captures.first ?? nil {
            return .setWiFi(isOn: verb == "enable")
        }
        // Brightness.
        if matches(normalizedText, #"^((?:turn\s+)?(?:the\s+)?(?:screen\s+|display\s+)?brightness\s+up|(?:increase|raise)\s+(?:the\s+)?(?:screen\s+)?brightness|(?:make\s+(?:the\s+)?screen\s+)?brighter)$"#) {
            return .changeBrightness(isUp: true)
        }
        if matches(normalizedText, #"^((?:turn\s+)?(?:the\s+)?(?:screen\s+|display\s+)?brightness\s+down|(?:decrease|lower|reduce)\s+(?:the\s+)?(?:screen\s+)?brightness|(?:make\s+(?:the\s+)?screen\s+)?(?:dimmer|darker)|dim\s+(?:the\s+)?screen)$"#) {
            return .changeBrightness(isUp: false)
        }
        // Lock, sleep, screenshot.
        if matches(normalizedText, #"^lock\s+(?:my\s+|the\s+)?(?:screen|mac|computer|laptop|it)$"#) {
            return .lockScreen
        }
        if matches(normalizedText, #"^((?:turn\s+off|sleep)\s+(?:the\s+|my\s+)?(?:screen|display|monitor)|put\s+(?:the\s+|my\s+)?(?:screen|display)\s+to\s+sleep)$"#) {
            return .sleepDisplay
        }
        if matches(normalizedText, #"^((?:take|grab|capture)\s+(?:a\s+)?(?:screenshot|screen shot)(?:\s+of\s+(?:the|my)\s+screen)?|screenshot)$"#) {
            return .takeScreenshot
        }
        return nil
    }

    // MARK: Timers

    private static func timerCommand(in normalizedText: String) -> VesperInstantCommand? {
        // "set a timer for ten minutes (for pasta)", "timer 5 minutes",
        // "start a 10 minute timer (for tea)", "ten minute timer".
        let timerPatterns = [
            #"^(?:(?:set|start|put on|give me|make)\s+)?(?:(?:a|an|the)\s+)?(?:timer|countdown)\s+(?:for\s+)?(.+?)(?:\s+(?:for|called|named|labelled|labeled)\s+(.+))?$"#,
            #"^(?:(?:set|start|put on|give me|make)\s+)?(?:(?:a|an|the)\s+)?(.+?)\s+(?:timer|countdown)(?:\s+(?:for|called|named)\s+(.+))?$"#
        ]
        for timerPattern in timerPatterns {
            guard let captures = firstMatchCaptures(normalizedText, timerPattern),
                  let durationText = captures.first ?? nil,
                  let durationSeconds = spokenDurationSeconds(durationText),
                  durationSeconds >= 5, durationSeconds <= 24 * 3600 else { continue }
            let label = captures.count > 1 ? captures[1].flatMap { $0.isEmpty ? nil : $0 } : nil
            return .startTimer(durationSeconds: durationSeconds, label: label)
        }
        return nil
    }

    /// "ten minutes", "1 hour and 30 minutes", "90 seconds", "half an
    /// hour", "an hour", "2 and a half minutes", "5 min".
    static func spokenDurationSeconds(_ durationText: String) -> Int? {
        var remainingText = durationText
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        if matches(remainingText, #"^half an? hour$"#) { return 1800 }
        if matches(remainingText, #"^(a|an|one) hour and a half$"#) { return 5400 }
        if matches(remainingText, #"^(a|an) quarter of an hour$"#) { return 900 }

        let unitSeconds: [(pattern: String, seconds: Int)] = [
            (#"^(hours?|hrs?|h)$"#, 3600),
            (#"^(minutes?|mins?|m)$"#, 60),
            (#"^(seconds?|secs?|s)$"#, 1)
        ]
        var totalSeconds = 0
        var didReadAnyAmount = false
        remainingText = remainingText.replacingOccurrences(of: " and a half", with: " and_a_half")
        var words = remainingText.split(separator: " ").map(String.init).filter { $0 != "and" }
        while !words.isEmpty {
            // An amount, then a unit.
            var amount: Double?
            var consumedWordCount = 0
            if let numericAmount = Double(words[0]) {
                amount = numericAmount
                consumedWordCount = 1
            } else if let (wordAmount, wordCount) = numberFromWords(words) {
                amount = Double(wordAmount)
                consumedWordCount = wordCount
            } else if words[0] == "a" || words[0] == "an" {
                amount = 1
                consumedWordCount = 1
            }
            guard let parsedAmount = amount, consumedWordCount < words.count else { return nil }
            var unitWord = words[consumedWordCount]
            var halfExtra = 0.0
            if unitWord == "and_a_half", consumedWordCount + 1 < words.count {
                halfExtra = 0.5
                consumedWordCount += 1
                unitWord = words[consumedWordCount]
            }
            guard let unit = unitSeconds.first(where: { matches(unitWord, $0.pattern) }) else { return nil }
            if consumedWordCount + 1 < words.count, words[consumedWordCount + 1] == "and_a_half" {
                halfExtra = 0.5
                consumedWordCount += 1
            }
            totalSeconds += Int(((parsedAmount + halfExtra) * Double(unit.seconds)).rounded())
            didReadAnyAmount = true
            words.removeFirst(consumedWordCount + 1)
        }
        return didReadAnyAmount && totalSeconds > 0 ? totalSeconds : nil
    }

    /// "twenty five" → (25, 2 words); "ten" → (10, 1).
    private static func numberFromWords(_ words: [String]) -> (Int, Int)? {
        let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                     "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
                     "seventeen": 17, "eighteen": 18, "nineteen": 19]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        guard let firstWord = words.first else { return nil }
        if let unitValue = units[firstWord] { return (unitValue, 1) }
        if let tensValue = tens[firstWord] {
            if words.count > 1, let unitValue = units[words[1]], unitValue < 10, unitValue > 0 {
                return (tensValue + unitValue, 2)
            }
            return (tensValue, 1)
        }
        return nil
    }

    // MARK: Volume

    private static func volumeCommand(in normalizedText: String) -> VesperInstantCommand? {
        if matches(normalizedText, #"^((turn|crank|bring) (it|the volume|the sound|volume) up|(turn )?(the )?volume up|louder|make it louder|increase (the )?volume)$"#) {
            return .changeVolume(.up)
        }
        if matches(normalizedText, #"^((turn|bring) (it|the volume|the sound|volume) down|(turn )?(the )?volume down|quieter|softer|make it quieter|lower (the )?volume|decrease (the )?volume)$"#) {
            return .changeVolume(.down)
        }
        if matches(normalizedText, #"^(mute|mute (it|the sound|the volume|my mac|the mac)|go quiet)$"#) {
            return .changeVolume(.mute)
        }
        if matches(normalizedText, #"^(unmute|unmute (it|the sound|the volume|my mac|the mac))$"#) {
            return .changeVolume(.unmute)
        }
        if let captures = firstMatchCaptures(normalizedText, #"^(?:(?:set|turn|put) )?(?:the )?volume (?:to |at )?(.+?)(?: percent| %)?$"#),
           let amountText = captures.first ?? nil {
            let amountWords = amountText.split(separator: " ").map(String.init)
            let percent = Int(amountText) ?? numberFromWords(amountWords).flatMap { $0.1 == amountWords.count ? $0.0 : nil }
            if let percent, (0...100).contains(percent) {
                return .changeVolume(.setLevel(percent: percent))
            }
        }
        return nil
    }

    // MARK: Music

    private static func musicCommand(in normalizedText: String) -> VesperInstantCommand? {
        if matches(normalizedText, #"^(pause|pause (it|the music|the song|music|this song|playback)|stop the music|stop music)$"#) {
            return .controlMusic(.pause)
        }
        if matches(normalizedText, #"^(resume|resume (the )?music|play the music|play music|unpause|keep playing|continue playing)$"#) {
            return .controlMusic(.play)
        }
        if matches(normalizedText, #"^(next|next (song|track)|skip|skip (it|this|this song|the song|this track|song|track)|play the next (song|track))$"#) {
            return .controlMusic(.nextTrack)
        }
        if matches(normalizedText, #"^(previous|previous (song|track)|go back a (song|track)|last song|play the last (song|track)|play the previous (song|track))$"#) {
            return .controlMusic(.previousTrack)
        }
        return nil
    }

    // MARK: What She Says

    /// The short line she says once it's done.
    static func spokenLine(for instantCommand: VesperInstantCommand, now: Date = Date()) -> String {
        switch instantCommand {
        case .startTimer(let durationSeconds, let label):
            let durationText = spokenDuration(seconds: durationSeconds)
            if let label, !label.isEmpty {
                return "\(durationText) timer for \(label), starting now."
            }
            return "\(durationText) timer, starting now."
        case .changeVolume(let volumeChange):
            switch volumeChange {
            case .up: return "louder."
            case .down: return "quieter."
            case .mute: return "muted."
            case .unmute: return "sound's back."
            case .setLevel(let percent): return "volume at \(percent) percent."
            }
        case .controlMusic(let musicCommand):
            switch musicCommand {
            case .play: return "playing."
            case .pause: return "paused."
            case .nextTrack: return "skipping."
            case .previousTrack: return "going back one."
            case .playSearchResult: return "playing."
            }
        case .tellTime:
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            return "it's \(timeFormatter.string(from: now).lowercased())."
        case .tellDate:
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, d MMMM"
            return "it's \(dateFormatter.string(from: now).lowercased())."
        case .setDarkMode(let isOn):
            switch isOn {
            case true?: return "dark mode on."
            case false?: return "light mode."
            case nil: return "switched."
            }
        case .setWiFi(let isOn):
            return isOn ? "wi-fi on." : "wi-fi off."
        case .searchWeb(let query, _):
            return "here's \(query)."
        case .playOnYouTube(let query):
            return "playing \(query)."
        // Things you can see happen need no words.
        case .tellBattery, .open, .newTab, .pressShortcut, .scroll, .arrangeWindow, .quitApplication,
             .hideApplication, .changeBrightness, .lockScreen, .sleepDisplay, .takeScreenshot:
            return ""
        }
    }

    // MARK: YouTube Results

    /// The first real result on a YouTube search page: the first
    /// `"videoRenderer":{"videoId":"…"}` (ads use other renderers). Nil when
    /// the page doesn't have one (a consent page, a changed layout).
    static func firstVideoIdentifier(inYouTubeSearchPage searchPageHTML: String) -> String? {
        guard let captures = firstMatchCaptures(searchPageHTML, #""videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})""#),
              let videoIdentifier = captures.first ?? nil else { return nil }
        return videoIdentifier
    }

    /// "ten minute", "1 hour 30 minute", "90 second" — the adjective form
    /// ("a ten minute timer").
    static func spokenDuration(seconds totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour") }
        if minutes > 0 { parts.append("\(minutes) minute") }
        if seconds > 0 { parts.append("\(seconds) second") }
        return parts.joined(separator: " ")
    }

    // MARK: Text Helpers

    /// Lowercased, punctuation and fillers gone: "Hey Vesper, pause the
    /// music please." → "pause the music".
    static func normalized(_ spokenText: String) -> String {
        var text = spokenText.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        text = String(text.map { character in
            character.isLetter || character.isNumber || character == "'" || character == "%" || character == "-" ? character : " "
        })
        var words = text.split(separator: " ").map(String.init)
        let leadingFillers: Set<String> = ["hey", "vesper", "whisper", "vespa", "okay", "ok", "please", "can", "could", "you", "just", "um", "uh", "so"]
        while let firstWord = words.first, leadingFillers.contains(firstWord) {
            words.removeFirst()
        }
        let trailingFillers: Set<String> = ["please", "thanks", "thank", "you", "vesper", "now"]
        while let lastWord = words.last, trailingFillers.contains(lastWord) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The capture groups of the first match (nil for a group that didn't take part).
    private static func firstMatchCaptures(_ text: String, _ pattern: String) -> [String?]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { groupIndex in
            Range(match.range(at: groupIndex), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }
}
