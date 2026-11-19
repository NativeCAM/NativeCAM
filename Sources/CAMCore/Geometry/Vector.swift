import Foundation

/// 2D point/vector in millimetres (CAMCore works in mm internally; units are converted at the edges).
public struct Vec2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Vec2(0, 0)

    @inlinable public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    @inlinable public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    @inlinable public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    @inlinable public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    @inlinable public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    @inlinable public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// z-component of the 3D cross product; > 0 when `o` is counter-clockwise from `self`.
    @inlinable public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    @inlinable public var lengthSquared: Double { x * x + y * y }
    @inlinable public var length: Double { (x * x + y * y).squareRoot() }
    @inlinable public var normalized: Vec2 {
        let l = length
        return l > 1e-15 ? Vec2(x / l, y / l) : .zero
    }
    /// Left-hand perpendicular (rotated +90°).
    @inlinable public var perpLeft: Vec2 { Vec2(-y, x) }
    /// Right-hand perpendicular (rotated -90°).
    @inlinable public var perpRight: Vec2 { Vec2(y, -x) }
    @inlinable public var angle: Double { atan2(y, x) }
    @inlinable public func distance(to o: Vec2) -> Double { (self - o).length }
    @inlinable public func distanceSquared(to o: Vec2) -> Double { (self - o).lengthSquared }
    @inlinable public func lerp(to o: Vec2, _ t: Double) -> Vec2 { Vec2(x + (o.x - x) * t, y + (o.y - y) * t) }
    @inlinable public func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }
    @inlinable public static func fromAngle(_ a: Double, length: Double = 1) -> Vec2 { Vec2(cos(a) * length, sin(a) * length) }

    public func isApprox(_ o: Vec2, tolerance: Double = 1e-9) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance
    }

    public var description: String { String(format: "(%.4f, %.4f)", x, y) }
}

/// 3D point in millimetres. In toolpaths, z = 0 is the top of the material and negative z is into it.
public struct Vec3: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public init(_ xy: Vec2, _ z: Double) { self.x = xy.x; self.y = xy.y; self.z = z }

    public static let zero = Vec3(0, 0, 0)

    @inlinable public var xy: Vec2 { Vec2(x, y) }
    @inlinable public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    @inlinable public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    @inlinable public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    @inlinable public var length: Double { (x * x + y * y + z * z).squareRoot() }
    @inlinable public func distance(to o: Vec3) -> Double { (self - o).length }
    @inlinable public func lerp(to o: Vec3, _ t: Double) -> Vec3 {
        Vec3(x + (o.x - x) * t, y + (o.y - y) * t, z + (o.z - z) * t)
    }

    public var description: String { String(format: "(%.4f, %.4f, %.4f)", x, y, z) }
}

/// Axis-aligned 2D rectangle.
public struct Rect2: Hashable, Codable, Sendable {
    public var min: Vec2
    public var max: Vec2

    public init(min: Vec2, max: Vec2) { self.min = min; self.max = max }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.min = Vec2(x, y); self.max = Vec2(x + width, y + height)
    }

    /// An "inverted" rectangle that any union will replace.
    public static let empty = Rect2(min: Vec2(.infinity, .infinity), max: Vec2(-.infinity, -.infinity))

    public var isEmpty: Bool { min.x > max.x || min.y > max.y }
    public var width: Double { Swift.max(0, max.x - min.x) }
    public var height: Double { Swift.max(0, max.y - min.y) }
    public var center: Vec2 { (min + max) * 0.5 }
    public var size: Vec2 { Vec2(width, height) }

    public func union(_ p: Vec2) -> Rect2 {
        Rect2(min: Vec2(Swift.min(min.x, p.x), Swift.min(min.y, p.y)),
              max: Vec2(Swift.max(max.x, p.x), Swift.max(max.y, p.y)))
    }
    public func union(_ r: Rect2) -> Rect2 {
        if r.isEmpty { return self }
        if isEmpty { return r }
        return union(r.min).union(r.max)
    }
    public func insetBy(_ d: Double) -> Rect2 { Rect2(min: min + Vec2(d, d), max: max - Vec2(d, d)) }
    public func contains(_ p: Vec2, tolerance: Double = 0) -> Bool {
        p.x >= min.x - tolerance && p.x <= max.x + tolerance && p.y >= min.y - tolerance && p.y <= max.y + tolerance
    }
    public func intersects(_ r: Rect2) -> Bool {
        !(r.min.x > max.x || r.max.x < min.x || r.min.y > max.y || r.max.y < min.y)
    }
}

/// 2D affine transform: p' = (a*x + c*y + tx, b*x + d*y + ty).
public struct Transform2D: Hashable, Codable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Transform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public static func translation(_ v: Vec2) -> Transform2D { Transform2D(a: 1, b: 0, c: 0, d: 1, tx: v.x, ty: v.y) }
    public static func scale(_ sx: Double, _ sy: Double) -> Transform2D { Transform2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    public static func rotation(_ radians: Double) -> Transform2D {
        let co = cos(radians), si = sin(radians)
        return Transform2D(a: co, b: si, c: -si, d: co, tx: 0, ty: 0)
    }

    public func apply(_ p: Vec2) -> Vec2 { Vec2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }

    /// Returns the transform that applies `self` first, then `other`.
    public func then(_ o: Transform2D) -> Transform2D {
        Transform2D(a: o.a * a + o.c * b, b: o.b * a + o.d * b,
                    c: o.a * c + o.c * d, d: o.b * c + o.d * d,
                    tx: o.a * tx + o.c * ty + o.tx, ty: o.b * tx + o.d * ty + o.ty)
    }

    public var determinant: Double { a * d - b * c }
    /// Uniform scale estimate (used for curve flattening tolerance).
    public var approximateScale: Double { sqrt(abs(determinant)) }
}

public extension Double {
    /// Degrees → radians.
    var radians: Double { self * .pi / 180 }
    /// Radians → degrees.
    var degrees: Double { self * 180 / .pi }
}
