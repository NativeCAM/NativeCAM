import Foundation
import Testing
@testable import CAMCore

/// #200: spoilboard surfacing's air cut is named `<file> (air cut).<ext>` like every other air cut (`Surfacing.paths`,
/// through `AirCut.paths`), and `AirCut.namingProblem`'s refusals apply to it: a program named as an air cut, and an
/// air cut over a file that isn't one. The command line and the app's sheet both name and check the files this way.
/// The inputs are in `Fixtures/surfacing-air-cut` (see its README).
struct SurfacingAirCutNamingTests {
    static let fixtures = GoldenPostTests.fixtures.appendingPathComponent("surfacing-air-cut")

    /// `names.txt`: the program's and the air cut's file names for a case.
    static func expected(_ key: String) throws -> (program: String, airCut: String) {
        let text = try String(contentsOf: fixtures.appendingPathComponent("names.txt"), encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix(key + ": ") })
        let parts = line.dropFirst(key.count + 2).components(separatedBy: " | ")
        try #require(parts.count == 2)
        return (parts[0], parts[1])
    }

    static func realCut() throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent("real-cut.tap"), encoding: .ascii)
    }

    @Test func namesFollowEveryOtherAirCut() throws {
        let program = try SurfacingTests.program()
        let byDefault = try Self.expected("default")
        let paths = Surfacing.paths(program.fileName, fileExtension: program.fileExtension)
        var got: [(String, String, String)] = [("default", paths.program, paths.airCut)]
        var want: [(String, String, String)] = [("default", byDefault.program, byDefault.airCut)]
        for key in ["-o board.tap", "-o board", "-o board.nc"] {
            let p = Surfacing.paths(String(key.dropFirst(3)), fileExtension: program.fileExtension)
            let e = try Self.expected(key)
            got.append((key, p.program, p.airCut))
            want.append((key, e.program, e.airCut))
        }
        let grbl = try SurfacingTests.program(SurfacingTests.controller(.grbl)) { $0.area = .custom(Vec2(300, 300)) }
        let g = Surfacing.paths("grbl", fileExtension: grbl.fileExtension)
        let eg = try Self.expected("grbl -o grbl")
        got.append(("grbl", g.program, g.airCut))
        want.append(("grbl", eg.program, eg.airCut))
        for (a, b) in zip(got, want) {
            #expect(a.1 == b.1, "\(a.0): program")
            #expect(a.2 == b.2, "\(a.0): air cut")
        }

        #expect(program.fileName == byDefault.program)
        #expect(program.airFileName == byDefault.airCut)
        // A folder in the path stays, and " (air cut)" isn't written twice.
        let inFolder = Surfacing.paths("/jobs/board.tap", fileExtension: "tap")
        #expect(inFolder.program == "/jobs/board.tap")
        #expect(inFolder.airCut == "/jobs/board (air cut).tap")
        // The default names pass every rule.
        let none: (String) -> String? = { _ in nil }
        let problem = Surfacing.namingProblem(paths, airCut: true, existing: none)
        #expect(problem == nil)
        // The air cut says so at the top; the program and the stand-in real cut don't.
        #expect(AirCut.isAirCut(program.airGCode))
        #expect(!AirCut.isAirCut(program.gcode))
        #expect(!AirCut.isAirCut(try Self.realCut()))
    }

    @Test func collidingNamesAreRefused() throws {
        let realCut = try Self.realCut()
        let program = try SurfacingTests.program { $0.area = .custom(Vec2(12.inch, 12.inch)) }
        let board = Surfacing.paths("board.tap", fileExtension: "tap")
        let none: (String) -> String? = { _ in nil }
        let realAtAirCut: (String) -> String? = { $0 == board.airCut ? realCut : nil }
        let airCutAtAirCut: (String) -> String? = { $0 == board.airCut ? program.airGCode : nil }
        let realAtProgram: (String) -> String? = { $0 == board.program ? realCut : nil }

        let clear = Surfacing.namingProblem(board, airCut: true, existing: none)
        // A real cut where the air cut would go: refused, unless no air cut is written.
        let overReal = Surfacing.namingProblem(board, airCut: true, existing: realAtAirCut)
        let overRealNoAirCut = Surfacing.namingProblem(board, airCut: false, existing: realAtAirCut)
        // An earlier air cut there is replaced, and so is an earlier program at the program's name.
        let overAirCut = Surfacing.namingProblem(board, airCut: true, existing: airCutAtAirCut)
        let overProgram = Surfacing.namingProblem(board, airCut: true, existing: realAtProgram)
        // A program named as an air cut is refused, with or without the air cut (which would take the same name).
        let named = Surfacing.paths("board (air cut).tap", fileExtension: "tap")
        let namedProblem = Surfacing.namingProblem(named, airCut: true, existing: none)
        let namedNoAirCut = Surfacing.namingProblem(named, airCut: false, existing: none)
        let aircut = Surfacing.namingProblem(Surfacing.paths("aircut-board.tap", fileExtension: "tap"), airCut: false, existing: none)

        #expect(clear == nil)
        #expect(overReal?.hasPrefix("“board (air cut).tap” already exists and isn't an air cut") == true, "\(overReal ?? "nil")")
        #expect(overRealNoAirCut == nil)
        #expect(overAirCut == nil)
        #expect(overProgram == nil)
        #expect(named.program == named.airCut)
        #expect(namedProblem?.hasPrefix("“board (air cut).tap” says it's an air cut, but this file cuts at full depth") == true,
                "\(namedProblem ?? "nil")")
        #expect(namedNoAirCut == namedProblem)
        #expect(aircut?.contains("says it's an air cut") == true, "\(aircut ?? "nil")")
    }
}

/// `nativecam-cli surface`'s air cut, run as a user runs it.
struct SurfacingAirCutNamingCommandLineTests {
    static func files(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func surfaceNamesItsAirCutAndRefusesCollisions() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let board = try SurfacingAirCutNamingTests.expected("-o board.tap")
        let small = ["surface", "--area", "12x12"]

        // board.tap and "board (air cut).tap", the air cut marked at the top; run again, it replaces its own files.
        let first = try CommandLineTests.run(small + ["-o", dir.appendingPathComponent("board.tap").path])
        let afterFirst = try Self.files(in: dir)
        let airText = try String(contentsOf: dir.appendingPathComponent(board.airCut), encoding: .ascii)
        let realText = try String(contentsOf: dir.appendingPathComponent(board.program), encoding: .ascii)
        let again = try CommandLineTests.run(small + ["-o", dir.appendingPathComponent("board").path])

        // A real cut already where the air cut would go: nothing is written, and it's untouched.
        let real = try SurfacingAirCutNamingTests.realCut()
        try real.write(to: dir.appendingPathComponent("other (air cut).tap"), atomically: true, encoding: .ascii)
        let refused = try CommandLineTests.run(small + ["-o", dir.appendingPathComponent("other.tap").path])
        let afterRefused = try Self.files(in: dir)
        let stillReal = try String(contentsOf: dir.appendingPathComponent("other (air cut).tap"), encoding: .ascii)
        // Without the air cut, the program is written beside it.
        let noAirCut = try CommandLineTests.run(small + ["--no-air-cut", "-o", dir.appendingPathComponent("other.tap").path])
        let stillRealAfter = try String(contentsOf: dir.appendingPathComponent("other (air cut).tap"), encoding: .ascii)

        // A program named as an air cut: refused, with or without the air cut.
        let named = try CommandLineTests.run(small + ["-o", dir.appendingPathComponent("named (air cut).tap").path])
        let namedNoAirCut = try CommandLineTests.run(small + ["--no-air-cut", "-o", dir.appendingPathComponent("named (air cut).tap").path])

        // Another controller's extension.
        let grblNames = try SurfacingAirCutNamingTests.expected("grbl -o grbl")
        let grbl = try CommandLineTests.run(["surface", "--controller", "grbl", "--units", "mm", "--area", "300x300",
                                             "-o", dir.appendingPathComponent("grbl").path])
        let afterAll = try Self.files(in: dir)

        #expect(first.status == 0, "\(first.output)")
        #expect(afterFirst == [board.program, board.airCut])
        #expect(first.output.contains("Air cut (Z raised 1 in) -> " + dir.appendingPathComponent(board.airCut).path), "\(first.output)")
        #expect(AirCut.isAirCut(airText))
        #expect(!AirCut.isAirCut(realText))
        #expect(again.status == 0, "\(again.output)")

        #expect(refused.status == 1)
        #expect(refused.output.contains("Not written: “other (air cut).tap” already exists and isn't an air cut"), "\(refused.output)")
        #expect(afterRefused == afterFirst.union(["other (air cut).tap"]))
        #expect(stillReal == real)
        #expect(noAirCut.status == 0, "\(noAirCut.output)")
        #expect(stillRealAfter == real)

        #expect(named.status == 1)
        #expect(named.output.contains("Not written: “named (air cut).tap” says it's an air cut"), "\(named.output)")
        #expect(namedNoAirCut.status == 1)
        #expect(namedNoAirCut.output.contains("says it's an air cut"), "\(namedNoAirCut.output)")

        #expect(grbl.status == 0, "\(grbl.output)")
        #expect(afterAll == afterFirst.union(["other (air cut).tap", "other.tap", grblNames.program, grblNames.airCut]))
    }
}
