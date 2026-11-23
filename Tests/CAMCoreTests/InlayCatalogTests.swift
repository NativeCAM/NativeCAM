import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog's inlay entries (#85): one golden G-code file per inlay option and workflow step, posted for
/// the default Avid PRO6060 with Mach4 in millimetres (`golden/inlay-<option>-mm.tap`), so a regression points at one
/// option, and a fixture for each edge case with what NativeCAM does with it.
struct InlayCatalogTests {
    static var vBit60: Tool { InlayTests.vBit60 }
    static var eighth: Tool { InlayTests.eighth }

    static let stock = Stock(width: 120, height: 100, thickness: 19, materialName: "Walnut")

    /// The L with a hole (`InlayTests.lShape`), in the middle of the board.
    static func design() -> [DesignShape] {
        [InlayTests.lShape(at: Vec2(60, 50)), DesignShape(name: "Hole", kind: .circle(radius: 3), position: Vec2(68, 42))]
    }

    /// The default Avid PRO6060 with Mach4, posting millimetres.
    static func project(shapes: [DesignShape]) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = .mm
        return Project(name: "Inlay catalog", displayUnits: .mm, stock: stock, machine: machine, shapes: shapes)
    }

    /// The Inlay dialog's usual settings, with the 1/8" end mill clearing the flats.
    static func settings(_ change: (inout InlayPairSettings) -> Void = { _ in }) -> InlayPairSettings {
        var s = InlayPairSettings(vBit: vBit60, clearanceTool: eighth)
        change(&s)
        return s
    }

    enum Side { case pocket, plug }

    /// The pair Add Toolpath ▸ Inlay… makes for `shapes`, with only `side` included in the output (as it's exported),
    /// after `change` (a step taken on the pair afterwards).
    static func pair(_ settings: InlayPairSettings, side: Side, shapes: [DesignShape] = design(),
                     change: (inout Project, CAMOperation, CAMOperation) -> Void = { _, _, _ in }) throws -> Project {
        var project = project(shapes: shapes)
        let added = project.addInlay(settings, shapes: shapes.map(\.id))
        let pair = try #require(added)
        change(&project, pair.pocket, pair.plug)
        for i in project.operations.indices {
            project.operations[i].enabled = project.operations[i].id == (side == .pocket ? pair.pocket.id : pair.plug.id)
        }
        return project
    }

    /// Posts `project` and compares it with `golden/<name>.tap`; the job has no warnings, the file passes the export
    /// checks and never rapids sideways below the surface.
    static func checkGolden(_ project: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(project)
        let warnings = job.issues.filter { $0.severity != .info }.map(\.message)
        #expect(warnings.isEmpty, "\(warnings)", sourceLocation: sourceLocation)
        #expect(InlayTests.lowRapids(job.toolpaths).isEmpty, sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(project, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: project, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    // MARK: Inlay…: one golden per workflow step

    @Test func dialogPocketGolden() throws {
        try Self.checkGolden(Self.pair(Self.settings(), side: .pocket), "inlay-dialog-pocket-mm")
    }

    @Test func dialogPlugGolden() throws {
        try Self.checkGolden(Self.pair(Self.settings(), side: .plug), "inlay-dialog-plug-mm")
    }

    @Test func dialogSelectedVectorGolden() throws {
        // A rectangle round the design, selected with it: the dialog gives it to the plug only, as its boundary.
        let board = DesignShape(name: "Plug board", kind: .rectangle(width: 70, height: 50, cornerRadius: 0), position: Vec2(60, 50))
        let p = try Self.pair(Self.settings { $0.boundary = .vector }, side: .plug, shapes: Self.design() + [board])
        #expect(p.operations[0].shapeIDs.count == 2 && p.operations[1].shapeIDs.contains(board.id))
        try Self.checkGolden(p, "inlay-dialog-vector-mm")
    }

    @Test func updatePartnerGolden() throws {
        // The pocket made 0.25 in deep afterwards, then Update “Inlay plug” on the pocket: the plug follows.
        let p = try Self.pair(Self.settings(), side: .plug) { project, pocket, plug in
            var deeper = pocket
            guard case var .vcarve(v) = deeper.kind else { return }
            v.flatDepth = 0.25.inch
            deeper.kind = .vcarve(v)
            project.operations = [deeper, deeper.inlayPartnerMatched(plug)]
        }
        #expect(p.operations[1].inlayPocketDepth == 0.25.inch && p.operations[0].inlayDifferences(from: p.operations[1]).isEmpty)
        try Self.checkGolden(p, "inlay-update-partner-mm")
    }

    // MARK: Whole board

    @Test func wholeBoardGolden() throws {
        let p = try Self.pair(Self.settings { $0.boundary = .board }, side: .plug)
        #expect(p.plugBoard(for: p.operations[1]) == Self.stock.bounds)
        try Self.checkGolden(p, "inlay-whole-board-mm")
    }

    @Test func boardSizeGolden() throws {
        let p = try Self.pair(Self.settings { $0.boundary = .board; $0.boardSize = Vec2(90, 70) }, side: .plug)
        #expect(p.plugBoard(for: p.operations[1]) == Rect2(x: 15, y: 15, width: 90, height: 70))
        try Self.checkGolden(p, "inlay-board-size-mm")
    }

    // MARK: Raster flat clearing

    static func raster(_ raster: VCarveRaster) -> InlayPairSettings {
        settings { $0.clearanceTool = nil; $0.flatRaster = raster }
    }

    @Test func rasterPocketGolden() throws {
        try Self.checkGolden(Self.pair(Self.raster(VCarveRaster()), side: .pocket), "inlay-raster-pocket-mm")
    }

    @Test func rasterPlugGolden() throws {
        try Self.checkGolden(Self.pair(Self.raster(VCarveRaster()), side: .plug), "inlay-raster-plug-mm")
    }

    @Test func rasterAngleGolden() throws {
        try Self.checkGolden(Self.pair(Self.raster(VCarveRaster(angle: 30)), side: .pocket), "inlay-raster-angle-mm")
    }

    @Test func rasterStepoverGolden() throws {
        // A stepover of your own, finer than the automatic one.
        let p = try Self.pair(Self.raster(VCarveRaster(stepover: 0.1)), side: .pocket)
        guard case let .vcarve(v) = p.operations[0].kind else { Issue.record("not a V-carve"); return }
        #expect(v.vBitRasterStepover(Self.vBit60) == 0.1 && v.vBitRasterSpacing(Self.vBit60) > 0.1)
        try Self.checkGolden(p, "inlay-raster-stepover-mm")
    }

    // MARK: Edge cases

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "1A1A0000-0000-0000-0000-%012d", n))! }

    /// A saved pair, its shapes and toolpaths given fixed ids, with only the plug included.
    static func saved(_ name: String, _ settings: InlayPairSettings, notes: String) -> Project {
        var shapes = design()
        for i in shapes.indices { shapes[i].id = id(i + 1) }
        var (pocket, plug) = settings.operations(design: shapes.map(\.id), boundaryVector: nil)
        pocket.id = id(11)
        plug.id = id(12)
        pocket.enabled = false
        plug.enabled = true
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = .mm
        return Project(name: name, displayUnits: .mm, stock: stock, machine: machine, shapes: shapes, operations: [pocket, plug], notes: notes)
    }

    static func savedGlueGapOverDepth() -> Project {
        saved("Inlay: glue gap over the pocket depth", settings { $0.pocketDepth = 0.2.inch; $0.glueGap = 0.3.inch },
              notes: "A plug whose glue gap (0.3 in) is bigger than its pocket depth (0.2 in).")
    }

    @Test func glueGapBiggerThanThePocketDepth() throws {
        let p = try GoldenPostTests.savedProject("inlay-glue-gap-over-depth", make: Self.savedGlueGapOverDepth)
        #expect(p == Self.savedGlueGapOverDepth())
        #expect(p.formatVersion == 6)
        guard case let .vcarve(v) = p.operations[1].kind, let inlay = v.inlay else { Issue.record("no plug"); return }
        // Kept as entered, never quietly changed...
        #expect(inlay.glueGap == 0.3.inch && inlay.pocketDepth == 0.2.inch)
        // ...but the start depth can't rise above the surface: the plug is carved from the top down to the surface
        // clearance, and Checks says it has no walls to fit by.
        #expect(inlay.plugStartDepth == 0 && inlay.plugCutDepth == inlay.surfaceClearance)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let deepest = job.toolpaths.compactMap { $0.cuttingExtents.map { -$0.min.z } }.max() ?? 0
        #expect(abs(deepest - inlay.surfaceClearance) < 1e-6, "cut \(deepest) deep")
        #expect(job.issues.contains { $0.operation == "Inlay plug" && $0.message.contains("isn't less than the pocket depth") })
        #expect(InlayTests.lowRapids(job.toolpaths).isEmpty)
    }

    static func savedStartDepthZero() -> Project {
        saved("Inlay: start depth 0", raster(VCarveRaster()).with { $0.pocketDepth = 0.1.inch; $0.glueGap = 0.1.inch; $0.boundary = .board },
              notes: "A whole-board plug cleared in raster lines whose glue gap equals its pocket depth: start depth 0.")
    }

    @Test func startDepthOfZero() throws {
        let p = try GoldenPostTests.savedProject("inlay-start-depth-zero", make: Self.savedStartDepthZero)
        #expect(p == Self.savedStartDepthZero())
        #expect(p.formatVersion == 14)
        // The pocket's start depth of 0 isn't written at all, as in files saved before start depths.
        let data = try Data(contentsOf: GoldenPostTests.projects.appendingPathComponent("inlay-start-depth-zero.nativecam"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ops = try #require(json["operations"] as? [[String: Any]])
        let pocketKind = try #require(ops.first?["kind"] as? [String: Any])
        #expect(!String(describing: pocketKind).contains("startDepth"))
        guard case let .vcarve(v) = p.operations[1].kind, let inlay = v.inlay else { Issue.record("no plug"); return }
        #expect(inlay.plugStartDepth == 0 && v.carveStartDepth == 0)
        // Carved from the surface: its floor at the surface clearance right across the board, one level of raster.
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tps = job.toolpaths.filter { $0.sourceOperationID == p.operations[1].id }
        let deepest = tps.compactMap { $0.cuttingExtents.map { -$0.min.z } }.max() ?? 0
        #expect(abs(deepest - inlay.surfaceClearance) < 1e-6, "cut \(deepest) deep")
        let grid = Fixture.simulate(tps, stock: p.stock, cell: 0.25)
        for q in [Vec2(5.125, 5.125), Vec2(110.125, 90.125), Vec2(20.125, 80.125)] {
            let h = Double(try #require(grid.height(at: q)))
            #expect(h < -inlay.surfaceClearance + 2 * v.vBitRasterRidge + 0.1 && h > -inlay.surfaceClearance - 0.02, "\(q): \(h)")
        }
        #expect(job.issues.contains { $0.operation == "Inlay plug" && $0.message.contains("isn't less than the pocket depth") })
        #expect(InlayTests.lowRapids(job.toolpaths).isEmpty)
        let gcode = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(GCodeCheck.run(gcode, toolpaths: job.toolpaths, project: p, dialect: .avidMach4).filter { $0.severity == .error }.isEmpty)
    }

    @Test func openContoursInAnImportedDesignAreLeftOut() throws {
        let url = try #require(Bundle.module.url(forResource: "inlay-open-contour", withExtension: "svg", subdirectory: "Fixtures/svg"))
        let shapes = try VectorImporter.importFile(at: url).shapes(name: "inlay-open-contour", stock: Self.stock)
        // One shape per layer: the design (a closed L and an open stroke) and the swash (open only).
        #expect(shapes.map(\.layer).sorted() == ["Design", "Swash"])
        let design = try #require(shapes.first { $0.layer == "Design" }), swash = try #require(shapes.first { $0.layer == "Swash" })
        #expect(design.polylines(tolerance: 0.01).filter(\.isClosed).count == 1 && design.polylines(tolerance: 0.01).contains { !$0.isClosed })
        var project = Self.project(shapes: shapes)
        // The swash, open only, isn't a vector an inlay can be made from.
        #expect(project.inlayShapes(shapes.map(\.id)).map(\.id) == [design.id])
        let swashOnly = project.addInlay(Self.settings(), shapes: [swash.id])
        #expect(swashOnly == nil && project.operations.isEmpty)
        // With everything selected, the pair is the L's: the open stroke in its layer isn't carved on either side.
        let added = project.addInlay(Self.settings(), shapes: shapes.map(\.id))
        let pair = try #require(added)
        #expect(pair.pocket.shapeIDs == [design.id] && pair.plug.shapeIDs == [design.id])
        for i in project.operations.indices { project.operations[i].enabled = true }
        let job = CAMEngine.generate(project)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let stroke = try #require(design.polylines(tolerance: 0.01).first { !$0.isClosed }).bounds
        for tp in job.toolpaths {
            let e = try #require(tp.cuttingExtents)
            // The L spans x 40–80 (the plug's band 6 mm further); the stroke starts at x 96.
            #expect(e.max.x < stroke.min.x - 1, "\(tp.name) reaches x \(e.max.x)")
        }
    }
}

extension InlayPairSettings {
    /// A copy with `change` made.
    func with(_ change: (inout InlayPairSettings) -> Void) -> InlayPairSettings {
        var s = self
        change(&s)
        return s
    }
}
