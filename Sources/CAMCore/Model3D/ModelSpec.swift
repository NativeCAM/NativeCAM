import Foundation
import simd

/// A 3D model placed on the stock. XY placement, rotation and uniform XY scale come from the owning `DesignShape`;
/// this spec decides orientation and how deep the model is carved.
public struct ModelSpec: Hashable, Codable, Sendable {
    public var mesh: MeshModel
    /// Source axis that should point up (away from the table).
    public var upAxis: UpAxis
    /// Turn the model upside down (after applying `upAxis`).
    public var flipped: Bool
    /// Z thickness of the carved model, from its highest to its lowest point (mm).
    public var depth: Double
    /// How far below the material top the model's highest point sits (mm, >= 0).
    public var topOffset: Double

    public init(mesh: MeshModel, upAxis: UpAxis = .z, flipped: Bool = false, depth: Double, topOffset: Double = 0) {
        self.mesh = mesh
        self.upAxis = upAxis
        self.flipped = flipped
        self.depth = depth
        self.topOffset = topOffset
    }

    /// Oriented, XY-centred mesh with its lowest point at z = 0 (cached).
    public var oriented: OrientedMesh { ModelGeometry.oriented(self) }

    /// Natural (unscaled) size of the oriented model in mm.
    public var naturalSize: SIMD3<Double> { SIMD3<Double>(oriented.size) }

    /// Depth that keeps the model's true proportions at XY scale `scale`.
    public func proportionalDepth(scale: Double) -> Double { naturalSize.z * scale }

    /// Design-space Z of the bottom of the carved model.
    public var bottomZ: Double { -topOffset - depth }
}

/// Mesh re-oriented to Z-up, centred on the XY origin, lowest point at z = 0.
public struct OrientedMesh: Sendable {
    public let positions: [SIMD3<Float>]
    public let indices: [UInt32]
    /// Width (X), height (Y), thickness (Z).
    public let size: SIMD3<Float>
    /// Outline of the model seen from above, in the same local coordinates.
    public let silhouette: [Polyline]
}

/// Process-wide cache for oriented meshes and silhouettes (meshes are immutable, keyed by id + orientation).
public enum ModelGeometry {
    private struct Key: Hashable { let id: UUID; let up: UpAxis; let flipped: Bool }
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var entries: [Key: OrientedMesh] = [:]
    }
    private static let store = Store()

    public static func oriented(_ spec: ModelSpec) -> OrientedMesh {
        let key = Key(id: spec.mesh.id, up: spec.upAxis, flipped: spec.flipped)
        store.lock.lock()
        if let hit = store.entries[key] { store.lock.unlock(); return hit }
        store.lock.unlock()
        let made = build(spec)
        store.lock.lock()
        if store.entries.count > 64 { store.entries.removeAll() }
        store.entries[key] = made
        store.lock.unlock()
        return made
    }

    /// Maps a source vertex so `up` becomes +Z (right-handed rotations), optionally flipped 180° about Y.
    static func orient(_ v: SIMD3<Float>, up: UpAxis, flipped: Bool) -> SIMD3<Float> {
        var o: SIMD3<Float>
        switch up {
        case .z: o = v
        case .y: o = SIMD3(v.x, -v.z, v.y)   // +90° about X
        case .x: o = SIMD3(-v.z, v.y, v.x)   // -90° about Y
        }
        if flipped { o = SIMD3(-o.x, o.y, -o.z) }
        return o
    }

    private static func build(_ spec: ModelSpec) -> OrientedMesh {
        let m = spec.mesh
        var pts = [SIMD3<Float>](repeating: .zero, count: m.vertexCount)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<m.vertexCount {
            let p = orient(m.vertex(i), up: spec.upAxis, flipped: spec.flipped)
            pts[i] = p
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        if m.vertexCount == 0 { lo = .zero; hi = .zero }
        let shift = SIMD3<Float>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z)
        for i in pts.indices { pts[i] -= shift }
        let size = hi - lo
        // Silhouette: rasterise the footprint at ~400 cells across and trace it.
        var silhouette: [Polyline] = []
        let maxDim = Double(max(size.x, size.y))
        if maxDim > 0 {
            let cell = maxDim / 400
            let area = Rect2(min: Vec2(Double(-size.x / 2) - cell * 2, Double(-size.y / 2) - cell * 2),
                             max: Vec2(Double(size.x / 2) + cell * 2, Double(size.y / 2) + cell * 2))
            var grid = SurfaceGrid(area: area, cellSize: cell)
            grid.rasterize(positions: pts, indices: m.indices) { $0 }
            silhouette = GridContours.loops(mask: grid.covered, columns: grid.columns, rows: grid.rows,
                                            origin: grid.origin, cellSize: cell)
                .map { $0.simplified(tolerance: cell * 0.6) }
                .filter { $0.count >= 3 }
        }
        return OrientedMesh(positions: pts, indices: m.indices, size: size, silhouette: silhouette)
    }
}

public extension DesignShape {
    var modelSpec: ModelSpec? {
        if case let .model(spec) = kind { return spec }
        return nil
    }

    /// Visits every triangle of a model shape in design coordinates (Z relative to the material top).
    func forEachModelTriangle(_ body: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) -> Void) {
        guard let spec = modelSpec else { return }
        let o = spec.oriented
        let t = transform
        let H = Double(o.size.z)
        let zScale = H > 0 ? spec.depth / H : 0
        func map(_ p: SIMD3<Float>) -> SIMD3<Double> {
            let xy = t.apply(Vec2(Double(p.x), Double(p.y)))
            return SIMD3(xy.x, xy.y, -spec.topOffset - (H - Double(p.z)) * zScale)
        }
        let idx = o.indices
        var i = 0
        while i + 2 < idx.count {
            body(map(o.positions[Int(idx[i])]), map(o.positions[Int(idx[i + 1])]), map(o.positions[Int(idx[i + 2])]))
            i += 3
        }
    }
}
