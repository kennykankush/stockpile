import Foundation
import Testing
@testable import ThermalKit

@Suite("top parser")
struct TopParserTests {
    // A captured `top -l 2 -stats pid,cpu,command -o cpu` output: two samples.
    // The parser must read the LAST (instantaneous) table, not the first.
    static let fixture = """
    Processes: 500 total
    Load Avg: 4.91, 4.56, 4.26

    PID    %CPU COMMAND
    99999  10.0 STALE_FIRST_SAMPLE

    Processes: 500 total
    Load Avg: 4.91, 4.56, 4.26

    PID    %CPU COMMAND
    50094  92.7 LeagueClient
    408    45.1 WindowServer
    2152   20.6 RustDesk
    6574   5.0 Cherminal Helper
    """

    @Test("Reads the instantaneous (last) sample, not the first")
    func lastSample() {
        let loads = ThermalMonitor.parse(Self.fixture)
        #expect(!loads.contains { $0.command == "STALE_FIRST_SAMPLE" })
        #expect(loads.first?.pid == 50094)
        #expect(loads.first?.cpuPercent == 92.7)
        #expect(loads.count == 4)
    }

    @Test("Command names with spaces survive")
    func spacedCommand() {
        let loads = ThermalMonitor.parse(Self.fixture)
        #expect(loads.contains { $0.command == "Cherminal Helper" })
    }

    @Test("Garbage lines are skipped, not crashed on")
    func robustToJunk() {
        let loads = ThermalMonitor.parse("nonsense\nPID %CPU COMMAND\nnot a row\n123 abc bad\n7 12.5 ok")
        #expect(loads.count == 1)
        #expect(loads.first?.command == "ok")
    }
}

@Suite("heat forecast")
struct HeatForecastTests {
    private func reading(_ level: ThermalLevel, _ loads: [(Int32, Double)]) -> ThermalReading {
        ThermalReading(level: level, processes: loads.map { ProcessLoad(pid: $0.0, command: "p\($0.0)", cpuPercent: $0.1) })
    }

    @Test("Quitting the dominant load sheds most of the heat share")
    func dominantQuit() {
        let r = reading(.serious, [(1, 90), (2, 10)])   // 100 total active
        let relief = HeatForecast.relief(from: r, quitting: [1])
        #expect(abs(relief.removedShare - 0.9) < 0.001)
        #expect(relief.remainingActiveCPU == 10)
        #expect(relief.willLikelyEase)
        #expect(relief.projectedLevel.rank < ThermalLevel.serious.rank)
    }

    @Test("Quitting a trivial process eases nothing")
    func trivialQuit() {
        let r = reading(.serious, [(1, 95), (2, 5)])
        let relief = HeatForecast.relief(from: r, quitting: [2])
        #expect(!relief.willLikelyEase)
        #expect(relief.projectedLevel == .serious)
    }

    @Test("Forecast never predicts below nominal")
    func floorAtNominal() {
        let r = reading(.fair, [(1, 100)])
        let relief = HeatForecast.relief(from: r, quitting: [1])
        #expect(relief.projectedLevel == .nominal)
    }
}
