import SwiftUI
import FleetKit

/// A remote machine's organs — capability-detected. Universal ones always
/// show; docker/battery appear only when the box reports them.
enum RemoteOrgan: String, CaseIterable, Identifiable {
    case overview, disk, memory, cpu, docker, battery
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"; case .disk: "Disk"; case .memory: "Memory"
        case .cpu: "CPU"; case .docker: "Docker"; case .battery: "Battery"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"; case .disk: "internaldrive"
        case .memory: "memorychip"; case .cpu: "cpu"; case .docker: "shippingbox"
        case .battery: "battery.100percent"
        }
    }

    static func available(for t: MachineTelemetry?) -> [RemoteOrgan] {
        var organs: [RemoteOrgan] = [.overview, .disk, .memory, .cpu]
        if t?.hasDocker == true { organs.append(.docker) }
        if t?.hasBattery == true { organs.append(.battery) }
        return organs
    }
}

struct RemoteMachineView: View {
    let machine: Machine
    let organ: RemoteOrgan
    @State private var store = MachineStore.shared

    private var telemetry: MachineTelemetry? { store.telemetry[machine.id] }
    private var isOnline: Bool { store.online[machine.id] ?? false }

    var body: some View {
        Screen(
            title: machine.name,
            subtitle: subtitle,
            actions: {
                BarButton(label: "Refresh", symbol: "arrow.clockwise", disabled: store.refreshing.contains(machine.id)) {
                    Task { await store.refresh(machine) }
                }
            }
        ) {
            Group {
                if let t = telemetry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.sectionGap) {
                            content(t)
                        }
                        .padding(28)
                    }
                } else if store.refreshing.contains(machine.id) {
                    loading
                } else {
                    offline
                }
            }
        }
        .task { if telemetry == nil { await store.refresh(machine) } }
    }

    private var subtitle: String {
        if let t = telemetry {
            return "\(t.hardware.osName) · \(machine.user)@\(machine.host)"
        }
        return isOnline ? machine.host : "offline · \(machine.host)"
    }

    @ViewBuilder
    private func content(_ t: MachineTelemetry) -> some View {
        switch organ {
        case .overview: RemoteOverview(machine: machine, t: t)
        case .disk: RemoteDisk(t: t)
        case .memory: RemoteMemory(t: t)
        case .cpu: RemoteCPU(t: t)
        case .docker: RemoteDocker(t: t)
        case .battery: RemoteBattery()
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to \(machine.host)…").font(.callout).foregroundStyle(.secondary)
            Text("Running the probe over SSH — one round-trip.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offline: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text("Offline").font(.system(.title3, design: .rounded).weight(.semibold))
            Text(store.lastError[machine.id] ?? "Couldn't reach \(machine.user)@\(machine.host).")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Retry") { Task { await store.refresh(machine) } }
                .buttonStyle(.bordered).controlSize(.small).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Organs

private struct RemoteOverview: View {
    let machine: Machine
    let t: MachineTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Hardware identity card — CPU-Z-lite.
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("HARDWARE").font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    hwRow("CPU", "\(t.hardware.cpuModel) · \(t.hardware.cores) cores")
                    hwRow("RAM", t.hardware.ramTotal.bytesFormatted)
                    if let gpu = t.hardware.gpu { hwRow("GPU", gpu) }
                    hwRow("OS", "\(t.hardware.osName) · kernel \(t.hardware.kernel)")
                    hwRow("Uptime", uptimeText(t.uptime))
                }
            }
            // Live health tiles.
            StatStrip(columns: [
                .init(label: "Disk", value: t.diskUsedFraction.formatted(.percent.precision(.fractionLength(0))),
                      caption: "\(t.diskFree.bytesFormatted) free", tint: frac(t.diskUsedFraction)),
                .init(label: "Memory", value: t.memUsedFraction.formatted(.percent.precision(.fractionLength(0))),
                      caption: "\(t.memAvailable.bytesFormatted) available", tint: frac(t.memUsedFraction)),
                .init(label: "CPU load", value: String(format: "%.2f", t.load1),
                      caption: "\(Int(t.loadFraction * 100))% of \(t.hardware.cores) cores", tint: frac(t.loadFraction)),
            ] + (t.hasDocker ? [
                .init(label: "Docker", value: "\(t.containers.count)",
                      caption: "\(t.containers.filter(\.isHealthy).count) healthy", tint: Theme.accent)
            ] : []))
        }
    }

    private func hwRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Text(k).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
    }
}

private struct RemoteDisk: View {
    let t: MachineTelemetry
    var body: some View {
        StatStrip(columns: [
            .init(label: "Used", value: t.diskUsed.bytesFormatted, caption: t.diskUsedFraction.formatted(.percent.precision(.fractionLength(0))), tint: frac(t.diskUsedFraction)),
            .init(label: "Free", value: t.diskFree.bytesFormatted, caption: "available", tint: Theme.tierCache),
            .init(label: "Total", value: t.diskTotal.bytesFormatted, caption: "root volume", tint: Theme.inkTertiary),
        ])
    }
}

private struct RemoteMemory: View {
    let t: MachineTelemetry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Memory", trailing: "used excludes reclaimable cache")
            StatStrip(columns: [
                .init(label: "In use", value: t.memUsed.bytesFormatted, caption: "honest — excludes cache", tint: frac(t.memUsedFraction)),
                .init(label: "Cached", value: t.memCached.bytesFormatted, caption: "reclaimable on demand", tint: Theme.purgeable),
                .init(label: "Available", value: t.memAvailable.bytesFormatted, caption: "free + cache", tint: Theme.tierCache),
            ])
        }
    }
}

private struct RemoteCPU: View {
    let t: MachineTelemetry
    var body: some View {
        StatStrip(columns: [
            .init(label: "Load 1m", value: String(format: "%.2f", t.load1), caption: "\(Int(t.loadFraction*100))% of \(t.hardware.cores)c", tint: frac(t.loadFraction)),
            .init(label: "Load 5m", value: String(format: "%.2f", t.load5), caption: "5-min avg", tint: Theme.accent),
            .init(label: "Load 15m", value: String(format: "%.2f", t.load15), caption: "15-min avg", tint: Theme.inkTertiary),
        ])
    }
}

/// The homelab killer view: every container, its status, health at a glance.
private struct RemoteDocker: View {
    let t: MachineTelemetry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Containers", trailing: "\(t.containers.count) running · \(t.containers.filter(\.isHealthy).count) healthy")
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(t.containers.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 12) {
                            Circle().fill(c.isHealthy ? Theme.tierCache : Theme.tierRegenerable).frame(width: 7, height: 7)
                            Text(c.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(c.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        if i < t.containers.count - 1 { Divider().overlay(Theme.hairline).padding(.leading, 31) }
                    }
                }
            }
        }
    }
}

private struct RemoteBattery: View {
    var body: some View {
        Card { Text("Battery detected. Detailed remote battery health is coming in a later probe.").font(.callout).foregroundStyle(.secondary) }
    }
}

private func frac(_ f: Double) -> Color {
    f > 0.9 ? Theme.tierData : f > 0.75 ? Theme.tierRegenerable : Theme.tierCache
}

private func uptimeText(_ seconds: TimeInterval) -> String {
    let days = Int(seconds) / 86400
    if days > 0 { return "up \(days) day\(days == 1 ? "" : "s")" }
    let hours = Int(seconds) / 3600
    return "up \(hours) hour\(hours == 1 ? "" : "s")"
}
