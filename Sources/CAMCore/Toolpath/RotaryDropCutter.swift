import Foundation
import simd

/// Exact drop-cutter for a radial tool on a rotary blank (research_notes/Rotary milling/rotary_milling.md §2.2).
///
/// The tool points at the rotation axis (machine X) from above, over the axis's centreline. For the blank turned to
/// angle θ, the model is turned the same way (so the material that faces direction θ is on top), and the ordinary
/// vertical drop-cutter (`TriangleDropCutter`'s facet, edge and vertex tests) runs at (x, y = 0). The tip height it
/// gives is the tool tip's distance from the axis, r_tip(x, θ): the lowest the tool can come down at that station
/// and angle without cutting into the model. Like the 3-axis drop-cutter, the tool is modelled as its tip shape on an
/// endlessly long shank, so anything of the model within its footprint, however far out, keeps it away.
///
/// Angles are the material's, as in `RadialGrid`: θ (radians) from the top of the blank at A0 toward +Y is under the
/// tool when the blank has turned to A = θ, and turning the model by +θ about +X (right-hand rule) brings that
/// direction to the top.
///
/// Triangles are binned once in cylindrical coordinates (x, θ). Each one goes into the bins it can reach: its span
/// along x widened by the footprint, and the angles it spans round the axis widened by the footprint's angular
/// half-width at its nearest point to the axis. A query only turns and tests the triangles of one bin.
struct RotaryDropCutter: Sendable {
    typealias Kind = TriangleDropCutter.Kind

    let kind: Kind
    /// Tool radius, mm (0 for a probe).
    let radius: Double
    let allowance: Double
    /// The cutter for `.profile`, grown by the allowance.
    let profile: CutterProfile?
    /// Half-width of the tool's footprint, mm: the ball's radius plus the allowance, a flat bottom's radius, or the
    /// grown profile's radius.
    let reach: Double
    /// Extent of the triangles along x, and their farthest point from the axis, mm.
    let minX: Double, maxX: Double, maxRadius: Double
    /// Triangle vertices in the blank's frame, 9 per triangle.
    private let tri: [Double]
    private let xOrigin: Double
    private let xBin: Double
    private let xBins: Int
    private let angleBins: Int
    /// Bin contents, compressed rows: the triangles of bin k are items[start[k] ..< start[k + 1]], in order, with bin
    /// k = angleBin × xBins + xBin.
    private let start: [Int32]
    private let items: [Int32]
    /// The most a triangle can put the tip above its highest corner (what the cutter's lowest point leaves), plus a
    /// little slack for rounding: a triangle whose turned corners are all at least this far below the best so far
    /// can't beat it.
    private let lift: Double
    /// Each triangle's area × 2 (the length of its edges' cross product) and its edges' squared lengths, which don't
    /// change as it turns: for telling when its tests are well conditioned at an angle (`steady`).
    private let size: [Double]
    private let edges: [Double]

    var triangleCount: Int { tri.count / 9 }

    /// A cutter for `tool`: ball noses with their own test, flat end mills and surfacing bits with theirs when they
    /// leave no allowance, and V-bits, engraving bits, drills and bull noses exactly as a `CutterProfile` (grown by the
    /// allowance). A shape the profile can't describe (a V with no angle) is followed as a flat end mill of its
    /// diameter, which never cuts deeper than the real bit would. nil when there are no triangles.
    init?(tool: Tool, allowance: Double, triangles: [Double], angleBins: Int = 720) {
        let a = max(0, allowance)
        switch tool.shape {
        case .ballNose:
            self.init(kind: .ball, radius: tool.radius, allowance: a, profile: nil, triangles: triangles, angleBins: angleBins)
        case .flatEndMill, .surfacing:
            self.init(flat: tool.radius, allowance: a, triangles: triangles, angleBins: angleBins)
        default:
            if let shape = CutterProfile(tool: tool) {
                self.init(profile: shape, allowance: a, triangles: triangles, angleBins: angleBins)
            } else {
                self.init(flat: tool.radius, allowance: a, triangles: triangles, angleBins: angleBins)
            }
        }
    }

    /// A flat bottom of radius `radius`. With an allowance it's dropped as its profile grown by it all round (a bull
    /// nose the allowance wider, with the allowance for its corner), so the allowance stays square to the surface:
    /// beside a shoulder as well as above it. The flat test would only raise it by the allowance, and let its side
    /// come right up to a wall.
    private init?(flat radius: Double, allowance a: Double, triangles: [Double], angleBins: Int) {
        if a > 0, radius > 0 {
            self.init(profile: .flat(radius: radius), allowance: a, triangles: triangles, angleBins: angleBins)
        } else {
            self.init(kind: .flat, radius: radius, allowance: a, profile: nil, triangles: triangles, angleBins: angleBins)
        }
    }

    /// A cutter of any convex profile (a tapered ball nose, say), leaving `allowance` square to the surface.
    init?(profile shape: CutterProfile, allowance: Double, triangles: [Double], angleBins: Int = 720) {
        self.init(kind: .profile, radius: shape.radius, allowance: max(0, allowance), profile: shape.grown(by: max(0, allowance)),
                  triangles: triangles, angleBins: angleBins)
    }

    /// A probe with no width, for asking where a ray from the axis meets the model (`crossings`).
    init?(probe triangles: [Double], angleBins: Int = 720) {
        self.init(kind: .flat, radius: 0, allowance: 0, profile: nil, triangles: triangles, angleBins: angleBins)
    }

    private init?(kind: Kind, radius: Double, allowance: Double, profile: CutterProfile?, triangles: [Double], angleBins requested: Int) {
        let count = triangles.count / 9
        guard count > 0 else { return nil }
        self.kind = kind
        self.radius = radius
        self.allowance = allowance
        self.profile = profile
        tri = Array(triangles.prefix(count * 9))
        let reach = profile?.radius ?? (kind == .ball ? radius + allowance : radius)
        self.reach = reach

        // Each triangle's reach along x and round the axis.
        var x0s = [Double](repeating: 0, count: count), x1s = x0s
        var a0s = x0s, a1s = x0s
        var lo = Double.infinity, hi = -Double.infinity, far = 0.0
        for t in 0..<count {
            let i = t * 9
            let a = SIMD3(tri[i], tri[i + 1], tri[i + 2]), b = SIMD3(tri[i + 3], tri[i + 4], tri[i + 5])
            let c = SIMD3(tri[i + 6], tri[i + 7], tri[i + 8])
            let xl = min(a.x, b.x, c.x), xh = max(a.x, b.x, c.x)
            lo = min(lo, xl)
            hi = max(hi, xh)
            x0s[t] = xl - reach
            x1s[t] = xh + reach
            far = max(far, Self.length(a), Self.length(b), Self.length(c))
            let (from, to) = Self.angularReach(a, b, c, reach: reach)
            a0s[t] = from
            a1s[t] = to
        }
        guard lo.isFinite else { return nil }
        minX = lo
        maxX = hi
        maxRadius = far

        // Bins about as long as the footprint is wide, fewer if there'd be too many entries.
        var nA = max(8, requested)
        var bin = max(reach, 1)
        func entries(_ bin: Double, _ nA: Int) -> Int {
            let step = 2 * Double.pi / Double(nA)
            var total = 0
            for t in 0..<count {
                let xs = Int(((x1s[t] - x0s[t]) / bin).rounded(.down)) + 2
                let span = a1s[t] - a0s[t]
                let ns = span >= 2 * .pi ? nA : min(nA, Int((span / step).rounded(.down)) + 2)
                total += xs * ns
            }
            return total
        }
        while entries(bin, nA) > 60_000_000, nA > 64 || bin < hi - lo {
            if nA > 64 { nA /= 2 } else { bin *= 2 }
        }
        let origin = lo - reach
        let nX = max(1, Int(((hi + reach - origin) / bin).rounded(.down)) + 1)
        angleBins = nA
        xBin = bin
        xOrigin = origin
        xBins = nX

        let step = 2 * Double.pi / Double(nA)
        func xRange(_ t: Int) -> ClosedRange<Int> {
            let c0 = max(0, Int(((x0s[t] - origin) / bin).rounded(.down)))
            let c1 = min(nX - 1, Int(((x1s[t] - origin) / bin).rounded(.down)))
            return c0...max(c0, c1)
        }
        /// The angle bins a triangle reaches (indices may run past the ends; they wrap).
        func angleRange(_ t: Int) -> ClosedRange<Int> {
            let span = a1s[t] - a0s[t]
            if span >= 2 * .pi - 1e-12 { return 0...(nA - 1) }
            let j0 = Int(((a0s[t] + .pi) / step).rounded(.down))
            let j1 = Int(((a1s[t] + .pi) / step).rounded(.down))
            return j0...max(j0, min(j1, j0 + nA - 1))
        }
        var counts = [Int32](repeating: 0, count: nA * nX + 1)
        for t in 0..<count {
            let xr = xRange(t)
            for j in angleRange(t) {
                let row = ((j % nA) + nA) % nA * nX
                for c in xr { counts[row + c + 1] += 1 }
            }
        }
        for k in 1..<counts.count { counts[k] += counts[k - 1] }
        var fill = counts
        var list = [Int32](repeating: 0, count: Int(counts[counts.count - 1]))
        for t in 0..<count {
            let xr = xRange(t)
            for j in angleRange(t) {
                let row = ((j % nA) + nA) % nA * nX
                for c in xr {
                    list[Int(fill[row + c])] = Int32(t)
                    fill[row + c] += 1
                }
            }
        }
        // What turning doesn't change, for telling when a triangle's tests are well conditioned (`steady`).
        var area = [Double](repeating: 0, count: count), sides = [Double](repeating: 0, count: count * 3)
        for t in 0..<count {
            let i = t * 9
            let a = SIMD3(tri[i], tri[i + 1], tri[i + 2]), b = SIMD3(tri[i + 3], tri[i + 4], tri[i + 5])
            let c = SIMD3(tri[i + 6], tri[i + 7], tri[i + 8])
            area[t] = simd_length(simd_cross(b - a, c - a))
            sides[t * 3] = simd_length_squared(b - a)
            sides[t * 3 + 1] = simd_length_squared(c - b)
            sides[t * 3 + 2] = simd_length_squared(a - c)
        }
        start = counts
        items = list
        lift = (profile.map { -$0.minHeight } ?? allowance) + 1e-6
        size = area
        edges = sides
    }

    /// Whether triangle t's tests, turned so its corners' Y are ya, yb, yc, are accurate to well within the 1e-6 mm
    /// slack in its bound: its facet isn't nearly vertical without being skipped, and (for a ball) nor is an edge.
    @inline(__always) private func steady(_ t: Int, _ v: UnsafeBufferPointer<Double>, _ ya: Double, _ yb: Double, _ yc: Double) -> Bool {
        let i = t * 9
        let xa = v[i], xb = v[i + 3], xc = v[i + 6]
        // The Z part of the turned triangle's normal, as the tests work it out (it needs only X and Y).
        let nz = abs((xb - xa) * (yc - ya) - (yb - ya) * (xc - xa))
        let len = size[t]
        let skipped = nz < 0.5e-12 && nz < 0.5e-9 * len
        if !skipped, nz < 2e-3 * len { return false }
        guard kind == .ball else { return true } // flat and profile edges stay between their corners' heights
        @inline(__always) func steep(_ dx: Double, _ dy: Double, _ k: Int) -> Bool {
            let xy = dx * dx + dy * dy
            return xy > 0.5e-12 && xy < 2e-6 * edges[t * 3 + k]
        }
        return !steep(xb - xa, yb - ya, 0) && !steep(xc - xb, yc - yb, 1) && !steep(xa - xc, ya - yc, 2)
    }

    @inline(__always) private static func length(_ p: SIMD3<Double>) -> Double { (p.y * p.y + p.z * p.z).squareRoot() }

    /// The angles round the axis (radians, from −π, widened by the footprint) at which a triangle can be under a tool
    /// whose footprint is `reach` wide either side: (from, to) with to − from ≥ 2π when it can be at any angle.
    static func angularReach(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, reach: Double) -> (Double, Double) {
        // Across the axis, its points face every way.
        let p = [SIMD2(a.y, a.z), SIMD2(b.y, b.z), SIMD2(c.y, c.z)]
        let nearest = nearestDistance(p[0], p[1], p[2])
        guard nearest > max(reach, 1e-9) else { return (-.pi, 3 * .pi) }
        // The triangle seen from the axis spans less than half a turn: the arc that leaves out the widest gap
        // between its corners' angles.
        let angles = p.map { atan2($0.x, $0.y) }.sorted()
        let gaps = [angles[1] - angles[0], angles[2] - angles[1], angles[0] + 2 * .pi - angles[2]]
        let widest = gaps.indices.max { gaps[$0] < gaps[$1] }!
        let from: Double, to: Double
        switch widest {
        case 0: (from, to) = (angles[1], angles[0] + 2 * .pi)
        case 1: (from, to) = (angles[2], angles[1] + 2 * .pi)
        default: (from, to) = (angles[0], angles[2])
        }
        // Widened by the footprint's half-width at the triangle's nearest point to the axis: a point ρ out at φ is
        // within it at θ when |ρ sin(φ − θ)| ≤ reach on the near side.
        let pad = asin(min(1, reach / nearest)) + 1e-9
        return (from - pad, to + pad)
    }

    /// Distance from the axis (the origin of the cross-section) to the nearest point of a triangle's cross-section
    /// shadow: 0 when the axis passes through it.
    static func nearestDistance(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        func cross(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { u.x * v.y - u.y * v.x }
        let d1 = cross(b - a, -a), d2 = cross(c - b, -b), d3 = cross(a - c, -c)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        if !(neg && pos) { return 0 }
        func segment(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double {
            let d = v - u
            let l2 = simd_length_squared(d)
            let t = l2 > 1e-24 ? max(0, min(1, simd_dot(-u, d) / l2)) : 0
            return simd_length(u + d * t)
        }
        return min(segment(a, b), segment(b, c), segment(c, a))
    }

    @inline(__always) private func bin(x: Double, angle: Double) -> Int? {
        let c = Int(((x - xOrigin) / xBin).rounded(.down))
        guard c >= 0, c < xBins else { return nil }
        let step = 2 * Double.pi / Double(angleBins)
        // The angle as a direction, −π ≤ a < π, whatever number of turns it's unwound to.
        var a = angle.remainder(dividingBy: 2 * .pi)
        if a >= .pi { a -= 2 * .pi }
        var j = Int(((a + .pi) / step).rounded(.down)) % angleBins
        if j < 0 { j += angleBins }
        return j * xBins + c
    }

    /// Distance from the axis to the tool tip, mm, at station `x` with the blank turned to `angle` (radians, any number
    /// of turns round): the lowest the tool can come down there without cutting into the model. -infinity when no part
    /// of the model is within the tool's footprint.
    func tipRadius(x: Double, angle: Double) -> Double {
        var hint: Int32 = -1
        return tipRadius(x: x, angle: angle, hint: &hint)
    }

    /// `tipRadius(x:angle:)`, testing triangle `hint` first (the last query's winner, or -1); on return `hint` is
    /// this query's winner. The answer is the same whatever the hint: triangles that can't beat the best so far are
    /// skipped, and a good hint makes that most of them.
    func tipRadius(x: Double, angle: Double, hint: inout Int32) -> Double {
        guard let k = bin(x: x, angle: angle) else { return -.infinity }
        let c = cos(angle), s = sin(angle)
        let p = Vec2(x, 0)
        var best = -Double.infinity
        var winner: Int32 = -1
        let r = reach, lo = x - reach, hi = x + reach
        let first = Int(start[k]), end = Int(start[k + 1])
        tri.withUnsafeBufferPointer { v in
            items.withUnsafeBufferPointer { list in
                @inline(__always) func test(_ t: Int, skipping: Bool) {
                    let i = t * 9
                    guard max(v[i], v[i + 3], v[i + 6]) >= lo, min(v[i], v[i + 3], v[i + 6]) <= hi else { return }
                    // Turned so the material facing `angle` is on top: y' = y cos θ − z sin θ, z' = y sin θ + z cos θ.
                    let ya = v[i + 1] * c - v[i + 2] * s, yb = v[i + 4] * c - v[i + 5] * s, yc = v[i + 7] * c - v[i + 8] * s
                    guard max(ya, yb, yc) >= -r, min(ya, yb, yc) <= r else { return }
                    let za = v[i + 1] * s + v[i + 2] * c, zb = v[i + 4] * s + v[i + 5] * c, zc = v[i + 7] * s + v[i + 8] * c
                    // Can't beat the best so far (and its tests are accurate enough to be sure of that).
                    if skipping, max(za, zb, zc) + lift <= best, steady(t, v, ya, yb, yc) { return }
                    let a = SIMD3(v[i], ya, za), b = SIMD3(v[i + 3], yb, zb), cc = SIMD3(v[i + 6], yc, zc)
                    let z: Double
                    switch kind {
                    case .ball: z = TriangleDropCutter.ballTip(a, b, cc, p, radius: radius, allowance: allowance)
                    case .flat: z = TriangleDropCutter.flatTip(a, b, cc, p, radius: radius, allowance: allowance)
                    case .profile: z = profile!.tip(a, b, cc, p, normal: TriangleDropCutter.upNormal(a, b, cc), above: best)
                    // Never made here: a form or dovetail bit is followed as a flat end mill of its diameter.
                    case .rings: z = TriangleDropCutter.flatTip(a, b, cc, p, radius: radius, allowance: allowance)
                    }
                    if z > best {
                        best = z
                        winner = Int32(t)
                    }
                }
                // The hint counts only if it's in this bin (every triangle that can touch the tool here is).
                if hint >= 0 {
                    var a = first, b = end
                    while a < b {
                        let m = (a + b) / 2
                        if list[m] < hint { a = m + 1 } else { b = m }
                    }
                    if a < end, list[a] == hint { test(Int(hint), skipping: false) }
                }
                for n in first..<end where list[n] != hint { test(Int(list[n]), skipping: true) }
            }
        }
        if winner >= 0 { hint = winner }
        return best
    }

    /// Where the ray from the axis at station `x` and `angle` crosses the model's surface: how many times (distinct
    /// distances out), and the farthest crossing (the outside of the model there, mm from the axis; nil when the ray
    /// misses it). A solid model with the axis inside it is crossed once; more means part of the surface along that
    /// ray is hidden from a tool coming in from outside (an undercut), and 2 that the axis isn't inside the model
    /// there.
    func crossings(x: Double, angle: Double) -> (count: Int, outer: Double?) {
        guard let k = bin(x: x, angle: angle) else { return (0, nil) }
        let c = cos(angle), s = sin(angle)
        var hits: [Double] = []
        tri.withUnsafeBufferPointer { v in
            for n in Int(start[k])..<Int(start[k + 1]) {
                let i = Int(items[n]) * 9
                guard max(v[i], v[i + 3], v[i + 6]) >= x, min(v[i], v[i + 3], v[i + 6]) <= x else { continue }
                let ya = v[i + 1] * c - v[i + 2] * s, yb = v[i + 4] * c - v[i + 5] * s, yc = v[i + 7] * c - v[i + 8] * s
                guard max(ya, yb, yc) >= 0, min(ya, yb, yc) <= 0 else { continue }
                let a = SIMD3(v[i], ya, v[i + 1] * s + v[i + 2] * c)
                let b = SIMD3(v[i + 3], yb, v[i + 4] * s + v[i + 5] * c)
                let cc = SIMD3(v[i + 6], yc, v[i + 7] * s + v[i + 8] * c)
                // The vertical line through (x, 0) meets the triangle's plane at height z.
                let nrm = simd_cross(b - a, cc - a)
                guard abs(nrm.z) > 1e-12, TriangleDropCutter.insideXY(SIMD3(x, 0, 0), a, b, cc) else { continue }
                let z = a.z - (nrm.x * (x - a.x) + nrm.y * (0 - a.y)) / nrm.z
                if z > 0 { hits.append(z) }
            }
        }
        guard !hits.isEmpty else { return (0, nil) }
        hits.sort()
        // A ray through an edge or a vertex shared by several triangles meets each of them: count it once.
        var count = 1
        for i in 1..<hits.count where hits[i] - hits[i - 1] > 1e-6 { count += 1 }
        return (count, hits.last)
    }

    /// Runs `body` for indices 0..<count spread over the machine's cores, in chunks.
    static func concurrently(_ count: Int, chunk: Int = 256, _ body: @Sendable (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let chunks = (count + chunk - 1) / chunk
        DispatchQueue.concurrentPerform(iterations: chunks) { k in
            body((k * chunk)..<min(count, (k + 1) * chunk))
        }
    }

    /// Tip radii for many (x, angle) queries at once, spread over the machine's cores.
    func tipRadii(_ queries: [(x: Double, angle: Double)]) -> [Double] {
        let out = ParallelResults<Double>(count: queries.count, initial: -.infinity)
        Self.concurrently(queries.count) { range in
            var hint: Int32 = -1
            for i in range { out[i] = tipRadius(x: queries[i].x, angle: queries[i].angle, hint: &hint) }
        }
        return out.array
    }
}

/// Results written from several threads at once, each index by exactly one of them.
final class ParallelResults<T>: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<T>

    init(count: Int, initial: T) {
        storage = .allocate(capacity: max(count, 1))
        storage.initialize(repeating: initial)
        self.count = count
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    let count: Int

    subscript(i: Int) -> T {
        get { storage[i] }
        set { storage[i] = newValue }
    }

    var array: [T] { Array(storage.prefix(count)) }
}
