import Foundation
import RulesKit

/// One row in a Descend view: a child of the directory being inspected,
/// sized and annotated.
public struct ScannedEntry: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// Allocated bytes on disk (not logical size — APFS clones and sparse
    /// files report what they actually occupy).
    public let sizeBytes: Int64
    /// When this size was measured — from cache, this can be in the past.
    public let measuredAt: Date
    /// The matched rule, if Stockpile recognizes this entry. nil = user data.
    public let rule: Rule?
}

/// Sizes the children of a directory concurrently, annotates each against
/// the rules registry, and reuses cached measurements when mtimes match.
public struct DirectoryScanner: Sendable {
    private let registry: RulesRegistry
    private let cache: SizeCache

    public init(registry: RulesRegistry, cache: SizeCache = .shared) {
        self.registry = registry
        self.cache = cache
    }

    /// Returns the immediate children of `url`, largest first. Cached
    /// measurements are trusted while mtimes match; misses are measured
    /// and stored. One flush per call — never per entry.
    public func children(of url: URL) async throws -> [ScannedEntry] {
        let fm = FileManager.default
        let childURLs = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        )

        let entries = await withTaskGroup(of: ScannedEntry?.self) { group in
            for child in childURLs {
                group.addTask {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let isSymlink = values?.isSymbolicLink ?? false
                    let isDirectory = (values?.isDirectory ?? false) && !isSymlink
                    let mtime = AllocatedSize.modificationTime(of: child)

                    let size: Int64
                    let measuredAt: Date
                    if let hit = await self.cache.lookup(path: child.path, mtime: mtime) {
                        size = hit.size
                        measuredAt = hit.measuredAt
                    } else {
                        size = AllocatedSize.measure(child)
                        measuredAt = .now
                        await self.cache.store(path: child.path, mtime: mtime, size: size)
                    }

                    return ScannedEntry(
                        url: child,
                        name: child.lastPathComponent,
                        isDirectory: isDirectory,
                        sizeBytes: size,
                        measuredAt: measuredAt,
                        rule: isDirectory ? self.registry.match(directoryAt: child) : nil
                    )
                }
            }
            var collected: [ScannedEntry] = []
            for await entry in group {
                if let entry { collected.append(entry) }
            }
            return collected.sorted { $0.sizeBytes > $1.sizeBytes }
        }

        await cache.flush()
        return entries
    }

    /// Forget measurements under a path — the Refresh action.
    public func invalidate(subtree url: URL) async {
        await cache.invalidate(subtree: url.path)
        await cache.flush()
    }
}
