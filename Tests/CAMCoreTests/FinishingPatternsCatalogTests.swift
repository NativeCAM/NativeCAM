import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for constant scallop, spiral and radial 3D finishing (#88): one golden per pattern on a coin
/// read from an STL written for the tests (`Fixtures/finishing-patterns/coin.stl`), posted for Avid's Mach4 default and
/// compared byte for byte; a saved format-21 project; and saved projects for the edge cases
/// (`Fixtures/finishing-patterns`), each test asserting what NativeCAM does with it. The posts write these toolpaths like
/// any other 3D finish, so other controllers have no goldens of their own here.
struct FinishingPatternsCatalogTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("finishing-patterns")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "88F10000-0000-4000-8000-%012d", n))! }

    // MARK: The coin

    /// A coin 30 mm across and 3.2 mm thick: a bump in the middle, a flat field, a raised rim with a chamfer, and a
    /// 1.6 mm vertical edge.
    static func coinProfile() -> [(r: Float, z: Float)] {
        var p: [(r: Float, z: Float)] = []
        for i in 0...12 {
            let r = Float(i) * 0.5
            p.append((r, 1.6 + 1.6 * cos(Float.pi * r / 12)))
        }
        p.append((11, 1.6))
        for i in 1...4 {
            let t = Float(i) / 4
            p.append((11 + 1.5 * t, 1.6 + 0.5 * (1 - cos(Float.pi * t))))
        }
        p.append((14, 2.6))
        p.append((15, 1.6))
        return p
    }

    /// The coin as a binary STL, as `coin.stl` was written.
    static func coinSTL() -> Data {
        let mesh = revolvedMesh(coinProfile(), segments: 64, name: "Coin")
        var tris: [MeshImportTests.Tri] = []
        func v(_ i: UInt32) -> SIMD3<Float> {
            let k = Int(i) * 3
            return SIMD3(mesh.positions[k], mesh.positions[k + 1], mesh.positions[k + 2])
        }
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            tris.append((v(mesh.indices[t]), v(mesh.indices[t + 1]), v(mesh.indices[t + 2])))
        }
        return MeshImportTests.binarySTL(tris, header: "NativeCAM test coin, 30 mm, Z up")
    }

    /// The coin read from `coin.stl` (written from `coinSTL()` in update mode when it's missing, never replaced).
    static let coinMesh: MeshModel = {
        let url = dir.appendingPathComponent("coin.stl")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? coinSTL().write(to: url)
        }
        // swiftlint:disable:next force_try
        var mesh = try! STLImporter.importSTL(data: Data(contentsOf: url), name: "Coin").mesh
        mesh.id = id(1)
        return mesh
    }()

    static let coinCentre = Vec2(30, 30)

    static func coin() -> DesignShape {
        DesignShape(id: id(2), name: "Coin", kind: .model(ModelSpec(mesh: coinMesh, depth: 3.2)), position: coinCentre)
    }

    static func outline() -> DesignShape {
        DesignShape(id: id(3), name: "Outline", kind: .circle(radius: 15), position: coinCentre)
    }

    static let stock = Stock(width: 60, height: 60, thickness: 10, clearanceHeight: 10, plungeHeight: 2)

    /// The coin inside its outline with one 3D finish (`params`).
    static func coinProject(_ params: Finish3DParams, tool: Tool = FinishingPatternsTests.ball, name: String? = nil) -> Project {
        let shapes = [coin(), outline()]
        let op = CAMOperation(id: id(10), name: name ?? params.strategy.label, kind: .finish3D(params), shapeIDs: shapes.map(\.id), tool: tool)
        return Project(name: "Coin", displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: shapes, operations: [op])
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

    @Test func theCoinSTLIsTheOneTheTestsWrite() throws {
        _ = Self.coinMesh // writes it in update mode
        let url = Self.dir.appendingPathComponent("coin.stl")
        #expect(try Data(contentsOf: url) == Self.coinSTL())
        let o = ModelSpec(mesh: Self.coinMesh, depth: 3.2).oriented
        #expect(abs(o.size.x - 30) < 0.01 && abs(o.size.z - 3.2) < 0.01, "\(o.size)")
    }

    // MARK: Goldens

    @Test func constantScallopGolden() throws {
        try Self.checkGolden(Self.coinProject(Finish3DParams(boundary: .vectors, strategy: .constantScallop, scallopHeight: 0.1)),
                             "finish-constant-scallop-mm")
    }

    @Test func spiralGolden() throws {
        try Self.checkGolden(Self.coinProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .spiral)), "finish-spiral-mm")
    }

    @Test func radialGolden() throws {
        try Self.checkGolden(Self.coinProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .radial)), "finish-radial-mm")
    }

    // MARK: File format

    @Test func thePatternsRaiseTheFormatOnlyWhenUsed() throws {
        for s in [Finish3DStrategy.constantScallop, .spiral, .radial] {
            #expect(Finish3DParams(strategy: s).requiredFormatVersion == 21)
        }
        // Their settings mean nothing to the other strategies, so on those they leave the format alone.
        let unused = Finish3DParams(scallopHeight: 0.05, centre: Vec2(1, 2), spiralHoldsScallop: true, radialStep: 3, radialMinSpacing: 1)
        #expect(unused.requiredFormatVersion == 1)
        #expect(Self.coinProject(unused).formatVersion == 1)
        #expect(Self.coinProject(Finish3DParams(strategy: .spiral)).formatVersion == 21)
        #expect(Project.currentFormatVersion >= 21)
        // A raster saves only the keys it always had.
        let plain = String(decoding: try JSONEncoder().encode(Finish3DParams(smoothLinks: false)), as: UTF8.self)
        for key in ["scallopHeight", "centre", "spiralHoldsScallop", "radialStep", "radialMinSpacing"] { #expect(!plain.contains(key)) }
        let every = Finish3DParams(stepoverFraction: 0.15, boundary: .vectors, strategy: .radial, scallopHeight: 0.03, centre: Vec2(10, 20),
                                   spiralHoldsScallop: true, radialStep: 2.5, radialMinSpacing: 0.7)
        #expect(try JSONDecoder().decode(Finish3DParams.self, from: JSONEncoder().encode(every)) == every)
    }

    // MARK: Saved project

    /// Every new setting away from its default, saved as format 21: the coin finished by constant scallop to a
    /// scallop height with an allowance, by a spiral from a picked centre holding the scallop, and by radial spokes at
    /// a step and minimum spacing of their own without smooth links.
    static func savedProject() -> Project {
        let shapes = [coin(), outline()]
        let ids = shapes.map(\.id)
        let ball = FinishingPatternsTests.ball
        let ops = [
            CAMOperation(id: id(20), name: "Constant scallop", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.2, allowance: 0.05, boundary: .vectors, boundaryMargin: 2, strategy: .constantScallop, scallopHeight: 0.08)),
                         shapeIDs: ids, tool: ball),
            CAMOperation(id: id(21), name: "Spiral", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.3, boundary: .vectors, strategy: .spiral, scallopHeight: 0.12, centre: Vec2(31, 29), spiralHoldsScallop: true)),
                         shapeIDs: ids, tool: ball),
            CAMOperation(id: id(22), name: "Radial", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.25, boundary: .vectors, strategy: .radial, smoothLinks: false, radialStep: 6, radialMinSpacing: 1)),
                         shapeIDs: ids, tool: ball),
        ]
        return Project(name: "Finishing patterns (format 21)", displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: shapes,
                       operations: ops, notes: "Saved by format 21 to pin constant scallop, spiral and radial finishing.")
    }

    @Test func savedFinishingPatternsProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("finishing-v21", make: Self.savedProject)
        #expect(p.formatVersion == 21)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 3 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "decoded-finishing-v21")
    }

    // MARK: Edge cases

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = dir.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    /// The coin with each pattern as its own toolpath (`params` with the strategy set), on `shapes`.
    static func eachPattern(_ params: Finish3DParams, shapes: [DesignShape], name: String) -> Project {
        let ops = [Finish3DStrategy.constantScallop, .spiral, .radial].enumerated().map { k, s in
            var q = params
            q.strategy = s
            return CAMOperation(id: id(30 + k), name: s.label, kind: .finish3D(q), shapeIDs: shapes.map(\.id), tool: FinishingPatternsTests.ball)
        }
        return Project(name: name, displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: shapes, operations: ops)
    }

    /// The regions the tool centre may be in for `p`'s first toolpath.
    static func regions(_ p: Project, _ op: CAMOperation) throws -> [Region] {
        guard case let .finish3D(fp) = op.kind else { return [] }
        var warnings: [String] = []
        let r = Model3DGenerator.boundaryRegions(shapes: p.shapes(for: op), boundary: fp.boundary,
                                                 margin: fp.boundaryMargin ?? Finish3DParams.autoMargin(tool: op.tool), stock: p.stock,
                                                 warnings: &warnings)
        return try #require(r).regions
    }

    /// A ring-shaped boundary: the coin's outline with a 4 mm circle over its bump, so the area has a hole. Every
    /// pattern stays out of the hole (and inside the outline) and covers the ring right round it: constant scallop runs
    /// its passes round the hole as well as in from the outline, and the spiral, whose centre (the ring's centroid) is
    /// in the hole, starts at the hole's edge with no warning.
    @Test func aBoundaryWithAHole() throws {
        let p = try Self.edgeCase("boundary-with-hole") {
            let hole = DesignShape(id: Self.id(4), name: "Hole", kind: .circle(radius: 4), position: Self.coinCentre)
            return Self.eachPattern(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, boundaryMargin: 0),
                                    shapes: [Self.coin(), Self.outline(), hole], name: "Boundary with a hole")
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let ring = try Self.regions(p, p.operations[0])
        #expect(ring.count == 1 && ring[0].holes.count == 1)
        for (op, tp) in zip(p.operations, job.toolpaths) {
            #expect(!tp.isEmpty)
            #expect(tp.warnings.isEmpty, "\(op.name): \(tp.warnings)")
            let outside = FinishingPatternsTests.farthestOutside(tp, ring)
            #expect(outside < 0.01, "\(op.name) goes \(outside) mm outside the ring")
            // Cuts all round the ring, near the hole and near the outline.
            var nearHole = Set<Int>(), nearRim = Set<Int>()
            for q in FinishingPatternsTests.cuts(tp) {
                let d = q.xy.distance(to: Self.coinCentre)
                let sector = Int((atan2(q.y - Self.coinCentre.y, q.x - Self.coinCentre.x) + .pi) / (2 * .pi) * 12) % 12
                if d < 6 { nearHole.insert(sector) }
                if d > 13 { nearRim.insert(sector) }
            }
            #expect(nearHole.count == 12 && nearRim.count == 12, "\(op.name): \(nearHole.count) and \(nearRim.count) of 12 sectors")
            let gouge = RestFinishingTests.pathGouge(tp, project: p)
            #expect(gouge < 0.002, "\(op.name) cuts \(gouge) mm into the coin")
        }
        // The spiral comes out of the hole once: a single plunge, ramping in to the hole's edge (from up to a ball
        // radius behind it, along the spiral).
        let plunges = FinishingPatternsTests.plunges(job.toolpaths[1])
        #expect(plunges.count == 1, "\(plunges)")
        let edge = plunges.first.map { abs($0.xy.distance(to: Self.coinCentre) - 4) } ?? .infinity
        #expect(edge < FinishingPatternsTests.ball.radius + 0.1, "\(plunges)")
    }

    /// A round boss with a vertical wall 6 mm tall, finished by constant scallop: the drop-cutter can only put the
    /// tool at the wall's top edge or its foot, so the passes don't pile up there (slopes past 75° count as 75°), and
    /// none cuts into the boss.
    @Test func aModelWithAVerticalWall() throws {
        let p = try Self.edgeCase("vertical-wall") {
            let boss = revolvedMesh([(0, 6), (10, 6)], segments: 96, id: Self.id(5), name: "Boss")
            let shapes = [DesignShape(id: Self.id(6), name: "Boss", kind: .model(ModelSpec(mesh: boss, depth: 6)), position: Self.coinCentre),
                          DesignShape(id: Self.id(7), name: "Outline", kind: .circle(radius: 18), position: Self.coinCentre)]
            let op = CAMOperation(id: Self.id(8), name: "Constant scallop", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.2, boundary: .vectors, boundaryMargin: 0, strategy: .constantScallop)), shapeIDs: shapes.map(\.id),
                                  tool: FinishingPatternsTests.ball)
            return Project(name: "Vertical wall", displayUnits: .mm, stock: Self.stock, machine: .avidPRO6060, shapes: shapes, operations: [op])
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(!tp.warnings.contains { $0.contains("bunch up") }, "\(tp.warnings)")
        let gouge = RestFinishingTests.pathGouge(tp, project: p)
        #expect(gouge < 0.002, "cuts \(gouge) mm into the boss")
        // Passes whose tool centre runs along the wall's foot (a ball radius out from it): at most a few, where without
        // the slope limit every stepover up the wall would land there.
        let R = FinishingPatternsTests.ball.radius
        var footLevels = Set<Int>()
        for q in FinishingPatternsTests.cuts(tp) where abs(q.xy.distance(to: Self.coinCentre) - (10 + R)) < 0.3 && q.z < -5.9 {
            footLevels.insert(Int((q.xy.distance(to: Self.coinCentre) * 50).rounded()))
        }
        #expect(footLevels.count <= 20, "\(footLevels.count) distinct radii at the wall's foot")
        let time = try #require(job.estimatedSeconds(toolpath: tp.id))
        #expect(time > 0)
    }

    /// A spiral whose picked centre is outside the boundary: it's clamped to the nearest point on the boundary, with a
    /// warning saying so and where, and the spiral starts there and stays inside.
    @Test func aSpiralCentreOutsideTheBoundaryIsClamped() throws {
        let p = try Self.edgeCase("spiral-centre-outside") {
            var p = Self.coinProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .spiral, centre: Vec2(55, 30)))
            p.name = "Spiral centre outside the boundary"
            return p
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        let ring = try Self.regions(p, p.operations[0])
        let reach = 15 + Finish3DParams.autoMargin(tool: FinishingPatternsTests.ball)
        let clamped = Self.coinCentre + Vec2(reach, 0)
        let warning = tp.warnings.first { $0.contains("is outside the boundary") }
        #expect(warning?.hasPrefix("The spiral's centre (55.000, 30.000 mm) is outside the boundary, so it starts from the nearest point on it") == true,
                "\(tp.warnings)")
        #expect(job.issues.contains { $0.message == warning && $0.severity == .warning })
        let start = try #require(FinishingPatternsTests.plunges(tp).first)
        #expect(start.xy.distance(to: clamped) < FinishingPatternsTests.ball.radius + 0.1, "starts at \(start), clamped to \(clamped)")
        #expect(FinishingPatternsTests.farthestOutside(tp, ring) < 0.01)
        #expect(RestFinishingTests.pathGouge(tp, project: p) < 0.002)
    }

    /// With `NATIVECAM_PATTERN_PROJECTS=<dir>`, writes the saved project and the demo relief finished by constant
    /// scallop there, for checking the app with `-NativeCAMSnapshotProject`. Off in normal runs.
    @Test func writeProjectsForTheApp() throws {
        guard let dir = ProcessInfo.processInfo.environment["NATIVECAM_PATTERN_PROJECTS"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.savedProject().encoded().write(to: url.appendingPathComponent("finishing-patterns.nativecam"))
        var relief = Project.demoRelief()
        if case var .finish3D(fp) = relief.operations[1].kind {
            fp.strategy = .constantScallop
            fp.scallopHeight = 0.002.inch
            relief.operations[1].kind = .finish3D(fp)
        }
        try relief.encoded().write(to: url.appendingPathComponent("relief-constant-scallop.nativecam"))
    }
}
