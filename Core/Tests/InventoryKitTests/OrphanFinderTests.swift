import Foundation
import Testing
@testable import InventoryKit

@Suite("Orphan finder")
struct OrphanFinderTests {
    @Test("Only confident reverse-DNS names are candidates")
    func bundleIDShape() {
        #expect(OrphanFinder.looksLikeBundleID("com.figma.Desktop"))
        #expect(OrphanFinder.looksLikeBundleID("net.maxon.app-manager"))
        #expect(!OrphanFinder.looksLikeBundleID("Google"))          // plain name
        #expect(!OrphanFinder.looksLikeBundleID("com.figma"))       // only 2 segments
        #expect(!OrphanFinder.looksLikeBundleID("My App Data"))     // spaces
    }

    @Test("Flags residue with no installed match; spares installed, system, and extensions")
    func discrimination() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "orphan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let appSupport = home.appending(path: "Library/Application Support")
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // A ghost: residue from a deleted app.
        try fm.createDirectory(at: appSupport.appending(path: "com.ghost.deleted"), withIntermediateDirectories: true)
        // Installed — must be spared.
        try fm.createDirectory(at: appSupport.appending(path: "com.figma.Desktop"), withIntermediateDirectories: true)
        // A helper extending an installed id — spared.
        try fm.createDirectory(at: appSupport.appending(path: "com.figma.Desktop.helper"), withIntermediateDirectories: true)
        // Apple — never an orphan.
        try fm.createDirectory(at: appSupport.appending(path: "com.apple.Something"), withIntermediateDirectories: true)
        // Plain name — too ambiguous, ignored.
        try fm.createDirectory(at: appSupport.appending(path: "Spotify"), withIntermediateDirectories: true)

        let orphans = OrphanFinder.find(installedBundleIDs: ["com.figma.Desktop"], home: home)
        let ids = Set(orphans.map(\.bundleID))

        #expect(ids.contains("com.ghost.deleted"))
        #expect(!ids.contains("com.figma.Desktop"))
        #expect(!ids.contains("com.figma.Desktop.helper"))
        #expect(!ids.contains("com.apple.Something"))
        #expect(!ids.contains("Spotify"))
    }
}
