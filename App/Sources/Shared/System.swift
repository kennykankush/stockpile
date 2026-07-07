import SwiftUI
import ScannerKit

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
