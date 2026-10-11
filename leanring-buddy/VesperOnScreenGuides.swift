//
//  VesperOnScreenGuides.swift
//  leanring-buddy
//
//  The small pieces of state behind two on-screen guides, kept free of
//  AppKit so they can be tested without building the app:
//
//  - highlight geometry: the area a [HIGHLIGHT:x1,y1,x2,y2:label:screenN]
//    frame is drawn around (her pen draws it; see VesperInk), and
//  - walkthrough step progress: the "2/4" in the island while she walks
//    through several pointed or drawn steps.
//

import CoreGraphics
import Foundation

enum VesperHighlightGeometry {
    /// The rectangle sits a little outside the area, so its stroke doesn't
    /// cover the edge of what it's pointing out.
    static let outsetPoints: CGFloat = 4
    /// A highlight never gets thinner than this (a single line of text, or
    /// an area that was clamped onto the screen's edge).
    static let minimumSidePoints: CGFloat = 16
    static let maximumCornerRadius: CGFloat = 8

    /// Builds the rectangle to draw from two opposite corners already mapped
    /// to screen points (in either order: flipping the y axis swaps them).
    /// Grown to the minimum size around its center, and kept on its screen.
    static func drawableRect(betweenCorner firstCorner: CGPoint, andCorner oppositeCorner: CGPoint, displayFrame: CGRect) -> CGRect {
        var drawableRect = CGRect(
            x: min(firstCorner.x, oppositeCorner.x),
            y: min(firstCorner.y, oppositeCorner.y),
            width: abs(oppositeCorner.x - firstCorner.x),
            height: abs(oppositeCorner.y - firstCorner.y)
        ).insetBy(dx: -outsetPoints, dy: -outsetPoints)

        if drawableRect.width < minimumSidePoints {
            drawableRect = drawableRect.insetBy(dx: -(minimumSidePoints - drawableRect.width) / 2, dy: 0)
        }
        if drawableRect.height < minimumSidePoints {
            drawableRect = drawableRect.insetBy(dx: 0, dy: -(minimumSidePoints - drawableRect.height) / 2)
        }

        // Keep it on its screen: shift it back inside first (so an area at
        // the edge keeps its size), then trim anything still hanging over.
        if drawableRect.minX < displayFrame.minX { drawableRect.origin.x = displayFrame.minX }
        if drawableRect.minY < displayFrame.minY { drawableRect.origin.y = displayFrame.minY }
        if drawableRect.maxX > displayFrame.maxX { drawableRect.origin.x = displayFrame.maxX - drawableRect.width }
        if drawableRect.maxY > displayFrame.maxY { drawableRect.origin.y = displayFrame.maxY - drawableRect.height }
        return drawableRect.intersection(displayFrame)
    }

    /// A rounded rectangle's corner radius can't exceed half its shorter side
    /// (CGPath asserts on that), so small highlights get rounder corners.
    static func cornerRadius(for drawableRect: CGRect) -> CGFloat {
        max(0, min(maximumCornerRadius, drawableRect.width / 2, drawableRect.height / 2))
    }
}

/// Which pointed step of a walkthrough is playing, e.g. step 2 of 4. The
/// total can grow while the reply is still streaming in.
struct VesperWalkthroughStepProgress: Equatable {
    let currentStepNumber: Int
    let totalStepCount: Int

    /// Only a reply with at least two pointed steps is a walkthrough; one
    /// point doesn't need a counter.
    static func makeIfWalkthrough(currentStepNumber: Int, totalStepCount: Int) -> VesperWalkthroughStepProgress? {
        guard totalStepCount >= 2, currentStepNumber >= 1 else { return nil }
        return VesperWalkthroughStepProgress(
            currentStepNumber: min(currentStepNumber, totalStepCount),
            totalStepCount: totalStepCount
        )
    }

    /// "2/4"
    var chipText: String {
        "\(currentStepNumber)/\(totalStepCount)"
    }
}
