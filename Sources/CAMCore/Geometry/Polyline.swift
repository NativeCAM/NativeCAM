import Foundation

/// An open or closed polyline in millimetres. Closed polylines do not repeat their first point.
public struct Polyline: Hashable, Codable, Sendable {
    public var points: [Vec2]
    public var isClosed: Bool

    public init(_ points: [Vec2], closed: Bool) {
        self.points = points
        self.isClosed = closed
        if closed, points.count > 1, points[0].isApprox(points[points.count - 1], tolerance: 1e-9) {
            self.points.removeLast()
        }
    }

    public var count: Int { points.count }
    public var isEmpty: Bool { points.isEmpty }

    /// Number of line segments (closing segment included for closed polylines).
    public var segmentCount: Int {
        guard points.count > 1 else { return 0 }
        return isClosed ? points.count : points.count - 1
    }

    public func segment(_ i: Int) -> (Vec2, Vec2) {
        (points[i], points[(i + 1) % points.count])
    }

    /// Shoelace area: positive for counter-clockwise (Y up), negative for clockwise. Zero if open.
    public var signedArea: Double {
        guard isClosed, points.count > 2 else { return 0 }
        var sum = 0.0
        var prev = points[points.count - 1]
        for p in points {
            sum += prev.cross(p)
            prev = p
        }
        return sum * 0.5
    }

    public var area: Double { abs(signedArea) }
    public var isCounterClockwise: Bool { signedArea > 0 }

    public var length: Double {
        var total = 0.0
        for i in 0..<segmentCount {
            let (a, b) = segment(i)
            total += a.distance(to: b)
        }
        return total
    }

    public var bounds: Rect2 {
        points.reduce(Rect2.empty) { $0.union($1) }
    }

    public var reversed: Polyline {
        Polyline(points.reversed(), closed: isClosed)
    }

    /// Returns this polyline oriented counter-clockwise (true) or clockwise (false).
    public func oriented(counterClockwise: Bool) -> Polyline {
        guard isClosed else { return self }
        return isCounterClockwise == counterClockwise ? self : reversed
    }

    public func transformed(_ t: Transform2D) -> Polyline {
        Polyline(points.map(t.apply), closed: isClosed)
    }

    /// Non-zero winding number test. Points exactly on the boundary may go either way.
    public func winding(of p: Vec2) -> Int {
        guard isClosed, points.count > 2 else { return 0 }
        var wn = 0
        var a = points[points.count - 1]
        for b in points {
            if a.y <= p.y {
                if b.y > p.y, (b - a).cross(p - a) > 0 { wn += 1 }
            } else if b.y <= p.y, (b - a).cross(p - a) < 0 {
                wn -= 1
            }
            a = b
        }
        return wn
    }

    public func contains(_ p: Vec2) -> Bool { winding(of: p) != 0 }

    /// A point guaranteed (for simple polygons) to lie strictly inside the closed polyline.
    public func interiorPoint() -> Vec2? {
        guard isClosed, points.count > 2 else { return nil }
        let ccw = isCounterClockwise
        // Step slightly to the inside of the longest edge's midpoint.
        var best = 0
        var bestLen = -1.0
        for i in 0..<segmentCount {
            let (a, b) = segment(i)
            let l = a.distanceSquared(to: b)
            if l > bestLen { bestLen = l; best = i }
        }
        let (a, b) = segment(best)
        let dir = (b - a).normalized
        let inward = ccw ? dir.perpLeft : dir.perpRight
        let mid = (a + b) * 0.5
        var eps = Swift.max(1e-4, sqrt(bestLen) * 1e-3)
        for _ in 0..<12 {
            let candidate = mid + inward * eps
            if contains(candidate) { return candidate }
            eps *= 0.5
        }
        return mid
    }

    /// Point at arc-length distance `s` from the start (wrapping for closed polylines).
    public func point(atDistance s: Double) -> Vec2 {
        guard points.count > 1 else { return points.first ?? .zero }
        let total = length
        var d = s
        if isClosed, total > 0 { d = d.truncatingRemainder(dividingBy: total); if d < 0 { d += total } }
        for i in 0..<segmentCount {
            let (a, b) = segment(i)
            let l = a.distance(to: b)
            if d <= l || i == segmentCount - 1 {
                return l > 0 ? a.lerp(to: b, Swift.min(1, Swift.max(0, d / l))) : a
            }
            d -= l
        }
        return points.last!
    }

    /// Closest point on the polyline to `p`, with the segment index and parameter.
    public func closestPoint(to p: Vec2) -> (point: Vec2, segment: Int, t: Double, distance: Double) {
        var best = (point: points.first ?? .zero, segment: 0, t: 0.0, distance: Double.infinity)
        if points.count == 1 { return (points[0], 0, 0, points[0].distance(to: p)) }
        for i in 0..<segmentCount {
            let (a, b) = segment(i)
            let ab = b - a
            let l2 = ab.lengthSquared
            let t = l2 > 0 ? Swift.max(0, Swift.min(1, (p - a).dot(ab) / l2)) : 0
            let q = a + ab * t
            let d = q.distance(to: p)
            if d < best.distance { best = (q, i, t, d) }
        }
        return best
    }

    /// For closed polylines: rotate the start to the vertex nearest `p`, or insert a new vertex on the
    /// nearest edge so the loop starts as close to `p` as possible.
    public func startingNearest(_ p: Vec2, insertVertex: Bool = true) -> Polyline {
        guard isClosed, points.count > 2 else { return self }
        let c = closestPoint(to: p)
        var pts = points
        var startIndex: Int
        if !insertVertex || c.t < 1e-9 {
            startIndex = c.segment
        } else if c.t > 1 - 1e-9 {
            startIndex = (c.segment + 1) % pts.count
        } else {
            pts.insert(c.point, at: c.segment + 1)
            startIndex = c.segment + 1
        }
        let rotated = Array(pts[startIndex...] + pts[..<startIndex])
        return Polyline(rotated, closed: true)
    }

    /// Ramer–Douglas–Peucker simplification.
    public func simplified(tolerance: Double) -> Polyline {
        guard points.count > 2, tolerance > 0 else { return self }
        if isClosed {
            // Split at the vertex farthest from point 0 so both halves are open chains.
            var far = 0
            var farD = -1.0
            for (i, q) in points.enumerated() {
                let d = q.distanceSquared(to: points[0])
                if d > farD { farD = d; far = i }
            }
            if far == 0 { return self }
            let first = Array(points[0...far])
            let second = Array(points[far...]) + [points[0]]
            let a = Polyline.rdp(first, tolerance)
            let b = Polyline.rdp(second, tolerance)
            var merged = a
            merged.append(contentsOf: b.dropFirst().dropLast())
            return merged.count >= 3 ? Polyline(merged, closed: true) : self
        }
        return Polyline(Polyline.rdp(points, tolerance), closed: false)
    }

    static func rdp(_ pts: [Vec2], _ tol: Double) -> [Vec2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxD = -1.0
            var idx = s
            for i in (s + 1)..<e {
                let d = distancePointSegment(pts[i], pts[s], pts[e])
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tol {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// Removes consecutive duplicate points (and a duplicate closing point).
    public func deduplicated(tolerance: Double = 1e-6) -> Polyline {
        var out: [Vec2] = []
        out.reserveCapacity(points.count)
        for p in points where out.last.map({ !$0.isApprox(p, tolerance: tolerance) }) ?? true {
            out.append(p)
        }
        if isClosed, out.count > 1, out[0].isApprox(out[out.count - 1], tolerance: tolerance) { out.removeLast() }
        return Polyline(out, closed: isClosed)
    }

    /// Points spaced at most `maxSpacing` apart along the polyline (original vertices kept).
    public func densified(maxSpacing: Double) -> Polyline {
        guard maxSpacing > 0, points.count > 1 else { return self }
        var out: [Vec2] = []
        for i in 0..<segmentCount {
            let (a, b) = segment(i)
            out.append(a)
            let n = Int((a.distance(to: b) / maxSpacing).rounded(.up))
            if n > 1 {
                for k in 1..<n { out.append(a.lerp(to: b, Double(k) / Double(n))) }
            }
        }
        if !isClosed, let last = points.last { out.append(last) }
        return Polyline(out, closed: isClosed)
    }
}

@inlinable
public func distancePointSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
    let ab = b - a
    let l2 = ab.lengthSquared
    if l2 <= 1e-24 { return p.distance(to: a) }
    let t = Swift.max(0, Swift.min(1, (p - a).dot(ab) / l2))
    return p.distance(to: a + ab * t)
}

/// Proper segment intersection test (touching counts as intersecting).
public func segmentsIntersect(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2, epsilon: Double = 1e-12) -> Bool {
    let d1 = (p2 - p1).cross(q1 - p1)
    let d2 = (p2 - p1).cross(q2 - p1)
    let d3 = (q2 - q1).cross(p1 - q1)
    let d4 = (q2 - q1).cross(p2 - q1)
    if ((d1 > epsilon && d2 < -epsilon) || (d1 < -epsilon && d2 > epsilon)) &&
        ((d3 > epsilon && d4 < -epsilon) || (d3 < -epsilon && d4 > epsilon)) {
        return true
    }
    func onSegment(_ a: Vec2, _ b: Vec2, _ p: Vec2) -> Bool {
        p.x >= Swift.min(a.x, b.x) - epsilon && p.x <= Swift.max(a.x, b.x) + epsilon &&
            p.y >= Swift.min(a.y, b.y) - epsilon && p.y <= Swift.max(a.y, b.y) + epsilon
    }
    if abs(d1) <= epsilon && onSegment(p1, p2, q1) { return true }
    if abs(d2) <= epsilon && onSegment(p1, p2, q2) { return true }
    if abs(d3) <= epsilon && onSegment(q1, q2, p1) { return true }
    if abs(d4) <= epsilon && onSegment(q1, q2, p2) { return true }
    return false
}

public extension Array where Element == Polyline {
    var bounds: Rect2 { reduce(Rect2.empty) { $0.union($1.bounds) } }
    func transformed(_ t: Transform2D) -> [Polyline] { map { $0.transformed(t) } }
}
