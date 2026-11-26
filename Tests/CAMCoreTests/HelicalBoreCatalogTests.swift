import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for Drill ▸ Method ▸ Helical bore (#171): furniture-hardware holes bored with a 1/4" end mill,
/// with and without a finishing lap, on Avid's Mach4 default and on Grbl (mm), Masso, ShopBot (OpenSBP) and LinuxCNC; a
/// saved format-31 project with its decoded golden; and saved projects for each case handled
/// (`Fixtures/helical-bore`): holes too small to bore, a rotary job refused, a machine that posts no arcs.
struct HelicalBoreCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("helical-bore")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "171B0000-0000-4000-8000-%012d", n))! }

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    // MARK: Builders

    static let quarter = ToolLibrary.starter.tool(number: 1)!   // 1/4" upcut

    static func circle(_ n: Int, _ name: String, diameter: Double, at p: Vec2) -> DesignShape {
        DesignShape(id: id(n), name: name, kind: .circle(radius: diameter / 2), position: p)
    }

    static func drill(_ n: Int, _ name: String, shapes: [DesignShape], depth: Double, helix: HelixBore?, peck: Double = 0) -> CAMOperation {
        CAMOperation(id: id(n), name: name, kind: .drill(DrillParams(depth: depth, peckDepth: peck, helix: helix)),
                     shapeIDs: shapes.map(\.id), tool: quarter)
    }

    static let thickness = 0.75.inch

    static func project(_ name: String, shapes: [DesignShape], ops: [CAMOperation]) -> Project {
        let stock = Stock(width: 300, height: 200, thickness: thickness, materialName: "Baltic birch plywood", clearanceHeight: 10,
                          plungeHeight: 2, materialKind: .plywood)
        return Project(name: name, displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: shapes, operations: ops)
    }

    /// Furniture hardware with one 1/4" end mill: four 3/8" dowel holes 1/2" deep with a 1/4" shelf-pin hole plunged in
    /// the same toolpath, two 1/2" bolt holes through, and a 35 mm hinge cup 13 mm deep.
    static func hardware(_ helix: HelixBore, name: String = "Helical bore hardware") -> Project {
        let dowels = (0..<4).map { k in circle(1 + k, "Dowel hole", diameter: 0.375.inch, at: Vec2(40 + 30 * Double(k), 40)) }
        let pin = circle(5, "Shelf pin", diameter: 0.25.inch, at: Vec2(40, 80))
        let bolts = (0..<2).map { k in circle(6 + k, "Bolt hole", diameter: 0.5.inch, at: Vec2(200 + 40 * Double(k), 50)) }
        let cup = circle(8, "Hinge cup", diameter: 35, at: Vec2(150, 140))
        return project(name, shapes: dowels + [pin] + bolts + [cup], ops: [
            drill(11, "Dowel holes", shapes: dowels + [pin], depth: 0.5.inch, helix: helix, peck: 0.25.inch),
            drill(12, "Bolt holes", shapes: bolts, depth: thickness + 0.02.inch, helix: helix),
            drill(13, "Hinge cup", shapes: [cup], depth: 13, helix: helix),
        ])
    }

    static let climb = HelixBore()
    static let lap = HelixBore(direction: .conventional, finishAllowance: 0.1)

    /// The hardware's holes: the drawn ones, by toolpath.
    static func drawn(_ p: Project, _ tp: Toolpath) -> [(center: Vec2, diameter: Double)] {
        let op = p.operations.first { $0.id == tp.sourceOperationID }!
        return p.shapes(for: op).compactMap { s in
            if case let .circle(r) = s.kind { return (s.position, 2 * r) }
            return nil
        }
    }

    // MARK: Measuring

    /// Points along a move (lines too), at most `step` apart, with its start.
    static func points(_ s: Vec3, _ m: Motion, step: Double = 0.05) -> [Vec3] {
        guard !m.kind.isArc else { return [s] + m.samples(from: s, maxStep: step) }
        let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
        return (0...n).map { k in s + (m.end - s) * (Double(k) / Double(n)) }
    }

    /// The helix, laps and leads of one hole: the moves from its first one below the top to the feed to its centre.
    struct HoleRun {
        var center: Vec2
        var diameter: Double
        var moves: [(start: Vec3, motion: Motion)]
    }

    static func runs(_ tp: Toolpath, holes: [(center: Vec2, diameter: Double)]) -> [HoleRun] {
        var out: [HoleRun] = []
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            let hole = holes.min { $0.center.distance(to: m.end.xy) < $1.center.distance(to: m.end.xy) }!
            if let last = out.last, last.center == hole.center {
                out[out.count - 1].moves.append((s, m))
            } else {
                out.append(HoleRun(center: hole.center, diameter: hole.diameter, moves: [(s, m)]))
            }
        }
        return out
    }

    /// Checks every hole of a bored toolpath: nothing below the top leaves the hole; every arc is centred on it (or
    /// a finishing lead inside it), under 180° and turning `ccw`; the helix only goes down, at the pitch the rule gives;
    /// a full lap at depth on the last ring; deepest Z exactly the depth.
    static func checkBores(_ tp: Toolpath, _ p: Project, depth: Double, helix: HelixBore,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
        let tool = tp.tool, r = tool.radius
        let holes = drawn(p, tp)
        let bores = try #require(tp.bores, sourceLocation: sourceLocation)
        #expect(bores.count == holes.count, sourceLocation: sourceLocation)
        let deepest = tp.cuttingExtents?.min.z ?? 0
        #expect(abs(deepest + depth) < 1e-9, "\(deepest)", sourceLocation: sourceLocation)
        for run in runs(tp, holes: holes) {
            let reach = max(0, (run.diameter - tool.diameter) / 2)
            let bored = run.diameter > tool.diameter * HelixBore.plungeRatio
            // Nothing below the top strays past the hole's wall.
            for (s, m) in run.moves {
                for q in points(s, m) where q.z < -1e-9 {
                    #expect(q.xy.distance(to: run.center) <= (bored ? reach : 0) + 1e-6,
                            "\(q.xy.distance(to: run.center)) > \(reach) at \(q)", sourceLocation: sourceLocation)
                }
            }
            let arcs = run.moves.filter { $0.motion.kind.isArc }
            guard bored else {
                #expect(arcs.isEmpty, sourceLocation: sourceLocation)
                continue
            }
            #expect(!arcs.isEmpty, sourceLocation: sourceLocation)
            for (s, m) in arcs {
                #expect(m.kind == (helix.direction == .climb ? .arcCCW : .arcCW), sourceLocation: sourceLocation)
                #expect(abs(m.arcSweep(from: s)) < .pi / 2 + 1e-9 && abs(m.arcSweep(from: s)) > 1e-9, sourceLocation: sourceLocation)
                #expect(s.distance(to: m.end) > 1e-6, sourceLocation: sourceLocation)
                #expect(m.end.z <= s.z + 1e-12, "the helix only goes down", sourceLocation: sourceLocation)
            }
            // The rings: arcs centred on the hole, each ring's helix at its pitch, then a full lap at depth.
            let centred = arcs.filter { $0.motion.center.distance(to: run.center) < 1e-9 }
            var byRadius: [Double: [(start: Vec3, motion: Motion)]] = [:]
            for a in centred { byRadius[(a.start.xy.distance(to: run.center) * 1e6).rounded() / 1e6, default: []].append(a) }
            let allowance = min(helix.allowanceInUse, max(0, reach - 0.01))
            let expectedRings = BoreHelix.rings(reach - allowance, tool: tool).map { ($0 * 1e6).rounded() / 1e6 }
            let finishRing = allowance > 0 ? [(reach * 1e6).rounded() / 1e6] : []
            #expect(Set(byRadius.keys) == Set(expectedRings + finishRing), "\(byRadius.keys.sorted()) vs \(expectedRings)",
                    sourceLocation: sourceLocation)
            #expect(expectedRings.last.map { abs($0 - (reach - allowance)) < 1e-6 } == true, sourceLocation: sourceLocation)
            for (rho, moves) in byRadius {
                let down = moves.filter { $0.motion.end.z < $0.start.z - 1e-12 }
                let level = moves.filter { abs($0.motion.end.z - $0.start.z) < 1e-12 && abs($0.motion.end.z + depth) < 1e-9 }
                let lapSweep = level.reduce(0) { $0 + abs($1.motion.arcSweep(from: $1.start)) }
                #expect(abs(lapSweep - 2 * .pi) < 1e-6, "a full lap at depth on ring \(rho): \(lapSweep)", sourceLocation: sourceLocation)
                if finishRing.contains(rho) {
                    #expect(down.isEmpty, sourceLocation: sourceLocation)
                    continue
                }
                let sweep = down.reduce(0) { $0 + abs($1.motion.arcSweep(from: $1.start)) }
                let drop = down.reduce(0) { $0 + ($1.start.z - $1.motion.end.z) }
                #expect(abs(drop - depth) < 1e-9, sourceLocation: sourceLocation)
                let pitch = drop / sweep * 2 * .pi
                let rule = min(max(0.05, tool.cutting.stepdown), 2 * .pi * rho * tan(helix.rampInUse * .pi / 180))
                #expect(abs(pitch - rule) < 1e-6, "pitch \(pitch) vs \(rule)", sourceLocation: sourceLocation)
                #expect(pitch <= tool.cutting.stepdown + 1e-9, sourceLocation: sourceLocation)
                // Z falls linearly with the angle.
                for (s, m) in down {
                    let rate = (s.z - m.end.z) / abs(m.arcSweep(from: s))
                    #expect(abs(rate - pitch / (2 * .pi)) < 1e-6, sourceLocation: sourceLocation)
                }
                // Fed slowed for the small circle.
                let feed = tool.cutting.feedRate * FeedScheduler.insideArcFactor(pathRadius: rho, toolRadius: r)
                #expect(moves.allSatisfy { abs($0.motion.feed - max(1, feed)) < 1e-3 }, "\(rho) \(feed) \(Set(moves.map(\.motion.feed)))", sourceLocation: sourceLocation)
            }
            // Ends off the wall in the middle, at depth, then straight up.
            let last = try #require(run.moves.last, sourceLocation: sourceLocation)
            #expect(last.motion.kind == .feed && last.motion.end.xy.distance(to: run.center) < 1e-9 && abs(last.motion.end.z + depth) < 1e-9,
                    sourceLocation: sourceLocation)
        }
    }

    /// Posts `p` for its machine's controller, checks each file against the golden `name` and the export checks, and
    /// reads the arcs back: every one under 180°, none from a point to itself, none past its hole's wall.
    @discardableResult
    static func checkPost(_ p: Project, golden name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [PostedFile] {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        var files: [PostedFile]
        let dialect: Dialect
        if p.machine.isLegacyAvidMach4 {
            files = [PostedFile(suffix: nil, toolpaths: job.toolpaths, gcode: String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self))]
            dialect = .avidMach4
        } else {
            let post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date), sourceLocation: sourceLocation)
            switch post {
            case var g as GenericGCodePost:
                g.timeZone = TimeZone(identifier: "UTC")!
                files = g.files(job.toolpaths)
            case var o as OpenSBPPost:
                o.timeZone = TimeZone(identifier: "UTC")!
                files = o.files(job.toolpaths)
            default:
                files = post.files(job.toolpaths)
            }
            dialect = post.dialect
        }
        #expect(files.count == 1, sourceLocation: sourceLocation)
        for (i, f) in files.enumerated() {
            try GoldenPostTests.check(Data(f.gcode.utf8), golden: files.count == 1 ? name : "\(name)-\(i + 1)", sourceLocation: sourceLocation)
            let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: p, dialect: dialect).filter { $0.severity != .info }
            #expect(issues.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
            let program = try #require(GCodeCheck.program(f.gcode, project: p, dialect: dialect), sourceLocation: sourceLocation)
            var arcs = 0
            for (m, s) in GCodeCheck.writtenMoves(program, dialect: dialect).map({ ($0.motion, $0.start) }) where m.kind.isArc {
                arcs += 1
                #expect(abs(m.arcSweep(from: s)) < .pi - 1e-6, "an arc of \(abs(m.arcSweep(from: s)) * 180 / .pi)°", sourceLocation: sourceLocation)
                #expect(!s.xy.isApprox(m.end.xy, tolerance: 1e-6), sourceLocation: sourceLocation)
            }
            if dialect.language == .openSBP {
                // CG keeps Z constant: only the level laps are arcs, the helix is short lines.
                let all = GCodeCheck.writtenMoves(program, dialect: dialect)
                #expect(all.allSatisfy { !$0.motion.kind.isArc || abs($0.motion.end.z - $0.start.z) < 1e-6 }, sourceLocation: sourceLocation)
            }
            #expect(arcs > 0, sourceLocation: sourceLocation)
        }
        return files
    }

    static func on(_ family: ControllerFamily, units: LengthUnit, _ p: Project) -> Project {
        var q = p
        var machine = MachineProfile(model: .custom, outputUnits: units)
        machine.controller = ControllerProfile(family: family)
        q.machine = machine
        return q
    }

    // MARK: Goldens

    @Test func hardwareGeometry() throws {
        let p = try Self.edgeCase("hardware", make: { Self.hardware(Self.climb) })
        #expect(p.formatVersion == HelixBore.formatVersion)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        for tp in job.toolpaths {
            guard case let .drill(d) = p.operations.first(where: { $0.id == tp.sourceOperationID })!.kind else { continue }
            try Self.checkBores(tp, p, depth: d.depth, helix: Self.climb)
        }
        // The pin hole in the dowel toolpath is plunged, in pecks, and noted.
        let dowels = try #require(job.toolpaths.first { $0.name == "Dowel holes" })
        #expect(dowels.bores?.filter { !$0.bored }.count == 1)
        #expect(dowels.bores?.filter(\.bored).count == 4)
        #expect(job.issues.contains { $0.severity == .info && $0.message.contains("Shelf pin") && $0.message.contains("plunged") })
        // The hinge cup, 5.5 × the bit, in rings out from the middle; the dowel holes in one ring; the bolt holes, twice
        // the bit, in two, so the first bores a full disc and no slug is left in the through-hole.
        let cup = try #require(job.toolpaths.first { $0.name == "Hinge cup" }?.bores?.first)
        #expect(cup.rings == 4 && cup.bored && cup.counterClockwise)
        #expect(job.toolpaths.first { $0.name == "Dowel holes" }?.bores?.filter(\.bored).allSatisfy { $0.rings == 1 } == true)
        #expect(job.toolpaths.first { $0.name == "Bolt holes" }?.bores?.allSatisfy { $0.rings == 2 } == true)
        #expect(!job.issues.contains { $0.message.contains("larger than the tool") })
        // The circles are slowed so the wall sees the set feed: the chip-load check reads the wall's chip, not the centre's.
        #expect(!job.issues.contains { $0.severity == .warning }, "\(job.issues.filter { $0.severity == .warning }.map(\.message))")
    }

    @Test func hardwareMach4Golden() throws {
        let p = try Self.edgeCase("hardware", make: { Self.hardware(Self.climb) })
        let files = try Self.checkPost(p, golden: "helical-bore-hardware-mach4")
        // Climb: G3 throughout, Z falling down the helix.
        let g = files[0].gcode
        #expect(g.contains("G03") && !g.contains("G02"))
    }

    @Test func finishLapGeometryAndGolden() throws {
        let p = try Self.edgeCase("hardware-finish-lap", make: { Self.hardware(Self.lap, name: "Helical bore with finishing lap") })
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        for tp in job.toolpaths {
            guard case let .drill(d) = p.operations.first(where: { $0.id == tp.sourceOperationID })!.kind else { continue }
            try Self.checkBores(tp, p, depth: d.depth, helix: Self.lap)
            #expect(tp.bores?.filter(\.bored).allSatisfy { $0.finishLap && !$0.counterClockwise } == true)
            // The lap runs at the finishing feed, slowed for the wall's circle; the lead stays inside the hole.
            for hole in tp.bores ?? [] where hole.bored {
                let laps = tp.motions.filter { $0.kind.isArc && $0.center.distance(to: hole.center) < 1e-9 }
                #expect(laps.contains { abs($0.feed - tp.tool.cutting.feedRate * FeedScheduler.insideArcFactor(pathRadius: hole.reach,
                                                                                                       toolRadius: tp.tool.radius)) < 1e-9 })
            }
        }
        let files = try Self.checkPost(p, golden: "helical-bore-finish-lap-mach4")
        #expect(files[0].gcode.contains("G02") && !files[0].gcode.contains("G03"))
    }

    @Test func otherControllersGoldens() throws {
        let p = try Self.edgeCase("hardware", make: { Self.hardware(Self.climb) })
        try Self.checkPost(Self.on(.grbl, units: .mm, p), golden: "helical-bore-hardware-grbl-mm")
        try Self.checkPost(Self.on(.masso, units: .inch, p), golden: "helical-bore-hardware-masso")
        try Self.checkPost(Self.on(.openSBP, units: .inch, p), golden: "helical-bore-hardware-opensbp")
        try Self.checkPost(Self.on(.linuxCNC, units: .mm, p), golden: "helical-bore-hardware-linuxcnc-mm")
    }

    // MARK: Saved project

    static func savedProject() -> Project {
        var p = hardware(HelixBore(rampAngle: 3, direction: .climb, finishAllowance: 0.1, finishFeedPercent: 0.8), name: "Helical bore v31")
        p.notes = "Saved by the first build with Drill ▸ Method ▸ Helical bore, as format 31."
        return p
    }

    @Test func savedProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("helical-bore-v31", make: Self.savedProject)
        #expect(p.formatVersion == 31)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        #expect(Project.currentFormatVersion >= 31)
        try Self.checkPost(p, golden: "decoded-helical-bore-v31")
    }

    @Test func plungeMethodKeepsTheOldFormatAndOutput() throws {
        var p = Self.hardware(Self.climb)
        for k in p.operations.indices {
            if case var .drill(d) = p.operations[k].kind { d.helix = nil; p.operations[k].kind = .drill(d) }
        }
        #expect(p.formatVersion < 31)
        let json = String(decoding: try p.encoded(), as: UTF8.self)
        #expect(!json.contains("helix"))
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.allSatisfy { $0.bores == nil && !$0.motions.contains { $0.kind.isArc } })
        #expect(job.issues.contains { $0.message.contains("hole is larger than the tool") })
    }

    // MARK: Edge cases

    static func tooSmall() -> Project {
        let holes = [circle(1, "Bit-size hole", diameter: 0.25.inch, at: Vec2(40, 40)),
                     circle(2, "Undersize hole", diameter: 0.24.inch, at: Vec2(80, 40)),
                     circle(3, "Just-over hole", diameter: 0.26.inch, at: Vec2(120, 40))]
        return project("Helical bore, holes too small", shapes: holes, ops: [drill(11, "Small holes", shapes: holes, depth: 0.5.inch, helix: climb)])
    }

    @Test func holesTooSmallArePlunged() throws {
        let p = try Self.edgeCase("too-small", make: Self.tooSmall)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.bores?.count == 3 && tp.bores?.allSatisfy { !$0.bored && $0.reach == 0 } == true)
        #expect(!tp.motions.contains { $0.kind.isArc })
        try Self.checkBores(tp, p, depth: 0.5.inch, helix: Self.climb)
        let notes = job.issues.filter { $0.severity == .info }.map(\.message)
        #expect(notes.contains { $0.contains("Bit-size hole and Just-over hole") && $0.contains("1.05") })
        #expect(notes.contains { $0.contains("Undersize hole") && $0.contains("smaller than the bit") })
    }

    @Test func wideHoleNotesAPocketIsFaster() throws {
        let p = try Self.edgeCase("wide-hole-note") {
            let hole = Self.circle(1, "Cable grommet", diameter: 2.25.inch, at: Vec2(100, 100))
            return Self.project("Helical bore, a hole 9 × the bit", shapes: [hole],
                                ops: [Self.drill(11, "Grommet", shapes: [hole], depth: 0.25.inch, helix: Self.climb)])
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.issues.contains { $0.severity == .info && $0.message.contains("Cable grommet") && $0.message.contains("pocket") })
        let tp = try #require(job.toolpaths.first)
        try Self.checkBores(tp, p, depth: 0.25.inch, helix: Self.climb)
    }

    @Test func rotaryJobIsRefused() throws {
        let p = try Self.edgeCase("rotary-refused") {
            var p = Self.project("Helical bore on a rotary job", shapes: [Self.circle(1, "Hole", diameter: 0.5.inch, at: Vec2(50, 10))],
                                 ops: [Self.drill(11, "Bore", shapes: [Self.circle(1, "Hole", diameter: 0.5.inch, at: Vec2(50, 10))],
                                                  depth: 5, helix: Self.climb)])
            p.stock.rotary = RotaryStock(shape: .cylinder, diameter: 50, length: 300)
            p.machine.rotary = RotaryAxis(centerHeight: 4.inch)
            return p
        }
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .error && $0.message.contains("Helical boring isn't available on a rotary job") })
        #expect(job.toolpaths.allSatisfy { !$0.motions.contains { $0.kind.isArc } })
    }

    @Test func noArcsMachineBoresInLinesInsideTheHole() throws {
        let p = try Self.edgeCase("no-arcs") {
            var p = Self.hardware(Self.climb, name: "Helical bore, no arcs")
            p.machine.outputArcs = false
            return p
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        for tp in job.toolpaths {
            #expect(!tp.motions.contains { $0.kind.isArc })
            let holes = Self.drawn(p, tp)
            for run in Self.runs(tp, holes: holes) {
                let reach = run.diameter > tp.tool.diameter * HelixBore.plungeRatio ? (run.diameter - tp.tool.diameter) / 2 : 0
                for (s, m) in run.moves {
                    for q in Self.points(s, m) where q.z < -1e-9 { #expect(q.xy.distance(to: run.center) <= reach + 1e-6) }
                }
            }
        }
        let g = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!g.contains("G02") && !g.contains("G03"))
        let issues = GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4).filter { $0.severity != .info }
        #expect(issues.isEmpty, "\(issues.map(\.text))")
    }

    // MARK: Checks

    @Test func readBackCatchesAMoveOutsideTheHole() throws {
        let p = Self.hardware(Self.climb)
        var job = CAMEngine.generate(p)
        let g = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        // Told the holes are smaller than they're bored, the check refuses the file.
        for k in job.toolpaths.indices { job.toolpaths[k].bores = job.toolpaths[k].bores?.map { var h = $0; h.reach *= 0.9; return h } }
        let issues = GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.contains { $0.severity == .error && $0.message.contains("past the") })
    }

    @Test func readBackRefusesAHalfCircleArc() {
        let hole = BoredHole(center: .zero, diameter: 20, bored: true, counterClockwise: true, reach: 5)
        let half = Motion(kind: .arcCCW, end: Vec3(-5, 0, -1), center: .zero, feed: 100)
        #expect(GCodeCheck.boreProblem(half, start: Vec3(5, 0, -1), holes: [hole], top: 0, tolerance: 0.01)?.contains("180") == true)
        let full = Motion(kind: .arcCCW, end: Vec3(5, 0, -1), center: .zero, feed: 100)
        #expect(GCodeCheck.boreProblem(full, start: Vec3(5, 0, -1), holes: [hole], top: 0, tolerance: 0.01) != nil)
        let quarter = Motion(kind: .arcCCW, end: Vec3(0, 5, -1), center: .zero, feed: 100)
        #expect(GCodeCheck.boreProblem(quarter, start: Vec3(5, 0, -1), holes: [hole], top: 0, tolerance: 0.01) == nil)
    }

    @Test func protectedBandIsRoundTheBoredHole() throws {
        let p = Self.hardware(Self.climb)
        let op = try #require(p.operations.first { $0.name == "Hinge cup" })
        let loops = ProtectedRegions.band(op, shapes: p.shapes(for: op), stock: p.stock, flattenTolerance: 0.01, arcTolerance: 0.005)
        let centre = Vec2(150, 140)
        let inner = loops.map { l in l.points.map { $0.distance(to: centre) }.max() ?? 0 }.min() ?? 0
        #expect(abs(inner - 17.5) < 0.05, "\(inner)")
        var plunged = op
        if case var .drill(d) = plunged.kind { d.helix = nil; plunged.kind = .drill(d) }
        let old = ProtectedRegions.band(plunged, shapes: p.shapes(for: op), stock: p.stock, flattenTolerance: 0.01, arcTolerance: 0.005)
        let oldInner = old.map { l in l.points.map { $0.distance(to: centre) }.max() ?? 0 }.min() ?? 0
        #expect(abs(oldInner - Self.quarter.radius) < 0.05)
    }

    @Test func setupSheetStatesEachHole() throws {
        let p = Self.hardware(Self.climb)
        let job = CAMEngine.generate(p)
        let html = SetupSheet.html(project: p, job: job, gcodeFile: nil, checks: [], date: GoldenPostTests.date)
        #expect(html.contains("<h2>Holes</h2>"))
        #expect(html.contains("4 × Ø0.375 in helical bore at"))
        #expect(html.contains("climb (G3)"))
        #expect(html.contains("1 × Ø0.250 in plunged at the bit's size"))
        #expect(html.contains("in 4 rings"))
        let plain = SetupSheet.html(project: Project.demoSign(), job: CAMEngine.generate(Project.demoSign()), gcodeFile: nil, checks: [],
                                    date: GoldenPostTests.date)
        #expect(!plain.contains("<h2>Holes</h2>"))
    }

    @Test func tilingRegistrationHolesGoThroughTheSharedHelper() {
        let tool = Self.quarter, stock = Self.hardware(Self.climb).stock
        let a = TileSplitter.bore([Vec2(10, 10), Vec2(50, 10)], radius: 5, depth: 25, tool: tool, stock: stock)
        let b = BoreHelix.registrationHoles([Vec2(10, 10), Vec2(50, 10)], radius: 5, depth: 25, tool: tool, stock: stock,
                                            id: TileSplitter.registrationOperation)
        #expect(a == b && !a.isEmpty)
    }
}
