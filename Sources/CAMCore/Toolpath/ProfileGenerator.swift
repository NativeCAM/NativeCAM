import Foundation

/// Inside / outside / on-line contour cutting with multiple depth passes, ramp entry and tabs.
///
/// Direction convention (clockwise M3 spindle): climb milling keeps the finished wall on the tool's right.
/// So an outside profile climbs clockwise around the part and an inside profile climbs counter-clockwise.
enum ProfileGenerator {
    static func generate(op: CAMOperation, params: ProfileParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        // A bit that's wider low down than higher up (a dovetail) can't step down, ramp, lift over a tab or lift out of
        // the cut where it is without cutting into the wall above: it cuts once at full depth, entered and left square
        // to the wall from far enough off it.
        let undercut = tool.hasUndercut
        let bitName = tool.name.isEmpty ? "T\(tool.number)" : "'\(tool.name)'"
        var params = params
        if undercut {
            if params.entry.kind == .ramp {
                warnings.append("\(bitName) is wider at its tip than above it, so it can't ramp in: it plunges in the waste instead.")
                params.entry.kind = .plunge
            }
            if params.tabs.enabled {
                warnings.append("\(bitName) is wider at its tip than above it, so it can't lift over tabs without cutting into the "
                    + "wall: tabs were left off. Hold the part another way.")
                params.tabs.enabled = false
            }
        }
        let polys = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
        let closed = polys.filter { $0.isClosed && $0.count >= 3 }
        let open = polys.filter { !$0.isClosed && $0.count >= 2 }

        // Effective radius: for tapered bits the cone radius where it meets the surface at final depth. A form or
        // dovetail bit rides the line with its tip (a form bit's pilot), so its profile is cut into the edge above it.
        let cutDepth = params.depth.cutDepth
        let r: Double
        switch tool.shape {
        case .taperedBallNose: r = tool.radius(atHeight: cutDepth)
        case .form, .dovetail: r = tool.radius(atHeight: 0)
        default: r = tool.shape.isTapered ? tool.radius(atHeight: cutDepth) : tool.radius
        }
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
                warnings.append("The tool (\(context.length(tool.diameter))) is too large to fit inside the selected shape(s).")
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
        // The parts other toolpaths cut nearby, less what this one cuts away itself (a rough's allowance, say), for
        // the leads and reliefs to keep clear of.
        var others: [ProtectedRegions.Zone] = []
        if let parts = context.protectedRegions, params.side != .on, params.leads != nil || params.cornerRelief != nil, !regions.isEmpty {
            let lead = params.leads.map { 2 * $0.size } ?? 0
            let reach = regions.reduce(Rect2.empty) { $0.union($1.bounds) }.insetBy(-(abs(params.allowance) + 2 * r + lead + 1))
            let cut = ProtectedRegions.profileCut(regions, side: params.side, allowance: params.allowance, toolRadius: r,
                                                  arcTolerance: context.arcTolerance)
            others = parts.zones(toolRadius: r, cut: cut, walls: regions.flatMap(\.loops), near: reach, arcTolerance: context.arcTolerance)
        }
        var reliefCorners: [ReliefCorner]?
        if let relief = params.cornerRelief {
            if params.side == .on {
                warnings.append("Corner reliefs need an inside or outside cut; they were skipped.")
            } else {
                let design = CornerRelief.Design(regions.flatMap(\.loops))
                let index = CornerRelief.ShapeIndex(shapes, tolerance: context.flattenTolerance)
                var matched = Set<Int>()
                var tally = CornerRelief.Tally()
                var marks: [ReliefCorner] = []
                for i in contours.indices where contours[i].closed {
                    let found = CornerRelief.corners(contours[i].loop, wasteOnLeft: wasteOnLeft, design: design, offset: offset,
                                                     maxCornerAngle: relief.maxCornerAngle, others: others)
                    let chosen = CornerRelief.choose(found, settings: relief, shapes: index, matched: &matched)
                    contours[i].reliefs = chosen.reliefs
                    tally.add(chosen)
                    marks += chosen.corners
                }
                reliefCorners = marks
                warnings += CornerRelief.warnings(tally, unmatched: (relief.overrides?.count ?? 0) - matched.count)
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
        var levels = depth.passLevels(toolStepdown: tool.cutting.stepdown, firstPassMinimum: tool.firstPassMinimum)
        // How far an undercut bit must be off the wall before it can lift out (a little spare for the arc fitting).
        let clearance = undercut ? tool.undercut(toDepth: depth.cutDepth) + 0.5 : 0
        if undercut, let last = levels.last {
            if levels.count > 1 {
                warnings.append("\(bitName) is wider at its tip than above it, so it cuts in one pass at full depth: stepping down "
                    + "would cut into the wall above each pass. Clear the waste with an end mill first.")
            }
            levels = [last]
            if params.side == .on {
                // Only an open line whose ends are off the material can be entered and left.
                let stockRect = context.stock.bounds
                func off(_ p: Vec2) -> Bool {
                    let dx = max(stockRect.min.x - p.x, 0, p.x - stockRect.max.x), dy = max(stockRect.min.y - p.y, 0, p.y - stockRect.max.y)
                    return (dx * dx + dy * dy).squareRoot() >= tool.radius - 1e-6
                }
                let kept = contours.filter { !$0.closed && off($0.loop.points[0]) && off($0.loop.points[$0.loop.count - 1]) }
                if kept.count < contours.count {
                    let n = contours.count - kept.count
                    warnings.append("\(bitName) is wider at its tip than above it, so on the line it can only cut a slot that starts and "
                        + "ends off the material (at least \(context.length(tool.radius)) past its edge): \(n == 1 ? "1 vector was" : "\(n) vectors were") "
                        + "skipped.")
                }
                contours = kept
            }
        }
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
        var leads = params.side == .on ? nil : params.leads
        if undercut, params.side != .on {
            // Straight off the wall, at least the undercut long, and back out the same way.
            leads = LeadSettings(kind: .line, length: max(clearance, params.leads?.size ?? 0), angle: 90, leadOut: true,
                                 overlap: params.leads?.overlap ?? 0)
        }
        if params.leads != nil && params.side == .on {
            warnings.append("Leads need an inside or outside cut; they were skipped.")
        }
        // With leads the toolpath starts above the first lead (not the first loop's start), so the opening rapid is
        // dropped; the first loop is still entered as near its own start as a lead fits.
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: leads == nil ? firstXY : nil)
        var probe = firstXY
        cursor = firstXY ?? .zero
        let centreClearance = ToolCentreClearance(regions: offsetRegions, inside: params.side == .inside, stock: context.stock,
                                                  toolRadius: tool.radius, keepOuts: context.keepOuts, others: others,
                                                  materialTop: context.materialTop, topLimit: -depth.startDepth)
        let rampLength: Double? = params.entry.kind == .ramp && params.entry.rampLength > 0 ? params.entry.rampLength : nil
        var unfitted = 0
        // Undercut bits: loops with no room to lead off the wall, and loops that plunge into uncut material.
        var stranded = 0
        var plungesIntoMaterial = 0
        let wallLoops = contours.filter(\.closed).map(\.loop)
        func clearOfWalls(_ p: Vec2) -> Bool {
            wallLoops.allSatisfy { $0.closestPoint(to: p).point.distance(to: p) >= clearance - 0.5 - 1e-6 }
        }
        // What lands on the material when an edge bit plunges: its bottom inside the tip's radius (a form bit's pilot;
        // the profile above it meets the edge it's meant to cut), half a dovetail's wide bottom.
        let plungeProbe = tool.shape == .dovetail ? tool.radius * 0.5 : max(0.1, 0.9 * tool.radius(atHeight: 0))
        func intoMaterial(_ p: Vec2, z: Double) -> Bool {
            guard tool.shape.cutsEdgesOnly, let top = context.materialTop else { return false }
            return top(p, plungeProbe) > z + 0.05
        }
        for contour in ordered {
            let near = probe ?? b.position.xy
            probe = nil
            if contour.closed {
                if let leads {
                    let relieved = CornerRelief.insert(contour.reliefs, into: contour.loop)
                    if let lead = LeadPlanner.fit(contour.loop, relieved: relieved, near: near, settings: leads, wasteOnLeft: wasteOnLeft,
                                                  clearance: centreClearance, rampLength: rampLength,
                                                  tabs: { TabPlan(length: $0.length, params: paramsAtDepth, tool: tool, lastLevel: levels[levels.count - 1]) },
                                                  linkLimit: max(3 * tool.diameter, 10), chordTolerance: context.arcTolerance) {
                        // The lead planner shortens a lead that doesn't fit; an undercut bit needs the whole length.
                        if undercut, !(clearOfWalls(lead.start) && clearOfWalls(lead.leadOut[lead.leadOut.count - 1])) {
                            stranded += 1
                            continue
                        }
                        if intoMaterial(lead.start, z: levels[0]) { plungesIntoMaterial += 1 }
                        cutClosedWithLeads(lead, levels: levels, params: paramsAtDepth, tool: tool, builder: &b, warnings: &warnings)
                        b.retract()
                        continue
                    }
                    if undercut {
                        stranded += 1
                        continue
                    }
                    unfitted += 1
                }
                // Reliefs go in after the start is chosen, so the entry never lands on a relief tip.
                let loop = CornerRelief.insert(contour.reliefs, into: contour.loop.startingNearest(near))
                if intoMaterial(loop.points[0], z: levels[0]) { plungesIntoMaterial += 1 }
                cutClosed(loop, levels: levels, params: paramsAtDepth, tool: tool, builder: &b, warnings: &warnings)
            } else {
                cutOpen(contour.loop, levels: levels, builder: &b)
            }
            b.retract()
        }
        if stranded > 0 {
            warnings.append("\(bitName) is wider at its tip than above it, so it must lead \(context.length(clearance)) straight off the "
                + "wall before lifting out, and \(stranded == 1 ? "1 loop has" : "\(stranded) loops have") no room for that: "
                + "\(stranded == 1 ? "it was" : "they were") skipped. Clear more room round \(stranded == 1 ? "it" : "them") first.")
        }
        if plungesIntoMaterial > 0 {
            warnings.append("\(bitName) plunges into uncut material at the start of \(plungesIntoMaterial == 1 ? "1 loop" : "\(plungesIntoMaterial) loops"). "
                + "Form and dovetail bits cut poorly on a plunge (a pilot or bearing doesn't cut at all): clear the waste with an "
                + "end mill first, or start off the material.")
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

    /// A closed loop without leads: entered at its first point (plunging, or ramping along the wall), cut at each level.
    static func cutClosed(_ loop: Polyline, levels: [Double], params: ProfileParams, tool: Tool,
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
    static func cutClosedWithLeads(_ lead: FittedLead, levels: [Double], params: ProfileParams, tool: Tool,
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
