import Foundation
import Testing
@testable import CAMCore

/// Stage 6 of machine support: importing a Vectric post (.pp) and running it as a template. The posts here are
/// written for these tests in Vectric's format; no vendor post is copied.
struct VectricPostTests {
    /// Shaped like an Avid Mach4 post: same safety line, tool change, spindle and move words.
    static let mach4Style = """
    + Test post written for NativeCAM's tests, not a vendor post.
    POST_NAME = "Test Mach4 (inch) (*.tap)"
    FILE_EXTENSION = "tap"
    UNITS = "INCHES"
    LINE_ENDING = "[13][10]"
    SUBSTITUTE = "({)}"
    VAR SPINDLE_SPEED = [S|A|S|1.0]
    VAR FEED_RATE = [F|C| F|1.1]
    VAR X_POSITION = [X|C| X|1.4]
    VAR Y_POSITION = [Y|C| Y|1.4]
    VAR Z_POSITION = [Z|C| Z|1.4]
    VAR ARC_CENTRE_I_INC_POSITION = [I|A| I|1.4]
    VAR ARC_CENTRE_J_INC_POSITION = [J|A| J|1.4]
    VAR X_HOME_POSITION = [XH|A|X|1.4]
    VAR Y_HOME_POSITION = [YH|A|Y|1.4]
    VAR Z_HOME_POSITION = [ZH|A|Z|1.4]
    VAR SAFE_Z_HEIGHT = [SAFEZ|A|Z|1.4]
    VAR DWELL_TIME = [DWELL|A|P|1.2]
    VAR TOOL_NUMBER = [T|A|T|1.0]
    begin HEADER
    "([TP_FILENAME])"
    "(Tools: [TOOLS_USED])"
    "G00 G94 G20 G17 G90 G40 G49 G80"
    "G91.1"
    "G64"
    "[T]M6"
    "M07"
    begin SPINDLE_ON
    "[S] M03"
    begin TOOLCHANGE
    "G00 [SAFEZ]"
    "M05"
    "[T]M6"
    "G90 G91.1 G64"
    "M07"
    begin NEW_SEGMENT
    "[S] M03"
    begin INITIAL_RAPID_MOVE
    "G00[X][Y][Z]"
    begin RAPID_MOVE
    "G00[X][Y][Z]"
    begin FEED_MOVE
    "G01[X][Y][Z][F]"
    begin CW_ARC_MOVE
    "G02[X][Y][Z][I][J][F]"
    begin CCW_ARC_MOVE
    "G03[X][Y][Z][I][J][F]"
    begin DWELL_MOVE
    "G04 [DWELL]"
    begin FOOTER
    "G00 [ZH]"
    "G00 [XH] [YH]"
    "M05"
    "M09"
    "M30"
    """

    /// Shaped like a Grbl post: mm, LF, no arcs and no tool changes (Vectric's own Grbl posts leave arcs out).
    static let grblStyle = """
    POST_NAME = "Test Grbl (mm) (*.gcode)"
    FILE_EXTENSION = "gcode"
    UNITS = "MM"
    LINE_ENDING = "[10]"
    VAR SPINDLE_SPEED = [S|A|S|1.0]
    VAR FEED_RATE = [F|C|F|1.0]
    VAR X_POSITION = [X|C|X|1.3]
    VAR Y_POSITION = [Y|C|Y|1.3]
    VAR Z_POSITION = [Z|C|Z|1.3]
    begin HEADER
    "G90 G94 G17"
    "G21"
    begin SPINDLE_ON
    "[S]M3"
    begin RAPID_MOVE
    "G0[X][Y][Z]"
    begin FEED_MOVE
    "G1[X][Y][Z][F]"
    begin FOOTER
    "M5"
    "M30"
    """

    static let date = GoldenPostTests.date

    func motions(_ g: String) throws -> [Motion] {
        // Moves that go somewhere (a repeated retract adds nothing).
        var out: [Motion] = []
        for seg in try GCodeParser.parse(g).segments {
            var p = seg.start
            for m in seg.motions {
                if m.kind == .dwell || m.end != p { out.append(m) }
                if m.kind != .dwell { p = m.end }
            }
        }
        return out
    }

    @Test func parsesTheReport() throws {
        let pp = try VectricPost.parse(Self.mach4Style)
        #expect(pp.name == "Test Mach4 (inch) (*.tap)" && pp.fileExtension == "tap" && pp.units == .inch)
        #expect(pp.lineEnding == "\r\n" && pp.substitutions["("] == "{")
        #expect(pp.variables["X"]?.decimals == 4 && pp.variables["X"]?.always == false && pp.variables["X"]?.prefix == " X")
        #expect(pp.usesArcs && pp.changesTools && pp.writesGCode)
        #expect(pp.report.contains { $0.item == "FEED_MOVE" && $0.status == .used })
        #expect(pp.refused.isEmpty)
    }

    @Test func refusesWhatItCantRunSafely() {
        #expect(throws: VectricPostError.self) { try VectricPost.parse(Self.mach4Style + "\nROTARY_WRAP_Y = \"YES\"") }
        #expect(throws: VectricPostError.self) { try VectricPost.parse(Self.mach4Style.replacingOccurrences(of: "\"G00[X][Y][Z]\"", with: "\"G00[X][Y][Z][A]\"")) }
        #expect(throws: VectricPostError.self) { try VectricPost.parse(Self.mach4Style.replacingOccurrences(of: "\"M07\"", with: "\"M07 [MYSTERY]\"")) }
        #expect(throws: VectricPostError.self) { try VectricPost.parse("just a text file\nwith no post in it") }
        let ignored = try? VectricPost.parse(Self.mach4Style + "\nLASER_SUPPORT = \"YES\"\nbegin JET_TOOL_ON\n\"M3\"")
        #expect(ignored?.report.contains { $0.item == "LASER_SUPPORT" && $0.status == .ignored } == true)
        #expect(ignored?.report.contains { $0.item == "JET_TOOL_ON" && $0.status == .ignored } == true)
    }

    @Test func mach4StylePostCutsExactlyLikeTheBuiltInPost() throws {
        var p = Project.demoSign()
        let toolpaths = CAMEngine.generate(p).toolpaths
        let builtIn = AvidMach4Post(project: p, date: Self.date).post(toolpaths)
        p.machine.customPost = try VectricPost.parse(Self.mach4Style)
        let post = try #require(PostProcessors.post(for: p, date: Self.date) as? VectricTemplatePost)
        let files = post.files(toolpaths)
        #expect(files.count == 1)
        let g = files[0].gcode
        // Same moves, feeds and arcs; only the header comments differ.
        let a = try motions(builtIn), b = try motions(g)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.kind == y.kind && x.end == y.end && abs(x.feed - y.feed) < 1e-9 && x.center == y.center)
        }
        let builtInLines = Set(builtIn.components(separatedBy: "\r\n").filter { !$0.hasPrefix("(") })
        let templateLines = Set(g.components(separatedBy: "\r\n").filter { !$0.hasPrefix("(") })
        #expect(templateLines.subtracting(builtInLines).isEmpty, "\(templateLines.subtracting(builtInLines).sorted().prefix(5))")
        #expect(g.contains("(Demo sign.tap)") && g.contains("T5 60deg") == false && g.contains("60° V-Bit"))
        // And it passes the export checks.
        let issues = GCodeCheck.run(g, toolpaths: files[0].toolpaths, project: p, dialect: post.dialect).filter { $0.severity != .info }
        #expect(issues.isEmpty, "\(issues.map(\.text))")
    }

    @Test func grblStylePostLinearisesArcsAndSplitsTools() throws {
        var p = Project.demoSign()
        p.machine.model = .custom
        p.machine.controller = ControllerProfile(family: .grbl)
        p.machine.customPost = try VectricPost.parse(Self.grblStyle)
        let toolpaths = CAMEngine.generate(p).toolpaths
        let post = try #require(PostProcessors.post(for: p, date: Self.date))
        #expect(post.dialect.name == "Test Grbl (mm) (*.gcode)" && post.dialect.strict) // still checked as Grbl
        let files = post.files(toolpaths)
        #expect(files.count == 2 && files.map { $0.suffix ?? "" } == [" 1 of 2 - T5", " 2 of 2 - T1"])
        for f in files {
            let lines = f.gcode.components(separatedBy: "\n")
            #expect(!lines.contains { ($0.hasPrefix("G2") && !$0.hasPrefix("G21")) || $0.hasPrefix("G3") })
            #expect(!f.gcode.contains("\r"))
            #expect(f.gcode.hasPrefix("G90 G94 G17\nG21\n"))
            let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: p, dialect: post.dialect).filter { $0.severity != .info }
            #expect(issues.isEmpty, "\(f.suffix ?? ""): \(issues.map(\.text))")
        }
    }

    @Test func postsThatDontWriteGCodeAreFlaggedNotChecked() throws {
        let sbp = """
        POST_NAME = "Test OpenSBP (inch) (*.sbp)"
        FILE_EXTENSION = "sbp"
        UNITS = "INCHES"
        VAR X_POSITION = [X|A||1.4]
        VAR Y_POSITION = [Y|A||1.4]
        VAR Z_POSITION = [Z|A||1.4]
        begin HEADER
        "SA"
        begin RAPID_MOVE
        "J3,[X],[Y],[Z]"
        begin FEED_MOVE
        "M3,[X],[Y],[Z]"
        begin FOOTER
        "END"
        """
        var p = Project.demoSign()
        p.machine.customPost = try VectricPost.parse(sbp)
        let post = try #require(PostProcessors.post(for: p, date: Self.date))
        let toolpaths = CAMEngine.generate(p).toolpaths
        let g = post.files(toolpaths)[0].gcode
        #expect(g.contains("M3,"))
        let issues = GCodeCheck.run(g, toolpaths: toolpaths, project: p, dialect: post.dialect)
        #expect(issues.count == 1 && issues[0].message.contains("isn't checked"))
    }

    @Test func comparisonShowsWhatDiffers() throws {
        let (p, toolpaths) = AcceptanceTest.job(machine: MachineProfile())
        let builtIn = AvidMach4Post(project: p, date: Self.date).post(toolpaths)
        var withPost = p
        withPost.machine.customPost = try VectricPost.parse(Self.mach4Style)
        let imported = VectricTemplatePost(project: withPost, pp: withPost.machine.customPost!, date: Self.date).post(toolpaths)
        let same = PostComparison.compare(imported: imported, builtIn: builtIn, units: .inch)
        #expect(same.sameMoves, "\(same.firstDifference ?? "")")
        // The only lines that differ are arcs where this post leaves out an unchanged X or Y, as Mach4 allows.
        #expect(same.onlyInImported.allSatisfy { $0.hasPrefix("G02") || $0.hasPrefix("G03") }, "\(same.onlyInImported.prefix(4))")
        // A post that drops the dust collector and writes feeds in whole numbers differs, and says where.
        let other = try VectricPost.parse(Self.mach4Style.replacingOccurrences(of: "\"M07\"\n", with: "")
            .replacingOccurrences(of: "[F|C| F|1.1]", with: "[F|C| F|1.0]"))
        withPost.machine.customPost = other
        let changed = PostComparison.compare(imported: VectricTemplatePost(project: withPost, pp: other, date: Self.date).post(toolpaths),
                                             builtIn: builtIn, units: .inch)
        #expect(changed.onlyInBuiltIn.contains("M07"))
        #expect(changed.onlyInImported.contains { $0.contains(" F") })
    }

    @Test func projectsKeepTheirPostAndAreFormatTwo() throws {
        var p = Project.demoSign()
        p.machine.customPost = try VectricPost.parse(Self.mach4Style)
        #expect(p.formatVersion == 2)
        let back = try Project.decode(p.encoded())
        #expect(back == p)
        #expect(back.machine.customPost?.source == Self.mach4Style)
        #expect(PostProcessors.post(for: back) is VectricTemplatePost)
        #expect(back.machine.postLabel == "Test Mach4 (inch) (*.tap)")
    }
}
