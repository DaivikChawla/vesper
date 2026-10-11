//
//  Tests VesperSketch: taps vs strokes, the marked area, point spacing,
//  mapping into a screenshot's pixels, the close-up's area, and that the
//  marks really land on the image Claude sees. No app, no windows.
//

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

let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
let externalScreenFrame = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

let tap = VesperSketchStroke(id: 1, displayFrame: screenFrame, globalPoints: [CGPoint(x: 100, y: 100), CGPoint(x: 103, y: 102)])
check("a click that barely moves is a tap", tap.isTap)
check("a tap marks a small square around it", tap.globalBoundingRect.width == VesperSketchGeometry.tapRingRadius * 2)

let circleAroundTotal = VesperSketchStroke(id: 2, displayFrame: screenFrame, globalPoints: [
    CGPoint(x: 400, y: 300), CGPoint(x: 460, y: 330), CGPoint(x: 520, y: 300), CGPoint(x: 460, y: 270), CGPoint(x: 402, y: 298)
])
check("a drawn loop is a stroke, not a tap", !circleAroundTotal.isTap)
check("a stroke's area is its extent", circleAroundTotal.globalBoundingRect == CGRect(x: 400, y: 270, width: 120, height: 60))

var spacedPoints = VesperSketchGeometry.appending(CGPoint(x: 0, y: 0), to: [])
spacedPoints = VesperSketchGeometry.appending(CGPoint(x: 0.5, y: 0.5), to: spacedPoints)
spacedPoints = VesperSketchGeometry.appending(CGPoint(x: 5, y: 0), to: spacedPoints)
check("points closer than 2 pt add nothing", spacedPoints.count == 2)
check("a smooth path is drawn through the points", !VesperSketchGeometry.smoothPath(through: circleAroundTotal.globalPoints).isEmpty)

let topLeftPixel = VesperSketchGeometry.screenshotPixel(forGlobalPoint: CGPoint(x: 1512, y: 1240), displayFrame: externalScreenFrame, screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720)
check("a global point maps into an offset screen's screenshot (top-left origin)", abs(topLeftPixel.x) < 0.01 && abs(topLeftPixel.y) < 0.01, "\(topLeftPixel)")
let middlePixel = VesperSketchGeometry.screenshotPixel(forGlobalPoint: CGPoint(x: externalScreenFrame.midX, y: externalScreenFrame.midY), displayFrame: externalScreenFrame, screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720)
check("the middle of a screen is the middle of its screenshot", abs(middlePixel.x - 640) < 0.01 && abs(middlePixel.y - 360) < 0.01)

let smallCloseUp = VesperSketchGeometry.closeUpRegion(around: CGRect(x: 700, y: 400, width: 20, height: 20), displayFrame: screenFrame)
check("a close-up is at least 320×200", smallCloseUp.width == 320 && smallCloseUp.height == 200)
let bigCloseUp = VesperSketchGeometry.closeUpRegion(around: CGRect(x: 0, y: 0, width: 1400, height: 900), displayFrame: screenFrame)
check("a close-up is at most 700×440", bigCloseUp.width == 700 && bigCloseUp.height == 440)
let edgeCloseUp = VesperSketchGeometry.closeUpRegion(around: CGRect(x: 1500, y: 970, width: 10, height: 10), displayFrame: screenFrame)
check("a close-up stays on its screen", screenFrame.contains(edgeCloseUp))

// The marks really land on the picture Claude sees.
let imageWidth = 1280
let imageHeight = 831
let whiteContext = CGContext(data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
whiteContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
whiteContext.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
let plainScreenshot = whiteContext.makeImage()!
let horizontalStroke = VesperSketchStroke(id: 3, displayFrame: screenFrame, globalPoints: [CGPoint(x: 300, y: 491), CGPoint(x: 900, y: 491)])
let markedScreenshot = VesperSketchGeometry.image(plainScreenshot, overlaying: [horizontalStroke], imageArea: screenFrame)

func pixelColor(of image: CGImage, x: Int, yFromTop: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
    let readContext = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    readContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixelBytes = readContext.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    let offset = (yFromTop * image.width + x) * 4
    return (pixelBytes[offset], pixelBytes[offset + 1], pixelBytes[offset + 2])
}
// 491 pt up from the bottom of a 982 pt screen is its middle row.
let markedPixel = pixelColor(of: markedScreenshot, x: 640, yFromTop: imageHeight / 2)
check("the stroke is drawn on the screenshot in magenta", markedPixel.red > 200 && markedPixel.green < 90 && markedPixel.blue > 110, "\(markedPixel)")
let untouchedPixel = pixelColor(of: markedScreenshot, x: 640, yFromTop: 40)
check("the rest of the screenshot is untouched", untouchedPixel.red == 255 && untouchedPixel.green == 255 && untouchedPixel.blue == 255, "\(untouchedPixel)")
check("no strokes: the same picture", VesperSketchGeometry.image(plainScreenshot, overlaying: [], imageArea: screenFrame) === plainScreenshot)

print(failureCount == 0 ? "\n✅ all sketch tests passed" : "\n❌ \(failureCount) sketch test(s) failed")
exit(failureCount == 0 ? 0 : 1)
