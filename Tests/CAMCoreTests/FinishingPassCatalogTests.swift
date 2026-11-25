import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for a profile's separate finishing pass (#157): goldens on Avid's Mach4 default, a saved
/// format-28 project with its decoded golden, and saved projects for each case handled (`Fixtures/finishing-pass`):
/// the walls inside and out, tabs the finish must lift over, leads kept in the roughing's kerf, the automatic lead,
/// each refusal and warning, the spring pass, Adjust Feeds for Load, a rest-aware start, tiling, templates and the
/// other toolpaths' view of the part.
struct FinishingPassCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("finishing-pass")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "157F1000-0000-4000-8000-%012d", n))! }

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

    static let quarter = ToolLibrary.starter.tool(number: 1)!   // 1/4" upcut, 1" flutes
    static let eighth = ToolLibrary.starter.tool(number: 2)!    // 1/8" upcut

    /// A part 120 × 80 mm (rounded corners) with a 2" round hole in it, on 3/4" plywood.
    static let partSize = Vec2(120, 80)
    static let partCentre = Vec2(100, 75)
    static let holeRadius = 1.inch

    static func partShape(_ n: Int = 1) -> DesignShape {
        DesignShape(id: id(n), name: "Part", kind: .rectangle(width: partSize.x, height: partSize.y, cornerRadius: 6), position: partCentre)
    }

    static func holeShape(_ n: Int = 2) -> DesignShape {
        DesignShape(id: id(n), name: "Hole", kind: .circle(radius: holeRadius), position: partCentre)
    }

    static func profile(_ n: Int, name: String, shape: DesignShape, side: CutSide = .outside, finish: ProfileFinishPass?,
                        depth: DepthSettings = DepthSettings(cutDepth: 0.75.inch + 0.5), allowance: Double = 0,
                        tabs: TabSettings = TabSettings(), leads: LeadSettings? = nil, tool: Tool = quarter) -> CAMOperation {
        CAMOperation(id: id(n), name: name,
                     kind: .profile(ProfileParams(side: side, direction: .climb, depth: depth, allowance: allowance, tabs: tabs,
                                                  entry: EntrySettings(kind: .plunge), leads: leads, finishPass: finish)),
                     shapeIDs: [shape.id], tool: tool)
    }

    static func project(_ name: String, shapes: [DesignShape], ops: [CAMOperation], units: LengthUnit = .mm,
                        stock: Stock? = nil) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        let s = stock ?? Stock(width: 200, height: 150, thickness: 0.75.inch, materialName: "Plywood", clearanceHeight: 10, plungeHeight: 2,
                               materialKind: .plywood)
        return Project(name: name, displayUnits: units, stock: s, machine: machine, shapes: shapes, operations: ops)
    }

    static let mmFinish = ProfileFinishPass(allowance: 0.5)
    static let inchFinish = ProfileFinishPass()

    // MARK: Measuring

    /// The drawn outline of a shape.
    static func outline(_ shape: DesignShape) -> Polyline { shape.polylines(tolerance: 0.001)[0] }

    /// Distance from the drawn wall to the tool centre.
    static func wall(_ p: Vec2, _ shape: DesignShape) -> Double { outline(shape).closestPoint(to: p).distance }

    /// The toolpath's moves split at each retract: (motions, whether any lies on a finishing loop), with each move's start.
    static func runs(_ tp: Toolpath) -> [(moves: [(Vec3, Motion)], finish: Bool)] {
        var out: [(moves: [(Vec3, Motion)], finish: Bool)] = []
        var current: [(Vec3, Motion)] = []
        var finish = false
        tp.forEachMotion { s, m in
            if m.kind == .rapid {
                if !current.isEmpty { out.append((current, finish)) }
                current = []
                finish = false
                return
            }
            current.append((s, m))
            if let laps = tp.finishLaps, ProfileFinish.isOnFinishLoop(m, from: s, loops: laps.loops, tolerance: laps.tolerance) { finish = true }
        }
        if !current.isEmpty { out.append((current, finish)) }
        return out
    }

    /// Points along a move (lines too), at most `step` apart, without its start.
    static func dense(_ s: Vec3, _ m: Motion, step: Double) -> [Vec3] {
        guard !m.kind.isArc else { return m.samples(from: s, maxStep: step) }
        let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
        return (1...n).map { k in s + (m.end - s) * (Double(k) / Double(n)) }
    }

    /// Points along a list of moves below the surface, at most 0.25 mm apart.
    static func points(_ moves: [(Vec3, Motion)]) -> [Vec3] {
        moves.flatMap { s, m in [s] + dense(s, m, step: 0.25) }.filter { $0.z < -1e-6 }
    }

    /// Checks a toolpath's walls against `shape`: the finishing loops sit `r + allowance` off the wall and nothing cuts
    /// closer; the roughing moves keep `r + allowance + finish` off it, and reach that on the wall loop.
    static func checkWalls(_ tp: Toolpath, shape: DesignShape, r: Double, allowance: Double, finish: Double,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let laps = try #require(tp.finishLaps, sourceLocation: sourceLocation)
        for loop in laps.loops {
            for p in loop.points { #expect(abs(wall(p, shape) - (r + allowance)) < 0.01, "\(wall(p, shape))", sourceLocation: sourceLocation) }
        }
        var roughNearest = Double.infinity
        for run in runs(tp) {
            let pts = points(run.moves)
            if run.finish {
                for p in pts { #expect(wall(p.xy, shape) >= r + allowance - 0.01, sourceLocation: sourceLocation) }
            } else {
                for p in pts { roughNearest = min(roughNearest, wall(p.xy, shape)) }
            }
        }
        #expect(abs(roughNearest - (r + allowance + finish)) < 0.01, "\(roughNearest)", sourceLocation: sourceLocation)
    }

    /// The finishing runs (their lead, laps and plunges) stay in the roughing's kerf: between the finished wall's and
    /// the roughing's tool-centre offsets.
    static func checkInKerf(_ tp: Toolpath, shape: DesignShape, r: Double, allowance: Double, finish: Double,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let finishing = runs(tp).filter(\.finish)
        #expect(!finishing.isEmpty, sourceLocation: sourceLocation)
        for run in finishing {
            for p in points(run.moves) {
                let d = wall(p.xy, shape)
                #expect(d >= r + allowance - 0.01 && d <= r + allowance + finish + 0.01, "\(d) at \(p)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: Goldens

    static func outsideProject() -> Project {
        let part = partShape()
        return project("Finishing pass outside", shapes: [part], ops: [profile(11, name: "Cut out", shape: part, finish: mmFinish)])
    }

    static func insideProject() -> Project {
        let hole = holeShape()
        var p = project("Finishing pass inside", shapes: [hole],
                        ops: [profile(12, name: "Hole", shape: hole, side: .inside, finish: inchFinish)], units: .inch)
        p.machine.outputArcs = MachineProfile.avidPRO6060.outputArcs
        return p
    }

    static func tabsLeadsProject() -> Project {
        let part = partShape()
        return project("Finishing pass tabs and leads", shapes: [part],
                       ops: [profile(13, name: "Cut out", shape: part, finish: mmFinish, tabs: TabSettings(enabled: true, count: 4),
                                     leads: LeadSettings(kind: .arc, radius: 6.35, overlap: 2))])
    }

    static func eachDepthProject() -> Project {
        let part = partShape()
        return project("Finishing pass each depth", shapes: [part],
                       ops: [profile(14, name: "Cut out", shape: part, finish: ProfileFinishPass(allowance: 0.5, depth: .eachPass),
                                     depth: DepthSettings(cutDepth: 0.75.inch + 0.5, passDepth: 7))])
    }

    static func springProject() -> Project {
        let part = partShape()
        return project("Finishing pass spring", shapes: [part],
                       ops: [profile(15, name: "Cut out", shape: part,
                                     finish: ProfileFinishPass(allowance: 0.5, feedPercent: 0.8, springPass: true))])
    }

    @Test func outsideGolden() throws { try Self.checkGolden(Self.outsideProject(), "finishing-pass-outside-mm") }
    @Test func insideGolden() throws { try Self.checkGolden(Self.insideProject(), "finishing-pass-inside-inch") }
    @Test func tabsLeadsGolden() throws { try Self.checkGolden(Self.tabsLeadsProject(), "finishing-pass-tabs-leads-mm") }
    @Test func eachDepthGolden() throws { try Self.checkGolden(Self.eachDepthProject(), "finishing-pass-each-depth-mm") }
    @Test func springGolden() throws { try Self.checkGolden(Self.springProject(), "finishing-pass-spring-mm") }

    // MARK: File format

    @Test func aFinishingPassIsFormatTwentyEightAndNoneKeepsTheFormat() throws {
        let plain = ProfileParams(depth: DepthSettings(cutDepth: 6))
        #expect(plain.requiredFormatVersion == 1)
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("finishPass"))
        var finished = plain
        finished.finishPass = ProfileFinishPass()
        #expect(finished.requiredFormatVersion == 28)
        let part = Self.partShape()
        #expect(Self.project("x", shapes: [part], ops: [Self.profile(1, name: "x", shape: part, finish: nil)]).formatVersion == 1)
        #expect(Self.outsideProject().formatVersion == 28)
        #expect(Project.currentFormatVersion >= 28)
        // Defaults: 0.02 in (0.5 mm in a metric project), full depth, conventional, 100%, no spring pass.
        let d = ProfileFinishPass()
        #expect(abs(d.allowance - 0.508) < 1e-9 && d.depth == .fullDepth && d.direction == .conventional && d.feedPercent == 1 && !d.springPass)
        #expect(ProfileFinishPass.defaultAllowance(for: .mm) == 0.5)
    }

    /// The outside profile with tabs, leads and a spring pass, and the 2" hole each depth, in inches.
    static func savedProject() -> Project {
        let part = Self.partShape(), hole = Self.holeShape()
        var p = Self.project("Finishing pass (format 28)", shapes: [part, hole], ops: [
            Self.profile(21, name: "Hole", shape: hole, side: .inside,
                         finish: ProfileFinishPass(depth: .eachPass, feedPercent: 0.9),
                         depth: DepthSettings(cutDepth: 0.75.inch + 0.5, passDepth: 0.375.inch)),
            Self.profile(22, name: "Cut out", shape: part,
                         finish: ProfileFinishPass(springPass: true), tabs: TabSettings(enabled: true, count: 4),
                         leads: LeadSettings(kind: .arc, radius: 0.25.inch)),
        ], units: .inch)
        p.notes = "Saved by the first build with finishing passes on profiles, as format 28."
        return p
    }

    @Test func savedProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("finishing-pass-v28", make: Self.savedProject)
        #expect(p.formatVersion == 28)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        try Self.checkGolden(p, "decoded-finishing-pass-v28")
    }

    // MARK: Walls and direction

    @Test func outsideWallsSitWhereTheyShould() throws {
        let p = try Self.edgeCase("outside-full-depth-conventional", make: Self.outsideProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        try Self.checkWalls(tp, shape: p.shapes[0], r: Self.quarter.radius, allowance: 0, finish: 0.5)
        // The roughing climbs (clockwise round the part); the conventional finish runs the other way.
        let laps = try #require(tp.finishLaps)
        #expect(laps.loops.allSatisfy { $0.signedArea > 0 })
        // One full-depth lap.
        var finishZ = Set<Double>()
        tp.forEachMotion { s, m in
            if ProfileFinish.isOnFinishLoop(m, from: s, loops: laps.loops, tolerance: laps.tolerance) { finishZ.insert(m.end.z) }
        }
        #expect(finishZ == [-p.operations[0].kind.profileDepth!])
    }

    @Test func insideHoleIsFinishedOnTheRightSide() throws {
        let p = try Self.edgeCase("inside-hole-finish", make: Self.insideProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        try Self.checkWalls(tp, shape: p.shapes[0], r: Self.quarter.radius, allowance: 0, finish: 0.02.inch)
        // Inside the hole, the waste: every cut is within the hole, and the finishing loop runs clockwise (conventional).
        for run in Self.runs(tp) {
            for q in Self.points(run.moves) { #expect(q.xy.distance(to: Self.partCentre) < Self.holeRadius - Self.quarter.radius + 0.01) }
        }
        #expect(try #require(tp.finishLaps).loops.allSatisfy { $0.signedArea < 0 })
    }

    /// The allowance stacks: the finished wall at r + allowance, the roughing a finish allowance further.
    @Test func theProfileAllowanceStillApplies() throws {
        var p = Self.outsideProject()
        guard case var .profile(params) = p.operations[0].kind else { return }
        params.allowance = 0.3
        p.operations[0].kind = .profile(params)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        try Self.checkWalls(tp, shape: p.shapes[0], r: Self.quarter.radius, allowance: 0.3, finish: 0.5)
    }

    // MARK: Tabs

    static func tabsProject() -> Project {
        let part = partShape()
        var p = project("Tabs survive the finish", shapes: [part],
                        ops: [profile(31, name: "Cut out", shape: part, finish: ProfileFinishPass(allowance: 0.5),
                                      tabs: TabSettings(enabled: true, count: 5, width: 8, thickness: 4),
                                      leads: LeadSettings(kind: .arc, radius: 6.35))])
        p.stock.width = 150
        p.stock.height = 110
        p.shapes[0].position = Vec2(75, 55)
        return p
    }

    /// The finish's Z is at or above the tab top everywhere beside a stretch where the roughing lifted over a tab, and
    /// the part is still held there once the whole toolpath has run (the regression for a finish ignoring tabs).
    @Test func tabsSurviveTheFinish() throws {
        let p = try Self.edgeCase("tabs-survive-finish", make: Self.tabsProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        guard case let .profile(params) = p.operations[0].kind, let finish = params.finishPass else { Issue.record(); return }
        let tabZ = -params.depth.cutDepth + params.tabs.thickness
        // The roughing's stretches at tab height along its wall loop, as points 0.05 mm apart, less 0.1 mm at each end
        // (where the finish steps down beside the roughing's step down).
        var stretches: [[Vec2]] = []
        var current: [Vec2] = []
        func close() {
            var length = 0.0
            var along = [0.0]
            for (a, b) in zip(current, current.dropFirst()) { length += a.distance(to: b); along.append(length) }
            if length > 1 { stretches.append(zip(current, along).filter { $0.1 >= 0.1 && $0.1 <= length - 0.1 }.map(\.0)) }
            current = []
        }
        for run in Self.runs(tp) where !run.finish {
            for (s, m) in run.moves {
                let onTab = abs(s.z - tabZ) < 1e-6 && abs(m.end.z - tabZ) < 1e-6 && s.xy.distance(to: m.end.xy) > 1e-6
                    && abs(Self.wall(s.xy, p.shapes[0]) - (Self.quarter.radius + finish.allowance)) < 0.02
                if onTab {
                    if current.isEmpty { current.append(s.xy) }
                    current += Self.dense(s, m, step: 0.05).map(\.xy)
                } else if !current.isEmpty {
                    close()
                }
            }
            if !current.isEmpty { close() }
        }
        // Five tabs, lifted over on each pass that's deeper than them.
        #expect(stretches.count >= 5 && stretches.count % 5 == 0 && stretches.allSatisfy { !$0.isEmpty }, "\(stretches.map(\.count))")
        let tabPoints = stretches.flatMap { $0 }
        var checked = 0
        for run in Self.runs(tp) where run.finish {
            for q in Self.points(run.moves) where tabPoints.contains(where: { $0.distance(to: q.xy) <= finish.allowance + 0.005 }) {
                checked += 1
                #expect(q.z >= tabZ - 1e-6, "finish at \(q) cuts a tab")
            }
        }
        #expect(checked > 20)
        // In the simulated material, the strip only the finish cuts is still at tab height in the middle of each tab.
        let grid = Fixture.simulate([tp], stock: p.stock, cell: 0.1)
        for stretch in stretches where !stretch.isEmpty {
            let mid = stretch[stretch.count / 2]
            let w = Self.outline(p.shapes[0]).closestPoint(to: mid).point
            let strip = w + (mid - w).normalized * (finish.allowance / 2)
            #expect(CutFixture.height(grid, strip) >= tabZ - 0.05, "tab strip at \(strip) cut to \(CutFixture.height(grid, strip))")
        }
    }

    @Test func tabsAreMappedFromTheFinishedWallOntoEachLoop() {
        // A square run the other way and offset 1 mm: each tab lands on the same stretch of wall.
        let inner = Polyline([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)], closed: true)
        let outer = Polyline([Vec2(-1, 50), Vec2(-1, -1), Vec2(101, -1), Vec2(101, 101), Vec2(-1, 101)], closed: true).reversed
        let plan = TabPlan(intervals: [(40, 60), (240, 260)], length: 400, z: -3)
        let mapped = TabPlan.mapped(plan, from: inner, onto: outer)
        let walker = LoopWalker(outer)
        #expect(mapped.intervals.count == 2)
        for (a, b) in mapped.intervals {
            let m = walker.point(at: (a + b) / 2)
            let onInner = inner.closestPoint(to: m)
            let s = LoopWalker(inner).cumulative[onInner.segment] + inner.points[onInner.segment].distance(to: onInner.point)
            #expect(plan.contains(s), "\(m)")
            #expect(abs(b - a - 20) < 0.01)
        }
    }

    // MARK: Entry

    static func leadInKerfProject() -> Project {
        let part = partShape()
        return project("Finish lead in the kerf", shapes: [part],
                       ops: [profile(41, name: "Cut out", shape: part, finish: ProfileFinishPass(),
                                     depth: DepthSettings(cutDepth: 12, passDepth: 3), leads: LeadSettings(kind: .arc, radius: 0.25.inch),
                                     tool: eighth)])
    }

    /// A 1/4" arc lead with a 1/8" bit is far wider than the kerf: the finish's lead is cut down to it, and its plunge
    /// and every move stay in it.
    @Test func finishLeadsStayInTheKerf() throws {
        let p = try Self.edgeCase("finish-lead-in-kerf", make: Self.leadInKerfProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        Self.checkInKerf(tp, shape: p.shapes[0], r: Self.eighth.radius, allowance: 0, finish: 0.02.inch)
        let finishing = Self.runs(tp).filter(\.finish)
        // It leads in (the first move after the plunge isn't on the loop) rather than plunging on the wall.
        let run = try #require(finishing.first)
        let firstCut = try #require(run.moves.first { $0.0.xy.distance(to: $0.1.end.xy) > 1e-6 })
        let laps = try #require(tp.finishLaps)
        #expect(!ProfileFinish.isOnFinishLoop(firstCut.1, from: firstCut.0, loops: laps.loops, tolerance: laps.tolerance))
        #expect(!tp.warnings.contains { $0.contains("entered on the wall") })
        // No ramp: it plunges, in the kerf.
        #expect(run.moves.contains { s, m in s.xy.distance(to: m.end.xy) < 1e-6 && m.end.z < s.z - 1 })
    }

    static func withoutLeadsProject() -> Project {
        let part = partShape()
        return project("Finish without leads", shapes: [part], ops: [profile(42, name: "Cut out", shape: part, finish: mmFinish)])
    }

    /// Without leads the finish still enters on a short automatic arc in the kerf, not on the wall.
    @Test func finishWithoutLeadsGetsAnAutomaticLead() throws {
        let p = try Self.edgeCase("finish-without-leads", make: Self.withoutLeadsProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        Self.checkInKerf(tp, shape: p.shapes[0], r: Self.quarter.radius, allowance: 0, finish: 0.5)
        #expect(!tp.warnings.contains { $0.contains("entered on the wall") }, "\(tp.warnings)")
        let run = try #require(Self.runs(tp).first { $0.finish })
        let laps = try #require(tp.finishLaps)
        let firstCut = try #require(run.moves.first { $0.0.xy.distance(to: $0.1.end.xy) > 1e-6 })
        #expect(!ProfileFinish.isOnFinishLoop(firstCut.1, from: firstCut.0, loops: laps.loops, tolerance: laps.tolerance))
    }

    @Test func leadsAreClippedToTheBand() {
        let arc = ProfileFinish.clipped(LeadSettings(kind: .arc, radius: 6.35, sweep: 90), size: 6.35, band: 0.45)
        #expect(arc.radius * (1 - cos(arc.sweep * .pi / 180)) <= 0.45 + 1e-9)
        let tiny = ProfileFinish.clipped(LeadSettings(kind: .arc, radius: 1, sweep: 90), size: 1, band: 0.01)
        #expect(tiny.sweep == 15 && tiny.radius * (1 - cos(15 * Double.pi / 180)) <= 0.01 + 1e-9)
        let line = ProfileFinish.clipped(LeadSettings(kind: .line, length: 6.35, angle: 45), size: 6.35, band: 0.45)
        #expect(line.length * sin(.pi / 4) <= 0.45 + 1e-9)
    }

    // MARK: Refusals and warnings

    static func allowanceProject(_ allowance: Double, name: String) -> Project {
        let part = partShape()
        return project(name, shapes: [part], ops: [profile(51, name: "Cut out", shape: part, finish: ProfileFinishPass(allowance: allowance))])
    }

    /// Over half the bit's width the finish would be a full-depth slot: refused, nothing cut.
    @Test func anAllowanceOverHalfTheBitIsRefused() throws {
        let p = try Self.edgeCase("allowance-too-large") { Self.allowanceProject(3.3, name: "Finish allowance over D/2") }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.isEmpty)
        #expect(tp.errors?.contains { $0.hasPrefix("Refused: the finish allowance") } == true, "\(tp.errors ?? [])")
        #expect(job.hasErrors)
        #expect(job.issues.contains { $0.severity == .error && $0.message.hasPrefix("Refused: the finish allowance") })
    }

    /// A toolpath's errors are the job's: `post` refuses to write the file (exit 1) unless forced, and says why.
    @Test func aToolpathErrorRefusesThePost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("finishing-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("refused.nativecam"), out = dir.appendingPathComponent("refused.tap")
        try Self.allowanceProject(3.3, name: "Finish allowance over D/2").encoded().write(to: project)
        let refused = try CommandLineTests.run(["post", project.path, "-o", out.path])
        #expect(refused.status == 1, "\(refused.output)")
        #expect(!FileManager.default.fileExists(atPath: out.path), "wrote the file anyway")
        #expect(refused.output.contains("[error] Cut out: Refused: the finish allowance"), "\(refused.output)")
        #expect(refused.output.contains("Not written: the job has 1 error."), "\(refused.output)")
    }

    /// Over a third of its width: cut, with a warning.
    @Test func anAllowanceOverAThirdOfTheBitWarns() throws {
        let p = try Self.edgeCase("allowance-heavy") { Self.allowanceProject(2.5, name: "Finish allowance over D/3") }
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty && tp.finishLaps != nil)
        #expect(tp.warnings.contains { $0.contains("more than a third of") }, "\(tp.warnings)")
        #expect(tp.errors == nil)
    }

    static func pastFlutesProject(_ depth: ProfileFinishPass.Depth) -> Project {
        let part = partShape()
        var short = quarter
        short.fluteLength = 12.7
        short.stickout = 30
        return project("Full-depth finish past the flutes", shapes: [part],
                       ops: [profile(52, name: "Cut out", shape: part, finish: ProfileFinishPass(allowance: 0.5, depth: depth),
                                     depth: DepthSettings(cutDepth: 0.75.inch + 0.5, passDepth: 6), tool: short)])
    }

    /// A full-depth lap past the flutes is refused, suggesting Each pass, which is then cut.
    @Test func fullDepthPastTheFlutesIsRefused() throws {
        let p = try Self.edgeCase("full-depth-past-flutes") { Self.pastFlutesProject(.fullDepth) }
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.isEmpty)
        #expect(tp.errors?.contains { $0.hasPrefix("Refused: a full-depth finishing pass") && $0.contains("Each pass") } == true, "\(tp.errors ?? [])")
        let each = try #require(CAMEngine.generate(Self.pastFlutesProject(.eachPass)).toolpaths.first)
        #expect(!each.isEmpty && each.finishLaps != nil)
    }

    static func onLineProject() -> Project {
        let part = partShape()
        return project("On-line finish skipped", shapes: [part], ops: [profile(53, name: "On the line", shape: part, side: .on, finish: mmFinish)])
    }

    @Test func anOnLineProfileSkipsTheFinish() throws {
        let p = try Self.edgeCase("on-line-finish-skipped", make: Self.onLineProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty && tp.finishLaps == nil)
        #expect(tp.warnings.contains { $0.hasPrefix("A finishing pass needs an inside or outside cut") })
        var plain = p
        guard case var .profile(params) = plain.operations[0].kind else { return }
        params.finishPass = nil
        plain.operations[0].kind = .profile(params)
        #expect(CAMEngine.generate(plain).toolpaths.first?.motions == tp.motions)
    }

    static func dovetailProject() -> Project {
        let part = partShape()
        var p = project("Dovetail finish skipped", shapes: [part],
                        ops: [profile(54, name: "Dovetail", shape: part, finish: mmFinish, depth: DepthSettings(cutDepth: 10),
                                      leads: LeadSettings(kind: .line, length: 12), tool: BitShapeTests.dovetail())])
        p.stock.width = 260
        p.stock.height = 220
        return p
    }

    @Test func anUndercutBitSkipsTheFinish() throws {
        let p = try Self.edgeCase("dovetail-finish-skipped", make: Self.dovetailProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.finishLaps == nil)
        #expect(tp.warnings.contains { $0.contains("can't step out to a finishing pass") }, "\(tp.warnings)")
    }

    static func finishOnlyHoleProject() -> Project {
        // The 1/4" bit (r 3.175) fits a 6.8 mm hole with its finish at r, but not the roughing 0.5 mm further in.
        let hole = DesignShape(id: id(3), name: "Small hole", kind: .circle(radius: 3.4), position: partCentre)
        return project("Finish-only inside loop", shapes: [hole],
                       ops: [profile(55, name: "Small hole", shape: hole, side: .inside, finish: mmFinish)])
    }

    /// An inside loop where only the finish's offset fits would be a full-width slot at full depth: refused for that loop.
    @Test func anInsideLoopOnlyTheFinishFitsIsRefused() throws {
        let p = try Self.edgeCase("inside-finish-only-refused", make: Self.finishOnlyHoleProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.isEmpty)
        #expect(tp.finishLaps == nil)
        #expect(tp.errors?.contains { $0.hasPrefix("Refused: the finishing pass on 1 loop") } == true, "\(tp.errors ?? [])")
    }

    static func tiledProject() -> Project {
        var p = outsideProject()
        p.stock.width = 30.inch
        p.stock.height = 30.inch
        p.shapes[0].position = Vec2(15.inch, 15.inch)
        p.tiling = TilingSettings(enabled: true, mode: .grid, tileWidth: 16.inch, tileHeight: 16.inch)
        return p
    }

    @Test func aTiledJobSkipsTheFinish() throws {
        let p = try Self.edgeCase("tiled-finish-skipped", make: Self.tiledProject)
        #expect(TileLayout(p) != nil)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.allSatisfy { $0.finishLaps == nil })
        #expect(job.issues.contains { $0.message.hasPrefix("Finishing passes aren't cut on tiled jobs yet") }, "\(job.issues.map(\.message))")
    }

    // MARK: Spring pass, feeds

    @Test func aSpringPassRunsTheLapTwiceAtTheFinishFeed() throws {
        let p = try Self.edgeCase("spring-pass", make: Self.springProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let feed = Self.quarter.cutting.feedRate * 0.8
        let laps = try #require(tp.finishLaps)
        var lapLength = 0.0
        for run in Self.runs(tp) where run.finish {
            for (s, m) in run.moves where ProfileFinish.isOnFinishLoop(m, from: s, loops: laps.loops, tolerance: laps.tolerance) {
                lapLength += m.length(from: s)
                #expect(abs(m.feed - feed) < 1e-6)
            }
        }
        let loopLength = laps.loops.reduce(0) { $0 + $1.length }
        #expect(lapLength > 2 * loopLength - 1 && lapLength < 2 * loopLength + 2 * Self.quarter.radius + 1, "\(lapLength) vs \(loopLength)")
        // The finish feed is written once at its lead-in (no tabs to step over).
        let gcode = String(decoding: GoldenPostTests.post(p), as: UTF8.self)
        let f = "F\(Int(feed.rounded()))"
        #expect(gcode.components(separatedBy: f).count - 1 == 1, "\(f)")
    }

    static func adjustFeedsProject() -> Project {
        var p = outsideProject()
        p.operations[0].adjustFeedsForLoad = true
        return p
    }

    /// Adjust Feeds for Load leaves the finish laps at their feed and keeps them out of its usual cut: the roughing is
    /// scheduled exactly as the same roughing without a finish.
    @Test func adjustFeedsForLoadLeavesTheFinishAlone() throws {
        let p = try Self.edgeCase("adjust-feeds-excludes-finish", make: Self.adjustFeedsProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let laps = try #require(tp.finishLaps)
        let loads = try #require(tp.loadFeeds)
        tp.forEachMotion { s, m in
            if ProfileFinish.isOnFinishLoop(m, from: s, loops: laps.loops, tolerance: laps.tolerance) {
                #expect(abs(m.feed - Self.quarter.cutting.feedRate) < 1e-6)
            }
        }
        var rough = p
        guard case var .profile(params) = rough.operations[0].kind else { return }
        params.allowance = 0.5
        params.finishPass = nil
        rough.operations[0].kind = .profile(params)
        let alone = try #require(CAMEngine.generate(rough).toolpaths.first?.loadFeeds)
        #expect(abs(loads.usualEngagement - alone.usualEngagement) < 1e-6, "\(loads.usualEngagement) vs \(alone.usualEngagement)")
    }

    @Test func aSlowFinishFeedIsCheckedForChipLoad() throws {
        var p = Self.outsideProject()
        guard case var .profile(params) = p.operations[0].kind else { return }
        params.finishPass?.feedPercent = 0.25
        p.operations[0].kind = .profile(params)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let laps = try #require(tp.finishLaps)
        var feeds = Set<Double>()
        tp.forEachMotion { s, m in
            if ProfileFinish.isOnFinishLoop(m, from: s, loops: laps.loops, tolerance: laps.tolerance) { feeds.insert(m.feed) }
        }
        #expect(feeds == [Self.quarter.cutting.feedRate * 0.25])
    }

    // MARK: Rest-aware start

    static func restProject() -> Project {
        let pocketShape = DesignShape(id: id(4), name: "Recess", kind: .rectangle(width: 160, height: 120, cornerRadius: 0), position: partCentre)
        let part = partShape()
        let pocket = CAMOperation(id: id(61), name: "Recess",
                                  kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 6))), shapeIDs: [pocketShape.id], tool: quarter)
        return project("Finish after a pocket", shapes: [pocketShape, part], ops: [
            pocket,
            profile(62, name: "Cut out", shape: part, finish: ProfileFinishPass(allowance: 0.5, depth: .eachPass),
                    depth: DepthSettings(cutDepth: 0.75.inch + 0.5, passDepth: 5)),
        ])
    }

    /// After a pocket has cleared the top 6 mm, the roughing and the finish both start below it, and the finish still
    /// reaches the cut depth.
    @Test func theFinishStartsWhereTheRoughingDoes() throws {
        let p = try Self.edgeCase("rest-start-depth-finish", make: Self.restProject)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first { $0.sourceOperationID == Self.id(62) })
        let laps = try #require(tp.finishLaps)
        var zs = Set<Double>()
        tp.forEachMotion { s, m in
            if ProfileFinish.isOnFinishLoop(m, from: s, loops: laps.loops, tolerance: laps.tolerance) { zs.insert((m.end.z * 1000).rounded() / 1000) }
        }
        #expect(zs.max()! <= -6 - 1 + 1e-6, "\(zs.sorted())")
        #expect(abs(zs.min()! + (0.75.inch + 0.5)) < 1e-3, "\(zs.sorted())")
    }

    // MARK: Templates and the part as other toolpaths see it

    @Test func templatesKeepTheFinishingPass() throws {
        var p = Self.tabsLeadsProject()
        p.shapes[0].layer = "Cut Out"
        p.operations[0].vectorSelection = .layers(["Cut Out"])
        let template = try ToolpathTemplateTests.roundTrip(ToolpathTemplate(name: "Finish", project: p))
        guard case let .profile(saved) = template.operations[0].kind, case let .profile(original) = p.operations[0].kind else {
            Issue.record(); return
        }
        #expect(saved.finishPass == original.finishPass)
        var blank = p
        blank.operations = []
        let applied = template.apply(to: blank, library: .starter)
        guard case let .profile(after) = applied.project.operations[0].kind else { Issue.record(); return }
        #expect(after.finishPass == original.finishPass)
    }

    /// Other toolpaths keep clear of the finished wall (the final allowance), and Nest Parts spaces by it: a finishing
    /// pass changes neither.
    @Test func otherToolpathsSeeTheFinishedWall() throws {
        let with = Self.tabsLeadsProject()
        var without = with
        guard case var .profile(params) = without.operations[0].kind else { return }
        params.finishPass = nil
        without.operations[0].kind = .profile(params)
        let a = ProtectedRegions(with, flattenTolerance: 0.01, arcTolerance: 0.005)
        let b = ProtectedRegions(without, flattenTolerance: 0.01, arcTolerance: 0.005)
        #expect(a.parts.map(\.band) == b.parts.map(\.band))
        #expect(!a.parts.isEmpty)
        #expect(NestJob.leadReach(with.operations[0]) == NestJob.leadReach(without.operations[0]))
    }
}

private extension OperationKind {
    var profileDepth: Double? { if case let .profile(p) = self { p.depth.cutDepth } else { nil } }
}
