import Foundation

/// System thermal pressure — the honest headline. Read from
/// `ProcessInfo.thermalState` (official, no-sudo). Absolute °C is deliberately
/// NOT here: on Apple Silicon it needs per-SoC SMC keys that break every chip
/// generation, so it must never be load-bearing.
public enum ThermalLevel: String, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .fair
        }
    }

    /// 0 = cool, 3 = throttling. For ordering and forecast math.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public var headline: String {
        switch self {
        case .nominal: "Running cool"
        case .fair: "Warming up"
        case .serious: "Running hot"
        case .critical: "Throttling"
        }
    }
}

/// One process's contribution to active compute load. Heat is one shared pool
/// the OS never attributes to a process, so this is a MODEL: a process's share
/// of active CPU load is its honest share of the heat you're generating — not
/// "its degrees." Labelled as an estimate everywhere it surfaces.
public struct ProcessLoad: Sendable, Identifiable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let command: String
    /// Instantaneous %CPU (can exceed 100 on multiple cores).
    public let cpuPercent: Double

    public init(pid: Int32, command: String, cpuPercent: Double) {
        self.pid = pid
        self.command = command
        self.cpuPercent = cpuPercent
    }
}

/// A full thermal snapshot: the pressure level plus who's driving it.
public struct ThermalReading: Sendable {
    public let level: ThermalLevel
    public let processes: [ProcessLoad]

    /// Total active CPU across sampled processes — the denominator for shares.
    public var totalActiveCPU: Double { processes.reduce(0) { $0 + $1.cpuPercent } }

    /// A process's share of active load = its honest share of the heat.
    public func share(of load: ProcessLoad) -> Double {
        totalActiveCPU > 0 ? load.cpuPercent / totalActiveCPU : 0
    }

    public init(level: ThermalLevel, processes: [ProcessLoad]) {
        self.level = level
        self.processes = processes
    }
}
