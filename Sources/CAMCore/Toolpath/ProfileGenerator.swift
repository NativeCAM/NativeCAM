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

        struct Contour { var loop: Polyline; var closed: Bool; var nesting: Int }
        var contours: [Contour] = []

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
            let regions = Region.build(from: closed, fill: .evenOdd)
            let delta = params.side == .outside ? offset : -offset
            let offsetRegions = regions.flatMap { $0.offset(by: delta, arcTolerance: context.arcTolerance) }
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
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: firstXY)
        cursor = firstXY ?? .zero
        for contour in ordered {
            if contour.closed {
                let loop = contour.loop.startingNearest(b.position.xy)
                cutClosed(loop, levels: levels, params: paramsAtDepth, tool: tool, builder: &b, warnings: &warnings)
            } else {
                cutOpen(contour.loop, levels: levels, builder: &b)
            }
            b.retract()
        }
        if params.tabs.enabled && params.side == .on {
            warnings.append("Tabs are only applied to inside/outside profiles.")
        }
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }

    private static func cutClosed(_ loop: Polyline, levels: [Double], params: ProfileParams, tool: Tool,
                                  builder b: inout ToolpathBuilder, warnings: inout [String]) {
        let walker = LoopWalker(loop)
        let L = walker.length
        guard L > 1e-6 else { return }

        // Tabs: evenly spaced, centred between the loop start and the next tab so entry isn't on a tab.
        var tabIntervals: [(Double, Double)] = []
        let tabZ = -params.depth.cutDepth + params.tabs.thickness
        if params.tabs.enabled, params.side != .on, params.tabs.count > 0, tabZ > levels.last! {
            let span = params.tabs.width + tool.diameter
            if span * Double(params.tabs.count) < L * 0.8 {
                for k in 0..<params.tabs.count {
                    let c = L * (Double(k) + 0.5) / Double(params.tabs.count)
                    tabIntervals.append((c - span / 2, c + span / 2))
                }
            } else {
                warnings.append("A contour is too short for \(params.tabs.count) tabs; tabs were skipped on it.")
            }
        }
        func inTab(_ s: Double) -> Bool {
            guard !tabIntervals.isEmpty else { return false }
            var d = s.truncatingRemainder(dividingBy: L)
            if d < 0 { d += L }
            return tabIntervals.contains { d > $0.0 && d < $0.1 }
        }
        func tabBreaks(_ s0: Double, _ s1: Double) -> [Double] {
            guard !tabIntervals.isEmpty else { return [] }
            var out: [Double] = []
            var w = (s0 / L).rounded(.down) - 1
            while w * L <= s1 {
                for (a, c) in tabIntervals { out.append(w * L + a); out.append(w * L + c) }
                w += 1
            }
            return out
        }
        func clampTab(_ s: Double, _ z: Double) -> Double { inTab(s) && z < tabZ ? tabZ : z }

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
