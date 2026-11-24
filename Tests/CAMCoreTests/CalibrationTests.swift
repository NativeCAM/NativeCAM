import Foundation
import Testing
@testable import CAMCore

/// The calibration programs (`Calibration`): goldens of a compact timing suite, the rotary check and the ladder, the
/// full-size suite's promises checked by reading it back, the refusals, and fitting times made up from known settings.
struct CalibrationTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let fixtures = GoldenPostTests.fixtures.appendingPathComponent("calibration")

    /// The settings the made-up times come from: slower than the PRO6060's class defaults, a tighter corner tolerance.
    static func known(_ machine: MachineProfile = MachineProfile()) -> MachineProfile {
        var m = machine
        m.accelerationXY = 30.inch
        m.accelerationZ = 15.inch
        m.rapidRateZ = 300.inch
        m.junctionDeviation = 0.02
        return m
    }

    /// Two-second sections in a 6 × 6 in window: every section type, in a golden small enough to read.
    static let compact = Calibration.TimingOptions(window: Vec2(6.inch, 6.inch), airHeight: 1.inch, sectionSeconds: 2)

    static func controller(_ family: ControllerFamily, units: LengthUnit = .mm) -> MachineProfile {
        var m = MachineProfile(model: .custom, outputUnits: units)
        m.controller = ControllerProfile(family: family)
        return m
    }

    /// Made-up times: each section's estimate on `truth`, off by up to ±1% the way a stopwatch would be.
    static func madeUpTimes(_ plan: Calibration.TimingPlan, truth: MachineProfile) -> [String: Double] {
        let built = Calibration.timingSections(plan: plan, machine: truth)
        var out: [String: Double] = [:]
        for (k, s) in built.sections.enumerated() {
            out[s.id] = (s.estimate * (1 + 0.01 * sin(Double(k) * 1.7)) * 10).rounded() / 10
        }
        return out
    }

    // MARK: Goldens

    @Test func compactTimingSuiteGolden() throws {
        let program = try Calibration.timing(machine: MachineProfile(), options: Self.compact, date: GoldenPostTests.date, timeZone: Self.utc)
        try GoldenPostTests.check(Data(program.gcode.utf8), golden: "calibration-timing-inch")
        #expect(program.issues.isEmpty, "\(program.issues.map(\.text))")
        let size = program.gcode.utf8.count
        #expect(size < 100_000, "\(size) bytes")
        let ids = program.sections.map(\.id)
        #expect(ids.count == 24)
        #expect(Set(ids).count == 24)
        let stops = program.gcode.components(separatedBy: "\r\n").filter { $0 == "M00" }.count
        #expect(stops == 24)
        #expect(program.gcode.contains("(MSG,1/24 Line at 100 in/min"))
        #expect(program.gcode.contains("G03 X"), "circles as arcs")
    }

    @Test func rotaryGoldens() throws {
        let cases: [(String, MachineProfile)] = [
            ("calibration-rotary-mach4", MachineProfile()),
            ("calibration-rotary-linuxcnc", Self.controller(.linuxCNC)),
            ("calibration-rotary-grblhal", Self.controller(.grblHAL, units: .inch)),
        ]
        for (name, machine) in cases {
            let program = try Calibration.rotary(machine: machine, date: GoldenPostTests.date, timeZone: Self.utc)
            try GoldenPostTests.check(Data(program.gcode.utf8), golden: name)
            #expect(program.issues.isEmpty, "\(name): \(program.issues.map(\.text))")
            #expect(program.gcode.contains("G93 G1 A360.000 F10.0000") || program.gcode.contains("G93 G01 A360.000 F10.0000"), "\(name)")
            #expect(program.sections.map(\.id) == ["rotary-g93", "rotary-360", "rotary-720"])
            let g93 = try #require(program.sections.first)
            #expect(g93.estimate == 6)
        }
    }

    @Test func ladderGolden() throws {
        let tool = try #require(ToolLibrary.starter.tool(number: 1))
        let options = Calibration.LadderOptions(tool: tool, material: .hardwood)
        let program = try Calibration.ladder(machine: MachineProfile(), options: options, date: GoldenPostTests.date, timeZone: Self.utc)
        try GoldenPostTests.check(Data(program.gcode.utf8), golden: "calibration-ladder-inch")
        #expect(program.issues.isEmpty, "\(program.issues.map(\.text))")
        // A real cut: the machine's own tool change (Avid's M6 macro and touch plate), not the air programs' pause.
        #expect(program.gcode.contains("T1M6"))
        #expect(!program.gcode.contains("M00"))
        // From below the chart to above it, the rungs far enough apart to tell apart.
        let charts = program.rungs.map(\.chart)
        #expect(charts.first == .below)
        #expect(charts.last == .above)
        #expect(charts.contains(.inside))
        let xs = program.rungs.map(\.x)
        let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= tool.diameter * 2 - 1e-9 })
        // The feeds step up with the chip load, all within the machine's highest feed.
        let feeds = program.rungs.map(\.feed)
        #expect(feeds == feeds.sorted())
        #expect(feeds.allSatisfy { $0 <= MachineProfile().maxFeedRate + 1e-9 })
    }

    @Test func ladderReadsTheChartWithoutChangingIt() throws {
        let tool = try #require(ToolLibrary.starter.tool(number: 1))
        let before = ChipLoad.reading(tool, material: .mdf, depth: tool.diameter / 2)
        let dovetail = ToolLibrary.template(for: .dovetail)
        for bit in [tool, dovetail] {
            let options = Calibration.LadderOptions(tool: bit, material: .mdf, stepRPM: true)
            let program = try Calibration.ladder(machine: MachineProfile(), options: options)
            #expect(program.issues.isEmpty, "\(bit.shape): \(program.issues.map(\.text))")
            let rpms = Set(program.rungs.map(\.rpm))
            #expect(rpms.count == 3, "three rows of spindle speeds")
            // Each rung's chip load is its feed over its speed and flutes, as written.
            for r in program.rungs {
                let chip = r.feed / (Double(bit.fluteCount) * r.rpm)
                #expect(abs(chip - r.chipLoad) < 1e-9)
            }
        }
        #expect(ChipLoad.reading(tool, material: .mdf, depth: tool.diameter / 2) == before)
        let reading = ChipLoad.reading(dovetail, material: .mdf, depth: dovetail.fluteLength)
        #expect(reading.chart == .routerBit)
    }

    // MARK: The full-size programs

    /// The program a user runs, checked by reading it back rather than byte for byte.
    @Test func fullTimingSuiteKeepsItsPromises() throws {
        for machine in [MachineProfile(), Self.controller(.linuxCNC), Self.controller(.grbl), Self.controller(.grblHAL, units: .inch)] {
            let program = try Calibration.timing(machine: machine)
            let label = program.dialect.name
            #expect(program.issues.isEmpty, "\(label): \(program.issues.map(\.text))")
            #expect(program.sections.count == 24)
            for s in program.sections {
                #expect(s.estimate >= 35 && s.estimate <= 70, "\(label) \(s.id): \(s.estimate) s")
                #expect(s.minimum <= s.estimate + 1e-6, "\(label) \(s.id)")
            }
            let plan = try #require(program.plan)
            let parsed = try GCodeParser.parse(program.gcode, dwellUnit: program.dialect.dwell.parserUnit)
            var lowest = Double.infinity, xs = [Double](), ys = [Double]()
            for seg in parsed.segments {
                for m in seg.motions where m.kind != .dwell {
                    lowest = min(lowest, m.end.z)
                    xs.append(m.end.x)
                    ys.append(m.end.y)
                }
            }
            let tol = 0.01
            #expect(lowest >= plan.airHeight - tol, "\(label): \(lowest)")
            #expect(plan.airHeight >= Calibration.minimumAirHeight)
            #expect((xs.min() ?? 0) >= -tol)
            #expect((xs.max() ?? 0) <= plan.window.x + tol)
            #expect((ys.min() ?? 0) >= -tol)
            #expect((ys.max() ?? 0) <= plan.window.y + tol)
            #expect(parsed.pauses.count == 24, "\(label): a stop before each section")
            // The header says where to zero and to keep the bit clear.
            let setup = program.setup.joined(separator: " ")
            #expect(setup.contains("zero Z on the work"))
            #expect(setup.contains("keep the bit clear"))
            #expect(program.gcode.hasPrefix("(NATIVECAM TIMING SUITE"))
        }
    }

    @Test func applyingAFitDoesNotChangeTheProgram() throws {
        let plain = try Calibration.timingPlan(machine: MachineProfile(), options: .defaults(.inch))
        let fitted = try Calibration.timingPlan(machine: Self.known(), options: .defaults(.inch))
        #expect(plain == fitted)
    }

    @Test func millimetreSuiteUsesMetricSizes() throws {
        let program = try Calibration.timing(machine: Self.controller(.linuxCNC))
        let plan = try #require(program.plan)
        #expect(plan.window == Vec2(600, 600))
        #expect(plan.airHeight == 25)
        #expect(program.sections.contains { $0.name == "Arcs, radius 3 mm" })
    }

    // MARK: Refusals

    @Test func neverBelowTheAirHeight() {
        var options = Calibration.TimingOptions.defaults(.mm)
        options.airHeight = 20
        #expect(throws: Calibration.Refused.self) { try Calibration.timing(machine: MachineProfile(), options: options) }
        options.airHeight = 25
        #expect(throws: Never.self) { _ = try Calibration.timingPlan(machine: MachineProfile(), options: options) }
    }

    @Test func windowBiggerThanTheMachineIsRefused() throws {
        let project = try Project.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("small-machine.nativecam")))
        #expect(project.machine.travel.x < 24.inch)
        do {
            _ = try Calibration.timing(machine: project.machine)
            Issue.record("A 24 × 24 in window on a smaller machine was accepted")
        } catch let r as Calibration.Refused {
            #expect(r.reason.contains("bigger than the machine's"), "\(r.reason)")
        }
        let fits = Calibration.TimingOptions(window: Vec2(10.inch, 10.inch), airHeight: 1.inch)
        let program = try Calibration.timing(machine: project.machine, options: fits)
        #expect(program.issues.isEmpty, "\(program.issues.map(\.text))")
    }

    @Test func rotaryCheckIsRefusedOnGrbl() throws {
        let project = try Project.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("grbl-machine.nativecam")))
        #expect(project.machine.controller?.family == .grbl)
        let reason = try #require(Calibration.rotaryRefusal(project.machine))
        #expect(reason.reason.contains("Grbl can't drive a rotary axis"), "\(reason.reason)")
        #expect(throws: Calibration.Refused.self) { try Calibration.rotary(machine: project.machine) }
        for family in [ControllerFamily.fluidNC, .masso, .centroid, .buildbotics, .openSBP, .richAuto] {
            #expect(Calibration.rotaryRefusal(Self.controller(family)) != nil, "\(family.label)")
        }
        var byHand = MachineProfile()
        byHand.rotary = RotaryAxis(manualIndexing: true)
        #expect(Calibration.rotaryRefusal(byHand)?.reason.contains("by hand") == true)
    }

    @Test func ladderRefusesBitsItCannotTest() throws {
        let vBit = try #require(ToolLibrary.starter.tools.first { $0.shape == .vBit })
        #expect(throws: Calibration.Refused.self) {
            try Calibration.ladder(machine: MachineProfile(), options: .init(tool: vBit, material: .plywood))
        }
        let form = ToolLibrary.template(for: .form)
        #expect(Calibration.ladderRefusal(.init(tool: form, material: .plywood), machine: MachineProfile())?.reason.contains("edge") == true)
    }

    // MARK: Fitting

    @Test func fitRecoversKnownSettings() throws {
        let plan = try Calibration.timingPlan(machine: MachineProfile(), options: .defaults(.inch))
        let measured = Self.madeUpTimes(plan, truth: Self.known())
        let times = Calibration.Times(kind: .timing, controller: plan.controller, plan: plan, measured: measured)
        let fit = try Calibration.fit([times], machine: MachineProfile())
        let truth = Self.known()
        let wanted: [MachineProfile.Field: Double] = [
            .accelerationXY: truth.axisAcceleration.x, .accelerationZ: truth.axisAcceleration.z,
            .rapidRateZ: truth.axisRapid.z, .junctionDeviation: truth.cornerDeviation,
        ]
        for v in fit.values {
            let want = try #require(wanted[v.field])
            #expect(v.determined, "\(v.label)")
            #expect(abs(v.after / want - 1) < 0.05, "\(v.label): \(v.after) for \(want)")
        }
        let verdict = try #require(fit.fChange)
        #expect(verdict.passed, "\(verdict.text)")
    }

    /// The times fixture: the full-size suite for Avid Mach4 in inches, timed (made up) on `known()`.
    static func fixtureTimes(editing: (inout [String: Double]) -> Void = { _ in }) throws -> String {
        let program = try Calibration.timing(machine: MachineProfile())
        var measured = madeUpTimes(try #require(program.plan), truth: known())
        editing(&measured)
        return Calibration.timesCSV(program, measured: measured)
    }

    @Test func timesFixtureFits() throws {
        let url = Self.fixtures.appendingPathComponent("times.csv")
        if GoldenPostTests.updating {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try Self.fixtureTimes().write(to: url, atomically: true, encoding: .utf8)
        }
        let times = try Calibration.readTimes(String(contentsOf: url, encoding: .utf8))
        #expect(times.kind == .timing)
        #expect(times.measured.count == 24)
        let fit = try Calibration.fit([times], machine: MachineProfile())
        let truth = Self.known()
        let after = Dictionary(uniqueKeysWithValues: fit.values.map { ($0.field, $0.after) })
        let xy = try #require(after[.accelerationXY]), z = try #require(after[.accelerationZ])
        let rapid = try #require(after[.rapidRateZ]), deviation = try #require(after[.junctionDeviation])
        #expect(abs(xy / truth.axisAcceleration.x - 1) < 0.05)
        #expect(abs(z / truth.axisAcceleration.z - 1) < 0.05)
        #expect(abs(rapid / truth.axisRapid.z - 1) < 0.05)
        #expect(abs(deviation / truth.cornerDeviation - 1) < 0.05)
        // Every fitted section within a few percent afterwards.
        let worst = fit.rows.filter(\.fitted).compactMap(\.errorAfter).map(abs).max() ?? 1
        #expect(worst < 0.03, "\(worst)")
        #expect(fit.fChange?.passed == true)
    }

    @Test func unfittableTimesAreRefused() throws {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent("unfittable-times.csv"), encoding: .utf8)
        let times = try Calibration.readTimes(text)
        do {
            _ = try Calibration.fit([times], machine: MachineProfile())
            Issue.record("Unfittable times were fitted")
        } catch let r as Calibration.Refused {
            #expect(r.reason.contains("faster than its moves allow"), "\(r.reason)")
        }
        // Nonsense of other kinds.
        let plan = try #require(times.plan)
        var measured = Self.madeUpTimes(plan, truth: Self.known())
        measured["line-2"] = 900
        #expect(throws: Calibration.Refused.self) {
            try Calibration.fit([Calibration.Times(kind: .timing, controller: plan.controller, plan: plan, measured: measured)], machine: MachineProfile())
        }
        measured = Self.madeUpTimes(plan, truth: Self.known())
        measured["line-1"] = (measured["line-1"] ?? 0) * 1.6
        do {
            _ = try Calibration.fit([Calibration.Times(kind: .timing, controller: plan.controller, plan: plan, measured: measured)], machine: MachineProfile())
            Issue.record("A section 60% slower than the rest of its times was fitted")
        } catch let r as Calibration.Refused {
            #expect(r.reason.contains("can't be fitted"), "\(r.reason)")
        }
        #expect(throws: Calibration.Refused.self) { try Calibration.readTimes("program,timing\nnot,a,times,file\n") }
        // Times for another controller's program.
        let grbl = Calibration.Times(kind: .timing, controller: "grbl", plan: plan, measured: measured)
        #expect(throws: Calibration.Refused.self) { try Calibration.fit([grbl], machine: MachineProfile()) }
    }

    @Test func fChangeVerdictFailsWhenTheChangesSlowTheMachine() throws {
        let plan = try Calibration.timingPlan(machine: MachineProfile(), options: .defaults(.inch))
        var measured = Self.madeUpTimes(plan, truth: Self.known())
        measured["fchange-alternating"] = (measured["fchange-single"] ?? 0) * 1.15
        let fit = try Calibration.fit([Calibration.Times(kind: .timing, controller: plan.controller, plan: plan, measured: measured)],
                                      machine: MachineProfile())
        let verdict = try #require(fit.fChange)
        #expect(!verdict.passed)
        #expect(verdict.text.contains("slows at each change of F"), "\(verdict.text)")
    }

    @Test func rotaryFitAndG93Verdict() throws {
        var machine = MachineProfile()
        machine.rotary = RotaryAxis()
        let program = try Calibration.rotary(machine: machine)
        // A 60°/s axis (3600°/min): 6 s and 12 s for the turns, and G93 on time.
        let times = Calibration.Times(program, measured: ["rotary-g93": 6.1, "rotary-360": 6.0, "rotary-720": 12.1])
        let csv = Calibration.timesCSV(program, measured: times.measured)
        let read = try Calibration.readTimes(csv)
        #expect(read.measured == times.measured)
        let fit = try Calibration.fit([read], machine: machine)
        let speed = try #require(fit.values.first { $0.field == .turnSpeed })
        #expect(speed.determined)
        #expect(abs(speed.after / 3600 - 1) < 0.02, "\(speed.after)")
        #expect(fit.g93?.passed == true, "\(fit.g93?.text ?? "")")
        // G93 well off its 6 s.
        let slow = try Calibration.fit([Calibration.Times(program, measured: ["rotary-g93": 10, "rotary-360": 4, "rotary-720": 8])], machine: machine)
        #expect(slow.g93?.passed == false)
        // A two-turn move quicker than one turn.
        #expect(throws: Calibration.Refused.self) {
            try Calibration.fit([Calibration.Times(program, measured: ["rotary-360": 5, "rotary-720": 4])], machine: machine)
        }
    }

    @Test func applyChangesOnlyTheProfileItIsGiven() throws {
        let plan = try Calibration.timingPlan(machine: MachineProfile(), options: .defaults(.inch))
        let times = Calibration.Times(kind: .timing, controller: plan.controller, plan: plan, measured: Self.madeUpTimes(plan, truth: Self.known()))
        let shipped = MachineProfile.avidPRO6060
        let fit = try Calibration.fit([times], machine: shipped)
        var mine = shipped
        fit.apply(to: &mine, date: GoldenPostTests.date)
        #expect(MachineProfile.avidPRO6060 == shipped, "the shipped defaults stay")
        #expect(MachineProfile().accelerationXY == nil)
        #expect(mine.accelerationXY != nil && mine.accelerationZ != nil && mine.rapidRateZ != nil && mine.junctionDeviation != nil)
        #expect(mine.source(of: .accelerationXY)?.kind == .measured)
        #expect(mine.source(of: .accelerationXY)?.note?.contains("2027-01-15") == true)
        // Nothing else moves.
        var reset = mine
        reset.accelerationXY = nil
        reset.accelerationZ = nil
        reset.rapidRateZ = nil
        reset.junctionDeviation = nil
        reset.provenance = nil
        #expect(reset == shipped)
    }

    @Test func timesFileRoundTrips() throws {
        let program = try Calibration.timing(machine: MachineProfile(), options: Self.compact)
        let plan = try #require(program.plan)
        let csv = Calibration.timesCSV(program, measured: ["line-1": 12.5, "arc-1": 3])
        let read = try Calibration.readTimes(csv)
        let back = try #require(read.plan)
        #expect(back.counts == plan.counts)
        #expect(back.units == plan.units)
        #expect(abs(back.window.x - plan.window.x) < 1e-6)
        #expect(read.measured == ["line-1": 12.5, "arc-1": 3])
        // The same sections when rebuilt from the file.
        let rebuilt = Calibration.timingSections(plan: back, machine: MachineProfile())
        let estimates = rebuilt.sections.map(\.estimate)
        let original = program.sections.map(\.estimate)
        #expect(zip(estimates, original).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func recordingSheetsListEverySection() throws {
        let timing = try Calibration.timing(machine: MachineProfile(), options: Self.compact)
        let sheet = RecordingSheet.html(timing)
        for s in timing.sections { #expect(sheet.contains(SetupSheet.esc(s.name)), "\(s.name)") }
        #expect(sheet.contains("Measured (s)"))
        var machine = MachineProfile()
        machine.rotary = RotaryAxis()
        let rotary = RecordingSheet.html(try Calibration.rotary(machine: machine))
        #expect(rotary.contains("6 s expected"))
        let tool = try #require(ToolLibrary.starter.tool(number: 1))
        let ladder = RecordingSheet.html(try Calibration.ladder(machine: MachineProfile(), options: .init(tool: tool, material: .plywood)))
        #expect(ladder.contains("Chip load"))
        #expect(ladder.contains("in/tooth"))
    }

    /// Writes the project fixtures the refusals use when goldens are being updated.
    @Test func projectFixtures() throws {
        guard GoldenPostTests.updating else { return }
        try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        var small = Project(name: "Desktop machine, 12 × 12 in")
        small.machine = MachineProfile(model: .custom, travel: Vec3(12.inch, 12.inch, 3.inch))
        try small.encoded().write(to: Self.fixtures.appendingPathComponent("small-machine.nativecam"))
        var grbl = Project(name: "Grbl machine")
        grbl.machine = Self.controller(.grbl)
        try grbl.encoded().write(to: Self.fixtures.appendingPathComponent("grbl-machine.nativecam"))
        // A times file with the fast line timed far quicker than 400 in/min allows.
        try Self.fixtureTimes { $0["line-3"] = 12 }
            .write(to: Self.fixtures.appendingPathComponent("unfittable-times.csv"), atomically: true, encoding: .utf8)
    }
}

/// `nativecam-cli calibrate`, run as a user runs it.
struct CalibrationCommandLineTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func calibrateWritesProgramsAndFits() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("timing").path
        let timing = try CommandLineTests.run(["calibrate", "timing", "--window", "12x12", "-o", stem])
        #expect(timing.status == 0, "\(timing.output)")
        #expect(timing.output.contains("Avid Mach4 timing suite"), "\(timing.output)")
        for path in [stem + ".tap", stem + ".html", stem + "-times.csv"] {
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }

        let rotary = try CommandLineTests.run(["calibrate", "rotary", "--controller", "linuxCNC", "-o", dir.appendingPathComponent("rotary").path])
        #expect(rotary.status == 0, "\(rotary.output)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rotary.ngc").path))
        let refused = try CommandLineTests.run(["calibrate", "rotary", "--controller", "grbl", "-o", dir.appendingPathComponent("grbl").path])
        #expect(refused.status != 0)
        #expect(refused.output.contains("Grbl can't drive a rotary axis"), "\(refused.output)")

        let ladder = try CommandLineTests.run(["calibrate", "ladder", "--material", "mdf", "-o", dir.appendingPathComponent("ladder").path])
        #expect(ladder.status == 0, "\(ladder.output)")
        #expect(ladder.output.contains("Rung 1:"), "\(ladder.output)")

        // Fit the fixture's times into a project, then apply them.
        let project = dir.appendingPathComponent("shop.nativecam")
        try Project().encoded().write(to: project)
        let csv = CalibrationTests.fixtures.appendingPathComponent("times.csv").path
        let report = try CommandLineTests.run(["calibrate", "fit", csv, project.path])
        #expect(report.status == 0, "\(report.output)")
        #expect(report.output.contains("X/Y acceleration: 50.0 in/s² -> 30."), "\(report.output)")
        #expect(report.output.contains("F-change line:"), "\(report.output)")
        #expect(report.output.contains("add --apply"), "\(report.output)")
        #expect(try Project.decode(Data(contentsOf: project)).machine.accelerationXY == nil, "nothing changes without --apply")
        let applied = try CommandLineTests.run(["calibrate", "fit", csv, project.path, "--apply"])
        #expect(applied.status == 0, "\(applied.output)")
        let machine = try Project.decode(Data(contentsOf: project)).machine
        let xy = try #require(machine.accelerationXY)
        #expect(abs(xy / 30.inch - 1) < 0.05)

        let bad = try CommandLineTests.run(["calibrate", "fit", CalibrationTests.fixtures.appendingPathComponent("unfittable-times.csv").path])
        #expect(bad.status != 0)
        #expect(bad.output.contains("Not fitted"), "\(bad.output)")
    }
}
