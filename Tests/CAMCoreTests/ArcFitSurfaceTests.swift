import Foundation
import Testing
@testable import CAMCore

/// Arc fitting on 3D finishing (#125): an arc within the fitting tolerance of a pass's points can still dip under the
/// drop-cutter surface between them, so 3D finishing keeps only the arcs (and merged straight moves) that stay on or
/// above it.
struct ArcFitSurfaceTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "A2C0F170-0000-4000-8000-%012d", n))! }

    /// What a 3D finishing toolpath posts like with and without the surface check.
    struct Fitted {
        /// Arcs on, checked against the surface (as generated).
        var checked: Toolpath
        /// The same points fitted without the check (before #125).
        var unchecked: Toolpath
        /// No arcs at all.
        var straight: Toolpath
    }

    /// The finishing toolpath `opID` of `p`, generated on its own with arcs on, and refitted without the check.
    static func fitted(_ p: Project, _ opID: UUID) throws -> Fitted {
        let checked = try #require(CAMEngine.generate(p, operationIDs: [opID]).toolpaths.first { $0.id == opID })
        var flat = p
        flat.machine.outputArcs = false
        let straight = try #require(CAMEngine.generate(flat, operationIDs: [opID]).toolpaths.first { $0.id == opID })
        let unchecked = ArcFitter.fit(straight, tolerance: p.machine.arcFitTolerance)
        return Fitted(checked: checked, unchecked: unchecked, straight: straight)
    }

    static func arcs(_ tp: Toolpath) -> Int { tp.motions.count { $0.kind.isArc } }

    /// The demo relief's finish with `strategy` instead of its raster.
    static func relief(_ strategy: Finish3DStrategy) throws -> (Project, UUID) {
        var p = Project.demoRelief()
        let k = try #require(p.operations.firstIndex { if case .finish3D = $0.kind { true } else { false } })
        guard case var .finish3D(fp) = p.operations[k].kind else { throw CancellationError() }
        fp.strategy = strategy
        p.operations[k].kind = .finish3D(fp)
        return (p, p.operations[k].id)
    }

    /// The cases #125 measured: waterline on the golden dome (20% stepover), pencil and waterline on the demo relief.
    static func measuredCase(_ name: String) throws -> (Project, UUID) {
        switch name {
        case "dome waterline":
            let p = Finish3DStrategyTests.goldenProject(Finish3DParams(stepoverFraction: 0.2, boundary: .vectors, strategy: .waterline),
                                                        shapes: Finish3DStrategyTests.goldenShapes("dome"), tool: Finish3DStrategyTests.ball)
            return (p, p.operations[0].id)
        case "relief pencil": return try relief(.pencil)
        default: return try relief(.waterline)
        }
    }

    @Test(arguments: ["dome waterline", "relief pencil", "relief waterline"])
    func finishingArcsStayOnTheSurface(_ name: String) throws {
        let (p, opID) = try Self.measuredCase(name)
        let f = try Self.fitted(p, opID)
        let gouge = RestFinishingTests.pathGouge(f.checked, project: p)
        let before = RestFinishingTests.pathGouge(f.unchecked, project: p)
        let posted = { (tp: Toolpath) in String(decoding: GoldenPostTests.post(p, [tp]), as: UTF8.self).split(whereSeparator: \.isNewline).count }
        let lines = (checked: posted(f.checked), unchecked: posted(f.unchecked), straight: posted(f.straight))
        // What the check costs: fitting the same points with and without it.
        let clock = ContinuousClock()
        let tol = p.machine.arcFitTolerance
        let plain = clock.measure { _ = ArcFitter.fit(f.straight, tolerance: tol) }
        let op = try #require(p.operations.first { $0.id == opID })
        let withCheck = clock.measure { _ = ArcFitter.fit(f.straight, for: op, project: p) }
        let generation = clock.measure { _ = CAMEngine.generate(p, operationIDs: [opID]) }
        print("#125 \(name): gouge \(gouge) (unchecked \(before)); lines \(lines.checked) (unchecked \(lines.unchecked), "
            + "straight \(lines.straight)); arcs \(Self.arcs(f.checked)) (unchecked \(Self.arcs(f.unchecked))); "
            + "fit \(withCheck) (unchecked \(plain)); whole toolpath \(generation)")
        #expect(gouge <= 0.001, "\(name): \(gouge) mm below the surface")
        // The case dips without the check (or it tests nothing).
        #expect(before > 0.005, "\(name): \(before)")
        // Arcs are still used where they're safe, so the file stays smaller than straight moves. (On a faceted mesh the
        // contour has a corner at every facet edge, and an arc that cut across them was the dip, so it is larger than
        // before.)
        #expect(Self.arcs(f.checked) > 0)
        #expect(Double(lines.checked) < 0.95 * Double(lines.straight), "\(lines)")
    }

    /// 2D toolpaths and 3D roughing don't get a surface: they fit exactly as before.
    @Test func onlyFinishingGetsASurface() throws {
        let p = Project.demoRelief()
        for op in p.operations {
            let has = ArcFitter.surface(for: op, tool: op.tool, project: p) != nil
            if case .finish3D = op.kind {
                #expect(has, "\(op.name)")
            } else {
                #expect(!has, "\(op.name)")
            }
        }
    }

    // MARK: Saved fixture

    /// A small dome finished by waterline at a 20% stepover, where fitting without the check dips about 0.03 mm.
    static func savedProject() -> Project {
        var mesh = hemisphereMesh(radius: 12, rings: 16, segments: 32)
        mesh.id = id(1)
        let centre = Vec2(25, 25)
        let dome = DesignShape(id: id(2), name: "Dome", kind: .model(ModelSpec(mesh: mesh, depth: 12)), position: centre)
        let outline = DesignShape(id: id(3), name: "Outline", kind: .circle(radius: 17), position: centre)
        let op = CAMOperation(id: id(4), name: "Waterline dome",
                              kind: .finish3D(Finish3DParams(stepoverFraction: 0.2, boundary: .vectors, strategy: .waterline)),
                              shapeIDs: [dome.id, outline.id], tool: Finish3DStrategyTests.ball)
        let stock = Stock(width: 50, height: 50, thickness: 20, clearanceHeight: 10, plungeHeight: 2)
        return Project(name: "Arc fitting on a dome", displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: [dome, outline],
                       operations: [op], notes: "Saved to pin arc fitting on 3D finishing to the drop-cutter surface (#125).")
    }

    @Test func savedDomeDecodesAndPostsArcsOnTheSurface() throws {
        let p = try GoldenPostTests.savedProject("arcfit-dome-v10", make: Self.savedProject)
        #expect(p == Self.savedProject())
        let f = try Self.fitted(p, Self.id(4))
        #expect(RestFinishingTests.pathGouge(f.checked, project: p) <= 0.001)
        #expect(RestFinishingTests.pathGouge(f.unchecked, project: p) > 0.005)
        #expect(Self.arcs(f.checked) > 0)
        try Finish3DStrategyTests.checkGolden(p, "decoded-arcfit-dome")
    }
}
