import Foundation

// Tests VesperScreenSettle.swift with made-up 64×40 screens: when a wait
// settles, when it keeps waiting, and when it gives up.

var failedCheckCount = 0
func check(_ condition: Bool, _ testName: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("✅ \(testName)\(detail().isEmpty ? "" : " — " + detail())")
    } else {
        failedCheckCount += 1
        print("❌ \(testName)\(detail().isEmpty ? "" : "\n   " + detail())")
    }
}

let fingerprintWidth = 64
let fingerprintHeight = 40
let pixelCount = fingerprintWidth * fingerprintHeight

/// A flat screen of one gray.
func screen(_ gray: UInt8) -> [UInt8] { [UInt8](repeating: gray, count: pixelCount) }

/// The same screen with a rectangle (in fingerprint pixels) painted.
func screen(_ base: [UInt8], painting columns: Range<Int>, rows: Range<Int>, gray: UInt8) -> [UInt8] {
    var painted = base
    for row in rows { for column in columns { painted[row * fingerprintWidth + column] = gray } }
    return painted
}

/// Feeds a screen that changes over time (`screenAt(seconds, sampleIndex)`)
/// every 0.13 s and returns when the detector stopped, and how.
func runWait(
    expectation: VesperScreenSettleExpectation,
    baseline: [UInt8]?,
    previouslyAnimated: [Bool]? = nil,
    screenAt: (TimeInterval, Int) -> [UInt8]
) -> (verdict: VesperScreenSettleDetector.Verdict, seconds: TimeInterval, summary: String) {
    var detector = VesperScreenSettleDetector(plan: .plan(for: expectation), baselineFingerprint: baseline, previouslyAnimatedPixelMask: previouslyAnimated)
    var sampleIndex = 0
    while true {
        let sampleSeconds = Double(sampleIndex) * 0.13
        let verdict = detector.addSample(screenAt(sampleSeconds, sampleIndex), atSeconds: sampleSeconds)
        if verdict != .keepWaiting || sampleSeconds > 10 {
            return (verdict, sampleSeconds, detector.diagnosticSummary)
        }
        sampleIndex += 1
    }
}

let pageA = screen(screen(200), painting: 4..<60, rows: 4..<12, gray: 40)
let pageB = screen(screen(240), painting: 10..<50, rows: 15..<35, gray: 90)
/// A "video" area that shows a different frame at every snapshot.
func withVideo(_ base: [UInt8], frame: Int, columns: Range<Int> = 20..<44, rows: Range<Int> = 14..<34) -> [UInt8] {
    screen(base, painting: columns, rows: rows, gray: UInt8(60 + (frame * 37) % 150))
}

print("— typing and scrolling (immediate)")
let typingWait = runWait(expectation: .immediateEffect, baseline: nil) { _, _ in pageA }
check(typingWait.verdict == .settled && typingWait.seconds <= 0.55, "a still screen settles quickly after typing", String(format: "%.2fs", typingWait.seconds))

let caretWait = runWait(expectation: .immediateEffect, baseline: nil) { _, sampleIndex in
    sampleIndex % 4 < 2 ? pageA : screen(pageA, painting: 30..<31, rows: 20..<23, gray: 0)
}
check(caretWait.verdict == .settled && caretWait.seconds <= 0.7, "a blinking text cursor doesn't keep it waiting", String(format: "%.2fs", caretWait.seconds))

print("— clicks (may change the screen)")
let nothingHappensWait = runWait(expectation: .mayChangeScreen, baseline: pageA) { _, _ in pageA }
check(nothingHappensWait.verdict == .settled && nothingHappensWait.seconds >= 1.29 && nothingHappensWait.seconds <= 1.45,
      "a click with no visible effect waits 1.3 s for one, then goes on", String(format: "%.2fs", nothingHappensWait.seconds))

let pageLoadWait = runWait(expectation: .mayChangeScreen, baseline: pageA) { seconds, _ in seconds < 0.6 ? pageA : pageB }
check(pageLoadWait.verdict == .settled && pageLoadWait.seconds >= 1.04 && pageLoadWait.seconds <= 1.35,
      "a page that changes 0.6 s after the click: never the old page, settled once still", String(format: "%.2fs · %@", pageLoadWait.seconds, pageLoadWait.summary))

let hoverOnlyWait = runWait(expectation: .mayChangeScreen, baseline: pageA) { seconds, _ in
    seconds < 0.1 ? pageA : screen(pageA, painting: 0..<3, rows: 0..<3, gray: 230)
}
check(hoverOnlyWait.seconds >= 1.29, "a hover tint alone isn't taken for the page changing", String(format: "%.2fs", hoverOnlyWait.seconds))

let slowLoadingWait = runWait(expectation: .mayChangeScreen, baseline: pageA) { seconds, _ in
    var loadingPage = seconds < 0.2 ? pageA : pageB
    for (appearSeconds, column) in [(0.5, 2), (0.8, 8), (1.1, 14), (1.4, 54)] where seconds >= appearSeconds {
        loadingPage = screen(loadingPage, painting: column..<(column + 5), rows: 36..<40, gray: 10)
    }
    return loadingPage
}
check(slowLoadingWait.verdict == .settled && slowLoadingWait.seconds >= 1.86, "a page still filling in keeps it waiting until it's done", String(format: "%.2fs", slowLoadingWait.seconds))

print("— videos and things that never stop")
let videoPageWait = runWait(expectation: .mayChangeScreen, baseline: pageA) { seconds, sampleIndex in
    seconds < 0.4 ? pageA : withVideo(pageB, frame: sampleIndex)
}
check(videoPageWait.verdict == .settled && videoPageWait.seconds < 3.4,
      "a page with a playing video settles (the video is ignored) before the cap", String(format: "%.2fs · %@", videoPageWait.seconds, videoPageWait.summary))

var videoMask = [Bool](repeating: false, count: pixelCount)
for row in 14..<34 { for column in 20..<44 { videoMask[row * fingerprintWidth + column] = true } }
let menuOverVideoWait = runWait(expectation: .mayChangeScreen, baseline: withVideo(pageA, frame: 0), previouslyAnimated: videoMask) { seconds, sampleIndex in
    let videoPage = withVideo(pageA, frame: sampleIndex + 1)
    return seconds < 0.3 ? videoPage : screen(videoPage, painting: 46..<62, rows: 2..<20, gray: 250)
}
check(menuOverVideoWait.verdict == .settled && menuOverVideoWait.seconds <= 1.0 && menuOverVideoWait.seconds >= 0.75,
      "with a video already playing, a menu opening is still noticed and waited for", String(format: "%.2fs · %@", menuOverVideoWait.seconds, menuOverVideoWait.summary))

let flickeringWait = runWait(expectation: .mayChangeScreen, baseline: pageA) { _, sampleIndex in
    // A different small area changes every third snapshot, forever.
    let column = (sampleIndex / 3 * 7) % 56
    return screen(pageB, painting: column..<(column + 6), rows: 2..<8, gray: UInt8((sampleIndex / 3 * 53) % 200))
}
check(flickeringWait.verdict == .gaveUp && flickeringWait.seconds >= 3.5 && flickeringWait.seconds < 3.7,
      "a screen that keeps changing in new places gives up at the 3.5 s cap", String(format: "%@ at %.2fs", "\(flickeringWait.verdict)", flickeringWait.seconds))

print("— opening a site, and an explicit wait")
let openedWait = runWait(expectation: .openedSomething, baseline: pageA) { seconds, _ in seconds < 1.4 ? pageA : pageB }
check(openedWait.verdict == .settled && openedWait.seconds >= 1.98 && openedWait.seconds <= 2.3, "an opened site that appears after 1.4 s is waited for", String(format: "%.2fs", openedWait.seconds))
let afterWaitWait = runWait(expectation: .afterExplicitWait, baseline: pageA) { _, _ in pageA }
check(afterWaitWait.verdict == .settled && afterWaitWait.seconds <= 0.55, "after [WAIT], a still screen is looked at right away", String(format: "%.2fs", afterWaitWait.seconds))
let noBaselineWait = runWait(expectation: .mayChangeScreen, baseline: nil) { _, _ in pageA }
check(noBaselineWait.verdict == .settled && noBaselineWait.seconds <= 0.7, "without a before-snapshot, stillness alone decides", String(format: "%.2fs", noBaselineWait.seconds))

print(failedCheckCount == 0 ? "\n✅ all screen settle tests passed" : "\n❌ \(failedCheckCount) screen settle test(s) failed")
exit(failedCheckCount == 0 ? 0 : 1)
