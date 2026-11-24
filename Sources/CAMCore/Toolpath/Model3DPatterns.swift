import Foundation
import simd

/// 3D finishing patterns that don't run in rows: constant scallop (3D offset), spiral and radial. Each lays out its
/// passes in plan, drops them onto the model with the exact drop-cutter (as raster rows are) and links them with feeds
/// along the surface where they're close, or up and over, which the job's link optimiser lowers to the minimum height.
extension Model3DGenerator {
    /// One finishing pass, dropped onto the surface, in the order and direction it's cut. A closed pass (first point
    /// = last) may start anywhere round it.
    struct Pass {
        var points: [Vec3]
        var closed: Bool
        /// Passes are cut a group at a time, in order; within a group the nearest goes next.
        var group: Int
    }

    /// Constant scallop, spiral or radial passes inside the boundary; false when none fit.
    static func pattern(_ f: Finishing, _ b: inout ToolpathBuilder, warnings: inout [String]) -> Bool {
        let map = f.buildMap()
        let inside = regionMask(f.setup.boundary, f.setup.surface)
        // Hops up to a bit width stay down, along the surface: where a spiral turn grazes the boundary it leaves and
        // comes back in a little way along.
        var hop = max(f.linkLimit, f.tool.diameter)
        let passes: [Pass]
        switch f.params.strategy {
        case .constantScallop:
            passes = constantScallopPasses(map, inside: inside, f)
        case .spiral:
            passes = spiralPasses(f, warnings: &warnings)
        case .radial:
            // Spokes start at different distances from the centre, so the hop between one's inner end and the next's
            // can be long; it's still along the surface, over ground the spokes around it cut.
            passes = radialPasses(f, warnings: &warnings)
            hop = .infinity
        default:
            return false
        }
        guard passes.contains(where: { $0.points.count >= 2 }) else { return false }
        cutPasses(passes, f, &b, hop: hop)
        warnings += coverageWarnings(passes.map(\.points), map: map, inside: inside, f)
        return true
    }

    // MARK: Constant scallop

    /// Passes a stepover apart along the CL surface: the iso-lines of geodesic distance from the boundary (see
    /// `GeodesicField`), outermost first, climb milled (the higher ground inside a pass on its right). Where the
    /// distance tops out between two levels (round a peak, along a ridge) more than half a stepover above the last,
    /// a pass halfway between fills in, so nowhere is more than half a stepover from a pass.
    static func constantScallopPasses(_ map: CLMap, inside: [Bool], _ f: Finishing) -> [Pass] {
        let s = f.stepover
        let field = GeodesicField(map: map, inside: inside, boundary: f.setup.boundary.flatMap(\.loops))
        let top = field.maximum
        guard top > 1e-6 else { return [] }
        var levels: [Double] = Array(stride(from: s / 2, to: top, by: s))
        if levels.isEmpty { levels = [top / 2] }
        let values = field.distance.map { Float(-$0) }
        let cols = map.columns, rows = map.rows
        func contour(_ level: Double, mask: [Bool]) -> [Polyline] {
            GridContours.loops(mask: mask, columns: cols, rows: rows, origin: map.origin, cellSize: map.pitch,
                               field: values, level: Float(-level), steepSlope: .infinity, interpolationLimit: 0.5)
        }
        // Each level, then (where needed) the half level above it: (level value, loops).
        var jobs: [(Double, Bool)] = []
        for (k, level) in levels.enumerated() {
            jobs.append((level, false))
            let half = level + s / 2
            if half < top, k + 1 == levels.count || half < levels[k + 1] { jobs.append((half, true)) }
        }
        let found = ParallelResults<[Polyline]>(count: jobs.count, initial: [])
        DispatchQueue.concurrentPerform(iterations: jobs.count) { j in
            let (level, isHalf) = jobs[j]
            var mask = field.distance.map { $0 >= level }
            if isHalf {
                // Only where the distance tops out below the next level: elsewhere that level's passes are close enough.
                mask = Self.componentsBelow(mask, field.distance, columns: cols, rows: rows, peak: level + s / 2)
            }
            found[j] = contour(level, mask: mask).map { Polyline($0.points.reversed(), closed: true).simplified(tolerance: f.tolerance / 2) }
        }
        var loops: [(points: [Vec2], group: Int)] = []
        for (j, list) in found.array.enumerated() {
            for loop in list where loop.points.count >= 3 { loops.append((loop.points, j)) }
        }
        let dropped = ParallelResults<[Vec3]>(count: loops.count, initial: [])
        DispatchQueue.concurrentPerform(iterations: loops.count) { i in
            dropped[i] = drop(loops[i].points + [loops[i].points[0]], f)
        }
        return dropped.array.enumerated().compactMap { i, pts in
            pts.count >= 2 ? Pass(points: pts, closed: true, group: loops[i].group) : nil
        }
    }

    /// `mask` keeping only its 4-connected pieces whose highest `value` is below `peak`.
    static func componentsBelow(_ mask: [Bool], _ value: [Double], columns: Int, rows: Int, peak: Double) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        var seen = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        var piece: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            seen[start] = true
            stack = [start]
            piece = []
            var high = -Double.infinity
            while let i = stack.popLast() {
                piece.append(i)
                high = max(high, value[i])
                let c = i % columns, r = i / columns
                for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let cc = c + dc, rr = r + dr
                    guard cc >= 0, rr >= 0, cc < columns, rr < rows else { continue }
                    let j = rr * columns + cc
                    if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            if high < peak { for i in piece { out[i] = true } }
        }
        return out
    }

    // MARK: Spiral and radial

    /// The centre a spiral or radial works out from: the one set, or the boundary's centroid. One outside the
    /// boundary altogether (not in a hole of it) moves to the nearest point on the boundary, with a warning.
    static func patternCentre(_ f: Finishing, warnings: inout [String]) -> Vec2 {
        let regions = f.setup.boundary
        let wanted = f.params.centre ?? centroid(regions)
        guard !regions.contains(where: { $0.outer.contains(wanted) }) else { return wanted }
        var best = (point: wanted, distance: Double.infinity)
        for r in regions {
            let c = r.outer.closestPoint(to: wanted)
            if c.distance < best.distance { best = (c.point, c.distance) }
        }
        let u = f.context.units
        let what = f.params.strategy == .spiral ? "spiral" : "radial"
        warnings.append("The \(what)'s centre (\(u.format(wanted.x)), \(u.format(wanted.y)) \(u.symbol)) is outside the boundary, "
            + "so it starts from the nearest point on it, (\(u.format(best.point.x)), \(u.format(best.point.y)) \(u.symbol)), instead.")
        return best.point
    }

    /// Area centroid of the regions (holes taken out).
    static func centroid(_ regions: [Region]) -> Vec2 {
        var area = 0.0, sum = Vec2.zero
        for r in regions {
            for (k, loop) in r.loops.enumerated() {
                var a = 0.0, cx = 0.0, cy = 0.0
                let p = loop.points
                for i in p.indices {
                    let q = p[i], n = p[(i + 1) % p.count]
                    let w = q.x * n.y - n.x * q.y
                    a += w
                    cx += (q.x + n.x) * w
                    cy += (q.y + n.y) * w
                }
                guard abs(a) > 1e-12 else { continue }
                // The outer loop adds and holes take away, whichever way they wind.
                let loopArea = abs(a) / 2 * (k == 0 ? 1 : -1)
                area += loopArea
                sum = sum + Vec2(cx / (3 * a), cy / (3 * a)) * loopArea
            }
        }
        guard abs(area) > 1e-9 else { return regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }.center }
        return sum / area
    }

    /// The farthest the boundary reaches from `centre`.
    static func reach(from centre: Vec2, _ f: Finishing) -> Double {
        f.setup.boundary.flatMap(\.loops).flatMap(\.points).reduce(0) { max($0, $1.distance(to: centre)) }
    }

    /// Whether the tool centre may be at p.
    static func inBoundary(_ p: Vec2, _ f: Finishing) -> Bool { f.setup.boundary.contains { $0.contains(p) } }

    /// The runs of a sampled path that lie inside the boundary, each ending where the path crosses it.
    static func runsInside(_ pts: [Vec2], _ f: Finishing) -> [[Vec2]] {
        guard let first = pts.first else { return [] }
        func crossing(_ a: Vec2, _ b: Vec2) -> Vec2 { // a inside, b outside
            var lo = a, hi = b
            for _ in 0..<24 {
                let m = lo.lerp(to: hi, 0.5)
                if inBoundary(m, f) { lo = m } else { hi = m }
            }
            return lo
        }
        var runs: [[Vec2]] = []
        var run: [Vec2] = []
        var was = inBoundary(first, f)
        if was { run.append(first) }
        for i in 1..<pts.count {
            let p = pts[i]
            let now = inBoundary(p, f)
            if now && was {
                run.append(p)
            } else if now {
                run = [crossing(p, pts[i - 1]), p]
            } else if was {
                run.append(crossing(pts[i - 1], p))
                if run.count >= 2 { runs.append(run) }
                run = []
            }
            was = now
        }
        if run.count >= 2 { runs.append(run) }
        return runs
    }

    /// A path dropped onto the surface: sampled every `ds`, split where moves would cut in, simplified.
    static func drop(_ path: [Vec2], _ f: Finishing) -> [Vec3] {
        guard path.count >= 2 else { return [] }
        var pts: [Vec3] = []
        var hint: Int32 = -1
        pts.append(Vec3(path[0], f.z(path[0], hint: &hint)))
        for k in 1..<path.count {
            let a = path[k - 1], q = path[k]
            let n = max(1, Int((a.distance(to: q) / f.ds).rounded(.up)))
            for i in 1...n {
                let p = a.lerp(to: q, Double(i) / Double(n))
                pts.append(Vec3(p, f.z(p, hint: &hint)))
            }
        }
        return simplify3D(f.refined(pts, hint: &hint), tolerance: f.tolerance)
    }

    /// An Archimedean spiral from the centre out past the boundary's farthest point, counter-clockwise (climb milling:
    /// the uncut ground outside the turn is on its right), clipped to the boundary. Its turns are a stepover apart in
    /// plan, or with `spiralHoldsScallop` a stepover apart along the surface where it slopes across them.
    static func spiralPasses(_ f: Finishing, warnings: inout [String]) -> [Pass] {
        let centre = patternCentre(f, warnings: &warnings)
        let s = f.stepover
        let end = reach(from: centre, f) + s
        let holds = f.params.spiralHoldsScallop
        let tightest = s * cos(75 * Double.pi / 180)
        var pts: [Vec2] = []
        var theta = 0.0, r = 0.0
        var hint: Int32 = -1
        let delta = max(f.cell, s / 4)
        while r <= end {
            let u = Vec2(cos(theta), sin(theta))
            let p = centre + u * r
            pts.append(p)
            var pitch = s
            if holds, r > delta {
                let g = (f.z(p + u * delta, hint: &hint) - f.z(p - u * delta, hint: &hint)) / (2 * delta)
                pitch = max(tightest, s / (1 + g * g).squareRoot())
            }
            let dr = pitch / (2 * Double.pi)
            let dTheta = f.ds / (r * r + dr * dr).squareRoot()
            theta += dTheta
            r += dr * dTheta
        }
        let runs = runsInside(pts, f)
        let dropped = ParallelResults<[Vec3]>(count: runs.count, initial: [])
        DispatchQueue.concurrentPerform(iterations: runs.count) { i in dropped[i] = drop(runs[i], f) }
        return dropped.array.enumerated().map { Pass(points: $1, closed: false, group: $0) }
    }

    /// Spokes from the centre at the angular step, alternately out and back in, clipped to the boundary. Near the
    /// centre, where the spokes crowd together, each stops where it would come closer than the minimum spacing to one
    /// cut further in (every other spoke first, then every other of those, and so on), so only a few reach the
    /// middle.
    static func radialPasses(_ f: Finishing, warnings: inout [String]) -> [Pass] {
        let centre = patternCentre(f, warnings: &warnings)
        let s = f.stepover
        let far = reach(from: centre, f)
        let spacing = max(f.cell, f.params.radialMinSpacing ?? s / 2)
        let wanted = f.params.radialStep ?? (far > 1e-6 ? s / far * 180 / Double.pi : 45)
        let n = max(4, min(3600, Int((360 / min(45, max(0.1, wanted))).rounded())))
        let step = 2 * Double.pi / Double(n)
        let start = spokeStarts(count: n, spacing: spacing)
        var lines: [[Vec2]] = []
        var spoke = 0
        for k in 0..<n where start[k] < far {
            let u = Vec2.fromAngle(Double(k) * step)
            let a = centre + u * start[k], z = centre + u * (far + s)
            let count = max(1, Int((a.distance(to: z) / f.ds).rounded(.up)))
            let samples = (0...count).map { a.lerp(to: z, Double($0) / Double(count)) }
            var runs = runsInside(samples, f)
            // Every other spoke comes back in, so each starts near where the last ended.
            if spoke % 2 == 1 { runs = runs.reversed().map { Array($0.reversed()) } }
            lines += runs
            spoke += 1
        }
        let dropped = ParallelResults<[Vec3]>(count: lines.count, initial: [])
        DispatchQueue.concurrentPerform(iterations: lines.count) { i in dropped[i] = drop(lines[i], f) }
        return dropped.array.enumerated().compactMap { i, p in p.count >= 2 ? Pass(points: p, closed: false, group: i) : nil }
    }

    /// How far from the centre each of `n` evenly spaced spokes starts so that no two come closer than `spacing`
    /// (chord between them at the same radius). Spokes are placed in turn, spoke 0 first (it reaches the centre),
    /// then by how many times 2 divides their number (every other spoke, then every other of the rest, ...), each
    /// starting where it's `spacing` from the nearest spoke placed before it.
    static func spokeStarts(count n: Int, spacing: Double) -> [Double] {
        let step = 2 * Double.pi / Double(n)
        func rank(_ k: Int) -> Int { k == 0 ? Int.max : k.trailingZeroBitCount }
        let order = (0..<n).sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0 < $1 }
        var start = [Double](repeating: 0, count: n)
        var placed: [Int] = []
        placed.reserveCapacity(n)
        for k in order {
            var gap = Int.max
            for j in placed {
                let d = abs(j - k) % n
                gap = min(gap, min(d, n - d))
            }
            if gap != Int.max { start[k] = spacing / (2 * sin(Double(gap) * step / 2)) }
            placed.append(k)
        }
        return start
    }

    // MARK: Linking

    /// A feed from the tool's position to `to` along the surface, every point of it inside the boundary and clear of
    /// the clamps; nil when the hop is longer than `limit` or leaves the boundary.
    static func boundedLink(from a: Vec3, to b: Vec3, limit: Double, _ f: Finishing) -> [Vec3]? {
        let hop = a.xy.distance(to: b.xy)
        guard hop <= limit, f.clearOfKeepOuts(a.xy, b.xy) else { return nil }
        let k = max(1, Int((hop / f.ds).rounded(.up)))
        var out: [Vec3] = [a]
        var hint: Int32 = -1
        for i in 1...k {
            let p = a.xy.lerp(to: b.xy, Double(i) / Double(k))
            guard f.insideBoundary(p) else { return nil }
            out.append(Vec3(p, f.z(p, hint: &hint)))
        }
        out[out.count - 1] = b
        return Array(f.refined(out, hint: &hint).dropFirst())
    }

    /// Cuts the passes a group at a time (nearest first within a group, a closed pass from its nearest point), each
    /// joined to the last along the surface when it's within `hop`, otherwise entered from above (ramping in along
    /// it with smooth links).
    static func cutPasses(_ passes: [Pass], _ f: Finishing, _ b: inout ToolpathBuilder, hop: Double) {
        var byGroup: [Int: [Int]] = [:]
        for (i, p) in passes.enumerated() where p.points.count >= 2 { byGroup[p.group, default: []].append(i) }
        var first = b.motions.isEmpty
        for g in byGroup.keys.sorted() {
            var remaining = byGroup[g]!
            while !remaining.isEmpty {
                let here = b.position.xy
                var pick = (index: 0, start: 0, distance: Double.infinity)
                for (n, i) in remaining.enumerated() {
                    let pts = passes[i].points
                    if passes[i].closed {
                        for (k, q) in pts.enumerated().dropLast() {
                            let d = first ? Double(k) : q.xy.distance(to: here)
                            if d < pick.distance { pick = (n, k, d) }
                        }
                    } else {
                        let d = first ? 0 : pts[0].xy.distance(to: here)
                        if d < pick.distance { pick = (n, 0, d) }
                    }
                }
                let i = remaining.remove(at: pick.index)
                var pts = passes[i].points
                if passes[i].closed, pick.start > 0 {
                    pts = Array(pts[pick.start..<(pts.count - 1)]) + Array(pts[0...pick.start])
                }
                let start = pts[0]
                if !first, b.position.z < f.setup.stock.plungeHeight,
                   let link = boundedLink(from: b.position, to: start, limit: hop, f) {
                    b.follow(link)
                } else if f.params.smoothLinks {
                    let d = (pts[1].xy - start.xy)
                    enter(start, travelling: d.lengthSquared > 1e-12 ? d.normalized : Vec2(1, 0), f, &b)
                } else {
                    b.enter(at: start)
                }
                b.follow(Array(pts.dropFirst()))
                first = false
            }
        }
    }

    // MARK: Checks

    /// What the passes leave, for Checks: where neighbouring passes are farther apart than the stepover (so the scallop
    /// there is over 1.5× the target), where they leave gaps the bit doesn't reach, and when they bunch up (running
    /// far longer than the area needs). Measured at the CL map's nodes, as the distance in 3D from the tip's place on
    /// the surface to the nearest pass.
    static func coverageWarnings(_ passes: [[Vec3]], map: CLMap, inside: [Bool], _ f: Finishing) -> [String] {
        let s = f.stepover
        let bucket = s
        var segments: [(SIMD3<Double>, SIMD3<Double>)] = []
        var buckets: [SIMD2<Int32>: [Int32]] = [:]
        var length = 0.0
        for pass in passes {
            for k in 1..<max(1, pass.count) {
                let a = SIMD3(pass[k - 1].x, pass[k - 1].y, pass[k - 1].z), q = SIMD3(pass[k].x, pass[k].y, pass[k].z)
                length += simd_distance(a, q)
                let id = Int32(segments.count)
                segments.append((a, q))
                let x0 = Int32((min(a.x, q.x) / bucket).rounded(.down)), x1 = Int32((max(a.x, q.x) / bucket).rounded(.down))
                let y0 = Int32((min(a.y, q.y) / bucket).rounded(.down)), y1 = Int32((max(a.y, q.y) / bucket).rounded(.down))
                for x in x0...x1 { for y in y0...y1 { buckets[SIMD2(x, y), default: []].append(id) } }
            }
        }
        guard !segments.isEmpty else { return [] }
        let cols = map.columns
        let nodes = inside.indices.filter { inside[$0] }
        guard !nodes.isEmpty else { return [] }
        let stride = max(1, nodes.count / 250_000)
        let sample = Swift.stride(from: 0, to: nodes.count, by: stride).map { nodes[$0] }
        let gaps = ParallelResults<Double>(count: sample.count, initial: 0)
        DispatchQueue.concurrentPerform(iterations: max(1, sample.count / 1024 + 1)) { chunk in
            for j in (chunk * 1024)..<min(sample.count, (chunk + 1) * 1024) {
                let i = sample[j]
                let q = map.node(i % cols, i / cols)
                let p = SIMD3(q.x, q.y, map.z[i])
                let cx = Int32((q.x / bucket).rounded(.down)), cy = Int32((q.y / bucket).rounded(.down))
                var best = Double.infinity
                for x in (cx - 1)...(cx + 1) {
                    for y in (cy - 1)...(cy + 1) {
                        for k in buckets[SIMD2(x, y)] ?? [] {
                            let (a, e) = segments[Int(k)]
                            let ab = e - a
                            let l2 = simd_length_squared(ab)
                            let t = l2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
                            best = min(best, simd_distance(p, a + ab * t))
                        }
                    }
                }
                gaps[j] = best
            }
        }
        let g = gaps.array
        let half = s / 2
        let wideLimit = half * 1.5.squareRoot()
        let wide = g.filter { $0 > wideLimit }
        let reachLimit = f.tool.radius
        let gapCount = g.filter { $0 > reachLimit }.count
        var out: [String] = []
        let strategy = f.params.strategy
        func percent(_ n: Int) -> String { String(format: "%.0f", max(1, (100 * Double(n) / Double(g.count)).rounded())) }
        if Double(gapCount) > 0.005 * Double(g.count) {
            out.append("The passes leave gaps the bit doesn't reach over \(percent(gapCount))% of the area; use a smaller stepover"
                + (strategy == .radial ? " or angular step." : "."))
        } else if Double(wide.count) > 0.02 * Double(g.count) {
            let sorted = g.sorted()
            let worst = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))]
            let factor = (worst / half) * (worst / half)
            let where_: String
            switch strategy {
            case .constantScallop: where_ = " (at sharp corners of the boundary, and on slopes steeper than 75°)"
            case .spiral: where_ = f.params.spiralHoldsScallop ? "" : " (where the surface slopes across the turns; Hold scallop closes them up there)"
            case .radial: where_ = " (between the spokes far from the centre; a smaller angular step closes them up)"
            default: where_ = ""
            }
            out.append("The passes are farther apart than the stepover over \(percent(wide.count))% of the area\(where_), so the "
                + "scallop there reaches about \(String(format: "%.1f", factor))× what the stepover leaves on the flat.")
        }
        // Bunching: the passes' length against the surface's area over the stepover.
        let h = map.pitch
        var area = 0.0
        let tanMax = tan(75 * Double.pi / 180)
        for i in nodes {
            let c = i % cols, r = i / cols
            let c0 = max(0, c - 1), c1 = min(cols - 1, c + 1), r0 = max(0, r - 1), r1 = min(map.rows - 1, r + 1)
            let gx = (map.z[map.index(c1, r)] - map.z[map.index(c0, r)]) / (Double(max(1, c1 - c0)) * h)
            let gy = (map.z[map.index(c, r1)] - map.z[map.index(c, r0)]) / (Double(max(1, r1 - r0)) * h)
            area += h * h * min((1 + tanMax * tanMax).squareRoot(), (1 + gx * gx + gy * gy).squareRoot())
        }
        let ratio = length / max(1e-9, area / s)
        if ratio > 1.6 {
            let tail: String
            switch strategy {
            case .radial: tail = "near the centre; a larger minimum spacing thins them out there"
            case .constantScallop: tail = "on steep walls or in narrow places"
            default: tail = "where they overlap"
            }
            out.append("The passes run \(String(format: "%.1f", ratio))× as far as the area needs at this stepover: they bunch up \(tail), "
                + "which takes longer than it needs to.")
        }
        return out
    }
}
