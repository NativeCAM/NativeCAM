import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for adaptive 3D roughing (#89): goldens for adaptive and raster 3D roughing on Avid's Mach4
/// default, a saved format-26 project with its decoded golden, the format itself, and saved projects for the edge
/// cases (`Fixtures/rough3d-adaptive`): an island narrower than the bit, layers the bit fits nowhere in, a slot too tight
/// for the loops off a floor they have room on, and rotary jobs
/// (refused). Each test asserts what NativeCAM does. The models are height fields made in code, so the tests read no
/// model file.
struct Rough3DAdaptiveCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("rough3d-adaptive")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "89AD0000-0000-4000-8001-%012d", n))! }

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
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    // MARK: Models

    /// A height field over `width` × `height` mm, `n` × `m` samples, top at `z(u, v)` (u, v from 0 to 1, z ≥ 0, mm), with a
    /// flat base at z = 0.
    static func heightField(_ meshID: UUID, width: Double, height: Double, n: Int, m: Int, z: (Double, Double) -> Double) -> MeshModel {
        var pos: [Float] = []
        var idx: [UInt32] = []
        for j in 0...m {
            for i in 0...n {
                let u = Double(i) / Double(n), v = Double(j) / Double(m)
                pos += [Float(u * width), Float(v * height), Float(max(0.01, z(u, v)))]
            }
        }
        func at(_ i: Int, _ j: Int) -> UInt32 { UInt32(j * (n + 1) + i) }
        for j in 0..<m {
            for i in 0..<n {
                idx += [at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j), at(i + 1, j + 1), at(i, j + 1)]
            }
        }
        let base = UInt32(pos.count / 3)
        pos += [0, 0, 0, Float(width), 0, 0, Float(width), Float(height), 0, 0, Float(height), 0]
        idx += [base, base + 2, base + 1, base, base + 3, base + 2]
        return MeshModel(id: meshID, name: "Height field", positions: pos, indices: idx)
    }

    /// A 50 × 40 mm dish sloping from its rim to a floor 10 mm down, with a rounded boss off centre rising 6 mm from it:
    /// slopes, a floor and an island, at a size the 1/4" end mill clears in a few levels.
    static func dish(meshID: UUID = id(1), shapeID: UUID = id(2)) -> DesignShape {
        let mesh = heightField(meshID, width: 50, height: 40, n: 25, m: 20) { u, v in
            let x = 2 * u - 1, y = 2 * v - 1
            let r2 = min(1, x * x + y * y)
            let bowl = 10 * min(1, 2.5 * (1 - r2))
            let boss = 6 * exp(-((x - 0.35) * (x - 0.35) + y * y) / 0.04)
            return 12 - bowl + min(bowl, boss)
        }
        return DesignShape(id: shapeID, name: "Dish", kind: .model(ModelSpec(mesh: mesh, depth: 12)), position: Vec2(40, 30))
    }

    static let stock = Stock(width: 80, height: 60, thickness: 20, materialName: "Maple", clearanceHeight: 10, plungeHeight: 2,
                             materialKind: .hardwood)

    static var quarter: Tool { ToolLibrary.starter.tool(number: 1)! }

    static func rough(_ n: Int, _ name: String, _ params: Rough3DParams, shape: DesignShape) -> CAMOperation {
        CAMOperation(id: id(n), name: name, kind: .rough3D(params), shapeIDs: [shape.id], tool: quarter)
    }

    static func project(_ name: String, shape: DesignShape, ops: [CAMOperation], units: LengthUnit = .inch) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        return Project(name: name, displayUnits: units, stock: stock, machine: machine, shapes: [shape], operations: ops)
    }

    static func dishJob(_ clearing: Rough3DClearing, name: String) -> Project {
        let d = dish()
        return project(name, shape: d, ops: [rough(11, "Rough dish", Rough3DParams(allowance: 0.5, clearing: clearing), shape: d)])
    }

    // MARK: Goldens

    /// The dish roughed adaptively with the defaults (a 12% load, clearing two layers deep and stepping up between),
    /// in inches on the default PRO6060.
    @Test func adaptiveGolden() throws {
        let p = Self.dishJob(.adaptive, name: "Adaptive 3D roughing")
        #expect(p.formatVersion == 26)
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(tp.radialLoad == AdaptiveSettings.defaultLoad)
        // Two 4.75 mm layers in one 9.5 mm clearing: the floor first, then a step-up round the slopes.
        let op = p.operations[0]
        guard case let .rough3D(params) = op.kind else { return }
        let plans = Model3DGenerator.adaptivePlans(op: op, params: params, shapes: p.shapes, context: GenerationContext(stock: p.stock, machine: p.machine))
        #expect(plans.map(\.layer.stepUp) == [false, true])
        #expect(Rough3DAdaptiveTests.clearance(tp, project: p) >= 0.5 - 0.03)
        try Self.checkGolden(p, "rough3d-adaptive-inch")
    }

    /// The dish roughed in raster lines: no new format.
    @Test func rasterGolden() throws {
        let p = Self.dishJob(.raster, name: "Raster 3D roughing")
        #expect(p.formatVersion < 26)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(Rough3DAdaptiveTests.clearance(tp, project: p) >= 0.5 - 0.03)
        try Self.checkGolden(p, "rough3d-raster-inch")
    }

    // MARK: File format

    /// Adaptive 3D roughing is format 26; offset and raster keep the format they had, saved without the new keys
    /// unless set, so an offset roughing's file is what it was.
    @Test func adaptiveIsFormatTwentySix() throws {
        let adaptive = Self.dishJob(.adaptive, name: "A")
        #expect(adaptive.formatVersion == Rough3DParams.adaptiveFormatVersion)
        #expect(try Project.decode(adaptive.encoded()) == adaptive)
        let raster = Self.dishJob(.raster, name: "R")
        #expect(raster.formatVersion < 26)
        var offset = Self.dishJob(.offset, name: "O")
        #expect(offset.formatVersion < 26)
        offset.operations[0].kind = .rough3D(Rough3DParams(allowance: 0.5))
        let text = String(decoding: try offset.encoded(), as: UTF8.self)
        #expect(!text.contains("\"clearing\"") && !text.contains("\"clearingDepth\"") && !text.contains("\"rasterAngle\""))
        // Settings carried by an offset roughing don't raise it.
        offset.operations[0].kind = .rough3D(Rough3DParams(allowance: 0.5, adaptive: AdaptiveSettings(optimalLoad: 0.2), clearingDepth: 9))
        #expect(offset.formatVersion < 26)
    }

    /// Every new setting away from its default, saved as format 26: the dish roughed adaptively at 15% with a 4 mm loop
    /// radius, 3 mm layers and a 9 mm clearing depth, then roughed again in raster lines at 30°.
    static func savedProject() -> Project {
        let d = dish()
        let adaptive = Rough3DParams(allowance: 0.5, passDepth: 3, clearing: .adaptive,
                                     adaptive: AdaptiveSettings(optimalLoad: 0.15, minimumLoopRadius: 4), clearingDepth: 9)
        let raster = Rough3DParams(allowance: 0.3, stepoverFraction: 0.3, clearing: .raster, rasterAngle: 30)
        var p = project("Adaptive 3D roughing (format 26)", shape: d,
                        ops: [rough(21, "Rough adaptively", adaptive, shape: d), rough(22, "Rough in raster lines", raster, shape: d)],
                        units: .mm)
        p.notes = "Saved by the first build with adaptive 3D roughing, as format 26."
        return p
    }

    @Test func savedProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("rough3d-adaptive-v26", make: Self.savedProject)
        #expect(p.formatVersion == 26)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "decoded-rough3d-adaptive-v26")
    }

    // MARK: Edge cases

    /// A floor 8 mm down round a 2 mm square pin standing to the material top: at every layer the pin is an island
    /// narrower than the bit.
    static func pinned() -> Project {
        let mesh = heightField(id(31), width: 40, height: 40, n: 40, m: 40) { u, v in
            let x = 40 * u - 20, y = 40 * v - 20
            if abs(x) <= 1, abs(y) <= 1 { return 12 }
            let edge = max(abs(x), abs(y))
            return edge > 18 ? 12 : 4
        }
        let shape = DesignShape(id: id(32), name: "Pin", kind: .model(ModelSpec(mesh: mesh, depth: 12)), position: Vec2(40, 30))
        return project("Island narrower than the bit", shape: shape,
                       ops: [rough(33, "Rough round the pin", Rough3DParams(allowance: 0.5, clearing: .adaptive), shape: shape)], units: .mm)
    }

    /// The bit goes round the pin and leaves the allowance on it: it clears the floor right round it, and never comes
    /// nearer the pin (or anything else) than the allowance.
    @Test func anIslandNarrowerThanTheBitIsLeftStanding() throws {
        let p = try Self.edgeCase("island-narrower-than-bit", make: Self.pinned)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(Rough3DAdaptiveTests.clearance(tp, project: p) >= 0.5 - 0.03)
        let grid = Fixture.simulate(job.toolpaths, stock: p.stock, cell: 0.25)
        let pin = Vec2(40, 30)
        var standing = 0, ring = 0, ringCut = 0
        for r in 0..<grid.rows {
            for c in 0..<grid.columns {
                let q = grid.origin + Vec2(Double(c), Double(r)) * grid.cellSize
                let d = max(abs(q.x - pin.x), abs(q.y - pin.y))
                let h = Double(grid.heights[grid.index(c, r)])
                if d < 0.9, h > -0.01 { standing += 1 }
                // A ring round the pin, beyond its allowance plus the grid's margin.
                if d > 3, d < 6 {
                    ring += 1
                    if h < -6 { ringCut += 1 }
                }
            }
        }
        #expect(standing > 20, "the pin's top was cut")
        #expect(ringCut > ring * 9 / 10, "\(ringCut) of \(ring) cells round the pin cleared")
    }

    /// A floor 6 mm down with a 3 mm trench to 14 mm along it: the layers below the floor are only the trench, which
    /// the bit fits nowhere in.
    static func trenched() -> Project {
        let mesh = heightField(id(41), width: 40, height: 30, n: 40, m: 30) { u, v in
            let x = 40 * u - 20, y = 30 * v - 15
            if abs(x) > 18 || abs(y) > 13 { return 16 }
            return abs(y) <= 1.5 ? 2 : 10
        }
        let shape = DesignShape(id: id(42), name: "Trench", kind: .model(ModelSpec(mesh: mesh, depth: 16)), position: Vec2(40, 30))
        return project("Layers the bit fits nowhere in", shape: shape,
                       ops: [rough(43, "Rough the trenched floor", Rough3DParams(allowance: 0.5, clearing: .adaptive), shape: shape)],
                       units: .mm)
    }

    /// The layers the bit fits nowhere in are skipped without a word, as offset roughing skips them: the toolpath clears
    /// the levels above and stops at the same depth offset roughing does.
    @Test func aLayerTheBitFitsNowhereInIsSkipped() throws {
        let p = try Self.edgeCase("layer-too-narrow-for-the-bit", make: Self.trenched)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        var offset = p
        offset.operations[0].kind = .rough3D(Rough3DParams(allowance: 0.5))
        let o = try #require(CAMEngine.generate(offset).toolpaths.first)
        let deepest = try #require(tp.cuttingExtents).min.z
        let offsetDeepest = try #require(o.cuttingExtents).min.z
        #expect(abs(deepest - offsetDeepest) < 1e-6, "adaptive to \(deepest), offset to \(offsetDeepest)")
        // Nothing reaches into the trench: the cut stops above the floor less the allowance.
        #expect(deepest > -(6 - 0.5) - 1e-6)
        #expect(Rough3DAdaptiveTests.clearance(tp, project: p) >= 0.5 - 0.03)
    }

    /// A 50 × 24 mm floor 6 mm down with a 10 mm wide slot 15 mm long off one side (#146): the loops have room on the
    /// floor, but the slot is too tight for them.
    static func slotted() -> Project {
        let mesh = heightField(id(51), width: 70, height: 50, n: 70, m: 50) { u, v in
            let x = 70 * u - 35, y = 50 * v - 25
            let floor = abs(x) <= 25 && y >= -20 && y <= 4
            let slot = abs(x) <= 5 && y > 4 && y <= 19
            return floor || slot ? 6 : 12
        }
        let shape = DesignShape(id: id(52), name: "Slotted floor", kind: .model(ModelSpec(mesh: mesh, depth: 12)), position: Vec2(40, 30))
        return project("Load not held", shape: shape,
                       ops: [rough(53, "Rough the slotted floor", Rough3DParams(allowance: 0.5, clearing: .adaptive), shape: shape)],
                       units: .mm)
    }

    /// Where the loops have room and still can't hold the load (the slot off the floor), the toolpath warns, as an
    /// adaptive pocket does; a layer that's only a narrow band (the demo relief's foot, `Rough3DAdaptiveTests`) is noted.
    @Test func aSlotTooTightForTheLoopsStillWarns() throws {
        let p = try Self.edgeCase("load-not-held", make: Self.slotted)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        let warned = tp.warnings.contains { $0.hasPrefix("Adaptive clearing couldn't hold its load everywhere") }
        #expect(warned, "\(tp.warnings)")
        let issue = job.issues.first { $0.message.hasPrefix("Adaptive clearing couldn't hold its load") }
        #expect(issue?.severity == .warning)
        #expect(Rough3DAdaptiveTests.clearance(tp, project: p) >= 0.5 - 0.03)
    }

    /// The dish on an indexed rotary blank, and on one with designs wrapped round it.
    static func rotary(wrapped: Bool) -> Project {
        var p = Self.dishJob(.adaptive, name: wrapped ? "Adaptive 3D roughing, wrapped (refused)" : "Adaptive 3D roughing, rotary (refused)")
        p.machine.rotary = RotaryAxis(centerHeight: 4.inch)
        p.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 3.inch, length: 8.inch, layout: wrapped ? .wrapped : nil))
        return p
    }

    /// On a rotary job adaptive 3D roughing isn't cut, and says why; offset roughing on the same job isn't refused.
    @Test(arguments: [false, true])
    func rotaryJobsRefuseAdaptiveRoughing(_ wrapped: Bool) throws {
        let p = try Self.edgeCase(wrapped ? "rotary-wrapped-refused" : "rotary-refused") { Self.rotary(wrapped: wrapped) }
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.allSatisfy { $0.cuttingExtents == nil })
        let refusal = "Adaptive 3D roughing isn't available on rotary jobs yet"
        #expect(job.issues.contains { $0.message.hasPrefix(refusal) }, "\(job.issues.map(\.message))")
        var offset = p
        offset.operations[0].kind = .rough3D(Rough3DParams(allowance: 0.5))
        #expect(!CAMEngine.generate(offset).issues.contains { $0.message.hasPrefix(refusal) })
    }
}
