//
//  VesperActionSafety.swift
//  leanring-buddy
//
//  The checks that run before every hands-on action, enforced by Vesper
//  herself rather than left to what Claude decides:
//
//  - Before a click, the element under the pointer is read through the
//    Accessibility API. If it (or Claude's own label for it) looks like
//    send / post / buy / pay / delete and friends, she asks first.
//  - Return in anything that isn't clearly a one-line field (a chat box,
//    a message, or an app she can't see into) asks first, because that's
//    how most chat apps send. So do cmd+return and delete shortcuts.
//  - She never types into a password field.
//
//  This is a safety net, not a guarantee: an icon-only button in an app
//  that exposes nothing to Accessibility can still slip past it, which is
//  why Claude's own label is checked too.
//

import AppKit
import ApplicationServices
import Foundation

/// What the Accessibility API says about one on-screen element.
struct VesperInspectedElement: Equatable {
    let role: String?
    let subrole: String?
    /// Titles, descriptions and (for buttons and labels) values of the
    /// element and its enclosing button or link, if any.
    let describingTexts: [String]
    let applicationBundleIdentifier: String?

    var isSecureTextField: Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// A button, link or similar control — pressing Space or Return on it
    /// while it has focus is the same as clicking it.
    var isPressableControl: Bool {
        guard let role else { return false }
        return ["AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton"].contains(role)
    }

    /// Somewhere typing puts text, rather than triggering shortcuts.
    var isTextEntry: Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"].contains(role)
            || subrole == "AXSearchField"
    }

    /// A search box or a browser's address bar, where Return searches or
    /// loads a page rather than sending a message or submitting a form.
    var isSearchOrAddressField: Bool {
        guard !isSecureTextField, let role else { return false }
        if subrole == "AXSearchField" || role == "AXSearchField" || role == "AXComboBox" {
            return true
        }
        guard role == "AXTextField" else { return false }
        return describingTexts.contains { describingText in
            let lowercasedText = describingText.lowercased()
            return ["search", "find", "address", "url", "location", "go to"].contains { lowercasedText.contains($0) }
        }
    }
}

protocol VesperScreenElementInspecting: AnyObject {
    func inspectElement(atAppKitGlobalPoint appKitGlobalPoint: CGPoint) async -> VesperInspectedElement?
    func inspectFocusedElement() async -> VesperInspectedElement?
}

/// A hands-on action with its screenshot coordinates already mapped to
/// real screen positions.
enum VesperResolvedScreenAction: Equatable {
    case click(appKitGlobalPoint: CGPoint, elementLabel: String?, clickKind: VesperClickKind)
    case typeText(String)
    case pressKeys(String)
    case scroll(direction: VesperScrollDirection, appKitGlobalPoint: CGPoint?)
    case waitForScreen(seconds: Double)

    /// Short past-tense description for the step log Claude sees.
    var performedDescription: String {
        switch self {
        case .click(_, let elementLabel, let clickKind):
            let clickVerb = clickKind == .double ? "double-clicked" : (clickKind == .right ? "right-clicked" : "clicked")
            return "\(clickVerb) \(elementLabel ?? "something")"
        case .typeText(let typedText):
            return "typed \"\(typedText.count > 60 ? String(typedText.prefix(60)) + "…" : typedText)\""
        case .pressKeys(let keyCombinationText):
            return "pressed \(keyCombinationText)"
        case .scroll(let direction, _):
            return "scrolled \(direction.rawValue)"
        case .waitForScreen(let seconds):
            return "waited \(Int(seconds))s for it to load"
        }
    }

    /// What she's doing right now, for the island: "clicking “compile”".
    var islandActivityText: String {
        switch self {
        case .click(_, let elementLabel, let clickKind):
            let clickVerb = clickKind == .double ? "double-clicking" : (clickKind == .right ? "right-clicking" : "clicking")
            guard let elementLabel, !elementLabel.isEmpty else { return clickVerb }
            return "\(clickVerb) \u{201C}\(elementLabel)\u{201D}"
        case .typeText(let typedText):
            let shownText = typedText.count > 40 ? String(typedText.prefix(40)) + "…" : typedText
            return "typing \u{201C}\(shownText)\u{201D}"
        case .pressKeys(let keyCombinationText):
            return "pressing \(keyCombinationText)"
        case .scroll(let direction, _):
            return "scrolling \(direction.rawValue)"
        case .waitForScreen:
            return "waiting for it to load"
        }
    }
}

enum VesperActionSafetyDecision: Equatable {
    case allowed
    /// She asks out loud first. `spokenQuestion` is what she says.
    case needsConfirmation(spokenQuestion: String)
    /// She won't do it at all, and says why.
    case refused(spokenReason: String)
    /// Not something she can do (e.g. an unknown key) — skipped, and the
    /// next screenshot shows Claude nothing changed.
    case skipped(reason: String)
}

/// What the step runner knows around one action, beyond the action itself.
struct VesperActionSafetyContext {
    /// The last text typed earlier in this step — what a Return would send.
    var textTypedEarlierInStep: String?
    /// For the first terminal action in a step: what it and the rest of the
    /// step would do there, read out in the question ("type 'ls', then
    /// press return").
    var terminalCommandPreview: String?
    /// True once the user has said yes to running this step's command in a
    /// terminal — the rest of the step's typing and keys there don't ask again.
    var isTerminalCommandApproved = false
    /// Whether a web address typed into an address bar may open without
    /// asking (the same rule as [OPEN:...]).
    var isWebsiteSafeToOpenWithoutAsking: (URL) -> Bool = { _ in false }
}

enum VesperActionSafetyPolicy {
    /// Words that mark an action as consequential: sending, publishing,
    /// spending, deleting, agreeing to something, or granting access.
    private static let consequentialWordsPattern = try! NSRegularExpression(
        pattern: #"\b(send|sent|post|publish|submit|tweet|reply all|share|buy|purchase|pay|payment|order|checkout|check out|subscribe|unsubscribe|donate|transfer|withdraw|delete|remove|erase|trash|discard|confirm|accept|decline|agree|sign up|install|uninstall|authorize|authorise|allow|grant|approve|merge|sign out|log out|open anyway|revoke|block|report)\b"#,
        options: [.caseInsensitive]
    )

    /// Terminals and apps that run scripts: typing there can run a command,
    /// and in a terminal app like Claude Code a single typed "1" answers a
    /// prompt — so a step's typing and keys there ask once, first.
    static let commandRunningApplicationBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts"
    ]
    /// Code editors whose built-in terminal is detected by its name.
    private static let codeEditorBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed"
    ]

    /// Shortcuts that only navigate, edit text or change the view — safe to
    /// press without asking. Anything with cmd, ctrl or option that isn't
    /// here asks first.
    private static let safeModifierShortcuts: Set<String> = {
        var shortcuts: Set<String> = []
        for keyName in ["l", "t", "n", "f", "g", "c", "v", "x", "a", "z", "s", "w", "r", "b", "i", "u", "k",
                        "[", "]", "=", "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                        "left", "right", "up", "down", "tab", "`"] {
            shortcuts.insert("command+\(keyName)")
        }
        for keyName in ["z", "t", "[", "]", "g", "tab"] {
            shortcuts.insert("command+shift+\(keyName)")
        }
        for keyName in ["left", "right", "up", "down"] {
            shortcuts.insert("command+option+\(keyName)")
            shortcuts.insert("option+\(keyName)")
            shortcuts.insert("option+shift+\(keyName)")
            shortcuts.insert("command+shift+\(keyName)")
        }
        // Emacs-style caret moves every Mac text field understands, and tab switching.
        for keyName in ["a", "e", "b", "f", "n", "p", "tab"] {
            shortcuts.insert("control+\(keyName)")
        }
        shortcuts.insert("control+shift+tab")
        // Lock screen: harmless, and asked for by name ("lock my screen").
        shortcuts.insert("command+control+q")
        return shortcuts
    }()

    static func isConsequential(_ text: String) -> Bool {
        consequentialWordsPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isCommandRunningContext(_ inspectedElement: VesperInspectedElement?) -> Bool {
        guard let inspectedElement, let bundleIdentifier = inspectedElement.applicationBundleIdentifier else { return false }
        if commandRunningApplicationBundleIdentifiers.contains(bundleIdentifier) { return true }
        // A code editor's own terminal panel names itself ("Terminal 1, zsh").
        return codeEditorBundleIdentifiers.contains(bundleIdentifier)
            && inspectedElement.describingTexts.contains { describingText in describingText.lowercased().contains("terminal") }
    }

    static func decision(
        for resolvedAction: VesperResolvedScreenAction,
        elementUnderClick: VesperInspectedElement?,
        focusedElement: VesperInspectedElement?,
        context: VesperActionSafetyContext = VesperActionSafetyContext()
    ) -> VesperActionSafetyDecision {
        switch resolvedAction {
        case .click(_, let elementLabel, _):
            let accessibilityTexts = elementUnderClick?.describingTexts ?? []
            if elementUnderClick != nil && accessibilityTexts.isEmpty {
                // Logged so the icon-only rule can be decided from real data.
                print("🔎 Click on an element with no Accessibility text (\(elementUnderClick?.role ?? "?")) — judged by the label \"\(elementLabel ?? "")\"")
            }
            let consequentialAccessibilityText = accessibilityTexts.first(where: { candidateText in isConsequential(candidateText) })
            let isLabelConsequential = elementLabel.map { candidateText in isConsequential(candidateText) } ?? false
            guard consequentialAccessibilityText != nil || isLabelConsequential else { return .allowed }
            let spokenTarget = spokenClickTarget(
                accessibilityText: consequentialAccessibilityText ?? accessibilityTexts.first,
                elementLabel: elementLabel,
                applicationBundleIdentifier: elementUnderClick?.applicationBundleIdentifier
            )
            return .needsConfirmation(spokenQuestion: "about to click \(spokenTarget). say yes and i'll do it, or tell me what to change.")

        case .typeText(let typedText):
            print("🔎 Typing into role \(focusedElement?.role ?? "none") / \(focusedElement?.subrole ?? "none")")
            if focusedElement?.isSecureTextField == true {
                return .refused(spokenReason: "that's a password field. you type that one, i don't touch passwords.")
            }
            if isCommandRunningContext(focusedElement) && !context.isTerminalCommandApproved {
                return terminalConfirmation(context: context, focusedElement: focusedElement, fallbackPreview: "type \(quoted(typedText))")
            }
            // With no text box focused, typed letters become shortcuts
            // (in Gmail, "#" deletes the open email).
            guard focusedElement?.isTextEntry == true else {
                return .needsConfirmation(spokenQuestion: "about to type \(quoted(typedText))\(inApplication(focusedElement)), but no text box has the focus, so the keys could trigger shortcuts. say yes to type anyway.")
            }
            return .allowed

        case .pressKeys(let keyCombinationText):
            guard let keyCombination = VesperKeyCombination(parsing: keyCombinationText) else {
                return .skipped(reason: "unknown key \(keyCombinationText)")
            }
            return keyDecision(for: keyCombination, focusedElement: focusedElement, context: context)

        case .scroll, .waitForScreen:
            return .allowed
        }
    }

    private static func keyDecision(
        for keyCombination: VesperKeyCombination,
        focusedElement: VesperInspectedElement?,
        context: VesperActionSafetyContext
    ) -> VesperActionSafetyDecision {
        let modifiers = keyCombination.modifiers
        let spokenKeys = keyCombination.spokenDescription

        // In a password field, only moving around is allowed: single
        // keys would otherwise type into it one character at a time.
        if focusedElement?.isSecureTextField == true && !keyCombination.isNavigationKey {
            if keyCombination.submitsLikeReturn {
                return .needsConfirmation(spokenQuestion: "about to press return in a password field, which usually signs in. say yes to go ahead.")
            }
            return .refused(spokenReason: "that's a password field. you fill that one in yourself.")
        }

        // Terminals: one question for the step's command, keys included —
        // arrows too: "up" brings back an earlier command, and "down" picks
        // an option in a terminal app's menu.
        if isCommandRunningContext(focusedElement) && !context.isTerminalCommandApproved {
            return terminalConfirmation(context: context, focusedElement: focusedElement, fallbackPreview: "press \(spokenKeys)")
        }
        if isCommandRunningContext(focusedElement) && context.isTerminalCommandApproved {
            return .allowed
        }

        // Space or Return on a focused button or link presses it — the
        // same as clicking it, so a send / pay / delete button asks first.
        let isPressingKey = (keyCombination.keyName == "space" || keyCombination.submitsLikeReturn) && modifiers.isEmpty
        if isPressingKey, focusedElement?.isPressableControl == true {
            if let consequentialText = focusedElement?.describingTexts.first(where: { candidateText in isConsequential(candidateText) }) {
                let spokenTarget = spokenClickTarget(
                    accessibilityText: consequentialText,
                    elementLabel: nil,
                    applicationBundleIdentifier: focusedElement?.applicationBundleIdentifier
                )
                return .needsConfirmation(spokenQuestion: "about to press \(spokenTarget). say yes and i'll do it, or tell me what to change.")
            }
            return .allowed
        }

        if keyCombination.submitsLikeReturn && modifiers.contains(.command) {
            return .needsConfirmation(spokenQuestion: "about to press command return\(inApplication(focusedElement)), which usually sends. say yes to go ahead.")
        }
        if keyCombination.keyName == "d" && modifiers == [.command, .shift] {
            return .needsConfirmation(spokenQuestion: "about to press the send shortcut\(inApplication(focusedElement)). say yes to go ahead.")
        }
        if (keyCombination.keyName == "delete" || keyCombination.keyName == "forwarddelete") && modifiers.contains(.command) {
            return .needsConfirmation(spokenQuestion: "about to press a delete shortcut\(inApplication(focusedElement)). say yes to go ahead.")
        }

        // Return (and ctrl+M / ctrl+J / ctrl+O, which act as Return). Shift+
        // Return is a new line in chat boxes, never a send.
        if keyCombination.submitsLikeReturn && !modifiers.contains(.shift) {
            return returnDecision(focusedElement: focusedElement, context: context)
        }

        // Space where nothing can be read: it might press whatever has focus.
        if keyCombination.keyName == "space" && modifiers.isEmpty && focusedElement == nil {
            return .needsConfirmation(spokenQuestion: "about to press space, but i can't tell what it would press. say yes to go ahead.")
        }

        if keyCombination.isNavigationKey {
            return .allowed
        }

        let hasShortcutModifier = modifiers.contains(.command) || modifiers.contains(.control)
            || (modifiers.contains(.option) && !keyCombination.isCharacterKey)
        if hasShortcutModifier {
            if safeModifierShortcuts.contains(keyCombination.normalizedShortcutName) {
                return .allowed
            }
            return .needsConfirmation(spokenQuestion: "about to press \(spokenKeys)\(inApplication(focusedElement)). say yes to go ahead.")
        }

        // A plain key that types (a letter, space, delete): fine in a text
        // box, a shortcut anywhere else.
        if focusedElement?.isTextEntry == true || keyCombination.keyName == "space" || keyCombination.keyName == "escape" {
            return .allowed
        }
        return .needsConfirmation(spokenQuestion: "about to press \(spokenKeys)\(inApplication(focusedElement)), but no text box has the focus, so it could trigger a shortcut. say yes to go ahead.")
    }

    /// Return is safe in a search box or an address bar (it searches or
    /// loads a page); anywhere else it may send a message or submit a form.
    private static func returnDecision(focusedElement: VesperInspectedElement?, context: VesperActionSafetyContext) -> VesperActionSafetyDecision {
        let typedText = context.textTypedEarlierInStep?.trimmingCharacters(in: .whitespaces)
        print("🔎 Return in role \(focusedElement?.role ?? "none") / \(focusedElement?.subrole ?? "none"), texts \(focusedElement?.describingTexts.prefix(3).map { $0 } ?? [])")

        let isFieldConsequential = focusedElement?.describingTexts.contains(where: { candidateText in isConsequential(candidateText) }) ?? false
        guard let focusedElement, focusedElement.isSearchOrAddressField, !isFieldConsequential else {
            let sendingDescription = typedText.map { ", which could send \(quoted($0))" } ?? ", which might send it"
            return .needsConfirmation(spokenQuestion: "about to press return\(inApplication(focusedElement))\(sendingDescription). say yes to go ahead.")
        }

        // Typed a web address into the address bar: the same rule as [OPEN:...].
        if let typedText, let typedAddress = webAddress(fromTypedText: typedText) {
            switch typedAddress {
            case .scriptAddress:
                return .refused(spokenReason: "that's a script, not a web address, so i won't run it.")
            case .website(let websiteURL):
                if context.isWebsiteSafeToOpenWithoutAsking(websiteURL) {
                    return .allowed
                }
                let siteHost = VesperOpenLinkPolicy.siteHost(ofHost: websiteURL.host ?? "")
                return .needsConfirmation(spokenQuestion: "about to open \(siteHost), a site i haven't opened for you before. say yes and i'll go ahead.")
            }
        }
        return .allowed
    }

    private enum TypedWebAddress {
        case website(URL)
        case scriptAddress
    }

    /// What a Return in an address bar would load, if the typed text is an
    /// address rather than a search.
    private static func webAddress(fromTypedText typedText: String) -> TypedWebAddress? {
        let lowercasedTypedText = typedText.lowercased()
        if lowercasedTypedText.hasPrefix("javascript:") || lowercasedTypedText.hasPrefix("data:") {
            return .scriptAddress
        }
        if lowercasedTypedText.hasPrefix("http://") || lowercasedTypedText.hasPrefix("https://") {
            return URL(string: typedText).map { .website($0) }
        }
        let looksLikeBareAddress = !typedText.contains(" ")
            && typedText.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if looksLikeBareAddress, let websiteURL = URL(string: "https://" + typedText) {
            return .website(websiteURL)
        }
        return nil
    }

    private static func terminalConfirmation(
        context: VesperActionSafetyContext,
        focusedElement: VesperInspectedElement?,
        fallbackPreview: String
    ) -> VesperActionSafetyDecision {
        let commandPreview = context.terminalCommandPreview ?? fallbackPreview
        let applicationName = applicationDisplayName(forBundleIdentifier: focusedElement?.applicationBundleIdentifier)?.lowercased() ?? "the terminal"
        return .needsConfirmation(spokenQuestion: "about to \(commandPreview) in \(applicationName). say yes and i'll run it.")
    }

    /// Built from what the screen really says, not from Claude's label: the
    /// Accessibility text first, and the app it's in. Claude's label is
    /// added only when it disagrees, and used alone only when Accessibility
    /// shows nothing (an icon-only button).
    private static func spokenClickTarget(accessibilityText: String?, elementLabel: String?, applicationBundleIdentifier: String?) -> String {
        let applicationSuffix = applicationDisplayName(forBundleIdentifier: applicationBundleIdentifier).map { " in \($0.lowercased())" } ?? ""
        guard let accessibilityText, !accessibilityText.isEmpty else {
            return "what looks like \(quoted(elementLabel ?? "a button"))\(applicationSuffix)"
        }
        let screenName = accessibilityText.lowercased()
        var spokenTarget = quoted(screenName) + applicationSuffix
        if let elementLabel, !elementLabel.isEmpty {
            let lowercasedLabel = elementLabel.lowercased()
            let namesAgree = lowercasedLabel.contains(screenName) || screenName.contains(lowercasedLabel)
            if !namesAgree {
                spokenTarget += " (i'd called it \(quoted(lowercasedLabel)))"
            }
        }
        return spokenTarget
    }

    static func inApplication(_ inspectedElement: VesperInspectedElement?) -> String {
        applicationDisplayName(forBundleIdentifier: inspectedElement?.applicationBundleIdentifier).map { " in \($0.lowercased())" } ?? ""
    }

    private static func applicationDisplayName(forBundleIdentifier bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications
            .first { runningApplication in runningApplication.bundleIdentifier == bundleIdentifier }?
            .localizedName
    }

    private static func quoted(_ text: String) -> String {
        let shortenedText = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return "\"\(shortenedText)\""
    }
}

/// How the user answered "say yes and i'll do it".
enum VesperConfirmationAnswer: Equatable {
    case approved
    case declined
    /// Anything else, e.g. "change the second line to thanks". Passed to
    /// Claude as a new instruction; the risky action is not done.
    case otherInstruction

    /// A clear yes: at least one of these words or phrases, with nothing
    /// that turns it into a question or a change ("I allow you to do it, do
    /// it, yes" approves; "ok what's this" and "yes but change the greeting"
    /// don't). Loosened after the old six-word rule read real yeses like
    /// "I allow you to do it" as new instructions, so Claude redid the step
    /// and asked again, in a loop.
    private static let approvalWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "ya", "yea", "haan", "sure", "ok", "okay", "alright",
        "confirm", "confirmed", "approve", "approved", "allow", "allowed", "affirmative",
        "absolutely", "definitely", "proceed"
    ]
    private static let approvalPhrases = ["go ahead", "do it", "send it", "go for it", "please do", "run it", "post it", "you can"]
    /// Words that make an answer a question, a hesitation or a change.
    private static let instructionMarkerWords: Set<String> = [
        "what", "what's", "whats", "why", "how", "how's", "which", "where", "where's", "who", "who's", "when",
        "but", "change", "instead",
        "first", "different", "edit", "fix", "maybe", "whatever", "hmm", "later", "if", "actually", "rather"
    ]
    private static let instructionMarkerPhrases = ["let me", "hold on", "before you", "one sec"]
    private static let maximumApprovalWordCount = 12
    private static let declineWords: Set<String> = [
        "no", "nope", "nah", "don't", "dont", "do not", "stop", "cancel", "wait", "never", "hold", "abort", "not"
    ]

    static func classify(_ transcript: String) -> VesperConfirmationAnswer {
        let normalizedWords = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let normalizedTranscript = normalizedWords.joined(separator: " ")

        let containsDeclineWord = normalizedWords.contains(where: declineWords.contains)
            || normalizedTranscript.contains("do not")
            || normalizedTranscript.contains("hold on")
        if containsDeclineWord {
            // "no, change the greeting first" is an instruction, not only a no.
            return normalizedWords.count <= 4 ? .declined : .otherInstruction
        }

        let isQuestionOrChange = transcript.contains("?")
            || normalizedWords.contains(where: instructionMarkerWords.contains)
            || instructionMarkerPhrases.contains { normalizedTranscript.contains($0) }
        let containsApproval = normalizedWords.contains(where: approvalWords.contains)
            || approvalPhrases.contains { normalizedTranscript.contains($0) }
        let isApproval = !normalizedWords.isEmpty
            && normalizedWords.count <= maximumApprovalWordCount
            && containsApproval
            && !isQuestionOrChange
        return isApproval ? .approved : .otherInstruction
    }
}

// MARK: - Reading the Screen Through Accessibility

final class AccessibilityScreenElementInspector: VesperScreenElementInspecting {
    /// Roles whose own title or value names what a click does.
    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXMenuBarItem", "AXTab", "AXCell"
    ]
    /// Chromium browsers only build their accessibility tree when asked.
    private static let chromiumBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Apps whose accessibility tree has already been switched on.
    private var processIdentifiersWithAccessibilityEnabled = Set<pid_t>()

    func inspectElement(atAppKitGlobalPoint appKitGlobalPoint: CGPoint) async -> VesperInspectedElement? {
        let quartzPoint = VesperScreenCoordinates.quartzPoint(fromAppKitGlobalPoint: appKitGlobalPoint)

        // Hit-test inside the app whose window is under the point, not
        // system-wide, so Vesper's own overlay (which covers every screen)
        // is never what gets found.
        guard let owningProcessIdentifier = Self.processIdentifierOfWindow(atQuartzPoint: quartzPoint) else { return nil }
        let applicationElement = AXUIElementCreateApplication(owningProcessIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 1.0)
        await enableAccessibilityTreeIfNeeded(applicationElement: applicationElement, processIdentifier: owningProcessIdentifier)

        var hitElement: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(applicationElement, Float(quartzPoint.x), Float(quartzPoint.y), &hitElement)
        guard hitTestResult == .success, let hitElement else { return nil }
        return describe(element: hitElement, processIdentifier: owningProcessIdentifier)
    }

    func inspectFocusedElement() async -> VesperInspectedElement? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let frontmostProcessIdentifier = frontmostApplication.processIdentifier
        let applicationElement = AXUIElementCreateApplication(frontmostProcessIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 1.0)
        await enableAccessibilityTreeIfNeeded(applicationElement: applicationElement, processIdentifier: frontmostProcessIdentifier)

        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return describe(element: focusedElementValue as! AXUIElement, processIdentifier: frontmostProcessIdentifier)
    }

    /// Electron and Chromium apps expose almost nothing until an assistive
    /// app asks. These attributes are how screen readers ask; apps that
    /// don't know them ignore them.
    private func enableAccessibilityTreeIfNeeded(applicationElement: AXUIElement, processIdentifier: pid_t) async {
        guard !processIdentifiersWithAccessibilityEnabled.contains(processIdentifier) else { return }
        processIdentifiersWithAccessibilityEnabled.insert(processIdentifier)

        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier ?? ""
        if Self.chromiumBrowserBundleIdentifiers.contains(bundleIdentifier) {
            AXUIElementSetAttributeValue(applicationElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        // The tree is built asynchronously after the first request.
        try? await Task.sleep(for: .milliseconds(350))
    }

    private func describe(element: AXUIElement, processIdentifier: pid_t) -> VesperInspectedElement {
        let role = Self.stringAttribute(kAXRoleAttribute, of: element)
        let subrole = Self.stringAttribute(kAXSubroleAttribute, of: element)

        var describingTexts: [String] = []
        describingTexts += Self.namingTexts(of: element, role: role)

        // A click often lands on the label or icon inside a button; the
        // button's own name is one or two levels up.
        var ancestorElement = Self.parent(of: element)
        for _ in 0..<3 {
            guard let currentAncestorElement = ancestorElement else { break }
            let ancestorRole = Self.stringAttribute(kAXRoleAttribute, of: currentAncestorElement)
            if let ancestorRole, Self.actionableRoles.contains(ancestorRole) {
                describingTexts += Self.namingTexts(of: currentAncestorElement, role: ancestorRole)
                break
            }
            ancestorElement = Self.parent(of: currentAncestorElement)
        }

        return VesperInspectedElement(
            role: role,
            subrole: subrole,
            describingTexts: describingTexts.filter { !$0.isEmpty },
            applicationBundleIdentifier: NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        )
    }

    /// Title, description and help — plus the value, but only for buttons
    /// and labels: a text box's value is what's typed in it, and a message
    /// that says "please delete this" must not make every click risky.
    private static func namingTexts(of element: AXUIElement, role: String?) -> [String] {
        var namingTexts = [
            stringAttribute(kAXTitleAttribute, of: element),
            stringAttribute(kAXDescriptionAttribute, of: element),
            stringAttribute(kAXHelpAttribute, of: element)
        ].compactMap { $0 }
        if let role, actionableRoles.contains(role) || role == "AXStaticText" {
            if let elementValue = stringAttribute(kAXValueAttribute, of: element), elementValue.count <= 80 {
                namingTexts.append(elementValue)
            }
        }
        return namingTexts
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        return (attributeValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Vesper's own windows.
    private static func processIdentifierOfWindow(atQuartzPoint quartzPoint: CGPoint) -> pid_t? {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // The list is ordered front to back.
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

// MARK: - Running One Step

/// Runs the hands-on actions from one of Vesper's replies, in order,
/// checking each against the safety policy first.
@MainActor
final class VesperHandsOnStepRunner {
    enum StepOutcome: Equatable {
        /// Every action ran (unknown ones were skipped).
        case completed(performedDescriptions: [String])
        /// Stopped before an action that needs the user's yes. Nothing from
        /// `remainingActions` (the risky one first) has been done.
        /// `inspectedElementWhenAsked` is what the screen showed for it, so
        /// the yes can be checked against the screen as it is later.
        case needsConfirmation(
            spokenQuestion: String,
            remainingActions: [VesperResolvedScreenAction],
            inspectedElementWhenAsked: VesperInspectedElement?,
            performedDescriptions: [String]
        )
        /// Stopped because an action is never allowed.
        case refused(spokenReason: String, performedDescriptions: [String])
        /// The user said yes, but the element they approved is no longer
        /// what's there (they switched windows or scrolled). Nothing was done.
        case screenChangedBeforeConfirmedAction
        /// Something about the next action looked wrong — her typing would
        /// go somewhere that isn't a text box — so nothing from that action
        /// on was done, and she looks at the screen again instead of
        /// guessing. Checks like this run in both paces: Turbo only skips
        /// the "is this risky?" questions, never the "is this right?" ones.
        /// (28 Sep: with asking off, a click on the terminal missed and
        /// "12345" plus Return went into the Phone app.)
        case needsFreshLook(reason: String, performedDescriptions: [String])
    }

    /// Pause after a click, a shortcut or Return: menus, dialogs, new tabs
    /// and focus changes need a moment to land before the next action.
    private static let pauseAfterScreenChangingActionMilliseconds = 350
    /// Pause after typing, plain keys or a scroll, whose effect is
    /// immediate (and events always arrive in order).
    private static let pauseAfterImmediateActionMilliseconds = 150
    /// Before typing, how long to wait for a text box to take the focus
    /// (web pages can take a moment after a click).
    private static let maximumWaitForTextFocusSeconds = 0.6
    /// At most this many look-agains per task, so a screen she misreads
    /// can't loop her; after that the normal rules apply.
    private static let maximumFreshLooksPerTask = 3

    private let screenEventPoster: VesperScreenEventPosting
    private let screenElementInspector: VesperScreenElementInspecting
    /// Called before each click, so the blue cursor flies to the target and
    /// the user sees where she's about to click.
    private let showClickTarget: (CGPoint, String?) async -> Void
    /// The [OPEN:...] rule, reused for addresses typed into an address bar.
    private let isWebsiteSafeToOpenWithoutAsking: (URL) -> Bool
    /// Called right before each click is posted (after every check has
    /// passed), so the overlay can show a ripple where it lands.
    private let onBeforeClick: (CGPoint, VesperClickKind) -> Void
    /// The panel's "Ask before risky actions" switch. Off: questions are
    /// skipped and the action runs (password fields stay refused).
    private let shouldAskBeforeRiskyActions: () -> Bool
    /// Called right before each action runs, so the island can say what
    /// she's doing.
    private let onWillPerformAction: (VesperResolvedScreenAction) -> Void
    /// Compares the screen around a click point with the screenshot Claude
    /// picked it from (VesperClickTargetCheck). Nil: couldn't check.
    private let compareClickTargetWithScreenshot: (CGPoint) async -> VesperClickTargetCheck.Comparison?
    /// Where a click was held back this task because the screen had changed
    /// there. Claude choosing the same spot again on the fresh screenshot
    /// means it's right (or the spot is animated): no second check.
    private var clickPointsLookedAgainInCurrentTask: [CGPoint] = []
    /// Apps where the user already said yes to pressing Return during the
    /// current task — Return there doesn't ask again until the task ends
    /// (typing input into a compiler and pressing Return asked every time).
    private var applicationsApprovedForReturnInCurrentTask = Set<String>()
    /// What already made her look again this task ("typing into AXButton in
    /// com.apple.mobilephone"). The same problem a second time is taken as
    /// what Claude really means, so it can't loop.
    private var freshLookReasonsUsedInCurrentTask = Set<String>()

    /// Called when a task ends, so the next task starts afresh: asks
    /// again, and may look again.
    func forgetStateFromLastTask() {
        applicationsApprovedForReturnInCurrentTask.removeAll()
        freshLookReasonsUsedInCurrentTask.removeAll()
        clickPointsLookedAgainInCurrentTask.removeAll()
    }

    init(
        screenEventPoster: VesperScreenEventPosting,
        screenElementInspector: VesperScreenElementInspecting,
        showClickTarget: @escaping (CGPoint, String?) async -> Void,
        isWebsiteSafeToOpenWithoutAsking: @escaping (URL) -> Bool = { _ in false },
        onBeforeClick: @escaping (CGPoint, VesperClickKind) -> Void = { _, _ in },
        onWillPerformAction: @escaping (VesperResolvedScreenAction) -> Void = { _ in },
        shouldAskBeforeRiskyActions: @escaping () -> Bool = { true },
        compareClickTargetWithScreenshot: @escaping (CGPoint) async -> VesperClickTargetCheck.Comparison? = { _ in nil }
    ) {
        self.screenEventPoster = screenEventPoster
        self.screenElementInspector = screenElementInspector
        self.showClickTarget = showClickTarget
        self.isWebsiteSafeToOpenWithoutAsking = isWebsiteSafeToOpenWithoutAsking
        self.onBeforeClick = onBeforeClick
        self.onWillPerformAction = onWillPerformAction
        self.shouldAskBeforeRiskyActions = shouldAskBeforeRiskyActions
        self.compareClickTargetWithScreenshot = compareClickTargetWithScreenshot
    }

    /// Whether a question about this action can be skipped: confirmations
    /// are switched off, or it's another Return in an app where Return was
    /// already approved during this task.
    private func canSkipQuestion(_ spokenQuestion: String, for resolvedAction: VesperResolvedScreenAction, inspectedElement: VesperInspectedElement?) -> Bool {
        if !shouldAskBeforeRiskyActions() {
            print("🖐️ Not asking (Ask before risky actions is off): \(spokenQuestion)")
            return true
        }
        if Self.isReturnPress(resolvedAction),
           let applicationBundleIdentifier = inspectedElement?.applicationBundleIdentifier,
           applicationsApprovedForReturnInCurrentTask.contains(applicationBundleIdentifier),
           inspectedElement?.isPressableControl != true {
            print("🖐️ Not asking again: Return in \(applicationBundleIdentifier) was approved earlier in this task")
            return true
        }
        return false
    }

    private static func isReturnPress(_ resolvedAction: VesperResolvedScreenAction) -> Bool {
        guard case .pressKeys(let keyCombinationText) = resolvedAction,
              let keyCombination = VesperKeyCombination(parsing: keyCombinationText) else { return false }
        return keyCombination.submitsLikeReturn && !keyCombination.modifiers.contains(.command)
    }

    /// Throws CancellationError if the task is cancelled (hotkey pressed)
    /// between actions.
    ///
    /// `approvedElementForFirstAction` is set when the user just said yes
    /// to the first action: it's what the screen showed when she asked
    /// (nil inside means Accessibility couldn't see anything then). The
    /// first action runs without asking again only if the screen still
    /// shows the same element.
    func run(
        _ resolvedActions: [VesperResolvedScreenAction],
        approvedElementForFirstAction: VesperInspectedElement?? = nil
    ) async throws -> StepOutcome {
        var performedDescriptions: [String] = []
        var textTypedEarlierInStep: String?
        var isTerminalCommandApproved = false

        for (actionIndex, resolvedAction) in resolvedActions.enumerated() {
            try Task.checkCancellation()

            // A yes to a terminal command covers only what she read out:
            // the typing and keys up to the next click, scroll or wait.
            switch resolvedAction {
            case .click, .scroll, .waitForScreen:
                isTerminalCommandApproved = false
            case .typeText, .pressKeys:
                break
            }

            let isFirstActionTheUserApproved = actionIndex == 0 && approvedElementForFirstAction != nil

            // Look before clicking: the step's first click is checked
            // against the screenshot it was chosen from (later ones follow
            // other actions that changed the screen on purpose).
            if case .click(let appKitGlobalPoint, let elementLabel, _) = resolvedAction, actionIndex == 0, !isFirstActionTheUserApproved,
               let freshLookReason = await freshLookReasonForClick(at: appKitGlobalPoint, elementLabel: elementLabel) {
                print("🖐️ Looking again instead of clicking: \(freshLookReason)")
                return .needsFreshLook(reason: freshLookReason, performedDescriptions: performedDescriptions)
            }
            try Task.checkCancellation()

            var inspectedElement = await inspectElementForSafetyCheck(resolvedAction)
            try Task.checkCancellation()

            // Typing: give a text box a moment to take the focus (a click on
            // a search box can take a beat to land), then make sure the
            // keys won't go somewhere else entirely.
            if case .typeText(let typedText) = resolvedAction, !isFirstActionTheUserApproved {
                if inspectedElement?.isTextEntry != true {
                    inspectedElement = try await waitForTextEntryFocus(startingWith: inspectedElement)
                }
                if let freshLookReason = freshLookReasonForTyping(typedText, focusedElement: inspectedElement) {
                    print("🖐️ Looking again instead of typing: \(freshLookReason)")
                    return .needsFreshLook(reason: freshLookReason, performedDescriptions: performedDescriptions)
                }
            }

            let safetyContext = VesperActionSafetyContext(
                textTypedEarlierInStep: textTypedEarlierInStep,
                terminalCommandPreview: Self.terminalCommandPreview(for: Array(resolvedActions[actionIndex...])),
                isTerminalCommandApproved: isTerminalCommandApproved,
                isWebsiteSafeToOpenWithoutAsking: isWebsiteSafeToOpenWithoutAsking
            )

            if actionIndex == 0, let approvedElement = approvedElementForFirstAction {
                guard inspectedElement == approvedElement else {
                    print("🖐️ Screen changed since the yes — not doing it")
                    return .screenChangedBeforeConfirmedAction
                }
                // A yes to a terminal command covers the rest of the step there.
                if VesperActionSafetyPolicy.isCommandRunningContext(inspectedElement) {
                    isTerminalCommandApproved = true
                }
                // A yes to Return covers later Returns in the same app for this task.
                if Self.isReturnPress(resolvedAction), let applicationBundleIdentifier = inspectedElement?.applicationBundleIdentifier {
                    applicationsApprovedForReturnInCurrentTask.insert(applicationBundleIdentifier)
                }
            } else {
                let safetyDecision = Self.safetyDecision(for: resolvedAction, inspectedElement: inspectedElement, context: safetyContext)
                switch safetyDecision {
                case .allowed:
                    break
                case .needsConfirmation(let spokenQuestion):
                    if canSkipQuestion(spokenQuestion, for: resolvedAction, inspectedElement: inspectedElement) {
                        break
                    }
                    return .needsConfirmation(
                        spokenQuestion: spokenQuestion,
                        remainingActions: Array(resolvedActions[actionIndex...]),
                        inspectedElementWhenAsked: inspectedElement,
                        performedDescriptions: performedDescriptions
                    )
                case .refused(let spokenReason):
                    return .refused(spokenReason: spokenReason, performedDescriptions: performedDescriptions)
                case .skipped(let reason):
                    print("🖐️ Skipped: \(reason)")
                    performedDescriptions.append("skipped (\(reason))")
                    continue
                }
            }

            // A click first shows its target (the cursor flies there, up to
            // ~2 s). The page can change meanwhile — a dialog appears, a
            // "Buy" button loads under the point — so look again right
            // before clicking, and judge whatever is there now.
            // (In Turbo the click doesn't wait for the flight, so the look
            // above is already the latest one.)
            if case .click(let appKitGlobalPoint, let elementLabel, _) = resolvedAction {
                await showClickTarget(appKitGlobalPoint, elementLabel)
                try Task.checkCancellation()
            }
            if case .click = resolvedAction, shouldAskBeforeRiskyActions() {
                let elementJustBeforeClick = await inspectElementForSafetyCheck(resolvedAction)
                try Task.checkCancellation()
                if elementJustBeforeClick != inspectedElement {
                    print("🖐️ What's under the click changed during the flight — checking again")
                    if actionIndex == 0, approvedElementForFirstAction != nil {
                        return .screenChangedBeforeConfirmedAction
                    }
                    switch Self.safetyDecision(for: resolvedAction, inspectedElement: elementJustBeforeClick, context: safetyContext) {
                    case .allowed:
                        break
                    case .needsConfirmation(let spokenQuestion):
                        if canSkipQuestion(spokenQuestion, for: resolvedAction, inspectedElement: elementJustBeforeClick) {
                            break
                        }
                        return .needsConfirmation(
                            spokenQuestion: spokenQuestion,
                            remainingActions: Array(resolvedActions[actionIndex...]),
                            inspectedElementWhenAsked: elementJustBeforeClick,
                            performedDescriptions: performedDescriptions
                        )
                    case .refused(let spokenReason):
                        return .refused(spokenReason: spokenReason, performedDescriptions: performedDescriptions)
                    case .skipped(let reason):
                        performedDescriptions.append("skipped (\(reason))")
                        continue
                    }
                }
            }

            onWillPerformAction(resolvedAction)
            try await perform(resolvedAction)
            if case .typeText(let typedText) = resolvedAction {
                textTypedEarlierInStep = typedText
            }
            performedDescriptions.append(resolvedAction.performedDescription)
            print("🖐️ \(resolvedAction.performedDescription)")
            try await Task.sleep(for: .milliseconds(Self.pauseMilliseconds(after: resolvedAction)))
        }

        return .completed(performedDescriptions: performedDescriptions)
    }

    private static func pauseMilliseconds(after resolvedAction: VesperResolvedScreenAction) -> Int {
        switch resolvedAction {
        case .click, .waitForScreen:
            return pauseAfterScreenChangingActionMilliseconds
        case .pressKeys(let keyCombinationText):
            guard let keyCombination = VesperKeyCombination(parsing: keyCombinationText) else {
                return pauseAfterScreenChangingActionMilliseconds
            }
            let isShortcut = keyCombination.modifiers.contains(.command) || keyCombination.modifiers.contains(.control)
            return isShortcut || keyCombination.submitsLikeReturn
                ? pauseAfterScreenChangingActionMilliseconds
                : pauseAfterImmediateActionMilliseconds
        case .typeText, .scroll:
            return pauseAfterImmediateActionMilliseconds
        }
    }

    /// How to wait for the screen after a step, from what it did last.
    static func settleExpectation(afterRunning resolvedActions: [VesperResolvedScreenAction], didOpenSomething: Bool) -> VesperScreenSettleExpectation {
        if didOpenSomething {
            return .openedSomething
        }
        guard let lastAction = resolvedActions.last else { return .mayChangeScreen }
        switch lastAction {
        case .click:
            return .mayChangeScreen
        case .waitForScreen:
            return .afterExplicitWait
        case .typeText, .scroll:
            return .immediateEffect
        case .pressKeys:
            return pauseMilliseconds(after: lastAction) == pauseAfterScreenChangingActionMilliseconds
                ? .mayChangeScreen
                : .immediateEffect
        }
    }

    /// Re-reads the focused element every 0.1 s until a text box has it,
    /// for up to `maximumWaitForTextFocusSeconds`. Returns the last look.
    private func waitForTextEntryFocus(startingWith firstFocusedElement: VesperInspectedElement?) async throws -> VesperInspectedElement? {
        var latestFocusedElement = firstFocusedElement
        let waitStartedAt = Date()
        while Date().timeIntervalSince(waitStartedAt) < Self.maximumWaitForTextFocusSeconds {
            try await Task.sleep(for: .milliseconds(100))
            latestFocusedElement = await screenElementInspector.inspectFocusedElement()
            if latestFocusedElement?.isTextEntry == true {
                print(String(format: "🖐️ Text box took the focus after %.2fs", Date().timeIntervalSince(waitStartedAt)))
                return latestFocusedElement
            }
            // Some apps (terminals, editors) never show Accessibility what
            // has the focus: waiting longer wouldn't change that.
            if firstFocusedElement == nil && latestFocusedElement == nil {
                return nil
            }
        }
        return latestFocusedElement
    }

    /// Why a click must not happen yet, or nil: the screen around it no
    /// longer looks like the screenshot Claude chose it from.
    private func freshLookReasonForClick(at appKitGlobalPoint: CGPoint, elementLabel: String?) async -> String? {
        let isNearASpotAlreadyLookedAgain = clickPointsLookedAgainInCurrentTask.contains { earlierPoint in
            hypot(earlierPoint.x - appKitGlobalPoint.x, earlierPoint.y - appKitGlobalPoint.y) <= 40
        }
        guard !isNearASpotAlreadyLookedAgain,
              freshLookReasonsUsedInCurrentTask.count + clickPointsLookedAgainInCurrentTask.count < Self.maximumFreshLooksPerTask else {
            return nil
        }
        let checkStartedAt = Date()
        guard let comparison = await compareClickTargetWithScreenshot(appKitGlobalPoint) else { return nil }
        let spokenLabel = elementLabel.map { "\u{201C}\($0)\u{201D}" } ?? "there"
        print(String(format: "🎯 Click check %@: %@ — difference %.1f where Claude saw it, best %.1f at %.0f,%.0f pt, %.0f ms",
                     spokenLabel, comparison.verdict.rawValue, comparison.meanDifferenceAtClaudesPosition, comparison.bestMeanDifference,
                     comparison.bestOffsetInPoints.width, comparison.bestOffsetInPoints.height, Date().timeIntervalSince(checkStartedAt) * 1000))
        guard !comparison.looksTheSame else { return nil }
        clickPointsLookedAgainInCurrentTask.append(appKitGlobalPoint)
        let whatHappened = comparison.verdict == .moved
            ? "what was there has moved by about \(Int(abs(comparison.bestOffsetInPoints.height))) points (the page shifted or was still loading)"
            : "that part of the screen looks different now (it may still have been loading, or something opened over it)"
        return "your click on \(spokenLabel) was not done: since your screenshot, \(whatHappened)"
    }

    /// Why typing must not happen yet, or nil. Only when Accessibility can
    /// see what has the focus and it clearly isn't a text box — a button,
    /// a window, a list. When it can't see anything (some terminals and
    /// editors expose nothing), the normal rules decide, as before.
    private func freshLookReasonForTyping(_ typedText: String, focusedElement: VesperInspectedElement?) -> String? {
        guard let focusedElement, let focusedRole = focusedElement.role, !focusedElement.isTextEntry else { return nil }
        guard freshLookReasonsUsedInCurrentTask.count + clickPointsLookedAgainInCurrentTask.count < Self.maximumFreshLooksPerTask else { return nil }
        let freshLookKey = "typing into \(focusedRole) in \(focusedElement.applicationBundleIdentifier ?? "an unknown app")"
        guard freshLookReasonsUsedInCurrentTask.insert(freshLookKey).inserted else { return nil }
        let shortenedText = typedText.count > 40 ? String(typedText.prefix(40)) + "…" : typedText
        return "typing \"\(shortenedText)\" was not done: the keyboard focus is on \(Self.spokenRoleDescription(focusedRole))\(VesperActionSafetyPolicy.inApplication(focusedElement)), not a text box"
    }

    private static func spokenRoleDescription(_ accessibilityRole: String) -> String {
        switch accessibilityRole {
        case "AXButton", "AXMenuButton", "AXPopUpButton": return "a button"
        case "AXLink": return "a link"
        case "AXWindow": return "a window"
        case "AXWebArea": return "the page itself"
        case "AXList", "AXTable", "AXOutline", "AXRow", "AXCell": return "a list"
        case "AXImage": return "an image"
        case "AXStaticText": return "some text"
        case "AXCheckBox", "AXRadioButton": return "a checkbox"
        case "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem": return "a menu"
        case "AXTabGroup", "AXRadioGroup": return "a tab"
        default:
            let roleName = accessibilityRole.hasPrefix("AX") ? String(accessibilityRole.dropFirst(2)) : accessibilityRole
            return "a \(roleName.lowercased())"
        }
    }

    /// What the safety check looks at: the element under a click, or the
    /// focused element for typing and keys.
    private func inspectElementForSafetyCheck(_ resolvedAction: VesperResolvedScreenAction) async -> VesperInspectedElement? {
        switch resolvedAction {
        case .click(let appKitGlobalPoint, _, _):
            return await screenElementInspector.inspectElement(atAppKitGlobalPoint: appKitGlobalPoint)
        case .typeText, .pressKeys:
            return await screenElementInspector.inspectFocusedElement()
        case .scroll, .waitForScreen:
            return nil
        }
    }

    /// "type \"ls -la\", then press return" — the typing and keys from
    /// here up to the next click or scroll, read out before a terminal runs them.
    private static func terminalCommandPreview(for upcomingActions: [VesperResolvedScreenAction]) -> String? {
        var previewParts: [String] = []
        for upcomingAction in upcomingActions {
            switch upcomingAction {
            case .typeText(let typedText):
                previewParts.append("type \"\(typedText.count > 80 ? String(typedText.prefix(80)) + "…" : typedText)\"")
            case .pressKeys(let keyCombinationText):
                let spokenKeys = VesperKeyCombination(parsing: keyCombinationText)?.spokenDescription ?? keyCombinationText
                previewParts.append("press \(spokenKeys)")
            case .click, .scroll, .waitForScreen:
                return previewParts.isEmpty ? nil : previewParts.joined(separator: ", then ")
            }
        }
        return previewParts.isEmpty ? nil : previewParts.joined(separator: ", then ")
    }

    private static func safetyDecision(
        for resolvedAction: VesperResolvedScreenAction,
        inspectedElement: VesperInspectedElement?,
        context: VesperActionSafetyContext
    ) -> VesperActionSafetyDecision {
        switch resolvedAction {
        case .click:
            return VesperActionSafetyPolicy.decision(for: resolvedAction, elementUnderClick: inspectedElement, focusedElement: nil, context: context)
        case .typeText, .pressKeys:
            return VesperActionSafetyPolicy.decision(for: resolvedAction, elementUnderClick: nil, focusedElement: inspectedElement, context: context)
        case .scroll, .waitForScreen:
            return .allowed
        }
    }

    private func perform(_ resolvedAction: VesperResolvedScreenAction) async throws {
        switch resolvedAction {
        case .click(let appKitGlobalPoint, _, let clickKind):
            // The target was already shown and re-checked in run().
            onBeforeClick(appKitGlobalPoint, clickKind)
            await screenEventPoster.click(atAppKitGlobalPoint: appKitGlobalPoint, clickKind: clickKind)
        case .typeText(let textToType):
            await screenEventPoster.typeText(textToType)
        case .pressKeys(let keyCombinationText):
            guard let keyCombination = VesperKeyCombination(parsing: keyCombinationText) else { return }
            await screenEventPoster.pressKeyCombination(keyCombination)
        case .scroll(let direction, let appKitGlobalPoint):
            await screenEventPoster.scroll(direction: direction, atAppKitGlobalPoint: appKitGlobalPoint)
        case .waitForScreen(let seconds):
            // Throws if the hotkey cancels the task mid-wait.
            try await Task.sleep(for: .seconds(seconds))
        }
    }
}
