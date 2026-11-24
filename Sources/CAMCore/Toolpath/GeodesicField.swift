import Foundation
import simd

/// Geodesic distance over the cutter-location surface from the edge of an area, inward: how far the tool tip travels
/// along the CL surface (not in plan) to reach each node of a `CLMap`'s grid from the area's boundary.
///
/// It's worked out by fast marching on the grid's triangles in 3D (Kimmel and Sethian, "Computing geodesic paths on
/// manifolds", 1998): each node's eight neighbours make eight triangles round it, each right-angled in plan with a 45°
/// corner at the node, and the distance front is taken as planar across each triangle, falling back to the edges where
/// the front would come from outside it. On a grid this is accurate to a few percent in any direction, where a
/// Dijkstra walk over the same edges is up to 8% long between them.
///
/// Slopes steeper than `maxSlope` count as that slope. Over a vertical wall (where the tip's height jumps from the top
/// edge to the floor between two nodes) the passes would otherwise all land between those two nodes in plan, where
/// the drop-cutter can't put them anywhere but the top or the foot.
struct GeodesicField: Sendable {
    let origin: Vec2
    let pitch: Double
    let columns: Int
    let rows: Int
    /// Distance at each node inside the area (row-major); outside it, minus the plan distance to the boundary next to
    /// the area (so contours just inside it interpolate), and -3 cells beyond that.
    let distance: [Double]
    /// Nodes inside the area.
    let inside: [Bool]

    /// The largest distance inside the area (0 when it's empty).
    var maximum: Double { zip(distance, inside).reduce(0) { $1.1 ? max($0, $1.0) : $0 } }

    /// The field over `map`'s nodes for the area `inside` marks, whose edge is `boundary`. Nodes next to the edge
    /// start at their plan distance to it, so passes follow it to within the grid's interpolation rather than a cell.
    init(map: CLMap, inside: [Bool], boundary: [Polyline], maxSlope: Double = 75) {
        origin = map.origin
        pitch = map.pitch
        columns = map.columns
        rows = map.rows
        self.inside = inside
        let cols = columns, rws = rows, h = pitch
        let n = cols * rws
        let tanMax = tan(maxSlope * .pi / 180)
        let near = BoundaryDistance(boundary, bucket: 4 * h)
        var t = [Double](repeating: .infinity, count: n)
        // 0 far, 1 trial, 2 known.
        var state = [UInt8](repeating: 0, count: n)
        var heap = MinHeap()
        let offsets: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        func isInside(_ c: Int, _ r: Int) -> Bool { c >= 0 && r >= 0 && c < cols && r < rws && inside[r * cols + c] }
        // Seeds: inside nodes with a neighbour outside the area (or off the grid).
        for r in 0..<rws {
            for c in 0..<cols where inside[r * cols + c] {
                guard offsets.contains(where: { !isInside(c + $0.0, r + $0.1) }) else { continue }
                let i = r * cols + c
                t[i] = near.distance(to: map.node(c, r), within: 3 * h) ?? 0
                state[i] = 1
                heap.push(t[i], i)
            }
        }
        let z = map.z
        // The vector from node i to its neighbour (dc, dr), its rise held to the steepest slope counted.
        @inline(__always) func edge(_ i: Int, _ dc: Int, _ dr: Int) -> SIMD3<Double> {
            let dx = Double(dc) * h, dy = Double(dr) * h
            let run = (dx * dx + dy * dy).squareRoot()
            let rise = z[i + dr * cols + dc] - z[i]
            return SIMD3(dx, dy, max(-run * tanMax, min(run * tanMax, rise)))
        }
        func update(_ c: Int, _ r: Int) {
            let i = r * cols + c
            var best = t[i]
            var known: UInt8 = 0
            for (k, o) in offsets.enumerated() where isInside(c + o.0, r + o.1) {
                let j = (r + o.1) * cols + c + o.0
                guard state[j] == 2 else { continue }
                known |= 1 << k
                best = min(best, t[j] + simd_length(edge(i, o.0, o.1)))
            }
            for k in 0..<8 where known & (1 << k) != 0 && known & (1 << ((k + 1) % 8)) != 0 {
                let a = offsets[k], b = offsets[(k + 1) % 8]
                let ja = (r + a.1) * cols + c + a.0, jb = (r + b.1) * cols + c + b.0
                if let v = Self.triangle(edge(i, a.0, a.1), t[ja], edge(i, b.0, b.1), t[jb]) { best = min(best, v) }
            }
            if best < t[i] - 1e-12 {
                t[i] = best
                state[i] = 1
                heap.push(best, i)
            }
        }
        while let (v, i) = heap.pop() {
            guard state[i] != 2, v <= t[i] + 1e-12 else { continue }
            state[i] = 2
            let c = i % cols, r = i / cols
            for o in offsets where isInside(c + o.0, r + o.1) {
                let j = (r + o.1) * cols + c + o.0
                if state[j] != 2 { update(c + o.0, r + o.1) }
            }
        }
        // Outside: minus the plan distance next to the area, so a contour between an inside and an outside node lands
        // where the boundary puts it.
        for r in 0..<rws {
            for c in 0..<cols where !inside[r * cols + c] {
                let i = r * cols + c
                if offsets.contains(where: { isInside(c + $0.0, r + $0.1) }) {
                    t[i] = -(near.distance(to: map.node(c, r), within: 3 * h) ?? h)
                } else {
                    t[i] = -3 * h
                }
            }
        }
        for i in 0..<n where inside[i] && !t[i].isFinite { t[i] = 0 }
        distance = t
    }

    /// The distance at C from a triangle C, A, B whose corners A and B (at `a` and `b` from C) are known, taking the
    /// front as a plane across it; nil when the front would reach C from outside the triangle.
    static func triangle(_ a: SIMD3<Double>, _ ta: Double, _ b: SIMD3<Double>, _ tb: Double) -> Double? {
        let aa = simd_dot(a, a), bb = simd_dot(b, b), ab = simd_dot(a, b)
        let det = aa * bb - ab * ab
        guard det > 1e-18 else { return nil }
        // The gradient g at C meets g·a = ta - t and g·b = tb - t with |g| = 1: a quadratic in t.
        let qa = (aa + bb - 2 * ab) / det
        let qb = ((bb - ab) * ta + (aa - ab) * tb) / det
        let qc = (bb * ta * ta - 2 * ab * ta * tb + aa * tb * tb) / det - 1
        let disc = qb * qb - qa * qc
        guard qa > 1e-18, disc >= 0 else { return nil }
        let t = (qb + disc.squareRoot()) / qa
        guard t >= max(ta, tb) - 1e-12 else { return nil }
        // Upwind: the front comes into C from between a and b, so -g lies between them.
        let alpha = (bb * (ta - t) - ab * (tb - t)) / det
        let beta = (aa * (tb - t) - ab * (ta - t)) / det
        guard alpha <= 1e-12, beta <= 1e-12 else { return nil }
        return t
    }
}

/// Plan distance from points to a set of loops, looking only at the segments in nearby buckets.
struct BoundaryDistance: Sendable {
    private let segments: [(Vec2, Vec2)]
    private let buckets: [SIMD2<Int32>: [Int32]]
    private let size: Double

    init(_ loops: [Polyline], bucket size: Double) {
        self.size = max(size, 1e-6)
        var segs: [(Vec2, Vec2)] = []
        var map: [SIMD2<Int32>: [Int32]] = [:]
        for loop in loops {
            for k in 0..<loop.segmentCount {
                let (a, b) = loop.segment(k)
                let id = Int32(segs.count)
                segs.append((a, b))
                let x0 = Int32((min(a.x, b.x) / self.size).rounded(.down)), x1 = Int32((max(a.x, b.x) / self.size).rounded(.down))
                let y0 = Int32((min(a.y, b.y) / self.size).rounded(.down)), y1 = Int32((max(a.y, b.y) / self.size).rounded(.down))
                for x in x0...x1 { for y in y0...y1 { map[SIMD2(x, y), default: []].append(id) } }
            }
        }
        segments = segs
        buckets = map
    }

    /// Distance from p to the nearest segment, if one is within about `reach` (nil when none is).
    func distance(to p: Vec2, within reach: Double) -> Double? {
        let k = Int32(max(1, (reach / size).rounded(.up)))
        let cx = Int32((p.x / size).rounded(.down)), cy = Int32((p.y / size).rounded(.down))
        var best = Double.infinity
        for x in (cx - k)...(cx + k) {
            for y in (cy - k)...(cy + k) {
                for s in buckets[SIMD2(x, y)] ?? [] {
                    let (a, b) = segments[Int(s)]
                    let ab = b - a
                    let l2 = ab.lengthSquared
                    let u = l2 > 0 ? max(0, min(1, (p - a).dot(ab) / l2)) : 0
                    best = min(best, p.distance(to: a + ab * u))
                }
            }
        }
        return best.isFinite ? best : nil
    }
}

/// A binary min-heap of (value, index) pairs; stale entries are skipped by the caller.
struct MinHeap {
    private var values: [Double] = []
    private var items: [Int] = []

    var isEmpty: Bool { values.isEmpty }

    mutating func push(_ v: Double, _ i: Int) {
        values.append(v)
        items.append(i)
        var k = values.count - 1
        while k > 0 {
            let p = (k - 1) / 2
            guard values[p] > values[k] else { break }
            values.swapAt(p, k)
            items.swapAt(p, k)
            k = p
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let v = values.first, let i = items.first else { return nil }
        let last = values.count - 1
        values.swapAt(0, last)
        items.swapAt(0, last)
        values.removeLast()
        items.removeLast()
        var k = 0
        let n = values.count
        while true {
            let l = 2 * k + 1, r = l + 1
            var m = k
            if l < n && values[l] < values[m] { m = l }
            if r < n && values[r] < values[m] { m = r }
            guard m != k else { break }
            values.swapAt(m, k)
            items.swapAt(m, k)
            k = m
        }
        return (v, i)
    }
}
