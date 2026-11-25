import Foundation

/// Where a profile's tool centre may go off the cut itself (leads and the links between passes): on the waste side of
/// the toolpath's loops, on the material, clear of clamps, and clear of the parts other toolpaths cut.
struct ToolCentreClearance {
    let regions: [Region]
    let regionBounds: [Rect2]
    /// Inside cut: the tool centre must stay inside `regions`. Outside cut: outside them.
    let inside: Bool
    /// The material grown by the tool radius (what `CAMEngine.validate` allows).
    let area: Rect2
    let keepOuts: [(outline: Polyline, bounds: Rect2)]
    /// Where the tool centre would cut into another toolpath's part (see `ProtectedRegions`).
    let others: [ProtectedRegions.Zone]
    let toolRadius: Double
    /// Height the material may reach under a lead (design Z), and how to read it; nil when not checked.
    let materialTop: (@Sendable (Vec2, Double) -> Double)?
    let topLimit: Double
    /// Allowed slack on the boundary itself, mm.
    let tolerance = 0.01
    let spacing: Double

    init(regions: [Region], inside: Bool, stock: Stock, toolRadius: Double, keepOuts: [KeepOut], others: [ProtectedRegions.Zone] = [],
         materialTop: (@Sendable (Vec2, Double) -> Double)?, topLimit: Double) {
        self.regions = regions
        regionBounds = regions.map { $0.bounds.insetBy(-0.02) }
        self.inside = inside
        // A wrapped sheet's Y goes round the blank: only its ends along X bound the tool.
        area = stock.rotary?.isWrapped == true
            ? Rect2(x: -toolRadius, y: -1e9, width: stock.width + 2 * toolRadius, height: 2e9)
            : stock.bounds.insetBy(-toolRadius)
        self.keepOuts = keepOuts.filter { $0.outline.isClosed && $0.outline.count >= 3 }
            .map { ($0.outline, $0.outline.bounds.insetBy(-toolRadius - 0.1)) }
        self.others = others
        self.toolRadius = toolRadius
        self.materialTop = materialTop
        self.topLimit = topLimit
        spacing = max(0.02, min(0.25, toolRadius / 4))
    }

    func isClear(_ p: Vec2) -> Bool {
        guard area.contains(p, tolerance: 1e-6) else { return false }
        for k in keepOuts where k.bounds.contains(p) {
            if k.outline.contains(p) || k.outline.closestPoint(to: p).distance < toolRadius + 0.05 { return false }
        }
        for zone in others where zone.contains(p) { return false }
        var inRegion = false
        for (i, region) in regions.enumerated() where regionBounds[i].contains(p) && region.contains(p) {
            inRegion = true
            break
        }
        if inRegion != inside {
            // On the wrong side: fine only right on the boundary (where a lead meets the loop).
            var nearest = Double.infinity
            for (i, region) in regions.enumerated() where regionBounds[i].contains(p, tolerance: tolerance) {
                for loop in region.loops { nearest = min(nearest, loop.closestPoint(to: p).distance) }
            }
            if nearest > tolerance { return false }
        }
        // Only the inner half of the footprint counts (as for the rest-aware start): the edge of a lead near the
        // loop runs along the finished wall, which is material that stays.
        if let top = materialTop, top(p, toolRadius * 0.5) > topLimit + 0.05 { return false }
        return true
    }

    /// Every point along an open path, at most `spacing` apart.
    func isClear(path: [Vec2]) -> Bool {
        samples(path).allSatisfy(isClear)
    }

    /// Whether a lead keeps at least a quarter of the distance from the cut it would have off a straight edge: so its
    /// far end, where the bit plunges, isn't on the wall of a nearby corner or another toolpath's part, and it doesn't
    /// run along another wall. (Inside a small hole a lead naturally comes back toward the wall a little; a quarter
    /// allows that.)
    func keepsAway(_ lead: [Vec2], from p: Vec2, normal n: Vec2) -> Bool {
        for q in samples(lead) {
            let ideal = (q - p).dot(n)
            guard ideal > 2 * tolerance else { continue }
            if boundaryDistance(q, within: ideal) < 0.25 * ideal - tolerance { return false }
        }
        return true
    }

    /// Distance to the nearest tool-centre loop, or the edge of another toolpath's part's zone (as near as the tool
    /// centre may come to it), if one is within `limit`.
    func boundaryDistance(_ p: Vec2, within limit: Double) -> Double {
        var nearest = Double.infinity
        for (i, region) in regions.enumerated() where regionBounds[i].contains(p, tolerance: limit) {
            for loop in region.loops { nearest = min(nearest, loop.closestPoint(to: p).distance) }
        }
        for zone in others { nearest = min(nearest, zone.distance(p, within: limit)) }
        return nearest
    }

    func samples(_ path: [Vec2]) -> [Vec2] {
        guard let first = path.first else { return [] }
        var out = [first]
        for (a, b) in zip(path, path.dropFirst()) {
            let n = max(1, Int((a.distance(to: b) / spacing).rounded(.up)))
            for k in 1...n { out.append(a.lerp(to: b, Double(k) / Double(n))) }
        }
        return out
    }
}

/// A lead-in and lead-out fitted to one closed loop of a profile.
struct FittedLead {
    /// The loop as cut: starting where the lead-in meets it, reliefs included.
    var loop: Polyline
    /// Lead-in from its start A to the loop start P.
    var leadIn: [Vec2]
    /// Lead-out from Q (where the last lap ends) to its end B; just [Q] without a lead-out.
    var leadOut: [Vec2]
    /// Arc length along `loop` where the ramp reaches full depth (0 without a ramp or when it all fits on the lead).
    var rampWall: Double
    /// Arc length along `loop` of Q.
    var exit: Double
    /// The straight link from the lead-out's end back to A is clear, so passes link at depth.
    var linkAtDepth: Bool

    var start: Vec2 { leadIn[0] }
    var leadInLength: Double { zip(leadIn, leadIn.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
}

/// How a profile with leads comes back onto its wall, and leaves it, where a tile line breaks the cut (see
/// `TileSplitter.assemble`): its own lead, on the waste side and clear of other parts as the profile's leads are.
struct BreakLeads {
    var settings: LeadSettings
    var wasteOnLeft: Bool
    var clearance: ToolCentreClearance
    var chordTolerance: Double

    /// A lead-in that reaches the cut at `p` going along `tangent` (or, `out`, a lead-out leaving it there), with every
    /// point inside `bounds` (the tile's reach) and clear; smaller ones are tried as `LeadPlanner.fit` does. nil when
    /// none fits.
    func lead(at p: Vec2, tangent t: Vec2, out: Bool, within bounds: Rect2) -> [Vec2]? {
        guard settings.size > 1e-6 else { return nil }
        let minSize = max(0.5, clearance.toolRadius / 4)
        var sizes: [Double] = [settings.size]
        while let last = sizes.last, last / 2 >= minSize - 1e-9, sizes.count < 4 { sizes.append(last / 2) }
        let normal = wasteOnLeft ? t.perpLeft : t.perpRight
        for size in sizes {
            var s = settings
            if s.kind == .arc { s.radius = size } else { s.length = size }
            guard let points = LeadPlanner.leadPoints(at: p, tangent: t, settings: s, wasteOnLeft: wasteOnLeft, out: out,
                                                      chordTolerance: chordTolerance) else { continue }
            if points.allSatisfy({ bounds.contains($0) }), clearance.isClear(path: points),
               clearance.keepsAway(points, from: p, normal: normal) {
                return points
            }
        }
        return nil
    }
}

enum LeadPlanner {
    /// Fits leads to a loop, entering as close to `near` as possible. `loop` is the tool-centre loop as cut (without
    /// reliefs); `relieved` is the same loop with any corner reliefs added, which is what gets cut. Tries entry points
    /// by distance from `near`, then smaller leads, down to max(0.5 mm, r/4). Nil when no lead fits.
    static func fit(_ loop: Polyline, relieved: Polyline, near: Vec2, settings: LeadSettings, wasteOnLeft: Bool,
                    clearance: ToolCentreClearance, rampLength: Double?, tabs: (Polyline) -> TabPlan,
                    linkLimit: Double, chordTolerance: Double) -> FittedLead? {
        guard loop.isClosed, loop.count >= 3, settings.size > 1e-6 else { return nil }
        let minSize = max(0.5, clearance.toolRadius / 4)
        var sizes: [Double] = [settings.size]
        while let last = sizes.last, last / 2 >= minSize - 1e-9, sizes.count < 4 { sizes.append(last / 2) }
        let candidates = entryCandidates(loop, near: near, spacing: max(1, settings.size))
        for size in sizes {
            var s = settings
            if s.kind == .arc { s.radius = size } else { s.length = size }
            for p in candidates {
                let cut = relieved.startingNearest(p)
                if let lead = build(cut, settings: s, wasteOnLeft: wasteOnLeft, clearance: clearance, rampLength: rampLength,
                                    tabs: tabs(cut), linkLimit: linkLimit, chordTolerance: chordTolerance) {
                    return lead
                }
            }
        }
        return nil
    }

    /// Entry points to try, nearest `near` first: the nearest point on the loop, then points about `spacing` apart
    /// along it both ways (at most 64), avoiding sharp vertices where the cut's direction isn't defined.
    static func entryCandidates(_ loop: Polyline, near: Vec2, spacing: Double) -> [Vec2] {
        let walker = LoopWalker(loop)
        let L = walker.length
        guard L > 1e-9 else { return [] }
        let c = loop.closestPoint(to: near)
        let s0 = walker.cumulative[c.segment] + loop.points[c.segment].distance(to: c.point)
        let step = max(spacing, L / 64)
        var params: [Double] = [s0]
        var k = 1.0
        while Double(params.count) < 64, k * step < L / 2 + 1e-9 {
            params.append(s0 + k * step)
            params.append(s0 - k * step)
            k += 1
        }
        // Sharp vertices (turning more than 10°): a lead there would meet the cut at the wrong angle.
        let pts = loop.points, n = pts.count
        var sharp: [Vec2] = []
        for i in 0..<n {
            let din = (pts[i] - pts[(i + n - 1) % n]).normalized, dout = (pts[(i + 1) % n] - pts[i]).normalized
            if abs(atan2(din.cross(dout), din.dot(dout))) > 10 * .pi / 180 { sharp.append(pts[i]) }
        }
        let points = params.map { walker.point(at: $0) }
        let smooth = points.filter { p in !sharp.contains { $0.distance(to: p) < 0.05 } }
        return smooth.isEmpty ? points : smooth + points.filter { p in sharp.contains { $0.distance(to: p) < 0.05 } }
    }

    /// The leads for a loop that starts at its entry point, or nil when either doesn't fit.
    static func build(_ loop: Polyline, settings: LeadSettings, wasteOnLeft: Bool, clearance: ToolCentreClearance,
                      rampLength: Double?, tabs: TabPlan, linkLimit: Double, chordTolerance: Double) -> FittedLead? {
        let walker = LoopWalker(loop)
        let L = walker.length
        // Never on a tab (a tab placed by hand can be anywhere round the loop).
        guard L > 1e-6, loop.count >= 2, !tabs.contains(0) else { return nil }
        let p = loop.points[0]
        let tIn = (loop.points[1] - p).normalized
        guard let leadIn = leadPoints(at: p, tangent: tIn, settings: settings, wasteOnLeft: wasteOnLeft, out: false,
                                      chordTolerance: chordTolerance),
              clearance.isClear(path: leadIn),
              clearance.keepsAway(leadIn, from: p, normal: wasteOnLeft ? tIn.perpLeft : tIn.perpRight) else { return nil }
        let leadInLength = zip(leadIn, leadIn.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        // The ramp runs along the lead-in, then on along the wall; the full lap at depth ends past its end.
        var rampWall = 0.0
        if let ramp = rampLength {
            let total = min(ramp, leadInLength + L * 0.98)
            rampWall = max(0, total - leadInLength)
        }
        // Keep the exit clear of the first tab (a lead-out from a tab would have to step down on the wall).
        let exitLimit = tabs.firstStart.map { max(0, $0 - 0.5) } ?? L * 0.98
        rampWall = min(rampWall, exitLimit)
        let exit = min(rampWall + max(0, settings.overlap), max(rampWall, exitLimit))
        let q = walker.point(at: exit)
        var leadOut = [q]
        if settings.leadOut {
            let tOut = tangent(walker, loop, arrivingAt: exit)
            guard let out = leadPoints(at: q, tangent: tOut, settings: settings, wasteOnLeft: wasteOnLeft, out: true,
                                       chordTolerance: chordTolerance),
                  clearance.isClear(path: out),
                  clearance.keepsAway(out, from: q, normal: wasteOnLeft ? tOut.perpLeft : tOut.perpRight) else { return nil }
            leadOut = out
        }
        let b = leadOut[leadOut.count - 1], a = leadIn[0]
        // With a ramp the exit is a ramp's length along from the entry, and linking back beats lifting and ramping
        // down from higher up, so the link may be that much longer.
        let limit = rampLength.map { max(linkLimit, $0 + 4 * settings.size) } ?? linkLimit
        let linkAtDepth = b.distance(to: a) <= limit && clearance.isClear(path: [b, a])
        return FittedLead(loop: loop, leadIn: leadIn, leadOut: leadOut, rampWall: rampWall, exit: exit, linkAtDepth: linkAtDepth)
    }

    /// Direction of travel arriving at arc length `s` (the segment that ends at or contains it).
    static func tangent(_ walker: LoopWalker, _ loop: Polyline, arrivingAt s: Double) -> Vec2 {
        let n = loop.count
        let L = walker.length
        var d = s.truncatingRemainder(dividingBy: L)
        if d < 0 { d += L }
        if d < 1e-9 { d = L }
        var i = 0
        while i < n - 1, walker.cumulative[i + 1] < d - 1e-9 { i += 1 }
        let a = loop.points[i], b = loop.points[(i + 1) % n]
        return (b - a).normalized
    }

    /// Lead points from its start to P (lead-in), or from P to its end (lead-out), on the waste side.
    static func leadPoints(at p: Vec2, tangent t: Vec2, settings: LeadSettings, wasteOnLeft: Bool, out: Bool,
                           chordTolerance: Double) -> [Vec2]? {
        guard t.length > 0.5 else { return nil }
        let n = wasteOnLeft ? t.perpLeft : t.perpRight
        switch settings.kind {
        case .line:
            let a = min(90, max(10, settings.angle)) * .pi / 180
            let l = settings.length
            let end = p + t * (out ? l * cos(a) : -l * cos(a)) + n * (l * sin(a))
            return out ? [p, end] : [end, p]
        case .arc:
            let r = settings.radius
            let sweep = min(180, max(15, settings.sweep)) * .pi / 180
            let centre = p + n * r
            // Waste on the left: the circle is run counter-clockwise, like the cut through P.
            let sense: Double = wasteOnLeft ? 1 : -1
            let a0 = (p - centre).angle
            let step = 2 * acos(max(-1, min(1, 1 - chordTolerance / max(r, chordTolerance))))
            let k = max(2, Int((sweep / max(step, 1e-3)).rounded(.up)))
            var pts: [Vec2] = []
            pts.reserveCapacity(k + 1)
            for j in 0...k {
                let f = Double(j) / Double(k)
                let angle = out ? a0 + sense * sweep * f : a0 - sense * sweep * (1 - f)
                pts.append(centre + Vec2.fromAngle(angle, length: r))
            }
            if out { pts[0] = p } else { pts[k] = p }
            return pts
        }
    }
}

/// Where a closed profile loop's tabs go, and how high the tool lifts over each: arc-length spans along the loop as
/// cut, measured from its start.
///
/// Evenly spaced tabs are centred between the loop start and the next tab, so the entry is never on one. Tabs at fixed
/// places (placed by hand, or any other caller's, such as holding tabs on another toolpath) are given as absolute
/// centres along the loop (`init(centres:...)`): the same tabs land on the wall wherever the loop starts. Overlapping
/// tabs merge into one lift.
///
/// A rectangular tab lifts the tool to `z` across its span. A triangular one ramps up from `base` over the first part
/// of the span, runs flat at `z` across `flatFraction` of it (one bit diameter, so a flat bit leaves the wall the tab's
/// full thickness at its centre and its set length at its base), and ramps back down.
struct TabPlan {
    struct Tab {
        /// Arc length where it begins, in [0, length).
        var start: Double
        /// Arc length where it ends: after `start`, past `length` when it wraps over the loop's start.
        var end: Double
        var span: Double { end - start }
    }

    /// The tabs as given (not merged), in order of `start`.
    let tabs: [Tab]
    /// The stretches the tool is lifted over: the tabs merged where they overlap and split at the loop's start, none
    /// wrapping past its end, in order.
    let intervals: [(Double, Double)]
    let length: Double
    /// Top of the tabs (design Z).
    let z: Double
    /// Where a triangular tab's ramps start and end (design Z): the cut's bottom.
    let base: Double
    /// nil for rectangular tabs; for triangular ones the share of each tab's span that's flat at the top.
    let flatFraction: Double?
    /// The loop was too short for its tabs (they're left off it), or for one placed by hand (that one's left off).
    let tooShort: Bool

    /// Evenly spaced tabs, `params.tabs.count` of them, measured from the loop's start.
    init(length L: Double, params: ProfileParams, tool: Tool, lastLevel: Double) {
        var tabs: [Tab] = []
        var tooShort = false
        let tabZ = -params.depth.cutDepth + params.tabs.thickness
        if params.tabs.enabled, params.side != .on, params.tabs.count > 0, tabZ > lastLevel {
            let span = params.tabs.width + tool.diameter
            if span * Double(params.tabs.count) < L * 0.8 {
                for k in 0..<params.tabs.count {
                    let c = L * (Double(k) + 0.5) / Double(params.tabs.count)
                    tabs.append(Tab(start: c - span / 2, end: c + span / 2))
                }
            } else {
                tooShort = true
            }
        }
        self.init(tabs: tabs, length: L, z: tabZ, base: tabZ - params.tabs.thickness,
                  flatFraction: Self.flatFraction(params, tool: tool), tooShort: tooShort)
    }

    /// Tabs centred at these arc lengths along the loop as cut (measured from its start, any value: they wrap). A tab
    /// whose span (its length plus the bit's diameter) is more than 80% of the loop is left off, and `tooShort` says so.
    init(centres: [Double], length L: Double, params: ProfileParams, tool: Tool, lastLevel: Double) {
        var tabs: [Tab] = []
        var tooShort = false
        let tabZ = -params.depth.cutDepth + params.tabs.thickness
        if params.tabs.enabled, params.side != .on, tabZ > lastLevel, L > 1e-9 {
            let span = params.tabs.width + tool.diameter
            for c in centres {
                guard span < L * 0.8 else { tooShort = true; continue }
                var a = (c - span / 2).truncatingRemainder(dividingBy: L)
                if a < 0 { a += L }
                tabs.append(Tab(start: a, end: a + span))
            }
        }
        self.init(tabs: tabs, length: L, z: tabZ, base: tabZ - params.tabs.thickness,
                  flatFraction: Self.flatFraction(params, tool: tool), tooShort: tooShort)
    }

    /// A plan with these rectangular tabs: arc-length intervals along a loop `length` long, none wrapping past its end.
    init(intervals: [(Double, Double)], length: Double, z: Double, tooShort: Bool = false) {
        self.init(tabs: intervals.map { Tab(start: $0.0, end: $0.1) }, length: length, z: z, base: z, flatFraction: nil,
                  tooShort: tooShort)
    }

    init(tabs given: [Tab], length L: Double, z: Double, base: Double, flatFraction: Double?, tooShort: Bool) {
        let tabs = given.sorted { $0.start < $1.start }
        self.tabs = tabs
        length = L
        self.z = z
        self.base = base
        self.flatFraction = flatFraction
        self.tooShort = tooShort
        // Split at the loop's start, then merge what overlaps.
        var split: [(Double, Double)] = []
        for t in tabs {
            if t.end > L + 1e-9, t.start < L {
                split.append((t.start, L))
                split.append((0, t.end - L))
            } else {
                split.append((t.start, t.end))
            }
        }
        split.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for iv in split {
            if let last = merged.last, iv.0 < last.1 - 1e-9 {
                merged[merged.count - 1].1 = max(last.1, iv.1)
            } else {
                merged.append(iv)
            }
        }
        intervals = merged
    }

    /// For triangular tabs: the share of a tab's span that's flat at the top (one bit diameter of the tab length plus
    /// it). nil for rectangular tabs.
    static func flatFraction(_ params: ProfileParams, tool: Tool) -> Double? {
        guard params.tabs.shape == .triangular else { return nil }
        let span = params.tabs.width + tool.diameter
        return span > 1e-9 ? min(1, tool.diameter / span) : 1
    }

    /// The same tabs, not flagged as too short (a finishing pass's own, once the roughing has said so).
    var withoutTooShort: TabPlan {
        TabPlan(tabs: tabs, length: length, z: z, base: base, flatFraction: flatFraction, tooShort: false)
    }

    /// The tabs `plan` puts on `reference`, carried onto `loop`: another loop round the same wall (one offset from it,
    /// the same loop started somewhere else, run the other way or with corner reliefs added). Each tab's ends and
    /// middle are carried across to the nearest point on `loop`, so every loop round the wall lifts over the same
    /// stretch of it, with the same shape. A profile's finishing pass plans its tabs once on the finished wall and
    /// carries them onto each roughing loop with this.
    static func mapped(_ plan: TabPlan, from reference: Polyline, onto loop: Polyline) -> TabPlan {
        let target = LoopWalker(loop)
        let L = target.length
        guard !plan.tabs.isEmpty, L > 1e-9 else {
            return TabPlan(tabs: [], length: L, z: plan.z, base: plan.base, flatFraction: plan.flatFraction, tooShort: plan.tooShort)
        }
        let source = LoopWalker(reference)
        func along(_ p: Vec2) -> Double {
            let c = loop.closestPoint(to: p)
            var s = target.cumulative[c.segment] + loop.points[c.segment].distance(to: c.point)
            s = s.truncatingRemainder(dividingBy: L)
            return s < 0 ? s + L : s
        }
        /// Forward distance from `a` to `b` round the loop.
        func ahead(_ a: Double, _ b: Double) -> Double { let d = b - a; return d < 0 ? d + L : d }
        var out: [Tab] = []
        for t in plan.tabs {
            let p = along(source.point(at: t.start)), q = along(source.point(at: t.end))
            let m = along(source.point(at: (t.start + t.end) / 2))
            // The stretch from one end to the other that passes through the middle (either way round, as `loop` may run
            // the other way from `reference`).
            let (lo, hi) = ahead(p, m) <= ahead(p, q) ? (p, q) : (q, p)
            out.append(Tab(start: lo, end: lo <= hi ? hi : hi + L))
        }
        return TabPlan(tabs: out, length: L, z: plan.z, base: plan.base, flatFraction: plan.flatFraction, tooShort: plan.tooShort)
    }

    /// Arc length where the first tab begins, nil without tabs.
    var firstStart: Double? { intervals.first?.0 }

    /// Steepest a triangular tab's ramps climb, degrees from horizontal; nil for rectangular tabs or none.
    var rampAngle: Double? {
        guard let f = flatFraction, let t = tabs.first else { return nil }
        let ramp = t.span * (1 - f) / 2
        return atan2(z - base, max(ramp, 1e-9)) * 180 / .pi
    }

    /// Where `s` is on the loop, in [0, length).
    private func wrapped(_ s: Double) -> Double {
        var d = s.truncatingRemainder(dividingBy: length)
        if d < 0 { d += length }
        return d
    }

    func contains(_ s: Double) -> Bool {
        guard !intervals.isEmpty else { return false }
        let d = wrapped(s)
        return intervals.contains { d > $0.0 && d < $0.1 }
    }

    /// The lowest the tool may go at `s` (design Z), nil where there's no tab.
    func floor(at s: Double) -> Double? {
        guard !tabs.isEmpty else { return nil }
        guard let f = flatFraction else { return contains(s) ? z : nil }
        let d = wrapped(s)
        var best: Double?
        for t in tabs {
            for x in [d, d + length] where x > t.start && x < t.end {
                let ramp = t.span * (1 - f) / 2
                let u = min(x - t.start, t.end - x)
                let h = ramp > 1e-9 ? base + (z - base) * min(1, u / ramp) : z
                best = max(best ?? -.infinity, h)
            }
        }
        return best
    }

    /// Arc lengths between `s0` and `s1` (unwrapped) where the lift over a tab changes slope, for the walker to put a
    /// vertex on: each tab's ends, and for triangular tabs the top's ends and where each ramp crosses `level` (the
    /// pass's Z), so the chord between vertices follows the tab exactly.
    func breaks(_ s0: Double, _ s1: Double, level: Double? = nil) -> [Double] {
        guard !intervals.isEmpty else { return [] }
        var local: [Double] = []
        if let f = flatFraction {
            for t in tabs {
                let ramp = t.span * (1 - f) / 2
                local += [t.start, t.end, t.start + ramp, t.end - ramp]
                if let level, level > base + 1e-9, level < z - 1e-9, ramp > 1e-9 {
                    let along = ramp * (level - base) / (z - base)
                    local += [t.start + along, t.end - along]
                }
            }
        } else {
            for (a, c) in intervals { local += [a, c] }
        }
        var out: [Double] = []
        var w = (s0 / length).rounded(.down) - 1
        while w * length <= s1 {
            for x in local { out.append(w * length + x) }
            w += 1
        }
        return out
    }

    func clamp(_ s: Double, _ zz: Double) -> Double {
        guard let f = floor(at: s) else { return zz }
        return max(zz, f)
    }
}
