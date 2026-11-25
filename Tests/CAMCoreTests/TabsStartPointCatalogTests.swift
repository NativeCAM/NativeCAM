import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for a profile's hand-placed and triangular tabs and its chosen start points (#167): goldens on
/// Avid's Mach4 default, a saved format-29 project with its decoded golden, and saved projects for each case handled
/// (`Fixtures/tabs-start`, listed in its README): marks no longer on their shapes, every tab removed, a start on a tab
/// or with no room for its lead, the ball-nose fallback, a steep ramp, overlapping tabs, a tab too long for its hole,
/// inside cuts, tabs on material already cut, nesting, tiling and the edge-profile check.
struct TabsStartPointCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("tabs-start")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "167AB000-0000-4000-8000-%012d", n))! }

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try CutDirectionCatalogTests.checkGolden(p, name, sourceLocation: sourceLocation)
    }

    // MARK: Builders

    static let quarter = ToolLibrary.starter.tool(number: 1)!   // 1/4" upcut
    static let ball = ToolLibrary.starter.tool(number: 7)!      // 1/4" ball nose

    /// A part 120 × 80 mm with square corners at (100, 75): its edges are at x 40 and 160, y 35 and 115; in its own
    /// coordinates at x ±60, y ±40.
    static func part(_ n: Int = 1, at centre: Vec2 = Vec2(100, 75)) -> DesignShape {
        DesignShape(id: id(n), name: "Part", kind: .rectangle(width: 120, height: 80, cornerRadius: 0), position: centre)
    }

    /// A round part 50 mm across.
    static func disc(_ n: Int = 2, at centre: Vec2 = Vec2(230, 75)) -> DesignShape {
        DesignShape(id: id(n), name: "Disc", kind: .circle(radius: 25), position: centre)
    }

    static let through = DepthSettings(cutDepth: 0.75.inch + 0.5)

    static func mark(_ shape: DesignShape, _ x: Double, _ y: Double) -> ContourMark { ContourMark(shapeID: shape.id, point: Vec2(x, y)) }

    static func profile(_ n: Int, name: String = "Cut out", shapes: [DesignShape], side: CutSide = .outside, depth: DepthSettings = through,
                        tabs: TabSettings = TabSettings(enabled: true), entry: EntrySettings = EntrySettings(kind: .plunge),
                        leads: LeadSettings? = nil, finish: ProfileFinishPass? = nil, starts: [ContourMark]? = nil,
                        tool: Tool = quarter) -> CAMOperation {
        CAMOperation(id: id(n), name: name,
                     kind: .profile(ProfileParams(side: side, direction: .climb, depth: depth, tabs: tabs, entry: entry, leads: leads,
                                                  finishPass: finish, startPoints: starts)),
                     shapeIDs: shapes.map(\.id), tool: tool)
    }

    static func project(_ name: String, shapes: [DesignShape], ops: [CAMOperation], units: LengthUnit = .inch,
                        width: Double = 300, height: Double = 150) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        let s = Stock(width: width, height: height, thickness: 0.75.inch, materialName: "Plywood", clearanceHeight: 10, plungeHeight: 2,
                      materialKind: .plywood)
        return Project(name: name, displayUnits: units, stock: s, machine: machine, shapes: shapes, operations: ops)
    }

    /// Four tabs on the part's straight edges, two on the disc.
    static func placedTabs(_ part: DesignShape, _ disc: DesignShape?) -> [ContourMark] {
        [mark(part, -30, -40), mark(part, 30, 40), mark(part, -60, 0), mark(part, 60, 10)]
            + (disc.map { [mark($0, 25, 0), mark($0, -25, 0)] } ?? [])
    }

    // MARK: Measuring

    static func params(_ op: CAMOperation) -> ProfileParams {
        if case let .profile(p) = op.kind { return p }
        fatalError("not a profile")
    }

    /// Every point the tool cuts at (no rapids), densely, with each move's feed.
    static func cutPoints(_ tp: Toolpath, step: Double = 0.2) -> [Vec3] {
        var out: [Vec3] = []
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            if m.kind.isArc {
                out += m.samples(from: s, maxStep: step)
            } else {
                let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
                out += (0...n).map { k in s + (m.end - s) * (Double(k) / Double(n)) }
            }
        }
        return out
    }

    /// How many times the tool lifts off `level` (the final pass's Z) while cutting: one per tab crossed.
    static func lifts(_ tp: Toolpath, level: Double) -> Int {
        var n = 0
        tp.forEachMotion { s, m in
            guard m.kind == .feed else { return }
            if abs(s.z - level) < 1e-4, m.end.z > level + 0.01 { n += 1 }
        }
        return n
    }

    // MARK: Goldens

    /// A rectangle and a disc with tabs placed by hand: four on the rectangle's straight edges, two on the disc.
    static func placedProject() -> Project {
        let part = Self.part(), disc = Self.disc()
        return project("Tabs placed by hand", shapes: [part, disc],
                       ops: [profile(1, shapes: [part, disc], tabs: TabSettings(enabled: true, placed: placedTabs(part, disc)))])
    }

    @Test func placedTabsGolden() throws {
        let p = Self.placedProject()
        #expect(p.formatVersion == 29)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.tabMarks?.count == 6)
        #expect(tp.tabMarks?.allSatisfy { $0.placed && $0.cut && $0.flag == nil } == true)
        #expect(Self.lifts(tp, level: -Self.through.cutDepth) == 6)
        try Self.checkGolden(p, "tabs-placed-inch")
    }

    /// Triangular tabs thicker than a pass, so a pass above the floor crosses their ramps (cut at the ramps' crossings).
    static func triangularProject(units: LengthUnit) -> Project {
        let part = Self.part()
        let tabs = TabSettings(enabled: true, count: 4, width: 0.625.inch, thickness: 0.25.inch, shape: .triangular)
        return project("Triangular tabs", shapes: [part],
                       ops: [profile(1, shapes: [part], depth: DepthSettings(cutDepth: 0.75.inch + 0.5, passDepth: 0.25.inch), tabs: tabs)],
                       units: units, width: 200)
    }

    @Test func triangularTabsGoldens() throws {
        for units in [LengthUnit.inch, .mm] {
            let p = Self.triangularProject(units: units)
            #expect(p.formatVersion == 29)
            let job = CAMEngine.generate(p)
            #expect(!job.issues.contains { $0.message.contains("steeper than 45°") })
            try Self.checkGolden(p, units == .inch ? "tabs-triangular-inch" : "tabs-triangular-mm")
        }
    }

    /// Arc leads and a ramp entry with triangular tabs: the ramp along the wall rides up over a tab.
    static func leadsRampProject() -> Project {
        let part = Self.part()
        let tabs = TabSettings(enabled: true, count: 6, shape: .triangular)
        return project("Triangular tabs, leads and ramp", shapes: [part],
                       ops: [profile(1, shapes: [part], tabs: tabs, entry: EntrySettings(kind: .ramp, rampLength: 3.inch),
                                     leads: LeadSettings(kind: .arc, radius: 0.25.inch))], width: 200)
    }

    @Test func triangularTabsLeadsAndRampGolden() throws {
        try Self.checkGolden(Self.leadsRampProject(), "tabs-triangular-leads-ramp")
    }

    /// A start chosen mid-way along the back edge (the far one, +Y), with arc leads.
    static func backEdgeStartProject() -> Project {
        let part = Self.part()
        return project("Start on the back edge", shapes: [part],
                       ops: [profile(1, shapes: [part], leads: LeadSettings(kind: .arc, radius: 0.25.inch), starts: [mark(part, 0, 40)])],
                       width: 200)
    }

    @Test func backEdgeStartGolden() throws {
        let p = Self.backEdgeStartProject()
        #expect(p.formatVersion == 29)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let start = try #require(tp.startMarks?.first)
        // The tool centre runs a bit radius outside the back edge, entering right behind the chosen point.
        #expect(start.used.distance(to: Vec2(100, 115 + Self.quarter.radius)) < 0.05, "\(start.used)")
        #expect(start.moved < 0.05)
        #expect(abs(start.direction.y) < 1e-6)
        try Self.checkGolden(p, "start-point-leads-inch")
    }

    /// A start on a corner, plunging in, no leads.
    static func cornerStartProject() -> Project {
        let part = Self.part()
        return project("Start on a corner", shapes: [part], ops: [profile(1, shapes: [part], starts: [mark(part, 60, -40)])], width: 200)
    }

    @Test func cornerStartGolden() throws {
        let p = Self.cornerStartProject()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let start = try #require(tp.startMarks?.first)
        // On the bit's arc round the corner, as near the drawn corner as the cut comes.
        #expect(abs(start.used.distance(to: Vec2(160, 35)) - Self.quarter.radius) < 0.05, "\(start.used)")
        try Self.checkGolden(p, "start-point-corner-noleads")
    }

    /// A finishing pass and a spring pass with triangular tabs placed by hand.
    static func finishProject() -> Project {
        let part = Self.part()
        let tabs = TabSettings(enabled: true, shape: .triangular, placed: [mark(part, -30, -40), mark(part, 30, 40), mark(part, 60, 0)])
        return project("Finish over placed triangular tabs", shapes: [part],
                       ops: [profile(1, shapes: [part], tabs: tabs, leads: LeadSettings(kind: .arc, radius: 0.25.inch),
                                     finish: ProfileFinishPass(springPass: true))], width: 200)
    }

    @Test func finishPassOverPlacedTriangularTabsGolden() throws {
        try Self.checkGolden(Self.finishProject(), "tabs-finish-placed-triangular")
    }

    /// The finish and spring laps stay at or above every tab's lift where they cross it: the same tabs as the roughing.
    @Test func theFinishLapsLiftOverTheSameTabs() throws {
        let p = Self.finishProject()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let laps = try #require(tp.finishLaps)
        let marks = try #require(tp.tabMarks)
        #expect(marks.count == 3)
        let q = Self.params(p.operations[0])
        let floor = -q.depth.cutDepth, top = floor + q.tabs.thickness
        let half = q.tabs.width / 2, r = Self.quarter.radius
        // Each tab's centre on the finishing loop; along the loop the lift is a trapezoid of base width + 2r.
        let loop = try #require(laps.loops.first)
        var lowestOverCentre = [Double](repeating: .infinity, count: marks.count)
        var finishPoints = 0, roughPoints = 0
        for run in FinishingPassCatalogTests.runs(tp) {
            for pt in FinishingPassCatalogTests.points(run.moves) {
                for (k, mark) in marks.enumerated() {
                    let centre = loop.closestPoint(to: mark.point).point
                    let d = pt.xy.distance(to: centre)
                    guard d < half + r else { continue }
                    // Within the flat top the tool stays at the tab's top; on the ramps, above the ramp.
                    let along = max(0, d - r)
                    let want = along <= 1e-9 ? top : top - (top - floor) * along / half
                    #expect(pt.z >= want - 0.02, "z \(pt.z) under \(want) at \(d) from tab \(k)")
                    if d < r * 0.5 { lowestOverCentre[k] = min(lowestOverCentre[k], pt.z) }
                    if run.finish { finishPoints += 1 } else { roughPoints += 1 }
                }
            }
        }
        #expect(finishPoints > 0 && roughPoints > 0)
        for z in lowestOverCentre { #expect(abs(z - top) < 0.02, "\(z) vs \(top)") }
    }

    // MARK: Saved project

    /// Placed triangular tabs and a chosen start on the outside, evenly spaced triangular tabs on a hole, in inches.
    static func savedProject() -> Project {
        let part = Self.part()
        let hole = DesignShape(id: id(3), name: "Hole", kind: .circle(radius: 1.inch), position: Vec2(100, 75))
        var p = project("Tabs and start points (format 29)", shapes: [part, hole], ops: [
            profile(31, name: "Hole", shapes: [hole], side: .inside, tabs: TabSettings(enabled: true, count: 2, shape: .triangular)),
            profile(32, shapes: [part], tabs: TabSettings(enabled: true, shape: .triangular, placed: placedTabs(part, nil)),
                    leads: LeadSettings(kind: .arc, radius: 0.25.inch), starts: [mark(part, 0, 40)]),
        ], width: 200)
        p.notes = "Saved by the first build with tabs placed by hand, triangular tabs and chosen starts, as format 29."
        return p
    }

    @Test func savedProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("tabs-start-v29", make: Self.savedProject)
        #expect(p.formatVersion == 29)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        try Self.checkGolden(p, "decoded-tabs-start-v29")
    }

    // MARK: File format

    @Test func theNewSettingsAreFormatTwentyNineOnlyWhenUsed() throws {
        let plain = ProfileParams(depth: Self.through, tabs: TabSettings(enabled: true))
        #expect(plain.requiredFormatVersion == 1)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("shape") && !json.contains("placed") && !json.contains("startPoints"), "\(json)")
        // An old file's tabs (the four keys only) decode as today's.
        let old = #"{"enabled":true,"count":3,"width":9,"thickness":2}"#
        let decoded = try JSONDecoder().decode(TabSettings.self, from: Data(old.utf8))
        #expect(decoded == TabSettings(enabled: true, count: 3, width: 9, thickness: 2))
        var t = plain
        t.tabs.shape = .triangular
        #expect(t.requiredFormatVersion == 29)
        t.tabs.enabled = false
        #expect(t.requiredFormatVersion == 1)
        var placed = plain
        placed.tabs.placed = []
        #expect(placed.requiredFormatVersion == 29)
        var started = plain
        started.startPoints = [ContourMark(shapeID: Self.id(1), point: .zero)]
        #expect(started.requiredFormatVersion == 29)
        started.side = .on
        #expect(started.requiredFormatVersion == 1)
        #expect(Project.currentFormatVersion >= 29)
        // Round trip.
        var all = placed
        all.tabs.shape = .triangular
        all.startPoints = started.startPoints
        #expect(try JSONDecoder().decode(ProfileParams.self, from: JSONEncoder().encode(all)) == all)
    }

    @Test func templatesStripShapeBoundMarks() throws {
        let p = Self.savedProject()
        for op in p.operations {
            let copy = ToolpathTemplate.templateCopy(of: op, in: p)
            let q = Self.params(copy)
            #expect(q.tabs.placed == nil && q.startPoints == nil && q.cornerRelief?.overrides == nil)
            #expect(q.tabs.shape == Self.params(op).tabs.shape)
        }
    }

    // MARK: Tab plans

    /// Tabs at fixed places land on the same stretches of the wall wherever the loop starts.
    @Test func placedTabsLandInTheSamePlaceWhateverTheStart() throws {
        var lifted: [[Vec2]] = []
        for start in [nil, Vec2(0, 40), Vec2(-60, -20), Vec2(45, -40)] as [Vec2?] {
            var p = Self.placedProject()
            var q = Self.params(p.operations[0])
            q.startPoints = start.map { [ContourMark(shapeID: Self.id(1), point: $0)] }
            p.operations[0].kind = .profile(q)
            let tp = try #require(CAMEngine.generate(p).toolpaths.first)
            // Where the tool runs along over a tab (moves across, at the tab's top), rounded to 0.5 mm.
            let top = -Self.through.cutDepth + Self.params(p.operations[0]).tabs.thickness
            var pts = Set<[Int]>()
            tp.forEachMotion { s, m in
                guard m.kind == .feed, abs(s.z - top) < 1e-4, abs(m.end.z - top) < 1e-4 else { return }
                let n = max(1, Int((s.xy.distance(to: m.end.xy) / 0.5).rounded(.up)))
                for k in 0...n {
                    let q = s.xy.lerp(to: m.end.xy, Double(k) / Double(n))
                    pts.insert([Int((q.x * 2).rounded()), Int((q.y * 2).rounded())])
                }
            }
            lifted.append(pts.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }.map { Vec2(Double($0[0]) / 2, Double($0[1]) / 2) })
            let marks = try #require(tp.tabMarks)
            #expect(marks.count == 6)
        }
        // Each start's lifted stretches are within a sample of every other start's.
        for other in lifted.dropFirst() {
            for p in other { #expect(lifted[0].contains { $0.distance(to: p) < 1.01 }, "\(p)") }
            for p in lifted[0] { #expect(other.contains { $0.distance(to: p) < 1.01 }, "\(p)") }
        }
    }

    @Test func tabPlanMergesOverlapsAndKeepsEvenlySpacedTabsWhereTheyWere() throws {
        let params = ProfileParams(depth: DepthSettings(cutDepth: 10), tabs: TabSettings(enabled: true, count: 4, width: 10, thickness: 3))
        let tool = Self.quarter
        let even = TabPlan(length: 400, params: params, tool: tool, lastLevel: -10)
        let span = 10 + tool.diameter
        #expect(even.intervals.count == 4)
        for (k, iv) in even.intervals.enumerated() {
            let c = 400 * (Double(k) + 0.5) / 4
            #expect(abs(iv.0 - (c - span / 2)) < 1e-9 && abs(iv.1 - (c + span / 2)) < 1e-9)
        }
        // Two tabs closer than a span merge; one across the loop's start wraps.
        let placed = TabPlan(centres: [100, 105, 398], length: 400, params: params, tool: tool, lastLevel: -10)
        #expect(placed.tabs.count == 3)
        #expect(placed.intervals.count == 3)
        #expect(abs(placed.intervals[0].0) < 1e-9 && abs(placed.intervals[0].1 - (398 + span / 2 - 400)) < 1e-9)
        #expect(abs(placed.intervals[1].0 - (100 - span / 2)) < 1e-9 && abs(placed.intervals[1].1 - (105 + span / 2)) < 1e-9)
        #expect(placed.contains(0.5) && placed.contains(399) && placed.contains(102))
        // A tab longer than most of its loop is left off.
        let short = TabPlan(centres: [5], length: 20, params: params, tool: tool, lastLevel: -10)
        #expect(short.tooShort && short.intervals.isEmpty)
    }

    @Test func aTriangularTabRampsUpRunsFlatOneDiameterAndRampsDown() throws {
        var params = ProfileParams(depth: DepthSettings(cutDepth: 10), tabs: TabSettings(enabled: true, count: 1, width: 10, thickness: 3, shape: .triangular))
        params.side = .outside
        let tool = Self.quarter, d = tool.diameter
        let plan = TabPlan(centres: [100], length: 400, params: params, tool: tool, lastLevel: -10)
        let a = 100 - (10 + d) / 2
        #expect(plan.floor(at: a - 0.1) == nil)
        #expect(abs((plan.floor(at: a + 2.5) ?? 0) - (-8.5)) < 1e-9)  // half way up the 5 mm ramp
        #expect(abs((plan.floor(at: 100) ?? 0) - (-7)) < 1e-9)
        #expect(abs((plan.floor(at: 100 + d / 2 - 0.01) ?? 0) - (-7)) < 1e-9)
        #expect(abs((plan.rampAngle ?? 0) - atan2(3, 5) * 180 / .pi) < 1e-9)
        // A pass at -8.5 gets vertices where it meets each ramp.
        let breaks = plan.breaks(0, 400, level: -8.5)
        #expect(breaks.contains { abs($0 - (a + 2.5)) < 1e-9 } && breaks.contains { abs($0 - (a + 10 + d - 2.5)) < 1e-9 })
    }

    /// A flat bit cutting a triangular tab leaves the wall the tab's full thickness at its centre and its set length at
    /// its base, measured along the middle of the kerf (where a rectangular tab is its set length too).
    @Test func aTriangularTabLeavesItsThicknessAndLengthOnTheWall() throws {
        let part = Self.part()
        let tabs = TabSettings(enabled: true, width: 0.375.inch, thickness: 0.125.inch, shape: .triangular, placed: [Self.mark(part, 0, -40)])
        let p = Self.project("Wall", shapes: [part], ops: [Self.profile(1, shapes: [part], tabs: tabs)], width: 200)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.025)
        tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
        let g = sim.grid
        let y = 35 - Self.quarter.radius
        let row = Int(((y - g.origin.y) / g.cellSize).rounded())
        func height(_ x: Double) -> Double { Double(g.heights[g.index(Int(((x - g.origin.x) / g.cellSize).rounded()), row)]) }
        let floor = -Self.through.cutDepth
        // Full thickness at the centre.
        #expect(abs(height(100) - (floor + tabs.thickness)) < 0.05, "\(height(100) - floor)")
        // The base: each ramp's line (through where the wall is a quarter and three quarters of the tab's height)
        // carried down to the floor, so the grid's steps at the ramp's foot don't count.
        func crossing(_ z: Double, from x0: Double, step: Double) -> Double {
            var x = x0
            while abs(x - x0) < 20, height(x + step) > z { x += step }
            let a = height(x), b = height(x + step)
            return x + step * (a - z) / max(a - b, 1e-9)
        }
        let h = tabs.thickness
        func foot(_ step: Double) -> Double {
            let lowX = crossing(floor + 0.25 * h, from: 100, step: step), highX = crossing(floor + 0.75 * h, from: 100, step: step)
            return lowX + (lowX - highX) / 2
        }
        let base = foot(g.cellSize) - foot(-g.cellSize)
        #expect(abs(base - tabs.width) < 0.1, "\(base) vs \(tabs.width)")
    }

    // MARK: Part hold (#155)

    @Test func noPlacedTabsOrOnlyOrphanedOnesHoldNothing() throws {
        var p = Self.placedProject()
        #expect(PartHold.holdsPart(p.operations[0], in: p))
        var q = Self.params(p.operations[0])
        q.tabs.placed = []
        #expect(!PartHold.holdsPart(q))
        p.operations[0].kind = .profile(q)
        #expect(!PartHold.holdsPart(p.operations[0], in: p))
        #expect(PartHold.isTabbedCutOut(p.operations[0], in: p) == nil)
        // Marks on a shape that's gone (or moved off) hold nothing either.
        q.tabs.placed = [ContourMark(shapeID: Self.id(99), point: .zero), Self.mark(Self.part(), 0, 0)]
        p.operations[0].kind = .profile(q)
        #expect(PartHold.holdsPart(q))
        #expect(!PartHold.holdsPart(p.operations[0], in: p))
        #expect(!OperationScheduler.clearsTabs(1, of: p.operations[0], in: p))
    }

    /// A 3D toolpath next to a cut-out with tabs placed by hand holds its floor a tab thickness up while one of them is
    /// on its shape, and not once none is (they'd hold nothing).
    @Test func aThreeDFloorIsHeldForPlacedTabsOnly() throws {
        var p = try PartHoldTests.deepRelief()
        let k = try #require(p.operations.firstIndex { $0.name == "Cut out medallion" })
        let finish = try #require(p.operations.first { $0.name == "Finish relief" })
        var q = Self.params(p.operations[k])
        let shape = try #require(p.shapes(for: p.operations[k]).first)
        let outline = try #require(shape.polylines().first)
        let local = try #require(shape.transform.inverted).apply(outline.points[0])
        q.tabs.placed = [ContourMark(shapeID: shape.id, point: local)]
        p.operations[k].kind = .profile(q)
        let hold = try #require(PartHold.hold(for: finish, in: p))
        #expect(abs(hold.tabThickness - q.tabs.thickness) < 1e-9)
        #expect(abs(hold.z + (p.stock.thickness - q.tabs.thickness)) < 1e-9)
        q.tabs.placed = [ContourMark(shapeID: shape.id, point: local + Vec2(500, 0))]
        p.operations[k].kind = .profile(q)
        #expect(PartHold.hold(for: finish, in: p) == nil)
    }

    // MARK: Edge cases

    /// Marks placed on a 120 mm rectangle since made 100 mm wide: those on its left and right sides are now 10 mm off
    /// (left off, with a warning, shown in orange), those on the top and bottom slide in and are kept.
    static func orphanedProject() -> Project {
        var part = Self.part()
        part.kind = .rectangle(width: 100, height: 80, cornerRadius: 0)
        return project("Orphaned", shapes: [part], ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: placedTabs(part, nil)))],
                       width: 200)
    }

    @Test func marksNoLongerOnTheirShapeAreLeftOffWithAWarning() throws {
        let p = try Self.edgeCase("orphaned-after-resize", make: Self.orphanedProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.warnings.contains { $0.hasPrefix("2 tabs placed by hand are no longer on their shapes") }, "\(tp.warnings)")
        let marks = try #require(tp.tabMarks)
        #expect(marks.filter(\.cut).count == 2)
        #expect(marks.filter { !$0.cut && $0.flag != nil }.count == 2)
        #expect(Self.lifts(tp, level: -Self.through.cutDepth) == 2)
        // Still in the file.
        #expect(Self.params(p.operations[0]).tabs.placed?.count == 4)
        #expect(ContourMarks.matchedCount(Self.params(p.operations[0]).tabs.placed ?? [], shapes: p.shapes, toolRadius: Self.quarter.radius) == 2)
    }

    static func allRemovedProject() -> Project {
        let part = Self.part()
        return project("All removed", shapes: [part], ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: []))], width: 200)
    }

    @Test func removingEveryTabWarnsThePartIsCutFree() throws {
        let p = try Self.edgeCase("all-tabs-removed", make: Self.allRemovedProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.warnings.contains { $0.hasPrefix("1 loop has no tabs (they're placed by hand), so this cut through the material frees its part") },
                "\(tp.warnings)")
        #expect(Self.lifts(tp, level: -Self.through.cutDepth) == 0)
        #expect(!PartHold.holdsPart(p.operations[0], in: p))
        #expect(SetupSheet.html(project: p, job: CAMEngine.generate(p), date: GoldenPostTests.date).contains("<h2>Tabs</h2>") == false)
    }

    /// The start chosen right on a placed tab: the loop starts just past the tab, never on it.
    static func startOnTabProject() -> Project {
        let part = Self.part()
        return project("Start on a tab", shapes: [part],
                       ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: placedTabs(part, nil)), starts: [mark(part, -30, -40)])],
                       width: 200)
    }

    @Test func aStartOnATabMovesJustPastIt() throws {
        let p = try Self.edgeCase("start-inside-tab", make: Self.startOnTabProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.notes?.contains("The start chosen on 1 loop is on a tab, so the loop starts just past the tab.") == true, "\(tp.notes ?? [])")
        let start = try #require(tp.startMarks?.first)
        // Climb on an outside cut runs clockwise: along the bottom edge towards -X, so past the tab is to its left.
        let span = Self.params(p.operations[0]).tabs.width + Self.quarter.diameter
        #expect(abs(start.used.x - (70 - span / 2 - Self.quarter.radius)) < 0.05, "\(start.used)")
        // The plunge is at full depth's first pass, off the tab, and every move down stays off the tab's stretch.
        let floor = -Self.through.cutDepth
        let top = floor + Self.params(p.operations[0]).tabs.thickness
        for pt in Self.cutPoints(tp) where abs(pt.y - (35 - Self.quarter.radius)) < 0.01 && abs(pt.x - 70) < span / 2 - 0.05 {
            #expect(pt.z >= top - 1e-6 || pt.z > floor + 0.01 && pt.z >= -13, "\(pt)")
        }
    }

    /// Two parts 7 mm apart, the start chosen on the side facing the other one: there's no room there for a lead, so
    /// the entry moves along the loop to where one fits (and the lead is still checked clear).
    static func noLeadRoomProject() -> Project {
        let a = Self.part(1, at: Vec2(70, 75)), b = Self.part(2, at: Vec2(197, 75))
        return project("No room for the lead", shapes: [a, b],
                       ops: [profile(1, shapes: [a, b], tabs: TabSettings(enabled: false), leads: LeadSettings(kind: .arc, radius: 0.25.inch),
                                     starts: [mark(a, 60, 0)])])
    }

    @Test func aStartWithNoRoomForItsLeadMovesAndSaysHowFar() throws {
        let p = try Self.edgeCase("start-no-lead-room", make: Self.noLeadRoomProject)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let tp = try #require(job.toolpaths.first)
        let start = try #require(tp.startMarks?.first)
        #expect(start.moved > 5, "\(start.moved)")
        #expect(tp.notes?.contains { $0.hasPrefix("The lead didn't fit at the start chosen on 1 loop, so it's entered") } == true, "\(tp.notes ?? [])")
        // No move goes between the parts closer than a bit radius to either one's wall.
        let walls = p.shapes.flatMap { $0.polylines() }
        for pt in Self.cutPoints(tp) where pt.z < 0 {
            #expect(walls.map { $0.closestPoint(to: pt.xy).distance }.min()! >= Self.quarter.radius - 0.02, "\(pt)")
        }
    }

    static func ballProject() -> Project {
        let part = Self.part()
        return project("Ball nose", shapes: [part],
                       ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, shape: .triangular), tool: Self.ball)], width: 200)
    }

    @Test func aBallNoseCutsRectangularTabsWithAWarning() throws {
        let p = try Self.edgeCase("triangular-ball-fallback", make: Self.ballProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.warnings.contains { $0.hasPrefix("Triangular tabs need a flat-bottomed bit") }, "\(tp.warnings)")
        var rect = p
        var q = Self.params(rect.operations[0])
        q.tabs.shape = .rectangular
        rect.operations[0].kind = .profile(q)
        #expect(CAMEngine.generate(rect).toolpaths.first?.motions == tp.motions)
    }

    /// 0.1" long and 0.2" thick: the ramp is 76°, so the tool comes down off it at the plunge rate.
    static func steepProject() -> Project {
        let part = Self.part()
        return project("Steep", shapes: [part],
                       ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, width: 0.1.inch, thickness: 0.2.inch, shape: .triangular))],
                       width: 200)
    }

    @Test func aSteepTriangularTabDescendsAtThePlungeRate() throws {
        let p = try Self.edgeCase("triangular-steep", make: Self.steepProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.warnings.contains { $0.hasPrefix("The triangular tabs ramp at 76°, steeper than 45°") }, "\(tp.warnings)")
        var downRamps = 0
        var fastest = 0.0
        tp.forEachMotion { s, m in
            guard m.kind == .feed, m.end.z < s.z - 1e-6, Vec2(m.end.x - s.x, m.end.y - s.y).length > 1e-6 else { return }
            let d = m.end - s
            downRamps += 1
            fastest = max(fastest, m.feed * abs(d.z) / d.length)
        }
        #expect(downRamps > 0)
        #expect(fastest <= Self.quarter.cutting.plungeRate + 1e-6, "\(fastest)")
    }

    static func overlapProject() -> Project {
        let part = Self.part()
        return project("Overlapping tabs", shapes: [part],
                       ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: [mark(part, -30, -40), mark(part, -24, -40)]))],
                       width: 200)
    }

    @Test func overlappingTabsMergeIntoOneLift() throws {
        let p = try Self.edgeCase("tabs-overlap", make: Self.overlapProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.tabMarks?.count == 2)
        #expect(Self.lifts(tp, level: -Self.through.cutDepth) == 1)
    }

    /// A tab 3/4" long on a hole 16 mm across: with the bit's width it would take most of the loop, so it's refused.
    static func tooLongProject() -> Project {
        let part = Self.part()
        let hole = DesignShape(id: id(3), name: "Hole", kind: .circle(radius: 8), position: Vec2(100, 75))
        return project("Tab too long", shapes: [part, hole],
                       ops: [profile(1, name: "Hole", shapes: [hole], side: .inside,
                                     tabs: TabSettings(enabled: true, width: 0.75.inch, placed: [mark(hole, 8, 0)]))], width: 200)
    }

    @Test func aTabTooLongForItsHoleIsRefused() throws {
        let p = try Self.edgeCase("tab-too-long-for-hole", make: Self.tooLongProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.warnings.contains { $0.hasPrefix("A tab placed by hand is too long for the loop it's on") }, "\(tp.warnings)")
        #expect(Self.lifts(tp, level: -Self.through.cutDepth) == 0)
    }

    /// Tabs on an inside cut hold the waste piece inside the hole (the slug), as evenly spaced ones do.
    static func insideProject() -> Project {
        let part = Self.part()
        let hole = DesignShape(id: id(3), name: "Hole", kind: .circle(radius: 1.inch), position: Vec2(100, 75))
        return project("Inside tabs", shapes: [part, hole],
                       ops: [profile(1, name: "Hole", shapes: [hole], side: .inside,
                                     tabs: TabSettings(enabled: true, placed: [mark(hole, 1.inch, 0), mark(hole, -1.inch, 0)]))], width: 200)
    }

    @Test func tabsOnAnInsideCutHoldTheSlug() throws {
        let p = try Self.edgeCase("tabs-on-inside-profile", make: Self.insideProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(Self.lifts(tp, level: -Self.through.cutDepth) == 2)
        // The lifts are on the tool-centre loop inside the hole.
        for mark in try #require(tp.tabMarks) { #expect(abs(mark.point.distance(to: Vec2(100, 75)) - 1.inch) < 0.05) }
        #expect(!tp.warnings.contains { $0.contains("frees") })
    }

    /// A pocket run first clears below the tabs' top where one placed tab sits.
    static func clearedEarlierProject() -> Project {
        let part = Self.part()
        let pocket = DesignShape(id: id(4), name: "Notch", kind: .rectangle(width: 30, height: 20, cornerRadius: 0), position: Vec2(130, 35))
        let pocketOp = CAMOperation(id: id(41), name: "Notch", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.7.inch))),
                                    shapeIDs: [pocket.id], tool: Self.quarter)
        return project("Tab cleared earlier", shapes: [part, pocket],
                       ops: [pocketOp, profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: [mark(part, 30, -40), mark(part, -30, 40)]))],
                       width: 200)
    }

    @Test func aTabOnMaterialAlreadyCutAwayIsWarnedAbout() throws {
        let p = try Self.edgeCase("tab-cleared-earlier", make: Self.clearedEarlierProject)
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first { $0.sourceOperationID == Self.id(1) })
        #expect(tp.warnings.contains { $0.hasPrefix("1 tab placed by hand is where an earlier toolpath has already cut below the tabs' top") },
                "\(tp.warnings)")
        #expect(tp.tabMarks?.filter { $0.flag != nil }.count == 1)
    }

    /// The part turned and moved by Nest Parts: its marks are in its own coordinates, so they follow it.
    static func nestProject() -> Project {
        let part = Self.part()
        var p = project("Nested", shapes: [part], ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: placedTabs(part, nil)),
                                                                leads: LeadSettings(kind: .arc, radius: 0.25.inch), starts: [mark(part, 0, 40)])],
                        width: 600, height: 400)
        p.shapes[0].rotation = 30
        p.shapes[0].position = Vec2(300, 200)
        return p
    }

    @Test func marksFollowMoveRotateAndNestParts() throws {
        let p = try Self.edgeCase("nest-rotated", make: Self.nestProject)
        let nest = try NestJob.prepare(p, selection: [])
        let settings = NestFixture.settings()
        let result = nest.nest(settings)
        let moved = nest.apply(result, to: p, settings: settings).project
        #expect(moved.shapes[0].position.distance(to: p.shapes[0].position) > 1 || abs(moved.shapes[0].rotation - p.shapes[0].rotation) > 1)
        #expect(moved.operations == p.operations)
        for project in [p, moved] {
            let tp = try #require(CAMEngine.generate(project).toolpaths.first)
            let shape = project.shapes[0]
            let want = Self.placedTabs(shape, nil).map { shape.transform.apply($0.point) }
            let got = try #require(tp.tabMarks).map(\.point)
            #expect(got.count == 4)
            for w in want { #expect(got.contains { $0.distance(to: w) < 0.05 }, "\(w) not in \(got)") }
            let start = try #require(tp.startMarks?.first)
            #expect(start.requested.distance(to: shape.transform.apply(Vec2(0, 40))) < 0.05)
            #expect(start.moved < 0.05)
        }
    }

    /// A placed tab straddling a tile line: the tile split keeps the lift on both sides of the break, so the tab is cut
    /// whole, half in each tile (no step down onto it at the break).
    static func tiledProject() -> Project {
        let part = DesignShape(id: id(1), name: "Panel", kind: .rectangle(width: 500, height: 200, cornerRadius: 0), position: Vec2(15.inch, 8.inch))
        var p = project("Tab on a tile line", shapes: [part],
                        ops: [profile(1, shapes: [part], tabs: TabSettings(enabled: true, placed: [mark(part, 0, -100), mark(part, 0, 100)]))],
                        width: 30.inch, height: 16.inch)
        p.tiling = TilingSettings(enabled: true, mode: .grid, tileWidth: 16.inch, tileHeight: 16.inch)
        return p
    }

    @Test func aTabOnATileLineIsCutWholeAcrossTheTiles() throws {
        let p = try Self.edgeCase("tiled-tab-on-seam", make: Self.tiledProject)
        let layout = try #require(TileLayout(p))
        let seam = try #require(layout.seamsX.first)
        #expect(abs(seam - 15.inch) < 2.inch)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let pieces = job.toolpaths.filter { $0.sourceOperationID == Self.id(1) }
        #expect(Set(pieces.compactMap(\.tile)).count == 2)
        let q = Self.params(p.operations[0])
        let top = -q.depth.cutDepth + q.tabs.thickness
        let half = q.tabs.width / 2
        for tp in pieces {
            for pt in Self.cutPoints(tp) where abs(pt.x - 15.inch) < half - 0.05 && (abs(pt.y - (8.inch - 100 - Self.quarter.radius)) < 0.01
                                                                                    || abs(pt.y - (8.inch + 100 + Self.quarter.radius)) < 0.01) {
                #expect(pt.z >= top - 1e-6 || pt.z > -q.depth.cutDepth + q.tabs.thickness, "\(pt) in tile \(tp.tile ?? -1)")
            }
        }
    }

    /// An edge profile run before a cut-out with tabs placed by hand reaches them: Checks says so. With every placed
    /// tab removed there are no tabs to reach.
    static func edgeProfileProject() -> Project {
        let part = Self.part()
        let cove = EdgeProfileTests.form(.cove, radius: 0.5.inch, number: 6, id: 991)
        let edge = EdgeProfileTests.edge(EdgeProfileParams(depth: 0.7.inch), tool: cove, shapes: [part.id], id: id(51), name: "Cove")
        return project("Edge profile", shapes: [part],
                       ops: [edge, profile(1, shapes: [part], tabs: TabSettings(enabled: true, count: 0, placed: placedTabs(part, nil)))], width: 200)
    }

    @Test func theEdgeProfileCheckSeesPlacedTabs() throws {
        let p = try Self.edgeCase("edge-profile-reaches-placed-tabs", make: Self.edgeProfileProject)
        let issues = CAMEngine.edgeProfileIssues(p)
        #expect(issues.contains { $0.operation == "Cove" && $0.message.contains("reaches below the tops of the tabs") }, "\(issues.map(\.message))")
        var none = p
        var q = Self.params(none.operations[1])
        q.tabs.placed = []
        none.operations[1].kind = .profile(q)
        #expect(CAMEngine.edgeProfileIssues(none).isEmpty)
    }

    // MARK: Setup sheet and editing

    @Test func theSetupSheetSaysHowEachProfileIsHeld() throws {
        let p = Self.savedProject()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p), date: GoldenPostTests.date)
        #expect(html.contains("<h2>Tabs</h2>"))
        #expect(html.contains("<b>Cut out</b>: 4 triangular tabs, 0.375 × 0.125 in, placed by hand"), "\(html)")
        #expect(html.contains("<b>Hole</b>: 2 triangular tabs, 0.375 × 0.125 in, evenly spaced"))
    }

    /// The canvas's edits: the first one starts from the evenly spaced tabs shown, then adds, removes and slides marks;
    /// a start replaces any other on the same loop.
    @Test func editingStartsFromTheTabsShown() throws {
        let part = Self.part()
        let p = Self.project("Edit", shapes: [part], ops: [Self.profile(1, shapes: [part], tabs: TabSettings(enabled: true, count: 4))], width: 200)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let shown = try #require(tp.tabMarks)
        #expect(shown.count == 4 && shown.allSatisfy { !$0.placed })
        let q = Self.params(p.operations[0])
        let added = q.addingTab(Self.mark(part, 0, -40), shown: shown)
        #expect(added.tabs.placed?.count == 5)
        let removed = added.removingTab(shown[0], shown: shown, tolerance: 1e-3)
        #expect(removed.tabs.placed?.count == 4)
        #expect(removed.tabs.placed?.contains(shown[0].mark) == false)
        let slid = removed.movingTab(shown[1], to: Self.mark(part, 10, 40), shown: shown, tolerance: 1e-3)
        #expect(slid.tabs.placed?.count == 4 && slid.tabs.placed?.contains(Self.mark(part, 10, 40)) == true)
        #expect(slid.resettingTabs().tabs.placed == nil)
        // Placed tabs cut exactly where the marks are, the evenly spaced ones included.
        var edited = p
        edited.operations[0].kind = .profile(q.addingTab(Self.mark(part, 0, -40), shown: shown))
        let after = try #require(CAMEngine.generate(edited).toolpaths.first?.tabMarks)
        #expect(after.count == 5)
        for s in shown { #expect(after.contains { $0.point.distance(to: s.point) < 0.05 }) }
        // Starts: one per loop.
        let index = ContourMarks.Index([part], flatten: 0.01)
        let one = q.settingStart(Self.mark(part, 0, 40), index: index, tolerance: 3.2)
        let two = one.settingStart(Self.mark(part, 60, 0), index: index, tolerance: 3.2)
        #expect(two.startPoints == [Self.mark(part, 60, 0)])
        #expect(two.settingStart(Self.mark(part, 60, 0), clear: true, index: index, tolerance: 3.2).startPoints == nil)
    }

    /// Splitting an imported shape's vectors into their own shape (Nest Parts' separate parts) moves the marks on them.
    @Test func splittingAShapeCarriesItsMarks() throws {
        let a = Polyline([Vec2(0, 0), Vec2(50, 0), Vec2(50, 30), Vec2(0, 30)], closed: true)
        let b = Polyline([Vec2(100, 0), Vec2(150, 0), Vec2(150, 30), Vec2(100, 30)], closed: true)
        let shape = DesignShape(id: Self.id(6), name: "Panels", kind: .paths([a, b]), position: Vec2(10, 10))
        var q = ProfileParams(depth: Self.through, tabs: TabSettings(enabled: true, placed: [Self.mark(shape, 25, 0), Self.mark(shape, 125, 0)]))
        q.startPoints = [Self.mark(shape, 125, 30)]
        let op = CAMOperation(id: Self.id(61), name: "Cut out", kind: .profile(q), shapeIDs: [shape.id], tool: Self.quarter)
        let newID = Self.id(7)
        let shared = NestJob.sharing([op], shape: shape.id, with: newID, paths: [1], original: shape)
        let r = Self.params(shared[0])
        #expect(r.tabs.placed == [Self.mark(shape, 25, 0), ContourMark(shapeID: newID, point: Vec2(125, 0))])
        #expect(r.startPoints == [ContourMark(shapeID: newID, point: Vec2(125, 30))])
    }
}
