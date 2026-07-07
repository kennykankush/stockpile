import Foundation
import Testing
@testable import BatteryKit

@Suite("Battery parser")
struct BatteryParserTests {
    // A trimmed real `ioreg -rn AppleSmartBattery` sample. Note the inline
    // BatteryData blob repeats keys WITHOUT spaces around `=` — the parser
    // must take the top-level `"Key" = value` form only.
    static let fixture = """
          "CurrentCapacity" = 100
          "AppleRawCurrentCapacity" = 8162
          "ExternalConnected" = Yes
          "BatteryData" = {"DesignCapacity"=9999,"MaxCapacity"=100,"CycleCount"=999}
          "FullyCharged" = Yes
          "MaxCapacity" = 100
          "IsCharging" = No
          "DesignCapacity" = 8579
          "CycleCount" = 36
          "AppleRawMaxCapacity" = 8217
    """

    @Test("Reads top-level keys, ignores the inline blob's collisions")
    func topLevelWins() throws {
        let b = try #require(BatteryMonitor.parse(Self.fixture))
        #expect(b.charge == 100)
        #expect(b.cycleCount == 36)               // NOT 999 from the blob
        #expect(b.designCapacity == 8579)          // NOT 9999 from the blob
        #expect(b.maxCapacity == 8217)
        #expect(b.onACPower)
        #expect(!b.isCharging)
    }

    @Test("Health = raw-max ÷ design")
    func health() throws {
        let b = try #require(BatteryMonitor.parse(Self.fixture))
        #expect(b.healthPercent == 96)             // 8217/8579 = 95.8 → 96
        #expect(b.healthHeadline == "Excellent")
    }

    @Test("Desktop (no battery keys) yields nil")
    func noBattery() {
        #expect(BatteryMonitor.parse("no battery here\n\"Something\" = 5") == nil)
    }
}
