import Foundation
import Testing
@testable import ScannerKit

@Suite("Size cache")
struct SizeCacheTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "stockpile-cache-\(UUID().uuidString).json")
    }

    @Test("Hit requires an exact mtime match")
    func mtimeValidation() async {
        let cache = SizeCache(fileURL: tempFile())
        await cache.store(path: "/a/b", mtime: 100, size: 42)

        #expect(await cache.lookup(path: "/a/b", mtime: 100)?.size == 42)
        // mtime moved → stale → miss.
        #expect(await cache.lookup(path: "/a/b", mtime: 101) == nil)
        #expect(await cache.lookup(path: "/a/other", mtime: 100) == nil)
    }

    @Test("Invalidate forgets the subtree, inclusive, without prefix bleed")
    func subtreeInvalidation() async {
        let cache = SizeCache(fileURL: tempFile())
        await cache.store(path: "/home/dev", mtime: 1, size: 1)
        await cache.store(path: "/home/dev/project", mtime: 1, size: 2)
        await cache.store(path: "/home/devother", mtime: 1, size: 3)

        await cache.invalidate(subtree: "/home/dev")

        #expect(await cache.lookup(path: "/home/dev", mtime: 1) == nil)
        #expect(await cache.lookup(path: "/home/dev/project", mtime: 1) == nil)
        // "devother" shares the string prefix but is NOT inside the subtree.
        #expect(await cache.lookup(path: "/home/devother", mtime: 1)?.size == 3)
    }

    @Test("Survives a relaunch via flush")
    func persistence() async {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let first = SizeCache(fileURL: file)
        await first.store(path: "/persist/me", mtime: 7, size: 99)
        await first.flush()

        let second = SizeCache(fileURL: file)
        #expect(await second.lookup(path: "/persist/me", mtime: 7)?.size == 99)
    }

    @Test("LRU cap evicts oldest measurements, never grows unbounded")
    func lruCap() async {
        let cache = SizeCache(fileURL: tempFile(), maxEntries: 8)
        for i in 0..<20 {
            await cache.store(path: "/item/\(i)", mtime: 1, size: Int64(i))
        }
        // The most recent entries must survive; the earliest must be gone.
        #expect(await cache.lookup(path: "/item/19", mtime: 1) != nil)
        #expect(await cache.lookup(path: "/item/0", mtime: 1) == nil)
    }
}
