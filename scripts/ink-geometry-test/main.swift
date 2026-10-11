//
//  Checks VesperInk's hand-drawn geometry, and (given an output folder)
//  draws a sample of every mark over a mock screen so it can be looked at.
//  No app, no windows, no permissions.
//

import AppKit
import CoreGraphics
import Foundation

var failureCount = 0

func check(_ testName: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("✅ \(testName)")
    } else {
        failureCount += 1
        print("❌ \(testName) \(detail)")
    }
}

/// Ray casting: is `point` inside the closed polygon through `polygonPoints`?
func isPoint(_ point: CGPoint, insidePolygon polygonPoints: [CGPoint]) -> Bool {
    var isInside = false
    var previousIndex = polygonPoints.count - 1
    for currentIndex in polygonPoints.indices {
        let currentPoint = polygonPoints[currentIndex]
        let previousPoint = polygonPoints[previousIndex]
        if (currentPoint.y > point.y) != (previousPoint.y > point.y) {
            let crossingX = (previousPoint.x - currentPoint.x) * (point.y - currentPoint.y) / (previousPoint.y - currentPoint.y) + currentPoint.x
            if point.x < crossingX { isInside.toggle() }
        }
        previousIndex = currentIndex
    }
    return isInside
}

let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
let secondDisplayFrame = CGRect(x: 1512, y: -300, width: 2560, height: 1440)

// MARK: Coordinates

let sampleGlobalPoint = CGPoint(x: 1700, y: 900)
let screenSpace = VesperInkGeometry.screenSpacePoint(fromGlobalPoint: sampleGlobalPoint, displayFrame: secondDisplayFrame)
let roundTrip = VesperInkGeometry.globalPoint(fromScreenSpacePoint: screenSpace, displayFrame: secondDisplayFrame)
check("global ↔ screen space round-trips on an offset screen", abs(roundTrip.x - sampleGlobalPoint.x) < 0.001 && abs(roundTrip.y - sampleGlobalPoint.y) < 0.001)
check("screen space has y down from the screen's top", abs(screenSpace.y - (secondDisplayFrame.maxY - 900)) < 0.001)

// MARK: Circles

for (rectIndex, textRect) in [CGRect(x: 400, y: 300, width: 120, height: 22), CGRect(x: 40, y: 60, width: 18, height: 18), CGRect(x: 600, y: 200, width: 400, height: 260)].enumerated() {
    let loop = VesperInkGeometry.encircleStrokes(around: textRect, seed: 7 + rectIndex)
    let corners = [CGPoint(x: textRect.minX, y: textRect.minY), CGPoint(x: textRect.maxX, y: textRect.minY),
                   CGPoint(x: textRect.minX, y: textRect.maxY), CGPoint(x: textRect.maxX, y: textRect.maxY)]
    check("circle \(rectIndex + 1) goes all the way round what it circles", corners.allSatisfy { isPoint($0, insidePolygon: loop.mainStroke) })
    check("circle \(rectIndex + 1)'s number sits outside it", !textRect.insetBy(dx: -4, dy: -4).contains(loop.badgeCenter))
    // It runs a little past where it started (the overshoot), inside the first pass.
    let startPoint = loop.mainStroke.first!
    let endPoint = loop.mainStroke.last!
    let center = CGPoint(x: textRect.midX, y: textRect.midY)
    let startDistance = hypot(startPoint.x - center.x, startPoint.y - center.y)
    let endDistance = hypot(endPoint.x - center.x, endPoint.y - center.y)
    check("circle \(rectIndex + 1) overshoots its start, slightly inside", endDistance < startDistance && hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) > 4)
}
let loopA = VesperInkGeometry.encircleStrokes(around: CGRect(x: 10, y: 10, width: 100, height: 30), seed: 42)
let loopB = VesperInkGeometry.encircleStrokes(around: CGRect(x: 10, y: 10, width: 100, height: 30), seed: 42)
let loopC = VesperInkGeometry.encircleStrokes(around: CGRect(x: 10, y: 10, width: 100, height: 30), seed: 43)
check("the same mark always wobbles the same way", loopA == loopB)
check("different marks wobble differently", loopA != loopC)

// MARK: Underlines

let underlinedText = CGRect(x: 200, y: 500, width: 300, height: 16)
let underline = VesperInkGeometry.underlineStrokes(below: underlinedText, seed: 3)
check("an underline runs below the text", underline.mainStroke.allSatisfy { $0.y > underlinedText.maxY - 1 && $0.y < underlinedText.maxY + 8 })
check("an underline spans the text", (underline.mainStroke.first!.x < underlinedText.minX) && (underline.mainStroke.last!.x > underlinedText.maxX))

// MARK: Arrows

let arrowStart = CGPoint(x: 300, y: 410)
let arrowEnd = CGPoint(x: 720, y: 380)
let arrow = VesperInkGeometry.arrowStrokes(from: arrowStart, to: arrowEnd, seed: 5)
check("an arrow's shaft starts at its tail", hypot(arrow.mainStroke.first!.x - arrowStart.x, arrow.mainStroke.first!.y - arrowStart.y) < 0.5)
check("an arrow's shaft reaches its tip", hypot(arrow.mainStroke.last!.x - arrowEnd.x, arrow.mainStroke.last!.y - arrowEnd.y) < 0.5)
check("an arrow's head meets at the tip", arrow.finishingStroke?.count == 3 && hypot(arrow.finishingStroke![1].x - arrowEnd.x, arrow.finishingStroke![1].y - arrowEnd.y) < 0.5)
let headWingDistances = (arrow.finishingStroke ?? []).map { hypot($0.x - arrowEnd.x, $0.y - arrowEnd.y) }
check("an arrow's head wings are 9–15 pt", headWingDistances.count == 3 && headWingDistances[0] >= 9 && headWingDistances[0] <= 15.01 && headWingDistances[2] >= 9 && headWingDistances[2] <= 15.01)
let arrowMiddle = arrow.mainStroke[arrow.mainStroke.count / 2]
let straightMiddleY = (arrowStart.y + arrowEnd.y) / 2
check("a sideways arrow bows toward the top of the screen", arrowMiddle.y < straightMiddleY)

// MARK: Boxes

let boxedArea = CGRect(x: 100, y: 100, width: 300, height: 200)
let box = VesperInkGeometry.boxStrokes(around: boxedArea)
check("a frame closes where it started", box.mainStroke.first == box.mainStroke.last)
check("a frame stays on its area's outline", box.mainStroke.allSatisfy { boxedArea.insetBy(dx: -0.5, dy: -0.5).contains($0) && !boxedArea.insetBy(dx: 13, dy: 13).contains($0) })

// MARK: Walking a stroke

let cumulativeLengths = VesperInkGeometry.cumulativeLengths(of: arrow.mainStroke)
check("stroke lengths only grow", zip(cumulativeLengths, cumulativeLengths.dropFirst()).allSatisfy { $0 <= $1 })
let halfwayPoint = VesperInkGeometry.point(atDistance: cumulativeLengths.last! / 2, along: arrow.mainStroke, cumulativeLengths: cumulativeLengths)
check("walking half a stroke lands between its ends", halfwayPoint.x > arrowStart.x && halfwayPoint.x < arrowEnd.x)
check("walking past the end stays at the end", VesperInkGeometry.point(atDistance: 1e6, along: arrow.mainStroke, cumulativeLengths: cumulativeLengths) == arrow.mainStroke.last!)
check("drawing takes 0.32–0.85 s", VesperInkGeometry.drawingDurationSeconds(forStrokeLength: 10) == 0.32 && VesperInkGeometry.drawingDurationSeconds(forStrokeLength: 5000) == 0.85)
check("drawing eases in and out", VesperInkGeometry.easedDrawingProgress(forLinearProgress: 0.1) < 0.1 && VesperInkGeometry.easedDrawingProgress(forLinearProgress: 0.9) > 0.9)

// MARK: Marks

let markOnSecondScreen = VesperInkMark(
    id: 9,
    shape: .encircle(globalRect: CGRect(x: 2000, y: 400, width: 120, height: 30)),
    displayFrame: secondDisplayFrame,
    label: "total",
    badgeNumber: 2
)
let penStart = markOnSecondScreen.drawingStartGlobalPoint
check("a mark's pen starts on its own screen", secondDisplayFrame.contains(penStart))
let badgeNearEdge = VesperInkGeometry.strokes(for: VesperInkMark(id: 1, shape: .encircle(globalRect: CGRect(x: 2, y: 960, width: 30, height: 20)), displayFrame: displayFrame, label: nil, badgeNumber: 1)).badgeCenter
check("a number never hangs off the screen", badgeNearEdge.x >= 12 && badgeNearEdge.y >= 12)

// MARK: A picture

if CommandLine.arguments.count > 1 {
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let canvasSize = CGSize(width: 900, height: 560)
    let pixelScale: CGFloat = 2
    let bitmapContext = CGContext(
        data: nil, width: Int(canvasSize.width * pixelScale), height: Int(canvasSize.height * pixelScale),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    bitmapContext.scaleBy(x: pixelScale, y: pixelScale)
    // Top-left origin, like the overlay's screen space.
    bitmapContext.translateBy(x: 0, y: canvasSize.height)
    bitmapContext.scaleBy(x: 1, y: -1)

    let graphicsContext = NSGraphicsContext(cgContext: bitmapContext, flipped: true)
    NSGraphicsContext.current = graphicsContext
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    CGRect(origin: .zero, size: canvasSize).fill()
    // A mock app: a sidebar, a toolbar, some rows of text.
    NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: 200, height: canvasSize.height).fill()
    NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
    CGRect(x: 200, y: 0, width: canvasSize.width - 200, height: 44).fill()
    let textAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1)]
    for (rowIndex, rowText) in ["Spent this month        $1,284.20", "Left to spend              $515.80", "Next payment due      Oct 3", "Savings goal                $2,000"].enumerated() {
        (rowText as NSString).draw(at: CGPoint(x: 240, y: 80 + CGFloat(rowIndex) * 34), withAttributes: textAttributes)
    }
    ("error: missing return in closure expected to return 'Int'" as NSString).draw(at: CGPoint(x: 240, y: 300), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.systemRed])
    ("report.pdf" as NSString).draw(at: CGPoint(x: 30, y: 420), withAttributes: textAttributes)
    ("Archive" as NSString).draw(at: CGPoint(x: 30, y: 120), withAttributes: textAttributes)
    NSGraphicsContext.current = nil

    let vesperBlue = CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
    func drawInk(_ points: [CGPoint]) {
        guard let firstPoint = points.first else { return }
        for (lineWidth, alpha) in [(CGFloat(10), CGFloat(0.2)), (CGFloat(2.8), CGFloat(0.95))] {
            bitmapContext.beginPath()
            bitmapContext.move(to: firstPoint)
            for point in points.dropFirst() { bitmapContext.addLine(to: point) }
            bitmapContext.setStrokeColor(vesperBlue.copy(alpha: alpha)!)
            bitmapContext.setLineWidth(lineWidth)
            bitmapContext.setLineCap(.round)
            bitmapContext.setLineJoin(.round)
            bitmapContext.strokePath()
        }
    }
    func drawBadge(_ number: Int, at center: CGPoint) {
        bitmapContext.setFillColor(vesperBlue)
        bitmapContext.fillEllipse(in: CGRect(x: center.x - 8.5, y: center.y - 8.5, width: 17, height: 17))
        bitmapContext.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        bitmapContext.setLineWidth(1)
        bitmapContext.strokeEllipse(in: CGRect(x: center.x - 8.5, y: center.y - 8.5, width: 17, height: 17))
        NSGraphicsContext.current = graphicsContext
        let numberText = "\(number)" as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: NSColor.white]
        let numberSize = numberText.size(withAttributes: numberAttributes)
        numberText.draw(at: CGPoint(x: center.x - numberSize.width / 2, y: center.y - numberSize.height / 2), withAttributes: numberAttributes)
        NSGraphicsContext.current = nil
    }

    let spentLoop = VesperInkGeometry.encircleStrokes(around: CGRect(x: 372, y: 82, width: 60, height: 13), seed: 11)
    drawInk(spentLoop.mainStroke)
    drawBadge(1, at: spentLoop.badgeCenter)
    let leftLoop = VesperInkGeometry.encircleStrokes(around: CGRect(x: 370, y: 116, width: 49, height: 13), seed: 12)
    drawInk(leftLoop.mainStroke)
    drawBadge(2, at: leftLoop.badgeCenter)
    let errorUnderline = VesperInkGeometry.underlineStrokes(below: CGRect(x: 240, y: 302, width: 422, height: 12), seed: 13)
    drawInk(errorUnderline.mainStroke)
    drawBadge(3, at: errorUnderline.badgeCenter)
    let dragArrow = VesperInkGeometry.arrowStrokes(from: CGPoint(x: 70, y: 412), to: CGPoint(x: 62, y: 144), seed: 14)
    drawInk(dragArrow.mainStroke)
    drawInk(dragArrow.finishingStroke!)
    drawBadge(4, at: dragArrow.badgeCenter)
    let toolbarFrame = VesperInkGeometry.boxStrokes(around: CGRect(x: 232, y: 150, width: 260, height: 40))
    drawInk(toolbarFrame.mainStroke)
    drawBadge(5, at: toolbarFrame.badgeCenter)

    let image = bitmapContext.makeImage()!
    let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try? pngData.write(to: outputURL)
    print("🖼️ drew \(outputURL.path)")
}

print(failureCount == 0 ? "\n✅ all ink geometry tests passed" : "\n❌ \(failureCount) ink geometry test(s) failed")
exit(failureCount == 0 ? 0 : 1)
