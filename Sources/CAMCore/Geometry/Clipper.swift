import CClipper2
import Foundation

/// Swift façade over the vendored Clipper2 library.
///
/// Real coordinates (mm) are scaled into Clipper's 64-bit integer space at `scale` units per mm,
/// i.e. 0.1 µm resolution, which is far below anything a router can cut and well inside Int64 range.
public enum Clipper {
    public static let scale: Double = 10_000

    public enum JoinType: Sendable { case square, bevel, round, miter }
    public enum EndType: Sendable { case polygon, joined, butt, square, round }
    public enum FillRule: Sendable { case evenOdd, nonZero, positive, negative }
    public enum ClipType: Sendable { case intersection, union, difference, xor }

    // MARK: Public real-unit API

    /// Offsets closed polygons outward (delta > 0) or inward (delta < 0). Results are cleaned closed loops.
    /// `arcTolerance` is the maximum deviation (mm) of the polygonal approximation of round joins.
    public static func offset(_ paths: [Polyline], delta: Double, join: JoinType = .round,
                              end: EndType = .polygon, miterLimit: Double = 2.0,
                              arcTolerance: Double = 0.005) -> [Polyline] {
        let ints = paths.map { toInt($0) }
        let out = inflateInt(ints, delta: delta * scale, join: join, end: end,
                             miterLimit: miterLimit, arcTolerance: arcTolerance * scale)
        return out.map { fromInt($0, closed: true) }.filter { $0.count >= 3 }
    }

    public static func boolean(_ type: ClipType, subjects: [Polyline], clips: [Polyline],
                               fill: FillRule = .nonZero) -> [Polyline] {
        let (closed, _) = booleanInt(type, fill: fill, subjects: subjects.map(toInt), openSubjects: [], clips: clips.map(toInt))
        return closed.map { fromInt($0, closed: true) }.filter { $0.count >= 3 }
    }

    public static func union(_ paths: [Polyline], fill: FillRule = .nonZero) -> [Polyline] {
        boolean(.union, subjects: paths, clips: [], fill: fill)
    }

    public static func difference(_ subjects: [Polyline], minus clips: [Polyline], fill: FillRule = .nonZero) -> [Polyline] {
        boolean(.difference, subjects: subjects, clips: clips, fill: fill)
    }

    public static func intersection(_ subjects: [Polyline], _ clips: [Polyline], fill: FillRule = .nonZero) -> [Polyline] {
        boolean(.intersection, subjects: subjects, clips: clips, fill: fill)
    }

    /// Clips open polylines (e.g. raster lines) to the inside of closed `region` polygons.
    public static func clipOpen(_ lines: [Polyline], to region: [Polyline], fill: FillRule = .nonZero) -> [Polyline] {
        let (_, open) = booleanInt(.intersection, fill: fill, subjects: [], openSubjects: lines.map(toInt), clips: region.map(toInt))
        return open.map { fromInt($0, closed: false) }.filter { $0.count >= 2 }
    }

    // MARK: Minkowski sums

    /// The Minkowski sum A ⊕ B of two closed polygons, filled: every point a + b with a in A and b in B, as outer
    /// loops (counter-clockwise) and any holes (clockwise). A hole is left where B fits inside a pocket of A without
    /// touching it.
    ///
    /// When one polygon is convex, the sum is the region the convolution of the two winds round (`convolution`): a
    /// single loop of n + m edges, unioned with Clipper2. Otherwise the polygon with fewer convex pieces
    /// (`convexPieces`) is split and the other convolved with each piece. Polygons that can't be split
    /// (self-intersecting) fall back to Clipper2's MinkowskiSum (one quad per pair of edges) filled in.
    ///
    /// For nesting, the no-fit polygon of a part B moving round a fixed part A is `minkowskiSum(A, B.reflected)`:
    /// B's reference point inside it means the two overlap, on its edge that they touch.
    public static func minkowskiSum(_ a: Polyline, _ b: Polyline) -> [Polyline] {
        let pa = a.oriented(counterClockwise: true).deduplicated(), pb = b.oriented(counterClockwise: true).deduplicated()
        guard pa.count >= 3, pb.count >= 3 else { return [] }
        if let ca = convexPieces([pa]), let cb = convexPieces([pb]) {
            return ca.count < cb.count ? minkowskiSum(loops: [pb.points], convexPieces: ca) : minkowskiSum(loops: [pa.points], convexPieces: cb)
        }
        return minkowskiSumQuads(pa, pb)
    }

    /// Clipper2's MinkowskiSum of the two boundaries (one quad per pair of edges), filled in with A moved by a point of
    /// B and B moved by a point of A.
    static func minkowskiSumQuads(_ a: Polyline, _ b: Polyline) -> [Polyline] {
        let pa = a.oriented(counterClockwise: true), pb = b.oriented(counterClockwise: true)
        let ai = toInt(pa), bi = toInt(pb)
        let boundary = minkowskiSumInt(bi, ai, closed: true)
        let aMoved = ai.map { IntPoint(x: $0.x + bi[0].x, y: $0.y + bi[0].y) }
        let bMoved = bi.map { IntPoint(x: $0.x + ai[0].x, y: $0.y + ai[0].y) }
        let (closed, _) = booleanInt(.union, fill: .nonZero, subjects: boundary + [aMoved, bMoved], openSubjects: [], clips: [])
        return closed.map { fromInt($0, closed: true) }.filter { $0.count >= 3 }
    }

    /// The Minkowski sum of simple counter-clockwise loops (no repeated points) and a shape given as convex
    /// counter-clockwise pieces: the union of every loop's convolution with every piece, filled where it winds round
    /// a positive number of times.
    public static func minkowskiSum(loops: [[Vec2]], convexPieces pieces: [[Vec2]]) -> [Polyline] {
        var cycles: [IntPath] = []
        cycles.reserveCapacity(loops.count * pieces.count)
        for loop in loops where loop.count >= 3 {
            for piece in pieces where piece.count >= 3 { cycles.append(toInt(Polyline(convolution(loop, piece), closed: true))) }
        }
        guard !cycles.isEmpty else { return [] }
        let (closed, _) = booleanInt(.union, fill: .positive, subjects: cycles, openSubjects: [], clips: [])
        return closed.map { fromInt($0, closed: true) }.filter { $0.count >= 3 }
    }

    /// The convolution of a simple counter-clockwise polygon `a` with a strictly convex counter-clockwise polygon `b`
    /// (Guibas, Ramshaw and Stolfi's kinetic framework): each edge of `a` moved by the vertex of `b` furthest out
    /// beyond it, joined at each corner of `a` by `b`'s edges between the two (forward round a convex corner,
    /// backward round a reflex one). It winds round every point of A ⊕ B a positive number of times and round every
    /// other point zero times.
    static func convolution(_ a: [Vec2], _ b: [Vec2]) -> [Vec2] {
        let n = a.count, m = b.count
        let ea = (0..<n).map { a[($0 + 1) % n] - a[$0] }
        let eb = (0..<m).map { b[($0 + 1) % m] - b[$0] }
        /// The vertex of `b` extreme beyond an edge running along `d`: the one between b's edges either side of d.
        func active(_ d: Vec2) -> Int {
            for j in 0..<m where eb[(j + m - 1) % m].cross(d) >= 0 && d.cross(eb[j]) > 0 { return j }
            return 0
        }
        var out: [Vec2] = []
        out.reserveCapacity(n + 2 * m)
        var j = active(ea[n - 1])
        for i in 0..<n {
            let target = active(ea[i])
            let forward = ea[(i + n - 1) % n].cross(ea[i]) >= 0
            while j != target {
                out.append(a[i] + b[j])
                j = forward ? (j + 1) % m : (j + m - 1) % m
            }
            out.append(a[i] + b[j])
        }
        return out
    }

    /// The Minkowski sum of two shapes given as convex counter-clockwise pieces, by unioning the sum of every pair
    /// (slower than `minkowskiSum(loops:convexPieces:)`; the tests check one against the other).
    static func minkowskiSum(pieces a: [[Vec2]], _ b: [[Vec2]]) -> [Polyline] {
        var sums: [Polyline] = []
        sums.reserveCapacity(a.count * b.count)
        for p in a {
            for q in b { sums.append(Polyline(convexMinkowskiSum(p, q), closed: true)) }
        }
        return sums.count == 1 ? sums : union(sums)
    }

    /// Convex counter-clockwise pieces exactly covering closed, non-intersecting loops (outer boundaries; clockwise
    /// loops inside them are holes): Clipper2's triangulation, with neighbouring pieces merged while they stay convex
    /// (Hertel–Mehlhorn), which leaves at most four times the fewest pieces possible. A convex loop is one piece. Nil
    /// when the loops can't be triangulated.
    public static func convexPieces(_ loops: [Polyline]) -> [[Vec2]]? {
        if loops.count == 1, let convex = strictlyConvex(loops[0].oriented(counterClockwise: true).points) { return [convex] }
        let paths = loops.filter { $0.count >= 3 }.map(toInt)
        guard !paths.isEmpty else { return [] }
        let triangles: [IntPath] = withFlat(paths) { input in
            guard let result = ncl_triangulate(input) else { return [] }
            defer { ncl_paths_free(result) }
            return unpack(result)
        }
        guard !triangles.isEmpty else { return nil }
        let pieces = mergeConvex(triangles.compactMap { t -> IntPath? in
            guard t.count == 3 else { return nil }
            let area = intArea([t])
            return area > 0 ? t : (area < 0 ? t.reversed() : nil)
        })
        return pieces.compactMap { strictlyConvex(fromInt($0, closed: true).points) }
    }

    /// Hertel–Mehlhorn: removes shared edges between counter-clockwise convex pieces while the merged piece stays
    /// convex.
    static func mergeConvex(_ input: [IntPath]) -> [IntPath] {
        struct Edge: Hashable { var a: IntPoint; var b: IntPoint }
        var pieces = input
        var alive = [Bool](repeating: true, count: pieces.count)
        var owner: [Edge: Int] = [:]
        for (i, p) in pieces.enumerated() {
            for k in p.indices { owner[Edge(a: p[k], b: p[(k + 1) % p.count])] = i }
        }
        func convex(_ p: IntPath) -> Bool {
            let n = p.count
            for k in 0..<n {
                let o = p[k], a = p[(k + 1) % n], b = p[(k + 2) % n]
                let cross = Double(a.x - o.x) * Double(b.y - a.y) - Double(a.y - o.y) * Double(b.x - a.x)
                if cross < 0 { return false }
            }
            return true
        }
        var changed = true
        while changed {
            changed = false
            for i in pieces.indices where alive[i] {
                var k = 0
                while k < pieces[i].count {
                    let p = pieces[i]
                    let u = p[k], v = p[(k + 1) % p.count]
                    guard let j = owner[Edge(a: v, b: u)], j != i, alive[j], let jv = pieces[j].firstIndex(of: v) else {
                        k += 1
                        continue
                    }
                    let q = pieces[j]
                    // p from v round to u, then q's points strictly between u and v.
                    let fromV = Array(p[((k + 1) % p.count)...] + p[..<((k + 1) % p.count)])
                    let fromU = Array(q[((jv + 1) % q.count)...] + q[..<((jv + 1) % q.count)])
                    let merged = fromV + fromU.dropFirst().dropLast()
                    guard convex(merged) else {
                        k += 1
                        continue
                    }
                    pieces[i] = merged
                    alive[j] = false
                    owner[Edge(a: u, b: v)] = nil
                    owner[Edge(a: v, b: u)] = nil
                    for m in merged.indices {
                        let e = Edge(a: merged[m], b: merged[(m + 1) % merged.count])
                        if owner[e] != nil { owner[e] = i }
                    }
                    changed = true
                    k = 0
                }
            }
        }
        return pieces.indices.filter { alive[$0] }.map { pieces[$0] }
    }

    /// Clipper2's MinkowskiSum of `pattern` swept along `path`: the union of one quad per pair of edges.
    static func minkowskiSumInt(_ pattern: IntPath, _ path: IntPath, closed: Bool) -> [IntPath] {
        withFlat([pattern]) { p in
            withFlat([path]) { q in
                guard let result = ncl_minkowski_sum(p, q, closed ? 1 : 0) else { return [] }
                defer { ncl_paths_free(result) }
                return unpack(result)
            }
        }
    }

    /// The points of a counter-clockwise polygon with collinear and repeated points removed, when it is convex.
    static func strictlyConvex(_ points: [Vec2]) -> [Vec2]? {
        var pts: [Vec2] = []
        pts.reserveCapacity(points.count)
        let n = points.count
        let scaleLength = points.reduce(Rect2.empty) { $0.union($1) }.size.length
        let eps = 1e-12 * max(1, scaleLength * scaleLength)
        for i in 0..<n {
            let prev = points[(i + n - 1) % n], p = points[i], next = points[(i + 1) % n]
            let c = (p - prev).cross(next - p)
            if c < -eps { return nil }
            if c > eps { pts.append(p) }
        }
        return pts.count >= 3 ? pts : nil
    }

    /// Minkowski sum of two strictly convex counter-clockwise polygons by merging their edges in angle order.
    static func convexMinkowskiSum(_ a: [Vec2], _ b: [Vec2]) -> [Vec2] {
        func lowest(_ p: [Vec2]) -> [Vec2] {
            var k = 0
            for i in p.indices where p[i].y < p[k].y || (p[i].y == p[k].y && p[i].x < p[k].x) { k = i }
            return Array(p[k...] + p[..<k])
        }
        let p = lowest(a), q = lowest(b)
        var out: [Vec2] = []
        out.reserveCapacity(p.count + q.count)
        var i = 0, j = 0
        while i < p.count || j < q.count {
            out.append(p[i % p.count] + q[j % q.count])
            let e1 = p[(i + 1) % p.count] - p[i % p.count]
            let e2 = q[(j + 1) % q.count] - q[j % q.count]
            let c = e1.cross(e2)
            if j >= q.count || (i < p.count && c > 0) {
                i += 1
            } else if i >= p.count || c < 0 {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return out
    }

    // MARK: Integer API (exposed internally for the Clipper2 fixture tests)

    struct IntPoint: Hashable { var x: Int64; var y: Int64 }
    typealias IntPath = [IntPoint]

    static func toInt(_ p: Polyline) -> IntPath {
        p.points.map { IntPoint(x: Int64(($0.x * scale).rounded()), y: Int64(($0.y * scale).rounded())) }
    }

    static func fromInt(_ p: IntPath, closed: Bool) -> Polyline {
        Polyline(p.map { Vec2(Double($0.x) / scale, Double($0.y) / scale) }, closed: closed)
    }

    static func intArea(_ paths: [IntPath]) -> Double {
        var total = 0.0
        for path in paths where path.count > 2 {
            var sum = 0.0
            var prev = path[path.count - 1]
            for p in path {
                sum += (Double(prev.y) + Double(p.y)) * (Double(prev.x) - Double(p.x))
                prev = p
            }
            total += sum * 0.5
        }
        return total
    }

    static func inflateInt(_ paths: [IntPath], delta: Double, join: JoinType, end: EndType,
                           miterLimit: Double, arcTolerance: Double) -> [IntPath] {
        withFlat(paths) { input in
            guard let result = ncl_inflate(input, delta, join.c, end.c, miterLimit, arcTolerance) else { return [] }
            defer { ncl_paths_free(result) }
            return unpack(result)
        }
    }

    static func booleanInt(_ type: ClipType, fill: FillRule, subjects: [IntPath], openSubjects: [IntPath],
                           clips: [IntPath]) -> (closed: [IntPath], open: [IntPath]) {
        withFlat(subjects) { s in
            withFlat(openSubjects) { o in
                withFlat(clips) { c in
                    var openOut: UnsafeMutablePointer<ncl_paths>?
                    let closed = ncl_boolean(type.c, fill.c, s, o, c, &openOut)
                    defer {
                        ncl_paths_free(closed)
                        ncl_paths_free(openOut)
                    }
                    let closedPaths = closed.map(unpack) ?? []
                    let openPaths = openOut.map(unpack) ?? []
                    return (closedPaths, openPaths)
                }
            }
        }
    }

    private static func withFlat<R>(_ paths: [IntPath], _ body: (ncl_paths_in) -> R) -> R {
        var counts = paths.map { $0.count }
        var points: [ncl_point] = []
        points.reserveCapacity(counts.reduce(0, +))
        for path in paths { for p in path { points.append(ncl_point(x: p.x, y: p.y)) } }
        if counts.isEmpty { counts = [0] }
        if points.isEmpty { points = [ncl_point(x: 0, y: 0)] }
        return counts.withUnsafeBufferPointer { cb in
            points.withUnsafeBufferPointer { pb in
                body(ncl_paths_in(path_count: paths.count, counts: cb.baseAddress, points: pb.baseAddress))
            }
        }
    }

    private static func unpack(_ result: UnsafeMutablePointer<ncl_paths>) -> [IntPath] {
        let r = result.pointee
        var out: [IntPath] = []
        out.reserveCapacity(r.path_count)
        var cursor = 0
        for i in 0..<r.path_count {
            let n = r.counts[i]
            var path = IntPath()
            path.reserveCapacity(n)
            for j in 0..<n {
                let p = r.points[cursor + j]
                path.append(IntPoint(x: p.x, y: p.y))
            }
            cursor += n
            out.append(path)
        }
        return out
    }
}

private extension Clipper.JoinType {
    var c: ncl_join {
        switch self {
        case .square: NCL_JOIN_SQUARE
        case .bevel: NCL_JOIN_BEVEL
        case .round: NCL_JOIN_ROUND
        case .miter: NCL_JOIN_MITER
        }
    }
}

private extension Clipper.EndType {
    var c: ncl_end {
        switch self {
        case .polygon: NCL_END_POLYGON
        case .joined: NCL_END_JOINED
        case .butt: NCL_END_BUTT
        case .square: NCL_END_SQUARE
        case .round: NCL_END_ROUND
        }
    }
}

private extension Clipper.FillRule {
    var c: ncl_fill {
        switch self {
        case .evenOdd: NCL_FILL_EVENODD
        case .nonZero: NCL_FILL_NONZERO
        case .positive: NCL_FILL_POSITIVE
        case .negative: NCL_FILL_NEGATIVE
        }
    }
}

private extension Clipper.ClipType {
    var c: ncl_clip {
        switch self {
        case .intersection: NCL_CLIP_INTERSECTION
        case .union: NCL_CLIP_UNION
        case .difference: NCL_CLIP_DIFFERENCE
        case .xor: NCL_CLIP_XOR
        }
    }
}
