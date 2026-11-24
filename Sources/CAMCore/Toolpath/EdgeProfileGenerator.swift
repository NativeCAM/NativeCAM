import Foundation

// MARK: The passes

/// How an edge profile's passes divide its profile (`EdgeProfileParams.plan(tool:thickness:)`).
///
/// In the plane square to the edge, with u measured into the part from the edge and h up from the bit's tip, the bit's
/// cutting edge is r(h) out from its axis, and at its final position the axis is c = (pilot radius + offset) off the
/// edge, on the waste side. A pass stood a further s off removes what lies within r(h) − c − s of the edge at each
/// height, so every pass's cut is the final profile moved s out from the part: no pass reaches past it, and the
/// passes nest, each taking the band between its own and the one before. Its cross-section, against a square edge the
/// material's thickness tall, is
///
///     A(d, s) = ∫ max(0, r(h) − c − s) dh, over h from max(0, d − thickness) to d (the tip d below the top),
///
/// so a pass takes A(its own) − A(the pass before's). This is what one full pass at the depth takes when c is the pilot
/// radius and s = 0, as `ChipLoad.crossSection` has it.
public struct EdgeProfilePlan: Hashable, Sendable {
    public struct Pass: Hashable, Sendable {
        /// How far the bit stands off its final position, mm (0 for the last pass).
        public var standoff: Double
        /// The depths its tip cuts at below the material top, mm: one for a horizontal pass, several stepping down for a
        /// vertical one.
        public var depths: [Double]
        /// How far it steps in from the pass before, mm.
        public var band: Double
        /// The cross-section each of its laps takes, one per depth, mm².
        public var laps: [Double]
        /// The light last pass after the others.
        public var isFinish: Bool

        public var crossSection: Double { laps.reduce(0, +) }
        public var largestLap: Double { laps.max() ?? 0 }
    }

    /// In cutting order, from the outside in.
    public var passes: [Pass]
    /// Depth of the tip below the material top, mm.
    public var depth: Double
    /// How far into the part the profile reaches at its widest (the top, for a profile that widens going up), mm.
    public var reach: Double
    /// Distance from the edge to the bit's axis at its final position (its radius at the tip, plus the offset), mm.
    public var centreOffset: Double
    /// The step left above the profile when it's cut deeper than the profile is tall, mm.
    public var reveal: Double
    /// The whole profile's cross-section against a square edge, mm².
    public var crossSection: Double

    /// The most any one lap takes, mm²: what the chip-load chart's cross-section rule reads (`ChipLoad.reading`).
    public var largestLap: Double { passes.map(\.largestLap).max() ?? 0 }
    /// The pass (from 0) whose lap takes the most.
    public var largestPass: Int? { passes.indices.max { passes[$0].largestLap < passes[$1].largestLap } }
}

public extension EdgeProfileParams {
    /// The passes `tool` takes on an edge `thickness` tall (`EdgeProfilePlan`). Empty when the bit doesn't reach the edge.
    func plan(tool: Tool, thickness: Double) -> EdgeProfilePlan {
        let d = depth(for: tool)
        let edge = tool.cuttingEdge
        let c = ToolProfile.radius(edge, atHeight: 0) + offset
        let tall = max(0.01, thickness)
        func r(_ h: Double) -> Double { ToolProfile.radius(edge, atHeight: h) }
        // The profile's reach into the part at its widest, between the material's bottom (or the tip) and its top.
        let low = max(0, d - tall)
        var reach = 0.0
        for i in 0...200 { reach = max(reach, r(low + (d - low) * Double(i) / 200) - c) }
        func area(_ depth: Double, _ s: Double) -> Double {
            let a = max(0, depth - tall), b = depth
            guard b - a > 1e-9 else { return 0 }
            let n = 200
            let step = (b - a) / Double(n)
            var sum = 0.0
            for i in 0...n {
                let w = i == 0 || i == n ? 1.0 : (i % 2 == 1 ? 4.0 : 2.0)
                sum += w * max(0, r(a + Double(i) * step) - c - s)
            }
            return sum * step / 3
        }
        var plan = EdgeProfilePlan(passes: [], depth: d, reach: reach, centreOffset: c, reveal: reveal(for: tool),
                                   crossSection: area(d, 0))
        guard reach > 0.01 else { return plan }
        let f = min(max(0, finish), reach)
        let rough = reach - f
        // The final position: the finish's, or the last rough pass's when there's no finish (or nothing left for one).
        let finishing = f > 1e-6 && rough > 0.01
        switch passes {
        case .horizontal:
            var standoffs: [Double] = []
            if rough > 0.01 {
                if let band = bandWidth, band > 1e-6 {
                    let n = max(1, Int((rough / band - 1e-9).rounded(.up)))
                    standoffs = (1...n).map { f + rough * Double(n - $0) / Double(n) }
                } else {
                    // Equal shares of the cross-section: A(d, s) falls from A(d, f) to 0 as s goes from f to the reach.
                    let n = max(1, passCount)
                    let total = area(d, f)
                    standoffs = (1..<n).map { k in
                        let target = total * Double(k) / Double(n)
                        var lo = f, hi = reach
                        for _ in 0..<60 {
                            let mid = (lo + hi) / 2
                            if area(d, mid) > target { lo = mid } else { hi = mid }
                        }
                        return (lo + hi) / 2
                    } + [f]
                }
            } else {
                standoffs = [0]
            }
            if finishing { standoffs.append(0) }
            var before = reach, taken = 0.0
            for (k, s) in standoffs.enumerated() {
                let now = area(d, s)
                plan.passes.append(.init(standoff: s, depths: [d], band: before - s, laps: [max(0, now - taken)],
                                         isFinish: finishing && k == standoffs.count - 1))
                before = s
                taken = now
            }
        case .vertical:
            let s = finishing ? f : 0
            let levels = DepthSettings(startDepth: 0, cutDepth: d, passDepth: passDepth)
                .passLevels(toolStepdown: tool.cutting.stepdown).map { -$0 }
            var taken = 0.0
            var laps: [Double] = []
            for level in levels {
                let now = area(level, s)
                laps.append(max(0, now - taken))
                taken = now
            }
            plan.passes.append(.init(standoff: s, depths: levels, band: reach - s, laps: laps, isFinish: false))
            if finishing {
                plan.passes.append(.init(standoff: 0, depths: [d], band: s, laps: [max(0, area(d, 0) - taken)], isFinish: true))
            }
        }
        return plan
    }
}

// MARK: The toolpath

/// Edge profiles (`EdgeProfileParams`): a form bit cuts its profile into the top edge of the parts, round their
/// outside, their holes or both.
///
/// The closed shapes are built into parts (shapes inside shapes are holes) and offset outward together by each pass's
/// distance from the edge, the bit's radius at its tip (its pilot) plus the offset and the pass's standoff, with round
/// joins: so round the outside of a corner the bit rolls round it as a bearing would, and the parts' outlines and holes
/// get their passes from one offset, which never runs one part's pass into another's. Each loop of an offset belongs
/// to the drawn edge nearest it. An inside corner sharper than that distance can't be followed, so the bit leaves its
/// own shape there, and Checks notes it. A hole the final pass doesn't fit in is skipped.
///
/// Edges are cut one after another, nearest first, each from the outside in: its first pass enters as set (a ramp down
/// the lead-in and along the wall, or a plunge in the waste) and each later pass links to the next at depth through the
/// waste when the way is clear. Leads stay in the waste, as a profile's do. Vertical passes step down at the finishing
/// pass's standoff, linking back to the lead's start between laps as a profile does.
enum EdgeProfileGenerator {
    static func generate(op: CAMOperation, params: EdgeProfileParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        var notes: [String] = []
        let bitName = tool.name.isEmpty ? "T\(tool.number)" : "'\(tool.name)'"
        func empty() -> Toolpath {
            ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
                .build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        let plan = params.plan(tool: tool, thickness: context.stock.thickness)
        if plan.passes.isEmpty {
            warnings.append("Stood \(context.length(params.offset)) off the edge, \(bitName) doesn't reach it at "
                + "\(context.length(plan.depth)) deep: there's no profile to cut. Make the offset smaller or the profile deeper.")
            return empty()
        }
        let polys = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
        let closed = polys.filter { $0.isClosed && $0.count >= 3 }
        let open = polys.filter { !$0.isClosed && $0.count >= 2 }.count
        if open > 0 {
            warnings.append("\(open == 1 ? "1 open vector was" : "\(open) open vectors were") skipped: an edge profile follows the "
                + "edges of closed shapes.")
        }
        let regions = Region.build(from: closed, fill: .evenOdd)
        guard !regions.isEmpty else {
            if open == 0 { warnings.append("No closed shapes to profile.") }
            return empty()
        }

        // The drawn edges: each region's outline and its holes.
        struct DrawnEdge { var loop: Polyline; var isHole: Bool }
        var drawn: [DrawnEdge] = []
        for region in regions {
            drawn.append(DrawnEdge(loop: region.outer, isHole: false))
            for hole in region.holes { drawn.append(DrawnEdge(loop: hole, isHole: true)) }
        }
        let drawnLoops = regions.flatMap(\.loops)
        let walls = drawnLoops

        let c = plan.centreOffset
        let depth = plan.depth
        // The bit's widest where it meets the material top: what must stay clear of clamps and other parts.
        let topRadius = max(tool.radius(atHeight: depth), c)
        let wasteOnLeft = params.direction == .climb
        // Offset loops have the grown part on their left; climb keeps the finished edge on the tool's right.
        let reverse = params.direction == .climb

        // The parts other toolpaths cut nearby, less what this one cuts away itself, for the leads to keep clear of.
        var others: [ProtectedRegions.Zone] = []
        if let parts = context.protectedRegions, params.leads != nil {
            let lead = params.leads.map { 2 * $0.size } ?? 0
            let reach = regions.reduce(Rect2.empty) { $0.union($1.bounds) }.insetBy(-(c + plan.reach + 2 * topRadius + lead + 1))
            let cut = ProtectedRegions.profileCut(regions, side: .outside, allowance: 0, toolRadius: topRadius,
                                                  arcTolerance: context.arcTolerance)
            others = parts.zones(toolRadius: topRadius, cut: cut, walls: walls, near: reach, arcTolerance: context.arcTolerance)
        }

        // Each pass's tool-centre loops, sorted onto the drawn edge nearest them.
        var loops = [[[Polyline]]](repeating: [[Polyline]](repeating: [], count: plan.passes.count), count: drawn.count)
        var clearances: [ToolCentreClearance] = []
        for (k, pass) in plan.passes.enumerated() {
            let offsetRegions = Region.build(from: Clipper.offset(drawnLoops, delta: c + pass.standoff, arcTolerance: context.arcTolerance),
                                             fill: .nonZero)
            clearances.append(ToolCentreClearance(regions: offsetRegions, inside: false, stock: context.stock, toolRadius: topRadius,
                                                  keepOuts: context.keepOuts, others: others, materialTop: context.materialTop,
                                                  topLimit: 0))
            for loop in offsetRegions.flatMap(\.loops) {
                // A few points round the loop, so one that passes near another edge is still put with its own.
                let n = loop.count
                let probes = [0, n / 3, 2 * n / 3].map { loop.points[$0] }
                var nearest = 0, best = Double.infinity
                for (i, e) in drawn.enumerated() {
                    let d = probes.reduce(0) { $0 + e.loop.closestPoint(to: $1).distance }
                    if d < best { best = d; nearest = i }
                }
                loops[nearest][k].append(reverse ? loop.reversed : loop)
            }
        }

        // The edges asked for, and the holes the bit can't ride.
        let final = plan.passes.count - 1
        var tooSmall = 0, narrow = 0
        var chosen: [Int] = []
        for (i, e) in drawn.enumerated() {
            guard e.isHole ? params.edges.includesHoles : params.edges.includesOutside else { continue }
            if loops[i][final].isEmpty {
                if e.isHole { tooSmall += 1 }
                continue
            }
            if e.isHole, loops[i].contains(where: \.isEmpty) { narrow += 1 }
            chosen.append(i)
        }
        if tooSmall > 0 {
            warnings.append("\(tooSmall == 1 ? "1 hole is" : "\(tooSmall) holes are") too small for \(bitName) to ride "
                + "\(tooSmall == 1 ? "its edge" : "their edges"): its pilot\(params.offset > 1e-9 ? ", stood off the edge," : "") needs a "
                + "hole more than \(context.length(2 * c)) across. \(tooSmall == 1 ? "It was" : "They were") skipped.")
        }
        if narrow > 0 {
            warnings.append("\(narrow == 1 ? "1 hole is" : "\(narrow) holes are") too narrow for the first passes, so the first pass "
                + "that fits takes their bands too: a heavier cut.")
        }
        guard !chosen.isEmpty else {
            if tooSmall == 0 {
                warnings.append(params.edges == .holes ? "The shapes have no holes to profile." : "No edges to profile.")
            }
            return empty()
        }

        // Inside corners the bit can't follow.
        let design = CornerRelief.Design(drawnLoops)
        var sharp = 0
        for i in chosen {
            for loop in loops[i][final] {
                sharp += CornerRelief.corners(loop, wasteOnLeft: wasteOnLeft, design: design, offset: c, maxCornerAngle: 179).count
            }
        }
        if sharp > 0 {
            let top = tool.radius(atHeight: depth)
            notes.append("\(sharp == 1 ? "1 inside corner is" : "\(sharp) inside corners are") sharper than \(bitName) can follow, "
                + "so the profile there takes the bit's own round: \(context.length(c)) at the bottom of the cut and "
                + "\(context.length(top)) at the top. Round \(sharp == 1 ? "the corner" : "the corners") to at least "
                + "\(context.length(c)) to carry the profile round \(sharp == 1 ? "it" : "them").")
        }

        // Order: nearest edge first, entered where its first pass is nearest the tool, then improved by local search.
        let cursor = context.stock.homePosition.xy
        func firstLoop(_ i: Int) -> Polyline { loops[i].first { !$0.isEmpty }![0] }
        var entries: [Vec2] = chosen.map { firstLoop($0).points[0] }
        var remaining = Array(chosen.indices)
        var probe = cursor
        while !remaining.isEmpty {
            var best = 0, bestD = Double.infinity, bestEntry = Vec2.zero
            for (k, j) in remaining.enumerated() {
                let p = firstLoop(chosen[j]).closestPoint(to: probe).point
                let d = p.distanceSquared(to: probe)
                if d < bestD { bestD = d; best = k; bestEntry = p }
            }
            let j = remaining.remove(at: best)
            entries[j] = bestEntry
            probe = bestEntry
        }
        let tour = TourOptimizer.order(count: chosen.count, from: cursor, start: { entries[$0] }, end: { entries[$0] })

        // How each lap is cut: the first pass of an edge enters as set; later ones arrive at depth (a plunge entry of no
        // length) or, when they can't link, enter as set again.
        let entryParams = ProfileParams(side: .outside, direction: params.direction, depth: DepthSettings(startDepth: 0, cutDepth: depth),
                                        tabs: TabSettings(enabled: false), entry: params.entry, leads: params.leads)
        let rampLength: Double? = params.entry.kind == .ramp && params.entry.rampLength > 0 ? params.entry.rampLength : nil
        var linkedParams = entryParams
        linkedParams.entry = EntrySettings(kind: .plunge, rampLength: 0)
        let linkLimit = max(3 * tool.diameter, 10)
        let plungeProbe = max(0.1, 0.9 * tool.radius(atHeight: 0))
        var plungesIntoMaterial = 0
        var unfitted = 0

        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: params.leads == nil ? entries[tour.first ?? 0] : nil)
        for j in tour {
            let i = chosen[j]
            var atDepth = false
            for (k, pass) in plan.passes.enumerated() {
                let levels = pass.depths.map { -$0 }
                var lapLoops = loops[i][k]
                while !lapLoops.isEmpty {
                    // The nearest loop of this pass next (one, almost always).
                    let here = b.position.xy
                    let n = lapLoops.indices.min { lapLoops[$0].closestPoint(to: here).distance < lapLoops[$1].closestPoint(to: here).distance }!
                    let loop = lapLoops.remove(at: n)
                    let clearance = clearances[k]
                    // A link at depth: from where the last lap ended, at its depth, straight to this one's start.
                    func canLink(to p: Vec2) -> Bool {
                        atDepth && abs(b.position.z - levels[0]) < 1e-6 && here.distance(to: p) <= linkLimit
                            && clearance.isClear(path: [here, p])
                    }
                    func intoMaterial(_ p: Vec2) -> Bool {
                        guard params.entry.kind == .plunge, let top = context.materialTop else { return false }
                        return top(p, plungeProbe) > levels[0] + 0.05
                    }
                    let tabs = { (l: Polyline) in TabPlan(length: l.length, params: entryParams, tool: tool, lastLevel: levels[levels.count - 1]) }
                    func fit(_ leads: LeadSettings, ramp: Double?) -> FittedLead? {
                        LeadPlanner.fit(loop, relieved: loop, near: here, settings: leads, wasteOnLeft: wasteOnLeft, clearance: clearance,
                                        rampLength: ramp, tabs: tabs, linkLimit: linkLimit, chordTolerance: context.arcTolerance)
                    }
                    // A lap that links arrives at depth, so its lead has no ramp (and its lap no overrun to recut one).
                    if let leads = params.leads, atDepth, let lead = fit(leads, ramp: nil), canLink(to: lead.start) {
                        b.feed(Vec3(lead.start, b.position.z))
                        ProfileGenerator.cutClosedWithLeads(lead, levels: levels, params: linkedParams, tool: tool, builder: &b,
                                                            warnings: &warnings)
                    } else if let leads = params.leads, let lead = fit(leads, ramp: rampLength) {
                        b.retract()
                        if intoMaterial(lead.start) { plungesIntoMaterial += 1 }
                        ProfileGenerator.cutClosedWithLeads(lead, levels: levels, params: entryParams, tool: tool, builder: &b,
                                                            warnings: &warnings)
                    } else {
                        if params.leads != nil { unfitted += 1 }
                        let start = loop.startingNearest(here)
                        if canLink(to: start.points[0]) {
                            b.feed(Vec3(start.points[0], b.position.z))
                            ProfileGenerator.cutClosed(start, levels: levels, params: linkedParams, tool: tool, builder: &b, warnings: &warnings)
                        } else {
                            b.retract()
                            if intoMaterial(start.points[0]) { plungesIntoMaterial += 1 }
                            ProfileGenerator.cutClosed(start, levels: levels, params: entryParams, tool: tool, builder: &b, warnings: &warnings)
                        }
                    }
                    atDepth = true
                }
            }
            b.retract()
        }
        if plungesIntoMaterial > 0 {
            warnings.append("\(bitName) plunges into uncut material at the start of \(plungesIntoMaterial == 1 ? "1 lap" : "\(plungesIntoMaterial) laps"). "
                + "Form bits cut poorly on a plunge: use a ramp entry, or clear the waste with an end mill first.")
        }
        if unfitted > 0 {
            warnings.append(unfitted == 1 ? "Leads didn't fit on 1 lap; it's entered without one."
                : "Leads didn't fit on \(unfitted) laps; they're entered without one.")
        }
        var toolpath = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        toolpath.notes = notes.isEmpty ? nil : notes
        return toolpath
    }
}
