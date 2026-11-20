import Foundation
import Testing
@testable import CAMCore

/// V-carve start depth and inlays: a pocket (female) and a mirrored plug (male) that seats in it with a glue gap.
struct InlayTests {
    static let lib = ToolLibrary.starter
    static var vBit60: Tool { lib.tool(number: 5)! }
    static var vBit90: Tool { lib.tool(number: 6)! }
    static var eighth: Tool { lib.tool(number: 2)! }

    static func carve(_ params: VCarveParams, shapes: [DesignShape], tool: Tool = vBit90) -> [Toolpath] {
        let op = CAMOperation(kind: .vcarve(params), shapeIDs: shapes.map(\.id), tool: tool)
        return CAMEngine.generate(Fixture.project(shapes: shapes, ops: [op])).toolpaths
    }

    /// Distance from `p` to the nearest edge of an axis-aligned rectangle (positive inside).
    static func inside(_ p: Vec2, rect c: Vec2, _ w: Double, _ h: Double) -> Double {
        min(w / 2 - abs(p.x - c.x), h / 2 - abs(p.y - c.y))
    }

    // MARK: Start depth

    @Test func startDepthCarvesAsIfTheTopWereLower() throws {
        // A 30 × 8 rectangle's inscribed radius is 4: with a 60° bit the tip goes 4 / tan 30° below the start depth.
        let shape = Fixture.rect(30, 8, at: Vec2(100, 75))
        let tps = Self.carve(VCarveParams(sampleSpacing: 0.2, startDepth: 2), shapes: [shape], tool: Self.vBit60)
        let tp = try #require(tps.first)
        let expected = 2 + 4 / Self.vBit60.halfAngleTangent
        #expect(abs(try #require(tp.cuttingExtents).min.z + expected) < 0.05)
        // The tip never cuts above the start depth: every feed move below the surface ends at or below it.
        let shallow = tp.motions.filter { $0.kind == .feed && $0.end.z < 0 && $0.end.z > -2 + 1e-6 }
        #expect(shallow.isEmpty, "\(shallow.count) feed moves above the start depth")
    }

    @Test func startDepthWallsCarryOnAboveIt() throws {
        // 90° bit, start depth 2: inside, depth = 2 + distance to the edge; above the start depth the cone cuts on,
        // up to 2 mm past the outline at the surface, and nothing further out.
        let c = Vec2(100, 75)
        let shape = Fixture.rect(30, 6, at: c)
        let project = Fixture.project(shapes: [shape], ops: [])
        let grid = Fixture.simulate(Self.carve(VCarveParams(sampleSpacing: 0.2, startDepth: 2), shapes: [shape]), stock: project.stock, cell: 0.1)
        var worst = 0.0
        for p in [Vec2(100, 75), Vec2(92, 74), Vec2(110, 76.5), Vec2(88, 75), Vec2(100, 73.5)] {
            let h = Double(try #require(grid.height(at: p)))
            worst = max(worst, abs(h + 2 + Self.inside(p, rect: c, 30, 6)))
        }
        #expect(worst < 0.2, "inside: max depth error \(worst) mm")
        // 1 mm outside the long edge the cone has cut 1 mm deep; 2.6 mm out, nothing.
        let out1 = Double(try #require(grid.height(at: Vec2(100, 75 + 4))))
        #expect(abs(out1 + 1) < 0.2, "\(out1)")
        #expect(try #require(grid.height(at: Vec2(100, 75 + 5.6))) == 0)
    }

    @Test func flatDepthAndPassesCountFromTheStartDepth() throws {
        let shape = Fixture.rect(40, 30, at: Vec2(100, 75))
        let tps = Self.carve(VCarveParams(flatDepth: 3, passDepth: 1, startDepth: 2), shapes: [shape])
        let tp = try #require(tps.last)
        #expect(abs(try #require(tp.cuttingExtents).min.z + 5) < 1e-6)
        // Passes limited at 3 and 4 mm (1 and 2 below the start depth), then the full 5.
        for z in [-3.0, -4.0, -5.0] { #expect(Fixture.pointsAt(z: z, tp).count > 4, "pass at \(z)") }
        #expect(Fixture.pointsAt(z: -1, tp).isEmpty && Fixture.pointsAt(z: -2.5, tp).isEmpty)
    }

    @Test func clearanceToolClearsTheFlatBelowTheStartDepthAndStaysOffTheWalls() throws {
        let c = Vec2(100, 75)
        let shape = Fixture.rect(40, 30, at: c)
        var mill = Fixture.endMill
        mill.cutting.stepdown = 1
        let tps = Self.carve(VCarveParams(flatDepth: 3, clearanceTool: mill, startDepth: 2), shapes: [shape])
        #expect(tps.count == 2)
        let clear = tps[0]
        #expect(clear.tool.number == mill.number)
        #expect(abs(try #require(clear.cuttingExtents).min.z + 5) < 1e-6)
        // The end mill's edge stays at least rCap (where the 90° V reaches the flat, 3 mm) inside the outline, so it
        // never cuts where the V-bit's walls go, above the start depth or below it.
        let r = mill.radius
        for m in clear.motions where m.kind == .feed && m.end.z < 0 {
            #expect(Self.inside(m.end.xy, rect: c, 40, 30) >= 3 + r - 0.01)
        }
        // In solid material its passes start from the top.
        #expect(clear.motions.contains { $0.kind == .feed && $0.end.z < 0 && $0.end.z > -2 })
    }

    @Test func clearingInsideAnEarlierPocketSkipsWhatItCleared() throws {
        // A 3 mm deep pocket, then a flat-bottomed V-carve inside it from a 3 mm start depth.
        let c = Vec2(100, 75)
        let pocketShape = Fixture.rect(80, 60, at: c), carveShape = Fixture.rect(40, 30, at: c)
        var mill = Fixture.endMill
        mill.cutting.stepdown = 1
        let pocket = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [pocketShape.id], tool: mill)
        let carve = CAMOperation(kind: .vcarve(VCarveParams(flatDepth: 2.5, clearanceTool: mill, startDepth: 3)),
                                 shapeIDs: [carveShape.id], tool: Self.vBit90)
        let tps = CAMEngine.generate(Fixture.project(shapes: [pocketShape, carveShape], ops: [pocket, carve])).toolpaths
        let clear = try #require(tps.first { $0.name.contains("flat clearing") })
        let cutting = clear.motions.filter { $0.kind == .feed && $0.end.z < 0 }
        #expect(!cutting.isEmpty)
        #expect(cutting.allSatisfy { $0.end.z <= -3 + 1e-6 }, "the clearing cut air above the pocket floor")
        #expect(abs((cutting.map(\.end.z).min() ?? 0) + 5.5) < 1e-6)
        // Without the pocket it starts at the top.
        let solid = CAMEngine.generate(Fixture.project(shapes: [carveShape], ops: [carve])).toolpaths
        let fromTop = try #require(solid.first { $0.name.contains("flat clearing") })
        #expect(fromTop.motions.contains { $0.kind == .feed && $0.end.z < 0 && $0.end.z > -3 })
    }

    @Test func vBitClearsTheFlatWithoutAClearanceTool() throws {
        let c = Vec2(100, 75)
        let shape = Fixture.rect(40, 30, at: c)
        let project = Fixture.project(shapes: [shape], ops: [])
        let tps = Self.carve(VCarveParams(flatDepth: 3), shapes: [shape])
        #expect(tps.count == 1)
        let grid = Fixture.simulate(tps, stock: project.stock, cell: 0.1)
        // The whole floor is down at the flat depth, give or take the ridges between the V-bit's passes.
        var highest = -Double.infinity
        for x in stride(from: 85.0, through: 115.0, by: 0.7) {
            for y in stride(from: 63.0, through: 87.0, by: 0.7) {
                highest = max(highest, Double(try #require(grid.height(at: Vec2(x, y)))))
            }
        }
        #expect(highest < -3 + 2 * VCarveGenerator.flatClearingRidge + 0.1, "floor reaches \(highest)")
        #expect(highest > -3.01)
    }

    // MARK: Plug layout

    @Test func plugCarvesAroundTheDesignInsideAMargin() throws {
        let design = Fixture.rect(20, 10, at: Vec2(50, 50))
        let regions = VCarveGenerator.plugRegions(shapes: [design], margin: 5, tolerance: 0.01, arcTolerance: 0.005)
        #expect(regions.count == 1)
        let r = try #require(regions.first)
        #expect(r.holes.count == 1)
        #expect(abs(r.bounds.min.x - 35) < 0.01 && abs(r.bounds.max.x - 65) < 0.01)
        #expect(abs(r.bounds.min.y - 40) < 0.01 && abs(r.bounds.max.y - 60) < 0.01)
        #expect(r.contains(Vec2(37, 50)) && r.contains(Vec2(50, 57)))
        #expect(!r.contains(Vec2(50, 50)) && !r.contains(Vec2(33, 50)))
    }

    @Test func plugCarvesInsideTheSelectedVectorWhenAskedTo() throws {
        // The boundary is off-centre; it's mirrored with the design about the design's centre (x = 50).
        let design = Fixture.rect(20, 10, at: Vec2(50, 50))
        let board = Fixture.rect(60, 40, at: Vec2(60, 50))
        let regions = VCarveGenerator.plugRegions(shapes: [design, board], margin: 5, tolerance: 0.01, arcTolerance: 0.005, useVector: true)
        let r = try #require(regions.first)
        #expect(regions.count == 1 && r.holes.count == 1)
        #expect(abs(r.bounds.min.x - 10) < 0.01 && abs(r.bounds.max.x - 70) < 0.01)
        // With a margin boundary, a shape round the rest is part of the design (a frame): the frame (x 30–90, now the
        // design's bounds) grows by the margin, and the band between frame and rectangle stands proud with them.
        let framed = VCarveGenerator.plugRegions(shapes: [design, board], margin: 5, tolerance: 0.01, arcTolerance: 0.005)
        #expect(framed.count == 2)
        #expect(framed.contains { abs($0.bounds.min.x - 25) < 0.01 && abs($0.bounds.max.x - 95) < 0.01 })
        #expect(!framed.contains { $0.contains(Vec2(35, 50)) } && framed.contains { $0.contains(Vec2(70, 50)) })
        // The project helper agrees, and the toolpath warns when no selected vector goes round the rest.
        var inlay = VCarveInlay(role: .plug, boundary: .vector)
        let plug = CAMOperation(kind: .vcarve(VCarveParams(inlay: inlay)), shapeIDs: [design.id, board.id], tool: Self.vBit60)
        #expect(Fixture.project(shapes: [design, board], ops: [plug]).plugBoundary(for: plug)?.id == board.id)
        let alone = CAMOperation(kind: .vcarve(VCarveParams(inlay: inlay)), shapeIDs: [design.id], tool: Self.vBit60)
        let job = CAMEngine.generate(Fixture.project(shapes: [design, board], ops: [alone]))
        #expect(job.issues.contains { $0.message.contains("None of the selected vectors goes round the rest") })
        inlay.boundary = .margin
        let margin = CAMOperation(kind: .vcarve(VCarveParams(inlay: inlay)), shapeIDs: [design.id, board.id], tool: Self.vBit60)
        #expect(Fixture.project(shapes: [design, board], ops: [margin]).plugBoundary(for: margin) == nil)
    }

    @Test func aShapeInsideAnotherStaysPartOfTheDesign() {
        // A copy of the L-with-a-hole design, on its own for the plug: the L isn't mistaken for a boundary.
        let l = Self.lShape(at: Vec2(160, 50)), hole = DesignShape(kind: .circle(radius: 3), position: Vec2(168, 42))
        let plug = CAMOperation(kind: .vcarve(VCarveParams(inlay: VCarveInlay(role: .plug))), shapeIDs: [l.id, hole.id], tool: Self.vBit60)
        let project = Fixture.project(shapes: [l, hole], ops: [plug], stock: Stock(width: 250, height: 100, thickness: 19))
        #expect(project.plugBoundary(for: plug) == nil)
        let regions = VCarveGenerator.plugRegions(shapes: [l, hole], margin: 6, tolerance: 0.01, arcTolerance: 0.005)
        func carved(_ p: Vec2) -> Bool { regions.contains { $0.contains(p) } }
        // Mirrored about x = 160: the hole is at x 152, the foot runs the whole width, the stem is on the right.
        #expect(carved(Vec2(152, 42)) && !carved(Vec2(168, 42)) && !carved(Vec2(160, 40)))
        #expect(!carved(Vec2(177, 60)) && carved(Vec2(143, 52)))
    }

    @Test func plugCarvesTheMiddleOfAnO() throws {
        let outer = DesignShape(kind: .circle(radius: 10), position: Vec2(50, 50))
        let inner = DesignShape(kind: .circle(radius: 5), position: Vec2(50, 50))
        let regions = VCarveGenerator.plugRegions(shapes: [outer, inner], margin: 4, tolerance: 0.01, arcTolerance: 0.005)
        func carved(_ p: Vec2) -> Bool { regions.contains { $0.contains(p) } }
        #expect(carved(Vec2(50, 50)), "the counter fits over the pocket's island")
        #expect(!carved(Vec2(57.5, 50)), "the ring stands proud")
        #expect(carved(Vec2(62, 50)) && !carved(Vec2(65, 50)))
    }

    /// The plug carves exactly where the mirrored design isn't (with a margin wider than the design, so everywhere
    /// in its bounds), sampled away from the edges.
    static func expectMirrored(_ design: [DesignShape], sourceLocation: SourceLocation = #_sourceLocation) {
        let loops = design.flatMap { $0.polylines(tolerance: 0.01) }.filter(\.isClosed)
        let drawn = Region.build(from: loops, fill: .evenOdd)
        let center = loops.bounds.center
        let plug = VCarveGenerator.plugRegions(shapes: design, margin: 60, tolerance: 0.01, arcTolerance: 0.005)
        let edges = loops.map { $0.transformed(Transform2D.translation(-center).then(.scale(-1, 1)).then(.translation(center))) }
        var checked = 0, wrong = 0, differs = 0
        let b = loops.bounds
        for x in stride(from: b.min.x + 0.13, to: b.max.x, by: 0.37) {
            for y in stride(from: b.min.y + 0.11, to: b.max.y, by: 0.41) {
                let p = Vec2(x, y)
                guard !edges.contains(where: { $0.closestPoint(to: p).distance < 0.05 }),
                      !loops.contains(where: { $0.closestPoint(to: p).distance < 0.05 }) else { continue }
                let mirror = Vec2(2 * center.x - x, y)
                let inDesign = drawn.contains { $0.contains(mirror) }
                let carved = plug.contains { $0.contains(p) }
                checked += 1
                if carved == inDesign { wrong += 1 }
                if inDesign != drawn.contains(where: { $0.contains(p) }) { differs += 1 }
            }
        }
        #expect(checked > 100 && wrong == 0, "\(wrong) of \(checked) samples not mirrored", sourceLocation: sourceLocation)
        // The design isn't symmetric, so mirroring matters.
        #expect(differs > 10, sourceLocation: sourceLocation)
    }

    @Test func plugMirrorsPaths() {
        Self.expectMirrored([Self.lShape(at: Vec2(60, 50))])
    }

    @Test func plugMirrorsText() {
        Self.expectMirrored([DesignShape(kind: .text(TextSpec(string: "Fg", fontName: "Helvetica-Bold", capHeight: 20)), position: Vec2(60, 50))])
    }

    @Test func plugDepthsComeFromPocketDepthGlueGapAndClearance() throws {
        let c = Vec2(100, 75)
        let design = Fixture.rect(20, 14, at: c)
        let inlay = VCarveInlay(role: .plug, pocketDepth: 5, glueGap: 0.5, surfaceClearance: 1.5, boundaryMargin: 6)
        let tps = Self.carve(VCarveParams(sampleSpacing: 0.2, inlay: inlay), shapes: [design], tool: Self.vBit60)
        let tp = try #require(tps.last)
        // Carved from S = 5 − 0.5 down to S + C.
        #expect(abs(try #require(tp.cuttingExtents).min.z + 6) < 1e-6)
        // The plug's wall crosses the outline at the start depth and leans in at the bit's angle above it; outside, the
        // band goes down at the same angle to the floor at S + C.
        let grid = Fixture.simulate(tps, stock: Fixture.stock, cell: 0.1)
        let t = Self.vBit60.halfAngleTangent
        for d in [0.05, -0.95, -1.95, 0.55, 2.95] {
            // d mm outside the long top edge (a cell centre), along the middle of the design.
            let expected = min(6, 4.5 + d / t)
            let h = Double(try #require(grid.height(at: Vec2(100.05, 82 + d))))
            #expect(abs(-h - expected) < 0.12, "at \(d) mm: \(-h) deep, expected \(expected)")
        }
        #expect(try #require(grid.height(at: c)) == 0, "the design's middle stands at full height")
        // Settings: S = P − G, total S + C.
        #expect(abs(inlay.plugStartDepth - 4.5) < 1e-12 && abs(inlay.plugCutDepth - 6) < 1e-12)
        #expect(VCarveParams(startDepth: 3, inlay: inlay).carveStartDepth == 4.5)
    }

    // MARK: Nesting

    /// An L (a narrow stem the V never flattens and a wide foot with a flat) with a round hole in the foot, so the
    /// pocket has an island; not symmetric, so the plug must be mirrored to fit.
    static func lShape(at c: Vec2) -> DesignShape {
        DesignShape(name: "L", kind: .paths([Polyline([Vec2(-20, -15), Vec2(20, -15), Vec2(20, -1), Vec2(-14, -1), Vec2(-14, 15),
                                                       Vec2(-20, 15)], closed: true)]), position: c)
    }

    static func inlayPair(glueGap: Double = 0.5, clearance: Tool? = eighth) -> (Project, CAMOperation, CAMOperation) {
        let l = lShape(at: Vec2(60, 50))
        let hole = DesignShape(name: "Hole", kind: .circle(radius: 3), position: Vec2(68, 42))
        let pocket = CAMOperation(name: "Pocket", kind: .vcarve(VCarveParams(flatDepth: 0.2.inch, sampleSpacing: 0.1, clearanceTool: clearance,
                                                                             inlay: VCarveInlay(role: .pocket))),
                                  shapeIDs: [l.id, hole.id], tool: vBit60)
        let plug = CAMOperation(name: "Plug", kind: .vcarve(VCarveParams(sampleSpacing: 0.1, clearanceTool: clearance, inlay: VCarveInlay(
            role: .plug, pocketDepth: 0.2.inch, glueGap: glueGap, surfaceClearance: 1.6, boundaryMargin: 6))),
                                shapeIDs: [l.id, hole.id], tool: vBit60)
        let stock = Stock(width: 120, height: 100, thickness: 19, clearanceHeight: 10, plungeHeight: 2)
        return (Fixture.project(shapes: [l, hole], ops: [pocket, plug], stock: stock), pocket, plug)
    }

    /// Simulates both sides on their own boards, flips the plug over into the pocket and measures the gap between
    /// them at each cell of the pocket board with the plug's start plane level with the pocket board's top. Only the
    /// plug itself counts: the design and the band carved round it (the rest of its board is sawn off).
    static func nestingGaps(_ project: Project, pocket: CAMOperation, plug: CAMOperation, mirrorPlug: Bool = true)
        -> (gaps: [(p: Vec2, gap: Double, pocketZ: Double, plugZ: Double)], start: Double) {
        let tps = CAMEngine.generate(project).toolpaths
        let pocketIDs: Set<UUID> = [pocket.id, VCarveGenerator.deterministicID(pocket.id, salt: 1)]
        let plugIDs: Set<UUID> = [plug.id, VCarveGenerator.deterministicID(plug.id, salt: 1)]
        let female = Fixture.simulate(tps.filter { pocketIDs.contains($0.id) }, stock: project.stock, cell: 0.1)
        let male = Fixture.simulate(tps.filter { plugIDs.contains($0.id) }, stock: project.stock, cell: 0.1)
        guard case let .vcarve(params) = plug.kind, let inlay = params.inlay else { return ([], 0) }
        let shapes = project.shapes(for: plug)
        let band = VCarveGenerator.plugRegions(shapes: shapes, margin: inlay.boundaryMargin, tolerance: 0.01, arcTolerance: 0.005)
        let design = Region.build(from: shapes.flatMap { $0.polylines(tolerance: 0.01) }, fill: .evenOdd)
        let s = inlay.plugStartDepth
        let cx = 60.0 // the design's centre, on a cell boundary so mirrored cells line up exactly
        var out: [(Vec2, Double, Double, Double)] = []
        for x in stride(from: 30.05, to: 90, by: 0.1) {
            for y in stride(from: 25.05, to: 75, by: 0.1) {
                let p = Vec2(x, y), q = Vec2(mirrorPlug ? 2 * cx - x : x, y)
                guard band.contains(where: { $0.contains(Vec2(2 * cx - x, y)) }) || design.contains(where: { $0.contains(p) }),
                      let hp = female.height(at: p), let hq = male.height(at: q) else { continue }
                // Flipped, the plug's material at depth d below its top sits d − S below the pocket board's top.
                out.append((p, -Double(hq) - s - Double(hp), Double(hp), Double(hq)))
            }
        }
        return (out, s)
    }

    @Test func plugNestsInItsPocket() throws {
        let (project, pocket, plug) = Self.inlayPair()
        let (gaps, s) = Self.nestingGaps(project, pocket: pocket, plug: plug)
        #expect(gaps.count > 100_000)
        let p = 0.2.inch, g = 0.5
        // Never negative: nothing on the plug runs into the pocket board (the cells are 0.1 mm, the walls 60° steep).
        let tightest = try #require(gaps.min { $0.gap < $1.gap })
        #expect(tightest.gap > -0.12, "plug runs \(-tightest.gap) mm into the pocket at \(tightest.p)")
        // The walls meet: where the pocket's wall is (between its top and its floor, and above the plug's face) the
        // two are in contact, within the grid's resolution.
        let walls = gaps.filter { $0.pocketZ < -0.2 && $0.pocketZ > -s + 0.2 }
        #expect(walls.count > 2000)
        let loose = walls.filter { abs($0.gap) > 0.12 }
        #expect(Double(loose.count) < 0.01 * Double(walls.count), "\(loose.count) of \(walls.count) wall cells off by more than 0.12 mm")
        // Under the plug's face, the pocket's flat floor is the glue gap away.
        let floor = gaps.filter { abs($0.pocketZ + p) < 0.02 && abs($0.plugZ) < 1e-6 }
        #expect(floor.count > 2000)
        let meanFloor = floor.map(\.gap).reduce(0, +) / Double(floor.count)
        #expect(abs(meanFloor - g) < 0.03, "mean floor gap \(meanFloor)")
        #expect(floor.allSatisfy { $0.gap > g - 0.12 && $0.gap < g + 0.05 })
        // Nowhere does the plug stand off further than the glue gap plus the V-bit's clearing ridges, so it's held
        // all round by its walls (the pocket board's top surface, outside the design, is clear of the plug's floor).
        #expect(gaps.allSatisfy { $0.pocketZ > -1e-6 ? $0.gap > -0.12 : $0.gap < g + 2 * VCarveGenerator.inlayPocketRidge + 0.1 })
        // Without mirroring, the plug wouldn't go in.
        let unmirrored = Self.nestingGaps(project, pocket: pocket, plug: plug, mirrorPlug: false).gaps
        #expect((unmirrored.map(\.gap).min() ?? 0) < -2)
    }

    @Test func plugNestsWithTheVBitClearingAlone() throws {
        let (project, pocket, plug) = Self.inlayPair(clearance: nil)
        let (gaps, _) = Self.nestingGaps(project, pocket: pocket, plug: plug)
        let tightest = try #require(gaps.min { $0.gap < $1.gap })
        #expect(tightest.gap > -0.12, "plug runs \(-tightest.gap) mm into the pocket at \(tightest.p)")
        let floor = gaps.filter { abs($0.pocketZ + 0.2.inch) < 0.02 && abs($0.plugZ) < 1e-6 }
        #expect(floor.count > 1000)
        #expect(abs(floor.map(\.gap).reduce(0, +) / Double(floor.count) - 0.5) < 0.05)
    }

    // MARK: Fit check

    static func fitIssues(_ project: Project) -> [String] {
        CAMEngine.inlayIssues(project, toolpaths: CAMEngine.generate(project).toolpaths).map(\.message)
    }

    static func pairOnTwoBoards(_ configure: (inout CAMOperation, inout CAMOperation) -> Void = { _, _ in }) -> Project {
        var (project, pocket, plug) = inlayPair()
        configure(&pocket, &plug)
        // Exported one side at a time.
        plug.enabled = false
        project.operations = [pocket, plug]
        return project
    }

    static func setPlug(_ op: inout CAMOperation, _ change: (inout VCarveInlay) -> Void) {
        guard case var .vcarve(p) = op.kind, var inlay = p.inlay else { return }
        change(&inlay)
        p.inlay = inlay
        op.kind = .vcarve(p)
    }

    @Test func aMatchingPairSeatsCleanly() {
        #expect(Self.fitIssues(Self.pairOnTwoBoards()).isEmpty, "\(Self.fitIssues(Self.pairOnTwoBoards()))")
    }

    @Test func differentBitsDontFit() {
        let issues = Self.fitIssues(Self.pairOnTwoBoards { _, plug in plug.tool = Self.vBit90 })
        #expect(issues.contains { $0.contains("same V-bit") && $0.contains("90°") && $0.contains("60°") }, "\(issues)")
        // A different tip is just as bad.
        var tipped = Self.vBit60
        tipped.tipDiameter = 0.01.inch
        let tips = Self.fitIssues(Self.pairOnTwoBoards { _, plug in plug.tool = tipped })
        #expect(tips.contains { $0.contains("same V-bit") } && tips.contains { $0.contains("flat tip") }, "\(tips)")
    }

    @Test func pocketDepthMustMatchThePocketsFlatDepth() {
        // Deeper than the pocket by more than the glue gap: the plug bottoms out.
        let deep = Self.fitIssues(Self.pairOnTwoBoards { _, plug in Self.setPlug(&plug) { $0.pocketDepth = 0.25.inch } })
        #expect(deep.contains { $0.contains("bottoms out before its walls meet") && $0.contains("Set Pocket depth to 5.080 mm") }, "\(deep)")
        // Shallower: it seats, but with a bigger gap than asked for.
        let shallow = Self.fitIssues(Self.pairOnTwoBoards { _, plug in Self.setPlug(&plug) { $0.pocketDepth = 0.15.inch } })
        #expect(shallow.contains { $0.contains("instead of the") }, "\(shallow)")
        // A pocket with no flat depth can't be matched.
        let noFlat = Self.fitIssues(Self.pairOnTwoBoards { pocket, _ in
            guard case var .vcarve(p) = pocket.kind else { return }
            p.flatDepth = nil
            pocket.kind = .vcarve(p)
        })
        #expect(noFlat.contains { $0.contains("has no flat depth") }, "\(noFlat)")
    }

    @Test func gapsMustLeaveRoom() {
        let noGap = Self.fitIssues(Self.pairOnTwoBoards { _, plug in Self.setPlug(&plug) { $0.glueGap = 0 } })
        #expect(noGap.contains { $0.contains("No glue gap") }, "\(noGap)")
        let tiny = Self.fitIssues(Self.pairOnTwoBoards { _, plug in Self.setPlug(&plug) { $0.glueGap = 0.05 } })
        #expect(tiny.contains { $0.contains("ridges") }, "\(tiny)")
        let noClearance = Self.fitIssues(Self.pairOnTwoBoards { _, plug in Self.setPlug(&plug) { $0.surfaceClearance = 0 } })
        #expect(noClearance.contains { $0.contains("No surface clearance") }, "\(noClearance)")
        let tooDeep = Self.fitIssues(Self.pairOnTwoBoards { _, plug in plug.tool = Self.vBit90; Self.setPlug(&plug) { $0.surfaceClearance = 3 } })
        #expect(tooDeep.contains { $0.contains("V is only") }, "\(tooDeep)")
    }

    @Test func bothSidesInOneFileWarn() {
        let (project, _, _) = Self.inlayPair()
        let issues = Self.fitIssues(project)
        #expect(issues.contains { $0.contains("separate board") }, "\(issues)")
        // And Checks shows it.
        #expect(CAMEngine.generate(project).issues.contains { $0.operation == "Plug" && $0.message.contains("separate board") })
    }

    // MARK: File format

    func json(_ value: some Encodable) throws -> [String: Any] {
        let e = JSONEncoder()
        return try #require(JSONSerialization.jsonObject(with: e.encode(value)) as? [String: Any])
    }

    @Test func ordinaryVCarvesSaveAsBefore() throws {
        let j = try json(VCarveParams(flatDepth: 2, clearanceTool: Self.eighth))
        #expect(j["startDepth"] == nil && j["inlay"] == nil)
        #expect(Set(j.keys) == ["flatDepth", "sampleSpacing", "clearanceTool"])
        // Files written before decode with no start depth and no inlay.
        let old = try #require(#"{"sampleSpacing": 0.25, "flatDepth": 3}"#.data(using: .utf8))
        let p = try JSONDecoder().decode(VCarveParams.self, from: old)
        #expect(p == VCarveParams(flatDepth: 3))
        #expect(p.startDepth == 0 && p.inlay == nil && p.requiredFormatVersion == 1)
        #expect(Project.demoSign().formatVersion == 1)
    }

    @Test func startDepthAndPlugsAreFormatSix() throws {
        var (project, pocket, plug) = Self.inlayPair()
        // A pocket alone cuts the same in an older build: it's an ordinary V-carve.
        project.operations = [pocket]
        #expect(project.formatVersion == 1)
        project.operations = [pocket, plug]
        #expect(project.formatVersion == 6)
        #expect(try Project.decode(project.encoded()) == project)
        project.operations = [CAMOperation(kind: .vcarve(VCarveParams(startDepth: 1)), shapeIDs: pocket.shapeIDs, tool: Self.vBit60)]
        #expect(project.formatVersion == 6)
        let back = try Project.decode(project.encoded())
        #expect(back == project)
        guard case let .vcarve(p) = back.operations[0].kind else { Issue.record("not a V-carve"); return }
        #expect(p.startDepth == 1)
        // Round-trips every inlay field.
        let inlay = VCarveInlay(role: .plug, pocketDepth: 4, glueGap: 0.3, surfaceClearance: 2, boundaryMargin: 9)
        let j = try json(VCarveParams(inlay: inlay))
        let saved = try #require(j["inlay"] as? [String: Any])
        #expect(saved["role"] as? String == "plug" && saved["pocketDepth"] as? Double == 4 && saved["glueGap"] as? Double == 0.3
            && saved["surfaceClearance"] as? Double == 2 && saved["boundaryMargin"] as? Double == 9)
        #expect(try JSONDecoder().decode(VCarveParams.self, from: JSONEncoder().encode(VCarveParams(inlay: inlay))).inlay == inlay)
    }

    /// A project as format 6 first saved it: an inlay pocket (turned off) and its plug, on the default PRO6060 with
    /// Mach4. It must keep loading and posting the same bytes: the plug's G-code.
    static func savedInlay() -> Project {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "1A1A0000-0000-0000-0000-%012d", n))! }
        var l = lShape(at: Vec2(3.inch, 2.5.inch))
        l.id = id(1)
        let hole = DesignShape(id: id(2), name: "Hole", kind: .circle(radius: 3), position: Vec2(3.inch + 8, 2.5.inch - 8))
        var pocket = CAMOperation(id: id(11), name: "Inlay pocket", kind: .vcarve(VCarveParams(
            flatDepth: 0.2.inch, clearanceTool: eighth, inlay: VCarveInlay(role: .pocket))), shapeIDs: [l.id, hole.id], tool: vBit60)
        pocket.enabled = false
        let plug = CAMOperation(id: id(12), name: "Inlay plug", kind: .vcarve(VCarveParams(
            clearanceTool: eighth, inlay: VCarveInlay(role: .plug, pocketDepth: 0.2.inch, glueGap: 0.02.inch, surfaceClearance: 0.0625.inch,
                                                     boundaryMargin: 0.25.inch))), shapeIDs: [l.id, hole.id], tool: vBit60)
        let stock = Stock(width: 6.inch, height: 5.inch, thickness: 0.75.inch, materialName: "Walnut")
        return Project(name: "Inlay (pocket and plug)", displayUnits: .inch, stock: stock, shapes: [l, hole], operations: [pocket, plug],
                       notes: "Saved by format 6: a V-carve inlay pocket, turned off, and its plug.")
    }

    @Test func inlaySavedByFormatSixStillDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("inlay-v6", make: Self.savedInlay)
        #expect(p.formatVersion == 6)
        #expect(p == Self.savedInlay())
        #expect(p.operations.map(\.name) == ["Inlay pocket", "Inlay plug"])
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.severity != .info }, "\(job.issues.map(\.message))")
        let data = GoldenPostTests.post(p)
        try GoldenPostTests.check(data, golden: "decoded-inlay-v6")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }

    // MARK: Setup sheet

    @Test func setupSheetNotesEachInlayToolpath() {
        let (project, _, _) = Self.inlayPair()
        let html = SetupSheet.html(project: project, job: CAMEngine.generate(project))
        #expect(html.contains("<h2>Inlay</h2>"))
        #expect(html.contains("Pocket: <b>pocket</b> (female), V-carved to a flat depth of 5.1 mm with the 60° T5"))
        #expect(html.contains("Plug: <b>plug</b> (male), mirrored, with the 60° T5: pocket depth 5.1 mm, glue gap 0.5 mm, "
            + "surface clearance 1.6 mm, so carved from 4.6 mm down to 6.2 mm"))
        // Ordinary jobs don't get the section.
        #expect(!SetupSheet.html(project: .demoSign(), job: CAMEngine.generate(.demoSign())).contains("<h2>Inlay</h2>"))
    }
}
