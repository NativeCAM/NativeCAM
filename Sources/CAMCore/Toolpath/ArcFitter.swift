import Foundation

/// Replaces runs of short feed moves with G2/G3 arcs (planar or helical) and merges collinear moves.
///
/// Offsetting and curve flattening produce dense polylines; fitting arcs back in keeps files small and lets
/// Mach4 run smooth constant-velocity arcs. Every fitted arc stays within `tolerance` of the original points
/// and of the original segment midpoints, sweeps less than 180°, and has Z varying linearly with angle.
///
/// A 3D finishing pass follows a surface it must not cut below, and an arc within `tolerance` of its points can still
/// dip under that surface between them (by the plan tolerance times the slope, plus the Z tolerance). Fitted with a
/// `Surface` (`fit(_:for:project:)` does this for 3D finishing), every arc and merged straight move is sampled against
/// the exact drop-cutter surface and kept only where it stays on or above it; elsewhere the points stay straight moves.
public enum ArcFitter {
    /// How far below the drop-cutter surface a fitted move may sample (numeric noise), mm.
    static let surfaceEpsilon = 0.0005
    /// Longest gap between the samples checked against the surface, mm.
    static let surfaceStep = 0.02

    /// The surface a 3D finishing pass promises not to cut below: the tool-tip height the exact drop-cutter gives.
    final class Surface {
        let cutter: TriangleDropCutter
        /// How far below the drop-cutter surface moves may go, mm: 0 for a 3D finish, a flute's depth for flutes that
        /// follow a model.
        let lowered: Double
        var hint: Int32 = -1
        init(_ cutter: TriangleDropCutter, lowered: Double = 0) {
            self.cutter = cutter
            self.lowered = lowered
        }

        /// Whether `q` is no more than `surfaceEpsilon` below the surface (lowered by `lowered`).
        func allows(_ q: Vec3) -> Bool {
            let z = cutter.z(at: q.xy, hint: &hint) - lowered
            return !(z.isFinite && z - q.z > ArcFitter.surfaceEpsilon)
        }

        /// Where (0 to 1) along a move whose point at `t` is `point(t)` a sample at `t = k / n`, 0 < k < n, is below the
        /// surface, or nil when none is. Every fifth sample is tried first, so a move that dips is usually turned down
        /// after a fifth of the work; one that doesn't is checked at every sample.
        func dip(samples n: Int, _ point: (Double) -> Vec3) -> Double? {
            let stride = 5
            for pass in 0..<2 {
                for k in 1..<n where (k % stride == 0) == (pass == 0) {
                    let t = Double(k) / Double(n)
                    if !allows(point(t)) { return t }
                }
            }
            return nil
        }

        /// How far along an arc from `start` through points `gaps` gaps long (0 to 1, by angle) a sample below the
        /// surface is, or nil when none is. Sampled every `surfaceStep`, and at least four times per gap.
        func dip(arc m: Motion, from start: Vec3, gaps: Int) -> Double? {
            let r = start.xy.distance(to: m.center)
            let sweep = m.arcSweep(from: start)
            let n = max(4 * gaps, Int((abs(sweep) * r / ArcFitter.surfaceStep).rounded(.up)))
            let a0 = (start.xy - m.center).angle
            return dip(samples: n) { t in
                Vec3(m.center + Vec2.fromAngle(a0 + sweep * t, length: r), start.z + (m.end.z - start.z) * t)
            }
        }

        /// How far along a straight move from `a` to `b` (0 to 1) a sample below the surface is, or nil when none is.
        /// Sampled every `surfaceStep`.
        func dip(line a: Vec3, _ b: Vec3) -> Double? {
            dip(samples: max(2, Int((a.xy.distance(to: b.xy) / ArcFitter.surfaceStep).rounded(.up)))) { a + (b - a) * $0 }
        }
    }

    /// Fits arcs to a toolpath as `project`'s machine asks (nothing when it posts straight moves). 3D finishing
    /// toolpaths keep only the arcs that stay on or above the drop-cutter surface of `operation`'s models.
    static func fit(_ toolpath: Toolpath, for operation: CAMOperation?, project: Project) -> Toolpath {
        let machine = project.machine
        guard machine.outputArcs else { return toolpath }
        let checked = operation.flatMap { Self.surface(for: $0, tool: toolpath.tool, project: project) }
        return fit(toolpath, tolerance: machine.arcFitTolerance, surface: checked)
    }

    /// The drop-cutter surface a 3D finishing operation's toolpath must stay on or above; nil for every other kind.
    static func surface(for operation: CAMOperation, tool: Tool, project: Project) -> Surface? {
        // A moulding's swept surface, for its finish (and its roughing, which leaves its own allowance on it).
        if case let .moulding(m) = operation.kind {
            guard case let .success(s) = MouldingGenerator.surface(op: operation, params: m, shapes: project.shapes(for: operation)) else {
                return nil
            }
            let roughing = m.roughing.flatMap { $0.tool == tool && tool != operation.tool ? $0 : nil }
            let allowance = roughing?.allowance ?? m.finish.allowance
            guard let cutter = TriangleDropCutter(tool: tool, allowance: allowance, triangles: Model3DGenerator.triangles(of: [s.shape]))
            else { return nil }
            return Surface(cutter)
        }
        // Flutes that follow a model: no move deeper than the flute's depth below the model's surface.
        if case let .fluting(f) = operation.kind, let id = f.surfaceModelID {
            guard case let .success(s) = FlutingGenerator.Surface.make(modelID: id, tool: tool, project: project, stock: project.stock),
                  let cutter = s.flat else { return nil }
            return Surface(cutter, lowered: max(0, f.depth))
        }
        guard case let .finish3D(p) = operation.kind else { return nil }
        let models = project.shapes(for: operation).filter { !$0.isKeepOut && $0.modelSpec != nil }
        guard !models.isEmpty,
              let cutter = TriangleDropCutter(tool: tool, allowance: p.allowance, triangles: Model3DGenerator.triangles(of: models))
        else { return nil }
        return Surface(cutter)
    }

    public static func fit(_ toolpath: Toolpath, tolerance: Double, maxRadius: Double = 2000) -> Toolpath {
        fit(toolpath, tolerance: tolerance, maxRadius: maxRadius, surface: nil)
    }

    static func fit(_ toolpath: Toolpath, tolerance: Double, maxRadius: Double = 2000, surface: Surface?) -> Toolpath {
        var out = toolpath
        var motions: [Motion] = []
        motions.reserveCapacity(toolpath.motions.count)
        var run: [Vec3] = []      // points of the current feed run, run[0] = start position
        var runFeed = 0.0
        var position = toolpath.start

        func flush() {
            if run.count >= 2 { motions.append(contentsOf: fitRun(run, feed: runFeed, tolerance: tolerance, maxRadius: maxRadius,
                                                                 surface: surface)) }
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

    static func fitRun(_ pts: [Vec3], feed: Double, tolerance: Double, maxRadius: Double, surface: Surface? = nil) -> [Motion] {
        var out: [Motion] = []
        var i = 0
        let n = pts.count
        // On a surface: the gap (between this point and the next) where an arc from an earlier start dipped. Arcs from
        // the starts before it stop short of it too, rather than each finding the same dip (a corner of the surface
        // that an arc across it would cut into) from scratch.
        var dipGap = Int.max
        while i < n - 1 {
            if i >= dipGap { dipGap = Int.max }
            var arcs: [Motion] = [] // arcs[k] ends at pts[i + 2 + k]
            var j = i + 2
            // Extend the arc as far as it stays within tolerance (cap work per arc).
            while j < n && j - i <= 600 && j <= dipGap {
                if let arc = tryArc(pts, i, j, tolerance: tolerance, maxRadius: maxRadius) {
                    arcs.append(Motion(kind: arc.ccw ? .arcCCW : .arcCW, end: pts[j], center: arc.center, feed: feed))
                    j += 1
                } else {
                    break
                }
            }
            var chosen = arcs.indices.last
            if let surface, let last = chosen {
                // The longest arc that stays on the surface. Where one dips, the next tried ends at the last point before
                // the dip (by length along the points), and a check that finds a dip stops there.
                chosen = nil
                var k = last
                while k >= 0 {
                    var t = surface.dip(arc: arcs[k], from: pts[i], gaps: k + 2)
                    // Where the arc through the middle point dips, one bulging a little to either side may not.
                    for bulge in [0.5, -0.5] where t != nil {
                        guard let arc = tryArc(pts, i, i + 2 + k, tolerance: tolerance, maxRadius: maxRadius,
                                               bulge: bulge * tolerance) else { continue }
                        let m = Motion(kind: arc.ccw ? .arcCCW : .arcCW, end: pts[i + 2 + k], center: arc.center, feed: feed)
                        if let dip = surface.dip(arc: m, from: pts[i], gaps: k + 2) {
                            t = max(t!, dip)
                        } else {
                            arcs[k] = m
                            t = nil
                        }
                    }
                    guard let t else {
                        chosen = k
                        break
                    }
                    let end = i + 2 + k
                    var total = 0.0
                    for e in i..<end { total += pts[e].xy.distance(to: pts[e + 1].xy) }
                    var along = 0.0, e = i
                    while e < end && along + pts[e].xy.distance(to: pts[e + 1].xy) < t * total {
                        along += pts[e].xy.distance(to: pts[e + 1].xy)
                        e += 1
                    }
                    dipGap = min(dipGap, e)
                    k = min(k - 1, e - i - 2)
                }
            }
            if let k = chosen {
                out.append(arcs[k])
                i += k + 2
            } else {
                // Merge collinear straight segments (on a surface, only as far as the merged move stays on it).
                var k = i + 1
                while k + 1 < n && collinear(pts[i], pts[k], pts[k + 1], tolerance: tolerance * 0.1) { k += 1 }
                if let surface {
                    // Back to the last point before a dip, until the move stays on the surface.
                    while k > i + 1, let t = surface.dip(line: pts[i], pts[k]) {
                        var e = k - 1
                        while e > i + 1 && pts[i].xy.distance(to: pts[e].xy) >= t * pts[i].xy.distance(to: pts[k].xy) { e -= 1 }
                        k = e
                    }
                }
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
    /// `bulge` moves the arc's middle that far out from its centre (negative: in), keeping its ends, for an arc that
    /// stays clear of a surface the arc through the middle point would dip into.
    static func tryArc(_ pts: [Vec3], _ i: Int, _ j: Int, tolerance: Double, maxRadius: Double,
                       bulge: Double = 0) -> (center: Vec2, ccw: Bool)? {
        let p0 = pts[i].xy, p2 = pts[j].xy
        var p1 = pts[(i + j) / 2].xy
        guard var c = circumcenter(p0, p1, p2) else { return nil }
        if bulge != 0 {
            let out = p1 - c
            let l = out.length
            guard l > 1e-12 else { return nil }
            p1 = p1 + out * (bulge / l)
            guard let moved = circumcenter(p0, p1, p2) else { return nil }
            c = moved
        }
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
