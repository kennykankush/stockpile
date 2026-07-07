import Foundation
import RulesKit

/// One recognized reclaimable location, sized.
public struct ReclaimableItem: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let rule: Rule
    public let sizeBytes: Int64
}

/// Finds everything the registry recognizes as reclaimable — without the
/// user having to descend to it.
///
/// Two discovery passes:
/// 1. Direct: every `homeRelativePath` rule that exists on disk.
/// 2. Sweep: a cheap directories-only walk of the dev roots (default `~/dev`)
///    hunting `directoryName` rules (node_modules, .build, target…). Only
///    directories are visited — never files — so the sweep is thousands of
///    stats, not millions. Matched directories are not descended into.
///
/// Results are prefix-deduplicated (a Spotify cache inside `~/Library/Caches`
/// is not counted twice) and sized through the shared cache.
public struct ReclaimableIndex: Sendable {
    private let registry: RulesRegistry
    private let cache: SizeCache

    public init(registry: RulesRegistry, cache: SizeCache = .shared) {
        self.registry = registry
        self.cache = cache
    }

    public func build(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sweepRoots: [URL]? = nil,
        maxSweepDepth: Int = 6
    ) async -> [ReclaimableItem] {
        let fm = FileManager.default
        var found: [(URL, Rule)] = []

        // Pass 1 — direct paths.
        for rule in registry.rules where rule.match.kind == .homeRelativePath {
            let url = home.appending(path: rule.match.value)
            if fm.fileExists(atPath: url.path) {
                found.append((url, rule))
            }
        }

        // Pass 2 — sweep dev roots for named directories.
        let roots = sweepRoots ?? [home.appending(path: "dev")]
        for root in roots where fm.fileExists(atPath: root.path) {
            sweep(root, home: home, depth: maxSweepDepth, into: &found)
        }

        // Canonicalize (e.g. /var vs /private/var) so dedup compares like
        // with like, then prefix-dedup: keep ancestors, drop anything inside
        // a counted item.
        let canonical = found.map { (url, rule) in (url.resolvingSymlinksInPath(), rule) }
        let sorted = canonical.sorted { $0.0.path.count < $1.0.path.count }
        var kept: [(URL, Rule)] = []
        for (url, rule) in sorted {
            let inside = kept.contains { url.path.hasPrefix($0.0.path + "/") }
            if !inside { kept.append((url, rule)) }
        }

        // Size everything through the cache.
        let items = await withTaskGroup(of: ReclaimableItem.self) { group in
            for (url, rule) in kept {
                group.addTask {
                    let mtime = AllocatedSize.modificationTime(of: url)
                    let size: Int64
                    if let hit = await self.cache.lookup(path: url.path, mtime: mtime) {
                        size = hit.size
                    } else {
                        size = AllocatedSize.measure(url)
                        await self.cache.store(path: url.path, mtime: mtime, size: size)
                    }
                    return ReclaimableItem(path: url.path, rule: rule, sizeBytes: size)
                }
            }
            var collected: [ReclaimableItem] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.sizeBytes > $1.sizeBytes }
        }

        await cache.flush()
        return items
    }

    /// Totals by tier — the Reclaimable Number.
    public static func totals(of items: [ReclaimableItem]) -> [Tier: Int64] {
        items.reduce(into: [:]) { acc, item in
            acc[item.rule.tier, default: 0] += item.sizeBytes
        }
    }

    /// Directories-only recursive walk. Skips `.git`, never descends into a
    /// matched directory, and never touches files.
    private func sweep(_ dir: URL, home: URL, depth: Int, into found: inout [(URL, Rule)]) {
        guard depth > 0 else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        autoreleasepool {
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if child.lastPathComponent == ".git" { continue }

                if let rule = registry.match(directoryAt: child, home: home),
                   rule.match.kind == .directoryName {
                    found.append((child, rule))
                    continue // matched — don't descend into it
                }
                sweep(child, home: home, depth: depth - 1, into: &found)
            }
        }
    }
}
