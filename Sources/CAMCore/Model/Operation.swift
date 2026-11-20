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
    public var cutDepth: Double
    /// Max depth per pass; nil uses the tool's stepdown.
    public var passDepth: Double?

    public init(startDepth: Double = 0, cutDepth: Double, passDepth: Double? = nil) {
        self.startDepth = startDepth
        self.cutDepth = cutDepth
        self.passDepth = passDepth
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
public struct CornerReliefSettings: Hashable, Codable, Sendable {
    public var style: CornerReliefStyle
    public var tBoneSide: TBoneSide
    /// Corners up to this angle (degrees, measured across the cut-away area; a square corner is 90) are relieved.
    public var maxCornerAngle: Double
    /// Corners given their own relief on the canvas; nil = every corner follows the settings above.
    public var overrides: [CornerOverride]?

    public init(style: CornerReliefStyle = .dogbone, tBoneSide: TBoneSide = .longer, maxCornerAngle: Double = 120,
                overrides: [CornerOverride]? = nil) {
        self.style = style
        self.tBoneSide = tBoneSide
        self.maxCornerAngle = maxCornerAngle
        self.overrides = overrides
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
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
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

    public init(strategy: PocketStrategy = .offset, direction: CutDirection = .climb, depth: DepthSettings,
                allowance: Double = 0, rasterAngle: Double = 0, stepoverFraction: Double? = nil,
                entry: EntrySettings = EntrySettings(), cornerRelief: CornerReliefSettings? = nil) {
        self.strategy = strategy
        self.direction = direction
        self.depth = depth
        self.allowance = allowance
        self.rasterAngle = rasterAngle
        self.stepoverFraction = stepoverFraction
        self.entry = entry
        self.cornerRelief = cornerRelief
    }
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

    public init(depth: Double, peckDepth: Double = 0, fullRetract: Bool = true, dwell: Double = 0) {
        self.depth = depth
        self.peckDepth = peckDepth
        self.fullRetract = fullRetract
        self.dwell = dwell
    }
}

public struct VCarveParams: Hashable, Codable, Sendable {
    /// Maximum carve depth (flat bottom), mm; nil carves to full V depth wherever the shape allows.
    public var flatDepth: Double?
    /// Max depth per pass; nil carves in one pass.
    public var passDepth: Double?
    /// Spacing of samples along the outline, mm (smaller = smoother, more G-code).
    public var sampleSpacing: Double
    /// Optional flat end mill that clears the flat bottom (only used with `flatDepth`). Cut before the V-bit.
    public var clearanceTool: Tool?

    public init(flatDepth: Double? = nil, passDepth: Double? = nil, sampleSpacing: Double = 0.25, clearanceTool: Tool? = nil) {
        self.flatDepth = flatDepth
        self.passDepth = passDepth
        self.sampleSpacing = sampleSpacing
        self.clearanceTool = clearanceTool
    }
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

    public init(allowance: Double = 0.02.inch, passDepth: Double? = nil, stepoverFraction: Double? = nil, boundary: ModelBoundary = .model,
                boundaryMargin: Double? = nil) {
        self.allowance = allowance
        self.passDepth = passDepth
        self.stepoverFraction = stepoverFraction
        self.boundary = boundary
        self.boundaryMargin = boundaryMargin
    }

    public static func autoMargin(tool: Tool) -> Double { tool.diameter + 1 }
}

public struct Finish3DParams: Hashable, Codable, Sendable {
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

    public init(stepoverFraction: Double = 0.1, rasterAngle: Double = 0, allowance: Double = 0, boundary: ModelBoundary = .model,
                boundaryMargin: Double? = nil) {
        self.stepoverFraction = stepoverFraction
        self.rasterAngle = rasterAngle
        self.allowance = allowance
        self.boundary = boundary
        self.boundaryMargin = boundaryMargin
    }

    public static func autoMargin(tool: Tool) -> Double { tool.radius + 0.5 }
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

public enum OperationKind: Hashable, Codable, Sendable {
    case profile(ProfileParams)
    case pocket(PocketParams)
    case drill(DrillParams)
    case vcarve(VCarveParams)
    case rough3D(Rough3DParams)
    case finish3D(Finish3DParams)
    /// Rotary jobs: turning the blank round (needs no shapes).
    case rounding(RoundingParams)

    public var label: String {
        switch self {
        case .profile: "Profile"
        case .pocket: "Pocket"
        case .drill: "Drill"
        case .vcarve: "V-carve"
        case .rough3D: "3D Roughing"
        case .finish3D: "3D Finishing"
        case .rounding: "Rounding"
        }
    }

    /// True for an operation that works on the blank itself rather than on shapes.
    public var needsShapes: Bool {
        if case .rounding = self { return false }
        return true
    }

    public var is3D: Bool {
        switch self {
        case .rough3D, .finish3D: true
        default: false
        }
    }

    /// Deepest point the operation is asked to reach, mm below the material top (nil for unlimited V-carve).
    public var requestedDepth: Double? {
        switch self {
        case let .profile(p): p.depth.cutDepth
        case let .pocket(p): p.depth.cutDepth
        case let .drill(p): p.depth
        case let .vcarve(p): p.flatDepth
        case .rough3D, .finish3D, .rounding: nil
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

    public init(id: UUID = UUID(), name: String? = nil, enabled: Bool = true, kind: OperationKind,
                shapeIDs: [UUID], tool: Tool, indexAngles: [Double]? = nil) {
        self.id = id
        self.name = name ?? kind.label
        self.enabled = enabled
        self.kind = kind
        self.shapeIDs = shapeIDs
        self.tool = tool
        self.indexAngles = indexAngles
    }

    /// The angles this operation cuts at on rotary stock.
    public var rotaryAngles: [Double] { indexAngles ?? [0] }

    /// The project file format this operation needs. Index angles are format 3: a build that reads format 2 would
    /// drop them and cut every face's shapes at one angle. Rounding is format 5 (older builds can't read it).
    public var requiredFormatVersion: Int {
        if case .rounding = kind { return 5 }
        return indexAngles == nil ? 1 : 3
    }
}
