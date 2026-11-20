import Foundation

/// Inside / outside / on-line contour cutting with multiple depth passes, ramp entry and tabs.
///
/// Direction convention (clockwise M3 spindle): climb milling keeps the finished wall on the tool's right.
/// So an outside profile climbs clockwise around the part and an inside profile climbs counter-clockwise.
enum ProfileGenerator {
    static func generate(op: CAMOperation, params: ProfileParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        let polys = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
        let closed = polys.filter { $0.isClosed && $0.count >= 3 }
        let open = polys.filter { !$0.isClosed && $0.count >= 2 }

        // Effective radius: for tapered bits the cone radius where it meets the surface at final depth.
        let cutDepth = params.depth.cutDepth
        let r = tool.shape.isTapered ? tool.radius(atHeight: cutDepth) : tool.radius
        let offset = r + params.allowance

        struct Contour { var loop: Polyline; var closed: Bool; var nesting: Int; var reliefs: [CornerRelief.Relief] = [] }
        var contours: [Contour] = []
        // The drawn regions and the tool-centre regions offset from them (inside and outside cuts).
        var regions: [Region] = []
        var offsetRegions: [Region] = []

        switch params.side {
        case .on:
            for loop in closed {
                // Treat like an outside cut so "climb" means clockwise.
                let ccw = params.direction == .conventional
                contours.append(Contour(loop: loop.oriented(counterClockwise: ccw), closed: true, nesting: 0))
            }
            for line in open { contours.append(Contour(loop: line, closed: false, nesting: 0)) }
        case .outside, .inside:
            if !open.isEmpty {
                warnings.append("\(open.count) open vector(s) can only be cut 'On'; they were skipped. Join them into closed shapes to cut inside/outside.")
            }
            regions = Region.build(from: closed, fill: .evenOdd)
            let delta = params.side == .outside ? offset : -offset
            offsetRegions = regions.flatMap { $0.offset(by: delta, arcTolerance: context.arcTolerance) }
            if params.side == .inside && offsetRegions.isEmpty && !regions.isEmpty {
                warnings.append("The tool (\(String(format: "%.3f", tool.diameter)) mm) is too large to fit inside the selected shape(s).")
            }
            // Region loops have the region interior on their left (outer CCW, holes CW).
            // Outside: the part is the region → climb needs it on the right → reverse.
            // Inside: the region is waste → keep orientation for climb.
            let reverse = (params.side == .outside) == (params.direction == .climb)
            for region in offsetRegions {
                for loop in region.loops {
                    contours.append(Contour(loop: reverse ? loop.reversed : loop, closed: true, nesting: 0))
                }
            }
        }

        // Climb keeps the finished wall on the tool's right, so the waste is on its left.
        let wasteOnLeft = params.direction == .climb
        var reliefCorners: [ReliefCorner]?
        if let relief = params.cornerRelief {
            if params.side == .on {
                warnings.append("Corner reliefs need an inside or outside cut; they were skipped.")
            } else {
                let design = CornerRelief.Design(regions.flatMap(\.loops))
                let index = CornerRelief.ShapeIndex(shapes, tolerance: context.flattenTolerance)
                var matched = Set<Int>()
                var blocked = 0
                var marks: [ReliefCorner] = []
                for i in contours.indices where contours[i].closed {
                    let found = CornerRelief.corners(contours[i].loop, wasteOnLeft: wasteOnLeft, design: design, offset: offset,
                                                     maxCornerAngle: relief.maxCornerAngle)
                    let chosen = CornerRelief.choose(found, settings: relief, shapes: index, matched: &matched)
                    contours[i].reliefs = chosen.reliefs
                    blocked += chosen.blocked
                    marks += chosen.corners
                }
                reliefCorners = marks
                warnings += CornerRelief.warnings(blocked: blocked, unmatched: (relief.overrides?.count ?? 0) - matched.count)
            }
        }

        // Nesting depth: loops inside other loops are cut first so parts don't shift before their holes are cut.
        let probes = contours.map { $0.closed ? ($0.loop.interiorPoint() ?? $0.loop.points[0]) : $0.loop.points[0] }
        for i in contours.indices {
            var depth = 0
            for j in contours.indices where j != i && contours[j].closed {
                if contours[j].loop.bounds.contains(probes[i]) && contours[j].loop.contains(probes[i]) { depth += 1 }
            }
            contours[i].nesting = depth
        }

        var depth = params.depth
        // Rest-aware start: skip depths that earlier toolpaths already cleared all along the cut. Only the inner half of
        // the tool's footprint counts, so a thin leftover ring at its edge (at most a quarter-diameter side cut) doesn't
        // force the whole cut to start at the top; full-width slotting at depth can't happen.
        if let top = context.materialTop, !contours.isEmpty {
            var highest = -Double.infinity
            for c in contours {
                let walker = LoopWalker(c.loop)
                let n = max(8, Int(walker.length / 2))
                for k in 0..<n { highest = max(highest, top(walker.point(at: walker.length * Double(k) / Double(n)), r * 0.5)) }
                // A corner an earlier toolpath didn't reach isn't cleared: its relief would cut a full-depth sliver.
                for relief in c.reliefs { highest = max(highest, top(relief.tip, r * 0.5)) }
            }
            if highest.isFinite, -highest > depth.startDepth + 0.05, -highest < depth.cutDepth - 0.05 {
                depth.startDepth = -highest
            }
        }
        var paramsAtDepth = params
        paramsAtDepth.depth = depth
        let levels = depth.passLevels(toolStepdown: tool.cutting.stepdown, firstPassMinimum: tool.firstPassMinimum)
        guard !levels.isEmpty, !contours.isEmpty else {
            if levels.isEmpty { warnings.append("Cut depth must be greater than the start depth.") }
            return ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
                .build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }

        // Order: deepest nesting first (inside before outside), shortest travel within each nesting level. A closed
        // loop is entered wherever it's nearest the tool, so first pick entries by nearest neighbour, then improve
        // the order of those entry points (and re-pick entries as the cut runs).
        var ordered: [Contour] = []
        var cursor = context.stock.homePosition.xy
        for depth in Set(contours.map(\.nesting)).sorted(by: >) {
            let group = contours.filter { $0.nesting == depth }
            func exit(_ i: Int, entry: Vec2) -> Vec2 { group[i].closed ? entry : group[i].loop.points[group[i].loop.count - 1] }
            var entries: [Vec2] = group.map { $0.loop.points[0] }
            var remaining = Array(group.indices)
            var probe = cursor
            while !remaining.isEmpty {
                var best = 0, bestD = Double.infinity, bestEntry = Vec2.zero
                for (k, i) in remaining.enumerated() {
                    let p = group[i].closed ? group[i].loop.closestPoint(to: probe).point : group[i].loop.points[0]
                    let d = p.distanceSquared(to: probe)
                    if d < bestD { bestD = d; best = k; bestEntry = p }
                }
                let i = remaining.remove(at: best)
                entries[i] = bestEntry
                probe = exit(i, entry: bestEntry)
            }
            let tour = TourOptimizer.order(count: group.count, from: cursor, start: { entries[$0] }, end: { exit($0, entry: entries[$0]) })
            ordered.append(contentsOf: tour.map { group[$0] })
            if let last = tour.last { cursor = exit(last, entry: entries[last]) }
        }

        let firstXY = ordered.first.map { $0.loop.points[0] }
        let leads = params.side == .on ? nil : params.leads
        if params.leads != nil && params.side == .on {
            warnings.append("Leads need an inside or outside cut; they were skipped.")
        }
        // With leads the toolpath starts above the first lead (not the first loop's start), so the opening rapid is
        // dropped; the first loop is still entered as near its own start as a lead fits.
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: leads == nil ? firstXY : nil)
        var probe = firstXY
        cursor = firstXY ?? .zero
        let clearance = ToolCentreClearance(regions: offsetRegions, inside: params.side == .inside, stock: context.stock,
                                            toolRadius: tool.radius, keepOuts: context.keepOuts,
                                            materialTop: context.materialTop, topLimit: -depth.startDepth)
        let rampLength: Double? = params.entry.kind == .ramp && params.entry.rampLength > 0 ? params.entry.rampLength : nil
        var unfitted = 0
        for contour in ordered {
            let near = probe ?? b.position.xy
            probe = nil
            if contour.closed {
                if let leads {
                    let relieved = CornerRelief.insert(contour.reliefs, into: contour.loop)
                    if let lead = LeadPlanner.fit(contour.loop, relieved: relieved, near: near, settings: leads, wasteOnLeft: wasteOnLeft,
                                                  clearance: clearance, rampLength: rampLength,
                                                  tabs: { TabPlan(length: $0.length, params: paramsAtDepth, tool: tool, lastLevel: levels[levels.count - 1]) },
                                                  linkLimit: max(3 * tool.diameter, 10), chordTolerance: context.arcTolerance) {
                        cutClosedWithLeads(lead, levels: levels, params: paramsAtDepth, tool: tool, builder: &b, warnings: &warnings)
                        b.retract()
                        continue
                    }
                    unfitted += 1
                }
                // Reliefs go in after the start is chosen, so the entry never lands on a relief tip.
                let loop = CornerRelief.insert(contour.reliefs, into: contour.loop.startingNearest(near))
                cutClosed(loop, levels: levels, params: paramsAtDepth, tool: tool, builder: &b, warnings: &warnings)
            } else {
                cutOpen(contour.loop, levels: levels, builder: &b)
            }
            b.retract()
        }
        if unfitted > 0 {
            warnings.append(unfitted == 1 ? "Leads didn't fit on 1 loop; it's entered without one."
                : "Leads didn't fit on \(unfitted) loops; they're entered without one.")
        }
        if params.tabs.enabled && params.side == .on {
            warnings.append("Tabs are only applied to inside/outside profiles.")
        }
        var toolpath = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        toolpath.reliefCorners = reliefCorners
        return toolpath
    }

    private static func cutClosed(_ loop: Polyline, levels: [Double], params: ProfileParams, tool: Tool,
                                  builder b: inout ToolpathBuilder, warnings: inout [String]) {
        let walker = LoopWalker(loop)
        let L = walker.length
        guard L > 1e-6 else { return }

        let tabs = TabPlan(length: L, params: params, tool: tool, lastLevel: levels[levels.count - 1])
        if tabs.tooShort {
            warnings.append("A contour is too short for \(params.tabs.count) tabs; tabs were skipped on it.")
        }
        func tabBreaks(_ s0: Double, _ s1: Double) -> [Double] { tabs.breaks(s0, s1) }
        func clampTab(_ s: Double, _ z: Double) -> Double { tabs.clamp(s, z) }

        let useRamp = params.entry.kind == .ramp && params.entry.rampLength > 0
        let rampLen = min(params.entry.rampLength, L * 0.98)
        var s = 0.0
        var zPrev = -params.depth.startDepth
        let first = walker.point(at: 0)
        b.enter(at: Vec3(first, useRamp ? zPrev : clampTab(0, levels[0])))

        for z in levels {
            if useRamp {
                let s0 = s, zp = zPrev
                // The ramp end must be its own vertex, or a long edge would stretch the descent across its full length.
                let breaks = tabBreaks(s0, s0 + rampLen + L) + [s0 + rampLen]
                let pts = walker.walk(from: s0, to: s0 + rampLen + L, breaks: breaks) { t in
                    let base = t < s0 + rampLen ? zp + (z - zp) * (t - s0) / rampLen : z
                    return clampTab(t, base)
                }
                b.follow(pts)
                s = s0 + rampLen + L
            } else {
                b.feed(Vec3(walker.point(at: s), clampTab(s, z)))
                let s0 = s
                let pts = walker.walk(from: s0, to: s0 + L, breaks: tabBreaks(s0, s0 + L)) { t in clampTab(t, z) }
                b.follow(pts)
                s = s0 + L
            }
            zPrev = z
        }
    }

    /// A closed loop entered and left on leads. The entry stays in one place on every pass, so each pass's leads cut
    /// one stepdown deeper:
    /// - plunge entry: plunge at the lead's start A (in the waste), lead in, a lap past the start by the overlap,
    ///   lead out, then straight back to A at that depth and down one pass;
    /// - ramp entry: the ramp runs from A at the previous floor along the lead-in and on along the wall, a full lap at
    ///   depth follows, then the lead-out and the link back to A at the same depth, so no plunge at all.
    /// When the link back isn't clear, the tool lifts and drops in at A instead (the link optimiser lowers the lift):
    /// with a plunge entry it plunges one pass in the waste; with a ramp it drops to the floor already cut at A and the
    /// next ramp starts from there (steeper, but each point still cuts at most one pass deeper).
    private static func cutClosedWithLeads(_ lead: FittedLead, levels: [Double], params: ProfileParams, tool: Tool,
                                           builder b: inout ToolpathBuilder, warnings: inout [String]) {
        let walker = LoopWalker(lead.loop)
        let L = walker.length
        guard L > 1e-6, let deepest = levels.last else { return }
        let tabs = TabPlan(length: L, params: params, tool: tool, lastLevel: deepest)
        if tabs.tooShort {
            warnings.append("A contour is too short for \(params.tabs.count) tabs; tabs were skipped on it.")
        }
        let useRamp = params.entry.kind == .ramp && params.entry.rampLength > 0
        let a = lead.start
        let leadIn = lead.leadIn
        var cumulative = [0.0]
        for (p, q) in zip(leadIn, leadIn.dropFirst()) { cumulative.append(cumulative[cumulative.count - 1] + p.distance(to: q)) }
        let leadInLength = cumulative[cumulative.count - 1]
        let rampWall = lead.rampWall
        let rampTotal = leadInLength + rampWall
        let lapEnd = L + lead.exit
        // Ramp: where this pass's ramp starts at A (the floor there).
        var zPrev = -params.depth.startDepth
        b.enter(at: Vec3(a, useRamp ? zPrev : levels[0]))
        for (k, z) in levels.enumerated() {
            if useRamp {
                let z0 = zPrev
                func rampZ(_ u: Double) -> Double { u < rampTotal ? z0 + (z - z0) * u / rampTotal : z }
                var pts: [Vec3] = []
                for j in 1..<leadIn.count {
                    // The ramp's end is its own vertex when it falls on the lead.
                    if rampTotal > cumulative[j - 1] + 1e-9, rampTotal < cumulative[j] - 1e-9 {
                        let f = (rampTotal - cumulative[j - 1]) / (cumulative[j] - cumulative[j - 1])
                        pts.append(Vec3(leadIn[j - 1].lerp(to: leadIn[j], f), z))
                    }
                    pts.append(Vec3(leadIn[j], rampZ(cumulative[j])))
                }
                b.follow(pts)
                let breaks = tabs.breaks(0, lapEnd) + (rampWall > 1e-9 ? [rampWall] : [])
                b.follow(walker.walk(from: 0, to: lapEnd, breaks: breaks) { t in
                    tabs.clamp(t, t < rampWall ? z0 + (z - z0) * (leadInLength + t) / rampTotal : z)
                })
            } else {
                b.follow(leadIn.dropFirst().map { Vec3($0, z) })
                b.follow(walker.walk(from: 0, to: lapEnd, breaks: tabs.breaks(0, lapEnd)) { t in tabs.clamp(t, z) })
            }
            let exitZ = b.position.z
            b.follow(lead.leadOut.dropFirst().map { Vec3($0, exitZ) })
            guard k + 1 < levels.count else { break }
            let next = levels[k + 1]
            if lead.linkAtDepth {
                b.feed(Vec3(a, exitZ))
                if useRamp { zPrev = z } else { b.feed(Vec3(a, next)) }
            } else {
                b.retract()
                b.enter(at: Vec3(a, useRamp ? zPrev : next))
            }
        }
    }

    private static func cutOpen(_ line: Polyline, levels: [Double], builder b: inout ToolpathBuilder) {
        var forward = true
        var pts = line.points
        // Start from the end nearest the tool.
        if pts[pts.count - 1].distance(to: b.position.xy) < pts[0].distance(to: b.position.xy) { pts.reverse() }
        b.enter(at: Vec3(pts[0], levels[0]))
        for z in levels {
            let seq = forward ? pts : pts.reversed()
            b.feed(Vec3(seq[0], z))
            b.follow(seq.dropFirst().map { Vec3($0, z) })
            forward.toggle()
        }
    }
}
