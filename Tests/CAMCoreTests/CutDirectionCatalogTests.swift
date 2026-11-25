import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for cut direction (#137): goldens on Avid's Mach4 default for raster finishing climbing,
/// waterline going conventional, a spiral climbing, a V-carve's raster clearing going conventional and 3D rotary
/// roughing climbing; a saved format-27 project with its decoded golden and the format itself; and saved projects for
/// the edge cases (`Fixtures/cut-direction`): a pattern that can't hold the direction (pencil passes, which warn), and
/// a one-way raster over a model with a deep pocket, whose links must go over it safely.
struct CutDirectionCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("cut-direction")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "137CD000-0000-4000-8000-%012d", n))! }

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    /// Posts `p` for Avid's Mach4 profile, compares it with the golden and runs the export checks on it.
    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        #expect(job.toolpaths.allSatisfy { !$0.isEmpty }, sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    /// `p` on Avid's default output, arcs and all.
    static func withArcs(_ p: Project) -> Project {
        var q = p
        q.machine.outputArcs = MachineProfile.avidPRO6060.outputArcs
        return q
    }

    // MARK: Goldens

    @Test func rasterFinishingClimbGolden() throws {
        let p = Self.withArcs(CutDirectionTests.finish(.climb))
        #expect(p.formatVersion == 27)
        try Self.checkGolden(p, "cut-direction-raster-climb-mm")
    }

    @Test func waterlineConventionalGolden() throws {
        let p = FinishingPatternsCatalogTests.coinProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .waterline,
                                                                         cutDirection: .conventional))
        #expect(p.formatVersion == 27)
        try Self.checkGolden(p, "cut-direction-waterline-conventional-mm")
    }

    @Test func spiralClimbGolden() throws {
        let p = Self.withArcs(CutDirectionTests.finish(.climb, strategy: .spiral))
        try Self.checkGolden(p, "cut-direction-spiral-climb-mm")
    }

    @Test func vcarveRasterConventionalGolden() throws {
        let p = CutDirectionTests.vcarve(.conventional)
        #expect(p.formatVersion == 27)
        try Self.checkGolden(p, "cut-direction-vcarve-raster-conventional-mm")
    }

    @Test func rotaryRoughingClimbGolden() throws {
        var p = Rotary3DRoughingTests.smallRough()
        guard case var .rotaryRough(r) = p.operations[0].kind else { return }
        r.cutDirection = .climb
        p.operations[0].kind = .rotaryRough(r)
        #expect(p.formatVersion == 27)
        try Self.checkGolden(p, "cut-direction-rotary-rough-climb-mm")
    }

    // MARK: File format

    /// The default direction saves no key and keeps the format; any other is format 27, except where the passes can't
    /// hold it and cut the same.
    @Test func aDirectionOtherThanTheDefaultIsFormatTwentySeven() throws {
        let plain = String(decoding: try JSONEncoder().encode(Finish3DParams(strategy: .waterline)), as: UTF8.self)
        #expect(!plain.contains("cutDirection"))
        var kind = OperationKind.finish3D(Finish3DParams(strategy: .waterline))
        kind.passDirection = .climb
        #expect(kind == .finish3D(Finish3DParams(strategy: .waterline)))
        #expect(Finish3DParams(cutDirection: .climb).requiredFormatVersion == 27)
        #expect(Finish3DParams(strategy: .waterline, cutDirection: .conventional).requiredFormatVersion == 27)
        #expect(Finish3DParams(strategy: .pencil, cutDirection: .climb).requiredFormatVersion == 10)
        #expect(Rough3DParams(clearing: .raster, cutDirection: .climb).requiredFormatVersion == 27)
        #expect(Rough3DParams(cutDirection: .climb).requiredFormatVersion == 1)
        #expect(VCarveParams(cutDirection: .conventional).requiredFormatVersion == 27)
        #expect(FlutingParams(cutDirection: .climb).directionNote != nil)
        let rounding = CAMOperation(kind: .rounding(RoundingParams(cutDirection: .climb)), shapeIDs: [], tool: CutDirectionTests.endMill)
        #expect(rounding.requiredFormatVersion == 27)
        #expect(Project.currentFormatVersion >= 27)
        let p = Self.savedProject()
        #expect(try Project.decode(p.encoded()) == p)
    }

    /// Every toolpath kind away from its default direction that a flat job holds: 3D raster roughing conventional at
    /// 30°, then a raster finish climbing, on the dish.
    static func savedProject() -> Project {
        var p = CutDirectionTests.dishJob(.rough3D(Rough3DParams(allowance: 0.5, stepoverFraction: 0.5, clearing: .raster, rasterAngle: 30,
                                                                 cutDirection: .conventional)),
                                          tool: CutDirectionTests.endMill, name: "Cut direction (format 27)")
        p.operations[0].name = "Rough conventional"
        p.operations.append(CAMOperation(id: Self.id(11), name: "Finish climbing",
                                         kind: .finish3D(Finish3DParams(stepoverFraction: 0.3, cutDirection: .climb)),
                                         shapeIDs: p.operations[0].shapeIDs, tool: CutDirectionTests.ball))
        p.notes = "Saved by the first build with cut direction, as format 27."
        return p
    }

    @Test func savedProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("cut-direction-v27", make: Self.savedProject)
        #expect(p.formatVersion == 27)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        try Self.checkGolden(p, "decoded-cut-direction-v27")
    }

    // MARK: Edge cases

    /// Pencil finishing asked to climb: its passes can't, so they're cut as both ways, and the toolpath and Checks say so.
    @Test func aPatternThatCantHoldTheDirectionWarns() throws {
        let p = try Self.edgeCase("pencil-cannot-climb") {
            var p = CutDirectionTests.finish(.climb, strategy: .pencil)
            p.name = "Pencil asked to climb"
            return p
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        let warning = "Pencil passes run along creases with the model rising on both sides, so they can't be cut climb"
        #expect(tp.warnings.contains { $0.hasPrefix(warning) }, "\(tp.warnings)")
        #expect(job.issues.contains { $0.severity == .warning && $0.message.hasPrefix(warning) })
        var both = p
        both.operations[0].kind.passDirection = .both
        #expect(CAMEngine.generate(both).toolpaths.first?.motions == tp.motions)
    }

    /// A 40 mm block with a 12 mm square pocket 16 mm deep in it, roughed, then finished in one-way raster rows.
    static func deepPocket() -> Project {
        let mesh = Rough3DAdaptiveCatalogTests.heightField(Self.id(21), width: 40, height: 40, n: 40, m: 40) { u, v in
            let x = 40 * u - 20, y = 40 * v - 20
            return abs(x) <= 6 && abs(y) <= 6 ? 4 : 20
        }
        let shape = DesignShape(id: Self.id(22), name: "Block", kind: .model(ModelSpec(mesh: mesh, depth: 20)), position: Vec2(30, 30))
        let stock = Stock(width: 60, height: 60, thickness: 25, materialName: "Maple", clearanceHeight: 10, plungeHeight: 2,
                          materialKind: .hardwood)
        let rough = CAMOperation(id: Self.id(23), name: "Rough", kind: .rough3D(Rough3DParams(allowance: 0.5)), shapeIDs: [shape.id],
                                 tool: CutDirectionTests.endMill)
        let finish = CAMOperation(id: Self.id(24), name: "Finish one way",
                                  kind: .finish3D(Finish3DParams(stepoverFraction: 0.2, cutDirection: .climb)), shapeIDs: [shape.id],
                                  tool: CutDirectionTests.ball)
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = .mm
        return Project(name: "One-way raster over a deep pocket", displayUnits: .mm, stock: stock, machine: machine, shapes: [shape],
                       operations: [rough, finish])
    }

    /// Every row climbs; each link back lifts over the pocket's walls (no rapid runs into material in simulation), the
    /// passes never go below the drop-cutter surface, and arc fitting keeps to its surface check (#128).
    @Test func aOneWayRasterLinksSafelyOverADeepPocket() throws {
        let p = try Self.edgeCase("one-way-over-deep-pocket", make: Self.deepPocket)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first { $0.id == Self.id(24) })
        let rows = CutDirectionTests.rowTravel(tp, angle: 0)
        #expect(rows.forward == 0 && rows.back > 200, "\(rows)")
        // The rows reach the pocket's floor.
        #expect((tp.cuttingExtents?.min.z ?? 0) < -15)
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 0.25)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty, "\(s.rapidCollisions.prefix(5))")
        #expect(RestFinishingTests.pathGouge(tp, project: p) < 3 * p.machine.arcFitTolerance)
        var straight = p
        straight.machine.outputArcs = false
        let plain = try #require(CAMEngine.generate(straight).toolpaths.first { $0.id == Self.id(24) })
        #expect(RestFinishingTests.pathGouge(plain, project: p) < 1e-6)
    }
}
