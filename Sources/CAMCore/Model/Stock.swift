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
    public var xyOrigin: XYOrigin
    public var zZero: ZZero
    /// Rapid-safe height above the material top for moves between cuts (Vectric's "Clearance Z1").
    public var clearanceHeight: Double
    /// Height above the material top where rapids stop and plunge feed begins ("Plunge Z2").
    public var plungeHeight: Double
    /// Park position at program end, in design coordinates (XY) and height above material (Z).
    public var homePosition: Vec3

    public init(width: Double = 24.inch, height: Double = 18.inch, thickness: Double = 0.75.inch,
                materialName: String = "Plywood", xyOrigin: XYOrigin = .lowerLeft, zZero: ZZero = .materialTop,
                clearanceHeight: Double = 0.5.inch, plungeHeight: Double = 0.1.inch,
                homePosition: Vec3 = Vec3(0, 0, 1.0.inch)) {
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
