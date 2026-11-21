import Foundation

/// What the stock is made of, for chip-load guidance.
public enum MaterialKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case plywood, hardwood, softwood, mdf, laminatedParticle, softPlastic, hardPlastic
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .plywood: "Plywood"
        case .hardwood: "Hardwood"
        case .softwood: "Softwood"
        case .mdf: "MDF / particleboard"
        case .laminatedParticle: "Laminated particleboard"
        case .softPlastic: "Acrylic / soft plastic"
        case .hardPlastic: "Solid surface / hard plastic"
        }
    }
}

/// Solid-carbide router-bit chip loads at a depth of cut up to 1×D.
///
/// Values are Freud's published CNC feed and speed guide (inches per tooth by diameter and material), interpolated
/// between the 1/8, 1/4, 3/8 and 1/2 inch rows and clamped outside them. Below the range the chip is too thin to carry
/// heat away (rubbing, burning, early dulling); above it the cut gets rough. They are starting points: wood varies.
public enum ChipLoad {
    /// Diameters (in) of the table rows.
    static let diameters: [Double] = [0.125, 0.25, 0.375, 0.5]

    /// (min, max) inches per tooth for each diameter row.
    static let table: [MaterialKind: [(Double, Double)]] = [
        .mdf: [(0.004, 0.007), (0.013, 0.017), (0.018, 0.021), (0.023, 0.027)],
        .laminatedParticle: [(0.003, 0.006), (0.010, 0.015), (0.014, 0.018), (0.022, 0.026)],
        .hardwood: [(0.002, 0.005), (0.008, 0.011), (0.014, 0.016), (0.018, 0.021)],
        .softwood: [(0.004, 0.006), (0.010, 0.012), (0.016, 0.019), (0.020, 0.023)],
        .softPlastic: [(0.003, 0.005), (0.006, 0.009), (0.010, 0.012), (0.012, 0.015)],
        .hardPlastic: [(0.002, 0.004), (0.005, 0.008), (0.008, 0.010), (0.010, 0.012)],
        .plywood: [(0.003, 0.005), (0.006, 0.009), (0.015, 0.018), (0.018, 0.021)],
    ]

    /// Recommended chip-load range (mm per tooth) for a bit diameter (mm) in a material.
    public static func range(_ material: MaterialKind, diameter: Double) -> ClosedRange<Double> {
        let rows = table[material]!
        let d = diameter / LengthUnit.mmPerInch
        let lo: Double, hi: Double
        if d <= diameters[0] {
            (lo, hi) = rows[0]
        } else if d >= diameters[diameters.count - 1] {
            (lo, hi) = rows[rows.count - 1]
        } else {
            var k = 0
            while diameters[k + 1] < d { k += 1 }
            let t = (d - diameters[k]) / (diameters[k + 1] - diameters[k])
            lo = rows[k].0 + (rows[k + 1].0 - rows[k].0) * t
            hi = rows[k].1 + (rows[k + 1].1 - rows[k].1) * t
        }
        return (lo * LengthUnit.mmPerInch)...(hi * LengthUnit.mmPerInch)
    }

    /// Whether the chart applies: solid end mills and ball/bull noses, not V-bits, engravers, drills or surfacing cutters.
    public static func applies(to tool: Tool) -> Bool {
        switch tool.shape {
        case .flatEndMill, .ballNose, .bullNose: true
        default: false
        }
    }

    /// Spindle speed and feed that put the chip load a quarter of the way into the recommended range, keeping the
    /// feed within the machine's cutting cap by lowering RPM (on an Avid stepper the feed cap, not the chart, binds).
    /// `thinning` is the share of the feed per tooth the chip comes to (`radialThinning`, for a light radial cut).
    public static func recommend(for tool: Tool, material: MaterialKind, machine: MachineProfile,
                                 thinning: Double = 1) -> (rpm: Double, feed: Double) {
        let r = range(material, diameter: tool.diameter)
        let target = r.lowerBound + (r.upperBound - r.lowerBound) * 0.25
        let z = Double(max(1, tool.fluteCount))
        let k = min(1, max(0.05, thinning))
        var rpm = machine.clampRPM(tool.cutting.spindleRPM)
        var feed = target * z * rpm / k
        if feed > machine.maxFeedRate {
            rpm = machine.clampRPM(machine.maxFeedRate * k / (z * target))
            feed = min(machine.maxFeedRate, target * z * rpm / k)
        }
        return (rpm, feed)
    }

    /// Radial chip thinning: the share of the feed per tooth the thickest chip comes to when the bit cuts `load` of
    /// its diameter (0–1) from the side, 2√(k(1 − k)) below half its width (the sine of its engagement angle), 1 from
    /// half on.
    public static func radialThinning(load k: Double) -> Double {
        guard k < 0.5 else { return 1 }
        return 2 * (max(0, k) * (1 - max(0, k))).squareRoot()
    }
}
