import Foundation
import Testing
@testable import CAMCore

/// #151: a program larger than the machine's travel, in X, Y or Z with the tool's stickout, is an error, so `post`
/// refuses it without `--force` and Export asks first. A cut deeper than the bit's stickout (the collet nut would hit
/// the stock) is an error; deeper than its flutes but within the stickout stays a warning.
struct TravelCheckTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("travel")

    static func fixture(_ name: String) throws -> Project {
        try Project.decode(Data(contentsOf: fixtures.appendingPathComponent(name + ".nativecam")))
    }

    /// Every issue the export checks find in the project's files.
    static func checks(_ project: Project) -> [GCodeCheck.Issue] {
        let job = CAMEngine.generate(project)
        guard let output = JobExport.files(project, job: job, airCut: nil) else { return [] }
        return output.files.flatMap {
            GCodeCheck.run($0.gcode, toolpaths: $0.toolpaths, project: $0.project, dialect: output.post.dialect)
        }
    }

    static func errors(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity == .error }.map(\.message) }

    @Test func overTravelInEachAxisIsAnError() {
        let fits = Self.errors(Self.checks(Project.demoSign()))
        #expect(fits.isEmpty, "\(fits)")
        for (axis, travel) in [("X", Vec3(300, 2000, 400)), ("Y", Vec3(2000, 300, 400)), ("Z", Vec3(2000, 2000, 60))] {
            var p = Project.demoSign()
            p.machine.travel = travel
            let errors = Self.errors(Self.checks(p))
            let label = axis == "Z" ? "of Z travel" : "of \(axis) travel"
            #expect(errors.count == 1, "\(axis): \(errors)")
            #expect(errors.contains { $0.contains(label) && $0.contains("more than the machine's") }, "\(axis): \(errors)")
        }
    }

    @Test func overrunIsNamed() throws {
        let errors = Self.errors(Self.checks(try Self.fixture("over-x")))
        let x = try #require(errors.first { $0.contains("X travel") }, "\(errors)")
        // 78.05 in of X against 61.375 in of travel: 16.68 in over.
        #expect(x.contains("in more than the machine's 61.3750 in of X travel"), "\(x)")
        #expect(!errors.contains { $0.contains("Y travel") || $0.contains("Z travel") }, "\(errors)")
    }

    @Test func overZIsAnError() throws {
        let errors = Self.errors(Self.checks(try Self.fixture("over-z")))
        #expect(errors.contains { $0.contains("of Z travel") }, "\(errors)")
        #expect(!errors.contains { $0.contains("X travel") || $0.contains("Y travel") }, "\(errors)")
    }

    @Test func justInsideTheTravelIsClean() throws {
        let p = try Self.fixture("just-inside-travel")
        #expect(!CAMEngine.generate(p).hasErrors)
        let errors = Self.errors(Self.checks(p))
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func colletPastStickoutIsAnErrorFlutesOnlyAWarning() throws {
        let deep = CAMEngine.generate(try Self.fixture("collet-past-stickout"))
        #expect(deep.issues.contains { $0.severity == .error && $0.message.contains("collet nut would hit the stock") },
                "\(deep.issues.map(\.message))")
        #expect(!deep.issues.contains { $0.message.contains("exceeds the cutting length") })

        // Past the flutes but within the stickout: a warning only.
        var p = Project.demoSign()
        let i = try #require(p.operations.firstIndex { if case .profile = $0.kind { true } else { false } })
        let tool = p.operations[i].tool
        guard case var .profile(params) = p.operations[i].kind else { return }
        params.depth.cutDepth = (tool.fluteLength + tool.stickout) / 2
        p.operations[i].kind = .profile(params)
        let job = CAMEngine.generate(p)
        let name = p.operations[i].name
        #expect(job.issues.contains { $0.operation == name && $0.severity == .warning && $0.message.contains("exceeds the cutting length") },
                "\(job.issues.map(\.message))")
        #expect(!job.issues.contains { $0.operation == name && $0.severity == .error }, "\(job.issues.map(\.message))")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func postRefusesOverTravelUnlessForced() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Self.fixtures.appendingPathComponent("over-x.nativecam").path
        let out = dir.appendingPathComponent("over-x.tap")
        let refused = try CommandLineTests.run(["post", project, "-o", out.path])
        #expect(refused.status != 0, "\(refused.output)")
        #expect(!FileManager.default.fileExists(atPath: out.path), "wrote the file anyway")
        #expect(refused.output.contains("[error] G-code: The program moves 78.0541 in in X"), "\(refused.output)")
        #expect(refused.output.contains("16.6791 in more than the machine's 61.3750 in of X travel"), "\(refused.output)")
        #expect(refused.output.contains("Not written: the G-code failed 1 check."), "\(refused.output)")

        let forced = try CommandLineTests.run(["post", project, "-o", out.path, "--force"])
        #expect(forced.status == 0, "\(forced.output)")
        #expect(forced.output.contains("[error] G-code: The program moves 78.0541 in in X"), "\(forced.output)")
        #expect(forced.output.contains("Writing it anyway (--force): the G-code failed 1 check."), "\(forced.output)")
        #expect(try String(contentsOf: out, encoding: .ascii).contains("M30"))

        let inside = dir.appendingPathComponent("inside.tap")
        let fits = try CommandLineTests.run(["post", Self.fixtures.appendingPathComponent("just-inside-travel.nativecam").path,
                                             "-o", inside.path])
        #expect(fits.status == 0, "\(fits.output)")
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    /// No demo or saved fixture (flat, tiled, nested, rotary, wrapped, along Y) trips the new errors.
    @Test func demosAndFixturesStayFreeOfTravelErrors() throws {
        // The frames and coasters demo (`demoNestingSheets`) is laid out to be nested first: as it opens its cut-out is
        // already larger than the work area by the per-toolpath check. Nested, it's the nesting-multisheet fixture.
        #expect(CAMEngine.generate(.demoNestingSheets()).issues.contains { $0.severity == .error && $0.message.contains("work area") })
        var projects: [(String, Project)] = [("sign", .demoSign()), ("relief", .demoRelief()), ("pawn", .demoPawn()),
                                             ("table leg", .demoTableLeg()), ("nesting", .demoNesting())]
        let root = Self.fixtures.deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        // `travel` and `flute-reach` (#203) hold fixtures made to trip these errors.
        for url in files where url.pathExtension == "nativecam" && !["travel", "flute-reach"].contains(url.deletingLastPathComponent().lastPathComponent) {
            guard let p = try? Project.decode(Data(contentsOf: url)) else { continue }
            projects.append((url.lastPathComponent, p))
        }
        #expect(projects.count > 20)
        let ours = ["travel.", "collet nut would hit"]
        for (name, p) in projects {
            let job = CAMEngine.generate(p)
            let jobHits = job.issues.filter { i in i.severity == .error && ours.contains { i.message.contains($0) } }.map(\.message)
            #expect(jobHits.isEmpty, "\(name): \(jobHits)")
            let fileHits = Self.errors(Self.checks(p)).filter { m in ours.contains { m.contains($0) } }
            #expect(fileHits.isEmpty, "\(name): \(fileHits)")
        }
    }
}
