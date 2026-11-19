import Foundation
import Testing
@testable import CAMCore

/// Helpers shared by the lead and corner relief tests.
enum CutFixture {
    static var r: Double { Fixture.endMill.radius }
    static let arc = LeadSettings(kind: .arc, radius: 6.35)
    static let line = LeadSettings(kind: .line, length: 6.35)

    static func profile(_ shapes: [DesignShape], side: CutSide = .outside, direction: CutDirection = .climb,
                        depth: DepthSettings = DepthSettings(cutDepth: 6, passDepth: 3), allowance: Double = 0,
                        tabs: TabSettings = TabSettings(), entry: EntrySettings = EntrySettings(),
                        leads: LeadSettings? = nil, relief: CornerReliefSettings? = nil) -> CAMOperation {
        CAMOperation(kind: .profile(ProfileParams(side: side, direction: direction, depth: depth, allowance: allowance, tabs: tabs,
                                                  entry: entry, leads: leads, cornerRelief: relief)),
                     shapeIDs: shapes.map(\.id), tool: Fixture.endMill)
    }

    static func pocket(_ shapes: [DesignShape], strategy: PocketStrategy = .offset, direction: CutDirection = .climb,
                       allowance: Double = 0, relief: CornerReliefSettings? = nil) -> CAMOperation {
        CAMOperation(kind: .pocket(PocketParams(strategy: strategy, direction: direction, depth: DepthSettings(cutDepth: 6, passDepth: 3),
                                                allowance: allowance, cornerRelief: relief)),
                     shapeIDs: shapes.map(\.id), tool: Fixture.endMill)
    }

    static func job(_ shapes: [DesignShape], _ ops: [CAMOperation], stock: Stock = Fixture.stock, arcs: Bool = false) -> (Project, JobResult) {
        var p = Fixture.project(shapes: shapes, ops: ops, stock: stock)
        p.machine.outputArcs = arcs
        return (p, CAMEngine.generate(p))
    }

    /// Straight-down feeds that end below the surface: (start, end).
    static func plunges(_ tp: Toolpath) -> [(Vec3, Vec3)] {
        var out: [(Vec3, Vec3)] = []
        tp.forEachMotion { s, m in
            if m.kind == .feed, m.end.z < s.z - 1e-6, m.end.z < -1e-6, s.xy.distance(to: m.end.xy) < 1e-6 { out.append((s, m.end)) }
        }
        return out
    }

    /// Distance from p to the outline of an axis-aligned rectangle.
    static func distanceToRect(_ p: Vec2, size: Vec2, at c: Vec2) -> Double {
        let hw = size.x / 2, hh = size.y / 2
        let outline = Polyline([c + Vec2(-hw, -hh), c + Vec2(hw, -hh), c + Vec2(hw, hh), c + Vec2(-hw, hh)], closed: true)
        return outline.closestPoint(to: p).distance
    }

    static func height(_ g: HeightGrid, _ p: Vec2) -> Double { Double(g.height(at: p) ?? 0) }

    /// Cell centres of a grid with their heights.
    static func cells(_ g: HeightGrid) -> [(Vec2, Double)] {
        var out: [(Vec2, Double)] = []
        out.reserveCapacity(g.rows * g.columns)
        for row in 0..<g.rows {
            for col in 0..<g.columns {
                out.append((Vec2(g.origin.x + Double(col) * g.cellSize, g.origin.y + Double(row) * g.cellSize),
                            Double(g.heights[g.index(col, row)])))
            }
        }
        return out
    }

    /// Spike tips: feed moves that turn straight back on themselves in XY.
    static func reversals(_ tp: Toolpath) -> Int {
        var count = 0
        var prev: Vec2?
        var prevPos = tp.start
        for m in tp.motions {
            defer { prevPos = m.end }
            guard m.kind == .feed else { prev = nil; continue }
            let d = m.end.xy - prevPos.xy
            guard d.length > 1e-6 else { continue }
            let dir = d.normalized
            if let p = prev, p.dot(dir) < -0.99 { count += 1 }
            prev = dir
        }
        return count
    }
}

struct LeadTests {
    let part = Fixture.rect(100, 60, at: Vec2(100, 75))

    @Test(arguments: [CutSide.outside, .inside], [CutFixture.arc, CutFixture.line])
    func plungesStayOffTheWallAndLeadsMeetItTangentially(side: CutSide, lead: LeadSettings) throws {
        let (_, job) = CutFixture.job([part], [CutFixture.profile([part], side: side, leads: lead)])
        let tp = try #require(job.toolpaths.first)
        #expect(!job.hasErrors)
        #expect(!tp.warnings.contains { $0.contains("Leads") }, "\(tp.warnings)")
        let r = CutFixture.r
        let size = Vec2(100, 60), c = Vec2(100, 75)
        let plunges = CutFixture.plunges(tp)
        #expect(!plunges.isEmpty)
        for (_, e) in plunges {
            #expect(CutFixture.distanceToRect(e.xy, size: size, at: c) > r + 0.5, "plunge at \(e) is on the wall (\(side))")
        }
        // The lead meets the cut where the tool first reaches the wall: no sharp turn there.
        var pts: [Vec2] = []
        tp.forEachMotion { _, m in if m.kind == .feed { pts.append(m.end.xy) } }
        let k = try #require(pts.indices.first { abs(CutFixture.distanceToRect(pts[$0], size: size, at: c) - r) < 0.01 })
        try #require(k > 0 && k + 1 < pts.count, "the first feed is already on the wall")
        let din = (pts[k] - pts[k - 1]).normalized, dout = (pts[k + 1] - pts[k]).normalized
        // Arcs: half a chord step of the lead plus half of the loop's (on a rounded corner); lines come in at 45°.
        let tolerance = lead.kind == .arc ? 7.0 : 46.0
        #expect(acos(min(1, din.dot(dout))) * 180 / .pi < tolerance, "lead meets the wall at an angle (\(side), \(lead.kind))")
    }

    @Test func climbAndConventionalLeadsCurlOppositeWays() throws {
        for (direction, expected) in [(CutDirection.climb, MotionKind.arcCCW), (.conventional, .arcCW)] {
            let (_, job) = CutFixture.job([part], [CutFixture.profile([part], direction: direction, leads: CutFixture.arc)], arcs: true)
            let tp = try #require(job.toolpaths.first)
            var leadArcs: [MotionKind] = []
            tp.forEachMotion { s, m in
                if m.kind.isArc, abs(s.xy.distance(to: m.center) - 6.35) < 0.05 { leadArcs.append(m.kind) }
            }
            #expect(!leadArcs.isEmpty, "\(direction)")
            #expect(leadArcs.allSatisfy { $0 == expected }, "\(direction): \(leadArcs)")
        }
    }

    @Test func passesPlungeOnlyAtTheLeadStartAndCutThrough() throws {
        let shape = Fixture.rect(180, 120, at: Vec2(100, 75))
        var stock = Fixture.stock
        stock.width = 220; stock.height = 160
        let op = CutFixture.profile([shape], depth: DepthSettings(cutDepth: 20.5, passDepth: 5), leads: CutFixture.arc)
        let (_, job) = CutFixture.job([shape], [op], stock: stock)
        let tp = try #require(job.toolpaths.first)
        let plunges = CutFixture.plunges(tp)
        #expect(plunges.count == 5, "one plunge per pass: \(plunges.count)")
        #expect(Set(plunges.map { "\(Int(($0.1.x * 1000).rounded())),\(Int(($0.1.y * 1000).rounded()))" }).count == 1, "all at one spot")
        for (s, e) in plunges { #expect(min(s.z, 0) - e.z <= 4.1 + 1e-6) }
        let r = CutFixture.r
        for (_, e) in plunges { #expect(CutFixture.distanceToRect(e.xy, size: Vec2(180, 120), at: Vec2(100, 75)) > r + 0.5) }

        let grid = Fixture.simulate([tp], stock: stock, cell: 0.5)
        let path = LoopWalker(Polyline([Vec2(10 - r, 15 - r), Vec2(190 + r, 15 - r), Vec2(190 + r, 135 + r), Vec2(10 - r, 135 + r)], closed: true))
        var notThrough = 0
        var s = 0.0
        while s < path.length {
            if let h = grid.height(at: path.point(at: s)), h > grid.floorZ + 1e-3 { notThrough += 1 }
            s += 1
        }
        #expect(notThrough == 0)
        // The part itself is untouched.
        let gouged = CutFixture.cells(grid).filter { p, h in abs(p.x - 100) < 90 - 0.5 && abs(p.y - 75) < 60 - 0.5 && h < -1e-6 }
        #expect(gouged.isEmpty, "\(gouged.count) cells of the part were cut")
    }

    @Test func rampRunsAlongTheLeadSoNothingPlunges() throws {
        for lead in [CutFixture.arc, CutFixture.line, LeadSettings(kind: .arc, radius: 6.35, leadOut: false)] {
            let op = CutFixture.profile([part], depth: DepthSettings(cutDepth: 12, passDepth: 4), entry: EntrySettings(kind: .ramp, rampLength: 30),
                                        leads: lead)
            let (_, job) = CutFixture.job([part], [op])
            let tp = try #require(job.toolpaths.first)
            #expect(CutFixture.plunges(tp).isEmpty, "\(lead.kind) lead-out \(lead.leadOut)")
            // The descent starts on the lead, off the wall.
            var descentStart: Vec3?
            tp.forEachMotion { s, m in if descentStart == nil, m.kind == .feed, m.end.z < -1e-6 { descentStart = s } }
            let start = try #require(descentStart)
            #expect(CutFixture.distanceToRect(start.xy, size: Vec2(100, 60), at: Vec2(100, 75)) > CutFixture.r + 0.5,
                    "\(lead.kind) lead-out \(lead.leadOut): descent starts at \(start), warnings \(tp.warnings)")
            #expect(abs((tp.motions.map(\.end.z).min() ?? 0) + 12) < 1e-6)
        }
    }

    @Test func tabsStayWhereTheyWereWithLeads() throws {
        let tabs = TabSettings(enabled: true, count: 4, width: 8, thickness: 3)
        for entry in [EntrySettings(), EntrySettings(kind: .ramp, rampLength: 30)] {
            let op = CutFixture.profile([part], depth: DepthSettings(cutDepth: 20, passDepth: 5), tabs: tabs, entry: entry,
                                        leads: LeadSettings(kind: .arc, radius: 6.35, overlap: 3))
            let (_, job) = CutFixture.job([part], [op])
            let tp = try #require(job.toolpaths.first)
            let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.5)
            let r = CutFixture.r
            let walker = LoopWalker(Polyline([Vec2(50 - r, 45 - r), Vec2(150 + r, 45 - r), Vec2(150 + r, 105 + r), Vec2(50 - r, 105 + r)], closed: true))
            var inTab = false, bridges = 0, through = 0
            var s = 0.0
            while s < walker.length {
                guard let h = grid.height(at: walker.point(at: s)) else { s += 0.5; continue }
                let isTab = abs(Double(h) - (-17)) < 0.2
                if isTab && !inTab { bridges += 1 }
                if h <= grid.floorZ + 1e-3 { through += 1 }
                inTab = isTab
                s += 0.5
            }
            #expect(bridges == 4, "\(entry.kind)")
            #expect(through > 500, "\(entry.kind)")
        }
    }

    @Test func leadsShrinkToFitSmallHolesOrAreLeftOff() throws {
        let hole = DesignShape(kind: .circle(radius: 5), position: Vec2(100, 75))
        let (_, job) = CutFixture.job([hole], [CutFixture.profile([hole], side: .inside, leads: CutFixture.arc)])
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.warnings.contains { $0.contains("Leads") }, "\(tp.warnings)")
        for (_, e) in CutFixture.plunges(tp) { #expect(5 - e.xy.distance(to: Vec2(100, 75)) > CutFixture.r + 0.1) }

        let tiny = DesignShape(kind: .circle(radius: 3.5), position: Vec2(100, 75))
        let (_, job2) = CutFixture.job([tiny], [CutFixture.profile([tiny], side: .inside, leads: CutFixture.arc)])
        let tp2 = try #require(job2.toolpaths.first)
        #expect(tp2.warnings.contains("Leads didn't fit on 1 loop; it's entered without one."), "\(tp2.warnings)")
        #expect(!tp2.isEmpty)
    }

    @Test func leadsKeepClearOfNeighboursTheMaterialEdgeAndClamps() throws {
        // Two parts 10 mm apart in one toolpath: neither is cut.
        let a = Fixture.rect(40, 40, at: Vec2(60, 75)), b = Fixture.rect(40, 40, at: Vec2(110, 75))
        let (_, job) = CutFixture.job([a, b], [CutFixture.profile([a, b], leads: CutFixture.arc)])
        let tp = try #require(job.toolpaths.first)
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        let gouged = CutFixture.cells(grid).filter { p, h in
            h < -1e-6 && abs(p.y - 75) < 20 - 0.25 && (abs(p.x - 60) < 20 - 0.25 || abs(p.x - 110) < 20 - 0.25)
        }
        #expect(gouged.isEmpty, "\(gouged.count) cells of the parts were cut")

        // A part flush with the material's corner: the leads go in from the sides that have room.
        let corner = Fixture.rect(40, 40, at: Vec2(20, 20))
        let (_, job2) = CutFixture.job([corner], [CutFixture.profile([corner], leads: CutFixture.arc)])
        #expect(!job2.issues.contains { $0.message.contains("beyond the material edges") }, "\(job2.issues.map(\.message))")
        #expect(!(job2.toolpaths.first?.warnings ?? []).contains { $0.contains("Leads") })

        // A clamp just below the part: the leads don't cut into it.
        let piece = Fixture.rect(60, 40, at: Vec2(100, 75))
        var clamp = Fixture.rect(120, 10, at: Vec2(100, 41))
        clamp.keepOutHeight = 5
        let (_, job3) = CutFixture.job([piece, clamp], [CutFixture.profile([piece], leads: CutFixture.arc)])
        #expect(!job3.hasErrors, "\(job3.issues.map(\.message))")
        #expect(!(job3.toolpaths.first?.warnings ?? []).contains { $0.contains("Leads") })
    }

    @Test func finishingAfterRoughingLeadsOnlyThroughClearedMaterial() throws {
        let shape = Fixture.rect(100, 60, at: Vec2(100, 75))
        let rough = CutFixture.profile([shape], depth: DepthSettings(cutDepth: 19, passDepth: 5), allowance: 0.5)
        let finish = CutFixture.profile([shape], depth: DepthSettings(cutDepth: 20.5, passDepth: 5), leads: CutFixture.arc)
        let (_, job) = CutFixture.job([shape], [rough, finish])
        #expect(job.toolpaths.count == 2)
        let finished = job.toolpaths[1]
        #expect(!finished.warnings.contains { $0.contains("Leads") }, "\(finished.warnings)")
        // One pass at the bottom, entered from the roughing kerf.
        let cutting = finished.motions.filter { $0.kind != .rapid && $0.end.z < -1e-6 }
        #expect(!cutting.isEmpty)
        #expect(cutting.allSatisfy { $0.end.z < -18.9 }, "finishing should start below what roughing cleared")
        let grid = Fixture.simulate([job.toolpaths[0]], stock: Fixture.stock, cell: 0.5)
        let r = CutFixture.r
        for m in cutting {
            let top = Double(LinkOptimizer.maxHeight(grid, around: m.end.xy, radius: r * 0.5))
            #expect(top <= -19 + 0.1, "finishing cuts uncut material at \(m.end): \(top)")
        }
    }

    @Test func onLineProfilesIgnoreLeadsWithANote() throws {
        let line = DesignShape(kind: .paths([Polyline([Vec2(50, 50), Vec2(150, 50), Vec2(150, 100)], closed: false)]), position: .zero)
        let (_, plain) = CutFixture.job([line], [CutFixture.profile([line], side: .on)])
        let (_, led) = CutFixture.job([line], [CutFixture.profile([line], side: .on, leads: CutFixture.arc,
                                                                   relief: CornerReliefSettings())])
        let a = try #require(plain.toolpaths.first), b = try #require(led.toolpaths.first)
        #expect(a.motions == b.motions)
        #expect(b.warnings.contains("Leads need an inside or outside cut; they were skipped."))
        #expect(b.warnings.contains("Corner reliefs need an inside or outside cut; they were skipped."))
    }

    @Test func leadsDoNotChangeLoopsWhenOff() throws {
        // nil settings are the old behaviour: same motions as a project that never had the fields.
        let op = CutFixture.profile([part], depth: DepthSettings(cutDepth: 12, passDepth: 4), entry: EntrySettings(kind: .ramp, rampLength: 30))
        let (_, a) = CutFixture.job([part], [op])
        var data = try JSONEncoder().encode(op)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("leads") && !json.contains("cornerRelief"), "nil options are not written")
        data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(CAMOperation.self, from: data)
        let (_, b) = CutFixture.job([part], [decoded])
        #expect(a.toolpaths.first?.motions == b.toolpaths.first?.motions)
    }

    @Test func settingsRoundTripThroughProjectFiles() throws {
        let leads = LeadSettings(kind: .line, radius: 4, sweep: 60, length: 5, angle: 30, leadOut: false, overlap: 2)
        let relief = CornerReliefSettings(style: .tBone, tBoneSide: .alongY, maxCornerAngle: 100)
        let profile = CutFixture.profile([part], leads: leads, relief: relief)
        let pocket = CutFixture.pocket([part], relief: relief)
        let p = Fixture.project(shapes: [part], ops: [profile, pocket])
        let back = try Project.decode(try p.encoded())
        #expect(back.operations == p.operations)
        #expect(back.formatVersion == p.formatVersion)
    }

    @Test func aSheetOfPartsStaysQuick() throws {
        // 50 notched parts (inside corners for the reliefs) on one sheet, with leads and dogbones.
        var shapes: [DesignShape] = []
        for row in 0..<5 {
            for col in 0..<10 {
                let o = Vec2(10 + Double(col) * 48, 10 + Double(row) * 48)
                let pts = [Vec2(0, 0), Vec2(36, 0), Vec2(36, 36), Vec2(24, 36), Vec2(24, 24), Vec2(12, 24), Vec2(12, 36), Vec2(0, 36)].map { $0 + o }
                shapes.append(DesignShape(kind: .paths([Polyline(pts, closed: true)]), position: .zero))
            }
        }
        let stock = Stock(width: 500, height: 260, thickness: 18, clearanceHeight: 10, plungeHeight: 2)
        let op = CutFixture.profile(shapes, depth: DepthSettings(cutDepth: 18.5, passDepth: 6.5), leads: CutFixture.arc,
                                    relief: CornerReliefSettings())
        let clock = ContinuousClock()
        var job: JobResult?
        let elapsed = clock.measure { job = CutFixture.job(shapes, [op], stock: stock).1 }
        let tp = try #require(job?.toolpaths.first)
        #expect(!tp.warnings.contains { $0.contains("Leads") || $0.contains("corner") }, "\(tp.warnings)")
        #expect(CutFixture.reversals(tp) == 50 * 2 * 3, "two reliefs per part, three passes")
        #expect(elapsed < .seconds(20), "took \(elapsed)")
    }
}
