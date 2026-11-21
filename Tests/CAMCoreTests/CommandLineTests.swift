import Foundation
import Testing
@testable import CAMCore

/// `nativecam-cli`, run as a user runs it. `swift test` builds it next to the test bundle.
struct CommandLineTests {
    static var cli: URL { Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("nativecam-cli") }

    struct Run {
        var status: Int32
        var output: String
    }

    static func run(_ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs the tool with standard output and standard error kept apart.
    static func runSplit(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Small outputs: read one, then the other, after the process ends.
        process.waitUntilExit()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// A fresh folder for one test's files.
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nativecam-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The demo sign with a clamp over a mounting hole: a job-check error ("Cuts into a clamp"), in G-code that
    /// passes its own checks.
    static func clampedSign() throws -> Project {
        var project = Project.demoSign()
        let hole = try #require(project.shapes.first { $0.name == "Mounting hole 1" })
        var clamp = DesignShape(name: "Clamp", kind: .rectangle(width: 1.inch, height: 1.inch, cornerRadius: 0), position: hole.position)
        clamp.keepOutHeight = 0.25.inch
        project.shapes.append(clamp)
        return project
    }

    @Test func cliIsBuilt() {
        #expect(FileManager.default.isExecutableFile(atPath: Self.cli.path), "no nativecam-cli at \(Self.cli.path)")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: cli.path)))
    func postRefusesAJobWithErrorsUnlessForced() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("clamped.nativecam"), out = dir.appendingPathComponent("clamped.tap")
        let sign = try Self.clampedSign()
        #expect(CAMEngine.generate(sign).hasErrors)
        try sign.encoded().write(to: project)

        let refused = try Self.run(["post", project.path, "-o", out.path])
        #expect(refused.status != 0, "\(refused.output)")
        #expect(!FileManager.default.fileExists(atPath: out.path), "wrote the file anyway")
        #expect(refused.output.contains("[error] Drill mounting holes: Cuts into a clamp / keep-out zone."), "\(refused.output)")
        #expect(refused.output.contains("Not written: the job has 1 error."), "\(refused.output)")
        #expect(!refused.output.contains("G-code failed"), "\(refused.output)")

        let forced = try Self.run(["post", project.path, "-o", out.path, "--force"])
        #expect(forced.status == 0, "\(forced.output)")
        #expect(forced.output.contains("Writing it anyway (--force): the job has 1 error."), "\(forced.output)")
        let written = try String(contentsOf: out, encoding: .ascii)
        #expect(written.contains("M30"), "\(written.prefix(200))")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: cli.path)))
    func postWritesAJobWithOnlyWarnings() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("warned.nativecam"), out = dir.appendingPathComponent("warned.tap")
        var sign = Project.demoSign()
        let bit = try #require(sign.operations.first).tool
        sign.operations.append(CAMOperation(name: "Empty pocket", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))),
                                            shapeIDs: [], tool: bit))
        let job = CAMEngine.generate(sign)
        #expect(!job.hasErrors)
        #expect(job.issues.contains { $0.severity == .warning })
        try sign.encoded().write(to: project)

        let run = try Self.run(["post", project.path, "-o", out.path])
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("[warning] Empty pocket: No shapes selected."), "\(run.output)")
        #expect(!run.output.contains("Not written"), "\(run.output)")
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
    @Test func templatesSaveAndApplyFromTheCommandLine() throws {
        let dir = try Self.folder()
        var sign = Project.demoSign()
        for i in sign.shapes.indices where sign.shapes[i].name == "Sign outline" { sign.shapes[i].layer = "Cut Out" }
        let source = dir.appendingPathComponent("sign.nativecam")
        try sign.encoded().write(to: source)
        let template = dir.appendingPathComponent("Sign.nativecamtemplate")
        let saved = try Self.run(["template", "save", source.path, "-o", template.path])
        #expect(saved.status == 0, "\(saved.output)")
        #expect(saved.output.contains("Cut out sign: Layer “Cut Out”"))

        var board = sign
        board.operations = []
        board.stock.thickness = 0.5.inch
        let target = dir.appendingPathComponent("board.nativecam")
        try board.encoded().write(to: target)
        let out = dir.appendingPathComponent("applied.nativecam")
        let applied = try Self.run(["template", "apply", template.path, target.path, "-o", out.path])
        #expect(applied.status == 0, "\(applied.output)")
        #expect(applied.output.contains("T1 1/4\" Upcut End Mill: in the library"))
        let result = try Project.decode(Data(contentsOf: out))
        #expect(result.operations.count == 4)
        guard case let .profile(cut)? = result.operations.last?.kind else { Issue.record("no profile"); return }
        #expect(abs(cut.depth.cutDepth - 0.52.inch) < 1e-9)
    }
    /// `template apply` never writes over the project unless told to (#63), and counts in the singular for one (#64).
    @Test func applyingATemplateKeepsTheProjectUnlessTold() throws {
        let dir = try Self.folder()
        var sign = Project.demoSign()
        for i in sign.shapes.indices where sign.shapes[i].name == "Sign outline" { sign.shapes[i].layer = "Cut Out" }
        let source = dir.appendingPathComponent("sign.nativecam")
        try sign.encoded().write(to: source)
        let template = dir.appendingPathComponent("Sign.nativecamtemplate")
        #expect(try Self.run(["template", "save", source.path, "-o", template.path]).status == 0)

        var board = sign
        board.operations = []
        let target = dir.appendingPathComponent("board.nativecam")
        let original = try board.encoded()
        try original.write(to: target)

        // No -o: a new file beside the project, which stays as it was.
        let first = try Self.run(["template", "apply", template.path, target.path])
        #expect(first.status == 0, "\(first.output)")
        let made = dir.appendingPathComponent("board + Sign.nativecam")
        #expect(first.output.contains("Wrote \(made.path)"))
        #expect(try Data(contentsOf: target) == original)
        #expect(try Project.decode(Data(contentsOf: made)).operations.count == 4)
        // Plurals: one outline on Cut Out, and only the pocket (bound to the selection) found nothing.
        #expect(first.output.contains("Cut out sign: Layer “Cut Out”: 1 vector\n"))
        #expect(first.output.contains("1 toolpath found no vectors"))
        #expect(!first.output.contains("1 vectors"))

        // Run again: the next free name.
        let second = try Self.run(["template", "apply", template.path, target.path])
        #expect(second.output.contains("Wrote \(dir.appendingPathComponent("board + Sign 2.nativecam").path)"))
        #expect(try Data(contentsOf: target) == original)

        // --in-place overwrites the project; with -o as well it refuses before doing anything (#67): nothing on
        // standard output, the reason on standard error, and no file touched.
        let madeBefore = try Data(contentsOf: made)
        let both = try Self.runSplit(["template", "apply", template.path, target.path, "-o", made.path, "--in-place"])
        #expect(both.status != 0)
        #expect(both.stdout.isEmpty, "\(both.stdout)")
        #expect(both.stderr.contains("Pass -o or --in-place, not both."))
        #expect(try Data(contentsOf: made) == madeBefore)
        #expect(try Data(contentsOf: target) == original)
        let inPlace = try Self.run(["template", "apply", template.path, target.path, "--in-place"])
        #expect(inPlace.status == 0, "\(inPlace.output)")
        #expect(try Project.decode(Data(contentsOf: target)).operations.count == 4)
    }
}
