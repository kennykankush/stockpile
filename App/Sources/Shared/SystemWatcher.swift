import SwiftUI
import UserNotifications
import ScannerKit
import MemoryKit
import ThermalKit
import HonestKit
import LedgerKit

/// The leap from "a thing you open" to "a thing that tells you." A light
/// background sampler that notices when an organ's pressure *worsens* across
/// a threshold — disk past 90%, memory to serious, thermal to serious — and
/// fires one native notification + a Ledger entry. Never nags: only worsening
/// transitions, debounced, and off means silent.
@MainActor
@Observable
final class SystemWatcher {
    static let shared = SystemWatcher()

    private var lastMemory: PressureLevel?
    private var lastThermalRank = 0
    private var lastDiskHot = false
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        Task { await requestAuthorizationIfNeeded() }
        Task { await loop() }
    }

    private func loop() async {
        while !Task.isCancelled {
            await sampleAndNotify()
            try? await Task.sleep(for: .seconds(90))
        }
    }

    private func sampleAndNotify() async {
        guard UserDefaults.standard.object(forKey: "watcher.enabled") as? Bool ?? true else { return }

        // Memory — worsening into serious/critical.
        if let mem = MemoryMonitor().read() {
            let level = mem.pressure
            if let prev = lastMemory, level.rank > prev.rank, level.rank >= PressureLevel.serious.rank {
                await notify("Memory \(mem.pressureHeadline.lowercased())",
                             "Genuinely in use: \(mem.used.bytesFormatted) of \(mem.total.bytesFormatted). \(mem.available.bytesFormatted) still available.",
                             ledger: "Memory crossed into \(level.rawValue)")
            }
            lastMemory = level
        }

        // Thermal — worsening into serious/critical.
        let thermalRank = ThermalLevel(ProcessInfo.processInfo.thermalState).rank
        if thermalRank > lastThermalRank, thermalRank >= ThermalLevel.serious.rank {
            await notify("Running hot", "Thermal pressure rose. Open Stockpile → Heat to see what's driving it.",
                         ledger: "Thermal crossed into rank \(thermalRank)")
        }
        lastThermalRank = thermalRank

        // Disk — crossing the 90% line.
        if let disk = try? DiskAccounting.measure() {
            let hot = disk.physicalUsedFraction >= 0.90
            if hot && !lastDiskHot {
                await notify("Disk almost full",
                             "\(disk.physicalUsedFraction.formatted(.percent.precision(.fractionLength(0)))) used. Stockpile → Caches has reclaimable space.",
                             ledger: "Disk crossed 90% used")
            }
            lastDiskHot = hot
        }
    }

    private func notify(_ title: String, _ body: String, ledger: String) async {
        await LedgerStore.shared.append(LedgerEvent(kind: .snapshot, title: "⚠︎ \(title)", detail: ledger))
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}
