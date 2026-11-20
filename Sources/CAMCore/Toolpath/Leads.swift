import Foundation

/// Where a profile's tool centre may go off the cut itself (leads and the links between passes): on the waste side of
/// the toolpath's loops, on the material, and clear of clamps.
struct ToolCentreClearance {
    let regions: [Region]
    let regionBounds: [Rect2]
    /// Inside cut: the tool centre must stay inside `regions`. Outside cut: outside them.
    let inside: Bool
    /// The material grown by the tool radius (what `CAMEngine.validate` allows).
    let area: Rect2
    let keepOuts: [(outline: Polyline, bounds: Rect2)]
    let toolRadius: Double
    /// Height the material may reach under a lead (design Z), and how to read it; nil when not checked.
    let materialTop: (@Sendable (Vec2, Double) -> Double)?
    let topLimit: Double
    /// Allowed slack on the boundary itself, mm.
    let tolerance = 0.01
    let spacing: Double

    init(regions: [Region], inside: Bool, stock: Stock, toolRadius: Double, keepOuts: [KeepOut],
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
    /// far end, where the bit plunges, isn't on the wall of a nearby corner, and it doesn't run along another wall.
    /// (Inside a small hole a lead naturally comes back toward the wall a little; a quarter allows that.)
    func keepsAway(_ lead: [Vec2], from p: Vec2, normal n: Vec2) -> Bool {
        for q in samples(lead) {
            let ideal = (q - p).dot(n)
            guard ideal > 2 * tolerance else { continue }
            if boundaryDistance(q, within: ideal) < 0.25 * ideal - tolerance { return false }
        }
        return true
    }

    /// Distance to the nearest tool-centre loop, if one is within `limit`.
    func boundaryDistance(_ p: Vec2, within limit: Double) -> Double {
        var nearest = Double.infinity
        for (i, region) in regions.enumerated() where regionBounds[i].contains(p, tolerance: limit) {
            for loop in region.loops { nearest = min(nearest, loop.closestPoint(to: p).distance) }
        }
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
        guard L > 1e-6, loop.count >= 2 else { return nil }
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

/// Where a closed profile loop's tabs go: evenly spaced, centred between the loop start and the next tab so the
/// entry isn't on a tab.
struct TabPlan {
    let intervals: [(Double, Double)]
    let length: Double
    /// Top of the tabs (design Z).
    let z: Double
    /// The loop was too short for its tabs (they're left off it).
    let tooShort: Bool

    init(length L: Double, params: ProfileParams, tool: Tool, lastLevel: Double) {
        var intervals: [(Double, Double)] = []
        var tooShort = false
        let tabZ = -params.depth.cutDepth + params.tabs.thickness
        if params.tabs.enabled, params.side != .on, params.tabs.count > 0, tabZ > lastLevel {
            let span = params.tabs.width + tool.diameter
            if span * Double(params.tabs.count) < L * 0.8 {
                for k in 0..<params.tabs.count {
                    let c = L * (Double(k) + 0.5) / Double(params.tabs.count)
                    intervals.append((c - span / 2, c + span / 2))
                }
            } else {
                tooShort = true
            }
        }
        self.intervals = intervals
        self.tooShort = tooShort
        length = L
        z = tabZ
    }

    /// Arc length where the first tab begins, nil without tabs.
    var firstStart: Double? { intervals.first?.0 }

    func contains(_ s: Double) -> Bool {
        guard !intervals.isEmpty else { return false }
        var d = s.truncatingRemainder(dividingBy: length)
        if d < 0 { d += length }
        return intervals.contains { d > $0.0 && d < $0.1 }
    }

    func breaks(_ s0: Double, _ s1: Double) -> [Double] {
        guard !intervals.isEmpty else { return [] }
        var out: [Double] = []
        var w = (s0 / length).rounded(.down) - 1
        while w * length <= s1 {
            for (a, c) in intervals { out.append(w * length + a); out.append(w * length + c) }
            w += 1
        }
        return out
    }

    func clamp(_ s: Double, _ zz: Double) -> Double { contains(s) && zz < z ? z : zz }
}
