import Foundation
import Testing
@testable import ScannerKit
import RulesKit

@Suite("Reclaimable index")
struct ReclaimableIndexTests {
    /// Builds a fake home: a cache root with a specific child, a tool cache,
    /// and a dev tree with a real node_modules and an impostor.
    private func makeFixtureHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "stockpile-home-\(UUID().uuidString)")

        try fm.createDirectory(at: home.appending(path: "Library/Caches/com.spotify.client"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: home.appending(path: "Library/Caches/com.spotify.client/blob"))

        try fm.createDirectory(at: home.appending(path: ".npm"), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 2048).write(to: home.appending(path: ".npm/pkg.tgz"))

        let project = home.appending(path: "dev/webapp")
        try fm.createDirectory(at: project.appending(path: "node_modules/dep"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "package.json"))
        try Data(repeating: 3, count: 1024).write(to: project.appending(path: "node_modules/dep/index.js"))

        // Impostor: node_modules with no package.json sibling — user data.
        try fm.createDirectory(at: home.appending(path: "dev/photos/node_modules"), withIntermediateDirectories: true)

        // Canonical form (/private/var, not /var) so path comparisons hold.
        return home.resolvingSymlinksInPath()
    }

    @Test("Discovers direct paths and sweeps dev for named directories")
    func discovery() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let index = ReclaimableIndex(
            registry: try RulesRegistry.bundled(),
            cache: SizeCache(fileURL: FileManager.default.temporaryDirectory
                .appending(path: "cache-\(UUID().uuidString).json"))
        )
        let items = await index.build(home: home)
        let paths = Set(items.map(\.path))

        #expect(paths.contains(home.appending(path: ".npm").path))
        #expect(paths.contains(home.appending(path: "Library/Caches").path))
        #expect(paths.contains(home.appending(path: "dev/webapp/node_modules").path))
        // The impostor node_modules (no package.json) is user data — absent.
        #expect(!paths.contains(home.appending(path: "dev/photos/node_modules").path))
        // The Spotify cache is INSIDE Library/Caches — deduped, never counted twice.
        #expect(!paths.contains(home.appending(path: "Library/Caches/com.spotify.client").path))
    }

    @Test("Totals aggregate by tier and sizes are real")
    func totals() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let index = ReclaimableIndex(
            registry: try RulesRegistry.bundled(),
            cache: SizeCache(fileURL: FileManager.default.temporaryDirectory
                .appending(path: "cache-\(UUID().uuidString).json"))
        )
        let items = await index.build(home: home)
        let totals = ReclaimableIndex.totals(of: items)

        // 🟢 .npm (2048) + Library/Caches (4096) ≥ 6KB allocated.
        #expect(totals[.cache, default: 0] >= 6 * 1024)
        // 🟡 node_modules holds a 1KB file.
        #expect(totals[.regenerable, default: 0] >= 1024)
    }

    @Test("Generic parent rules badge cache children, specific rules win")
    func genericParentMatching() throws {
        let registry = try RulesRegistry.bundled()
        let home = URL(fileURLWithPath: "/Users/example")

        // A random app's cache dir — matched by the generic rule.
        let generic = registry.match(
            directoryAt: home.appending(path: "Library/Caches/com.random.app"), home: home)
        #expect(generic?.id == "generic-library-cache")
        #expect(generic?.tier == .cache)

        // Spotify has a specific rule — ordering makes it win over generic.
        let specific = registry.match(
            directoryAt: home.appending(path: "Library/Caches/com.spotify.client"), home: home)
        #expect(specific?.id == "spotify-cache")

        // XDG children too.
        let xdg = registry.match(directoryAt: home.appending(path: ".cache/some-tool"), home: home)
        #expect(xdg?.id == "generic-xdg-cache")
    }
}
