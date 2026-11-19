import Foundation
import Testing
@testable import CAMCore

/// Stage 3 of machine support: one capability-driven post for Grbl 1.1, grblHAL, FluidNC and Carbide Motion,
/// pinned by golden files and passing the same export checks as the Avid post.
struct GrblPostTests {
    static func grbl(_ family: ControllerFamily = .grbl, sender: String? = nil) -> @Sendable (inout Project) -> Void {
        { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: family, sender: sender)
        }
    }

    static let variants: [(String, @Sendable (inout Project) -> Void)] = [
        ("grbl-coverage-inch", grbl()),
        ("grbl-coverage-mm", { p in grbl()(&p); p.machine.outputUnits = .mm }),
        ("grbl-gsender-m6", grbl(sender: "gSender")),
        ("grbl-pause", { p in grbl()(&p); p.machine.toolChange = .manualPause }),
        ("grbl-line-numbers-dwell", { p in grbl()(&p); p.machine.lineNumbers = true; p.machine.spindleSpinUpDwell = 2 }),
        ("grblhal-atc", { p in grbl(.grblHAL)(&p); p.machine.toolChange = .atc }),
        ("fluidnc-coverage", grbl(.fluidNC)),
        ("carbide-motion-coverage", grbl(.carbideMotion)),
    ]

    func post(_ p: Project, _ toolpaths: [Toolpath]) throws -> (String, any PostProcessor) {
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
        post.timeZone = TimeZone(identifier: "UTC")!
        return (post.post(toolpaths), post)
    }

    /// The files an export saves, each checked against its golden (`name`, or `name-1`, `name-2`… when split).
    func files(_ p: Project, _ toolpaths: [Toolpath], golden name: String) throws -> [(PostedFile, [GCodeCheck.Issue])] {
        let post: any PostProcessor
        if var generic = PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost {
            generic.timeZone = TimeZone(identifier: "UTC")!
            post = generic
        } else {
            var avid = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? AvidMach4Post)
            avid.timeZone = TimeZone(identifier: "UTC")!
            post = avid
        }
        let files = post.files(toolpaths)
        return try files.enumerated().map { i, f in
            try GoldenPostTests.check(Data(f.gcode.utf8), golden: files.count == 1 ? name : "\(name)-\(i + 1)")
            return (f, problems(f.gcode, p, f.toolpaths, dialect: post.dialect))
        }
    }

    func problems(_ g: String, _ p: Project, _ toolpaths: [Toolpath], dialect: Dialect) -> [GCodeCheck.Issue] {
        GCodeCheck.run(g, toolpaths: toolpaths, project: p, dialect: dialect).filter { $0.severity != .info }
    }

    @Test func goldenFilesMatchAndPassEveryCheck() throws {
        for (name, configure) in Self.variants {
            let (p, toolpaths) = GoldenPostTests.coverageJob(configure)
            let issues = try files(p, toolpaths, golden: name).flatMap(\.1)
            if name == "grbl-gsender-m6" {
                // The only open question for a sender: does it really pause on M6?
                #expect(issues.allSatisfy { $0.severity == .warning && $0.message.contains("sending the file") }, "\(issues.map(\.text))")
                #expect(!issues.isEmpty)
            } else {
                #expect(issues.isEmpty, "\(name): \(issues.map(\.text))")
            }
        }
    }

    @Test func demoSignForGrbl() throws {
        var p = Project.demoSign()
        Self.grbl()(&p)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let out = try files(p, job.toolpaths, golden: "grbl-sign-inch")
        #expect(out.count == 2) // V-bit, then the end mill: one file each
        #expect(out.allSatisfy { $0.1.isEmpty }, "\(out.flatMap(\.1).map(\.text))")
    }

    @Test func acceptanceProgramsForEveryController() throws {
        let machines: [(String, MachineProfile)] = [
            ("acceptance-avid", MachineProfile()),
            ("acceptance-grbl", { var m = MachineProfile(model: .custom, outputUnits: .mm); m.controller = ControllerProfile(family: .grbl); return m }()),
            ("acceptance-grblhal", { var m = MachineProfile(model: .custom, outputUnits: .mm); m.controller = ControllerProfile(family: .grblHAL); return m }()),
            ("acceptance-fluidnc", { var m = MachineProfile(model: .custom, outputUnits: .mm); m.controller = ControllerProfile(family: .fluidNC); return m }()),
            ("acceptance-carbide-motion", { var m = MachineProfile(model: .custom, outputUnits: .inch); m.controller = ControllerProfile(family: .carbideMotion); return m }()),
        ]
        for (name, machine) in machines {
            let (p, toolpaths) = AcceptanceTest.job(machine: machine)
            let out = try files(p, toolpaths, golden: name)
            let issues = out.flatMap(\.1)
            #expect(issues.isEmpty, "\(name): \(issues.map(\.text))")
            // The 3 s dwell is in every one; Grbl, grblHAL and FluidNC without an M6 handler get a file per tool.
            #expect(out.contains { $0.0.gcode.contains("P3.00") }, "\(name)")
            #expect(out.count == (["acceptance-avid", "acceptance-carbide-motion"].contains(name) ? 1 : 3), "\(name)")
        }
    }

    @Test func grblOutputUsesOnlyWhatGrblAccepts() throws {
        let (p, toolpaths) = GoldenPostTests.coverageJob(Self.grbl())
        let post = try #require(PostProcessors.post(for: p))
        let out = post.files(toolpaths)
        // T1, T5, back to T1: three complete programs, each starting from a freshly zeroed tool.
        #expect(out.map { $0.suffix ?? "" } == [" 1 of 3 - T1", " 2 of 3 - T5", " 3 of 3 - T1"])
        for file in out {
            let g = file.gcode
            let lines = g.components(separatedBy: "\n").dropLast()
            #expect(!g.contains("\r"))
            #expect(lines.allSatisfy { $0.count <= 79 })
            for word in ["G64", "G91.1", "G90.1", "G43", "M7", "M6", "M0", "T1", "M07", "M03"] {
                #expect(!lines.contains { GCodeParser.stripComments($0).split(separator: " ").contains(Substring(word)) }, "\(word)")
            }
            #expect(lines.contains("M8"))
            #expect(lines.contains("G20"))
            #expect(lines.contains { $0.hasPrefix("(Load T") && $0.contains("zero Z") })
            #expect(lines.suffix(3) == ["M5", "M9", "M30"])
        }
        // Chosen explicitly, a pause keeps one file and stops with M0.
        var pause = p
        pause.machine.toolChange = .manualPause
        let single = try #require(PostProcessors.post(for: pause)).files(toolpaths)
        #expect(single.count == 1 && single[0].gcode.contains("\nM0\n"))
    }

    @Test func senderAndFirmwareDecideHowToolsChange() throws {
        func usesM6(_ family: ControllerFamily, sender: String? = nil, change: ToolChangeMode = .manualM6) -> Bool {
            var m = MachineProfile()
            m.controller = ControllerProfile(family: family, sender: sender)
            m.toolChange = change
            return GenericGCodePost(project: Project(machine: m), dialect: Dialect.for(m)!).usesM6
        }
        #expect(!usesM6(.grbl))                        // stock Grbl: error 20 on M6
        #expect(!usesM6(.grbl, sender: "UGS"))
        #expect(usesM6(.grbl, sender: "gSender"))
        #expect(usesM6(.grbl, sender: "CNCjs 1.9.22"))
        #expect(!usesM6(.grbl, sender: "gSender", change: .manualPause))
        #expect(usesM6(.carbideMotion))
        #expect(!usesM6(.fluidNC))                      // records the tool, doesn't stop
        #expect(usesM6(.fluidNC, change: .atc))
        #expect(!usesM6(.grblHAL))                      // $341 mode 4 ignores M6; unknown without the sender
        #expect(usesM6(.grblHAL, sender: "gSender"))
        #expect(usesM6(.grblHAL, change: .atc))
    }

    @Test func arcsGrblWouldRejectAreCutAsLines() throws {
        // Radii 3.000 and 3.008 mm: inside Mach4's 0.0127 mm, outside Grbl's 0.005 mm and 0.1%.
        let arc = Toolpath(id: UUID(), name: "arc", tool: ToolLibrary.starter.tool(number: 2)!, spindleRPM: 18000, start: Vec3(10, 10, 5),
                           motions: [.rapid(Vec3(10, 10, 1)), .feed(Vec3(10, 10, -1), 300),
                                     Motion(kind: .arcCW, end: Vec3(13, 13.008, -1), center: Vec2(13, 10), feed: 600)])
        var p = Project(stock: Stock(width: 100, height: 100, thickness: 10))
        p.machine.outputUnits = .mm
        let avid = AvidMach4Post(project: p).post([arc])
        #expect(avid.contains("G02 X13.000 Y13.008"))
        Self.grbl()(&p)
        let (g, post) = try post(p, [arc])
        #expect(g.contains("G1 X13.000 Y13.008") && !g.contains("G2 "))
        let issues = GCodeCheck.run(g, toolpaths: [arc], project: p, dialect: post.dialect)
        #expect(issues.contains { $0.severity == .info && $0.message.contains("radii disagree") })
        #expect(issues.allSatisfy { $0.severity == .info }, "\(issues.map(\.text))")
    }

    @Test func grblPlannerShapesTheEstimate() {
        var m = MachineProfile()
        #expect(m.planner == Dialect.avidMach4.planner)
        m.controller = ControllerProfile(family: .grbl)
        #expect(m.plannerLookahead == 16 && m.cornerDeviation == 0.01 && !m.planner.rapidsExactStop)
        m.junctionDeviation = 0.02
        #expect(m.cornerDeviation == 0.02)
        // Blended rapids make the same job's rapids quicker than exact-stop ones.
        var avid = Project.demoSign()
        var grbl = avid
        Self.grbl()(&grbl)
        avid.machine.junctionDeviation = 0.01
        avid.machine.lookaheadLines = 16
        let a = CAMEngine.generate(avid).estimate!, b = CAMEngine.generate(grbl).estimate!
        #expect(b.rapidSeconds < a.rapidSeconds)
        #expect(abs(b.feedSeconds - a.feedSeconds) < 0.05 * a.feedSeconds)
    }

    @Test func unsupportedControllersStillHaveNoPost() {
        var m = MachineProfile()
        m.controller = ControllerProfile(family: .masso)
        #expect(Dialect.for(m) == nil)
        #expect(PostProcessors.unavailableReason(for: m)?.contains("Masso") == true)
    }
}
