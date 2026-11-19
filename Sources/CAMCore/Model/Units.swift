import Foundation

/// Display/output length unit. CAMCore stores every length in millimetres.
public enum LengthUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case inch
    case mm

    public var id: String { rawValue }
    public static let mmPerInch = 25.4

    /// Millimetres per one of this unit.
    public var mmPerUnit: Double { self == .inch ? LengthUnit.mmPerInch : 1 }

    public func toMM(_ v: Double) -> Double { v * mmPerUnit }
    public func fromMM(_ v: Double) -> Double { v / mmPerUnit }

    public var symbol: String { self == .inch ? "in" : "mm" }
    public var feedSymbol: String { self == .inch ? "in/min" : "mm/min" }
    /// Decimal places shown for lengths in the UI.
    public var displayDecimals: Int { self == .inch ? 4 : 3 }

    public func format(_ mm: Double, decimals: Int? = nil) -> String {
        String(format: "%.\(decimals ?? displayDecimals)f", fromMM(mm))
    }
}

/// Convenience for writing values in inches in code and tests.
public extension Double {
    var inch: Double { self * LengthUnit.mmPerInch }
    var mm: Double { self }
}

public extension Int {
    var inch: Double { Double(self) * LengthUnit.mmPerInch }
}
