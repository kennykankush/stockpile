import SwiftUI
import ScannerKit
import WidgetKit
import ThermalKit
import MemoryKit
import BatteryKit

/// Who's running — the "quit Spotify before clearing its cache" guard.
enum RunningApps {
    static func app(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    /// Terminates an app and waits until it has actually exited, polling
    /// `isTerminated` rather than guessing with a fixed sleep (F-008). Returns
    /// true if the app is gone; false if it didn't quit within the timeout, so
    /// the caller can abort rather than clear a cache the app is still writing.
    static func quitAndWait(_ app: NSRunningApplication, timeout: Duration = .seconds(6)) async -> Bool {
        app.terminate()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if app.isTerminated { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return app.isTerminated
    }
}

/// Shares the honest numbers with the widget via the App Group container.
/// Harmless no-op until the group entitlement exists.
enum WidgetBridge {
    static let groupID = "483LU3J5WJ.com.hadimulia.stockpile"

    struct Snapshot: Codable {
        let date: Date
        let physicalUsedFraction: Double
        let effectiveUsedFraction: Double
        let physicalFree: Int64
        let purgeable: Int64
        let reclaimable: Int64
        // The other three organs — optional so older payloads still decode.
        var thermalRank: Int?
        var memoryUsedFraction: Double?
        var batteryHealth: Int?
    }

    static func export(accounting: DiskAccounting, reclaimable: Int64) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else { return }
        let snapshot = Snapshot(
            date: .now,
            physicalUsedFraction: accounting.physicalUsedFraction,
            effectiveUsedFraction: accounting.effectiveUsedFraction,
            physicalFree: accounting.physicalFree,
            purgeable: accounting.purgeable,
            reclaimable: reclaimable,
            thermalRank: ThermalLevel(ProcessInfo.processInfo.thermalState).rank,
            memoryUsedFraction: MemoryMonitor().read()?.usedFraction,
            batteryHealth: BatteryMonitor().read()?.healthPercent
        )
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: container.appending(path: "snapshot.json"), options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// Permission state, probed — never assumed, never nagging.
/// Ask once, deep-link once, respect the dismissal.
enum Permissions {
    /// Full Disk Access probe: Safari's container is TCC-protected, so a
    /// successful directory read means FDA is granted.
    static var hasFullDiskAccess: Bool {
        let probe = NSHomeDirectory() + "/Library/Safari"
        return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
    }

    static let fullDiskSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}

/// Flushes the size cache's RAM copy when macOS signals memory pressure.
/// The disk copy remains, so nothing is re-measured — only re-read.
@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    private var source: DispatchSourceMemoryPressure?

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler {
            Task { await SizeCache.shared.releaseMemory() }
        }
        s.resume()
        source = s
    }
}

/// One-time setup card: shown until FDA is granted or the user dismisses it.
struct SetupCard: View {
    @AppStorage("setup.fda.dismissed") private var dismissed = false
    @State private var granted = Permissions.hasFullDiskAccess

    var body: some View {
        if !granted && !dismissed {
            Card(padding: 18) {
                HStack(spacing: 14) {
                    IconTile(symbol: "lock.open", tint: Theme.tierRegenerable, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Grant Full Disk Access — once")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Lets Stockpile measure protected folders (Mail, Safari, some caches). One grant in System Settings; Stockpile never asks again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(Permissions.fullDiskSettingsURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent.opacity(0.8))
                    .controlSize(.small)
                    Button("Later") { dismissed = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                // Re-probe while visible so the card melts away on grant.
                while !granted && !dismissed {
                    try? await Task.sleep(for: .seconds(3))
                    granted = Permissions.hasFullDiskAccess
                }
            }
        }
    }
}
