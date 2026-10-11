#!/bin/zsh
#
# Tests VesperResponseStreamParser — the code that turns Claude's streamed
# reply into spoken sentences and pulls out [POINT] tags — without building
# the app. Compiles the parser with a small test program into a temporary
# folder (no app bundle, no signing, no permission impact) and runs it.
#
# Each reply is fed one character at a time, the worst case for tags that
# get split across streamed chunks.
#
# Usage: scripts/test-response-parser.sh

set -euo pipefail
cd "$(dirname "$0")/.."

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

cat > "$temporary_directory/main.swift" <<'SWIFT'
import Foundation

var failureCount = 0

func describe(_ action: VesperAction) -> String {
    switch action {
    case .open(let target, let applicationName):
        return "open(\(target)\(applicationName.map { " in " + $0 } ?? ""))"
    case .music(let command):
        return "music(\(command))"
    case .volume(let change):
        return "volume(\(change))"
    case .runShortcut(let shortcutName):
        return "shortcut(\(shortcutName))"
    case .click(let pixel, let label, let screenNumber, let clickKind):
        return "click.\(clickKind)(\(Int(pixel.x)),\(Int(pixel.y)):\(label ?? "")\(screenNumber.map { ":screen\($0)" } ?? ""))"
    case .typeText(let text):
        return "type(\(text))"
    case .pressKeys(let keys):
        return "key(\(keys))"
    case .scroll(let direction, let pixel, _):
        return "scroll(\(direction.rawValue)\(pixel.map { ":\(Int($0.x)),\(Int($0.y))" } ?? ""))"
    case .waitForScreen(let seconds):
        return "wait(\(Int(seconds)))"
    case .finishTask:
        return "done"
    case .rememberNote(let noteText):
        return "remember(\(noteText))"
    case .forgetNotes(let searchText):
        return "forget(\(searchText))"
    case .createReminder(let reminderText, let dueDate):
        return "remind(\(reminderText)\(dueDate.map { " @" + timeText($0) } ?? ""))"
    case .createCalendarEvent(let eventTitle, let startDate, let durationMinutes):
        return "event(\(eventTitle) @\(timeText(startDate)) \(durationMinutes)m)"
    case .startTimer(let durationSeconds, let timerLabel):
        return "timer(\(durationSeconds)s\(timerLabel.map { " " + $0 } ?? ""))"
    case .arrangeWindow(let arrangement, let applicationName):
        return "window(\(arrangement.rawValue)\(applicationName.map { " in " + $0 } ?? ""))"
    case .hideApplication(let applicationName):
        return "hide(\(applicationName))"
    case .focusApplication(let applicationName):
        return "focus(\(applicationName))"
    case .quitApplication(let applicationName):
        return "quit(\(applicationName))"
    case .lookUp(let lookupRequest):
        return "lookup(\(lookupRequest.kind.rawValue)\(lookupRequest.query.isEmpty ? "" : ":" + lookupRequest.query))"
    case .researchOnWeb(let question):
        return "research(\(question))"
    case .browserTask(let task):
        return "browser(\(task))"
    }
}

func timeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func describe(_ segment: VesperResponseSegment) -> String {
    var description = segment.spokenText
    if let pointTag = segment.pointTag {
        let screenSuffix = pointTag.screenNumber.map { ":screen\($0)" } ?? ""
        description += " @(\(Int(pointTag.screenshotPixel.x)),\(Int(pointTag.screenshotPixel.y))):\(pointTag.elementLabel ?? "")\(screenSuffix)"
    }
    if let highlightTag = segment.highlightTag {
        let highlightRect = highlightTag.screenshotRect
        let screenSuffix = highlightTag.screenNumber.map { ":screen\($0)" } ?? ""
        description += " #(\(Int(highlightRect.minX)),\(Int(highlightRect.minY)),\(Int(highlightRect.maxX)),\(Int(highlightRect.maxY))):\(highlightTag.areaLabel ?? "")\(screenSuffix)"
    }
    for inkTag in segment.inkTags {
        let inkKindName: String
        switch inkTag.kind {
        case .encircle: inkKindName = "circle"
        case .underline: inkKindName = "underline"
        case .arrow: inkKindName = "arrow"
        }
        let screenSuffix = inkTag.screenNumber.map { ":screen\($0)" } ?? ""
        description += " ~\(inkKindName)(\(Int(inkTag.firstScreenshotPixel.x)),\(Int(inkTag.firstScreenshotPixel.y)),\(Int(inkTag.secondScreenshotPixel.x)),\(Int(inkTag.secondScreenshotPixel.y))):\(inkTag.label ?? "")\(screenSuffix)"
    }
    if let guideTag = segment.guideTag {
        let screenSuffix = guideTag.screenNumber.map { ":screen\($0)" } ?? ""
        description += " >(\(Int(guideTag.screenshotPixel.x)),\(Int(guideTag.screenshotPixel.y))):\(guideTag.elementLabel ?? "")\(screenSuffix)"
    }
    for action in segment.actions {
        description += " +" + describe(action)
    }
    return description
}

func expect(_ testName: String, reply: String, chunkSize: Int = 1, segments expectedSegments: [String]) {
    let parser = VesperResponseStreamParser()
    var producedSegments: [VesperResponseSegment] = []
    var chunkStart = reply.startIndex
    while chunkStart < reply.endIndex {
        let chunkEnd = reply.index(chunkStart, offsetBy: chunkSize, limitedBy: reply.endIndex) ?? reply.endIndex
        producedSegments += parser.appendTextDelta(String(reply[chunkStart..<chunkEnd]))
        chunkStart = chunkEnd
    }
    producedSegments += parser.finish()

    let producedDescriptions = producedSegments.map(describe)
    if producedDescriptions == expectedSegments {
        print("✅ \(testName)")
    } else {
        failureCount += 1
        print("❌ \(testName)\n   expected: \(expectedSegments)\n   got:      \(producedDescriptions)")
    }
}

expect("tag first attaches to the first sentence",
       reply: "[POINT:285,11:source control] source control menu, top of the screen. hit commit, or command option c.",
       segments: ["source control menu, top of the screen. @(285,11):source control",
                  "hit commit, or command option c."])

expect("inline tags walk through steps",
       reply: "[POINT:40,11:file menu] open the file menu, [POINT:120,236:export] then hit export down here, and pick png.",
       segments: ["open the file menu, @(40,11):file menu",
                  "then hit export down here, and pick png. @(120,236):export"])

expect("[POINT:none] is dropped silently",
       reply: "it's the skeleton of every web page. [POINT:none]",
       segments: ["it's the skeleton of every web page."])

expect("an old-style tag at the end still points",
       reply: "other screen. that terminal is where it's happening. [POINT:400,300:terminal:screen2]",
       segments: ["other screen.", "that terminal is where it's happening.", " @(400,300):terminal:screen2"])

expect("a tag cut off at the end of the reply is never spoken",
       reply: "hello there [POINT:12,",
       segments: ["hello there"])

expect("ordinary brackets are spoken normally",
       reply: "use array [1] here, it's fine.",
       segments: ["use array [1] here, it's fine."])

expect("a long first sentence splits early at a comma",
       reply: "so the thing about this particular build error is that swift can't infer the type, which means you need an explicit annotation.",
       segments: ["so the thing about this particular build error is that swift can't infer the type,",
                  "which means you need an explicit annotation."])

expect("larger streamed chunks behave the same",
       reply: "[POINT:10,20:save] hit save. done.",
       chunkSize: 7,
       segments: ["hit save. @(10,20):save", "done."])

expect("a quick action attaches to the sentence after it",
       reply: "[OPEN:https://www.youtube.com/results?search_query=lofi | Google Chrome] opening youtube in chrome.",
       segments: ["opening youtube in chrome. +open(https://www.youtube.com/results?search_query=lofi in Google Chrome)"])

expect("music and volume tags",
       reply: "[MUSIC:play:bohemian rhapsody][VOLUME:40] queen, at a civilised volume.",
       segments: ["queen, at a civilised volume. +music(playSearchResult(searchQuery: \"bohemian rhapsody\")) +volume(setLevel(percent: 40))"])

expect("a silent hands-on step keeps its actions in order",
       reply: "[CLICK:640,88:search box][TYPE:lofi beats: study mix][KEY:return]",
       segments: [" +click.single(640,88:search box) +type(lofi beats: study mix) +key(return)"])

expect("typed text with sentence punctuation is never split or spoken",
       reply: "[TYPE:hi there. thanks! see you soon.] typed it.",
       segments: ["typed it. +type(hi there. thanks! see you soon.)"])

expect("typed text containing an opening bracket is held until the tag closes",
       reply: "[TYPE:see [the attached. file] typed.",
       segments: ["typed. +type(see [the attached. file)"])

expect("line breaks inside typed text become spaces",
       reply: "[TYPE:line one\nline two] done.",
       segments: ["done. +type(line one line two)"])

expect("double click, right click, scroll and done",
       reply: "[DOUBLECLICK:10,20:file:screen2][RIGHTCLICK:30,40][SCROLL:down:500,600][DONE] all set.",
       segments: ["all set. +click.double(10,20:file:screen2) +click.right(30,40:) +scroll(down:500,600) +done"])

expect("a hands-on tag cut off at the end is never spoken",
       reply: "clicking now [CLICK:12,",
       segments: ["clicking now"])

expect("a tag-name fragment cut off at the end is never spoken",
       reply: "one sec [CLI",
       segments: ["one sec"])

expect("unknown bracket words are still spoken",
       reply: "press [ctrl] and [c]. [KEYS] too.",
       segments: ["press [ctrl] and [c].", "[KEYS] too."])

expect("action tags in bigger chunks",
       reply: "[OPEN:Music] opening music. [MUSIC:play] [DONE]",
       chunkSize: 5,
       segments: ["opening music. +open(Music)", " +music(play) +done"])

expect("control characters are removed from typed text",
       reply: "[TYPE:hi\u{0003}there] ok.",
       segments: ["ok. +type(hithere)"])

do {
    // An unclosed "[TYPE:" followed by a long reply: past the tag length cap
    // it's ordinary text, so nothing is typed and the rest is still spoken.
    let runawayParser = VesperResponseStreamParser()
    let runawayReply = "[TYPE:oops " + String(repeating: "word ", count: 150) + "] after."
    var runawaySegments: [VesperResponseSegment] = []
    var chunkStart = runawayReply.startIndex
    while chunkStart < runawayReply.endIndex {
        let chunkEnd = runawayReply.index(chunkStart, offsetBy: 40, limitedBy: runawayReply.endIndex) ?? runawayReply.endIndex
        runawaySegments += runawayParser.appendTextDelta(String(runawayReply[chunkStart..<chunkEnd]))
        chunkStart = chunkEnd
    }
    runawaySegments += runawayParser.finish()
    let nothingTyped = runawaySegments.allSatisfy { $0.actions.isEmpty }
    let restSpoken = runawaySegments.last?.spokenText.hasSuffix("after.") == true
    if nothingTyped && restSpoken {
        print("✅ an unclosed TYPE tag doesn't swallow (and type) the rest of a long reply")
    } else {
        failureCount += 1
        print("❌ an unclosed TYPE tag doesn't swallow the rest — typed: \(!nothingTyped), rest spoken: \(restSpoken)")
    }
}

expect("a screen number without a label is still a screen number",
       reply: "[CLICK:640,400:screen2][POINT:10,20:screen3] there.",
       segments: ["there. @(10,20)::screen3 +click.single(640,400::screen2)"])

expect("wait tags: default, explicit, and clamped",
       reply: "[WAIT] [WAIT:5][WAIT:60]",
       chunkSize: 2,
       segments: [" +wait(3) +wait(5) +wait(10)"])

expect("memory tags are never spoken, even split across chunks",
       reply: "[FORGET:gig price][REMEMBER:their fiverr gig is logo design, from forty dollars: basic tier] noted.",
       chunkSize: 3,
       segments: ["noted. +forget(gig price) +remember(their fiverr gig is logo design, from forty dollars: basic tier)"])

expect("an unclosed TYPE runs into a later tag: nothing is typed, the prose isn't spoken, the point survives",
       reply: "[TYPE:hello and more prose [POINT:40,50:box] there.",
       segments: ["there. @(40,50):box"])

expect("an unclosed TYPE before an action tag doesn't type the action",
       reply: "[TYPE:hi sam [KEY:return] sent.",
       segments: ["sent. +key(return)"])

expect("reminder and event tags: times in local time, minutes default to an hour",
       reply: "adding it. [REMIND:call mum | 2026-09-24T15:00][REMIND:buy milk][EVENT:dentist | 2026-09-25T10:00][EVENT:standup | 2026-09-26 09:30 | 15]",
       chunkSize: 4,
       segments: ["adding it.", " +remind(call mum @2026-09-24 15:00) +remind(buy milk) +event(dentist @2026-09-25 10:00 60m) +event(standup @2026-09-26 09:30 15m)"])

expect("shortcut tags",
       reply: "[SHORTCUT:Focus On] focus is on.",
       segments: ["focus is on. +shortcut(Focus On)"])

expect("an event without a readable time does nothing",
       reply: "[EVENT:party | sometime soon] noted.",
       segments: ["noted."])

expect("coordinates can be slightly negative or have decimals (things at the screen's edge)",
       reply: "[POINT:-3,412.5:menu] top left. [CLICK:640.4,-2:close button]",
       segments: ["top left. @(-3,412):menu", " +click.single(640,-2:close button)"])

expect("timer tags: minutes, seconds, combined, with and without a label",
       reply: "[TIMER:10m | pasta][TIMER:90s][TIMER:1h30m | laundry] timers set.",
       chunkSize: 3,
       segments: ["timers set. +timer(600s pasta) +timer(90s) +timer(5400s laundry)"])

expect("a timer with a garbled duration does nothing",
       reply: "[TIMER:soonish | tea] okay.",
       segments: ["okay."])

expect("lookup tags: kinds with and without a query, and loose spellings",
       reply: "[LOOKUP:weather:paris, france][LOOKUP:screen text][LOOKUP:Window_Text][LOOKUP:files:tax return 2025] checking.",
       chunkSize: 4,
       segments: ["checking. +lookup(weather:paris, france) +lookup(screen-text) +lookup(window-text) +lookup(files:tax return 2025)"])

expect("a blank weather city is kept blank; unknown kinds and a files lookup with no name do nothing",
       reply: "[LOOKUP:weather][LOOKUP:bank-balance][LOOKUP:files] checking.",
       segments: ["checking. +lookup(weather)"])

expect("clipboard, battery and wifi lookups",
       reply: "[LOOKUP:clipboard][LOOKUP:battery][LOOKUP:wifi] one sec.",
       segments: ["one sec. +lookup(clipboard) +lookup(battery) +lookup(wifi)"])

expect("a research tag before the filler attaches to it and is never spoken",
       reply: "[RESEARCH:who won the last f1 race] let me look that up.",
       chunkSize: 3,
       segments: ["let me look that up. +research(who won the last f1 race)"])

expect("a research tag after the filler still runs",
       reply: "let me look that up. [RESEARCH:latest macos version]",
       segments: ["let me look that up.", " +research(latest macos version)"])

expect("a browser tag attaches to its filler and is never spoken",
       reply: "[BROWSER:on youtube, play lofi | first result] on it.",
       chunkSize: 4,
       segments: ["on it. +browser(on youtube, play lofi | first result)"])

expect("an empty browser tag does nothing",
       reply: "[BROWSER: ] on it.",
       segments: ["on it."])

expect("an empty research tag does nothing",
       reply: "[RESEARCH: ] let me look that up.",
       segments: ["let me look that up."])

expect("window and app tags, with aliases and an optional app",
       reply: "[WINDOW:left-half][WINDOW:Right | Safari][WINDOW:maximize][WINDOW:next screen][FOCUS:Notes][HIDE:Slack][QUIT:Music] tidied.",
       chunkSize: 5,
       segments: ["tidied. +window(left-half) +window(right-half in Safari) +window(fullscreen) +window(next-screen) +focus(Notes) +hide(Slack) +quit(Music)"])

expect("an unknown window arrangement and an empty quit do nothing",
       reply: "[WINDOW:diagonal][QUIT:] nope.",
       segments: ["nope."])

do {
    let durationExamples: [(String, Int?)] = [
        ("10m", 600), ("90s", 90), ("1h30m", 5400), ("1h 30m", 5400), ("10 min", 600),
        ("2 minutes", 120), ("1 hour and 15 minutes", 4500), ("1.5h", 5400), ("5", 300),
        ("0m", nil), ("25h", nil), ("10m of pasta", nil), ("", nil), ("soon", nil)
    ]
    for (durationText, expectedSeconds) in durationExamples {
        let parsedSeconds = VesperResponseStreamParser.parseTimerDurationSeconds(durationText)
        if parsedSeconds == expectedSeconds {
            print("✅ timer duration \"\(durationText)\" → \(parsedSeconds.map(String.init) ?? "nil")")
        } else {
            failureCount += 1
            print("❌ timer duration \"\(durationText)\": expected \(expectedSeconds.map(String.init) ?? "nil"), got \(parsedSeconds.map(String.init) ?? "nil")")
        }
    }
}
expect("a highlight tag first attaches to the first sentence",
       reply: "[HIGHLIGHT:20,100,300,640:sidebar] your whole project lives in that sidebar. pick a file.",
       segments: ["your whole project lives in that sidebar. #(20,100,300,640):sidebar", "pick a file."])

expect("inline highlights walk through areas",
       reply: "[HIGHLIGHT:0,0,1280,40:toolbar] the toolbar up top, [HIGHLIGHT:0,700,1280,800:status bar:screen2] and the status bar down here.",
       chunkSize: 3,
       segments: ["the toolbar up top, #(0,0,1280,40):toolbar",
                  "and the status bar down here. #(0,700,1280,800):status bar:screen2"])

expect("a point and a highlight can share a sentence",
       reply: "[HIGHLIGHT:600,80,900,120:tabs][POINT:640,100:first tab] tabs are here.",
       segments: ["tabs are here. @(640,100):first tab #(600,80,900,120):tabs"])

expect("highlight corners can be negative, decimal or swapped, and a bare screen number is a screen",
       reply: "[HIGHLIGHT:410.5,300,-2,12.9:screen2] that corner.",
       segments: ["that corner. #(-2,12,410,300)::screen2"])

expect("a highlight with three numbers is dropped and never spoken",
       reply: "[HIGHLIGHT:10,20,30:oops] still talking.",
       segments: ["still talking."])

expect("a highlight cut off at the end of the reply is never spoken",
       reply: "look at this [HIGHLIGHT:10,20,3",
       segments: ["look at this"])

expect("a highlight at the very end still highlights",
       reply: "that panel. [HIGHLIGHT:1,2,3,4:panel]",
       segments: ["that panel.", " #(1,2,3,4):panel"])

expect("drawings attach to the sentence after them, one character at a time",
       reply: "[CIRCLE:880,210,960,232:spent] that's what you've spent, [CIRCLE:880,250,960,272:left] and that's what's left.",
       segments: ["that's what you've spent, ~circle(880,210,960,232):spent",
                  "and that's what's left. ~circle(880,250,960,272):left"])

expect("an arrow keeps its direction (tail first, tip second)",
       reply: "[ARROW:720,380,300,410:drag] drag it back over here.",
       chunkSize: 4,
       segments: ["drag it back over here. ~arrow(720,380,300,410):drag"])

expect("an underline on another screen, with no label",
       reply: "[UNDERLINE:100,50,420,68:screen2] that error line.",
       segments: ["that error line. ~underline(100,50,420,68)::screen2"])

expect("several drawings before one sentence all belong to it, in order",
       reply: "[CIRCLE:1,2,30,40:a][ARROW:30,40,200,200:b][UNDERLINE:5,6,70,80] these connect.",
       chunkSize: 2,
       segments: ["these connect. ~circle(1,2,30,40):a ~arrow(30,40,200,200):b ~underline(5,6,70,80):"])

expect("a drawing and a point can share a sentence (the point is kept, the drawing wins later)",
       reply: "[POINT:10,20:x][CIRCLE:5,5,50,50:y] right there.",
       segments: ["right there. @(10,20):x ~circle(5,5,50,50):y"])

expect("a drawing with three numbers is dropped and never spoken",
       reply: "[CIRCLE:10,20,30:oops] still talking.",
       segments: ["still talking."])

expect("a zero-length arrow is dropped",
       reply: "[ARROW:10,10,11,11] nothing to see.",
       segments: ["nothing to see."])

expect("a drawing cut off at the end of the reply is never spoken",
       reply: "look here [ARROW:10,20,3",
       segments: ["look here"])

expect("a drawing at the very end still draws",
       reply: "that one. [UNDERLINE:1,2,300,20:line]",
       segments: ["that one.", " ~underline(1,2,300,20):line"])

expect("words that look like tag names in brackets are spoken",
       reply: "the [circle] tool is on the left.",
       segments: ["the [circle] tool is on the left."])

expect("a guided step attaches to its sentence, one character at a time",
       reply: "[GUIDE:40,11:file menu] first, the file menu up top.",
       segments: ["first, the file menu up top. >(40,11):file menu"])

expect("a guided step on another screen, split across chunks",
       reply: "now export. [GUIDE:120,236:export:screen2]",
       chunkSize: 5,
       segments: ["now export.", " >(120,236):export:screen2"])

expect("a malformed guide is dropped and never spoken",
       reply: "[GUIDE:12:oops] still talking.",
       segments: ["still talking."])

expect("a guide cut off at the end of the reply is never spoken",
       reply: "click this [GUIDE:40,",
       segments: ["click this"])

print(failureCount == 0 ? "\n✅ all parser tests passed" : "\n❌ \(failureCount) parser test(s) failed")
exit(failureCount == 0 ? 0 : 1)
SWIFT

swiftc -o "$temporary_directory/test-response-parser" \
  "$temporary_directory/main.swift" \
  leanring-buddy/VesperResponseStreamParser.swift
"$temporary_directory/test-response-parser"
