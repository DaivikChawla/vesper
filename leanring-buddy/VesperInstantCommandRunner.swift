//
//  VesperInstantCommandRunner.swift
//  leanring-buddy
//
//  Does the fast lane's commands on the Mac (VesperInstantCommands decides
//  what was asked): opens apps, websites and Settings pages, plays the top
//  YouTube result, presses shortcuts in the front app, arranges windows,
//  switches dark mode and Wi-Fi, locks the screen. No screenshot and no
//  Claude: from the end of the question to done is well under a second
//  (playing a YouTube video adds one quick fetch of the results page).
//
//  Anything it can't place ("open" a name that's no app, site or Settings
//  page; quitting an app that isn't running) is reported up front by
//  `canHandle`, and the question goes to Claude as before.
//

import AppKit
import CoreWLAN
import Foundation

enum VesperInstantCommandRunner {
    enum Outcome: Equatable {
        /// Done. An empty line means nothing needs saying: the change is
        /// right there on screen.
        case done(spokenLine: String)
        case failed(spokenLine: String)
    }

    /// What an "open" name means on this Mac.
    enum OpenTarget: Equatable {
        case application(URL)
        case settingsPage(URL, displayName: String)
        case website(URL, displayName: String)
    }

    // MARK: - Can It Be Done Here?

    /// False when the command needs Claude after all: an "open" name that
    /// isn't an app, a website or a Settings page, or an app to quit or
    /// hide that isn't running.
    static func canHandle(_ instantCommand: VesperInstantCommand) -> Bool {
        switch instantCommand {
        case .open(let targetName, _):
            return resolveOpenTarget(named: targetName) != nil
        case .quitApplication(let applicationName):
            return VesperWindowControl.isApplicationRunning(named: applicationName, requiresUniqueMatch: true)
        case .hideApplication(let applicationName):
            return VesperWindowControl.isApplicationRunning(named: applicationName, requiresUniqueMatch: false)
        case .newTab(let browserName?):
            return VesperApplicationLocator.applicationURL(named: browserName) != nil
        default:
            return true
        }
    }

    // MARK: - Doing It

    static func perform(_ instantCommand: VesperInstantCommand) async -> Outcome {
        switch instantCommand {
        case .open(let targetName, let browserName):
            return await open(targetName: targetName, browserName: browserName)
        case .searchWeb(let query, let site):
            let searchURL = site == .youtube ? youTubeSearchURL(for: query) : googleSearchURL(for: query)
            return await openInBrowser(searchURL, displayName: "the results")
        case .playOnYouTube(let query):
            return await playTopYouTubeResult(for: query)
        case .newTab(let browserName):
            return await openNewTab(inBrowserNamed: browserName)
        case .pressShortcut(let shortcut):
            return await pressKeys(shortcut.keyCombinationText)
        case .scroll(let direction):
            await SystemScreenEventPoster().scroll(direction: direction, atAppKitGlobalPoint: nil)
            return .done(spokenLine: "")
        case .arrangeWindow(let arrangement):
            return outcome(fromFailureLine: await VesperWindowControl.perform(.arrangeWindow(arrangement, applicationName: nil)))
        case .quitApplication(let applicationName):
            return outcome(fromFailureLine: await VesperWindowControl.perform(.quitApplication(name: applicationName)))
        case .hideApplication(let applicationName):
            return outcome(fromFailureLine: await VesperWindowControl.perform(.hideApplication(name: applicationName)))
        case .setDarkMode(let isOn):
            return await setDarkMode(isOn: isOn)
        case .setWiFi(let isOn):
            return await setWiFi(isOn: isOn)
        case .changeBrightness(let isUp):
            // Two presses of the brightness key: one is a barely visible step.
            for _ in 0..<2 {
                VesperMediaKeys.press(isUp ? VesperMediaKeys.brightnessUpKey : VesperMediaKeys.brightnessDownKey)
            }
            return .done(spokenLine: "")
        case .lockScreen:
            return await pressKeys("ctrl+cmd+q")
        case .sleepDisplay:
            let sleepResult = await VesperProcessRunner.run(executablePath: "/usr/bin/pmset", arguments: ["displaysleepnow"])
            return sleepResult.exitStatus == 0 ? .done(spokenLine: "") : .failed(spokenLine: "the screen wouldn't sleep.")
        case .takeScreenshot:
            // The Mac's own shortcut: saved where their screenshots go, with its sound.
            return await pressKeys("cmd+shift+3")
        case .tellBattery:
            return .done(spokenLine: speakableBatteryLine(VesperLookups.readBatteryStatus()))
        case .startTimer, .changeVolume, .controlMusic, .tellTime, .tellDate:
            // Done by CompanionManager's own runners.
            return .done(spokenLine: VesperInstantCommands.spokenLine(for: instantCommand))
        }
    }

    private static func outcome(fromFailureLine failureLine: String?) -> Outcome {
        failureLine.map { .failed(spokenLine: $0) } ?? .done(spokenLine: "")
    }

    // MARK: - Open

    private static func open(targetName: String, browserName: String?) async -> Outcome {
        guard let openTarget = resolveOpenTarget(named: targetName) else {
            return .failed(spokenLine: "i don't know what \(targetName) is.")
        }
        switch openTarget {
        case .application(let applicationURL):
            // `open -a` with the full path: it launches the app or brings it
            // forward. Asking an app to activate itself can be ignored when
            // the request comes from a menu bar app.
            let openResult = await VesperProcessRunner.run(executablePath: "/usr/bin/open", arguments: ["-a", applicationURL.path])
            return openResult.exitStatus == 0
                ? .done(spokenLine: "")
                : .failed(spokenLine: "\(applicationURL.deletingPathExtension().lastPathComponent.lowercased()) wouldn't open.")
        case .settingsPage(let settingsPageURL, let displayName):
            let openResult = await VesperProcessRunner.run(executablePath: "/usr/bin/open", arguments: [settingsPageURL.absoluteString])
            return openResult.exitStatus == 0 ? .done(spokenLine: "") : .failed(spokenLine: "\(displayName) settings wouldn't open.")
        case .website(let websiteURL, let displayName):
            return await openInBrowser(websiteURL, displayName: displayName, browserName: browserName)
        }
    }

    /// Settings pages first ("bluetooth settings"), then an app named
    /// exactly that, then a well-known website, then an app whose name has
    /// those words ("chrome" → Google Chrome). Nil: nothing known.
    static func resolveOpenTarget(named targetName: String, searchingApplicationFolders applicationFolderURLs: [URL] = VesperApplicationLocator.applicationFolderURLs) -> OpenTarget? {
        let lowercasedTargetName = targetName.lowercased().trimmingCharacters(in: .whitespaces)

        if let settingsTarget = settingsTarget(named: lowercasedTargetName, searchingApplicationFolders: applicationFolderURLs) {
            return settingsTarget
        }
        let applicationName = applicationNameAliases[lowercasedTargetName] ?? lowercasedTargetName
        if let exactApplicationURL = VesperApplicationLocator.applicationURL(named: applicationName, searchingFolders: applicationFolderURLs),
           exactApplicationURL.deletingPathExtension().lastPathComponent.lowercased() == applicationName {
            return .application(exactApplicationURL)
        }
        if let knownWebsite = knownWebsites[lowercasedTargetName], let websiteURL = URL(string: knownWebsite.address) {
            return .website(websiteURL, displayName: knownWebsite.displayName)
        }
        if let partialApplicationURL = VesperApplicationLocator.applicationURL(named: applicationName, searchingFolders: applicationFolderURLs) {
            return .application(partialApplicationURL)
        }
        return nil
    }

    private static func settingsTarget(named lowercasedTargetName: String, searchingApplicationFolders applicationFolderURLs: [URL]) -> OpenTarget? {
        if lowercasedTargetName.range(of: #"^(?:system\s+)?(?:settings|preferences)$"#, options: .regularExpression) != nil {
            return VesperApplicationLocator.applicationURL(named: "System Settings", searchingFolders: applicationFolderURLs).map { .application($0) }
        }
        let pagePatterns = [#"^(.+?)\s+(?:settings|preferences|setting)$"#, #"^(?:system\s+)?settings\s+(?:for|of)\s+(.+)$"#]
        for pagePattern in pagePatterns {
            guard let pageRange = lowercasedTargetName.range(of: pagePattern, options: .regularExpression) else { continue }
            let pageName = String(lowercasedTargetName[pageRange])
                .replacingOccurrences(of: #"^(?:system\s+)?settings\s+(?:for|of)\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+(?:settings|preferences|setting)$"#, with: "", options: .regularExpression)
            if let settingsPage = settingsPages[pageName], let settingsPageURL = URL(string: "x-apple.systempreferences:" + settingsPage.identifier) {
                return .settingsPage(settingsPageURL, displayName: settingsPage.displayName)
            }
            // A page we don't know by name: Settings itself is still right.
            return VesperApplicationLocator.applicationURL(named: "System Settings", searchingFolders: applicationFolderURLs).map { .application($0) }
        }
        return nil
    }

    /// System Settings pages by the words people use (macOS 13+ identifiers;
    /// an unknown one still opens Settings).
    static let settingsPages: [String: (identifier: String, displayName: String)] = [
        "wifi": ("com.apple.wifi-settings-extension", "wi-fi"),
        "wi-fi": ("com.apple.wifi-settings-extension", "wi-fi"),
        "wi fi": ("com.apple.wifi-settings-extension", "wi-fi"),
        "bluetooth": ("com.apple.BluetoothSettings", "bluetooth"),
        "network": ("com.apple.Network-Settings.extension", "network"),
        "display": ("com.apple.Displays-Settings.extension", "display"),
        "displays": ("com.apple.Displays-Settings.extension", "display"),
        "screen": ("com.apple.Displays-Settings.extension", "display"),
        "sound": ("com.apple.Sound-Settings.extension", "sound"),
        "audio": ("com.apple.Sound-Settings.extension", "sound"),
        "battery": ("com.apple.Battery-Settings.extension", "battery"),
        "notification": ("com.apple.Notifications-Settings.extension", "notifications"),
        "notifications": ("com.apple.Notifications-Settings.extension", "notifications"),
        "focus": ("com.apple.Focus-Settings.extension", "focus"),
        "keyboard": ("com.apple.Keyboard-Settings.extension", "keyboard"),
        "trackpad": ("com.apple.Trackpad-Settings.extension", "trackpad"),
        "mouse": ("com.apple.Mouse-Settings.extension", "mouse"),
        "appearance": ("com.apple.Appearance-Settings.extension", "appearance"),
        "wallpaper": ("com.apple.Wallpaper-Settings.extension", "wallpaper"),
        "desktop": ("com.apple.Desktop-Settings.extension", "desktop and dock"),
        "dock": ("com.apple.Desktop-Settings.extension", "desktop and dock"),
        "control center": ("com.apple.ControlCenter-Settings.extension", "control center"),
        "privacy": ("com.apple.settings.PrivacySecurity.extension", "privacy and security"),
        "security": ("com.apple.settings.PrivacySecurity.extension", "privacy and security"),
        "privacy and security": ("com.apple.settings.PrivacySecurity.extension", "privacy and security"),
        "general": ("com.apple.systempreferences.GeneralSettings", "general"),
        "software update": ("com.apple.Software-Update-Settings.extension", "software update"),
        "update": ("com.apple.Software-Update-Settings.extension", "software update"),
        "storage": ("com.apple.settings.Storage", "storage"),
        "accessibility": ("com.apple.Accessibility-Settings.extension", "accessibility"),
        "siri": ("com.apple.Siri-Settings.extension", "siri"),
        "screen time": ("com.apple.Screen-Time-Settings.extension", "screen time"),
        "users": ("com.apple.Users-Groups-Settings.extension", "users and groups"),
        "login items": ("com.apple.LoginItems-Settings.extension", "login items"),
        "date and time": ("com.apple.Date-Time-Settings.extension", "date and time"),
        "time": ("com.apple.Date-Time-Settings.extension", "date and time"),
        "sharing": ("com.apple.Sharing-Settings.extension", "sharing"),
        "lock screen": ("com.apple.Lock-Screen-Settings.extension", "lock screen"),
        "touch id": ("com.apple.Touch-ID-Settings.extension", "touch id and password"),
        "password": ("com.apple.Touch-ID-Settings.extension", "touch id and password"),
        "internet accounts": ("com.apple.Internet-Accounts-Settings.extension", "internet accounts")
    ]

    /// Websites people open by name. Mail sites are left out on purpose.
    static let knownWebsites: [String: (address: String, displayName: String)] = [
        "youtube": ("https://www.youtube.com", "youtube"),
        "you tube": ("https://www.youtube.com", "youtube"),
        "yt": ("https://www.youtube.com", "youtube"),
        "youtube music": ("https://music.youtube.com", "youtube music"),
        "google": ("https://www.google.com", "google"),
        "github": ("https://github.com", "github"),
        "fiverr": ("https://www.fiverr.com", "fiverr"),
        // How on-device speech often hears "fiverr".
        "fibre": ("https://www.fiverr.com", "fiverr"),
        "fiber": ("https://www.fiverr.com", "fiverr"),
        "chatgpt": ("https://chatgpt.com", "chatgpt"),
        "chat gpt": ("https://chatgpt.com", "chatgpt"),
        "claude": ("https://claude.ai", "claude"),
        "netflix": ("https://www.netflix.com", "netflix"),
        "instagram": ("https://www.instagram.com", "instagram"),
        "insta": ("https://www.instagram.com", "instagram"),
        "twitter": ("https://x.com", "x"),
        "x": ("https://x.com", "x"),
        "reddit": ("https://www.reddit.com", "reddit"),
        "amazon": ("https://www.amazon.in", "amazon"),
        "flipkart": ("https://www.flipkart.com", "flipkart"),
        "linkedin": ("https://www.linkedin.com", "linkedin"),
        "wikipedia": ("https://www.wikipedia.org", "wikipedia"),
        "spotify": ("https://open.spotify.com", "spotify"),
        "whatsapp": ("https://web.whatsapp.com", "whatsapp"),
        "google maps": ("https://www.google.com/maps", "google maps"),
        "google drive": ("https://drive.google.com", "google drive"),
        "drive": ("https://drive.google.com", "google drive"),
        "google docs": ("https://docs.google.com", "google docs"),
        "leetcode": ("https://leetcode.com", "leetcode")
    ]

    /// Names people say that aren't the app's file name.
    private static let applicationNameAliases: [String: String] = [
        "vs code": "visual studio code",
        "vscode": "visual studio code",
        "app store": "app store",
        "terminal app": "terminal"
    ]

    // MARK: - Browser

    private static func openInBrowser(_ pageURL: URL, displayName: String, browserName: String? = nil) async -> Outcome {
        var openArguments: [String] = []
        if let browserName, let browserApplicationURL = VesperApplicationLocator.applicationURL(named: browserName) {
            openArguments += ["-a", browserApplicationURL.path]
        }
        openArguments.append(pageURL.absoluteString)
        let openResult = await VesperProcessRunner.run(executablePath: "/usr/bin/open", arguments: openArguments)
        return openResult.exitStatus == 0 ? .done(spokenLine: "") : .failed(spokenLine: "\(displayName) wouldn't open.")
    }

    static func youTubeSearchURL(for query: String) -> URL {
        var urlComponents = URLComponents(string: "https://www.youtube.com/results")!
        urlComponents.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return urlComponents.url!
    }

    static func googleSearchURL(for query: String) -> URL {
        var urlComponents = URLComponents(string: "https://www.google.com/search")!
        urlComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        return urlComponents.url!
    }

    /// Fetches the results page (like opening it), takes the first real
    /// video and opens it. If the page can't be read in time, the results
    /// page opens instead — still no Claude.
    private static func playTopYouTubeResult(for query: String) async -> Outcome {
        let searchPageURL = youTubeSearchURL(for: query)
        let fetchStartedAt = Date()
        if let videoIdentifier = await fetchTopYouTubeVideoIdentifier(searchPageURL: searchPageURL),
           let watchPageURL = URL(string: "https://www.youtube.com/watch?v=\(videoIdentifier)") {
            print(String(format: "⚡ YouTube: top result %@ for \"%@\" in %.2fs", videoIdentifier, query, Date().timeIntervalSince(fetchStartedAt)))
            let openOutcome = await openInBrowser(watchPageURL, displayName: "youtube")
            return openOutcome == .done(spokenLine: "") ? .done(spokenLine: "playing \(query).") : openOutcome
        }
        print(String(format: "⚡ YouTube: no result read for \"%@\" (%.2fs) — opening the results page", query, Date().timeIntervalSince(fetchStartedAt)))
        let openOutcome = await openInBrowser(searchPageURL, displayName: "youtube")
        return openOutcome == .done(spokenLine: "") ? .done(spokenLine: "here's youtube for \(query).") : openOutcome
    }

    private static func fetchTopYouTubeVideoIdentifier(searchPageURL: URL) async -> String? {
        var searchPageRequest = URLRequest(url: searchPageURL, timeoutInterval: 4)
        searchPageRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        searchPageRequest.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Skips the cookie consent page shown in some countries.
        searchPageRequest.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        guard let (pageData, pageResponse) = try? await URLSession.shared.data(for: searchPageRequest),
              (pageResponse as? HTTPURLResponse)?.statusCode == 200,
              let searchPageHTML = String(data: pageData, encoding: .utf8) else { return nil }
        return VesperInstantCommands.firstVideoIdentifier(inYouTubeSearchPage: searchPageHTML)
    }

    /// A new tab in the front app, or in the named browser (brought forward
    /// first; one that wasn't running opens with a fresh window anyway).
    private static func openNewTab(inBrowserNamed browserName: String?) async -> Outcome {
        guard let browserName else {
            return await pressKeys("cmd+t")
        }
        guard let browserApplicationURL = VesperApplicationLocator.applicationURL(named: browserName) else {
            return .failed(spokenLine: "i couldn't find \(browserName).")
        }
        let browserBundleIdentifier = Bundle(url: browserApplicationURL)?.bundleIdentifier
        let wasAlreadyRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == browserBundleIdentifier }
        _ = await VesperProcessRunner.run(executablePath: "/usr/bin/open", arguments: ["-a", browserApplicationURL.path])
        guard wasAlreadyRunning else { return .done(spokenLine: "") }
        // The keys must reach the browser, so wait until it's in front.
        let waitStartedAt = Date()
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != browserBundleIdentifier,
              Date().timeIntervalSince(waitStartedAt) < 2 {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browserBundleIdentifier else {
            return .failed(spokenLine: "\(browserName) didn't come forward.")
        }
        return await pressKeys("cmd+t")
    }

    private static func pressKeys(_ keyCombinationText: String) async -> Outcome {
        guard let keyCombination = VesperKeyCombination(parsing: keyCombinationText) else {
            return .failed(spokenLine: "that shortcut didn't work.")
        }
        await SystemScreenEventPoster().pressKeyCombination(keyCombination)
        return .done(spokenLine: "")
    }

    // MARK: - System

    private static func setDarkMode(isOn: Bool?) async -> Outcome {
        let newValueText = isOn.map { $0 ? "true" : "false" } ?? "not dark mode"
        let appleScript = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(newValueText)"
        let scriptResult = await VesperProcessRunner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", appleScript])
        guard scriptResult.exitStatus == 0 else {
            // The first time, macOS asks whether Vesper may control System Events.
            return .failed(spokenLine: "i couldn't switch it. allow vesper to control system events in settings, privacy, automation.")
        }
        return .done(spokenLine: VesperInstantCommands.spokenLine(for: .setDarkMode(isOn: isOn)))
    }

    private static func setWiFi(isOn: Bool) async -> Outcome {
        guard let wifiInterface = CWWiFiClient.shared().interface() else {
            return .failed(spokenLine: "this mac has no wi-fi.")
        }
        do {
            try wifiInterface.setPower(isOn)
        } catch {
            // The command-line way, if the framework refuses.
            let interfaceName = wifiInterface.interfaceName ?? "en0"
            let networkSetupResult = await VesperProcessRunner.run(
                executablePath: "/usr/sbin/networksetup",
                arguments: ["-setairportpower", interfaceName, isOn ? "on" : "off"]
            )
            guard networkSetupResult.exitStatus == 0 else {
                return .failed(spokenLine: "wi-fi wouldn't switch \(isOn ? "on" : "off").")
            }
        }
        return .done(spokenLine: VesperInstantCommands.spokenLine(for: .setWiFi(isOn: isOn)))
    }

    /// "82%, on battery, about 3 h 20 min left." → said the way a person would.
    static func speakableBatteryLine(_ batteryStatus: String) -> String {
        let spokenStatus = batteryStatus
            .replacingOccurrences(of: #"(\d+) h (\d+) min"#, with: "$1 hours $2 minutes", options: .regularExpression)
            .replacingOccurrences(of: "%", with: " percent")
        return spokenStatus.first?.isNumber == true ? "you're at \(spokenStatus)" : spokenStatus
    }
}
