import Foundation
import Testing
@testable import CAMCore

/// Stage R0 of rotary milling: rotary stock, a machine's rotary axis, an A value on motions, the controllers'
/// rotary capabilities, A words read back from G-code, and a check for A words a controller can't run. Nothing
/// machines rotary stock yet, so flat projects and Avid's output must not change.
struct RotaryFoundationTests {
    func json(_ p: Project) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
    }

    // MARK: Model and file format

    @Test func flatProjectsWriteNoRotaryFields() throws {
        let j = try json(Project.demoSign())
        #expect(j["formatVersion"] as? Int == 1)
        let stock = try #require(j["stock"] as? [String: Any])
        let machine = try #require(j["machine"] as? [String: Any])
        #expect(stock["rotary"] == nil)
        #expect(machine["rotary"] == nil)
    }

    @Test func olderFilesLoadWithoutRotary() throws {
        for name in ["sign-v1", "setup-v1"] {
            let p = try Project.decode(Data(contentsOf: GoldenPostTests.projects.appendingPathComponent(name + ".nativecam")))
            #expect(p.stock.rotary == nil, "\(name)")
            #expect(p.machine.rotary == nil, "\(name)")
            #expect(p.formatVersion == 1, "\(name)")
        }
    }

    @Test func rotaryStockRoundTripsAsFormatThree() throws {
        var p = Project.demoSign()
        p.stock.rotary = RotaryStock(shape: .squareBar, diameter: 50, length: 400)
        // Builds that read format 2 would drop the blank and post the job flat, so rotary stock is format 3.
        #expect(p.formatVersion == 3)
        let j = try json(p)
        #expect(j["formatVersion"] as? Int == 3)
        let rotary = try #require((j["stock"] as? [String: Any])?["rotary"] as? [String: Any])
        #expect(rotary["shape"] as? String == "squareBar" && rotary["diameter"] as? Double == 50 && rotary["length"] as? Double == 400)
        let back = try Project.decode(p.encoded())
        #expect(back == p)
        // Back to a flat sheet, the file is format 1 again.
        var flat = back
        flat.stock.rotary = nil
        #expect(try json(flat)["formatVersion"] as? Int == 1)
    }

    @Test func formatTwoFilesWithRotaryStockStillOpen() throws {
        // Written by the first rotary build, which saved rotary stock as format 2.
        var p = Project.demoSign()
        p.stock.rotary = RotaryStock(shape: .cylinder, diameter: 40, length: 250)
        let text = try #require(String(data: p.encoded(), encoding: .utf8))
        let old = Data(text.replacingOccurrences(of: "\"formatVersion\" : 3", with: "\"formatVersion\" : 2").utf8)
        let back = try Project.decode(old)
        #expect(back.stock.rotary == p.stock.rotary)
        // Saved again, it moves to format 3.
        #expect(try json(back)["formatVersion"] as? Int == 3)
    }

    @Test func machineRotaryAxisRoundTripsAsFormatTwo() throws {
        var p = Project.demoSign()
        p.machine.rotary = RotaryAxis(letter: .a, alignment: .x, reversed: true, centerHeight: 4.inch)
        #expect(p.machine.isLegacyAvidMach4) // still Avid's Mach4 profile, but a format 1 build would drop the axis
        #expect(p.formatVersion == 2) // a flat job posts the same without it, so format 2 is enough
        let j = try json(p)
        let rotary = try #require((j["machine"] as? [String: Any])?["rotary"] as? [String: Any])
        #expect(rotary["letter"] as? String == "A" && rotary["alignment"] as? String == "x" && rotary["reversed"] as? Bool == true)
        let back = try Project.decode(p.encoded())
        #expect(back == p)
        #expect(back.machine.rotary?.centerHeight == 4.inch)
        // An axis whose centre height isn't measured yet leaves it out of the file.
        p.machine.rotary = RotaryAxis()
        let unmeasured = try #require((try json(p)["machine"] as? [String: Any])?["rotary"] as? [String: Any])
        #expect(unmeasured["centerHeight"] == nil)
        #expect(try Project.decode(p.encoded()).machine.rotary == RotaryAxis())
        p.machine.rotary = nil
        #expect(p.formatVersion == 1)
    }

    @Test func blankRadii() {
        let round = RotaryStock(shape: .cylinder, diameter: 60, length: 300)
        #expect(round.radius == 30 && round.outerRadius == 30)
        #expect(round.surfaceRadius(atDegrees: 37) == 30)
        let bar = RotaryStock(shape: .squareBar, diameter: 50, length: 300)
        #expect(bar.radius == 25)
        #expect(abs(bar.outerRadius - 25 * 2.0.squareRoot()) < 1e-12)
        // A face is square to the spindle at A0; the corners come round every 90° from 45°.
        for (degrees, r) in [(0.0, 25.0), (45, 25 * 2.0.squareRoot()), (90, 25), (135, 25 * 2.0.squareRoot()), (180, 25), (-90, 25)] {
            #expect(abs(bar.surfaceRadius(atDegrees: degrees) - r) < 1e-9, "\(degrees)°")
        }
        #expect(abs(bar.surfaceRadius(atDegrees: 30) - 25 / cos(30 * Double.pi / 180)) < 1e-9)
    }

    // MARK: Motions and output

    @Test func generatorsLeaveANil() {
        let job = CAMEngine.generate(Project.demoSign())
        #expect(!job.toolpaths.isEmpty)
        #expect(job.toolpaths.allSatisfy { $0.motions.allSatisfy { $0.a == nil } })
        #expect(Motion.feed(Vec3(1, 2, 3), 100) == Motion(kind: .feed, end: Vec3(1, 2, 3), feed: 100, a: nil))
        #expect(!job.issues.contains { $0.message.contains("rotary") })
    }

    @Test func rotarySettingsDontChangeAvidOutput() throws {
        let p = Project.demoSign()
        let toolpaths = CAMEngine.generate(p).toolpaths
        var rotary = p
        rotary.machine.rotary = RotaryAxis(centerHeight: 100)
        rotary.stock.rotary = RotaryStock()
        let job = CAMEngine.generate(rotary)
        #expect(job.toolpaths == toolpaths)
        #expect(AvidMach4Post(project: rotary, date: GoldenPostTests.date).post(toolpaths)
            == AvidMach4Post(project: p, date: GoldenPostTests.date).post(toolpaths))
        // The job says plainly that the blank is cut as a flat block.
        #expect(job.issues.contains { $0.severity == .warning && $0.message.contains("can't cut rotary stock yet") })
    }

    // MARK: Dialects

    static var dialects: [Dialect] {
        var all: [Dialect] = [.avidMach4, .linuxCNC, .masso, .centroid, .buildbotics, .richAuto, .openSBP(toolChange: .manualM6)]
        for family in [ControllerFamily.grbl, .grblHAL, .fluidNC, .carbideMotion] {
            all.append(.grblFamily(ControllerProfile(family: family), toolChange: .manualM6))
        }
        return all
    }

    @Test func rotaryCapabilities() {
        let mach4 = Dialect.avidMach4
        #expect(mach4.hasAAxis && mach4.rotaryAxes == Set("ABC") && mach4.inverseTime && mach4.rotaryFeed == .unknown)
        #expect(mach4.allowedG?.contains(93) == true)
        let grbl = Dialect.grblFamily(ControllerProfile(family: .grbl), toolChange: .manualM6)
        #expect(!grbl.hasAAxis && grbl.inverseTime && grbl.rotaryFeed == .allAxes)
        let hal = Dialect.grblFamily(ControllerProfile(family: .grblHAL), toolChange: .manualM6)
        #expect(hal.rotaryAxes == Set("ABC") && hal.inverseTime)
        #expect(Dialect.linuxCNC.hasAAxis && Dialect.linuxCNC.inverseTime && Dialect.linuxCNC.rotaryFeed == .linearAxesOnly)
        #expect(!Dialect.masso.hasAAxis && !Dialect.masso.inverseTime && Dialect.masso.rotaryFeed == .degreesPerMinute)
        #expect(Dialect.centroid.rotaryAxes == ["A"] && !Dialect.centroid.inverseTime)
        #expect(!Dialect.richAuto.hasAAxis && !Dialect.openSBP(toolChange: .atc).hasAAxis)
        // A dialect that claims G93 lists it among its G codes, and its rotary letters among its letters.
        for d in Self.dialects {
            #expect(d.rotaryAxes.isSubset(of: d.allowedLetters), "\(d.name)")
            #expect(d.rotaryAxes.isSubset(of: GCodeCheck.rotaryLetters), "\(d.name)")
            if d.inverseTime, let g = d.allowedG { #expect(g.contains(93), "\(d.name)") }
        }
    }

    // MARK: Reading A back

    /// A wrapped program the way a Vectric or Fusion rotary post writes it: Y stays on the axis centreline and A
    /// turns the part.
    let wrapped = ["G00 G21 G17 G90", "T1 M6", "S18000 M3", "G00 Z30.000", "G00 X0.000 Y0.000 A0.000", "G01 Z20.000 F500",
                   "G01 X10.000 A90.000", "G01 A180.000", "G91 G01 A-45.000", "G90", "G00 Z30.000", "G00 A720.000", "M30"]

    @Test func aWordsAreReadAndWarnedAbout() throws {
        let program = try GCodeParser.parse(wrapped.joined(separator: "\n"))
        let motions = program.segments.flatMap(\.motions)
        #expect(motions.map(\.a) == [nil, 0, 0, 90, 180, 135, 135, 720])
        // A line that only turns A is a move in place.
        let turn = motions[4]
        #expect(turn.kind == .feed && turn.end == Vec3(10, 0, 20) && turn.a == 180)
        #expect(program.warnings.filter { $0.contains("rotary axis") && $0.contains("aren't simulated") }.count == 1)
        // A carries through to toolpaths for the simulator.
        let toolpaths = program.toolpaths(tools: [], stock: Project.demoSign().stock, fallback: Fixture.endMill)
        #expect(toolpaths.flatMap(\.motions).map(\.a) == motions.map(\.a))
    }

    @Test func aIsDegreesInInchPrograms() throws {
        let program = try GCodeParser.parse("G20 G90\nG00 X1.0000 A90.0000\nG01 X2.0000 A-30.5 F100\n")
        let motions = program.segments.flatMap(\.motions)
        #expect(motions.map(\.a) == [90, -30.5])
        #expect(abs(motions[1].end.x - 2.inch) < 1e-9)
    }

    @Test func programsWithoutAAreUnchanged() throws {
        let g = try String(decoding: Data(contentsOf: GoldenPostTests.goldens.appendingPathComponent("sign-inch.tap")), as: UTF8.self)
        let program = try GCodeParser.parse(g)
        #expect(program.segments.flatMap(\.motions).allSatisfy { $0.a == nil })
        #expect(!program.warnings.contains { $0.contains("rotary") })
    }

    // MARK: Export check

    func rotaryIssues(_ lines: [String], dialect: Dialect, machine: (inout MachineProfile) -> Void = { _ in }) -> [GCodeCheck.Issue] {
        var p = Project()
        machine(&p.machine)
        return GCodeCheck.lint(lines.joined(separator: dialect.lineEnding) + dialect.lineEnding, project: p, dialect: dialect)
            .filter { $0.message.contains("rotary") }
    }

    @Test func aWordsForAControllerWithoutAnAAxisAreErrors() throws {
        let grbl = Dialect.grblFamily(ControllerProfile(family: .grbl), toolChange: .manualM6)
        let issues = rotaryIssues(wrapped, dialect: grbl) { $0.rotary = RotaryAxis() }
        #expect(issues.count == 1)
        let issue = try #require(issues.first)
        #expect(issue.severity == .error && issue.line == 5)
        #expect(issue.message.contains("Grbl has no A axis") && issue.message.contains("4 more lines"))
        // The plain letter check doesn't report the same words a second time.
        let all = GCodeCheck.lint(wrapped.joined(separator: "\n") + "\n", project: Project(), dialect: grbl)
        #expect(!all.contains { $0.message.contains("doesn't accept A words") })
        #expect(rotaryIssues(wrapped, dialect: .masso).first?.severity == .error)
    }

    @Test func aWordsNeedTheMachinesRotaryAxis() {
        let mach4 = Dialect.avidMach4
        let none = rotaryIssues(wrapped, dialect: mach4)
        #expect(none.count == 1 && none.first?.severity == .warning)
        #expect(none.first?.message.contains("no rotary axis set up") == true)
        #expect(rotaryIssues(wrapped, dialect: mach4) { $0.rotary = RotaryAxis(letter: .a) }.isEmpty)
        let other = rotaryIssues(wrapped, dialect: mach4) { $0.rotary = RotaryAxis(letter: .b) }
        #expect(other.first?.message.contains("rotary axis is B") == true)
        // B words on a controller with only an A axis.
        let b = rotaryIssues(["G21", "G00 X0 B90"], dialect: .centroid) { $0.rotary = RotaryAxis() }
        #expect(b.first?.severity == .error && b.first?.message.contains("no B axis") == true)
    }
}
