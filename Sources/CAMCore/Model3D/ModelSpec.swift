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
    /// Set when the model sits on a rotary blank, with one of its axes along the rotation axis (see
    /// `RotaryPlacement`); `upAxis`, `flipped`, `depth` and `topOffset` then don't apply. nil places it flat on the
    /// sheet, as in every file before rotary 3D finishing.
    public var rotary: RotaryPlacement?

    public init(mesh: MeshModel, upAxis: UpAxis = .z, flipped: Bool = false, depth: Double, topOffset: Double = 0,
                rotary: RotaryPlacement? = nil) {
        self.mesh = mesh
        self.upAxis = upAxis
        self.flipped = flipped
        self.depth = depth
        self.topOffset = topOffset
        self.rotary = rotary
    }

    /// The project file format this model needs: placed on a rotary blank it's format 7, since an older build would
    /// lay it flat on the sheet.
    public var requiredFormatVersion: Int { rotary == nil ? 1 : 7 }

    /// The model laid along the rotation axis and centred on it (cached; see `RotaryPlacement`), its longest axis
    /// along the blank when it has no placement.
    public var alongAxis: RotaryMesh { ModelGeometry.rotary(mesh, placement: rotary ?? RotaryPlacement(longestOf: mesh)) }

    /// Oriented, XY-centred mesh with its lowest point at z = 0 (cached).
    public var oriented: OrientedMesh { ModelGeometry.oriented(self) }

    /// Natural (unscaled) size of the oriented model in mm.
    public var naturalSize: SIMD3<Double> { SIMD3<Double>(oriented.size) }

    /// Depth that keeps the model's true proportions at XY scale `scale`.
    public func proportionalDepth(scale: Double) -> Double { naturalSize.z * scale }

    /// Design-space Z of the bottom of the carved model.
    public var bottomZ: Double { -topOffset - depth }
}

/// How a 3D model sits on a rotary blank (rotary 3D finishing): one of its own axes runs along the rotation axis
/// (machine X), its cross-sections are centred on that axis (the middle of their bounding box is on it), and it can be
/// turned end for end and about the axis. Its place along the blank (the middle of its length) and its size come from
/// the owning shape's `position.x` and `scale`; the shape's `position.y` and `rotation` are kept on the axis and at 0
/// (`Project.placeModelsOnBlank()`), and the toolpaths ignore them.
///
/// The blank's own frame, used by the rotary toolpaths: x along the axis (design X), y and z across it with the axis
/// at y = z = 0, as the blank is at A0 (+z straight up at the spindle, +y toward the sheet's +Y). A positive `turn`
/// rolls the model's top toward −Y, as a positive A turn rolls the blank.
public struct RotaryPlacement: Hashable, Codable, Sendable {
    /// The model's own axis that lies along the blank.
    public var alongAxis: UpAxis
    /// End for end: the model's far end (along `alongAxis`) toward the chuck, at low X.
    public var reversed: Bool
    /// Turn about the rotation axis, degrees (right-hand rule about +X).
    public var turn: Double

    public init(alongAxis: UpAxis = .x, reversed: Bool = false, turn: Double = 0) {
        self.alongAxis = alongAxis
        self.reversed = reversed
        self.turn = turn
    }

    /// The model's longest axis along the blank: how a turning is usually drawn.
    public init(longestOf mesh: MeshModel) {
        let b = mesh.bounds
        let size = b.max - b.min
        self.init(alongAxis: size.x >= size.y && size.x >= size.z ? .x : (size.y >= size.z ? .y : .z))
    }

    /// Room left between a model scaled to fit and each end of the blank, mm: the cutter has to stay clear of the
    /// chuck's jaws and the tailstock.
    public static let endClearance = 0.5.inch

    /// The scale that fits `mesh` to `blank`: as wide as the blank is round (across its faces on a square bar), and no
    /// longer than the blank less `endClearance` at each end.
    public static func fitScale(_ mesh: RotaryMesh, blank: RotaryStock) -> Double {
        var s = Double.infinity
        if mesh.maxRadius > 0 { s = blank.radius / Double(mesh.maxRadius) }
        if mesh.length > 0 { s = min(s, max(1, blank.length - 2 * endClearance) / Double(mesh.length)) }
        return s.isFinite && s > 0 ? s : 1
    }

    /// Maps a source vertex so `alongAxis` becomes +X, keeping the frame right-handed (a cyclic swap of the axes),
    /// then turns it end for end about Z when `reversed`.
    func orient(_ v: SIMD3<Float>) -> SIMD3<Float> {
        var o: SIMD3<Float>
        switch alongAxis {
        case .x: o = v
        case .y: o = SIMD3(v.y, v.z, v.x)
        case .z: o = SIMD3(v.z, v.x, v.y)
        }
        if reversed { o = SIMD3(-o.x, -o.y, o.z) }
        return o
    }
}

/// A mesh laid along the rotation axis (see `RotaryPlacement`), before its scale, turn and place along the blank:
/// the middle of its length at x = 0 and its cross-sections centred on the axis (y = z = 0).
public struct RotaryMesh: Sendable {
    public let positions: [SIMD3<Float>]
    public let indices: [UInt32]
    /// Length along the axis, mm.
    public let length: Float
    /// Farthest any point reaches from the axis, mm.
    public let maxRadius: Float
    /// Farthest the model reaches from the axis in each of `slices` equal slices along its length, mm: its outline
    /// seen from the side, whichever way it's turned.
    public let profile: [Float]

    /// Number of slices in `profile`.
    static let slices = 400

    /// The outline from the side as a closed loop in the shape's local coordinates (x along the axis, y across it),
    /// for drawing on the sheet.
    public var outline: [Polyline] {
        guard length > 0, !profile.isEmpty else { return [] }
        let n = profile.count
        let step = Double(length) / Double(n)
        let x0 = -Double(length) / 2
        var top: [Vec2] = []
        for i in 0..<n {
            let r = Double(profile[i])
            top.append(Vec2(x0 + Double(i) * step, r))
            top.append(Vec2(x0 + Double(i + 1) * step, r))
        }
        let bottom = top.reversed().map { Vec2($0.x, -$0.y) }
        let loop = Polyline(top + bottom, closed: true).simplified(tolerance: max(0.01, Double(maxRadius) / 400))
        return loop.count >= 3 ? [loop] : []
    }

    /// Distance from the axis, mm, the model reaches at `x` along its length (measured from its middle, unscaled).
    public func profileRadius(at x: Double) -> Double {
        guard length > 0, !profile.isEmpty else { return 0 }
        let i = Int(((x + Double(length) / 2) / Double(length) * Double(profile.count)).rounded(.down))
        return Double(profile[max(0, min(profile.count - 1, i))])
    }

    init(mesh m: MeshModel, placement: RotaryPlacement) {
        var pts = [SIMD3<Float>](repeating: .zero, count: m.vertexCount)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<m.vertexCount {
            let p = placement.orient(m.vertex(i))
            pts[i] = p
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        if m.vertexCount == 0 { lo = .zero; hi = .zero }
        let shift = (lo + hi) / 2
        var far: Float = 0
        for i in pts.indices {
            pts[i] -= shift
            far = max(far, (pts[i].y * pts[i].y + pts[i].z * pts[i].z).squareRoot())
        }
        positions = pts
        indices = m.indices
        length = hi.x - lo.x
        maxRadius = far
        // The side outline: the farthest each slice reaches. Distance from the axis is convex, so over the part of a
        // triangle inside a slice it peaks on the triangle's edges: at a vertex, or where an edge crosses into the slice.
        let n = Self.slices
        var prof = [Float](repeating: 0, count: n)
        let len = max(length, 1e-6), half = length / 2
        func slice(_ x: Float) -> Int { max(0, min(n - 1, Int(((x + half) / len * Float(n)).rounded(.down)))) }
        func radius(_ p: SIMD3<Float>) -> Float { (p.y * p.y + p.z * p.z).squareRoot() }
        var t = 0
        let idx = m.indices
        while t + 2 < idx.count {
            for k in 0..<3 {
                let a = pts[Int(idx[t + k])], b = pts[Int(idx[t + (k + 1) % 3])]
                let sa = slice(a.x), sb = slice(b.x)
                prof[sa] = max(prof[sa], radius(a))
                prof[sb] = max(prof[sb], radius(b))
                guard sa != sb, abs(b.x - a.x) > 1e-9 else { continue }
                // Where the edge crosses each slice boundary, the slices either side get its distance there.
                for s in (min(sa, sb) + 1)...max(sa, sb) {
                    let xb = -half + Float(s) * len / Float(n)
                    let f = (xb - a.x) / (b.x - a.x)
                    let r = radius(a + (b - a) * f)
                    prof[s - 1] = max(prof[s - 1], r)
                    prof[s] = max(prof[s], r)
                }
            }
            t += 3
        }
        profile = prof
    }
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

    private struct RotaryKey: Hashable { let id: UUID; let along: UpAxis; let reversed: Bool }
    private final class RotaryStore: @unchecked Sendable {
        let lock = NSLock()
        var entries: [RotaryKey: RotaryMesh] = [:]
    }
    private static let rotaryStore = RotaryStore()

    /// `mesh` laid along the rotation axis as `placement` says (all but its turn, which is applied with the scale).
    public static func rotary(_ mesh: MeshModel, placement: RotaryPlacement) -> RotaryMesh {
        let key = RotaryKey(id: mesh.id, along: placement.alongAxis, reversed: placement.reversed)
        rotaryStore.lock.lock()
        if let hit = rotaryStore.entries[key] { rotaryStore.lock.unlock(); return hit }
        rotaryStore.lock.unlock()
        let made = RotaryMesh(mesh: mesh, placement: placement)
        rotaryStore.lock.lock()
        if rotaryStore.entries.count > 64 { rotaryStore.entries.removeAll() }
        rotaryStore.entries[key] = made
        rotaryStore.lock.unlock()
        return made
    }

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

    /// A model on a rotary blank: where it starts and ends along the blank (design X) and how far it reaches from the
    /// axis, mm, at the shape's scale. nil for other shapes.
    var rotaryExtent: (minX: Double, maxX: Double, radius: Double)? {
        guard let spec = modelSpec else { return nil }
        let m = spec.alongAxis
        let half = Double(m.length) / 2 * scale
        return (position.x - half, position.x + half, Double(m.maxRadius) * scale)
    }

    /// Visits every triangle of a model in the rotary blank's frame (see `RotaryPlacement`): x along the axis in
    /// design X, y and z across it with the axis at y = z = 0 and the blank at A0. The model is laid along the axis as
    /// its placement says (its longest axis along it when it has none), scaled, turned and moved along the blank to
    /// `position.x`.
    func forEachBlankTriangle(_ body: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) -> Void) {
        guard let spec = modelSpec else { return }
        let m = spec.alongAxis
        let s = scale, x0 = position.x
        let t = (spec.rotary?.turn ?? 0) * .pi / 180
        let c = cos(t), sn = sin(t)
        func map(_ p: SIMD3<Float>) -> SIMD3<Double> {
            let y = Double(p.y) * s, z = Double(p.z) * s
            return SIMD3(Double(p.x) * s + x0, y * c - z * sn, y * sn + z * c)
        }
        let idx = m.indices
        var i = 0
        while i + 2 < idx.count {
            body(map(m.positions[Int(idx[i])]), map(m.positions[Int(idx[i + 1])]), map(m.positions[Int(idx[i + 2])]))
            i += 3
        }
    }

    /// A model's footprint from its mesh, design XY: what its toolpaths cut to. `bounds` is its outline's, traced from a
    /// grid of cells about 1/400 of the model across, so up to a cell larger. On a rotary blank, the outline's bounds
    /// (along the axis); nil for other shapes.
    var modelBounds: Rect2? {
        guard let spec = modelSpec else { return nil }
        guard spec.rotary == nil else { return bounds }
        var box = Rect2.empty
        forEachModelTriangle { a, b, c in
            for v in [a, b, c] { box = box.union(Vec2(v.x, v.y)) }
        }
        return box
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
