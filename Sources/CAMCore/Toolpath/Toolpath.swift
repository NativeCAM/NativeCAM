import Foundation

public enum MotionKind: String, Codable, Sendable {
    case rapid
    case feed
    /// Clockwise arc in XY (G2), optionally helical (Z changes linearly).
    case arcCW
    /// Counter-clockwise arc in XY (G3), optionally helical.
    case arcCCW
    /// Pause in place (G4); `feed` holds the duration in seconds.
    case dwell

    public var isArc: Bool { self == .arcCW || self == .arcCCW }
}

/// One machine move. Coordinates are design XY (mm) and Z relative to the material top (mm, negative = into stock).
public struct Motion: Hashable, Codable, Sendable {
    public var kind: MotionKind
    public var end: Vec3
    /// Absolute XY arc centre (arcs only).
    public var center: Vec2
    /// Feed rate in mm/min (0 for rapids).
    public var feed: Double
    /// Rotary A position at the end of the move, degrees, unwound (720 is two full turns, not 0); nil when no
    /// rotary axis is involved. Only G-code read back from a file sets it so far: every toolpath generator, the
    /// simulator and the posts ignore it (wrapped toolpaths work out A from Y instead; see `RotaryWrap`).
    public var a: Double?
    /// The F word of a move read back in inverse-time mode (G93): one over the move's time in minutes. nil for
    /// ordinary feeds. When it's set, `feed` is only the XYZ distance over that time.
    public var inverseTime: Double?

    public init(kind: MotionKind, end: Vec3, center: Vec2 = .zero, feed: Double = 0, a: Double? = nil, inverseTime: Double? = nil) {
        self.kind = kind
        self.end = end
        self.center = center
        self.feed = feed
        self.a = a
        self.inverseTime = inverseTime
    }

    public static func rapid(_ p: Vec3) -> Motion { Motion(kind: .rapid, end: p) }
    public static func feed(_ p: Vec3, _ f: Double) -> Motion { Motion(kind: .feed, end: p, feed: f) }
}

/// Geometry helpers for a motion that starts at `start`.
public extension Motion {
    /// Signed sweep angle (radians) for arcs; positive = CCW.
    func arcSweep(from start: Vec3) -> Double {
        guard kind.isArc else { return 0 }
        let a0 = (start.xy - center).angle
        let a1 = (end.xy - center).angle
        var sweep = a1 - a0
        if kind == .arcCCW {
            while sweep <= 1e-12 { sweep += 2 * .pi }
        } else {
            while sweep >= -1e-12 { sweep -= 2 * .pi }
        }
        return sweep
    }

    func length(from start: Vec3) -> Double {
        if kind == .dwell { return 0 }
        if kind.isArc {
            let r = start.xy.distance(to: center)
            let planar = abs(arcSweep(from: start)) * r
            let dz = end.z - start.z
            return (planar * planar + dz * dz).squareRoot()
        }
        return start.distance(to: end)
    }

    /// Seconds this motion takes (constant-velocity model). An inverse-time move takes exactly the time its F word
    /// gives.
    func duration(from start: Vec3, rapidRate: Double) -> Double {
        switch kind {
        case .dwell: return max(0, feed)
        case .rapid: return length(from: start) / max(rapidRate, 1) * 60
        default:
            if let f = inverseTime, f > 0 { return 60 / f }
            return length(from: start) / max(feed, 1) * 60
        }
    }

    /// Points along the motion (excluding `start`), spaced at most `maxStep` mm apart for arcs.
    func samples(from start: Vec3, maxStep: Double = 0.5) -> [Vec3] {
        guard kind.isArc else { return [end] }
        let r = start.xy.distance(to: center)
        let sweep = arcSweep(from: start)
        let n = max(2, Int((abs(sweep) * r / max(maxStep, 1e-3)).rounded(.up)))
        let a0 = (start.xy - center).angle
        var out: [Vec3] = []
        out.reserveCapacity(n)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let p = center + Vec2.fromAngle(a0 + sweep * t, length: r)
            out.append(Vec3(p, start.z + (end.z - start.z) * t))
        }
        out[out.count - 1] = end
        return out
    }
}

/// The planner's estimate for a toolpath cut one way and for the same toolpath cut both ways (`Toolpath.directionTime`),
/// seconds, linked as the job links them, before arc fitting.
public struct DirectionTime: Hashable, Codable, Sendable {
    public var seconds: Double
    public var bothWaysSeconds: Double

    public init(seconds: Double, bothWaysSeconds: Double) {
        self.seconds = seconds
        self.bothWaysSeconds = bothWaysSeconds
    }

    /// How much longer one way takes, seconds (negative when it's quicker).
    public var extraSeconds: Double { seconds - bothWaysSeconds }
}

/// The ordered motions for one operation, cut with one tool.
/// The loops a profile's finishing laps run round (tool centre), and how near a move must be to count as on one.
public struct FinishLaps: Hashable, Codable, Sendable {
    public var loops: [Polyline]
    public var tolerance: Double

    public init(loops: [Polyline], tolerance: Double) {
        self.loops = loops
        self.tolerance = tolerance
    }
}

public struct Toolpath: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var tool: Tool
    public var spindleRPM: Double
    /// Where the tool is before the first motion (normally clearance height above the first cut).
    public var start: Vec3
    public var motions: [Motion]
    public var warnings: [String]
    /// On rotary stock, the angle (degrees, right-hand rule about +X) the blank turns to before this toolpath cuts;
    /// its motions are in that face's frame. nil on a flat job.
    public var indexAngle: Double?
    /// The operation this toolpath came from, when it isn't `id` (an operation cut at several angles makes one
    /// toolpath per angle, and a rest-machined pocket's clearing with the larger tool has an ID of its own).
    public var operationID: UUID?
    /// The inside corners that get (or could get) a relief, for showing and changing them on the canvas; nil when the
    /// operation has no corner reliefs. Posts and checks don't read it.
    public var reliefCorners: [ReliefCorner]?
    /// On a wrapped rotary job, the diameter the motions wrap around, mm; nil for flat and indexed toolpaths. The
    /// motions stay on the flat sheet: the posts and checks turn design Y into the A angle and Z into a distance
    /// from the axis as they write and read the file (`RotaryWrap`).
    public var wrapDiameter: Double?
    /// On a tiled job, the tile (from 0, in run order) whose file this toolpath is cut in; its motions stay in job
    /// coordinates (see `TiledJob`). nil when the job isn't tiled.
    public var tile: Int?
    /// On a job nested onto several sheets, the sheet (from 0) whose file this toolpath is cut in; its motions are in
    /// that sheet's coordinates (see `SheetJob`). nil on a job of one sheet.
    public var sheet: Int?
    /// With "Adjust feeds for load", what the scheduler did to the feeds (see `FeedScheduler`); nil when the
    /// toolpath keeps its programmed feed throughout.
    public var loadFeeds: LoadFeeds?
    /// Adaptive clearing: the share of the bit's diameter its usual cut takes from the side (the optimal load), so the
    /// chip-load check allows for the thinner chip (`ChipLoad.radialThinning`). nil = a full-width chip.
    public var radialLoad: Double?
    /// Rest machining: the areas left for this toolpath's bit, for shading on the canvas (where a 3D rest pass's centre
    /// goes; what a pocket resting from earlier toolpaths has left to clear). Empty when nothing is left; nil for every
    /// other toolpath. Posts and checks don't read it.
    public var restAreas: [Polyline]?
    /// A profile's finishing pass: the loops its finishing laps run round, for "Adjust feeds for load" to leave alone.
    /// nil for every other toolpath. Posts and checks don't read it.
    public var finishLaps: FinishLaps?
    /// Calibration programs (`Calibration`): the program stops (M0) once the tool is over this toolpath's start at
    /// safe Z, showing this message, and goes back to safe Z when the operator resumes. The spindle keeps turning: the
    /// operator only times the run, nowhere near the tool. nil everywhere else. The G-code and OpenSBP posts write it
    /// for flat and indexed toolpaths; imported Vectric posts and wrapped toolpaths ignore it.
    public var stopMessage: String?
    /// A stop before this toolpath for the operator to work at the material (an individual tile's dowels, see
    /// `TileSplitter`): the posts raise the tool to safe Z, turn the spindle off, stop (M0, or PAUSE) showing this
    /// message, and start the spindle again with its spin-up dwell afterwards. nil everywhere else. The G-code and
    /// OpenSBP posts write it; imported Vectric posts ignore it.
    public var spindleOffStop: String?
    /// What Checks notes about the toolpath as information rather than a warning (an edge profile's inside corners
    /// sharper than its bit). nil for none.
    public var notes: [String]?
    /// Spindle ▸ Automatic: the speed picked for this toolpath (`spindleRPM` is set to it) and why; nil when it runs
    /// at its tool's RPM.
    public var automaticSpindle: AutomaticSpindle?
    /// A toolpath whose passes would zig-zag, cut one way (Climb or Conventional): the planner's time for it against
    /// the same cut both ways, for the inspector. nil otherwise.
    public var directionTime: DirectionTime?

    public init(id: UUID, name: String, tool: Tool, spindleRPM: Double, start: Vec3, motions: [Motion], warnings: [String] = [],
                indexAngle: Double? = nil, operationID: UUID? = nil) {
        self.id = id
        self.name = name
        self.tool = tool
        self.spindleRPM = spindleRPM
        self.start = start
        self.motions = motions
        self.warnings = warnings
        self.indexAngle = indexAngle
        self.operationID = operationID
    }

    /// The operation this toolpath belongs to.
    public var sourceOperationID: UUID { operationID ?? id }

    public var isEmpty: Bool { !motions.contains { $0.kind != .rapid } }

    /// Visits every motion with its start point.
    public func forEachMotion(_ body: (_ start: Vec3, _ motion: Motion) -> Void) {
        var p = start
        for m in motions {
            body(p, m)
            p = m.end
        }
    }

    public struct Extents: Hashable, Sendable {
        public var min: Vec3
        public var max: Vec3
    }

    /// Bounding box of all cutting (non-rapid) motion, including arc bulges. Nil if nothing is cut.
    public var cuttingExtents: Extents? {
        var lo = Vec3(.infinity, .infinity, .infinity)
        var hi = Vec3(-.infinity, -.infinity, -.infinity)
        var any = false
        forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            any = true
            for p in [s] + m.samples(from: s, maxStep: 1) {
                lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
                hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
            }
        }
        return any ? Extents(min: lo, max: hi) : nil
    }

    public var cuttingLength: Double {
        var total = 0.0
        forEachMotion { s, m in if m.kind != .rapid && m.kind != .dwell { total += m.length(from: s) } }
        return total
    }

    public var rapidLength: Double {
        var total = 0.0
        forEachMotion { s, m in if m.kind == .rapid { total += m.length(from: s) } }
        return total
    }

    /// Estimated run time in seconds (constant-velocity model: ignores acceleration).
    public func estimatedSeconds(rapidRate: Double) -> Double {
        var t = 0.0
        forEachMotion { s, m in t += m.duration(from: s, rapidRate: rapidRate) }
        return t
    }
}
