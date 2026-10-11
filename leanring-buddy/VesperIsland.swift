//
//  VesperIsland.swift
//  leanring-buddy
//
//  Vesper's island: a black shape that grows out of the top edge of the
//  screen — out of the notch on a MacBook, and as a notch of its own on a
//  display without one — whenever she's doing something, and retracts into
//  the edge when she's done. It's where her state lives:
//
//    listening   white bars that follow your voice
//    thinking    a small comet orbiting
//    speaking    her sentence as a caption, bars in her color for her voice
//    working     amber: what she's doing with the controls right now
//    asking      amber: the question she's waiting on, how to answer, and
//                how long the question stays open
//    notices     a memory saved, a reminder, an error
//    done        a check when a task finishes, a cross when it's cut short
//
//  Her cursor is her hand (it points and acts); the island is her voice.
//  Both share one glyph and one tint, so they read as one presence.
//
//  This file has no dependencies beyond SwiftUI/AppKit and the DS color
//  tokens, so scripts/render-island.sh can draw every state to images
//  without running the app. VesperIslandController owns the window and
//  maps CompanionManager's state onto `VesperIslandModel`.
//

import AppKit
import SwiftUI

// MARK: - What the Island Shows

/// What the island is showing. Each case has its own layout; changes
/// between them morph the shape and crossfade the content.
enum VesperIslandPresentation: Equatable {
    case hidden
    case listening
    case thinking
    /// `caption` is the sentence she's saying (nil with captions off);
    /// `stepText` is "2/4" during a walkthrough; `noticeText` is a short
    /// note that arrived while she's talking ("noted: …").
    case speaking(caption: String?, stepText: String?, noticeText: String?)
    /// In control of the screen: what she's doing right now and which step.
    case working(activityText: String, stepNumber: Int?)
    /// Waiting on a yes. `isListening` while the mic is open for the answer.
    case asking(questionText: String, isListening: Bool, expiresAt: Date)
    case notice(text: String, kind: VesperIslandNoticeKind)
    /// A task ended by itself: finished, or cut short.
    case finished(didSucceed: Bool)
    /// First launch: "hey, i'm vesper."
    case welcome(text: String)
    /// First launch: "hold ⌃ ⌥ and say hi".
    case shortcutHint(beforeKeysText: String, afterKeysText: String)
    /// A guided walkthrough: what to click, while she waits for it.
    case guiding(instructionText: String, stepNumber: Int)

    /// The layout family, for transitions: content crossfades when this
    /// changes, and morphs in place when only the text changes.
    enum Kind: Equatable {
        case hidden, listening, thinking, speaking, working, asking, notice, finished, welcome, shortcutHint, guiding
    }

    var kind: Kind {
        switch self {
        case .hidden: return .hidden
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .working: return .working
        case .asking: return .asking
        case .notice: return .notice
        case .finished: return .finished
        case .welcome: return .welcome
        case .shortcutHint: return .shortcutHint
        case .guiding: return .guiding
        }
    }
}

/// Which icon and color a notice gets.
enum VesperIslandNoticeKind: Equatable {
    case memory
    case forgot
    case calendar
    case timer
    case reminder
    case information
    case warning
    case error

    var symbolName: String {
        switch self {
        case .memory: return "sparkles"
        case .forgot: return "eraser"
        case .calendar: return "calendar.badge.plus"
        case .timer: return "timer"
        case .reminder: return "bell.fill"
        case .information: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Her color: blue normally, amber while she's in control or waiting on a
/// yes, slate while resting at the plan's limit.
enum VesperIslandTint: Equatable {
    case normal
    case inControl
    case resting

    var color: Color {
        switch self {
        case .normal: return VesperIslandStyle.vesperBlue
        case .inControl: return VesperIslandStyle.controlAmber
        case .resting: return VesperIslandStyle.restingSlate
        }
    }
}

/// The screen the island is on: whether it has a camera notch, how tall
/// the top band is, and how wide the middle of the band is. On a notch
/// the middle is hidden behind the camera housing, so nothing is ever
/// drawn there; without a notch the island keeps the same proportions,
/// so it looks the same on every screen.
struct VesperIslandMetrics: Equatable {
    var hasHardwareNotch: Bool
    /// The notch's height, or the island's own band height without one.
    var bandHeight: CGFloat
    /// The notch's width, or the island's own middle without one.
    var centerGapWidth: CGFloat

    static let withoutNotch = VesperIslandMetrics(hasHardwareNotch: false, bandHeight: 32, centerGapWidth: 104)
}

// MARK: - Style

enum VesperIslandStyle {
    static let vesperBlue = Color(hex: "#3380FF")
    static let controlAmber = Color(hex: "#FFA826")
    static let restingSlate = Color(hex: "#7D8CA8")
    static let successGreen = Color(hex: "#3DDC84")
    static let errorRed = Color(hex: "#FF5A5F")

    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.52)

    /// Room on each side of the band for the glyph and the indicator.
    static let earWidth: CGFloat = 42
    /// The flare where the island meets the top edge, so it reads as
    /// growing out of the edge rather than stuck on it.
    static let shoulderRadius: CGFloat = 7
    static let compactBottomCornerRadius: CGFloat = 13
    static let expandedBottomCornerRadius: CGFloat = 22
    /// Text never runs wider than this: a long sentence wraps into a
    /// taller island rather than a slab across the menu bar.
    static let maximumTextWidth: CGFloat = 372
    static let bodyHorizontalPadding: CGFloat = 20
    static let bodyBottomPadding: CGFloat = 14
    /// An island showing text is never narrower than this, so a two-word
    /// caption still sits in a considered shape.
    static let minimumExpandedWidth: CGFloat = 260

    /// Measuring fonts (AppKit) and the drawing fonts (SwiftUI) are the same
    /// SF Pro at the same size and weight, so measurements match what's drawn.
    static let captionFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let captionSwiftUIFont = Font.system(size: 13, weight: .medium)
    static let captionLineSpacing: CGFloat = 2.5
    static let secondaryFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let secondarySwiftUIFont = Font.system(size: 11, weight: .medium)

    /// Shape and size changes: quick, with a hint of overshoot, so the
    /// island feels elastic rather than mechanical.
    static let morphAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// Growing out of the edge: a little more bounce on arrival.
    static let arrivalAnimation = Animation.spring(response: 0.46, dampingFraction: 0.74)
    /// Retracting into the edge: no bounce on the way out.
    static let departureAnimation = Animation.spring(response: 0.34, dampingFraction: 0.95)
    /// Reduce Motion: every change is a short fade, nothing springs.
    static let reducedMotionAnimation = Animation.easeInOut(duration: 0.2)

    /// Measured the same way SwiftUI lays the text out, so the shape and
    /// the text agree on their size before anything is drawn.
    static func singleLineWidth(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    static func textWidth(for text: String, font: NSFont) -> CGFloat {
        min(singleLineWidth(of: text, font: font), maximumTextWidth)
    }
}

// MARK: - Model

/// Everything the island view reads. VesperIslandController writes it;
/// `@Observable` redraws only the parts that read what changed, so the
/// voice levels (updated many times a second) only redraw the bars.
@MainActor
@Observable
final class VesperIslandModel {
    var presentation: VesperIslandPresentation = .hidden
    var metrics: VesperIslandMetrics = .withoutNotch
    /// False while tucked into the top edge (before it grows out, and
    /// after it retracts).
    var isOut = false
    var tint: VesperIslandTint = .normal
    /// 0…1, the user's voice while listening.
    var microphoneLevel: CGFloat = 0
    /// 0…1, her voice while speaking.
    var voiceLevel: CGFloat = 0
    /// Bumped to shake the island ("no": a voice that isn't yours, a task
    /// cut short).
    var shakeCount = 0
    /// Bumped for one soft swell ("look here": a question needs an answer).
    var attentionPulseCount = 0
    var isReduceMotionOn = false
}

// MARK: - The Shape

/// The island's outline: flat along the top edge with small flared
/// shoulders where it meets the edge, straight sides, and rounded bottom
/// corners. The frame it's drawn in includes the shoulders.
struct VesperIslandShape: Shape {
    var shoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = min(shoulderRadius, rect.width / 4, rect.height / 2)
        let bodyMinX = rect.minX + shoulder
        let bodyMaxX = rect.maxX - shoulder
        let bodyWidth = max(bodyMaxX - bodyMinX, 0)
        let cornerRadius = max(min(bottomCornerRadius, bodyWidth / 2, max(rect.height - shoulder, 0)), 0)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left shoulder: curves in from the edge to the body's side.
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX, y: rect.minY + shoulder),
            control: CGPoint(x: bodyMinX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX + cornerRadius, y: rect.maxY),
            control: CGPoint(x: bodyMinX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyMaxX - cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: bodyMaxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + shoulder))
        // Right shoulder, back out to the edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyMaxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - The Island View

struct VesperIslandView: View {
    let model: VesperIslandModel

    var body: some View {
        let presentation = model.presentation
        let metrics = model.metrics
        let islandBodySize = Self.bodySize(for: presentation, metrics: metrics)
        let collapsedBodySize = CGSize(
            width: metrics.centerGapWidth,
            height: metrics.hasHardwareNotch ? metrics.bandHeight : 0
        )
        let isOut = model.isOut && presentation != .hidden
        let visibleBodySize = isOut ? islandBodySize : collapsedBodySize
        let isExpanded = isOut && islandBodySize.height > metrics.bandHeight + 1
        let bottomCornerRadius = isExpanded
            ? VesperIslandStyle.expandedBottomCornerRadius
            : VesperIslandStyle.compactBottomCornerRadius
        let shoulderRadius = VesperIslandStyle.shoulderRadius
        let islandShape = VesperIslandShape(shoulderRadius: shoulderRadius, bottomCornerRadius: bottomCornerRadius)

        ZStack(alignment: .top) {
            if isOut {
                VesperIslandContent(model: model, bodyWidth: islandBodySize.width)
                    .frame(width: islandBodySize.width, alignment: .top)
                    .transition(.asymmetric(
                        // The shape leads; the content follows it out.
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            }
        }
        // Out: as tall as its content. Tucked in: the notch's size (or
        // nothing, on a screen without one).
        .frame(width: visibleBodySize.width, height: isOut ? nil : collapsedBodySize.height, alignment: .top)
        // The shoulders flare out past the body on both sides.
        .padding(.horizontal, shoulderRadius)
        .clipShape(islandShape)
        .background(alignment: .top) {
            islandShape
                .fill(Color.black)
                .shadow(color: Color.black.opacity(isExpanded ? 0.38 : 0), radius: 18, x: 0, y: 8)
        }
        .modifier(VesperIslandShakeEffect(shakeCount: CGFloat(model.shakeCount)))
        .modifier(VesperIslandAttentionPulseEffect(pulseCount: CGFloat(model.attentionPulseCount)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The island's size (without its shoulders) for a presentation, from
    /// measured text — so the shape knows its size before anything is laid out.
    static func bodySize(for presentation: VesperIslandPresentation, metrics: VesperIslandMetrics) -> CGSize {
        let compactWidth = metrics.centerGapWidth + VesperIslandStyle.earWidth * 2
        let bandHeight = metrics.bandHeight

        func expandedSize(textWidth: CGFloat, bodyHeight: CGFloat) -> CGSize {
            let width = max(
                compactWidth,
                VesperIslandStyle.minimumExpandedWidth,
                textWidth + VesperIslandStyle.bodyHorizontalPadding * 2
            )
            return CGSize(width: width, height: bandHeight + bodyHeight + VesperIslandStyle.bodyBottomPadding)
        }

        switch presentation {
        case .hidden, .listening, .thinking, .finished:
            return CGSize(width: compactWidth, height: bandHeight)

        case .speaking(let caption, _, let noticeText):
            let lines = [caption, noticeText].compactMap { $0 }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { return CGSize(width: compactWidth, height: bandHeight) }
            var textWidth: CGFloat = 0
            var bodyHeight: CGFloat = 0
            if let caption, !caption.isEmpty {
                let captionMetrics = VesperIslandTextBlock.metrics(for: caption, font: VesperIslandStyle.captionFont, lineSpacing: VesperIslandStyle.captionLineSpacing)
                textWidth = max(textWidth, captionMetrics.width)
                bodyHeight += captionMetrics.height
            }
            if let noticeText, !noticeText.isEmpty {
                let noticeMetrics = VesperIslandTextBlock.metrics(for: noticeText, font: VesperIslandStyle.secondaryFont, lineSpacing: 1, extraWidth: 16)
                textWidth = max(textWidth, noticeMetrics.width)
                bodyHeight += (bodyHeight > 0 ? 6 : 0) + noticeMetrics.height
            }
            return expandedSize(textWidth: textWidth, bodyHeight: bodyHeight)

        case .working(let activityText, _):
            let activityMetrics = VesperIslandTextBlock.metrics(for: activityText, font: VesperIslandStyle.captionFont, lineSpacing: VesperIslandStyle.captionLineSpacing)
            let hintHeight = VesperIslandTextBlock.metrics(for: VesperIslandContent.stopHintText, font: VesperIslandStyle.secondaryFont, lineSpacing: 1).height
            return expandedSize(textWidth: activityMetrics.width, bodyHeight: activityMetrics.height + 4 + hintHeight)

        case .asking(let questionText, _, _):
            let questionMetrics = VesperIslandTextBlock.metrics(for: questionText, font: VesperIslandStyle.captionFont, lineSpacing: VesperIslandStyle.captionLineSpacing)
            // The answer hint row, then the bar showing how long the question stays open.
            let answerHintHeight: CGFloat = 20
            let expiryBarHeight: CGFloat = 2
            return expandedSize(
                textWidth: max(questionMetrics.width, VesperIslandContent.answerHintWidth),
                bodyHeight: questionMetrics.height + 8 + answerHintHeight + 10 + expiryBarHeight
            )

        case .notice(let text, _):
            let noticeMetrics = VesperIslandTextBlock.metrics(for: text, font: VesperIslandStyle.captionFont, lineSpacing: VesperIslandStyle.captionLineSpacing)
            return expandedSize(textWidth: noticeMetrics.width, bodyHeight: noticeMetrics.height)

        case .welcome(let text):
            let welcomeMetrics = VesperIslandTextBlock.metrics(for: text, font: VesperIslandStyle.captionFont, lineSpacing: VesperIslandStyle.captionLineSpacing)
            return expandedSize(textWidth: welcomeMetrics.width, bodyHeight: welcomeMetrics.height)

        case .shortcutHint(let beforeKeysText, let afterKeysText):
            let hintWidth = VesperIslandContent.shortcutHintWidth(beforeKeysText: beforeKeysText, afterKeysText: afterKeysText)
            return expandedSize(textWidth: hintWidth, bodyHeight: 22)

        case .guiding(let instructionText, _):
            let instructionMetrics = VesperIslandTextBlock.metrics(for: instructionText, font: VesperIslandStyle.captionFont, lineSpacing: VesperIslandStyle.captionLineSpacing)
            let hintMetrics = VesperIslandTextBlock.metrics(for: VesperIslandContent.guidingHintText, font: VesperIslandStyle.secondaryFont, lineSpacing: 1)
            return expandedSize(textWidth: max(instructionMetrics.width, hintMetrics.width), bodyHeight: instructionMetrics.height + 4 + hintMetrics.height)
        }
    }
}

/// Measures a block of wrapped text the way SwiftUI will draw it.
enum VesperIslandTextBlock {
    struct Metrics {
        let width: CGFloat
        let height: CGFloat
    }

    /// `extraWidth` reserves room beside the text (an inline icon).
    static func metrics(for text: String, font: NSFont, lineSpacing: CGFloat, extraWidth: CGFloat = 0) -> Metrics {
        let textWidth = VesperIslandStyle.textWidth(for: text, font: font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let textBounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        return Metrics(width: min(textWidth + extraWidth, VesperIslandStyle.maximumTextWidth + extraWidth), height: ceil(textBounds.height))
    }
}

/// A horizontal "no": a quick, decaying side-to-side shake.
struct VesperIslandShakeEffect: GeometryEffect {
    var shakeCount: CGFloat

    var animatableData: CGFloat {
        get { shakeCount }
        set { shakeCount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Between two whole counts, the fraction runs 0 → 1: three decaying swings.
        let progress = shakeCount - floor(shakeCount)
        guard progress > 0 else { return ProjectionTransform(.identity) }
        let horizontalOffset = sin(progress * .pi * 6) * 7 * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: horizontalOffset, y: 0))
    }
}

/// One soft swell from the top edge and back: "this needs you".
struct VesperIslandAttentionPulseEffect: GeometryEffect {
    var pulseCount: CGFloat

    var animatableData: CGFloat {
        get { pulseCount }
        set { pulseCount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = pulseCount - floor(pulseCount)
        guard progress > 0 else { return ProjectionTransform(.identity) }
        let swellScale = 1 + sin(progress * .pi) * 0.035
        // Anchored at the top center, so it swells down and out of the edge.
        let anchoredSwell = CGAffineTransform(translationX: size.width / 2, y: 0)
            .scaledBy(x: swellScale, y: swellScale)
            .translatedBy(x: -size.width / 2, y: 0)
        return ProjectionTransform(anchoredSwell)
    }
}

// MARK: - Content

/// The band (glyph on the left, indicator on the right, the middle left
/// empty for the notch) and, when there's text, the body below it.
struct VesperIslandContent: View {
    let model: VesperIslandModel
    let bodyWidth: CGFloat

    static let stopHintText = "hold ⌃ ⌥ to stop me"
    static let guidingHintText = "i'll show you the next step when you do"

    var body: some View {
        let presentation = model.presentation
        let metrics = model.metrics
        let tintColor = model.tint.color

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leadingEar(presentation: presentation, tintColor: tintColor)
                    .frame(width: VesperIslandStyle.earWidth, height: metrics.bandHeight)
                Spacer(minLength: 0)
                trailingEar(presentation: presentation, tintColor: tintColor)
                    .frame(width: VesperIslandStyle.earWidth, height: metrics.bandHeight)
            }
            .frame(width: bodyWidth, height: metrics.bandHeight)

            islandBody(presentation: presentation, tintColor: tintColor)
                .frame(width: bodyWidth)
        }
    }

    // MARK: Ears

    @ViewBuilder
    private func leadingEar(presentation: VesperIslandPresentation, tintColor: Color) -> some View {
        switch presentation {
        case .notice(_, let kind):
            Image(systemName: kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.noticeColor(for: kind, tintColor: tintColor))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .id(kind.symbolName)
        default:
            VesperIslandGlyph(
                tintColor: tintColor,
                glowLevel: presentation.kind == .speaking ? model.voiceLevel : 0,
                scale: presentation.kind == .listening || presentation.kind == .thinking ? 0.82 : 1
            )
        }
    }

    @ViewBuilder
    private func trailingEar(presentation: VesperIslandPresentation, tintColor: Color) -> some View {
        ZStack {
            switch presentation {
            case .listening:
                VesperIslandLevelBars(level: model.microphoneLevel, barColor: .white, isIdlePulseOn: !model.isReduceMotionOn)
                    .transition(Self.earTransition)
            case .thinking:
                VesperIslandThinkingOrbit(tintColor: tintColor, isReduceMotionOn: model.isReduceMotionOn)
                    .transition(Self.earTransition)
            case .speaking(_, let stepText, _):
                if let stepText {
                    Text(stepText)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tintColor)
                        .contentTransition(.numericText())
                        .transition(Self.earTransition)
                } else {
                    VesperIslandLevelBars(level: model.voiceLevel, barColor: tintColor, isIdlePulseOn: false)
                        .transition(Self.earTransition)
                }
            case .working(_, let stepNumber):
                VesperIslandStepBadge(stepNumber: stepNumber, tintColor: tintColor, isWaiting: false, isReduceMotionOn: model.isReduceMotionOn)
                    .transition(Self.earTransition)
            case .guiding(_, let stepNumber):
                VesperIslandStepBadge(stepNumber: stepNumber, tintColor: tintColor, isWaiting: true, isReduceMotionOn: model.isReduceMotionOn)
                    .transition(Self.earTransition)
            case .asking(_, let isListening, _):
                if isListening {
                    VesperIslandLevelBars(level: model.microphoneLevel, barColor: .white, isIdlePulseOn: !model.isReduceMotionOn)
                        .transition(Self.earTransition)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(tintColor))
                        .transition(Self.earTransition)
                }
            case .finished(let didSucceed):
                VesperIslandOutcomeMark(didSucceed: didSucceed, isReduceMotionOn: model.isReduceMotionOn)
                    .transition(Self.earTransition)
            case .hidden, .notice, .welcome, .shortcutHint:
                EmptyView()
            }
        }
        .animation(VesperIslandStyle.morphAnimation, value: presentation.kind)
    }

    private static let earTransition = AnyTransition.scale(scale: 0.5).combined(with: .opacity)

    // MARK: Body

    @ViewBuilder
    private func islandBody(presentation: VesperIslandPresentation, tintColor: Color) -> some View {
        switch presentation {
        case .speaking(let caption, _, let noticeText):
            if (caption?.isEmpty == false) || (noticeText?.isEmpty == false) {
                VStack(spacing: 6) {
                    if let caption, !caption.isEmpty {
                        VesperIslandCaption(text: caption, color: VesperIslandStyle.primaryText)
                    }
                    if let noticeText, !noticeText.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(tintColor)
                            Text(noticeText)
                                .font(VesperIslandStyle.secondarySwiftUIFont)
                                .foregroundStyle(VesperIslandStyle.secondaryText)
                                .lineLimit(2)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
                .transition(Self.bodyTransition)
            }

        case .working(let activityText, _):
            VStack(spacing: 4) {
                VesperIslandCaption(text: activityText, color: VesperIslandStyle.primaryText)
                Text(Self.stopHintText)
                    .font(VesperIslandStyle.secondarySwiftUIFont)
                    .foregroundStyle(VesperIslandStyle.secondaryText)
            }
            .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
            .transition(Self.bodyTransition)

        case .guiding(let instructionText, _):
            VStack(spacing: 4) {
                VesperIslandCaption(text: instructionText, color: VesperIslandStyle.primaryText)
                Text(Self.guidingHintText)
                    .font(VesperIslandStyle.secondarySwiftUIFont)
                    .foregroundStyle(VesperIslandStyle.secondaryText)
            }
            .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
            .transition(Self.bodyTransition)

        case .asking(let questionText, let isListening, let expiresAt):
            VStack(spacing: 8) {
                VesperIslandCaption(text: questionText, color: VesperIslandStyle.primaryText)
                VesperIslandAnswerHint(isListening: isListening, tintColor: tintColor)
                    .frame(height: 20)
                VesperIslandExpiryBar(expiresAt: expiresAt, tintColor: tintColor)
                    .frame(width: max(bodyWidth - VesperIslandStyle.bodyHorizontalPadding * 2, 40), height: 2)
                    .padding(.top, 2)
            }
            .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
            .transition(Self.bodyTransition)

        case .notice(let text, _):
            VesperIslandCaption(text: text, color: VesperIslandStyle.primaryText)
                .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
                .transition(Self.bodyTransition)

        case .welcome(let text):
            VesperIslandCaption(text: text, color: VesperIslandStyle.primaryText)
                .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
                .transition(Self.bodyTransition)

        case .shortcutHint(let beforeKeysText, let afterKeysText):
            HStack(spacing: 5) {
                Text(beforeKeysText)
                VesperIslandKeyCap(symbol: "⌃")
                VesperIslandKeyCap(symbol: "⌥")
                Text(afterKeysText)
            }
            .font(VesperIslandStyle.captionSwiftUIFont)
            .foregroundStyle(VesperIslandStyle.primaryText)
            .frame(height: 22)
            .padding(.bottom, VesperIslandStyle.bodyBottomPadding)
            .transition(Self.bodyTransition)

        case .hidden, .listening, .thinking, .finished:
            EmptyView()
        }
    }

    /// Text arrives a beat after the shape starts to grow (it follows the
    /// container, never leads it), softening in from a slight blur.
    private static let bodyTransition = AnyTransition.asymmetric(
        insertion: .modifier(
            active: VesperIslandSoftenModifier(amount: 1),
            identity: VesperIslandSoftenModifier(amount: 0)
        )
        .animation(.easeOut(duration: 0.24).delay(0.07)),
        removal: .opacity.animation(.easeIn(duration: 0.1))
    )

    static let answerHintWidth: CGFloat = 190

    static func shortcutHintWidth(beforeKeysText: String, afterKeysText: String) -> CGFloat {
        VesperIslandStyle.singleLineWidth(of: beforeKeysText, font: VesperIslandStyle.captionFont)
            + VesperIslandStyle.singleLineWidth(of: afterKeysText, font: VesperIslandStyle.captionFont)
            + VesperIslandKeyCap.width * 2 + 5 * 3
    }

    static func noticeColor(for kind: VesperIslandNoticeKind, tintColor: Color) -> Color {
        switch kind {
        case .warning: return VesperIslandStyle.controlAmber
        case .error: return VesperIslandStyle.errorRed
        case .memory, .forgot, .calendar, .timer, .reminder, .information: return tintColor
        }
    }
}

/// Fades and un-blurs text into place (and the reverse).
struct VesperIslandSoftenModifier: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: amount * 5)
            .scaleEffect(1 - amount * 0.04, anchor: .top)
    }
}

/// A caption: centered, wrapped at the island's text width. A new sentence
/// rises into place as the old one lifts away, like a teleprompter.
struct VesperIslandCaption: View {
    let text: String
    let color: Color

    var body: some View {
        let textWidth = VesperIslandStyle.textWidth(for: text, font: VesperIslandStyle.captionFont)
        Text(text)
            .font(VesperIslandStyle.captionSwiftUIFont)
            .foregroundStyle(color)
            .lineSpacing(VesperIslandStyle.captionLineSpacing)
            .multilineTextAlignment(.center)
            .frame(width: textWidth)
            .fixedSize(horizontal: false, vertical: true)
            .id(text)
            .transition(.asymmetric(
                insertion: .offset(y: 7).combined(with: .opacity).animation(.easeOut(duration: 0.22).delay(0.05)),
                removal: .offset(y: -7).combined(with: .opacity).animation(.easeIn(duration: 0.12))
            ))
    }
}

// MARK: - Pieces

/// Her glyph — the same tilted triangle as her cursor — with a soft glow
/// that swells with her voice.
struct VesperIslandGlyph: View {
    let tintColor: Color
    /// 0…1: her voice level while speaking, else 0.
    let glowLevel: CGFloat
    let scale: CGFloat

    var body: some View {
        VesperIslandTriangle()
            .fill(tintColor)
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(-35))
            .shadow(color: tintColor.opacity(0.55 + glowLevel * 0.45), radius: 3 + glowLevel * 5)
            .scaleEffect(scale * (1 + glowLevel * 0.12))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scale)
            .animation(.linear(duration: 0.08), value: glowLevel)
    }
}

/// Tip-up triangle, the same proportions as the cursor's.
struct VesperIslandTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

/// Four bars that follow a voice. White for the user's voice, her tint for
/// hers — so it's always clear whose voice is moving them.
struct VesperIslandLevelBars: View {
    let level: CGFloat
    let barColor: Color
    /// A slow ripple through the bars in silence, so she visibly is listening.
    let isIdlePulseOn: Bool

    private static let heightProfile: [CGFloat] = [0.55, 1.0, 0.78, 0.42]
    private static let minimumBarHeight: CGFloat = 3
    private static let maximumExtraHeight: CGFloat = 11

    var body: some View {
        let easedLevel = pow(min(max(level, 0), 1), 0.8)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isIdlePulseOn)) { timelineContext in
            let secondsNow = timelineContext.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<Self.heightProfile.count, id: \.self) { barIndex in
                    let idleRipple = isIdlePulseOn
                        ? CGFloat(0.5 + 0.5 * sin(secondsNow * 5.2 - Double(barIndex) * 0.9)) * 2
                        : 0
                    Capsule(style: .continuous)
                        .fill(barColor)
                        .frame(
                            width: 3,
                            height: Self.minimumBarHeight + idleRipple + easedLevel * Self.maximumExtraHeight * Self.heightProfile[barIndex]
                        )
                }
            }
            .animation(.interpolatingSpring(stiffness: 420, damping: 26), value: easedLevel)
        }
        .frame(height: Self.minimumBarHeight + Self.maximumExtraHeight + 2)
    }
}

/// Thinking: a short comet of dots circling. Speeds up after a few seconds
/// so a long think never looks stuck.
struct VesperIslandThinkingOrbit: View {
    let tintColor: Color
    let isReduceMotionOn: Bool

    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isReduceMotionOn)) { timelineContext in
            let secondsThinking = max(timelineContext.date.timeIntervalSince(appearedAt), 0)
            // One lap per 1.1 s, then one per 0.75 s after three seconds —
            // continuing from where it is, so the orbit never jumps.
            let lapsSoFar = secondsThinking < 3
                ? secondsThinking / 1.1
                : 3 / 1.1 + (secondsThinking - 3) / 0.75
            let orbitAngle = isReduceMotionOn ? Angle.zero : Angle.radians(-lapsSoFar * 2 * .pi)
            ZStack {
                ForEach(0..<5, id: \.self) { dotIndex in
                    Circle()
                        .fill(tintColor.opacity(1 - Double(dotIndex) * 0.18))
                        .frame(width: 3.6 - CGFloat(dotIndex) * 0.35, height: 3.6 - CGFloat(dotIndex) * 0.35)
                        .offset(y: -6.5)
                        .rotationEffect(.radians(Double(dotIndex) * 0.42))
                }
            }
            .rotationEffect(orbitAngle)
        }
        .frame(width: 18, height: 18)
        .onAppear { appearedAt = Date() }
    }
}

/// Which step she's on, in a small ring: an arc turning while she works
/// (busy), a full ring breathing slowly while she waits for the user.
struct VesperIslandStepBadge: View {
    let stepNumber: Int?
    let tintColor: Color
    /// Waiting on the user rather than working herself.
    let isWaiting: Bool
    let isReduceMotionOn: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isReduceMotionOn)) { timelineContext in
            let secondsNow = timelineContext.date.timeIntervalSinceReferenceDate
            let turnAngle = isReduceMotionOn || isWaiting ? 0 : secondsNow * 360 / 1.6
            let breath = isReduceMotionOn || !isWaiting ? 1 : 0.55 + 0.45 * (0.5 + 0.5 * sin(secondsNow * 2 * .pi / 1.8))
            ZStack {
                Circle()
                    .stroke(tintColor.opacity(0.22), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: isWaiting ? 1 : 0.28)
                    .stroke(tintColor.opacity(breath), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(turnAngle))
                if let stepNumber {
                    Text("\(stepNumber)")
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(tintColor)
                        .contentTransition(.numericText())
                }
            }
        }
        .frame(width: 19, height: 19)
    }
}

/// Done: a check that draws itself. Cut short: a cross.
struct VesperIslandOutcomeMark: View {
    let didSucceed: Bool
    let isReduceMotionOn: Bool

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        let markColor = didSucceed ? VesperIslandStyle.successGreen : VesperIslandStyle.controlAmber
        ZStack {
            Circle()
                .fill(markColor.opacity(0.18))
            VesperIslandOutcomeStroke(didSucceed: didSucceed)
                .trim(from: 0, to: drawProgress)
                .stroke(markColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .padding(5)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            if isReduceMotionOn {
                drawProgress = 1
            } else {
                withAnimation(.easeOut(duration: 0.32).delay(0.1)) {
                    drawProgress = 1
                }
            }
        }
    }
}

struct VesperIslandOutcomeStroke: Shape {
    let didSucceed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if didSucceed {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.1))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        } else {
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 1))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1))
            path.move(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
            path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
        }
        return path
    }
}

/// "hold ⌃ ⌥ and say yes" — or, while the mic is already open for the
/// answer, "listening for yes or no".
struct VesperIslandAnswerHint: View {
    let isListening: Bool
    let tintColor: Color

    var body: some View {
        HStack(spacing: 5) {
            if isListening {
                Circle()
                    .fill(tintColor)
                    .frame(width: 5, height: 5)
                Text("listening for yes or no")
            } else {
                Text("hold")
                VesperIslandKeyCap(symbol: "⌃")
                VesperIslandKeyCap(symbol: "⌥")
                Text("and say yes")
            }
        }
        .font(VesperIslandStyle.secondarySwiftUIFont)
        .foregroundStyle(VesperIslandStyle.secondaryText)
        .id(isListening)
        .transition(.opacity)
    }
}

/// One key of the shortcut, drawn like a key.
struct VesperIslandKeyCap: View {
    let symbol: String

    static let width: CGFloat = 18

    var body: some View {
        Text(symbol)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: Self.width, height: 17)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}

/// How long the question stays open: a thin bar that runs down to nothing
/// when the question expires, so waiting is never open-ended.
struct VesperIslandExpiryBar: View {
    let expiresAt: Date
    let tintColor: Color

    /// The whole length of the bar, in seconds (the question's lifetime).
    static let fullSeconds: TimeInterval = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timelineContext in
            let remainingShare = min(max(expiresAt.timeIntervalSince(timelineContext.date) / Self.fullSeconds, 0), 1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(tintColor.opacity(0.85))
                        .frame(width: geometry.size.width * remainingShare)
                }
            }
        }
    }
}
