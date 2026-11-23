import Foundation

/// Cutter geometry families. The shape drives offsetting, V-carve depth math, and the simulator.
public enum ToolShape: String, Codable, Sendable, CaseIterable, Identifiable {
    case flatEndMill
    case ballNose
    /// Flat end mill with a corner radius (bull nose).
    case bullNose
    /// V-bit; `includedAngle` and optional flat `tipDiameter`.
    case vBit
    /// Tapered engraving bit: V with a small flat tip.
    case engraving
    /// Large-diameter flat spoilboard / surfacing bit.
    case surfacing
    case drill
    /// Tapered ball nose (3D relief carving): a ball tip of diameter `tipDiameter` running into a cone that widens by
    /// half the `includedAngle` per side, up to `diameter` at the top of the flutes.
    case taperedBallNose
    /// A bit with a profile of its own for cutting edges (roundover, cove, ogee or custom), described by `Tool.form`.
    case form
    /// Dovetail: widest at the tip (`diameter`), narrowing by half the `includedAngle` per side up to `fluteLength`.
    case dovetail

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .flatEndMill: "End Mill"
        case .ballNose: "Ball Nose"
        case .bullNose: "Bull Nose"
        case .vBit: "V-Bit"
        case .engraving: "Engraving"
        case .surfacing: "Surfacing"
        case .drill: "Drill"
        case .taperedBallNose: "Tapered Ball Nose"
        case .form: "Form"
        case .dovetail: "Dovetail"
        }
    }

    public var isTapered: Bool { self == .vBit || self == .engraving }
    public var usesCornerRadius: Bool { self == .bullNose }
    public var usesAngle: Bool { self == .vBit || self == .engraving || self == .drill }
    /// Form and dovetail bits, which only cut edges (a profile toolpath at depth), never floors or 3D surfaces.
    public var cutsEdgesOnly: Bool { self == .form || self == .dovetail }

    /// The project file format a toolpath using this shape needs: tapered ball noses, form and dovetail bits are format
    /// 15 (a format-14 build can't read them).
    public var requiredFormatVersion: Int {
        switch self {
        case .taperedBallNose, .form, .dovetail: 15
        default: 1
        }
    }
}

public enum FluteDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case upcut, downcut, compression, straight
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Feeds, speeds and engagement for one tool. Lengths are mm, feeds mm/min.
public struct CuttingData: Hashable, Codable, Sendable {
    public var spindleRPM: Double
    public var feedRate: Double
    public var plungeRate: Double
    /// Maximum depth per pass.
    public var stepdown: Double
    /// Lateral step between adjacent passes, as a fraction of the tool diameter (0–1).
    public var stepoverFraction: Double

    public init(spindleRPM: Double, feedRate: Double, plungeRate: Double, stepdown: Double, stepoverFraction: Double) {
        self.spindleRPM = spindleRPM
        self.feedRate = feedRate
        self.plungeRate = plungeRate
        self.stepdown = stepdown
        self.stepoverFraction = stepoverFraction
    }
}

/// A cutting tool with full geometry. All lengths in mm.
public struct Tool: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Tool number written as T# in the G-code (and the ATC pocket / tool table slot).
    public var number: Int
    public var name: String
    public var shape: ToolShape
    public var fluteDirection: FluteDirection
    public var fluteCount: Int
    /// Cutting diameter (for tapered tools: the maximum diameter at the top of the cutting edge).
    public var diameter: Double
    public var shankDiameter: Double
    /// Length of the cutting edge.
    public var fluteLength: Double
    /// Tool length out of the collet (informational; used for clearance checks).
    public var stickout: Double
    /// Corner radius for bull nose tools.
    public var cornerRadius: Double
    /// Included angle for V-bits/engraving/drill points, degrees (e.g. 60, 90, 118).
    public var includedAngle: Double
    /// Flat tip diameter for V-bits and engraving bits.
    public var tipDiameter: Double
    public var cutting: CuttingData
    public var notes: String
    /// Compression bits: length of the upcut section at the tip. The first pass must go deeper than this or the bit
    /// cuts like an upcut and frays the top face. nil means "about one diameter".
    public var upcutLength: Double?
    /// Form bits: the shape of the cutting edge. nil for every other shape (and not written to files then).
    public var form: FormProfile?

    public init(id: UUID = UUID(), number: Int, name: String, shape: ToolShape,
                fluteDirection: FluteDirection = .upcut, fluteCount: Int = 2,
                diameter: Double, shankDiameter: Double? = nil, fluteLength: Double, stickout: Double? = nil,
                cornerRadius: Double = 0, includedAngle: Double = 90, tipDiameter: Double = 0,
                cutting: CuttingData, notes: String = "", upcutLength: Double? = nil, form: FormProfile? = nil) {
        self.id = id
        self.number = number
        self.name = name
        self.shape = shape
        self.fluteDirection = fluteDirection
        self.fluteCount = fluteCount
        self.diameter = diameter
        self.shankDiameter = shankDiameter ?? diameter
        self.fluteLength = fluteLength
        self.stickout = stickout ?? fluteLength + 0.5.inch
        self.cornerRadius = cornerRadius
        self.includedAngle = includedAngle
        self.tipDiameter = tipDiameter
        self.cutting = cutting
        self.notes = notes
        self.upcutLength = upcutLength
        self.form = form
    }

    public var radius: Double { diameter / 2 }

    /// tan(half the included angle). Tapered tools only.
    public var halfAngleTangent: Double { tan((includedAngle / 2).radians) }

    /// Height of the tapered section (from tip to full diameter) for V and engraving bits.
    public var taperHeight: Double {
        guard shape.isTapered else { return 0 }
        return max(0, (radius - tipDiameter / 2) / halfAngleTangent)
    }

    /// The diameter stepover fractions are taken of: a tapered ball nose's tip (as Vectric does), else the diameter.
    public var stepoverBasis: Double {
        shape == .taperedBallNose && tipDiameter > 1e-6 ? min(tipDiameter, diameter) : diameter
    }

    /// Lateral stepover in mm.
    public var stepover: Double { max(0.01, stepoverBasis * cutting.stepoverFraction) }

    /// Height of the tool's cutting surface above its lowest point at radial distance `r` from the axis,
    /// or nil if `r` is outside the tool. This is the profile the simulator stamps into the stock.
    public func profileHeight(atRadius r: Double) -> Double? {
        let R = radius
        guard r <= R + 1e-9 else { return nil }
        let r = min(r, R)
        switch shape {
        case .flatEndMill, .surfacing:
            return 0
        case .ballNose:
            return R - (max(0, R * R - r * r)).squareRoot()
        case .bullNose:
            let cr = min(cornerRadius, R)
            let flat = R - cr
            if r <= flat { return 0 }
            let dx = r - flat
            return cr - (max(0, cr * cr - dx * dx)).squareRoot()
        case .vBit, .engraving:
            let tip = tipDiameter / 2
            if r <= tip { return 0 }
            return (r - tip) / halfAngleTangent
        case .drill:
            // Conical point, then full diameter.
            return r / halfAngleTangent
        case .taperedBallNose:
            return TaperedBall(self).height(atRadius: r)
        case .dovetail:
            // Widest at the tip: from below it's a flat bottom.
            return 0
        case .form:
            return ToolProfile.lowerEnvelope(cuttingEdge, atRadius: r)
        }
    }

    /// Cutting radius at a height `h` above the tool tip (inverse of `profileHeight`).
    public func radius(atHeight h: Double) -> Double {
        let R = radius
        switch shape {
        case .taperedBallNose: return TaperedBall(self).radius(atHeight: h)
        case .form, .dovetail: return ToolProfile.radius(cuttingEdge, atHeight: h)
        default: break
        }
        if h <= 0 { return shape.isTapered ? tipDiameter / 2 : (shape == .ballNose || shape == .drill ? 0 : (shape == .bullNose ? R - cornerRadius : R)) }
        switch shape {
        case .flatEndMill, .surfacing:
            return R
        case .ballNose:
            if h >= R { return R }
            return (max(0, R * R - (R - h) * (R - h))).squareRoot()
        case .bullNose:
            let cr = min(cornerRadius, R)
            if h >= cr { return R }
            return R - cr + (max(0, cr * cr - (cr - h) * (cr - h))).squareRoot()
        case .vBit, .engraving:
            return min(R, tipDiameter / 2 + h * halfAngleTangent)
        case .drill:
            return min(R, h * halfAngleTangent)
        case .taperedBallNose, .form, .dovetail:
            return R // handled above
        }
    }

    /// Side silhouette of the tool (right half, x = radius, y = height above tip) for drawing and rendering.
    /// Goes from the tip up to the top of the shank.
    public func silhouette(segments: Int = 24) -> [Vec2] {
        var pts: [Vec2] = []
        let R = radius
        switch shape {
        case .flatEndMill, .surfacing:
            pts = [Vec2(0, 0), Vec2(R, 0)]
        case .ballNose:
            pts = [Vec2(0, 0)]
            for i in 1...segments {
                let a = -Double.pi / 2 + Double(i) / Double(segments) * Double.pi / 2
                pts.append(Vec2(R * cos(a), R + R * sin(a)))
            }
        case .bullNose:
            let cr = min(cornerRadius, R)
            pts = [Vec2(0, 0)]
            for i in 0...segments {
                let a = -Double.pi / 2 + Double(i) / Double(segments) * Double.pi / 2
                pts.append(Vec2(R - cr + cr * cos(a), cr + cr * sin(a)))
            }
        case .vBit, .engraving:
            pts = [Vec2(0, 0), Vec2(tipDiameter / 2, 0), Vec2(R, taperHeight)]
        case .drill:
            pts = [Vec2(0, 0), Vec2(R, R / halfAngleTangent)]
        case .taperedBallNose, .form, .dovetail:
            return ToolProfile.silhouette(self, segments: segments)
        }
        let cutTop = max(fluteLength, pts.last?.y ?? 0)
        pts.append(Vec2(R, cutTop))
        let shank = shankDiameter / 2
        pts.append(Vec2(shank, cutTop))
        pts.append(Vec2(shank, max(stickout, cutTop)))
        return pts
    }

    /// Chip load per tooth (mm) at the programmed feed and speed.
    public var chipLoad: Double {
        guard cutting.spindleRPM > 0, fluteCount > 0 else { return 0 }
        return cutting.feedRate / (cutting.spindleRPM * Double(fluteCount))
    }

    /// Feed rate (mm/min) that gives the requested chip load.
    public func feedRate(forChipLoad cl: Double) -> Double {
        cl * cutting.spindleRPM * Double(fluteCount)
    }

    /// Smallest allowed first-pass depth: compression bits must start below their upcut section (plus 0.5 mm).
    public var firstPassMinimum: Double? {
        fluteDirection == .compression ? (upcutLength ?? diameter) + 0.5 : nil
    }

    /// Maximum usable cut depth (limited by the cutting edge length).
    public var maxCutDepth: Double { fluteLength }

    /// True when both describe the same physical bit: the same cutting geometry, whatever their feeds, speeds,
    /// names or notes. Two library entries for one bit (say, one per material) can safely share a T number.
    public func isSameBit(as other: Tool) -> Bool {
        if id == other.id { return true }
        func near(_ a: Double, _ b: Double, _ tol: Double = 0.005) -> Bool { abs(a - b) <= tol }
        guard shape == other.shape, fluteDirection == other.fluteDirection, fluteCount == other.fluteCount,
              near(diameter, other.diameter) else { return false }
        if shape.usesCornerRadius && !near(cornerRadius, other.cornerRadius) { return false }
        if shape.usesAngle && !near(includedAngle, other.includedAngle, 0.01) { return false }
        if shape.isTapered && !near(tipDiameter, other.tipDiameter) { return false }
        switch shape {
        case .taperedBallNose:
            if !near(tipDiameter, other.tipDiameter) || !near(includedAngle, other.includedAngle, 0.01) { return false }
        case .dovetail:
            if !near(includedAngle, other.includedAngle, 0.01) || !near(fluteLength, other.fluteLength) { return false }
        case .form:
            let a = cuttingEdge, b = other.cuttingEdge
            if a.count != b.count || zip(a, b).contains(where: { !near($0.x, $1.x) || !near($0.y, $1.y) }) { return false }
        default:
            break
        }
        return true
    }
}
