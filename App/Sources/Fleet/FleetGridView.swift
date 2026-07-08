import SwiftUI
import FleetKit

/// The cockpit home — a fleet-wide summary band over an instrument-cluster
/// tile per machine (identity + three gauges + vitals).
struct FleetGridView: View {
    @State private var store = MachineStore.shared
    let onOpen: (Machine) -> Void
    @State private var addingMachine = false
    @State private var updates = UpdateChecker.shared

    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 16, alignment: .top)]

    var body: some View {
        Screen(
            title: "Fleet",
            subtitle: "\(store.machines.count) machine\(store.machines.count == 1 ? "" : "s") · \(reachableCount) reachable",
            actions: {
                BarButton(label: "Refresh all", symbol: "arrow.clockwise") { Task { await store.refreshAll() } }
            }
        ) {
            ScrollView {
                VStack(spacing: 16) {
                    if let latest = updates.latestVersion {
                        UpdateBanner(version: latest)
                    }
                    FleetSummaryBar(machines: store.machines, telemetry: store.telemetry, online: store.online)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.machines) { machine in
                            Button { onOpen(machine) } label: {
                                MachineTile(
                                    machine: machine,
                                    telemetry: store.telemetry[machine.id],
                                    online: store.online[machine.id] ?? (machine.kind == .local),
                                    refreshing: store.refreshing.contains(machine.id)
                                )
                            }
                            .buttonStyle(Pressable())
                            .contextMenu {
                                if machine.kind == .remote {
                                    Button("Remove", role: .destructive) { store.remove(machine) }
                                }
                            }
                        }
                        Button { addingMachine = true } label: { AddTile() }
                            .buttonStyle(Pressable())
                    }
                }
                .padding(Theme.pagePadding)
            }
        }
        .task {
            await store.refreshAll()
            await updates.checkIfNeeded()
        }
        .sheet(isPresented: $addingMachine) { AddMachineView() }
    }

    private var reachableCount: Int {
        store.machines.filter { store.online[$0.id] ?? ($0.kind == .local) }.count
    }
}

// MARK: - Fleet summary

/// The mission-control band: aggregate vitals across the whole fleet.
private struct FleetSummaryBar: View {
    let machines: [Machine]
    let telemetry: [UUID: MachineTelemetry]
    let online: [UUID: Bool]

    // An adaptive grid — cells reflow to fewer-per-row as the window narrows
    // instead of crushing labels/numbers into two lines.
    private let cols = [GridItem(.adaptive(minimum: 158, maximum: .infinity), spacing: 0, alignment: .leading)]

    var body: some View {
        Card(padding: 8) {
            LazyVGrid(columns: cols, spacing: 4) {
                cell("MACHINES", "\(onlineCount)/\(machines.count)", "online", "wifi", Theme.accent)
                cell("STORAGE", totalStorage.bytesFormatted, "across fleet", "internaldrive", Theme.metricDisk)
                cell("MEMORY", totalRAM.bytesFormatted, "installed", "memorychip", Theme.metricMemory)
                cell("CONTAINERS", "\(totalContainers)", "running", "shippingbox.fill", Theme.ok)
                if alertCount > 0 {
                    cell("ALERTS", "\(alertCount)", "need a look", "exclamationmark.triangle.fill", Theme.metricHeat)
                }
            }
        }
    }

    private func cell(_ label: String, _ value: String, _ caption: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 11) {
            IconTile(symbol: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.inkTertiary).lineLimit(1).fixedSize()
                Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).tracking(-0.4)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).allowsTightening(true)
                Text(caption).font(.system(size: 10)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveTelemetry: [MachineTelemetry] {
        machines.compactMap { (online[$0.id] ?? ($0.kind == .local)) ? telemetry[$0.id] : nil }
    }
    private var onlineCount: Int { machines.filter { online[$0.id] ?? ($0.kind == .local) }.count }
    private var totalStorage: Int64 { liveTelemetry.reduce(0) { $0 + $1.disks.reduce(Int64(0)) { $0 + $1.total } } }
    private var totalRAM: Int64 { liveTelemetry.reduce(0) { $0 + $1.hardware.ramTotal } }
    private var totalContainers: Int { liveTelemetry.reduce(0) { $0 + $1.containers.count } }
    private var alertCount: Int {
        liveTelemetry.filter {
            var w = max($0.diskUsedFraction, $0.memUsedFraction, min($0.loadFraction, 1))
            if $0.swapPressured { w = max(w, $0.swapUsedFraction) }
            return w > 0.75
        }.count
    }
}

// MARK: - Machine tile

private struct MachineTile: View {
    let machine: Machine
    let telemetry: MachineTelemetry?
    let online: Bool
    let refreshing: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                // Header — fixed height (icon + name/status + subtitle).
                HStack(alignment: .center, spacing: 10) {
                    IconTile(symbol: osSymbol, tint: online ? Theme.accent : Theme.inkTertiary, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(machine.name).font(.system(size: 15, weight: .bold)).tracking(-0.2).lineLimit(1)
                            statusPill
                            Spacer(minLength: 0)
                        }
                        Text(subtitleText).font(.system(size: 10.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                    }
                }

                if let t = telemetry, online {
                    hardwareLine(t)            // fixed 1 line
                    gauges(t)                  // fixed anchor — aligns across all cards
                    Divider().overlay(Theme.hairline)
                    footer(t)                  // two consistent bands
                } else {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if refreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "wifi.slash").font(.system(size: 13)).foregroundStyle(Theme.inkTertiary) }
                        Text(refreshing ? "connecting…" : "offline")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        Spacer()
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .top)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(status.color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(status.color.opacity(0.12), in: Capsule())
    }

    // Hardware identity chip line — this is a hardware monitor first.
    private func hardwareLine(_ t: MachineTelemetry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 9.5)).foregroundStyle(Theme.inkTertiary)
            Text(hwText(t)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // The instrument cluster: three gauges.
    private func gauges(_ t: MachineTelemetry) -> some View {
        HStack(spacing: 8) {
            gauge("DISK", t.diskUsedFraction, Theme.metricDisk)
            gauge("MEM", t.memUsedFraction, Theme.metricMemory)
            gauge("CPU", min(t.loadFraction, 1), Theme.metricCPU)
        }
        .frame(maxWidth: .infinity)
    }

    private func gauge(_ label: String, _ fraction: Double, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                ArcGauge(fraction: fraction, tint: tint, lineWidth: 7, size: 70)
                    .animation(.easeOut(duration: 0.4), value: fraction)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 16, weight: .bold, design: .rounded)).tracking(-0.5).monospacedDigit()
            }
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.9).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // Footer — two consistent bands so every tile has the same shape:
    //   band 1: a named chip per drive (magi's C: AND D: both show)
    //   band 2: capability chips (temp / net / gpu / docker / battery)
    private func footer(_ t: MachineTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(t.disks.prefix(3)) { d in
                    vital("internaldrive", "\(d.name) \(d.free.bytesFormatted)", Theme.metricDisk)
                }
                if t.disks.count > 3 { vital("externaldrive", "+\(t.disks.count - 3)", Theme.inkTertiary) }
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if let temp = primaryTemp(t) {
                    vital("thermometer.medium", "\(Int(temp.celsius.rounded()))°", Theme.tempColor(temp.celsius))
                }
                if let tp = t.throughput, tp.netRx + tp.netTx > 0 {
                    vital("arrow.down.arrow.up", "\(shortRate(tp.netRx))↓ \(shortRate(tp.netTx))↑", Theme.accent)
                }
                if let g = t.gpu {
                    vital("cpu.fill", "GPU \(Int((g.utilization * 100).rounded()))%", Theme.metricGPU)
                }
                if t.hasDocker {
                    vital("shippingbox.fill", "\(t.containers.filter(\.isHealthy).count)/\(t.containers.count)", Theme.accent)
                }
                if t.hasBattery { vital("battery.100percent", nil, Theme.ok) }
                if t.swapPressured {
                    vital("exclamationmark.triangle.fill", "SWAP \(Int((t.swapUsedFraction * 100).rounded()))%",
                          Theme.severity(t.swapUsedFraction))
                }
            }
        }
    }

    /// Compact rate for a tile chip: "1.2M", "340K", "8K", "0".
    private func shortRate(_ bytesPerSec: Int64) -> String {
        let b = Double(bytesPerSec)
        if b >= 1_000_000 { return String(format: "%.1fM", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0fK", b / 1_000) }
        return "\(bytesPerSec)"
    }

    /// The most telling temperature to headline on the tile — CPU, else GPU, else hottest.
    private func primaryTemp(_ t: MachineTelemetry) -> TempReading? {
        t.temps.first { $0.label == "CPU" } ?? t.temps.first { $0.label == "GPU" } ?? t.temps.max { $0.celsius < $1.celsius }
    }

    private func vital(_ symbol: String, _ text: String?, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(tint)
            if let text {
                Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4.5)
        .background(tint.opacity(0.09), in: Capsule())
    }

    // MARK: derived

    private var status: (label: String, color: Color) {
        guard online, let t = telemetry else { return ("Offline", Theme.inkTertiary) }
        var worst = max(t.diskUsedFraction, t.memUsedFraction, min(t.loadFraction, 1))
        if t.swapPressured { worst = max(worst, t.swapUsedFraction) }
        if worst > 0.9 { return ("Critical", Theme.danger) }
        if worst > 0.75 { return ("Warm", Theme.metricHeat) }
        return ("Healthy", Theme.ok)
    }

    private func hwText(_ t: MachineTelemetry) -> String {
        var parts: [String] = []
        if !t.hardware.cpuModel.isEmpty { parts.append(cleanCPU(t.hardware.cpuModel)) }
        parts.append("\(t.hardware.cores) cores")
        parts.append(t.hardware.ramTotal.bytesFormatted)
        if let gpu = t.hardware.gpu { parts.append(shortGPU(gpu)) }
        return parts.joined(separator: "  ·  ")
    }

    private func cleanCPU(_ s: String) -> String {
        s.replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
            .replacingOccurrences(of: " Processor", with: "")
            .replacingOccurrences(of: " CPU", with: "")
            .replacingOccurrences(of: #"\s+\d+-Core"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "AMD ", with: "")
            .replacingOccurrences(of: "Intel ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func shortGPU(_ s: String) -> String {
        s.replacingOccurrences(of: "NVIDIA GeForce ", with: "")
            .replacingOccurrences(of: "NVIDIA ", with: "")
            .replacingOccurrences(of: "AMD Radeon ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var subtitleText: String {
        if machine.kind == .local { return "this machine" }
        if let t = telemetry, online { return "\(t.hardware.osName) · \(machine.host)" }
        return machine.host
    }

    private var osSymbol: String {
        if machine.kind == .local { return "laptopcomputer" }
        switch machine.os { case .windows: return "pc"; case .linux: return "server.rack"; default: return "desktopcomputer" }
    }
}

private struct AddTile: View {
    var body: some View {
        Card {
            VStack(spacing: 10) {
                IconTile(symbol: "plus", size: 40)
                Text("Add machine").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("Connect over Tailscale SSH").font(.system(size: 10.5)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 172)
        }
    }
}
