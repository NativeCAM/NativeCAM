import Foundation

/// How a toolpath sets its spindle speed (`CAMOperation.spindleSpeed`).
public enum SpindleSpeedMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The tool's own RPM (`CuttingData.spindleRPM`), as every toolpath had before.
    case tool
    /// Picked per toolpath to put the chip at the chart's target at the feed the machine reaches (`AutomaticSpindle`).
    case automatic
    public var id: String { rawValue }
    public var label: String { self == .tool ? "Tool's RPM" : "Automatic" }
}

/// The spindle speed Spindle ▸ Automatic picked for one toolpath, and why (`ChipLoad.automaticSpindle`).
///
/// On a drive-capped machine (an Avid stepper tops out at 400 in/min) the feed can't rise to the chart's, so the
/// spindle speed is what sets the chip: the speed is `feed × thinning / (flutes × target)`, the feed being the
/// toolpath's own held to the machine's cutting cap and the target the chart's (`ChipLoad.Reading.target`, after the
/// depth derate). It's rounded to 100 RPM, kept within the spindle's range, and never above a router bit's speed limit
/// (`ChipLoad.Reading.maxRPM`). One S per toolpath, written at its start like any toolpath's.
///
/// Uses the chart's figures, which haven't been calibrated on a machine; the feed is the programmed one, not the one
/// the planner reaches on short moves.
public struct AutomaticSpindle: Hashable, Codable, Sendable {
    /// What held the speed from the one the chart's chip needs.
    public enum Limit: String, Codable, Sendable {
        /// The spindle's fastest.
        case spindleMaximum
        /// The spindle's slowest.
        case spindleMinimum
        /// A router bit's speed limit for its diameter.
        case bitLimit
    }

    /// The speed picked, RPM.
    public var rpm: Double
    /// The tool's own speed, which the toolpath would otherwise run at.
    public var toolRPM: Double
    /// The feed the chip is worked out at, mm/min: the toolpath's feed, held to the machine's cutting cap.
    public var feed: Double
    /// The toolpath's feed is faster than the machine's cutting cap, which holds it.
    public var feedCapped: Bool
    /// The speed the chart's target chip needs at that feed, before rounding and limits.
    public var wanted: Double
    /// What held the speed from `wanted`, or nil.
    public var limit: Limit?
    /// The chip at `rpm` and `feed` (after radial thinning), mm per tooth.
    public var chip: Double
    /// The chart's range and target for this bit, depth and material, mm per tooth (after the depth derate).
    public var rangeLow: Double
    public var rangeHigh: Double
    public var target: Double
    /// How far below the range the chip-load check lets a chip go before it warns (0.9 for end mills, 0.8 otherwise).
    public var floorShare: Double
    /// The depth derate taken into the range (`ChipLoad.depthShare`).
    public var depthShare: Double

    /// True when the chip at the picked speed is outside what the chip-load check accepts.
    public var outOfRange: Bool { chip < rangeLow * floorShare - 1e-12 || chip > rangeHigh * 1.25 + 1e-12 }

    /// A speed as the posts write it: whole RPM, as in `S\(Int(rpm.rounded()))`.
    fileprivate static func rpmText(_ v: Double) -> String { "\(Int(v.rounded()).formatted()) RPM" }
    /// The speed the chart's chip would need, rounded to 100 RPM as the speed picked is: "about 30,500 RPM".
    private var wantedText: String { "about \(Self.rpmText((wanted / 100).rounded() * 100))" }
    private static func chipText(_ mm: Double) -> String { String(format: "%.4f in", mm / LengthUnit.mmPerInch) }

    /// Why this speed, in a sentence: the feed it's for and what held it.
    public func reason(_ units: LengthUnit) -> String {
        let feedText = "\(units.format(feed, decimals: 0)) \(units.feedSymbol)"
        var s = "\(Self.rpmText(rpm)) puts the chip at \(Self.chipText(chip)) at \(feedText)"
        s += feedCapped ? " (the machine's cutting cap, below the toolpath's feed)" : ""
        switch limit {
        case nil:
            s += ", the chart's target for this bit"
        case .spindleMaximum:
            s += ": the chart's chip would need \(wantedText), past the spindle's fastest"
        case .spindleMinimum:
            s += ": the chart's chip would need \(wantedText), below the spindle's slowest"
        case .bitLimit:
            s += ": the chart's chip would need \(wantedText), past this bit's speed limit"
        }
        if depthShare < 1 - 1e-9 { s += ", with the chip cut to \(Int((100 * depthShare).rounded()))% for the pass depth" }
        return s + "."
    }

    /// The warning when the speed couldn't put the chip in range, or nil.
    public func warning(_ units: LengthUnit) -> String? {
        guard outOfRange else { return nil }
        let range = "\(Self.chipText(rangeLow))–\(Self.chipText(rangeHigh))"
        let thin = chip < rangeLow
        var s = "Automatic spindle speed can't keep the chip in the chart's \(range) range: "
        switch limit {
        case .spindleMaximum: s += "it needs \(wantedText), and the spindle tops out at \(Self.rpmText(rpm))"
        case .spindleMinimum: s += "it needs \(wantedText), and the spindle turns no slower than \(Self.rpmText(rpm))"
        case .bitLimit: s += "it needs \(wantedText), and this bit is rated to \(Self.rpmText(rpm))"
        case nil: s += "at \(Self.rpmText(rpm))"
        }
        s += ", so the chip is \(Self.chipText(chip))"
        s += thin ? "; thin chips rub, burn and dull the bit. Raise the feed or use a bit with fewer flutes."
            : "; expect a rougher edge. Lower the feed or use a bit with more flutes."
        return s
    }
}

public extension AutomaticSpindle {
    /// What Spindle ▸ Automatic does with `tool` when no chip-load chart covers it (a V-bit, an engraving bit, a drill):
    /// it keeps the tool's own speed, which the toolpath then posts. nil when a chart covers it and a speed is picked.
    static func keepsToolRPMNote(for tool: Tool) -> String? {
        guard !ChipLoad.applies(to: tool) || tool.fluteCount <= 0 else { return nil }
        return "No chip-load chart covers a \(tool.shape.label.lowercased()), so Automatic keeps the tool's "
            + "\(rpmText(tool.cutting.spindleRPM)) for this toolpath."
    }
}

public extension ChipLoad {
    /// The feed per tooth (mm, before radial thinning) the inspector shows under the bit picture and in the Chip load
    /// row, so both are at the speed that will be posted: at Spindle ▸ Automatic's speed `automaticRPM`, the tool's feed
    /// held to the machine's cutting cap over that speed (as `AutomaticSpindle.chip` works it out), else the tool's own
    /// `Tool.chipLoad` at its RPM.
    static func feedPerTooth(_ tool: Tool, machine: MachineProfile, automaticRPM: Double?) -> Double {
        guard let rpm = automaticRPM, rpm > 0 else { return tool.chipLoad }
        return min(tool.cutting.feedRate, machine.maxFeedRate) / (rpm * Double(max(1, tool.fluteCount)))
    }

    /// Spindle ▸ Automatic: the speed that puts `tool`'s chip at the chart's target (`Reading.target`) at `feed` mm/min
    /// held to the machine's cutting cap, rounded to 100 RPM, within the spindle's range and never past a router bit's
    /// speed limit (unless the spindle can't turn that slowly, which the chip-load check warns about). `thinning`,
    /// `depth`, `crossSection` and `passDepth` read the chart as `recommendation` does. nil when no chart applies.
    static func automaticSpindle(for tool: Tool, material: MaterialKind, machine: MachineProfile, feed set: Double,
                                 thinning: Double = 1, depth: Double? = nil, crossSection: Double? = nil,
                                 passDepth: Double? = nil) -> AutomaticSpindle? {
        guard applies(to: tool), tool.fluteCount > 0, set > 0 else { return nil }
        let reading = reading(tool, material: material, depth: depth, crossSection: crossSection, passDepth: passDepth)
        let z = Double(tool.fluteCount)
        let k = min(1, max(0.05, thinning))
        let feed = min(set, machine.maxFeedRate)
        let wanted = feed * k / (z * reading.target)
        var rpm = (wanted / 100).rounded() * 100
        var limit: AutomaticSpindle.Limit?
        if let top = reading.maxRPM, rpm > top { rpm = top; limit = .bitLimit }
        if rpm > machine.maxRPM { rpm = machine.maxRPM; limit = .spindleMaximum }
        if rpm < machine.minRPM { rpm = machine.minRPM; limit = .spindleMinimum }
        return AutomaticSpindle(rpm: rpm, toolRPM: tool.cutting.spindleRPM, feed: feed, feedCapped: set > machine.maxFeedRate + 1e-6,
                                wanted: wanted, limit: limit, chip: feed * k / (z * rpm), rangeLow: reading.range.lowerBound,
                                rangeHigh: reading.range.upperBound, target: reading.target,
                                floorShare: tool.shape == .flatEndMill ? 0.9 : 0.8, depthShare: reading.depthShare)
    }
}
