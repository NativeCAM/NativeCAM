import Foundation
import Testing
@testable import CAMCore

/// Stage 7 of machine support: LinuxCNC, Masso, Centroid CNC12 (Avid EX) and Buildbotics through the capability-driven
/// post, pinned by golden files and passing the export checks. All are written from documentation; none is tested
/// on hardware.
struct ControllerPostTests {
    static func controller(_ family: ControllerFamily, units: LengthUnit = .inch) -> @Sendable (inout Project) -> Void {
        { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: family)
            p.machine.outputUnits = units
        }
    }

    static let families: [(String, ControllerFamily)] = [("linuxcnc", .linuxCNC), ("masso", .masso), ("centroid", .centroid),
                                                         ("buildbotics", .buildbotics)]

    func files(_ p: Project, _ toolpaths: [Toolpath], golden name: String) throws -> [(PostedFile, [GCodeCheck.Issue], any PostProcessor)] {
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
        post.timeZone = TimeZone(identifier: "UTC")!
        let files = post.files(toolpaths)
        return try files.enumerated().map { i, f in
            try GoldenPostTests.check(Data(f.gcode.utf8), golden: files.count == 1 ? name : "\(name)-\(i + 1)")
            let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: p, dialect: post.dialect).filter { $0.severity != .info }
            return (f, issues, post)
        }
    }

    @Test func linuxCNCRotaryRoundBlankGolden() throws {
        let (p, toolpaths) = GoldenPostTests.rotaryJob(blank: RotaryStock(shape: .cylinder, diameter: 50, length: 300),
                                                       slotAngles: [0, 180], holeAngles: [0, 60, 120, 180, 240, 300],
                                                       Self.controller(.linuxCNC, units: .mm))
        let out = try files(p, toolpaths, golden: "linuxcnc-rotary-round")
        #expect(out.count == 1 && out.allSatisfy { $0.1.isEmpty }, "\(out.flatMap(\.1).map(\.text))")
        #expect(out.first?.0.gcode.contains("G0 A300.000") == true)
    }

    @Test func coverageAndAcceptanceGoldensPassEveryCheck() throws {
        for (id, family) in Self.families {
            let (p, toolpaths) = GoldenPostTests.coverageJob(Self.controller(family))
            let out = try files(p, toolpaths, golden: "\(id)-coverage")
            #expect(out.count == 1, "\(id): M6 stops on every one of these, so one file")
            #expect(out.allSatisfy { $0.1.isEmpty }, "\(id): \(out.flatMap(\.1).map(\.text))")

            var machine = MachineProfile(model: .custom, outputUnits: .mm)
            machine.controller = ControllerProfile(family: family)
            let (ap, apaths) = AcceptanceTest.job(machine: machine)
            let acc = try files(ap, apaths, golden: "acceptance-\(id)")
            #expect(acc.allSatisfy { $0.1.isEmpty }, "acceptance \(id): \(acc.flatMap(\.1).map(\.text))")
        }
    }

    func gcode(_ family: ControllerFamily, units: LengthUnit = .inch) throws -> (String, GenericGCodePost) {
        let (p, toolpaths) = GoldenPostTests.coverageJob(Self.controller(family, units: units))
        let post = try #require(PostProcessors.post(for: p) as? GenericGCodePost)
        return (post.post(toolpaths), post)
    }

    func lines(_ g: String) -> [String] { g.components(separatedBy: .newlines).filter { !$0.isEmpty } }

    @Test func linuxCNC() throws {
        let (g, post) = try gcode(.linuxCNC)
        let l = lines(g)
        #expect(post.fileExtension == "ngc" && !g.contains("\r"))
        #expect(l.contains("G91.1") && l.contains("G64 P0.0004"))
        #expect(l.contains("T5 M6") && l.contains("G43 H5"))   // M6 leaves the length alone on LinuxCNC
        #expect(l.contains("M8") && l.contains("G4 P0.50"))
        let (mm, _) = try gcode(.linuxCNC, units: .mm)
        #expect(lines(mm).contains("G64 P0.010"))
    }

    @Test func masso() throws {
        let (g, post) = try gcode(.masso)
        let l = lines(g)
        #expect(post.fileExtension == "nc")
        #expect(l.contains("G4 P500"))   // milliseconds: half a second
        #expect(!l.contains { $0.hasPrefix("G43") || $0.hasPrefix("G64") || $0 == "G91.1" })
        #expect(l.contains("T5 M6"))
        // Read back as milliseconds, the dwell is still half a second.
        let program = try GCodeParser.parse(g, dwellUnit: post.dialect.dwell.parserUnit)
        #expect(program.segments.flatMap(\.motions).filter { $0.kind == .dwell }.map(\.feed) == [0.5])
    }

    @Test func centroidForAvidEX() throws {
        let (g, post) = try gcode(.centroid)
        let l = lines(g)
        #expect(post.fileExtension == "cnc" && g.contains("\r\n"))
        #expect(l.contains("T5 M6") && l.contains("G43 H5"))
        #expect(l.contains("M7") && l.contains("G4 P0.50"))
        // The Avid PRO catalogue entries offer EX, which now gets this post.
        let pro = try #require(MachineCatalogue.builtIn.entries.first { $0.id == "avid-pro6060" })
        let ex = try #require(pro.controllers.first { $0.family == "centroid" })
        let machine = pro.profile(controller: ex)
        #expect(PostProcessors.post(for: Project(machine: machine))?.dialect.id == "centroid")
        #expect(machine.summary.contains { $0.contains("G43 H#") })
    }

    @Test func buildbotics() throws {
        let (g, post) = try gcode(.buildbotics)
        let l = lines(g)
        #expect(post.fileExtension == "nc")
        #expect(l.contains("G91.1") && l.contains("T5 M6"))
        #expect(!l.contains { $0.hasPrefix("G43") })
    }
}
