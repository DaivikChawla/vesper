//
//  VesperAttention.swift
//  leanring-buddy
//
//  Asks Accessibility what's at a point on screen — the element's name,
//  role and edges — without ever touching the main thread. Guided
//  walkthroughs use it so the whole of the button she's waiting on counts
//  as the target and her ring hugs its edges.
//
//  (It also used to power pointing-by-resting-the-pointer, replaced by
//  drawing on screen — see VesperSketch.)
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - What They Pointed At

/// What Accessibility says is under the pointer. Built on the probe's own
/// queue, so it belongs to no actor.
nonisolated struct VesperPointedElement: Equatable, Sendable {
    let role: String?
    /// "button", "link", "text" — the app's own words for what it is.
    let roleDescription: String?
    /// Its title, description or (for text) its words, cleaned and capped.
    let name: String?
    /// AppKit global coordinates (bottom-left origin).
    let globalFrame: CGRect
}

/// One thing the user pointed at while asking.
// MARK: - Asking Accessibility (off the main thread)

/// Finds the meaningful element under a point — a button, a link, a line
/// of text, a field, an image — in the app that owns the window there.
/// Runs on its own queue with a short timeout per request, so a slow app
/// never stalls the cursor. Never switches an app's accessibility tree on
/// (that slows Chromium and breaks some window animations): where there's
/// no tree, the brackets simply stay around the pointer.
nonisolated final class VesperAccessibilityPointProbe: @unchecked Sendable {
    static let shared = VesperAccessibilityPointProbe()

    private let probeQueue = DispatchQueue(label: "vesper.accessibility-point-probe", qos: .userInitiated)
    /// Each Accessibility request gives up after this long.
    private static let requestTimeoutSeconds: Float = 0.15

    /// Roles worth framing: what people point at and ask about.
    private static let meaningfulRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXSecureTextField", "AXStaticText", "AXImage", "AXCell", "AXRow", "AXTab",
        "AXSlider", "AXHeading", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
        "AXMenuBarItem", "AXDockItem", "AXValueIndicator", "AXProgressIndicator"
    ]

    /// `screenFrameInQuartzSpace` is the screen the point is on, in the
    /// same top-left-origin space Accessibility uses.
    func pointedElement(
        atQuartzPoint quartzPoint: CGPoint,
        screenFrameInQuartzSpace: CGRect,
        primaryScreenHeight: CGFloat
    ) async -> VesperPointedElement? {
        await withCheckedContinuation { (continuation: CheckedContinuation<VesperPointedElement?, Never>) in
            probeQueue.async {
                continuation.resume(returning: Self.findPointedElement(
                    atQuartzPoint: quartzPoint,
                    screenFrameInQuartzSpace: screenFrameInQuartzSpace,
                    primaryScreenHeight: primaryScreenHeight
                ))
            }
        }
    }

    private static func findPointedElement(
        atQuartzPoint quartzPoint: CGPoint,
        screenFrameInQuartzSpace: CGRect,
        primaryScreenHeight: CGFloat
    ) -> VesperPointedElement? {
        guard let owningProcessIdentifier = processIdentifierOfWindow(atQuartzPoint: quartzPoint) else { return nil }
        let applicationElement = AXUIElementCreateApplication(owningProcessIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, requestTimeoutSeconds)

        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(applicationElement, Float(quartzPoint.x), Float(quartzPoint.y), &hitElement) == .success,
              let hitElement else {
            return nil
        }

        let screenArea = screenFrameInQuartzSpace.width * screenFrameInQuartzSpace.height
        var candidateElement: AXUIElement? = hitElement
        // The element itself, or the nearest meaningful thing around it.
        for _ in 0..<6 {
            guard let currentElement = candidateElement else { break }
            let role = stringAttribute(kAXRoleAttribute, of: currentElement)
            if let quartzFrame = frame(of: currentElement),
               isUsefulFrame(quartzFrame, screenFrameInQuartzSpace: screenFrameInQuartzSpace, screenArea: screenArea) {
                let name = name(of: currentElement, role: role)
                let isMeaningful = role.map { meaningfulRoles.contains($0) } ?? false
                // A plain group counts only when it has a name of its own
                // (a card, a labelled section), and isn't huge.
                let isNamedGroup = (role == "AXGroup" || role == "AXList") && name != nil
                    && quartzFrame.width * quartzFrame.height <= screenArea * 0.08
                if isMeaningful || isNamedGroup {
                    let appKitFrame = CGRect(
                        x: quartzFrame.minX,
                        y: primaryScreenHeight - quartzFrame.maxY,
                        width: quartzFrame.width,
                        height: quartzFrame.height
                    )
                    return VesperPointedElement(
                        role: role,
                        roleDescription: stringAttribute(kAXRoleDescriptionAttribute, of: currentElement).map(cleanedText),
                        name: name,
                        globalFrame: appKitFrame
                    )
                }
            }
            candidateElement = parent(of: currentElement)
        }
        return nil
    }

    /// Something that can be framed: not a sliver, not most of the screen.
    private static func isUsefulFrame(_ quartzFrame: CGRect, screenFrameInQuartzSpace: CGRect, screenArea: CGFloat) -> Bool {
        quartzFrame.width >= 8 && quartzFrame.height >= 8
            && quartzFrame.width * quartzFrame.height <= screenArea * 0.2
            && quartzFrame.width <= screenFrameInQuartzSpace.width * 0.8
            && screenFrameInQuartzSpace.intersects(quartzFrame)
    }

    /// Its title or description; for text, its words. Never a password
    /// field's value.
    private static func name(of element: AXUIElement, role: String?) -> String? {
        var candidateNames = [
            stringAttribute(kAXTitleAttribute, of: element),
            stringAttribute(kAXDescriptionAttribute, of: element)
        ]
        let valueReadingRoles: Set<String> = ["AXStaticText", "AXButton", "AXLink", "AXMenuItem", "AXPopUpButton", "AXHeading", "AXCell"]
        if let role, valueReadingRoles.contains(role) {
            candidateNames.append(stringAttribute(kAXValueAttribute, of: element))
        }
        candidateNames.append(stringAttribute(kAXHelpAttribute, of: element))
        guard let firstName = candidateNames.compactMap({ $0 }).map(cleanedText).first(where: { !$0.isEmpty }) else { return nil }
        return firstName.count > 60 ? String(firstName.prefix(60)) + "…" : firstName
    }

    /// One line, no brackets (a name is on-screen text, never a tag).
    private static func cleanedText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        let text = (attributeValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (parentValue as! AXUIElement)
    }

    /// The app owning the frontmost visible window at a point, skipping
    /// Vesper's own windows (her overlay covers every screen).
    private static func processIdentifierOfWindow(atQuartzPoint quartzPoint: CGPoint) -> pid_t? {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for windowInfo in windowInfoList {
            guard let ownerProcessIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessIdentifier != ownProcessIdentifier,
                  (windowInfo[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let windowBoundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: windowBoundsDictionary),
                  windowBounds.contains(quartzPoint) else {
                continue
            }
            return ownerProcessIdentifier
        }
        return nil
    }
}
