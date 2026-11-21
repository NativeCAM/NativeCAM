import Foundation
import Testing
@testable import CAMCore

/// Whole-file golden G-code for the Avid Mach4 post: today's output, byte for byte and CRLF included, so that
/// splitting the machine model and adding other controllers can't change what an Avid machine runs.
///
/// - `coverage-*`: a small hand-written job that reaches every branch of the post, once per machine setting.
///   Independent of the toolpath generators, so only post changes move these.
/// - `sign-*`, `relief-*`: the demo projects end to end (generators, links, arc fitting and the post). Toolpath
///   improvements move these on purpose; review the diff. The sign's lettering comes from the system's
///   Helvetica Bold, so a macOS font update can also move its V-carve section.
/// - `decoded-*`: project files saved by an earlier build (`Fixtures/projects`), which must keep decoding to the
///   same project and posting the same bytes. Those files are never regenerated.
///
/// To accept an intended change, run `NATIVECAM_UPDATE_GOLDENS=1 scripts/test.sh --filter GoldenPostTests`
/// and review `git diff Tests/CAMCoreTests/Fixtures`. A mismatch leaves the new output in `.build/golden-actual`.
struct GoldenPostTests {
    /// 2027-01-15 08:00 UTC.
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let goldens = fixtures.appendingPathComponent("golden")
    static let projects = fixtures.appendingPathComponent("projects")
    static let actualOutput = fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/golden-actual")
    static let updating = ProcessInfo.processInfo.environment["NATIVECAM_UPDATE_GOLDENS"] == "1"

    /// Posts exactly as File ▸ Export G-code does (ASCII bytes), with the date and time zone pinned.
    static func post(_ project: Project, _ toolpaths: [Toolpath]) -> Data {
        var post = AvidMach4Post(project: project, date: date)
        post.timeZone = TimeZone(identifier: "UTC")!
        return post.post(toolpaths).data(using: .ascii, allowLossyConversion: true)!
    }

    static func post(_ project: Project) -> Data { post(project, CAMEngine.generate(project).toolpaths) }

    static func check(_ actual: Data, golden name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = goldens.appendingPathComponent(name + ".tap")
        if updating {
            try FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
            if (try? Data(contentsOf: url)) != actual { try actual.write(to: url) }
            return
        }
        guard let expected = try? Data(contentsOf: url) else {
            Issue.record("No golden file \(name).tap. Run with NATIVECAM_UPDATE_GOLDENS=1 to create it.", sourceLocation: sourceLocation)
            return
        }
        guard expected != actual else { return }
        try FileManager.default.createDirectory(at: actualOutput, withIntermediateDirectories: true)
        let saved = actualOutput.appendingPathComponent(name + ".tap")
        try actual.write(to: saved)
        let e = String(decoding: expected, as: UTF8.self).components(separatedBy: "\n")
        let a = String(decoding: actual, as: UTF8.self).components(separatedBy: "\n")
        let i = (0..<min(e.count, a.count)).first { e[$0] != a[$0] } ?? min(e.count, a.count)
        func show(_ lines: [String]) -> String {
            i < lines.count ? "“\(lines[i].replacingOccurrences(of: "\r", with: "\\r"))”" : "end of file"
        }
        Issue.record("""
            \(name).tap changed at line \(i + 1): expected \(show(e)), got \(show(a)) \
            (\(e.count) lines expected, \(a.count) now). New output: \(saved.path). \
            If the change is intended, rerun with NATIVECAM_UPDATE_GOLDENS=1 and review the diff.
            """, sourceLocation: sourceLocation)
    }

    // MARK: Post coverage

    /// A hand-written job for every branch of the post: two tools and a change back to the first, an RPM change on
    /// one tool, an RPM above the spindle's range, rapids, feed changes, CW and CCW arcs, a helical arc, an arc
    /// that rounds to a point, an arc whose rounded radii disagree (cut as a line), a dwell, a value that rounds
    /// to -0, an empty toolpath, and names that need cleaning for Mach4 comments.
    static func coverage(_ configure: (inout Project) -> Void = { _ in }) -> Data {
        let (p, toolpaths) = coverageJob(configure)
        return post(p, toolpaths)
    }

    /// A hand-built indexed rotary job: a slot along the top of each face with T1, then a radial hole at each angle
    /// with T2. Built by hand, like the coverage job, so it freezes the post rather than the generators.
    static func rotaryJob(blank: RotaryStock = RotaryStock(shape: .squareBar, diameter: 2.inch, length: 12.inch),
                          slotAngles: [Double] = [0, 90, 180, 270], holeAngles: [Double] = [0, 90, 180, 270],
                          _ configure: (inout Project) -> Void = { _ in }) -> (Project, [Toolpath]) {
        let lib = ToolLibrary.starter
        let endMill = lib.tool(number: 1)!, small = lib.tool(number: 2)!
        var stock = Stock(materialName: "Maple")
        stock.setRotary(blank)
        var p = Project(name: "Golden (rotary)", displayUnits: .inch, stock: stock)
        p.machine.rotary = RotaryAxis(centerHeight: 4.inch)
        configure(&p)
        let c = p.stock.height / 2, safe = p.stock.clearanceHeight
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "60D0E000-0000-0000-0001-%012d", n))! }
        var toolpaths: [Toolpath] = []
        for (k, angle) in slotAngles.enumerated() {
            toolpaths.append(Toolpath(id: id(1 + k), name: "Slot @ \(RotaryIndex.label(angle))", tool: endMill, spindleRPM: 18000,
                                      start: Vec3(100, c, safe), motions: [
                .rapid(Vec3(100, c, 2)), .feed(Vec3(100, c, -3), 750), .feed(Vec3(160, c, -3), 2000), .rapid(Vec3(160, c, safe)),
            ], indexAngle: angle, operationID: id(1)))
        }
        for (k, angle) in holeAngles.enumerated() {
            toolpaths.append(Toolpath(id: id(21 + k), name: "Hole @ \(RotaryIndex.label(angle))", tool: small, spindleRPM: 18000,
                                      start: Vec3(220, c, safe), motions: [
                .rapid(Vec3(220, c, 2)), .feed(Vec3(220, c, -12), 500), .rapid(Vec3(220, c, safe)),
            ], indexAngle: angle, operationID: id(21)))
        }
        return (p, toolpaths)
    }

    @Test func rotarySquareBarGolden() throws {
        let (p, toolpaths) = Self.rotaryJob()
        let data = Self.post(p, toolpaths)
        try Self.check(data, golden: "rotary-square-inch")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }

    static func coverageJob(_ configure: (inout Project) -> Void = { _ in }) -> (Project, [Toolpath]) {
        let lib = ToolLibrary.starter
        let endMill = lib.tool(number: 1)!, vBit = lib.tool(number: 5)!, unused = lib.tool(number: 9)!
        var p = Project(name: "Golden (coverage)", displayUnits: .inch,
                        stock: Stock(width: 300, height: 200, thickness: 19, materialName: "MDF \"test\" (half sheet)"))
        configure(&p)
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "60D0E000-0000-0000-0000-%012d", n))! }
        let profile = Toolpath(id: id(1), name: "Profile (outer) – test", tool: endMill, spindleRPM: 18000, start: Vec3(20, 20, 5), motions: [
            .rapid(Vec3(20, 20, 2)),
            .feed(Vec3(20, 20, -3), 750),
            .feed(Vec3(120, 20, -3), 2500),
            Motion(kind: .arcCCW, end: Vec3(140, 40, -3), center: Vec2(120, 40), feed: 2500),
            .feed(Vec3(140, 140, -3), 2500),
            Motion(kind: .arcCW, end: Vec3(120, 120, -3), center: Vec2(120, 140), feed: 2000),
            .feed(Vec3(20, 120, -3), 2000),
            // Helical quarter turn down to -4.
            Motion(kind: .arcCW, end: Vec3(30, 110, -4), center: Vec2(20, 110), feed: 1500),
            // Endpoints closer than the output precision: must not become a full circle.
            Motion(kind: .arcCCW, end: Vec3(30.001, 110.0005, -4.5), center: Vec2(25, 110), feed: 1500),
            // Start radius 10, end radius 10.03: cut as a line rather than an arc Mach4 rejects.
            Motion(kind: .arcCCW, end: Vec3(40, 120.03, -4.5), center: Vec2(40, 110), feed: 1500),
            .feed(Vec3(40, 120.03, -0.000_01), 750),
            Motion(kind: .dwell, end: Vec3(40, 120.03, -0.000_01), feed: 0.5),
            .rapid(Vec3(40, 120.03, 5)),
        ])
        let carve = Toolpath(id: id(2), name: "V-carve \"sign\" 60°", tool: vBit, spindleRPM: 30000, start: Vec3(150, 100, 5), motions: [
            .rapid(Vec3(150, 100, 1)),
            .feed(Vec3(150, 100, -2), 1000),
            .feed(Vec3(160, 105, -1.25), 2000),
            .feed(Vec3(170, 100, -2.5), 2000),
            .rapid(Vec3(170, 100, 5)),
        ])
        let carve2 = Toolpath(id: id(3), name: "V-carve pass 2", tool: vBit, spindleRPM: 16000, start: Vec3(200, 100, 5), motions: [
            .rapid(Vec3(200, 100, 1)),
            .feed(Vec3(200, 100, -1), 1000),
            Motion(kind: .arcCCW, end: Vec3(190, 110, -1), center: Vec2(190, 100), feed: 2000),
            .rapid(Vec3(190, 110, 5)),
        ])
        let empty = Toolpath(id: id(4), name: "Empty", tool: unused, spindleRPM: 18000, start: Vec3(0, 0, 5), motions: [])
        let cleanup = Toolpath(id: id(5), name: "Clean-up", tool: endMill, spindleRPM: 18000, start: Vec3(250, 150, 5), motions: [
            .rapid(Vec3(250, 150, 2)),
            .feed(Vec3(250, 150, -19.5), 750),
            .feed(Vec3(280, 150, -19.5), 2500),
            .rapid(Vec3(280, 150, 5)),
        ])
        return (p, [profile, carve, carve2, empty, cleanup])
    }

    static let coverageVariants: [(String, @Sendable (inout Project) -> Void)] = [
        ("coverage-inch", { _ in }),
        ("coverage-mm", { $0.machine.outputUnits = .mm }),
        ("coverage-atc", { $0.machine.toolChange = .atc }),
        ("coverage-pause", { $0.machine.toolChange = .manualPause }),
        ("coverage-line-numbers", { $0.machine.lineNumbers = true }),
        ("coverage-dwell", { $0.machine.spindleSpinUpDwell = 4 }),
        ("coverage-router", { $0.machine.spindle = .router }),
        ("coverage-no-dust", { $0.machine.dustCollection = false }),
        ("coverage-spoilboard-center", { $0.stock.zZero = .machineBed; $0.stock.xyOrigin = .center }),
    ]

    @Test func coverageInch() throws { try Self.check(Self.coverage(), golden: "coverage-inch") }
    @Test func coverageMillimetres() throws { try Self.check(Self.coverage { $0.machine.outputUnits = .mm }, golden: "coverage-mm") }
    @Test func coverageToolChanger() throws { try Self.check(Self.coverage { $0.machine.toolChange = .atc }, golden: "coverage-atc") }
    @Test func coveragePause() throws { try Self.check(Self.coverage { $0.machine.toolChange = .manualPause }, golden: "coverage-pause") }
    @Test func coverageLineNumbers() throws { try Self.check(Self.coverage { $0.machine.lineNumbers = true }, golden: "coverage-line-numbers") }
    @Test func coverageSpinUpDwell() throws { try Self.check(Self.coverage { $0.machine.spindleSpinUpDwell = 4 }, golden: "coverage-dwell") }
    @Test func coverageRouter() throws { try Self.check(Self.coverage { $0.machine.spindle = .router }, golden: "coverage-router") }
    @Test func coverageNoDustCollector() throws { try Self.check(Self.coverage { $0.machine.dustCollection = false }, golden: "coverage-no-dust") }
    @Test func coverageSpoilboardZeroCentreOrigin() throws {
        try Self.check(Self.coverage { $0.stock.zZero = .machineBed; $0.stock.xyOrigin = .center }, golden: "coverage-spoilboard-center")
    }

    // MARK: Demo jobs end to end

    @Test func signInch() throws { try Self.check(Self.post(Project.demoSign()), golden: "sign-inch") }

    @Test func signMillimetres() throws {
        var p = Project.demoSign()
        p.machine.outputUnits = .mm
        try Self.check(Self.post(p), golden: "sign-mm")
    }

    @Test func signWithoutArcs() throws {
        var p = Project.demoSign()
        p.machine.outputArcs = false
        try Self.check(Self.post(p), golden: "sign-no-arcs")
    }

    @Test func reliefInch() throws { try Self.check(Self.post(Project.demoRelief()), golden: "relief-inch") }

    // MARK: Project files from earlier builds

    /// Loads a saved project fixture. Update mode creates a missing one from `make`, but never replaces one: these
    /// files stand for what users already have on disk.
    static func savedProject(_ name: String, make: () -> Project) throws -> Project {
        let url = projects.appendingPathComponent(name + ".nativecam")
        if updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    /// The default PRO6060 setup as format 1 stored it, spelled out rather than taken from today's defaults: if a
    /// default changes later, files saved before still mean what they said.
    static let formatOneDefaultMachine = MachineProfile(
        model: .pro6060, travel: Vec3(61.375.inch, 61.375.inch, 8.inch), spindle: .vfdSpindle, minRPM: 6000, maxRPM: 24000,
        toolChange: .manualM6, dustCollection: true, spindleSpinUpDwell: 0, rapidRateForEstimates: 20320,
        maxFeedRate: 10160, outputUnits: .inch, outputArcs: true, arcFitTolerance: 0.01, lineNumbers: false)

    @Test func signSavedByFormatOneStillDecodesAndPosts() throws {
        let p = try Self.savedProject("sign-v1") { Project.demoSign() }
        #expect(p.formatVersion == 1)
        #expect(p.machine == Self.formatOneDefaultMachine)
        #expect(p.stock.width == 24.inch && p.stock.height == 18.inch && p.stock.thickness == 0.75.inch)
        #expect(p.stock.xyOrigin == .lowerLeft && p.stock.zZero == .materialTop)
        #expect(p.stock.retractMode == nil && p.stock.materialKind == nil)
        #expect(p.operations.map(\.name) == ["V-carve title", "Pocket plaque", "Drill mounting holes", "Cut out sign"])
        try Self.check(Self.post(p), golden: "decoded-sign-v1")
    }

    /// A project that sets every machine, material and operation option away from its default, with a small 3D
    /// model, a clamp, imported vectors and a disabled operation.
    static func setupProject() -> Project {
        let lib = ToolLibrary.starter
        var compression = lib.tool(number: 4)!
        compression.upcutLength = 0.2.inch
        let eighth = lib.tool(number: 2)!, vBit = lib.tool(number: 6)!
        var ball = lib.tool(number: 7)!
        // The starter library's speeds when format 1 saved this project (#23 lowered them for a thicker chip).
        compression.cutting.spindleRPM = 18000
        ball.cutting.spindleRPM = 18000

        var machine = MachineProfile(model: .pro4896, spindle: .vfdSpindle, minRPM: 7000, maxRPM: 18000, toolChange: .atc,
                                     dustCollection: false, spindleSpinUpDwell: 3, rapidRateForEstimates: 600.inch,
                                     maxFeedRate: 300.inch, outputUnits: .mm, outputArcs: true, arcFitTolerance: 0.02,
                                     lineNumbers: true)
        machine.drive = .clearPath
        machine.accelerationXY = 762
        machine.accelerationZ = 381
        machine.rapidRateZ = 300.inch
        machine.junctionDeviation = 0.02
        machine.lookaheadLines = 40
        machine.toolChangeSeconds = 20
        machine.roughingSmoothing = 0.1

        var stock = Stock(width: 300, height: 200, thickness: 18, materialName: "MDF", xyOrigin: .center, zZero: .machineBed,
                          clearanceHeight: 15, plungeHeight: 3, homePosition: Vec3(10, 190, 30), materialKind: .mdf)
        stock.retractMode = .full
        stock.linkSafeDistance = 4

        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "5E7D0000-0000-0000-0000-%012d", n))! }
        let outline = DesignShape(id: id(1), name: "Outline", kind: .rectangle(width: 280, height: 180, cornerRadius: 10),
                                  position: Vec2(150, 100))
        let bowl = DesignShape(id: id(2), name: "Bowl", kind: .circle(radius: 20), position: Vec2(60, 100))
        let hole = DesignShape(id: id(3), name: "Hole", kind: .circle(radius: 3), position: Vec2(250, 40))
        let star = DesignShape(id: id(4), name: "Star", kind: .star(points: 5, outerRadius: 22, innerRadius: 10),
                               position: Vec2(150, 60), rotation: 15)
        var mesh = MeshModel.reliefMedallion(width: 60, height: 40, resolution: 30)
        mesh.id = id(5)
        let model = DesignShape(id: id(6), name: "Medallion", kind: .model(ModelSpec(mesh: mesh, upAxis: .z, depth: 6)),
                                position: Vec2(220, 110))
        let modelOutline = DesignShape(id: id(7), name: "Medallion edge", kind: .ellipse(radiusX: 31, radiusY: 21),
                                       position: Vec2(220, 110))
        let vectors = DesignShape(id: id(8), name: "Imported line",
                                  kind: .paths([Polyline([Vec2(-20, -5), Vec2(0, 5), Vec2(20, -5)], closed: false)]),
                                  position: Vec2(60, 160))
        var clamp = DesignShape(id: id(9), name: "Clamp", kind: .rectangle(width: 30, height: 5, cornerRadius: 0), position: Vec2(150, 197.5))
        clamp.keepOutHeight = 25

        let ops = [
            CAMOperation(id: id(11), name: "Bowl", kind: .pocket(PocketParams(
                strategy: .raster, direction: .conventional, depth: DepthSettings(startDepth: 0.5, cutDepth: 6, passDepth: 2),
                allowance: 0.2, rasterAngle: 30, stepoverFraction: 0.4, entry: EntrySettings(kind: .ramp, rampLength: 15))),
                         shapeIDs: [bowl.id], tool: compression),
            CAMOperation(id: id(12), name: "Hole", kind: .drill(DrillParams(depth: 10, peckDepth: 3, fullRetract: false, dwell: 0.5)),
                         shapeIDs: [hole.id], tool: eighth),
            CAMOperation(id: id(13), name: "Star", kind: .vcarve(VCarveParams(flatDepth: 2, passDepth: 1, sampleSpacing: 0.3,
                                                                              clearanceTool: eighth)),
                         shapeIDs: [star.id], tool: vBit),
            CAMOperation(id: id(14), name: "Engrave line", kind: .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 1))),
                         shapeIDs: [vectors.id], tool: vBit),
            CAMOperation(id: id(15), name: "Rough medallion", kind: .rough3D(Rough3DParams(
                allowance: 0.3, passDepth: 3, stepoverFraction: 0.35, boundary: .vectors, boundaryMargin: 5)),
                         shapeIDs: [model.id, modelOutline.id], tool: compression),
            CAMOperation(id: id(16), name: "Finish medallion", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.12, rasterAngle: 90, allowance: 0.05, boundary: .vectors, boundaryMargin: 3,
                smoothLinks: false)), // format 1 had no smooth links
                         shapeIDs: [model.id, modelOutline.id], tool: ball),
            CAMOperation(id: id(17), name: "Spare", enabled: false, kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))),
                         shapeIDs: [bowl.id], tool: eighth),
            CAMOperation(id: id(18), name: "Cut out", kind: .profile(ProfileParams(
                side: .outside, direction: .conventional, depth: DepthSettings(startDepth: 0, cutDepth: 18.5, passDepth: 6),
                tabs: TabSettings(enabled: true, count: 3, width: 8, thickness: 2), entry: EntrySettings(kind: .ramp, rampLength: 30))),
                         shapeIDs: [outline.id], tool: compression),
        ]
        return Project(name: "Setup (every option)", displayUnits: .mm, stock: stock, machine: machine,
                       shapes: [outline, bowl, hole, star, model, modelOutline, vectors, clamp], operations: ops,
                       notes: "Saved by format 1 to pin every option's key and meaning.")
    }

    @Test func setupSavedByFormatOneStillDecodesAndPosts() throws {
        let p = try Self.savedProject("setup-v1", make: Self.setupProject)
        #expect(p.formatVersion == 1)
        // The whole project, every option included, decodes to what format 1 stored.
        #expect(p == Self.setupProject())
        #expect(p.machine.toolChange == .atc && p.machine.outputUnits == .mm && p.machine.lineNumbers)
        #expect(p.machine.accelerationXY == 762 && p.machine.lookaheadLines == 40 && p.machine.roughingSmoothing == 0.1)
        #expect(p.stock.zZero == .machineBed && p.stock.xyOrigin == .center && p.stock.retractMode == .full)
        // Re-saving keeps it identical.
        #expect(try Project.decode(p.encoded()) == p)
        try Self.check(Self.post(p), golden: "decoded-setup-v1")
    }

    // MARK: Rest machining

    /// A recess cleared with a 1/2" end mill and finished with a 1/8" one, on the default PRO6060: a 4" × 2-1/2"
    /// rectangle with a 3/8" slot out of its top (too narrow for the 1/2") and a round boss left standing.
    static func restPocketProject() -> Project {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "2E57F000-0000-0000-0000-%012d", n))! }
        let eighth = ToolLibrary.starter.tool(number: 2)!
        let half = Tool(id: id(20), number: 10, name: "1/2\" Upcut End Mill", shape: .flatEndMill, diameter: 0.5.inch, fluteLength: 1.25.inch,
                        cutting: CuttingData(spindleRPM: 10000, feedRate: 380.inch, plungeRate: 50.inch, stepdown: 0.25.inch,
                                             stepoverFraction: 0.45))
        let outline = [(2, 1.5), (6, 1.5), (6, 4), (4.1875, 4), (4.1875, 4.75), (3.8125, 4.75), (3.8125, 4), (2, 4)]
        let recess = DesignShape(id: id(1), name: "Recess", kind: .paths([Polyline(outline.map { Vec2($0.0.inch, $0.1.inch) }, closed: true)]),
                                 position: .zero)
        let boss = DesignShape(id: id(2), name: "Boss", kind: .circle(radius: 0.375.inch), position: Vec2(3.inch, 2.75.inch))
        let op = CAMOperation(id: id(11), name: "Recess", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch),
                                                                                    clearanceTool: half)),
                              shapeIDs: [recess.id, boss.id], tool: eighth)
        return Project(name: "Rest-machined recess", displayUnits: .inch,
                       stock: Stock(width: 8.inch, height: 6.inch, thickness: 0.75.inch, materialName: "Baltic birch plywood"),
                       machine: .avidPRO6060, shapes: [recess, boss], operations: [op],
                       notes: "Saved by the first build with rest machining, as format 1.")
    }

    /// The 1/2" clears first (T10), then the 1/8" (T2) cuts the slot, the corners and the walls. The project
    /// stays format 1: an older build ignores the clearance tool and cuts the same pocket with the 1/8" alone.
    @Test func restMachinedPocketDecodesAndPostsBothTools() throws {
        let p = try Self.savedProject("rest-pocket-v1", make: Self.restPocketProject)
        #expect(p.formatVersion == 1)
        let made = Self.restPocketProject()
        #expect(p.operations == made.operations && p.shapes == made.shapes)
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.toolpaths.map(\.name) == ["Recess – clearing", "Recess"])
        #expect(job.toolpaths.map(\.tool.number) == [10, 2])
        try Self.check(Self.post(p), golden: "decoded-rest-pocket-v1")
    }
}
