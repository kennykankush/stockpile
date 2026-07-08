import Foundation

/// The Linux telemetry probe: one bash script run over SSH that emits
/// section-marked output, plus a parser for it. One round-trip gathers the
/// whole picture — hardware identity, disk, memory, load, docker, battery, gpu.
public enum LinuxProbe {
    /// Runs remotely via `ssh host 'bash -s'`. Every section is best-effort;
    /// missing tools degrade to NO_* markers rather than failing the probe.
    public static let script = """
    echo "===OS==="; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"; uname -r
    echo "===CPU==="; nproc; lscpu 2>/dev/null | grep -E "^Model name" | sed "s/Model name: *//"
    echo "===LOAD==="; cat /proc/loadavg
    echo "===MEM==="; free -b | grep -E "^Mem"
    echo "===DISK==="; df -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs --output=target,size,used,avail 2>/dev/null | tail -n +2
    echo "===UPTIME==="; awk '{print $1}' /proc/uptime
    echo "===DOCKER==="; if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null || echo DOCKER_NOPERM; else echo NO_DOCKER; fi
    echo "===BATTERY==="; ls /sys/class/power_supply/ 2>/dev/null | grep -iE "^BAT" || echo NO_BATTERY
    echo "===GPU==="; lspci 2>/dev/null | grep -iE "vga|3d|display" | sed "s/.*: //" | head -1 || echo NO_GPU
    echo "===CLOCK==="; awk '/cpu MHz/{print $4; exit}' /proc/cpuinfo
    echo "===TEMPS==="; for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name 2>/dev/null); for f in $h/temp*_input; do [ -f "$f" ] && echo "$n $(cat $f 2>/dev/null)"; done; done 2>/dev/null
    echo "===SWAP==="; free -b | awk '/^Swap/{print $2, $3}'
    echo "===GPUSTATS==="; if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.gr --format=csv,noheader,nounits 2>/dev/null | head -1; else echo NO_NVIDIA; fi
    echo "===DOCKERSTATS==="; if command -v docker >/dev/null 2>&1; then docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null; fi
    echo "===SAMPLE1==="; date +%s%N; grep '^cpu[0-9]' /proc/stat; awk 'NR>2 && $1!="lo:"{rx+=$2;tx+=$10} END{print "NET", rx, tx}' /proc/net/dev; awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|mmcblk[0-9]+)$/{r+=$6;w+=$10} END{print "DIO", r*512, w*512}' /proc/diskstats
    sleep 0.5
    echo "===SAMPLE2==="; date +%s%N; grep '^cpu[0-9]' /proc/stat; awk 'NR>2 && $1!="lo:"{rx+=$2;tx+=$10} END{print "NET", rx, tx}' /proc/net/dev; awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|mmcblk[0-9]+)$/{r+=$6;w+=$10} END{print "DIO", r*512, w*512}' /proc/diskstats
    """

    public static func parse(_ output: String) -> MachineTelemetry? {
        let sections = splitSections(output)
        guard let mem = sections["MEM"]?.first,
              let diskLines = sections["DISK"], !diskLines.isEmpty,
              let cpuLines = sections["CPU"], cpuLines.count >= 1 else { return nil }

        // MEM: "Mem:  total used free shared buff/cache available"
        let memF = mem.split(separator: " ", omittingEmptySubsequences: true).compactMap { Int64($0) }
        guard memF.count >= 6 else { return nil }
        let (memTotal, memUsed, memCached, memAvail) = (memF[0], memF[1], memF[4], memF[5])

        // DISK: one line per mount — "target size used avail". Boot/efi
        // partitions are noise; system root sorts first, then by size.
        var disks: [DiskVolume] = diskLines.compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let total = Int64(f[1]), let used = Int64(f[2]), let free = Int64(f[3]) else { return nil }
            let mount = String(f[0])
            guard !mount.hasPrefix("/boot") else { return nil }
            return DiskVolume(name: mount, total: total, used: used, free: free)
        }
        disks.sort { a, b in
            if a.name == "/" { return true }
            if b.name == "/" { return false }
            return a.total > b.total
        }
        guard !disks.isEmpty else { return nil }

        let cores = Int(cpuLines[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let cpuModel = cpuLines.count >= 2 ? cpuLines[1] : "Unknown CPU"

        let load = (sections["LOAD"]?.first ?? "").split(separator: " ").compactMap { Double($0) }
        let uptime = TimeInterval(sections["UPTIME"]?.first ?? "") ?? 0

        let osLines = sections["OS"] ?? []
        let hardware = HardwareInfo(
            cpuModel: cpuModel, cores: cores, ramTotal: memTotal,
            gpu: sections["GPU"]?.first.flatMap { $0 == "NO_GPU" ? nil : $0 },
            osName: osLines.first ?? "Linux",
            kernel: osLines.count >= 2 ? osLines[1] : ""
        )

        let dockerLines = sections["DOCKER"] ?? ["NO_DOCKER"]
        let hasDocker = !(dockerLines.first == "NO_DOCKER")
        let stats = parseDockerStats(sections["DOCKERSTATS"] ?? [])
        let containers: [Container] = hasDocker
            ? dockerLines.filter { $0.contains("|") }.map {
                let parts = $0.split(separator: "|", maxSplits: 1).map(String.init)
                let name = parts[0]
                let s = stats[name]
                return Container(name: name, status: parts.count > 1 ? parts[1] : "",
                                 cpuPercent: s?.cpu, memUsed: s?.mem, memPercent: s?.memPct)
              }
            : []

        let hasBattery = !((sections["BATTERY"]?.first ?? "NO_BATTERY") == "NO_BATTERY")

        let clock = (sections["CLOCK"]?.first).flatMap { Double($0) }.map { Int($0) }
        let temps = parseTemps(sections["TEMPS"] ?? [])
        let gpu = (sections["GPUSTATS"]?.first).flatMap {
            $0 == "NO_NVIDIA" ? nil : GPUStats.parse(nvidiaCSV: $0)
        }

        // SWAP: "total used" bytes.
        let swapF = (sections["SWAP"]?.first ?? "").split(separator: " ").compactMap { Int64($0) }
        let (swapTotal, swapUsed) = swapF.count >= 2 ? (swapF[0], swapF[1]) : (Int64(0), Int64(0))

        // Two-sample delta → per-core load + network/disk throughput.
        let (coreLoads, throughput) = parseDelta(sections["SAMPLE1"] ?? [], sections["SAMPLE2"] ?? [])

        return MachineTelemetry(
            hardware: hardware,
            disks: disks,
            memTotal: memTotal, memUsed: memUsed, memAvailable: memAvail, memCached: memCached,
            swapTotal: swapTotal, swapUsed: swapUsed,
            load1: load.count > 0 ? load[0] : 0, load5: load.count > 1 ? load[1] : 0, load15: load.count > 2 ? load[2] : 0,
            uptime: uptime, hasDocker: hasDocker, hasBattery: hasBattery, containers: containers,
            coreLoads: coreLoads, cpuClockMHz: clock, gpu: gpu, temps: temps, throughput: throughput
        )
    }

    // MARK: delta sampling (per-core load + throughput)

    private struct Sample {
        let t: Double                 // ns epoch
        let cores: [[Int64]]          // per-core jiffy fields
        let netRx: Int64, netTx: Int64
        let read: Int64, write: Int64
    }

    private static func parseSample(_ lines: [String]) -> Sample? {
        guard let first = lines.first, let t = Double(first) else { return nil }
        var cores: [[Int64]] = []
        var rx: Int64 = 0, tx: Int64 = 0, rd: Int64 = 0, wr: Int64 = 0
        for line in lines.dropFirst() {
            let f = line.split(separator: " ")
            if line.hasPrefix("cpu") {
                let nums = f.dropFirst().compactMap { Int64($0) }
                if nums.count >= 5 { cores.append(nums) }
            } else if line.hasPrefix("NET"), f.count >= 3 {
                rx = Int64(f[1]) ?? 0; tx = Int64(f[2]) ?? 0
            } else if line.hasPrefix("DIO"), f.count >= 3 {
                rd = Int64(f[1]) ?? 0; wr = Int64(f[2]) ?? 0
            }
        }
        return Sample(t: t, cores: cores, netRx: rx, netTx: tx, read: rd, write: wr)
    }

    static func parseDelta(_ a: [String], _ b: [String]) -> ([Double], Throughput?) {
        guard let s1 = parseSample(a), let s2 = parseSample(b), s2.t > s1.t else { return ([], nil) }
        let dt = (s2.t - s1.t) / 1_000_000_000     // ns → s
        guard dt > 0 else { return ([], nil) }

        var loads: [Double] = []
        for i in 0..<min(s1.cores.count, s2.cores.count) {
            let x = s1.cores[i], y = s2.cores[i]
            let totX = x.reduce(0, +), totY = y.reduce(0, +)
            let idleX = x.count > 4 ? x[3] + x[4] : 0     // idle + iowait
            let idleY = y.count > 4 ? y[3] + y[4] : 0
            let dtot = Double(totY - totX), didle = Double(idleY - idleX)
            loads.append(dtot > 0 ? max(0, min(1, (dtot - didle) / dtot)) : 0)
        }
        let rate: (Int64, Int64) -> Int64 = { new, old in Int64(max(0, Double(new - old) / dt)) }
        let tp = Throughput(netRx: rate(s2.netRx, s1.netRx), netTx: rate(s2.netTx, s1.netTx),
                            diskRead: rate(s2.read, s1.read), diskWrite: rate(s2.write, s1.write))
        return (loads, tp)
    }

    // MARK: docker stats

    /// Parses `docker stats` rows: "name|cpu%|used / total|mem%".
    static func parseDockerStats(_ lines: [String]) -> [String: (cpu: Double, mem: Int64, memPct: Double)] {
        var out: [String: (Double, Int64, Double)] = [:]
        for line in lines {
            let f = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 4 else { continue }
            let cpu = Double(f[1].replacingOccurrences(of: "%", with: "")) ?? 0
            let memUsed = parseBinaryBytes(f[2].split(separator: "/").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "")
            let memPct = Double(f[3].replacingOccurrences(of: "%", with: "")) ?? 0
            out[f[0]] = (cpu, memUsed, memPct)
        }
        return out
    }

    /// "911.6MiB" / "1.5GiB" / "512KiB" / "20B" → bytes.
    static func parseBinaryBytes(_ s: String) -> Int64 {
        let units: [(String, Double)] = [("GiB", 1073741824), ("MiB", 1048576), ("KiB", 1024),
                                         ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, mult) in units where s.hasSuffix(u) {
            let num = Double(s.dropLast(u.count).trimmingCharacters(in: .whitespaces)) ?? 0
            return Int64(num * mult)
        }
        return 0
    }

    /// Aggregates raw `hwmon` sensor lines ("name millidegrees") into a few
    /// friendly readings: CPU (k10temp/coretemp), iGPU (amdgpu), SSD (hottest
    /// NVMe), System (acpitz).
    static func parseTemps(_ lines: [String]) -> [TempReading] {
        var cpu: Double?, gpu: Double?, nvme: Double?, sys: Double?
        for line in lines {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 2, let milli = Double(p[1]) else { continue }
            let c = milli / 1000
            guard c > 0, c < 150 else { continue }   // discard bogus sensors
            let name = p[0].lowercased()
            if name.contains("k10temp") || name.contains("coretemp") || name.contains("zenpower") {
                if cpu == nil { cpu = c }
            } else if name.contains("nvme") {
                nvme = max(nvme ?? 0, c)
            } else if name.contains("amdgpu") || name.contains("nouveau") || name.contains("radeon") {
                gpu = c
            } else if name.contains("acpitz") {
                sys = c
            }
        }
        var out: [TempReading] = []
        if let cpu { out.append(TempReading(label: "CPU", celsius: cpu)) }
        if let gpu { out.append(TempReading(label: "iGPU", celsius: gpu)) }
        if let nvme { out.append(TempReading(label: "SSD", celsius: nvme)) }
        if let sys { out.append(TempReading(label: "System", celsius: sys)) }
        return out
    }

    /// Splits `===NAME===`-marked output into section → trimmed non-empty lines.
    private static func splitSections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
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
