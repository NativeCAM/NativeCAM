import Foundation
import Testing
@testable import CAMCore

/// Stage 2 of machine support: every exported file is checked line by line against its controller, read back and
/// compared with the toolpaths, and measured against the machine's travel. Avid's golden files must pass clean.
struct ExportCheckTests {
    static let goldens = GoldenPostTests.goldens

    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }

    func golden(_ name: String) throws -> String {
        try String(decoding: Data(contentsOf: Self.goldens.appendingPathComponent(name + ".tap")), as: UTF8.self)
    }

    func check(_ gcode: String, _ project: Project, _ toolpaths: [Toolpath], dialect: Dialect = .avidMach4) -> [GCodeCheck.Issue] {
        GCodeCheck.run(gcode, toolpaths: toolpaths, project: project, dialect: dialect)
    }

    // MARK: Avid output passes

    @Test func coverageGoldensPassEveryCheck() throws {
        for (name, configure) in GoldenPostTests.coverageVariants {
            let (p, toolpaths) = GoldenPostTests.coverageJob(configure)
            let issues = check(try golden(name), p, toolpaths)
            #expect(problems(issues).isEmpty, "\(name): \(problems(issues))")
            // The deliberately broken arc in the coverage job is reported as information, not hidden.
            #expect(issues.contains { $0.severity == .info && $0.message.contains("radii disagree") }, "\(name)")
        }
    }

    @Test func demoGoldensPassEveryCheck() throws {
        var mm = Project.demoSign()
        mm.machine.outputUnits = .mm
        var lines = Project.demoSign()
        lines.machine.outputArcs = false
        for (name, p) in [("sign-inch", Project.demoSign()), ("sign-mm", mm), ("sign-no-arcs", lines), ("relief-inch", Project.demoRelief())] {
            let issues = check(try golden(name), p, CAMEngine.generate(p).toolpaths)
            #expect(problems(issues).isEmpty, "\(name): \(problems(issues))")
        }
    }

    @Test func savedProjectGoldensPassEveryCheck() throws {
        for name in ["sign-v1", "setup-v1"] {
            let p = try Project.decode(Data(contentsOf: GoldenPostTests.projects.appendingPathComponent(name + ".nativecam")))
            let issues = check(try golden("decoded-" + name), p, CAMEngine.generate(p).toolpaths)
            #expect(problems(issues).isEmpty, "\(name): \(problems(issues))")
        }
    }

    // MARK: Lint finds problems

    func lint(_ lines: [String], dialect: Dialect = .avidMach4, project: Project = Project(), crlf: Bool = true) -> [GCodeCheck.Issue] {
        GCodeCheck.lint(lines.joined(separator: crlf ? "\r\n" : "\n") + (crlf ? "\r\n" : "\n"), project: project, dialect: dialect)
    }

    func messages(_ issues: [GCodeCheck.Issue], _ severity: Severity = .error) -> String {
        issues.filter { $0.severity == severity }.map(\.text).joined(separator: " | ")
    }

    /// A clean Avid-style program to break one thing at a time.
    let good = ["(test)", "G00 G94 G20 G17 G90 G40 G49 G80", "G91.1", "T1M6", "M07", "S18000 M03", "G00 Z0.5000",
                "G00 X1.0000 Y1.0000", "G01 Z-0.1000 F30.0", "G01 X2.0000 F100.0", "G02 X3.0000 Y2.0000 I0.0000 J1.0000",
                "G04 P1.00", "G00 Z0.5000", "M05", "M09", "M30"]

    @Test func cleanProgramHasNoIssues() {
        #expect(lint(good).isEmpty, "\(lint(good).map(\.text))")
    }

    func replacing(_ old: String, with new: String?) -> [String] {
        good.compactMap { $0 == old ? new : $0 }
    }

    @Test func lintFindsEachProblem() {
        #expect(messages(lint(replacing("G00 G94 G20 G17 G90 G40 G49 G80", with: "G00 G94 G17 G90 G40 G49 G80"))).contains("before G20 or G21"))
        #expect(messages(lint(replacing("G00 G94 G20 G17 G90 G40 G49 G80", with: "G00 G94 G21 G17 G90 G40 G49 G80"))).contains("set up for in"))
        #expect(messages(lint(good, crlf: false)).contains("CRLF"))
        #expect(messages(lint(replacing("(test)", with: "(a (nested) comment)"))).contains("nested"))
        #expect(messages(lint(replacing("G04 P1.00", with: "G04 P1"))).contains("decimal point"))
        #expect(messages(lint(replacing("G01 X2.0000 F100.0", with: "G01 X2.0000 I0.5 F100.0"))).contains("isn't an arc"))
        #expect(messages(lint(replacing("M07", with: "H1"))).contains("without G43"))
        #expect(messages(lint(replacing("G01 Z-0.1000 F30.0", with: "G01 Z-0.1000"))).contains("before any F word"))
        #expect(messages(lint(replacing("S18000 M03", with: "S18000"))).contains("spindle stopped"))
        #expect(messages(lint(replacing("G00 Z0.5000", with: nil))).contains("before lifting to safe Z"))
        #expect(messages(lint(replacing("G02 X3.0000 Y2.0000 I0.0000 J1.0000", with: "G02 X3.0000 Y2.0000 I0.0000 J1.0100"))).contains("radii differ"))
        #expect(messages(lint(replacing("M30", with: nil))).contains("M30 or M2"))
        // Feeds above the machine's maximum are a warning.
        #expect(messages(lint(replacing("G01 X2.0000 F100.0", with: "G01 X2.0000 F900.0")), .warning).contains("above the machine's maximum"))
    }

    @Test func liftIsRequiredAgainAfterEachToolChange() {
        var lines = good
        let end = lines.firstIndex(of: "M05")!
        lines.insert(contentsOf: ["G00 Z0.5000", "M05", "T2M6", "S18000 M03", "G00 X4.0000 Y1.0000", "G01 Z-0.1000 F30.0"], at: end)
        #expect(messages(lint(lines)).contains("after a tool change before lifting"))
        lines.insert("G00 Z0.5000", at: lines.firstIndex(of: "G00 X4.0000 Y1.0000")!)
        #expect(messages(lint(lines)).isEmpty)
    }

    @Test func strictDialectsStopOnWhatTheyDontKnow() {
        var strict = Dialect.avidMach4
        strict.name = "Strict"
        strict.strict = true
        strict.allowedG = Set([0, 1, 2, 3, 4, 17, 20, 21, 40, 49, 80, 90, 91, 91.1, 94])
        strict.allowedM = Set([0, 3, 5, 9, 30])
        strict.maxLineLength = 40
        strict.maxToolNumber = 255
        strict.m6 = .rejected
        let issues = lint(good + [], dialect: strict)
        let text = messages(issues)
        #expect(text.contains("doesn't support M7"))
        #expect(text.contains("rejects M6"))
        var long = replacing("(test)", with: "(" + String(repeating: "x", count: 60) + ")")
        long[long.firstIndex(of: "T1M6")!] = "T300M6"
        let more = messages(lint(long, dialect: strict))
        #expect(more.contains("reads at most 40"))
        #expect(more.contains("above 255"))
    }

    @Test func repeatedProblemsAreCountedOnce() {
        let lines = good.map { $0.hasPrefix("G01") ? $0.replacingOccurrences(of: "F", with: "F9") : $0 }
        let warnings = lint(lines).filter { $0.message.contains("above the machine's maximum") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.message.contains("1 more line") == true)
    }

    // MARK: Read-back finds post bugs

    func signJob() -> (Project, [Toolpath], String) {
        let p = Project.demoSign()
        let toolpaths = CAMEngine.generate(p).toolpaths
        return (p, toolpaths, AvidMach4Post(project: p, date: GoldenPostTests.date).post(toolpaths))
    }

    @Test func readBackCatchesDoubledCoordinates() throws {
        let (p, toolpaths, g) = signJob()
        var lines = g.components(separatedBy: "\r\n")
        let i = try #require(lines.firstIndex { $0.hasPrefix("G01 X") })
        let x = try #require(Double(lines[i].split(separator: " ")[1].dropFirst()))
        lines[i] = lines[i].replacingOccurrences(of: String(format: "X%.4f", x), with: String(format: "X%.4f", 2 * x))
        let issues = check(lines.joined(separator: "\r\n"), p, toolpaths)
        #expect(messages(issues).contains("but “"))
    }

    @Test func readBackCatchesWrongUnitsAndArcDirection() throws {
        let (p, toolpaths, g) = signJob()
        #expect(messages(check(g.replacingOccurrences(of: "G20", with: "G21"), p, toolpaths)).contains("Ends at"))
        let i = try #require(g.range(of: "\r\nG02 "))
        let flipped = g.replacingCharacters(in: i, with: "\r\nG03 ")
        #expect(messages(check(flipped, p, toolpaths)).contains("wrong way"))
    }

    @Test func readBackCatchesDwellUnitsAndMissingMoves() throws {
        let (p, toolpaths) = GoldenPostTests.coverageJob { $0.machine.spindleSpinUpDwell = 4 }
        let g = try golden("coverage-dwell")
        let ms = g.replacingOccurrences(of: "G04 P4.00", with: "G04 P4000")
        let text = messages(check(ms, p, toolpaths))
        #expect(text.contains("decimal point"))
        #expect(text.contains("Dwells 4000"))
        var lines = g.components(separatedBy: "\r\n")
        lines.remove(at: try #require(lines.firstIndex { $0.hasPrefix("G01 X") }))
        #expect(messages(check(lines.joined(separator: "\r\n"), p, toolpaths)).contains("cutting moves and dwells"))
    }

    // MARK: Work area

    @Test func programsLargerThanTheMachineAreFlagged() {
        var p = Project.demoSign()
        p.machine.travel = Vec3(300, 300, 60)
        let toolpaths = CAMEngine.generate(p).toolpaths
        let g = AvidMach4Post(project: p).post(toolpaths)
        let program = try? GCodeParser.parse(g)
        let issues = program.map { GCodeCheck.envelope($0, toolpaths: toolpaths, project: p) } ?? []
        let text = issues.map(\.message).joined(separator: " | ")
        #expect(text.contains("in X") && text.contains("in Y") && text.contains("Z travel"))
    }

    // MARK: Air cut

    @Test func airCutRaisesEveryZAndKeepsXY() throws {
        let p = Project.demoSign()
        let toolpaths = CAMEngine.generate(p).toolpaths
        let normal = AvidMach4Post(project: p, date: GoldenPostTests.date).post(toolpaths)
        let air = try #require(AirCut.post(p, toolpaths: toolpaths, height: 1.inch, date: GoldenPostTests.date))
        #expect(air.gcode.hasPrefix("(AIR CUT: Z raised 1.0000 in, X and Y unchanged)"))
        let a = try GCodeParser.parse(normal).segments.flatMap(\.motions)
        let b = try GCodeParser.parse(air.gcode).segments.flatMap(\.motions)
        #expect(a.count == b.count)
        for (m, r) in zip(a, b) {
            #expect(abs(m.end.x - r.end.x) < 1e-9 && abs(m.end.y - r.end.y) < 1e-9)
            #expect(abs(r.end.z - m.end.z - 1.inch) < 0.003)
        }
        // The raised file passes the same checks against the raised toolpaths.
        let issues = GCodeCheck.run(air.gcode, toolpaths: air.toolpaths, project: air.project, dialect: air.post.dialect)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    // MARK: Setup sheet

    @Test func setupSheetListsToolsChangesAndTimes() {
        var p = Project.demoSign()
        p.name = "Sign <draft>"
        let job = CAMEngine.generate(p)
        let html = SetupSheet.html(project: p, job: job, gcodeFile: "Sign.tap")
        #expect(html.contains("Sign &lt;draft&gt;"))
        #expect(html.contains("T5 60° V-Bit"))
        #expect(html.contains("Change to T1"))
        for op in p.operations { #expect(html.contains(SetupSheet.esc(op.name))) }
        #expect(html.contains("Baltic birch plywood: 24.000 in × 18.000 in × 0.750 in"))
        #expect(html.contains("About "))
    }
}
