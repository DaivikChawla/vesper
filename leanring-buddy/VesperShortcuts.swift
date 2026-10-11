//
//  VesperShortcuts.swift
//  leanring-buddy
//
//  [SHORTCUT:name] runs one of the user's Shortcuts through
//  `/usr/bin/shortcuts run` — which reaches HomeKit, Focus, timers, Notes
//  and apps' own actions with no accounts or extra code.
//
//  Only shortcuts the user has allowed in the panel can run, each marked
//  "run" (at once) or "ask first" (spoken yes, like an unknown site). Any
//  other name is refused. She never passes input to a shortcut, so one that
//  would send free text can't be fed anything; and while the conversation
//  holds text others wrote, every shortcut asks first.
//

import Foundation

enum VesperShortcutPermission: String, Codable, CaseIterable {
    case off
    case run
    case askFirst

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .run: return "Run"
        case .askFirst: return "Ask"
        }
    }
}

enum VesperShortcutDecision: Equatable {
    /// Allowed: `shortcutName` is the installed name, exactly as spelled there.
    case runNow(shortcutName: String)
    case askFirst(shortcutName: String)
    case notAllowed
}

enum VesperShortcuts {
    /// Shortcuts can do more than a quick action (a HomeKit scene, a
    /// timer), but one still running after this long is stuck.
    static let runTimeoutSeconds: Double = 30

    /// Matches a requested name to an allowed one, ignoring case and spaces
    /// at the ends. Once untrusted text is in the conversation, even
    /// "run" shortcuts ask first.
    static func decision(
        forRequestedName requestedName: String,
        permissionsByShortcutName: [String: VesperShortcutPermission],
        isConversationTainted: Bool
    ) -> VesperShortcutDecision {
        let normalizedRequestedName = requestedName.trimmingCharacters(in: .whitespaces).lowercased()
        guard let (shortcutName, permission) = permissionsByShortcutName.first(where: { shortcutName, _ in
            shortcutName.lowercased() == normalizedRequestedName
        }) else {
            return .notAllowed
        }
        switch permission {
        case .off:
            return .notAllowed
        case .run:
            // A name like "send invoice" or "delete old photos" asks anyway:
            // the spoken yes before sending, buying or deleting isn't
            // skipped just because a shortcut does it.
            let looksConsequential = VesperActionSafetyPolicy.isConsequential(shortcutName)
            return isConversationTainted || looksConsequential
                ? .askFirst(shortcutName: shortcutName)
                : .runNow(shortcutName: shortcutName)
        case .askFirst:
            return .askFirst(shortcutName: shortcutName)
        }
    }

    /// The names of every installed shortcut, for the panel.
    static func listInstalledShortcutNames() async -> [String] {
        let listResult = await VesperProcessRunner.run(executablePath: "/usr/bin/shortcuts", arguments: ["list"], timeoutSeconds: 10)
        guard listResult.exitStatus == 0 else {
            print("⚠️ Shortcuts: couldn't list shortcuts: \(listResult.standardError)")
            return []
        }
        return listResult.standardOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Runs an allowed shortcut, with no input. Returns a line to say if it failed.
    static func runShortcut(named shortcutName: String) async -> String? {
        print("⚡ Shortcut: run \"\(shortcutName)\"")
        let runResult = await VesperProcessRunner.run(
            executablePath: "/usr/bin/shortcuts",
            arguments: ["run", shortcutName],
            timeoutSeconds: runTimeoutSeconds
        )
        if runResult.exitStatus == VesperProcessRunner.timedOutExitStatus {
            return "\(shortcutName.lowercased()) didn't finish within thirty seconds. it may still be running."
        }
        if runResult.exitStatus != 0 {
            print("⚠️ Shortcut \"\(shortcutName)\" failed: \(runResult.standardError)")
            return "\(shortcutName.lowercased()) didn't work."
        }
        return nil
    }
}

/// Which shortcuts she may run, saved in UserDefaults.
enum VesperShortcutSettingsStore {
    private static let userDefaultsKey = "shortcutPermissions"

    static func load() -> [String: VesperShortcutPermission] {
        guard let savedData = UserDefaults.standard.data(forKey: userDefaultsKey),
              let savedPermissions = try? JSONDecoder().decode([String: VesperShortcutPermission].self, from: savedData) else {
            return [:]
        }
        return savedPermissions
    }

    static func save(_ permissionsByShortcutName: [String: VesperShortcutPermission]) {
        // Only allowed ones are kept; "off" is the default for everything else.
        let allowedPermissions = permissionsByShortcutName.filter { $0.value != .off }
        if let encodedData = try? JSONEncoder().encode(allowedPermissions) {
            UserDefaults.standard.set(encodedData, forKey: userDefaultsKey)
        }
    }
}
