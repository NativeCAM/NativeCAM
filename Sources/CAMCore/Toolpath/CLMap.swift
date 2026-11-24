import Foundation
import simd

/// Cutter-location (CL) height map for one tool: the tip Z of the exact drop-cutter (`CombinedDrop`) at every node of
/// a regular grid, clamped between the floor and the material top the way finishing passes are.
///
/// The slope-aware finishing strategies all read it:
/// - **waterline**: the loops at a height are its iso-contours (marching squares), each vertex then bisected with the
///   exact drop-cutter onto the contour, and each chord checked at its middle and split until it lies on it too;
/// - **steep and shallow**: its slope, thresholded (for a ball nose the CL surface's slope is the contact normal's);
/// - **pencil**: neighbouring nodes whose contact jumps from one face to another (double contact, a concave crease).
///
/// The grid's pitch only decides what is found: where the tool goes is always worked out with the exact cutter.
struct CLMap: Sendable {
    struct Sample {
        /// Clamped tip Z.
        var z: Double
        /// The model itself (a triangle, not the material round it or the floor) holds the tool up.
        var onModel: Bool
        /// The exact cutter's winning triangle, -1 when none touches.
        var winner: Int32
        /// The exact cutter's own tip Z, unclamped (-infinity when no triangle is in reach).
        var exactZ: Double
    }

    let origin: Vec2
    let pitch: Double
    let columns: Int
    let rows: Int
    /// Clamped tip Z at each node (row-major).
    let z: [Double]
    let onModel: [Bool]
    let dropper: CombinedDrop
    let floor: Double

    /// Drops the tool at every node of `grid` (its cell centres; in parallel, a row at a time).
    init(dropper: CombinedDrop, floor: Double, grid: SurfaceGrid) {
        self.dropper = dropper
        self.floor = floor
        let pitch = grid.cellSize
        self.pitch = pitch
        origin = grid.origin
        let cols = grid.columns, rws = grid.rows
        columns = cols
        rows = rws
        let zs = ParallelResults<Double>(count: cols * rws, initial: floor)
        let model = ParallelResults<Bool>(count: cols * rws, initial: false)
        let o = grid.origin
        DispatchQueue.concurrentPerform(iterations: rws) { r in
            var hint: Int32 = -1
            for c in 0..<cols {
                let s = CLMap.sample(dropper, floor: floor, Vec2(o.x + Double(c) * pitch, o.y + Double(r) * pitch), hint: &hint)
                zs[r * cols + c] = s.z
                model[r * cols + c] = s.onModel
            }
        }
        z = zs.array
        onModel = model.array
    }

    /// A map of `grid`'s nodes whose samples are already worked out (as `init(dropper:floor:grid:)` would).
    init(dropper: CombinedDrop, floor: Double, grid: SurfaceGrid, z: [Double], onModel: [Bool]) {
        self.dropper = dropper
        self.floor = floor
        pitch = grid.cellSize
        origin = grid.origin
        columns = grid.columns
        rows = grid.rows
        self.z = z
        self.onModel = onModel
    }

    static func sample(_ d: CombinedDrop, floor: Double, _ p: Vec2, hint: inout Int32) -> Sample {
        var h = hint
        let e = d.exact?.z(at: p, hint: &h) ?? -.infinity
        let g = d.grid.z(at: p)
        if e.isFinite { hint = h } // a finite answer always has a winner
        return Sample(z: max(floor, min(0, max(e, g))), onModel: e.isFinite && e >= g && e > floor, winner: e.isFinite ? h : -1, exactZ: e)
    }

    func sample(_ p: Vec2, hint: inout Int32) -> Sample { Self.sample(dropper, floor: floor, p, hint: &hint) }
    func height(_ p: Vec2, hint: inout Int32) -> Double { sample(p, hint: &hint).z }
    func height(_ p: Vec2) -> Double {
        var h: Int32 = -1
        return height(p, hint: &h)
    }

    @inline(__always) func index(_ c: Int, _ r: Int) -> Int { r * columns + c }
    @inline(__always) func node(_ c: Int, _ r: Int) -> Vec2 { Vec2(origin.x + Double(c) * pitch, origin.y + Double(r) * pitch) }

    // MARK: Slope

    /// Slope of the CL surface at each node, degrees from horizontal (central differences, one-sided at the edges).
    func slopes() -> [Double] {
        var out = [Double](repeating: 0, count: z.count)
        for r in 0..<rows {
            let r0 = max(0, r - 1), r1 = min(rows - 1, r + 1)
            for c in 0..<columns {
                let c0 = max(0, c - 1), c1 = min(columns - 1, c + 1)
                let gx = (z[index(c1, r)] - z[index(c0, r)]) / (Double(c1 - c0) * pitch)
                let gy = (z[index(c, r1)] - z[index(c, r0)]) / (Double(r1 - r0) * pitch)
                out[index(c, r)] = atan((gx * gx + gy * gy).squareRoot()).degrees
            }
        }
        return out
    }

    // MARK: Waterline

    /// One waterline loop: closed, with the material on its right (climb milling with an M3 spindle). `onModel[i]` says
    /// whether the model holds the tool at `points[i]`, so the parts of a loop that only run round the material beside
    /// the model (an uncut lip, the wall past the boundary) can be dropped.
    struct Contour {
        var points: [Vec2]
        var onModel: [Bool]
    }

    /// The waterline at tip height `level`: loops round where the tool at that height would cut into the model
    /// (CL > level). Every vertex is on the free side of the contour, within 1e-4 mm of it, and every chord's middle is
    /// within `tolerance` of the level in Z (or its chord is shorter than a micron).
    ///
    /// `within`, when given, marks the nodes worth contouring (the area being cut, with a margin): the rest count as
    /// past the grid, so loops are only traced, bisected and refined where they can be used.
    func contours(at level: Double, tolerance: Double, within: [Bool]? = nil) -> [Contour] {
        let W = columns + 2, H = rows + 2
        @inline(__always) func inGrid(_ c: Int, _ r: Int) -> Bool {
            c >= 0 && r >= 0 && c < columns && r < rows && (within?[r * columns + c] ?? true)
        }
        @inline(__always) func inside(_ c: Int, _ r: Int) -> Bool {
            inGrid(c, r) && z[r * columns + c] > level
        }
        // Edges between padded nodes (-1...columns, -1...rows): 2 × node + 0 to the right, + 1 upward.
        @inline(__always) func hEdge(_ c: Int, _ r: Int) -> Int { 2 * ((r + 1) * W + c + 1) }
        @inline(__always) func vEdge(_ c: Int, _ r: Int) -> Int { 2 * ((r + 1) * W + c + 1) + 1 }
        var next = [Int32](repeating: -1, count: 2 * W * H)
        var hint: Int32 = -1
        func centreInside(_ c: Int, _ r: Int) -> Bool {
            height(Vec2(origin.x + (Double(c) + 0.5) * pitch, origin.y + (Double(r) + 0.5) * pitch), hint: &hint) > level
        }
        // Segments with the inside on the left (counter-clockwise round the material). A saddle is split or joined as
        // the exact drop at the cell's centre says.
        for r in -1..<rows {
            for c in -1..<columns {
                let code = (inside(c, r) ? 1 : 0) | (inside(c + 1, r) ? 2 : 0) | (inside(c + 1, r + 1) ? 4 : 0) | (inside(c, r + 1) ? 8 : 0)
                if code == 0 || code == 15 { continue }
                let bottom = hEdge(c, r), right = vEdge(c + 1, r), top = hEdge(c, r + 1), left = vEdge(c, r)
                switch code {
                case 1: next[bottom] = Int32(left)
                case 2: next[right] = Int32(bottom)
                case 3: next[right] = Int32(left)
                case 4: next[top] = Int32(right)
                case 5:
                    if centreInside(c, r) {
                        next[bottom] = Int32(right); next[top] = Int32(left)
                    } else {
                        next[bottom] = Int32(left); next[top] = Int32(right)
                    }
                case 6: next[top] = Int32(bottom)
                case 7: next[top] = Int32(left)
                case 8: next[left] = Int32(top)
                case 9: next[bottom] = Int32(top)
                case 10:
                    if centreInside(c, r) {
                        next[left] = Int32(bottom); next[right] = Int32(top)
                    } else {
                        next[right] = Int32(bottom); next[left] = Int32(top)
                    }
                case 11: next[right] = Int32(top)
                case 12: next[left] = Int32(right)
                case 13: next[bottom] = Int32(right)
                case 14: next[left] = Int32(bottom)
                default: break
                }
            }
        }
        let iterations = max(8, Int(log2(pitch / 1e-4).rounded(.up)))
        // Bisects between a free point and a point inside the material; returns the free end, and whether the model is
        // what holds the tool up just inside.
        func crossing(free a: Vec2, inside b: Vec2) -> (Vec2, Bool) {
            var lo = a, hi = b
            for _ in 0..<iterations {
                let m = lo.lerp(to: hi, 0.5)
                if height(m, hint: &hint) > level { hi = m } else { lo = m }
            }
            return (lo, sample(hi, hint: &hint).onModel)
        }
        func vertex(_ id: Int) -> (Vec2, Bool) {
            let n = id / 2
            let c0 = n % W - 1, r0 = n / W - 1
            let (c1, r1) = id % 2 == 0 ? (c0 + 1, r0) : (c0, r0 + 1)
            let in0 = inside(c0, r0)
            let (ci, ri, cf, rf) = in0 ? (c0, r0, c1, r1) : (c1, r1, c0, r0)
            let pIn = node(ci, ri), pFree = node(cf, rf)
            if !inGrid(cf, rf) {
                return (pIn.lerp(to: pFree, 0.5), false) // past the grid: nothing to bisect, never the model
            }
            return crossing(free: pFree, inside: pIn)
        }
        // Splits a chord whose middle is off the contour by more than the tolerance, at the contour point straight across
        // from its middle, until it isn't (or is too short to matter).
        func refine(_ a: Vec2, _ b: Vec2, depth: Int, points: inout [Vec2], flags: inout [Bool]) {
            guard depth > 0, a.distanceSquared(to: b) > 1e-6 else { return }
            let m = a.lerp(to: b, 0.5)
            let e = height(m, hint: &hint) - level
            guard abs(e) > tolerance else { return }
            let dir = (b - a).normalized
            // Material on the left: step right to get out of it, left to reach it.
            let u = e > 0 ? dir.perpRight : dir.perpLeft
            var far: Vec2?
            var s = pitch / 8
            while s <= 2 * pitch {
                let q = m + u * s
                if (height(q, hint: &hint) > level) != (e > 0) { far = q; break }
                s *= 2
            }
            guard let far else { return }
            let x = e > 0 ? crossing(free: far, inside: m) : crossing(free: m, inside: far)
            refine(a, x.0, depth: depth - 1, points: &points, flags: &flags)
            points.append(x.0)
            flags.append(x.1)
            refine(x.0, b, depth: depth - 1, points: &points, flags: &flags)
        }
        var out: [Contour] = []
        for start in 0..<next.count where next[start] >= 0 {
            var ids: [Int] = []
            var cur = start
            while next[cur] >= 0, ids.count <= next.count {
                ids.append(cur)
                let n = Int(next[cur])
                next[cur] = -1
                cur = n
                if cur == start { break }
            }
            guard ids.count >= 3 else { continue }
            let raw = ids.map(vertex)
            var points: [Vec2] = [], flags: [Bool] = []
            points.reserveCapacity(raw.count)
            for k in raw.indices {
                points.append(raw[k].0)
                flags.append(raw[k].1)
                // Only chords against the model are worth getting right; the rest are dropped.
                if raw[k].1 && raw[(k + 1) % raw.count].1 {
                    refine(raw[k].0, raw[(k + 1) % raw.count].0, depth: 4, points: &points, flags: &flags)
                }
            }
            // Material on the right for climb milling.
            out.append(Contour(points: Array(points.reversed()), onModel: Array(flags.reversed())))
        }
        return out
    }

    // MARK: Pencil

    /// Concave creases for a ball nose of radius `ballRadius`: polylines through the places where it touches two faces at
    /// once. Between two neighbouring nodes that is where the contact normal turns by at least `angle` degrees while the
    /// contact point runs ahead of the tool (at least twice as far as the tool moved, which no convex edge or gentle
    /// hollow does). The crossing on each such grid edge is bisected to where the contact switches faces, the strongest
    /// along each grid line kept, and crossings in the same cell joined.
    func creases(ballRadius R: Double, angle: Double) -> [Polyline] {
        guard let exact = dropper.exact else { return [] }
        let n = columns * rows
        let normals = ParallelResults<SIMD3<Float>>(count: n, initial: SIMD3(0, 0, 1))
        let contacts = ParallelResults<SIMD3<Float>>(count: n, initial: .zero)
        let cols = columns
        func contact(_ p: Vec2, hint: inout Int32) -> (n: SIMD3<Double>, q: SIMD3<Double>) {
            self.contact(p, exact: exact, ballRadius: R, hint: &hint)
        }
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            var hint: Int32 = -1
            for c in 0..<cols {
                let k = self.contact(node(c, r), exact: exact, ballRadius: R, hint: &hint)
                normals[r * cols + c] = SIMD3<Float>(k.n)
                contacts[r * cols + c] = SIMD3<Float>(k.q)
            }
        }
        let cosLimit = Float(cos(angle.radians))
        let h2 = Float(pitch * pitch)
        /// How sharply the contact turns from node i to node j (1 - cos), or 0 when that's no crease.
        func strength(_ i: Int, _ j: Int, _ step: SIMD2<Float>) -> Float {
            let c = simd_dot(normals[i], normals[j])
            guard c <= cosLimit else { return 0 }
            let dq = contacts[j] - contacts[i]
            guard dq.x * step.x + dq.y * step.y >= 2 * h2 else { return 0 }
            return 1 - c
        }
        // Edge crossings: horizontal edge (c, r)-(c+1, r) is 2 × node, vertical (c, r)-(c, r+1) is 2 × node + 1.
        var score = [Float](repeating: 0, count: 2 * n)
        let hp = Float(pitch)
        for r in 0..<rows {
            for c in 0..<columns {
                let i = index(c, r)
                if c + 1 < columns { score[2 * i] = strength(i, i + 1, SIMD2(hp, 0)) }
                if r + 1 < rows { score[2 * i + 1] = strength(i, i + columns, SIMD2(0, hp)) }
            }
        }
        // Thin: along each grid line keep only the strongest of a run of neighbouring crossings.
        var keep = [Bool](repeating: false, count: 2 * n)
        for r in 0..<rows {
            var c = 0
            while c < columns - 1 {
                guard score[2 * index(c, r)] > 0 else { c += 1; continue }
                var best = c
                var k = c
                while k < columns - 1, score[2 * index(k, r)] > 0 {
                    if score[2 * index(k, r)] > score[2 * index(best, r)] { best = k }
                    k += 1
                }
                keep[2 * index(best, r)] = true
                c = k
            }
        }
        for c in 0..<columns {
            var r = 0
            while r < rows - 1 {
                guard score[2 * index(c, r) + 1] > 0 else { r += 1; continue }
                var best = r
                var k = r
                while k < rows - 1, score[2 * index(c, k) + 1] > 0 {
                    if score[2 * index(c, k) + 1] > score[2 * index(c, best) + 1] { best = k }
                    k += 1
                }
                keep[2 * index(c, best) + 1] = true
                r = k
            }
        }
        // Where on each kept edge the contact switches faces.
        var point = [Int: Vec2]()
        var hint: Int32 = -1
        for e in 0..<(2 * n) where keep[e] {
            let i = e / 2
            let c = i % columns, r = i / columns
            var a = node(c, r), b = e % 2 == 0 ? node(c + 1, r) : node(c, r + 1)
            let na = SIMD3<Double>(normals[i]), nb = SIMD3<Double>(normals[e % 2 == 0 ? i + 1 : i + columns])
            for _ in 0..<10 {
                let m = a.lerp(to: b, 0.5)
                let nm = contact(m, hint: &hint).n
                if simd_dot(nm, na) >= simd_dot(nm, nb) { a = m } else { b = m }
            }
            // At the foot of a vertical wall the height jumps here (the tool rides up onto the wall's top): the crease is
            // the bottom of the step, so stand a little off it on the low side, where the tool sits in the corner.
            let za = height(a, hint: &hint), zb = height(b, hint: &hint)
            if abs(za - zb) > pitch {
                let (low, high) = za < zb ? (a, b) : (b, a)
                point[e] = low + (low - high).normalized * min(0.01, pitch / 10)
            } else {
                point[e] = a.lerp(to: b, 0.5)
            }
        }
        // Join crossings that share a cell; each crossing sits in at most two cells, so it gets at most two links.
        var links = [Int: [Int]]()
        func link(_ x: Int, _ y: Int) {
            links[x, default: []].append(y)
            links[y, default: []].append(x)
        }
        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let i = index(c, r)
                let edges = [2 * i, 2 * (i + 1) + 1, 2 * (i + columns), 2 * i + 1].filter { point[$0] != nil }
                switch edges.count {
                case 2:
                    link(edges[0], edges[1])
                case 3, 4:
                    // Pair them off shortest first (a crossing of two creases, or one ending in the cell).
                    var free = edges
                    while free.count >= 2 {
                        var best = (0, 1, Double.infinity)
                        for x in 0..<free.count {
                            for y in (x + 1)..<free.count {
                                let d = point[free[x]]!.distance(to: point[free[y]]!)
                                if d < best.2 { best = (x, y, d) }
                            }
                        }
                        link(free[best.0], free[best.1])
                        free.remove(at: best.1)
                        free.remove(at: best.0)
                    }
                default:
                    break
                }
            }
        }
        // Walk the links into polylines: open chains from their ends first, then whatever closes on itself.
        var visited = Set<Int>()
        var chains: [Polyline] = []
        func walk(from s: Int) -> [Vec2] {
            var pts = [point[s]!]
            visited.insert(s)
            var prev = -1, cur = s
            while true {
                guard let nxt = links[cur, default: []].first(where: { $0 != prev && !visited.contains($0) }) else { break }
                pts.append(point[nxt]!)
                visited.insert(nxt)
                prev = cur
                cur = nxt
            }
            return pts
        }
        let ids = point.keys.sorted()
        for s in ids where !visited.contains(s) && links[s, default: []].count <= 1 {
            let pts = walk(from: s)
            if pts.count >= 2 { chains.append(Polyline(pts, closed: false)) }
        }
        for s in ids where !visited.contains(s) {
            let pts = walk(from: s)
            if pts.count >= 3 { chains.append(Polyline(pts, closed: true)) }
        }
        return chains
    }

    /// Where a ball of radius `R` dropped at p touches, and the surface normal there (straight up on the floor).
    func contact(_ p: Vec2, exact: TriangleDropCutter, ballRadius R: Double, hint: inout Int32) -> (n: SIMD3<Double>, q: SIMD3<Double>) {
        let s = sample(p, hint: &hint)
        if s.onModel, s.winner >= 0 {
            let (a, b, c) = exact.corners(Int(s.winner))
            let centre = SIMD3(p.x, p.y, s.exactZ + R)
            let q = Self.closestPoint(centre, a, b, c)
            let d = centre - q
            let len = simd_length(d)
            if len > 1e-9 { return (d / len, q) }
        }
        return (SIMD3(0, 0, 1), SIMD3(p.x, p.y, s.z))
    }

    /// The point of triangle a, b, c nearest p (Ericson, Real-Time Collision Detection, 5.1.5).
    static func closestPoint(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }
}
