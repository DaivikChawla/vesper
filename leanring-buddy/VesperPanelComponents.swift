//
//  VesperPanelComponents.swift
//  leanring-buddy
//
//  The menu bar panel's building blocks, in Vesper's own look: the same
//  near-black as her island, her blue triangle, amber when she's in
//  control. Grouped cards instead of one long list, so the panel stays a
//  fixed, MacBook-friendly size: a Home page for talking to her and a
//  Settings page for everything else.
//
//  Plain values in, closures out — no CompanionManager — so
//  scripts/render-panel.sh can draw the panel offscreen.
//

import SwiftUI

enum VesperPanelLayout {
    static let panelWidth: CGFloat = 340
    /// Fixed for both pages, so switching never makes the panel jump. Fits
    /// comfortably under the menu bar of a 13" MacBook (~900 pt visible).
    static let panelHeight: CGFloat = 520
    static let outerPadding: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
}

enum VesperPanelPalette {
    /// The island's black, a hair lifted so the panel reads as a surface.
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let cardFill = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.07)
    static let rowDivider = Color.white.opacity(0.06)
    static let controlTrack = Color.white.opacity(0.07)
    static let controlThumb = Color.white.opacity(0.14)
    /// Her tint: the cursor's blue.
    static let tint = DS.Colors.overlayCursorBlue
    /// While she's in control (hands-on, Chrome tasks).
    static let inControl = DS.Colors.overlayCursorAmber
}

// MARK: - Page

enum VesperPanelPage: String, CaseIterable {
    case home
    case settings

    var iconName: String {
        switch self {
        case .home: return "waveform"
        case .settings: return "slider.horizontal.3"
        }
    }

    var tooltip: String {
        switch self {
        case .home: return "Talk to Vesper"
        case .settings: return "Settings"
        }
    }
}

// MARK: - Header

/// Her glyph and name, what she's doing, and the page switcher.
struct VesperPanelHeader: View {
    let statusText: String
    let statusColor: Color
    let selectedPage: VesperPanelPage?
    let onSelectPage: (VesperPanelPage) -> Void
    @Namespace private var pageSwitcherNamespace

    var body: some View {
        HStack(spacing: 10) {
            VesperIslandTriangle()
                .fill(VesperPanelPalette.tint)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(-35))
                .shadow(color: VesperPanelPalette.tint.opacity(0.7), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("Vesper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if let selectedPage {
                HStack(spacing: 2) {
                    ForEach(VesperPanelPage.allCases, id: \.self) { page in
                        let isSelected = page == selectedPage
                        Button(action: { onSelectPage(page) }) {
                            Image(systemName: page.iconName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                                .frame(width: 30, height: 24)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(VesperPanelPalette.controlThumb)
                                            .matchedGeometryEffect(id: "selectedPage", in: pageSwitcherNamespace)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 7))
                        .pointerCursor()
                        .nativeTooltip(page.tooltip)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(VesperPanelPalette.controlTrack)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedPage)
            }
        }
        .padding(.horizontal, VesperPanelLayout.outerPadding + 2)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - Hero

/// The top of Home: what she's doing in words, and how to talk to her.
/// Turns amber with a Stop button while she's working on a task.
struct VesperPanelHero: View {
    let title: String
    let detail: String?
    let keyLabels: [String]
    let isActive: Bool
    /// Set while a task runs: "Working · step 3 of 30".
    let taskStatusText: String?
    let onStopTask: () -> Void

    private var accentColor: Color {
        taskStatusText != nil ? VesperPanelPalette.inControl : VesperPanelPalette.tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(isActive || taskStatusText != nil ? 0.22 : 0.12))
                    Circle()
                        .stroke(accentColor.opacity(0.35), lineWidth: 0.75)
                    VesperIslandTriangle()
                        .fill(accentColor)
                        .frame(width: 13, height: 13)
                        .rotationEffect(.degrees(-35))
                        .shadow(color: accentColor.opacity(0.8), radius: isActive ? 6 : 3)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(taskStatusText ?? title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if taskStatusText != nil {
                    Button(action: onStopTask) {
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(VesperPanelPalette.inControl))
                    }
                    .buttonStyle(VesperPanelPressableButtonStyle())
                    .pointerCursor()
                    .nativeTooltip("Stop right now (same as pressing the talk keys)")
                }
            }

            HStack(spacing: 5) {
                Text("Hold")
                ForEach(keyLabels, id: \.self) { keyLabel in
                    VesperPanelKeyCap(label: keyLabel)
                }
                Text("to talk")
                Text("·").foregroundColor(DS.Colors.textTertiary.opacity(0.6))
                ForEach(keyLabels, id: \.self) { keyLabel in
                    VesperPanelKeyCap(label: keyLabel)
                }
                VesperPanelKeyCap(label: "/")
                Text("to type")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VesperPanelLayout.cardCornerRadius + 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accentColor.opacity(0.13), accentColor.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: VesperPanelLayout.cardCornerRadius + 2, style: .continuous)
                .stroke(accentColor.opacity(0.18), lineWidth: 0.75)
        )
        .animation(.easeOut(duration: 0.25), value: taskStatusText)
    }
}

struct VesperPanelKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(minWidth: 18)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}

// MARK: - Groups and Rows

/// A titled card of settings rows, with an optional note under it.
struct VesperPanelGroup<Content: View>: View {
    let title: String?
    let footnote: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: VesperPanelLayout.cardCornerRadius, style: .continuous)
                    .fill(VesperPanelPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VesperPanelLayout.cardCornerRadius, style: .continuous)
                    .stroke(VesperPanelPalette.cardStroke, lineWidth: 0.5)
            )
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One line in a group: an icon, a title (and a small subtitle), and the
/// control on the right. `showsDivider` draws the hairline above it.
struct VesperPanelRow<TrailingContent: View>: View {
    let iconName: String
    let title: String
    let subtitle: String?
    let showsDivider: Bool
    @ViewBuilder let trailingContent: () -> TrailingContent

    init(
        iconName: String,
        title: String,
        subtitle: String? = nil,
        showsDivider: Bool = true,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.iconName = iconName
        self.title = title
        self.subtitle = subtitle
        self.showsDivider = showsDivider
        self.trailingContent = trailingContent
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(VesperPanelPalette.rowDivider)
                    .frame(height: 0.5)
                    .padding(.leading, 28)
            }
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                trailingContent()
            }
            .frame(minHeight: 38)
        }
    }
}

// MARK: - Controls

/// A segmented control whose selection slides between options.
struct VesperPanelSegmentedControl: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let tooltip: String?
    }

    let options: [Option]
    let selectedOptionID: String
    var isCompact: Bool = true
    /// The amber selection is for "she's in control" choices.
    var selectionColor: Color? = nil
    let onSelect: (String) -> Void
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option.id == selectedOptionID
                Button(action: { onSelect(option.id) }) {
                    Text(option.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .lineLimit(1)
                        .padding(.horizontal, isCompact ? 9 : 4)
                        .frame(maxWidth: isCompact ? nil : .infinity)
                        .frame(height: 22)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectionColor?.opacity(0.28) ?? VesperPanelPalette.controlThumb)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 6))
                .pointerCursor()
                .nativeTooltip(option.tooltip)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VesperPanelPalette.controlTrack)
        )
        // Never squeezed into "Q…": the row's text gives way instead.
        .fixedSize()
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selectedOptionID)
    }
}

/// A small switch in her tint. Drawn rather than the system Toggle, which
/// had to be scaled down and sat unevenly in the rows.
struct VesperPanelSwitch: View {
    let isOn: Bool
    var tooltip: String? = nil
    let onChange: (Bool) -> Void

    var body: some View {
        Button(action: { onChange(!isOn) }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? VesperPanelPalette.tint : Color.white.opacity(0.14))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        }
        .buttonStyle(VesperPanelPressableButtonStyle())
        .pointerCursor()
        .nativeTooltip(tooltip)
    }
}

/// A small bordered text button ("Edit", "Set up", "Choose").
struct VesperPanelSmallButton: View {
    let title: String
    var tooltip: String? = nil
    var color: Color = DS.Colors.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 6))
        .pointerCursor()
        .nativeTooltip(tooltip)
    }
}

/// A round icon button for the footer.
struct VesperPanelIconButton: View {
    let systemName: String
    let tooltip: String
    var color: Color = DS.Colors.textTertiary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 13))
        .pointerCursor()
        .nativeTooltip(tooltip)
    }
}

// MARK: - Usage

/// One Claude usage window as a slim bar: "5h  ▬▬▬───  23%".
struct VesperPanelUsageMeter: View {
    let label: String
    let fraction: Double?
    let tooltip: String?

    var body: some View {
        let clampedFraction = min(max(fraction ?? 0, 0), 1)
        let meterColor = clampedFraction >= 0.8 ? DS.Colors.warning : VesperPanelPalette.tint
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: max(geometry.size.width * clampedFraction, clampedFraction > 0 ? 3 : 0))
                }
            }
            .frame(width: 38, height: 3)
            Text(fraction == nil ? "–" : "\(Int((clampedFraction * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(clampedFraction >= 0.8 ? DS.Colors.warning : DS.Colors.textSecondary)
        }
        .nativeTooltip(tooltip)
    }
}

// MARK: - Recent

/// One past exchange: what they asked, and her answer underneath.
struct VesperPanelRecentRow: View {
    let userText: String
    let replyText: String
    let isShowingCopiedTick: Bool
    let onCopy: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if !userText.isEmpty {
                    Text(userText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                }
                if !replyText.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        VesperIslandTriangle()
                            .fill(VesperPanelPalette.tint)
                            .frame(width: 6, height: 6)
                            .rotationEffect(.degrees(-35))
                            .padding(.top, 4)
                        Text(replyText)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCopy) {
                Image(systemName: isShowingCopiedTick ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(isShowingCopiedTick ? DS.Colors.success : DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(VesperPanelPlainHoverButtonStyle(cornerRadius: 11))
            .pointerCursor()
            .nativeTooltip("Copy this exchange")
            .opacity(isHovered || isShowingCopiedTick ? 1 : 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.05 : 0))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }
}

// MARK: - Button Styles

/// No chrome of its own; a faint fill on hover and a small press.
struct VesperPanelPlainHoverButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.1 : (isHovered ? 0.06 : 0)))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

/// For controls that draw their own fill (switches, the Stop and send
/// buttons): a slight brighten on hover and a press.
struct VesperPanelPressableButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isHovered ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}
