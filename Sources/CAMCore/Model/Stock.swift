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

    public init(shape: Shape = .cylinder, diameter: Double = 2.inch, length: Double = 12.inch) {
        self.shape = shape
        self.diameter = diameter
        self.length = length
    }

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
    /// Park position at program end, in design coordinates (XY) and height above material (Z).
    public var homePosition: Vec3
    /// How the tool travels between cuts (nil = minimum retracts).
    public var retractMode: RetractMode?
    /// Minimum-retract links keep at least this much above remaining material, mm (nil = 0.2 in).
    public var linkSafeDistance: Double?
    /// Set when the blank turns on a rotary axis (nil = a flat sheet, as in every older file). Nothing machines
    /// rotary stock yet: toolpaths still treat the blank as the flat width × height × thickness block, and the job
    /// checks say so.
    public var rotary: RotaryStock?

    public var retract: RetractMode { retractMode ?? .minimum }
    public var safeDistance: Double { linkSafeDistance ?? 0.2.inch }

    /// The project file format this stock needs. Rotary stock is format 3: every build that reads format 2 would
    /// drop it and post the job as a flat sheet.
    public var requiredFormatVersion: Int { rotary == nil ? 1 : 3 }

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

    /// Design-space point that the machine's X0 Y0 corresponds to.
    public var originPoint: Vec2 {
        switch xyOrigin {
        case .lowerLeft: Vec2(0, 0)
        case .lowerRight: Vec2(width, 0)
        case .upperLeft: Vec2(0, height)
        case .upperRight: Vec2(width, height)
        case .center: Vec2(width / 2, height / 2)
        }
    }

    /// Converts a toolpath point (design XY, Z relative to material top) into work coordinates (G54).
    public func toWork(_ p: Vec3) -> Vec3 {
        let o = originPoint
        let z = zZero == .materialTop ? p.z : p.z + thickness
        return Vec3(p.x - o.x, p.y - o.y, z)
    }

    /// Inverse of `toWork`.
    public func fromWork(_ p: Vec3) -> Vec3 {
        let o = originPoint
        let z = zZero == .materialTop ? p.z : p.z - thickness
        return Vec3(p.x + o.x, p.y + o.y, z)
    }
}
