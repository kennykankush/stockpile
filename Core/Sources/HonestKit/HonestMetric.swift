import Foundation

/// Stockpile's philosophy, made load-bearing. Every organ tells the same
/// story: a *naive* number people are shown, an *honest* number that's true,
/// and the caveat bridging them — plus whether it was measured or estimated.
/// Disk (physical vs effective), Heat (state vs CPU-share), Memory (used vs
/// available) all instantiate this shape.
public struct HonestMetric: Sendable, Hashable {
    public enum Confidence: String, Sendable, Hashable {
        case measured   // a real system reading
        case estimated  // a model — shown with an "estimate" badge
    }

    public enum Unit: Sendable, Hashable {
        case bytes, fraction, count
    }

    public let title: String
    /// The number a naive tool would show — true but misleading alone.
    public let naive: Double
    /// The honest number, once the caveat is accounted for.
    public let honest: Double
    /// Why the two differ, in plain words.
    public let caveat: String
    public let confidence: Confidence
    public let unit: Unit

    public init(title: String, naive: Double, honest: Double, caveat: String,
                confidence: Confidence = .measured, unit: Unit = .bytes) {
        self.title = title
        self.naive = naive
        self.honest = honest
        self.caveat = caveat
        self.confidence = confidence
        self.unit = unit
    }

    /// The gap the caveat explains (purgeable, cached files, model slack…).
    public var gap: Double { naive - honest }

    public func format(_ value: Double) -> String {
        switch unit {
        case .bytes: Int64(value).formatted(.byteCount(style: .file))
        case .fraction: value.formatted(.percent.precision(.fractionLength(0)))
        case .count: Int(value).formatted()
        }
    }

    public var naiveText: String { format(naive) }
    public var honestText: String { format(honest) }
    public var gapText: String { format(gap) }
}

/// A four-step pressure ladder shared by every organ that has "pressure"
/// (heat, memory) so the UI reads consistently across the app.
public enum PressureLevel: String, Sendable, CaseIterable, Hashable {
    case nominal, fair, serious, critical

    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
