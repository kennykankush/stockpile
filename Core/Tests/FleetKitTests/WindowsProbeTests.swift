import Foundation
import Testing
@testable import FleetKit

@Suite("Windows probe parser")
struct WindowsProbeTests {
    // Real output captured from magi (Windows 11, Ryzen 7 5700X, 32GB, no
    // docker) — hardened MEM line: totalKB freeKB availableBytes standbyBytes.
    static let realOutput = """
    ===OS===
    Microsoft Windows 11 Home
    10.0.26200.0
    ===CPU===
    16
    AMD Ryzen 7 5700X 8-Core Processor
    ===MEM===
    33474540 12333784 12557271040 12548792320
    ===DISK===
    C: 998324412416 701890568192
    D: 2000381014016 1793117249536
    ===LOAD===
    7
    ===UPTIME===
    524163
    ===GPU===
    NVIDIA GeForce RTX 3070 Ti
    ===BATTERY===
    NO_BATTERY
    ===DOCKER===
    NO_DOCKER
    ===CLOCK===
    3401 3401
    ===GPUSTATS===
    NVIDIA GeForce RTX 3070 Ti, 100, 7877, 8192, 62, 119.56, 310.00, 72, 1995
    ===PERCORE===
    9 27 9 9 3 15 75 15 15 3 3 9 51 21 9 21
    ===SWAP===
    11970 3715
    ===NETIO===
    7664 9295
    ===DISKIO===
    0 0
    ===DOCKERSTATS===
    """

    @Test("Parses Windows hardware, trims CPU whitespace")
    func hardware() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.hardware.cores == 16)
        #expect(t.hardware.cpuModel == "AMD Ryzen 7 5700X 8-Core Processor")
        #expect(t.hardware.osName == "Microsoft Windows 11 Home")
        #expect(t.hardware.gpu == "NVIDIA GeForce RTX 3070 Ti")
        #expect(t.hardware.ramTotal == 33474540 * 1024)
    }

    @Test("Honest memory: available from perf counters, standby cache split out")
    func memoryHonest() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.memTotal == 33474540 * 1024)
        #expect(t.memAvailable == 12557271040)          // AvailableBytes
        #expect(t.memCached == 12548792320)             // standby cache — reclaimable
        #expect(t.memUsed == 33474540 * 1024 - 12557271040)  // total - available
    }

    @Test("Degrades to CIM-only when perf counters are absent")
    func memoryFallback() throws {
        let legacy = Self.realOutput.replacingOccurrences(
            of: "33474540 12333784 12557271040 12548792320",
            with: "33474540 12333784")
        let t = try #require(WindowsProbe.parse(legacy))
        #expect(t.memAvailable == 12333784 * 1024)
        #expect(t.memCached == 0)
    }

    @Test("ALL fixed drives detected — magi's 2TB D: was invisible before")
    func multiDisk() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.disks.count == 2)
        #expect(t.disks[0].name == "C:")             // system drive first
        #expect(t.disks[1].name == "D:")
        #expect(t.disks[1].total == 2000381014016)   // the mac-archives drive
        #expect(t.disks[1].free == 1793117249536)
    }

    @Test("Disk bytes, and CPU load% normalized to a load-average shape")
    func diskLoad() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.diskTotal == 998324412416)
        #expect(t.diskFree == 701890568192)
        #expect(abs(t.load1 - 1.12) < 0.01)   // 7% of 16 cores
        #expect(t.uptime == 524163)
    }

    @Test("Battery via Win32_Battery; docker absent on this box")
    func capabilities() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(!t.hasDocker)
        #expect(!t.hasBattery)
        let laptop = Self.realOutput.replacingOccurrences(of: "NO_BATTERY", with: "BAT")
        #expect(try #require(WindowsProbe.parse(laptop)).hasBattery)
    }

    @Test("CPU clock: current + max MHz")
    func clock() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.cpuClockMHz == 3401)
        #expect(t.cpuMaxClockMHz == 3401)
    }

    @Test("GPU: RTX 3070 Ti via nvidia-smi — util, VRAM, temp, power, fan, clock")
    func gpu() throws {
        let g = try #require(WindowsProbe.parse(Self.realOutput)?.gpu)
        #expect(g.name == "NVIDIA GeForce RTX 3070 Ti")
        #expect(g.utilization == 1.0)                      // 100%
        #expect(g.memUsed == 7877 * 1024 * 1024)
        #expect(g.memTotal == 8192 * 1024 * 1024)
        #expect(g.tempC == 62)
        #expect(g.powerDraw == 119.56)
        #expect(g.powerLimit == 310.0)
        #expect(abs((g.fanPercent ?? 0) - 0.72) < 0.001)
        #expect(g.clockMHz == 1995)
        #expect(abs(g.memFraction - 0.9616) < 0.001)
    }

    @Test("GPU temp surfaces as a temp reading since Windows hides CPU die temp")
    func gpuTempAsSensor() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.temps.contains { $0.label == "GPU" && $0.celsius == 62 })
    }

    @Test("No NVIDIA present degrades to no gpu, no temps")
    func noNvidia() throws {
        let legacy = Self.realOutput.replacingOccurrences(
            of: "NVIDIA GeForce RTX 3070 Ti, 100, 7877, 8192, 62, 119.56, 310.00, 72, 1995",
            with: "NO_NVIDIA")
        let t = try #require(WindowsProbe.parse(legacy))
        #expect(t.gpu == nil)
        #expect(t.temps.isEmpty)
    }

    @Test("Per-core % from perf counters (16 threads)")
    func perCore() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.coreLoads.count == 16)
        #expect(abs(t.coreLoads[6] - 0.75) < 0.001)    // the busy core
        #expect(abs(t.coreLoads[0] - 0.09) < 0.001)
    }

    @Test("Swap (page file) MB → bytes")
    func swap() throws {
        let t = try #require(WindowsProbe.parse(Self.realOutput))
        #expect(t.swapTotal == 11970 * 1048576)
        #expect(t.swapUsed == 3715 * 1048576)
    }

    @Test("Throughput from instantaneous perf counters")
    func throughput() throws {
        let tp = try #require(WindowsProbe.parse(Self.realOutput)?.throughput)
        #expect(tp.netRx == 7664)
        #expect(tp.netTx == 9295)
        #expect(tp.diskRead == 0)
        #expect(tp.diskWrite == 0)
    }

    @Test("CRLF line endings parse — PowerShell over SSH emits \\r\\n")
    func crlf() throws {
        let crlf = Self.realOutput.replacingOccurrences(of: "\n", with: "\r\n")
        let t = try #require(WindowsProbe.parse(crlf))
        #expect(t.hardware.cores == 16)
        #expect(t.memCached == 12548792320)
    }
}
