import Foundation
import simd

/// Exact drop-cutter against triangles for ball-nose and flat end mills (the classic facet / edge / vertex tests).
///
/// For an XY position it returns the lowest tool-tip Z at which the cutter touches but doesn't penetrate any
/// triangle. Unlike a height grid this has no sampling error, so steep walls can't be gouged between samples.
struct TriangleDropCutter: Sendable {
    enum Kind: Sendable { case ball, flat }

    let kind: Kind
    let radius: Double
    /// Extra material to leave on the surface (offsets the surface outward).
    let allowance: Double
    /// Triangle vertices, 9 doubles per triangle.
    private let tri: [Double]
    private let binOrigin: Vec2
    private let binSize: Double
    private let binCols: Int
    private let binRows: Int
    private let bins: [[Int32]]

    init?(tool: Tool, allowance: Double, triangles: [Double]) {
        switch tool.shape {
        case .ballNose: kind = .ball
        case .flatEndMill, .surfacing: kind = .flat
        default: return nil
        }
        radius = tool.radius
        self.allowance = allowance
        tri = triangles
        var lo = Vec2(.infinity, .infinity), hi = Vec2(-.infinity, -.infinity)
        var i = 0
        while i + 8 < triangles.count {
            for k in stride(from: 0, to: 9, by: 3) {
                lo = Vec2(min(lo.x, triangles[i + k]), min(lo.y, triangles[i + k + 1]))
                hi = Vec2(max(hi.x, triangles[i + k]), max(hi.y, triangles[i + k + 1]))
            }
            i += 9
        }
        guard lo.x.isFinite else { return nil }
        binSize = max(2 * tool.radius, 1)
        binOrigin = lo
        binCols = max(1, Int(((hi.x - lo.x) / binSize).rounded(.up)) + 1)
        binRows = max(1, Int(((hi.y - lo.y) / binSize).rounded(.up)) + 1)
        var b = [[Int32]](repeating: [], count: binCols * binRows)
        i = 0
        var t: Int32 = 0
        while i + 8 < triangles.count {
            let x0 = min(triangles[i], triangles[i + 3], triangles[i + 6]), x1 = max(triangles[i], triangles[i + 3], triangles[i + 6])
            let y0 = min(triangles[i + 1], triangles[i + 4], triangles[i + 7]), y1 = max(triangles[i + 1], triangles[i + 4], triangles[i + 7])
            let c0 = Int((x0 - lo.x) / binSize), c1 = Int((x1 - lo.x) / binSize)
            let r0 = Int((y0 - lo.y) / binSize), r1 = Int((y1 - lo.y) / binSize)
            for r in max(0, r0)...min(binRows - 1, r1) {
                for c in max(0, c0)...min(binCols - 1, c1) { b[r * binCols + c].append(t) }
            }
            i += 9
            t += 1
        }
        bins = b
    }

    /// Tool-tip Z at `p`, or -infinity if no triangle is within reach.
    func z(at p: Vec2) -> Double {
        let reach = radius + allowance
        let c0 = max(0, Int((p.x - reach - binOrigin.x) / binSize)), c1 = min(binCols - 1, Int((p.x + reach - binOrigin.x) / binSize))
        let r0 = max(0, Int((p.y - reach - binOrigin.y) / binSize)), r1 = min(binRows - 1, Int((p.y + reach - binOrigin.y) / binSize))
        guard c0 <= c1, r0 <= r1 else { return -.infinity }
        var best = -Double.infinity
        for r in r0...r1 {
            for c in c0...c1 {
                for t in bins[r * binCols + c] {
                    let v = kind == .ball ? ballDrop(Int(t), p) : flatDrop(Int(t), p)
                    if v > best { best = v }
                }
            }
        }
        return best
    }

    @inline(__always) private func vertex(_ t: Int, _ k: Int) -> SIMD3<Double> {
        let i = t * 9 + k * 3
        return SIMD3(tri[i], tri[i + 1], tri[i + 2])
    }

    private func ballDrop(_ t: Int, _ p: Vec2) -> Double {
        Self.ballTip(vertex(t, 0), vertex(t, 1), vertex(t, 2), p, radius: radius, allowance: allowance)
    }

    private func flatDrop(_ t: Int, _ p: Vec2) -> Double {
        Self.flatTip(vertex(t, 0), vertex(t, 1), vertex(t, 2), p, radius: radius, allowance: allowance)
    }

    // MARK: Ball

    /// Tip Z of a ball of radius `radius` + `allowance` dropped at `p` onto the triangle a, b, c (its centre Z −
    /// `radius`), or -infinity when the ball misses it. Shared with `RotaryDropCutter`.
    static func ballTip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, radius: Double, allowance: Double) -> Double {
        let R = radius + allowance
        var best = -Double.infinity
        // Facet: centre sits R along the (upward) normal from the plane, contact point inside the triangle.
        var n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        if len > 1e-12 {
            n /= len
            if n.z < 0 { n = -n }
            if n.z > 1e-9 {
                let zc = a.z + (R - n.x * (p.x - a.x) - n.y * (p.y - a.y)) / n.z
                let q = SIMD3(p.x, p.y, zc) - n * R
                if insideXY(q, a, b, c) { best = zc }
            }
        }
        // Vertices.
        @inline(__always) func vertex(_ v: SIMD3<Double>) {
            let dx = p.x - v.x, dy = p.y - v.y
            let d2 = dx * dx + dy * dy
            if d2 <= R * R { best = max(best, v.z + (R * R - d2).squareRoot()) }
        }
        vertex(a)
        vertex(b)
        vertex(c)
        // Edges.
        if let zc = ballEdge(a, b, p, R) { best = max(best, zc) }
        if let zc = ballEdge(b, c, p, R) { best = max(best, zc) }
        if let zc = ballEdge(c, a, p, R) { best = max(best, zc) }
        return best.isFinite ? best - radius : best
    }

    private static func ballEdge(_ v1: SIMD3<Double>, _ v2: SIMD3<Double>, _ p: Vec2, _ R: Double) -> Double? {
        let d = v2 - v1
        let L2 = simd_length_squared(d)
        let dxy2 = d.x * d.x + d.y * d.y
        guard L2 > 1e-18, dxy2 > 1e-12 else { return nil }
        let wx = p.x - v1.x, wy = p.y - v1.y
        let wd = wx * d.x + wy * d.y
        let A = dxy2 / L2
        let B = -2 * d.z * wd / L2
        let C = wx * wx + wy * wy - wd * wd / L2 - R * R
        let disc = B * B - 4 * A * C
        guard disc >= 0 else { return nil }
        let h = (-B + disc.squareRoot()) / (2 * A)
        let tParam = (wd + h * d.z) / L2
        guard tParam >= 0, tParam <= 1 else { return nil }
        return v1.z + h
    }

    // MARK: Flat

    /// Tip Z of a flat-bottomed cylinder of radius `radius` dropped at `p` onto the triangle a, b, c: the highest
    /// surface point under the disc, raised by `allowance`; -infinity when the disc misses it. Shared with
    /// `RotaryDropCutter`.
    static func flatTip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, radius R: Double, allowance: Double) -> Double {
        var best = -Double.infinity
        // Facet: a plane's highest point over the disc is on the rim, in the uphill direction.
        let n = simd_cross(b - a, c - a)
        if abs(n.z) > 1e-12 {
            let gx = -n.x / n.z, gy = -n.y / n.z // dz/dx, dz/dy
            let g = (gx * gx + gy * gy).squareRoot()
            let q = g > 1e-12 ? Vec2(p.x + R * gx / g, p.y + R * gy / g) : p
            if insideXY(SIMD3(q.x, q.y, 0), a, b, c) {
                best = a.z + gx * (q.x - a.x) + gy * (q.y - a.y)
            }
        }
        // Vertices under the disc.
        @inline(__always) func vertex(_ v: SIMD3<Double>) {
            if (v.x - p.x) * (v.x - p.x) + (v.y - p.y) * (v.y - p.y) <= R * R { best = max(best, v.z) }
        }
        vertex(a)
        vertex(b)
        vertex(c)
        // Edges: the part of each edge inside the disc; Z is linear along it, so check the clipped ends.
        @inline(__always) func edge(_ u: SIMD3<Double>, _ w: SIMD3<Double>) {
            let dx = w.x - u.x, dy = w.y - u.y
            let A = dx * dx + dy * dy
            guard A > 1e-18 else { return }
            let fx = u.x - p.x, fy = u.y - p.y
            let B = 2 * (fx * dx + fy * dy), C = fx * fx + fy * fy - R * R
            let disc = B * B - 4 * A * C
            guard disc >= 0 else { return }
            let s = disc.squareRoot()
            let t0 = max(0, (-B - s) / (2 * A)), t1 = min(1, (-B + s) / (2 * A))
            guard t0 <= t1 else { return }
            best = max(best, u.z + (w.z - u.z) * t0, u.z + (w.z - u.z) * t1)
        }
        edge(a, b)
        edge(b, c)
        edge(c, a)
        return best.isFinite ? best + allowance : best
    }

    @inline(__always) static func insideXY(_ q: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Bool {
        let d1 = (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)
        let d2 = (c.x - b.x) * (q.y - b.y) - (c.y - b.y) * (q.x - b.x)
        let d3 = (a.x - c.x) * (q.y - c.y) - (a.y - c.y) * (q.x - c.x)
        let eps = 1e-12
        let hasNeg = d1 < -eps || d2 < -eps || d3 < -eps
        let hasPos = d1 > eps || d2 > eps || d3 > eps
        return !(hasNeg && hasPos)
    }
}
