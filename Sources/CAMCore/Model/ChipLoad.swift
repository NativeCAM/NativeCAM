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

/// Chip loads, spindle speeds and recommended feeds for router bits, from two charts.
///
/// **The end-mill chart** (end mills, ball, bull and tapered ball noses) is Freud's chart for its solid-carbide router
/// bits at a depth of cut up to 1×D (inches per tooth by diameter and material, from Freud's CNC feed and speed guide,
/// "Get the most out of your Freud bits by routing at ideal feed rates and speeds", 2017), interpolated between the
/// 1/8, 1/4, 3/8 and 1/2 inch rows. Freud's chart stops at 1/2"; NativeCAM holds its 1/2" row for bits up to 1" rather
/// than extrapolate (makers that chart larger spirals run them at the same chip or a thicker one: Amana Tool gives
/// about 0.024–0.026" a tooth in wood for a 3/4" three-flute spiral), and a bit wider than 1" is outside the chart.
///
/// **The router-bit chart** (form and dovetail bits) takes its thickest chip from Freud's chart for its carbide-tipped
/// straight and profile bits (1/8" to 3/4" rows, in the same guide) and its thinnest from half of that chart's
/// thinnest: makers' charts for carbide-tipped bits differ by about that much (Amana Tool's CNC charts for its
/// carbide-tipped V-groove and mortising bits give hardwood about 0.003–0.007" a tooth at 18,000 RPM, around half of
/// Freud's), so the range spans both and the recommendation aims at its thin end, as Freud also advises for a first
/// cut ("start your tests with the lower feed rates"). Bits wider than 3/4" are read at the 3/4" row, never
/// extrapolated. Each bit also has a top speed for its full diameter (`routerSpeedLimits`), from the router-bit speed
/// chart in makers' safety guides (24,000 RPM up to 1", 18,000 for 1-1/4" to 2", 16,000 for 2-1/4" to 2-1/2", 12,000
/// for 2-3/4" to 3-1/2"), stepping down sooner and never faster in between: 24,000 RPM up to 1", 18,000 to 1-1/2",
/// 16,000 to 2-1/4", 14,000 to 2-1/2" and 12,000 to 3-1/2". Amana Tool rates its bits faster (28,000 RPM under 2"), so
/// NativeCAM takes the slower; a bit's own rating, on its shank or packaging, comes first. A bit wider than 3-1/2" is
/// outside the chart.
///
/// Below a chart's range the chip is too thin to carry heat away (rubbing, burning, early dulling); above it the cut
/// gets rough. They are starting points: wood varies.
public enum ChipLoad {
    /// Diameters (in) of the end-mill chart's rows.
    static let diameters: [Double] = [0.125, 0.25, 0.375, 0.5]
    /// The widest end mill (in) the chart covers: its 1/2" row holds up to here.
    static let endMillChartTop = 1.0

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

    /// Diameters (in) of the router-bit chart's rows.
    static let routerDiameters: [Double] = [0.125, 0.25, 0.375, 0.5, 0.625, 0.75]

    /// The router-bit chart's thickest chip (in per tooth) for each row: Freud's carbide-tipped profile-bit maximum. The
    /// thinnest is half Freud's minimum for the row (`routerThinnest`).
    static let routerThickest: [MaterialKind: [Double]] = [
        .mdf: [0.004, 0.006, 0.007, 0.007, 0.007, 0.009],
        .laminatedParticle: [0.006, 0.008, 0.009, 0.010, 0.011, 0.012],
        .hardwood: [0.004, 0.007, 0.008, 0.010, 0.012, 0.013],
        .softwood: [0.005, 0.008, 0.010, 0.012, 0.013, 0.012],
        .softPlastic: [0.006, 0.008, 0.009, 0.010, 0.011, 0.012],
        .hardPlastic: [0.004, 0.006, 0.007, 0.007, 0.007, 0.009],
        .plywood: [0.005, 0.006, 0.008, 0.009, 0.010, 0.011],
    ]

    /// The router-bit chart's thinnest chip (in per tooth) for each row: half Freud's carbide-tipped profile-bit minimum.
    static let routerThinnest: [MaterialKind: [Double]] = [
        .mdf: [0.001, 0.002, 0.0025, 0.003, 0.003, 0.0035],
        .laminatedParticle: [0.0015, 0.003, 0.0035, 0.004, 0.0045, 0.005],
        .hardwood: [0.001, 0.0025, 0.003, 0.004, 0.004, 0.0045],
        .softwood: [0.0015, 0.003, 0.004, 0.004, 0.0045, 0.005],
        .softPlastic: [0.0015, 0.003, 0.0035, 0.004, 0.0045, 0.005],
        .hardPlastic: [0.001, 0.002, 0.0025, 0.003, 0.003, 0.0035],
        .plywood: [0.0015, 0.0025, 0.003, 0.0035, 0.004, 0.0045],
    ]

    /// Router-bit speed limits: (widest diameter in inches, top RPM) for a bit that wide or narrower.
    public static let routerSpeedLimits: [(diameter: Double, rpm: Double)] = [
        (1, 24000), (1.5, 18000), (2.25, 16000), (2.5, 14000), (3.5, 12000),
    ]

    /// Outside every chart, the feed is held to this share of the machine's cutting cap at most.
    static let outsideFeedShare = 0.5

    /// Recommended chip-load range (mm per tooth) for a bit diameter (mm) in a material, from the end-mill chart.
    public static func range(_ material: MaterialKind, diameter: Double) -> ClosedRange<Double> {
        let (lo, hi) = interpolate(diameter / LengthUnit.mmPerInch, rows: diameters, table[material]!)
        return (lo * LengthUnit.mmPerInch)...(hi * LengthUnit.mmPerInch)
    }

    /// The (min, max) of `values` at `d` inches: interpolated between rows, held at the first and last.
    private static func interpolate(_ d: Double, rows: [Double], _ values: [(Double, Double)]) -> (Double, Double) {
        if d <= rows[0] { return values[0] }
        if d >= rows[rows.count - 1] { return values[values.count - 1] }
        var k = 0
        while rows[k + 1] < d { k += 1 }
        let t = (d - rows[k]) / (rows[k + 1] - rows[k])
        return (values[k].0 + (values[k + 1].0 - values[k].0) * t, values[k].1 + (values[k + 1].1 - values[k].1) * t)
    }

    /// The router-bit chart's range (mm per tooth) for a bit read at `diameter` mm.
    static func routerRange(_ material: MaterialKind, diameter: Double) -> ClosedRange<Double> {
        let rows = zip(routerThinnest[material]!, routerThickest[material]!).map { ($0, $1) }
        let (lo, hi) = interpolate(diameter / LengthUnit.mmPerInch, rows: routerDiameters, rows)
        return (lo * LengthUnit.mmPerInch)...(hi * LengthUnit.mmPerInch)
    }

    /// The fastest a router bit `diameter` mm across should turn (the speed chart, `routerSpeedLimits`); past the
    /// chart's widest (3-1/2"), the speed that keeps its rim no faster than a 3-1/2" bit's at 12,000 RPM.
    public static func routerSpeedLimit(diameter: Double) -> Double {
        let d = diameter / LengthUnit.mmPerInch
        if let row = routerSpeedLimits.first(where: { d <= $0.diameter + 1e-6 }) { return row.rpm }
        let last = routerSpeedLimits[routerSpeedLimits.count - 1]
        return (last.rpm * last.diameter / d).rounded(.down)
    }

    /// Whether a chart applies: solid end mills, ball/bull noses and tapered ball noses, form and dovetail bits (at
    /// the diameter they cut with, `Tool.cuttingDiameter(atDepth:)`), not V-bits, engravers, drills or surfacing cutters.
    public static func applies(to tool: Tool) -> Bool {
        switch tool.shape {
        case .flatEndMill, .ballNose, .bullNose, .taperedBallNose, .form, .dovetail: true
        default: false
        }
    }

    /// The diameter to read the chart at for `tool` cutting `depth` deep: the widest it cuts with there for a tapered
    /// ball nose, form or dovetail bit (`Tool.cuttingDiameter(atDepth:)`), else its diameter. With no depth, a tapered
    /// ball nose is read at its full diameter and form and dovetail bits at theirs.
    public static func chartDiameter(_ tool: Tool, depth: Double?) -> Double {
        guard let depth, tool.shape.requiredFormatVersion > 1 else { return tool.diameter }
        return tool.cuttingDiameter(atDepth: depth)
    }

    // MARK: Reading a chart

    /// The two charts.
    public enum Chart: String, Sendable, Hashable {
        /// Solid-carbide end mills (and ball, bull and tapered ball noses).
        case endMill
        /// Form (profile) and dovetail bits.
        case routerBit

        public var label: String { self == .endMill ? "end-mill chart" : "router-bit chart" }
    }

    /// Where a bit's chip load and speeds come from, for one toolpath depth: the chart, the diameter it's read at, the
    /// range and the chip the recommendation aims at, and the limits on its speed and feed.
    public struct Reading: Sendable, Hashable {
        public var chart: Chart
        /// The bit's shape and form, for naming it.
        public var shape: ToolShape
        public var formKind: FormProfile.Kind?
        /// The diameter the chart is read at (mm): the widest the bit cuts with at the depth.
        public var diameter: Double
        /// The bit's widest diameter (mm), which sets its speed limit: the whole head turns, cutting or not.
        public var fullDiameter: Double
        /// The chart row read (in): the diameter, or the chart's widest row when the bit is wider.
        public var rowInches: Double
        /// The chip-load range, mm per tooth.
        public var range: ClosedRange<Double>
        /// The chip the recommendation aims at, mm per tooth: a quarter into the end-mill chart's range, the thin end
        /// of the router-bit chart's, and the thin end of the widest row's outside every chart.
        public var target: Double
        /// The bit is wider than every chart covers (an end mill over 1", a form or dovetail bit over 3-1/2"): it's read
        /// at the widest row and recommended conservatively.
        public var outsideChart: Bool
        /// The fastest the bit should turn (RPM), or nil when no chart sets one (end mills up to 1").
        public var maxRPM: Double?
        /// Form bits: the cross-section (mm²) a full pass at the depth takes from a square edge, between the line its tip
        /// rides and its cutting edge. nil for other bits.
        public var crossSection: Double?
        /// The share of the chart's feed the cross-section allows (`ChipLoad.crossSectionShare`): 1 unless the cut is
        /// bigger than a slot as wide and as deep as the bit's shank.
        public var crossSectionShare: Double

        /// What the bit is called in notes: "roundover", "dovetail", "end mill".
        public var bitName: String {
            switch shape {
            case .form: formKind.map { $0 == .custom ? "form bit" : $0.label.lowercased() } ?? "form bit"
            case .dovetail: "dovetail"
            case .flatEndMill: "end mill"
            case .ballNose: "ball nose"
            case .bullNose: "bull nose"
            case .taperedBallNose: "tapered ball nose"
            default: shape.label.lowercased()
            }
        }

        /// The chart and how it was read, for the recommendation and the chip-load check: "router-bit chart, 1/2"
        /// dovetail", or "router-bit chart, 1" roundover, 3/4" row" when a wider bit takes the chart's widest row. A bit
        /// read at less than its full width, or wider than every chart, says so.
        public func source(_ units: LengthUnit) -> String {
            let size = ChipLoad.size(diameter, units)
            if outsideChart {
                let row = ChipLoad.size(rowInches * LengthUnit.mmPerInch, units)
                return "no chart covers a \(ChipLoad.size(fullDiameter, units)) \(bitName): read at the \(chart.label)'s \(row) row"
            }
            var s = "\(chart.label), "
            if diameter < fullDiameter - 0.01 {
                s += "\(ChipLoad.size(fullDiameter, units)) \(bitName) read at \(size), its widest at this depth"
            } else {
                s += "\(size) \(bitName)"
            }
            if rowInches * LengthUnit.mmPerInch < diameter - 0.01 {
                s += ", \(ChipLoad.size(rowInches * LengthUnit.mmPerInch, units)) row"
            }
            return s
        }

        /// The limits that shape the recommendation, as short sentences (empty for an end mill the chart covers).
        public func notes(_ units: LengthUnit) -> [String] {
            var out: [String] = []
            if let maxRPM {
                let rpm = Int(maxRPM.rounded()).formatted()
                if outsideChart {
                    out.append("Wider than every chart: the thinnest chip of its widest row, at most \(rpm) RPM and half the machine's cutting feed.")
                } else {
                    out.append("At most \(rpm) RPM for a bit \(ChipLoad.size(fullDiameter, units)) across.")
                }
            }
            if crossSectionShare < 1 - 1e-9 {
                out.append("Feed held to \(Int((100 * crossSectionShare).rounded()))% for the profile's cross-section, "
                    + "bigger than a slot as wide and as deep as the shank.")
            }
            return out
        }
    }

    /// Reads the chart for `tool` cutting `depth` deep (nil: at its full diameter and, for a form bit, the whole profile)
    /// in `material`.
    public static func reading(_ tool: Tool, material: MaterialKind, depth: Double?) -> Reading {
        let d = chartDiameter(tool, depth: depth)
        let full = max(tool.diameter, tool.shape.cutsEdgesOnly ? 2 * (tool.cuttingEdge.map(\.x).max() ?? 0) : 0)
        let inches = d / LengthUnit.mmPerInch
        switch tool.shape {
        case .form, .dovetail:
            let outside = full / LengthUnit.mmPerInch > routerSpeedLimits[routerSpeedLimits.count - 1].diameter + 1e-6
            let r = routerRange(material, diameter: d)
            var area: Double?
            var share = 1.0
            if tool.shape == .form {
                let a = crossSection(tool, depth: depth)
                area = a
                share = crossSectionShare(area: a, shank: tool.shankDiameter > 1e-6 ? tool.shankDiameter : tool.diameter)
            }
            return Reading(chart: .routerBit, shape: tool.shape, formKind: tool.form?.kind, diameter: d, fullDiameter: full,
                           rowInches: min(inches, routerDiameters[routerDiameters.count - 1]), range: r, target: r.lowerBound,
                           outsideChart: outside, maxRPM: routerSpeedLimit(diameter: full), crossSection: area,
                           crossSectionShare: share)
        default:
            let r = range(material, diameter: d)
            let outside = inches > endMillChartTop + 1e-6
            return Reading(chart: .endMill, shape: tool.shape, formKind: nil, diameter: d, fullDiameter: max(d, tool.diameter),
                           rowInches: min(inches, diameters[diameters.count - 1]), range: r,
                           target: outside ? r.lowerBound : r.lowerBound + (r.upperBound - r.lowerBound) * 0.25,
                           outsideChart: outside, maxRPM: outside ? routerSpeedLimit(diameter: tool.diameter) : nil,
                           crossSection: nil, crossSectionShare: 1)
        }
    }

    /// The chip-load range (mm per tooth) for `tool` cutting `depth` deep in `material`, from the chart that applies.
    public static func range(_ material: MaterialKind, for tool: Tool, depth: Double?) -> ClosedRange<Double> {
        reading(tool, material: material, depth: depth).range
    }

    /// A form bit's cut cross-section (mm²): the area between the line its tip rides (its radius at the tip, the pilot
    /// on a roundover or cove) and its cutting edge, from the tip up to `depth` (nil: the whole profile), as a full pass
    /// takes it from a square edge.
    static func crossSection(_ tool: Tool, depth: Double?) -> Double {
        let edge = tool.cuttingEdge
        let profile = tool.form?.profileHeight ?? tool.fluteLength
        let top = min(depth ?? max(profile, 1e-6), tool.fluteLength)
        guard top > 1e-9, !edge.isEmpty else { return 0 }
        let tip = ToolProfile.radius(edge, atHeight: 0)
        // Simpson's rule over fine slices (the edge is a polyline within 0.002 mm of its arcs).
        let n = 400
        let h = top / Double(n)
        var sum = 0.0
        for i in 0...n {
            let w = i == 0 || i == n ? 1.0 : (i % 2 == 1 ? 4.0 : 2.0)
            sum += w * max(0, ToolProfile.radius(edge, atHeight: Double(i) * h) - tip)
        }
        return sum * h / 3
    }

    /// The share of the chart's feed a form bit cutting `area` mm² on a `shank` mm shank gets: the chart's chips are for
    /// a straight bit cutting no deeper than its diameter (Freud), so up to a slot as wide and as deep as the shank
    /// (shank²) the chart's feed stands, and a bigger cut has it cut in proportion, so the bit takes no more material a
    /// minute than that slot would. Never below a tenth.
    static func crossSectionShare(area: Double, shank: Double) -> Double {
        guard area > 1e-9, shank > 1e-9 else { return 1 }
        return min(1, max(0.1, shank * shank / area))
    }

    /// A diameter as a router bit's size: 1/2", 1-1/2", 0.55" or 12.7 mm.
    public static func size(_ mm: Double, _ units: LengthUnit) -> String {
        guard units == .inch else {
            return "\(mm.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))) mm"
        }
        let v = mm / LengthUnit.mmPerInch
        let n = (v * 32).rounded()
        guard abs(v * 32 - n) < 0.005, n > 0 else {
            return "\(v.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)))\""
        }
        let whole = Int(n) / 32
        var num = Int(n) % 32, den = 32
        while num > 0, num % 2 == 0 { num /= 2; den /= 2 }
        if num == 0 { return "\(whole)\"" }
        return whole > 0 ? "\(whole)-\(num)/\(den)\"" : "\(num)/\(den)\""
    }

    // MARK: Recommendation

    /// Why a recommended feed is below the chart's.
    public enum Hold: String, Sendable, Hashable {
        /// The machine's cutting cap.
        case machine
        /// The toolpath's own limit (adaptive clearing's loops).
        case toolpath
        /// A form bit's large cross-section (`Reading.crossSectionShare`).
        case crossSection
        /// The conservative limit for a bit outside every chart.
        case outsideChart
    }

    /// A recommended spindle speed and feed, and where they came from.
    public struct Recommendation: Sendable, Hashable {
        public var rpm: Double
        public var feed: Double
        public var reading: Reading
        /// What held the feed below the chart's at the bit's speed, or nil when nothing did.
        public var heldBy: Hold?
        /// The bit's speed limit is below the spindle's slowest speed: this machine can't turn it slowly enough.
        public var belowSpindleMinimum: Bool
    }

    /// Spindle speed and feed that put the chip at the chart's target (`Reading.target`), keeping the feed within the
    /// machine's cutting cap by lowering RPM (on an Avid stepper the feed cap, not the chart, binds).
    /// `thinning` is the share of the feed per tooth the chip comes to (`radialThinning`, for a light radial cut).
    /// `feedLimit` is a cap of the toolpath's own (adaptive clearing's loops, `AdaptiveSettings.loopFeedLimit`), held
    /// to the same way. Never below the spindle's slowest speed: there, the feed stays at the cap and the chip may
    /// come out thinner than the chart. `depth` is the toolpath's depth, which sets the chart's diameter for a bit whose
    /// width changes with depth (`chartDiameter`) and a form bit's cross-section; nil reads the bit at its full diameter.
    ///
    /// Form and dovetail bits (the router-bit chart) also never turn faster than their speed limit (`Reading.maxRPM`),
    /// even below the spindle's slowest; a form bit whose cut is bigger than a slot as wide and as deep as its shank has
    /// its feed cut in proportion (`crossSectionShare`); and a bit outside every chart takes the thin end of the widest
    /// row, the speed limit, and at most half the machine's cutting feed.
    public static func recommendation(for tool: Tool, material: MaterialKind, machine: MachineProfile, thinning: Double = 1,
                                      feedLimit: Double? = nil, depth: Double? = nil) -> Recommendation {
        let reading = Self.reading(tool, material: material, depth: depth)
        let target = reading.target
        let z = Double(max(1, tool.fluteCount))
        let k = min(1, max(0.05, thinning))
        func speed(_ rpm: Double) -> Double { reading.maxRPM.map { min(machine.clampRPM(rpm), $0) } ?? machine.clampRPM(rpm) }
        var rpm = speed(tool.cutting.spindleRPM)
        var feed = target * z * rpm / k
        var caps: [(feed: Double, why: Hold)] = [(machine.maxFeedRate, .machine)]
        if let feedLimit { caps.append((feedLimit, .toolpath)) }
        if reading.crossSectionShare < 1 { caps.append((feed * reading.crossSectionShare, .crossSection)) }
        if reading.outsideChart { caps.append((machine.maxFeedRate * outsideFeedShare, .outsideChart)) }
        let cap = caps.map(\.feed).min()!
        var held: Hold?
        if feed > cap {
            held = caps.first { $0.feed == cap }?.why
            rpm = speed(cap * k / (z * target))
            feed = min(cap, target * z * rpm / k)
        }
        let below = reading.maxRPM.map { $0 < machine.minRPM - 1e-9 } ?? false
        return Recommendation(rpm: rpm, feed: feed, reading: reading, heldBy: held, belowSpindleMinimum: below)
    }

    /// The recommended spindle speed and feed (`recommendation(for:material:machine:thinning:feedLimit:depth:)`).
    public static func recommend(for tool: Tool, material: MaterialKind, machine: MachineProfile,
                                 thinning: Double = 1, feedLimit: Double? = nil, depth: Double? = nil) -> (rpm: Double, feed: Double) {
        let r = recommendation(for: tool, material: material, machine: machine, thinning: thinning, feedLimit: feedLimit, depth: depth)
        return (r.rpm, r.feed)
    }

    /// Radial chip thinning: the share of the feed per tooth the thickest chip comes to when the bit cuts `load` of
    /// its diameter (0–1) from the side, 2√(k(1 − k)) below half its width (the sine of its engagement angle), 1 from
    /// half on.
    public static func radialThinning(load k: Double) -> Double {
        guard k < 0.5 else { return 1 }
        return 2 * (max(0, k) * (1 - max(0, k))).squareRoot()
    }
}
