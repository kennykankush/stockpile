import Foundation
import UserNotifications
import InventoryKit
import LedgerKit

/// Pearcleaner's Sentinel, honestly borrowed: watches the Trash, and when an
/// app lands there, checks whether it left residue behind — then tells you,
/// so its leftovers don't quietly become ghosts. ~nothing of RAM: one file
/// descriptor and a dispatch source.
@MainActor
final class TrashSentinel {
    static let shared = TrashSentinel()

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var knownApps: Set<String> = []

    private var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    }

    func start() {
        guard source == nil else { return }
        knownApps = currentTrashedApps()

        fd = open(trashURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in self?.trashChanged() }
        s.setCancelHandler { [weak self] in if let fd = self?.fd, fd >= 0 { close(fd) } }
        s.resume()
        source = s
    }

    private func trashChanged() {
        let now = currentTrashedApps()
        let newlyTrashed = now.subtracting(knownApps)
        knownApps = now
        for appPath in newlyTrashed { inspect(appPath) }
    }

    private func inspect(_ appPath: String) {
        let url = URL(fileURLWithPath: appPath)
        let name = url.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: url)?.bundleIdentifier
        // Look for residue OUTSIDE the trashed bundle (in the live Library).
        let leftovers = LeftoverLocator.find(bundleIdentifier: bundleID, appName: name)
            .filter { $0.confidence == .high }
        guard !leftovers.isEmpty else { return }
        let total = leftovers.reduce(0) { $0 + $1.sizeBytes }

        Task {
            await LedgerStore.shared.append(LedgerEvent(
                kind: .snapshot, title: "Trashed: \(name)",
                detail: "Left \(leftovers.count) leftover location\(leftovers.count == 1 ? "" : "s") (\(total.bytesFormatted)) — see Apps → Ghosts."))
            let content = UNMutableNotificationContent()
            content.title = "\(name) left leftovers behind"
            content.body = "\(total.bytesFormatted) of its data is still on disk. Open Stockpile → Apps to clear it."
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func currentTrashedApps() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        return Set(entries.filter { $0.hasSuffix(".app") }.map { trashURL.appending(path: $0).path })
    }
}
