import AppKit
import ImageIO
import UniformTypeIdentifiers

// Tests VesperClickTargetCheck.swift on real UI pictures (the panel renders),
// put through the same steps as the app: the screenshot Claude saw is the
// whole screen scaled to 1280 px and JPEG-compressed; the check captures
// just the patch at the same density.
// Arguments: <picture.png> <another picture.png>

var failedCheckCount = 0
func check(_ condition: Bool, _ testName: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("✅ \(testName)\(detail().isEmpty ? "" : " — " + detail())")
    } else {
        failedCheckCount += 1
        print("❌ \(testName)\(detail().isEmpty ? "" : "\n   " + detail())")
    }
}

func loadImage(_ path: String) -> CGImage {
    guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        fatalError("can't load \(path)")
    }
    return image
}

func drawn(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}

/// The screenshot Claude saw: scaled to `screenshotWidth` and JPEG'd at 0.8.
func claudeScreenshot(of screen: CGImage, screenshotWidth: Int) -> CGImage {
    let screenshotHeight = Int(Double(screen.height) * Double(screenshotWidth) / Double(screen.width))
    let scaled = drawn(width: screenshotWidth, height: screenshotHeight) { context in
        context.draw(screen, in: CGRect(x: 0, y: 0, width: screenshotWidth, height: screenshotHeight))
    }
    let jpegData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(jpegData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(destination)
    let source = CGImageSourceCreateWithData(jpegData as CFData, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

/// The patch captured right before clicking: just that area of the
/// screen now, at the screenshot's density.
func capturedPatch(of screen: CGImage, patchRectInPoints: CGRect, pixelsPerPoint: CGFloat) -> CGImage {
    let outputWidth = Int((patchRectInPoints.width * pixelsPerPoint).rounded())
    let outputHeight = Int((patchRectInPoints.height * pixelsPerPoint).rounded())
    let patchRectInRetinaPixels = CGRect(x: patchRectInPoints.minX * retinaScale, y: patchRectInPoints.minY * retinaScale,
                                         width: patchRectInPoints.width * retinaScale, height: patchRectInPoints.height * retinaScale)
    let cropped = screen.cropping(to: patchRectInRetinaPixels)!
    return drawn(width: outputWidth, height: outputHeight) { context in
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    }
}

let firstScreen = loadImage(CommandLine.arguments[1])
let secondScreen = loadImage(CommandLine.arguments[2])
// The pictures are Retina (2 pixels per point): the "display" is half
// their pixel size in points, origin at 0,0, and Claude's screenshot has
// 0.87 pixels per point (a 1470-point MacBook screen at 1280 px).
let retinaScale: CGFloat = 2
let displayFrame = CGRect(x: 0, y: 0, width: CGFloat(firstScreen.width) / retinaScale, height: CGFloat(firstScreen.height) / retinaScale)
let screenshotWidth = Int(displayFrame.width * 0.87)
let screenshotHeight = Int(displayFrame.height * CGFloat(screenshotWidth) / displayFrame.width)
let pixelsPerPoint = CGFloat(screenshotWidth) / displayFrame.width
let screenshotSeenByClaude = claudeScreenshot(of: firstScreen, screenshotWidth: screenshotWidth)

func comparison(screenNow: CGImage, atGlobalPoint globalPoint: CGPoint, screenshot: CGImage = screenshotSeenByClaude) -> VesperClickTargetCheck.Comparison {
    let patchInPoints = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: globalPoint, displayFrame: displayFrame)
    let patchInScreenshot = VesperClickTargetCheck.patchRectInScreenshotPixels(
        patchRectInDisplayPoints: patchInPoints, displayFrame: displayFrame,
        screenshotWidthInPixels: screenshotWidth, screenshotHeightInPixels: screenshotHeight
    )
    let currentGrid = VesperClickTargetCheck.grayscaleGrid(of: capturedPatch(of: screenNow, patchRectInPoints: patchInPoints, pixelsPerPoint: pixelsPerPoint))!
    return VesperClickTargetCheck.compare(currentGrid: currentGrid, screenshot: screenshot, patchRectInScreenshotPixels: patchInScreenshot, screenshotPixelsPerPoint: pixelsPerPoint)!
}

func scoreList(_ comparisons: [VesperClickTargetCheck.Comparison]) -> String {
    comparisons.map { String(format: "%.1f", $0.meanDifferenceAtClaudesPosition) }.sorted { Double($0)! < Double($1)! }.joined(separator: " ")
}

// Click points all over the picture (AppKit: bottom-left origin).
var clickPoints: [CGPoint] = []
for column in stride(from: 40, to: Int(displayFrame.width) - 30, by: 45) {
    for row in stride(from: 45, to: Int(displayFrame.height) - 30, by: 50) {
        clickPoints.append(CGPoint(x: column, y: row))
    }
}

print("— the same screen")
let sameComparisons = clickPoints.map { comparison(screenNow: firstScreen, atGlobalPoint: $0) }
print("   unchanged differences: " + scoreList(sameComparisons))
check(sameComparisons.allSatisfy(\.looksTheSame), "an unchanged screen always looks the same (JPEG and scaling don't count)",
      String(format: "worst %.1f over %d spots", sameComparisons.map(\.meanDifferenceAtClaudesPosition).max() ?? 0, clickPoints.count))

print("— the mouse pointer")
let screenshotWithPointer = drawn(width: screenshotSeenByClaude.width, height: screenshotSeenByClaude.height) { context in
    context.draw(screenshotSeenByClaude, in: CGRect(x: 0, y: 0, width: screenshotSeenByClaude.width, height: screenshotSeenByClaude.height))
    // A pointer-sized black arrow right at the click point.
    let pointerTip = CGPoint(x: 150 * pixelsPerPoint, y: 200 * pixelsPerPoint)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.move(to: pointerTip)
    context.addLine(to: CGPoint(x: pointerTip.x, y: pointerTip.y - 18 * pixelsPerPoint))
    context.addLine(to: CGPoint(x: pointerTip.x + 12 * pixelsPerPoint, y: pointerTip.y - 12 * pixelsPerPoint))
    context.fillPath()
}
let pointerComparison = comparison(screenNow: firstScreen, atGlobalPoint: CGPoint(x: 150, y: 200), screenshot: screenshotWithPointer)
check(pointerComparison.looksTheSame, "the pointer in Claude's screenshot doesn't count as a change", String(format: "%.1f", pointerComparison.meanDifferenceAtClaudesPosition))

print("— the page moved")
let shiftedScreen = drawn(width: firstScreen.width, height: firstScreen.height) { context in
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: firstScreen.width, height: firstScreen.height))
    context.draw(firstScreen, in: CGRect(x: 0, y: -40 * retinaScale, width: CGFloat(firstScreen.width), height: CGFloat(firstScreen.height)))
}
var detectedShiftCount = 0
var shiftedShares: [Double] = []
var busySpotCount = 0
for clickPoint in clickPoints {
    // Only spots with something on them (a flat background moved is still flat).
    let patchInPoints = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: clickPoint, displayFrame: displayFrame)
    let patchInRetinaPixels = CGRect(x: patchInPoints.minX * retinaScale, y: patchInPoints.minY * retinaScale, width: patchInPoints.width * retinaScale, height: patchInPoints.height * retinaScale)
    let grid = VesperClickTargetCheck.grayscaleGrid(of: firstScreen, sampling: patchInRetinaPixels)!
    let mean = Double(grid.reduce(0) { $0 + Int($1) }) / Double(grid.count)
    let spread = grid.reduce(0.0) { $0 + abs(Double($1) - mean) } / Double(grid.count)
    guard spread > 8 else { continue }
    busySpotCount += 1
    let shiftedComparison = comparison(screenNow: shiftedScreen, atGlobalPoint: clickPoint)
    shiftedShares.append(shiftedComparison.meanDifferenceAtClaudesPosition)
    if !shiftedComparison.looksTheSame { detectedShiftCount += 1 }
}
print("   shifted differences: " + shiftedShares.sorted().map { String(format: "%.1f", $0) }.joined(separator: " "))
check(busySpotCount > 5 && Double(detectedShiftCount) / Double(busySpotCount) >= 0.85, "content pushed down 40 points is caught at most busy spots", "\(detectedShiftCount) of \(busySpotCount)")

print("— different content")
var detectedDifferenceCount = 0
var differentSpotCount = 0
for clickPoint in clickPoints {
    let patchInPoints = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: clickPoint, displayFrame: displayFrame)
    let patchInRetinaPixels = CGRect(x: patchInPoints.minX * retinaScale, y: patchInPoints.minY * retinaScale, width: patchInPoints.width * retinaScale, height: patchInPoints.height * retinaScale)
    let before = VesperClickTargetCheck.grayscaleGrid(of: firstScreen, sampling: patchInRetinaPixels)!
    let after = VesperClickTargetCheck.grayscaleGrid(of: secondScreen, sampling: patchInRetinaPixels)!
    // Only spots that really differ between the two pictures.
    guard VesperClickTargetCheck.meanDifference(before, after) > 25 else { continue }
    differentSpotCount += 1
    if !comparison(screenNow: secondScreen, atGlobalPoint: clickPoint).looksTheSame { detectedDifferenceCount += 1 }
}
check(differentSpotCount > 0 && detectedDifferenceCount == differentSpotCount, "a different page under the point is always caught", "\(detectedDifferenceCount) of \(differentSpotCount)")

print("— a light page full of small text (where JPEG noise is worst)")
/// A white, text-dense web page at 2× (Retina): headings, 13 pt body text,
/// links, a photo-like gradient and buttons.
func makeLightTextPage(widthInPoints: Int, heightInPoints: Int, verticalOffsetInPoints: CGFloat = 0) -> CGImage {
    let pixelWidth = widthInPoints * 2
    let pixelHeight = heightInPoints * 2
    return drawn(width: pixelWidth, height: pixelHeight) { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: 2, y: 2)
        // AppKit text drawing into this context (flipped so text reads top-down).
        context.translateBy(x: 0, y: CGFloat(heightInPoints))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: verticalOffsetInPoints)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
        let linkAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemBlue]
        let headingAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.black]
        let words = "the quick brown fox jumps over a lazy dog while results load and sidebars shift under the cursor".split(separator: " ")
        var lineY: CGFloat = 20
        var lineIndex = 0
        while lineY < CGFloat(heightInPoints) - 20 {
            if lineIndex % 9 == 0 {
                ("Section \(lineIndex / 9 + 1): search results" as NSString).draw(at: CGPoint(x: 24, y: lineY), withAttributes: headingAttributes)
                lineY += 30
            } else {
                let line = (0..<14).map { String(words[($0 * 7 + lineIndex * 3) % words.count]) }.joined(separator: " ")
                (line as NSString).draw(at: CGPoint(x: 24, y: lineY), withAttributes: lineIndex % 4 == 1 ? linkAttributes : bodyAttributes)
                lineY += 18
            }
            lineIndex += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        // A photo-like gradient and two buttons.
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1)] as CFArray, locations: [0, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: CGFloat(widthInPoints) - 260, y: 120, width: 220, height: 140))
        context.drawLinearGradient(gradient, start: CGPoint(x: CGFloat(widthInPoints) - 260, y: 120), end: CGPoint(x: CGFloat(widthInPoints) - 40, y: 260), options: [])
        context.restoreGState()
        context.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: CGFloat(widthInPoints) - 260, y: 300, width: 100, height: 30))
        context.fill(CGRect(x: CGFloat(widthInPoints) - 140, y: 300, width: 100, height: 30))
    }
}
let lightPageWidth = 1000
let lightPageHeight = 700
let lightPage = makeLightTextPage(widthInPoints: lightPageWidth, heightInPoints: lightPageHeight)
let lightPageShifted = makeLightTextPage(widthInPoints: lightPageWidth, heightInPoints: lightPageHeight, verticalOffsetInPoints: 40)
let lightDisplayFrame = CGRect(x: 0, y: 0, width: lightPageWidth, height: lightPageHeight)
let lightScreenshotWidth = Int(lightDisplayFrame.width * 0.87)
let lightScreenshotHeight = Int(lightDisplayFrame.height * CGFloat(lightScreenshotWidth) / lightDisplayFrame.width)
let lightScreenshot = claudeScreenshot(of: lightPage, screenshotWidth: lightScreenshotWidth)
func lightComparison(screenNow: CGImage, atGlobalPoint globalPoint: CGPoint) -> VesperClickTargetCheck.Comparison {
    let patchInPoints = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: globalPoint, displayFrame: lightDisplayFrame)
    let patchInScreenshot = VesperClickTargetCheck.patchRectInScreenshotPixels(
        patchRectInDisplayPoints: patchInPoints, displayFrame: lightDisplayFrame,
        screenshotWidthInPixels: lightScreenshotWidth, screenshotHeightInPixels: lightScreenshotHeight
    )
    let lightPixelsPerPoint = CGFloat(lightScreenshotWidth) / lightDisplayFrame.width
    let currentGrid = VesperClickTargetCheck.grayscaleGrid(of: capturedPatch(of: screenNow, patchRectInPoints: patchInPoints, pixelsPerPoint: lightPixelsPerPoint))!
    return VesperClickTargetCheck.compare(currentGrid: currentGrid, screenshot: lightScreenshot, patchRectInScreenshotPixels: patchInScreenshot, screenshotPixelsPerPoint: lightPixelsPerPoint)!
}
var lightSameComparisons: [VesperClickTargetCheck.Comparison] = []
var lightShiftedComparisons: [VesperClickTargetCheck.Comparison] = []
for column in stride(from: 40, to: lightPageWidth - 30, by: 50) {
    for row in stride(from: 40, to: lightPageHeight - 30, by: 45) {
        let clickPoint = CGPoint(x: column, y: row)
        lightSameComparisons.append(lightComparison(screenNow: lightPage, atGlobalPoint: clickPoint))
        lightShiftedComparisons.append(lightComparison(screenNow: lightPageShifted, atGlobalPoint: clickPoint))
    }
}
print("   light unchanged differences (top 10): " + lightSameComparisons.map(\.meanDifferenceAtClaudesPosition).sorted().suffix(10).map { String(format: "%.1f", $0) }.joined(separator: " "))
let worstLightSameDifference = lightSameComparisons.map(\.meanDifferenceAtClaudesPosition).max() ?? 255
check(lightSameComparisons.allSatisfy(\.looksTheSame) && worstLightSameDifference < VesperClickTargetCheck.sameScreenMeanDifference * 0.75,
      "an unchanged light page full of 13 pt text stays well clear of the line", String(format: "worst %.1f over %d spots (same below %.0f)", worstLightSameDifference, lightSameComparisons.count, VesperClickTargetCheck.sameScreenMeanDifference))
let lightBusyShifted = lightShiftedComparisons.filter { $0.meanDifferenceAtClaudesPosition >= 3 }
let caughtLightShiftShare = Double(lightBusyShifted.filter { !$0.looksTheSame }.count) / Double(max(lightBusyShifted.count, 1))
let movedOffsets = Set(lightBusyShifted.filter { $0.verdict == .moved }.map { "\(Int($0.bestOffsetInPoints.width)),\(Int($0.bestOffsetInPoints.height))" })
check(caughtLightShiftShare >= 0.9, "text pushed down 40 points is caught", String(format: "%.0f%% of %d spots · offsets found: %@", caughtLightShiftShare * 100, lightBusyShifted.count, movedOffsets.sorted().joined(separator: " ")))

print("— cost")
// The worst case: the spot changed, so the whole offset search runs.
let timedPoint = CGPoint(x: 500, y: 350)
let timedPatchInPoints = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: timedPoint, displayFrame: lightDisplayFrame)
let timedCurrentGrid = VesperClickTargetCheck.grayscaleGrid(of: capturedPatch(of: lightPageShifted, patchRectInPoints: timedPatchInPoints, pixelsPerPoint: CGFloat(lightScreenshotWidth) / lightDisplayFrame.width))!
let timedPatchInScreenshot = VesperClickTargetCheck.patchRectInScreenshotPixels(patchRectInDisplayPoints: timedPatchInPoints, displayFrame: lightDisplayFrame, screenshotWidthInPixels: lightScreenshotWidth, screenshotHeightInPixels: lightScreenshotHeight)
let timingStartedAt = Date()
for _ in 0..<10 {
    _ = VesperClickTargetCheck.compare(currentGrid: timedCurrentGrid, screenshot: lightScreenshot, patchRectInScreenshotPixels: timedPatchInScreenshot, screenshotPixelsPerPoint: CGFloat(lightScreenshotWidth) / lightDisplayFrame.width)
}
let millisecondsPerComparison = Date().timeIntervalSince(timingStartedAt) * 100
check(millisecondsPerComparison < 60, "decoding and the full offset search take a moment", String(format: "%.0f ms per check (870 px screenshot)", millisecondsPerComparison))

print("— patch placement")
let cornerPatch = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: CGPoint(x: 2, y: 2), displayFrame: CGRect(x: 0, y: 0, width: 1470, height: 956))
check(cornerPatch == CGRect(x: 0, y: 956 - 72, width: 120, height: 72), "a click in the bottom-left corner keeps the patch on screen", "\(cornerPatch)")
let offsetPatch = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: CGPoint(x: 1470 + 500, y: 300), displayFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1440))
check(offsetPatch == CGRect(x: 440, y: 1104, width: 120, height: 72), "a second screen to the right: its own points, top-left origin", "\(offsetPatch)")

print(failedCheckCount == 0 ? "\n✅ all click target tests passed" : "\n❌ \(failedCheckCount) click target test(s) failed")
exit(failedCheckCount == 0 ? 0 : 1)
