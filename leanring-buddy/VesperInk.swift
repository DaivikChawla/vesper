//
//  VesperInk.swift
//  leanring-buddy
//
//  Her drawings ("ink"): circles, underlines, arrows and boxes she draws
//  on the screen with her cursor while she explains something.
//
//  Her cursor is the pen: it flies to where the mark starts and draws it
//  in light, so every mark visibly comes from her hand. Marks from one
//  reply build up (numbered once there are two or more, the older ones
//  dimmed while she draws the next), and they evaporate when they're no
//  longer needed: the next time she's asked something, when the user
//  clicks or scrolls, or a while after she's done talking.
//
//  This file is the data and the geometry only — the hand-drawn shapes,
//  as points in a screen's top-left-origin space — with no AppKit, so
//  scripts/test-ink-geometry.sh checks it directly. The overlay draws it
//  (OverlayWindow), CompanionManager decides when.
//

import CoreGraphics
import Foundation

/// One drawing, in AppKit global coordinates (bottom-left origin).
enum VesperInkShape: Equatable {
    /// A hand-drawn loop around one thing.
    case encircle(globalRect: CGRect)
    /// A line under a piece of text.
    case underline(globalRect: CGRect)
    /// From one place to another: where to drag, what leads to what.
    case arrow(fromGlobalPoint: CGPoint, toGlobalPoint: CGPoint)
    /// A rounded frame around an area ([HIGHLIGHT]).
    case box(globalRect: CGRect)
}

/// A drawing mapped onto a screen, before it becomes a numbered mark.
struct VesperInkPlacement: Equatable {
    let shape: VesperInkShape
    /// The frame of the screen it's on (AppKit global coordinates).
    let displayFrame: CGRect
    let label: String?
}

/// One mark on screen, as CompanionManager publishes it.
struct VesperInkMark: Equatable, Identifiable {
    /// Unique for the life of the app (also seeds the hand-drawn wobble,
    /// so a mark looks the same every time it's drawn).
    let id: Int
    let shape: VesperInkShape
    /// The frame of the screen it's on (AppKit global coordinates).
    let displayFrame: CGRect
    let label: String?
    /// 1, 2, 3… once a reply has two or more marks; nil for a lone mark.
    var badgeNumber: Int?

    /// Where her pen touches down, in AppKit global coordinates.
    var drawingStartGlobalPoint: CGPoint {
        let strokes = VesperInkGeometry.strokes(for: self)
        let startInScreenSpace = strokes.mainStroke.first ?? .zero
        return VesperInkGeometry.globalPoint(fromScreenSpacePoint: startInScreenSpace, displayFrame: displayFrame)
    }
}

/// The points her pen passes through for one mark, in the screen's
/// top-left-origin space (the overlay's own coordinates).
struct VesperInkStrokes: Equatable {
    /// Drawn by the cursor, start to end.
    let mainStroke: [CGPoint]
    /// Drawn right after the main stroke, without the cursor tracing it
    /// (an arrow's head: a quick flick).
    let finishingStroke: [CGPoint]?
    /// Where the step number sits, just outside the mark.
    let badgeCenter: CGPoint
}

enum VesperInkGeometry {
    // MARK: Coordinates

    /// AppKit global (bottom-left origin) → the screen's top-left-origin space.
    static func screenSpacePoint(fromGlobalPoint globalPoint: CGPoint, displayFrame: CGRect) -> CGPoint {
        CGPoint(x: globalPoint.x - displayFrame.minX, y: displayFrame.maxY - globalPoint.y)
    }

    static func globalPoint(fromScreenSpacePoint screenSpacePoint: CGPoint, displayFrame: CGRect) -> CGPoint {
        CGPoint(x: screenSpacePoint.x + displayFrame.minX, y: displayFrame.maxY - screenSpacePoint.y)
    }

    static func screenSpaceRect(fromGlobalRect globalRect: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - displayFrame.minX,
            y: displayFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    // MARK: Strokes

    static func strokes(for inkMark: VesperInkMark) -> VesperInkStrokes {
        let displayFrame = inkMark.displayFrame
        let screenBounds = CGRect(origin: .zero, size: displayFrame.size)
        let strokes: VesperInkStrokes
        switch inkMark.shape {
        case .encircle(let globalRect):
            strokes = encircleStrokes(around: screenSpaceRect(fromGlobalRect: globalRect, displayFrame: displayFrame), seed: inkMark.id)
        case .underline(let globalRect):
            strokes = underlineStrokes(below: screenSpaceRect(fromGlobalRect: globalRect, displayFrame: displayFrame), seed: inkMark.id)
        case .arrow(let fromGlobalPoint, let toGlobalPoint):
            strokes = arrowStrokes(
                from: screenSpacePoint(fromGlobalPoint: fromGlobalPoint, displayFrame: displayFrame),
                to: screenSpacePoint(fromGlobalPoint: toGlobalPoint, displayFrame: displayFrame),
                seed: inkMark.id
            )
        case .box(let globalRect):
            strokes = boxStrokes(around: screenSpaceRect(fromGlobalRect: globalRect, displayFrame: displayFrame))
        }
        // The number never hangs off the screen's edge.
        let badgeMargin: CGFloat = 12
        let clampedBadgeCenter = CGPoint(
            x: min(max(strokes.badgeCenter.x, badgeMargin), max(screenBounds.width - badgeMargin, badgeMargin)),
            y: min(max(strokes.badgeCenter.y, badgeMargin), max(screenBounds.height - badgeMargin, badgeMargin))
        )
        return VesperInkStrokes(mainStroke: strokes.mainStroke, finishingStroke: strokes.finishingStroke, badgeCenter: clampedBadgeCenter)
    }

    /// A loop around `rect`, drawn the way a hand circles something: it
    /// starts upper right, goes round counterclockwise, and runs a little
    /// past where it started, slightly inside the first pass — never a
    /// perfect ellipse. The wobble comes from `seed`, so the same mark
    /// always looks the same.
    static func encircleStrokes(around rect: CGRect, seed: Int) -> VesperInkStrokes {
        var randomSource = VesperInkRandomSource(seed: seed)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // The loop has to clear the rectangle's corners, not only its
        // sides: an ellipse with the rectangle's half-sizes cuts through
        // them. Along the longer side the loop gets a little room (more for
        // squarish things, which get a near-circle), and the shorter radius
        // is then exactly what clears the corners — so a word gets a snug
        // oval and a button a round loop. 7% more makes room for the wobble.
        let cornerClearance: CGFloat = 3
        let halfWidth = rect.width / 2 + cornerClearance
        let halfHeight = rect.height / 2 + cornerClearance
        let horizontalRadius: CGFloat
        let verticalRadius: CGFloat
        if halfWidth >= halfHeight {
            let longerSideScale = 1 + 0.414 * (halfHeight / halfWidth)
            let longerRadius = max(halfWidth * longerSideScale, halfWidth + 10)
            let shareOfLongerRadius = halfWidth / longerRadius
            horizontalRadius = longerRadius * 1.07
            verticalRadius = halfHeight / sqrt(1 - shareOfLongerRadius * shareOfLongerRadius) * 1.07
        } else {
            let longerSideScale = 1 + 0.414 * (halfWidth / halfHeight)
            let longerRadius = max(halfHeight * longerSideScale, halfHeight + 10)
            let shareOfLongerRadius = halfHeight / longerRadius
            verticalRadius = longerRadius * 1.07
            horizontalRadius = halfWidth / sqrt(1 - shareOfLongerRadius * shareOfLongerRadius) * 1.07
        }
        // A slight tilt, like a loop drawn quickly.
        let tiltRadians = randomSource.nextValue(in: -0.05...0.05)
        let wobblePhaseOne = randomSource.nextValue(in: 0...(2 * .pi))
        let wobblePhaseTwo = randomSource.nextValue(in: 0...(2 * .pi))

        // Screen space has y down, so decreasing angles go counterclockwise.
        let startAngle = -CGFloat.pi / 3
        let overshootRadians: CGFloat = 0.42
        let totalSweep = 2 * CGFloat.pi + overshootRadians
        let sampleCount = 96

        var loopPoints: [CGPoint] = []
        loopPoints.reserveCapacity(sampleCount + 1)
        for sampleIndex in 0...sampleCount {
            let sweptShare = CGFloat(sampleIndex) / CGFloat(sampleCount)
            let sweptAngle = sweptShare * totalSweep
            let angle = startAngle - sweptAngle
            // Two slow wobbles; and once round, the overshoot draws in by up
            // to 6%, passing just inside where it started.
            let wobble = 1 + 0.03 * sin(2 * angle + wobblePhaseOne) + 0.015 * sin(3 * angle + wobblePhaseTwo)
            let overshootShare = max(sweptAngle - 2 * .pi, 0) / overshootRadians
            let drawInward = 1 - 0.06 * overshootShare
            let localX = horizontalRadius * cos(angle) * wobble * drawInward
            let localY = verticalRadius * sin(angle) * wobble * drawInward
            loopPoints.append(CGPoint(
                x: center.x + localX * cos(tiltRadians) - localY * sin(tiltRadians),
                y: center.y + localX * sin(tiltRadians) + localY * cos(tiltRadians)
            ))
        }
        // The number sits outside the upper-left of the loop.
        let badgeAngle = CGFloat.pi * 1.25
        let badgeCenter = CGPoint(
            x: center.x + (horizontalRadius + 11) * cos(badgeAngle),
            y: center.y + (verticalRadius + 11) * sin(badgeAngle)
        )
        return VesperInkStrokes(mainStroke: loopPoints, finishingStroke: nil, badgeCenter: badgeCenter)
    }

    /// A line just under `rect`'s text, a touch wider than it, bowing up
    /// very slightly the way a quick underline does.
    static func underlineStrokes(below rect: CGRect, seed: Int) -> VesperInkStrokes {
        var randomSource = VesperInkRandomSource(seed: seed)
        let lineY = rect.maxY + 3.5
        let startX = rect.minX - 3
        let endX = rect.maxX + 4
        let endRise = randomSource.nextValue(in: -1.2...0.4)
        let sampleCount = 28
        var linePoints: [CGPoint] = []
        for sampleIndex in 0...sampleCount {
            let share = CGFloat(sampleIndex) / CGFloat(sampleCount)
            linePoints.append(CGPoint(
                x: startX + (endX - startX) * share,
                y: lineY - 1.4 * sin(.pi * share) + endRise * share
            ))
        }
        return VesperInkStrokes(
            mainStroke: linePoints,
            finishingStroke: nil,
            badgeCenter: CGPoint(x: startX - 12, y: lineY - 9)
        )
    }

    /// An arrow from `start` to `end`: a gently bowed shaft, then a
    /// two-stroke head flicked on at the tip. The head's tip is exactly `end`.
    static func arrowStrokes(from start: CGPoint, to end: CGPoint, seed: Int) -> VesperInkStrokes {
        var randomSource = VesperInkRandomSource(seed: seed)
        let travel = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        let length = max(hypot(travel.dx, travel.dy), 0.001)
        let unitTravel = CGVector(dx: travel.dx / length, dy: travel.dy / length)
        // Bow toward the top of the screen where there's a choice.
        var unitSideways = CGVector(dx: unitTravel.dy, dy: -unitTravel.dx)
        if unitSideways.dy > 0 {
            unitSideways = CGVector(dx: -unitSideways.dx, dy: -unitSideways.dy)
        }
        let bowAmount = length * randomSource.nextValue(in: 0.07...0.11)
        let controlPoint = CGPoint(
            x: (start.x + end.x) / 2 + unitSideways.dx * bowAmount,
            y: (start.y + end.y) / 2 + unitSideways.dy * bowAmount
        )

        let sampleCount = max(Int(length / 12), 16)
        var shaftPoints: [CGPoint] = []
        for sampleIndex in 0...sampleCount {
            let progress = CGFloat(sampleIndex) / CGFloat(sampleCount)
            let remaining = 1 - progress
            shaftPoints.append(CGPoint(
                x: remaining * remaining * start.x + 2 * remaining * progress * controlPoint.x + progress * progress * end.x,
                y: remaining * remaining * start.y + 2 * remaining * progress * controlPoint.y + progress * progress * end.y
            ))
        }

        // The head follows the shaft's direction where it arrives.
        let arrivalDirection = CGVector(dx: end.x - controlPoint.x, dy: end.y - controlPoint.y)
        let arrivalLength = max(hypot(arrivalDirection.dx, arrivalDirection.dy), 0.001)
        let unitArrival = CGVector(dx: arrivalDirection.dx / arrivalLength, dy: arrivalDirection.dy / arrivalLength)
        let headLength = min(max(length * 0.22, 9), 15)
        let headSpread: CGFloat = 0.5
        func headWingPoint(rotatedBy angle: CGFloat) -> CGPoint {
            let rotatedX = unitArrival.dx * cos(angle) - unitArrival.dy * sin(angle)
            let rotatedY = unitArrival.dx * sin(angle) + unitArrival.dy * cos(angle)
            return CGPoint(x: end.x - rotatedX * headLength, y: end.y - rotatedY * headLength)
        }
        let headPoints = [headWingPoint(rotatedBy: headSpread), end, headWingPoint(rotatedBy: -headSpread)]

        return VesperInkStrokes(
            mainStroke: shaftPoints,
            finishingStroke: headPoints,
            badgeCenter: CGPoint(x: start.x - unitTravel.dx * 13, y: start.y - unitTravel.dy * 13)
        )
    }

    /// A rounded frame around `rect`, drawn clockwise from its top-left.
    static func boxStrokes(around rect: CGRect) -> VesperInkStrokes {
        let cornerRadius = min(max(min(rect.width, rect.height) * 0.12, 4), 12)
        var framePoints: [CGPoint] = []
        func addCorner(center: CGPoint, fromAngle: CGFloat) {
            for cornerStep in 0...6 {
                let angle = fromAngle + CGFloat(cornerStep) / 6 * (.pi / 2)
                framePoints.append(CGPoint(x: center.x + cornerRadius * cos(angle), y: center.y + cornerRadius * sin(angle)))
            }
        }
        // Screen space has y down: angles grow clockwise.
        addCorner(center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius), fromAngle: .pi)
        addCorner(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius), fromAngle: -.pi / 2)
        addCorner(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius), fromAngle: 0)
        addCorner(center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius), fromAngle: .pi / 2)
        // Back to where it started, closing the frame.
        if let firstPoint = framePoints.first {
            framePoints.append(firstPoint)
        }
        return VesperInkStrokes(
            mainStroke: framePoints,
            finishingStroke: nil,
            badgeCenter: CGPoint(x: rect.minX - 2, y: rect.minY - 2)
        )
    }

    // MARK: Measuring Strokes

    /// Running length along the points, starting at 0 — for moving the pen
    /// at a steady speed and matching the drawn length to it.
    static func cumulativeLengths(of points: [CGPoint]) -> [CGFloat] {
        var runningLength: CGFloat = 0
        var cumulativeLengths: [CGFloat] = [0]
        cumulativeLengths.reserveCapacity(points.count)
        for pointIndex in points.indices.dropFirst() {
            let previousPoint = points[pointIndex - 1]
            let currentPoint = points[pointIndex]
            runningLength += hypot(currentPoint.x - previousPoint.x, currentPoint.y - previousPoint.y)
            cumulativeLengths.append(runningLength)
        }
        return cumulativeLengths
    }

    /// The point `distance` along the stroke (clamped to its ends).
    static func point(atDistance distance: CGFloat, along points: [CGPoint], cumulativeLengths: [CGFloat]) -> CGPoint {
        guard let lastPoint = points.last, let totalLength = cumulativeLengths.last, totalLength > 0 else {
            return points.first ?? .zero
        }
        if distance <= 0 { return points[0] }
        if distance >= totalLength { return lastPoint }
        // Binary search for the segment containing `distance`.
        var lowerIndex = 0
        var upperIndex = cumulativeLengths.count - 1
        while upperIndex - lowerIndex > 1 {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if cumulativeLengths[middleIndex] < distance {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }
        let segmentLength = cumulativeLengths[upperIndex] - cumulativeLengths[lowerIndex]
        let shareOfSegment = segmentLength > 0 ? (distance - cumulativeLengths[lowerIndex]) / segmentLength : 0
        let segmentStart = points[lowerIndex]
        let segmentEnd = points[upperIndex]
        return CGPoint(
            x: segmentStart.x + (segmentEnd.x - segmentStart.x) * shareOfSegment,
            y: segmentStart.y + (segmentEnd.y - segmentStart.y) * shareOfSegment
        )
    }

    /// How long her pen takes over a stroke: brisk, like a quick hand —
    /// short marks in about a third of a second, long ones never over 0.85 s.
    static func drawingDurationSeconds(forStrokeLength strokeLength: CGFloat) -> Double {
        min(max(Double(strokeLength) / 950.0, 0.32), 0.85)
    }

    /// Ease in and out, the way a hand speeds up and slows down.
    static func easedDrawingProgress(forLinearProgress linearProgress: Double) -> Double {
        let clampedProgress = min(max(linearProgress, 0), 1)
        return clampedProgress * clampedProgress * (3 - 2 * clampedProgress)
    }
}

/// A tiny deterministic random source, so each mark's wobble comes from
/// its id and it looks the same however often it's drawn.
struct VesperInkRandomSource {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
    }

    mutating func nextValue(in range: ClosedRange<CGFloat>) -> CGFloat {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed = mixed ^ (mixed >> 31)
        let unitValue = CGFloat(Double(mixed >> 11) / Double(1 << 53))
        return range.lowerBound + (range.upperBound - range.lowerBound) * unitValue
    }
}
