import Foundation
import simd

/// Exact drop-cutter against triangles (the classic facet / edge / vertex tests).
///
/// For an XY position it returns the lowest tool-tip Z at which the cutter touches but doesn't penetrate any
/// triangle. Unlike a height grid this has no sampling error, so steep walls can't be gouged between samples. Ball
/// noses and flat end mills have their own tests (`ballTip`, `flatTip`); V-bits, engraving bits, drills, bull noses
/// and tapered ball noses are dropped as a `CutterProfile`.
///
/// Speed: triangles are binned in XY, each bin sorted by the highest the triangle could lift the tool, so a query
/// stops once no triangle left in a bin could beat the best so far. A caller sampling along a line passes the last
/// sample's winner (`z(at:hint:)`), which is tested first. Normals are worked out once, not per query.
struct TriangleDropCutter: Sendable {
    enum Kind: Sendable, Equatable { case ball, flat, profile }

    let kind: Kind
    let radius: Double
    /// Extra material to leave on the surface (offsets the surface outward).
    let allowance: Double
    /// The cutter for `.profile`, grown by the allowance (so it leaves the allowance square to the surface).
    let profile: CutterProfile?
    /// Farthest from the tool's axis a triangle can be and still touch it.
    let reach: Double
    /// Triangle vertices, 9 doubles per triangle.
    private let tri: [Double]
    /// Each triangle's upward unit normal (zero for a degenerate one), as `ballTip` works it out.
    private let nx: [Double], ny: [Double], nz: [Double]
    /// Each triangle's slope dz/dx, dz/dy, as `flatTip` works it out; NaN when it has none.
    private let fx: [Double], fy: [Double]
    /// Each triangle's bins: first and last column, first and last row (4 per triangle).
    private let cells: [Int32]
    private let binOrigin: Vec2
    private let binSize: Double
    private let binCols: Int
    private let binRows: Int
    /// Bin contents, compressed rows: the triangles of bin k are items[start[k] ..< start[k + 1]], sorted by `bound`
    /// (the highest tip Z each could give, +infinity for a triangle whose tests aren't well conditioned), highest first.
    private let start: [Int32]
    private let items: [Int32]
    private let bound: [Double]

    var triangleCount: Int { tri.count / 9 }

    init?(tool: Tool, allowance: Double, triangles: [Double]) {
        switch tool.shape {
        case .ballNose:
            self.init(kind: .ball, radius: tool.radius, allowance: allowance, profile: nil, triangles: triangles)
        case .flatEndMill, .surfacing:
            self.init(kind: .flat, radius: tool.radius, allowance: allowance, profile: nil, triangles: triangles)
        default:
            guard let shape = CutterProfile(tool: tool) else { return nil }
            self.init(profile: shape, allowance: allowance, triangles: triangles)
        }
    }

    /// A cutter of any convex profile (a tapered ball nose, say), leaving `allowance` square to the surface.
    init?(profile shape: CutterProfile, allowance: Double, triangles: [Double]) {
        self.init(kind: .profile, radius: shape.radius, allowance: allowance, profile: shape.grown(by: max(0, allowance)),
                  triangles: triangles)
    }

    private init?(kind: Kind, radius: Double, allowance: Double, profile: CutterProfile?, triangles: [Double]) {
        self.kind = kind
        self.radius = radius
        self.allowance = allowance
        self.profile = profile
        // Ball and flat keep the reach and bins they always had, so they find exactly the same triangles.
        reach = profile?.radius ?? radius + allowance
        let lift = profile.map { -$0.minHeight } ?? allowance
        let count = triangles.count / 9
        tri = Array(triangles.prefix(count * 9))
        var lo = Vec2(.infinity, .infinity), hi = Vec2(-.infinity, -.infinity)
        for i in stride(from: 0, to: count * 9, by: 9) {
            for k in stride(from: 0, to: 9, by: 3) {
                lo = Vec2(min(lo.x, triangles[i + k]), min(lo.y, triangles[i + k + 1]))
                hi = Vec2(max(hi.x, triangles[i + k]), max(hi.y, triangles[i + k + 1]))
            }
        }
        guard lo.x.isFinite else { return nil }
        let size = max(2 * (profile?.radius ?? radius), 1)
        binSize = size
        binOrigin = lo
        binCols = max(1, Int(((hi.x - lo.x) / size).rounded(.up)) + 1)
        binRows = max(1, Int(((hi.y - lo.y) / size).rounded(.up)) + 1)

        var nx = [Double](repeating: 0, count: count), ny = nx, nz = nx, fx = nx, fy = nx
        var cells = [Int32](repeating: 0, count: count * 4)
        var top = [Double](repeating: 0, count: count)
        var counts = [Int32](repeating: 0, count: binCols * binRows + 1)
        for t in 0..<count {
            let i = t * 9
            let a = SIMD3(triangles[i], triangles[i + 1], triangles[i + 2])
            let b = SIMD3(triangles[i + 3], triangles[i + 4], triangles[i + 5])
            let c = SIMD3(triangles[i + 6], triangles[i + 7], triangles[i + 8])
            let n = Self.upNormal(a, b, c)
            (nx[t], ny[t], nz[t]) = (n.x, n.y, n.z)
            if let g = Self.flatSlope(a, b, c) { (fx[t], fy[t]) = (g.x, g.y) } else { (fx[t], fy[t]) = (.nan, .nan) }
            top[t] = Self.wellConditioned(a, b, c, normal: n) ? max(a.z, b.z, c.z) + lift + 1e-6 : .infinity
            let x0 = min(a.x, b.x, c.x), x1 = max(a.x, b.x, c.x)
            let y0 = min(a.y, b.y, c.y), y1 = max(a.y, b.y, c.y)
            let c0 = max(0, Int((x0 - lo.x) / size)), c1 = min(binCols - 1, Int((x1 - lo.x) / size))
            let r0 = max(0, Int((y0 - lo.y) / size)), r1 = min(binRows - 1, Int((y1 - lo.y) / size))
            cells[t * 4] = Int32(c0)
            cells[t * 4 + 1] = Int32(c1)
            cells[t * 4 + 2] = Int32(r0)
            cells[t * 4 + 3] = Int32(r1)
            for r in r0...r1 { for col in c0...c1 { counts[r * binCols + col + 1] += 1 } }
        }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        var fill = counts
        var list = [Int32](repeating: 0, count: Int(counts[counts.count - 1]))
        for t in 0..<count {
            for r in Int(cells[t * 4 + 2])...Int(cells[t * 4 + 3]) {
                for col in Int(cells[t * 4])...Int(cells[t * 4 + 1]) {
                    let k = r * binCols + col
                    list[Int(fill[k])] = Int32(t)
                    fill[k] += 1
                }
            }
        }
        var bounds = [Double](repeating: 0, count: list.count)
        for k in 0..<(counts.count - 1) {
            let range = Int(counts[k])..<Int(counts[k + 1])
            list[range].sort { top[Int($0)] != top[Int($1)] ? top[Int($0)] > top[Int($1)] : $0 < $1 }
            for n in range { bounds[n] = top[Int(list[n])] }
        }
        (self.nx, self.ny, self.nz, self.fx, self.fy) = (nx, ny, nz, fx, fy)
        self.cells = cells
        start = counts
        items = list
        bound = bounds
    }

    /// Whether a triangle's tests are accurate to well within the 1e-6 mm slack on its bound: no near-vertical facet
    /// or edge, whose tests divide by a small number, unless it is exactly vertical (and so skipped).
    private static func wellConditioned(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, normal n: SIMD3<Double>) -> Bool {
        let raw = simd_cross(b - a, c - a)
        if (n.z > 1e-9 || abs(raw.z) > 1e-12), n.z < 1e-3 { return false }
        for (u, w) in [(a, b), (b, c), (c, a)] { // once per triangle, when binning
            let d = w - u
            let xy = d.x * d.x + d.y * d.y
            if xy > 1e-12, xy < 1e-6 * simd_length_squared(d) { return false }
        }
        return true
    }

    /// Tool-tip Z at `p`, or -infinity if no triangle is within reach.
    func z(at p: Vec2) -> Double {
        var hint: Int32 = -1
        return z(at: p, hint: &hint)
    }

    /// Tool-tip Z at `p`, testing triangle `hint` first (the last sample's winner, or -1); on return `hint` is this
    /// sample's winner. The answer is the same whatever the hint.
    func z(at p: Vec2, hint: inout Int32) -> Double {
        let c0 = max(0, Int((p.x - reach - binOrigin.x) / binSize)), c1 = min(binCols - 1, Int((p.x + reach - binOrigin.x) / binSize))
        let r0 = max(0, Int((p.y - reach - binOrigin.y) / binSize)), r1 = min(binRows - 1, Int((p.y + reach - binOrigin.y) / binSize))
        guard c0 <= c1, r0 <= r1 else { return -.infinity }
        var best = -Double.infinity
        var winner: Int32 = -1
        // Only a triangle in one of these bins can touch the tool here, so the hint counts only if it is.
        let h = Int(hint)
        if h >= 0, h < tri.count / 9, Int(cells[h * 4]) <= c1, Int(cells[h * 4 + 1]) >= c0,
           Int(cells[h * 4 + 2]) <= r1, Int(cells[h * 4 + 3]) >= r0 {
            let v = value(h, p, best: best)
            if v > best { best = v; winner = hint }
        }
        let far = reach + 1e-6
        for r in r0...r1 {
            for c in c0...c1 {
                let k = r * binCols + c
                for n in Int(start[k])..<Int(start[k + 1]) {
                    if bound[n] <= best { break } // nothing left in this bin can lift the tool
                    let t = items[n]
                    if t == hint { continue }
                    let i = Int(t) * 9
                    // Out of reach in X or Y: no test can touch it.
                    if min(tri[i], tri[i + 3], tri[i + 6]) > p.x + far || max(tri[i], tri[i + 3], tri[i + 6]) < p.x - far
                        || min(tri[i + 1], tri[i + 4], tri[i + 7]) > p.y + far || max(tri[i + 1], tri[i + 4], tri[i + 7]) < p.y - far {
                        continue
                    }
                    let v = value(Int(t), p, best: best)
                    if v > best { best = v; winner = t }
                }
            }
        }
        if winner >= 0 { hint = winner }
        return best
    }

    @inline(__always) private func vertex(_ t: Int, _ k: Int) -> SIMD3<Double> {
        let i = t * 9 + k * 3
        return SIMD3(tri[i], tri[i + 1], tri[i + 2])
    }

    /// What triangle t asks the tip to rise to at p (or, for a profile, anything up to `best` when it can't beat it).
    @inline(__always) private func value(_ t: Int, _ p: Vec2, best: Double = -.infinity) -> Double {
        let a = vertex(t, 0), b = vertex(t, 1), c = vertex(t, 2)
        switch kind {
        case .ball:
            return Self.ballTip(a, b, c, p, radius: radius, allowance: allowance, normal: SIMD3(nx[t], ny[t], nz[t]))
        case .flat:
            let g = fx[t].isNaN ? nil : SIMD2(fx[t], fy[t])
            return Self.flatTip(a, b, c, p, radius: radius, allowance: allowance, slope: g)
        case .profile:
            return profile!.tip(a, b, c, p, normal: SIMD3(nx[t], ny[t], nz[t]), above: best)
        }
    }

    // MARK: Ball

    /// The triangle's unit normal turned to face up, or zero for a degenerate triangle.
    @inline(__always) static func upNormal(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        var n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        guard len > 1e-12 else { return .zero }
        n /= len
        if n.z < 0 { n = -n }
        return n
    }

    /// Tip Z of a ball of radius `radius` + `allowance` dropped at `p` onto the triangle a, b, c (its centre Z −
    /// `radius`), or -infinity when the ball misses it. Shared with `RotaryDropCutter`.
    static func ballTip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, radius: Double, allowance: Double) -> Double {
        ballTip(a, b, c, p, radius: radius, allowance: allowance, normal: upNormal(a, b, c))
    }

    /// `ballTip` with the triangle's `upNormal` already worked out.
    static func ballTip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, radius: Double, allowance: Double,
                        normal n: SIMD3<Double>) -> Double {
        let R = radius + allowance
        var best = -Double.infinity
        // Facet: centre sits R along the (upward) normal from the plane, contact point inside the triangle.
        if n.z > 1e-9 {
            let zc = a.z + (R - n.x * (p.x - a.x) - n.y * (p.y - a.y)) / n.z
            let q = SIMD3(p.x, p.y, zc) - n * R
            if insideXY(q, a, b, c) { best = zc }
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

    /// The triangle's slope (dz/dx, dz/dy), or nil when it is vertical.
    @inline(__always) static func flatSlope(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD2<Double>? {
        let n = simd_cross(b - a, c - a)
        guard abs(n.z) > 1e-12 else { return nil }
        return SIMD2(-n.x / n.z, -n.y / n.z)
    }

    /// Tip Z of a flat-bottomed cylinder of radius `radius` dropped at `p` onto the triangle a, b, c: the highest
    /// surface point under the disc, raised by `allowance`; -infinity when the disc misses it. Shared with
    /// `RotaryDropCutter`.
    static func flatTip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, radius R: Double, allowance: Double) -> Double {
        flatTip(a, b, c, p, radius: R, allowance: allowance, slope: flatSlope(a, b, c))
    }

    /// `flatTip` with the triangle's `flatSlope` already worked out.
    static func flatTip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, radius R: Double, allowance: Double,
                        slope: SIMD2<Double>?) -> Double {
        var best = -Double.infinity
        // Facet: a plane's highest point over the disc is on the rim, in the uphill direction.
        if let slope {
            let gx = slope.x, gy = slope.y // dz/dx, dz/dy
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

/// The lower surface of a convex cutter of revolution: its height above the tip at each distance from its axis, out
/// to its radius, with the shank going straight up from there. It is made of straight pieces (flats and cones) and
/// rising circular arcs (a ball, a bull nose's corner), in order out from the axis, each joining the last.
///
/// Dropped onto a triangle (`tip`), the tip Z is the most any point q of the triangle within the radius asks for,
/// q.z − h(|q − p|). Because the profile is convex, that is a concave function on the triangle, so it peaks once:
/// - **facet**: inside the triangle, where the cutter's slope matches the plane's (`facetRadius`, uphill of p);
/// - **edge**: along an edge, at the one peak of a concave function of one variable (`edgePeak`);
/// - **vertex**: at a corner.
struct CutterProfile: Sendable, Equatable {
    struct Piece: Sendable, Equatable {
        /// Distances from the axis it spans.
        var r0: Double, r1: Double
        /// A straight piece: h = h0 + k (r − r0).
        var h0: Double = 0, k: Double = 0
        /// An arc (c > 0): the rising part of the circle of radius c centred cR out from the axis and cH above the tip,
        /// h = cH − √(c² − (r − cR)²).
        var cR: Double = 0, cH: Double = 0, c: Double = 0

        static func line(_ r0: Double, _ r1: Double, h0: Double, slope k: Double) -> Piece { Piece(r0: r0, r1: r1, h0: h0, k: k) }
        static func arc(_ r0: Double, _ r1: Double, centre cR: Double, _ cH: Double, radius c: Double) -> Piece {
            Piece(r0: r0, r1: r1, cR: cR, cH: cH, c: c)
        }

        var isArc: Bool { c > 0 }

        @inline(__always) func height(_ r: Double) -> Double {
            guard c > 0 else { return h0 + k * (r - r0) }
            let s = r - cR
            return cH - max(0, c * c - s * s).squareRoot()
        }

        /// dh/dr at r: infinite where an arc turns vertical.
        @inline(__always) func slope(_ r: Double) -> Double {
            guard c > 0 else { return k }
            let s = r - cR, w2 = c * c - s * s
            return w2 > 0 ? s / w2.squareRoot() : .infinity
        }

        /// The angle of the outward normal from straight down at r (0 on a flat, π/2 where it turns vertical).
        func normalAngle(_ r: Double) -> Double { c > 0 ? asin(max(0, min(1, (r - cR) / c))) : atan(k) }
    }

    let pieces: [Piece]

    init(pieces: [Piece]) {
        self.pieces = pieces.filter { $0.r1 > $0.r0 + 1e-12 }
    }

    /// Radius of the footprint.
    var radius: Double { pieces.last?.r1 ?? 0 }
    /// Height of its lowest point above the tip (below zero once grown by an allowance).
    var minHeight: Double { pieces.first?.height(0) ?? 0 }

    static func flat(radius R: Double) -> CutterProfile { CutterProfile(pieces: [.line(0, R, h0: 0, slope: 0)]) }

    static func ball(radius R: Double) -> CutterProfile { CutterProfile(pieces: [.arc(0, R, centre: 0, R, radius: R)]) }

    /// A flat end mill of radius R with corners rounded to radius `corner`.
    static func bullNose(radius R: Double, corner: Double) -> CutterProfile {
        let cr = max(0, min(corner, R))
        guard cr > 0 else { return flat(radius: R) }
        return CutterProfile(pieces: [.line(0, R - cr, h0: 0, slope: 0), .arc(R - cr, R, centre: R - cr, cr, radius: cr)])
    }

    /// A cone of half-angle `halfAngle` (radians, from the axis) out to radius R, with a flat tip of radius `tip`.
    static func vBit(radius R: Double, tip: Double, halfAngle: Double) -> CutterProfile {
        let r0 = max(0, min(tip, R))
        return CutterProfile(pieces: [.line(0, r0, h0: 0, slope: 0), .line(r0, R, h0: 0, slope: 1 / tan(halfAngle))])
    }

    /// A ball of radius `ball` running into a cone of half-angle `halfAngle` (radians, from the axis) that touches it,
    /// out to radius R.
    static func taperedBall(radius R: Double, ball rho: Double, halfAngle: Double) -> CutterProfile {
        let rt = min(R, rho * cos(halfAngle))
        let ht = rho - (max(0, rho * rho - rt * rt)).squareRoot()
        return CutterProfile(pieces: [.arc(0, rt, centre: 0, rho, radius: rho), .line(rt, R, h0: ht, slope: 1 / tan(halfAngle))])
    }

    /// The profile of a tool's tip, or nil for a shape it can't describe.
    init?(tool: Tool) {
        let R = tool.radius
        guard R > 0 else { return nil }
        switch tool.shape {
        case .flatEndMill, .surfacing: self = .flat(radius: R)
        case .ballNose: self = .ball(radius: R)
        case .bullNose: self = .bullNose(radius: R, corner: tool.cornerRadius)
        case .vBit, .engraving, .drill:
            let t = tool.halfAngleTangent
            guard t > 1e-6, t.isFinite else { return nil }
            self = .vBit(radius: R, tip: tool.shape == .drill ? 0 : tool.tipDiameter / 2, halfAngle: atan(t))
        }
    }

    /// The same cutter grown by `a` all round (the Minkowski sum with a ball of radius a), so that dropping it keeps
    /// the real cutter a clear of the surface: each piece moves a along its normal, and each corner (the tip of a V,
    /// the top of a cone where the shank starts) becomes an arc of radius a. Heights stay measured from the real tip.
    func grown(by a: Double) -> CutterProfile {
        guard a > 0, !pieces.isEmpty else { return self }
        var out: [Piece] = []
        var angle = 0.0
        var corner = (r: 0.0, h: pieces[0].height(0))
        func round(to next: Double) {
            guard next > angle + 1e-12 else { return }
            out.append(.arc(corner.r + a * sin(angle), corner.r + a * sin(next), centre: corner.r, corner.h, radius: a))
        }
        for p in pieces {
            let from = p.normalAngle(p.r0), to = p.normalAngle(p.r1)
            corner = (p.r0, p.height(p.r0))
            round(to: from)
            if p.isArc {
                let c = p.c + a
                out.append(.arc(p.cR + c * sin(from), p.cR + c * sin(to), centre: p.cR, p.cH, radius: c))
            } else {
                out.append(.line(p.r0 + a * sin(from), p.r1 + a * sin(from), h0: p.height(p.r0) - a * cos(from), slope: p.k))
            }
            angle = to
            corner = (p.r1, p.height(p.r1))
        }
        round(to: .pi / 2)
        return CutterProfile(pieces: out)
    }

    /// Height above the tip at distance r from the axis.
    @inline(__always) func height(_ r: Double) -> Double {
        for p in pieces where r <= p.r1 { return p.height(r) }
        return pieces.last.map { $0.height($0.r1) } ?? 0
    }

    /// Where on the cutter a plane of slope s (rise over run) touches it: the distance from the axis at which the
    /// cutter's own slope reaches s, or the rim when it never does.
    func facetRadius(_ s: Double) -> Double {
        for p in pieces {
            if s <= p.slope(p.r0) { return p.r0 }
            if p.isArc, s <= p.slope(p.r1) {
                return min(p.r1, max(p.r0, p.cR + p.c * s / (1 + s * s).squareRoot()))
            }
        }
        return radius
    }

    /// For a line passing `d` from the axis and rising at slope m ≥ 0 along it, the u ≥ 0 (distance along the line
    /// from its nearest point to the axis) that maximises m u − h(√(d² + u²)), within u ≤ `limit`. That function is
    /// concave, so its derivative m − h′(r) u / r falls as u grows: walk out the pieces to where it turns negative.
    func edgePeak(m: Double, d: Double, limit: Double) -> Double {
        for p in pieces where p.r1 > d {
            let ra = max(p.r0, d)
            let ua = max(0, ra * ra - d * d).squareRoot(), ub = max(0, p.r1 * p.r1 - d * d).squareRoot()
            let ka = p.slope(ra)
            if !ka.isFinite { return ua }
            if m <= ka * (ra > 0 ? ua / ra : 1) { return ua }
            if p.isArc {
                if p.cR == 0 {
                    // A sphere on the axis: m = u / √(c² − d² − u²).
                    let u = m * max(0, p.c * p.c - d * d).squareRoot() / (1 + m * m).squareRoot()
                    if u <= ub { return max(u, ua) }
                } else if let u = Self.torusPeak(p, m: m, d: d, from: ua, to: ub) {
                    return u
                }
            } else if p.k > m {
                // A cone: u / r = m / k.
                let t = m / p.k
                let u = d * t / (1 - t * t).squareRoot()
                if u <= ub { return max(u, ua) }
            }
        }
        return limit
    }

    /// The root of m − h′(r) u / r between `from` (where it is positive) and `to` on a torus piece, or nil when it is
    /// still positive at `to`. Newton's method, falling back to bisection.
    private static func torusPeak(_ p: Piece, m: Double, d: Double, from: Double, to: Double) -> Double? {
        func f(_ u: Double) -> Double {
            let r = (d * d + u * u).squareRoot()
            return r > 0 ? m - p.slope(r) * u / r : m
        }
        guard f(to) < 0 else { return nil }
        var lo = from, hi = to
        var u = 0.5 * (lo + hi)
        for _ in 0..<64 {
            let r = (d * d + u * u).squareRoot()
            let s = r - p.cR, w2 = p.c * p.c - s * s
            guard w2 > 0, r > 0 else {
                hi = u
                u = 0.5 * (lo + hi)
                continue
            }
            let w = w2.squareRoot()
            let hp = s / w, hpp = p.c * p.c / (w2 * w)
            let value = m - hp * u / r
            if value > 0 { lo = u } else { hi = u }
            if hi - lo <= 1e-13 * max(1, hi) { break }
            let slope = -(hpp * u * u / (r * r) + hp * d * d / (r * r * r))
            var next = slope < 0 ? u - value / slope : .nan
            if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
            u = next
        }
        return u
    }

    /// Tip Z of this cutter dropped at `p` onto the triangle a, b, c with upward unit normal n (`upNormal`), or
    /// -infinity when it misses. Each test returns the height a real point of the triangle asks for, so none can
    /// overshoot, and between them they find the point that asks most.
    ///
    /// `above`: the best answer already known from other triangles. Tests that can't beat it may be skipped (it's
    /// only their maximum that counts), so the answer is then either right or no more than `above`.
    func tip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ p: Vec2, normal n: SIMD3<Double>,
             above floor: Double = -.infinity) -> Double {
        let R = radius
        var best = -Double.infinity
        // Facet: uphill of p, where the cutter's slope matches the plane's.
        if n.z > 1e-9 {
            let gx = -n.x / n.z, gy = -n.y / n.z
            let s = (gx * gx + gy * gy).squareRoot()
            let r = facetRadius(s)
            let qx = s > 1e-12 ? p.x + r * gx / s : p.x, qy = s > 1e-12 ? p.y + r * gy / s : p.y
            if TriangleDropCutter.insideXY(SIMD3(qx, qy, 0), a, b, c) {
                best = a.z + gx * (qx - a.x) + gy * (qy - a.y) - height(r)
            }
        }
        // Vertices.
        @inline(__always) func vertex(_ v: SIMD3<Double>) {
            let dx = v.x - p.x, dy = v.y - p.y
            let d2 = dx * dx + dy * dy
            if d2 <= R * R { best = max(best, v.z - height(d2.squareRoot())) }
        }
        vertex(a)
        vertex(b)
        vertex(c)
        let bar = max(best, floor)
        best = max(best, edge(a, b, p, above: bar), edge(b, c, p, above: bar), edge(c, a, p, above: bar))
        return best
    }

    /// The most the edge from v1 to v2 asks the tip to rise at `p`, or -infinity when it is out of reach.
    @inline(__always) private func edge(_ v1: SIMD3<Double>, _ v2: SIMD3<Double>, _ p: Vec2, above floor: Double) -> Double {
        let ex = v2.x - v1.x, ey = v2.y - v1.y
        let L2 = ex * ex + ey * ey
        guard L2 > 1e-18 else { return -.infinity } // vertical: its top vertex is the most it asks
        let L = L2.squareRoot()
        let wx = p.x - v1.x, wy = p.y - v1.y
        let s0 = (wx * ex + wy * ey) / L // along the edge from v1 to the point nearest p
        let d = abs(wx * ey - wy * ex) / L
        let R = radius
        guard d <= R else { return -.infinity }
        // Every point of the edge is at least d from the axis, so it can ask for no more than this.
        guard max(v1.z, v2.z) - height(d) > floor else { return -.infinity }
        let U = max(0, R * R - d * d).squareRoot()
        // u is measured along the edge from the point nearest p; the edge runs from u = −s0 to L − s0.
        var lo = max(-s0, -U), hi = min(L - s0, U)
        guard lo <= hi else { return -.infinity }
        var m = (v2.z - v1.z) / L
        let flip = m < 0
        if flip {
            m = -m
            (lo, hi) = (-hi, -lo)
        }
        var u = min(max(edgePeak(m: m, d: d, limit: U), lo), hi)
        if flip { u = -u }
        let z = v1.z + (v2.z - v1.z) * max(0, min(1, (s0 + u) / L))
        return z - height(min(R, (d * d + u * u).squareRoot()))
    }
}
