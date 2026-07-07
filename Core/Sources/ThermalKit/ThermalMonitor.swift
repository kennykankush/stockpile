import Foundation

/// Samples system thermal pressure and per-process compute load — all
/// no-sudo. Load comes from `top -l 2`, whose *second* sample is instantaneous
/// %CPU (a lifetime-average like `ps` would misattribute long-idle apps).
public struct ThermalMonitor: Sendable {
    public init() {}

    public func sample(topPath: String = "/usr/bin/top") async -> ThermalReading {
        let level = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let output = await Self.runTop(topPath)
        let processes = Self.parse(output)
        return ThermalReading(level: level, processes: processes)
    }

    /// Parses the LAST "PID %CPU COMMAND" table from `top -l 2` output — the
    /// instantaneous sample. Pure and testable against a captured fixture.
    public static func parse(_ output: String) -> [ProcessLoad] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Find the last header row; rows after it are the instantaneous sample.
        guard let headerIndex = lines.lastIndex(where: {
            $0.contains("PID") && $0.contains("%CPU")
        }) else { return [] }

        var loads: [ProcessLoad] = []
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let cols = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0]),
                  let cpu = Double(cols[1]) else { continue }
            // COMMAND can contain spaces — rejoin the tail.
            let command = cols[2...].joined(separator: " ")
            loads.append(ProcessLoad(pid: pid, command: command, cpuPercent: cpu))
        }
        return loads.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private static func runTop(_ path: String) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            // -l 2: two samples (2nd is instantaneous) · -n 25: top 25 by CPU.
            process.arguments = ["-l", "2", "-n", "25", "-stats", "pid,cpu,command", "-o", "cpu"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
