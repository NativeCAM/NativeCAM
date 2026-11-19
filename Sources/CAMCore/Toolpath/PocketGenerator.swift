import Foundation

/// Area clearing for closed shapes (holes in the selection become islands).
enum PocketGenerator {
    static func generate(op: CAMOperation, params: PocketParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        let loops = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }.filter { $0.isClosed }
        let regions = Region.build(from: loops, fill: .evenOdd)
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let result = generate(regions: regions, tool: tool, params: params, context: context, builder: &b)
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: result)
    }

    /// Shared by pockets and V-carve flat-area clearing. Appends to `b`, returns warnings.
    /// `smoothBoundary` also rounds the outermost rings' corners (for roughing that leaves an allowance; a pocket's
    /// walls stay exact). Inner rings are always smoothed within the machine's roughing smoothing budget.
    static func generate(regions: [Region], tool: Tool, params: PocketParams, context: GenerationContext,
                         smoothBoundary: Bool = false, builder b: inout ToolpathBuilder) -> [String] {
        var warnings: [String] = []
        if regions.isEmpty {
            warnings.append("Pockets need closed shapes; none were selected.")
            return warnings
        }
        let r = tool.radius
        let stepover = max(0.05, tool.diameter * (params.stepoverFraction ?? tool.cutting.stepoverFraction))
        if stepover > tool.diameter * 0.95 {
            warnings.append("Stepover is larger than the tool diameter; material will be left behind.")
        }
        let levels = params.depth.passLevels(toolStepdown: tool.cutting.stepdown, firstPassMinimum: tool.firstPassMinimum)
        if levels.isEmpty {
            warnings.append("Cut depth must be greater than the start depth.")
            return warnings
        }

        // Tool-centre boundary: shrink each region by the tool radius plus allowance.
        let boundary = regions.flatMap { $0.offset(by: -(r + params.allowance), arcTolerance: context.arcTolerance) }
        if boundary.isEmpty {
            warnings.append("The tool is too large to fit in the pocket.")
            return warnings
        }
        // Feed links are allowed only if they stay inside this (slightly grown) safe area.
        let safe = boundary.flatMap { $0.offset(by: 0.01, arcTolerance: context.arcTolerance) }

        // Corner reliefs on the wall rings: the boundary and its islands (region loops have the pocket on their left).
        var reliefs: [CornerRelief.Relief] = []
        if let relief = params.cornerRelief {
            let design = CornerRelief.Design(regions.flatMap(\.loops))
            var blocked = 0
            for loop in boundary.flatMap(\.loops) {
                let plan = CornerRelief.plan(loop, wasteOnLeft: true, design: design, offset: r + params.allowance, settings: relief)
                reliefs += plan.reliefs
                blocked += plan.blocked
            }
            if blocked > 0 {
                warnings.append(blocked == 1 ? "1 corner wasn't relieved: its relief would cut into nearby geometry."
                    : "\(blocked) corners weren't relieved: their reliefs would cut into nearby geometry.")
            }
        }

        switch params.strategy {
        case .offset:
            let tree = ringTree(boundary, stepover: stepover, toolRadius: r, arcTolerance: context.arcTolerance)
            smooth(tree, deviation: context.machine.cornerSmoothing, plannerDeviation: context.machine.cornerDeviation,
                   stepover: stepover, toolRadius: r, boundary: smoothBoundary, chordTolerance: context.arcTolerance)
            var zAbove = -params.depth.startDepth
            for z in levels {
                var first = true
                cutTree(tree, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, reliefs: reliefs,
                        first: &first, builder: &b)
                b.retract()
                zAbove = z
            }
        case .raster:
            let lines = rasterLines(boundary, stepover: stepover, angle: params.rasterAngle)
            var zAbove = -params.depth.startDepth
            for z in levels {
                var first = true
                cutRaster(lines, z: z, zAbove: zAbove, stepover: stepover, safe: safe, params: params, first: &first, builder: &b)
                // Clean-up pass around the boundary (and islands) to remove raster scallops.
                for region in boundary {
                    for loop in region.loops {
                        let oriented = params.direction == .climb ? loop : loop.reversed
                        cutLoop(oriented, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, reliefs: reliefs,
                                first: &first, builder: &b)
                    }
                }
                b.retract()
                zAbove = z
            }
        }
        return warnings
    }

    // MARK: Offset rings

    final class RingNode {
        var region: Region
        var children: [RingNode] = []
        init(_ region: Region) { self.region = region }
    }

    /// Rounds ring corners (convex only, so rings only move inward). An inner ring may come in at a corner only
    /// as far as keeps the ring outside it overlapping: at a turn α the strip between rings stays covered while
    /// stepover + e·cos(α/2) ≤ r·(1 + cos(α/2)); a fifth of that slack is kept in reserve.
    static func smooth(_ nodes: [RingNode], deviation: Double, plannerDeviation: Double, stepover: Double, toolRadius r: Double,
                       boundary: Bool, chordTolerance: Double) {
        guard deviation > 1e-6 else { return }
        let budget = { (turn: Double) -> Double in
            let c = cos(turn / 2)
            return max(0, 0.8 * (r * (1 + c) - stepover) / max(c, 1e-3))
        }
        func visit(_ node: RingNode, isRoot: Bool) {
            if !isRoot || boundary {
                let reg = node.region
                let f = { (l: Polyline) in
                    l.filletingConvexCorners(deviation: deviation, plannerDeviation: plannerDeviation, chordTolerance: chordTolerance,
                                             budget: isRoot ? nil : budget)
                }
                node.region = Region(outer: f(reg.outer), holes: reg.holes.map(f))
            }
            for child in node.children { visit(child, isRoot: false) }
        }
        for node in nodes { visit(node, isRoot: true) }
    }

    /// Successive inward offsets arranged as a containment tree (each level's regions under the one containing them).
    static func ringTree(_ boundary: [Region], stepover: Double, toolRadius: Double, arcTolerance: Double) -> [RingNode] {
        let roots = boundary.map(RingNode.init)
        var frontier = roots
        var guardCount = 0
        while !frontier.isEmpty && guardCount < 10_000 {
            guardCount += 1
            var next: [RingNode] = []
            for node in frontier {
                var inner = node.region.offset(by: -stepover, arcTolerance: arcTolerance)
                if inner.isEmpty, stepover > toolRadius * 0.98 {
                    // Big stepover: make sure the middle gets cut by adding a final ring at the tool radius.
                    inner = node.region.offset(by: -toolRadius * 0.95, arcTolerance: arcTolerance)
                    if inner.contains(where: { $0.area < 1e-6 }) { inner = [] }
                    let children = inner.map(RingNode.init)
                    node.children = children
                    continue
                }
                let children = inner.map(RingNode.init)
                node.children = children
                next.append(contentsOf: children)
            }
            frontier = next
        }
        return roots
    }

    /// `reliefs` belong to the wall rings, the top level of the tree; inner rings never get any.
    private static func cutTree(_ nodes: [RingNode], z: Double, zAbove: Double, params: PocketParams, stepover: Double, safe: [Region],
                                reliefs: [CornerRelief.Relief] = [], first: inout Bool, builder b: inout ToolpathBuilder) {
        // Inside-out: finish each branch's inner rings before its enclosing ring.
        let ordered = nearestNeighborOrder(nodes, from: b.position.xy,
                                           start: { $0.region.outer.closestPoint(to: b.position.xy).point },
                                           end: { $0.region.outer.points[0] })
        for node in ordered {
            cutTree(node.children, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, first: &first, builder: &b)
            // Islands first (they are closer to the inner rings), then the outer ring.
            let loops = node.region.holes + [node.region.outer]
            for loop in loops {
                // Region loops: outer CCW / holes CW = climb for inside-out clearing with an M3 spindle.
                let oriented = params.direction == .climb ? loop : loop.reversed
                cutLoop(oriented, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, reliefs: reliefs,
                        first: &first, builder: &b)
            }
        }
    }

    /// Cuts one closed loop at depth z, linking from the current position when safe.
    /// `zAbove` is the floor of the previous pass (where a ramp starts). Corner reliefs at the loop's vertices are
    /// added after its start is chosen, so the entry never lands on a relief tip.
    static func cutLoop(_ loopIn: Polyline, z: Double, zAbove: Double, params: PocketParams, stepover: Double, safe: [Region],
                        reliefs: [CornerRelief.Relief] = [], first: inout Bool, builder b: inout ToolpathBuilder) {
        let loop = CornerRelief.insert(reliefs, into: loopIn.startingNearest(b.position.xy))
        guard let startXY = loop.points.first else { return }
        let start = Vec3(startXY, z)
        let atDepth = abs(b.position.z - z) < 1e-6
        let linkLength = b.position.xy.distance(to: startXY)
        if !first && atDepth && linkLength <= stepover * 2.5 && segmentInside(b.position.xy, startXY, safe) {
            b.feed(start)
            followLoop(loop, z: z, builder: &b)
        } else if params.entry.kind == .ramp && params.entry.rampLength > 0 && loop.length > 1 {
            // Ramp down along the loop from the top of this pass, then go around once at full depth.
            let walker = LoopWalker(loop)
            let L = walker.length
            let rampLen = min(params.entry.rampLength, L * 0.98)
            let z0 = max(zAbove, z)
            b.enter(at: Vec3(startXY, z0))
            let pts = walker.walk(from: 0, to: rampLen + L, breaks: [rampLen]) { t in t < rampLen ? z0 + (z - z0) * t / rampLen : z }
            b.follow(pts)
        } else {
            b.enter(at: start)
            followLoop(loop, z: z, builder: &b)
        }
        first = false
    }

    private static func followLoop(_ loop: Polyline, z: Double, builder b: inout ToolpathBuilder) {
        b.follow(loop.points.dropFirst().map { Vec3($0, z) })
        b.feed(Vec3(loop.points[0], z))
    }

    static func segmentInside(_ a: Vec2, _ c: Vec2, _ regions: [Region]) -> Bool {
        let mid = (a + c) * 0.5
        guard let region = regions.first(where: { $0.contains(a) && $0.contains(c) && $0.contains(mid) }) else { return false }
        for loop in region.loops {
            for i in 0..<loop.segmentCount {
                let (p, q) = loop.segment(i)
                if segmentsIntersect(a, c, p, q, epsilon: 1e-9) { return false }
            }
        }
        return true
    }

    // MARK: Raster

    struct RasterLine { var a: Vec2; var b: Vec2; var row: Int }

    static func rasterLines(_ boundary: [Region], stepover: Double, angle: Double) -> [RasterLine] {
        let rot = Transform2D.rotation(-angle.radians)
        let unrot = Transform2D.rotation(angle.radians)
        let loops = boundary.flatMap(\.loops).map { $0.transformed(rot) }
        let bounds = loops.bounds
        guard !bounds.isEmpty else { return [] }
        var raw: [Polyline] = []
        var y = bounds.min.y + stepover * 0.5
        while y < bounds.max.y {
            raw.append(Polyline([Vec2(bounds.min.x - 1, y), Vec2(bounds.max.x + 1, y)], closed: false))
            y += stepover
        }
        let clipped = Clipper.clipOpen(raw, to: loops, fill: .nonZero)
        var out: [RasterLine] = []
        for seg in clipped {
            guard let p = seg.points.first, let q = seg.points.last else { continue }
            let row = Int(((p.y - bounds.min.y - stepover * 0.5) / stepover).rounded())
            let (l, r) = p.x <= q.x ? (p, q) : (q, p)
            out.append(RasterLine(a: unrot.apply(l), b: unrot.apply(r), row: row))
        }
        return out
    }

    private static func cutRaster(_ lines: [RasterLine], z: Double, zAbove: Double, stepover: Double, safe: [Region], params: PocketParams,
                                  first: inout Bool, builder b: inout ToolpathBuilder) {
        var remaining = lines
        while !remaining.isEmpty {
            // Pick the nearest endpoint among segments on the lowest remaining row (keeps the zig-zag orderly).
            let minRow = remaining.map(\.row).min()!
            var best = -1
            var bestD = Double.infinity
            var reversed = false
            for (i, l) in remaining.enumerated() where l.row <= minRow + 1 {
                let da = l.a.distanceSquared(to: b.position.xy), db = l.b.distanceSquared(to: b.position.xy)
                if da < bestD { bestD = da; best = i; reversed = false }
                if db < bestD { bestD = db; best = i; reversed = true }
            }
            let line = remaining.remove(at: best)
            let (s, e) = reversed ? (line.b, line.a) : (line.a, line.b)
            let atDepth = abs(b.position.z - z) < 1e-6
            if !first && atDepth && b.position.xy.distance(to: s) <= stepover * 2.5 && segmentInside(b.position.xy, s, safe) {
                b.feed(Vec3(s, z))
            } else {
                b.enter(at: Vec3(s, z))
            }
            b.feed(Vec3(e, z))
            first = false
        }
    }
}
