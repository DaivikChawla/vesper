//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. The icon reflects Vesper's state:
//  solid when idle, with a dot while she's busy, outlined while resting.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    /// Posted when the panel opens and closes, so status that's only worth
    /// checking often while someone is looking at it can slow down otherwise.
    static let vesperPanelVisibilityChanged = Notification.Name("vesperPanelVisibilityChanged")
    /// Posted for ctrl+option+/: open the panel ready to type a question.
    static let vesperOpenPanelForTypedQuestion = Notification.Name("vesperOpenPanelForTypedQuestion")
    /// Posted once the panel is showing, so its "Type to Vesper" field takes focus.
    static let vesperFocusTypedQuestionField = Notification.Name("vesperFocusTypedQuestionField")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Escape closes the panel wherever focus is. Caught here rather than
    /// through cancelOperation, because a focused text field's editor
    /// handles Escape itself (as "complete") and it would never arrive.
    override func sendEvent(_ event: NSEvent) {
        let escapeKeyCode: UInt16 = 53
        if event.type == .keyDown && event.keyCode == escapeKeyCode {
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var openPanelForTypedQuestionObserver: NSObjectProtocol?
    private var menuBarIconStateCancellable: AnyCancellable?
    private var currentMenuBarIconStyle: MenuBarIconStyle?

    /// The three looks of the menu bar icon.
    private enum MenuBarIconStyle {
        /// Solid triangle — ready.
        case idle
        /// Solid triangle with a dot — listening, thinking or speaking.
        case busy
        /// Outlined triangle — the Claude subscription limit is reached.
        case resting
    }

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = VesperPanelLayout.panelWidth
    private let panelHeight: CGFloat = VesperPanelLayout.panelHeight

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        openPanelForTypedQuestionObserver = NotificationCenter.default.addObserver(
            forName: .vesperOpenPanelForTypedQuestion,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showPanelWithTypedQuestionFieldFocused()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = openPanelForTypedQuestionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        updateMenuBarIcon(to: .idle)
        button.action = #selector(statusItemClicked)
        button.target = self

        menuBarIconStateCancellable = companionManager.$voiceState
            .combineLatest(companionManager.$latestSubscriptionUsage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState, _ in
                guard let self else { return }
                if self.companionManager.isSubscriptionKnownToBeResting {
                    self.updateMenuBarIcon(to: .resting)
                } else {
                    self.updateMenuBarIcon(to: voiceState == .idle ? .idle : .busy)
                }
            }
    }

    private func updateMenuBarIcon(to menuBarIconStyle: MenuBarIconStyle) {
        guard menuBarIconStyle != currentMenuBarIconStyle else { return }
        currentMenuBarIconStyle = menuBarIconStyle
        let menuBarIcon = makeVesperMenuBarIcon(style: menuBarIconStyle)
        // Template images adapt to light/dark menu bars automatically.
        menuBarIcon.isTemplate = true
        statusItem?.button?.image = menuBarIcon
    }

    /// Draws Vesper's triangle as a menu bar icon. Uses the same shape
    /// and rotation as the on-screen cursor so the two match.
    private func makeVesperMenuBarIcon(style menuBarIconStyle: MenuBarIconStyle) -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch menuBarIconStyle {
        case .idle:
            path.fill()
        case .busy:
            path.fill()
            let activityDotDiameter: CGFloat = 4.5
            let activityDot = NSBezierPath(ovalIn: NSRect(
                x: iconSize - activityDotDiameter - 0.5,
                y: 0.5,
                width: activityDotDiameter,
                height: activityDotDiameter
            ))
            activityDot.fill()
        case .resting:
            path.lineWidth = 1.3
            path.lineJoinStyle = .round
            path.stroke()
        }

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
        NotificationCenter.default.post(name: .vesperPanelVisibilityChanged, object: nil, userInfo: ["isVisible": true])
    }

    /// ctrl+option+/: show the panel (it becomes key, so it can take
    /// typing without activating the app) and focus the question field.
    /// The focus request waits a moment so a panel created just now has
    /// its SwiftUI view, and the field's focus state, in place.
    private func showPanelWithTypedQuestionFieldFocused() {
        showPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: .vesperFocusTypedQuestionField, object: nil)
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        NotificationCenter.default.post(name: .vesperPanelVisibilityChanged, object: nil, userInfo: ["isVisible": false])
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon, but
        // keep it on the screen: an icon far to the right would otherwise
        // push the panel past the edge, and a short screen would cut off
        // its bottom.
        let screenVisibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let edgeMargin: CGFloat = 8
        let clampedPanelHeight = min(actualPanelHeight, screenVisibleFrame.height - gapBelowMenuBar - edgeMargin)
        let centeredPanelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginX = min(
            max(centeredPanelOriginX, screenVisibleFrame.minX + edgeMargin),
            screenVisibleFrame.maxX - panelWidth - edgeMargin
        )
        let panelOriginY = max(statusItemFrame.minY - clampedPanelHeight - gapBelowMenuBar, screenVisibleFrame.minY + edgeMargin)

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: clampedPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
