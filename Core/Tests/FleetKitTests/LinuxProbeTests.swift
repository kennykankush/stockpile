import Foundation
import Testing
@testable import FleetKit

@Suite("Linux probe parser")
struct LinuxProbeTests {
    // Real output captured from hadi-pc (Ubuntu 24.04, Ryzen 5 5625U, 16GB,
    // 13 docker containers, a battery). The parser must survive real data.
    static let realOutput = """
    ===OS===
    Ubuntu 24.04.4 LTS
    6.17.0-20-generic
    ===CPU===
    12
    AMD Ryzen 5 5625U with Radeon Graphics
    ===LOAD===
    0.18 0.20 0.16 2/1749 3131915
    ===MEM===
    Mem:     16070844416  9038823424  1167216640   208424960  6416908288  7032020992
    ===DISK===
    / 501809635328 116446396416 359797436416
    ===UPTIME===
    8034162.11
    ===DOCKER===
    bank-browser-dbs|Up 7 days
    docs-reader|Up 3 months
    media-stack-jellyfin-1|Up 3 months (healthy)
    gitea|Up 2 months
    ===BATTERY===
    BAT0
    ===GPU===
    Advanced Micro Devices, Inc. [AMD/ATI] Barcelo (rev c2)
    ===CLOCK===
    3972.435
    ===TEMPS===
    acpitz 40000
    nvme 33850
    nvme 44850
    nvme 33850
    k10temp 40750
    amdgpu 39000
    ===SWAP===
    4294963200 4046163968
    ===GPUSTATS===
    NO_NVIDIA
    ===DOCKERSTATS===
    bank-browser-dbs|1.74%|911.6MiB / 14.97GiB|5.95%
    gitea|0.50%|120MiB / 14.97GiB|0.80%
    ===SAMPLE1===
    1000000000000
    cpu0 0 0 0 1000 0 0 0 0 0 0
    cpu1 0 0 0 1000 0 0 0 0 0 0
    NET 0 0
    DIO 0 0
    ===SAMPLE2===
    1000500000000
    cpu0 500 0 0 1500 0 0 0 0 0 0
    cpu1 100 0 0 1900 0 0 0 0 0 0
    NET 500000 1000000
    DIO 250000 750000
    """

    @Test("Parses hardware identity from real output")
    func hardware() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.hardware.cores == 12)
        #expect(t.hardware.cpuModel == "AMD Ryzen 5 5625U with Radeon Graphics")
        #expect(t.hardware.osName == "Ubuntu 24.04.4 LTS")
        #expect(t.hardware.kernel == "6.17.0-20-generic")
        #expect(t.hardware.gpu?.contains("AMD") == true)
        #expect(t.hardware.ramTotal == 16070844416)
    }

    @Test("Memory is the honest story: used excludes cache, available counts it")
    func memory() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.memTotal == 16070844416)
        #expect(t.memUsed == 9038823424)          // honest used
        #expect(t.memAvailable == 7032020992)     // cache counted as free
        #expect(t.memCached == 6416908288)        // the reclaimable gap
        // Naive "used" (total - free) would be far higher than honest used.
        #expect(t.memUsed < t.memTotal - t.memAvailable + t.memCached)
    }

    @Test("Disk and load parse")
    func diskLoad() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.diskTotal == 501809635328)
        #expect(t.diskUsed == 116446396416)
        #expect(t.load1 == 0.18)
        #expect(t.load15 == 0.16)
        #expect(t.uptime > 8_000_000)
    }

    @Test("Docker + battery capabilities detected, containers parsed")
    func capabilities() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.hasDocker)
        #expect(t.hasBattery)
        #expect(t.containers.count == 4)
        #expect(t.containers.contains { $0.name == "gitea" })
        let jellyfin = try #require(t.containers.first { $0.name.contains("jellyfin") })
        #expect(jellyfin.isHealthy)
    }

    @Test("CPU clock parses from /proc/cpuinfo MHz")
    func clock() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.cpuClockMHz == 3972)
    }

    @Test("hwmon temps aggregate to friendly sensors — hottest NVMe wins")
    func temps() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        let cpu = try #require(t.temps.first { $0.label == "CPU" })
        #expect(abs(cpu.celsius - 40.75) < 0.01)          // k10temp
        #expect(t.temps.contains { $0.label == "iGPU" && abs($0.celsius - 39) < 0.01 })
        let ssd = try #require(t.temps.first { $0.label == "SSD" })
        #expect(abs(ssd.celsius - 44.85) < 0.01)          // max of three NVMe sensors
        #expect(t.temps.contains { $0.label == "System" && abs($0.celsius - 40) < 0.01 })
    }

    @Test("No NVIDIA GPU on this box — gpu stats absent")
    func noNvidia() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.gpu == nil)
    }

    @Test("Swap parses (hadi-pc is swapping hard)")
    func swap() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.swapTotal == 4294963200)
        #expect(t.swapUsed == 4046163968)
        #expect(t.swapUsedFraction > 0.9)
    }

    @Test("Per-core load computed from the two /proc/stat samples")
    func perCore() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        #expect(t.coreLoads.count == 2)
        #expect(abs(t.coreLoads[0] - 0.5) < 0.001)     // 500 busy / 1000 total delta
        #expect(abs(t.coreLoads[1] - 0.1) < 0.001)     // 100 busy / 1000 total delta
    }

    @Test("Network + disk throughput rates over the sample interval")
    func throughput() throws {
        let tp = try #require(LinuxProbe.parse(Self.realOutput)?.throughput)
        // 0.5s interval: 500000 rx bytes → 1,000,000 B/s, etc.
        #expect(tp.netRx == 1_000_000)
        #expect(tp.netTx == 2_000_000)
        #expect(tp.diskRead == 500_000)
        #expect(tp.diskWrite == 1_500_000)
    }

    @Test("docker stats merge live CPU/mem into containers by name")
    func dockerStats() throws {
        let t = try #require(LinuxProbe.parse(Self.realOutput))
        let bank = try #require(t.containers.first { $0.name == "bank-browser-dbs" })
        #expect(bank.cpuPercent == 1.74)
        #expect(abs((bank.memPercent ?? 0) - 5.95) < 0.001)
        #expect((bank.memUsed ?? 0) > 900_000_000 && (bank.memUsed ?? 0) < 970_000_000)   // 911.6 MiB
        // jellyfin has no stats row → nil, not a crash
        let jelly = try #require(t.containers.first { $0.name.contains("jellyfin") })
        #expect(jelly.cpuPercent == nil)
    }

    @Test("Binary byte parser: MiB/GiB → bytes")
    func binaryBytes() {
        #expect(LinuxProbe.parseBinaryBytes("1GiB") == 1073741824)
        #expect(LinuxProbe.parseBinaryBytes("256MiB") == 268435456)
        #expect(LinuxProbe.parseBinaryBytes("512KiB") == 524288)
    }

    @Test("No-docker / no-battery boxes degrade cleanly")
    func absentCapabilities() throws {
        let minimal = """
        ===OS===
        Debian
        6.1.0
        ===CPU===
        4
        Intel Xeon
        ===LOAD===
        1.5 1.2 1.0
        ===MEM===
        Mem: 8000000000 2000000000 1000000000 100000000 5000000000 6000000000
        ===DISK===
        / 100000000000 50000000000 50000000000
        ===UPTIME===
        3600
        ===DOCKER===
        NO_DOCKER
        ===BATTERY===
        NO_BATTERY
        ===GPU===
        NO_GPU
        """
        let t = try #require(LinuxProbe.parse(minimal))
        #expect(!t.hasDocker)
        #expect(!t.hasBattery)
        #expect(t.containers.isEmpty)
        #expect(t.hardware.gpu == nil)
    }
}
