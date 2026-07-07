import Foundation
import Testing
@testable import MemoryKit
import HonestKit

@Suite("Memory reading")
struct MemoryReadingTests {
    // 16 GB machine, mid-load: 4G free, 3G cached, 6G app, 2G wired, 1G compressed.
    private let gb: Int64 = 1_073_741_824
    private func reading() -> MemoryReading {
        MemoryReading(total: 16 * gb, free: 4 * gb, cached: 3 * gb, app: 6 * gb, wired: 2 * gb, compressed: gb)
    }

    @Test("Honest 'used' excludes cached; naive includes it")
    func honestVsNaive() {
        let m = reading()
        #expect(m.used == 9 * gb)                    // app + wired + compressed
        #expect(m.available == 7 * gb)               // free + cached
        // Naive = total - free = 12G (counts the 3G cached as used).
        #expect(m.metric.naive == Double(12 * gb))
        #expect(m.metric.honest == Double(9 * gb))
        #expect(m.metric.gap == Double(3 * gb))      // exactly the cached files
        #expect(m.metric.confidence == .measured)
    }

    @Test("Pressure ladder tracks genuine unavailability")
    func pressure() {
        // 9/16 = 56% used → fair
        #expect(reading().pressure == .fair)
        // 15G app on 16G → critical
        let hot = MemoryReading(total: 16 * gb, free: 0, cached: 0, app: 15 * gb, wired: gb, compressed: 0)
        #expect(hot.pressure == .critical)
        // Mostly free → nominal
        let cool = MemoryReading(total: 16 * gb, free: 10 * gb, cached: 4 * gb, app: gb, wired: gb, compressed: 0)
        #expect(cool.pressure == .nominal)
    }

    @Test("Live read returns a sane snapshot")
    func liveRead() {
        let m = MemoryMonitor().read()
        #expect(m != nil)
        if let m {
            #expect(m.total > 0)
            #expect(m.used + m.available <= m.total + m.total / 10)  // within rounding slack
        }
    }
}
