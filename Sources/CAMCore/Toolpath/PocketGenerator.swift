import Foundation

/// Area clearing for closed shapes (holes in the selection become islands).
enum PocketGenerator {
    /// One toolpath, or with a clearance tool two: the larger tool's clearing, then the operation's own tool on what
    /// it left (rest machining; see `PocketParams.clearanceTool`).
    static func generate(op: CAMOperation, params: PocketParams, shapes: [DesignShape], context: GenerationContext) -> [Toolpath] {
        let tool = op.tool
        if params.strategy == .adaptive, context.stock.rotary?.isWrapped == true {
            let b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
            return [b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: [
                "Adaptive clearing isn't available on wrapped rotary jobs yet, so this pocket isn't cut. Choose Offset or Raster."])]
        }
        let loops = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }.filter { $0.isClosed }
        let regions = Region.build(from: loops, fill: .evenOdd)
        var notes: [String] = []
        if params.restsFromEarlier, !regions.isEmpty {
            let earlier = earlierReach(op: op, context: context)
            if earlier.counted {
                return restMachined(op: op, params: params, large: params.clearanceTool, earlier: earlier, regions: regions,
                                    shapes: shapes, context: context)
            }
            notes = earlier.warnings
        }
        if let large = params.clearanceTool, !regions.isEmpty {
            return restMachined(op: op, params: params, large: large, earlier: notes.isEmpty ? nil : EarlierReach(warnings: notes),
                                regions: regions, shapes: shapes, context: context)
        }
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let result = clear(regions: regions, tool: tool, params: params, context: context, shapes: shapes, builder: &b)
        var toolpath = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: notes + result.warnings)
        toolpath.reliefCorners = result.corners
        if params.strategy == .adaptive { toolpath.radialLoad = params.adaptiveSettings.load }
        return [toolpath]
    }

    // MARK: Rest machining

    /// Rest pieces narrower than this are dropped, mm: material that thin isn't worth a trip, and it hides the
    /// slivers left where two offsets of the same curve disagree by their arc tolerance.
    static func restTolerance(arcTolerance: Double) -> Double { 0.02 + 2 * arcTolerance }

    /// What the pocket toolpaths a pocket rests from reached (`earlierReach`).
    struct EarlierReach {
        /// Each one's own pocket, less its allowance, opened by its bit's radius.
        var reached: [Region] = []
        var warnings: [String] = []
        /// There were some to count; when false the warnings say there weren't, and the pocket is cleared as without
        /// the option.
        var counted = false
    }

    /// What the pocket toolpaths `op` rests from (`RestMachining.pocketReferences`) reached.
    static func earlierReach(op: CAMOperation, context: GenerationContext) -> EarlierReach {
        guard let project = context.project else {
            return EarlierReach(warnings: ["Rest from earlier toolpaths follows the toolpaths before it in the job, so on its own this "
                + "clears the whole pocket."])
        }
        let refs = RestMachining.pocketReferences(for: op, in: project)
        let tol = context.arcTolerance
        var out = EarlierReach(warnings: refs.warnings, counted: !refs.operations.isEmpty)
        for ref in refs.operations {
            guard case let .pocket(q) = ref.kind else { continue }
            let loops = project.shapes(for: ref).filter { !$0.isKeepOut }.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
                .filter(\.isClosed)
            let r = ref.tool.radius
            out.reached += Region.build(from: loops, fill: .evenOdd).flatMap { $0.offset(by: -(r + q.allowance), arcTolerance: tol) }
                .flatMap { $0.offset(by: r, arcTolerance: tol) }
        }
        return out
    }

    /// The part of the pocket (less the allowance) `small` reaches that `reached` doesn't cover, less pieces narrower
    /// than the rest tolerance: what's left for it to cut.
    static func leftover(_ regions: [Region], small: Tool, allowance: Double, reached: [Region], arcTolerance tol: Double) -> [Region] {
        let mine = regions.flatMap { $0.offset(by: -(small.radius + allowance), arcTolerance: tol) }
            .flatMap { $0.offset(by: small.radius, arcTolerance: tol) }.flatMap(\.loops)
        let rest = Region.nest(Clipper.difference(mine, minus: reached.flatMap(\.loops)))
        return opened(rest, by: restTolerance(arcTolerance: tol) / 2, arcTolerance: tol)
    }

    /// The larger tool clears the whole pocket with the operation's strategy and its own stepover, pass depth and
    /// feeds, leaving the allowance plus the rest margin on the walls. The operation's tool then runs the wall
    /// pass (with any corner reliefs) at each of its pass depths, and offset rings wherever neither the larger tool
    /// nor that wall pass reaches.
    ///
    /// Resting from earlier toolpaths (`earlier`, with or without a clearance tool), what they reached counts too, and
    /// the wall pass runs only where something is left to cut (`leftover`): in pieces round the corners and along the
    /// walls next to what's left, each starting and ending where it's already clear. With nothing left, the toolpath is
    /// empty and says so.
    static func restMachined(op: CAMOperation, params: PocketParams, large: Tool?, earlier: EarlierReach?, regions: [Region],
                             shapes: [DesignShape], context: GenerationContext) -> [Toolpath] {
        let small = op.tool
        let tol = context.arcTolerance
        var warnings: [String] = earlier?.warnings ?? []
        var toolpaths: [Toolpath] = []
        var reached: [Region]?
        let resting = earlier?.counted == true
        if let large {
            reached = clearFirst(op: op, params: params, large: large, regions: regions, context: context, resting: resting,
                                 warnings: &warnings, toolpaths: &toolpaths)
        }
        var zone: [Region]?
        var left: [Region]?
        if let earlier, earlier.counted {
            let all = (reached ?? []) + earlier.reached
            reached = all
            let rest = leftover(regions, small: small, allowance: params.allowance, reached: all, arcTolerance: tol)
            left = rest
            guard !rest.isEmpty else {
                warnings.append("Nothing left to cut: the larger bits before it reach the whole pocket, so it posts nothing.")
                var main = ToolpathBuilder(stock: context.stock, tool: small, startXY: nil)
                    .build(id: op.id, name: op.name, tool: small, rpm: small.cutting.spindleRPM, warnings: warnings)
                main.restAreas = []
                toolpaths.append(main)
                return toolpaths
            }
            // The wall pass is needed where the bit's edge reaches what's left: within its radius, and a little more so
            // each piece runs on past it.
            zone = rest.flatMap { $0.offset(by: 1.1 * small.radius + 0.05, arcTolerance: tol) }
        }

        var b = ToolpathBuilder(stock: context.stock, tool: small, startXY: nil)
        let result = clear(regions: regions, tool: small, params: params, context: context, shapes: shapes, reached: reached,
                           wallZone: zone, builder: &b)
        var main = b.build(id: op.id, name: op.name, tool: small, rpm: small.cutting.spindleRPM, warnings: warnings + result.warnings)
        main.reliefCorners = result.corners
        main.restAreas = left?.flatMap(\.loops)
        toolpaths.append(main)
        return toolpaths
    }

    /// The clearance tool's toolpath, appended to `toolpaths`; returns the area it reached (nil when it doesn't fit).
    /// `resting`: the pocket rests from earlier toolpaths too, so whether the clearance tool reaches it all isn't the
    /// whole story.
    private static func clearFirst(op: CAMOperation, params: PocketParams, large: Tool, regions: [Region], context: GenerationContext,
                                   resting: Bool, warnings: inout [String], toolpaths: inout [Toolpath]) -> [Region]? {
        let small = op.tool
        let tol = context.arcTolerance
        func label(_ t: Tool) -> String { t.name.isEmpty ? "T\(t.number)" : t.name }
        let larger = large.diameter > small.diameter + 1e-6
        if !larger {
            warnings.append("The clearance tool (\(label(large))) isn't larger than this toolpath's tool (\(label(small))), so it saves "
                + "no cutting. Choose a larger clearance tool, or none.")
        }
        if large.shape != .flatEndMill && large.shape != .surfacing {
            warnings.append("The clearance tool (\(label(large))) is a \(large.shape.label.lowercased()), so it leaves an uneven "
                + "floor where this toolpath's tool doesn't recut it. Clear with a flat end mill.")
        }

        var lp = params
        lp.allowance = params.allowance + PocketParams.restMargin(for: small)
        lp.stepoverFraction = nil
        lp.depth.passDepth = nil
        lp.cornerRelief = nil
        let centres = regions.flatMap { $0.offset(by: -(large.radius + lp.allowance), arcTolerance: tol) }
        var reached: [Region]?
        if centres.isEmpty {
            warnings.append("The clearance tool (\(label(large))) is too large to fit in the pocket, so this toolpath's tool clears "
                + "all of it.")
        } else {
            var cb = ToolpathBuilder(stock: context.stock, tool: large, startXY: nil)
            let cleared = clear(regions: regions, tool: large, params: lp, context: context, shapes: [], builder: &cb)
            var tp = cb.build(id: VCarveGenerator.deterministicID(op.id, salt: 1), name: "\(op.name) – clearing", tool: large,
                              rpm: large.cutting.spindleRPM, warnings: cleared.warnings)
            tp.operationID = op.id
            if params.strategy == .adaptive { tp.radialLoad = params.adaptiveSettings.load }
            // Without depths both toolpaths would say so; the operation's own does.
            if !tp.isEmpty { toolpaths.append(tp) }
            reached = centres.flatMap { $0.offset(by: large.radius, arcTolerance: tol) }
            if larger, !resting, restRegion(regions, large: large, small: small, allowance: params.allowance, arcTolerance: tol).isEmpty {
                warnings.append("The clearance tool (\(label(large))) reaches the whole pocket, so this toolpath's tool only makes the "
                    + "pass round the walls. Cut the pocket with \(label(large)) alone and save a tool change.")
            }
        }
        return reached
    }

    /// The parts of the finished pocket only `small` reaches: the regions (less the allowance) opened by its radius,
    /// minus the same opened by `large`'s, less pieces narrower than the rest tolerance. Corners, and slots
    /// narrower than `large`.
    static func restRegion(_ regions: [Region], large: Tool, small: Tool, allowance: Double, arcTolerance tol: Double) -> [Region] {
        func reach(_ r: Double) -> [Polyline] {
            regions.flatMap { $0.offset(by: -(r + allowance), arcTolerance: tol) }.flatMap { $0.offset(by: r, arcTolerance: tol) }
                .flatMap(\.loops)
        }
        let rest = Region.nest(Clipper.difference(reach(small.radius), minus: reach(large.radius)))
        return opened(rest, by: restTolerance(arcTolerance: tol) / 2, arcTolerance: tol)
    }

    /// Drops the parts of `regions` narrower than twice `w` (and rounds the rest's corners by `w`).
    static func opened(_ regions: [Region], by w: Double, arcTolerance tol: Double) -> [Region] {
        regions.flatMap { $0.offset(by: -w, arcTolerance: tol) }.flatMap { $0.offset(by: w, arcTolerance: tol) }
    }

    /// Tool-centre areas for the rest clearing: inside the wall ring (`boundary`, the tool-centre boundary), the
    /// pocket more than a tool radius in from it (the wall pass reaches the rest) that `reached` doesn't cover. Thin
    /// pieces are dropped and the others grown by a fifth of the tool radius, so the cuts overlap and leave no
    /// slivers; they stay inside the wall ring.
    static func restPieces(_ boundary: [Region], reached: [Region], toolRadius r: Double, arcTolerance tol: Double) -> [Region] {
        let inner = boundary.flatMap { $0.offset(by: -r, arcTolerance: tol) }
        guard !inner.isEmpty else { return [] }
        let left = Region.nest(Clipper.difference(inner.flatMap(\.loops), minus: reached.flatMap(\.loops)))
        let w = restTolerance(arcTolerance: tol) / 2
        return left.flatMap { $0.offset(by: -w, arcTolerance: tol) }.flatMap { $0.offset(by: w + 0.2 * r, arcTolerance: tol) }
    }

    /// The wall rings, each with ring trees for its rest pieces under it, so `cutTree` clears the rest inside out and
    /// then runs the wall pass.
    static func restTree(_ boundary: [Region], reached: [Region], stepover: Double, toolRadius r: Double,
                         arcTolerance tol: Double) -> [RingNode] {
        let roots = boundary.map(RingNode.init)
        for piece in restPieces(boundary, reached: reached, toolRadius: r, arcTolerance: tol) {
            let probe = piece.outer.interiorPoint() ?? piece.outer.points[0]
            guard let root = roots.first(where: { $0.region.contains(probe) }) ?? roots.first else { continue }
            root.children += ringTree([piece], stepover: stepover, toolRadius: r, arcTolerance: tol)
        }
        return roots
    }

    /// Shared by pockets and V-carve flat-area clearing. Appends to `b`, returns warnings.
    /// `smoothBoundary` also rounds the outermost rings' corners (for roughing that leaves an allowance; a pocket's
    /// walls stay exact). Inner rings are always smoothed within the machine's roughing smoothing budget.
    /// `rasterPasses`: how raster lines are cut (`cutRaster`); the walls' pass follows `params.direction`.
    static func generate(regions: [Region], tool: Tool, params: PocketParams, context: GenerationContext,
                         smoothBoundary: Bool = false, rasterPasses: PassDirection = .both, builder b: inout ToolpathBuilder) -> [String] {
        clear(regions: regions, tool: tool, params: params, context: context, smoothBoundary: smoothBoundary, shapes: [],
              rasterPasses: rasterPasses, builder: &b).warnings
    }

    /// The clearing itself. `shapes` are the drawn shapes the regions came from, so corner choices can find their
    /// corners; also returns the wall corners that get reliefs (nil without corner reliefs). With `reached` (the area a
    /// clearance tool already cut), only the rest is cleared, with offset rings whatever the strategy, then the walls.
    /// `wallZone` (with `reached`): the wall pass is cut only inside it, in pieces (`cutRest`).
    static func clear(regions: [Region], tool: Tool, params: PocketParams, context: GenerationContext, smoothBoundary: Bool = false,
                      shapes: [DesignShape], reached: [Region]? = nil, wallZone: [Region]? = nil, rasterPasses: PassDirection = .both,
                      builder b: inout ToolpathBuilder) -> (warnings: [String], corners: [ReliefCorner]?) {
        var warnings: [String] = []
        if regions.isEmpty {
            warnings.append("Pockets need closed shapes; none were selected.")
            return (warnings, nil)
        }
        let r = tool.radius
        let stepover = max(0.05, tool.stepoverBasis * (params.stepoverFraction ?? tool.cutting.stepoverFraction))
        if stepover > tool.diameter * 0.95 {
            warnings.append("Stepover is larger than the tool diameter; material will be left behind.")
        }
        // Adaptive clearing cuts the full length of the flutes at once; rest machining's rings take the bit's stepdown.
        let levels = reached == nil ? params.passLevels(tool)
            : params.depth.passLevels(toolStepdown: tool.cutting.stepdown, firstPassMinimum: tool.firstPassMinimum)
        if levels.isEmpty {
            warnings.append("Cut depth must be greater than the start depth.")
            return (warnings, nil)
        }

        // Tool-centre boundary: shrink each region by the tool radius plus allowance.
        let boundary = regions.flatMap { $0.offset(by: -(r + params.allowance), arcTolerance: context.arcTolerance) }
        if boundary.isEmpty {
            warnings.append("The tool is too large to fit in the pocket.")
            return (warnings, nil)
        }
        // Feed links are allowed only if they stay inside this (slightly grown) safe area.
        let safe = boundary.flatMap { $0.offset(by: 0.01, arcTolerance: context.arcTolerance) }

        // Corner reliefs on the wall rings: the boundary and its islands (region loops have the pocket on their left).
        var reliefs: [CornerRelief.Relief] = []
        var reliefCorners: [ReliefCorner]?
        if let relief = params.cornerRelief {
            let design = CornerRelief.Design(regions.flatMap(\.loops))
            let index = CornerRelief.ShapeIndex(shapes, tolerance: context.flattenTolerance)
            // The parts other toolpaths cut nearby, less the pocket itself.
            var others: [ProtectedRegions.Zone] = []
            if let parts = context.protectedRegions {
                let cut = abs(params.allowance) < 1e-9 ? regions
                    : regions.flatMap { $0.offset(by: -params.allowance, arcTolerance: context.arcTolerance) }
                let reach = regions.reduce(Rect2.empty) { $0.union($1.bounds) }.insetBy(-(abs(params.allowance) + r + 1))
                others = parts.zones(toolRadius: r, cut: cut.flatMap(\.loops), walls: regions.flatMap(\.loops), near: reach,
                                     arcTolerance: context.arcTolerance)
            }
            var matched = Set<Int>()
            var tally = CornerRelief.Tally()
            var marks: [ReliefCorner] = []
            for loop in boundary.flatMap(\.loops) {
                let found = CornerRelief.corners(loop, wasteOnLeft: true, design: design, offset: r + params.allowance,
                                                 maxCornerAngle: relief.maxCornerAngle, others: others)
                let chosen = CornerRelief.choose(found, settings: relief, shapes: index, matched: &matched)
                reliefs += chosen.reliefs
                tally.add(chosen)
                marks += chosen.corners
            }
            reliefCorners = marks
            warnings += CornerRelief.warnings(tally, unmatched: (relief.overrides?.count ?? 0) - matched.count)
        }

        if let reached {
            let tree = restTree(boundary, reached: reached, stepover: stepover, toolRadius: r, arcTolerance: context.arcTolerance)
            smooth(tree, deviation: context.machine.cornerSmoothing, plannerDeviation: context.machine.cornerDeviation,
                   stepover: stepover, toolRadius: r, boundary: false, chordTolerance: context.arcTolerance)
            var zAbove = -params.depth.startDepth
            for z in levels {
                var first = true
                if let wallZone {
                    cutRest(tree, wallZone: wallZone, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe,
                            reliefs: reliefs, toolRadius: r, first: &first, builder: &b)
                } else {
                    cutTree(tree, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, reliefs: reliefs,
                            first: &first, builder: &b)
                }
                b.retract()
                zAbove = z
            }
            return (warnings, reliefCorners)
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
                cutRaster(lines, z: z, zAbove: zAbove, stepover: stepover, safe: safe, params: params, passes: rasterPasses,
                          first: &first, builder: &b)
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
        case .adaptive:
            warnings += AdaptiveClearing.cut(boundary: boundary, tool: tool, params: params, levels: levels, context: context,
                                             reliefs: reliefs, safe: safe, builder: &b)
        }
        return (warnings, reliefCorners)
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
    static func cutTree(_ nodes: [RingNode], z: Double, zAbove: Double, params: PocketParams, stepover: Double, safe: [Region],
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

    /// Rest from earlier toolpaths at one depth: each wall ring's rest pieces (offset rings, inside out, as `cutTree`
    /// cuts them), then its wall pass, but only the parts of it inside `wallZone` (`wallPieces`): a loop that's all
    /// inside it as `cutLoop` cuts it, otherwise the pieces of it there, each fed in from a plunge where it's clear.
    static func cutRest(_ nodes: [RingNode], wallZone zone: [Region], z: Double, zAbove: Double, params: PocketParams, stepover: Double,
                        safe: [Region], reliefs: [CornerRelief.Relief], toolRadius r: Double, first: inout Bool,
                        builder b: inout ToolpathBuilder) {
        let ordered = nearestNeighborOrder(nodes, from: b.position.xy,
                                           start: { $0.region.outer.closestPoint(to: b.position.xy).point },
                                           end: { $0.region.outer.points[0] })
        for node in ordered {
            cutTree(node.children, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, first: &first, builder: &b)
            for loop in node.region.holes + [node.region.outer] {
                let oriented = params.direction == .climb ? loop : loop.reversed
                let step = max(0.05, min(1, r / 2))
                guard let pieces = wallPieces(CornerRelief.insert(reliefs, into: oriented), inside: zone, step: step) else {
                    cutLoop(oriented, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, reliefs: reliefs,
                            first: &first, builder: &b)
                    continue
                }
                for piece in pieces where piece.count >= 2 {
                    let start = Vec3(piece[0], z)
                    if !first, abs(b.position.z - z) < 1e-6, b.position.xy.distance(to: piece[0]) <= stepover * 2.5,
                       segmentInside(b.position.xy, piece[0], safe) {
                        b.feed(start)
                    } else {
                        b.enter(at: start)
                    }
                    b.follow(piece.dropFirst().map { Vec3($0, z) })
                    first = false
                }
            }
        }
    }

    /// The parts of the closed `loop` inside `zone`, in the loop's direction, each running on to the first tested point
    /// past the zone's edge at either end (points `step` apart along the loop are tested). nil when all of it is inside.
    static func wallPieces(_ loop: Polyline, inside zone: [Region], step: Double) -> [[Vec2]]? {
        let pts = loop.points
        let n = pts.count
        guard n >= 2 else { return [] }
        func inZone(_ p: Vec2) -> Bool { zone.contains { $0.contains(p) } }
        // Samples round the loop: each vertex (kept in a piece), then points along its segment (kept only at a piece's
        // ends).
        var samples: [(p: Vec2, vertex: Bool, inside: Bool)] = []
        for i in 0..<n {
            let a = pts[i], c = pts[(i + 1) % n]
            let k = max(1, Int((a.distance(to: c) / step).rounded(.up)))
            samples.append((a, true, inZone(a)))
            for j in 1..<k {
                let p = a.lerp(to: c, Double(j) / Double(k))
                samples.append((p, false, inZone(p)))
            }
        }
        guard let out = samples.firstIndex(where: { !$0.inside }) else { return nil }
        guard samples.contains(where: \.inside) else { return [] }
        let m = samples.count
        var pieces: [[Vec2]] = []
        var current: [Vec2] = []
        for s in 1...m {
            let k = (out + s) % m, prev = (out + s - 1) % m
            let here = samples[k]
            if here.inside {
                if current.isEmpty { current = [samples[prev].p] }
                if here.vertex || !samples[(k + 1) % m].inside || !samples[prev].inside { current.append(here.p) }
            } else if !current.isEmpty {
                current.append(here.p)
                pieces.append(current)
                current = []
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
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

    /// Cuts raster lines at `z`. Both ways, they zig-zag: the nearest end on the lowest rows next, linked at depth when
    /// it's close. Climbing or conventional, the rows are cut in order up the raster (+90° from the raster angle), each
    /// the one way that keeps the next row's material on the tool's right (climb, travelling at the raster angle + 180°)
    /// or left (conventional, at the raster angle), and each line is entered from above: the link back is left to the
    /// job's link optimiser, which lowers it to just over the material where that's safe.
    static func cutRaster(_ lines: [RasterLine], z: Double, zAbove: Double, stepover: Double, safe: [Region], params: PocketParams,
                          passes: PassDirection = .both, first: inout Bool, builder b: inout ToolpathBuilder) {
        if passes != .both {
            let dir = Vec2.fromAngle(params.rasterAngle.radians)
            // Rows up the raster; along each, in the direction it's cut.
            let travel = passes == .climb ? -1.0 : 1.0
            let ordered = lines.sorted { l, m in
                l.row != m.row ? l.row < m.row : travel * l.a.dot(dir) < travel * m.a.dot(dir)
            }
            for line in ordered {
                let (s, e) = passes == .climb ? (line.b, line.a) : (line.a, line.b)
                b.enter(at: Vec3(s, z))
                b.feed(Vec3(e, z))
                first = false
            }
            return
        }
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

// MARK: Tool-centre areas

extension PocketGenerator {
    /// Clears areas given as where the tool's centre may go, for a caller that has already allowed for the tool's shape
    /// (3D rotary roughing works them out with its drop-cutter): offset rings inside out, ramping in from `zAbove`, or
    /// raster lines at `rasterAngle` (degrees) and a pass round each area's edge. One level, `z`; links stay down
    /// inside the areas as a pocket's do, and the tool is back at safe Z at the end.
    static func clearCentres(_ boundary: [Region], strategy: PocketStrategy, rasterAngle: Double, stepover: Double, tool: Tool,
                             z: Double, zAbove: Double, passes: PassDirection = .both, context: GenerationContext,
                             builder b: inout ToolpathBuilder) {
        guard !boundary.isEmpty else { return }
        let entry = strategy == .offset ? EntrySettings(kind: .ramp, rampLength: 2 * tool.diameter) : EntrySettings()
        let params = PocketParams(strategy: strategy, direction: passes == .conventional ? .conventional : .climb,
                                  depth: DepthSettings(startDepth: -zAbove, cutDepth: -z), rasterAngle: rasterAngle, entry: entry)
        let safe = boundary.flatMap { $0.offset(by: 0.01, arcTolerance: context.arcTolerance) }
        var first = true
        switch strategy {
        case .offset, .adaptive:
            // (Nothing asks for adaptive here; 3D rotary roughing's patterns are offset rings or raster lines.)
            let tree = ringTree(boundary, stepover: stepover, toolRadius: tool.radius, arcTolerance: context.arcTolerance)
            smooth(tree, deviation: context.machine.cornerSmoothing, plannerDeviation: context.machine.cornerDeviation,
                   stepover: stepover, toolRadius: tool.radius, boundary: false, chordTolerance: context.arcTolerance)
            cutTree(tree, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, first: &first, builder: &b)
        case .raster:
            let lines = rasterLines(boundary, stepover: stepover, angle: rasterAngle)
            cutRaster(lines, z: z, zAbove: zAbove, stepover: stepover, safe: safe, params: params, passes: passes, first: &first, builder: &b)
            for region in boundary {
                for loop in region.loops {
                    // The edge pass climbs (outer loops counter-clockwise, holes clockwise) unless conventional is asked for.
                    let oriented = passes == .conventional ? loop.reversed : loop
                    cutLoop(oriented, z: z, zAbove: zAbove, params: params, stepover: stepover, safe: safe, first: &first, builder: &b)
                }
            }
        }
        b.retract()
    }
}
