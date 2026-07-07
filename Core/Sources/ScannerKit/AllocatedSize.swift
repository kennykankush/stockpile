import Foundation

/// Honest sizing: allocated bytes on disk, symlinks never followed, file
/// contents never read (iCloud dataless files stay dataless).
///
/// Enumeration is batched inside autorelease pools — Foundation's enumerator
/// autoreleases every URL it yields, and on million-file trees that spike
/// would otherwise hold gigabytes until the walk finishes.
public enum AllocatedSize {
    private static let keys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
    ]

    public static func measure(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { return 0 }
        guard values?.isDirectory == true else {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var finished = false
        while !finished {
            autoreleasepool {
                var batch = 0
                while batch < 2048 {
                    guard let fileURL = enumerator.nextObject() as? URL else {
                        finished = true
                        return
                    }
                    batch += 1
                    guard let v = try? fileURL.resourceValues(forKeys: keys),
                          v.isRegularFile == true else { continue }
                    total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    /// The mtime used for cache validation.
    public static func modificationTime(of url: URL) -> TimeInterval {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
}
