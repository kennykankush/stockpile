import Foundation

/// A machine's identity — static, scanned once on connect. CPU-Z-lite.
public struct HardwareInfo: Codable, Sendable, Hashable {
    public var cpuModel: String
    public var cores: Int
    public var ramTotal: Int64
    public var gpu: String?
    public var osName: String
    public var kernel: String

    public init(cpuModel: String, cores: Int, ramTotal: Int64, gpu: String?, osName: String, kernel: String) {
        self.cpuModel = cpuModel; self.cores = cores; self.ramTotal = ramTotal
        self.gpu = gpu; self.osName = osName; self.kernel = kernel
    }
}

/// One container on a machine running Docker — the homelab killer view.
/// Live CPU/memory come from `docker stats` (Beszel-style per-container view).
public struct Container: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let status: String
    public var cpuPercent: Double?     // 0…100+ (can exceed 100 across cores)
    public var memUsed: Int64?         // bytes
    public var memPercent: Double?     // 0…100
    /// Best-effort health parsed from the status string.
    public var isHealthy: Bool { !status.lowercased().contains("unhealthy") && status.lowercased().hasPrefix("up") }

    public init(name: String, status: String, cpuPercent: Double? = nil, memUsed: Int64? = nil, memPercent: Double? = nil) {
        self.name = name; self.status = status
        self.cpuPercent = cpuPercent; self.memUsed = memUsed; self.memPercent = memPercent
    }
}

/// One storage volume on a machine (a drive letter or a mount point).
public struct DiskVolume: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String        // "C:", "D:", "/", "/data"
    public let total: Int64
    public let used: Int64
    public let free: Int64

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public init(name: String, total: Int64, used: Int64, free: Int64) {
        self.name = name; self.total = total; self.used = used; self.free = free
    }
}

/// A discrete GPU's live stats — read from nvidia-smi. Present only when the
/// machine has an NVIDIA GPU reachable over the probe.
public struct GPUStats: Codable, Sendable, Hashable {
    public let name: String
    public let utilization: Double      // 0…1
    public let memUsed: Int64           // bytes
    public let memTotal: Int64          // bytes
    public let tempC: Double?
    public let powerDraw: Double?       // watts
    public let powerLimit: Double?      // watts
    public let fanPercent: Double?      // 0…1
    public let clockMHz: Int?

    public var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    public var powerFraction: Double {
        guard let d = powerDraw, let l = powerLimit, l > 0 else { return 0 }
        return min(d / l, 1)
    }

    public init(name: String, utilization: Double, memUsed: Int64, memTotal: Int64,
                tempC: Double?, powerDraw: Double?, powerLimit: Double?, fanPercent: Double?, clockMHz: Int?) {
        self.name = name; self.utilization = utilization
        self.memUsed = memUsed; self.memTotal = memTotal
        self.tempC = tempC; self.powerDraw = powerDraw; self.powerLimit = powerLimit
        self.fanPercent = fanPercent; self.clockMHz = clockMHz
    }

    /// Parses one nvidia-smi CSV row:
    /// `name, util%, memUsedMB, memTotalMB, tempC, powerW, limitW, fan%, clockMHz`.
    public static func parse(nvidiaCSV line: String) -> GPUStats? {
        let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 4 else { return nil }
        func num(_ i: Int) -> Double? {
            guard i < f.count else { return nil }
            let v = f[i]
            return (v == "[N/A]" || v.isEmpty) ? nil : Double(v)
        }
        guard let util = num(1), let mu = num(2), let mt = num(3) else { return nil }
        return GPUStats(
            name: f[0],
            utilization: util / 100,
            memUsed: Int64(mu) * 1024 * 1024,
            memTotal: Int64(mt) * 1024 * 1024,
            tempC: num(4),
            powerDraw: num(5),
            powerLimit: num(6),
            fanPercent: num(7).map { $0 / 100 },
            clockMHz: num(8).map { Int($0) }
        )
    }
}

/// A named temperature sensor reading (°C).
public struct TempReading: Codable, Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String            // "CPU", "iGPU", "SSD", "System"
    public let celsius: Double
    public init(label: String, celsius: Double) { self.label = label; self.celsius = celsius }
}

/// Live throughput rates (bytes/sec), computed from two spaced samples.
public struct Throughput: Codable, Sendable, Hashable {
    public let netRx: Int64
    public let netTx: Int64
    public let diskRead: Int64
    public let diskWrite: Int64
    public init(netRx: Int64, netTx: Int64, diskRead: Int64, diskWrite: Int64) {
        self.netRx = netRx; self.netTx = netTx; self.diskRead = diskRead; self.diskWrite = diskWrite
    }
}

/// What Fleetwatch could read from a machine, plus what it's capable of — the
/// three-ring model made concrete. Universal fields are always present;
/// capabilities gate the Ring-2 organs.
public struct MachineTelemetry: Sendable, Hashable {
    public var hardware: HardwareInfo
    /// Every fixed volume, system disk first.
    public var disks: [DiskVolume]
    // Memory — bytes. `used` is honest (excludes reclaimable cache);
    // `available` counts cache as free (the purgeable lesson, on Linux).
    public var memTotal: Int64
    public var memUsed: Int64
    public var memAvailable: Int64
    public var memCached: Int64
    public var swapTotal: Int64
    public var swapUsed: Int64
    // CPU load averages.
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var uptime: TimeInterval
    // Ring-2 capabilities.
    public var hasDocker: Bool
    public var hasBattery: Bool
    public var containers: [Container]
    // Extended hardware telemetry (best-effort; empty/nil when unavailable).
    public var coreLoads: [Double]      // 0…1 per logical core
    public var cpuClockMHz: Int?        // current core clock
    public var cpuMaxClockMHz: Int?     // rated/boost clock
    public var gpu: GPUStats?
    public var temps: [TempReading]
    public var throughput: Throughput?

    // Primary-volume conveniences.
    public var diskTotal: Int64 { disks.first?.total ?? 0 }
    public var diskUsed: Int64 { disks.first?.used ?? 0 }
    public var diskFree: Int64 { disks.first?.free ?? 0 }

    public var memUsedFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
    public var swapUsedFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
    public var memAvailableFraction: Double { memTotal > 0 ? Double(memAvailable) / Double(memTotal) : 1 }
    /// A full swap is only a health concern when RAM *also* has little
    /// headroom. A full swap with plenty of available memory is benign —
    /// idle pages parked on disk over a long uptime, not active thrashing.
    public var swapPressured: Bool { swapUsedFraction > 0.5 && memAvailableFraction < 0.2 }
    /// Load as a fraction of core count — a normalized "how busy" (can exceed 1).
    public var loadFraction: Double { hardware.cores > 0 ? load1 / Double(hardware.cores) : 0 }

    public init(hardware: HardwareInfo, disks: [DiskVolume],
                memTotal: Int64, memUsed: Int64, memAvailable: Int64, memCached: Int64,
                swapTotal: Int64 = 0, swapUsed: Int64 = 0,
                load1: Double, load5: Double, load15: Double, uptime: TimeInterval,
                hasDocker: Bool, hasBattery: Bool, containers: [Container],
                coreLoads: [Double] = [], cpuClockMHz: Int? = nil, cpuMaxClockMHz: Int? = nil,
                gpu: GPUStats? = nil, temps: [TempReading] = [], throughput: Throughput? = nil) {
        self.hardware = hardware
        self.disks = disks
        self.memTotal = memTotal; self.memUsed = memUsed; self.memAvailable = memAvailable; self.memCached = memCached
        self.swapTotal = swapTotal; self.swapUsed = swapUsed
        self.load1 = load1; self.load5 = load5; self.load15 = load15; self.uptime = uptime
        self.hasDocker = hasDocker; self.hasBattery = hasBattery; self.containers = containers
        self.coreLoads = coreLoads; self.cpuClockMHz = cpuClockMHz; self.cpuMaxClockMHz = cpuMaxClockMHz
        self.gpu = gpu; self.temps = temps; self.throughput = throughput
    }
}
