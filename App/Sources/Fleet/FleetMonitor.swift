import SwiftUI
import UserNotifications
import FleetKit

/// One reachability sample.
struct StatusCheck: Codable, Sendable, Hashable {
    let t: Date
    let online: Bool
}

/// The fleet's memory of health over time: records every refresh into a
/// per-machine reachability history (persisted), computes uptime %, and fires
/// notifications on the transitions that matter — a machine going down/up, or
/// a vital crossing a critical threshold. De-duped so it alerts on the *edge*,
/// not every tick.
@MainActor
@Observable
final class FleetMonitor {
    static let shared = FleetMonitor()

    private(set) var history: [UUID: [StatusCheck]] = [:]
    private var lastOnline: [UUID: Bool] = [:]
    private var alarmed: [UUID: Set<String>] = [:]
    private var notificationsAllowed = false

    private let cap = 2016                       // ~7 days at 5-min resolution
    private let sampleInterval: TimeInterval = 60
    private let key = "fleet.history.v1"

    init() { load() }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAllowed = granted }
        }
    }

    // MARK: recording

    func record(_ id: UUID, name: String, telemetry: MachineTelemetry?, online: Bool) {
        checkAlerts(id: id, name: name, telemetry: telemetry, online: online)

        var series = history[id] ?? []
        let stateChanged = series.last?.online != online
        let stale = series.last.map { Date().timeIntervalSince($0.t) >= sampleInterval } ?? true
        if stateChanged || stale {
            series.append(StatusCheck(t: Date(), online: online))
            if series.count > cap { series.removeFirst(series.count - cap) }
            history[id] = series
            save()
        }
    }

    // MARK: queries

    /// Fraction of checks that were online over the window (default 24h).
    func reachability(_ id: UUID, since window: TimeInterval = 86400) -> Double? {
        let cutoff = Date().addingTimeInterval(-window)
        let checks = (history[id] ?? []).filter { $0.t >= cutoff }
        guard !checks.isEmpty else { return nil }
        return Double(checks.filter(\.online).count) / Double(checks.count)
    }

    func lastSeen(_ id: UUID) -> Date? { history[id]?.last(where: \.online)?.t }

    func timeline(_ id: UUID, count: Int = 48) -> [StatusCheck] { Array((history[id] ?? []).suffix(count)) }

    /// How long the machine has been continuously in its current state.
    func currentStreak(_ id: UUID) -> (online: Bool, since: Date)? {
        guard let series = history[id], let last = series.last else { return nil }
        var since = last.t
        for c in series.reversed() {
            if c.online == last.online { since = c.t } else { break }
        }
        return (last.online, since)
    }

    // MARK: alerts

    private func checkAlerts(id: UUID, name: String, telemetry: MachineTelemetry?, online: Bool) {
        if let was = lastOnline[id] {
            if was, !online { notify("\(name) went offline", "No longer reachable.") }
            if !was, online { notify("\(name) is back online", "Reachable again.") }
        }
        lastOnline[id] = online

        guard let t = telemetry, online else { return }
        var rules: [(key: String, tripped: Bool, desc: String)] = [
            ("disk", t.diskUsedFraction > 0.9, "disk \(pct(t.diskUsedFraction))"),
            ("mem", t.memUsedFraction > 0.9, "memory \(pct(t.memUsedFraction))"),
            ("swap", t.swapPressured && t.swapUsedFraction > 0.9, "swap \(pct(t.swapUsedFraction))"),
        ]
        if let hottest = t.temps.map(\.celsius).max() { rules.append(("temp", hottest >= 90, "temperature \(Int(hottest))°C")) }
        if let gt = t.gpu?.tempC { rules.append(("gpu", gt >= 90, "GPU \(Int(gt))°C")) }

        var set = alarmed[id] ?? []
        for r in rules {
            if r.tripped, !set.contains(r.key) {
                notify("\(name): \(r.desc)", "Crossed the alert threshold.")
                set.insert(r.key)
            } else if !r.tripped {
                set.remove(r.key)          // reset so it can fire again next time
            }
        }
        alarmed[id] = set
    }

    private func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    private func notify(_ title: String, _ body: String) {
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: persistence

    private func save() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([UUID: [StatusCheck]].self, from: data) else { return }
        history = decoded
    }
}
