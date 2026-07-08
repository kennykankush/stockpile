import SwiftUI
import Darwin
import FleetKit
import ScannerKit
import MemoryKit
import BatteryKit

/// The fleet: the local Mac (always first) plus remotes added by Tailscale
/// host. Persists the remote list; telemetry is fetched live and cached.
@MainActor
@Observable
final class MachineStore {
    static let shared = MachineStore()

    private(set) var machines: [Machine] = []
    var telemetry: [UUID: MachineTelemetry] = [:]
    var online: [UUID: Bool] = [:]
    var refreshing: Set<UUID> = []
    var lastError: [UUID: String] = [:]

    private let defaultsKey = "fleet.remotes"

    var local: Machine { machines.first { $0.kind == .local } ?? .thisMac(name: "This Mac") }
    var remotes: [Machine] { machines.filter { $0.kind == .remote } }

    init() {
        let localName = (Host.current().localizedName ?? "This Mac")
        machines = [Machine.thisMac(name: localName)] + loadRemotes()
    }

    // MARK: fleet mutation

    func addRemote(host: String, user: String, name: String?) {
        let display = (name?.isEmpty == false ? name! : host)
        let m = Machine(name: display, kind: .remote, host: host, user: user, os: .unknown)
        machines.append(m)
        saveRemotes()
        Task {
            // Detect the OS once, persist it, then fetch telemetry.
            let os = await SSHRunner(host: host, user: user).detectOS()
            if let idx = machines.firstIndex(where: { $0.id == m.id }) {
                machines[idx].os = os
                saveRemotes()
                await refresh(machines[idx])
            }
        }
    }

    func remove(_ machine: Machine) {
        guard machine.kind == .remote else { return }
        machines.removeAll { $0.id == machine.id }
        telemetry[machine.id] = nil; online[machine.id] = nil
        saveRemotes()
    }

    // MARK: telemetry

    /// Coalesces concurrent refreshes: a second caller (e.g. opening a machine
    /// dashboard while the fleet grid's refresh is in flight) awaits the same
    /// probe result instead of being silently skipped and left "Connecting…".
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    func refresh(_ machine: Machine) async {
        if let existing = inFlight[machine.id] { await existing.value; return }
        let task = Task { await self.performRefresh(machine) }
        inFlight[machine.id] = task
        await task.value
        inFlight[machine.id] = nil
    }

    private func performRefresh(_ machine: Machine) async {
        refreshing.insert(machine.id)
        defer {
            refreshing.remove(machine.id)
            FleetMonitor.shared.record(machine.id, name: machine.name,
                                       telemetry: telemetry[machine.id], online: online[machine.id] ?? false)
        }
        if machine.kind == .local {
            telemetry[machine.id] = LocalTelemetry.snapshot()
            online[machine.id] = true
            return
        }
        let ssh = SSHRunner(host: machine.host, user: machine.user)
        do {
            telemetry[machine.id] = try await RemoteSource(ssh: ssh, os: machine.os).snapshot()
            online[machine.id] = true
            lastError[machine.id] = nil
        } catch {
            // The probe failed — the stored OS may be stale/wrong (e.g. a
            // Windows box saved as Linux by an older build). Re-detect and
            // retry once before giving up.
            let freshOS = await ssh.detectOS()
            if freshOS != machine.os, let idx = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[idx].os = freshOS
                saveRemotes()
                do {
                    telemetry[machine.id] = try await RemoteSource(ssh: ssh, os: freshOS).snapshot()
                    online[machine.id] = true
                    lastError[machine.id] = nil
                    return
                } catch { }
            }
            online[machine.id] = false
            lastError[machine.id] = error.localizedDescription
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for m in machines { group.addTask { await self.refresh(m) } }
        }
    }

    // MARK: persistence (remotes only — never telemetry)

    private func loadRemotes() -> [Machine] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([Machine].self, from: data) else { return [] }
        return list
    }

    private func saveRemotes() {
        if let data = try? JSONEncoder().encode(remotes) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Assembles a MachineTelemetry for the local Mac from native reads, so it
/// sits in the Fleet grid alongside remotes in one uniform shape.
enum LocalTelemetry {
    static func snapshot() -> MachineTelemetry {
        let disk = try? DiskAccounting.measure()
        let mem = MemoryMonitor().read()
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let v = ProcessInfo.processInfo.operatingSystemVersion

        return MachineTelemetry(
            hardware: HardwareInfo(
                cpuModel: sysctlString("machdep.cpu.brand_string"),
                cores: ProcessInfo.processInfo.processorCount,
                ramTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                gpu: nil,
                osName: "macOS \(v.majorVersion).\(v.minorVersion)",
                kernel: sysctlString("kern.osrelease")
            ),
            disks: [DiskVolume(
                name: "Macintosh HD",
                total: disk?.totalCapacity ?? 0,
                used: disk?.physicalUsed ?? 0,
                free: disk?.physicalFree ?? 0
            )],
            memTotal: mem?.total ?? 0,
            memUsed: mem?.used ?? 0,
            memAvailable: mem?.available ?? 0,
            memCached: mem?.cached ?? 0,
            swapTotal: swap.total, swapUsed: swap.used,
            load1: loads[0], load5: loads[1], load15: loads[2],
            uptime: ProcessInfo.processInfo.systemUptime,
            hasDocker: FileManager.default.fileExists(atPath: "/opt/homebrew/bin/docker")
                || FileManager.default.fileExists(atPath: "/usr/local/bin/docker"),
            hasBattery: BatteryMonitor().read() != nil,
            containers: []
        )
    }

    /// Swap usage from `vm.swapusage`.
    private static var swap: (total: Int64, used: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_total), Int64(usage.xsu_used))
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
