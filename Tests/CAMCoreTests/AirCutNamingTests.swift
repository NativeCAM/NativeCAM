import Foundation
import Testing
@testable import CAMCore

/// #192: every air-cut file is named " (air cut)" and says AIR CUT on its first line, whichever path writes it (the
/// full job, a group or chosen toolpaths, a restart, from the command line or the app), and no air cut is written under
/// a real cut's name or over one. The inputs are in `Fixtures/air-cut-names` (see its README).
struct AirCutNamingTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("air-cut-names")

    /// `names.txt`: the expected file name for each path.
    static func expected(_ path: String) throws -> String {
        let text = try String(contentsOf: fixtures.appendingPathComponent("names.txt"), encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix(path + ": ") })
        return String(line.dropFirst(path.count + 2))
    }

    static func firstLine(_ gcode: String) -> String { String(gcode.split(whereSeparator: \.isNewline).first ?? "") }

    /// The grouped sign saved as "Grouped sign.nativecam" in a fresh folder.
    static func groupedSign() throws -> (dir: URL, project: URL) {
        let dir = try CommandLineTests.folder()
        let project = dir.appendingPathComponent("Grouped sign.nativecam")
        try FileManager.default.copyItem(at: GoldenPostTests.projects.appendingPathComponent("toolpath-groups-v1.nativecam"), to: project)
        return (dir, project)
    }

    static func files(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tap") })
    }

    // MARK: The command line

    /// `post --group --air-cut` writes "<project> - <group> (air cut).tap", AIR CUT first, and the real file beside it
    /// under its own name: neither overwrites the other.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func commandLineGroupAirCutIsNamedAndMarked() throws {
        let (dir, project) = try Self.groupedSign()
        defer { try? FileManager.default.removeItem(at: dir) }
        let air = try CommandLineTests.run(["post", project.path, "--group", "Finish", "--air-cut", "1"])
        #expect(air.status == 0, "\(air.output)")
        let airName = try Self.expected("cli group")
        #expect(try Self.files(in: dir) == [airName])
        let airText = try String(contentsOf: dir.appendingPathComponent(airName), encoding: .ascii)
        #expect(Self.firstLine(airText) == "(AIR CUT: Z raised 1.0000 in, X and Y unchanged)")
        #expect(airText.contains("(PART OF Grouped sign: group 'Finish')"))

        let real = try CommandLineTests.run(["post", project.path, "--group", "Finish"])
        #expect(real.status == 0, "\(real.output)")
        let realName = try Self.expected("cli group real")
        #expect(try Self.files(in: dir) == [airName, realName])
        let realText = try String(contentsOf: dir.appendingPathComponent(realName), encoding: .ascii)
        #expect(!AirCut.isAirCut(realText))
        // The air cut is still the air cut.
        #expect(try String(contentsOf: dir.appendingPathComponent(airName), encoding: .ascii) == airText)
    }

    /// `post --toolpaths --air-cut -o part.tap` adds " (air cut)" as `post --air-cut -o` does, and doesn't write it twice
    /// when the name already has it.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func commandLineToolpathsAirCutFollowsTheOutputName() throws {
        let (dir, project) = try Self.groupedSign()
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = try CommandLineTests.run(["post", project.path, "--toolpaths", "1", "--air-cut", "1", "-o", dir.appendingPathComponent("part.tap").path])
        #expect(run.status == 0, "\(run.output)")
        let name = try Self.expected("cli toolpaths -o part.tap")
        #expect(try Self.files(in: dir) == [name])
        let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .ascii)
        #expect(Self.firstLine(text).hasPrefix("(AIR CUT: Z raised"))
        #expect(text.contains("(PART OF Grouped sign: toolpath 'Pocket plaque')"))

        let again = try CommandLineTests.run(["post", project.path, "--toolpaths", "1", "--air-cut", "1",
                                             "-o", dir.appendingPathComponent("part (air cut).tap").path])
        #expect(again.status == 0, "\(again.output)")
        #expect(try Self.files(in: dir) == [try Self.expected("cli toolpaths -o part (air cut).tap")])
    }

    /// `post --restart-* --air-cut` names the restart " (air cut) (restart at …)".
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func commandLineRestartAirCutIsNamed() throws {
        let (dir, project) = try Self.groupedSign()
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = try CommandLineTests.run(["post", project.path, "--restart-toolpath", "2", "--air-cut", "1"])
        #expect(run.status == 0, "\(run.output)")
        let name = try Self.expected("cli restart")
        #expect(try Self.files(in: dir) == [name])
        #expect(AirCut.isAirCut(try String(contentsOf: dir.appendingPathComponent(name), encoding: .ascii)))
    }

    /// An air cut that would land on a real cut, or a real cut named as an air cut, is refused: exit 1, nothing written,
    /// the file already there untouched.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func commandLineRefusesACollision() throws {
        let (dir, project) = try Self.groupedSign()
        defer { try? FileManager.default.removeItem(at: dir) }
        let standIn = dir.appendingPathComponent("part (air cut).tap")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("real-cut.tap"), to: standIn)
        let before = try Data(contentsOf: standIn)
        for subset in [["--group", "Finish"], ["--toolpaths", "1"], []] {
            let run = try CommandLineTests.run(["post", project.path] + subset + ["--air-cut", "1", "-o", dir.appendingPathComponent("part.tap").path,
                                                                                    "--sheet", dir.appendingPathComponent("part.html").path])
            #expect(run.status == 1, "\(subset): \(run.output)")
            #expect(run.output.contains("Not written: “part (air cut).tap” already exists and isn't an air cut"), "\(run.output)")
        }
        #expect(try Data(contentsOf: standIn) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Grouped sign.nativecam", "part (air cut).tap"])

        // A real cut under an air cut's name.
        for subset in [["--group", "Finish"], []] {
            let run = try CommandLineTests.run(["post", project.path] + subset + ["-o", dir.appendingPathComponent("finish (air cut).tap").path])
            #expect(run.status == 1, "\(subset): \(run.output)")
            #expect(run.output.contains("says it's an air cut, but this file cuts at full depth"), "\(run.output)")
        }
        #expect(try Self.files(in: dir) == ["part (air cut).tap"])
    }

    // MARK: What the app writes

    /// Export Group… and Export G-code's air cut name their files with `AirCut.paths` from the name chosen in the save
    /// panel: " (air cut)" is kept, put back when it was taken out, and the group's file says AIR CUT first.
    @Test func appGroupAirCutIsNamedAndMarked() throws {
        let p = try Project.decode(Data(contentsOf: GoldenPostTests.projects.appendingPathComponent("toolpath-groups-v1.nativecam")))
        let finish = try #require(p.toolpathGroups.first { $0.name == "Finish" })
        var request = try #require(JobSubset.Request.group(finish.id, in: p))
        request.airCut = 1.inch
        let subset = try ToolpathGroupsTests.subset(p, request)
        #expect(subset.files.count == 1)
        #expect(Self.firstLine(subset.files[0].gcode) == "(AIR CUT: Z raised 1.0000 in, X and Y unchanged)")
        #expect(subset.files[0].gcode.contains("(PART OF Grouped sign: group 'Finish')"))
        let ext = subset.post.fileExtension
        // The panel's suggestion, "Grouped sign - Finish (air cut).tap", and the same with the marker taken out.
        #expect(AirCut.paths(subset.files, stem: "Grouped sign - Finish (air cut)", airCut: true, fileExtension: ext)
                == [try Self.expected("app group, name kept")])
        #expect(AirCut.paths(subset.files, stem: "Grouped sign - Finish", airCut: true, fileExtension: ext)
                == [try Self.expected("app group, marker taken out")])
        // The real group's file keeps the chosen name.
        let real = try ToolpathGroupsTests.subset(p, try #require(JobSubset.Request.group(finish.id, in: p)))
        #expect(AirCut.paths(real.files, stem: "Grouped sign - Finish", airCut: false, fileExtension: ext) == ["Grouped sign - Finish.tap"])
        #expect(!AirCut.isAirCut(real.files[0].gcode))

        // The whole job's air cut, saved as "Grouped sign.tap".
        let job = try #require(JobExport.files(p, job: CAMEngine.generate(p), airCut: 1.inch, date: GoldenPostTests.date))
        #expect(AirCut.paths(job.files, stem: "Grouped sign", airCut: true, fileExtension: ext) == [try Self.expected("app job, marker taken out")])
    }

    /// A restart's air cut is named " (air cut) (restart at …)" and says AIR CUT in its header; it can't share a name with
    /// the real restart or with the full job's files.
    @Test func restartAirCutIsNamedAndMarked() throws {
        let p = try RestartTests.fixture("sign")
        let air = try RestartTests.restart(p, Restart.Request(toolpath: 1, airCut: 1.inch))
        let real = try RestartTests.restart(p, Restart.Request(toolpath: 1))
        #expect(air.file.suffix == " (air cut) (restart at toolpath 2)")
        #expect(real.file.suffix == " (restart at toolpath 2)")
        #expect(AirCut.isAirCut(air.file.gcode) && !AirCut.isAirCut(real.file.gcode))
        let names = ["Sign" + air.file.suffix! + ".tap", "Sign" + real.file.suffix! + ".tap", "Sign.tap", "Sign (air cut).tap"]
        #expect(Set(names).count == names.count)
        let none: (String) -> String? = { _ in nil }
        #expect(AirCut.namingProblem([names[0]], airCut: true, existing: none) == nil)
        #expect(AirCut.namingProblem([names[1]], airCut: false, existing: none) == nil)
    }

    /// The rule on its own: a real cut can't be called an air cut, an air cut must be, an air cut never replaces a file
    /// that isn't one (or one that can't be read), and two files can't share a name.
    @Test func namingRule() throws {
        let realCut = try String(contentsOf: Self.fixtures.appendingPathComponent("real-cut.tap"), encoding: .ascii)
        let none: (String) -> String? = { _ in nil }
        let real: (String) -> String? = { _ in realCut }
        let unreadable: (String) -> String? = { _ in "" }
        let air: (String) -> String? = { _ in "(AIR CUT: Z raised 1.0000 in)\nM30\n" }
        #expect(AirCut.namingProblem(["/a/Sign (air cut).tap"], airCut: false, existing: none)?.contains("cuts at full depth") == true)
        #expect(AirCut.namingProblem(["/a/Sign AIR CUT.tap"], airCut: false, existing: none) != nil)
        #expect(AirCut.namingProblem(["/a/Sign.tap"], airCut: true, existing: none)?.contains("doesn't say it's an air cut") == true)
        #expect(AirCut.namingProblem(["/a/Sign (air cut).tap"], airCut: true, existing: real)?.contains("isn't an air cut") == true)
        #expect(AirCut.namingProblem(["/a/Sign (air cut).tap"], airCut: true, existing: unreadable) != nil)
        #expect(AirCut.namingProblem(["/a/Sign (air cut).tap"], airCut: true, existing: air) == nil)
        #expect(AirCut.namingProblem(["/a/x.tap", "/a/X.tap"], airCut: false, existing: none)?.contains("Two files") == true)
        #expect(AirCut.namingProblem(["/a/Sign.tap"], airCut: false, existing: real) == nil)
    }
}
