import Foundation

/// 3D finishing strategies on top of the exact drop-cutter: raster (with cross-hatching), waterline, steep and shallow,
/// and pencil, and the links between their passes.
extension Model3DGenerator {
    /// What every finishing strategy works from.
    struct Finishing {
        let setup: Setup
        let tool: Tool
        let params: Finish3DParams
        let dropper: CombinedDrop
        /// Lowest the tip may go (the model's base plus the allowance).
        let floor: Double
        let stepover: Double
        /// Grid cell, and the CL map's pitch.
        let cell: Double
        /// Sample spacing along passes.
        let ds: Double
        /// Simplification tolerance for passes, and how far a waterline chord may stray from its level (mm).
        let tolerance: Double
        let context: GenerationContext
        /// Short hops between passes follow the surface instead of lifting.
        var linkLimit: Double { stepover * 3 }

        /// Tip Z on the finishing surface: the exact drop onto the model, the material round it, within the floor and
        /// the material top.
        func z(_ p: Vec2, hint: inout Int32) -> Double { max(floor, min(0, dropper.z(at: p, hint: &hint))) }

        /// The dropped path with its moves split wherever they'd cut into the surface (see `refineDrops`).
        func refined(_ pts: [Vec3], above low: Double = -.infinity, hint: inout Int32) -> [Vec3] {
            Model3DGenerator.refineDrops(pts, tolerance: tolerance, above: low, hint: &hint) { p, h in z(p, hint: &h) }
        }

        func buildMap() -> CLMap {
            CLMap(dropper: dropper, floor: floor, grid: setup.surface)
        }

        // MARK: Links

        /// How deep the remaining material (the job's material model) is above a tip at `p`; 0 when unknown.
        func engagement(_ p: Vec3) -> Double {
            guard let top = context.materialTop else { return 0 }
            let t = top(p.xy, tool.radius)
            return t.isFinite ? max(0, t - p.z) : 0
        }

        /// Tip Z for a point of a link (a turnaround, a lead-in): on the finishing surface when that's no higher than
        /// `ceiling`. Past the boundary that surface counts the material as uncut, so there the model alone is used when
        /// the job's material model shows the material was cleared, cutting no deeper than `engagement` into what's left
        /// there. nil when neither holds.
        func linkZ(_ p: Vec2, ceiling: Double, engagement limit: Double, hint: inout Int32) -> Double? {
            let full = z(p, hint: &hint)
            if full <= ceiling + 1e-9 { return full }
            guard let top = context.materialTop, let exact = dropper.exact else { return nil }
            var h: Int32 = -1
            let m = max(floor, min(0, exact.z(at: p, hint: &h)))
            guard m <= ceiling + 1e-9 else { return nil }
            let t = top(p, tool.radius)
            guard !t.isFinite || t - m <= limit else { return nil }
            return m
        }

        /// Whether a feed from `a` to `b` stays clear of the clamps.
        func clearOfKeepOuts(_ a: Vec2, _ b: Vec2) -> Bool {
            !context.keepOuts.contains { LinkOptimizer.crosses($0, from: a, to: b, radius: tool.radius) }
        }

        /// Whether a link point keeps the tool centre inside the boundary (on it counts): links and lead-ins keep to the
        /// boundary margin's promise like the passes do.
        func insideBoundary(_ p: Vec2) -> Bool {
            if setup.boundary.contains(where: { $0.contains(p) }) { return true }
            return setup.boundary.contains { r in r.loops.contains { $0.closestPoint(to: p).distance < 1e-3 } }
        }

        /// A link point is usable: inside the boundary and the feed to it clear of the clamps.
        func usable(_ prev: Vec2, _ p: Vec2) -> Bool { insideBoundary(p) && clearOfKeepOuts(prev, p) }

        /// A U-turn from the end `a` of one raster row (travelling along `d`) onto the start `b` of the next: a half
        /// circle across the stepover, with a straight run first or after where the rows end unevenly. It follows the
        /// surface (see `linkZ`), climbing no more than a stepover above the higher end, and keeps inside the boundary,
        /// so it fits where rows end inside it (at a steep-and-shallow seam) rather than on it. nil when it can't.
        func turnaround(from a: Vec3, travelling d: Vec2, to b: Vec3) -> [Vec3]? {
            let delta = b.xy - a.xy
            let t = delta.dot(d)
            let across = delta - d * t
            let w = across.length
            guard w > 1e-6, w <= 2.5 * stepover, abs(t) <= linkLimit else { return nil }
            let n = across / w
            var xy: [Vec2] = []
            func straight(_ from: Vec2, _ to: Vec2) {
                let k = max(1, Int((from.distance(to: to) / ds).rounded(.up)))
                for i in 1...k { xy.append(from.lerp(to: to, Double(i) / Double(k))) }
            }
            var s = a.xy
            if t > 0 {
                straight(s, s + d * t)
                s = s + d * t
            }
            let centre = s + n * (w / 2)
            let steps = max(8, Int((Double.pi * w / 2 / min(ds, w / 4)).rounded(.up)))
            for i in 1...steps {
                let phi = Double.pi * Double(i) / Double(steps)
                xy.append(centre + (n * -cos(phi) + d * sin(phi)) * (w / 2))
            }
            if t < 0 { straight(s + n * w, b.xy) }
            xy[xy.count - 1] = b.xy
            let ceiling = max(a.z, b.z) + max(stepover, 0.25)
            let limit = max(engagement(a), engagement(b)) + 0.5
            var out: [Vec3] = []
            out.reserveCapacity(xy.count)
            var hint: Int32 = -1
            var prev = a.xy
            for p in xy {
                guard usable(prev, p), let z = linkZ(p, ceiling: ceiling, engagement: limit, hint: &hint) else { return nil }
                out.append(Vec3(p, z))
                prev = p
            }
            out[out.count - 1] = b
            // Over a step the turn would need splitting at its foot: leave that to the plain link.
            var last = a
            for q in out {
                if abs(q.z - last.z) > 3 * max(q.xy.distance(to: last.xy), 1e-9) && abs(q.z - last.z) > tolerance { return nil }
                last = q
            }
            return simplify3D(refined([a] + out, hint: &hint), tolerance: tolerance).dropFirst().map { $0 }
        }

        /// A ramp into `start` along the path's own line from behind it (travelling along `d`), so the tool comes down in
        /// the air and runs onto the surface instead of plunging onto it. nil when the tool is on the floor anyway, or the
        /// surface behind rises above the ramp (it would land on the model there instead).
        func rampIn(to start: Vec3, travelling d: Vec2) -> [Vec3]? {
            guard start.z > floor + 0.01 else { return nil }
            let length = max(1, tool.radius)
            let rise = tan(15.0.radians)
            let n = max(2, Int((length / ds).rounded(.up)))
            let limit = engagement(start) + 0.5
            var out: [Vec3] = []
            var hint: Int32 = -1
            var prev: Vec2?
            for k in 0..<n {
                let back = length * Double(n - k) / Double(n)
                let p = start.xy - d * back
                let ramp = start.z + back * rise
                guard insideBoundary(p), let z = linkZ(p, ceiling: ramp, engagement: limit, hint: &hint) else { return nil }
                if let prev, !clearOfKeepOuts(prev, p) { return nil }
                out.append(Vec3(p, max(z, ramp)))
                prev = p
            }
            guard let last = prev, clearOfKeepOuts(last, start.xy) else { return nil }
            return out
        }

        /// A feed at depth from the tool's position to `to` that follows the surface, never below `low` (the lower of
        /// the two ends, say) and, when `climbing` is false, never more than a stepover above the higher end. nil when
        /// the hop is too long or would climb.
        func surfaceLink(from a: Vec3, to b: Vec3, low: Double? = nil, climbing: Bool = false) -> [Vec3]? {
            let hop = a.xy.distance(to: b.xy)
            guard hop <= linkLimit, clearOfKeepOuts(a.xy, b.xy) else { return nil }
            let k = max(1, Int((hop / ds).rounded(.up)))
            let ceiling = climbing ? Double.infinity : max(a.z, b.z) + max(stepover, 0.25)
            var out: [Vec3] = []
            var hint: Int32 = -1
            for i in 1...k {
                let p = a.xy.lerp(to: b.xy, Double(i) / Double(k))
                var z = self.z(p, hint: &hint)
                if let low { z = max(z, low) }
                guard z <= ceiling else { return nil }
                out.append(Vec3(p, z))
            }
            out[out.count - 1] = b
            return Array(refined([a] + out, above: low ?? -.infinity, hint: &hint).dropFirst())
        }
    }

    // MARK: Raster

    struct RasterSegment {
        var row: Int
        /// Where it starts and ends along the row.
        var along: Double
        var end: Double
        var a: Vec2
        var b: Vec2
    }

    /// Raster rows at `angle` (degrees) a stepover apart across `rowsOver`'s extent, clipped to `area`, sorted by row
    /// and then along it.
    static func rasterSegments(over rowsOver: [Polyline], clippedTo area: [Polyline], angle: Double, stepover: Double) -> [RasterSegment] {
        let rot = Transform2D.rotation(-angle.radians)
        let unrot = Transform2D.rotation(angle.radians)
        let rb = rowsOver.map { $0.transformed(rot) }.bounds
        var raw: [Polyline] = []
        var y = rb.min.y + stepover / 2
        while y < rb.max.y {
            raw.append(Polyline([unrot.apply(Vec2(rb.min.x - 1, y)), unrot.apply(Vec2(rb.max.x + 1, y))], closed: false))
            y += stepover
        }
        var segments: [RasterSegment] = []
        for seg in Clipper.clipOpen(raw, to: area, fill: .nonZero) {
            guard let p = seg.points.first, let q = seg.points.last else { continue }
            let pr = rot.apply(p), qr = rot.apply(q)
            let row = Int(((pr.y - rb.min.y - stepover / 2) / stepover).rounded())
            let (a, bb) = pr.x <= qr.x ? (p, q) : (q, p)
            segments.append(RasterSegment(row: row, along: min(pr.x, qr.x), end: max(pr.x, qr.x), a: a, b: bb))
        }
        segments.sort { $0.row != $1.row ? $0.row < $1.row : $0.along < $1.along }
        return segments
    }

    /// Each segment dropped onto the surface (in parallel) and simplified, from `a` to `b`.
    static func dropSegments(_ segments: [RasterSegment], _ f: Finishing) -> [[Vec3]] {
        let out = ParallelResults<[Vec3]>(count: segments.count, initial: [])
        DispatchQueue.concurrentPerform(iterations: segments.count) { i in
            let sgm = segments[i]
            let len = sgm.a.distance(to: sgm.b)
            let n = max(1, Int((len / f.ds).rounded(.up)))
            var pts: [Vec3] = []
            pts.reserveCapacity(n + 1)
            var hint: Int32 = -1
            for k in 0...n {
                let p = sgm.a.lerp(to: sgm.b, Double(k) / Double(n))
                pts.append(Vec3(p, f.z(p, hint: &hint)))
            }
            out[i] = simplify3D(f.refined(pts, hint: &hint), tolerance: f.tolerance)
        }
        return out.array
    }

    /// The raster as it has always linked: zig-zag by row number, neighbours joined at depth along the surface when
    /// the hop is short, otherwise up and over.
    static func linkRowsAsBefore(_ segments: [RasterSegment], paths: [[Vec3]], _ f: Finishing, _ b: inout ToolpathBuilder) {
        var lastRow = Int.min
        var forward = true
        for (i, sgm) in segments.enumerated() {
            if sgm.row != lastRow { forward = (sgm.row % 2 == 0); lastRow = sgm.row }
            let path = forward ? paths[i] : paths[i].reversed()
            guard let first = path.first else { continue }
            let hop = b.position.xy.distance(to: first.xy)
            if b.position.z < f.setup.stock.plungeHeight && hop <= f.stepover * 3 && i > 0 {
                // Short hop: follow the surface (drop-cutter) so the link can't gouge.
                let n = max(1, Int((hop / f.ds).rounded(.up)))
                let from = b.position
                var hint: Int32 = -1
                var hopPoints = [from]
                for k in 1...n {
                    let p = from.xy.lerp(to: first.xy, Double(k) / Double(n))
                    hopPoints.append(Vec3(p, f.z(p, hint: &hint)))
                }
                b.follow(Array(f.refined(hopPoints, hint: &hint).dropFirst()))
            } else {
                b.enter(at: first)
            }
            b.follow(Array(path.dropFirst()))
        }
    }

    /// The raster in blocks: runs of rows whose segments overlap their neighbours', cut zig-zag one block at a time
    /// (nearest first), each row turning onto the next on an arc where that stays clear, and each block ramping in from
    /// behind its first row.
    static func linkRowsSmoothly(_ segments: [RasterSegment], paths: [[Vec3]], angle: Double, _ f: Finishing,
                                 _ b: inout ToolpathBuilder) {
        // Blocks: each segment joins the block whose last segment, in the row before, it overlaps most.
        var blocks: [[Int]] = []
        var open: [Int] = []
        var i = 0
        while i < segments.count {
            let row = segments[i].row
            var j = i
            while j < segments.count, segments[j].row == row { j += 1 }
            var next: [Int] = []
            var taken = Set<Int>()
            for k in i..<j {
                let s = segments[k]
                var best = -1
                var bestOverlap = 1e-9
                for blk in open where !taken.contains(blk) {
                    let last = segments[blocks[blk].last!]
                    guard last.row == row - 1 else { continue }
                    let overlap = min(last.end, s.end) - max(last.along, s.along)
                    if overlap > bestOverlap { bestOverlap = overlap; best = blk }
                }
                if best >= 0 {
                    blocks[best].append(k)
                    taken.insert(best)
                    next.append(best)
                } else {
                    blocks.append([k])
                    next.append(blocks.count - 1)
                }
            }
            open = next
            i = j
        }
        let dir = Vec2.fromAngle(angle.radians)
        var remaining = Array(blocks.indices)
        var first = b.motions.isEmpty
        while !remaining.isEmpty {
            // Nearest way into a block: either end row, either way along it.
            var pick = (index: 0, reversedRows: false, forward: true, distance: Double.infinity)
            for (n, blk) in remaining.enumerated() {
                for reversedRows in [false, true] {
                    let seg = reversedRows ? blocks[blk].last! : blocks[blk].first!
                    guard let p0 = paths[seg].first, let p1 = paths[seg].last else { continue }
                    for (forward, p) in [(true, p0), (false, p1)] {
                        let d = first ? 0 : p.xy.distance(to: b.position.xy)
                        if d < pick.distance - 1e-9 { pick = (n, reversedRows, forward, d) }
                    }
                }
            }
            let blk = remaining.remove(at: pick.index)
            let order = pick.reversedRows ? blocks[blk].reversed() : blocks[blk]
            var forward = pick.forward
            var previousEnd: Vec3?
            for seg in order {
                let path = forward ? paths[seg] : paths[seg].reversed()
                guard let start = path.first else { continue }
                let travel = forward ? dir : -dir
                // Within a block from the row before; into a new block from wherever the last one ended, if it's close.
                if let end = previousEnd ?? (b.motions.isEmpty ? nil : b.position), b.position.z < f.setup.stock.plungeHeight {
                    if previousEnd != nil, let turn = f.turnaround(from: end, travelling: -travel, to: start) {
                        b.follow(turn)
                    } else if let link = f.surfaceLink(from: end, to: start, climbing: true) {
                        b.follow(link)
                    } else {
                        enter(start, travelling: travel, f, &b)
                    }
                } else {
                    enter(start, travelling: travel, f, &b)
                }
                b.follow(Array(path.dropFirst()))
                previousEnd = path.last
                forward.toggle()
            }
            first = false
        }
    }

    /// Up, over and down to `start`, ramping in along the path's line where the start is on the model.
    static func enter(_ start: Vec3, travelling d: Vec2, _ f: Finishing, _ b: inout ToolpathBuilder) {
        if let ramp = f.rampIn(to: start, travelling: d), let top = ramp.first {
            b.enter(at: top)
            b.follow(Array(ramp.dropFirst()) + [start])
        } else {
            b.enter(at: start)
        }
    }

    /// Raster passes at the raster angle (and + 90° when cross-hatching) over `area`; false when none fit.
    static func raster(over area: [Polyline], _ f: Finishing, _ b: inout ToolpathBuilder) -> Bool {
        let angles = f.params.crossHatch ? [f.params.rasterAngle, f.params.rasterAngle + 90] : [f.params.rasterAngle]
        var any = false
        for angle in angles {
            let segments = rasterSegments(over: f.setup.boundary.flatMap(\.loops), clippedTo: area, angle: angle, stepover: f.stepover)
            guard !segments.isEmpty else { continue }
            any = true
            let paths = dropSegments(segments, f)
            if f.params.smoothLinks {
                linkRowsSmoothly(segments, paths: paths, angle: angle, f, &b)
            } else {
                linkRowsAsBefore(segments, paths: paths, f, &b)
            }
            if angles.count > 1 { b.retract() }
        }
        return any
    }

    // MARK: Waterline

    /// One waterline pass: a closed loop or part of one, at a level, with the material on its right.
    struct WaterPiece {
        var points: [Vec2]
        var closed: Bool
        var level: Int
        var z: Double
        var bounds: Rect2
    }

    /// Waterline levels from a step below the highest the model holds the tool, down to just above the floor.
    static func waterlineLevels(_ map: CLMap, step: Double) -> [Double] {
        var top = -Double.infinity
        for i in map.z.indices where map.onModel[i] { top = max(top, map.z[i]) }
        guard top.isFinite else { return [] }
        let bottom = map.floor + 0.01
        var levels: [Double] = []
        var z = top - step
        while z > bottom + step / 4 {
            levels.append(z)
            z -= step
        }
        if top > bottom + 1e-6 { levels.append(bottom) }
        return levels
    }

    /// The waterline loops at `levels` clipped to `area`, only where the model holds the tool (not the material round
    /// it), simplified, with the material on their right.
    static func waterPieces(_ map: CLMap, levels: [Double], area: [Polyline], _ f: Finishing) -> [WaterPiece] {
        let found = ParallelResults<[WaterPiece]>(count: levels.count, initial: [])
        // Contour only round the area (two cells spare), not the whole model under the map.
        let within = regionMask(Region.nest(Clipper.offset(area, delta: 2 * map.pitch)), f.setup.surface)
        DispatchQueue.concurrentPerform(iterations: levels.count) { k in
            let level = levels[k]
            var pieces: [Polyline] = []
            for contour in map.contours(at: level, tolerance: f.tolerance, within: within) {
                let n = contour.points.count
                if contour.onModel.allSatisfy({ $0 }) {
                    pieces.append(Polyline(contour.points + [contour.points[0]], closed: false))
                    continue
                }
                // Runs of vertices against the model, round the loop.
                guard let gap = contour.onModel.firstIndex(of: false) else { continue }
                var run: [Vec2] = []
                for s in 1...n {
                    let i = (gap + s) % n
                    if contour.onModel[i] {
                        run.append(contour.points[i])
                    } else {
                        if run.count >= 2 { pieces.append(Polyline(run, closed: false)) }
                        run = []
                    }
                }
                if run.count >= 2 { pieces.append(Polyline(run, closed: false)) }
            }
            guard !pieces.isEmpty else { return }
            // Clip to the area, then put each piece back the way round that keeps the material on its right (clipping
            // doesn't promise to keep open paths' direction) and join pieces the clip split at a loop's start.
            var clipped = Clipper.clipOpen(pieces, to: area, fill: .nonZero).map(\.points)
            var hint: Int32 = -1
            for i in clipped.indices where clipped[i].count >= 2 {
                let pts = clipped[i]
                let m = pts.count / 2
                let (p, q) = m > 0 ? (pts[m - 1], pts[m]) : (pts[0], pts[1])
                let d = (q - p).normalized
                let mid = p.lerp(to: q, 0.5)
                let right = map.height(mid + d.perpRight * (map.pitch / 2), hint: &hint)
                let left = map.height(mid + d.perpLeft * (map.pitch / 2), hint: &hint)
                if left > right { clipped[i].reverse() }
            }
            var joined: [[Vec2]] = []
            var used = [Bool](repeating: false, count: clipped.count)
            for i in clipped.indices where !used[i] {
                used[i] = true
                var chain = clipped[i]
                var grew = true
                while grew {
                    grew = false
                    for j in clipped.indices where !used[j] {
                        if chain.last!.distance(to: clipped[j][0]) < 1e-3 {
                            chain += clipped[j].dropFirst()
                            used[j] = true
                            grew = true
                        } else if clipped[j].last!.distance(to: chain[0]) < 1e-3 {
                            chain = clipped[j] + chain.dropFirst()
                            used[j] = true
                            grew = true
                        }
                    }
                }
                joined.append(chain)
            }
            var out: [WaterPiece] = []
            for chain in joined {
                let closed = chain.count >= 4 && chain[0].distance(to: chain[chain.count - 1]) < 1e-3
                var line = Polyline(closed ? Array(chain.dropLast()) : chain, closed: closed)
                line = line.simplified(tolerance: f.tolerance / 2)
                guard line.points.count >= 2, line.length >= map.pitch else { continue }
                out.append(WaterPiece(points: line.points, closed: closed, level: k, z: level, bounds: line.bounds))
            }
            found[k] = out
        }
        return found.array.flatMap { $0 }
    }

    /// Cuts waterline pieces top down a column at a time: a piece waits until every piece in the level above that it
    /// could be under (their outlines within a link of each other) is done, and of those ready the nearest goes next.
    static func cutWaterline(_ pieces: [WaterPiece], _ map: CLMap, _ f: Finishing, _ b: inout ToolpathBuilder) {
        guard !pieces.isEmpty else { return }
        let reach = f.linkLimit
        var byLevel: [Int: [Int]] = [:]
        for (i, p) in pieces.enumerated() { byLevel[p.level, default: []].append(i) }
        var waiting = [Int](repeating: 0, count: pieces.count)
        var below = [[Int]](repeating: [], count: pieces.count)
        for (i, p) in pieces.enumerated() {
            for j in byLevel[p.level - 1] ?? [] where pieces[j].bounds.insetBy(-reach).intersects(p.bounds) {
                waiting[i] += 1
                below[j].append(i)
            }
        }
        var ready = Set(pieces.indices.filter { waiting[$0] == 0 })
        var first = b.motions.isEmpty
        while !ready.isEmpty {
            let here = b.position.xy
            var best = (piece: -1, start: 0, distance: Double.infinity)
            for i in ready.sorted() {
                let p = pieces[i]
                let boxGap = first ? 0 : max(0, max(p.bounds.min.x - here.x, here.x - p.bounds.max.x),
                                             max(p.bounds.min.y - here.y, here.y - p.bounds.max.y))
                guard boxGap < best.distance else { continue }
                if p.closed {
                    for (k, q) in p.points.enumerated() {
                        let d = first ? 0 : q.distance(to: here)
                        if d < best.distance { best = (i, k, d) }
                    }
                } else {
                    let d = first ? 0 : p.points[0].distance(to: here)
                    if d < best.distance { best = (i, 0, d) }
                }
            }
            let i = best.piece
            ready.remove(i)
            for j in below[i] {
                waiting[j] -= 1
                if waiting[j] == 0 { ready.insert(j) }
            }
            let p = pieces[i]
            var pts = p.points
            if p.closed {
                pts = Array(pts[best.start...] + pts[..<best.start])
                pts.append(pts[0])
            }
            let start = Vec3(pts[0], p.z)
            if !first, b.position.z < f.setup.stock.plungeHeight,
               let link = f.surfaceLink(from: b.position, to: start, low: min(b.position.z, p.z)) {
                b.follow(link)
            } else if f.params.smoothLinks, let lead = leadIn(to: pts, z: p.z, map, f), let top = lead.first {
                b.enter(at: top)
                b.follow(Array(lead.dropFirst()) + [start])
            } else {
                b.enter(at: start)
            }
            b.follow(pts.dropFirst().map { Vec3($0, p.z) })
            first = false
        }
    }

    /// A quarter circle onto a waterline pass's start from its free side (the left, the material being on the right),
    /// all of it where the tool clears the model at that height: the tool comes down there instead of onto the wall.
    static func leadIn(to pts: [Vec2], z: Double, _ map: CLMap, _ f: Finishing) -> [Vec3]? {
        guard pts.count >= 2 else { return nil }
        let s = pts[0]
        let d = (pts[1] - pts[0]).normalized
        guard d.lengthSquared > 0.5 else { return nil }
        let left = d.perpLeft
        var hint: Int32 = -1
        func clear(_ p: Vec2) -> Bool { map.height(p, hint: &hint) <= z - 1e-4 }
        for radius in [max(0.5, f.tool.radius), max(0.25, f.tool.radius / 2)] {
            let centre = s + left * radius
            let steps = 12
            var out: [Vec3] = []
            var ok = true
            var prev: Vec2?
            for k in 0..<steps {
                let phi = Double.pi / 2 * Double(steps - k) / Double(steps)
                let p = centre + (left * -cos(phi) - d * sin(phi)) * radius
                if !f.insideBoundary(p) || !clear(p) { ok = false; break }
                if let prev, !f.clearOfKeepOuts(prev, p) || !clear(prev.lerp(to: p, 0.5)) { ok = false; break }
                out.append(Vec3(p, z))
                prev = p
            }
            if ok, let prev, f.clearOfKeepOuts(prev, s), clear(prev.lerp(to: s, 0.5)) { return out }
        }
        return nil
    }

    // MARK: Steep and shallow

    /// Where the CL surface is steeper than `angle` degrees and the model holds the tool, as cleaned-up polygons: gaps
    /// and pinholes a grid cell across closed, and specks a couple of cells across dropped. Long thin strips stay: along
    /// the top of a vertical wall the steep part is under a millimetre wide (where the ball rolls over the edge).
    static func steepAreas(_ map: CLMap, angle: Double) -> [Polyline] {
        let slope = map.slopes()
        let mask = slope.indices.map { slope[$0] > angle && map.onModel[$0] }
        let loops = GridContours.loops(mask: mask, columns: map.columns, rows: map.rows, origin: map.origin, cellSize: map.pitch)
        guard !loops.isEmpty else { return [] }
        let d = map.pitch
        let closed = Clipper.offset(Clipper.offset(Clipper.union(loops, fill: .nonZero), delta: d), delta: -d)
        return Region.nest(closed).filter { $0.area >= 6 * d * d }.flatMap(\.loops)
    }

    // MARK: Pencil

    /// Pencil passes along the creases the map finds for this ball, nearest first, each ramping in along its own line.
    static func pencil(_ map: CLMap, _ f: Finishing, _ b: inout ToolpathBuilder, warnings: inout [String]) {
        let area = f.setup.boundary.flatMap(\.loops)
        let minimum = max(2 * map.pitch, f.tool.radius)
        var chains: [[Vec2]] = []
        for crease in map.creases(ballRadius: f.tool.radius, angle: 20) {
            let pts = crease.isClosed ? crease.points + [crease.points[0]] : crease.points
            for piece in Clipper.clipOpen([Polyline(pts, closed: false)], to: area, fill: .nonZero) {
                let simple = piece.simplified(tolerance: f.tolerance)
                if simple.length >= minimum { chains.append(simple.points) }
            }
        }
        guard !chains.isEmpty else {
            warnings.append("No concave creases for \(f.tool.name) to clean up.")
            return
        }
        // Each chain dropped onto the surface. Along the foot of a vertical wall the surface steps up right beside the
        // crease, so a sample that lands on top of the step (well above both ends of its stretch) moves sideways to the
        // nearest spot at the bottom of it; failing that it stays where it is, up on the wall, which is safe.
        let spike = max(0.5, f.tool.radius / 2)
        let paths = chains.map { chain -> [Vec3] in
            var pts: [Vec3] = []
            var hint: Int32 = -1
            for k in 0..<(chain.count - 1) {
                let (p, q) = (chain[k], chain[k + 1])
                let zp = f.z(p, hint: &hint), zq = f.z(q, hint: &hint)
                let limit = max(zp, zq) + spike
                let side = (q - p).normalized.perpLeft
                let n = max(1, Int((p.distance(to: q) / f.ds).rounded(.up)))
                for i in (k == 0 ? 0 : 1)...n {
                    var x = p.lerp(to: q, Double(i) / Double(n))
                    var z = f.z(x, hint: &hint)
                    if z > limit {
                        search: for d in [0.005, 0.01, 0.02, 0.05, 0.1, 0.2] {
                            for y in [x + side * d, x - side * d] {
                                let zy = f.z(y, hint: &hint)
                                if zy <= limit { x = y; z = zy; break search }
                            }
                        }
                    }
                    pts.append(Vec3(x, z))
                }
            }
            return simplify3D(f.refined(pts, hint: &hint), tolerance: f.tolerance)
        }
        var remaining = Array(paths.indices)
        var first = b.motions.isEmpty
        while !remaining.isEmpty {
            var pick = (index: 0, reversed: false, distance: Double.infinity)
            for (n, i) in remaining.enumerated() {
                for reversed in [false, true] {
                    guard let s = reversed ? paths[i].last : paths[i].first else { continue }
                    let d = first ? 0 : s.xy.distance(to: b.position.xy)
                    if d < pick.distance - 1e-9 { pick = (n, reversed, d) }
                }
            }
            let i = remaining.remove(at: pick.index)
            let path = pick.reversed ? Array(paths[i].reversed()) : paths[i]
            guard path.count >= 2 else { continue }
            let start = path[0]
            if !first, b.position.z < f.setup.stock.plungeHeight, let link = f.surfaceLink(from: b.position, to: start) {
                b.follow(link)
            } else if f.params.smoothLinks {
                enter(start, travelling: (path[1].xy - start.xy).normalized, f, &b)
            } else {
                b.enter(at: start)
            }
            b.follow(Array(path.dropFirst()))
            first = false
        }
    }
}
