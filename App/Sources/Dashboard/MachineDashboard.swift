import SwiftUI
import FleetKit
import ScannerKit
import MemoryKit
import BatteryKit
import ThermalKit
import LedgerKit

/// Tracks once-per-launch work (snapshots, exports).
@MainActor
enum AppRuntime {
    static var snapshotsRecorded = false
}

/// THE machine view: one bento dashboard per machine — identity strip on
/// top, then gauge cards. Local and remote machines share this; cards
/// appear based on what the machine has (multi-disk, docker, battery) and
/// the local Mac gets its extras (heat contributors, reclaimable, deltas).
struct MachineDashboard: View {
    let machine: Machine
    var onOpenCaches: () -> Void = {}
    @State private var store = MachineStore.shared
    @State private var reclaimable = ReclaimableModel.shared
    @State private var battery: BatteryReading?
    @State private var thermal: ThermalLevel?
    @State private var contributors: [HeatContributor] = []
    @State private var loadingContributors = false
    @State private var deltaBytes: Int64?
    @State private var reportCopied = false
    @State private var systemInfo: SystemInfo?
    @State private var loadingInfo = false
    @State private var infoError: String?
    @State private var showingInfo = false

    private var isLocal: Bool { machine.kind == .local }
    private var t: MachineTelemetry? { store.telemetry[machine.id] }
    private var online: Bool { store.online[machine.id] ?? isLocal }

    var body: some View {
        Screen(title: machine.name, subtitle: subtitle, actions: {
            if isLocal {
                BarButton(label: reportCopied ? "Copied ✓" : "Copy Report", symbol: "doc.on.doc") {
                    Task {
                        SystemReport.copyToClipboard(await SystemReport.build(reclaimable: reclaimable.grandTotal))
                        reportCopied = true
                        try? await Task.sleep(for: .seconds(2))
                        reportCopied = false
                    }
                }
            }
            BarButton(label: "System Info", symbol: "info.circle") {
                showingInfo = true
                Task { await loadSystemInfo() }
            }
            BarButton(label: "Refresh", symbol: "arrow.clockwise", disabled: store.refreshing.contains(machine.id)) {
                Task { await refresh() }
            }
        }) {
            if let t {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if isLocal { SetupCard() }
                        identityStrip(t)
                        MasonryLayout(minColumnWidth: 340, spacing: 16, maxColumns: 3) {
                            StorageCard(t: t, deltaBytes: deltaBytes)
                            MemoryCard(t: t)
                            CPUCard(t: t, os: machine.os, thermal: isLocal ? thermal : nil,
                                    contributors: contributors, loading: loadingContributors,
                                    onQuit: quit)
                            if let gpu = t.gpu { GPUCard(g: gpu) }
                            if let tp = t.throughput { ActivityCard(tp: tp) }
                            if t.hasDocker { DockerCard(containers: t.containers) }
                            if isLocal, let battery { BatteryCard(b: battery) }
                            if isLocal { ReclaimableCard(model: reclaimable, onOpen: onOpenCaches) }
                            UptimeCard(id: machine.id)
                        }
                    }
                    .padding(Theme.pagePadding)
                }
            } else if store.refreshing.contains(machine.id) {
                center { ProgressView(); Text("Connecting to \(machine.host)…").font(.callout).foregroundStyle(.secondary) }
            } else {
                center {
                    Image(systemName: "wifi.slash").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.inkTertiary)
                    Text("Offline").font(.system(size: 17, weight: .bold))
                    Text(store.lastError[machine.id] ?? "Couldn't reach \(machine.user)@\(machine.host).")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Retry") { Task { await refresh() } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .task(id: machine.id) {
            await load()
            await pollLoop()
        }
        .sheet(isPresented: $showingInfo) {
            SystemInfoView(machineName: machine.name, info: systemInfo, loading: loadingInfo, error: infoError) {
                showingInfo = false
            }
        }
    }

    /// Fetches the static spec sheet once, lazily, when the sheet opens.
    private func loadSystemInfo() async {
        guard systemInfo == nil, !loadingInfo else { return }
        loadingInfo = true; infoError = nil
        defer { loadingInfo = false }
        if isLocal {
            systemInfo = LocalSystemInfo.build()
        } else {
            do {
                systemInfo = try await SystemInfoProbe.fetch(
                    ssh: SSHRunner(host: machine.host, user: machine.user), os: machine.os)
            } catch {
                infoError = "Couldn't reach \(machine.user)@\(machine.host)."
            }
        }
    }

    /// Keep the dashboard live while it's on screen. Local reads are native
    /// and cheap (poll fast); remote is an SSH round trip (poll gently). The
    /// task auto-cancels when the view leaves or the machine changes.
    private func pollLoop() async {
        let interval: Duration = isLocal ? .seconds(3) : .seconds(15)
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await store.refresh(machine)
            tick += 1
            if isLocal {
                battery = BatteryMonitor().read()
                thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
                // The process sample shells out to `top` — heavier; every ~4th tick.
                if tick % 4 == 0 { await loadContributors() }
            }
        }
    }

    private var subtitle: String {
        guard let t else { return isLocal ? "this machine" : (online ? machine.host : "offline · \(machine.host)") }
        let up = uptimeText(t.uptime)
        return isLocal ? "\(t.hardware.osName) · \(up)" : "\(t.hardware.osName) · \(machine.user)@\(machine.host) · \(up)"
    }

    // MARK: identity

    private func identityStrip(_ t: MachineTelemetry) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: isLocal ? "laptopcomputer" : (machine.os == .windows ? "pc" : "server.rack"),
                             tint: online ? Theme.accent : Theme.inkTertiary, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.hardware.cpuModel.isEmpty ? machine.name : t.hardware.cpuModel)
                            .font(.system(size: 15, weight: .bold)).tracking(-0.2).lineLimit(1)
                        Text("\(t.hardware.osName) · \(uptimeText(t.uptime))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(health.color).frame(width: 7, height: 7)
                        Text(health.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(health.color)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(health.color.opacity(0.12), in: Capsule())
                }
                Divider().overlay(Theme.hairline)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    chip("CORES", "\(t.hardware.cores)")
                    chip("MEMORY", t.hardware.ramTotal.bytesFormatted)
                    if let gpu = t.hardware.gpu { chip("GPU", String(gpu.prefix(26))) }
                    chip("STORAGE", t.disks.reduce(Int64(0)) { $0 + $1.total }.bytesFormatted)
                    if !t.hardware.kernel.isEmpty { chip("KERNEL", String(t.hardware.kernel.prefix(18))) }
                }
            }
        }
    }

    /// A single overall health read — worst of the live metrics.
    private var health: (label: String, color: Color) {
        guard online, let t else { return ("Offline", Theme.inkTertiary) }
        var worst = max(t.diskUsedFraction, t.memUsedFraction, min(t.loadFraction, 1))
        if t.swapPressured { worst = max(worst, t.swapUsedFraction) }
        if worst > 0.9 { return ("Critical", Theme.danger) }
        if worst > 0.75 { return ("Warm", Theme.metricHeat) }
        return ("Healthy", Theme.ok)
    }

    private func chip(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
            Text(v).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: data

    private func load() async {
        if isLocal {
            battery = BatteryMonitor().read()
            thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
            Task { await reclaimable.loadIfNeeded() }
            Task { await loadContributors() }
            if t == nil { await store.refresh(machine) }
            await recordSnapshotsOnce()
            if let prev = await LedgerStore.shared.latestSnapshot()?.metrics?["physicalUsed"],
               let now = t?.diskUsed ?? (try? DiskAccounting.measure())?.physicalUsed {
                deltaBytes = now - prev
            }
        } else if t == nil {
            await store.refresh(machine)
        }
    }

    private func refresh() async {
        await store.refresh(machine)
        if isLocal {
            battery = BatteryMonitor().read()
            thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
            await loadContributors()
        }
    }

    private func loadContributors() async {
        guard isLocal, !loadingContributors else { return }
        loadingContributors = true
        let raw = await ThermalMonitor().sample()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        contributors = raw.processes
            .filter { $0.pid != ownPID && !$0.command.localizedCaseInsensitiveContains("Fleetwatch") }
            .prefix(5)
            .map { HeatContributor(load: $0, runningApp: NSRunningApplication(processIdentifier: $0.pid)) }
        loadingContributors = false
    }

    private func quit(_ c: HeatContributor) {
        guard let app = c.runningApp else { return }
        Task {
            if await RunningApps.quitAndWait(app) {
                await LedgerStore.shared.append(LedgerEvent(
                    kind: .cleared, title: "Quit \(c.displayName)",
                    detail: "Was \(Int(c.load.cpuPercent))% CPU."))
                await loadContributors()
            }
        }
    }

    private func recordSnapshotsOnce() async {
        guard !AppRuntime.snapshotsRecorded else { return }
        AppRuntime.snapshotsRecorded = true
        if let d = try? DiskAccounting.measure() {
            await LedgerStore.shared.append(LedgerEvent(
                kind: .snapshot, title: "Disk snapshot",
                detail: "\(d.physicalUsed.bytesFormatted) physical · \(d.purgeable.bytesFormatted) purgeable",
                bytes: d.physicalUsed,
                metrics: ["physicalUsed": d.physicalUsed, "effectiveUsed": d.effectiveUsed, "purgeable": d.purgeable]))
            WidgetBridge.export(accounting: d, reclaimable: reclaimable.grandTotal)
        }
        if let m = MemoryMonitor().read() {
            await LedgerStore.shared.append(LedgerEvent(
                kind: .snapshot, title: "Memory snapshot",
                detail: "\(m.used.bytesFormatted) in use · \(m.available.bytesFormatted) available",
                bytes: m.used,
                metrics: ["memUsed": m.used, "memAvailable": m.available, "memCached": m.cached]))
        }
    }

    @ViewBuilder
    private func center(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 10) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A process contributor with its owning app resolved (for quit).
struct HeatContributor: Identifiable {
    var id: Int32 { load.pid }
    let load: ProcessLoad
    let runningApp: NSRunningApplication?
    var displayName: String { runningApp?.localizedName ?? load.command }
    var isQuittable: Bool { runningApp != nil }
}

// MARK: - Cards

/// Storage: gauge for the system volume + a row per additional volume —
/// magi's D: finally shows up.
private struct StorageCard: View {
    let t: MachineTelemetry
    var deltaBytes: Int64?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("Storage", symbol: "internaldrive", tint: Theme.metricDisk,
                           trailing: AnyView(HStack(spacing: 6) {
                               if let ssd = t.temps.first(where: { $0.label == "SSD" }) { TempPill(celsius: ssd.celsius) }
                               if let deltaBytes { DeltaChip(bytes: deltaBytes) }
                           }))
                HStack(spacing: 20) {
                    ZStack {
                        ArcGauge(fraction: t.diskUsedFraction, tint: Theme.metricDisk, lineWidth: 12, size: 116)
                            .animation(.easeOut(duration: 0.4), value: t.diskUsedFraction)
                        VStack(spacing: 0) {
                            Text(t.diskUsedFraction, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1).monospacedDigit()
                            Text(t.diskUsed.bytesFormatted).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(t.disks) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(d.name).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(d.free.bytesFormatted) free of \(d.total.bytesFormatted)")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                                }
                                ProgressBar(fraction: d.usedFraction, tint: Theme.severity(d.usedFraction))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Memory: gauge + the honest stack (in use / cached / available).
private struct MemoryCard: View {
    let t: MachineTelemetry

    private var usedF: Double { t.memTotal > 0 ? Double(t.memUsed) / Double(t.memTotal) : 0 }
    private var cachedF: Double { t.memTotal > 0 ? Double(t.memCached) / Double(t.memTotal) : 0 }
    private var freeF: Double { max(0, 1 - usedF - cachedF) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("Memory", symbol: "memorychip", tint: Theme.metricMemory,
                           trailing: AnyView(Text(t.memTotal.bytesFormatted)
                               .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()))
                HStack(spacing: 20) {
                    ZStack {
                        ArcGauge(fraction: t.memUsedFraction, tint: Theme.metricMemory, lineWidth: 12, size: 116)
                            .animation(.easeOut(duration: 0.4), value: t.memUsedFraction)
                        VStack(spacing: 0) {
                            Text(t.memUsedFraction, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1).monospacedDigit()
                            Text("in use").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SegmentBar(segments: [
                            (usedF, Theme.metricMemory),
                            (cachedF, Theme.purgeable),
                            (freeF, Theme.track),
                        ], height: 12)
                        VStack(alignment: .leading, spacing: 7) {
                            memLegend(Theme.metricMemory, "In use", t.memUsed)
                            memLegend(Theme.purgeable, "Cached", t.memCached)
                            memLegend(Theme.ok, "Free", max(0, t.memTotal - t.memUsed - t.memCached))
                        }
                    }
                }
                if t.swapTotal > 0 {
                    Divider().overlay(Theme.hairline)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Swap").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            if t.swapUsedFraction > 0.5 && !t.swapPressured {
                                Text("· idle pages, RAM has headroom")
                                    .font(.system(size: 9.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text("\(t.swapUsed.bytesFormatted) / \(t.swapTotal.bytesFormatted)")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(t.swapPressured ? Theme.danger : .primary)
                        }
                        ProgressBar(fraction: t.swapUsedFraction,
                                    tint: t.swapPressured ? Theme.severity(t.swapUsedFraction) : Theme.metricMemory.opacity(0.45))
                    }
                }
            }
        }
    }

    private func memLegend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(bytes.bytesFormatted)
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

/// CPU: load vs cores; local adds thermal headline + top processes w/ quit.
private struct CPUCard: View {
    let t: MachineTelemetry
    var os: Machine.OS = .unknown
    var thermal: ThermalLevel?
    var contributors: [HeatContributor] = []
    var loading = false
    var onQuit: (HeatContributor) -> Void = { _ in }

    /// Windows exposes an instantaneous utilization %, not a real load
    /// average — so don't fake three identical loadavg rows there.
    private var isLoadAverage: Bool { os != .windows }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("CPU", symbol: "cpu", tint: Theme.metricCPU, trailing: AnyView(headerTrailing))
                HStack(spacing: 20) {
                    ZStack {
                        ArcGauge(fraction: min(t.loadFraction, 1), tint: Theme.metricCPU, lineWidth: 12, size: 116)
                            .animation(.easeOut(duration: 0.4), value: t.loadFraction)
                        VStack(spacing: 0) {
                            if isLoadAverage {
                                Text(String(format: "%.2f", t.load1))
                                    .font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1).monospacedDigit()
                                Text(clockText ?? "load · \(t.hardware.cores)c").font(.system(size: 10)).foregroundStyle(.secondary)
                            } else {
                                Text(min(t.loadFraction, 1), format: .percent.precision(.fractionLength(0)))
                                    .font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1).monospacedDigit()
                                Text(clockText ?? "usage · \(t.hardware.cores)c").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if isLoadAverage {
                        VStack(alignment: .leading, spacing: 0) {
                            loadRow("1 min", String(format: "%.2f", t.load1), Theme.metricCPU)
                            Divider().overlay(Theme.hairline)
                            loadRow("5 min", String(format: "%.2f", t.load5), Theme.metricCPU.opacity(0.7))
                            Divider().overlay(Theme.hairline)
                            loadRow("15 min", String(format: "%.2f", t.load15), Theme.inkTertiary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            loadRow("Utilization", "\(Int((min(t.loadFraction, 1) * 100).rounded()))%", Theme.metricCPU)
                            Divider().overlay(Theme.hairline)
                            loadRow("Cores", "\(t.hardware.cores)", Theme.inkTertiary)
                            if let clk = t.cpuClockMHz {
                                Divider().overlay(Theme.hairline)
                                loadRow("Clock", String(format: "%.2f GHz", Double(clk) / 1000), Theme.metricCPU.opacity(0.7))
                            }
                        }
                    }
                }
                if !t.coreLoads.isEmpty {
                    Divider().overlay(Theme.hairline)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("PER-CORE").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.inkTertiary)
                            Spacer()
                            Text("\(t.coreLoads.count) threads").font(.system(size: 9.5)).foregroundStyle(Theme.inkTertiary)
                        }
                        CoreBars(loads: t.coreLoads)
                    }
                }
                if !contributors.isEmpty {
                    Divider().overlay(Theme.hairline)
                    VStack(spacing: 2) {
                        ForEach(contributors) { c in
                            HStack(spacing: 8) {
                                if let icon = c.runningApp?.icon {
                                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "gearshape.2").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary).frame(width: 16)
                                }
                                Text(c.displayName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text("\(Int(c.load.cpuPercent))%")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                                Button { onQuit(c) } label: {
                                    Image(systemName: "xmark.circle").font(.system(size: 10.5))
                                        .foregroundStyle(c.isQuittable ? Theme.inkTertiary : Theme.inkTertiary.opacity(0.3))
                                }
                                .buttonStyle(Pressable()).disabled(!c.isQuittable)
                                .help(c.isQuittable ? "Quit \(c.displayName)" : "System process")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } else if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Sampling processes…").font(.system(size: 10.5)).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
        }
    }

    private func thermalColor(_ l: ThermalLevel) -> Color {
        switch l { case .nominal: Theme.ok; case .fair: Theme.metricCPU; case .serious: Theme.metricHeat; case .critical: Theme.danger }
    }

    /// A load-average row whose value right-aligns with the process rows below
    /// — the trailing clear box reserves the same width the quit button takes.
    private func loadRow(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Color.clear.frame(width: 14, height: 1)
        }
        .padding(.vertical, 7)
    }

    /// Clock as "3.97 GHz" for the gauge subtitle.
    private var clockText: String? {
        guard let mhz = t.cpuClockMHz, mhz > 0 else { return nil }
        return String(format: "%.2f GHz · %dc", Double(mhz) / 1000, t.hardware.cores)
    }

    /// Trailing badges: CPU temp (remote), macOS thermal state (local).
    @ViewBuilder private var headerTrailing: some View {
        HStack(spacing: 6) {
            if let cpuTemp = t.temps.first(where: { $0.label == "CPU" }) {
                TempPill(celsius: cpuTemp.celsius)
            }
            if let thermal {
                TierBadge(label: thermal.headline, color: thermalColor(thermal))
            }
        }
    }
}

/// A temperature badge — value in °C, tinted by how hot it is.
struct TempPill: View {
    let celsius: Double
    var label: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "thermometer.medium").font(.system(size: 9, weight: .semibold))
            if let label { Text(label).font(.system(size: 9.5, weight: .semibold)) }
            Text("\(Int(celsius.rounded()))°").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(Theme.tempColor(celsius))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.tempColor(celsius).opacity(0.12), in: Capsule())
    }
}

/// GPU: the showpiece for a discrete NVIDIA card — utilization arc, VRAM,
/// temp, power draw vs limit, fan, clock. Appears only when nvidia-smi reads.
private struct GPUCard: View {
    let g: GPUStats

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("GPU", symbol: "cpu.fill", tint: Theme.metricGPU,
                           trailing: g.tempC.map { AnyView(TempPill(celsius: $0)) })
                HStack(spacing: 20) {
                    ZStack {
                        ArcGauge(fraction: g.utilization, tint: Theme.metricGPU, lineWidth: 12, size: 116)
                            .animation(.easeOut(duration: 0.4), value: g.utilization)
                        VStack(spacing: 0) {
                            Text(g.utilization, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1).monospacedDigit()
                            Text("util").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("VRAM").font(.system(size: 11.5)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(g.memUsed.bytesFormatted) / \(g.memTotal.bytesFormatted)")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            ProgressBar(fraction: g.memFraction, tint: Theme.severity(g.memFraction))
                        }
                        if g.powerDraw != nil, g.powerLimit != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Power").font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(powerText).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                }
                                ProgressBar(fraction: g.powerFraction, tint: Theme.metricGPU)
                            }
                        }
                    }
                }
                Divider().overlay(Theme.hairline)
                HStack(spacing: 0) {
                    gpuStat("Name", String(g.name.replacingOccurrences(of: "NVIDIA GeForce ", with: "")))
                    if let clock = g.clockMHz { gpuStat("Clock", "\(clock) MHz") }
                    if let fan = g.fanPercent { gpuStat("Fan", "\(Int((fan * 100).rounded()))%") }
                }
            }
        }
    }

    private var powerText: String {
        let draw = Int(g.powerDraw!.rounded())
        if let lim = g.powerLimit { return "\(draw) / \(Int(lim.rounded())) W" }
        return "\(draw) W"
    }

    private func gpuStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.inkTertiary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Network + disk I/O throughput — Beszel's bandwidth panel.
private struct ActivityCard: View {
    let tp: Throughput

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("Activity", symbol: "waveform.path.ecg", tint: Theme.accent)
                HStack(spacing: 10) {
                    rate("Down", tp.netRx, "arrow.down", Theme.metricDisk)
                    rate("Up", tp.netTx, "arrow.up", Theme.metricMemory)
                }
                HStack(spacing: 10) {
                    rate("Disk read", tp.diskRead, "arrow.down.to.line", Theme.metricCPU)
                    rate("Disk write", tp.diskWrite, "arrow.up.to.line", Theme.metricHeat)
                }
            }
        }
    }

    private func rate(_ label: String, _ bytes: Int64, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.inkTertiary)
            }
            Text(bytes.rateFormatted)
                .font(.system(size: 16, weight: .bold, design: .rounded)).tracking(-0.4)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Docker: per-container health, CPU%, and memory — Beszel's container view.
private struct DockerCard: View {
    let containers: [Container]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("Docker", symbol: "shippingbox.fill", tint: Theme.accent,
                           trailing: AnyView(Text("\(containers.filter(\.isHealthy).count)/\(containers.count) healthy")
                               .font(.system(size: 11)).foregroundStyle(.secondary)))
                VStack(spacing: 0) {
                    ForEach(Array(containers.enumerated()), id: \.element.id) { i, c in
                        VStack(spacing: 6) {
                            HStack(spacing: 9) {
                                Circle().fill(c.isHealthy ? Theme.ok : Theme.metricHeat).frame(width: 7, height: 7)
                                Text(c.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 6)
                                if let cpu = c.cpuPercent {
                                    Text("\(String(format: "%.0f", cpu))%")
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(Theme.metricCPU)
                                }
                                if let mem = c.memUsed {
                                    Text(mem.bytesFormatted)
                                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                                        .foregroundStyle(Theme.metricMemory).lineLimit(1)
                                } else {
                                    Text(c.status).font(.system(size: 10.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                                }
                            }
                            if let cpu = c.cpuPercent {
                                ProgressBar(fraction: min(cpu / 100, 1), tint: Theme.metricCPU.opacity(0.7))
                            }
                        }
                        .padding(.vertical, 5)
                        if i < containers.count - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
            }
        }
    }
}

/// Battery (local): health hero + charge/cycles.
private struct BatteryCard: View {
    let b: BatteryReading

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("Battery", symbol: "battery.100percent", tint: Theme.ok,
                           trailing: AnyView(TierBadge(label: b.healthHeadline, color: healthColor)))
                HStack(spacing: 20) {
                    ZStack {
                        ArcGauge(fraction: Double(b.healthPercent) / 100, tint: healthColor, lineWidth: 12, size: 116)
                        VStack(spacing: 0) {
                            Text("\(b.healthPercent)%")
                                .font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1).monospacedDigit()
                            Text("health").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        statRow("Charge", "\(b.charge)%", Theme.ok)
                        Divider().overlay(Theme.hairline)
                        statRow("Cycles", "\(b.cycleCount)", Theme.metricCPU)
                        Divider().overlay(Theme.hairline)
                        statRow("Capacity", "\(b.maxCapacity)/\(b.designCapacity) mAh", Theme.inkTertiary)
                    }
                }
            }
        }
    }

    private var healthColor: Color {
        switch b.healthPercent { case 90...: Theme.ok; case 80..<90: Theme.metricCPU; case 70..<80: Theme.metricHeat; default: Theme.danger }
    }
}

/// Reclaimable (local): totals + jump to Caches.
private struct ReclaimableCard: View {
    let model: ReclaimableModel
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader("Reclaimable", symbol: "arrow.3.trianglepath", tint: Theme.metricHeat,
                               trailing: AnyView(Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkTertiary)))
                    if model.items.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Finding reclaimable space…").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                        }
                    } else {
                        Text(model.grandTotal.bytesFormatted)
                            .font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.8).monospacedDigit()
                        HStack(spacing: 14) {
                            LegendDot(color: Theme.ok, label: "Free to clear", detail: model.freeToClearBytes.bytesFormatted)
                            LegendDot(color: Theme.metricHeat, label: "Rebuildable", detail: model.regenerableBytes.bytesFormatted)
                        }
                    }
                }
            }
        }
        .buttonStyle(Pressable())
    }
}

/// Uptime: a status-page timeline of reachability over time + 24h uptime %,
/// current streak, and last-seen. Fed by FleetMonitor's persisted history.
private struct UptimeCard: View {
    let id: UUID
    @State private var monitor = FleetMonitor.shared

    var body: some View {
        let checks = monitor.timeline(id)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("Uptime", symbol: "checkmark.seal.fill", tint: Theme.ok,
                           trailing: monitor.reachability(id).map {
                               AnyView(Text("\(Int(($0 * 100).rounded()))% · 24h")
                                   .font(.system(size: 11, weight: .semibold, design: .rounded))
                                   .foregroundStyle($0 > 0.99 ? Theme.ok : $0 > 0.9 ? Theme.metricHeat : Theme.danger)) })
                if checks.count >= 2 {
                    StatusTimeline(checks: checks)
                    HStack(spacing: 8) {
                        if let s = monitor.currentStreak(id) {
                            Circle().fill(s.online ? Theme.ok : Theme.danger).frame(width: 6, height: 6)
                            Text("\(s.online ? "Up" : "Down") since \(s.since.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let seen = monitor.lastSeen(id) {
                            Text("seen \(seen.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Collecting reachability history…").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
        }
    }
}

/// A status-page bar: one segment per check, green up / red down.
struct StatusTimeline: View {
    let checks: [StatusCheck]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(c.online ? Theme.ok : Theme.danger)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 26)
    }
}

// MARK: - shared bits

private func cardHeader(_ title: String, symbol: String, tint: Color, trailing: AnyView? = nil) -> some View {
    HStack(spacing: 9) {
        IconTile(symbol: symbol, tint: tint, size: 26)
        Text(title).font(.system(size: 13.5, weight: .bold))
        Spacer()
        if let trailing { trailing }
    }
}

private func statRow(_ label: String, _ value: String, _ tint: Color) -> some View {
    HStack(spacing: 8) {
        Circle().fill(tint).frame(width: 6, height: 6)
        Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 4)
        Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
    .padding(.vertical, 7)
}

/// Full-width slim progress bar.
struct ProgressBar: View {
    let fraction: Double
    var tint: Color = Theme.metricDisk

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint).frame(width: max(geo.size.width * min(fraction, 1), 3))
            }
        }
        .frame(height: 6)
    }
}

/// A per-core equalizer — one vertical bar per logical core, height/color by
/// load. The btop/iStat instrument-cluster look.
struct CoreBars: View {
    let loads: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.severity(load))
                        .frame(height: max(3, 34 * min(load, 1)))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 34)
        .animation(.easeOut(duration: 0.4), value: loads)
    }
}

extension Int64 {
    /// "1.2 MB/s" — a throughput rate.
    var rateFormatted: String { "\(bytesFormatted)/s" }
}

func uptimeText(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s >= 86400 { return "up \(s / 86400)d" }
    if s >= 3600 { return "up \(s / 3600)h" }
    return "up \(max(1, s / 60))m"
}
