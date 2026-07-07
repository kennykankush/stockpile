import Foundation

/// Reads battery health from `ioreg -rn AppleSmartBattery` — no sudo. The
/// health numbers (design vs raw-max capacity in mAh) are the ones Apple
/// doesn't surface in the UI.
public struct BatteryMonitor: Sendable {
    public init() {}

    /// Returns nil on desktops (no battery).
    public func read() -> BatteryReading? {
        Self.parse(Self.runIoreg())
    }

    /// Parses top-level ioreg `"Key" = value` lines (spaces around `=`), which
    /// excludes the inline BatteryData blob whose keys use `Key=value`.
    public static func parse(_ output: String) -> BatteryReading? {
        var kv: [String: String] = [:]
        for line in output.split(separator: "\n") {
            // Top-level lines look like:  "DesignCapacity" = 8579
            guard let eq = line.range(of: "\" = ") else { continue }
            let key = line[..<eq.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            let value = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            if kv[key] == nil { kv[key] = value }   // first (top-level) wins
        }

        guard let design = kv["DesignCapacity"].flatMap({ Int($0) }), design > 0,
              let rawMax = kv["AppleRawMaxCapacity"].flatMap({ Int($0) }) else {
            return nil
        }
        return BatteryReading(
            charge: kv["CurrentCapacity"].flatMap { Int($0) } ?? 0,
            isCharging: kv["IsCharging"] == "Yes",
            onACPower: kv["ExternalConnected"] == "Yes",
            cycleCount: kv["CycleCount"].flatMap { Int($0) } ?? 0,
            designCapacity: design,
            maxCapacity: rawMax
        )
    }

    private static func runIoreg() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rn", "AppleSmartBattery"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
