import Foundation

/// Replaces runs of short feed moves with G2/G3 arcs (planar or helical) and merges collinear moves.
///
/// Offsetting and curve flattening produce dense polylines; fitting arcs back in keeps files small and lets
/// Mach4 run smooth constant-velocity arcs. Every fitted arc stays within `tolerance` of the original points
/// and of the original segment midpoints, sweeps less than 180°, and has Z varying linearly with angle.
public enum ArcFitter {
    public static func fit(_ toolpath: Toolpath, tolerance: Double, maxRadius: Double = 2000) -> Toolpath {
        var out = toolpath
        var motions: [Motion] = []
        motions.reserveCapacity(toolpath.motions.count)
        var run: [Vec3] = []      // points of the current feed run, run[0] = start position
        var runFeed = 0.0
        var position = toolpath.start

        func flush() {
            if run.count >= 2 { motions.append(contentsOf: fitRun(run, feed: runFeed, tolerance: tolerance, maxRadius: maxRadius)) }
            run = []
        }

        for m in toolpath.motions {
            if m.kind == .feed {
                if run.isEmpty || abs(m.feed - runFeed) > 1e-9 {
                    flush()
                    run = [position]
                    runFeed = m.feed
                }
                run.append(m.end)
            } else {
                flush()
                motions.append(m)
            }
            position = m.end
        }
        flush()
        out.motions = motions
        return out
    }

    static func fitRun(_ pts: [Vec3], feed: Double, tolerance: Double, maxRadius: Double) -> [Motion] {
        var out: [Motion] = []
        var i = 0
        let n = pts.count
        while i < n - 1 {
            var bestJ = -1
            var bestArc: (center: Vec2, ccw: Bool)?
            var j = i + 2
            // Extend the arc as far as it stays within tolerance (cap work per arc).
            while j < n && j - i <= 600 {
                if let arc = tryArc(pts, i, j, tolerance: tolerance, maxRadius: maxRadius) {
                    bestJ = j
                    bestArc = arc
                    j += 1
                } else {
                    break
                }
            }
            if bestJ > 0, let arc = bestArc {
                out.append(Motion(kind: arc.ccw ? .arcCCW : .arcCW, end: pts[bestJ], center: arc.center, feed: feed))
                i = bestJ
            } else {
                // Merge collinear straight segments.
                var k = i + 1
                while k + 1 < n && collinear(pts[i], pts[k], pts[k + 1], tolerance: tolerance * 0.1) { k += 1 }
                out.append(.feed(pts[k], feed))
                i = k
            }
        }
        return out
    }

    private static func collinear(_ a: Vec3, _ b: Vec3, _ c: Vec3, tolerance: Double) -> Bool {
        let ab = b - a, ac = c - a
        let l = ac.length
        // Back where it started: only a detour of nothing is collinear (an out-and-back move, such as a corner
        // relief, must stay).
        guard l > 1e-12 else { return ab.length <= tolerance }
        // Distance of b from line ac, and b must lie between a and c.
        let t = (ab.x * ac.x + ab.y * ac.y + ab.z * ac.z) / (l * l)
        guard t > 0 && t < 1 else { return false }
        let proj = a + ac * t
        return proj.distance(to: b) <= tolerance
    }

    /// Tries to fit points i...j with one arc; returns centre and direction if all checks pass.
    static func tryArc(_ pts: [Vec3], _ i: Int, _ j: Int, tolerance: Double, maxRadius: Double) -> (center: Vec2, ccw: Bool)? {
        let p0 = pts[i].xy, p2 = pts[j].xy
        let p1 = pts[(i + j) / 2].xy
        guard let c = circumcenter(p0, p1, p2) else { return nil }
        let r = c.distance(to: p0)
        guard r > tolerance * 2, r < maxRadius else { return nil }
        let ccw = (p1 - p0).cross(p2 - p1) > 0
        // Angles must progress monotonically in one direction; total sweep < 180°.
        var total = 0.0
        var prevAngle = (p0 - c).angle
        var angles: [Double] = [0]
        angles.reserveCapacity(j - i + 1)
        for k in (i + 1)...j {
            let q = pts[k].xy
            if abs(q.distance(to: c) - r) > tolerance { return nil }
            let a = (q - c).angle
            var d = a - prevAngle
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            if ccw ? d <= 1e-12 : d >= -1e-12 { return nil }
            total += d
            angles.append(total)
            prevAngle = a
            // Chord midpoint must also be close to the arc (catches big chords that skip across).
            let mid = (pts[k - 1].xy + q) * 0.5
            if r - mid.distance(to: c) > tolerance { return nil }
        }
        guard abs(total) < Double.pi * 0.999 else { return nil }
        // Z must vary linearly with angle (helix) within tolerance.
        let z0 = pts[i].z, z1 = pts[j].z
        for (k, a) in angles.enumerated() {
            let expected = z0 + (z1 - z0) * (a / total)
            if abs(pts[i + k].z - expected) > tolerance { return nil }
        }
        return (c, ccw)
    }

    static func circumcenter(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Vec2? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-12 else { return nil }
        let a2 = a.lengthSquared, b2 = b.lengthSquared, c2 = c.lengthSquared
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        return Vec2(ux, uy)
    }
}
