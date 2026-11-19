import Foundation
import Testing
@testable import CAMCore

/// Stage 8 of machine support: ShopBot's OpenSBP (a native post and a reader) and RichAuto DSP controllers, pinned
/// by golden files and passing the export checks. OpenSBP syntax follows ShopBot's Command Reference and Programming
/// Handbook; the spindle and tool-change commands follow vendor posts. Neither is tested on hardware.
struct LongTailPostTests {
    static func controller(_ family: ControllerFamily, _ change: ToolChangeMode = .manualM6) -> @Sendable (inout Project) -> Void {
        { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: family)
            p.machine.toolChange = change
        }
    }

    func files(_ p: Project, _ toolpaths: [Toolpath], golden name: String) throws -> [(PostedFile, [GCodeCheck.Issue])] {
        let post: any PostProcessor
        if var sbp = PostProcessors.post(for: p, date: GoldenPostTests.date) as? OpenSBPPost {
            sbp.timeZone = TimeZone(identifier: "UTC")!
            post = sbp
        } else {
            var generic = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
            generic.timeZone = TimeZone(identifier: "UTC")!
            post = generic
        }
        let files = post.files(toolpaths)
        return try files.enumerated().map { i, f in
            try GoldenPostTests.check(Data(f.gcode.utf8), golden: files.count == 1 ? name : "\(name)-\(i + 1)")
            return (f, GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: p, dialect: post.dialect).filter { $0.severity != .info })
        }
    }

    @Test func goldensPassEveryCheck() throws {
        let cases: [(String, @Sendable (inout Project) -> Void, Int)] = [
            ("opensbp-coverage", Self.controller(.openSBP), 3),                // one file per tool
            ("opensbp-pause", Self.controller(.openSBP, .manualPause), 1),
            ("opensbp-atc", Self.controller(.openSBP, .atc), 1),
            ("richauto-coverage", Self.controller(.richAuto), 3),
        ]
        for (name, configure, count) in cases {
            let (p, toolpaths) = GoldenPostTests.coverageJob(configure)
            let out = try files(p, toolpaths, golden: name)
            #expect(out.count == count, "\(name)")
            #expect(out.allSatisfy { $0.1.isEmpty }, "\(name): \(out.flatMap(\.1).map(\.text))")
        }
        for (id, family) in [("opensbp", ControllerFamily.openSBP), ("richauto", .richAuto)] {
            var m = MachineProfile(model: .custom, outputUnits: .mm)
            m.controller = ControllerProfile(family: family)
            let (p, toolpaths) = AcceptanceTest.job(machine: m)
            let out = try files(p, toolpaths, golden: "acceptance-\(id)")
            #expect(out.allSatisfy { $0.1.isEmpty }, "acceptance \(id): \(out.flatMap(\.1).map(\.text))")
        }
    }

    @Test func openSBPWritesShopBotsCommands() throws {
        let (p, toolpaths) = GoldenPostTests.coverageJob(Self.controller(.openSBP, .manualPause))
        let post = try #require(PostProcessors.post(for: p) as? OpenSBPPost)
        let g = post.files(toolpaths)[0].gcode
        let lines = g.components(separatedBy: "\r\n")
        #expect(post.fileExtension == "sbp")
        #expect(lines.contains("IF %(25)=1 THEN GOTO UNIT_ERROR") && lines.contains("SA"))
        #expect(lines.contains("TR,18000") && lines.contains("C6") && lines.contains("C7"))
        #expect(lines.contains { $0.hasPrefix("CG,,") && $0.hasSuffix(",T,-1") })    // counterclockwise arc
        #expect(lines.contains { $0.hasPrefix("CG,,") && $0.hasSuffix(",T,1") })     // clockwise arc
        #expect(lines.contains("MS,1.640,0.492"))  // 2500 mm/min across = 1.640 in/s, 750 mm/min down = 0.492 in/s
        #expect(lines.contains("PAUSE 0.50") && lines.contains("PAUSE"))
        let end = try #require(lines.firstIndex(of: "END"))
        #expect(lines[end...].contains("UNIT_ERROR:"))
        // The helix (an arc that changes depth) is written as short moves, since CG keeps Z constant.
        #expect(!lines.contains { $0.hasPrefix("CG") && $0.contains("-0.15") })
    }

    @Test func openSBPReaderFollowsTheFile() {
        let text = "'test\r\nIF %(25)=1 THEN GOTO UNIT_ERROR\r\nSA\r\nMS,1,0.5\r\nJZ,0.5\r\nJ2,1,1\r\nTR,12000\r\nC6\r\nMZ,-0.1\r\nM2,2,1\r\n"
            + "CG,,3,2,0,1,T,1\r\nPAUSE 1.5\r\nEND\r\nUNIT_ERROR:\r\nJ2,9,9\r\nEND\r\n"
        let program = OpenSBPParser.parse(text)
        let m = program.segments.flatMap(\.motions)
        #expect(program.units == .inch)
        #expect(m.map(\.kind) == [.rapid, .rapid, .feed, .feed, .arcCW, .dwell])
        #expect(abs(m[2].feed - 0.5 * 25.4 * 60) < 1e-6 && abs(m[3].feed - 25.4 * 60) < 1e-6)
        #expect(m[4].center == Vec2(2 * 25.4, 2 * 25.4) && m[4].end == Vec3(3 * 25.4, 2 * 25.4, -0.1 * 25.4))
        #expect(m[5].feed == 1.5)
        // The cuts run at the spindle speed TR set (the rapids before it are their own segment, as in G-code).
        #expect(program.segments.filter { $0.motions.contains { $0.kind == .feed } }.allSatisfy { $0.spindleRPM == 12000 })
    }

    @Test func openSBPLintFindsProblems() {
        func errors(_ body: String) -> String {
            GCodeCheck.lintOpenSBP("IF %(25)=1 THEN GOTO UNIT_ERROR\r\nSA\r\n" + body, project: Project(), dialect: .openSBP(toolChange: .manualM6))
                .map(\.message).joined(separator: " | ")
        }
        #expect(errors("C6\r\nJZ,0.5\r\nJ2,1,1\r\nMZ,-0.1\r\nEND\r\n").contains("before MS"))
        #expect(errors("MS,1,1\r\nJZ,0.5\r\nJ2,1,1\r\nMZ,-0.1\r\nEND\r\n").contains("spindle stopped"))
        #expect(errors("MS,1,1\r\nC6\r\nJ2,1,1\r\nEND\r\n").contains("before lifting"))
        #expect(errors("MS,1,1\r\nC6\r\nJZ,0.5\r\nJ2,1,1\r\n").contains("END"))
        #expect(errors("MS,1,1\r\nC6\r\nJZ,0.5\r\nJ2,1,1\r\nMZ,-0.1\r\nEND\r\n").isEmpty)
    }

    @Test func richAutoIsMetricWithoutArcsOrComments() throws {
        let (p, toolpaths) = GoldenPostTests.coverageJob(Self.controller(.richAuto))
        #expect(p.machine.outputUnits == .inch) // the machine says inches; RichAuto only runs in millimetres
        let post = try #require(PostProcessors.post(for: p) as? GenericGCodePost)
        for f in post.files(toolpaths) {
            let lines = f.gcode.components(separatedBy: "\r\n")
            #expect(lines.prefix(2) == ["G90", "G21"])
            #expect(!f.gcode.contains("(") && !f.gcode.contains("M6"))
            #expect(!lines.contains { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") })
        }
        #expect(p.machine.summary[0].contains("millimetres (G21)"))
    }

    @Test func catalogueShopBotAndDSPMachinesHavePosts() {
        let entries = MachineCatalogue.builtIn.entries
        for e in entries where ["openSBP", "richAuto"].contains(e.defaultController?.family ?? "") {
            let post = PostProcessors.post(for: Project(machine: e.profile()))
            #expect(post != nil, "\(e.id)")
        }
        #expect(entries.contains { $0.defaultController?.family == "openSBP" })
    }
}
