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
}
