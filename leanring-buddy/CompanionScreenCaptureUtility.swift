//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// Where the mouse pointer was, in this screenshot's pixels (top-left
    /// origin) — only on the screen the pointer is on. "What's this?" is
    /// usually about whatever is under it.
    var mousePointerScreenshotPixel: CGPoint? = nil
    /// The user's drawn marks are burned into this screenshot, so it can't
    /// be compared with the screen as it is (look before clicking).
    var hasUserMarksDrawnOn: Bool = false
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Normal capture size. Measured: at 1280px Claude points within 0–4px
    /// of the true target; at 1024px error rose to as much as 19px on small
    /// UI text, so the smaller size is reserved for saver mode.
    private static let standardMaximumScreenshotDimension = 1280
    /// Saver-mode capture size: ~33% fewer tokens per turn than 1280px.
    private static let saverModeMaximumScreenshotDimension = 1024

    /// Captures connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    ///
    /// In saver mode (`onlyCursorScreenAtReducedResolution`), only the
    /// screen with the cursor is captured, at a smaller size, to stretch a
    /// nearly-spent subscription budget.
    /// `sketchStrokes` (what the user drew while asking) are drawn onto the
    /// screenshots of their screens, so Claude sees exactly what they marked.
    /// `onlyCursorScreen` captures only the screen the mouse is on, at full size.
    static func captureAllScreensAsJPEG(
        onlyCursorScreenAtReducedResolution: Bool = false,
        onlyCursorScreen: Bool = false,
        sketchStrokes: [VesperSketchStroke] = []
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        // The cursor screen is always first after sorting.
        let displaysToCapture = onlyCursorScreenAtReducedResolution || onlyCursorScreen
            ? Array(sortedDisplays.prefix(1))
            : sortedDisplays
        let maxDimension = onlyCursorScreenAtReducedResolution
            ? saverModeMaximumScreenshotDimension
            : standardMaximumScreenshotDimension

        for (displayIndex, display) in displaysToCapture.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            let strokesOnThisScreen = sketchStrokes.filter { $0.displayFrame == displayFrame }
            guard let jpegData = await encodeAsJPEG(cgImage, overlaying: strokesOnThisScreen, imageArea: displayFrame) else {
                continue
            }

            let screenLabel: String
            if displaysToCapture.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — secondary screen"
            }

            // The pointer in this screenshot's pixels: AppKit points are
            // bottom-left-origin, the screenshot is top-left-origin.
            let mousePointerScreenshotPixel: CGPoint? = isCursorScreen && displayFrame.width > 0 && displayFrame.height > 0
                ? CGPoint(
                    x: ((mouseLocation.x - displayFrame.minX) * CGFloat(configuration.width) / displayFrame.width).rounded(),
                    y: ((displayFrame.maxY - mouseLocation.y) * CGFloat(configuration.height) / displayFrame.height).rounded()
                )
                : nil

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height,
                mousePointerScreenshotPixel: mousePointerScreenshotPixel,
                hasUserMarksDrawnOn: !strokesOnThisScreen.isEmpty
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    // MARK: - A Close-Up of What They Pointed At

    /// A sharp crop of one area, for reading small text and icons the full
    /// screenshot shrinks away (on a 27-inch display it's half size).
    nonisolated struct CloseUpCapture: Sendable {
        let imageData: Data
        let widthInPixels: Int
        let heightInPixels: Int
    }

    /// The close-up is never wider than this (about 550 tokens at most).
    private static let maximumCloseUpWidthInPixels = 800

    /// Captures `globalRect` (AppKit global coordinates) of its screen at
    /// up to its full pixel density, without the mouse pointer (it would
    /// sit right on top of the thing they're asking about) and without
    /// Vesper's own windows. Nil if it can't be captured.
    static func captureCloseUpJPEG(ofGlobalRect globalRect: CGRect, sketchStrokes: [VesperSketchStroke] = []) async -> CloseUpCapture? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let rectCenter = CGPoint(x: globalRect.midX, y: globalRect.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(rectCenter, $0.frame, false) }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
            return nil
        }
        let clampedRect = globalRect.intersection(screen.frame)
        guard !clampedRect.isNull, clampedRect.width >= 8, clampedRect.height >= 8 else { return nil }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        // The display's own points, top-left origin.
        configuration.sourceRect = CGRect(
            x: clampedRect.minX - screen.frame.minX,
            y: screen.frame.maxY - clampedRect.maxY,
            width: clampedRect.width,
            height: clampedRect.height
        )
        let pixelScale = min(screen.backingScaleFactor, CGFloat(maximumCloseUpWidthInPixels) / clampedRect.width)
        configuration.width = max(Int((clampedRect.width * pixelScale).rounded()), 16)
        configuration.height = max(Int((clampedRect.height * pixelScale).rounded()), 16)
        configuration.showsCursor = false

        guard let closeUpImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let jpegData = await encodeAsJPEG(closeUpImage, overlaying: sketchStrokes, imageArea: clampedRect) else {
            return nil
        }
        return CloseUpCapture(imageData: jpegData, widthInPixels: configuration.width, heightInPixels: configuration.height)
    }

    /// JPEG-encodes a screenshot off the main actor (`@concurrent`). At
    /// 1280px per screen the encode takes long enough that, on the main
    /// actor, it stalled the cursor and the hotkey right at release.
    /// Any strokes are drawn on first (also off the main actor).
    @concurrent
    nonisolated private static func encodeAsJPEG(
        _ capturedImage: CGImage,
        overlaying sketchStrokes: [VesperSketchStroke] = [],
        imageArea: CGRect = .zero
    ) async -> Data? {
        let screenshotImage = sketchStrokes.isEmpty
            ? capturedImage
            : VesperSketchGeometry.image(capturedImage, overlaying: sketchStrokes, imageArea: imageArea)
        let jpegData = NSMutableData()
        guard let jpegDestination = CGImageDestinationCreateWithData(
            jpegData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let jpegProperties = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(jpegDestination, screenshotImage, jpegProperties)
        guard CGImageDestinationFinalize(jpegDestination) else { return nil }
        return jpegData as Data
    }

    // MARK: - Look Before Clicking

    /// The filter for the last screen checked, reused for a while: listing
    /// every window is the slow part of a capture.
    private static var cachedClickCheckFilter: (displayFrame: CGRect, filter: SCContentFilter, createdAt: Date)?

    /// For the look-before-click check (VesperClickTargetCheck): captures
    /// the patch around `globalPoint` on screen right now (at the
    /// screenshot's density, without the pointer and Vesper's windows) and
    /// compares it with the screenshot Claude saw. Nil if it can't capture.
    static func clickTargetComparison(aroundGlobalPoint globalPoint: CGPoint, seenIn screenCapture: CompanionScreenCapture) async -> VesperClickTargetCheck.Comparison? {
        let displayFrame = screenCapture.displayFrame
        let patchInDisplayPoints = VesperClickTargetCheck.patchRectInDisplayPoints(aroundGlobalPoint: globalPoint, displayFrame: displayFrame)
        let patchInScreenshotPixels = VesperClickTargetCheck.patchRectInScreenshotPixels(
            patchRectInDisplayPoints: patchInDisplayPoints,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
        )
        guard let filter = await clickCheckFilter(forDisplayFrame: displayFrame) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = patchInDisplayPoints
        configuration.width = max(Int(patchInScreenshotPixels.width.rounded()), 8)
        configuration.height = max(Int(patchInScreenshotPixels.height.rounded()), 8)
        configuration.showsCursor = false
        guard let currentPatchImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let currentGrid = VesperClickTargetCheck.grayscaleGrid(of: currentPatchImage) else {
            return nil
        }
        let screenshotPixelsPerPoint = CGFloat(screenCapture.screenshotWidthInPixels) / max(displayFrame.width, 1)
        return await compareClickPatch(
            currentGrid: currentGrid,
            screenshotJPEG: screenCapture.imageData,
            patchRectInScreenshotPixels: patchInScreenshotPixels,
            screenshotPixelsPerPoint: screenshotPixelsPerPoint
        )
    }

    /// Decodes the screenshot and searches it off the main actor.
    @concurrent
    nonisolated private static func compareClickPatch(
        currentGrid: [UInt8],
        screenshotJPEG: Data,
        patchRectInScreenshotPixels: CGRect,
        screenshotPixelsPerPoint: CGFloat
    ) async -> VesperClickTargetCheck.Comparison? {
        guard let imageSource = CGImageSourceCreateWithData(screenshotJPEG as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        return VesperClickTargetCheck.compare(
            currentGrid: currentGrid,
            screenshot: screenshotImage,
            patchRectInScreenshotPixels: patchRectInScreenshotPixels,
            screenshotPixelsPerPoint: screenshotPixelsPerPoint
        )
    }

    private static func clickCheckFilter(forDisplayFrame displayFrame: CGRect) async -> SCContentFilter? {
        if let cachedClickCheckFilter, cachedClickCheckFilter.displayFrame == displayFrame,
           Date().timeIntervalSince(cachedClickCheckFilter.createdAt) < 60 {
            return cachedClickCheckFilter.filter
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let screen = NSScreen.screens.first(where: { $0.frame == displayFrame }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == screenNumber }) else {
            return nil
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)
        cachedClickCheckFilter = (displayFrame, filter, Date())
        return filter
    }

    // MARK: - Screen Fingerprints (has the screen settled?)

    private static let fingerprintWidth = 64
    private static let fingerprintHeight = 40

    /// What to fingerprint: the screen the cursor is on, with Vesper's own
    /// windows left out. Found once per settle-wait, because listing every
    /// window is the slow part of a capture.
    static func makeCursorScreenFingerprintFilter() async -> SCContentFilter? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let mouseLocation = NSEvent.mouseLocation
        let cursorScreenNumber = NSScreen.screens
            .first { NSMouseInRect(mouseLocation, $0.frame, false) }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == cursorScreenNumber }) ?? content.displays.first else { return nil }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        return SCContentFilter(display: display, excludingWindows: ownAppWindows)
    }

    /// A tiny grayscale thumbnail of the screen — cheap enough to take
    /// several times a second to tell when a page has finished changing.
    /// Nil if capture fails.
    static func captureFingerprint(using fingerprintFilter: SCContentFilter) async -> [UInt8]? {
        let configuration = SCStreamConfiguration()
        configuration.width = fingerprintWidth
        configuration.height = fingerprintHeight
        // The pointer moves to every click; it must not count as the screen changing.
        configuration.showsCursor = false
        guard let thumbnailImage = try? await SCScreenshotManager.captureImage(
            contentFilter: fingerprintFilter,
            configuration: configuration
        ) else { return nil }

        var grayscalePixels = [UInt8](repeating: 0, count: fingerprintWidth * fingerprintHeight)
        let didDraw = grayscalePixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let grayscaleContext = CGContext(
                data: pixelBuffer.baseAddress,
                width: fingerprintWidth,
                height: fingerprintHeight,
                bitsPerComponent: 8,
                bytesPerRow: fingerprintWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            grayscaleContext.draw(thumbnailImage, in: CGRect(x: 0, y: 0, width: fingerprintWidth, height: fingerprintHeight))
            return true
        }
        return didDraw ? grayscalePixels : nil
    }

}
