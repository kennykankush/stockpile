import Foundation

/// The Windows telemetry probe: a PowerShell script piped over SSH (Windows
/// OpenSSH defaults to cmd, so we pipe to `powershell -Command -`). Emits the
/// same `===SECTION===` format as the Linux probe so parsing is uniform.
///
/// Memory honesty: CIM's FreePhysicalMemory actually reports *available*
/// (standby cache included). Perf counters split it properly — AvailableBytes
/// plus the standby-cache trio — so Windows gets the same used/cached/
/// available story as Linux and macOS: standby cache is reclaimable on
/// demand, not "used."
public enum WindowsProbe {
    public static let script = """
    $ErrorActionPreference='SilentlyContinue'
    $os=Get-CimInstance Win32_OperatingSystem
    $cpu=Get-CimInstance Win32_Processor | Select-Object -First 1
    $perf=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $bat=Get-CimInstance Win32_Battery
    "===OS==="; $os.Caption; [System.Environment]::OSVersion.Version.ToString()
    "===CPU==="; $cpu.NumberOfLogicalProcessors; $cpu.Name
    "===MEM==="; "$($os.TotalVisibleMemorySize) $($os.FreePhysicalMemory) $($perf.AvailableBytes) $([int64]$perf.StandbyCacheNormalPriorityBytes + [int64]$perf.StandbyCacheReserveBytes + [int64]$perf.StandbyCacheCoreBytes)"
    "===DISK==="; Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { "$($_.DeviceID) $($_.Size) $($_.FreeSpace)" }
    "===LOAD==="; $cpu.LoadPercentage
    "===UPTIME==="; [int]((Get-Date)-$os.LastBootUpTime).TotalSeconds
    "===GPU==="; (Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 } | Sort-Object AdapterRAM -Descending | Select-Object -First 1).Name
    "===BATTERY==="; if ($bat) { "BAT" } else { "NO_BATTERY" }
    "===DOCKER==="; if (Get-Command docker -ErrorAction SilentlyContinue) { docker ps --format '{{.Names}}|{{.Status}}' } else { "NO_DOCKER" }
    "===CLOCK==="; "$($cpu.CurrentClockSpeed) $($cpu.MaxClockSpeed)"
    "===GPUSTATS==="; if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.gr --format=csv,noheader,nounits } else { "NO_NVIDIA" }
    "===PERCORE==="; (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object { $_.Name -ne '_Total' } | Sort-Object {[int]$_.Name} | ForEach-Object { $_.PercentProcessorTime }) -join ' '
    "===SWAP==="; $pf=Get-CimInstance Win32_PageFileUsage; "$($pf.AllocatedBaseSize) $($pf.CurrentUsage)"
    "===NETIO==="; $ni=Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | Where-Object { $_.Name -notmatch 'Loopback|isatap' }; "$((($ni | Measure-Object BytesReceivedPersec -Sum).Sum)) $((($ni | Measure-Object BytesSentPersec -Sum).Sum))"
    "===DISKIO==="; $dd=Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -eq '_Total' }; "$($dd.DiskReadBytesPersec) $($dd.DiskWriteBytesPersec)"
    "===DOCKERSTATS==="; if (Get-Command docker -ErrorAction SilentlyContinue) { docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' }
    """

    public static func parse(_ output: String) -> MachineTelemetry? {
        // PowerShell over SSH emits CRLF — normalize before anything else.
        let s = splitSections(output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        guard let mem = s["MEM"]?.first, let disk = s["DISK"], !disk.isEmpty,
              let cpuLines = s["CPU"], cpuLines.count >= 1 else { return nil }

        // MEM: "totalKB freeKB [availableBytes standbyBytes]" — the bracketed
        // pair comes from perf counters; degrade gracefully if they're absent.
        let memF = mem.split(separator: " ").compactMap { Int64($0) }
        guard memF.count >= 2 else { return nil }
        let memTotal = memF[0] * 1024
        let memAvailable: Int64, memCached: Int64
        if memF.count >= 4, memF[2] > 0 {
            memAvailable = memF[2]
            memCached = min(memF[3], memAvailable)
        } else {
            memAvailable = memF[1] * 1024   // CIM "free" is really available
            memCached = 0
        }
        let memUsed = max(0, memTotal - memAvailable)

        // DISK: one line per fixed drive — "C: size free". System drive (C:)
        // first, then by size.
        var disks: [DiskVolume] = disk.compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 3, let total = Int64(f[1]), let free = Int64(f[2]) else { return nil }
            return DiskVolume(name: String(f[0]), total: total, used: max(0, total - free), free: free)
        }
        disks.sort { a, b in
            if a.name.uppercased() == "C:" { return true }
            if b.name.uppercased() == "C:" { return false }
            return a.total > b.total
        }
        guard !disks.isEmpty else { return nil }

        let cores = Int(cpuLines[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let cpuModel = (cpuLines.count >= 2 ? cpuLines[1] : "Unknown CPU").trimmingCharacters(in: .whitespaces)
        // Windows exposes a single CPU load %, not a load average — normalize
        // to a load-like number (fraction of cores) so the UI reads uniformly.
        let loadPct = Double(s["LOAD"]?.first ?? "0") ?? 0
        let load = loadPct / 100.0 * Double(cores)

        let osLines = s["OS"] ?? []
        let hardware = HardwareInfo(
            cpuModel: cpuModel, cores: cores, ramTotal: memTotal,
            gpu: s["GPU"]?.first.flatMap { $0.isEmpty ? nil : $0 },
            osName: osLines.first ?? "Windows",
            kernel: osLines.count >= 2 ? osLines[1] : ""
        )

        // Clock: "current max" MHz. GPU: nvidia-smi CSV or NO_NVIDIA.
        let clockF = (s["CLOCK"]?.first ?? "").split(separator: " ").compactMap { Int($0) }
        let clock = clockF.first
        let maxClock = clockF.count > 1 ? clockF[1] : nil
        let gpu = (s["GPUSTATS"]?.first).flatMap {
            $0 == "NO_NVIDIA" ? nil : GPUStats.parse(nvidiaCSV: $0)
        }
        // Windows doesn't expose a reliable CPU die temperature; the GPU temp
        // (from nvidia-smi) is surfaced on the GPU card instead.
        let temps: [TempReading] = gpu?.tempC.map { [TempReading(label: "GPU", celsius: $0)] } ?? []

        let dockerLines = s["DOCKER"] ?? ["NO_DOCKER"]
        let hasDocker = !(dockerLines.first == "NO_DOCKER")
        let dstats = LinuxProbe.parseDockerStats(s["DOCKERSTATS"] ?? [])
        let containers: [Container] = hasDocker
            ? dockerLines.filter { $0.contains("|") }.map {
                let p = $0.split(separator: "|", maxSplits: 1).map(String.init)
                let st = dstats[p[0]]
                return Container(name: p[0], status: p.count > 1 ? p[1] : "",
                                 cpuPercent: st?.cpu, memUsed: st?.mem, memPercent: st?.memPct)
              } : []

        // Per-core %, swap (page file, MB→bytes), and instantaneous throughput.
        let coreLoads = (s["PERCORE"]?.first ?? "").split(separator: " ").compactMap { Double($0) }.map { $0 / 100 }
        let swapF = (s["SWAP"]?.first ?? "").split(separator: " ").compactMap { Int64($0) }
        let (swapTotal, swapUsed) = swapF.count >= 2 ? (swapF[0] * 1048576, swapF[1] * 1048576) : (Int64(0), Int64(0))
        let netF = (s["NETIO"]?.first ?? "").split(separator: " ").compactMap { Int64($0) }
        let dioF = (s["DISKIO"]?.first ?? "").split(separator: " ").compactMap { Int64($0) }
        let throughput = (netF.count >= 2 || dioF.count >= 2)
            ? Throughput(netRx: netF.first ?? 0, netTx: netF.count > 1 ? netF[1] : Int64(0),
                         diskRead: dioF.first ?? 0, diskWrite: dioF.count > 1 ? dioF[1] : Int64(0))
            : nil

        return MachineTelemetry(
            hardware: hardware,
            disks: disks,
            memTotal: memTotal, memUsed: memUsed, memAvailable: memAvailable, memCached: memCached,
            swapTotal: swapTotal, swapUsed: swapUsed,
            load1: load, load5: load, load15: load,
            uptime: TimeInterval(s["UPTIME"]?.first ?? "") ?? 0,
            hasDocker: hasDocker,
            hasBattery: (s["BATTERY"]?.first ?? "NO_BATTERY") == "BAT",
            containers: containers,
            coreLoads: coreLoads, cpuClockMHz: clock, cpuMaxClockMHz: maxClock,
            gpu: gpu, temps: temps, throughput: throughput
        )
    }

    private static func splitSections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("===") && line.hasSuffix("===") {
                current = String(line.dropFirst(3).dropLast(3))
                result[current!] = []
            } else if let current, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result[current]?.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }
}
