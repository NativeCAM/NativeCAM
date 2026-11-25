import Foundation
import Testing
@testable import CAMCore

/// The spoilboard surfacing program (`Surfacing`): goldens on the Avid Mach4 default and other controllers, the promises
/// checked by reading the program back (coverage, depth, rapids, the travel, the Z-zero line, the estimate), and the
/// edge cases in `Fixtures/surfacing/*.json`, one file per refusal, warning or clamp.
struct SurfacingTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let fixtures = GoldenPostTests.fixtures.appendingPathComponent("surfacing")

    static func program(_ machine: MachineProfile = MachineProfile(), _ configure: (inout Surfacing.Options) -> Void = { _ in }) throws
        -> Surfacing.Program {
        var options = Surfacing.Options.defaults(machine.outputUnits)
        configure(&options)
        return try Surfacing.program(machine: machine, options: options, date: GoldenPostTests.date, timeZone: utc)
    }

    static func controller(_ family: ControllerFamily, units: LengthUnit = .mm) -> MachineProfile {
        var m = MachineProfile(model: .custom, outputUnits: units)
        m.controller = ControllerProfile(family: family)
        return m
    }

    /// The golden cases: name, machine, options.
    static func goldens() -> [(String, MachineProfile, Surfacing.Options)] {
        func options(_ machine: MachineProfile, _ configure: (inout Surfacing.Options) -> Void) -> Surfacing.Options {
            var o = Surfacing.Options.defaults(machine.outputUnits)
            configure(&o)
            return o
        }
        let avid = MachineProfile(), grbl = controller(.grbl), shopBot = controller(.openSBP, units: .inch)
        return [
            ("surfacing-bed-pro6060-inch", avid, options(avid) { _ in }),
            ("surfacing-custom-along-y-inch", avid, options(avid) { $0.area = .custom(Vec2(24.inch, 36.inch)); $0.along = .y }),
            ("surfacing-two-passes-inch", avid, options(avid) { $0.area = .custom(Vec2(12.inch, 12.inch)); $0.passes = 2 }),
            ("surfacing-one-way-inch", avid, options(avid) { $0.area = .custom(Vec2(12.inch, 12.inch)); $0.direction = .oneWay; $0.stepover = 0.9 }),
            ("surfacing-grbl-mm", grbl, options(grbl) { $0.area = .custom(Vec2(300, 300)) }),
            ("surfacing-shopbot", shopBot, options(shopBot) { $0.area = .custom(Vec2(12.inch, 12.inch)) }),
        ]
    }

    // MARK: Goldens

    @Test func goldensMatchAndPassTheirChecks() throws {
        for (name, machine, options) in Self.goldens() {
            let program = try Surfacing.program(machine: machine, options: options, date: GoldenPostTests.date, timeZone: Self.utc)
            try GoldenPostTests.check(Data(program.gcode.utf8), golden: name)
            #expect(program.passedChecks, "\(name): \((program.issues + program.airIssues).map(\.text))")
            #expect(program.issues.allSatisfy { program.plan.warnings.contains($0.message) }, "\(name): \(program.issues.map(\.text))")
            #expect(program.airIssues.isEmpty, "\(name) air: \(program.airIssues.map(\.text))")
        }
    }

    // MARK: Promises

    @Test func everyGoldenKeepsItsPromises() throws {
        for (name, machine, options) in Self.goldens() {
            let program = try Surfacing.program(machine: machine, options: options, date: GoldenPostTests.date, timeZone: Self.utc)
            try Self.checkPromises(program, name: name)
        }
    }

    /// Reads the program back and checks it independently of `Surfacing.verify`.
    static func checkPromises(_ program: Surfacing.Program, name: String) throws {
        let first = program.gcode.components(separatedBy: .newlines)[0]
        #expect(first.contains("Z ZERO: TOP OF THE SPOILBOARD"), "\(name): \(first)")
        #expect(program.project.stock.zZero == .materialTop, "\(name)")
        let u = program.project.machine.outputUnits
        let read = program.dialect.language == .openSBP
            ? OpenSBPParser.parse(program.gcode, units: u)
            : try GCodeParser.parse(program.gcode, dwellUnit: program.dialect.dwell.parserUnit)
        let tol = 1e-3 + (u == .inch ? 0.0001.inch : 0.001)
        let depth = program.options.depth, total = depth * Double(program.options.passes)
        var minZ = Double.infinity
        var lo = Vec2(.infinity, .infinity), hi = Vec2(-.infinity, -.infinity)
        for seg in read.segments {
            for m in seg.motions where m.kind != .dwell {
                minZ = min(minZ, m.end.z)
                lo = Vec2(min(lo.x, m.end.x), min(lo.y, m.end.y))
                hi = Vec2(max(hi.x, m.end.x), max(hi.y, m.end.y))
                if m.kind == .rapid {
                    #expect(m.end.z >= program.options.clearance - tol, "\(name): G0 to Z \(m.end.z)")
                } else if m.end.z < -tol {
                    let k = (-m.end.z / depth).rounded()
                    #expect(abs(m.end.z + k * depth) <= tol && k >= 1, "\(name): cut at Z \(m.end.z)")
                }
            }
        }
        #expect(abs(minZ + total) <= tol, "\(name): min Z \(minZ), total \(total)")
        let travel = program.project.machine.travel
        #expect(hi.x - lo.x <= travel.x + tol && hi.y - lo.y <= travel.y + tol, "\(name): spans \(hi.x - lo.x) × \(hi.y - lo.y)")
        // The swept bit at the final depth covers every point of the area.
        try checkCoverage(program, name: name)
        // The estimate against a hand count of the moves at their feeds and the rapid rates.
        let hand = handTime(program)
        let estimate = CycleTimeEstimator.estimate(program.toolpaths, project: program.project)
        let moves = estimate.feedSeconds + estimate.rapidSeconds
        #expect(abs(moves / hand - 1) < 0.10, "\(name): estimate \(moves) s, hand \(hand) s")
        #expect(program.estimatedSeconds >= moves, "\(name)")
    }

    static func checkCoverage(_ program: Surfacing.Program, name: String) throws {
        let r = program.options.tool.diameter / 2
        let bottom = -program.options.depth * Double(program.options.passes)
        let last = try #require(program.toolpaths.last)
        var segments: [(Vec2, Vec2)] = []
        var p = last.start
        for m in last.motions {
            if m.kind == .feed, abs(m.end.z - bottom) < 1e-6, abs(p.z - bottom) < 1e-6 { segments.append((p.xy, m.end.xy)) }
            p = m.end
        }
        let a = program.plan.area
        var uncovered = 0
        let n = 80
        for i in 0...n {
            for j in 0...n {
                let q = Vec2(a.x * Double(i) / Double(n), a.y * Double(j) / Double(n))
                let d = segments.map { distance(q, $0.0, $0.1) }.min() ?? .infinity
                if d > r + 1e-6 { uncovered += 1 }
            }
        }
        #expect(uncovered == 0, "\(name): \(uncovered) grid points not covered")
    }

    static func distance(_ q: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = Vec2(b.x - a.x, b.y - a.y), aq = Vec2(q.x - a.x, q.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        let t = len2 > 0 ? max(0, min(1, (aq.x * ab.x + aq.y * ab.y) / len2)) : 0
        let c = Vec2(a.x + t * ab.x - q.x, a.y + t * ab.y - q.y)
        return (c.x * c.x + c.y * c.y).squareRoot()
    }

    /// Each move's length over its feed, and rapids at the machine's X/Y and Z rapid rates, seconds.
    static func handTime(_ program: Surfacing.Program) -> Double {
        let machine = program.project.machine
        var seconds = 0.0
        for tp in program.toolpaths {
            var p = tp.start
            for m in tp.motions {
                let d = p.distance(to: m.end)
                if m.kind == .rapid {
                    let xy = Vec2(m.end.x - p.x, m.end.y - p.y)
                    seconds += max((xy.x * xy.x + xy.y * xy.y).squareRoot() / machine.axisRapid.x, abs(m.end.z - p.z) / machine.axisRapid.z) * 60
                } else if m.kind == .feed {
                    seconds += d / m.feed * 60
                }
                p = m.end
            }
        }
        return seconds
    }

    /// The whole bed at the defaults, by hand: 99 lines of 61.375 in, 98 steps of 0.621 in and the 2 × 2.5 in ramp at
    /// 150 in/min, 0.5 in down at 20 in/min: about 41 min. The program says so in its header and its estimate.
    @Test func wholeBedTimeMatchesAHandCount() throws {
        let program = try Self.program()
        #expect(program.plan.lines.count == 99)
        let cut = (99 * 61.375 + 98 * (60.875 / 98) + 5) / 150 * 60 + 0.5 / 20 * 60
        let estimate = CycleTimeEstimator.estimate(program.toolpaths, project: program.project)
        #expect(abs((estimate.feedSeconds + estimate.rapidSeconds) / cut - 1) < 0.10, "\(estimate.feedSeconds) s vs \(cut) s")
        #expect(program.setup.contains("Runs about \(Surfacing.time(program.estimatedSeconds))."))
    }

    @Test func spinUpDwellIsAtLeastThreeSecondsWithoutChangingTheMachine() throws {
        var machine = MachineProfile()
        machine.spindleSpinUpDwell = 0
        let program = try Self.program(machine) { $0.area = .custom(Vec2(12.inch, 12.inch)) }
        #expect(program.gcode.contains("G04 P3.00"))
        #expect(machine.spindleSpinUpDwell == 0)
        machine.spindleSpinUpDwell = 5
        let longer = try Self.program(machine) { $0.area = .custom(Vec2(12.inch, 12.inch)) }
        #expect(longer.gcode.contains("G04 P5.00"))
        // The dwell comes before the first move down.
        let lines = program.gcode.components(separatedBy: "\r\n")
        let dwell = try #require(lines.firstIndex(of: "G04 P3.00"))
        let firstCut = try #require(lines.firstIndex { $0.hasPrefix("G01") })
        #expect(dwell < firstCut)
    }

    @Test func wholeBedRampsAndCustomPlungesPastTheEdge() throws {
        let bed = try Self.program()
        #expect(bed.plan.entry == .ramp)
        #expect(bed.plan.rampLength >= 2 * bed.options.tool.diameter - 1e-9)
        #expect(bed.plan.area == Vec2(61.375.inch - 0.5.inch, 61.375.inch - 0.5.inch))
        #expect(bed.setup[1].contains("jog to the front-left limit"))
        let custom = try Self.program { $0.area = .custom(Vec2(24.inch, 24.inch)) }
        #expect(custom.plan.entry == .offEdge)
        #expect(abs(custom.plan.overshoot - (0.625.inch + 0.125.inch)) < 1e-9)
        // The plunge is outside the area by more than the bit's radius.
        let plunge = try #require(custom.toolpaths[0].motions.first { $0.kind == .feed })
        #expect(plunge.end.x < -custom.options.tool.diameter / 2)
    }

    @Test func oneWayCutsEveryLineTheSameWay() throws {
        for along in Surfacing.Along.allCases {
            let program = try Self.program { $0.area = .custom(Vec2(12.inch, 12.inch)); $0.direction = .oneWay; $0.along = along }
            var p = program.toolpaths[0].start
            var directions = Set<Int>()
            for m in program.toolpaths[0].motions {
                if m.kind == .feed, abs(m.end.z - p.z) < 1e-9 {
                    let d = along == .x ? m.end.x - p.x : m.end.y - p.y
                    if abs(d) > 1 { directions.insert(d > 0 ? 1 : -1) }
                }
                p = m.end
            }
            #expect(directions.count == 1, "\(along)")
        }
    }

    @Test func starterLibraryHasTheSurfacingBit() {
        let bit = Surfacing.starterBit
        #expect(bit.shape == .surfacing)
        #expect(bit.number == 8)
        #expect(abs(bit.diameter - 1.25.inch) < 1e-9)
        #expect(Surfacing.bits(ToolLibrary.starter.tools).first?.id == bit.id)
    }

    @Test func airCutIsRaisedAndChecked() throws {
        let program = try Self.program { $0.area = .custom(Vec2(12.inch, 12.inch)) }
        #expect(program.airGCode.components(separatedBy: .newlines)[0].contains("Z ZERO: TOP OF THE SPOILBOARD"))
        #expect(program.airGCode.contains("AIR CUT: Z raised 1 in"))
        #expect(program.airIssues.isEmpty, "\(program.airIssues.map(\.text))")
        let lowest = program.airToolpaths.flatMap(\.motions).map(\.end.z).min() ?? 0
        #expect(abs(lowest - (1.inch - 0.02.inch)) < 1e-9)
    }

    // MARK: Edge cases

    struct Case: Decodable {
        struct ToolSpec: Decodable {
            var diameter: Double
            var fluteLength: Double
            var shape: String
            var feed: Double?
            var rpm: Double?
        }
        var note: String
        var project: String?
        var area: [Double]?
        var stepover: Double?
        var depth: Double?
        var passes: Int?
        var board: Double?
        var clampOvershoot: Bool?
        var tool: ToolSpec?
        var expect: String
        var text: String?
        var lines: Int?
        var spacing: Double?
        var entry: String?
        var ramp: Double?
    }

    @Test func edgeCaseFixtures() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 20)
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let c = try JSONDecoder().decode(Case.self, from: Data(contentsOf: file))
            var machine = MachineProfile()
            if let p = c.project {
                machine = try Project.decode(Data(contentsOf: Self.fixtures.appendingPathComponent(p + ".nativecam"))).machine
            }
            var options = Surfacing.Options.defaults(.inch)
            if let a = c.area { options.area = .custom(Vec2(a[0].inch, a[1].inch)) }
            if let s = c.stepover { options.stepover = s }
            if let d = c.depth { options.depth = d.inch }
            if let n = c.passes { options.passes = n }
            options.boardThickness = c.board?.inch
            options.clampOvershoot = c.clampOvershoot ?? false
            if let t = c.tool {
                var tool = Surfacing.starterBit
                tool.diameter = t.diameter.inch
                tool.fluteLength = t.fluteLength.inch
                tool.shape = try #require(ToolShape(rawValue: t.shape), "\(name)")
                if let f = t.feed { tool.cutting.feedRate = f.inch }
                if let r = t.rpm { tool.cutting.spindleRPM = r }
                options.tool = tool
            }
            switch c.expect {
            case "refused":
                do {
                    _ = try Surfacing.program(machine: machine, options: options)
                    Issue.record("\(name): not refused (\(c.note))")
                } catch let refused as Surfacing.Refused {
                    #expect(refused.reason.contains(c.text ?? ""), "\(name): \(refused.reason)")
                }
            case "warning", "ok":
                let program = try Surfacing.program(machine: machine, options: options)
                #expect(program.passedChecks, "\(name): \((program.issues + program.airIssues).map(\.text))")
                let warnings = program.issues.filter { $0.severity == .warning }.map(\.text)
                if c.expect == "warning" {
                    #expect(warnings.contains { $0.contains(c.text ?? "") }, "\(name): \(warnings)")
                } else {
                    #expect(warnings.isEmpty, "\(name): \(warnings)")
                }
                if let n = c.lines { #expect(program.plan.lines.count == n, "\(name): \(program.plan.lines.count) lines") }
                if let s = c.spacing { #expect(abs(program.plan.spacing - s.inch) < 0.0001.inch, "\(name): \(program.plan.spacing / 25.4)") }
                if c.lines != nil {
                    let across = program.options.along == .x ? program.plan.area.y : program.plan.area.x
                    #expect(abs((program.plan.lines.last ?? 0) - across) < 1e-9, "\(name): last line on the far edge")
                    #expect(program.plan.spacing <= program.options.stepover * program.options.tool.diameter + 1e-9)
                }
                if let e = c.entry { #expect(program.plan.entry.rawValue == e, "\(name)") }
                if let r = c.ramp { #expect(abs(program.plan.rampLength - r.inch) < 1e-9, "\(name)") }
                try Self.checkPromises(program, name: name)
            default:
                Issue.record("\(name): unknown expectation \(c.expect)")
            }
        }
    }

    /// Writes the project fixtures the edge cases use when goldens are being updated.
    @Test func projectFixtures() throws {
        guard GoldenPostTests.updating else { return }
        try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        var small = Project(name: "Desktop machine, 24 × 24 in")
        small.machine = MachineProfile(model: .custom, travel: Vec3(24.inch, 24.inch, 4.inch))
        try small.encoded().write(to: Self.fixtures.appendingPathComponent("small-machine.nativecam"))
        var none = Project(name: "PlanetCNC machine (no NativeCAM post)")
        none.machine = Self.controller(.planetCNC, units: .inch)
        try none.encoded().write(to: Self.fixtures.appendingPathComponent("no-post-machine.nativecam"))
    }
}

/// `nativecam-cli surface`, run as a user runs it.
struct SurfacingCommandLineTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func surfaceWritesTheProgramAndItsAirCut() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("bed.tap").path
        let bed = try CommandLineTests.run(["surface", "-o", out])
        #expect(bed.status == 0, "\(bed.output)")
        #expect(bed.output.contains("Avid Mach4 spoilboard surfacing"), "\(bed.output)")
        #expect(bed.output.contains("99 lines along X"), "\(bed.output)")
        #expect(FileManager.default.fileExists(atPath: out))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bed-air.tap").path))
        let text = try String(contentsOfFile: out, encoding: .ascii)
        #expect(text.hasPrefix("(Z ZERO: TOP OF THE SPOILBOARD"))

        let custom = try CommandLineTests.run(["surface", "--area", "24x36", "--along", "y", "--one-way", "--passes", "2",
                                               "--no-air-cut", "-o", dir.appendingPathComponent("board.tap").path])
        #expect(custom.status == 0, "\(custom.output)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("board-air.tap").path))

        let grbl = try CommandLineTests.run(["surface", "--controller", "grbl", "--units", "mm", "--area", "300x300",
                                             "-o", dir.appendingPathComponent("grbl").path])
        #expect(grbl.status == 0, "\(grbl.output)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("grbl.nc").path), "\(grbl.output)")

        let refused = try CommandLineTests.run(["surface", "--depth", "0.2", "-o", dir.appendingPathComponent("deep.tap").path])
        #expect(refused.status != 0)
        #expect(refused.output.contains("too deep"), "\(refused.output)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("deep.tap").path))

        let small = SurfacingTests.fixtures.appendingPathComponent("small-machine.nativecam").path
        let tooBig = try CommandLineTests.run(["surface", small, "--area", "36x36", "-o", dir.appendingPathComponent("big.tap").path])
        #expect(tooBig.status != 0)
        #expect(tooBig.output.contains("bigger than the machine's 24 × 24 in travel"), "\(tooBig.output)")
    }
}
