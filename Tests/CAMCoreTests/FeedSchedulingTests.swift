import Foundation
import Testing
@testable import CAMCore

/// "Adjust feeds for load" (`FeedScheduler`): engagement from what's been cut, the feed rule, inside arcs, few F words,
/// and the estimate and posted file following the scheduled feeds.
struct FeedSchedulingTests {
    static let lib = ToolLibrary.starter
    /// The starter 1/4" upcut: 220 in/min at 13,000 RPM (0.0085 in a tooth), 40% stepover, 3/16" stepdown.
    static let endMill = lib.tool(number: 1)!
    static var feed: Double { endMill.cutting.feedRate }

    static func project(_ shapes: [DesignShape], _ ops: [CAMOperation], material: MaterialKind = .plywood) -> Project {
        Project(name: "Feeds", displayUnits: .inch,
                stock: Stock(width: 12.inch, height: 12.inch, thickness: 0.75.inch, materialKind: material),
                machine: .avidPRO6060, shapes: shapes, operations: ops)
    }

    /// A 4" square in the middle of the sheet.
    static let square = DesignShape(id: UUID(uuidString: "FEED0000-0000-4000-8000-000000000001")!,
                                    kind: .rectangle(width: 4.inch, height: 4.inch, cornerRadius: 0), position: Vec2(6.inch, 6.inch))

    /// The square pocketed 1/4" deep (two levels) with offset rings, cleared inside out.
    static func pocket(_ on: Bool?, tool: Tool = endMill) -> CAMOperation {
        CAMOperation(id: UUID(uuidString: "FEED0000-0000-4000-8000-000000000011")!, name: "Pocket",
                     kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))), shapeIDs: [square.id], tool: tool,
                     adjustFeedsForLoad: on)
    }

    /// Solid stock everywhere.
    static func solid(_ p: Vec2) -> Double? { 0 }

    // MARK: Engagement

    @Test func engagementOfASlotAndOfLightPasses() {
        let r = Self.endMill.radius
        var region = FeedScheduler.SweptRegion(toolRadius: r)
        func engagement(_ p: Vec2, z: Double = -3) -> FeedScheduler.Engagement {
            FeedScheduler.engagement(at: p, z: z, direction: Vec2(1, 0), region: region, material: Self.solid, floorZ: -20)
        }
        // In solid wood the whole leading half cuts: a full-width slot.
        #expect(engagement(.zero) == FeedScheduler.Engagement(left: 90, right: 90))
        // After a pass along y = 0, a pass `ae` to its left cuts only the strip beyond it: arccos(1 − 2·ae/D).
        region.addLine(Vec3(-50, 0, -3), Vec3(50, 0, -3), spacing: 0.8)
        for stepover in [0.1, 0.2, 0.4] {
            let e = engagement(Vec2(0, stepover * 2 * r))
            let exact = acos(1 - 2 * stepover) * 180 / .pi
            #expect(abs(e.left - exact) <= 5, "\(stepover): \(e.left)° for \(exact)°")
            #expect(e.right == 0)
        }
        // The pass cleared only down to its own depth: below it the slot is full width again, above it nothing's left.
        #expect(engagement(.zero, z: -6).total == 180)
        #expect(engagement(.zero, z: -2).total == 0)
        // Off the stock there's nothing to cut.
        let off = FeedScheduler.engagement(at: .zero, z: -3, direction: Vec2(0, 1), region: FeedScheduler.SweptRegion(toolRadius: r),
                                           material: { $0.x < 0 ? nil : 0 }, floorZ: -20)
        #expect(off == FeedScheduler.Engagement(left: 0, right: 90))
    }

    @Test func feedRuleHoldsTheChipAndSharesTheExtraLoad() {
        // Lighter than the usual cut, or the same: the programmed feed.
        #expect(FeedScheduler.loadShare(engagement: 40, usual: 60) == 1)
        #expect(FeedScheduler.loadShare(engagement: 60, usual: 60) == 1)
        // Below half width, the chip is held at the usual cut's: a slot after 10% passes runs at sin 36.9° = 0.6.
        let tenPercent = acos(0.8) * 180 / .pi
        #expect(abs(FeedScheduler.loadShare(engagement: 180, usual: tenPercent) - 0.6) < 1e-9)
        let held60 = 0.6 / sin(60 * Double.pi / 180)
        #expect(abs(FeedScheduler.loadShare(engagement: 60, usual: tenPercent) - held60) < 1e-9)
        // Past half width the chip stops growing but the force doesn't: a slot after half-width cuts runs at 1/√2.
        #expect(abs(FeedScheduler.loadShare(engagement: 180, usual: 90) - 0.5.squareRoot()) < 1e-9)
        #expect(abs(FeedScheduler.loadShare(engagement: 180, usual: 78.5) - 0.5.squareRoot()) < 1e-9)
        // The usual cut is itself a slot: nothing is harder.
        #expect(FeedScheduler.loadShare(engagement: 180, usual: 180) == 1)
        // Rounding: down to a level, or up to one within 10%.
        #expect(FeedScheduler.levels[FeedScheduler.level(0.707)] == 0.70)
        #expect(FeedScheduler.levels[FeedScheduler.level(0.78)] == 0.85)
        #expect(FeedScheduler.levels[FeedScheduler.level(0.78, tolerance: 0)] == 0.70)
        #expect(FeedScheduler.levels[FeedScheduler.level(0.707, floor: 0.72)] == 0.85)
        #expect(FeedScheduler.levels[FeedScheduler.level(0.01)] == 0.25)
    }

    // MARK: A square pocket

    @Test func squarePocketSlowsItsFirstPassAndItsCorners() throws {
        let off = CAMEngine.generate(Self.project([Self.square], [Self.pocket(nil)])).toolpaths[0]
        let job = CAMEngine.generate(Self.project([Self.square], [Self.pocket(true)]))
        #expect(!job.hasErrors)
        let tp = job.toolpaths[0]
        let lf = try #require(tp.loadFeeds)
        let f = Self.feed
        // The usual cut is a 40% stepover ring.
        let ring = acos(1 - 0.8) * 180 / .pi
        #expect(abs(lf.usualEngagement - ring) <= 5, "\(lf.usualEngagement)")
        #expect(lf.varies && abs(lf.lowest - 0.7 * f) < 1e-6)
        #expect(off.loadFeeds == nil)
        // Nothing runs faster than programmed, and the plunges keep their feed.
        #expect(tp.motions.allSatisfy { $0.feed <= f + 1e-9 || $0.kind == .dwell })
        // The first ring at each level, cut in solid wood after the plunge, is a full-width slot: 70%.
        var plunges = 0
        for (i, m) in tp.motions.enumerated() where m.kind == .feed && abs(m.feed - Self.endMill.cutting.plungeRate) < 1e-9 {
            plunges += 1
            #expect(abs(tp.motions[i + 1].feed - 0.7 * f) < 1e-6)
        }
        #expect(plunges == 2)
        // The wall ring (the last ring at each level) cuts its sides at the full feed and slows into each corner,
        // where it meets the material the ring inside left there.
        let c = Self.square.position, a = 2.inch - Self.endMill.radius
        let corners = [Vec2(c.x + a, c.y + a), Vec2(c.x - a, c.y + a), Vec2(c.x - a, c.y - a), Vec2(c.x + a, c.y - a)]
        let sides = [Vec2(c.x + a, c.y), Vec2(c.x, c.y + a), Vec2(c.x - a, c.y), Vec2(c.x, c.y - a)]
        // Collected first: #expect inside a motion closure crashes the compiler.
        var cornerShares: [Double] = [], sideShares: [Double] = []
        tp.forEachMotion { s, m in
            guard m.kind == .feed, s.z < -1, abs(s.z - m.end.z) < 1e-9 else { return }
            if corners.contains(where: { $0.isApprox(m.end.xy, tolerance: 1e-6) }) { cornerShares.append(m.feed / f) }
            for p in sides where Self.onSegment(p, s.xy, m.end.xy) { sideShares.append(m.feed / f) }
        }
        #expect(cornerShares.count == 8 && cornerShares.allSatisfy { $0 < 0.86 }, "\(cornerShares)")
        #expect(sideShares.count == 8 && sideShares.allSatisfy { abs($0 - 1) < 1e-9 }, "\(sideShares)")
        // The extra time is the slowed cuts' (the machine slows for the corners anyway).
        let eOff = try #require(CAMEngine.generate(Self.project([Self.square], [Self.pocket(nil)])).estimate)
        let eOn = try #require(job.estimate)
        #expect(eOn.feedSeconds > eOff.feedSeconds && eOn.feedSeconds < eOff.feedSeconds * 1.2)
    }

    static func onSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
        let ab = b - a
        let l2 = ab.lengthSquared
        guard l2 > 1e-12 else { return false }
        let t = (p - a).dot(ab) / l2
        return t > 1e-6 && t < 1 - 1e-6 && (a + ab * t).distance(to: p) < 1e-6
    }

    @Test func profileInSolidWoodKeepsItsFeed() throws {
        // A cut-out is a full-width slot all the way round, its usual cut: nothing is harder, and a slot round an arc
        // (its outside corners, a hole's circle) loads the bit as a straight one does.
        let hole = DesignShape(kind: .circle(radius: 0.375.inch), position: Vec2(3.inch, 3.inch))
        let rounded = DesignShape(kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.5.inch), position: Vec2(9.75.inch, 10.25.inch))
        func job(_ on: Bool?) -> JobResult {
            let outside = CAMOperation(name: "Out", kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 0.77.inch),
                                                                                 tabs: TabSettings(enabled: true), entry: EntrySettings(kind: .ramp))),
                                       shapeIDs: [Self.square.id, rounded.id], tool: Self.endMill, adjustFeedsForLoad: on)
            let inside = CAMOperation(name: "In", kind: .profile(ProfileParams(side: .inside, depth: DepthSettings(cutDepth: 0.77.inch))),
                                      shapeIDs: [hole.id], tool: Self.endMill, adjustFeedsForLoad: on)
            return CAMEngine.generate(Self.project([Self.square, rounded, hole], [inside, outside]))
        }
        let on = job(true), off = job(nil)
        for (a, b) in zip(on.toolpaths, off.toolpaths) {
            #expect(a.motions == b.motions)
            let lf = try #require(a.loadFeeds)
            #expect(lf.usualEngagement == 180 && !lf.varies)
        }
    }

    // MARK: Inside arcs

    @Test func insideArcFormula() {
        // F_centre = F·(R − r)/R, R = ρ + r the outer wall's radius.
        let r = 3.175
        #expect(abs(FeedScheduler.insideArcFactor(pathRadius: 9.525, toolRadius: r) - (12.7 - r) / 12.7) < 1e-12)
        #expect(abs(FeedScheduler.insideArcFactor(pathRadius: r, toolRadius: r) - 0.5) < 1e-12)
        #expect(abs(FeedScheduler.insideArcFactor(pathRadius: 1000, toolRadius: r) - 1000 / 1003.175) < 1e-12)
        #expect(FeedScheduler.insideArcFactor(pathRadius: 0, toolRadius: r) == 0)
    }

    /// One lap of a circle of tool-centre radius `rho` round (100, 100) at 3 mm deep, as two half arcs, after a plunge.
    static func lap(_ rho: Double, ccw: Bool) -> Toolpath {
        let c = Vec2(100, 100), f = Self.feed
        let start = Vec3(c.x + rho, c.y, -3)
        return Toolpath(id: UUID(), name: "Lap", tool: Self.endMill, spindleRPM: 13000, start: Vec3(start.x, start.y, 5), motions: [
            .feed(start, Self.endMill.cutting.plungeRate),
            Motion(kind: ccw ? .arcCCW : .arcCW, end: Vec3(c.x - rho, c.y, -3), center: c, feed: f),
            Motion(kind: ccw ? .arcCCW : .arcCW, end: start, center: c, feed: f),
        ])
    }

    @Test func insideArcsSlowTheCentreSoTheEdgeKeepsItsFeed() {
        let r = Self.endMill.radius, f = Self.feed, c = Vec2(100, 100)
        func arcFeeds(_ tp: Toolpath, material: @escaping (Vec2) -> Double?) -> [Double] {
            FeedScheduler.schedule(tp, material: material, floorZ: -20, chipFloor: nil, maxFeed: 10_000).motions
                .filter(\.kind.isArc).map(\.feed)
        }
        // Finishing the wall of a 1" hole whose core is gone, 0.5 mm left on it: material on the arcs' outside only.
        let wall = 0.5.inch
        let finishHole = arcFeeds(Self.lap(wall - r, ccw: true)) { $0.distance(to: c) > wall - 0.5 ? 0 : -10 }
        let factor = FeedScheduler.insideArcFactor(pathRadius: wall - r, toolRadius: r)
        #expect(abs(factor - 0.75) < 1e-12)
        let expected = FeedScheduler.levels[FeedScheduler.level(factor)] * f
        #expect(finishHole.count == 2)
        #expect(finishHole.allSatisfy { abs($0 - expected) < 1e-6 })
        #expect(expected <= factor * f * 1.1 && expected < f)
        // Climbing round the outside of a 1" boss: material only on the centre's side, an outside arc, left alone.
        let boss = arcFeeds(Self.lap(wall + r, ccw: false)) { $0.distance(to: c) < wall + 0.5 ? 0 : -10 }
        #expect(boss == [f, f])
        // A slot round the hole in solid wood: the thicker chip outside is matched by the thinner one inside.
        #expect(arcFeeds(Self.lap(wall - r, ccw: true), material: Self.solid) == [f, f])
        // Tighter than half the bit's radius: a corner, not an inside arc.
        let tight = 0.4 * r
        let corner = arcFeeds(Self.lap(tight, ccw: true)) { $0.distance(to: c) > tight + r - 0.5 ? 0 : -10 }
        #expect(corner == [f, f])
    }

    @Test func pocketRingsFollowTheirEngagementNotTheArcRule() throws {
        // A round pocket's rings are inside arcs all the way round; only their engagement slows them.
        let disc = DesignShape(kind: .circle(radius: 1.inch), position: Vec2(6.inch, 6.inch))
        let op = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.125.inch))), shapeIDs: [disc.id],
                              tool: Self.endMill, adjustFeedsForLoad: true)
        let tp = CAMEngine.generate(Self.project([disc], [op])).toolpaths[0]
        // The wall ring (radius 1" − r): the arc rule would give 0.875 → 85%; its engagement is the usual ring's.
        let wall = 1.inch - Self.endMill.radius
        let outer = tp.motions.enumerated().filter { i, m in
            m.kind.isArc && abs(m.center.distance(to: m.end.xy) - wall) < 0.01
        }
        #expect(!outer.isEmpty)
        #expect(outer.contains { abs($0.element.feed - Self.feed) < 1e-9 })
    }

    // MARK: Few F words

    /// Each stretch at one feed inside a run of cuts between plunges and rapids, in order.
    static func stretches(_ tp: Toolpath) -> [[(feed: Double, length: Double)]] {
        let f = tp.loadFeeds?.programmed ?? tp.tool.cutting.feedRate
        let scheduled = FeedScheduler.levels.map { $0 * f }
        var chains: [[(feed: Double, length: Double)]] = []
        var chain: [(feed: Double, length: Double)] = []
        tp.forEachMotion { s, m in
            let cuts = (m.kind == .feed || m.kind.isArc) && scheduled.contains { abs($0 - m.feed) < 1e-6 }
                && (m.kind.isArc || s.xy.distance(to: m.end.xy) > 1e-9 || m.end.z > s.z)
            guard cuts else {
                if !chain.isEmpty { chains.append(chain); chain = [] }
                return
            }
            if let last = chain.last, abs(last.feed - m.feed) < 1e-9 {
                chain[chain.count - 1].length += m.length(from: s)
            } else {
                chain.append((m.feed, m.length(from: s)))
            }
        }
        if !chain.isEmpty { chains.append(chain) }
        return chains
    }

    @Test func feedChangesAreFewAndFarApart() throws {
        let rounded = DesignShape(kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.5.inch), position: Vec2(6.inch, 6.inch))
        var rough = PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))
        rough.allowance = 0.02.inch
        let roughing = CAMOperation(name: "Rough", kind: .pocket(rough), shapeIDs: [rounded.id], tool: Self.endMill, adjustFeedsForLoad: true)
        let walls = CAMOperation(name: "Walls", kind: .profile(ProfileParams(side: .inside, depth: DepthSettings(cutDepth: 0.25.inch))),
                                 shapeIDs: [rounded.id], tool: Self.endMill, adjustFeedsForLoad: true)
        let jobs = [CAMEngine.generate(Self.project([Self.square], [Self.pocket(true)])),
                    CAMEngine.generate(Self.project([rounded], [roughing, walls]))]
        let minimum = FeedScheduler.minimumRun(Self.endMill)
        var anyChanges = false
        for tp in jobs.flatMap(\.toolpaths) {
            #expect(tp.loadFeeds?.varies == true, "\(tp.name)")
            for chain in Self.stretches(tp) {
                // Every stretch but a run's last is at least half a diameter long, so changes are bounded by length.
                for s in chain.dropLast() { #expect(s.length >= minimum - 1e-6, "\(tp.name): \(s.length) mm at \(s.feed)") }
                let length = chain.reduce(0) { $0 + $1.length }
                #expect(Double(chain.count - 1) <= length / minimum + 1e-9)
                anyChanges = anyChanges || chain.count > 1
            }
            // A handful of distinct feeds.
            let feeds = Set(tp.motions.filter { $0.kind == .feed || $0.kind.isArc }.map { ($0.feed * 1000).rounded() })
            #expect(feeds.count <= FeedScheduler.levels.count + 1)
        }
        #expect(anyChanges)
        // The walls slow into the rounded corners the roughing left 0.02" on (inside arcs: R = 1/2", r = 1/8").
        let finish = try #require(jobs[1].toolpaths.last)
        let arcs = finish.motions.filter(\.kind.isArc)
        #expect(!arcs.isEmpty && arcs.allSatisfy { $0.feed < Self.feed - 1e-6 })
    }

    @Test func runsAreNeverFasterThanNeededAndNeverShort() {
        // A pseudo-random chain: atoms needing any level, of any length.
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let minimum = 3.0
        for _ in 0..<20 {
            let atoms = (0..<400).map { _ -> FeedScheduler.Atom in
                let down = Int(next() * 4)
                return FeedScheduler.Atom(length: 0.1 + 2 * next(), down: down, up: min(3, down + (next() < 0.3 ? 1 : 0)))
            }
            let out = FeedScheduler.runs(atoms, minimum: minimum)
            // Never faster than an atom needs.
            #expect(zip(atoms, out).allSatisfy { $1 >= $0.down })
            // Stretches at least `minimum` long, but for the last.
            var stretch = 0.0
            for j in atoms.indices {
                stretch += atoms[j].length
                if j + 1 < atoms.count, out[j + 1] != out[j] {
                    #expect(stretch >= minimum - 1e-9)
                    stretch = 0
                }
            }
        }
        // A short speed-up between two slowdowns doesn't happen; a short slowdown runs on until it's long enough.
        let a = { (down: Int) in FeedScheduler.Atom(length: 1, down: down, up: down) }
        #expect(FeedScheduler.runs([a(2), a(2), a(2), a(0), a(2), a(2), a(2)], minimum: 3) == [2, 2, 2, 2, 2, 2, 2])
        #expect(FeedScheduler.runs([a(0), a(0), a(0), a(2), a(0), a(0), a(0), a(0), a(0)], minimum: 3) == [0, 0, 0, 2, 2, 2, 0, 0, 0])
        // A short last stretch faster than the one before runs at that one's.
        #expect(FeedScheduler.runs([a(0), a(0), a(0), a(2), a(2), a(2), a(0)], minimum: 3) == [0, 0, 0, 2, 2, 2, 2])
        // Neutral moves (a tab's step) take the feed around them.
        let step = FeedScheduler.Atom(length: 2, down: -1, up: -1)
        #expect(FeedScheduler.runs([step, a(1), a(1), a(1), step, a(1)], minimum: 3) == [1, 1, 1, 1, 1, 1])
    }

    @Test func arcsKeepOneFeedAndThePathStaysTheSame() throws {
        let rounded = DesignShape(kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.5.inch), position: Vec2(6.inch, 6.inch))
        let disc = DesignShape(kind: .circle(radius: 0.75.inch), position: Vec2(3.inch, 3.inch))
        func ops(_ on: Bool?) -> [CAMOperation] {
            [CAMOperation(id: UUID(uuidString: "FEED0000-0000-4000-8000-000000000021")!, name: "Pocket",
                          kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.3.inch))), shapeIDs: [rounded.id, disc.id],
                          tool: Self.endMill, adjustFeedsForLoad: on),
             CAMOperation(id: UUID(uuidString: "FEED0000-0000-4000-8000-000000000022")!, name: "Walls",
                          kind: .profile(ProfileParams(side: .inside, depth: DepthSettings(cutDepth: 0.3.inch))),
                          shapeIDs: [rounded.id, disc.id], tool: Self.endMill, adjustFeedsForLoad: on)]
        }
        let on = CAMEngine.generate(Self.project([rounded, disc], ops(true))).toolpaths
        let off = CAMEngine.generate(Self.project([rounded, disc], ops(nil))).toolpaths
        #expect(on.count == off.count)
        for (a, b) in zip(on, off) {
            // The arcs are the same arcs, each with one feed: F never changes inside one.
            let arcsOn = a.motions.filter(\.kind.isArc), arcsOff = b.motions.filter(\.kind.isArc)
            #expect(arcsOn.count == arcsOff.count && arcsOn.count > 0)
            for (x, y) in zip(arcsOn, arcsOff) {
                #expect(x.kind == y.kind && x.end == y.end && x.center == y.center)
            }
            // Lines are only split where their feed changes: joined back up, the path is the same.
            #expect(Self.path(a) == Self.path(b))
            #expect(a.motions.count >= b.motions.count)
        }
        #expect(on.contains { $0.loadFeeds?.varies == true })
    }

    /// The toolpath's moves with collinear lines joined and feeds dropped.
    static func path(_ tp: Toolpath) -> [String] {
        var out: [(kind: MotionKind, start: Vec3, end: Vec3, center: Vec2)] = []
        tp.forEachMotion { s, m in
            if m.kind == .feed, let last = out.last, last.kind == .feed {
                let d0 = last.end - last.start, d1 = m.end - s
                let cross = Vec3(d0.y * d1.z - d0.z * d1.y, d0.z * d1.x - d0.x * d1.z, d0.x * d1.y - d0.y * d1.x)
                let dot = d0.x * d1.x + d0.y * d1.y + d0.z * d1.z
                if cross.length <= 1e-9 * max(1, d0.length * d1.length), dot > 0 {
                    out[out.count - 1].end = m.end
                    return
                }
            }
            out.append((m.kind, s, m.end, m.center))
        }
        func r(_ v: Double) -> String { String(format: "%.6f", v) }
        return out.map { "\($0.kind) \(r($0.end.x)) \(r($0.end.y)) \(r($0.end.z)) \(r($0.center.x)) \(r($0.center.y))" }
    }

    // MARK: Time and the posted file

    @Test func estimateAndPostedFileFollowTheScheduledFeeds() throws {
        let p = Self.project([Self.square], [Self.pocket(true)])
        let on = CAMEngine.generate(p)
        let off = CAMEngine.generate(Self.project([Self.square], [Self.pocket(nil)]))
        let eOn = try #require(on.estimate), eOff = try #require(off.estimate)
        #expect(eOn.feedSeconds > eOff.feedSeconds)
        #expect(eOn.constantVelocity > eOff.constantVelocity)
        #expect(eOn.motionSeconds[0].count == on.toolpaths[0].motions.count)
        // The slowed moves take as long as their own feed says (at least).
        let tp = on.toolpaths[0]
        var position = tp.start
        for (i, m) in tp.motions.enumerated() {
            defer { position = m.end }
            guard m.kind == .feed || m.kind.isArc, m.feed < Self.feed - 1e-6 else { continue }
            #expect(eOn.motionSeconds[0][i] >= m.length(from: position) / m.feed * 60 - 1e-9)
        }
        // Read back from the posted file, the job takes the same time.
        let gcode = AvidMach4Post(project: p, date: GoldenPostTests.date).post(on.toolpaths)
        #expect(gcode.contains("F154.0") && gcode.contains("F220.0"))
        let read = try GCodeParser.parse(gcode, controller: .avidMach4).toolpaths(tools: [Self.endMill], stock: p.stock, fallback: Self.endMill)
        let eRead = CycleTimeEstimator.estimate(read, project: p)
        #expect(abs(eRead.feedSeconds - eOn.feedSeconds) <= 0.01 * eOn.feedSeconds, "\(eRead.feedSeconds) vs \(eOn.feedSeconds)")
        // And the export checks pass.
        let errors = GCodeCheck.lint(gcode, project: p, dialect: .avidMach4).filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test func setupSheetMarksFeedsThatVary() {
        let p = Self.goldenProject()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p), date: GoldenPostTests.date)
        // The well slows to 70% of 220 in/min; the cut-out (a slot all round) keeps its feed.
        #expect(html.contains("154–220 in/min *"))
        #expect(html.contains("Adjust feeds for load"))
        let plain = Self.project([Self.square], [Self.pocket(nil)])
        let plainSheet = SetupSheet.html(project: plain, job: CAMEngine.generate(plain), date: GoldenPostTests.date)
        #expect(!plainSheet.contains("Adjust feeds for load"))
    }

    // MARK: When it applies

    @Test func offOrUnsuitedLeavesTheFeedsAlone() throws {
        let off = CAMEngine.generate(Self.project([Self.square], [Self.pocket(nil)])).toolpaths
        #expect(CAMEngine.generate(Self.project([Self.square], [Self.pocket(false)])).toolpaths == off)
        // A V-bit's or a ball nose's engagement isn't in plan: no change.
        for n in [5, 7] {
            let tool = Self.lib.tool(number: n)!
            let a = CAMEngine.generate(Self.project([Self.square], [Self.pocket(true, tool: tool)])).toolpaths
            let b = CAMEngine.generate(Self.project([Self.square], [Self.pocket(nil, tool: tool)])).toolpaths
            #expect(a == b)
        }
        // Only profiles and pockets take it.
        var drill = CAMOperation(kind: .drill(DrillParams(depth: 0.25.inch, peckDepth: 0.1.inch)), shapeIDs: [Self.square.id], tool: Self.endMill)
        drill.adjustFeedsForLoad = true
        #expect(!drill.adjustsFeedsForLoad && Self.pocket(true).adjustsFeedsForLoad)
        // It doesn't raise the file format, and it round-trips.
        let p = Self.project([Self.square], [Self.pocket(true)])
        #expect(p.formatVersion == 1)
        #expect(try Project.decode(p.encoded()).operations[0].adjustFeedsForLoad == true)
        // An older project (no field) decodes with it off and encodes the same bytes.
        let old = Self.project([Self.square], [Self.pocket(nil)])
        #expect(!String(decoding: try old.encoded(), as: UTF8.self).contains("adjustFeedsForLoad"))
    }

    @Test func chartFloorHoldsTheChipInHardwood() throws {
        // The starter bit's 0.0085 in chip is near hardwood's 0.008 in floor: slowing to 70% would make it 0.0059 in,
        // which rubs and burns, so the feed stays and the job says why.
        let job = CAMEngine.generate(Self.project([Self.square], [Self.pocket(true)], material: .hardwood))
        let tp = job.toolpaths[0]
        let lf = try #require(tp.loadFeeds)
        #expect(!lf.varies)
        #expect(lf.held == 1 && lf.wanted == 0.7)
        let note = try #require(job.issues.first { $0.message.contains("Adjust feeds for load") })
        #expect(note.severity == .info && note.message.contains("hardwood") && note.message.contains("spindle speed"))
        // The floor is the chip-load check's: 10% under the chart's least, which the chip-load row shows (#68).
        #expect(note.message.contains("thinner than 0.0072 in, 10% under the chart's least (0.0080 in) for this bit in hardwood"),
                "\(note.message)")
        // In plywood the chip has room to thin: 70%, and no note.
        let ply = CAMEngine.generate(Self.project([Self.square], [Self.pocket(true)]))
        #expect(ply.toolpaths[0].loadFeeds?.lowest == 0.7 * Self.feed)
        #expect(!ply.issues.contains { $0.message.contains("Adjust feeds for load") })
    }

    @Test func wrappedRotaryKeepsItsFeedsAndSaysSo() throws {
        var p = RotaryWrapTests.job()
        let rect = DesignShape(kind: .rectangle(width: 40, height: 30, cornerRadius: 0), position: Vec2(150, RotaryWrapTests.middle))
        p.shapes = [rect]
        let op = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 2))), shapeIDs: [rect.id], tool: Self.endMill,
                              adjustFeedsForLoad: true)
        p.operations = [op]
        let on = CAMEngine.generate(p)
        var plain = p
        plain.operations[0].adjustFeedsForLoad = nil
        #expect(on.toolpaths == CAMEngine.generate(plain).toolpaths)
        let note = try #require(on.issues.first { $0.message.contains("inverse time") })
        #expect(note.severity == .info)
    }

    @Test func tiledJobsScheduleEachTile() throws {
        // A 12" × 96" board through the 5 × 5 ft machine, the pocket across a tile line.
        var p = Self.project([Self.square], [Self.pocket(true)])
        p.stock.height = 96.inch
        p.tiling = TilingSettings(enabled: true, mode: .feedThroughY)
        p.shapes[0].position.y = 48.inch
        let job = CAMEngine.generate(p)
        let tps = job.toolpaths.filter { $0.sourceOperationID == Self.pocket(true).id }
        #expect(!tps.isEmpty)
        #expect(tps.allSatisfy { $0.loadFeeds != nil })
        #expect(tps.contains { $0.loadFeeds?.varies == true })
    }

    // MARK: Golden

    /// A sign blank with feeds that follow the load: a recess roughed with 0.02" left on its rounded walls and the walls
    /// finished by a profile (which slows into the corners' inside arcs), a square well (slowed for its first ring and
    /// its corners) and the cut-out (a slot all round, so it keeps its feed). One 1/4" upcut, plywood, default PRO6060.
    static func goldenProject() -> Project {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "FEED0000-0000-4000-8000-%012d", 100 + n))! }
        let recess = DesignShape(id: id(1), name: "Recess", kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.5.inch),
                                 position: Vec2(3.5.inch, 3.5.inch))
        let well = DesignShape(id: id(2), name: "Well", kind: .rectangle(width: 1.5.inch, height: 1.5.inch, cornerRadius: 0),
                               position: Vec2(7.inch, 3.5.inch))
        let blank = DesignShape(id: id(3), name: "Blank", kind: .rectangle(width: 8.inch, height: 5.inch, cornerRadius: 0.25.inch),
                                position: Vec2(5.inch, 3.5.inch))
        var rough = PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))
        rough.allowance = 0.02.inch
        let ops = [
            CAMOperation(id: id(11), name: "Rough recess", kind: .pocket(rough), shapeIDs: [recess.id], tool: endMill, adjustFeedsForLoad: true),
            CAMOperation(id: id(12), name: "Finish recess walls", kind: .profile(ProfileParams(side: .inside, depth: DepthSettings(cutDepth: 0.25.inch))),
                         shapeIDs: [recess.id], tool: endMill, adjustFeedsForLoad: true),
            CAMOperation(id: id(13), name: "Well", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.375.inch))), shapeIDs: [well.id],
                         tool: endMill, adjustFeedsForLoad: true),
            CAMOperation(id: id(14), name: "Cut out", kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 0.77.inch),
                                                                                   tabs: TabSettings(enabled: true), entry: EntrySettings(kind: .ramp))),
                         shapeIDs: [blank.id], tool: endMill, adjustFeedsForLoad: true),
        ]
        return Project(name: "Feeds that follow the load", displayUnits: .inch,
                       stock: Stock(width: 10.inch, height: 7.inch, thickness: 0.75.inch, materialName: "Baltic birch plywood"),
                       machine: .avidPRO6060, shapes: [recess, well, blank], operations: ops,
                       notes: "Saved by the first build with Adjust feeds for load, as format 1.")
    }

    @Test func goldenWithFeedsThatFollowTheLoad() throws {
        let p = Self.goldenProject()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let varies = job.toolpaths.map { $0.loadFeeds?.varies == true }
        #expect(varies == [true, true, true, false])
        try GoldenPostTests.check(GoldenPostTests.post(p, job.toolpaths), golden: "load-feeds-inch")
    }

    /// The same project saved to a file: it stays format 1 and decodes with the option on.
    @Test func savedWithFeedsThatFollowTheLoadDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("load-feeds-v1", make: Self.goldenProject)
        #expect(p.formatVersion == 1)
        #expect(p.operations.allSatisfy { $0.adjustFeedsForLoad == true })
        #expect(p.operations == Self.goldenProject().operations)
        try GoldenPostTests.check(GoldenPostTests.post(p), golden: "load-feeds-inch")
    }
}
