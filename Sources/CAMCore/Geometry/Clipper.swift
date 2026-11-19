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
