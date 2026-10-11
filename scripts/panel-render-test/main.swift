//
//  Draws the menu bar panel's pages to PNGs with mock data, so its layout
//  can be checked without running the app. It mirrors CompanionPanelView's
//  structure with the same VesperPanelComponents (the real view needs
//  CompanionManager). Rendered through an offscreen NSHostingView, so the
//  AppKit tooltip and cursor helpers draw as they do in the app. No window
//  is ever shown and no permissions are used.
//

import AppKit
import SwiftUI

struct MockRecentExchange: Identifiable {
    let id = UUID()
    let userText: String
    let replyText: String
}

let mockRecentExchanges = [
    MockRecentExchange(userText: "what's this error in the terminal?", replyText: "a missing semicolon on line 42 — the red line. the yellow ones are only warnings."),
    MockRecentExchange(userText: "open youtube and play lofi", replyText: "on it. playing lofi hip hop radio in chrome."),
    MockRecentExchange(userText: "set a timer for ten minutes for pasta", replyText: "ten minutes for pasta, starting now."),
    MockRecentExchange(userText: "how do i export this as a pdf", replyText: "file menu, top left, then export as pdf near the bottom."),
    MockRecentExchange(userText: "what's the weather tomorrow", replyText: "18 and cloudy in london, light rain after four."),
]

struct MockPanelPage: View {
    let page: VesperPanelPage
    let isTaskRunning: Bool
    let heardText: String
    let recentExchanges: [MockRecentExchange]
    let isTurboOn: Bool
    let showsSettingsUnscrolled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VesperPanelHeader(
                statusText: isTaskRunning ? "Working" : "Ready",
                statusColor: isTaskRunning ? VesperPanelPalette.inControl : DS.Colors.success,
                selectedPage: page,
                onSelectPage: { _ in }
            )
            Group {
                switch page {
                case .home: home
                case .settings: settings
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: VesperPanelLayout.panelWidth, height: showsSettingsUnscrolled ? nil : VesperPanelLayout.panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(VesperPanelPalette.background)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        )
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 12) {
            VesperPanelHero(
                title: "Ready when you are",
                detail: "Heard \u{201C}\(heardText)\u{201D}",
                keyLabels: ["⌃", "⌥"],
                isActive: false,
                taskStatusText: isTaskRunning ? "Working · step 3 of 30" : nil,
                onStopTask: {}
            )
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Ask Vesper…")
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(VesperPanelPalette.cardStroke, lineWidth: 0.5))

            VesperPanelGroup(footnote: isTurboOn ? "Clicks and types for you · Turbo: never asks first" : "Clicks and types for you · asks before risky steps") {
                VesperPanelRow(iconName: "hand.point.up.left", title: "Control", showsDivider: false) {
                    VesperPanelSegmentedControl(
                        options: [.init(id: "off", title: "Off", tooltip: nil), .init(id: "quick", title: "Quick", tooltip: nil), .init(id: "hands", title: "Hands-on", tooltip: nil)],
                        selectedOptionID: "hands",
                        selectionColor: VesperPanelPalette.inControl,
                        onSelect: { _ in }
                    )
                }
                VesperPanelRow(iconName: isTurboOn ? "bolt.fill" : "checkmark.shield", title: "Pace") {
                    VesperPanelSegmentedControl(
                        options: [.init(id: "careful", title: "Careful", tooltip: nil), .init(id: "turbo", title: "Turbo", tooltip: nil)],
                        selectedOptionID: isTurboOn ? "turbo" : "careful",
                        selectionColor: isTurboOn ? VesperPanelPalette.inControl : nil,
                        onSelect: { _ in }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("RECENT")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "plus.bubble").font(.system(size: 9.5, weight: .semibold))
                        Text("New conversation").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                }
                .padding(.leading, 4)
                if recentExchanges.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
                        Text("Your conversation shows up here.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(recentExchanges) { exchange in
                                VesperPanelRecentRow(userText: exchange.userText, replyText: exchange.replyText, isShowingCopiedTick: false, onCopy: {})
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 12) {
                VesperPanelUsageMeter(label: "5h", fraction: 0.23, tooltip: nil)
                VesperPanelUsageMeter(label: "Week", fraction: 0.84, tooltip: nil)
                Spacer()
                VesperPanelIconButton(systemName: "power", tooltip: "Quit Vesper") {}
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, VesperPanelLayout.outerPadding)
        .padding(.bottom, 12)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VesperPanelGroup(title: "Claude", footnote: "Plan usage — 5-hour: 23% · resets 4:00 PM. Weekly: 84% · resets Mon 9:00 AM.") {
                VesperPanelRow(iconName: "sparkle", title: "Model", subtitle: "Sonnet is fastest", showsDivider: false) {
                    VesperPanelSegmentedControl(options: [.init(id: "s", title: "Sonnet", tooltip: nil), .init(id: "o", title: "Opus", tooltip: nil)], selectedOptionID: "s", onSelect: { _ in })
                }
                VesperPanelRow(iconName: "globe", title: "Web research", subtitle: "~15k tokens per lookup") {
                    VesperPanelSwitch(isOn: true, onChange: { _ in })
                }
                VesperPanelRow(iconName: "brain", title: "Memory", subtitle: "7 notes") {
                    VesperPanelSmallButton(title: "Edit") {}
                }
            }
            VesperPanelGroup(title: "Voice", footnote: "Google: ready · 12,340 of 950,000 characters this month\nKokoro: loaded\nLast spoke: Google (0.42 s)") {
                VesperPanelRow(iconName: "waveform", title: "Voice", showsDivider: false) {
                    VesperPanelSegmentedControl(options: [.init(id: "a", title: "Auto", tooltip: nil), .init(id: "g", title: "Google", tooltip: nil), .init(id: "k", title: "Kokoro", tooltip: nil)], selectedOptionID: "a", onSelect: { _ in })
                }
                VesperPanelRow(iconName: "person.wave.2", title: "Google voice") {
                    Text("en-US-Chirp3-HD-Aoede").font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                }
                VesperPanelRow(iconName: "key", title: "Google API key", subtitle: "Saved in your Keychain") {
                    VesperPanelSmallButton(title: "Remove") {}
                }
            }
            VesperPanelGroup(title: "Doing things", footnote: "She can also click, type and press keys, step by step. Your talk keys stop her.") {
                VesperPanelRow(iconName: "checkmark.shield", title: "Pace", showsDivider: false) {
                    VesperPanelSegmentedControl(options: [.init(id: "careful", title: "Careful", tooltip: nil), .init(id: "turbo", title: "Turbo", tooltip: nil)], selectedOptionID: "careful", onSelect: { _ in })
                }
                VesperPanelRow(iconName: "list.number", title: "Max steps per task") {
                    Text("30").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                }
                VesperPanelRow(iconName: "square.stack.3d.up", title: "Shortcuts", subtitle: "2 allowed") {
                    VesperPanelSmallButton(title: "Choose") {}
                }
            }
            VesperPanelGroup(title: "Listening", footnote: "Voiceprint saved for MacBook Air Microphone") {
                VesperPanelRow(iconName: "ear", title: "Listen for my answer", subtitle: "Mic stays open after her questions", showsDivider: false) {
                    VesperPanelSwitch(isOn: true, onChange: { _ in })
                }
                VesperPanelRow(iconName: "person.wave.2.fill", title: "Only my voice", subtitle: "Ignores anyone who isn't you") {
                    HStack(spacing: 8) {
                        VesperPanelSmallButton(title: "Redo") {}
                        VesperPanelSwitch(isOn: false, onChange: { _ in })
                    }
                }
            }
            VesperPanelGroup(title: "On screen") {
                VesperPanelRow(iconName: "captions.bubble", title: "Captions", subtitle: "Her words in the island", showsDivider: false) {
                    VesperPanelSwitch(isOn: true, onChange: { _ in })
                }
                VesperPanelRow(iconName: "cursorarrow", title: "Always show cursor", subtitle: "Off: only while you talk") {
                    VesperPanelSwitch(isOn: true, onChange: { _ in })
                }
            }
        }
        .padding(.horizontal, VesperPanelLayout.outerPadding)
        .padding(.top, 2)
        .padding(.bottom, 16)
    }
}

@MainActor
func renderToPNG<Content: View>(_ content: Content, size: CGSize, path: String) {
    let hostingView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
    hostingView.frame = CGRect(origin: .zero, size: size)
    let offscreenWindow = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    offscreenWindow.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    // Let SwiftUI finish its first layout pass.
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
    try? pngData.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

@main
struct PanelRenderHarness {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/panel-renders"
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let backdrop = Color(red: 0.2, green: 0.22, blue: 0.28)
        let panelSize = CGSize(width: VesperPanelLayout.panelWidth + 40, height: VesperPanelLayout.panelHeight + 40)

        func scene<Content: View>(_ content: Content) -> some View {
            ZStack { backdrop; content }
        }

        renderToPNG(scene(MockPanelPage(page: .home, isTaskRunning: false, heardText: "what's this error in the terminal and how do i fix it before the deadline tonight", recentExchanges: mockRecentExchanges, isTurboOn: false, showsSettingsUnscrolled: false)), size: panelSize, path: outputDirectory + "/1-home.png")
        renderToPNG(scene(MockPanelPage(page: .home, isTaskRunning: true, heardText: "compile and run this", recentExchanges: Array(mockRecentExchanges.prefix(2)), isTurboOn: true, showsSettingsUnscrolled: false)), size: panelSize, path: outputDirectory + "/2-home-task-turbo.png")
        renderToPNG(scene(MockPanelPage(page: .home, isTaskRunning: false, heardText: "hi", recentExchanges: [], isTurboOn: false, showsSettingsUnscrolled: false)), size: panelSize, path: outputDirectory + "/3-home-empty.png")
        renderToPNG(scene(MockPanelPage(page: .settings, isTaskRunning: false, heardText: "", recentExchanges: [], isTurboOn: false, showsSettingsUnscrolled: true)), size: CGSize(width: panelSize.width, height: 900), path: outputDirectory + "/4-settings-full.png")
    }
}
