import Foundation
import ScannerKit

/// Residue from an app that's already gone — the leftover of a *deleted*
/// app, which no uninstaller can catch because the app isn't there to select.
public struct Orphan: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let bundleID: String
    public let sizeBytes: Int64

    public init(path: String, bundleID: String, sizeBytes: Int64) {
        self.path = path
        self.bundleID = bundleID
        self.sizeBytes = sizeBytes
    }
}

/// Finds reverse-DNS residue in the Library that matches NO installed app and
/// isn't system/Apple — i.e. leftovers from software you removed long ago
/// (Pearcleaner's "orphaned files"). Deliberately conservative: only
/// confident `com.x.y`-style names are considered, never bare display names
/// (too ambiguous), and a broad system denylist protects Apple/framework
/// data. Findings are SUGGESTIONS — shown with paths, Trash-only, reviewable.
public enum OrphanFinder {
    /// Library subfolders where per-app residue lives, and whether entries
    /// there carry a file extension to strip.
    private static let scanDirs: [(String, String?)] = [
        ("Library/Application Support", nil),
        ("Library/Caches", nil),
        ("Library/HTTPStorages", nil),
        ("Library/WebKit", nil),
        ("Library/Containers", nil),
        ("Library/Group Containers", nil),
        ("Library/Preferences", "plist"),
        ("Library/Saved Application State", "savedState"),
    ]

    /// Prefixes that are NEVER orphans — Apple, the OS, and common frameworks
    /// whose data outlives any single app.
    private static let systemPrefixes = [
        "com.apple.", "group.com.apple.", "apple.", "org.swift.",
        "com.crashlytics", "com.google.SoftwareUpdate", "com.microsoft.autoupdate",
    ]

    public static func find(
        installedBundleIDs: Set<String>,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Orphan] {
        let fm = FileManager.default
        // Normalize installed IDs for prefix-aware matching (group containers
        // and helpers often extend a base id).
        let installed = installedBundleIDs.map { $0.lowercased() }

        var orphans: [Orphan] = []
        var seen = Set<String>()

        for (dir, ext) in scanDirs {
            let base = home.appending(path: dir)
            guard let entries = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for entry in entries {
                var token = entry
                if let ext, token.hasSuffix(".\(ext)") { token = String(token.dropLast(ext.count + 1)) }

                guard looksLikeBundleID(token) else { continue }
                let lower = token.lowercased()
                if systemPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
                // Installed if any installed id equals it or it extends one.
                if installed.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { continue }

                let url = base.appending(path: entry)
                guard seen.insert(url.path).inserted else { continue }
                orphans.append(Orphan(path: url.path, bundleID: token, sizeBytes: AllocatedSize.measure(url)))
            }
        }
        return orphans.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// A real reverse-DNS id: at least two dot-separated alphanumeric-ish
    /// segments, no spaces. Excludes plain folder names like "Google" or
    /// "Firefox" which are too ambiguous to call orphans.
    static func looksLikeBundleID(_ s: String) -> Bool {
        guard !s.contains(" ") else { return false }
        let parts = s.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }
}
