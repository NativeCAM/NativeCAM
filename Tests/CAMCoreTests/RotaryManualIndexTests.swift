import Foundation
import Testing
@testable import CAMCore

/// Indexed rotary on a machine that can't drive the axis (Grbl, FluidNC, Carbide Motion, Masso, or a hand-cranked
/// indexer): the post stops the program with the spindle off and the tool at safe Z, and says which angle to turn
/// the blank to, in place of each A move. Also the time each turn takes, driven or by hand.
struct RotaryManualIndexTests {
    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }
    func errors(_ p: Project) -> [String] { CAMEngine.generate(p).issues.filter { $0.severity == .error }.map(\.message) }

    /// The table leg on a Mach4 machine whose rotary is turned by hand.
    static func handLeg(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        RotaryIndexTests.leg { p in
            p.machine.rotary?.turnsByHand = true
            configure(&p)
        }
    }

    func avid(_ p: Project) -> (String, [Toolpath]) {
        let tps = CAMEngine.generate(p).toolpaths
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        return (post.post(tps), tps)
    }

    // MARK: Job checks

    @Test func controllersWithoutAnAAxisCanTurnByHand() {
        for family in [ControllerFamily.grbl, .fluidNC, .carbideMotion, .masso] {
            let driven = RotaryIndexTests.leg { p in
                p.machine.model = .custom
                p.machine.controller = ControllerProfile(family: family)
            }
            #expect(errors(driven).contains { $0.contains("has no A axis") }, "\(family)")
            var byHand = driven
            byHand.machine.rotary?.turnsByHand = true
            // Tools split into files on Grbl, which is a note, not an error.
            #expect(errors(byHand).isEmpty, "\(family): \(errors(byHand))")
            #expect(CAMEngine.generate(byHand).issues.contains { $0.message.contains("turned by hand") })
        }
        // The letter doesn't matter when nothing is driven.
        let lettered = errors(Self.handLeg { $0.machine.rotary?.letter = .b })
        #expect(lettered.isEmpty, "\(lettered)")
        // A stop has to be able to say which angle: RichAuto files carry no comments, and ShopBot's aren't written yet.
        let richAuto = Self.handLeg { p in p.machine.model = .custom; p.machine.controller = ControllerProfile(family: .richAuto) }
        #expect(errors(richAuto).contains { $0.contains("carry no comments") })
        let shopBot = Self.handLeg { p in p.machine.model = .custom; p.machine.controller = ControllerProfile(family: .openSBP) }
        #expect(errors(shopBot).contains { $0.contains("by hand in ShopBot") })
    }

    @Test func theMachineSummarySaysHowTheBlankTurns() {
        var grbl = MachineProfile(model: .custom)
        grbl.controller = ControllerProfile(family: .grbl)
        grbl.rotary = RotaryAxis()
        #expect(grbl.summary.contains { $0.contains("Turn on Turn by hand") })
        grbl.rotary?.turnsByHand = true
        #expect(grbl.summary.contains { $0.contains("turned by hand") })
        var avid = MachineProfile()
        avid.rotary = RotaryAxis()
        #expect(avid.summary.contains { $0.contains("G0 A moves") })
        #expect(!MachineProfile().summary.contains { $0.contains("Rotary") })
    }

    @Test func turningByHandIsFormatFourOnRotaryStock() throws {
        var p = RotaryIndexTests.leg()
        p.machine.rotary?.turnSpeed = 7200
        // A turn speed only changes estimates, so older builds can still open the file.
        #expect(p.formatVersion == 3)
        p.machine.rotary?.turnsByHand = true
        #expect(p.formatVersion == 4)
        #expect(try Project.decode(p.encoded()) == p)
        // Off is stored as nil, so a file saved before the setting existed keeps its bytes.
        p.machine.rotary?.turnsByHand = false
        #expect(p.machine.rotary?.manualIndexing == nil)
        #expect(try !String(decoding: p.encoded(), as: UTF8.self).contains("manualIndexing"))
        // A flat job posts nothing rotary, so a hand-turned indexer on the machine doesn't raise its format.
        var flat = Project.demoSign()
        flat.machine.rotary = RotaryAxis(manualIndexing: true)
        #expect(flat.formatVersion == 2)
    }

    // MARK: Posts

    @Test func eachTurnIsAStopWithTheSpindleOffAtSafeZ() throws {
        let p = Self.handLeg()
        let (g, tps) = avid(p)
        let lines = g.components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.hasPrefix("G00 A") })
        let stops = lines.indices.filter { lines[$0] == "M00" }
        #expect(stops.map { lines[$0 - 1] } == [
            "(Turn the blank to 0deg, then Cycle Start)", "(Turn the blank to 90deg, then Cycle Start)",
            "(Turn the blank to 180deg, then Cycle Start)", "(Turn the blank to 270deg, then Cycle Start)",
            "(Turn the blank to 0deg, then Cycle Start)", "(Turn the blank to 90deg, then Cycle Start)",
            "(Turn the blank to 180deg, then Cycle Start)", "(Turn the blank to 270deg, then Cycle Start)",
        ])
        let safe = String(format: "G00 Z%.4f", (p.stock.thickness + p.stock.clearanceHeight) / 25.4)
        for i in stops {
            // Mid-job turns stop the spindle at safe Z first, where each toolpath ends (the first stop, and the one
            // after the tool change, find it stopped already); the spindle starts again after.
            if lines[i - 2] == "M05" { #expect(lines[i - 3] == safe) }
            #expect(lines[i + 1].hasPrefix("S") && lines[i + 1].hasSuffix(" M03"), "\(lines[i + 1])")
        }
        #expect(stops.filter { lines[$0 - 2] == "M05" }.count == 6)
        #expect(g.contains("(TURN THE BLANK BY HAND AT EACH STOP {M0})"))
        #expect(g.contains("(Angles count up as the top of the blank rolls toward -Y)"))
        let issues = GCodeCheck.run(g, toolpaths: tps, project: p, dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    @Test func aReversedIndexerAsksForItsOwnReading() {
        let (g, _) = avid(Self.handLeg { $0.machine.rotary?.reversed = true })
        #expect(g.contains("(Turn the blank to 270deg, then Cycle Start)\r\nM00"))
        #expect(g.contains("(Angles count up as the top of the blank rolls toward +Y)"))
        #expect(!g.contains("-90"))
    }

    @Test func aTurnSpeedChangesNothingInTheFile() {
        let (before, _) = avid(RotaryIndexTests.leg())
        let (after, _) = avid(RotaryIndexTests.leg { $0.machine.rotary?.turnSpeed = 7200 })
        #expect(before == after)
    }

    /// A Grbl machine turned by hand: stock Grbl can't stop on M6, so each tool gets its own file, and each file
    /// starts by asking for the angle rather than assuming where the last one left the blank.
    @Test func grblTurnedByHandGolden() throws {
        let (p, toolpaths) = GoldenPostTests.rotaryJob(blank: RotaryStock(shape: .cylinder, diameter: 50, length: 300),
                                                       slotAngles: [0, 180], holeAngles: [0, 90, 180, 270]) { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: .grbl)
            p.machine.outputUnits = .mm
            p.machine.spindleSpinUpDwell = 2
            p.machine.rotary?.turnsByHand = true
        }
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
        post.timeZone = TimeZone(identifier: "UTC")!
        let files = post.files(toolpaths)
        #expect(files.count == 2)
        for (i, f) in files.enumerated() {
            try GoldenPostTests.check(Data(f.gcode.utf8), golden: "grbl-rotary-by-hand-\(i + 1)")
            let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: p, dialect: post.dialect)
            #expect(problems(issues).isEmpty, "file \(i + 1): \(problems(issues))")
            #expect(!f.gcode.contains("A0.000") && !f.gcode.contains(" A1"))
        }
        // The second file starts at the hole's first angle, with a stop of its own.
        #expect(files[1].gcode.contains("(Turn the blank to 0deg, then resume)\nM0\n"))
        #expect(files[0].gcode.components(separatedBy: "\nM0\n").count - 1 == 2)
        #expect(files[1].gcode.components(separatedBy: "\nM0\n").count - 1 == 4)
    }

    // MARK: Export checks

    @Test func readBackFollowsTheStops() throws {
        let p = Self.handLeg()
        let (g, tps) = avid(p)
        func check(_ lines: [String]) -> String {
            problems(GCodeCheck.run(lines.joined(separator: "\r\n"), toolpaths: tps, project: p, dialect: .avidMach4)).joined(separator: "\n")
        }
        // A missing stop leaves the 90° face cut at 0°.
        var lines = g.components(separatedBy: "\r\n")
        let i = try #require(lines.firstIndex(of: "(Turn the blank to 90deg, then Cycle Start)"))
        lines.removeSubrange(i...(i + 1))
        #expect(check(lines).contains("Cuts with the blank turned to 0°, where “Mortise @ 90°” needs it at 90°."), "\(check(lines))")
        // So does a stop that asks for the wrong angle.
        var wrong = g.components(separatedBy: "\r\n")
        wrong[i] = "(Turn the blank to 45deg, then Cycle Start)"
        #expect(check(wrong).contains("turned to 45°"))
        // Moves before any stop asks for an angle aren't trusted either.
        var none = g.components(separatedBy: "\r\n")
        let first = try #require(none.firstIndex(of: "(Turn the blank to 0deg, then Cycle Start)"))
        none.removeSubrange(first...(first + 1))
        #expect(check(none).contains("before any stop asks for the blank to be turned"))
    }

    @Test func aTurnWithTheSpindleRunningOrTheToolDownIsAnError() throws {
        let p = Self.handLeg()
        let (g, _) = avid(p)
        let lines = g.components(separatedBy: "\r\n")
        let stop = try #require(lines.firstIndex(of: "(Turn the blank to 90deg, then Cycle Start)"))
        #expect(lines[stop - 1] == "M05")
        var running = lines
        running.remove(at: stop - 1)
        #expect(problems(GCodeCheck.lint(running.joined(separator: "\r\n"), project: p, dialect: .avidMach4)).joined()
            .contains("with the spindle running"))
        var low = lines
        low.insert("G00 Z0.5000", at: stop - 1)
        #expect(problems(GCodeCheck.lint(low.joined(separator: "\r\n"), project: p, dialect: .avidMach4)).joined()
            .contains("below safe Z"))
    }

    @Test func setupSheetListsEachTurn() {
        let p = Self.handLeg()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p))
        #expect(html.contains("Turned by hand. The program stops with the spindle off"))
        #expect(html.contains("The program stops: turn the blank to 90° by hand, then press Cycle Start."))
        #expect(html.components(separatedBy: "The program stops: turn the blank").count - 1 == 8)
        // A driven axis has no such steps.
        let driven = SetupSheet.html(project: RotaryIndexTests.leg(), job: CAMEngine.generate(RotaryIndexTests.leg()))
        #expect(!driven.contains("The program stops") && driven.contains("Turns on A between faces"))
    }

    /// A project as format 4 first saved it: the carved table leg (V-carve and its clearing at every face) on a Mach4
    /// machine whose rotary is turned by hand, with a turn speed set. It must keep loading and posting the same bytes.
    @Test func handTurnedLegSavedByFormatFourStillDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("rotary-by-hand-v4") {
            RotaryIndexTests.carvedLeg { p in
                p.machine.rotary?.turnsByHand = true
                p.machine.rotary?.turnSpeed = 3600
            }
        }
        #expect(p.formatVersion == 4)
        #expect(p.machine.rotary == RotaryAxis(centerHeight: 4.inch, manualIndexing: true, turnSpeed: 3600))
        #expect(p.operations.map(\.name) == ["Mortise", "Pin holes", "Panel"])
        let data = GoldenPostTests.post(p)
        try GoldenPostTests.check(data, golden: "decoded-rotary-by-hand-v4")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: CAMEngine.generate(p).toolpaths, project: p,
                                    dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    // MARK: Turn times

    @Test func theEstimateCountsEachTurn() throws {
        func total(_ configure: @escaping (inout Project) -> Void) throws -> Double {
            try #require(CAMEngine.generate(RotaryIndexTests.leg(configure)).estimate?.total)
        }
        // 0→90→180→270 on the mortise, 270 back to 0 and round again on the holes, then home: 1080° in all.
        let slow = try total { $0.machine.rotary?.turnSpeed = 3600 }
        let fast = try total { $0.machine.rotary?.turnSpeed = 7200 }
        #expect(abs((slow - fast) - (18 - 9)) < 1e-6, "\(slow - fast)")
        // Without a speed it assumes 90° a second, as the simulation does.
        let nominal = try total { _ in }
        #expect(abs((slow - nominal) - (18 - 12)) < 1e-6)
        // By hand, each of the seven turns that moves the blank allows 30 s, and the six that don't come with a tool
        // change spin the spindle up again; there's no turn home at the end.
        let dwell = 2.0
        let byHand = try total { p in p.machine.rotary?.turnsByHand = true; p.machine.spindleSpinUpDwell = dwell }
        let driven = try total { p in p.machine.spindleSpinUpDwell = dwell }
        #expect(abs((byHand - driven) - (7 * RotaryAxis.manualTurnSeconds + 6 * dwell - 12)) < 1e-3, "\(byHand - driven)")
        // Flat jobs don't change.
        var sign = Project.demoSign()
        let flat = CAMEngine.generate(sign).estimate?.total
        sign.machine.rotary = RotaryAxis(turnSpeed: 100)
        #expect(CAMEngine.generate(sign).estimate?.total == flat)
    }

    @Test func theSimulationTurnsAtTheMachinesSpeed() throws {
        let p = RotaryIndexTests.leg { $0.machine.rotary?.turnSpeed = 2700 }
        let job = CAMEngine.generate(p)
        let s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10_000, cellSize: 2,
                                  turnSpeed: p.machine.rotary?.drivenTurnSpeed)
        // 2700°/min is 45° a second, so a quarter turn takes 2 s.
        let first = try #require(s.timeline.steps.first { $0.turn != nil && $0.toolpathIndex == 1 })
        #expect(abs(first.duration - 2) < 1e-9)
        // A blank turned by hand turns at the nominal pace.
        #expect(RotaryAxis(manualIndexing: true, turnSpeed: 2700).drivenTurnSpeed == nil)
        let nominal = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10_000, cellSize: 2)
        let turn = try #require(nominal.timeline.steps.first { $0.turn != nil && $0.toolpathIndex == 1 })
        #expect(abs(turn.duration - 1) < 1e-9)
    }
}
