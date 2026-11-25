import Foundation

public enum CutSide: String, Codable, Sendable, CaseIterable, Identifiable {
    case outside, inside, on
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Climb vs conventional milling, assuming a clockwise (M3) spindle.
public enum CutDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case climb, conventional
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Depths are measured down from the material top (positive numbers, mm).
public struct DepthSettings: Hashable, Codable, Sendable {
    public var startDepth: Double
    /// The final depth below the material top. With `fromBottom` set it follows the material thickness
    /// (`Project.fitDepthsToMaterial()` keeps it so), so a build that doesn't know `fromBottom` cuts the same depth.
    public var cutDepth: Double
    /// Max depth per pass; nil uses the tool's stepdown.
    public var passDepth: Double?
    /// A cut depth tied to the material thickness: the cut stops this far above the material's bottom, mm. Negative
    /// cuts through it, that far into the spoilboard ("through the material"); positive leaves that much ("thickness
    /// − x"). nil = `cutDepth` is a plain depth below the top, whatever the thickness.
    ///
    /// No new file format: `cutDepth` is always saved fitted to the thickness, so an older build cuts the same depth.
    public var fromBottom: Double?

    public init(startDepth: Double = 0, cutDepth: Double, passDepth: Double? = nil, fromBottom: Double? = nil) {
        self.startDepth = startDepth
        self.cutDepth = cutDepth
        self.passDepth = passDepth
        self.fromBottom = fromBottom
    }

    /// Z levels (negative, relative to material top) for each pass, evenly distributed, last = final depth.
    /// `firstPassMinimum` (compression bits) makes the first pass at least that deep and spreads the rest evenly.
    public func passLevels(toolStepdown: Double, firstPassMinimum: Double? = nil) -> [Double] {
        let total = cutDepth - startDepth
        guard total > 1e-9 else { return [] }
        let step = max(0.01, passDepth ?? toolStepdown)
        let n = max(1, Int((total / step - 1e-9).rounded(.up)))
        let even = (1...n).map { -(startDepth + total * Double($0) / Double(n)) }
        guard let minFirst = firstPassMinimum, startDepth < 1e-9, total / Double(n) < minFirst - 1e-9 else { return even }
        let first = min(total, minFirst)
        let rest = total - first
        guard rest > 1e-6 else { return [-(startDepth + total)] }
        let m = max(1, Int((rest / step - 1e-9).rounded(.up)))
        return [-(startDepth + first)] + (1...m).map { -(startDepth + first + rest * Double($0) / Double(m)) }
    }
}

public struct TabSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    /// Tabs per closed contour (evenly spaced along it).
    public var count: Int
    /// Tab length along the contour, mm.
    public var width: Double
    /// Tab thickness: how much material is left standing above the final cut depth, mm.
    public var thickness: Double

    public init(enabled: Bool = false, count: Int = 4, width: Double = 0.375.inch, thickness: Double = 0.125.inch) {
        self.enabled = enabled
        self.count = count
        self.width = width
        self.thickness = thickness
    }
}

public enum EntryKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Straight plunge at the plunge rate.
    case plunge
    /// Ramp down along the cutting path over `rampLength`.
    case ramp
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public struct EntrySettings: Hashable, Codable, Sendable {
    public var kind: EntryKind
    public var rampLength: Double

    public init(kind: EntryKind = .plunge, rampLength: Double = 1.inch) {
        self.kind = kind
        self.rampLength = rampLength
    }
}

public enum LeadKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Tangent arc onto the cut.
    case arc
    /// Straight line meeting the cut at an angle.
    case line
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Short moves in the waste that start and end each closed profile loop, so the bit never plunges or stops
/// against the finished wall.
public struct LeadSettings: Hashable, Codable, Sendable {
    public var kind: LeadKind
    /// Arc radius, mm.
    public var radius: Double
    /// Arc sweep, degrees (15–180).
    public var sweep: Double
    /// Line length, mm.
    public var length: Double
    /// Angle between a line lead and the cut, degrees (10–90; 90 comes in square to it).
    public var angle: Double
    /// Leave each loop on a lead too (otherwise the last lap ends on the wall).
    public var leadOut: Bool
    /// How far the last lap runs past its start before leading out, mm.
    public var overlap: Double

    public init(kind: LeadKind = .arc, radius: Double = 0.25.inch, sweep: Double = 90, length: Double = 0.25.inch,
                angle: Double = 45, leadOut: Bool = true, overlap: Double = 0) {
        self.kind = kind
        self.radius = radius
        self.sweep = sweep
        self.length = length
        self.angle = angle
        self.leadOut = leadOut
        self.overlap = overlap
    }

    /// The lead's main size (arc radius or line length).
    var size: Double { kind == .arc ? radius : length }
}

public enum CornerReliefStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Cut into the corner along its bisector.
    case dogbone
    /// Cut past the corner along one wall, so the notch is in the other wall only.
    case tBone
    public var id: String { rawValue }
    public var label: String { self == .dogbone ? "Dogbone" : "T-bone" }
}

/// Which wall of a corner a T-bone's notch goes into.
public enum TBoneSide: String, Codable, Sendable, CaseIterable, Identifiable {
    case longer, shorter, alongX, alongY
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .longer: "Longer side"
        case .shorter: "Shorter side"
        case .alongX: "Sides along X"
        case .alongY: "Sides along Y"
        }
    }
}

/// Relief for inside corners the bit can't reach (so square tenons, tabs and finger joints fit).
public struct CornerReliefSettings: Hashable, Sendable {
    public var style: CornerReliefStyle
    public var tBoneSide: TBoneSide
    /// Corners up to this angle (degrees, measured across the cut-away area; a square corner is 90) are relieved.
    public var maxCornerAngle: Double
    /// Corners given their own relief on the canvas; nil = every corner follows the settings above.
    public var overrides: [CornerOverride]?
    /// Leave off a relief whose bit would cut into a part another toolpath cuts (through a thin wall between them, say),
    /// rather than gouging it. Off cuts it anyway. Either way the corner is flagged and Checks says so.
    ///
    /// Saved only when off. No new file format: a build that doesn't know the key cuts every relief, as off does.
    public var avoidsOtherParts: Bool

    public init(style: CornerReliefStyle = .dogbone, tBoneSide: TBoneSide = .longer, maxCornerAngle: Double = 120,
                overrides: [CornerOverride]? = nil, avoidsOtherParts: Bool = true) {
        self.style = style
        self.tBoneSide = tBoneSide
        self.maxCornerAngle = maxCornerAngle
        self.overrides = overrides
        self.avoidsOtherParts = avoidsOtherParts
    }
}

extension CornerReliefSettings: Codable {
    private enum CodingKeys: String, CodingKey { case style, tBoneSide, maxCornerAngle, overrides, avoidsOtherParts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(CornerReliefStyle.self, forKey: .style)
        tBoneSide = try c.decode(TBoneSide.self, forKey: .tBoneSide)
        maxCornerAngle = try c.decode(Double.self, forKey: .maxCornerAngle)
        overrides = try c.decodeIfPresent([CornerOverride].self, forKey: .overrides)
        avoidsOtherParts = try c.decodeIfPresent(Bool.self, forKey: .avoidsOtherParts) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(tBoneSide, forKey: .tBoneSide)
        try c.encode(maxCornerAngle, forKey: .maxCornerAngle)
        try c.encodeIfPresent(overrides, forKey: .overrides)
        if !avoidsOtherParts { try c.encode(false, forKey: .avoidsOtherParts) }
    }
}

/// One corner's own relief, in place of the toolpath's setting there. The corner is found by its shape and its place
/// in that shape's own coordinates (before the shape's position, rotation and scale), so moving, turning or scaling
/// the shape keeps the choice; changing the shape's geometry so the corner moves doesn't.
public struct CornerOverride: Hashable, Codable, Sendable {
    public enum Choice: Hashable, Codable, Sendable {
        /// Leave this corner as the bit cuts it.
        case asCut
        case dogbone
        /// A T-bone whose notch goes into the wall running at this angle (degrees in the shape's own coordinates,
        /// 0–180; the direction of travel doesn't matter).
        case tBone(wallAngle: Double)
    }

    public var shapeID: UUID
    /// The drawn corner in the shape's own coordinates, mm.
    public var point: Vec2
    public var choice: Choice

    public init(shapeID: UUID, point: Vec2, choice: Choice) {
        self.shapeID = shapeID
        self.point = point
        self.choice = choice
    }
}

public struct ProfileParams: Hashable, Codable, Sendable {
    public var side: CutSide
    public var direction: CutDirection
    public var depth: DepthSettings
    /// Material left on the wall for a later finishing pass, mm (positive = leave material).
    public var allowance: Double
    public var tabs: TabSettings
    public var entry: EntrySettings
    /// Lead-in and lead-out moves on closed loops; nil = none.
    public var leads: LeadSettings?
    /// Dogbone or T-bone relief in inside corners; nil = corners stay as the bit cuts them.
    public var cornerRelief: CornerReliefSettings?

    public init(side: CutSide = .outside, direction: CutDirection = .climb, depth: DepthSettings,
                allowance: Double = 0, tabs: TabSettings = TabSettings(), entry: EntrySettings = EntrySettings(),
                leads: LeadSettings? = nil, cornerRelief: CornerReliefSettings? = nil) {
        self.side = side
        self.direction = direction
        self.depth = depth
        self.allowance = allowance
        self.tabs = tabs
        self.entry = entry
        self.leads = leads
        self.cornerRelief = cornerRelief
    }
}

public enum PocketStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Contour-parallel offsets from the inside out.
    case offset
    /// Zig-zag raster lines, followed by a boundary clean-up pass.
    case raster
    /// Constant-engagement clearing (`AdaptiveClearing`): the bit cuts a steady sliver of its width at the full depth
    /// of its flutes, then a pass round the walls. Format 13.
    case adaptive
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Settings for adaptive pocket clearing (`PocketStrategy.adaptive`). Its pass depth is the pocket's Pass depth, which
/// for adaptive defaults to the bit's flute length (`PocketParams.passLevels`).
public struct AdaptiveSettings: Hashable, Codable, Sendable {
    /// Optimal load: the radial engagement the clearing holds, as a fraction of the bit's diameter (0.12 = 12%).
    public var optimalLoad: Double
    /// Smallest radius the clearing's loops and links turn on, mm; nil = automatic, from the machine's X/Y
    /// acceleration (`AdaptiveSettings.automaticLoopRadius`).
    public var minimumLoopRadius: Double?

    public init(optimalLoad: Double = AdaptiveSettings.defaultLoad, minimumLoopRadius: Double? = nil) {
        self.optimalLoad = optimalLoad
        self.minimumLoopRadius = minimumLoopRadius
    }

    public static let defaultLoad = 0.12
    /// The optimal load the clearing accepts, as a fraction of the diameter.
    public static let loadRange: ClosedRange<Double> = 0.03...0.5

    /// The load in use, kept inside `loadRange`.
    public var load: Double { min(max(optimalLoad, Self.loadRange.lowerBound), Self.loadRange.upperBound) }

    /// A loop of radius ρ caps the feed at √(a·ρ) (a = the machine's X/Y acceleration), so the automatic radius is the
    /// one that lets `feed` (mm/min) run at full speed, F²/a, kept between a quarter of the bit's diameter and twice it:
    /// tighter is too tight to cut round, wider leaves too much in corners.
    public static func automaticLoopRadius(tool: Tool, feed: Double, machine: MachineProfile) -> Double {
        let d = tool.diameter
        return min(max(fullSpeedRadius(feed: feed, machine: machine), 0.25 * d), 2 * d)
    }

    /// The loop radius at which the machine's X/Y acceleration first holds `feed` (mm/min) back: F²/a.
    public static func fullSpeedRadius(feed: Double, machine: MachineProfile) -> Double {
        let v = feed / 60, a = max(1, machine.axisAcceleration.x)
        return v * v / a
    }

    /// The fastest a loop of radius `radius` (mm) can be cut with the machine's X/Y acceleration, mm/min: √(a·ρ).
    public static func loopFeedCap(radius: Double, machine: MachineProfile) -> Double {
        (max(1, machine.axisAcceleration.x) * max(0, radius)).squareRoot() * 60
    }

    /// The minimum loop radius in use for `tool` cutting at `feed` (mm/min).
    public func loopRadius(tool: Tool, feed: Double, machine: MachineProfile) -> Double {
        if let r = minimumLoopRadius { return max(0.05, r) }
        return Self.automaticLoopRadius(tool: tool, feed: feed, machine: machine)
    }

    /// The fastest feed `tool`'s loops can hold with the machine's X/Y acceleration, mm/min: √(a·ρ) at the minimum loop
    /// radius, or, automatic, at the widest it goes (twice the bit's diameter). The chip-load recommendation keeps to it.
    public func loopFeedLimit(tool: Tool, machine: MachineProfile) -> Double {
        Self.loopFeedCap(radius: minimumLoopRadius.map { max(0.05, $0) } ?? 2 * tool.diameter, machine: machine)
    }
}

public struct PocketParams: Hashable, Codable, Sendable {
    public var strategy: PocketStrategy
    public var direction: CutDirection
    public var depth: DepthSettings
    public var allowance: Double
    /// Raster angle in degrees (raster strategy).
    public var rasterAngle: Double
    /// Stepover override as a fraction of tool diameter; nil uses the tool's stepover.
    public var stepoverFraction: Double?
    public var entry: EntrySettings
    /// Dogbone or T-bone relief in the wall's inside corners (islands included); nil = none.
    public var cornerRelief: CornerReliefSettings?
    /// Rest machining: a larger end mill that clears the pocket first, with its own stepover, pass depth and feeds,
    /// leaving the allowance plus `restMargin(for:)` on the walls. The operation's own tool then cuts only where the
    /// larger one couldn't reach (corners, narrow slots) and the final pass round the walls. nil = the operation's
    /// tool clears it all.
    ///
    /// No new file format: a build that doesn't know the key cuts the same pocket with the operation's tool alone,
    /// which is slower but not wrong.
    public var clearanceTool: Tool?
    /// Adaptive clearing's settings (`strategy == .adaptive`); nil = the defaults. Other strategies ignore it.
    public var adaptive: AdaptiveSettings?
    /// Rest from earlier toolpaths: the pocket toolpaths before this one in the run order that cut the same shapes as
    /// deep or deeper with a larger bit (`RestMachining.pocketReferences`) have already cleared what their bits reach,
    /// so this toolpath's tool cuts only what they left (corners, narrow parts) and the walls there. nil or false = it
    /// clears the whole pocket.
    ///
    /// Saved only when on. No new file format: a build that doesn't know the key clears the whole pocket with this
    /// toolpath's tool, which is slower but not wrong.
    public var restFromEarlier: Bool?

    public init(strategy: PocketStrategy = .offset, direction: CutDirection = .climb, depth: DepthSettings,
                allowance: Double = 0, rasterAngle: Double = 0, stepoverFraction: Double? = nil,
                entry: EntrySettings = EntrySettings(), cornerRelief: CornerReliefSettings? = nil, clearanceTool: Tool? = nil,
                adaptive: AdaptiveSettings? = nil, restFromEarlier: Bool? = nil) {
        self.strategy = strategy
        self.direction = direction
        self.depth = depth
        self.allowance = allowance
        self.rasterAngle = rasterAngle
        self.stepoverFraction = stepoverFraction
        self.entry = entry
        self.cornerRelief = cornerRelief
        self.clearanceTool = clearanceTool
        self.adaptive = adaptive
        self.restFromEarlier = restFromEarlier
    }

    /// Adaptive clearing's settings in use.
    public var adaptiveSettings: AdaptiveSettings { adaptive ?? AdaptiveSettings() }

    /// True when the pocket rests from the pocket toolpaths before it (`restFromEarlier`).
    public var restsFromEarlier: Bool { restFromEarlier == true }

    /// The pass depth `tool` cuts at when Pass depth isn't set: its stepdown, or for adaptive clearing the full length
    /// of its flutes, which is the point of it (a light cut the bit's whole height rather than a wide one at a time).
    public func defaultPassDepth(_ tool: Tool) -> Double {
        strategy == .adaptive ? max(tool.cutting.stepdown, tool.fluteLength) : tool.cutting.stepdown
    }

    /// The Z levels `tool` cuts this pocket at.
    public func passLevels(_ tool: Tool) -> [Double] {
        depth.passLevels(toolStepdown: defaultPassDepth(tool), firstPassMinimum: tool.firstPassMinimum)
    }

    /// Adaptive clearing is format 13: a format-12 build can't read the strategy.
    public var requiredFormatVersion: Int { strategy == .adaptive ? 13 : 1 }

    /// Material a clearance tool leaves on the walls beyond the allowance, so the operation's own tool (`small`) cuts
    /// the whole wall and the two bits leave no step where they meet: a tenth of its diameter, at most 0.25 mm
    /// (0.01 in).
    public static func restMargin(for small: Tool) -> Double { min(0.25, 0.1 * small.diameter) }
}

public struct DrillParams: Hashable, Codable, Sendable {
    /// Final hole depth below the material top, mm.
    public var depth: Double
    /// Peck increment, mm; 0 drills in one plunge.
    public var peckDepth: Double
    /// Retract fully above the material between pecks (true) or just back off for chip breaking (false).
    public var fullRetract: Bool
    /// Dwell at the bottom of the hole, seconds.
    public var dwell: Double
    /// A hole depth tied to the material thickness, as `DepthSettings.fromBottom`: the hole stops this far above the
    /// material's bottom (negative goes through it). nil = `depth` is a plain depth. No new file format.
    public var fromBottom: Double?

    public init(depth: Double, peckDepth: Double = 0, fullRetract: Bool = true, dwell: Double = 0, fromBottom: Double? = nil) {
        self.depth = depth
        self.peckDepth = peckDepth
        self.fullRetract = fullRetract
        self.dwell = dwell
        self.fromBottom = fromBottom
    }

}

public struct VCarveParams: Hashable, Sendable {
    /// Maximum carve depth (flat bottom) below the start depth, mm; nil carves to full V depth wherever the shape
    /// allows. Measured from the start depth, as Vectric VCarve's Flat Depth is, so the deepest cut is
    /// `startDepth + flatDepth` below the material top.
    public var flatDepth: Double?
    /// Max depth per pass, counted down from the start depth; nil carves in one pass.
    public var passDepth: Double?
    /// Spacing of samples along the outline, mm (smaller = smoother, more G-code).
    public var sampleSpacing: Double
    /// Optional flat end mill that clears the flat bottom (only used with `flatDepth`). Cut before the V-bit.
    /// Without one, the V-bit clears the flat bottom itself.
    public var clearanceTool: Tool?
    /// Depth the carve is calculated from, mm below the material top: the carve is cut as if the material top
    /// were this much lower (0 on the surface; an existing pocket's depth to carve inside it). The bit's tip runs at
    /// `startDepth + (r − tipRadius) / tan(halfAngle)` for a circle of radius r inscribed at that depth. A plug
    /// ignores it and uses its own (see `VCarveInlay`).
    public var startDepth: Double
    /// One side of a V-carve inlay; nil = an ordinary V-carve.
    public var inlay: VCarveInlay?
    /// How the V-bit clears a flat bottom itself, when there's no clearance tool: in raster lines with these settings,
    /// or in offset rings (nil). With a clearance tool, the corners it can't reach are always cleared in rings.
    ///
    /// No new file format: a build that doesn't know the key clears the same floor in rings, which is slower but not
    /// wrong.
    public var flatRaster: VCarveRaster?

    public init(flatDepth: Double? = nil, passDepth: Double? = nil, sampleSpacing: Double = 0.25, clearanceTool: Tool? = nil,
                startDepth: Double = 0, inlay: VCarveInlay? = nil, flatRaster: VCarveRaster? = nil) {
        self.flatDepth = flatDepth
        self.passDepth = passDepth
        self.sampleSpacing = sampleSpacing
        self.clearanceTool = clearanceTool
        self.startDepth = startDepth
        self.inlay = inlay
        self.flatRaster = flatRaster
    }

    public var isPlug: Bool { inlay?.role == .plug }

    /// The depth the carve is calculated from: a plug's P − G, otherwise `startDepth`.
    public var carveStartDepth: Double { inlay.flatMap { $0.role == .plug ? $0.plugStartDepth : nil } ?? max(0, startDepth) }

    /// How far below the start depth the carve may go (flat bottom): a plug's surface clearance, otherwise
    /// `flatDepth`.
    public var carveFlatDepth: Double? { inlay.flatMap { $0.role == .plug ? $0.surfaceClearance : nil } ?? flatDepth }

    /// Deepest point below the material top the carve is asked to reach (nil for an unlimited V).
    public var deepest: Double? { carveFlatDepth.map { carveStartDepth + $0 } }

    /// The project file format these settings need: a start depth or a plug is format 6, since an older build would
    /// ignore them and carve from the surface (a plug as an ordinary V-carve of the design). A whole-board plug is
    /// format 14: a format-13 build can't read the boundary.
    public var requiredFormatVersion: Int {
        if inlay?.boundary == .board { return 14 }
        return startDepth > 1e-9 || isPlug ? 6 : 1
    }

    /// Whether the V-bit clears flat areas itself: there's a flat bottom and no clearance tool takes it (with one, an
    /// inlay's V-bit still cleans up the corners the clearance tool can't reach).
    public var vBitClearsFlats: Bool { (carveFlatDepth ?? 0) > 0 && clearanceTool == nil }

    /// Tallest ridge the V-bit may leave between its passes where it clears a flat itself, mm. A plug's floor only has
    /// to stay clear of the pocket board, so its ridges may reach a third of the surface clearance; an inlay pocket's
    /// must stay under the plug (the glue gap). In the middle of a flat, past the last ring, a ridge can be up to twice
    /// this.
    public var vBitClearingRidge: Double {
        switch inlay?.role {
        case .plug: max(Self.flatClearingRidge, (carveFlatDepth ?? 0) / 3)
        case .pocket: Self.inlayPocketRidge
        case nil: Self.flatClearingRidge
        }
    }

    /// Spacing of the V-bit's rings that keeps the ridges between them within `vBitClearingRidge`, mm.
    public func vBitClearingSpacing(_ tool: Tool) -> Double {
        max(0.02, tool.tipDiameter + 2 * vBitClearingRidge * tool.halfAngleTangent)
    }

    /// Tallest ridge a V-bit's raster may leave between its lines with the automatic stepover, mm: the tallest the
    /// rings leave, in the middle of a flat past the last ring (twice `vBitClearingRidge`). The raster's ridges are all
    /// the same height, so the two leave the same floor.
    public var vBitRasterRidge: Double { 2 * vBitClearingRidge }

    /// The raster's automatic stepover, which keeps its ridges within `vBitRasterRidge`, mm: twice the ring spacing
    /// for a pointed bit.
    public func vBitRasterSpacing(_ tool: Tool) -> Double {
        max(0.02, tool.tipDiameter + 2 * vBitRasterRidge * tool.halfAngleTangent)
    }

    /// The stepover the V-bit's raster clears flats at, mm: its own, or the automatic one.
    public func vBitRasterStepover(_ tool: Tool) -> Double {
        flatRaster?.stepover.map { max(0.02, $0) } ?? vBitRasterSpacing(tool)
    }

    /// Height of the ridges a V-bit leaves between passes `spacing` apart at one depth, mm.
    public static func vBitRidge(_ tool: Tool, spacing: Double) -> Double {
        guard tool.shape.isTapered, tool.halfAngleTangent > 1e-9 else { return 0 }
        return max(0, spacing - tool.tipDiameter) / (2 * tool.halfAngleTangent)
    }

    /// Tallest ridge the V-bit may leave between its passes when it clears a flat bottom itself, mm.
    public static let flatClearingRidge = 0.1
    /// The same for an inlay pocket, whose floor has to stay below the plug's face (the glue gap).
    public static let inlayPocketRidge = 0.05
}

/// Raster flat clearing with a V-bit: straight lines a stepover apart, kept clear of the V walls as the rings are, then
/// a pass round each flat's edge.
public struct VCarveRaster: Hashable, Codable, Sendable {
    /// Distance between the lines, mm; nil = the spacing that keeps the ridges between them no taller than the tallest
    /// the rings leave (`VCarveParams.vBitRasterSpacing`).
    public var stepover: Double?
    /// Direction of the lines, degrees from X.
    public var angle: Double

    public init(stepover: Double? = nil, angle: Double = 0) {
        self.stepover = stepover
        self.angle = angle
    }
}

extension VCarveParams: Codable {
    private enum CodingKeys: String, CodingKey { case flatDepth, passDepth, sampleSpacing, clearanceTool, startDepth, inlay, flatRaster }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flatDepth = try c.decodeIfPresent(Double.self, forKey: .flatDepth)
        passDepth = try c.decodeIfPresent(Double.self, forKey: .passDepth)
        sampleSpacing = try c.decode(Double.self, forKey: .sampleSpacing)
        clearanceTool = try c.decodeIfPresent(Tool.self, forKey: .clearanceTool)
        startDepth = try c.decodeIfPresent(Double.self, forKey: .startDepth) ?? 0
        inlay = try c.decodeIfPresent(VCarveInlay.self, forKey: .inlay)
        flatRaster = try c.decodeIfPresent(VCarveRaster.self, forKey: .flatRaster)
    }

    /// A start depth of 0, no inlay and ring clearing are left out, so ordinary V-carves save exactly as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(flatDepth, forKey: .flatDepth)
        try c.encodeIfPresent(passDepth, forKey: .passDepth)
        try c.encode(sampleSpacing, forKey: .sampleSpacing)
        try c.encodeIfPresent(clearanceTool, forKey: .clearanceTool)
        if startDepth != 0 { try c.encode(startDepth, forKey: .startDepth) }
        try c.encodeIfPresent(inlay, forKey: .inlay)
        try c.encodeIfPresent(flatRaster, forKey: .flatRaster)
    }
}

/// One side of a V-carve inlay: a contrasting plug glued into a V-carved pocket, then planed flush. Both sides are
/// cut with the same V-bit. Settings follow Vectric's VCarve Inlay toolpath (V12), so its tutorials translate.
///
/// The **pocket** (female) is an ordinary V-carve of the design to its flat depth P: at depth d below its start
/// depth, its wall is inset d·tan(α) from the outline (α = the bit's half angle).
///
/// The **plug** (male) carves the area *around* the design, mirrored left to right about the centre of the design's
/// bounds, inside a boundary (a margin round the design, a selected vector or the whole board), so the design stands proud. It is carved as if the material top were S = P − G lower: at depth S the plug's walls lie
/// exactly on the (mirrored) outline, and above it they lean in at the bit's angle, d·tan(α) at height d above S.
/// Flipped into the pocket, the plug's walls therefore meet the pocket's along their whole height when the plug's
/// face (the plug board's original top) is S deep in the pocket, leaving
///
///     glue gap = P − S = G
///
/// between the plug's face and the pocket's flat bottom; where the pocket is too narrow to reach its flat depth,
/// the plug's ridges fill its grooves exactly. The plug is cut on down to S + C, so the plug board's carved floor
/// stands C (the surface clearance) above the pocket board's top when the walls meet: room for the wood to
/// compress as it's clamped, and the waste that's sawn or planed off afterwards.
public struct VCarveInlay: Hashable, Codable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The female side: an ordinary V-carve to the flat depth.
        case pocket
        /// The male side: the area around the mirrored design, so the design stands proud.
        case plug
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// Where a plug's carving stops.
    public enum Boundary: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The design's outline grown by the boundary margin.
        case margin
        /// The outermost selected vector: the one holding all the others (a rectangle the size of the plug board,
        /// say). A choice, not a guess: a design can have a shape round the rest of it too.
        case vector
        /// The whole plug board (`VCarveInlay.board(around:stock:)`), carved right out to its edges. Format 14.
        case board
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .margin: "Margin"
            case .vector: "Selected vector"
            case .board: "Whole board"
            }
        }
    }

    public var role: Role
    /// Plug: the flat depth of the pocket it goes into (P), mm.
    public var pocketDepth: Double
    /// Plug: the gap left between the plug's face and the pocket's flat bottom (G), mm.
    public var glueGap: Double
    /// Plug: how far the plug board's carved floor stands above the pocket board's surface when the walls meet (C), mm.
    public var surfaceClearance: Double
    /// Plug: where the carving stops.
    public var boundary: Boundary
    /// Plug: how far past the design's outline the plug is carved with a margin boundary, mm.
    public var boundaryMargin: Double
    /// Plug with a whole-board boundary: the plug board's width (x) and height (y), mm, centred on the design; nil = the
    /// material, where it is.
    public var boardSize: Vec2?

    public static let defaultPocketDepth = 0.2.inch
    public static let defaultGlueGap = 0.02.inch
    public static let defaultSurfaceClearance = 0.0625.inch
    public static let defaultBoundaryMargin = 0.25.inch

    public init(role: Role, pocketDepth: Double = VCarveInlay.defaultPocketDepth, glueGap: Double = VCarveInlay.defaultGlueGap,
                surfaceClearance: Double = VCarveInlay.defaultSurfaceClearance, boundary: Boundary = .margin,
                boundaryMargin: Double = VCarveInlay.defaultBoundaryMargin, boardSize: Vec2? = nil) {
        self.role = role
        self.pocketDepth = pocketDepth
        self.glueGap = glueGap
        self.surfaceClearance = surfaceClearance
        self.boundary = boundary
        self.boundaryMargin = boundaryMargin
        self.boardSize = boardSize
    }

    /// The plug board a whole-board plug carves: the material, or a board of `boardSize` centred on `center` (the
    /// middle of the design, which mirroring leaves where it is).
    public func board(around center: Vec2, stock: Stock) -> Rect2 {
        guard let size = boardSize, size.x > 0, size.y > 0 else { return stock.bounds }
        return Rect2(x: center.x - size.x / 2, y: center.y - size.y / 2, width: size.x, height: size.y)
    }

    /// The plug's start depth, S = P − G.
    public var plugStartDepth: Double { max(0, pocketDepth - glueGap) }
    /// The plug's deepest cut below its material top, S + C.
    public var plugCutDepth: Double { plugStartDepth + max(0, surfaceClearance) }
}

/// Where 3D toolpaths may go.
public enum ModelBoundary: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Only inside the model's outline; material around the model is left alone.
    case model
    /// Inside the closed vectors selected with the model (typically the cut-out outline) plus a margin;
    /// everything there outside the model is cut down to the model's base. Avoids machining scrap.
    case vectors
    /// The whole material; everything outside the model is cut down to the model's base.
    case material
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .model: "Model outline"
        case .vectors: "Selected vectors"
        case .material: "Whole material"
        }
    }
}

/// How 3D roughing clears each layer.
public enum Rough3DClearing: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Offset rings inward from the layer's walls (the original roughing).
    case offset
    /// Zig-zag raster lines at the raster angle, then a pass round the layer's walls.
    case raster
    /// Constant-engagement clearing (`AdaptiveClearing`) at each layer, then a pass round its walls. Format 26.
    case adaptive
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public struct Rough3DParams: Hashable, Codable, Sendable {
    /// Material left on the model surface for the finishing pass, mm.
    public var allowance: Double
    /// Max depth per layer; nil uses the tool's stepdown.
    public var passDepth: Double?
    /// Stepover as a fraction of the tool diameter; nil uses the tool's.
    public var stepoverFraction: Double?
    public var boundary: ModelBoundary
    /// How far beyond the selected vectors roughing may clear, mm; nil = tool diameter + 1 mm, enough for a
    /// finishing ball of the same size to reach right up to the vector.
    public var boundaryMargin: Double?
    /// How each layer is cleared; nil = offset rings. Saved only when set.
    ///
    /// Raster needs no new file format: a build that doesn't know the key clears the same layers in rings, which
    /// leaves the same part. Adaptive is format 26 (`requiredFormatVersion`): its layers are cut at the full
    /// layer depth with the adaptive load's feeds, which an older build would push through offset rings.
    public var clearing: Rough3DClearing?
    /// Raster direction in degrees (raster clearing; nil = 0, along X).
    public var rasterAngle: Double?
    /// Adaptive clearing's settings (`clearing == .adaptive`); nil = the defaults.
    public var adaptive: AdaptiveSettings?
    /// Adaptive clearing: how deep each clearing pass goes, mm, in whole layers (`passDepth` stays the height of the
    /// steps left on the model: the layers between are stepped up, clearing only the terraces). nil = automatic,
    /// `automaticClearingDepth`.
    public var clearingDepth: Double?

    public init(allowance: Double = 0.02.inch, passDepth: Double? = nil, stepoverFraction: Double? = nil, boundary: ModelBoundary = .model,
                boundaryMargin: Double? = nil, clearing: Rough3DClearing? = nil, rasterAngle: Double? = nil,
                adaptive: AdaptiveSettings? = nil, clearingDepth: Double? = nil) {
        self.allowance = allowance
        self.passDepth = passDepth
        self.stepoverFraction = stepoverFraction
        self.boundary = boundary
        self.boundaryMargin = boundaryMargin
        self.clearing = clearing
        self.rasterAngle = rasterAngle
        self.adaptive = adaptive
        self.clearingDepth = clearingDepth
    }

    public static func autoMargin(tool: Tool) -> Double { tool.diameter + 1 }

    /// The layer depth `tool` cuts at, mm.
    public func layerDepth(_ tool: Tool) -> Double { max(0.05, passDepth ?? tool.cutting.stepdown) }

    /// Adaptive clearing's automatic clearing depth: twice the bit's diameter, within its flute length. Deeper, the
    /// chip-load chart's depth derate takes more off the feed than the light cut gains.
    public static func automaticClearingDepth(tool: Tool) -> Double { min(2 * tool.diameter, tool.fluteLength) }

    /// The clearing depth in use (adaptive clearing), mm: never less than a layer.
    public func clearingDepthInUse(_ tool: Tool) -> Double {
        max(layerDepth(tool), clearingDepth ?? Self.automaticClearingDepth(tool: tool))
    }

    /// The deepest single pass, mm, for the chip-load chart's depth derate: the layer depth, or with adaptive clearing
    /// the clearing depth (its passes take as many whole layers as fit in it, so they're never deeper).
    public func deepestPass(_ tool: Tool) -> Double {
        clearingInUse == .adaptive ? clearingDepthInUse(tool) : layerDepth(tool)
    }

    /// The clearing in use.
    public var clearingInUse: Rough3DClearing { clearing ?? .offset }

    /// Adaptive clearing's settings in use.
    public var adaptiveSettings: AdaptiveSettings { adaptive ?? AdaptiveSettings() }

    /// Adaptive 3D roughing is format 26: a format-25 build can't read the clearing.
    public static let adaptiveFormatVersion = 26

    /// The project file format these settings need.
    public var requiredFormatVersion: Int { clearingInUse == .adaptive ? Self.adaptiveFormatVersion : 1 }
}

/// How 3D finishing covers the surface.
public enum Finish3DStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Parallel rows following the surface (lace cut).
    case raster
    /// Constant-Z loops round the model, a level at a time from the top down.
    case waterline
    /// Waterline loops where the surface is steeper than the steep angle, raster rows on the rest, overlapping a little.
    case steepShallow
    /// Single passes along concave creases, where the bit touches two faces at once (usually a smaller ball after the
    /// main finish).
    case pencil
    /// Rest finishing: a smaller ball or tapered ball nose finishes only where earlier 3D finishing toolpaths' larger
    /// bits couldn't reach (`RestSettings`), in raster rows clipped to those areas. Format 17.
    case rest
    /// Constant scallop (3D offset): passes that are iso-lines of geodesic distance on the cutter-location surface from
    /// the boundary inward, so neighbouring passes are the same distance apart along the surface and the scallop
    /// between them stays even however the slope changes. Format 21.
    case constantScallop
    /// An Archimedean spiral from a centre out to the boundary, dropped onto the model: one continuous cut out to where it
    /// first meets the boundary, then the arcs left inside it, each from its nearer end. Format 21.
    case spiral
    /// Spokes from a centre at an angular step, thinned near the centre to a minimum spacing. Format 21.
    case radial

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .raster: "Raster"
        case .waterline: "Waterline"
        case .steepShallow: "Steep and shallow"
        case .pencil: "Pencil"
        case .rest: "Rest"
        case .constantScallop: "Constant scallop"
        case .spiral: "Spiral"
        case .radial: "Radial"
        }
    }
    /// Whether it lays raster rows (and so can cross-hatch).
    public var usesRaster: Bool { self == .raster || self == .steepShallow || self == .rest }
    /// Whether it lays waterline loops (and so has a Z step from the steep angle).
    public var usesWaterline: Bool { self == .waterline || self == .steepShallow }
    /// Whether it can space its passes by a scallop-height target (`Finish3DParams.scallopHeight`).
    public var usesScallopTarget: Bool { self == .constantScallop || self == .spiral }
    /// Whether it works out from a centre (`Finish3DParams.centre`).
    public var usesCentre: Bool { self == .spiral || self == .radial }
    /// The strategies format 21 adds.
    public var isFormat21: Bool { self == .constantScallop || self == .spiral || self == .radial }
}

public struct Finish3DParams: Hashable, Sendable {
    /// Distance between raster passes as a fraction of the tool diameter.
    public var stepoverFraction: Double
    /// Raster direction in degrees (0 = along X).
    public var rasterAngle: Double
    /// Material left on the surface, mm (normally 0).
    public var allowance: Double
    public var boundary: ModelBoundary
    /// How far beyond the selected vectors the tool centre may go, mm; nil = tool radius + 0.5 mm (the ball can
    /// finish right up to the vector without reaching past what roughing cleared).
    public var boundaryMargin: Double?
    public var strategy: Finish3DStrategy
    /// A second raster at the raster angle + 90° in the same toolpath (raster rows only).
    public var crossHatch: Bool
    /// Steep and shallow: slope (degrees from horizontal) above which waterline takes over from the raster; nil = 40°.
    /// It also sets the waterline Z step, stepover × tan(angle), so loops on that slope are as far apart as raster rows
    /// running along it, and the scallop matches across the seam.
    public var steepAngle: Double?
    /// Steep and shallow: how far each strategy runs past the seam into the other's area, mm; nil = a quarter of the
    /// tool diameter.
    public var overlap: Double?
    /// Turns between raster rows on an arc and starts passes off the model (a ramp along the row, or a waterline loop
    /// from the free side) instead of plunging onto it. Off (as projects saved before it existed read) keeps the row
    /// links the raster always had.
    public var smoothLinks: Bool
    /// Rest finishing's settings (`strategy == .rest`); nil = the defaults in millimetres. Other strategies ignore it.
    public var rest: RestSettings?
    /// Constant scallop and spiral: the scallop height to hold between passes, mm, which sets the stepover from the
    /// bit's effective radius (`Tool.stepover(forScallop:)`); nil = the stepover fraction sets the spacing. Other
    /// strategies ignore it.
    public var scallopHeight: Double?
    /// Spiral and radial: the centre they work out from, in design coordinates (mm from the material's lower-left
    /// corner); nil = the boundary's centroid. Other strategies ignore it.
    public var centre: Vec2?
    /// Spiral: hold the scallop on slopes by closing the turns up where the surface tilts across them (the stepover
    /// measured along the surface); off = a constant stepover in plan.
    public var spiralHoldsScallop: Bool
    /// Radial: the angle between spokes, degrees; nil = automatic, a stepover apart where each spoke meets the boundary.
    public var radialStep: Double?
    /// Radial: how close spokes may come near the centre before every other one stops short, mm; nil = half the stepover
    /// (so between the centre and the boundary neighbouring spokes are between half a stepover and a stepover apart).
    public var radialMinSpacing: Double?

    public init(stepoverFraction: Double = 0.1, rasterAngle: Double = 0, allowance: Double = 0, boundary: ModelBoundary = .model,
                boundaryMargin: Double? = nil, strategy: Finish3DStrategy = .raster, crossHatch: Bool = false,
                steepAngle: Double? = nil, overlap: Double? = nil, smoothLinks: Bool = true, rest: RestSettings? = nil,
                scallopHeight: Double? = nil, centre: Vec2? = nil, spiralHoldsScallop: Bool = false, radialStep: Double? = nil,
                radialMinSpacing: Double? = nil) {
        self.stepoverFraction = stepoverFraction
        self.rasterAngle = rasterAngle
        self.allowance = allowance
        self.boundary = boundary
        self.boundaryMargin = boundaryMargin
        self.strategy = strategy
        self.crossHatch = crossHatch
        self.steepAngle = steepAngle
        self.overlap = overlap
        self.smoothLinks = smoothLinks
        self.rest = rest
        self.scallopHeight = scallopHeight
        self.centre = centre
        self.spiralHoldsScallop = spiralHoldsScallop
        self.radialStep = radialStep
        self.radialMinSpacing = radialMinSpacing
    }

    /// Rest finishing's settings in use.
    public var restSettings: RestSettings { rest ?? RestSettings() }

    public static func autoMargin(tool: Tool) -> Double { tool.radius + 0.5 }
    public static let defaultSteepAngle = 40.0
    public static func autoOverlap(tool: Tool) -> Double { tool.diameter / 4 }

    /// The steep angle in use, degrees (kept between 5° and 85°).
    public var steepAngleInUse: Double { min(85, max(5, steepAngle ?? Self.defaultSteepAngle)) }
    public func overlapInUse(tool: Tool) -> Double { max(0, overlap ?? Self.autoOverlap(tool: tool)) }
    /// Waterline Z step for `tool`: stepover × tan(steep angle).
    public func waterlineStep(tool: Tool) -> Double {
        max(0.01, tool.stepoverBasis * stepoverFraction) * tan(steepAngleInUse.radians)
    }

    /// The stepover in use for `tool`, mm: from the scallop-height target where the strategy holds one and it's set
    /// (and the bit has a rounded tip to hold it with), otherwise the stepover fraction of the bit's stepover basis.
    public func stepoverInUse(tool: Tool) -> Double {
        if strategy.usesScallopTarget, let h = scallopHeight, h > 0, let s = tool.stepover(forScallop: h) { return max(0.02, s) }
        return max(0.02, tool.stepoverBasis * stepoverFraction)
    }

    /// Format 10 adds the waterline, steep-and-shallow and pencil strategies and cross-hatching: a format-9 build would
    /// ignore them and cut one raster. Smooth links don't raise it (an older build links rows its own way, cutting the
    /// same surface), nor do a steep angle or overlap a raster doesn't use. Rest finishing is format 17: a format-16
    /// build can't read it (and would otherwise finish the whole model with the small bit). Constant scallop, spiral and
    /// radial finishing are format 21, which an older build can't read; their settings mean nothing to the others, so
    /// they don't raise it on their own.
    public var requiredFormatVersion: Int {
        if strategy.isFormat21 { return 21 }
        if strategy == .rest { return 17 }
        return strategy != .raster || (crossHatch && strategy.usesRaster) ? 10 : 1
    }
}

/// 3D rest finishing (`Finish3DStrategy.rest`): what a smaller ball or tapered ball nose follows. The places the
/// references' bits couldn't reach (where they left more than the tolerance) are worked out exactly with the
/// drop-cutter, from where each bit could have touched the model, not from the passes it made: the scallops between a
/// reference's passes don't count.
public struct RestSettings: Hashable, Codable, Sendable {
    /// The earlier 3D finishing toolpaths whose cuts this one follows, by ID; nil = automatic: every enabled 3D
    /// finishing toolpath before this one in the run order, on the same model, with a larger bit
    /// (`RestMachining.references`).
    public var references: [UUID]?
    /// Material thicker than this, square to the surface, counts as left over, mm.
    public var tolerance: Double
    /// How far each rest area is grown, so the passes run a little onto the finished surface round it, mm.
    public var margin: Double
    /// Also run the pencil pass along the concave creases inside the rest areas.
    public var pencil: Bool

    /// 0.05 mm (0.002 in on an inch job, `defaults(for:)`).
    public static let defaultTolerance = 0.05
    /// 0.5 mm (0.02 in on an inch job).
    public static let defaultMargin = 0.5

    public init(references: [UUID]? = nil, tolerance: Double = RestSettings.defaultTolerance,
                margin: Double = RestSettings.defaultMargin, pencil: Bool = false) {
        self.references = references
        self.tolerance = tolerance
        self.margin = margin
        self.pencil = pencil
    }

    /// The defaults for a job in `units`: 0.05 mm and 0.5 mm, or 0.002" and 0.02".
    public static func defaults(for units: LengthUnit) -> RestSettings {
        units == .inch ? RestSettings(tolerance: 0.002.inch, margin: 0.02.inch) : RestSettings()
    }

    /// The tolerance in use, mm (at least a micron).
    public var toleranceInUse: Double { max(0.001, tolerance) }
    /// The margin in use, mm.
    public var marginInUse: Double { max(0, margin) }
}

extension Finish3DParams: Codable {
    private enum CodingKeys: String, CodingKey {
        case stepoverFraction, rasterAngle, allowance, boundary, boundaryMargin, strategy, crossHatch, steepAngle, overlap, smoothLinks, rest
        case scallopHeight, centre, spiralHoldsScallop, radialStep, radialMinSpacing
    }

    /// Keys missing from older files read as the raster without cross-hatching or smooth links they meant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepoverFraction = try c.decode(Double.self, forKey: .stepoverFraction)
        rasterAngle = try c.decode(Double.self, forKey: .rasterAngle)
        allowance = try c.decode(Double.self, forKey: .allowance)
        boundary = try c.decode(ModelBoundary.self, forKey: .boundary)
        boundaryMargin = try c.decodeIfPresent(Double.self, forKey: .boundaryMargin)
        strategy = try c.decodeIfPresent(Finish3DStrategy.self, forKey: .strategy) ?? .raster
        crossHatch = try c.decodeIfPresent(Bool.self, forKey: .crossHatch) ?? false
        steepAngle = try c.decodeIfPresent(Double.self, forKey: .steepAngle)
        overlap = try c.decodeIfPresent(Double.self, forKey: .overlap)
        smoothLinks = try c.decodeIfPresent(Bool.self, forKey: .smoothLinks) ?? false
        rest = try c.decodeIfPresent(RestSettings.self, forKey: .rest)
        scallopHeight = try c.decodeIfPresent(Double.self, forKey: .scallopHeight)
        centre = try c.decodeIfPresent(Vec2.self, forKey: .centre)
        spiralHoldsScallop = try c.decodeIfPresent(Bool.self, forKey: .spiralHoldsScallop) ?? false
        radialStep = try c.decodeIfPresent(Double.self, forKey: .radialStep)
        radialMinSpacing = try c.decodeIfPresent(Double.self, forKey: .radialMinSpacing)
    }

    /// Defaults are left out, so a plain raster saves exactly as before (apart from smooth links, which are on).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stepoverFraction, forKey: .stepoverFraction)
        try c.encode(rasterAngle, forKey: .rasterAngle)
        try c.encode(allowance, forKey: .allowance)
        try c.encode(boundary, forKey: .boundary)
        try c.encodeIfPresent(boundaryMargin, forKey: .boundaryMargin)
        if strategy != .raster { try c.encode(strategy, forKey: .strategy) }
        if crossHatch { try c.encode(crossHatch, forKey: .crossHatch) }
        try c.encodeIfPresent(steepAngle, forKey: .steepAngle)
        try c.encodeIfPresent(overlap, forKey: .overlap)
        if smoothLinks { try c.encode(smoothLinks, forKey: .smoothLinks) }
        try c.encodeIfPresent(rest, forKey: .rest)
        try c.encodeIfPresent(scallopHeight, forKey: .scallopHeight)
        try c.encodeIfPresent(centre, forKey: .centre)
        if spiralHoldsScallop { try c.encode(spiralHoldsScallop, forKey: .spiralHoldsScallop) }
        try c.encodeIfPresent(radialStep, forKey: .radialStep)
        try c.encodeIfPresent(radialMinSpacing, forKey: .radialMinSpacing)
    }
}

/// Turning a rotary blank down to a round of a given diameter: a square bar to round, or a round blank smaller (see
/// `RoundingGenerator`). Needs no shapes.
public struct RoundingParams: Hashable, Codable, Sendable {
    public enum Method: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Round the blank: one spiral per layer, stepping along it as it turns (Vectric's "Radial").
        case radial
        /// Along the blank: passes parallel to the axis, turning a step between them (Vectric's "Raster"). Often
        /// quicker where the rotary is slower than X, and it skips the corners of a square bar it has already cut.
        case raster
        public var id: String { rawValue }
        public var label: String { self == .radial ? "Around" : "Along" }
    }

    /// Diameter to turn down to, mm; nil = the job's wrap diameter on a wrapped job, the blank's own on a faces job
    /// (a square bar's size across the faces).
    public var finishedDiameter: Double?
    public var method: Method
    /// Depth per layer, measured in from the surface, mm; nil uses the tool's stepdown.
    public var passDepth: Double?
    /// Stepover as a fraction of the tool diameter (along the blank for Around, round it at the largest radius for
    /// Along); nil uses the tool's.
    public var stepoverFraction: Double?
    /// Where along the blank (X) the rounding starts and ends, mm; nil keeps the cutter just inside each end.
    public var startX: Double?
    public var endX: Double?

    /// The diameter this turns `blank` down to.
    public func finishedDiameter(on blank: RotaryStock) -> Double {
        finishedDiameter ?? (blank.isWrapped ? blank.wrapDiameterOrBlank : blank.diameter)
    }

    public init(finishedDiameter: Double? = nil, method: Method = .radial, passDepth: Double? = nil, stepoverFraction: Double? = nil,
                startX: Double? = nil, endX: Double? = nil) {
        self.finishedDiameter = finishedDiameter
        self.method = method
        self.passDepth = passDepth
        self.stepoverFraction = stepoverFraction
        self.startX = startX
        self.endX = endX
    }
}

/// 3D rotary finishing (see `Rotary3DGenerator`): a ball nose follows a 3D model laid along the rotation axis, all
/// the way round it, with the blank turning as it cuts. Deeper than the pass depth below the stock, it cuts down in
/// layers first, each following the model no closer to the axis than its layer.
public struct RotaryFinishParams: Hashable, Codable, Sendable {
    public enum Pattern: String, Codable, Sendable, CaseIterable, Identifiable {
        /// One continuous helix along the blank, a stepover per turn, with a full turn at each end.
        case spiral
        /// A full turn at one station, then a stepover along the blank, and again.
        case rings
        /// Passes along the blank at one angle, zig-zag, turning a stepover (at the model's largest radius) between
        /// them. Often quicker when the rotary is slow.
        case lines
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .spiral: "Spiral"
            case .rings: "Rings"
            case .lines: "Along X"
            }
        }
    }

    public var pattern: Pattern
    /// Stepover as a fraction of the tool diameter: along the blank per turn (spiral, rings), or round it at the
    /// model's largest radius (along X).
    public var stepoverFraction: Double
    /// Material left on the model's surface, mm.
    public var allowance: Double
    /// Where along the blank (X) the finish starts and ends, mm; nil = the model's ends, kept the cutter's radius
    /// inside the blank's ends (clear of the chuck and tailstock).
    public var startX: Double?
    public var endX: Double?
    /// Distance between the points the tool is dropped at along the blank, mm.
    public var sampleSpacing: Double
    /// Angle between the points round the blank, degrees; nil = the sample spacing at the model's largest radius.
    public var angleStep: Double?
    /// Deepest cut per pass, mm: where the model is deeper than this below the stock, layers cut down to it first,
    /// each at most this much deeper than the last. nil = the tool's stepdown.
    public var passDepth: Double?
    /// The layers' stepover as a fraction of the tool diameter; nil = 40%, or the finish's if that's more.
    public var layerStepoverFraction: Double?

    public static let defaultLayerStepover = 0.4

    public init(pattern: Pattern = .spiral, stepoverFraction: Double = 0.1, allowance: Double = 0, startX: Double? = nil,
                endX: Double? = nil, sampleSpacing: Double = 0.25, angleStep: Double? = nil, passDepth: Double? = nil,
                layerStepoverFraction: Double? = nil) {
        self.pattern = pattern
        self.stepoverFraction = stepoverFraction
        self.allowance = allowance
        self.startX = startX
        self.endX = endX
        self.sampleSpacing = sampleSpacing
        self.angleStep = angleStep
        self.passDepth = passDepth
        self.layerStepoverFraction = layerStepoverFraction
    }

    /// The finish's stepover with `tool`, mm.
    public func stepover(_ tool: Tool) -> Double { max(0.01, stepoverFraction * tool.stepoverBasis) }

    /// The layers' stepover with `tool`, mm: never finer than the finish's.
    public func layerStepover(_ tool: Tool) -> Double {
        max(stepover(tool), (layerStepoverFraction ?? Self.defaultLayerStepover) * tool.stepoverBasis)
    }

    /// The deepest cut per pass with `tool`, mm.
    public func passDepth(_ tool: Tool) -> Double { max(0.05, passDepth ?? tool.cutting.stepdown) }
}

// MARK: 3D rotary roughing

/// 3D rotary roughing (see `Rotary3DRoughing`): a flat or bull-nose end mill clears the stock round a 3D model on a
/// rotary blank, from a square bar or a round blank, in layers a radial stepdown apart, leaving an allowance on the model
/// for 3D rotary finishing. Each layer clears the area of the blank unrolled at its radius where there's material left
/// and the tool is clear of the model; it skips the air over a square bar's faces, and starts from what a Rounding
/// before it leaves.
public struct RotaryRoughParams: Hashable, Codable, Sendable {
    public enum Pattern: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Each area as lines its longer way: along the blank on the strips at a square bar's corners, round it on a
        /// short band that goes all the way round.
        case auto
        /// Lines round the blank (whole or part rings), stepping along it.
        case around
        /// Lines along the blank, stepping round it.
        case along
        /// Rings offset in from each area's edge, inside out.
        case offset
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .auto: "Auto"
            case .around: "Around"
            case .along: "Along X"
            case .offset: "Offset"
            }
        }
    }

    public var pattern: Pattern
    /// Radial depth from one layer to the next, mm; nil = the tool's stepdown.
    public var stepdown: Double?
    /// Stepover as a fraction of the tool diameter, measured on each layer's surface; nil = the tool's.
    public var stepoverFraction: Double?
    /// Material left on the model for the finish, mm, square to its surface.
    public var allowance: Double
    /// Where along the blank (X) the roughing starts and ends, mm; nil = the model's ends, kept the cutter's radius
    /// inside the blank's ends (clear of the chuck and tailstock).
    public var startX: Double?
    public var endX: Double?
    /// How far apart the tool is dropped onto the model to find each layer's area, along the blank and round it at the
    /// stock's surface, mm.
    public var sampleSpacing: Double

    public static let defaultAllowance = 0.02.inch

    public init(pattern: Pattern = .auto, stepdown: Double? = nil, stepoverFraction: Double? = nil,
                allowance: Double = RotaryRoughParams.defaultAllowance, startX: Double? = nil, endX: Double? = nil,
                sampleSpacing: Double = 0.5) {
        self.pattern = pattern
        self.stepdown = stepdown
        self.stepoverFraction = stepoverFraction
        self.allowance = allowance
        self.startX = startX
        self.endX = endX
        self.sampleSpacing = sampleSpacing
    }

    /// Radial depth between layers with `tool`, mm.
    public func stepdown(_ tool: Tool) -> Double { max(0.05, stepdown ?? tool.cutting.stepdown) }

    /// Stepover with `tool`, mm.
    public func stepover(_ tool: Tool) -> Double { max(0.05, (stepoverFraction ?? tool.cutting.stepoverFraction) * tool.stepoverBasis) }

    /// The most a flat bottom (and a bull nose's corners) leaves standing on a round surface `radius` from the axis,
    /// mm: across its width the bottom is a plane tangent to the round, which falls away under it to √(ρ² + y²) − ρ
    /// at y off its axis, about R²/2ρ at the edge of a flat end mill (research §2.4). Between passes and beside the
    /// model the finish meets ridges up to this high on top of the allowance.
    public static func cusp(_ tool: Tool, radius rho: Double) -> Double {
        let r = max(rho, 1e-6)
        var most = 0.0
        for i in 0...64 {
            let y = tool.radius * Double(i) / 64
            let rise = (tool.profileHeight(atRadius: y) ?? 0)
            most = max(most, (r * r + y * y).squareRoot() - r - rise)
        }
        return most
    }
}

/// A chamfer: a V-bit or engraving bit bevels the edges of closed vectors at its own angle (see `ChamferGenerator`).
/// The settings follow Vectric's Chamfer toolpath, so its tutorials translate: the bevel lies outside or inside the
/// vector (or both), and the vector is its top edge (Vectric's "Down") or its bottom edge ("Up").
public struct ChamferParams: Hashable, Codable, Sendable {
    /// Which side of the selected shapes the bevel lies on. Shapes inside shapes count as holes, as a profile's do.
    public enum Side: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Outside the shapes: round a part's edge, and into its holes.
        case outside
        /// Inside the shapes: into a hole or pocket, and round its islands.
        case inside
        /// Both sides of the vector.
        case both
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// Which edge of the bevel the vector marks.
    public enum Edge: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The vector is the bevel's top edge: it slopes down away from the vector (Vectric's "Down").
        case top
        /// The vector is the bevel's bottom edge, where a profile cut on the same vector leaves its wall: the bevel
        /// rises away from the vector to the surface (Vectric's "Up").
        case bottom
        public var id: String { rawValue }
        public var label: String { self == .top ? "Top edge" : "Bottom edge" }
    }

    public var side: Side
    public var edge: Edge
    /// The bevel's width across the top, mm. Its depth follows from the bit's angle (`depth(with:)`), so changing
    /// the bit keeps the width.
    public var width: Double
    /// Depth the bevel starts at, mm below the material top: 0 on the surface, or the floor of a pocket or step.
    public var startDepth: Double
    /// Max depth per pass; nil uses the tool's stepdown.
    public var passDepth: Double?
    /// Keep corners crisp: where two faces of the bevel meet in a corner the bit can't reach at depth, it rises along
    /// the corner's bisector (as a V-carve does), and round the outside of a corner it runs to a mitre rather than
    /// round an arc. Off, the bit stays at depth and the corners come out rounded.
    public var sharpCorners: Bool
    public var direction: CutDirection
    /// V-bits: how far past the bevel's foot the tip also runs, mm, in further laps at the bevel's depth (Vectric's
    /// Overcut). The bevel keeps its width and angle; the tip is kept off its foot, which is left as a flat this wide
    /// (plus the tip's own width) rather than the bottom of a V-groove. nil or 0 = none. Format 19 when set.
    public var overcut: Double?

    public static let defaultWidth = 0.125.inch

    public init(side: Side = .outside, edge: Edge = .top, width: Double = ChamferParams.defaultWidth, startDepth: Double = 0,
                passDepth: Double? = nil, sharpCorners: Bool = true, direction: CutDirection = .climb, overcut: Double? = nil) {
        self.side = side
        self.edge = edge
        self.width = width
        self.startDepth = startDepth
        self.passDepth = passDepth
        self.sharpCorners = sharpCorners
        self.direction = direction
        self.overcut = overcut
    }

    /// The overcut that applies with `tool`, mm: a V-bit or engraving bit's, 0 otherwise (and on a bottom-edge bevel on
    /// both sides, whose foot is the vector between two bevels).
    public func overcut(with tool: Tool) -> Double {
        guard tool.shape.isTapered, !(edge == .bottom && side == .both) else { return 0 }
        return max(0, overcut ?? 0)
    }

    /// The flat a V-bit leaves along the bevel's foot, mm: the overcut plus the tip's own width (0 for a pointed bit with
    /// no overcut).
    public func flatWidth(with tool: Tool) -> Double {
        guard tool.shape.isTapered else { return 0 }
        return overcut(with: tool) + max(0, tool.tipDiameter)
    }

    /// The bevel's depth (its height) with `tool`, mm: the width over tan(half the bit's angle) for a V-bit, or how deep
    /// a form bit's tip runs for its profile to meet the surface at the width (`EdgeProfileParams.formDepth`). 0 for
    /// other bits, and for a width beyond a form bit's profile.
    public func depth(with tool: Tool) -> Double {
        if tool.shape == .form { return EdgeProfileParams.formDepth(reaching: width, tool: tool) ?? 0 }
        return Self.depth(width: width, tool: tool)
    }

    /// Whether the chamfer needs format 19: an overcut, or a form bit (a round-nose chamfer), which older builds refuse
    /// or would cut without.
    public func needsFormat19(with tool: Tool) -> Bool { (overcut ?? 0) > 1e-9 || tool.shape == .form }

    /// Depth ↔ width through the bit's angle: a bevel `width` wide is width / tan(half angle) deep.
    public static func depth(width: Double, tool: Tool) -> Double {
        guard tool.shape.isTapered, tool.halfAngleTangent > 1e-9 else { return 0 }
        return max(0, width) / tool.halfAngleTangent
    }

    /// The width a bevel `depth` deep has with `tool`, mm.
    public static func width(depth: Double, tool: Tool) -> Double {
        guard tool.shape.isTapered else { return 0 }
        return max(0, depth) * tool.halfAngleTangent
    }
}

/// Fluting: a ball nose, core box or V-bit cuts along vectors with its depth ramping in and out at the ends (see
/// `FlutingGenerator`), as Vectric's Fluting toolpath does. A flute ramped at one end starts at its vector's start point.
public struct FlutingParams: Hashable, Codable, Sendable {
    /// Which ends of a flute ramp.
    public enum Ramp: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Down at the start and back up at the end.
        case both
        /// Down at the start only; the flute ends at full depth.
        case start
        /// Up at the end only; the flute starts at full depth.
        case end
        /// Full depth all along.
        case none
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .both: "Both ends"
            case .start: "Start"
            case .end: "End"
            case .none: "None"
            }
        }
    }

    public enum RampShape: String, Codable, Sendable, CaseIterable, Identifiable {
        /// A straight slope from the start depth to the flute depth.
        case linear
        /// A curve that eases into the flute depth (a quarter sine), for a rounder end.
        case smooth
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// Depth the flute is measured from, mm below the material top (0 on the surface, or a pocket's floor).
    public var startDepth: Double
    /// Depth of the flute below the start depth, mm.
    public var depth: Double
    public var ramp: Ramp
    /// Length of each ramp, mm, unless `rampPercent` is set.
    public var rampLength: Double
    /// Length of each ramp as a fraction of the longest it can be (the flute's length for one ramp, half of it for
    /// both), as Vectric's Ramp %; nil uses `rampLength`.
    public var rampPercent: Double?
    public var rampShape: RampShape
    /// Max depth per pass; nil uses the tool's stepdown. Each pass follows the whole flute, its ramps scaled to its
    /// depth, so the last pass cuts the full length.
    public var passDepth: Double?
    /// The 3D model (its shape's ID) whose surface the flutes follow: each flute's depth is then measured down from
    /// where the bit touches the model (the exact drop-cutter), on a flat job or wrapped round a rotary blank, and the
    /// start depth isn't used. nil measures them from the start depth, as in every file before format 25.
    public var surfaceModelID: UUID?

    public init(startDepth: Double = 0, depth: Double = 0.125.inch, ramp: Ramp = .both, rampLength: Double = 1.inch,
                rampPercent: Double? = nil, rampShape: RampShape = .linear, passDepth: Double? = nil, surfaceModelID: UUID? = nil) {
        self.startDepth = startDepth
        self.depth = depth
        self.ramp = ramp
        self.rampLength = rampLength
        self.rampPercent = rampPercent
        self.rampShape = rampShape
        self.passDepth = passDepth
        self.surfaceModelID = surfaceModelID
    }

    /// Flutes that follow a 3D model are format 25: an older build would drop the model and cut them from the start
    /// depth, in the air above a finished model or into it.
    public static let followsModelFormat = 25

    /// What the flutes' depth is measured from.
    public enum Follow: String, CaseIterable, Identifiable, Sendable {
        case materialTop, startDepth, model
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .materialTop: "Material top"
            case .startDepth: "Start depth"
            case .model: "3D model"
            }
        }
    }

    /// What the flutes follow: a 3D model when one is set, else the material top (start depth 0) or the start depth.
    public var follow: Follow {
        if surfaceModelID != nil { return .model }
        return startDepth > 1e-9 ? .startDepth : .materialTop
    }

    /// Tool shapes that leave a rounded or V-shaped flute (a core box bit is a ball nose in the tool library).
    public static func suits(_ shape: ToolShape) -> Bool {
        switch shape {
        case .ballNose, .bullNose, .vBit, .engraving, .taperedBallNose: true
        case .flatEndMill, .surfacing, .drill, .form, .dovetail: false
        }
    }

    /// The length of the ramps on a flute `length` long, mm: the ramp length or percentage, no longer than the
    /// flute allows (all of it for one ramp, half for two).
    public func rampLength(onFluteOf length: Double) -> Double {
        guard ramp != .none, length > 1e-9 else { return 0 }
        let longest = ramp == .both ? length / 2 : length
        let asked = rampPercent.map { max(0, $0) * longest } ?? max(0, rampLength)
        return min(asked, longest)
    }

    /// Depth below the start depth at distance `s` along a flute `length` long, mm (0 to `depth`).
    public func depth(at s: Double, fluteLength length: Double) -> Double {
        let ramp = rampLength(onFluteOf: length)
        guard ramp > 1e-9 else { return max(0, depth) }
        func eased(_ x: Double) -> Double {
            let f = min(1, max(0, x))
            return rampShape == .linear ? f : sin(f * .pi / 2)
        }
        var fraction = 1.0
        if self.ramp == .both || self.ramp == .start { fraction = min(fraction, eased(s / ramp)) }
        if self.ramp == .both || self.ramp == .end { fraction = min(fraction, eased((length - s) / ramp)) }
        return max(0, depth) * fraction
    }
}

/// Prism carving: a V-bit carves a shape as a raised bevel rising to a ridge along its middle (see `PrismGenerator`),
/// as Vectric's Prism Carving toolpath does. The bit's tip runs round the outline at the prism depth; its side cuts the
/// slopes, so the outer side of the cut wants a pocket or profile round it.
public struct PrismParams: Hashable, Codable, Sendable {
    /// Depth the prism is calculated from, mm below the material top (0 on the surface, or a pocket's floor).
    public var startDepth: Double
    /// Depth of the prism's base below the start depth, mm; nil = deep enough for a full prism, its slopes meeting in
    /// a ridge everywhere. A shallower prism has a flat top where the shape is wider than the slopes reach.
    public var depth: Double?
    /// Max depth per pass; nil uses the tool's stepdown.
    public var passDepth: Double?
    public var direction: CutDirection

    public init(startDepth: Double = 0, depth: Double? = nil, passDepth: Double? = nil, direction: CutDirection = .climb) {
        self.startDepth = startDepth
        self.depth = depth
        self.passDepth = passDepth
        self.direction = direction
    }
}

// MARK: Edge profile

/// An edge profile: a form bit (roundover, cove, ogee or custom) shapes the top edge of closed shapes, the parts, round
/// their outside, their holes or both, as a bearing-guided bit does on a router table (see `EdgeProfileGenerator`). The
/// bit's tip runs `depth` below the material top with its pilot (its radius at the tip) on the edge, stood off it by
/// `offset`, so a roundover rounds the edge rather than cutting a groove beside it. By default it steps in from the
/// waste in horizontal passes at full depth, each taking a band of the cross-section, then takes a light finishing pass;
/// or it steps down at its final position, as a Profile toolpath does. Format 18.
public struct EdgeProfileParams: Hashable, Codable, Sendable {
    /// Which edges of the parts are profiled. Shapes inside shapes are holes, as a profile's are.
    public enum Edges: String, Codable, Sendable, CaseIterable, Identifiable {
        case outside, holes, both
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
        public var includesOutside: Bool { self != .holes }
        public var includesHoles: Bool { self != .outside }
    }

    /// How the passes divide the profile.
    public enum Passes: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Stepping in from the waste at full depth, a band of the cross-section at a time (as a router table's fence is
        /// moved back between passes).
        case horizontal
        /// Stepping down at the final position, as a Profile toolpath does (for profiles that only widen going up).
        case vertical
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public var edges: Edges
    /// How far below the material top the bit's tip runs, mm; nil = the bit's full profile height (`depth(for:)`).
    /// Deeper than the profile leaves a step above it (a reveal), as raising the bit on a router table does.
    public var depth: Double?
    /// How far the bit stands off the edge, mm: 0 puts its pilot on the edge; more cuts only the inner part of the
    /// profile.
    public var offset: Double
    public var passes: Passes
    /// Horizontal passes before the finishing pass, each taking an equal share of the cross-section (unless `bandWidth`
    /// is set).
    public var passCount: Int
    /// Horizontal passes: the widest band one pass may step in, mm; the passes then step in evenly, as few as keep each
    /// band within it. nil = `passCount` passes of equal cross-section.
    public var bandWidth: Double?
    /// Vertical passes: the deepest cut per pass, mm; nil uses the tool's stepdown.
    public var passDepth: Double?
    /// The finishing pass's band at most, mm: the passes before it stop this far off the final position, and a last lap
    /// takes the rest. Narrower where that band would take more than a quarter of the heaviest pass before it
    /// (`EdgeProfilePlan.finishShare`), so the finish stays the lightest cut. 0 = no finishing pass.
    public var finish: Double
    public var direction: CutDirection
    /// How each edge's first pass enters (later passes link to it at depth where they can).
    public var entry: EntrySettings
    /// Lead-in and lead-out moves in the waste; nil = none.
    public var leads: LeadSettings?

    public static let defaultPassCount = 3
    public static let defaultFinish = 0.02.inch
    public static let defaultEntry = EntrySettings(kind: .ramp, rampLength: 2.inch)

    public init(edges: Edges = .outside, depth: Double? = nil, offset: Double = 0, passes: Passes = .horizontal,
                passCount: Int = EdgeProfileParams.defaultPassCount, bandWidth: Double? = nil, passDepth: Double? = nil,
                finish: Double = EdgeProfileParams.defaultFinish, direction: CutDirection = .climb,
                entry: EntrySettings = EdgeProfileParams.defaultEntry, leads: LeadSettings? = LeadSettings()) {
        self.edges = edges
        self.depth = depth
        self.offset = offset
        self.passes = passes
        self.passCount = passCount
        self.bandWidth = bandWidth
        self.passDepth = passDepth
        self.finish = finish
        self.direction = direction
        self.entry = entry
        self.leads = leads
    }

    /// The depth `tool`'s tip runs at below the material top, mm: the depth set, or the height of its profile.
    public func depth(for tool: Tool) -> Double {
        max(0.01, depth ?? tool.form?.profileHeight ?? tool.fluteLength)
    }

    /// How much deeper than `tool`'s profile the cut goes, mm: the step (reveal) left above the profile.
    public func reveal(for tool: Tool) -> Double {
        guard let h = tool.form?.profileHeight else { return 0 }
        return max(0, depth(for: tool) - h)
    }
}

public enum OperationKind: Hashable, Codable, Sendable {
    case profile(ProfileParams)
    case pocket(PocketParams)
    case drill(DrillParams)
    case vcarve(VCarveParams)
    case rough3D(Rough3DParams)
    case finish3D(Finish3DParams)
    /// Rotary jobs: turning the blank round (needs no shapes).
    case rounding(RoundingParams)
    /// Rotary jobs: a 3D model on the blank, finished all the way round as it turns.
    case rotaryFinish(RotaryFinishParams)
    /// Rotary jobs: the stock round a 3D model on the blank cleared in layers, leaving an allowance for the finish.
    case rotaryRough(RotaryRoughParams)
    /// A V-bit bevel along closed vectors.
    case chamfer(ChamferParams)
    /// A groove along vectors that ramps in and out at its ends.
    case fluting(FlutingParams)
    /// A raised bevel rising to a ridge along the middle of a shape.
    case prism(PrismParams)
    /// A form bit's profile cut into the top edge of parts, round their outside or their holes. Format 18.
    case edgeProfile(EdgeProfileParams)
    /// A profile vector swept along rail vectors into a 3D surface, roughed and finished with the 3D strategies.
    /// Format 22.
    case moulding(MouldingParams)

    public var label: String {
        switch self {
        case .profile: "Profile"
        case .pocket: "Pocket"
        case .drill: "Drill"
        case .vcarve: "V-carve"
        case .rough3D: "3D Roughing"
        case .finish3D: "3D Finishing"
        case .rounding: "Rounding"
        case .rotaryFinish: "3D Rotary Finishing"
        case .rotaryRough: "3D Rotary Roughing"
        case .chamfer: "Chamfer"
        case .fluting: "Fluting"
        case .prism: "Prism"
        case .edgeProfile: "Edge Profile"
        case .moulding: "Moulding"
        }
    }

    /// True for the operations that cut along their vectors rather than from the tool's edge (chamfers, flutes, prisms
    /// and edge profiles): the part they shape is the one drawn, however wide the bit.
    public var followsVectors: Bool {
        switch self {
        case .chamfer, .fluting, .prism, .edgeProfile: true
        default: false
        }
    }

    /// True for an edge profile.
    public var isEdgeProfile: Bool {
        if case .edgeProfile = self { return true }
        return false
    }

    /// True for an operation that works on the blank itself rather than on shapes.
    public var needsShapes: Bool {
        if case .rounding = self { return false }
        return true
    }

    /// True for the rotary operations that cut all the way round the blank as it turns, on either layout: rounding and
    /// 3D rotary roughing and finishing. Their toolpaths are wrapped round the blank at the sheet's radius, and they take
    /// no index angles.
    public var turnsWholeBlank: Bool {
        switch self {
        case .rounding, .rotaryFinish, .rotaryRough: true
        default: false
        }
    }

    public var is3D: Bool {
        switch self {
        case .rough3D, .finish3D, .rotaryFinish, .rotaryRough, .moulding: true
        default: false
        }
    }

    /// Whether the posted moves may be fitted with arcs. Constant scallop, spiral and radial passes curve in plan while
    /// following the surface: an arc fitted to them (Z linear in angle, within the fitting tolerance in plan and at
    /// its points) can dip into the surface by about the tolerance on a slope, and side into a vertical edge the
    /// passes run beside. They post as the straight moves along the exact drop-cutter path that raster rows are.
    public var fitsArcs: Bool {
        if case let .finish3D(p) = self, p.strategy.isFormat21 { return false }
        if case let .moulding(p) = self, p.finish.strategy.isFormat21 { return false }
        return true
    }

    /// Deepest point the operation is asked to reach, mm below the material top (nil for unlimited V-carve).
    public var requestedDepth: Double? {
        switch self {
        case let .profile(p): p.depth.cutDepth
        case let .pocket(p): p.depth.cutDepth
        case let .drill(p): p.depth
        case let .vcarve(p): p.deepest
        case let .fluting(p): p.startDepth + p.depth
        // Set by the bit's angle (a chamfer's width) or the shape (a full prism).
        case let .prism(p): p.depth.map { p.startDepth + $0 }
        // nil: the bit's whole profile, as the chip-load chart reads a form bit with no depth.
        case let .edgeProfile(p): p.depth
        case .rough3D, .finish3D, .rounding, .rotaryFinish, .rotaryRough, .chamfer, .moulding: nil
        }
    }
}

/// A machining operation applied to a set of design shapes with one tool.
public struct CAMOperation: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var kind: OperationKind
    public var shapeIDs: [UUID]
    /// A copy of the tool so the project stays self-contained if the library changes.
    public var tool: Tool
    /// On rotary stock, the angles (degrees, in cutting order) the blank turns to before this operation cuts the
    /// face under the spindle; the same shapes are cut at each angle. nil cuts at 0° only. Only rotary jobs take
    /// angles.
    public var indexAngles: [Double]?
    /// How the toolpath finds its shapes: the shapes on a layer, or of a kind, which `Project.bindVectors()` picks up
    /// again (applying a template, Recalculate All, changing a shape's layer); nil = chosen by hand. `shapeIDs` is
    /// always what's cut, so a build that doesn't know the key cuts the same shapes. In a template, `.selection`
    /// means the shapes selected when it's applied.
    public var vectorSelection: VectorSelection?

    // MARK: Feed scheduling
    /// Profiles and pockets: "Adjust feeds for load", slowing the feed where the bit cuts more than in the toolpath's
    /// usual cut (see `FeedScheduler`). nil or false keeps the programmed feed throughout. An older build ignores it and
    /// posts the programmed feed, which the scheduler never exceeds, so it doesn't raise the file format.
    public var adjustFeedsForLoad: Bool?
    /// Spindle ▸ Automatic: the toolpath's spindle speed is picked to put the chip in the chart's range at the feed the
    /// machine reaches (`ChipLoad.automaticSpindle`), within the spindle's range and a router bit's speed limit; nil or
    /// `.tool` uses the tool's RPM. An older build ignores it and posts the tool's RPM, the speed every toolpath had
    /// before and still checked the same way, so it doesn't raise the file format (as `adjustFeedsForLoad` doesn't).
    public var spindleSpeed: SpindleSpeedMode?

    public init(id: UUID = UUID(), name: String? = nil, enabled: Bool = true, kind: OperationKind,
                shapeIDs: [UUID], tool: Tool, indexAngles: [Double]? = nil, vectorSelection: VectorSelection? = nil,
                adjustFeedsForLoad: Bool? = nil, spindleSpeed: SpindleSpeedMode? = nil) {
        self.id = id
        self.name = name ?? kind.label
        self.enabled = enabled
        self.kind = kind
        self.shapeIDs = shapeIDs
        self.tool = tool
        self.indexAngles = indexAngles
        self.vectorSelection = vectorSelection
        self.adjustFeedsForLoad = adjustFeedsForLoad
        self.spindleSpeed = spindleSpeed
    }

    /// The angles this operation cuts at on rotary stock.
    public var rotaryAngles: [Double] { indexAngles ?? [0] }

    /// The tool that cuts before the operation's own: a pocket's larger clearance tool, or the end mill that clears a
    /// V-carve's flat bottom. Operations next to each other in the run order that share one cut all their clearing
    /// first, then their own tools (see `OperationScheduler`).
    public var clearanceTool: Tool? {
        switch kind {
        case let .pocket(p): p.clearanceTool
        case let .vcarve(p): (p.carveFlatDepth ?? 0) > 0 ? p.clearanceTool : nil
        case let .moulding(p): p.roughing?.tool
        default: nil
        }
    }

    /// The project file format this operation needs. Index angles are format 3: a build that reads format 2 would
    /// drop them and cut every face's shapes at one angle. Rounding is format 5 (older builds can't read it). A V-carve
    /// start depth or inlay plug is format 6 (see `VCarveParams.requiredFormatVersion`). 3D rotary finishing is format 7.
    /// Chamfers, flutes and prisms are format 8 (older builds can't read them). 3D finishing other than a single raster
    /// is format 10 (see `Finish3DParams.requiredFormatVersion`). 3D rotary roughing is format 12. Adaptive pocket
    /// clearing is format 13. A whole-board inlay plug is format 14. A tapered ball nose, form or dovetail bit, as the
    /// operation's tool or its clearance tool, is format 15 (see `ToolShape.requiredFormatVersion`). 3D rest finishing
    /// is format 17. A pocket resting from earlier toolpaths needs no new format (`PocketParams.restFromEarlier`). Edge
    /// profiles are format 18. A chamfer with an overcut or a form bit is format 19. Constant scallop, spiral and radial
    /// 3D finishing are format 21. Mouldings are format 22. Flutes that follow a 3D model are format 25.
    public var requiredFormatVersion: Int {
        var bits = tool.shape.requiredFormatVersion
        switch kind {
        case let .pocket(p): bits = max(bits, p.clearanceTool?.shape.requiredFormatVersion ?? 1)
        case let .vcarve(p): bits = max(bits, p.clearanceTool?.shape.requiredFormatVersion ?? 1)
        case let .moulding(p): bits = max(bits, p.roughing?.tool.shape.requiredFormatVersion ?? 1)
        default: break
        }
        let own: Int
        switch kind {
        case let .pocket(p): own = p.requiredFormatVersion
        case .rounding: own = 5
        case .rotaryFinish: own = 7
        case .rotaryRough: own = 12
        case let .chamfer(p): own = p.needsFormat19(with: tool) ? 19 : 8
        case let .fluting(p): own = p.surfaceModelID == nil ? 8 : FlutingParams.followsModelFormat
        case .prism: own = 8
        case .edgeProfile: own = 18
        case let .vcarve(p): own = p.requiredFormatVersion
        case let .finish3D(p): own = p.requiredFormatVersion
        case let .rough3D(p): own = p.requiredFormatVersion
        case .moulding: own = MouldingParams.formatVersion
        default: own = 1
        }
        return max(own, indexAngles == nil ? 1 : 3, bits)
    }
}

// MARK: Feed scheduling

public extension OperationKind {
    /// The operations "Adjust feeds for load" applies to.
    var takesLoadFeeds: Bool {
        switch self {
        case .profile, .pocket: true
        default: false
        }
    }
}

public extension CAMOperation {
    /// True when this operation's feeds follow the load (`adjustFeedsForLoad`, on a profile or pocket).
    var adjustsFeedsForLoad: Bool { adjustFeedsForLoad == true && kind.takesLoadFeeds }

    /// True when this operation's spindle speed is picked per toolpath (`spindleSpeed`, Spindle ▸ Automatic).
    var usesAutomaticSpindle: Bool { spindleSpeed == .automatic }
}

// MARK: Pass depth

public extension OperationKind {
    /// The deepest single pass `tool` takes, mm, for the chip-load chart's depth derate (`ChipLoad.depthShare`): a
    /// profile's or pocket's deepest step between its Z levels, or 3D roughing's layer depth. nil where passes aren't
    /// set by a depth per pass, and for adaptive clearing, whose light cut is why it goes the bit's whole height deep
    /// (its chip is thinned for that instead).
    func deepestPass(_ tool: Tool) -> Double? {
        func deepest(_ depth: DepthSettings, _ levels: [Double]) -> Double? {
            var top = -depth.startDepth
            var most: Double?
            for z in levels {
                most = max(most ?? 0, top - z)
                top = z
            }
            return most
        }
        switch self {
        case let .profile(p):
            return deepest(p.depth, p.depth.passLevels(toolStepdown: tool.cutting.stepdown, firstPassMinimum: tool.firstPassMinimum))
        case let .pocket(p):
            return p.strategy == .adaptive ? nil : deepest(p.depth, p.passLevels(tool))
        case let .rough3D(p):
            return p.deepestPass(tool)
        default:
            return nil
        }
    }
}
