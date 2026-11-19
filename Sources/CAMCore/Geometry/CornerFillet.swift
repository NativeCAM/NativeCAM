import Foundation

extension Polyline {
    /// Rounds the convex corners of a closed loop that has its region on the left (outer loops counter-clockwise,
    /// holes clockwise) with tangent arcs, so the controller can keep moving instead of stopping at each corner.
    ///
    /// Each arc comes at most `deviation` inside its corner (the radius that budget allows for the turn,
    /// r = e·cos(α/2)/(1 − cos(α/2)), the same circle as a junction-deviation planner's), and never uses more than
    /// half of either neighbouring segment. Only left turns are rounded, so the region can only shrink: the path
    /// never moves outside where it was. `budget` can lower the deviation per corner (it gets the turn angle).
    ///
    /// A controller already rounds every corner by its own junction tolerance (`plannerDeviation`), so a fillet that
    /// can't use at least twice that (short neighbouring segments) would only add blocks without adding speed:
    /// those corners are left sharp.
    func filletingConvexCorners(deviation: Double, plannerDeviation: Double = 0, minimumTurn: Double = 10.0 * .pi / 180,
                                chordTolerance: Double = 0.005, budget: ((Double) -> Double)? = nil) -> Polyline {
        guard isClosed, points.count >= 3, deviation > 1e-6 else { return self }
        let p = points
        let n = p.count
        var lengths = [Double](repeating: 0, count: n)
        for i in 0..<n { lengths[i] = p[i].distance(to: p[(i + 1) % n]) }
        var out: [Vec2] = []
        out.reserveCapacity(n * 2)
        var changed = false
        for i in 0..<n {
            let prev = p[(i + n - 1) % n], cur = p[i], next = p[(i + 1) % n]
            let lin = lengths[(i + n - 1) % n], lout = lengths[i]
            guard lin > 1e-9, lout > 1e-9 else { out.append(cur); continue }
            let din = (cur - prev) * (1 / lin), dout = (next - cur) * (1 / lout)
            let turn = atan2(din.cross(dout), din.dot(dout))
            let e = min(deviation, budget?(turn) ?? deviation)
            guard turn >= minimumTurn, turn < .pi - 1e-3, e > 1e-6 else { out.append(cur); continue }
            let h = turn / 2
            var r = e * cos(h) / (1 - cos(h))
            var t = r * tan(h)
            let tMax = 0.5 * min(lin, lout)
            if t > tMax { t = tMax; r = t / tan(h) }
            let used = r * (1 - cos(h)) / cos(h)
            guard t > 1e-4, used >= 2 * plannerDeviation else { out.append(cur); continue }
            let t1 = cur - din * t
            let center = t1 + din.perpLeft * r
            let a0 = (t1 - center).angle
            let step = 2 * acos(max(-1, min(1, 1 - chordTolerance / max(r, chordTolerance))))
            let k = max(1, Int((turn / max(step, 1e-3)).rounded(.up)))
            for j in 0...k { out.append(center + Vec2.fromAngle(a0 + turn * Double(j) / Double(k), length: r)) }
            changed = true
        }
        guard changed else { return self }
        return Polyline(out, closed: true).deduplicated()
    }
}
