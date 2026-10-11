//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.writeLogToFileWhenNotInTerminal()
        print("🎯 Vesper: Starting...")
        print("🎯 Vesper: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    /// Where the log goes when Vesper isn't attached to a terminal or
    /// Xcode's console — e.g. the installed copy opened at login, whose
    /// output would otherwise be thrown away. Stays on this Mac.
    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Vesper.log")
    /// The log starts over once it's bigger than this.
    /// Kept alive for the life of the app: it owns the pipe stdout and
    /// stderr write into.
    private static var timestampedLogWriter: VesperTimestampedLogWriter?

    /// When not attached to a terminal or Xcode's console (the installed
    /// copy), everything printed goes to Vesper.log with a timestamp on every
    /// line, so each interaction can be read back as a timeline.
    private static func writeLogToFileWhenNotInTerminal() {
        if isatty(STDOUT_FILENO) == 0 {
            let logWriter = VesperTimestampedLogWriter(logFileURL: logFileURL)
            logWriter.start()
            timestampedLogWriter = logWriter
        } else {
            // Line buffering: each line is shown as it's printed.
            setvbuf(stdout, nil, _IOLBF, 0)
            setvbuf(stderr, nil, _IOLBF, 0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    ///
    /// Only the copy installed in /Applications registers: development
    /// builds that Xcode runs from DerivedData must never become the copy
    /// that opens at login. The installed copy re-registers whenever its
    /// location changes, so the login item always points at it.
    private func registerAsLoginItemIfNeeded() {
        let currentAppPath = Bundle.main.bundlePath
        let isInstalledCopy = currentAppPath.hasPrefix("/Applications/")
            || currentAppPath.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard isInstalledCopy else {
            print("🎯 Vesper: development copy — not registering as a login item")
            return
        }

        let loginItemService = SMAppService.mainApp
        let lastRegisteredAppPath = UserDefaults.standard.string(forKey: "loginItemRegisteredAppPath")
        let isRegisteredForThisCopy = loginItemService.status == .enabled && lastRegisteredAppPath == currentAppPath
        guard !isRegisteredForThisCopy else { return }

        do {
            if loginItemService.status == .enabled {
                // Registered from some other copy (e.g. an old build) — replace it.
                try? loginItemService.unregister()
            }
            try loginItemService.register()
            UserDefaults.standard.set(currentAppPath, forKey: "loginItemRegisteredAppPath")
            print("🎯 Vesper: Registered as login item (\(currentAppPath))")
        } catch {
            print("⚠️ Vesper: Failed to register as login item: \(error)")
        }
    }
}
