import Foundation

/// Dogbone and T-bone reliefs: short out-and-back spikes added to a tool-centre loop at the inside corners a round
/// bit can't reach, so the bit's edge just touches the drawn corner and square parts fit.
///
/// The offset that makes a tool-centre loop rounds every corner the bit can follow (round joins), so a sharp vertex
/// that turns toward the waste is a corner the bit can't reach: the corners of an inside cut or pocket, the inside
/// corners of an outside cut (finger joints, notches, holes in a part) and of islands. Its corner angle θ (180° minus
/// the turn) is the angle of the cut-away wedge, 90° for a square corner.
///
/// The drawn corner is found by casting a ray from the vertex C along the bisector w against the toolpath's own
/// drawn loops, which hits it at H. With o the distance from the drawn wall to the tool centre (radius + allowance),
/// a sharp corner is o / sin(θ/2) from C; a hit farther out isn't a corner but a pinch between separate features (an
/// island near a wall), so it's left alone, as is a corner the bit already reaches (rounded at or above its radius).
/// - Dogbone: out along w to C + (h − o)·w, where the bit just touches H.
/// - T-bone: along one wall's tool line to the point nearest H, so the notch is only in the other wall.
/// A relief that would come within o of any other drawn geometry is skipped and counted.
enum CornerRelief {
    struct Relief: Hashable, Sendable {
        /// The loop vertex the relief leaves from and returns to.
        var corner: Vec2
        /// Where the tool centre goes.
        var tip: Vec2
    }

    struct Plan {
        var reliefs: [Relief] = []
        /// Corners left alone because their relief would cut into other drawn geometry.
        var blocked = 0
    }

    /// Distance tolerance for matching the drawn corner, mm.
    static let tolerance = 0.02
    /// Vertices closer than this count as one corner (tiny chamfers from imported drawings), mm.
    static let mergeDistance = 0.05

    /// Plans the reliefs for one tool-centre loop. `wasteOnLeft` is the waste side for the loop's direction;
    /// `offset` is the distance from the drawn wall to the tool centre (tool radius + allowance).
    static func plan(_ loop: Polyline, wasteOnLeft: Bool, design: Design, offset o: Double,
                     settings: CornerReliefSettings) -> Plan {
        let pts = loop.points
        let n = pts.count
        var plan = Plan()
        guard loop.isClosed, n >= 3, o > 1e-6, !design.loops.isEmpty else { return plan }
        let maxAngle = min(179, max(1, settings.maxCornerAngle)) * .pi / 180
        // Half a degree of slack, so a corner exactly at the limit (a hexagon at 120°) counts.
        let minTurn = .pi - maxAngle - 0.5 * .pi / 180

        func neighbour(_ i: Int, _ step: Int) -> Int? {
            var j = i
            for _ in 0..<(n - 1) {
                j = (j + step + n) % n
                if pts[j].distance(to: pts[i]) >= mergeDistance { return j }
            }
            return nil
        }
        struct Candidate { var i: Int; var turn: Double; var din: Vec2; var dout: Vec2; var a: Int; var c: Int }
        var candidates: [Candidate] = []
        for i in 0..<n {
            guard let a = neighbour(i, -1), let c = neighbour(i, 1) else { continue }
            let din = (pts[i] - pts[a]).normalized, dout = (pts[c] - pts[i]).normalized
            var turn = atan2(din.cross(dout), din.dot(dout))
            if !wasteOnLeft { turn = -turn }
            guard turn >= minTurn, turn < .pi - 1e-3 else { continue }
            // A corner split over vertices closer than the merge distance: keep its sharpest vertex.
            if let k = candidates.lastIndex(where: { pts[$0.i].distance(to: pts[i]) < mergeDistance }) {
                if turn > candidates[k].turn { candidates[k] = Candidate(i: i, turn: turn, din: din, dout: dout, a: a, c: c) }
                continue
            }
            candidates.append(Candidate(i: i, turn: turn, din: din, dout: dout, a: a, c: c))
        }
        if candidates.count > 1, let first = candidates.first, let last = candidates.last,
           pts[first.i].distance(to: pts[last.i]) < mergeDistance {
            if last.turn > first.turn { candidates[0] = last }
            candidates.removeLast()
        }

        for cand in candidates {
            let c = pts[cand.i]
            let half = (.pi - cand.turn) / 2
            let bisector = cand.din - cand.dout
            guard bisector.length > 1e-9 else { continue }
            let w = bisector.normalized
            let reach = o / sin(half)
            guard let hit = design.ray(from: c, direction: w, maxDistance: reach + tolerance) else { continue }
            let depth = hit.distance - o
            guard depth >= 0.01 else { continue }
            // Both walls must be offsets of the drawn corner's own loop, close to it along that loop; otherwise
            // the sharp vertex is where two separate features (or the two sides of a narrow inlet) meet.
            let window = 2 * reach + tolerance
            let delta = min(o, 0.5 * c.distance(to: pts[cand.a]), 0.5 * c.distance(to: pts[cand.c]))
            guard design.isWall(near: c - cand.din * delta, of: hit, within: window, searchRadius: o + 0.1),
                  design.isWall(near: c + cand.dout * delta, of: hit, within: window, searchRadius: o + 0.1) else { continue }

            let tip: Vec2
            switch settings.style {
            case .dogbone:
                tip = c + w * depth
            case .tBone:
                // The notch goes into one wall: travel along the other wall's tool line until the bit touches H.
                let notchInOutgoing = notchGoesIntoOutgoingWall(pts, cand.i, din: cand.din, dout: cand.dout,
                                                                previous: pts[cand.a], next: pts[cand.c], side: settings.tBoneSide)
                let e = notchInOutgoing ? cand.din : -cand.dout
                let along = (hit.point - c).dot(e)
                guard along >= 0.01 else { continue }
                tip = c + e * along
            }
            if design.blocks(from: c, to: tip, clearance: o - 0.01, except: hit, within: window + 2 * o) {
                plan.blocked += 1
                continue
            }
            plan.reliefs.append(Relief(corner: c, tip: tip))
        }
        return plan
    }

    /// Adds each relief's out-and-back spike at its corner vertex.
    static func insert(_ reliefs: [Relief], into loop: Polyline) -> Polyline {
        guard !reliefs.isEmpty, loop.isClosed else { return loop }
        var out: [Vec2] = []
        out.reserveCapacity(loop.count + reliefs.count * 2)
        for p in loop.points {
            out.append(p)
            if let r = reliefs.first(where: { $0.corner.isApprox(p, tolerance: 1e-9) }) {
                out.append(r.tip)
                out.append(p)
            }
        }
        return Polyline(out, closed: true)
    }

    /// T-bone side: decided from the walls themselves (their length or direction), never from the direction of
    /// travel, so climb and conventional cut the same notch.
    static func notchGoesIntoOutgoingWall(_ pts: [Vec2], _ i: Int, din: Vec2, dout: Vec2, previous: Vec2, next: Vec2,
                                          side: TBoneSide) -> Bool {
        let lenIn = straightRun(pts, from: i, step: -1, direction: din)
        let lenOut = straightRun(pts, from: i, step: 1, direction: dout)
        // Last resort, for walls alike in every way: the wall whose midpoint is lower, then further left.
        let midIn = (previous + pts[i]) * 0.5, midOut = (pts[i] + next) * 0.5
        let lowerIsOutgoing = abs(midOut.y - midIn.y) > 1e-9 ? midOut.y < midIn.y : midOut.x < midIn.x
        func alongX() -> Bool {
            let ax = abs(dout.x) - abs(din.x)
            return abs(ax) > 1e-9 ? ax > 0 : lowerIsOutgoing
        }
        func alongY() -> Bool {
            let ay = abs(dout.y) - abs(din.y)
            return abs(ay) > 1e-9 ? ay > 0 : lowerIsOutgoing
        }
        switch side {
        case .longer: return abs(lenOut - lenIn) > 1e-6 ? lenOut > lenIn : alongX()
        case .shorter: return abs(lenOut - lenIn) > 1e-6 ? lenOut < lenIn : alongX()
        case .alongX: return alongX()
        case .alongY: return alongY()
        }
    }

    /// Length of the straight run of the loop leaving vertex `i` (backward for step −1), within 2° of `direction`.
    static func straightRun(_ pts: [Vec2], from i: Int, step: Int, direction: Vec2) -> Double {
        let n = pts.count
        let limit = cos(2 * Double.pi / 180)
        var total = 0.0
        var j = i
        for _ in 0..<n {
            let k = (j + step + n) % n
            let seg = step > 0 ? pts[k] - pts[j] : pts[j] - pts[k]
            let l = seg.length
            if l > 1e-12 {
                if (seg / l).dot(direction) < limit { break }
                total += l
            }
            j = k
            if j == i { break }
        }
        return total
    }

    // MARK: Drawn geometry

    /// The drawn loops a toolpath was offset from, indexed for ray casts and nearest-point queries.
    struct Design {
        let loops: [Polyline]
        let bounds: [Rect2]
        /// cumulative[k][j]: arc length from loop k's first point to its point j; the last entry is the length.
        let cumulative: [[Double]]

        init(_ loops: [Polyline]) {
            let closed = loops.filter { $0.isClosed && $0.count >= 2 }
            self.loops = closed
            bounds = closed.map(\.bounds)
            cumulative = closed.map { l in
                var c = [0.0]
                c.reserveCapacity(l.count + 1)
                for j in 0..<l.count { c.append(c[j] + l.points[j].distance(to: l.points[(j + 1) % l.count])) }
                return c
            }
        }

        struct Hit {
            var distance: Double
            var point: Vec2
            var loop: Int
            /// Arc-length position of the hit along its loop.
            var s: Double
        }

        /// First drawn boundary along a ray, within `maxDistance`.
        func ray(from o: Vec2, direction w: Vec2, maxDistance: Double) -> Hit? {
            let reach = Rect2.empty.union(o).union(o + w * maxDistance)
            var best: Hit?
            for (k, loop) in loops.enumerated() where bounds[k].intersects(reach) {
                let p = loop.points
                for j in 0..<p.count {
                    let a = p[j], b = p[(j + 1) % p.count]
                    let e = b - a
                    let denom = w.cross(e)
                    guard abs(denom) > 1e-12 else { continue }
                    let ao = a - o
                    let t = ao.cross(e) / denom
                    let u = ao.cross(w) / denom
                    guard t >= 0, t <= maxDistance, u >= -1e-9, u <= 1 + 1e-9 else { continue }
                    if t < (best?.distance ?? .infinity) {
                        let uc = min(1, max(0, u))
                        best = Hit(distance: t, point: a + e * uc, loop: k, s: cumulative[k][j] + e.length * uc)
                    }
                }
            }
            return best
        }

        /// Arc distance along loop k between position s and the stretch [s0, s1].
        func along(_ k: Int, _ s: Double, _ s0: Double, _ s1: Double) -> Double {
            if s >= s0 && s <= s1 { return 0 }
            let L = cumulative[k].last ?? 0
            func circ(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, L - d) }
            return min(circ(s, s0), circ(s, s1))
        }

        /// Whether the drawn boundary nearest `p` is on the hit's loop within `window` of it (so the tool edge at
        /// `p` is an offset of the corner's own wall).
        func isWall(near p: Vec2, of hit: Hit, within window: Double, searchRadius: Double) -> Bool {
            var bestD = Double.infinity, bestLoop = -1, bestS = 0.0
            for (k, loop) in loops.enumerated() where bounds[k].contains(p, tolerance: searchRadius) {
                let c = loop.closestPoint(to: p)
                if c.distance < bestD {
                    bestD = c.distance
                    bestLoop = k
                    let a = loop.points[c.segment], b = loop.points[(c.segment + 1) % loop.count]
                    bestS = cumulative[k][c.segment] + a.distance(to: b) * c.t
                }
            }
            guard bestLoop == hit.loop, bestD <= searchRadius else { return false }
            return along(bestLoop, bestS, hit.s, hit.s) <= window
        }

        /// Whether the straight move a→b passes within `clearance` of drawn geometry other than the stretch of the
        /// hit's loop within `window` of it.
        func blocks(from a: Vec2, to b: Vec2, clearance: Double, except hit: Hit, within window: Double) -> Bool {
            let box = Rect2.empty.union(a).union(b).insetBy(-clearance)
            for (k, loop) in loops.enumerated() where bounds[k].intersects(box) {
                let p = loop.points
                for j in 0..<p.count {
                    let q0 = p[j], q1 = p[(j + 1) % p.count]
                    if k == hit.loop, along(k, hit.s, cumulative[k][j], cumulative[k][j + 1]) <= window { continue }
                    if segmentDistance(a, b, q0, q1) < clearance { return true }
                }
            }
            return false
        }
    }

    static func segmentDistance(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(distancePointSegment(a, c, d), distancePointSegment(b, c, d),
                   distancePointSegment(c, a, b), distancePointSegment(d, a, b))
    }
}
