//
//  VesperSketch.swift
//  leanring-buddy
//
//  Pointing, from the user's side: while they hold the hotkey and talk,
//  they can draw on the screen with the mouse — circle a number, underline
//  a line of code, draw an arrow, tap a spot — and that's what "this" and
//  "that" mean.
//
//  While the hotkey is held, the cursor overlay takes the mouse: a drag
//  draws a stroke of light that follows the pointer exactly (no guessing,
//  no lag), a click without moving leaves a small ring. Nothing reaches
//  the app underneath during the hold, so a ctrl-click never opens a
//  context menu. When they let go, the strokes are burned into the
//  screenshot Claude sees, in a colour no app uses, together with a sharp
//  close-up of the marked area — so Claude sees exactly what they marked
//  instead of being told about it. The strokes stay on screen while she
//  thinks and evaporate as she starts to answer.
//
//  (This replaced resting-the-pointer detection with Accessibility
//  snapping: Chrome, Terminal and video players expose nothing to
//  Accessibility, so it only ever produced a square around the pointer
//  that lingered — 28 Sep, every logged attempt.)
//
//  The data and geometry here have no AppKit, so scripts/test-sketch.sh
//  checks them directly. The overlay draws the live strokes.
//

import CoreGraphics
import Foundation

/// One stroke the user drew while holding the hotkey, in AppKit global
/// coordinates (bottom-left origin).
nonisolated struct VesperSketchStroke: Equatable, Identifiable, Sendable {
    let id: Int
    /// The frame of the screen it was drawn on (AppKit global).
    let displayFrame: CGRect
    var globalPoints: [CGPoint]

    /// A click without real movement: shown and sent as a small ring.
    var isTap: Bool {
        guard let firstPoint = globalPoints.first else { return true }
        return globalPoints.allSatisfy { hypot($0.x - firstPoint.x, $0.y - firstPoint.y) < VesperSketchGeometry.tapMovementTolerance }
    }

    /// The area the stroke covers (a tap: a small square around it).
    var globalBoundingRect: CGRect {
        guard let firstPoint = globalPoints.first else { return .null }
        if isTap {
            let tapSide = VesperSketchGeometry.tapRingRadius * 2
            return CGRect(x: firstPoint.x - tapSide / 2, y: firstPoint.y - tapSide / 2, width: tapSide, height: tapSide)
        }
        var boundingRect = CGRect(origin: firstPoint, size: .zero)
        for globalPoint in globalPoints.dropFirst() {
            boundingRect = boundingRect.union(CGRect(origin: globalPoint, size: .zero))
        }
        return boundingRect
    }
}

nonisolated enum VesperSketchGeometry {
    /// Moving less than this from where the click went down is a tap.
    static let tapMovementTolerance: CGFloat = 6
    static let tapRingRadius: CGFloat = 12
    /// Points closer together than this add nothing to a stroke.
    static let minimumPointSpacing: CGFloat = 2
    /// At most this many strokes per question (the oldest is dropped).
    static let maximumStrokeCount = 6

    /// Adds a point to a stroke unless it's too close to the last one.
    static func appending(_ newPoint: CGPoint, to points: [CGPoint]) -> [CGPoint] {
        guard let lastPoint = points.last else { return [newPoint] }
        guard hypot(newPoint.x - lastPoint.x, newPoint.y - lastPoint.y) >= minimumPointSpacing else { return points }
        return points + [newPoint]
    }

    /// A smooth path through the points: straight segments between the
    /// midpoints, curving through each point (quadratic smoothing) — so a
    /// quick scribble looks drawn, not jagged. In whatever space the
    /// points are in.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let firstPoint = points.first else { return path }
        path.move(to: firstPoint)
        guard points.count > 2 else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return path
        }
        for pointIndex in 1..<(points.count - 1) {
            let currentPoint = points[pointIndex]
            let nextPoint = points[pointIndex + 1]
            let midpoint = CGPoint(x: (currentPoint.x + nextPoint.x) / 2, y: (currentPoint.y + nextPoint.y) / 2)
            path.addQuadCurve(to: midpoint, control: currentPoint)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// The area all the strokes on one screen cover.
    static func combinedBoundingRect(of strokes: [VesperSketchStroke]) -> CGRect {
        strokes.reduce(CGRect.null) { combinedRect, stroke in combinedRect.union(stroke.globalBoundingRect) }
    }

    /// Maps a global AppKit point into a screenshot's pixels (top-left
    /// origin) for the screen `displayFrame`.
    static func screenshotPixel(
        forGlobalPoint globalPoint: CGPoint,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGPoint {
        CGPoint(
            x: (globalPoint.x - displayFrame.minX) * CGFloat(screenshotWidthInPixels) / max(displayFrame.width, 1),
            y: (displayFrame.maxY - globalPoint.y) * CGFloat(screenshotHeightInPixels) / max(displayFrame.height, 1)
        )
    }

    /// Draws the strokes onto an image of `imageArea` (a global AppKit
    /// rect: a whole screen, or the close-up's area) — the version Claude
    /// sees. Strokes are a vivid magenta no app uses, with a thin dark
    /// edge so they read on light and dark screens; taps are rings.
    /// Returns the original image if drawing fails.
    static func image(_ screenImage: CGImage, overlaying strokes: [VesperSketchStroke], imageArea: CGRect) -> CGImage {
        guard !strokes.isEmpty, imageArea.width > 0, imageArea.height > 0,
              let drawingContext = CGContext(
                data: nil,
                width: screenImage.width,
                height: screenImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return screenImage
        }
        let imageSize = CGSize(width: screenImage.width, height: screenImage.height)
        drawingContext.draw(screenImage, in: CGRect(origin: .zero, size: imageSize))

        // Global AppKit (bottom-left origin) → this image's pixels, which
        // a CGContext also counts from the bottom-left.
        let pixelsPerPoint = imageSize.width / imageArea.width
        func imagePoint(_ globalPoint: CGPoint) -> CGPoint {
            CGPoint(
                x: (globalPoint.x - imageArea.minX) * pixelsPerPoint,
                y: (globalPoint.y - imageArea.minY) * (imageSize.height / imageArea.height)
            )
        }
        let strokeWidth = max(3, 3 * pixelsPerPoint)
        let markColor = CGColor(red: 1, green: 0.16, blue: 0.62, alpha: 1)
        let edgeColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        drawingContext.setLineCap(.round)
        drawingContext.setLineJoin(.round)

        for stroke in strokes {
            let strokePath: CGPath
            if stroke.isTap, let tapPoint = stroke.globalPoints.first {
                let ringRadius = tapRingRadius * pixelsPerPoint
                let ringCenter = imagePoint(tapPoint)
                strokePath = CGPath(ellipseIn: CGRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2), transform: nil)
            } else {
                strokePath = smoothPath(through: stroke.globalPoints.map(imagePoint))
            }
            // A dark edge first, so the mark reads on any background.
            drawingContext.addPath(strokePath)
            drawingContext.setStrokeColor(edgeColor)
            drawingContext.setLineWidth(strokeWidth + 2 * max(1, pixelsPerPoint))
            drawingContext.strokePath()
            drawingContext.addPath(strokePath)
            drawingContext.setStrokeColor(markColor)
            drawingContext.setLineWidth(strokeWidth)
            drawingContext.strokePath()
        }
        return drawingContext.makeImage() ?? screenImage
    }

    /// The area a close-up should show around the marks: their extent
    /// with room around it — at least 320×200 points so there's context,
    /// at most 700×440 — kept on its screen.
    static func closeUpRegion(around markedArea: CGRect, displayFrame: CGRect) -> CGRect {
        let minimumSize = CGSize(width: 320, height: 200)
        let maximumSize = CGSize(width: 700, height: 440)
        let paddedArea = markedArea.insetBy(dx: -24, dy: -24)
        let regionWidth = min(max(paddedArea.width, minimumSize.width), maximumSize.width)
        let regionHeight = min(max(paddedArea.height, minimumSize.height), maximumSize.height)
        var region = CGRect(x: paddedArea.midX - regionWidth / 2, y: paddedArea.midY - regionHeight / 2, width: regionWidth, height: regionHeight)
        region.origin.x = min(max(region.minX, displayFrame.minX), displayFrame.maxX - region.width)
        region.origin.y = min(max(region.minY, displayFrame.minY), displayFrame.maxY - region.height)
        return region
    }
}
