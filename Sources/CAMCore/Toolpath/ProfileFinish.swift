import Foundation

/// A profile's separate finishing pass (`ProfileFinishPass`): what's checked before it's cut, the kerf its leads stay
/// in, and how it's entered. `ProfileGenerator.generate` cuts the roughing loops `finish.allowance` further off the
/// wall, then a finishing lap per loop at the final wall, right after the roughing loops round it.
enum ProfileFinish {
    /// What becomes of a profile's finishing pass before anything is generated.
    enum Plan {
        /// No finishing pass (none set, or skipped with a warning).
        case none
        case active(ProfileFinishPass)
        /// The toolpath isn't cut at all: the finish would be dangerous as set.
        case refused
    }

    /// Checks a profile's finishing pass against its side, bit and job. `diameter` is the bit's cutting width at the
    /// wall (twice the profile's effective radius). Warnings and refusals go into `warnings`.
    static func plan(_ params: ProfileParams, tool: Tool, diameter: Double, context: GenerationContext,
                     warnings: inout [String]) -> Plan {
        guard let finish = params.finishPass else { return .none }
        let bitName = tool.name.isEmpty ? "T\(tool.number)" : "'\(tool.name)'"
        if params.side == .on {
            warnings.append("A finishing pass needs an inside or outside cut, with a wall to finish: it was skipped.")
            return .none
        }
        if tool.hasUndercut {
            warnings.append("\(bitName) is wider at its tip than above it, so it can't step out to a finishing pass without "
                + "cutting into the wall: the finishing pass was skipped.")
            return .none
        }
        if let project = context.project, TileLayout(project) != nil {
            warnings.append("Finishing passes aren't cut on tiled jobs yet: the finishing pass was skipped, so the wall is cut "
                + "to size by the roughing passes.")
            return .none
        }
        if finish.allowance < minimumAllowance {
            warnings.append("The finish allowance must be at least \(context.length(minimumAllowance)): the finishing pass was "
                + "skipped.")
            return .none
        }
        if finish.allowance > diameter / 2 + 1e-9 {
            warnings.append("Refused: the finish allowance (\(context.length(finish.allowance))) is more than half the width of "
                + "\(bitName) (\(context.length(diameter))), so the finishing pass would cut a full-depth slot. Nothing was cut. "
                + "Use a smaller finish allowance.")
            return .refused
        }
        if finish.depth == .fullDepth, tool.fluteLength > 0, params.depth.cutDepth > tool.fluteLength + 1e-6 {
            warnings.append("Refused: a full-depth finishing pass \(context.length(params.depth.cutDepth)) deep is deeper than "
                + "the flutes of \(bitName) (\(context.length(tool.fluteLength))), so the shank would rub the wall. Nothing was cut. "
                + "Set the finish depth to Each pass, or use a bit with longer flutes.")
            return .refused
        }
        if finish.allowance > diameter / 3 + 1e-9 {
            warnings.append("The finish allowance (\(context.length(finish.allowance))) is more than a third of the width of "
                + "\(bitName) (\(context.length(diameter))): the finishing pass takes a heavy cut at full depth and may deflect or "
                + "chatter. A finish of 0.02 in (0.5 mm) or so is usual.")
        }
        return .active(finish)
    }

    /// Below this a finishing lap can't be told from its roughing (mm).
    static let minimumAllowance = 0.05

    /// How far a finishing loop may be from the nearest roughing loop before the finish there would cut material the
    /// roughing never cleared: half the bit's width, the same limit as the finish allowance.
    static func farthestFromRoughing(_ loop: Polyline, rough: [Polyline]) -> Double {
        let walker = LoopWalker(loop)
        let L = walker.length
        guard L > 1e-9 else { return 0 }
        guard !rough.isEmpty else { return .infinity }
        let bounds = rough.map(\.bounds)
        let n = max(16, min(2000, Int(L / 0.25)))
        var worst = 0.0
        for k in 0..<n {
            let p = walker.point(at: L * Double(k) / Double(n))
            var nearest = Double.infinity
            for (i, r) in rough.enumerated() {
                if nearest.isFinite && !bounds[i].contains(p, tolerance: nearest) { continue }
                nearest = min(nearest, r.closestPoint(to: p).distance)
            }
            worst = max(worst, nearest)
        }
        return worst
    }

    /// The kerf the roughing cut round a finishing loop: where the finish's tool centre may be at depth off the loop
    /// itself. That's between the finishing loop and the roughing loop (closer to the waste and the bit would cut
    /// uncut material, closer to the part and it cuts the finished wall), and not over a tab.
    struct Kerf {
        /// The tool-centre regions of the finishing and roughing loops.
        let finish: [Region]
        let rough: [Region]
        /// Inside cut: the waste is inside the regions.
        let inside: Bool
        /// The finishing loop as planned and its tabs.
        let reference: Polyline
        let tabs: TabPlan
        let tolerance = 0.01
        let spacing: Double

        init(finish: [Region], rough: [Region], inside: Bool, reference: Polyline, tabs: TabPlan, toolRadius: Double) {
            self.finish = finish
            self.rough = rough
            self.inside = inside
            self.reference = reference
            self.tabs = tabs
            spacing = max(0.02, min(0.25, toolRadius / 4))
        }

        private func side(_ regions: [Region], _ p: Vec2) -> (inside: Bool, onBoundary: Bool) {
            let within = regions.contains { $0.bounds.contains(p, tolerance: tolerance) && $0.contains(p) }
            var nearest = Double.infinity
            for region in regions where region.bounds.contains(p, tolerance: tolerance) {
                for loop in region.loops { nearest = min(nearest, loop.closestPoint(to: p).distance) }
            }
            return (within, nearest <= tolerance)
        }

        /// Whether the arc length along the finishing loop nearest `p` is over a tab.
        func onTab(_ p: Vec2) -> Bool {
            guard !tabs.intervals.isEmpty else { return false }
            let walker = LoopWalker(reference)
            let c = reference.closestPoint(to: p)
            return tabs.contains(walker.cumulative[c.segment] + reference.points[c.segment].distance(to: c.point))
        }

        func isClear(_ p: Vec2) -> Bool {
            let f = side(finish, p), r = side(rough, p)
            // On the waste side of the finishing loop, and not past the roughing loop.
            let wasteOfFinish = (f.inside == inside) || f.onBoundary
            let partOfRough = (r.inside != inside) || r.onBoundary
            return wasteOfFinish && partOfRough && !onTab(p)
        }

        func isClear(path: [Vec2]) -> Bool {
            guard let first = path.first else { return true }
            if !isClear(first) { return false }
            for (a, b) in zip(path, path.dropFirst()) {
                let n = max(1, Int((a.distance(to: b) / spacing).rounded(.up)))
                for k in 1...n where !isClear(a.lerp(to: b, Double(k) / Double(n))) { return false }
            }
            return true
        }
    }

    /// The automatic lead a finishing lap enters on when the profile has none: a quarter arc the bit's width in radius,
    /// flattened to fit the kerf, leaving the same way, with a lap's overlap of the bit's radius.
    static func automaticLead(toolRadius r: Double) -> LeadSettings {
        LeadSettings(kind: .arc, radius: 2 * r, sweep: 90, leadOut: true, overlap: r)
    }

    /// `settings` at main size `size`, cut down so the lead stays within `band` of the loop it meets: an arc's sweep
    /// shortened (and below 15°, its radius), a line shortened.
    static func clipped(_ settings: LeadSettings, size: Double, band: Double) -> LeadSettings {
        var s = settings
        switch s.kind {
        case .arc:
            let minSweep = 15 * Double.pi / 180
            let r = max(size, 1e-6)
            let reach = band / r >= 1 ? Double.pi : acos(1 - band / r)
            if reach >= minSweep {
                s.radius = r
                s.sweep = min(min(180, max(15, settings.sweep)), reach * 180 / .pi)
            } else {
                s.radius = band / (1 - cos(minSweep))
                s.sweep = 15
            }
        case .line:
            let a = min(90, max(10, s.angle)) * .pi / 180
            s.length = min(size, band / sin(a))
        }
        return s
    }

    /// Leads for a finishing lap, kept in the roughing's kerf and off its tabs, entering as near the start of
    /// `reference` (the finishing loop, started between tabs) as fits. nil when none does.
    static func lead(_ reference: Polyline, tabs: TabPlan, settings: LeadSettings, kerf: Kerf, band: Double, wasteOnLeft: Bool,
                     toolRadius: Double, linkLimit: Double, chordTolerance: Double) -> FittedLead? {
        guard reference.isClosed, reference.count >= 3, settings.size > 1e-6 else { return nil }
        let minSize = max(0.5, toolRadius / 4)
        var sizes: [Double] = [settings.size]
        while let last = sizes.last, last / 2 >= minSize - 1e-9, sizes.count < 4 { sizes.append(last / 2) }
        let candidates = LeadPlanner.entryCandidates(reference, near: reference.points[0], spacing: max(1, settings.size))
            .filter { !kerf.onTab($0) }
        for size in sizes {
            let s = clipped(settings, size: size, band: band)
            for p in candidates {
                let cut = reference.startingNearest(p)
                let plan = TabPlan.mapped(tabs, from: reference, onto: cut)
                if let lead = build(cut, tabs: plan, settings: s, kerf: kerf, wasteOnLeft: wasteOnLeft, linkLimit: linkLimit,
                                    chordTolerance: chordTolerance) {
                    return lead
                }
            }
        }
        return nil
    }

    /// A finishing lap's leads on a loop that starts at its entry, or nil when either leaves the kerf.
    static func build(_ loop: Polyline, tabs: TabPlan, settings: LeadSettings, kerf: Kerf, wasteOnLeft: Bool, linkLimit: Double,
                      chordTolerance: Double) -> FittedLead? {
        let walker = LoopWalker(loop)
        let L = walker.length
        guard L > 1e-6, loop.count >= 2, !tabs.contains(0) else { return nil }
        let p = loop.points[0]
        let tIn = (loop.points[1] - p).normalized
        guard let leadIn = LeadPlanner.leadPoints(at: p, tangent: tIn, settings: settings, wasteOnLeft: wasteOnLeft, out: false,
                                                  chordTolerance: chordTolerance),
              kerf.isClear(path: leadIn) else { return nil }
        // The overlap ends clear of the first tab, as `LeadPlanner.build` keeps it.
        let exitLimit = tabs.firstStart.map { max(0, $0 - 0.5) } ?? L * 0.98
        let exit = min(max(0, settings.overlap), exitLimit)
        let q = walker.point(at: exit)
        var leadOut = [q]
        if settings.leadOut {
            let tOut = LeadPlanner.tangent(walker, loop, arrivingAt: exit)
            guard let out = LeadPlanner.leadPoints(at: q, tangent: tOut, settings: settings, wasteOnLeft: wasteOnLeft, out: true,
                                                   chordTolerance: chordTolerance),
                  kerf.isClear(path: out) else { return nil }
            leadOut = out
        }
        let b = leadOut[leadOut.count - 1], a = leadIn[0]
        let linkAtDepth = b.distance(to: a) <= linkLimit && kerf.isClear(path: [b, a])
        return FittedLead(loop: loop, leadIn: leadIn, leadOut: leadOut, rampWall: 0, exit: exit, linkAtDepth: linkAtDepth)
    }

    /// Whether a move lies along one of a toolpath's finishing loops (within `tolerance`), for "Adjust feeds for
    /// load" to leave alone.
    static func isOnFinishLoop(_ m: Motion, from s: Vec3, loops: [Polyline], tolerance: Double) -> Bool {
        guard m.kind == .feed || m.kind.isArc, s.xy.distance(to: m.end.xy) > 1e-6 else { return false }
        let probes = [s.xy, m.end.xy] + m.samples(from: s, maxStep: max(0.5, s.xy.distance(to: m.end.xy) / 4)).map(\.xy)
        return loops.contains { loop in
            loop.bounds.insetBy(-tolerance).contains(m.end.xy)
                && probes.allSatisfy { loop.closestPoint(to: $0).distance <= tolerance }
        }
    }

    /// The tolerance `isOnFinishLoop` uses for a finish allowance: well inside it, so a roughing lap isn't taken for
    /// the finish.
    static func loopTolerance(allowance: Double) -> Double { max(0.002, min(0.02, allowance / 4)) }
}
