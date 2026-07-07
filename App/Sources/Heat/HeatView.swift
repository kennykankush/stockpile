import SwiftUI
import AppKit
import ThermalKit
import LedgerKit

/// A process contributor, resolved against the app that owns it so we can
/// name it in plain words and offer a graceful quit.
struct HeatContributor: Identifiable {
    var id: Int32 { load.pid }
    let load: ProcessLoad
    let runningApp: NSRunningApplication?

    var displayName: String {
        runningApp?.localizedName ?? load.command
    }
    var isQuittable: Bool { runningApp != nil }
}

@MainActor
@Observable
final class HeatModel {
    var reading: ThermalReading?
    var contributors: [HeatContributor] = []
    var isSampling = false
    var banner: String?

    /// The biggest quittable app — the forecast headliner.
    var topQuittable: HeatContributor? {
        contributors.first { $0.isQuittable }
    }

    func sample() async {
        guard !isSampling else { return }
        isSampling = true
        let raw = await ThermalMonitor().sample()
        // Exclude Stockpile's own processes — measuring ourselves shouldn't
        // attribute the cost of the measurement as heat the user should quit.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundlePrefix = Bundle.main.bundleIdentifier ?? "com.hadimulia.stockpile"
        let kept = raw.processes.filter { load in
            if load.pid == ownPID { return false }
            if load.command.localizedCaseInsensitiveContains("Stockpile") { return false }
            let bid = NSRunningApplication(processIdentifier: load.pid)?.bundleIdentifier ?? ""
            return !bid.hasPrefix(ownBundlePrefix)
        }
        reading = ThermalReading(level: raw.level, processes: kept)
        contributors = kept.map { load in
            HeatContributor(load: load, runningApp: NSRunningApplication(processIdentifier: load.pid))
        }
        isSampling = false

        // Snapshot once per launch — the Ledger becomes a whole-machine timeline.
        if !AppRuntime.heatRecorded {
            AppRuntime.heatRecorded = true
            let top = kept.first.map { "\($0.command) leading" } ?? "idle"
            await LedgerStore.shared.append(LedgerEvent(
                kind: .snapshot,
                title: "Heat snapshot",
                detail: "\(raw.level.headline.lowercased()) · \(top)",
                metrics: ["thermalRank": Int64(raw.level.rank)]
            ))
        }
    }

    func quit(_ contributor: HeatContributor) async {
        guard let app = contributor.runningApp else { return }
        let name = contributor.displayName
        let share = reading.map { Int($0.share(of: contributor.load) * 100) } ?? 0
        let quit = await RunningApps.quitAndWait(app)
        if quit {
            await LedgerStore.shared.append(LedgerEvent(
                kind: .cleared,
                title: "Quit \(name) to cool down",
                detail: "\(name) was ~\(share)% of active compute load (~\(Int(contributor.load.cpuPercent))% CPU)."
            ))
            banner = "Quit \(name) — was ~\(share)% of your active heat load."
            await sample()
        } else {
            banner = "\(name) didn't quit — it may have unsaved work."
        }
    }
}

/// Heat: which processes are actually contributing to how hot you're running,
/// and what quitting them would likely do. Attribution is a MODEL (share of
/// active compute load ≈ share of heat), shown honestly — never "its degrees."
struct HeatView: View {
    @State private var model = HeatModel()
    @State private var live = false

    var body: some View {
        Screen(
            title: "Heat",
            subtitle: "Who's driving the heat — by share of active compute load, not degrees.",
            actions: {
                BarButton(label: live ? "Live ●" : "Go live", symbol: live ? "dot.radiowaves.left.and.right" : "play") {
                    live.toggle()
                }
                BarButton(label: "Refresh", symbol: "arrow.clockwise", disabled: model.isSampling) {
                    Task { await model.sample() }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    if let banner = model.banner {
                        Card(padding: 14) {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.tierCache)
                                Text(banner).font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Dismiss") { model.banner = nil }
                                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if let reading = model.reading {
                        gauge(reading)
                        if let top = model.topQuittable {
                            forecastCard(reading: reading, top: top)
                        }
                        contributorList(reading)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Reading thermal state…").font(.callout).foregroundStyle(.secondary)
                            Text("Sampling instantaneous CPU load — about a second.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .padding(28)
            }
        }
        .task { if model.reading == nil { await model.sample() } }
        // Live mode: samples on a loop ONLY while this tab is on screen and
        // the toggle is on. The task cancels the instant you leave Heat or
        // flip it off — no background observer-effect tax.
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled && live {
                await model.sample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func gauge(_ reading: ThermalReading) -> some View {
        HeroCard {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THERMAL PRESSURE")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Text(reading.level.headline)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(color(for: reading.level))
                    Text("macOS-reported pressure — the honest, stable signal (no per-chip °C guessing).")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                Spacer()
                // Four-segment pressure ladder.
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(ThermalLevel.allCases.reversed(), id: \.self) { lvl in
                        HStack(spacing: 8) {
                            Text(lvl.rawValue.capitalized)
                                .font(.system(size: 11))
                                .foregroundStyle(lvl == reading.level ? .primary : .tertiary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(lvl == reading.level ? color(for: lvl) : Theme.surface2)
                                .frame(width: 40, height: 8)
                        }
                    }
                }
            }
        }
    }

    private func forecastCard(reading: ThermalReading, top: HeatContributor) -> some View {
        let relief = HeatForecast.relief(from: reading, quitting: [top.load.pid])
        return Card {
            HStack(spacing: 14) {
                IconTile(symbol: "wand.and.stars", tint: Theme.accent, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Forecast — estimate")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(forecastText(reading: reading, top: top, relief: relief))
                        .font(.system(size: 13)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Quit \(top.displayName)") { Task { await model.quit(top) } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent.opacity(0.85)).controlSize(.large)
            }
        }
    }

    private func forecastText(reading: ThermalReading, top: HeatContributor, relief: HeatForecast.Relief) -> String {
        let share = Int(reading.share(of: top.load) * 100)
        if relief.willLikelyEase {
            return "\(top.displayName) is ~\(share)% of your active load. Quitting it sheds ~\(Int(relief.removedShare * 100))% — pressure would likely ease toward \(relief.projectedLevel.headline.lowercased()) within ~30s (thermal lag)."
        } else {
            return "\(top.displayName) is ~\(share)% of your active load. Quitting it helps a little, but wouldn't change the overall pressure much on its own."
        }
    }

    private func contributorList(_ reading: ThermalReading) -> some View {
        let largestShare = reading.processes.map { reading.share(of: $0) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Contributors", trailing: "share of active load · excludes Stockpile itself")
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(model.contributors.enumerated()), id: \.element.id) { index, c in
                        let share = reading.share(of: c.load)
                        ContributorRow(
                            contributor: c,
                            share: share,
                            fractionOfLargest: largestShare > 0 ? share / largestShare : 0
                        ) { Task { await model.quit(c) } }
                        if index < model.contributors.count - 1 {
                            Divider().overlay(Theme.hairline).padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }

    private func color(for level: ThermalLevel) -> Color {
        switch level {
        case .nominal: Theme.tierCache
        case .fair: Theme.accent
        case .serious: Theme.tierRegenerable
        case .critical: Theme.tierData
        }
    }
}

private struct ContributorRow: View {
    let contributor: HeatContributor
    let share: Double
    let fractionOfLargest: Double
    let onQuit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(contributor.displayName)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(Int(contributor.load.cpuPercent))% CPU · PID \(contributor.load.pid)\(contributor.isQuittable ? "" : " · system")")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer(minLength: 12)
            // One prominent number: the heat share, with a bar to match.
            SizeBar(fraction: fractionOfLargest, tint: Theme.tierRegenerable.opacity(0.75), width: 90)
            Text("\(Int(share * 100))%")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
            Button(action: onQuit) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering && contributor.isQuittable ? Theme.tierData : Color.white.opacity(0.12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(Pressable())
            .disabled(!contributor.isQuittable)
            .help(contributor.isQuittable ? "Quit \(contributor.displayName)" : "System process — not safe to quit here")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        if let app = contributor.runningApp, let nsImage = app.icon {
            Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
        } else {
            IconTile(symbol: "gearshape.2", size: 26)
        }
    }
}
