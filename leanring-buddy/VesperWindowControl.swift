//
//  VesperWindowControl.swift
//  leanring-buddy
//
//  Window and app management quick actions:
//  - [WINDOW:left-half|right-half|fullscreen|center|next-screen] moves and
//    resizes the front window (or, with " | app", that app's window)
//    through Accessibility, which Vesper already has.
//  - [HIDE:app], [FOCUS:app] and [QUIT:app] act on running apps. Quitting
//    is always the normal kind, never a force quit, so the app's own
//    "save changes?" prompts still appear.
//
//  App names resolve against running apps: an exact name first, then one
//  whose name contains every word. Quitting takes an exact or unique
//  match only, so a loose name can never quit the wrong app.
//

import AppKit
import ApplicationServices
import Foundation

enum VesperWindowControl {
    /// Runs one window or app action. Returns a line to say if it failed.
    static func perform(_ windowOrApplicationAction: VesperAction) async -> String? {
        switch windowOrApplicationAction {
        case .arrangeWindow(let arrangement, let applicationName):
            return arrangeWindow(arrangement, applicationName: applicationName)
        case .hideApplication(let applicationName):
            return hideApplication(named: applicationName)
        case .focusApplication(let applicationName):
            return await focusApplication(named: applicationName)
        case .quitApplication(let applicationName):
            return quitApplication(named: applicationName)
        default:
            return nil
        }
    }

    // MARK: - Frame Math (pure, tested in scripts/computer-control-test)

    /// Where the window should go, in AppKit coordinates (origin at the
    /// bottom-left of the main screen). `screenVisibleFrames` are each
    /// screen's area without the menu bar and Dock, in NSScreen order.
    /// Nil when there's nowhere to put it.
    static func targetWindowFrame(
        for arrangement: VesperWindowArrangement,
        currentWindowFrame: CGRect,
        screenVisibleFrames: [CGRect]
    ) -> CGRect? {
        guard let currentScreenIndex = indexOfScreen(containing: currentWindowFrame, screenFrames: screenVisibleFrames) else {
            return nil
        }
        let visibleFrame = screenVisibleFrames[currentScreenIndex]
        switch arrangement {
        case .leftHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: (visibleFrame.width / 2).rounded(.down), height: visibleFrame.height)
        case .rightHalf:
            let halfWidth = (visibleFrame.width / 2).rounded(.down)
            return CGRect(x: visibleFrame.maxX - halfWidth, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .fullscreen:
            return visibleFrame
        case .center:
            return centeredFrame(ofSize: currentWindowFrame.size, in: visibleFrame)
        case .nextScreen:
            guard screenVisibleFrames.count > 1 else { return nil }
            let nextVisibleFrame = screenVisibleFrames[(currentScreenIndex + 1) % screenVisibleFrames.count]
            // Same place and share of the screen, on the next one, so a
            // left half stays a left half.
            let relativeX = (currentWindowFrame.minX - visibleFrame.minX) / max(visibleFrame.width, 1)
            let relativeY = (currentWindowFrame.minY - visibleFrame.minY) / max(visibleFrame.height, 1)
            let relativeWidth = min(currentWindowFrame.width / max(visibleFrame.width, 1), 1)
            let relativeHeight = min(currentWindowFrame.height / max(visibleFrame.height, 1), 1)
            let movedFrame = CGRect(
                x: nextVisibleFrame.minX + relativeX * nextVisibleFrame.width,
                y: nextVisibleFrame.minY + relativeY * nextVisibleFrame.height,
                width: relativeWidth * nextVisibleFrame.width,
                height: relativeHeight * nextVisibleFrame.height
            ).integral
            return clamped(movedFrame, into: nextVisibleFrame)
        }
    }

    /// The screen the window mostly sits on; nil if it's on none of them.
    static func indexOfScreen(containing windowFrame: CGRect, screenFrames: [CGRect]) -> Int? {
        var bestScreenIndex: Int?
        var bestOverlapArea: CGFloat = 0
        for (screenIndex, screenFrame) in screenFrames.enumerated() {
            let overlap = screenFrame.intersection(windowFrame)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            if overlapArea > bestOverlapArea {
                bestOverlapArea = overlapArea
                bestScreenIndex = screenIndex
            }
        }
        // A window entirely off every screen goes to the first one.
        return bestScreenIndex ?? (screenFrames.isEmpty ? nil : 0)
    }

    static func centeredFrame(ofSize windowSize: CGSize, in visibleFrame: CGRect) -> CGRect {
        let fittedWidth = min(windowSize.width, visibleFrame.width)
        let fittedHeight = min(windowSize.height, visibleFrame.height)
        return CGRect(
            x: (visibleFrame.midX - fittedWidth / 2).rounded(),
            y: (visibleFrame.midY - fittedHeight / 2).rounded(),
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private static func clamped(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        let clampedWidth = min(frame.width, visibleFrame.width)
        let clampedHeight = min(frame.height, visibleFrame.height)
        let clampedX = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - clampedWidth)
        let clampedY = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - clampedHeight)
        return CGRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    /// Accessibility measures from the top-left of the main screen (the
    /// first NSScreen, not NSScreen.main), y growing downward; AppKit from
    /// its bottom-left, y growing upward. The same flip works both ways.
    static func flippedBetweenAppKitAndAccessibility(_ frame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: - App Name Matching (pure)

    /// Which of the running apps' names the request means: an exact name
    /// (ignoring case and ".app"), otherwise one containing every word of
    /// the request. With `requiresUniqueMatch`, several word matches are
    /// ambiguous and nothing is chosen; otherwise the shortest name wins
    /// ("chrome" → Google Chrome over Chrome Remote Desktop).
    static func indexOfApplication(named requestedName: String, amongApplicationNames applicationNames: [String], requiresUniqueMatch: Bool) -> Int? {
        var normalizedRequestedName = requestedName.trimmingCharacters(in: .whitespaces).lowercased()
        if normalizedRequestedName.hasSuffix(".app") {
            normalizedRequestedName = String(normalizedRequestedName.dropLast(4))
        }
        guard !normalizedRequestedName.isEmpty else { return nil }
        let lowercasedApplicationNames = applicationNames.map { $0.lowercased() }
        if let exactMatchIndex = lowercasedApplicationNames.firstIndex(of: normalizedRequestedName) {
            return exactMatchIndex
        }
        let requestedWords = normalizedRequestedName.split(separator: " ").map(String.init)
        let wordMatchIndices = lowercasedApplicationNames.indices.filter { applicationIndex in
            let applicationWords = Set(lowercasedApplicationNames[applicationIndex].split(separator: " ").map(String.init))
            return requestedWords.allSatisfy(applicationWords.contains)
        }
        if requiresUniqueMatch {
            return wordMatchIndices.count == 1 ? wordMatchIndices[0] : nil
        }
        return wordMatchIndices.min { lowercasedApplicationNames[$0].count < lowercasedApplicationNames[$1].count }
    }

    // MARK: - Running Apps

    /// Apps with a Dock icon, never Vesper herself.
    private static func userFacingRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { runningApplication in
            runningApplication.activationPolicy == .regular
                && runningApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && runningApplication.localizedName != nil
        }
    }

    /// For the fast lane: whether an app by that name is running (and, for
    /// quitting, unambiguous), so the request can skip Claude.
    static func isApplicationRunning(named applicationName: String, requiresUniqueMatch: Bool) -> Bool {
        runningApplication(named: applicationName, requiresUniqueMatch: requiresUniqueMatch) != nil
    }

    private static func runningApplication(named applicationName: String, requiresUniqueMatch: Bool) -> NSRunningApplication? {
        let runningApplications = userFacingRunningApplications()
        let runningApplicationNames = runningApplications.map { $0.localizedName ?? "" }
        if let matchIndex = indexOfApplication(named: applicationName, amongApplicationNames: runningApplicationNames, requiresUniqueMatch: requiresUniqueMatch) {
            return runningApplications[matchIndex]
        }
        // An app's file name can differ from the name it shows (the
        // request might use either), so try the installed app's file too.
        guard !requiresUniqueMatch,
              let installedApplicationURL = VesperApplicationLocator.applicationURL(named: applicationName) else { return nil }
        return runningApplications.first { $0.bundleURL?.standardizedFileURL == installedApplicationURL.standardizedFileURL }
    }

    private static func hideApplication(named applicationName: String) -> String? {
        guard let runningApplication = runningApplication(named: applicationName, requiresUniqueMatch: false) else {
            return "\(applicationName.lowercased()) isn't open."
        }
        print("🪟 Hide \(runningApplication.localizedName ?? applicationName)")
        runningApplication.hide()
        return nil
    }

    /// `open -a` with the app's full path: it brings a running app forward
    /// and opens one that isn't. Asking the app to activate itself can be
    /// ignored when the request comes from a menu bar app like Vesper.
    private static func focusApplication(named applicationName: String) async -> String? {
        let applicationURL = runningApplication(named: applicationName, requiresUniqueMatch: false)?.bundleURL
            ?? VesperApplicationLocator.applicationURL(named: applicationName)
        guard let applicationURL else {
            return "i couldn't find an app called \(applicationName.lowercased())."
        }
        print("🪟 Focus \(applicationURL.lastPathComponent)")
        let openResult = await VesperProcessRunner.run(executablePath: "/usr/bin/open", arguments: ["-a", applicationURL.path])
        return openResult.exitStatus == 0 ? nil : "\(applicationName.lowercased()) wouldn't come forward."
    }

    private static func quitApplication(named applicationName: String) -> String? {
        guard let runningApplication = runningApplication(named: applicationName, requiresUniqueMatch: true) else {
            return "i'm not sure which app you mean by \(applicationName.lowercased()), so i left everything open."
        }
        // Finder relaunches itself and has no normal quit; not worth trying.
        if runningApplication.bundleIdentifier == "com.apple.finder" {
            return "finder doesn't quit."
        }
        print("🪟 Quit \(runningApplication.localizedName ?? applicationName)")
        // A normal quit: unsaved work gets the app's own save prompt.
        return runningApplication.terminate() ? nil : "\(applicationName.lowercased()) didn't want to quit."
    }

    // MARK: - Moving Windows (Accessibility)

    private static func arrangeWindow(_ arrangement: VesperWindowArrangement, applicationName: String?) -> String? {
        let targetApplication: NSRunningApplication?
        if let applicationName {
            targetApplication = runningApplication(named: applicationName, requiresUniqueMatch: false)
        } else {
            targetApplication = NSWorkspace.shared.frontmostApplication
        }
        guard let targetApplication,
              targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return applicationName.map { "\($0.lowercased()) isn't open." } ?? "there's no window in front to move."
        }

        let applicationElement = AXUIElementCreateApplication(targetApplication.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.5)
        guard let windowElement = elementAttribute(kAXFocusedWindowAttribute, of: applicationElement)
                ?? elementAttribute(kAXMainWindowAttribute, of: applicationElement),
              let windowPosition = pointAttribute(kAXPositionAttribute, of: windowElement),
              let windowSize = sizeAttribute(kAXSizeAttribute, of: windowElement),
              let mainScreenHeight = NSScreen.screens.first?.frame.height else {
            return "i couldn't get hold of that window."
        }

        let currentAppKitFrame = flippedBetweenAppKitAndAccessibility(
            CGRect(origin: windowPosition, size: windowSize),
            mainScreenHeight: mainScreenHeight
        )
        guard let targetAppKitFrame = targetWindowFrame(
            for: arrangement,
            currentWindowFrame: currentAppKitFrame,
            screenVisibleFrames: NSScreen.screens.map(\.visibleFrame)
        ) else {
            return arrangement == .nextScreen ? "there's only one screen." : "i couldn't work out where to put it."
        }
        let targetAccessibilityFrame = flippedBetweenAppKitAndAccessibility(targetAppKitFrame, mainScreenHeight: mainScreenHeight)
        print("🪟 Window \(arrangement.rawValue) for \(targetApplication.localizedName ?? "app"): \(currentAppKitFrame) → \(targetAppKitFrame)")

        // Size, position, then size again: many apps clamp a new size to
        // the screen the window is on right now, so moving between screens
        // needs the second pass.
        let didSetFirstSize = setSize(targetAccessibilityFrame.size, of: windowElement)
        let didSetPosition = setPosition(targetAccessibilityFrame.origin, of: windowElement)
        let didSetFinalSize = setSize(targetAccessibilityFrame.size, of: windowElement)
        guard didSetPosition && (didSetFirstSize || didSetFinalSize) else {
            // Full-screen Spaces and fixed-size windows refuse.
            return "that window wouldn't move."
        }
        return nil
    }

    private static func elementAttribute(_ attributeName: String, of element: AXUIElement) -> AXUIElement? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    private static func pointAttribute(_ attributeName: String, of element: AXUIElement) -> CGPoint? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(attributeValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ attributeName: String, of element: AXUIElement) -> CGSize? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(attributeValue as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func setPosition(_ position: CGPoint, of windowElement: AXUIElement) -> Bool {
        var mutablePosition = position
        guard let positionValue = AXValueCreate(.cgPoint, &mutablePosition) else { return false }
        return AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue) == .success
    }

    private static func setSize(_ size: CGSize, of windowElement: AXUIElement) -> Bool {
        var mutableSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return false }
        return AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue) == .success
    }
}
