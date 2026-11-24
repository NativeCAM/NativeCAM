import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for feed scheduling's depth derate and automatic spindle speed (#92): goldens for automatic
/// RPM on Avid's Mach4 default, grblHAL, ShopBot and RichAuto, a deep pass at its derated recommendation, and the edge
/// cases (an RPM the spindle can't reach, a form bit at its speed limit, a pass exactly 1× the bit's diameter deep),
/// each test asserting what NativeCAM does. The shapes are rectangles made in code, so the tests read no drawing.
struct FeedRPMCatalogTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "92F00000-0000-4000-8000-%012d", n))! }

    /// Maple, 3/4" thick, on the default PRO6060 (400 in/min cutting cap, 6,000–24,000 RPM).
    static let stock = Stock(width: 6.inch, height: 5.inch, thickness: 0.75.inch, materialName: "Maple", clearanceHeight: 0.5.inch,
                             plungeHeight: 0.2.inch, materialKind: .hardwood)

    static let board = DesignShape(id: id(1), name: "Board", kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0),
                                   position: Vec2(3.inch, 2.5.inch))
    static let recess = DesignShape(id: id(2), name: "Recess", kind: .rectangle(width: 1.inch, height: 0.75.inch, cornerRadius: 0),
                                    position: Vec2(3.inch, 2.5.inch))

    /// The starter 1/4" two-flute upcut end mill, set to 18,000 RPM and 400 in/min: the PRO6060's cutting cap.
    static func quarter(feed: Double = 400.inch, rpm: Double = 18000) -> Tool {
        var t = ToolLibrary.starter.tool(number: 1)!
        t.cutting.feedRate = feed
        t.cutting.spindleRPM = rpm
        return t
    }

    static func profile(depth: Double, pass: Double? = nil) -> OperationKind {
        .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: depth, passDepth: pass)))
    }

    static func project(_ name: String, _ ops: [CAMOperation], shapes: [DesignShape] = [board, recess],
                        _ configure: (inout Project) -> Void = { _ in }) -> Project {
        var p = Project(name: name, displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: shapes, operations: ops)
        configure(&p)
        return p
    }

    static func controller(_ family: ControllerFamily, units: LengthUnit = .inch) -> (inout Project) -> Void {
        { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: family)
            p.machine.outputUnits = units
        }
    }

    /// A recess at the tool's RPM, then the cut-out with Spindle ▸ Automatic, with the same bit: the S changes between
    /// them without a tool change. A 2 s spin-up dwell shows where each post writes it.
    static func automaticJob(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        let tool = Self.quarter()
        let ops = [
            CAMOperation(id: id(11), name: "Recess", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.125.inch))),
                         shapeIDs: [recess.id], tool: tool),
            CAMOperation(id: id(12), name: "Cut out", kind: profile(depth: 0.5.inch, pass: 0.25.inch), shapeIDs: [board.id], tool: tool,
                         spindleSpeed: .automatic),
        ]
        return project("Automatic spindle speed", ops) { p in
            p.machine.spindleSpinUpDwell = 2
            configure(&p)
        }
    }

    /// Posts `p` with its machine's post, checks each file against its golden and runs the export checks on it.
    @discardableResult
    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> (job: JobResult, files: [String]) {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        if p.machine.controller == nil {
            let data = GoldenPostTests.post(p, job.toolpaths)
            try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
            let text = String(decoding: data, as: UTF8.self)
            let issues = GCodeCheck.run(text, toolpaths: job.toolpaths, project: p, dialect: .avidMach4).filter { $0.severity != .info }
            #expect(issues.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
            return (job, [text])
        }
        // A fixed date and time zone, so the header stays the same.
        let post: any PostProcessor
        if var sbp = PostProcessors.post(for: p, date: GoldenPostTests.date) as? OpenSBPPost {
            sbp.timeZone = TimeZone(identifier: "UTC")!
            post = sbp
        } else {
            var generic = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost,
                                       sourceLocation: sourceLocation)
            generic.timeZone = TimeZone(identifier: "UTC")!
            post = generic
        }
        let files = post.files(job.toolpaths)
        for (i, f) in files.enumerated() {
            try GoldenPostTests.check(Data(f.gcode.utf8), golden: files.count == 1 ? name : "\(name)-\(i + 1)", sourceLocation: sourceLocation)
            let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: p, dialect: post.dialect).filter { $0.severity != .info }
            #expect(issues.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
        }
        return (job, files.map(\.gcode))
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    // MARK: Depth derate

    @Test func freudsDerateIsAStraightLineHeldAtHalf() {
        let d = 0.25.inch
        #expect(ChipLoad.depthShare(pass: 0.5 * d, diameter: d) == 1)
        #expect(ChipLoad.depthShare(pass: d, diameter: d) == 1)
        #expect(abs(ChipLoad.depthShare(pass: 1.5 * d, diameter: d) - 0.875) < 1e-9)
        #expect(abs(ChipLoad.depthShare(pass: 2 * d, diameter: d) - 0.75) < 1e-9)
        #expect(abs(ChipLoad.depthShare(pass: 3 * d, diameter: d) - 0.5) < 1e-9)
        #expect(ChipLoad.depthShare(pass: 5 * d, diameter: d) == ChipLoad.depthShareFloor)
    }

    @Test func aPassTwiceTheDiameterDeepGetsALowerRecommendedFeed() {
        let tool = ToolLibrary.starter.tool(number: 1)! // 13,000 RPM
        let machine = MachineProfile.avidPRO6060
        let shallow = ChipLoad.recommendation(for: tool, material: .hardwood, machine: machine, passDepth: 0.25.inch)
        let deep = ChipLoad.recommendation(for: tool, material: .hardwood, machine: machine, passDepth: 0.5.inch)
        #expect(deep.rpm == shallow.rpm)
        #expect(abs(deep.feed - 0.75 * shallow.feed) < 1e-6)
        #expect(abs(shallow.feed - 227.5.inch) < 0.01)
        #expect(deep.reading.depthShare == 0.75)
        let notes = deep.reading.notes(.inch)
        #expect(notes.contains { $0.hasPrefix("Chip load cut to 75% for passes 2× the bit's diameter deep") }, "\(notes)")
        // The range is derated with the target.
        let r0 = shallow.reading.range, r1 = deep.reading.range
        #expect(abs(r1.lowerBound - 0.75 * r0.lowerBound) < 1e-12)
        #expect(abs(r1.upperBound - 0.75 * r0.upperBound) < 1e-12)
    }

    @Test func passDepthsComeFromTheOperation() {
        let tool = Self.quarter()
        #expect(Self.profile(depth: 0.5.inch, pass: 0.25.inch).deepestPass(tool).map { abs($0 - 0.25.inch) < 1e-9 } == true)
        // 0.7" at the tool's 3/16" stepdown is four passes of 0.175".
        #expect(Self.profile(depth: 0.7.inch).deepestPass(tool).map { abs($0 - 0.175.inch) < 1e-9 } == true)
        var adaptive = PocketParams(strategy: .adaptive, depth: DepthSettings(cutDepth: 0.75.inch))
        #expect(OperationKind.pocket(adaptive).deepestPass(tool) == nil)
        adaptive.strategy = .offset
        #expect(OperationKind.pocket(adaptive).deepestPass(tool) != nil)
        #expect(OperationKind.drill(DrillParams(depth: 10)).deepestPass(tool) == nil)
    }

    @Test func formBitsKeepTheirCrossSectionRuleAlone() {
        let cove = RouterBitFeedTests.cove(rpm: 18000)
        let r = ChipLoad.reading(cove, material: .hardwood, depth: 0.5.inch, passDepth: 3 * cove.diameter)
        #expect(r.depthShare == 1)
        let plain = ChipLoad.reading(cove, material: .hardwood, depth: 0.5.inch)
        #expect(r.range == plain.range && r.target == plain.target)
        // A dovetail, on the router-bit chart without a cross-section rule, is derated.
        let dovetail = RouterBitFeedTests.dovetail()
        #expect(ChipLoad.reading(dovetail, material: .hardwood, depth: nil, passDepth: 2 * dovetail.diameter).depthShare == 0.75)
    }

    /// Checks read the derated range: a chip inside the chart for a shallow pass is above it for one 3× as deep.
    @Test func checksUseTheDeratedRange() {
        let tool = Self.quarter(feed: 221.inch, rpm: 13000) // 0.0085 in a tooth
        func chipIssues(pass: Double) -> [String] {
            let op = CAMOperation(kind: Self.profile(depth: 0.75.inch, pass: pass), shapeIDs: [Self.board.id], tool: tool)
            return CAMEngine.generate(Self.project("Checks", [op], shapes: [Self.board])).issues.map(\.message)
                .filter { $0.hasPrefix("Chip load") }
        }
        #expect(chipIssues(pass: 0.25.inch).isEmpty)
        let deep = chipIssues(pass: 0.75.inch)
        #expect(deep.count == 1, "\(deep)")
        #expect(deep.first?.contains("is above the 0.0040 in–0.0055 in range") == true, "\(deep)")
        #expect(deep.first?.contains("Chip load cut to 50% for passes 3× the bit's diameter deep") == true, "\(deep)")
    }

    /// A 1/4" profile 1/2" deep in passes 1/2" deep, at Use Recommended's feed for that pass depth.
    @Test func deepPassGolden() throws {
        var tool = ToolLibrary.starter.tool(number: 1)!
        let kind = Self.profile(depth: 0.5.inch, pass: 0.5.inch)
        let rec = ChipLoad.recommendation(for: tool, material: .hardwood, machine: .avidPRO6060, passDepth: kind.deepestPass(tool))
        tool.cutting.feedRate = rec.feed
        tool.cutting.spindleRPM = rec.rpm
        #expect(abs(rec.feed - 0.75 * 227.5.inch) < 0.01)
        let op = CAMOperation(id: Self.id(21), name: "Deep cut out", kind: kind, shapeIDs: [Self.board.id], tool: tool)
        let (job, files) = try Self.checkGolden(Self.project("Deep pass", [op], shapes: [Self.board]), "deep-pass-derate-inch")
        #expect(files[0].contains("F170.6"), "the derated feed is posted")
        #expect(job.issues.filter { $0.message.hasPrefix("Chip load") }.isEmpty, "\(job.issues.map(\.message))")
    }

    /// The boundary: a pass exactly the bit's diameter deep keeps the full chart.
    @Test func aPassExactlyOneDiameterDeepIsNotDerated() throws {
        var tool = ToolLibrary.starter.tool(number: 1)!
        let kind = Self.profile(depth: 0.5.inch, pass: 0.25.inch)
        let pass = try #require(kind.deepestPass(tool))
        #expect(abs(pass - tool.diameter) < 1e-9)
        let rec = ChipLoad.recommendation(for: tool, material: .hardwood, machine: .avidPRO6060, passDepth: pass)
        let none = ChipLoad.recommendation(for: tool, material: .hardwood, machine: .avidPRO6060)
        #expect(rec.reading.depthShare == 1)
        #expect(rec.feed == none.feed && rec.rpm == none.rpm)
        #expect(rec.reading.notes(.inch).isEmpty)
        tool.cutting.feedRate = rec.feed
        tool.cutting.spindleRPM = rec.rpm
        let op = CAMOperation(id: Self.id(22), name: "Cut out at 1xD", kind: kind, shapeIDs: [Self.board.id], tool: tool)
        let (_, files) = try Self.checkGolden(Self.project("Pass 1xD", [op], shapes: [Self.board]), "deep-pass-1xd-inch")
        #expect(files[0].contains("F227.5"), "the chart's feed is posted")
    }

    // MARK: Automatic spindle speed

    @Test func defaultsChangeNothing() throws {
        let op = CAMOperation(kind: Self.profile(depth: 0.5.inch), shapeIDs: [Self.board.id], tool: Self.quarter())
        #expect(op.spindleSpeed == nil && !op.usesAutomaticSpindle)
        #expect(op.adjustFeedsForLoad == nil)
        let p = Self.project("Defaults", [op], shapes: [Self.board])
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.allSatisfy { $0.spindleRPM == 18000 && $0.automaticSpindle == nil })
        #expect(!String(decoding: try p.encoded(), as: UTF8.self).contains("spindleSpeed"))
    }

    @Test func automaticSavesWithoutANewFormat() throws {
        let p = Self.automaticJob()
        let decoded = try Project.decode(p.encoded())
        #expect(decoded.operations.map(\.spindleSpeed) == [nil, .automatic])
        var plain = p
        plain.operations[1].spindleSpeed = nil
        #expect(p.formatVersion == plain.formatVersion, "an older build posts the tool's RPM, which it checks as before")
    }

    /// The brief's case: a 1/4" two-flute end mill in maple, capped at 400 in/min, gets a speed that puts its chip inside
    /// the chart's range.
    @Test func automaticPutsTheChipInRangeAtTheCappedFeed() throws {
        let job = CAMEngine.generate(Self.automaticJob())
        let recess = try #require(job.toolpaths.first { $0.name == "Recess" })
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out" })
        #expect(recess.spindleRPM == 18000 && recess.automaticSpindle == nil)
        let auto = try #require(cut.automaticSpindle)
        #expect(cut.spindleRPM == auto.rpm)
        #expect(!auto.feedCapped && auto.feed == 400.inch)
        #expect(auto.rpm == 22900 && auto.limit == nil, "\(auto)")
        let range = ChipLoad.range(.hardwood, diameter: 0.25.inch)
        #expect(range.contains(auto.chip), "\(auto.chip / LengthUnit.mmPerInch) in")
        #expect(!auto.outOfRange)
        #expect(auto.reason(.inch) == "22,900 RPM puts the chip at 0.0087 in at 400 in/min, the chart's target for this bit.")
        let messages = job.issues.filter { $0.operation == "Cut out" }.map(\.message)
        #expect(!messages.contains { $0.hasPrefix("Chip load") || $0.hasPrefix("Automatic") }, "\(messages)")
    }

    /// A feed set above the machine's cutting cap is worked out at the cap, the fastest the machine cuts.
    @Test func aFeedAboveTheCapIsWorkedOutAtTheCap() throws {
        let tool = Self.quarter(feed: 450.inch)
        let auto = try #require(ChipLoad.automaticSpindle(for: tool, material: .hardwood, machine: .avidPRO6060, feed: tool.cutting.feedRate))
        #expect(auto.feedCapped && auto.feed == 400.inch && auto.rpm == 22900)
        #expect(auto.reason(.inch) == "22,900 RPM puts the chip at 0.0087 in at 400 in/min (the machine's cutting cap, below the "
            + "toolpath's feed), the chart's target for this bit.")
    }

    @Test func automaticGoldenAvidMach4() throws {
        let (_, files) = try Self.checkGolden(Self.automaticJob(), "auto-rpm-mach4-inch")
        let l = Self.lines(files[0])
        let first = try #require(l.firstIndex(of: "S18000 M03"))
        let second = try #require(l.firstIndex(of: "S22900 M03"))
        #expect(first < second)
        #expect(l[second + 1] == "G04 P2.00", "the spin-up dwell follows the new speed")
        #expect(l.filter { $0.hasSuffix("M6") && $0.hasPrefix("T") }.count == 1, "one tool change")
    }

    @Test func automaticGoldenGrblHAL() throws {
        let (_, files) = try Self.checkGolden(Self.automaticJob(Self.controller(.grblHAL)), "auto-rpm-grblhal-inch")
        #expect(files.count == 1)
        let l = Self.lines(files[0])
        let second = try #require(l.firstIndex(of: "S22900 M3"))
        #expect(l.contains("S18000 M3"))
        #expect(l[second + 1].hasPrefix("G4 P2"), "\(l[second + 1])")
    }

    @Test func automaticGoldenShopBot() throws {
        let (_, files) = try Self.checkGolden(Self.automaticJob(Self.controller(.openSBP)), "auto-rpm-shopbot-inch")
        let l = Self.lines(files[0])
        let second = try #require(l.firstIndex(of: "TR,22900"))
        #expect(l.contains("TR,18000"))
        #expect(l[second + 1] == "C6" && l[second + 2] == "PAUSE 2.00", "\(l[second...].prefix(3))")
    }

    @Test func automaticGoldenRichAuto() throws {
        let (_, files) = try Self.checkGolden(Self.automaticJob(Self.controller(.richAuto, units: .mm)), "auto-rpm-richauto-mm")
        let l = Self.lines(files[0])
        #expect(l.contains("S18000 M3") && l.contains("S22900 M3"), "\(l.filter { $0.hasPrefix("S") })")
    }

    @Test func setupSheetSaysWhy() throws {
        let p = Self.automaticJob()
        let job = CAMEngine.generate(p)
        let html = SetupSheet.html(project: p, job: job, date: GoldenPostTests.date)
        #expect(html.contains("22900 †"))
        #expect(html.contains("Automatic spindle speed, picked from the chip-load chart (not yet calibrated on this machine)"))
        #expect(html.contains("2. Cut out: 22,900 RPM puts the chip at 0.0087 in at 400 in/min"))
    }

    // MARK: Edge cases

    /// A 1/2" end mill fed at 60 in/min in maple would need about 1,600 RPM: clamped to the spindle's 6,000, with a warning.
    @Test func anUnreachableSpeedIsClampedWithAWarning() throws {
        var tool = ToolLibrary.starter.tool(number: 10)!
        tool.cutting.feedRate = 60.inch
        let op = CAMOperation(id: Self.id(31), name: "Slow cut out", kind: Self.profile(depth: 0.25.inch), shapeIDs: [Self.board.id],
                              tool: tool, spindleSpeed: .automatic)
        let p = Self.project("Unreachable speed", [op], shapes: [Self.board])
        let (job, files) = try Self.checkGolden(p, "auto-rpm-unreachable-inch")
        let tp = try #require(job.toolpaths.first)
        let auto = try #require(tp.automaticSpindle)
        #expect(auto.rpm == 6000 && auto.limit == .spindleMinimum)
        #expect(auto.wanted > 1500 && auto.wanted < 1700, "\(auto.wanted)")
        #expect(auto.outOfRange)
        let warnings = job.issues.filter { $0.severity == .warning }.map(\.message)
        let w = warnings.filter { $0.hasPrefix("Automatic spindle speed can't keep the chip") }
        #expect(w.count == 1, "\(warnings)")
        #expect(w.first?.contains("it needs 1,600 RPM, and the spindle turns no slower than 6,000 RPM") == true, "\(w)")
        #expect(!warnings.contains { $0.hasPrefix("Chip load") }, "one warning, not two: \(warnings)")
        #expect(Self.lines(files[0]).contains("S6000 M03"))
    }

    /// A 1-1/2" cove (18,000 RPM limit) fed fast enough that the chart's chip would need more: it runs at its limit.
    @Test func aFormBitStopsAtItsSpeedLimit() throws {
        var cove = RouterBitFeedTests.cove(rpm: 12000)
        cove.cutting.feedRate = 300.inch
        let op = CAMOperation(id: Self.id(32), name: "Cove", kind: Self.profile(depth: 0.5.inch), shapeIDs: [Self.board.id],
                              tool: cove, spindleSpeed: .automatic)
        let p = Self.project("Form bit at its limit", [op], shapes: [Self.board])
        let (job, files) = try Self.checkGolden(p, "auto-rpm-form-limit-inch")
        let tp = try #require(job.toolpaths.first)
        let auto = try #require(tp.automaticSpindle)
        #expect(auto.limit == .bitLimit)
        #expect(auto.rpm == 18000 && auto.wanted > 18000, "\(auto)")
        #expect(tp.spindleRPM <= ChipLoad.routerSpeedLimit(diameter: cove.diameter))
        let messages = job.issues.map(\.message)
        #expect(!messages.contains { $0.hasPrefix("Spindle speed") }, "never over its limit: \(messages)")
        #expect(auto.reason(.inch).contains("past this bit's speed limit"))
        #expect(Self.lines(files[0]).contains("S18000 M03"))
    }

    /// A bit no chart covers keeps its tool's speed, and says so.
    @Test func aVBitKeepsItsToolsSpeed() throws {
        let vbit = ToolLibrary.starter.tool(number: 5)!
        let op = CAMOperation(kind: .vcarve(VCarveParams()), shapeIDs: [Self.board.id], tool: vbit, spindleSpeed: .automatic)
        let job = CAMEngine.generate(Self.project("V-bit", [op], shapes: [Self.board]))
        #expect(job.toolpaths.allSatisfy { $0.spindleRPM == vbit.cutting.spindleRPM && $0.automaticSpindle == nil })
        #expect(job.issues.contains { $0.severity == .info && $0.message.hasPrefix("Automatic spindle speed: no chip-load chart covers") })
    }
}
