//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for Vesper's cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//
//  Built for low CPU. The cursor itself (triangle, glow, trail, voice halo,
//  thinking orbit, listening waveform, ripples) is made of Core Animation
//  layers that are moved, rotated and scaled every frame — work the GPU
//  compositor does without redrawing anything — and its idle breathing,
//  thinking orbit and one-off gestures are Core Animation animations that
//  run in the render server, costing the app nothing. Nothing here is
//  SwiftUI: her words, notices and questions live in the island at the top
//  of the screen (VesperIsland), so the cursor is only her hand — it
//  points, draws and acts. (The earlier full-screen SwiftUI overlay
//  re-laid out 2560×1440 of view tree on every mouse move: up to ~30% CPU.)
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor on a critically damped spring
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it
    case pointingAtTarget
    /// Buddy is drawing one of her marks: the pen follows the stroke while
    /// the ink appears behind it (see VesperInk)
    case drawingInk
}

// MARK: - Per-Screen Cursor Controller

/// Runs Vesper's cursor on one screen: follows the mouse, flies to targets
/// and back, shows the waveform / thinking indicator / caption bubble, and
/// hands off to another screen's controller when a target is over there.
///
/// All motion lives in plain stored properties advanced by the screen's
/// display link; each frame only moves layers and small views. Appearance
/// (tint, which glyph is showing, bubble text) is recomputed only when the
/// manager's published state changes.
@MainActor
final class VesperCursorOverlayController {
    let rootView: NSView

    private let screenFrame: CGRect
    private let companionManager: CompanionManager
    private let frameClock = OverlayFrameClock()
    private var stateSubscriptions: Set<AnyCancellable> = []

    // MARK: Layers (the cursor itself)

    /// Full-screen, layer-hosting view: its layers are ours, so AppKit never
    /// redraws or re-lays them out.
    private let cursorLayerHostView = NSView()
    /// Moved and rotated every frame.
    private let cursorGlyphLayer = CALayer()
    /// Fades and shrinks her a little when she's been idle and the mouse
    /// has been still for a couple of seconds. Only `setIdleDimmed` writes it.
    private let idleDimLayer = CALayer()
    /// Carries the endless breathing animation (render server, zero app CPU).
    private let breathingLayer = CALayer()
    /// Between the breathing and the triangle: owns her lasting "expression"
    /// — smaller while listening and thinking, drooped while resting. Only
    /// `setExpression` writes it, so these states never fight each other.
    private let expressionLayer = CALayer()
    /// One-off gestures (the hello pop, the click press) animate this
    /// layer's scale, on top of whatever expression she's holding.
    private let triangleLayer = CAShapeLayer()
    /// Reused dots for the flight trail.
    private var trailDotLayers: [CALayer] = []
    /// Follows the cursor like the glyph but never rotates or fades with it,
    /// so the halo, thinking orbit and waveform stay upright and can show
    /// while the triangle itself is hidden (listening).
    private let cursorAccessoryLayer = CALayer()
    /// Soft radial light behind her that swells with her voice (and with the
    /// mic while listening). A gradient, not a shadow: nothing is re-blurred.
    private let haloLayer = CAGradientLayer()
    /// Thinking: a short comet of dots orbiting her, plus a faint arc
    /// turning the other way. Pure render-server animation.
    private let thinkingIndicatorLayer = CALayer()
    private let thinkingOrbitReplicatorLayer = CAReplicatorLayer()
    private let thinkingOrbitDotLayer = CALayer()
    private let thinkingArcLayer = CAShapeLayer()
    /// Listening: five small bars that follow the mic level.
    private let waveformLayer = CALayer()
    private var waveformBarLayers: [CALayer] = []
    /// Reused rings for click ripples, voice echoes and highlights.
    private var effectRingLayers: [CAShapeLayer] = []
    private var nextEffectRingIndex = 0
    /// Her drawings on this screen (circles, underlines, arrows, boxes —
    /// see VesperInk), under everything else she draws.
    private let inkContainerLayer = CALayer()
    /// One mark's layers: a wide faint stroke (the glow, no blur) under the
    /// crisp stroke, the same pair for an arrow's head, and its number.
    private struct InkMarkLayers {
        let containerLayer: CALayer
        let glowStrokeLayer: CAShapeLayer
        let crispStrokeLayer: CAShapeLayer
        let finishingGlowStrokeLayer: CAShapeLayer?
        let finishingCrispStrokeLayer: CAShapeLayer?
        let badgeLayer: CALayer
        let badgeTextLayer: CATextLayer
        let strokes: VesperInkStrokes
        let cumulativeStrokeLengths: [CGFloat]
    }
    private var inkLayersByMarkID: [Int: InkMarkLayers] = [:]
    /// Marks on this screen waiting for her pen, in the order she said them.
    private var inkMarkIDsWaitingToBeDrawn: [Int] = []
    private var inkMarkIDsAlreadyDrawn = Set<Int>()
    /// The stroke her pen is drawing right now.
    private var activeInkStroke: CursorInkStroke?
    /// A place to point at that arrived while she was drawing: she goes
    /// there once the drawing is done. (`.some(nil)` means "come home".)
    private var pointingLocationWaitingForInk: CGPoint??
    /// True while her pen hops to where the next mark starts.
    private var isFlyingToPenStart = false

    /// What the user draws while holding the hotkey (see VesperSketch),
    /// over her drawings and under her cursor: a white core with a dark
    /// edge (readable on any screen) and her glow around it.
    private let sketchContainerLayer = CALayer()
    private struct SketchStrokeLayers {
        let containerLayer: CALayer
        let glowLayer: CAShapeLayer
        let edgeLayer: CAShapeLayer
        let coreLayer: CAShapeLayer
    }
    private var sketchLayersByStrokeID: [Int: SketchStrokeLayers] = [:]

    /// A guided step she's waiting for them to click: a steady ring around
    /// it, and a second ring breathing outward from it ("here").
    private let guidedTargetSteadyRingLayer = CAShapeLayer()
    private let guidedTargetPulseRingLayer = CAShapeLayer()
    private var shownGuidedStep: VesperGuidedStepDisplay?
    /// Where the last step's ring was on this screen (layer space), so the
    /// burst can play there even as the ring itself goes.
    private var lastGuidedRingCenterInLayers: CGPoint?

    // MARK: Motion state

    /// Where the buddy is, in this overlay's top-left-origin coordinates.
    private var cursorPosition: CGPoint
    private var isCursorOnThisScreen: Bool
    private var buddyNavigationMode: BuddyNavigationMode = .followingCursor
    private var isReturningToCursor = false
    /// Where the mouse was when a navigation started — moving it far enough
    /// during the return flight cancels the flight.
    private var cursorPositionWhenNavigationStarted: CGPoint = .zero
    private var followVelocity: CGVector = .zero
    private var activeFlight: CursorFlight?
    private var landingSettle: CursorLandingSettle?
    private var trailPoints: [CursorTrailPoint] = []
    /// 0…1: how fast she's flying right now. Brightens her glow.
    private var flightGlowIntensity: CGFloat = 0
    /// Default -35° (cursor-like); faces the direction of travel in flight.
    private var triangleRotationDegrees: Double = -35
    /// Grows to ~1.3x mid-flight.
    private var buddyFlightScale: CGFloat = 1
    /// What was last applied to the layers, so unchanged frames cost nothing.
    private var lastAppliedGlyphGeometry: (position: CGPoint, rotationDegrees: Double, scale: CGFloat)?
    private var lastAppliedShadowRadius: CGFloat = -1

    // MARK: Appearance state

    private var isShowingWelcome = false
    private var isWelcomeFadeInFinished = true
    private var lastAppliedTintColor: NSColor?
    private var lastAppliedIsResting: Bool?
    /// The voice state the expression and accessories last morphed to.
    private var lastAppliedVoiceState: CompanionVoiceState?
    /// The expression layer's model values (see `setExpression`).
    private var expressionScale: CGFloat = 1
    private var expressionDroopDegrees: Double = 0
    /// What the halo was last set to, so tiny changes cost nothing.
    private var lastAppliedHaloScale: CGFloat = 0.7
    private var lastAppliedHaloOpacity: Float = 0
    /// For spotting the moment her voice crosses a peak (an echo ring).
    private var previousSpeechLevelForEchoRings: CGFloat = 0
    private var lastEchoRingTimestamp: CFTimeInterval = 0
    /// Whether the thinking indicator / waveform are meant to be showing.
    /// Tracked here, not read from isHidden, because a fade-out keeps the
    /// layer unhidden for a moment after it's been asked to go.
    private var isThinkingIndicatorMeantToShow = false
    private var isWaveformMeantToShow = false
    /// Bumped on every show/hide, so a delayed step from an older change
    /// (hide after fade, orbit speed-up) knows it's stale and does nothing.
    private var thinkingIndicatorVisibilityGeneration = 0
    private var waveformVisibilityGeneration = 0

    /// The buddy sits just below-right of the mouse pointer, not on it.
    private static let followOffsetFromMouse = CGSize(width: 35, height: 25)
    /// How loosely the buddy trails the mouse. Smaller is snappier.
    private static let followSmoothingSeconds: CGFloat = 0.06
    /// How long a trail point stays visible after she passes it.
    private static let trailLifetimeSeconds: CFTimeInterval = 0.24
    private static let maximumTrailDotCount = 18
    private static let triangleSize: CGFloat = 16
    private static let baseShadowRadius: CGFloat = 7
    /// Room for the halo at its biggest.
    private static let accessoryCanvasSize: CGFloat = 56
    private static let effectRingPoolSize = 4
    /// A ring's size at scale 1; every ring effect scales from this.
    private static let effectRingDiameter: CGFloat = 20
    private static let waveformBarHeightProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]
    private static let waveformBarMinimumHeight: CGFloat = 3
    /// Thinking orbit: one lap per 1.1 s, quickening to 0.8 s after 3 s.
    private static let thinkingOrbitPeriodSeconds: CFTimeInterval = 1.1
    private static let thinkingOrbitQuickPeriodSeconds: CFTimeInterval = 0.8
    private static let secondsBeforeThinkingOrbitQuickens: TimeInterval = 3
    /// While resting her tip droops a little, like a sleepy head.
    private static let restingDroopDegrees: Double = -18
    /// Fast out, long soft tail — rings and echoes.
    private static let ringTimingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    /// System setting "Reduce motion": gestures and rings are skipped, fades stay.
    private var isReduceMotionOn: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(screen: NSScreen, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screen.frame
        self.companionManager = companionManager

        let mouseLocation = NSEvent.mouseLocation
        // NSMouseInRect (not CGRect.contains) so the very top edge counts.
        self.isCursorOnThisScreen = NSMouseInRect(mouseLocation, screen.frame, false)
        let mouseInOverlay = CGPoint(
            x: mouseLocation.x - screen.frame.origin.x,
            y: (screen.frame.origin.y + screen.frame.height) - mouseLocation.y
        )
        self.cursorPosition = CGPoint(
            x: mouseInOverlay.x + Self.followOffsetFromMouse.width,
            y: mouseInOverlay.y + Self.followOffsetFromMouse.height
        )

        let flippedRootView = FlippedContainerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        rootView = flippedRootView
        rootView.wantsLayer = true

        buildCursorLayers()
        flippedRootView.sketchController = self

        subscribeToCompanionState()
        refreshAppearance()
        applyGlyphGeometry(force: true)

        frameClock.onFrame = { [weak self] elapsedSeconds, frameTimestamp in
            self?.advanceMotion(elapsedSeconds: elapsedSeconds, frameTimestamp: frameTimestamp)
        }
        frameClock.start(on: screen)

        if isFirstAppearance && isCursorOnThisScreen {
            startWelcomeSequence()
        }
    }

    /// Stops the display link and subscriptions. Called when the overlay hides.
    func tearDown() {
        frameClock.stop()
        frameClock.onFrame = nil
        removeMouseMovementMonitors()
        stateSubscriptions.removeAll()
        // A pending idle dim must not fire on a torn-down overlay.
        idleDimGeneration += 1
    }

    // MARK: - Building the Cursor Layers

    private func buildCursorLayers() {
        cursorLayerHostView.frame = rootView.bounds
        cursorLayerHostView.autoresizingMask = [.width, .height]
        // Assigning a layer before wantsLayer makes this a layer-hosting view:
        // AppKit leaves our layer tree alone.
        let hostRootLayer = CALayer()
        cursorLayerHostView.layer = hostRootLayer
        cursorLayerHostView.wantsLayer = true
        // The layers use AppKit's bottom-left origin. AppKit resets a
        // geometryFlipped set earlier (which mirrored the cursor's path and
        // pointed the triangle the wrong way), so instead of flipping, every
        // point is converted with layerPoint(fromOverlayPoint:).
        hostRootLayer.isGeometryFlipped = false
        rootView.addSubview(cursorLayerHostView)

        // First, so her drawings sit under everything else.
        inkContainerLayer.frame = CGRect(origin: .zero, size: screenFrame.size)
        inkContainerLayer.actions = Self.noImplicitAnimations
        hostRootLayer.addSublayer(inkContainerLayer)
        sketchContainerLayer.frame = CGRect(origin: .zero, size: screenFrame.size)
        sketchContainerLayer.actions = Self.noImplicitAnimations
        hostRootLayer.addSublayer(sketchContainerLayer)
        for guidedTargetRingLayer in [guidedTargetPulseRingLayer, guidedTargetSteadyRingLayer] {
            guidedTargetRingLayer.fillColor = nil
            guidedTargetRingLayer.lineWidth = guidedTargetRingLayer === guidedTargetSteadyRingLayer ? 1.8 : 1.4
            guidedTargetRingLayer.opacity = 0
            guidedTargetRingLayer.isHidden = true
            guidedTargetRingLayer.actions = Self.noImplicitAnimations
            hostRootLayer.addSublayer(guidedTargetRingLayer)
        }

        for _ in 0..<Self.maximumTrailDotCount {
            let trailDotLayer = CALayer()
            trailDotLayer.isHidden = true
            trailDotLayer.actions = Self.noImplicitAnimations
            hostRootLayer.addSublayer(trailDotLayer)
            trailDotLayers.append(trailDotLayer)
        }

        for _ in 0..<Self.effectRingPoolSize {
            let effectRingLayer = CAShapeLayer()
            let ringBounds = CGRect(x: 0, y: 0, width: Self.effectRingDiameter, height: Self.effectRingDiameter)
            effectRingLayer.bounds = ringBounds
            effectRingLayer.path = CGPath(ellipseIn: ringBounds, transform: nil)
            effectRingLayer.fillColor = nil
            effectRingLayer.lineWidth = 1.5
            // Invisible at rest: every ring effect is an animation that ends at 0.
            effectRingLayer.opacity = 0
            effectRingLayer.actions = Self.noImplicitAnimations
            hostRootLayer.addSublayer(effectRingLayer)
            effectRingLayers.append(effectRingLayer)
        }

        buildCursorAccessoryLayers()
        hostRootLayer.addSublayer(cursorAccessoryLayer)

        let triangleBounds = CGRect(x: 0, y: 0, width: Self.triangleSize, height: Self.triangleSize)
        cursorGlyphLayer.bounds = triangleBounds
        cursorGlyphLayer.actions = Self.noImplicitAnimations
        idleDimLayer.frame = triangleBounds
        idleDimLayer.actions = Self.noImplicitAnimations
        breathingLayer.frame = triangleBounds
        breathingLayer.actions = Self.noImplicitAnimations
        expressionLayer.frame = triangleBounds
        expressionLayer.actions = Self.noImplicitAnimations
        triangleLayer.frame = triangleBounds
        triangleLayer.path = Self.makeTrianglePath(in: triangleBounds)
        triangleLayer.shadowPath = triangleLayer.path
        triangleLayer.shadowOffset = .zero
        triangleLayer.shadowOpacity = 1
        triangleLayer.shadowRadius = Self.baseShadowRadius
        triangleLayer.actions = Self.noImplicitAnimations

        expressionLayer.addSublayer(triangleLayer)
        breathingLayer.addSublayer(expressionLayer)
        idleDimLayer.addSublayer(breathingLayer)
        cursorGlyphLayer.addSublayer(idleDimLayer)
        hostRootLayer.addSublayer(cursorGlyphLayer)
    }

    /// The halo, thinking indicator and waveform, all centered on the cursor.
    /// Their colors are set along with the tint in `refreshAppearance`.
    private func buildCursorAccessoryLayers() {
        let accessoryBounds = CGRect(x: 0, y: 0, width: Self.accessoryCanvasSize, height: Self.accessoryCanvasSize)
        let accessoryCenter = CGPoint(x: accessoryBounds.midX, y: accessoryBounds.midY)
        cursorAccessoryLayer.bounds = accessoryBounds
        cursorAccessoryLayer.actions = Self.noImplicitAnimations

        haloLayer.type = .radial
        haloLayer.frame = accessoryBounds
        haloLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        haloLayer.endPoint = CGPoint(x: 1, y: 1)
        haloLayer.opacity = 0
        haloLayer.transform = CATransform3DMakeScale(lastAppliedHaloScale, lastAppliedHaloScale, 1)
        haloLayer.actions = Self.noImplicitAnimations
        cursorAccessoryLayer.addSublayer(haloLayer)

        let thinkingBounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        let thinkingCenter = CGPoint(x: thinkingBounds.midX, y: thinkingBounds.midY)
        thinkingIndicatorLayer.bounds = thinkingBounds
        thinkingIndicatorLayer.position = accessoryCenter
        thinkingIndicatorLayer.isHidden = true
        thinkingIndicatorLayer.opacity = 0
        thinkingIndicatorLayer.actions = Self.noImplicitAnimations

        let thinkingArcRadius: CGFloat = 15
        thinkingArcLayer.frame = thinkingBounds
        thinkingArcLayer.path = CGPath(
            ellipseIn: CGRect(
                x: thinkingCenter.x - thinkingArcRadius,
                y: thinkingCenter.y - thinkingArcRadius,
                width: thinkingArcRadius * 2,
                height: thinkingArcRadius * 2
            ),
            transform: nil
        )
        thinkingArcLayer.fillColor = nil
        thinkingArcLayer.lineWidth = 1.5
        thinkingArcLayer.lineCap = .round
        thinkingArcLayer.strokeEnd = 0.22
        thinkingArcLayer.actions = Self.noImplicitAnimations
        thinkingIndicatorLayer.addSublayer(thinkingArcLayer)

        // Six copies of one dot, each a little further back along the orbit
        // and a little fainter: a comet tail with nothing to redraw. The
        // orbit turns counterclockwise, so "back" is clockwise (-0.2 rad).
        thinkingOrbitReplicatorLayer.frame = thinkingBounds
        thinkingOrbitReplicatorLayer.instanceCount = 6
        thinkingOrbitReplicatorLayer.instanceTransform = CATransform3DMakeRotation(-0.2, 0, 0, 1)
        thinkingOrbitReplicatorLayer.instanceAlphaOffset = -0.15
        thinkingOrbitReplicatorLayer.actions = Self.noImplicitAnimations
        let thinkingOrbitRadius: CGFloat = 11
        thinkingOrbitDotLayer.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        thinkingOrbitDotLayer.cornerRadius = 2
        thinkingOrbitDotLayer.position = CGPoint(x: thinkingCenter.x, y: thinkingCenter.y + thinkingOrbitRadius)
        thinkingOrbitDotLayer.actions = Self.noImplicitAnimations
        thinkingOrbitReplicatorLayer.addSublayer(thinkingOrbitDotLayer)
        thinkingIndicatorLayer.addSublayer(thinkingOrbitReplicatorLayer)
        cursorAccessoryLayer.addSublayer(thinkingIndicatorLayer)

        let waveformBounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        waveformLayer.bounds = waveformBounds
        waveformLayer.position = accessoryCenter
        waveformLayer.isHidden = true
        waveformLayer.opacity = 0
        waveformLayer.actions = Self.noImplicitAnimations
        let waveformBarWidth: CGFloat = 2
        let waveformBarSpacing: CGFloat = 2
        let waveformBarCount = Self.waveformBarHeightProfile.count
        for waveformBarIndex in 0..<waveformBarCount {
            let waveformBarLayer = CALayer()
            waveformBarLayer.bounds = CGRect(x: 0, y: 0, width: waveformBarWidth, height: Self.waveformBarMinimumHeight)
            waveformBarLayer.cornerRadius = waveformBarWidth / 2
            let offsetFromMiddleBar = CGFloat(waveformBarIndex - waveformBarCount / 2)
            waveformBarLayer.position = CGPoint(
                x: waveformBounds.midX + offsetFromMiddleBar * (waveformBarWidth + waveformBarSpacing),
                y: waveformBounds.midY
            )
            waveformBarLayer.actions = Self.noImplicitAnimations
            waveformLayer.addSublayer(waveformBarLayer)
            waveformBarLayers.append(waveformBarLayer)
        }
        cursorAccessoryLayer.addSublayer(waveformLayer)
    }

    /// Same geometry as the `Triangle` shape (tip up), in a bottom-left-origin layer.
    private static func makeTrianglePath(in rect: CGRect) -> CGPath {
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.midY + height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY - height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY - height / 3))
        path.closeSubpath()
        return path
    }

    /// Overlay points are top-left-origin (like the mouse math); the layers
    /// are bottom-left-origin.
    private func layerPoint(fromOverlayPoint overlayPoint: CGPoint) -> CGPoint {
        CGPoint(x: overlayPoint.x, y: screenFrame.height - overlayPoint.y)
    }

    /// Rotation degrees are clockwise-positive (as on screen, like SwiftUI's
    /// rotationEffect); Core Animation's z-rotation is counterclockwise-positive
    /// in bottom-left-origin layers.
    private static func layerRotationRadians(fromClockwiseDegrees clockwiseDegrees: Double) -> CGFloat {
        CGFloat(-clockwiseDegrees * .pi / 180)
    }

    private static let noImplicitAnimations: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull(),
        "hidden": NSNull(), "shadowRadius": NSNull(), "backgroundColor": NSNull(),
        "fillColor": NSNull(), "shadowColor": NSNull(), "cornerRadius": NSNull(),
        "strokeColor": NSNull(), "strokeEnd": NSNull(), "lineDashPattern": NSNull(), "path": NSNull(),
        "colors": NSNull(), "instanceColor": NSNull()
    ]

    /// Gentle, endless breathing — a slight swell and a point of drift —
    /// animated by the render server, so an idle cursor costs no CPU here.
    private func installBreathingAnimation(isResting: Bool) {
        breathingLayer.removeAllAnimations()
        triangleLayer.removeAnimation(forKey: "breathingGlow")

        let halfBreathSeconds = isResting ? 3.0 : 1.8
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 1.0
        swell.toValue = 1.04
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = isResting ? -0.5 : -0.8
        drift.toValue = isResting ? 0.5 : 0.8

        let breath = CAAnimationGroup()
        breath.animations = [swell, drift]
        breath.duration = halfBreathSeconds
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        breathingLayer.add(breath, forKey: "breathing")

        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = isResting ? 0.35 : 0.8
        glow.toValue = isResting ? 0.5 : 1.0
        glow.duration = halfBreathSeconds
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.isRemovedOnCompletion = false
        triangleLayer.add(glow, forKey: "breathingGlow")

        // Resting, her tip slowly droops like a sleepy head; on waking it
        // springs back up.
        setExpression(
            scale: expressionScale,
            droopDegrees: isResting ? Self.restingDroopDegrees : 0,
            transition: isResting
                ? .ease(durationSeconds: 0.8, timingFunctionName: .easeInEaseOut)
                : .spring(stiffness: 260, damping: 16)
        )
    }

    // MARK: - Expression, Halo and Rings

    private enum ExpressionTransition {
        case immediate
        case ease(durationSeconds: CFTimeInterval, timingFunctionName: CAMediaTimingFunctionName)
        case spring(stiffness: CGFloat, damping: CGFloat)
    }

    /// Sets her lasting expression — overall size and droop — and animates
    /// there from wherever she is on screen right now. The one writer of
    /// expressionLayer, so listening, thinking, speaking and resting hand
    /// over smoothly instead of stacking animations.
    private func setExpression(scale newScale: CGFloat, droopDegrees newDroopDegrees: Double, transition: ExpressionTransition) {
        guard newScale != expressionScale || newDroopDegrees != expressionDroopDegrees else { return }
        expressionScale = newScale
        expressionDroopDegrees = newDroopDegrees

        let droopRotation = CATransform3DMakeRotation(Self.layerRotationRadians(fromClockwiseDegrees: newDroopDegrees), 0, 0, 1)
        let newTransform = CATransform3DScale(droopRotation, newScale, newScale, 1)
        let transformOnScreenNow = expressionLayer.presentation()?.transform ?? expressionLayer.transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        expressionLayer.transform = newTransform
        if isReduceMotionOn {
            expressionLayer.removeAnimation(forKey: "expression")
        } else {
            switch transition {
            case .immediate:
                expressionLayer.removeAnimation(forKey: "expression")
            case .ease(let durationSeconds, let timingFunctionName):
                let easeAnimation = CABasicAnimation(keyPath: "transform")
                easeAnimation.fromValue = NSValue(caTransform3D: transformOnScreenNow)
                easeAnimation.toValue = NSValue(caTransform3D: newTransform)
                easeAnimation.duration = durationSeconds
                easeAnimation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
                expressionLayer.add(easeAnimation, forKey: "expression")
            case .spring(let stiffness, let damping):
                let springAnimation = CASpringAnimation(keyPath: "transform")
                springAnimation.fromValue = NSValue(caTransform3D: transformOnScreenNow)
                springAnimation.toValue = NSValue(caTransform3D: newTransform)
                springAnimation.mass = 1
                springAnimation.stiffness = stiffness
                springAnimation.damping = damping
                springAnimation.duration = springAnimation.settlingDuration
                expressionLayer.add(springAnimation, forKey: "expression")
            }
        }
        CATransaction.commit()
    }

    /// Sets the halo's size and brightness. Tiny changes are skipped, so a
    /// steady voice costs nothing. With a duration, it eases there (used
    /// for the mic level, which arrives less often than frames).
    private func setHalo(scale newScale: CGFloat, opacity newOpacity: Float, animationDurationSeconds: CFTimeInterval) {
        guard abs(newScale - lastAppliedHaloScale) > 0.01 || abs(newOpacity - lastAppliedHaloOpacity) > 0.01 else { return }
        let scaleOnScreenNow = (haloLayer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue
            ?? Double(lastAppliedHaloScale)
        let opacityOnScreenNow = haloLayer.presentation()?.opacity ?? lastAppliedHaloOpacity
        lastAppliedHaloScale = newScale
        lastAppliedHaloOpacity = newOpacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.transform = CATransform3DMakeScale(newScale, newScale, 1)
        haloLayer.opacity = newOpacity
        if animationDurationSeconds > 0 {
            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = scaleOnScreenNow
            scaleAnimation.toValue = newScale
            scaleAnimation.duration = animationDurationSeconds
            haloLayer.add(scaleAnimation, forKey: "haloScale")
            let opacityAnimation = CABasicAnimation(keyPath: "opacity")
            opacityAnimation.fromValue = opacityOnScreenNow
            opacityAnimation.toValue = newOpacity
            opacityAnimation.duration = animationDurationSeconds
            haloLayer.add(opacityAnimation, forKey: "haloOpacity")
        } else {
            haloLayer.removeAnimation(forKey: "haloScale")
            haloLayer.removeAnimation(forKey: "haloOpacity")
        }
        CATransaction.commit()
    }

    /// A brief flash of the halo on top of whatever it's doing (her hello,
    /// the moment she starts speaking). Additive, so it never fights the
    /// voice-driven brightness.
    private func playHaloFlare(peakOpacity: Float, durationSeconds: CFTimeInterval) {
        let flare = CABasicAnimation(keyPath: "opacity")
        flare.fromValue = peakOpacity
        flare.toValue = 0
        flare.isAdditive = true
        flare.duration = durationSeconds
        flare.timingFunction = CAMediaTimingFunction(name: .easeOut)
        haloLayer.add(flare, forKey: "haloFlare")
    }

    /// Plays one ring from the reusable pool: it scales from `startScale`
    /// to `endScale` while its opacity runs through `opacityKeyframes`
    /// (ending at 0). Nothing needs cleaning up: a ring's resting opacity is 0.
    private func playEffectRing(
        atLayerPoint ringCenter: CGPoint,
        ringColor: NSColor,
        startScale: CGFloat,
        endScale: CGFloat,
        opacityKeyframes: [Float],
        durationSeconds: CFTimeInterval,
        timingFunction: CAMediaTimingFunction,
        startDelaySeconds: CFTimeInterval = 0,
        isDashed: Bool = false
    ) {
        let effectRingLayer = effectRingLayers[nextEffectRingIndex]
        nextEffectRingIndex = (nextEffectRingIndex + 1) % effectRingLayers.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectRingLayer.removeAllAnimations()
        effectRingLayer.position = ringCenter
        effectRingLayer.strokeColor = ringColor.cgColor
        effectRingLayer.lineDashPattern = isDashed ? [3, 3] : nil
        effectRingLayer.transform = CATransform3DMakeScale(endScale, endScale, 1)
        effectRingLayer.opacity = 0

        let growAnimation = CABasicAnimation(keyPath: "transform.scale")
        growAnimation.fromValue = startScale
        growAnimation.toValue = endScale
        let fadeAnimation = CAKeyframeAnimation(keyPath: "opacity")
        fadeAnimation.values = opacityKeyframes
        let ringAnimation = CAAnimationGroup()
        ringAnimation.animations = [growAnimation, fadeAnimation]
        ringAnimation.duration = durationSeconds
        ringAnimation.timingFunction = timingFunction
        if startDelaySeconds > 0 {
            // Before it starts, the ring shows its resting opacity: 0.
            ringAnimation.beginTime = effectRingLayer.convertTime(CACurrentMediaTime(), from: nil) + startDelaySeconds
        }
        effectRingLayer.add(ringAnimation, forKey: "effectRing")
        CATransaction.commit()
    }

    private var currentTintNSColor: NSColor {
        lastAppliedTintColor ?? NSColor(DS.Colors.overlayCursorBlue)
    }

    private var cursorLayerPoint: CGPoint {
        layerPoint(fromOverlayPoint: cursorPosition)
    }

    // MARK: - Reacting to Vesper's State

    private func subscribeToCompanionState() {
        // Published values fire before they're stored; hop one run-loop
        // turn so everything read afterwards is the new state.
        companionManager.$detectedElementScreenLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLocation in self?.handlePointingTargetChange(newLocation) }
            .store(in: &stateSubscriptions)

        companionManager.$inkMarks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncInkMarksWithCompanion() }
            .store(in: &stateSubscriptions)

        companionManager.$sketchStrokes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncSketchStrokes() }
            .store(in: &stateSubscriptions)

        companionManager.$guidedStepWaitingForClick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncGuidedTargetRing() }
            .store(in: &stateSubscriptions)

        // They clicked the step she was waiting on: the ring bursts outward.
        companionManager.$guidedTargetClickCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.playGuidedTargetBurst() }
            .store(in: &stateSubscriptions)

        Publishers.MergeMany(
            companionManager.$voiceState.map { _ in () }.eraseToAnyPublisher(),
            companionManager.$isControllingScreen.map { _ in () }.eraseToAnyPublisher(),
            companionManager.$latestSubscriptionUsage.map { _ in () }.eraseToAnyPublisher(),
            companionManager.$detectedElementDisplayFrame.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.refreshAppearance() }
        .store(in: &stateSubscriptions)

        // Another voice was ignored ("only my voice"): a small "no" shake.
        companionManager.$voiceRejectionCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.playNoShake() }
            .store(in: &stateSubscriptions)

        // Hands-on: a ripple where each click lands. dropFirst: a newly built
        // overlay (transient cursor mode, screen changes) mustn't replay the
        // last click it's handed on subscribing.
        companionManager.$handsOnClickPulse
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clickPulse in self?.playClickRipple(clickPulse) }
            .store(in: &stateSubscriptions)

        // Hands-on task finished (a nod) or cut short (an amber head-shake).
        companionManager.$handsOnTaskOutcomeEvent
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomeEvent in self?.playHandsOnTaskOutcome(outcomeEvent) }
            .store(in: &stateSubscriptions)

        companionManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioPowerLevel in
                guard let self, self.companionManager.voiceState == .listening, self.buddyIsVisibleOnThisScreen else { return }
                self.applyMicrophoneLevel(audioPowerLevel)
            }
            .store(in: &stateSubscriptions)
    }

    /// A quick side-to-side wiggle, like shaking her head. With
    /// `flashTintColor`, the triangle also flashes that color (a hands-on
    /// task that was cut short flashes amber, even though the tint is
    /// already on its way back to blue).
    private func playNoShake(flashTintColor: NSColor? = nil) {
        guard buddyIsVisibleOnThisScreen else { return }
        // Kept even with Reduce Motion: for an ignored voice it's the only
        // sign anything happened.
        // On the unrotated position (not the tilted triangle), so the shake
        // is truly side to side.
        let headShake = CAKeyframeAnimation(keyPath: "position.x")
        headShake.values = [0, -6, 6, -4, 4, -2, 0]
        headShake.duration = 0.45
        headShake.isAdditive = true
        cursorGlyphLayer.add(headShake, forKey: "noShake")
        if let flashTintColor {
            // One run-loop turn later, so this lands after the tint change
            // that ending the task publishes at the same moment; the later
            // animation is the one that shows.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let tintFlash = CAKeyframeAnimation(keyPath: "fillColor")
                tintFlash.values = [flashTintColor.cgColor, flashTintColor.cgColor, self.triangleLayer.fillColor ?? flashTintColor.cgColor]
                tintFlash.keyTimes = [0, 0.4, 1]
                tintFlash.duration = 0.6
                self.triangleLayer.add(tintFlash, forKey: "outcomeTintFlash")
            }
        }
        resumeFrameClockIfPaused()
    }

    /// An amber ring where a hands-on click lands (dashed for a right
    /// click, two for a double click), and a little press of the triangle.
    private func playClickRipple(_ clickPulse: VesperHandsOnClickPulse) {
        let clickPoint = clickPulse.appKitGlobalPoint
        // Only the screen the click is on shows it.
        guard NSMouseInRect(clickPoint, screenFrame, false) else { return }
        // An AppKit global point is bottom-left-origin like the layers, so
        // only the screen's origin comes off (no flip).
        let clickLayerPoint = CGPoint(x: clickPoint.x - screenFrame.origin.x, y: clickPoint.y - screenFrame.origin.y)
        let amberColor = NSColor(DS.Colors.overlayCursorAmber)
        let isRightClick = clickPulse.clickKind == .right

        guard !isReduceMotionOn else {
            // No growing ring: just a ring that fades where the click landed.
            playEffectRing(
                atLayerPoint: clickLayerPoint, ringColor: amberColor, startScale: 1.2, endScale: 1.2,
                opacityKeyframes: [0.9, 0], durationSeconds: 0.45,
                timingFunction: CAMediaTimingFunction(name: .easeOut), isDashed: isRightClick
            )
            return
        }

        let ringCount = clickPulse.clickKind == .double ? 2 : 1
        for ringIndex in 0..<ringCount {
            playEffectRing(
                atLayerPoint: clickLayerPoint, ringColor: amberColor, startScale: 0.3, endScale: 2.2,
                opacityKeyframes: [0.9, 0], durationSeconds: 0.45,
                timingFunction: CAMediaTimingFunction(name: .easeOut),
                startDelaySeconds: Double(ringIndex) * 0.09, isDashed: isRightClick
            )
        }

        if buddyIsVisibleOnThisScreen {
            let press = CAKeyframeAnimation(keyPath: "transform.scale")
            press.values = [1.0, 0.82, 1.0]
            press.keyTimes = [0, 0.35, 1]
            press.duration = 0.22
            press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            triangleLayer.add(press, forKey: "clickPress")
        }
    }

    /// Finished: a small nod and a soft highlight ring. Cut short (refused,
    /// step limit): an amber head-shake.
    private func playHandsOnTaskOutcome(_ outcomeEvent: VesperHandsOnTaskOutcomeEvent) {
        guard buddyIsVisibleOnThisScreen else { return }
        guard outcomeEvent.didSucceed else {
            playNoShake(flashTintColor: NSColor(DS.Colors.overlayCursorAmber))
            return
        }
        guard !isReduceMotionOn else { return }
        // Layers are bottom-left-origin: negative y dips her down.
        let nod = CAKeyframeAnimation(keyPath: "position.y")
        nod.values = [0, -4, 0, -2, 0]
        nod.duration = 0.4
        nod.isAdditive = true
        nod.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cursorGlyphLayer.add(nod, forKey: "outcomeNod")
        playEffectRing(
            atLayerPoint: cursorLayerPoint, ringColor: NSColor(DS.Colors.overlayCursorHighlight),
            startScale: 1, endScale: 2.2, opacityKeyframes: [0.6, 0], durationSeconds: 0.5,
            timingFunction: Self.ringTimingFunction
        )
        resumeFrameClockIfPaused()
    }

    /// Listening: the waveform bars and the halo follow the mic.
    private func applyMicrophoneLevel(_ audioPowerLevel: CGFloat) {
        // Same curve the SwiftUI waveform used: ignores the noise floor and
        // lifts quiet speech.
        let levelAboveNoiseFloor = max(audioPowerLevel - 0.008, 0)
        let easedMicrophoneLevel = pow(min(levelAboveNoiseFloor * 2.85, 1), 0.76)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (waveformBarIndex, waveformBarLayer) in waveformBarLayers.enumerated() {
            let newBarHeight = Self.waveformBarMinimumHeight + easedMicrophoneLevel * 10 * Self.waveformBarHeightProfile[waveformBarIndex]
            let oldBarHeight = waveformBarLayer.bounds.height
            guard abs(newBarHeight - oldBarHeight) > 0.05 else { continue }
            waveformBarLayer.bounds.size.height = newBarHeight
            // Additive "from the old height" smoothing, so it composes with
            // the idle pulse (also additive) instead of replacing it.
            let heightSmoothing = CABasicAnimation(keyPath: "bounds.size.height")
            heightSmoothing.fromValue = oldBarHeight - newBarHeight
            heightSmoothing.toValue = 0
            heightSmoothing.isAdditive = true
            heightSmoothing.duration = 0.08
            waveformBarLayer.add(heightSmoothing, forKey: nil)
        }
        CATransaction.commit()

        setHalo(
            scale: isReduceMotionOn ? 1 : 0.6 + easedMicrophoneLevel * 0.6,
            opacity: Float(easedMicrophoneLevel * 0.4),
            animationDurationSeconds: 0.08
        )
    }

    /// Speaking: the halo swells with her voice, and each loud peak sends an
    /// echo ring outward. Runs per frame, but the frame clock is already
    /// running while she speaks.
    private func applySpeechHalo(frameTimestamp: CFTimeInterval) {
        guard companionManager.voiceState == .responding, buddyIsVisibleOnThisScreen else { return }
        let speechLevel = min(max(companionManager.speechPlaybackEngine.currentOutputAudioLevel, 0), 1)
        let isReduceMotionOn = self.isReduceMotionOn
        setHalo(
            scale: isReduceMotionOn ? 1 : 0.7 + speechLevel * 0.9,
            opacity: Float(speechLevel * 0.6),
            animationDurationSeconds: 0
        )

        let echoPeakLevel: CGFloat = 0.55
        let didJustCrossPeak = speechLevel > echoPeakLevel && previousSpeechLevelForEchoRings <= echoPeakLevel
        previousSpeechLevelForEchoRings = speechLevel
        guard didJustCrossPeak, !isReduceMotionOn, frameTimestamp - lastEchoRingTimestamp >= 0.18 else { return }
        lastEchoRingTimestamp = frameTimestamp
        playEffectRing(
            atLayerPoint: cursorLayerPoint, ringColor: currentTintNSColor,
            startScale: 1, endScale: 2.6, opacityKeyframes: [0.45, 0], durationSeconds: 0.6,
            timingFunction: Self.ringTimingFunction
        )
    }

    /// Blue normally, amber while she's working the controls herself, and
    /// a dim slate while she's resting (subscription limit reached).
    private var cursorTintColor: Color {
        if companionManager.isControllingScreen {
            return DS.Colors.overlayCursorAmber
        }
        if isResting {
            return DS.Colors.overlayCursorResting
        }
        return DS.Colors.overlayCursorBlue
    }

    /// Resting: the Claude plan's limit is reached and she's idle. She
    /// dims and breathes slowly until the reset.
    private var isResting: Bool {
        companionManager.voiceState == .idle && companionManager.isSubscriptionKnownToBeResting
    }

    /// Whether the buddy should be visible on this screen. While another
    /// screen's buddy is flying to or pointing at something, this one hides,
    /// so only one buddy is ever visible.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget, .drawingInk:
            return true
        }
    }

    /// Recomputes which glyph shows and its tint. Runs when
    /// Vesper's state changes — never per frame.
    private func refreshAppearance() {
        // Any state change may start motion (a flight, speech glow).
        resumeFrameClockIfPaused()
        let voiceState = companionManager.voiceState
        let isVisible = buddyIsVisibleOnThisScreen
        // Thinking keeps a small version of her visible, with the orbit
        // around it; listening swaps her for the waveform.
        let isTriangleShowing = isVisible && voiceState != .listening
        let isWaveformShowing = isVisible && voiceState == .listening
        let isThinkingShowing = isVisible && voiceState == .processing

        let tintColor = cursorTintColor
        let tintNSColor = NSColor(tintColor)
        if tintNSColor != lastAppliedTintColor {
            lastAppliedTintColor = tintNSColor
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            let tintAnimation = CABasicAnimation(keyPath: "fillColor")
            tintAnimation.fromValue = triangleLayer.fillColor
            tintAnimation.toValue = tintNSColor.cgColor
            triangleLayer.add(tintAnimation, forKey: "tint")
            triangleLayer.fillColor = tintNSColor.cgColor
            triangleLayer.shadowColor = tintNSColor.cgColor
            for trailDotLayer in trailDotLayers {
                trailDotLayer.backgroundColor = tintNSColor.cgColor
            }
            haloLayer.colors = [
                tintNSColor.withAlphaComponent(0.55).cgColor,
                tintNSColor.withAlphaComponent(0).cgColor
            ]
            thinkingOrbitDotLayer.backgroundColor = tintNSColor.cgColor
            thinkingArcLayer.strokeColor = tintNSColor.withAlphaComponent(0.25).cgColor
            for waveformBarLayer in waveformBarLayers {
                waveformBarLayer.backgroundColor = tintNSColor.cgColor
            }
            applyInkTint(tintNSColor)
            applySketchTint(tintNSColor)
            guidedTargetSteadyRingLayer.strokeColor = tintNSColor.withAlphaComponent(0.85).cgColor
            guidedTargetPulseRingLayer.strokeColor = tintNSColor.withAlphaComponent(0.7).cgColor
            CATransaction.commit()
        }

        let isRestingNow = isResting
        if isRestingNow != lastAppliedIsResting {
            lastAppliedIsResting = isRestingNow
            installBreathingAnimation(isResting: isRestingNow)
        }

        let previousVoiceState = lastAppliedVoiceState
        if voiceState != previousVoiceState {
            lastAppliedVoiceState = voiceState
            playVoiceStateMorph(from: previousVoiceState, to: voiceState, isVisible: isVisible)
        }

        let triangleTargetOpacity: Float = isTriangleShowing && isWelcomeFadeInFinished
            ? (isRestingNow ? 0.55 : 1.0)
            : (isTriangleShowing ? cursorGlyphLayer.opacity : 0)
        if cursorGlyphLayer.opacity != triangleTargetOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = cursorGlyphLayer.presentation()?.opacity ?? cursorGlyphLayer.opacity
            fade.toValue = triangleTargetOpacity
            // Quick and eased-in as she shrinks away for the waveform.
            if voiceState == .listening {
                fade.duration = 0.16
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            } else {
                fade.duration = 0.25
            }
            cursorGlyphLayer.add(fade, forKey: "visibility")
            cursorGlyphLayer.opacity = triangleTargetOpacity
        }

        setWaveformVisible(isWaveformShowing, isHandingOffToThinking: isThinkingShowing)
        setThinkingIndicatorVisible(isThinkingShowing)

        // The halo belongs to her voice (speaking) and the user's (listening);
        // any other time, or on another screen, it goes dark.
        let isHaloInUse = isVisible && (voiceState == .listening || voiceState == .responding)
        if !isHaloInUse {
            previousSpeechLevelForEchoRings = 0
            setHalo(scale: 0.7, opacity: 0, animationDurationSeconds: 0.2)
        }

    }

    /// Size and halo changes as she moves between listening, thinking and
    /// speaking.
    private func playVoiceStateMorph(from previousVoiceState: CompanionVoiceState?, to newVoiceState: CompanionVoiceState, isVisible: Bool) {
        let newExpressionScale: CGFloat
        switch newVoiceState {
        case .listening: newExpressionScale = 0.5
        case .processing: newExpressionScale = 0.6
        case .idle, .responding: newExpressionScale = 1
        }

        let expressionTransition: ExpressionTransition
        if previousVoiceState == nil {
            expressionTransition = .immediate
        } else if newVoiceState == .listening {
            expressionTransition = .ease(durationSeconds: 0.16, timingFunctionName: .easeIn)
        } else if previousVoiceState == .processing && newVoiceState == .responding {
            // She "speaks up": springs from her thinking size, and her halo flares.
            expressionTransition = .spring(stiffness: 320, damping: 14)
            if isVisible {
                playHaloFlare(peakOpacity: 0.7, durationSeconds: 0.35)
            }
        } else {
            expressionTransition = .ease(durationSeconds: 0.25, timingFunctionName: .easeInEaseOut)
        }
        setExpression(scale: newExpressionScale, droopDegrees: expressionDroopDegrees, transition: expressionTransition)
    }

    // MARK: - Ink (her drawings)

    /// Where her pen's tip sits relative to the triangle's center: the
    /// up-left corner of the tilted triangle (the one that points at things).
    private static let penTipOffsetFromGlyphCenter = CGVector(dx: -5.3, dy: -7.6)
    /// Earlier marks fade back while she draws the next one, so the one
    /// she's talking about stands out.
    private static let earlierInkMarkOpacity: Float = 0.42

    private func glyphCenter(forPenPoint penPoint: CGPoint) -> CGPoint {
        CGPoint(x: penPoint.x - Self.penTipOffsetFromGlyphCenter.dx, y: penPoint.y - Self.penTipOffsetFromGlyphCenter.dy)
    }

    /// Brings this screen's marks in line with CompanionManager's: new
    /// ones wait for her pen, removed ones evaporate, numbers appear once
    /// there are two or more.
    private func syncInkMarksWithCompanion() {
        let currentInkMarks = companionManager.inkMarks.filter { inkMark in
            inkMark.displayFrame == screenFrame
                || screenFrame.contains(CGPoint(x: inkMark.displayFrame.midX, y: inkMark.displayFrame.midY))
        }
        let currentInkMarkIDs = Set(currentInkMarks.map(\.id))

        // Gone from the manager: evaporate.
        let removedInkMarkIDs = inkLayersByMarkID.keys.filter { !currentInkMarkIDs.contains($0) }
        if !removedInkMarkIDs.isEmpty {
            for removedInkMarkID in removedInkMarkIDs {
                evaporateInkMark(removedInkMarkID)
            }
            inkMarkIDsWaitingToBeDrawn.removeAll { removedInkMarkIDs.contains($0) }
            if let activeInkStroke, removedInkMarkIDs.contains(activeInkStroke.inkMarkID) {
                self.activeInkStroke = nil
                finishInkSequence()
            }
        }

        for inkMark in currentInkMarks {
            if let existingInkMarkLayers = inkLayersByMarkID[inkMark.id] {
                // A number arriving for a mark that's already drawn (the
                // reply just got its second mark).
                applyInkBadge(inkMark.badgeNumber, to: existingInkMarkLayers, isAppearing: inkMarkIDsAlreadyDrawn.contains(inkMark.id))
                continue
            }
            let newInkMarkLayers = makeInkMarkLayers(for: inkMark)
            inkLayersByMarkID[inkMark.id] = newInkMarkLayers
            applyInkBadge(inkMark.badgeNumber, to: newInkMarkLayers, isAppearing: false)
            inkMarkIDsWaitingToBeDrawn.append(inkMark.id)
        }
        if !inkMarkIDsWaitingToBeDrawn.isEmpty {
            drawNextInkMarkIfIdle()
            // She may have been hidden on this screen until now.
            refreshAppearance()
        }

        // Once she's finished talking, every mark comes back to full
        // strength, so the whole picture is there to look at.
        if companionManager.voiceState == .idle && activeInkStroke == nil && inkMarkIDsWaitingToBeDrawn.isEmpty {
            restoreAllInkMarksToFullStrength()
        }
    }

    private func makeInkMarkLayers(for inkMark: VesperInkMark) -> InkMarkLayers {
        let strokes = VesperInkGeometry.strokes(for: inkMark)
        let tintNSColor = currentTintNSColor

        let containerLayer = CALayer()
        containerLayer.frame = inkContainerLayer.bounds
        containerLayer.actions = Self.noImplicitAnimations

        func makeStrokeLayer(points: [CGPoint], lineWidth: CGFloat, alpha: CGFloat) -> CAShapeLayer {
            let strokeLayer = CAShapeLayer()
            strokeLayer.frame = containerLayer.bounds
            strokeLayer.path = makeLayerPath(throughOverlayPoints: points)
            strokeLayer.fillColor = nil
            strokeLayer.strokeColor = tintNSColor.withAlphaComponent(alpha).cgColor
            strokeLayer.lineWidth = lineWidth
            strokeLayer.lineCap = .round
            strokeLayer.lineJoin = .round
            // Not drawn yet: her pen reveals it.
            strokeLayer.strokeEnd = 0
            strokeLayer.actions = Self.noImplicitAnimations
            return strokeLayer
        }

        let glowStrokeLayer = makeStrokeLayer(points: strokes.mainStroke, lineWidth: 10, alpha: 0.2)
        let crispStrokeLayer = makeStrokeLayer(points: strokes.mainStroke, lineWidth: 2.8, alpha: 0.95)
        containerLayer.addSublayer(glowStrokeLayer)
        containerLayer.addSublayer(crispStrokeLayer)

        var finishingGlowStrokeLayer: CAShapeLayer?
        var finishingCrispStrokeLayer: CAShapeLayer?
        if let finishingStroke = strokes.finishingStroke {
            let newFinishingGlowStrokeLayer = makeStrokeLayer(points: finishingStroke, lineWidth: 10, alpha: 0.2)
            let newFinishingCrispStrokeLayer = makeStrokeLayer(points: finishingStroke, lineWidth: 2.8, alpha: 0.95)
            containerLayer.addSublayer(newFinishingGlowStrokeLayer)
            containerLayer.addSublayer(newFinishingCrispStrokeLayer)
            finishingGlowStrokeLayer = newFinishingGlowStrokeLayer
            finishingCrispStrokeLayer = newFinishingCrispStrokeLayer
        }

        // The step number: a small disc in her color with the digit in white.
        let badgeDiameter: CGFloat = 17
        let badgeLayer = CALayer()
        badgeLayer.bounds = CGRect(x: 0, y: 0, width: badgeDiameter, height: badgeDiameter)
        badgeLayer.position = layerPoint(fromOverlayPoint: strokes.badgeCenter)
        badgeLayer.cornerRadius = badgeDiameter / 2
        badgeLayer.backgroundColor = tintNSColor.cgColor
        badgeLayer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        badgeLayer.borderWidth = 1
        badgeLayer.shadowColor = NSColor.black.cgColor
        badgeLayer.shadowOpacity = 0.35
        badgeLayer.shadowRadius = 3
        badgeLayer.shadowOffset = CGSize(width: 0, height: -1)
        badgeLayer.shadowPath = CGPath(ellipseIn: badgeLayer.bounds, transform: nil)
        badgeLayer.opacity = 0
        badgeLayer.actions = Self.noImplicitAnimations
        let badgeTextLayer = CATextLayer()
        badgeTextLayer.frame = CGRect(x: 0, y: 2, width: badgeDiameter, height: badgeDiameter - 3)
        badgeTextLayer.alignmentMode = .center
        badgeTextLayer.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        badgeTextLayer.fontSize = 10.5
        badgeTextLayer.foregroundColor = NSColor.white.cgColor
        badgeTextLayer.contentsScale = NSScreen.screens.first(where: { $0.frame == screenFrame })?.backingScaleFactor ?? 2
        badgeTextLayer.actions = Self.noImplicitAnimations
        badgeLayer.addSublayer(badgeTextLayer)
        containerLayer.addSublayer(badgeLayer)

        inkContainerLayer.addSublayer(containerLayer)
        return InkMarkLayers(
            containerLayer: containerLayer,
            glowStrokeLayer: glowStrokeLayer,
            crispStrokeLayer: crispStrokeLayer,
            finishingGlowStrokeLayer: finishingGlowStrokeLayer,
            finishingCrispStrokeLayer: finishingCrispStrokeLayer,
            badgeLayer: badgeLayer,
            badgeTextLayer: badgeTextLayer,
            strokes: strokes,
            cumulativeStrokeLengths: VesperInkGeometry.cumulativeLengths(of: strokes.mainStroke)
        )
    }

    /// A path through overlay (top-left-origin) points, in the layers'
    /// bottom-left-origin space.
    private func makeLayerPath(throughOverlayPoints overlayPoints: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let firstPoint = overlayPoints.first else { return path }
        path.move(to: layerPoint(fromOverlayPoint: firstPoint))
        for overlayPoint in overlayPoints.dropFirst() {
            path.addLine(to: layerPoint(fromOverlayPoint: overlayPoint))
        }
        return path
    }

    /// Shows, updates or hides a mark's number. It pops in when the mark
    /// is (or already was) drawn; before that it waits for her pen.
    private func applyInkBadge(_ badgeNumber: Int?, to inkMarkLayers: InkMarkLayers, isAppearing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let badgeNumber {
            inkMarkLayers.badgeTextLayer.string = "\(badgeNumber)"
        }
        CATransaction.commit()
        guard badgeNumber != nil, isAppearing, inkMarkLayers.badgeLayer.opacity == 0 else { return }
        popInInkBadge(inkMarkLayers.badgeLayer)
    }

    private func popInInkBadge(_ badgeLayer: CALayer) {
        fadeLayer(badgeLayer, toOpacity: 1, durationSeconds: 0.18)
        guard !isReduceMotionOn else { return }
        let popIn = CASpringAnimation(keyPath: "transform.scale")
        popIn.fromValue = 0.3
        popIn.toValue = 1
        popIn.mass = 1
        popIn.stiffness = 380
        popIn.damping = 16
        popIn.duration = popIn.settlingDuration
        badgeLayer.add(popIn, forKey: "badgePop")
    }

    /// Her pen takes the next waiting mark: a quick hop to where it starts,
    /// then the stroke. With nothing waiting, she settles where she is (or
    /// goes where she was asked to meanwhile).
    private func drawNextInkMarkIfIdle() {
        guard activeInkStroke == nil, !isFlyingToPenStart else { return }
        guard let nextInkMarkID = inkMarkIDsWaitingToBeDrawn.first,
              let nextInkMarkLayers = inkLayersByMarkID[nextInkMarkID],
              let penStartPoint = nextInkMarkLayers.strokes.mainStroke.first else {
            finishInkSequence()
            return
        }
        guard !isShowingWelcome else { return }

        let glyphCenterForPenStart = glyphCenter(forPenPoint: penStartPoint)
        let distanceToPenStart = hypot(glyphCenterForPenStart.x - cursorPosition.x, glyphCenterForPenStart.y - cursorPosition.y)
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        if distanceToPenStart < 3 {
            startInkStroke(nextInkMarkID)
            return
        }
        // Between marks the pen hops briskly; from far away it flies.
        isFlyingToPenStart = true
        startFlight(to: glyphCenterForPenStart, isQuickHop: true) { [weak self] in
            guard let self else { return }
            self.isFlyingToPenStart = false
            self.startInkStroke(nextInkMarkID)
        }
        refreshAppearance()
    }

    private func startInkStroke(_ inkMarkID: Int) {
        guard let inkMarkLayers = inkLayersByMarkID[inkMarkID] else {
            inkMarkIDsWaitingToBeDrawn.removeAll { $0 == inkMarkID }
            drawNextInkMarkIfIdle()
            return
        }
        inkMarkIDsWaitingToBeDrawn.removeAll { $0 == inkMarkID }
        // The marks before this one step back.
        for (drawnInkMarkID, drawnInkMarkLayers) in inkLayersByMarkID where drawnInkMarkID != inkMarkID && inkMarkIDsAlreadyDrawn.contains(drawnInkMarkID) {
            if drawnInkMarkLayers.containerLayer.opacity > Self.earlierInkMarkOpacity {
                fadeLayer(drawnInkMarkLayers.containerLayer, toOpacity: Self.earlierInkMarkOpacity, durationSeconds: 0.3)
            }
        }
        // Reduce Motion: she still goes there, but the mark simply fades in
        // instead of being traced.
        if isReduceMotionOn {
            revealInkMarkWithoutTracing(inkMarkID)
            drawNextInkMarkIfIdle()
            return
        }
        buddyNavigationMode = .drawingInk
        landingSettle = nil
        // A pen is held at one angle while it draws.
        if triangleRotationDegrees != -35 {
            settleRotationBackToPointerAngle()
        }
        buddyFlightScale = 1
        let totalStrokeLength = inkMarkLayers.cumulativeStrokeLengths.last ?? 0
        activeInkStroke = CursorInkStroke(
            inkMarkID: inkMarkID,
            durationSeconds: VesperInkGeometry.drawingDurationSeconds(forStrokeLength: totalStrokeLength)
        )
        if companionManager.inkMarks.first(where: { $0.id == inkMarkID })?.badgeNumber != nil {
            popInInkBadge(inkMarkLayers.badgeLayer)
        }
        resumeFrameClockIfPaused()
    }

    /// One frame of the pen: moves the cursor along the stroke and reveals
    /// the ink up to it. Returns false once there's no stroke in progress.
    private func advanceInkStroke(elapsedSeconds: CFTimeInterval) -> Bool {
        guard var inkStroke = activeInkStroke else { return false }
        guard let inkMarkLayers = inkLayersByMarkID[inkStroke.inkMarkID] else {
            activeInkStroke = nil
            return false
        }
        inkStroke.elapsedSeconds += elapsedSeconds
        let linearProgress = min(inkStroke.elapsedSeconds / inkStroke.durationSeconds, 1)
        let drawnShare = VesperInkGeometry.easedDrawingProgress(forLinearProgress: linearProgress)
        let totalStrokeLength = inkMarkLayers.cumulativeStrokeLengths.last ?? 0
        let penPoint = VesperInkGeometry.point(
            atDistance: CGFloat(drawnShare) * totalStrokeLength,
            along: inkMarkLayers.strokes.mainStroke,
            cumulativeLengths: inkMarkLayers.cumulativeStrokeLengths
        )
        cursorPosition = glyphCenter(forPenPoint: penPoint)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkMarkLayers.glowStrokeLayer.strokeEnd = CGFloat(drawnShare)
        inkMarkLayers.crispStrokeLayer.strokeEnd = CGFloat(drawnShare)
        CATransaction.commit()

        if linearProgress >= 1 {
            activeInkStroke = nil
            inkMarkIDsAlreadyDrawn.insert(inkStroke.inkMarkID)
            // An arrow's head: a quick flick once the shaft arrives.
            for finishingStrokeLayer in [inkMarkLayers.finishingGlowStrokeLayer, inkMarkLayers.finishingCrispStrokeLayer].compactMap({ $0 }) {
                revealStroke(finishingStrokeLayer, durationSeconds: 0.14)
            }
            drawNextInkMarkIfIdle()
        } else {
            activeInkStroke = inkStroke
        }
        return true
    }

    /// Reveals a whole stroke with a quick draw-on (or at once with Reduce Motion).
    private func revealStroke(_ strokeLayer: CAShapeLayer, durationSeconds: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.strokeEnd = 1
        if !isReduceMotionOn {
            let drawOn = CABasicAnimation(keyPath: "strokeEnd")
            drawOn.fromValue = 0
            drawOn.toValue = 1
            drawOn.duration = durationSeconds
            drawOn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strokeLayer.add(drawOn, forKey: "drawOn")
        }
        CATransaction.commit()
    }

    /// Reduce Motion: the mark fades in whole, with no pen tracing it.
    private func revealInkMarkWithoutTracing(_ inkMarkID: Int) {
        guard let inkMarkLayers = inkLayersByMarkID[inkMarkID] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for strokeLayer in [inkMarkLayers.glowStrokeLayer, inkMarkLayers.crispStrokeLayer, inkMarkLayers.finishingGlowStrokeLayer, inkMarkLayers.finishingCrispStrokeLayer].compactMap({ $0 }) {
            strokeLayer.strokeEnd = 1
        }
        CATransaction.commit()
        inkMarkLayers.containerLayer.opacity = 0
        fadeLayer(inkMarkLayers.containerLayer, toOpacity: 1, durationSeconds: 0.25)
        inkMarkIDsAlreadyDrawn.insert(inkMarkID)
        if companionManager.inkMarks.first(where: { $0.id == inkMarkID })?.badgeNumber != nil {
            fadeLayer(inkMarkLayers.badgeLayer, toOpacity: 1, durationSeconds: 0.25)
        }
    }

    /// Nothing left to draw: go where she was asked to meanwhile, or come
    /// home, or rest at the end of the last stroke, pointing at it.
    private func finishInkSequence() {
        guard activeInkStroke == nil, inkMarkIDsWaitingToBeDrawn.isEmpty else { return }
        if let pointingLocationWaitingForInk {
            self.pointingLocationWaitingForInk = nil
            if let waitingPointingLocation = pointingLocationWaitingForInk {
                startNavigatingToElement(screenLocation: waitingPointingLocation)
            } else if isCursorOnThisScreen {
                startFlyingBackToCursor()
            } else {
                cancelNavigationAndResumeFollowing()
            }
            return
        }
        if buddyNavigationMode == .drawingInk || buddyNavigationMode == .navigatingToTarget {
            buddyNavigationMode = .pointingAtTarget
            refreshAppearance()
            // A hands-on click waiting on her arrival can go now.
            companionManager.noteCursorArrivedAtPointingTarget()
        }
        if companionManager.voiceState == .idle {
            restoreAllInkMarksToFullStrength()
        }
    }

    private func restoreAllInkMarksToFullStrength() {
        for inkMarkLayers in inkLayersByMarkID.values where inkMarkLayers.containerLayer.opacity < 1 && inkMarkLayers.containerLayer.opacity > 0 {
            fadeLayer(inkMarkLayers.containerLayer, toOpacity: 1, durationSeconds: 0.35)
        }
    }

    /// A mark she's done with: it unwinds from where it started as it fades.
    private func evaporateInkMark(_ inkMarkID: Int) {
        guard let inkMarkLayers = inkLayersByMarkID.removeValue(forKey: inkMarkID) else { return }
        inkMarkIDsAlreadyDrawn.remove(inkMarkID)
        let evaporationSeconds: CFTimeInterval = 0.45
        fadeLayer(inkMarkLayers.containerLayer, toOpacity: 0, durationSeconds: evaporationSeconds)
        if !isReduceMotionOn {
            for strokeLayer in [inkMarkLayers.glowStrokeLayer, inkMarkLayers.crispStrokeLayer] {
                let unwind = CABasicAnimation(keyPath: "strokeStart")
                unwind.fromValue = 0
                unwind.toValue = 0.35
                unwind.duration = evaporationSeconds
                unwind.timingFunction = CAMediaTimingFunction(name: .easeIn)
                unwind.fillMode = .forwards
                unwind.isRemovedOnCompletion = false
                strokeLayer.add(unwind, forKey: "evaporate")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + evaporationSeconds + 0.05) {
            inkMarkLayers.containerLayer.removeFromSuperlayer()
        }
    }

    /// Her drawings follow her tint (blue, amber while she's in control).
    private func applyInkTint(_ tintNSColor: NSColor) {
        for inkMarkLayers in inkLayersByMarkID.values {
            inkMarkLayers.glowStrokeLayer.strokeColor = tintNSColor.withAlphaComponent(0.2).cgColor
            inkMarkLayers.crispStrokeLayer.strokeColor = tintNSColor.withAlphaComponent(0.95).cgColor
            inkMarkLayers.finishingGlowStrokeLayer?.strokeColor = tintNSColor.withAlphaComponent(0.2).cgColor
            inkMarkLayers.finishingCrispStrokeLayer?.strokeColor = tintNSColor.withAlphaComponent(0.95).cgColor
            inkMarkLayers.badgeLayer.backgroundColor = tintNSColor.cgColor
        }
    }

    // MARK: - Guided Steps (waiting for their click)

    /// Shows the ring around the step she's waiting on (if it's on this
    /// screen), hugging the element once its edges are known.
    private func syncGuidedTargetRing() {
        let waitingStep = companionManager.guidedStepWaitingForClick
        let isOnThisScreen = waitingStep.map { step in
            step.displayFrame == screenFrame || screenFrame.contains(CGPoint(x: step.displayFrame.midX, y: step.displayFrame.midY))
        } ?? false
        guard let waitingStep, isOnThisScreen else {
            if shownGuidedStep != nil {
                shownGuidedStep = nil
                hideGuidedTargetRing()
            }
            return
        }
        guard waitingStep != shownGuidedStep else { return }
        let isNewStep = shownGuidedStep?.stepNumber != waitingStep.stepNumber || shownGuidedStep?.appKitGlobalPoint != waitingStep.appKitGlobalPoint
        shownGuidedStep = waitingStep

        // Around the element when Accessibility knows its edges; otherwise
        // a circle around where she pointed.
        let ringRect: CGRect
        let ringPath: CGPath
        if let targetGlobalFrame = waitingStep.targetGlobalFrame {
            ringRect = overlayRect(fromGlobalRect: targetGlobalFrame).insetBy(dx: -5, dy: -5)
            let cornerRadius = min(min(ringRect.width, ringRect.height) / 2, 8)
            ringPath = CGPath(roundedRect: CGRect(origin: .zero, size: ringRect.size), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        } else {
            let pointInOverlay = convertScreenPointToOverlayCoordinates(waitingStep.appKitGlobalPoint)
            ringRect = CGRect(x: pointInOverlay.x - 18, y: pointInOverlay.y - 18, width: 36, height: 36)
            ringPath = CGPath(ellipseIn: CGRect(origin: .zero, size: ringRect.size), transform: nil)
        }
        let ringCenterInLayers = layerPoint(fromOverlayPoint: CGPoint(x: ringRect.midX, y: ringRect.midY))
        lastGuidedRingCenterInLayers = ringCenterInLayers

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for guidedTargetRingLayer in [guidedTargetSteadyRingLayer, guidedTargetPulseRingLayer] {
            guidedTargetRingLayer.bounds = CGRect(origin: .zero, size: ringRect.size)
            guidedTargetRingLayer.position = ringCenterInLayers
            guidedTargetRingLayer.path = ringPath
            guidedTargetRingLayer.isHidden = false
        }
        CATransaction.commit()

        if isNewStep {
            guidedTargetSteadyRingLayer.opacity = 0
            fadeLayer(guidedTargetSteadyRingLayer, toOpacity: 1, durationSeconds: 0.25)
        }
        guidedTargetPulseRingLayer.removeAnimation(forKey: "breatheOut")
        guard !isReduceMotionOn else { return }
        // Render-server animation: a ring breathing outward and fading, every 1.4 s.
        let growOutward = CABasicAnimation(keyPath: "transform.scale")
        growOutward.fromValue = 1
        growOutward.toValue = 1.35
        let fadeAway = CABasicAnimation(keyPath: "opacity")
        fadeAway.fromValue = 0.7
        fadeAway.toValue = 0
        let breatheOut = CAAnimationGroup()
        breatheOut.animations = [growOutward, fadeAway]
        breatheOut.duration = 1.4
        breatheOut.repeatCount = .infinity
        breatheOut.timingFunction = Self.ringTimingFunction
        guidedTargetPulseRingLayer.add(breatheOut, forKey: "breatheOut")
    }

    private func hideGuidedTargetRing() {
        guidedTargetPulseRingLayer.removeAnimation(forKey: "breatheOut")
        guidedTargetPulseRingLayer.opacity = 0
        fadeLayer(guidedTargetSteadyRingLayer, toOpacity: 0, durationSeconds: 0.2)
    }

    /// Their click landed: a bright ring bursts out from the step.
    private func playGuidedTargetBurst() {
        // Only the screen the step was on.
        guard let burstCenter = lastGuidedRingCenterInLayers else { return }
        lastGuidedRingCenterInLayers = nil
        playEffectRing(
            atLayerPoint: burstCenter, ringColor: NSColor(DS.Colors.overlayCursorHighlight),
            startScale: 1.2, endScale: 3.2, opacityKeyframes: [0.9, 0], durationSeconds: 0.5,
            timingFunction: Self.ringTimingFunction
        )
    }

    // MARK: - Sketching (what the user draws while asking)

    /// The mouse, while they hold the hotkey (the overlay only takes it
    /// then). Overlay coordinates are top-left-origin; strokes are global.
    func handleSketchMouseDown(atOverlayPoint overlayPoint: CGPoint) {
        companionManager.beginSketchStroke(atGlobalPoint: globalPoint(fromOverlayPoint: overlayPoint), displayFrame: screenFrame)
    }

    func handleSketchMouseDragged(toOverlayPoint overlayPoint: CGPoint) {
        companionManager.extendSketchStroke(toGlobalPoint: globalPoint(fromOverlayPoint: overlayPoint))
    }

    func handleSketchMouseUp(atOverlayPoint overlayPoint: CGPoint) {
        companionManager.extendSketchStroke(toGlobalPoint: globalPoint(fromOverlayPoint: overlayPoint))
        companionManager.endSketchStroke()
    }

    private func globalPoint(fromOverlayPoint overlayPoint: CGPoint) -> CGPoint {
        CGPoint(x: overlayPoint.x + screenFrame.minX, y: screenFrame.maxY - overlayPoint.y)
    }

    /// Draws this screen's strokes exactly where the pointer went — the
    /// path is rebuilt on each mouse event, so it never trails behind —
    /// and lets removed ones evaporate.
    private func syncSketchStrokes() {
        let currentStrokes = companionManager.sketchStrokes.filter { $0.displayFrame == screenFrame }
        let currentStrokeIDs = Set(currentStrokes.map(\.id))

        for (removedStrokeID, removedStrokeLayers) in sketchLayersByStrokeID where !currentStrokeIDs.contains(removedStrokeID) {
            sketchLayersByStrokeID[removedStrokeID] = nil
            fadeLayer(removedStrokeLayers.containerLayer, toOpacity: 0, durationSeconds: 0.35)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                removedStrokeLayers.containerLayer.removeFromSuperlayer()
            }
        }

        for stroke in currentStrokes {
            let strokeLayers = sketchLayersByStrokeID[stroke.id] ?? makeSketchStrokeLayers(strokeID: stroke.id)
            let layerPath: CGPath
            if stroke.isTap, let tapPoint = stroke.globalPoints.first {
                let tapCenter = layerPoint(fromGlobalPoint: tapPoint)
                let ringRadius = VesperSketchGeometry.tapRingRadius
                layerPath = CGPath(ellipseIn: CGRect(x: tapCenter.x - ringRadius, y: tapCenter.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2), transform: nil)
            } else {
                layerPath = VesperSketchGeometry.smoothPath(through: stroke.globalPoints.map(layerPoint(fromGlobalPoint:)))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for strokeLayer in [strokeLayers.glowLayer, strokeLayers.edgeLayer, strokeLayers.coreLayer] {
                strokeLayer.path = layerPath
            }
            CATransaction.commit()
        }
        if !currentStrokes.isEmpty {
            resumeFrameClockIfPaused()
        }
    }

    /// A global AppKit rect in this overlay's top-left-origin coordinates.
    private func overlayRect(fromGlobalRect globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    /// A global AppKit point in this overlay's layer space (bottom-left
    /// origin, this screen's origin removed).
    private func layerPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - screenFrame.minX, y: globalPoint.y - screenFrame.minY)
    }

    private func makeSketchStrokeLayers(strokeID: Int) -> SketchStrokeLayers {
        let containerLayer = CALayer()
        containerLayer.frame = sketchContainerLayer.bounds
        containerLayer.actions = Self.noImplicitAnimations
        func makeLayer(color: NSColor, lineWidth: CGFloat) -> CAShapeLayer {
            let strokeLayer = CAShapeLayer()
            strokeLayer.frame = containerLayer.bounds
            strokeLayer.fillColor = nil
            strokeLayer.strokeColor = color.cgColor
            strokeLayer.lineWidth = lineWidth
            strokeLayer.lineCap = .round
            strokeLayer.lineJoin = .round
            strokeLayer.actions = Self.noImplicitAnimations
            containerLayer.addSublayer(strokeLayer)
            return strokeLayer
        }
        let sketchStrokeLayers = SketchStrokeLayers(
            containerLayer: containerLayer,
            glowLayer: makeLayer(color: currentTintNSColor.withAlphaComponent(0.3), lineWidth: 12),
            edgeLayer: makeLayer(color: NSColor.black.withAlphaComponent(0.32), lineWidth: 5.5),
            coreLayer: makeLayer(color: .white, lineWidth: 3)
        )
        sketchContainerLayer.addSublayer(containerLayer)
        sketchLayersByStrokeID[strokeID] = sketchStrokeLayers
        return sketchStrokeLayers
    }

    private func applySketchTint(_ tintNSColor: NSColor) {
        for sketchStrokeLayers in sketchLayersByStrokeID.values {
            sketchStrokeLayers.glowLayer.strokeColor = tintNSColor.withAlphaComponent(0.3).cgColor
        }
    }

    // MARK: - Thinking Indicator and Waveform

    /// Shows or hides the thinking orbit. Its animations only exist while
    /// it's showing, so a hidden indicator costs nothing.
    private func setThinkingIndicatorVisible(_ isVisible: Bool) {
        guard isVisible != isThinkingIndicatorMeantToShow else { return }
        isThinkingIndicatorMeantToShow = isVisible
        thinkingIndicatorVisibilityGeneration += 1
        let generationAtChange = thinkingIndicatorVisibilityGeneration

        if isVisible {
            resetThinkingOrbitSpeed()
            thinkingIndicatorLayer.isHidden = false
            let orbitSpin = CABasicAnimation(keyPath: "transform.rotation.z")
            orbitSpin.fromValue = 0
            orbitSpin.toValue = 2 * Double.pi
            orbitSpin.duration = Self.thinkingOrbitPeriodSeconds
            orbitSpin.repeatCount = .infinity
            thinkingOrbitReplicatorLayer.add(orbitSpin, forKey: "orbit")
            // The faint arc turns the other way, more slowly.
            let arcSpin = CABasicAnimation(keyPath: "transform.rotation.z")
            arcSpin.fromValue = 0
            arcSpin.toValue = -2 * Double.pi
            arcSpin.duration = 2.4
            arcSpin.repeatCount = .infinity
            thinkingArcLayer.add(arcSpin, forKey: "arcSpin")
            fadeLayer(thinkingIndicatorLayer, toOpacity: 1, durationSeconds: 0.15)

            // A long think: the orbit quickens, so it doesn't look stuck.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsBeforeThinkingOrbitQuickens) { [weak self] in
                guard let self, self.thinkingIndicatorVisibilityGeneration == generationAtChange else { return }
                self.quickenThinkingOrbit()
            }
        } else {
            fadeLayer(thinkingIndicatorLayer, toOpacity: 0, durationSeconds: 0.14)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, self.thinkingIndicatorVisibilityGeneration == generationAtChange else { return }
                self.thinkingIndicatorLayer.isHidden = true
                self.thinkingOrbitReplicatorLayer.removeAnimation(forKey: "orbit")
                self.thinkingArcLayer.removeAnimation(forKey: "arcSpin")
                self.resetThinkingOrbitSpeed()
            }
        }
    }

    /// Speeds up the orbit without a jump: the replicator's clock is
    /// re-based at the current moment, then runs faster from there.
    private func quickenThinkingOrbit() {
        let nowInParentTime = thinkingIndicatorLayer.convertTime(CACurrentMediaTime(), from: nil)
        let orbitTimeNow = thinkingOrbitReplicatorLayer.convertTime(CACurrentMediaTime(), from: nil)
        thinkingOrbitReplicatorLayer.timeOffset = orbitTimeNow
        thinkingOrbitReplicatorLayer.beginTime = nowInParentTime
        thinkingOrbitReplicatorLayer.speed = Float(Self.thinkingOrbitPeriodSeconds / Self.thinkingOrbitQuickPeriodSeconds)
    }

    private func resetThinkingOrbitSpeed() {
        thinkingOrbitReplicatorLayer.speed = 1
        thinkingOrbitReplicatorLayer.timeOffset = 0
        thinkingOrbitReplicatorLayer.beginTime = 0
    }

    /// Shows or hides the listening waveform: it springs in, and when she
    /// starts thinking it shrinks away as the orbit appears.
    private func setWaveformVisible(_ isVisible: Bool, isHandingOffToThinking: Bool) {
        guard isVisible != isWaveformMeantToShow else { return }
        isWaveformMeantToShow = isVisible
        waveformVisibilityGeneration += 1
        let generationAtChange = waveformVisibilityGeneration

        if isVisible {
            waveformLayer.isHidden = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            waveformLayer.transform = CATransform3DIdentity
            for (waveformBarIndex, waveformBarLayer) in waveformBarLayers.enumerated() {
                waveformBarLayer.bounds.size.height = Self.waveformBarMinimumHeight
                // A gentle breathing of the bars even in silence, each a
                // little behind the last, so she visibly is listening.
                let idlePulse = CABasicAnimation(keyPath: "bounds.size.height")
                idlePulse.fromValue = 0
                idlePulse.toValue = 1.5
                idlePulse.isAdditive = true
                idlePulse.duration = 0.87
                idlePulse.autoreverses = true
                idlePulse.repeatCount = .infinity
                idlePulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                idlePulse.timeOffset = Double(waveformBarIndex) * 0.1
                waveformBarLayer.add(idlePulse, forKey: "idlePulse")
            }
            CATransaction.commit()
            fadeLayer(waveformLayer, toOpacity: 1, durationSeconds: 0.12)
            if !isReduceMotionOn {
                // SwiftUI's spring(response: 0.32, dampingFraction: 0.7), in
                // Core Animation terms.
                let springIn = CASpringAnimation(keyPath: "transform.scale")
                springIn.fromValue = 0.6
                springIn.toValue = 1
                springIn.mass = 1
                springIn.stiffness = 385
                springIn.damping = 27.5
                springIn.duration = springIn.settlingDuration
                waveformLayer.add(springIn, forKey: "springIn")
            }
        } else {
            let fadeOutSeconds: CFTimeInterval = isHandingOffToThinking ? 0.14 : 0.12
            fadeLayer(waveformLayer, toOpacity: 0, durationSeconds: fadeOutSeconds)
            if isHandingOffToThinking && !isReduceMotionOn {
                let shrinkAway = CABasicAnimation(keyPath: "transform.scale")
                shrinkAway.fromValue = 1
                shrinkAway.toValue = 0.4
                shrinkAway.duration = fadeOutSeconds
                shrinkAway.timingFunction = CAMediaTimingFunction(name: .easeIn)
                shrinkAway.fillMode = .forwards
                shrinkAway.isRemovedOnCompletion = false
                waveformLayer.add(shrinkAway, forKey: "springIn")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutSeconds + 0.02) { [weak self] in
                guard let self, self.waveformVisibilityGeneration == generationAtChange else { return }
                self.waveformLayer.isHidden = true
                self.waveformLayer.removeAllAnimations()
                for waveformBarLayer in self.waveformBarLayers {
                    waveformBarLayer.removeAllAnimations()
                }
            }
        }
    }

    /// Fades a layer from wherever it is on screen to `targetOpacity`.
    private func fadeLayer(_ layer: CALayer, toOpacity targetOpacity: Float, durationSeconds: CFTimeInterval) {
        let opacityOnScreenNow = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = targetOpacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacityOnScreenNow
        fade.toValue = targetOpacity
        fade.duration = durationSeconds
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: - Frame Loop

    /// Runs once per display refresh. Only moves layers and small views,
    /// and does nothing at all when nothing moved.
    private func advanceMotion(elapsedSeconds: CFTimeInterval, frameTimestamp: CFTimeInterval) {
        let mouseLocation = NSEvent.mouseLocation
        // NSMouseInRect: CGRect.contains excludes the top edge, which made
        // the cursor flicker when the mouse was pinned against it.
        let isMouseOnThisScreen = NSMouseInRect(mouseLocation, screenFrame, false)
        let didMouseArriveOnThisScreen = isMouseOnThisScreen && !isCursorOnThisScreen
        if isMouseOnThisScreen != isCursorOnThisScreen {
            isCursorOnThisScreen = isMouseOnThisScreen
            refreshAppearance()
        }

        let positionBeforeThisFrame = cursorPosition

        if activeInkStroke != nil {
            _ = advanceInkStroke(elapsedSeconds: elapsedSeconds)
        } else if var flight = activeFlight {
            // Only during the RETURN flight may the user's mouse cancel it —
            // the forward flight and pointing always finish.
            if isReturningToCursor {
                let currentMouseInOverlay = convertScreenPointToOverlayCoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInOverlay.x - cursorPositionWhenNavigationStarted.x,
                    currentMouseInOverlay.y - cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                    return
                }
            }

            flight.elapsedSeconds += elapsedSeconds
            let linearProgress = min(flight.elapsedSeconds / flight.durationSeconds, 1.0)
            let pathProgress = CursorFlight.easedPathProgress(forLinearProgress: linearProgress)
            cursorPosition = flight.position(atPathProgress: pathProgress)

            // Face the direction of travel. +90° because the triangle's tip
            // points up at 0° and atan2 returns 0° for rightward movement.
            let travelDirection = flight.tangent(atPathProgress: pathProgress)
            triangleRotationDegrees = atan2(travelDirection.dy, travelDirection.dx) * (180.0 / .pi) + 90.0
            // Grows to ~1.3x at the apex and back to 1.0x on landing.
            buddyFlightScale = 1.0 + sin(linearProgress * .pi) * 0.3

            trailPoints.append(CursorTrailPoint(position: cursorPosition, recordedAt: frameTimestamp))

            if linearProgress >= 1.0 {
                activeFlight = nil
                buddyFlightScale = 1.0
                // A hop to where a drawing starts flows straight into the
                // stroke; a flight to a target settles with a little overshoot.
                if !flight.isQuickHop {
                    landingSettle = CursorLandingSettle(
                        landingPosition: flight.endPosition,
                        travelDirection: travelDirection,
                        arrivalSpeedPointsPerSecond: flight.arrivalSpeedPointsPerSecond
                    )
                }
                flight.onComplete()
            } else {
                activeFlight = flight
            }
        } else if var settle = landingSettle {
            settle.elapsedSeconds += elapsedSeconds
            cursorPosition = settle.currentPosition
            landingSettle = settle.isFinished ? nil : settle
        } else if buddyNavigationMode == .followingCursor {
            let mouseInOverlay = convertScreenPointToOverlayCoordinates(mouseLocation)
            let followTarget = CGPoint(
                x: mouseInOverlay.x + Self.followOffsetFromMouse.width,
                y: mouseInOverlay.y + Self.followOffsetFromMouse.height
            )
            if didMouseArriveOnThisScreen {
                // Coming from another monitor: appear at the mouse, don't
                // glide in from wherever this screen last saw it.
                cursorPosition = followTarget
                followVelocity = .zero
            } else {
                advanceFollowSpring(toward: followTarget, elapsedSeconds: CGFloat(elapsedSeconds))
            }
        }

        // Glow follows flight speed, fading out gently after landing.
        let movedDistance = hypot(cursorPosition.x - positionBeforeThisFrame.x, cursorPosition.y - positionBeforeThisFrame.y)
        let targetGlowIntensity: CGFloat = activeFlight != nil
            ? min(movedDistance / max(CGFloat(elapsedSeconds), 0.001) / 1600, 1)
            : 0
        let glowBlend = min(CGFloat(elapsedSeconds) * 10, 1)
        flightGlowIntensity += (targetGlowIntensity - flightGlowIntensity) * glowBlend
        if flightGlowIntensity < 0.003 { flightGlowIntensity = 0 }

        applyGlyphGeometry(force: false)
        applyGlow()
        applySpeechHalo(frameTimestamp: frameTimestamp)
        advanceTrail(frameTimestamp: frameTimestamp)

        // Nothing moving for a moment: pause this screen's frame clock (no
        // 60–120 wakeups a second while idle) until the mouse moves or her
        // state changes. Speaking keeps it running: the glow follows her voice.
        let isAnythingMoving = activeFlight != nil
            || activeInkStroke != nil
            || landingSettle != nil
            || !trailPoints.isEmpty
            || flightGlowIntensity > 0
            || cursorPosition != positionBeforeThisFrame
            || companionManager.voiceState == .responding
        consecutiveIdleFrameCount = isAnythingMoving ? 0 : consecutiveIdleFrameCount + 1
        if consecutiveIdleFrameCount >= Self.idleFramesBeforePausingFrameClock {
            pauseFrameClockUntilMouseMoves()
        }
    }

    // MARK: - Pausing When Idle

    private static let idleFramesBeforePausingFrameClock = 30
    private var consecutiveIdleFrameCount = 0
    private var mouseMovementMonitors: [Any] = []

    private func pauseFrameClockUntilMouseMoves() {
        guard !frameClock.isPaused else { return }
        frameClock.pause()
        let wakeOnMouseMovement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        // Global: movement over other apps. Local: movement over Vesper's own panel.
        // The handlers only schedule the resume for after this event has been
        // delivered: resuming removes these very monitors, and removing a
        // monitor while AppKit is still calling it crashed the app (AppKit
        // called into the freed handler).
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: wakeOnMouseMovement, handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumeFrameClockIfPaused()
            }
        }) {
            mouseMovementMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: wakeOnMouseMovement, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.resumeFrameClockIfPaused()
            }
            return event
        }) {
            mouseMovementMonitors.append(localMonitor)
        }
        scheduleIdleDim()
    }

    private func resumeFrameClockIfPaused() {
        consecutiveIdleFrameCount = 0
        removeMouseMovementMonitors()
        frameClock.resume()
        cancelIdleDimAndRestore()
    }

    // MARK: - Idle Dim

    /// The frame clock pauses after ~0.25–0.5 s of stillness; this much
    /// later she dims, so ~2 s after the mouse stopped.
    private static let secondsAfterPauseBeforeIdleDim: TimeInterval = 1.6
    private static let idleDimOpacity: Float = 0.55
    private static let idleDimScale: CGFloat = 0.85
    private var isIdleDimmed = false
    /// Bumped on every schedule and cancel, so a stale one-shot does nothing.
    private var idleDimGeneration = 0

    /// One delayed check, not a timer: the frame clock stays paused and
    /// nothing runs per frame. The dim itself is a render-server animation.
    private func scheduleIdleDim() {
        idleDimGeneration += 1
        let generationAtSchedule = idleDimGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsAfterPauseBeforeIdleDim) { [weak self] in
            guard let self,
                  self.idleDimGeneration == generationAtSchedule,
                  self.frameClock.isPaused,
                  self.isIdleEnoughToDim else { return }
            self.setIdleDimmed(true)
        }
    }

    /// Only when she's truly idle and following the mouse: never while
    /// listening, thinking, speaking, in control, resting (she already
    /// dims), pointing or saying hello.
    private var isIdleEnoughToDim: Bool {
        companionManager.voiceState == .idle
            && !companionManager.isControllingScreen
            && !isResting
            && buddyNavigationMode == .followingCursor
            && isCursorOnThisScreen
            && !isShowingWelcome
    }

    /// Mouse movement or any state change brings her straight back.
    private func cancelIdleDimAndRestore() {
        idleDimGeneration += 1
        if isIdleDimmed {
            setIdleDimmed(false)
        }
    }

    /// Eases to dimmed (slowly) or back (quickly) from wherever she is on
    /// screen right now, as one opacity-and-scale animation.
    private func setIdleDimmed(_ shouldBeDimmed: Bool) {
        isIdleDimmed = shouldBeDimmed
        let targetOpacity: Float = shouldBeDimmed ? Self.idleDimOpacity : 1
        // Reduce Motion: fade only, no shrinking.
        let targetScale: CGFloat = shouldBeDimmed && !isReduceMotionOn ? Self.idleDimScale : 1
        let targetTransform = CATransform3DMakeScale(targetScale, targetScale, 1)
        let opacityOnScreenNow = idleDimLayer.presentation()?.opacity ?? idleDimLayer.opacity
        let transformOnScreenNow = idleDimLayer.presentation()?.transform ?? idleDimLayer.transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        idleDimLayer.opacity = targetOpacity
        idleDimLayer.transform = targetTransform
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = opacityOnScreenNow
        opacityAnimation.toValue = targetOpacity
        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = NSValue(caTransform3D: transformOnScreenNow)
        transformAnimation.toValue = NSValue(caTransform3D: targetTransform)
        let idleDimAnimation = CAAnimationGroup()
        idleDimAnimation.animations = [opacityAnimation, transformAnimation]
        idleDimAnimation.duration = shouldBeDimmed ? 0.6 : 0.15
        idleDimAnimation.timingFunction = CAMediaTimingFunction(name: shouldBeDimmed ? .easeInEaseOut : .easeOut)
        idleDimLayer.add(idleDimAnimation, forKey: "idleDim")
        CATransaction.commit()
    }

    private func removeMouseMovementMonitors() {
        for mouseMovementMonitor in mouseMovementMonitors {
            NSEvent.removeMonitor(mouseMovementMonitor)
        }
        mouseMovementMonitors.removeAll()
    }

    /// Moves, rotates and scales the triangle layer — GPU compositing only.
    private func applyGlyphGeometry(force: Bool) {
        let newGeometry = (position: cursorPosition, rotationDegrees: triangleRotationDegrees, scale: buddyFlightScale)
        if !force, let lastAppliedGlyphGeometry,
           abs(lastAppliedGlyphGeometry.position.x - newGeometry.position.x) < 0.01,
           abs(lastAppliedGlyphGeometry.position.y - newGeometry.position.y) < 0.01,
           abs(lastAppliedGlyphGeometry.rotationDegrees - newGeometry.rotationDegrees) < 0.01,
           abs(lastAppliedGlyphGeometry.scale - newGeometry.scale) < 0.001 {
            return
        }
        lastAppliedGlyphGeometry = newGeometry

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorGlyphLayer.position = layerPoint(fromOverlayPoint: cursorPosition)
        cursorAccessoryLayer.position = cursorGlyphLayer.position
        let rotation = CATransform3DMakeRotation(Self.layerRotationRadians(fromClockwiseDegrees: triangleRotationDegrees), 0, 0, 1)
        cursorGlyphLayer.transform = CATransform3DScale(rotation, buddyFlightScale, buddyFlightScale, 1)
        CATransaction.commit()
    }

    /// Brighter while flying fast. Only touched when the value actually
    /// changes. (Her voice drives the halo instead: changing a shadow's
    /// radius makes the render server re-blur it every frame.)
    private func applyGlow() {
        let targetShadowRadius = Self.baseShadowRadius + flightGlowIntensity * 16
        guard abs(targetShadowRadius - lastAppliedShadowRadius) > 0.25 else { return }
        lastAppliedShadowRadius = targetShadowRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        triangleLayer.shadowRadius = targetShadowRadius
        CATransaction.commit()
    }

    /// Small dots along her recent path, shrinking and fading with age.
    private func advanceTrail(frameTimestamp: CFTimeInterval) {
        guard !trailPoints.isEmpty || trailDotLayers.contains(where: { !$0.isHidden }) else { return }

        let oldestKeptTimestamp = frameTimestamp - Self.trailLifetimeSeconds
        trailPoints.removeAll { $0.recordedAt < oldestKeptTimestamp }
        if trailPoints.count > Self.maximumTrailDotCount {
            trailPoints.removeFirst(trailPoints.count - Self.maximumTrailDotCount)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let isTrailVisible = buddyIsVisibleOnThisScreen
        for (dotIndex, trailDotLayer) in trailDotLayers.enumerated() {
            guard isTrailVisible, dotIndex < trailPoints.count else {
                trailDotLayer.isHidden = true
                continue
            }
            let trailPoint = trailPoints[dotIndex]
            let freshness = max(0, 1 - (frameTimestamp - trailPoint.recordedAt) / Self.trailLifetimeSeconds)
            let dotDiameter = (1.0 + 2.5 * freshness) * 2
            trailDotLayer.isHidden = false
            trailDotLayer.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
            trailDotLayer.cornerRadius = dotDiameter / 2
            trailDotLayer.position = layerPoint(fromOverlayPoint: trailPoint.position)
            trailDotLayer.opacity = Float(0.45 * freshness)
        }
        CATransaction.commit()
    }

    /// Critically damped spring toward the mouse: follows closely, never
    /// overshoots, and moves the same at 60 Hz or 120 Hz.
    private func advanceFollowSpring(toward followTarget: CGPoint, elapsedSeconds: CGFloat) {
        let offsetFromTarget = hypot(cursorPosition.x - followTarget.x, cursorPosition.y - followTarget.y)
        let followSpeed = hypot(followVelocity.dx, followVelocity.dy)
        if offsetFromTarget < 0.1 && followSpeed < 1 {
            cursorPosition = followTarget
            followVelocity = .zero
            return
        }

        var horizontalVelocity = followVelocity.dx
        var verticalVelocity = followVelocity.dy
        let nextX = Self.criticallyDampedStep(
            current: cursorPosition.x, target: followTarget.x, velocity: &horizontalVelocity,
            smoothingSeconds: Self.followSmoothingSeconds, elapsedSeconds: elapsedSeconds
        )
        let nextY = Self.criticallyDampedStep(
            current: cursorPosition.y, target: followTarget.y, velocity: &verticalVelocity,
            smoothingSeconds: Self.followSmoothingSeconds, elapsedSeconds: elapsedSeconds
        )
        cursorPosition = CGPoint(x: nextX, y: nextY)
        followVelocity = CGVector(dx: horizontalVelocity, dy: verticalVelocity)
    }

    /// One frame of a critically damped spring (the well-known "smooth
    /// damp" approximation), stable for any frame length.
    private static func criticallyDampedStep(
        current: CGFloat,
        target: CGFloat,
        velocity: inout CGFloat,
        smoothingSeconds: CGFloat,
        elapsedSeconds: CGFloat
    ) -> CGFloat {
        let angularFrequency = 2 / smoothingSeconds
        let dampingInput = angularFrequency * elapsedSeconds
        let decay = 1 / (1 + dampingInput + 0.48 * dampingInput * dampingInput + 0.235 * dampingInput * dampingInput * dampingInput)
        let offset = current - target
        let velocityTerm = (velocity + angularFrequency * offset) * elapsedSeconds
        velocity = (velocity - angularFrequency * velocityTerm) * decay
        return target + (offset + velocityTerm) * decay
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to this
    /// overlay's top-left-origin coordinates.
    private func convertScreenPointToOverlayCoordinates(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        )
    }

    // MARK: - Element Navigation

    private func handlePointingTargetChange(_ newLocation: CGPoint?) {
        defer { refreshAppearance() }
        // Marks and the pointing target change together; take the marks first.
        syncInkMarksWithCompanion()
        let isInkInProgressOnThisScreen = activeInkStroke != nil || isFlyingToPenStart || !inkMarkIDsWaitingToBeDrawn.isEmpty

        guard let screenLocation = newLocation,
              let displayFrame = companionManager.detectedElementDisplayFrame else {
            // Target cleared — she's done talking about it. Come home, once
            // any drawing in progress is finished.
            if isInkInProgressOnThisScreen {
                pointingLocationWaitingForInk = .some(nil)
                return
            }
            if buddyNavigationMode != .followingCursor && !isReturningToCursor {
                if isCursorOnThisScreen {
                    startFlyingBackToCursor()
                } else {
                    // The mouse is on another screen, whose buddy is already
                    // showing — don't fly off-screen and show two cursors.
                    cancelNavigationAndResumeFollowing()
                }
            }
            return
        }

        let isTargetOnThisScreen = screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
            || displayFrame == screenFrame
        guard isTargetOnThisScreen else {
            // The next point is on another monitor; that screen's buddy
            // takes over and this one steps aside.
            if buddyNavigationMode != .followingCursor {
                cancelNavigationAndResumeFollowing()
            }
            return
        }

        // Drawing here: the manager pointed her at where a mark starts,
        // which her pen is already handling. Anything else waits until the
        // drawing is done.
        if isInkInProgressOnThisScreen {
            if !isStartOfAnInkMark(screenLocation) {
                pointingLocationWaitingForInk = .some(screenLocation)
            }
            return
        }
        if isStartOfAnInkMark(screenLocation) {
            // Its mark has already been drawn (a repeat of the same place).
            return
        }

        // Also handles moving straight from one target to the next when
        // she walks through several steps.
        startNavigatingToElement(screenLocation: screenLocation)
    }

    /// Whether a pointing target is only where one of her marks starts
    /// (how the manager claims the cursor for a drawing).
    private func isStartOfAnInkMark(_ screenLocation: CGPoint) -> Bool {
        companionManager.inkMarks.contains { inkMark in
            let penStartGlobalPoint = inkMark.drawingStartGlobalPoint
            return abs(penStartGlobalPoint.x - screenLocation.x) < 1 && abs(penStartGlobalPoint.y - screenLocation.y) < 1
        }
    }

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt the welcome line.
        guard !isShowingWelcome else { return }

        let targetInOverlay = convertScreenPointToOverlayCoordinates(screenLocation)
        // Sit beside the element rather than on top of it: 8pt right, 12pt below.
        let clampedTarget = CGPoint(
            x: max(20, min(targetInOverlay.x + 8, screenFrame.width - 20)),
            y: max(20, min(targetInOverlay.y + 12, screenFrame.height - 20))
        )

        cursorPositionWhenNavigationStarted = convertScreenPointToOverlayCoordinates(NSEvent.mouseLocation)
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        startFlight(to: clampedTarget) { [weak self] in
            guard let self, self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    private func startFlight(to destination: CGPoint, isQuickHop: Bool = false, onComplete: @escaping () -> Void) {
        landingSettle = nil
        followVelocity = .zero
        activeFlight = CursorFlight(startPosition: cursorPosition, endPosition: destination, isQuickHop: isQuickHop, onComplete: onComplete)
    }

    /// Transitions to pointing mode on arrival. The buddy stays on the
    /// element for as long as Vesper is talking about it; the manager clears
    /// the target (sending it home) or sets the next one.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        settleRotationBackToPointerAngle()
        refreshAppearance()
        // A hands-on click waits for this, so it never lands before she does.
        companionManager.noteCursorArrivedAtPointingTarget()
    }

    /// Eases the triangle from its flight heading back to the pointer angle.
    private func settleRotationBackToPointerAngle() {
        // Take the short way round: a flight heading of e.g. 250° is the same
        // as -110°, which is 75° from -35°, not 285°.
        var headingDuringFlight = triangleRotationDegrees
        while headingDuringFlight - (-35) > 180 { headingDuringFlight -= 360 }
        while headingDuringFlight - (-35) < -180 { headingDuringFlight += 360 }
        triangleRotationDegrees = -35
        lastAppliedGlyphGeometry = nil
        let rotateBack = CABasicAnimation(keyPath: "transform.rotation.z")
        rotateBack.fromValue = Self.layerRotationRadians(fromClockwiseDegrees: headingDuringFlight)
        rotateBack.toValue = Self.layerRotationRadians(fromClockwiseDegrees: -35)
        rotateBack.duration = 0.3
        rotateBack.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cursorGlyphLayer.add(rotateBack, forKey: "rotateBack")
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseInOverlay = convertScreenPointToOverlayCoordinates(NSEvent.mouseLocation)
        let cursorWithTrackingOffset = CGPoint(
            x: mouseInOverlay.x + Self.followOffsetFromMouse.width,
            y: mouseInOverlay.y + Self.followOffsetFromMouse.height
        )
        cursorPositionWhenNavigationStarted = mouseInOverlay
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        startFlight(to: cursorWithTrackingOffset) { [weak self] in
            self?.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        activeFlight = nil
        landingSettle = nil
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        if triangleRotationDegrees != -35 {
            settleRotationBackToPointerAngle()
        }
        buddyFlightScale = 1.0
        applyGlyphGeometry(force: true)
        refreshAppearance()
    }

    // MARK: - Welcome (first launch)

    /// She arrives: a highlight ring converges on the spot and she pops in
    /// on a spring with a flash of her halo. (Her "hey, i'm vesper." is in
    /// the island.)
    private func startWelcomeSequence() {
        isShowingWelcome = true
        isWelcomeFadeInFinished = false
        let isReduceMotionOn = self.isReduceMotionOn
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = isReduceMotionOn ? 0.6 : 0.3
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cursorGlyphLayer.add(fadeIn, forKey: "welcomeFadeIn")
        cursorGlyphLayer.opacity = 1

        if !isReduceMotionOn {
            let popIn = CASpringAnimation(keyPath: "transform.scale")
            popIn.fromValue = 0
            popIn.toValue = 1
            popIn.mass = 1
            popIn.stiffness = 260
            popIn.damping = 12
            popIn.duration = popIn.settlingDuration
            triangleLayer.add(popIn, forKey: "welcomePop")
            playEffectRing(
                atLayerPoint: cursorLayerPoint, ringColor: NSColor(DS.Colors.overlayCursorHighlight),
                startScale: 3, endScale: 1, opacityKeyframes: [0, 0.7, 0], durationSeconds: 0.6,
                timingFunction: CAMediaTimingFunction(name: .easeOut)
            )
        }
        playHaloFlare(peakOpacity: 0.8, durationSeconds: 0.5)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.isWelcomeFadeInFinished = true
            self.isShowingWelcome = false
            self.refreshAppearance()
        }
    }
}

/// The overlay's root view uses top-left coordinates, like the motion math.
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }

    /// Only called while the window takes the mouse (the hotkey is held):
    /// the whole overlay is one drawing surface.
    weak var sketchController: VesperCursorOverlayController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// The overlay never becomes key or active; the first click must still draw.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        sketchController?.handleSketchMouseDown(atOverlayPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        sketchController?.handleSketchMouseDragged(toOverlayPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        sketchController?.handleSketchMouseUp(atOverlayPoint: convert(event.locationInWindow, from: nil))
    }
}

// MARK: - Motion Pieces

/// Calls `onFrame` once per refresh of one screen, with the real seconds
/// since the previous frame. Uses the screen's own display link, so motion
/// matches its refresh rate (60 Hz, 120 Hz ProMotion, external monitors).
final class OverlayFrameClock: NSObject {
    var onFrame: ((CFTimeInterval, CFTimeInterval) -> Void)?

    private var displayLink: CADisplayLink?
    private var previousFrameTimestamp: CFTimeInterval?

    func start(on screen: NSScreen) {
        stop()
        let screenDisplayLink = screen.displayLink(target: self, selector: #selector(handleDisplayLinkFrame(_:)))
        screenDisplayLink.add(to: .main, forMode: .common)
        displayLink = screenDisplayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousFrameTimestamp = nil
    }

    var isPaused: Bool { displayLink?.isPaused ?? true }

    func pause() {
        displayLink?.isPaused = true
    }

    func resume() {
        guard let displayLink, displayLink.isPaused else { return }
        // The first frame after a pause mustn't count the paused time.
        previousFrameTimestamp = nil
        displayLink.isPaused = false
    }

    @objc private func handleDisplayLinkFrame(_ displayLink: CADisplayLink) {
        let frameTimestamp = displayLink.timestamp
        // A long gap (app was busy, screen asleep) is capped so nothing jumps.
        let elapsedSeconds = previousFrameTimestamp.map { min(max(frameTimestamp - $0, 0), 1.0 / 20.0) } ?? (1.0 / 60.0)
        previousFrameTimestamp = frameTimestamp
        onFrame?(elapsedSeconds, frameTimestamp)
    }
}

/// One flight along a quadratic bezier arc.
private struct CursorFlight {
    let startPosition: CGPoint
    let endPosition: CGPoint
    let controlPoint: CGPoint
    let durationSeconds: Double
    /// A brisk hop to where a drawing starts: faster, flatter, and no
    /// landing settle — it flows straight into the stroke.
    let isQuickHop: Bool
    let onComplete: () -> Void
    var elapsedSeconds: Double = 0

    init(startPosition: CGPoint, endPosition: CGPoint, isQuickHop: Bool = false, onComplete: @escaping () -> Void) {
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.isQuickHop = isQuickHop
        self.onComplete = onComplete

        let distance = hypot(endPosition.x - startPosition.x, endPosition.y - startPosition.y)
        // Short hops are quick, long flights more dramatic: 0.6s–1.4s
        // (a pen's hop between marks: 0.28s–0.75s).
        self.durationSeconds = isQuickHop
            ? min(max(Double(distance) / 1300.0, 0.28), 0.75)
            : min(max(Double(distance) / 800.0, 0.6), 1.4)
        // The arc bows upward (negative Y) by up to 80pt (40pt for a hop).
        let arcHeight = isQuickHop ? min(distance * 0.12, 40.0) : min(distance * 0.2, 80.0)
        self.controlPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0 - arcHeight
        )
    }

    /// Mostly smoothstep, blended with an ease-in that still has speed at
    /// the end — so she arrives with a little momentum for the landing
    /// settle to absorb, instead of stopping dead.
    static func easedPathProgress(forLinearProgress linearProgress: Double) -> Double {
        let smoothstep = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)
        let easeInWithMomentum = linearProgress * linearProgress * (2.0 - linearProgress)
        return smoothstep * (1.0 - Self.arrivalMomentumShare) + easeInWithMomentum * Self.arrivalMomentumShare
    }

    /// How much of the arrival speed is kept (0 = stops dead).
    private static let arrivalMomentumShare = 0.3

    /// Speed at the moment of landing, in points per second.
    var arrivalSpeedPointsPerSecond: CGFloat {
        // Path progress rate at the end is arrivalMomentumShare per unit
        // time; the curve's end tangent is 2(end − control).
        let endTangentLength = 2 * hypot(endPosition.x - controlPoint.x, endPosition.y - controlPoint.y)
        return endTangentLength * CGFloat(Self.arrivalMomentumShare / durationSeconds)
    }

    func position(atPathProgress pathProgress: Double) -> CGPoint {
        let remainingProgress = 1.0 - pathProgress
        return CGPoint(
            x: remainingProgress * remainingProgress * startPosition.x
                + 2.0 * remainingProgress * pathProgress * controlPoint.x
                + pathProgress * pathProgress * endPosition.x,
            y: remainingProgress * remainingProgress * startPosition.y
                + 2.0 * remainingProgress * pathProgress * controlPoint.y
                + pathProgress * pathProgress * endPosition.y
        )
    }

    func tangent(atPathProgress pathProgress: Double) -> CGVector {
        let remainingProgress = 1.0 - pathProgress
        return CGVector(
            dx: 2.0 * remainingProgress * (controlPoint.x - startPosition.x) + 2.0 * pathProgress * (endPosition.x - controlPoint.x),
            dy: 2.0 * remainingProgress * (controlPoint.y - startPosition.y) + 2.0 * pathProgress * (endPosition.y - controlPoint.y)
        )
    }
}

/// After landing, she drifts a few points past the target and settles
/// back — a lightly damped spring, over in under half a second.
private struct CursorLandingSettle {
    let landingPosition: CGPoint
    let unitTravelDirection: CGVector
    let overshootAmplitude: CGFloat
    var elapsedSeconds: Double = 0

    private static let settleDurationSeconds = 0.45
    private static let oscillationAngularFrequency = 2.0 * Double.pi / 0.34
    private static let decaySeconds = 0.11
    private static let maximumOvershootPoints: CGFloat = 8

    init(landingPosition: CGPoint, travelDirection: CGVector, arrivalSpeedPointsPerSecond: CGFloat) {
        self.landingPosition = landingPosition
        let directionLength = max(hypot(travelDirection.dx, travelDirection.dy), 0.001)
        self.unitTravelDirection = CGVector(dx: travelDirection.dx / directionLength, dy: travelDirection.dy / directionLength)
        // Matches the landing speed where possible, so there's no jolt.
        self.overshootAmplitude = min(arrivalSpeedPointsPerSecond / CGFloat(Self.oscillationAngularFrequency), Self.maximumOvershootPoints)
    }

    var isFinished: Bool { elapsedSeconds >= Self.settleDurationSeconds }

    var currentPosition: CGPoint {
        guard !isFinished else { return landingPosition }
        let displacement = overshootAmplitude
            * CGFloat(exp(-elapsedSeconds / Self.decaySeconds) * sin(Self.oscillationAngularFrequency * elapsedSeconds))
        return CGPoint(
            x: landingPosition.x + unitTravelDirection.dx * displacement,
            y: landingPosition.y + unitTravelDirection.dy * displacement
        )
    }
}

/// One stroke her pen is drawing (see VesperInk).
private struct CursorInkStroke {
    let inkMarkID: Int
    let durationSeconds: Double
    var elapsedSeconds: Double = 0
}

private struct CursorTrailPoint {
    let position: CGPoint
    let recordedAt: CFTimeInterval
}

// MARK: - Hands-On Events for the Overlay

/// One hands-on click about to be posted (published by CompanionManager).
/// The number makes every click a new value, even at the same spot.
struct VesperHandsOnClickPulse: Equatable {
    let pulseNumber: Int
    /// AppKit global coordinates (bottom-left origin).
    let appKitGlobalPoint: CGPoint
    let clickKind: VesperClickKind
}

/// A hands-on task ending on its own: finished ([DONE]) or cut short.
struct VesperHandsOnTaskOutcomeEvent: Equatable {
    let eventNumber: Int
    let didSucceed: Bool
}

// MARK: - Overlay Window Manager

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    /// While the hotkey is held the overlays take the mouse, so the user
    /// can draw on screen (see VesperSketch); otherwise they're click-through.
    private var isTakingMouseForSketching = false

    func setTakesMouseForSketching(_ isTakingMouse: Bool) {
        isTakingMouseForSketching = isTakingMouse
        for window in overlayWindows {
            window.ignoresMouseEvents = !isTakingMouse
        }
    }
    private var cursorControllers: [VesperCursorOverlayController] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)
            let cursorController = VesperCursorOverlayController(
                screen: screen,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )
            window.contentView = cursorController.rootView
            window.ignoresMouseEvents = !isTakingMouseForSketching

            overlayWindows.append(window)
            cursorControllers.append(cursorController)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for cursorController in cursorControllers {
            cursorController.tearDown()
        }
        cursorControllers.removeAll()
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()
        // The cursor holds still while it fades; nothing needs a frame clock.
        for cursorController in cursorControllers {
            cursorController.tearDown()
        }
        cursorControllers.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
