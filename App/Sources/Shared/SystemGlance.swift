import SwiftUI
import ScannerKit
import MemoryKit
import BatteryKit
import ThermalKit
import HonestKit

/// A fast whole-machine snapshot for the Overview dashboard — every organ's
/// headline, cheap enough to read on load (heat uses the instant thermal
/// state, not the ~2s process sample).
struct SystemGlance: Sendable {
    struct Tile: Identifiable, Sendable {
        let id: String
        let section: AppSection
        let symbol: String
        let label: String
        let value: String
        let detail: String
        let tint: TileTint
    }

    enum TileTint: Sendable { case cool, warm, hot, danger, neutral }

    var tiles: [Tile] = []

    static func read() -> SystemGlance {
        var tiles: [Tile] = []

        if let disk = try? DiskAccounting.measure() {
            tiles.append(.init(id: "disk", section: .overview, symbol: "internaldrive",
                label: "Disk", value: disk.physicalUsedFraction.formatted(.percent.precision(.fractionLength(0))),
                detail: "\(disk.physicalFree.bytesFormatted) free",
                tint: disk.physicalUsedFraction > 0.9 ? .danger : disk.physicalUsedFraction > 0.75 ? .warm : .cool))
        }

        let heat = ThermalLevel(ProcessInfo.processInfo.thermalState)
        tiles.append(.init(id: "heat", section: .heat, symbol: "thermometer.medium",
            label: "Heat", value: heat.headline, detail: "thermal pressure",
            tint: tint(forRank: heat.rank)))

        if let mem = MemoryMonitor().read() {
            tiles.append(.init(id: "mem", section: .memory, symbol: "memorychip",
                label: "Memory", value: mem.usedFraction.formatted(.percent.precision(.fractionLength(0))),
                detail: mem.pressureHeadline.lowercased(),
                tint: tint(forRank: mem.pressure.rank)))
        }

        if let bat = BatteryMonitor().read() {
            tiles.append(.init(id: "bat", section: .battery, symbol: "battery.100percent",
                label: "Battery", value: "\(bat.healthPercent)%", detail: "\(bat.healthHeadline.lowercased()) · \(bat.cycleCount) cycles",
                tint: bat.healthPercent >= 90 ? .cool : bat.healthPercent >= 80 ? .neutral : bat.healthPercent >= 70 ? .warm : .danger))
        }

        return SystemGlance(tiles: tiles)
    }

    private static func tint(forRank rank: Int) -> TileTint {
        switch rank {
        case 0: .cool
        case 1: .neutral
        case 2: .warm
        default: .danger
        }
    }
}

extension SystemGlance.TileTint {
    var color: Color {
        switch self {
        case .cool: Theme.tierCache
        case .neutral: Theme.accent
        case .warm: Theme.tierRegenerable
        case .hot: Theme.tierRegenerable
        case .danger: Theme.tierData
        }
    }
}
