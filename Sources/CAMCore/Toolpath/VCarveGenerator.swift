import Foundation

/// V-carving by maximal inscribed circles.
///
/// For each sample point p on the outline with inward normal n, the largest circle inside the shape that
/// touches the outline at p has centre c = p + r·n. A V-bit whose cone meets the surface at radius r has its
/// tip at depth (r − tipRadius) / tan(halfAngle), so driving the tip along c(p) at that depth carves walls that
/// meet the outline exactly at the surface and rise to sharp corners. Each outline loop yields one path that runs
/// along the shape's medial axis. Depth is capped by the bit's taper height and the optional flat depth.
enum VCarveGenerator {
    static func generate(op: CAMOperation, params: VCarveParams, clearanceTool: Tool?, shapes: [DesignShape],
                         context: GenerationContext) -> [Toolpath] {
        let tool = op.tool
        var warnings: [String] = []
        if !tool.shape.isTapered {
            warnings.append("V-carving needs a V-bit or engraving bit; '\(tool.name)' is a \(tool.shape.label).")
        }
        let loops = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }.filter { $0.isClosed }
        let regions = Region.build(from: loops, fill: .evenOdd)
        if regions.isEmpty { warnings.append("V-carving needs closed shapes; none were selected.") }

        let t = tool.shape.isTapered ? tool.halfAngleTangent : 1
        let tip = tool.shape.isTapered ? tool.tipDiameter / 2 : 0
        let maxDepthByTool = tool.shape.isTapered ? min(tool.taperHeight, tool.fluteLength) : tool.fluteLength
        let depthCap = min(params.flatDepth ?? .infinity, maxDepthByTool)
        let rCap = tip + depthCap * t
        let spacing = max(0.05, params.sampleSpacing)

        // Pass levels for deep carves (depth limit per pass, last pass is unlimited).
        var passLimits: [Double] = []
        if let pd = params.passDepth, pd > 0, depthCap.isFinite {
            var d = pd
            while d < depthCap - 1e-6 { passLimits.append(d); d += pd }
        }
        passLimits.append(.infinity)

        var paths: [[Vec3]] = []
        for region in regions {
            let segs = region.loops.flatMap { loop in (0..<loop.segmentCount).map { loop.segment($0) } }
            let grid = SegmentGrid(segments: segs, cell: max(rCap * 2, spacing * 4, 0.5))
            for loop in region.loops {
                let pts = carvePath(loop: loop, segments: segs, grid: grid, spacing: spacing, rCap: rCap, tip: tip, t: t)
                if pts.count > 1 { paths.append(pts) }
            }
        }

        var toolpaths: [Toolpath] = []
        // Optional flat-area clearing with a second tool, cut before the V-bit.
        if let flat = params.flatDepth, let clear = clearanceTool, flat > 0 {
            let flatRegions = regions.flatMap { $0.offset(by: -rCap, arcTolerance: context.arcTolerance) }
            if !flatRegions.isEmpty {
                var cb = ToolpathBuilder(stock: context.stock, tool: clear, startXY: nil)
                let pp = PocketParams(strategy: .offset, direction: .climb, depth: DepthSettings(cutDepth: flat))
                let w = PocketGenerator.generate(regions: flatRegions, tool: clear, params: pp, context: context, builder: &cb)
                cb.retract()
                var tp = cb.build(id: UUID(), name: "\(op.name) – flat clearing", tool: clear, rpm: clear.cutting.spindleRPM,
                                  warnings: w)
                tp.id = deterministicID(op.id, salt: 1)
                toolpaths.append(tp)
            }
        }

        let ordered = TourOptimizer.order(count: paths.count, from: context.stock.homePosition.xy,
                                          start: { paths[$0][0].xy }, end: { paths[$0][paths[$0].count - 1].xy }).map { paths[$0] }
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: ordered.first?.first?.xy)
        let simplifyTol = min(0.01, context.arcTolerance * 2)
        for limit in passLimits {
            for path in ordered {
                let limited = path.map { Vec3($0.x, $0.y, max($0.z, -limit)) }
                let simplified = simplify3D(limited, tolerance: simplifyTol)
                b.enter(at: simplified[0])
                b.follow(Array(simplified.dropFirst()))
                b.retract()
            }
        }
        toolpaths.append(b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings))
        return toolpaths
    }

    /// Convex vertices turning less than this are treated as points on a curve, not corners (10°).
    static let minimumCornerTurn = 10.0 * Double.pi / 180

    /// Medial-axis path for one loop of a region (loop oriented with the region interior on its left).
    static func carvePath(loop: Polyline, segments: [(Vec2, Vec2)], grid: SegmentGrid?, spacing: Double, rCap: Double,
                          tip: Double, t: Double) -> [Vec3] {
        var out: [Vec3] = []
        let n = loop.count
        guard n >= 3 else { return [] }
        var scratch = SegmentGrid.Scratch(count: segments.count)
        func emit(_ p: Vec2, _ normal: Vec2, exclude: Set<Int>) {
            // Only segments within 2·rCap of p can limit a circle of radius <= rCap that touches p.
            let candidates = grid.map { $0.query(p, radius: 2 * rCap + 1e-6, scratch: &scratch) }
            let r = min(maxInscribedRadius(p: p, n: normal, segments: segments, candidates: candidates, exclude: exclude), rCap)
            let c = p + normal * r
            let depth = max(0, (r - tip) / t)
            out.append(Vec3(c, -depth))
        }
        // Global segment index of this loop's edge i is found by matching endpoints.
        let edgeIndex: [Int] = (0..<n).map { i in
            let (a, b) = loop.segment(i)
            return segments.firstIndex { $0.0.isApprox(a, tolerance: 1e-9) && $0.1.isApprox(b, tolerance: 1e-9) } ?? -1
        }
        for i in 0..<n {
            let (a, b) = loop.segment(i)
            let d = b - a
            let len = d.length
            guard len > 1e-9 else { continue }
            let dir = d / len
            let normal = dir.perpLeft
            let count = max(1, Int((len / spacing).rounded(.up)))
            for k in 0..<count {
                let s = (Double(k) + 0.5) / Double(count)
                emit(a + d * s, normal, exclude: [edgeIndex[i]])
            }
            // Vertex at the end of edge i.
            let (_, c2) = loop.segment((i + 1) % n)
            let nextDir = (c2 - b).normalized
            let turn = dir.cross(nextDir)
            let turnAngle = atan2(turn, dir.dot(nextDir))
            if turnAngle > minimumCornerTurn {
                // Real convex corner: the carve rises to the surface at the corner tip. Gentle turns are just a
                // flattened curve; rising there would send the bit up and down along every curve (air cutting).
                out.append(Vec3(b, 0))
            } else if turn < -1e-9 {
                // Reflex corner: sweep the normal around the corner, circles all touch at the vertex.
                let a0 = normal.angle
                var a1 = nextDir.perpLeft.angle
                while a1 > a0 { a1 -= 2 * .pi }
                while a1 < a0 - 2 * .pi { a1 += 2 * .pi }
                let sweep = a1 - a0 // negative (clockwise)
                let steps = max(2, Int((abs(sweep) * max(rCap, spacing) / spacing).rounded(.up)))
                let excl: Set<Int> = [edgeIndex[i], edgeIndex[(i + 1) % n]]
                for k in 1..<steps {
                    emit(b, Vec2.fromAngle(a0 + sweep * Double(k) / Double(steps)), exclude: excl)
                }
            }
        }
        if let first = out.first { out.append(first) }
        return out
    }

    /// Radius of the largest circle centred on p + r·n (|n| = 1) that touches the boundary at p and no closer.
    /// Exact against every segment: tangency to a segment's interior, or passing through an endpoint.
    static func maxInscribedRadius(p: Vec2, n: Vec2, segments: [(Vec2, Vec2)], candidates: [Int]? = nil,
                                   exclude: Set<Int>) -> Double {
        var best = Double.infinity
        let eps = 1e-9
        let indices = candidates ?? Array(segments.indices)
        for idx in indices where !exclude.contains(idx) {
            let (a, b) = segments[idx]
            let d = b - a
            let len = d.length
            guard len > eps else { continue }
            let m = (d / len).perpLeft // inward normal of this edge
            // Tangent to the edge's line from the inside: m·(p - a) + r m·n = r.
            let denom = 1 - m.dot(n)
            if denom > eps {
                let r = m.dot(p - a) / denom
                if r > eps && r < best {
                    let c = p + n * r
                    let foot = c - m * r
                    let u = (foot - a).dot(d) / (len * len)
                    if u >= 0 && u <= 1 { best = r }
                }
            }
            // Through endpoint a (each endpoint appears as some segment's `a` for closed loops).
            let q = a - p
            let nq = n.dot(q)
            if nq > eps {
                let r = q.lengthSquared / (2 * nq)
                if r > eps && r < best { best = r }
            }
        }
        return best
    }

    /// Uniform bucket grid over segments for radius queries.
    struct SegmentGrid {
        let cell: Double
        let origin: Vec2
        let cols: Int
        let rows: Int
        var buckets: [[Int]]

        struct Scratch {
            var stamp: [Int]
            var generation = 0
            init(count: Int) { stamp = [Int](repeating: -1, count: count) }
        }

        init(segments: [(Vec2, Vec2)], cell: Double) {
            var bounds = Rect2.empty
            for (a, b) in segments { bounds = bounds.union(a).union(b) }
            if bounds.isEmpty { bounds = Rect2(x: 0, y: 0, width: 1, height: 1) }
            self.cell = cell
            origin = bounds.min
            cols = max(1, Int((bounds.width / cell).rounded(.up)) + 1)
            rows = max(1, Int((bounds.height / cell).rounded(.up)) + 1)
            buckets = Array(repeating: [], count: cols * rows)
            for (i, (a, b)) in segments.enumerated() {
                let x0 = Int((min(a.x, b.x) - origin.x) / cell), x1 = Int((max(a.x, b.x) - origin.x) / cell)
                let y0 = Int((min(a.y, b.y) - origin.y) / cell), y1 = Int((max(a.y, b.y) - origin.y) / cell)
                for y in max(0, y0)...min(rows - 1, y1) {
                    for x in max(0, x0)...min(cols - 1, x1) { buckets[y * cols + x].append(i) }
                }
            }
        }

        func query(_ p: Vec2, radius: Double, scratch: inout Scratch) -> [Int] {
            scratch.generation += 1
            let g = scratch.generation
            let x0 = max(0, Int((p.x - radius - origin.x) / cell)), x1 = min(cols - 1, Int((p.x + radius - origin.x) / cell))
            let y0 = max(0, Int((p.y - radius - origin.y) / cell)), y1 = min(rows - 1, Int((p.y + radius - origin.y) / cell))
            guard x0 <= x1, y0 <= y1 else { return [] }
            var out: [Int] = []
            for y in y0...y1 {
                for x in x0...x1 {
                    for i in buckets[y * cols + x] where scratch.stamp[i] != g {
                        scratch.stamp[i] = g
                        out.append(i)
                    }
                }
            }
            return out
        }
    }

    static func deterministicID(_ id: UUID, salt: UInt8) -> UUID {
        var u = id.uuid
        u.15 ^= salt
        return UUID(uuid: u)
    }
}
