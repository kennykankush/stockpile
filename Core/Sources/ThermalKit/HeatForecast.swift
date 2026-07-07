import Foundation

/// The forecast nobody else does: if you quit these processes, how much of the
/// active heat load goes away — and does pressure likely ease? It's a MODEL
/// (steady-state, with real thermal lag), labelled an estimate like purgeable.
public enum HeatForecast {
    public struct Relief: Sendable {
        /// Fraction of active CPU load the quit set represents (0…1).
        public let removedShare: Double
        /// Active CPU remaining after the quit.
        public let remainingActiveCPU: Double
        /// The level we'd likely settle toward — estimate, never a promise.
        public let projectedLevel: ThermalLevel
        public let willLikelyEase: Bool
    }

    /// Predicts relief from quitting `pids`. Heat share ≈ CPU-load share, so
    /// removing a large share of active load eases pressure roughly one step
    /// per ~40% of load shed from a hot state — deliberately conservative.
    public static func relief(
        from reading: ThermalReading,
        quitting pids: Set<Int32>
    ) -> Relief {
        let total = reading.totalActiveCPU
        let removed = reading.processes
            .filter { pids.contains($0.pid) }
            .reduce(0) { $0 + $1.cpuPercent }
        let removedShare = total > 0 ? removed / total : 0
        let remaining = max(0, total - removed)

        // Conservative step-down: each ~40% of active load shed can ease the
        // level by one rank, but never below nominal, never predict below the
        // heat a fully-quit machine would still sit at.
        let stepsEased = Int((removedShare / 0.40).rounded(.down))
        let projectedRank = max(0, reading.level.rank - stepsEased)
        let projected = ThermalLevel.allCases[projectedRank]

        return Relief(
            removedShare: removedShare,
            remainingActiveCPU: remaining,
            projectedLevel: projected,
            willLikelyEase: projected.rank < reading.level.rank
        )
    }
}
