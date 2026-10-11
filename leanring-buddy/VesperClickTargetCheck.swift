//
//  VesperClickTargetCheck.swift
//  leanring-buddy
//
//  Look before you click. Claude picks a click from a screenshot taken a
//  few seconds earlier; if the page has moved since (it was still loading,
//  a banner pushed things down, a dialog opened), the same coordinates now
//  land on something else. So right before her first click of a step,
//  she compares a small patch of the screen around the point with the
//  screenshot Claude saw. If it moved or changed, the click isn't done and
//  she looks again instead.
//
//  How: both become 24×15 grids of average grays (which smooths away JPEG
//  noise, scaling and the mouse pointer). The screenshot's patch is taken
//  at Claude's position and at offsets around it (up to 48 points up or
//  down, 24 sideways):
//  - it matches best where it was, or matches closely there: the same;
//  - it matches clearly better somewhere else: the page moved;
//  - it matches nowhere: the content changed.
//  A plain "how many cells differ" test failed on light pages full of small
//  text: unchanged ones came near its threshold (JPEG ringing), and text
//  pushed down by a few lines looked alike cell by cell.
//
//  Accessibility can't do this in Chrome or video players (they often
//  expose nothing); pixels always work. Plain image math, so
//  scripts/test-click-target-check.sh tests it on real UI pictures.
//

import CoreGraphics
import Foundation

nonisolated enum VesperClickTargetCheck {
    /// The area compared around a click, in points: the element itself
    /// and a little around it.
    static let patchSizeInPoints = CGSize(width: 120, height: 72)
    static let gridColumnCount = 24
    static let gridRowCount = 15
    /// Offsets searched in the screenshot, in points.
    static let verticalSearchOffsetsInPoints: [CGFloat] = Array(stride(from: -48, through: 48, by: 4))
    static let horizontalSearchOffsetsInPoints: [CGFloat] = Array(stride(from: -24, through: 24, by: 6))
    /// Mean gray difference (0–255) below which the spot is the same.
    static let sameScreenMeanDifference = 7.0
    /// A better match elsewhere must beat Claude's position by this factor
    /// to count as "moved".
    static let movedMatchImprovementFactor = 0.6
    /// Matching nowhere this badly: the content changed.
    static let changedContentMeanDifference = 20.0

    enum Verdict: String, Equatable {
        case same
        case moved
        case changed
    }

    struct Comparison: Equatable {
        /// How different the spot is where Claude saw it (mean gray, 0–255).
        let meanDifferenceAtClaudesPosition: Double
        /// The best match in the screenshot, and where it was.
        let bestMeanDifference: Double
        let bestOffsetInPoints: CGSize
        let verdict: Verdict

        var looksTheSame: Bool { verdict == .same }
    }

    /// The patch around a click, in its screen's own points (top-left
    /// origin, as ScreenCaptureKit's source rect wants), kept on the screen.
    static func patchRectInDisplayPoints(aroundGlobalPoint globalPoint: CGPoint, displayFrame: CGRect) -> CGRect {
        let patchWidth = min(patchSizeInPoints.width, displayFrame.width)
        let patchHeight = min(patchSizeInPoints.height, displayFrame.height)
        let pointInDisplay = CGPoint(x: globalPoint.x - displayFrame.minX, y: displayFrame.maxY - globalPoint.y)
        let originX = min(max(pointInDisplay.x - patchWidth / 2, 0), displayFrame.width - patchWidth)
        let originY = min(max(pointInDisplay.y - patchHeight / 2, 0), displayFrame.height - patchHeight)
        return CGRect(x: originX, y: originY, width: patchWidth, height: patchHeight)
    }

    /// The same patch in a screenshot's pixels (may be fractional).
    static func patchRectInScreenshotPixels(
        patchRectInDisplayPoints: CGRect,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGRect {
        let horizontalScale = CGFloat(screenshotWidthInPixels) / max(displayFrame.width, 1)
        let verticalScale = CGFloat(screenshotHeightInPixels) / max(displayFrame.height, 1)
        return CGRect(
            x: patchRectInDisplayPoints.minX * horizontalScale,
            y: patchRectInDisplayPoints.minY * verticalScale,
            width: patchRectInDisplayPoints.width * horizontalScale,
            height: patchRectInDisplayPoints.height * verticalScale
        )
    }

    /// The grid of average grays for a whole image (the patch just captured).
    static func grayscaleGrid(of image: CGImage) -> [UInt8]? {
        grayscaleGrid(of: image, sampling: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// The grid for the part of `image` in `pixelRect` (top-left origin;
    /// fractional edges are honoured, so it lines up with a fresh capture
    /// of the same area). Each cell is the true average of the pixels it
    /// covers, weighted by how much of each pixel falls inside: shrinking
    /// with CoreGraphics instead only samples a few pixels per cell, and
    /// small text then aliased differently in the two pictures (unchanged
    /// light pages differed by up to 13 of 255). Nil if the rect isn't
    /// inside the image.
    static func grayscaleGrid(of image: CGImage, sampling pixelRect: CGRect) -> [UInt8]? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard pixelRect.width >= 4, pixelRect.height >= 4,
              imageBounds.insetBy(dx: -0.5, dy: -0.5).contains(pixelRect) else { return nil }
        let wholePixelRect = pixelRect.integral.intersection(imageBounds)
        guard let croppedImage = image.cropping(to: wholePixelRect),
              let croppedGrayImage = GrayImage(croppedImage) else { return nil }
        return croppedGrayImage.grid(sampling: pixelRect.offsetBy(dx: -wholePixelRect.minX, dy: -wholePixelRect.minY))
    }

    /// An image as one gray byte per pixel, top row first, at its own size
    /// (no scaling), so grids can be sampled from it many times cheaply.
    struct GrayImage {
        let pixelWidth: Int
        let pixelHeight: Int
        let grayPixels: [UInt8]

        init?(_ image: CGImage) {
            pixelWidth = image.width
            pixelHeight = image.height
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }
            var drawnGrayPixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
            let imageWidth = pixelWidth
            let imageHeight = pixelHeight
            let didDraw = drawnGrayPixels.withUnsafeMutableBytes { grayBuffer -> Bool in
                guard let grayContext = CGContext(
                    data: grayBuffer.baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: imageWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                grayContext.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
                return true
            }
            guard didDraw else { return nil }
            grayPixels = drawnGrayPixels
        }

        var bounds: CGRect { CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight) }

        /// The area-averaged grid for `sampledRect` (this image's pixels,
        /// top-left origin, fractional allowed). Nil if it's outside.
        func grid(sampling sampledRect: CGRect) -> [UInt8]? {
            guard sampledRect.width >= 4, sampledRect.height >= 4,
                  bounds.insetBy(dx: -0.5, dy: -0.5).contains(sampledRect) else { return nil }
            let bufferWidth = pixelWidth
            let bufferHeight = pixelHeight
            let cellWidth = sampledRect.width / CGFloat(gridColumnCount)
            let cellHeight = sampledRect.height / CGFloat(gridRowCount)

            var gridValues = [UInt8](repeating: 0, count: gridColumnCount * gridRowCount)
            for gridRow in 0..<gridRowCount {
                let cellTop = sampledRect.minY + CGFloat(gridRow) * cellHeight
                let cellBottom = cellTop + cellHeight
                let firstPixelRow = max(Int(cellTop.rounded(.down)), 0)
                let lastPixelRow = min(Int(cellBottom.rounded(.up)) - 1, bufferHeight - 1)
                for gridColumn in 0..<gridColumnCount {
                    let cellLeft = sampledRect.minX + CGFloat(gridColumn) * cellWidth
                    let cellRight = cellLeft + cellWidth
                    let firstPixelColumn = max(Int(cellLeft.rounded(.down)), 0)
                    let lastPixelColumn = min(Int(cellRight.rounded(.up)) - 1, bufferWidth - 1)
                    var weightedGrayTotal: CGFloat = 0
                    var totalWeight: CGFloat = 0
                    if firstPixelRow <= lastPixelRow && firstPixelColumn <= lastPixelColumn {
                        for pixelRow in firstPixelRow...lastPixelRow {
                            let rowOverlap = min(cellBottom, CGFloat(pixelRow + 1)) - max(cellTop, CGFloat(pixelRow))
                            guard rowOverlap > 0 else { continue }
                            for pixelColumn in firstPixelColumn...lastPixelColumn {
                                let columnOverlap = min(cellRight, CGFloat(pixelColumn + 1)) - max(cellLeft, CGFloat(pixelColumn))
                                guard columnOverlap > 0 else { continue }
                                let pixelWeight = rowOverlap * columnOverlap
                                weightedGrayTotal += CGFloat(grayPixels[pixelRow * bufferWidth + pixelColumn]) * pixelWeight
                                totalWeight += pixelWeight
                            }
                        }
                    }
                    gridValues[gridRow * gridColumnCount + gridColumn] = totalWeight > 0
                        ? UInt8(min(max((weightedGrayTotal / totalWeight).rounded(), 0), 255))
                        : 0
                }
            }
            return gridValues
        }
    }

    static func meanDifference(_ firstGrid: [UInt8], _ secondGrid: [UInt8]) -> Double {
        guard firstGrid.count == secondGrid.count, !firstGrid.isEmpty else { return 255 }
        var totalDifference = 0
        for cellIndex in firstGrid.indices {
            totalDifference += abs(Int(firstGrid[cellIndex]) - Int(secondGrid[cellIndex]))
        }
        return Double(totalDifference) / Double(firstGrid.count)
    }

    /// Compares the patch on screen now (`currentGrid`) with the screenshot
    /// Claude saw, at Claude's position and the offsets around it.
    static func compare(
        currentGrid: [UInt8],
        screenshot: CGImage,
        patchRectInScreenshotPixels: CGRect,
        screenshotPixelsPerPoint: CGFloat
    ) -> Comparison? {
        guard let grayScreenshot = GrayImage(screenshot) else { return nil }
        return compare(currentGrid: currentGrid, grayScreenshot: grayScreenshot, patchRectInScreenshotPixels: patchRectInScreenshotPixels, screenshotPixelsPerPoint: screenshotPixelsPerPoint)
    }

    static func compare(
        currentGrid: [UInt8],
        grayScreenshot: GrayImage,
        patchRectInScreenshotPixels: CGRect,
        screenshotPixelsPerPoint: CGFloat
    ) -> Comparison? {
        guard let gridAtClaudesPosition = grayScreenshot.grid(sampling: patchRectInScreenshotPixels) else { return nil }
        let differenceAtClaudesPosition = meanDifference(gridAtClaudesPosition, currentGrid)
        var bestDifference = differenceAtClaudesPosition
        var bestOffset = CGSize.zero
        if differenceAtClaudesPosition >= sameScreenMeanDifference {
            for verticalOffset in verticalSearchOffsetsInPoints {
                for horizontalOffset in horizontalSearchOffsetsInPoints where verticalOffset != 0 || horizontalOffset != 0 {
                    let offsetRect = patchRectInScreenshotPixels.offsetBy(
                        dx: horizontalOffset * screenshotPixelsPerPoint,
                        dy: verticalOffset * screenshotPixelsPerPoint
                    )
                    guard let offsetGrid = grayScreenshot.grid(sampling: offsetRect) else { continue }
                    let offsetDifference = meanDifference(offsetGrid, currentGrid)
                    if offsetDifference < bestDifference {
                        bestDifference = offsetDifference
                        bestOffset = CGSize(width: horizontalOffset, height: verticalOffset)
                    }
                }
            }
        }
        let verdict: Verdict
        if differenceAtClaudesPosition < sameScreenMeanDifference {
            verdict = .same
        } else if bestOffset != .zero && bestDifference < differenceAtClaudesPosition * movedMatchImprovementFactor {
            verdict = .moved
        } else if bestDifference >= changedContentMeanDifference {
            verdict = .changed
        } else {
            // Noisier than usual but nothing points to a move: click.
            verdict = .same
        }
        return Comparison(
            meanDifferenceAtClaudesPosition: differenceAtClaudesPosition,
            bestMeanDifference: bestDifference,
            bestOffsetInPoints: bestOffset,
            verdict: verdict
        )
    }
}
