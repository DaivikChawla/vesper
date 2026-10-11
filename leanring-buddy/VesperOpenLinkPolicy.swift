//
//  VesperOpenLinkPolicy.swift
//  leanring-buddy
//
//  Which links Vesper may open without asking, and which apps she may open
//  them in.
//
//  The risk with opening a link is sending something from the screen (a
//  code, a message) to a stranger's website inside the address, e.g.
//  https://evil.example/?d=<secret> or https://evil.example/<secret>. A
//  well-known site (YouTube, Google) receiving a search is harmless, so:
//
//  - A known site opens at once, searches included. Known means a short
//    built-in list plus every site (full host) the user has said yes to.
//  - Anything else asks first, naming the site: an unknown site, plain http
//    on an unknown site, or a known site's link that carries another
//    address inside it (a redirect like google.com/url?q=https://evil...).
//  - Parts of big sites that strangers publish on — Google Apps Script,
//    Google and Microsoft Forms, Google Sites — are never "known": whoever
//    made the script or form receives what's in the address.
//  - Approvals are per host, not per domain: a yes to one stranger's page
//    on vercel.app or github.io mustn't cover every other page there.
//
//  Apps: only apps installed in the standard Applications folders can be
//  opened by name, so a tag can't launch a bundle sitting in Downloads.
//

import Foundation

enum VesperOpenLinkDecision: Equatable {
    case openNow(URL)
    /// She asks first. `siteHost` is the site to name in the question and
    /// to remember once the user says yes.
    case needsConfirmation(URL, siteHost: String)
    case refused
}

enum VesperOpenLinkPolicy {
    /// Sites common enough that opening them (and searching on them) can't
    /// leak anything to a stranger.
    static let builtInKnownSiteDomains: Set<String> = [
        "youtube.com", "youtu.be", "google.com", "google.co.in", "bing.com", "duckduckgo.com",
        "wikipedia.org", "github.com", "stackoverflow.com", "reddit.com",
        "x.com", "twitter.com", "linkedin.com", "facebook.com", "instagram.com", "whatsapp.com",
        "netflix.com", "spotify.com", "music.apple.com", "apple.com", "icloud.com",
        "amazon.com", "amazon.in", "openai.com", "chatgpt.com", "claude.ai", "anthropic.com",
        "notion.so", "figma.com", "medium.com", "twitch.tv", "discord.com", "slack.com",
        "zoom.us", "dropbox.com", "microsoft.com", "office.com", "live.com", "bbc.com", "imdb.com"
    ]

    /// Hosts on known domains where strangers publish things that receive
    /// data: a script or form's owner sees everything in the address.
    private static let strangerPublishedHosts: Set<String> = [
        "script.google.com", "script.googleusercontent.com", "sites.google.com", "forms.gle",
        "forms.office.com", "forms.microsoft.com", "googleusercontent.com"
    ]

    /// File and framework endings that look like web addresses but aren't
    /// ("next.js tutorial" is a search, not a link).
    private static let nonAddressEndings: Set<String> = [
        "js", "ts", "py", "md", "txt", "json", "swift", "rb", "go", "rs", "sh", "css", "html", "pdf", "png", "jpg"
    ]

    static func decision(
        for websiteURL: URL,
        approvedSiteDomains: Set<String>,
        isConversationTainted: Bool
    ) -> VesperOpenLinkDecision {
        guard let scheme = websiteURL.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = websiteURL.host?.lowercased(), !host.isEmpty else {
            return .refused
        }
        let siteHost = siteHost(ofHost: host)
        // Once untrusted text (an invite, a looked-up page) is in the
        // conversation, only the built-in sites open without asking.
        let isKnownSite = isBuiltInKnownSite(websiteURL, siteHost: siteHost)
            || (!isConversationTainted && approvedSiteDomains.contains(siteHost))

        if isKnownSite && !carriesAnotherAddress(websiteURL) {
            return .openNow(upgradedToHTTPS(websiteURL))
        }
        return .needsConfirmation(websiteURL, siteHost: siteHost)
    }

    /// "www.fiverr.com" → "fiverr.com"; "someone.vercel.app" stays as is.
    static func siteHost(ofHost host: String) -> String {
        let lowercasedHost = host.lowercased()
        return lowercasedHost.hasPrefix("www.") ? String(lowercasedHost.dropFirst(4)) : lowercasedHost
    }

    private static func isBuiltInKnownSite(_ websiteURL: URL, siteHost: String) -> Bool {
        let isStrangerPublished = strangerPublishedHosts.contains { strangerHost in
            siteHost == strangerHost || siteHost.hasSuffix("." + strangerHost)
        }
        // Google Forms live under docs.google.com/forms.
        let isGoogleForm = siteHost == "docs.google.com" && websiteURL.path.lowercased().hasPrefix("/forms")
        if isStrangerPublished || isGoogleForm {
            return false
        }
        return builtInKnownSiteDomains.contains { knownDomain in
            siteHost == knownDomain || siteHost.hasSuffix("." + knownDomain)
        }
    }

    /// True when the part after the host holds another web address — the
    /// shape of a redirect that would pass data on to a different site.
    private static func carriesAnotherAddress(_ websiteURL: URL) -> Bool {
        var addressAfterHost = websiteURL.path
        if let query = websiteURL.query { addressAfterHost += "?" + query }
        if let fragment = websiteURL.fragment { addressAfterHost += "#" + fragment }
        let decodedAddressAfterHost = (addressAfterHost.removingPercentEncoding ?? addressAfterHost).lowercased()
        if decodedAddressAfterHost.contains("http:")
            || decodedAddressAfterHost.contains("https:")
            || decodedAddressAfterHost.contains("//")
            || decodedAddressAfterHost.contains("www.") {
            return true
        }
        // A bare address in the query or fragment ("redirect?q=evil.example/?d=x").
        var queryAndFragment = websiteURL.query ?? ""
        if let fragment = websiteURL.fragment { queryAndFragment += "#" + fragment }
        let decodedQueryAndFragment = (queryAndFragment.removingPercentEncoding ?? queryAndFragment).lowercased()
        let addressPattern = try! NSRegularExpression(pattern: #"\b[a-z0-9-]{2,}\.([a-z]{2,})\b"#)
        let addressMatches = addressPattern.matches(in: decodedQueryAndFragment, range: NSRange(decodedQueryAndFragment.startIndex..., in: decodedQueryAndFragment))
        return addressMatches.contains { addressMatch in
            guard let endingRange = Range(addressMatch.range(at: 1), in: decodedQueryAndFragment) else { return false }
            return !nonAddressEndings.contains(String(decodedQueryAndFragment[endingRange]))
        }
    }

    private static func upgradedToHTTPS(_ websiteURL: URL) -> URL {
        guard websiteURL.scheme?.lowercased() == "http",
              var urlComponents = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false) else {
            return websiteURL
        }
        urlComponents.scheme = "https"
        return urlComponents.url ?? websiteURL
    }
}

/// The sites (full hosts, without "www.") the user has said yes to opening,
/// one per line in ~/Library/Application Support/Vesper/open-approved-sites.txt.
/// After one yes, that site opens without asking.
final class VesperApprovedSitesStore {
    let approvedSitesFileURL: URL

    init(approvedSitesFileURL: URL = VesperApprovedSitesStore.defaultApprovedSitesFileURL) {
        self.approvedSitesFileURL = approvedSitesFileURL
    }

    static var defaultApprovedSitesFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent("Vesper", isDirectory: true)
            .appendingPathComponent("open-approved-sites.txt")
    }

    func loadApprovedSiteDomains() -> Set<String> {
        guard let fileContents = try? String(contentsOf: approvedSitesFileURL, encoding: .utf8) else { return [] }
        return Set(fileContents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    func approveSiteDomain(_ siteDomain: String) {
        var approvedSiteDomains = loadApprovedSiteDomains()
        guard approvedSiteDomains.insert(siteDomain.lowercased()).inserted else { return }
        let fileContents = approvedSiteDomains.sorted().joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: approvedSitesFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileContents.write(to: approvedSitesFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Couldn't save approved site \(siteDomain): \(error.localizedDescription)")
        }
    }
}

/// Finds an installed app by name, only in the standard Applications
/// folders — never a bundle in Downloads or anywhere else on disk.
enum VesperApplicationLocator {
    static var applicationFolderURLs: [URL] {
        let homeApplicationsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            // Finder lives here.
            "/System/Library/CoreServices"
        ].map { URL(fileURLWithPath: $0) } + [homeApplicationsURL]
    }

    /// True for an app *name* ("Google Chrome", "Music.app") — false for
    /// anything path-like or with a scheme.
    static func isPlainApplicationName(_ applicationName: String) -> Bool {
        let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespaces)
        return !trimmedApplicationName.isEmpty
            && !trimmedApplicationName.contains("/")
            && !trimmedApplicationName.contains("~")
            && !trimmedApplicationName.contains(":")
            && !trimmedApplicationName.hasPrefix(".")
    }

    /// "Google Chrome" or "chrome" → /Applications/Google Chrome.app. An
    /// exact name wins; otherwise one app whose name contains every word.
    static func applicationURL(named applicationName: String, searchingFolders folderURLs: [URL] = applicationFolderURLs) -> URL? {
        guard isPlainApplicationName(applicationName) else { return nil }
        var requestedName = applicationName.trimmingCharacters(in: .whitespaces).lowercased()
        if requestedName.hasSuffix(".app") {
            requestedName = String(requestedName.dropLast(4))
        }
        let requestedWords = requestedName.split(separator: " ").map(String.init)

        var partialMatchURLs: [URL] = []
        for folderURL in folderURLs {
            guard let folderEntries = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { continue }
            for entryURL in folderEntries where entryURL.pathExtension == "app" {
                let installedName = entryURL.deletingPathExtension().lastPathComponent.lowercased()
                if installedName == requestedName {
                    return entryURL
                }
                let installedWords = Set(installedName.split(separator: " ").map(String.init))
                if requestedWords.allSatisfy(installedWords.contains) {
                    partialMatchURLs.append(entryURL)
                }
            }
        }
        // "chrome" could be Google Chrome or Chrome Remote Desktop: take the
        // shortest name, the most likely meaning.
        return partialMatchURLs.min { firstURL, secondURL in
            firstURL.lastPathComponent.count < secondURL.lastPathComponent.count
        }
    }
}
