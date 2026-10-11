//
//  Draws every island state to PNGs, on a screen with a notch and on one
//  without, over a light and a dark menu bar — so the island's layout can
//  be checked without running the app (no windows, no permissions).
//

import AppKit
import SwiftUI

@main
struct IslandRenderHarness {
    @MainActor
    static func main() {
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/island-renders")
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let presentations: [(name: String, presentation: VesperIslandPresentation, tint: VesperIslandTint)] = [
            ("1-listening", .listening, .normal),
            ("2-thinking", .thinking, .normal),
            ("3-speaking-short", .speaking(caption: "file menu, top left.", stepText: nil, noticeText: nil), .normal),
            ("4-speaking-long", .speaking(caption: "that's the build log. the red line is a missing semicolon on line forty two, and the yellow ones are only warnings you can ignore for now.", stepText: nil, noticeText: nil), .normal),
            ("5-speaking-step", .speaking(caption: "then export, down here.", stepText: "2/3", noticeText: nil), .normal),
            ("6-speaking-notice", .speaking(caption: "got it, you like dark mode.", stepText: nil, noticeText: "noted: prefers dark mode"), .normal),
            ("7-speaking-compact", .speaking(caption: nil, stepText: nil, noticeText: nil), .normal),
            ("8-working", .working(activityText: "clicking \u{201C}compile\u{201D}", stepNumber: 3), .inControl),
            ("9-asking", .asking(questionText: "about to click send in slack: \u{201C}hi sam, can deliver by friday.\u{201D} want me to?", isListening: false, expiresAt: Date().addingTimeInterval(21)), .inControl),
            ("10-asking-listening", .asking(questionText: "send it?", isListening: true, expiresAt: Date().addingTimeInterval(12)), .inControl),
            ("11-notice-memory", .notice(text: "noted: works late on thursdays", kind: .memory), .normal),
            ("12-notice-error", .notice(text: "error: claude code isn't logged in", kind: .error), .normal),
            ("13-finished", .finished(didSucceed: true), .normal),
            ("14-welcome", .welcome(text: "hey, i'm vesper."), .normal),
            ("15-hint", .shortcutHint(beforeKeysText: "hold", afterKeysText: "and say hi"), .normal),
            ("16-resting", .speaking(caption: "i'm tapped out on your claude plan until 4:00 pm. i'll be here.", stepText: nil, noticeText: nil), .resting),
            ("17-guiding", .guiding(instructionText: "click \u{201C}export\u{201D}", stepNumber: 2), .normal),
        ]

        let screens: [(name: String, metrics: VesperIslandMetrics, menuBarHeight: CGFloat)] = [
            ("nonotch", .withoutNotch, 24),
            ("notch", VesperIslandMetrics(hasHardwareNotch: true, bandHeight: 32, centerGapWidth: 186), 32),
        ]

        for screen in screens {
            for menuBarStyle in ["light", "dark"] {
                var sceneRows: [AnyView] = []
                for entry in presentations {
                    let model = VesperIslandModel()
                    model.metrics = screen.metrics
                    model.presentation = entry.presentation
                    model.tint = entry.tint
                    model.isOut = true
                    model.microphoneLevel = 0.55
                    model.voiceLevel = 0.45

                    let scene = ZStack(alignment: .top) {
                        LinearGradient(
                            colors: menuBarStyle == "light"
                                ? [Color(red: 0.62, green: 0.72, blue: 0.86), Color(red: 0.86, green: 0.80, blue: 0.74)]
                                : [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.20, green: 0.14, blue: 0.22)],
                            startPoint: .top, endPoint: .bottom
                        )
                        // The menu bar.
                        Rectangle()
                            .fill(menuBarStyle == "light" ? Color.white.opacity(0.72) : Color.black.opacity(0.45))
                            .frame(height: screen.menuBarHeight)
                            .overlay(alignment: .leading) {
                                Text("  Xcode   File   Edit   View   Find   Navigate   Editor")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(menuBarStyle == "light" ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                        if screen.metrics.hasHardwareNotch {
                            // The camera housing, drawn where the real one is.
                            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                                .fill(Color.black)
                                .frame(width: screen.metrics.centerGapWidth, height: screen.metrics.bandHeight)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        VesperIslandView(model: model)
                    }
                    .frame(width: 640, height: 250)

                    sceneRows.append(AnyView(
                        scene
                            .frame(width: 640, height: 150, alignment: .top)
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                Text(entry.name)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.black.opacity(0.6))
                                    .padding(4)
                            }
                    ))

                    let renderer = ImageRenderer(content: scene)
                    renderer.scale = 2
                    guard let cgImage = renderer.cgImage else {
                        print("❌ couldn't render \(entry.name)")
                        continue
                    }
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    let pngData = bitmap.representation(using: .png, properties: [:])!
                    let fileURL = outputDirectory.appendingPathComponent("\(screen.name)-\(menuBarStyle)-\(entry.name).png")
                    try? pngData.write(to: fileURL)
                }

                // Every state on one sheet, top 150 pt of each.
                let contactSheet = VStack(spacing: 2) {
                    ForEach(0..<sceneRows.count, id: \.self) { rowIndex in
                        sceneRows[rowIndex]
                    }
                }
                .background(Color.gray)
                let sheetRenderer = ImageRenderer(content: contactSheet)
                sheetRenderer.scale = 1
                if let sheetImage = sheetRenderer.cgImage,
                   let sheetData = NSBitmapImageRep(cgImage: sheetImage).representation(using: .png, properties: [:]) {
                    try? sheetData.write(to: outputDirectory.appendingPathComponent("sheet-\(screen.name)-\(menuBarStyle).png"))
                }
            }
        }
        print("✅ rendered to \(outputDirectory.path)")
    }
}
