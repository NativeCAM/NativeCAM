import Foundation

/// Where the machine's X0 Y0 sits relative to the material.
public enum XYOrigin: String, Codable, Sendable, CaseIterable, Identifiable {
    case lowerLeft, lowerRight, upperLeft, upperRight, center
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .lowerLeft: "Lower left"
        case .lowerRight: "Lower right"
        case .upperLeft: "Upper left"
        case .upperRight: "Upper right"
        case .center: "Center"
        }
    }
}

/// Where Z0 is touched off: top of the material (touch plate on the stock) or the machine bed / spoilboard.
public enum ZZero: String, Codable, Sendable, CaseIterable, Identifiable {
    case materialTop, machineBed
    public var id: String { rawValue }
    public var label: String { self == .materialTop ? "Material top" : "Spoilboard" }
}

/// How designs map onto a rotary blank.
public enum RotaryLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Indexed (3+1): the design sheet is one flat face, and the blank turns to fixed angles between cuts.
    case faces
    /// Wrapped: the design sheet is the blank's surface unrolled, and design Y turns into the A angle as the tool
    /// cuts, so A moves together with X and Z.
    case wrapped
    public var id: String { rawValue }
    public var label: String { self == .faces ? "On faces" : "Wrapped around" }
}

/// A blank turned on a rotary axis: a round dowel or a square bar held in the chuck, with its rotation axis along
/// machine X.
///
/// Rotary jobs put Z zero on the rotation axis, as Avid's Rotary tab (Z Axis Touch), Vectric ("Center of
/// Cylinder") and Fusion all recommend, so a Z value on the machine is a distance from the axis. Touching off on
/// the top of the blank instead would drive the tool a radius too deep.
public struct RotaryStock: Hashable, Codable, Sendable {
    public enum Shape: String, Codable, Sendable, CaseIterable, Identifiable {
        case cylinder, squareBar
        public var id: String { rawValue }
        public var label: String { self == .cylinder ? "Round" : "Square bar" }
    }

    public var shape: Shape
    /// Diameter of a round blank, or the width across the faces of a square bar, mm.
    public var diameter: Double
    /// Length along the rotation axis (machine X), mm.
    public var length: Double
    /// How designs map onto the blank (nil = on faces, as in every file before wrapped jobs).
    public var layout: RotaryLayout?
    /// Wrapped jobs: the diameter the flat design wraps around, where it comes out true to size, mm. nil = the
    /// blank's diameter; set it to the finished size when the blank is rounded down first.
    public var wrapDiameter: Double?

    public init(shape: Shape = .cylinder, diameter: Double = 2.inch, length: Double = 12.inch, layout: RotaryLayout? = nil,
                wrapDiameter: Double? = nil) {
        self.shape = shape
        self.diameter = diameter
        self.length = length
        self.layout = layout
        self.wrapDiameter = wrapDiameter
    }

    /// True when designs wrap around the blank rather than sit on its faces.
    public var isWrapped: Bool { layout == .wrapped }

    /// The diameter a wrapped design is drawn at: `wrapDiameter`, or the blank's own diameter.
    public var wrapDiameterOrBlank: Double { wrapDiameter.flatMap { $0 > 0 ? $0 : nil } ?? diameter }

    /// Distance from the axis to Z = 0 of the design sheet, mm: the wrap radius on a wrapped job, the top of a face
    /// (the blank's radius) on a faces job.
    public var topRadius: Double { isWrapped ? wrapDiameterOrBlank / 2 : radius }

    /// Height of a wrapped job's unrolled sheet: once around the blank at the wrap diameter, mm.
    public var circumference: Double { .pi * wrapDiameterOrBlank }

    /// Distance from the axis to the nearest point of the surface (the middle of a face on a square bar), mm.
    public var radius: Double { diameter / 2 }

    /// Distance from the axis to the farthest point of the blank (a square bar's corners), mm. The tool has to stay
    /// outside this whenever the rotary axis turns.
    public var outerRadius: Double { shape == .cylinder ? radius : radius * 2.0.squareRoot() }

    /// Distance from the axis to the surface in the direction `degrees` around it, mm. 0° points straight up at A0,
    /// where a square bar has a face square to the spindle.
    public func surfaceRadius(atDegrees degrees: Double) -> Double {
        guard shape == .squareBar else { return radius }
        let t = degrees * .pi / 180
        return radius / max(abs(cos(t)), abs(sin(t)))
    }
}

/// The blank being cut. Design coordinates have (0,0) at the material's lower-left corner;
/// toolpath Z = 0 is the material's top surface and Z = -thickness is its bottom.
///
/// On rotary stock laid out on faces, the design sheet is one face of the blank as the spindle sees it: X runs along
/// the rotation axis (0 to the blank's length), Y across the face (0 to its diameter, with the axis under
/// y = diameter / 2), and Z = 0 is the top of the face, a radius above the axis. Indexed toolpaths cut that sheet with
/// the blank turned to each of their angles.
///
/// On a wrapped job the sheet is the blank's surface unrolled: X along the axis, Y once around the blank at the wrap
/// diameter (0 to π × D), and Z = 0 at the wrap diameter. The line across the middle of the sheet is the top of the
/// blank at A0, and the seam is along its top and bottom edges. `setRotary(_:)` keeps width, height and thickness
/// matched to the blank.
public struct Stock: Hashable, Codable, Sendable {
    /// X size, mm.
    public var width: Double
    /// Y size, mm.
    public var height: Double
    /// Material thickness (Z), mm.
    public var thickness: Double
    public var materialName: String
    /// Material family for chip-load guidance (nil in older files means plywood).
    public var materialKind: MaterialKind?
    public var material: MaterialKind { materialKind ?? .plywood }
    public var xyOrigin: XYOrigin
    public var zZero: ZZero
    /// Rapid-safe height above the material top for moves between cuts (Vectric's "Clearance Z1").
    public var clearanceHeight: Double
    /// Height above the material top where rapids stop and plunge feed begins ("Plunge Z2").
    public var plungeHeight: Double
    /// Park position at program end, in design coordinates (XY) and height above material (Z). Rotary jobs only use
    /// its height: see `parkPosition`.
    public var homePosition: Vec3
    /// How the tool travels between cuts (nil = minimum retracts).
    public var retractMode: RetractMode?
    /// Minimum-retract links keep at least this much above remaining material, mm (nil = 0.2 in).
    public var linkSafeDistance: Double?
    /// Set when the blank turns on a rotary axis (nil = a flat sheet, as in every older file). Set it with
    /// `setRotary(_:)`, which also sizes the design sheet to one face of the blank.
    public var rotary: RotaryStock?

    public var retract: RetractMode { retractMode ?? .minimum }
    public var safeDistance: Double { linkSafeDistance ?? 0.2.inch }

    /// The project file format this stock needs. Rotary stock is format 3: every build that reads format 2 would
    /// drop it and post the job as a flat sheet. A wrapped layout is format 4: a format-3 build would read the
    /// unrolled sheet as one face and cut it indexed.
    public var requiredFormatVersion: Int {
        guard let rotary else { return 1 }
        return rotary.isWrapped ? 4 : 3
    }

    public init(width: Double = 24.inch, height: Double = 18.inch, thickness: Double = 0.75.inch,
                materialName: String = "Plywood", xyOrigin: XYOrigin = .lowerLeft, zZero: ZZero = .materialTop,
                clearanceHeight: Double = 0.5.inch, plungeHeight: Double = 0.1.inch,
                homePosition: Vec3 = Vec3(0, 0, 1.0.inch), materialKind: MaterialKind? = nil) {
        self.materialKind = materialKind
        self.width = width
        self.height = height
        self.thickness = thickness
        self.materialName = materialName
        self.xyOrigin = xyOrigin
        self.zZero = zZero
        self.clearanceHeight = clearanceHeight
        self.plungeHeight = plungeHeight
        self.homePosition = homePosition
    }

    public var bounds: Rect2 { Rect2(x: 0, y: 0, width: width, height: height) }

    /// Where the tool parks at the end and for a manual tool change: `homePosition`, no lower than safe Z. On rotary
    /// stock it parks over the middle of the blank, since the chuck's jaws and the tailstock stand above the blank's
    /// ends and the sheet's corners are right at them.
    public var parkPosition: Vec3 {
        let z = max(homePosition.z, clearanceHeight)
        return rotary == nil ? Vec3(homePosition.xy, z) : Vec3(width / 2, height / 2, z)
    }

    /// Turns the job into a rotary one on `blank` (or back to a flat sheet with nil). On faces, the design sheet
    /// becomes one face of the blank (width = length, height = diameter, thickness = radius, so a cut to the full
    /// thickness reaches the axis). Wrapped, it becomes the surface unrolled at the wrap diameter (height =
    /// circumference, thickness = wrap radius). Safe Z rises if it wouldn't clear the blank's corners as it turns.
    public mutating func setRotary(_ blank: RotaryStock?) {
        rotary = blank
        guard let blank else { return }
        width = blank.length
        height = blank.isWrapped ? blank.circumference : blank.diameter
        thickness = blank.topRadius
        if let least = minimumRotaryClearance { clearanceHeight = max(clearanceHeight, least) }
    }

    /// Distance from the rotation axis to Z = 0 of the design sheet on rotary stock (see `RotaryStock.topRadius`);
    /// nil on a flat sheet.
    public var topRadius: Double? { rotary?.topRadius }

    /// The lowest safe Z for a rotary job, above the sheet's Z = 0: the blank turns at safe Z, so the tool has to
    /// clear its corners (a square bar's reach past its faces, or a blank wider than the wrap diameter) by the link
    /// safe distance. Nil on a flat sheet.
    public var minimumRotaryClearance: Double? {
        rotary.map { $0.outerRadius - $0.topRadius + safeDistance }
    }

    /// True when width, height and thickness describe the rotary blank's design sheet (always true on a flat sheet).
    public var matchesRotaryBlank: Bool {
        guard let r = rotary else { return true }
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 * max(1, abs(b)) }
        return same(width, r.length) && same(height, r.isWrapped ? r.circumference : r.diameter) && same(thickness, r.topRadius)
    }

    /// Design-space point that the machine's X0 Y0 corresponds to. On rotary stock Y zero is always the axis
    /// centreline, and X zero is the left end, the right end or the middle, from `xyOrigin`.
    public var originPoint: Vec2 {
        if rotary != nil {
            switch xyOrigin {
            case .lowerLeft, .upperLeft: return Vec2(0, height / 2)
            case .lowerRight, .upperRight: return Vec2(width, height / 2)
            case .center: return Vec2(width / 2, height / 2)
            }
        }
        return switch xyOrigin {
        case .lowerLeft: Vec2(0, 0)
        case .lowerRight: Vec2(width, 0)
        case .upperLeft: Vec2(0, height)
        case .upperRight: Vec2(width, height)
        case .center: Vec2(width / 2, height / 2)
        }
    }

    /// Converts a toolpath point (design XY, Z relative to material top) into work coordinates (G54). Rotary jobs
    /// zero Z on the rotation axis whatever `zZero` says, so work Z is the toolpath Z plus the sheet's top radius
    /// (the blank's radius on faces, the wrap radius when wrapped). On a wrapped job Y is still the sheet's: the
    /// posts turn it into an A angle (`RotaryWrap`) and keep the tool over the axis.
    public func toWork(_ p: Vec3) -> Vec3 {
        let o = originPoint
        let z = rotary.map { p.z + $0.topRadius } ?? (zZero == .materialTop ? p.z : p.z + thickness)
        return Vec3(p.x - o.x, p.y - o.y, z)
    }

    /// Inverse of `toWork`.
    public func fromWork(_ p: Vec3) -> Vec3 {
        let o = originPoint
        let z = rotary.map { p.z - $0.topRadius } ?? (zZero == .materialTop ? p.z : p.z - thickness)
        return Vec3(p.x + o.x, p.y + o.y, z)
    }

}
