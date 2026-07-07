import Foundation

/// The honest battery picture. The naive "100%" is charge; the number Apple
/// buries is *health* — how much of its original capacity the battery still
/// holds. That's the honest story.
public struct BatteryReading: Sendable, Hashable {
    public let charge: Int          // current charge %
    public let isCharging: Bool
    public let onACPower: Bool
    public let cycleCount: Int
    public let designCapacity: Int  // mAh, as-new
    public let maxCapacity: Int     // mAh, current full-charge capacity

    public init(charge: Int, isCharging: Bool, onACPower: Bool, cycleCount: Int, designCapacity: Int, maxCapacity: Int) {
        self.charge = charge
        self.isCharging = isCharging
        self.onACPower = onACPower
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
    }

    /// Health = current full capacity ÷ design capacity. The buried number.
    public var healthPercent: Int {
        designCapacity > 0 ? Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded()) : 0
    }

    public var healthHeadline: String {
        switch healthPercent {
        case 90...: "Excellent"
        case 80..<90: "Good"
        case 70..<80: "Fair — aging"
        default: "Worn"
        }
    }
}
