import Foundation
import HonestKit

/// The honest RAM picture — the purgeable lesson applied to memory. "Used"
/// as most tools show it includes cached files, which are evictable the
/// instant something needs the space (exactly like purgeable disk). The
/// honest number is what's genuinely unavailable.
public struct MemoryReading: Sendable, Hashable {
    public let total: Int64
    public let free: Int64
    /// File-backed + purgeable + speculative pages — droppable on demand.
    public let cached: Int64
    /// Anonymous app memory (can't be evicted, only compressed/swapped).
    public let app: Int64
    public let wired: Int64
    public let compressed: Int64

    public init(total: Int64, free: Int64, cached: Int64, app: Int64, wired: Int64, compressed: Int64) {
        self.total = total
        self.free = free
        self.cached = cached
        self.app = app
        self.wired = wired
        self.compressed = compressed
    }

    /// Genuinely unavailable = app + wired + compressed. Cached & free are not.
    public var used: Int64 { app + wired + compressed }
    /// What you can actually use right now = free + evictable cached.
    public var available: Int64 { free + cached }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// The naive figure other tools show — total minus free, cached included.
    public var naiveUsedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }

    /// The dual-number story as a HonestMetric.
    public var metric: HonestMetric {
        HonestMetric(
            title: "Memory in use",
            naive: Double(total - free),
            honest: Double(used),
            caveat: "The naive number counts cached files as \"used\" — but they're dropped the instant an app needs the space, exactly like purgeable disk.",
            confidence: .measured,
            unit: .bytes
        )
    }

    /// Pressure derived from how much is genuinely unavailable + compression.
    /// An estimate (macOS exposes no clean no-sudo pressure-level query).
    public var pressure: PressureLevel {
        let usedFrac = usedFraction
        let compressionFrac = total > 0 ? Double(compressed) / Double(total) : 0
        if usedFrac > 0.90 || compressionFrac > 0.25 { return .critical }
        if usedFrac > 0.75 || compressionFrac > 0.15 { return .serious }
        if usedFrac > 0.55 { return .fair }
        return .nominal
    }

    public var pressureHeadline: String {
        switch pressure {
        case .nominal: "Plenty free"
        case .fair: "Comfortable"
        case .serious: "Getting tight"
        case .critical: "Under pressure"
        }
    }
}
