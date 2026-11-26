import Foundation

/// Accumulates motions while tracking the tool position and applying safe-height rules.
///
/// Heights: `clearanceZ` is the rapid-safe height (above the material top), `plungeZ` is where rapids
/// stop and the plunge feed begins. Both are absolute in material coordinates (0 = material top).
struct ToolpathBuilder {
    let clearanceZ: Double
    let plungeZ: Double
    var feedRate: Double
    var plungeRate: Double
    private(set) var position: Vec3
    private(set) var motions: [Motion] = []
    let start: Vec3
    /// No start was given: the toolpath begins wherever its first cut is (see `build`).
    private let startFromFirstMove: Bool

    init(stock: Stock, tool: Tool, startXY: Vec2?) {
        clearanceZ = max(stock.clearanceHeight, stock.plungeHeight)
        plungeZ = max(0.1, stock.plungeHeight)
        feedRate = tool.cutting.feedRate
        plungeRate = tool.cutting.plungeRate
        let s = Vec3(startXY ?? .zero, clearanceZ)
        position = s
        start = s
        startFromFirstMove = startXY == nil
    }

    mutating func rapid(_ p: Vec3) {
        guard p.distance(to: position) > 1e-9 else { return }
        motions.append(.rapid(p))
        position = p
    }

    /// Straight feed move. Steep descents (more than 45°) are plunge-like, so their vertical speed is held to the
    /// plunge rate; the move as a whole runs faster than that instead of crawling at plunge feed. Shallower
    /// descents (ramps, 3D surfaces following roughed stock) keep the cutting feed.
    mutating func feed(_ p: Vec3, rate: Double? = nil) {
        let d = p - position
        guard d.length > 1e-9 else { return }
        var f = rate ?? feedRate
        if rate == nil, d.z < 0, Vec2(d.x, d.y).length < abs(d.z) { f = min(f, plungeRate * d.length / abs(d.z)) }
        motions.append(.feed(p, f))
        position = p
    }

    /// An arc in XY about `center` to `p` (Z changing linearly, so a helix when it changes), turning counter-clockwise
    /// or clockwise seen from above. The caller keeps it under 180°.
    mutating func arc(to p: Vec3, center: Vec2, counterClockwise: Bool, rate: Double) {
        guard p.distance(to: position) > 1e-9 else { return }
        motions.append(Motion(kind: counterClockwise ? .arcCCW : .arcCW, end: p, center: center, feed: rate))
        position = p
    }

    mutating func dwell(_ seconds: Double) {
        guard seconds > 0 else { return }
        motions.append(Motion(kind: .dwell, end: position, feed: seconds))
    }

    /// Rapid up to clearance height if below it.
    mutating func retract() {
        if position.z < clearanceZ - 1e-9 { rapid(Vec3(position.xy, clearanceZ)) }
    }

    /// Moves to `p` from wherever the tool is: retract, rapid over, rapid down to the plunge height, then feed down.
    mutating func enter(at p: Vec3) {
        if !position.xy.isApprox(p.xy, tolerance: 1e-6) {
            retract()
            rapid(Vec3(p.xy, clearanceZ))
        }
        if p.z < plungeZ {
            if position.z > plungeZ { rapid(Vec3(p.xy, plungeZ)) }
            feed(p, rate: plungeRate)
        } else {
            rapid(p)
        }
    }

    /// Feeds through a sequence of 3D points.
    mutating func follow(_ pts: [Vec3]) {
        for p in pts { feed(p) }
    }

    func build(id: UUID, name: String, tool: Tool, rpm: Double, warnings: [String]) -> Toolpath {
        var s = start
        var m = motions[...]
        if startFromFirstMove {
            // Start above the first cut rather than at X0 Y0: drop the opening rapids at clearance height.
            while let first = m.first, first.kind == .rapid, abs(first.end.z - clearanceZ) < 1e-9 {
                s = first.end
                m = m.dropFirst()
            }
        }
        return Toolpath(id: id, name: name, tool: tool, spindleRPM: rpm, start: s, motions: Array(m), warnings: warnings)
    }
}

/// Arc-length parameterisation of a closed loop, used for ramps and tabs.
struct LoopWalker {
    let points: [Vec2]
    /// cumulative[i] = distance from points[0] to points[i]; cumulative[n] = total length.
    let cumulative: [Double]
    var length: Double { cumulative[cumulative.count - 1] }

    init(_ loop: Polyline) {
        points = loop.points
        var c = [0.0]
        c.reserveCapacity(points.count + 1)
        for i in 0..<points.count {
            c.append(c[i] + points[i].distance(to: points[(i + 1) % points.count]))
        }
        cumulative = c
    }

    /// Point at unwrapped arc length `s` (any real value; wraps around the loop).
    func point(at s: Double) -> Vec2 {
        let L = length
        guard L > 0 else { return points.first ?? .zero }
        var d = s.truncatingRemainder(dividingBy: L)
        if d < 0 { d += L }
        // Binary search for the segment.
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid - 1 }
        }
        let i = lo
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? (d - cumulative[i]) / segLen : 0
        return points[i].lerp(to: points[(i + 1) % points.count], t)
    }

    /// Unwrapped arc lengths of every vertex strictly between s0 and s1 (s1 > s0).
    func vertexParams(from s0: Double, to s1: Double) -> [Double] {
        let L = length
        guard L > 0, s1 > s0 else { return [] }
        var out: [Double] = []
        var wrap = (s0 / L).rounded(.down)
        while wrap * L < s1 {
            for i in 0..<points.count {
                let s = wrap * L + cumulative[i]
                if s > s0 + 1e-9 && s < s1 - 1e-9 { out.append(s) }
            }
            wrap += 1
        }
        return out.sorted()
    }

    /// Walks from s0 to s1 emitting 3D points whose height comes from `z(s)`. Discontinuities in `z`
    /// at the given `breaks` produce a vertical step (two points at the same XY).
    func walk(from s0: Double, to s1: Double, breaks: [Double] = [], z: (Double) -> Double) -> [Vec3] {
        var params = vertexParams(from: s0, to: s1)
        params.append(contentsOf: breaks.filter { $0 > s0 + 1e-9 && $0 < s1 - 1e-9 })
        params.append(s1)
        params.sort()
        var out: [Vec3] = []
        let eps = 1e-6
        var last = s0
        for s in params where s - last > 1e-9 || s == s1 {
            let p = point(at: s)
            let zl = z(s - eps), zr = z(s + eps)
            if abs(zl - zr) > 1e-6, s != s1 {
                out.append(Vec3(p, zl))
                out.append(Vec3(p, zr))
            } else {
                out.append(Vec3(p, s == s1 ? z(s - eps) : z(s)))
            }
            last = s
        }
        return out
    }
}

/// 3D Ramer–Douglas–Peucker for dense sampled paths (V-carve).
func simplify3D(_ pts: [Vec3], tolerance: Double) -> [Vec3] {
    guard pts.count > 2 else { return pts }
    func dist(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let l2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
        if l2 < 1e-24 { return p.distance(to: a) }
        let ap = p - a
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / l2))
        return p.distance(to: a + ab * t)
    }
    var keep = [Bool](repeating: false, count: pts.count)
    keep[0] = true
    keep[pts.count - 1] = true
    var stack = [(0, pts.count - 1)]
    while let (s, e) = stack.popLast() {
        guard e > s + 1 else { continue }
        var maxD = -1.0, idx = s
        for i in (s + 1)..<e {
            let d = dist(pts[i], pts[s], pts[e])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > tolerance {
            keep[idx] = true
            stack.append((s, idx))
            stack.append((idx, e))
        }
    }
    return pts.indices.compactMap { keep[$0] ? pts[$0] : nil }
}

/// Orders items greedily by nearest start point, beginning near `from`.
func nearestNeighborOrder<T>(_ items: [T], from: Vec2, start: (T) -> Vec2, end: (T) -> Vec2) -> [T] {
    var remaining = items
    var out: [T] = []
    out.reserveCapacity(items.count)
    var cursor = from
    while !remaining.isEmpty {
        var bestIndex = 0
        var bestD = Double.infinity
        for (i, item) in remaining.enumerated() {
            let d = start(item).distanceSquared(to: cursor)
            if d < bestD { bestD = d; bestIndex = i }
        }
        let item = remaining.remove(at: bestIndex)
        cursor = end(item)
        out.append(item)
    }
    return out
}
