import Foundation
import Testing
@testable import CAMCore

/// Inlay upgrades (#85): Add Toolpath ▸ Inlay… (both sides made together, and kept in line), whole-board plugs and
/// raster flat clearing with the V-bit.
struct InlayPairTests {
    static var vBit60: Tool { InlayTests.vBit60 }
    static var vBit90: Tool { InlayTests.vBit90 }
    static var eighth: Tool { InlayTests.eighth }

    /// The L with a hole from `InlayTests`, on a 120 × 100 board, as the Inlay dialog makes it.
    static func design() -> [DesignShape] {
        [InlayTests.lShape(at: Vec2(60, 50)), DesignShape(name: "Hole", kind: .circle(radius: 3), position: Vec2(68, 42))]
    }

    static let stock = Stock(width: 120, height: 100, thickness: 19, clearanceHeight: 10, plungeHeight: 2)

    static func settings(clearance: Tool? = eighth, boundary: VCarveInlay.Boundary = .margin, raster: VCarveRaster? = nil)
        -> InlayPairSettings {
        InlayPairSettings(vBit: vBit60, clearanceTool: clearance, pocketDepth: 0.2.inch, glueGap: 0.5, surfaceClearance: 1.6,
                          boundary: boundary, boundaryMargin: 6, flatRaster: raster)
    }

    /// A project with the Inlay dialog's pair added for `shapes` (all of them selected), sample spacing as the nesting
    /// tests use (nil: the dialog's). The plug is included in the output too unless `asAdded`, so both are generated.
    static func pair(_ settings: InlayPairSettings, shapes: [DesignShape] = design(), stock: Stock = stock, sampleSpacing: Double? = 0.1,
                     asAdded: Bool = false) -> (Project, CAMOperation, CAMOperation) {
        var project = Fixture.project(shapes: shapes, ops: [], stock: stock)
        guard let added = project.addInlay(settings, shapes: shapes.map(\.id)) else { return (project, project.operations[0], project.operations[0]) }
        for i in project.operations.indices {
            if !asAdded { project.operations[i].enabled = true }
            guard let spacing = sampleSpacing, case var .vcarve(p) = project.operations[i].kind else { continue }
            p.sampleSpacing = spacing
            project.operations[i].kind = .vcarve(p)
        }
        let pocket = project.operations.first { $0.id == added.pocket.id }!, plug = project.operations.first { $0.id == added.plug.id }!
        return (project, pocket, plug)
    }

    /// The plug seats in the pocket: nothing runs into the pocket board, the walls meet, and the pocket's floor is the
    /// glue gap under the plug's face (`InlayTests.plugNestsInItsPocket`).
    static func expectSeats(_ project: Project, pocket: CAMOperation, plug: CAMOperation, glueGap g: Double, floorTolerance: Double = 0.05,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        // Each side simulated on its own board, so both are generated.
        var both = project
        for i in both.operations.indices { both.operations[i].enabled = true }
        let (gaps, s) = InlayTests.nestingGaps(both, pocket: pocket, plug: plug)
        #expect(gaps.count > 100_000, sourceLocation: sourceLocation)
        guard let tightest = gaps.min(by: { $0.gap < $1.gap }) else { return }
        #expect(tightest.gap > -0.12, "plug runs \(-tightest.gap) mm into the pocket at \(tightest.p)", sourceLocation: sourceLocation)
        let walls = gaps.filter { $0.pocketZ < -0.2 && $0.pocketZ > -s + 0.2 }
        #expect(walls.count > 2000, sourceLocation: sourceLocation)
        let loose = walls.filter { abs($0.gap) > 0.12 }.count
        #expect(Double(loose) < 0.01 * Double(walls.count), "\(loose) of \(walls.count) wall cells off by more than 0.12 mm",
                sourceLocation: sourceLocation)
        let floor = gaps.filter { abs($0.pocketZ + pocket.inlayPocketDepth!) < 0.02 && abs($0.plugZ) < 1e-6 }
        #expect(floor.count > 1000, sourceLocation: sourceLocation)
        let meanFloor = floor.map(\.gap).reduce(0, +) / Double(max(1, floor.count))
        #expect(abs(meanFloor - g) < floorTolerance, "mean floor gap \(meanFloor)", sourceLocation: sourceLocation)
    }

    // MARK: Inlay…

    @Test func inlayMakesAMatchingPairThatNests() throws {
        let (project, pocket, plug) = Self.pair(Self.settings(), asAdded: true)
        #expect(project.operations.map(\.name) == ["Inlay pocket", "Inlay plug"])
        // The two sides share the design, the V-bit and the clearance tool; P is the pocket's flat depth.
        #expect(pocket.shapeIDs == plug.shapeIDs && pocket.tool.isSameBit(as: plug.tool))
        guard case let .vcarve(a) = pocket.kind, case let .vcarve(b) = plug.kind else { Issue.record("not V-carves"); return }
        #expect(a.inlay?.role == .pocket && a.flatDepth == 0.2.inch && a.clearanceTool?.id == Self.eighth.id)
        #expect(b.inlay == VCarveInlay(role: .plug, pocketDepth: 0.2.inch, glueGap: 0.5, surfaceClearance: 1.6, boundaryMargin: 6))
        #expect(b.clearanceTool?.id == Self.eighth.id)
        #expect(project.inlayPartners(of: pocket).map(\.id) == [plug.id] && project.inlayPartners(of: plug).map(\.id) == [pocket.id])
        #expect(pocket.inlayDifferences(from: plug).isEmpty)
        // Cut one side at a time: the plug starts with Include in output off, so the job checks clean.
        #expect(pocket.enabled && !plug.enabled)
        let job = CAMEngine.generate(project)
        #expect(!job.issues.contains { $0.severity != .info }, "\(job.issues.map(\.message))")
        // And it nests, as the pair made by hand does.
        Self.expectSeats(project, pocket: pocket, plug: plug, glueGap: 0.5, floorTolerance: 0.03)
    }

    @Test func inlayTakesOnlyClosedVectorsAndSplitsOffTheBoundaryVector() throws {
        let l = InlayTests.lShape(at: Vec2(60, 50))
        let board = DesignShape(name: "Board", kind: .rectangle(width: 100, height: 80, cornerRadius: 0), position: Vec2(60, 50))
        let line = DesignShape(name: "Line", kind: .paths([Polyline([Vec2(0, 0), Vec2(10, 10)], closed: false)]), position: Vec2(10, 10))
        var project = Fixture.project(shapes: [l, board, line], ops: [], stock: Self.stock)
        #expect(project.inlayShapes([l.id, board.id, line.id]).map(\.id) == [l.id, board.id])
        // Selected vector: the board goes to the plug only.
        let added = project.addInlay(Self.settings(boundary: .vector), shapes: [l.id, board.id, line.id])
        let pair = try #require(added)
        #expect(pair.pocket.shapeIDs == [l.id] && Set(pair.plug.shapeIDs) == [l.id, board.id])
        #expect(project.plugBoundary(for: pair.plug)?.id == board.id)
        // A margin keeps every closed vector in the design (a frame round the rest is part of it).
        let margin = Self.settings(boundary: .margin).operations(design: [l.id, board.id], boundaryVector: board.id)
        #expect(margin.plug.shapeIDs == [l.id, board.id])
        // Nothing closed, nothing added.
        var empty = Fixture.project(shapes: [line], ops: [], stock: Self.stock)
        let none = empty.addInlay(Self.settings(), shapes: [line.id])
        #expect(none == nil && empty.operations.isEmpty)
    }

    @Test func eachSideOffersToBringTheOtherInLine() throws {
        var (project, pocket, plug) = Self.pair(Self.settings())
        // A new pocket depth on the plug: the two differ, and either can be brought in line.
        InlayTests.setPlug(&plug) { $0.pocketDepth = 0.25.inch }
        #expect(plug.inlayDifferences(from: pocket) == [.pocketDepth(0.25.inch, 0.2.inch)])
        let updated = plug.inlayPartnerMatched(pocket)
        #expect(updated.inlayPocketDepth == 0.25.inch && updated.inlayDifferences(from: plug).isEmpty)
        let matched = pocket.inlayPartnerMatched(plug)
        #expect(matched.inlayPocketDepth == 0.2.inch)
        // Only the shared settings move: the plug keeps its own glue gap, clearance and boundary.
        guard case let .vcarve(m) = matched.kind else { Issue.record("not a V-carve"); return }
        #expect(m.inlay?.glueGap == 0.5 && m.inlay?.surfaceClearance == 1.6 && m.inlay?.role == .plug)
        // A different bit and no clearance tool on the pocket.
        pocket.tool = Self.vBit90
        guard case var .vcarve(a) = pocket.kind else { return }
        a.clearanceTool = nil
        pocket.kind = .vcarve(a)
        let diffs = pocket.inlayDifferences(from: matched)
        #expect(diffs.contains(.bit) && diffs.contains(.clearanceTool) && !diffs.contains { if case .pocketDepth = $0 { true } else { false } })
        let plugNow = pocket.inlayPartnerMatched(matched)
        #expect(plugNow.tool.isSameBit(as: Self.vBit90))
        guard case let .vcarve(q) = plugNow.kind else { return }
        #expect(q.clearanceTool == nil)
        // In the project, the fit check agrees once they match.
        project.operations = [pocket, plugNow]
        #expect(InlayTests.fitIssues(project).allSatisfy { !$0.contains("same V-bit") && !$0.contains("Pocket depth is") },
                "\(InlayTests.fitIssues(project))")
    }

    // MARK: Whole board

    @Test func wholeBoardPlugCarvesTheMaterialOutToItsEdges() throws {
        let (project, pocket, plug) = Self.pair(Self.settings(boundary: .board))
        #expect(project.formatVersion == 14)
        #expect(project.plugBoard(for: plug) == Self.stock.bounds)
        // On its own board, the plug checks clean: nothing past the material's edges.
        var alone = project
        alone.operations = alone.operations.map { var o = $0; o.enabled = o.id == plug.id; return o }
        #expect(!CAMEngine.generate(alone).issues.contains { $0.severity != .info }, "\(CAMEngine.generate(alone).issues.map(\.message))")
        let job = CAMEngine.generate(project)
        let tps = job.toolpaths.filter { [plug.id, VCarveGenerator.deterministicID(plug.id, salt: 1)].contains($0.sourceOperationID) }
        let grid = Fixture.simulate(tps, stock: Self.stock, cell: 0.25)
        guard case let .vcarve(p) = plug.kind, let inlay = p.inlay else { return }
        let floor = -inlay.plugCutDepth
        // The floor is at the cut depth everywhere on the board away from the mirrored design, out to its edges and
        // corners (no rim left standing along them).
        let mirrored = Region.build(from: Self.design().flatMap { $0.polylines(tolerance: 0.01) }
            .map { $0.transformed(Transform2D.translation(Vec2(-60, 0)).then(.scale(-1, 1)).then(.translation(Vec2(60, 0)))) },
            fill: .evenOdd)
        var checked = 0, worst = 0.0
        for x in stride(from: 0.125, to: 120, by: 0.75) {
            for y in stride(from: 0.125, to: 100, by: 0.75) {
                let q = Vec2(x, y)
                guard !mirrored.contains(where: { $0.contains(q) || $0.loops.contains { $0.closestPoint(to: q).distance < 3 } }) else { continue }
                let h = Double(try #require(grid.height(at: q)))
                worst = max(worst, h - floor)
                checked += 1
            }
        }
        #expect(checked > 15_000)
        #expect(worst < p.vBitClearingRidge * 2 + 0.15, "the floor stands \(worst) mm proud somewhere")
        for corner in [Vec2(0.125, 0.125), Vec2(119.875, 0.125), Vec2(0.125, 99.875), Vec2(119.875, 99.875)] {
            #expect(abs(Double(try #require(grid.height(at: corner))) - floor) < 0.3, "corner \(corner)")
        }
        // The design stands at full height, and it still seats.
        #expect(try #require(grid.height(at: Vec2(60 + 17, 40))) == 0)
        Self.expectSeats(project, pocket: pocket, plug: plug, glueGap: 0.5)
        // The setup sheet says how to set the board up.
        var both = project
        both.operations = both.operations.map { var o = $0; o.enabled = o.id == plug.id; return o }
        let html = SetupSheet.html(project: both, job: CAMEngine.generate(both))
        #expect(html.contains("carved right out to the edges of its board: cut it from a board the size of the material"))
    }

    @Test func wholeBoardPlugOfAnotherSizeIsCentredOnTheDesign() throws {
        var settings = Self.settings(boundary: .board)
        settings.boardSize = Vec2(80, 60)
        let (project, _, plug) = Self.pair(settings)
        let board = try #require(project.plugBoard(for: plug))
        #expect(board == Rect2(x: 20, y: 20, width: 80, height: 60))
        let job = CAMEngine.generate(project)
        let tp = try #require(job.toolpaths.first { $0.sourceOperationID == plug.id })
        // Carved to just inside the board's edges, nowhere outside it but where the bit's cone leans past them.
        let e = try #require(tp.cuttingExtents)
        let r = plug.tool.radius
        #expect(e.min.x > 20 - r && e.max.x < 100 + r && e.min.y > 20 - r && e.max.y < 80 + r)
        let grid = Fixture.simulate(job.toolpaths.filter { $0.sourceOperationID == plug.id
            || $0.sourceOperationID == VCarveGenerator.deterministicID(plug.id, salt: 1) }, stock: Self.stock, cell: 0.25)
        guard case let .vcarve(p) = plug.kind, let inlay = p.inlay else { return }
        #expect(abs(Double(try #require(grid.height(at: Vec2(21.125, 50.125)))) + inlay.plugCutDepth) < 0.3)
        #expect(try #require(grid.height(at: Vec2(10.125, 50.125))) == 0)
        // Where to put it.
        var cut = project
        cut.operations = cut.operations.map { var o = $0; o.enabled = o.id == plug.id; return o }
        let html = SetupSheet.html(project: cut, job: CAMEngine.generate(cut))
        #expect(html.contains("cut it from a 80.0 mm × 60.0 mm board with its lower-left corner at X 20.0 mm, Y 20.0 mm")
            || html.contains("cut it from a 80 mm × 60 mm board with its lower-left corner at X 20 mm, Y 20 mm"), "\(html)")
        // A board too small for the design says so.
        var small = Self.settings(boundary: .board)
        small.boardSize = Vec2(30, 20)
        let (tooSmall, _, _) = Self.pair(small)
        #expect(CAMEngine.generate(tooSmall).issues.contains { $0.message.contains("runs off the plug board") })
    }

    // MARK: Raster flat clearing

    /// Simulated heights of `op`'s toolpaths (its flat clearing too) on their own board.
    static func heights(_ job: JobResult, _ op: CAMOperation, stock: Stock, cell: Double = 0.1) -> HeightGrid {
        let ids: Set<UUID> = [op.id, VCarveGenerator.deterministicID(op.id, salt: 1)]
        return Fixture.simulate(job.toolpaths.filter { ids.contains($0.sourceOperationID) }, stock: stock, cell: cell)
    }

    /// The estimate for `op`'s own toolpaths (its flat clearing too).
    static func seconds(_ job: JobResult, _ op: CAMOperation) -> Double {
        let ids: Set<UUID> = [op.id, VCarveGenerator.deterministicID(op.id, salt: 1)]
        return job.toolpaths.filter { ids.contains($0.sourceOperationID) }.compactMap { job.estimatedSeconds(toolpath: $0.id) }.reduce(0, +)
    }

    @Test func rasterLeavesTheSameFloorAsRingsFasterWithoutGouging() throws {
        let rings = Self.pair(Self.settings(clearance: nil))
        let raster = Self.pair(Self.settings(clearance: nil, raster: VCarveRaster()))
        let ringsJob = CAMEngine.generate(rings.0), rasterJob = CAMEngine.generate(raster.0)
        for side in [1, 2] {
            let (a, b) = side == 1 ? (rings.1, raster.1) : (rings.2, raster.2)
            let label = side == 1 ? "pocket" : "plug"
            guard case let .vcarve(p) = b.kind else { continue }
            #expect(p.flatRaster != nil && p.vBitClearsFlats)
            let ga = Self.heights(ringsJob, a, stock: Self.stock), gb = Self.heights(rasterJob, b, stock: Self.stock)
            // The flat: where the V reaches the flat depth.
            let tool = b.tool
            let rCap = tool.tipDiameter / 2 + (p.carveFlatDepth ?? 0) * tool.halfAngleTangent
            let shapes = raster.0.shapes(for: b)
            let carved = p.isPlug
                ? VCarveGenerator.plugRegions(p.inlay!, shapes: shapes, stock: raster.0.stock, edge: 0, tolerance: 0.01, arcTolerance: 0.005).regions
                : Region.build(from: shapes.flatMap { $0.polylines(tolerance: 0.01) }.filter(\.isClosed), fill: .evenOdd)
            let flat = carved.flatMap { $0.offset(by: -rCap, arcTolerance: 0.005) }
            let inner = flat.flatMap { $0.offset(by: -0.3, arcTolerance: 0.005) }
            let wallSide = flat.flatMap { $0.offset(by: 0.15, arcTolerance: 0.005) }
            // On the V walls (outside the flat), the raster leaves exactly what the rings do: they're the carve's own, and
            // neither clearing reaches them. On the flat, it never goes below the floor, reaches it, and leaves ridges no
            // taller than the tallest the rings can leave.
            var wallWorst = (d: 0.0, at: Vec2(0, 0)), floorCells = 0, tallest = -Double.infinity, ringsTallest = -Double.infinity
            var lowest = Double.infinity
            let floorZ = -(p.deepest ?? 0)
            let c = gb.cellSize, o = gb.origin
            for x in stride(from: o.x + c / 2, to: o.x + Double(gb.columns) * c, by: c) {
                for y in stride(from: o.y + c / 2, to: o.y + Double(gb.rows) * c, by: c) {
                    let q = Vec2(x, y)
                    guard let za = ga.height(at: q).map(Double.init), let zb = gb.height(at: q).map(Double.init) else { continue }
                    lowest = min(lowest, zb)
                    if !wallSide.contains(where: { $0.contains(q) }) {
                        if za - zb > wallWorst.d { wallWorst = (za - zb, q) }
                    } else if inner.contains(where: { $0.contains(q) }) {
                        floorCells += 1
                        tallest = max(tallest, zb)
                        ringsTallest = max(ringsTallest, za)
                    }
                }
            }
            #expect(wallWorst.d < 0.03, "\(label): raster cuts \(wallWorst.d) mm deeper than the rings on a wall at \(wallWorst.at)")
            #expect(lowest > floorZ - 0.02, "\(label): raster goes down to \(lowest), below the floor at \(floorZ)")
            #expect(floorCells > 1000, "\(label)")
            #expect(tallest - floorZ < p.vBitRasterRidge + 0.06,
                    "\(label): raster floor stands \(tallest - floorZ) mm proud (rings \(ringsTallest - floorZ))")
            #expect(tallest - floorZ > 0, "\(label): the floor's ridges should show at this cell size")
            // Faster in the estimate (a narrow band round a plug gains least: its lines are short).
            let ta = Self.seconds(ringsJob, a), tb = Self.seconds(rasterJob, b)
            #expect(tb < (p.isPlug ? 0.95 : 0.7) * ta, "\(label): raster \(tb) s, rings \(ta) s")
        }
        // And the plug seats in the raster pocket.
        Self.expectSeats(raster.0, pocket: raster.1, plug: raster.2, glueGap: 0.5)
    }

    @Test func rasterIsMuchFasterOverLargeFlats() throws {
        // A pocket with large flats, letters with counters (islands) and a whole-board plug round them: each flat on its
        // own, its lines in runs.
        let joy = DesignShape(name: "JO", kind: .text(TextSpec(string: "JO", capHeight: 1.5.inch)), position: Vec2(2.inch, 1.5.inch))
        let ellipse = DesignShape(kind: .ellipse(radiusX: 30, radiusY: 18), position: Vec2(2.inch, 1.5.inch))
        let stock = Stock(width: 4.inch, height: 3.inch, thickness: 0.75.inch)
        let cases: [(String, DesignShape, VCarveInlay.Boundary, Int)] = [("ellipse pocket", ellipse, .margin, 1), ("JO pocket", joy, .margin, 1),
                                                                        ("JO whole-board plug", joy, .board, 2)]
        for (name, shape, boundary, side) in cases {
            let rings = Self.pair(Self.settings(clearance: nil, boundary: boundary), shapes: [shape], stock: stock, sampleSpacing: nil)
            let raster = Self.pair(Self.settings(clearance: nil, boundary: boundary, raster: VCarveRaster(angle: 45)), shapes: [shape],
                                   stock: stock, sampleSpacing: nil)
            // Only the side measured is generated.
            func only(_ r: (Project, CAMOperation, CAMOperation)) -> (Project, CAMOperation) {
                var p = r.0
                let op = side == 1 ? r.1 : r.2
                p.operations = [op]
                return (p, op)
            }
            let (pa, a) = only(rings), (pb, b) = only(raster)
            let ja = CAMEngine.generate(pa), jb = CAMEngine.generate(pb)
            let ta = Self.seconds(ja, a), tb = Self.seconds(jb, b)
            #expect(tb < 0.7 * ta, "\(name): raster \(tb) s, rings \(ta) s")
            #expect(!jb.issues.contains { $0.severity == .error }, "\(name): \(jb.issues.map(\.message))")
            #expect(InlayTests.lowRapids(jb.toolpaths).isEmpty, "\(name)")
        }
    }

    @Test func aWiderRasterStepoverWarns() {
        var (project, pocket, _) = Self.pair(Self.settings(clearance: nil, raster: VCarveRaster(stepover: 1.5)))
        let job = CAMEngine.generate(project)
        #expect(job.issues.contains { $0.operation == "Inlay pocket" && $0.message.contains("leaves ridges up to") })
        #expect(InlayTests.fitIssues(project).contains { $0.contains("raster lines") && $0.contains("glue gap") })
        // The automatic stepover doesn't.
        guard case var .vcarve(p) = pocket.kind else { return }
        p.flatRaster = VCarveRaster()
        pocket.kind = .vcarve(p)
        project.operations[0] = pocket
        #expect(!CAMEngine.generate(project).issues.contains { $0.operation == "Inlay pocket" && $0.message.contains("leaves ridges up to") })
        #expect(!InlayTests.fitIssues(project).contains { $0.contains("raster lines") })
        // With a clearance tool the raster setting has nothing to do.
        #expect(!VCarveParams(flatDepth: 2, clearanceTool: Self.eighth, flatRaster: VCarveRaster()).vBitClearsFlats)
    }

    // MARK: File format

    @Test func rasterAndBoardSaveOnlyWhenUsed() throws {
        let e = JSONEncoder()
        func keys(_ v: some Encodable) throws -> Set<String> {
            Set(try #require(JSONSerialization.jsonObject(with: e.encode(v)) as? [String: Any]).keys)
        }
        #expect(try keys(VCarveParams(flatDepth: 2)) == ["flatDepth", "sampleSpacing"])
        #expect(try keys(VCarveInlay(role: .plug)).contains("boardSize") == false)
        // Raster needs no new format: an older build clears the same floor in rings.
        var (project, pocket, plug) = Self.pair(Self.settings(clearance: nil, raster: VCarveRaster(stepover: 0.3, angle: 30)))
        #expect(project.formatVersion == 6)
        project.operations = [pocket]
        #expect(project.formatVersion == 1)
        project.operations = [pocket, plug]
        #expect(try Project.decode(project.encoded()) == project)
        // A whole board is format 14, and round-trips its size.
        Self.setBoard(&plug, size: Vec2(80, 60))
        project.operations = [pocket, plug]
        #expect(project.formatVersion == 14)
        let back = try Project.decode(project.encoded())
        #expect(back == project)
        guard case let .vcarve(q) = back.operations[1].kind else { Issue.record("not a V-carve"); return }
        #expect(q.inlay?.boundary == .board && q.inlay?.boardSize == Vec2(80, 60) && q.flatRaster == VCarveRaster(stepover: 0.3, angle: 30))
    }

    static func setBoard(_ op: inout CAMOperation, size: Vec2?) {
        InlayTests.setPlug(&op) { $0.boundary = .board; $0.boardSize = size }
    }

    /// A project as format 14 first saved it: the Inlay dialog's pair with the V-bit clearing the flats in raster lines
    /// and a whole-board plug, on the default PRO6060 with Mach4. The plug is the side included in the output, so the
    /// golden is a raster-cleared, whole-board plug.
    static func savedBoardInlay() -> Project {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "1A1A0000-0000-0000-0000-%012d", n))! }
        var l = InlayTests.lShape(at: Vec2(2.inch, 1.5.inch))
        l.id = id(1)
        let hole = DesignShape(id: id(2), name: "Hole", kind: .circle(radius: 3), position: Vec2(2.inch + 8, 1.5.inch - 8))
        let settings = InlayPairSettings(vBit: vBit60, pocketDepth: 0.15.inch, boundary: .board, flatRaster: VCarveRaster())
        var (pocket, plug) = settings.operations(design: [l.id, hole.id], boundaryVector: nil)
        pocket.id = id(11)
        plug.id = id(12)
        pocket.enabled = false
        plug.enabled = true
        let stock = Stock(width: 4.inch, height: 3.inch, thickness: 0.5.inch, materialName: "Maple")
        return Project(name: "Inlay (whole-board plug)", displayUnits: .inch, stock: stock, shapes: [l, hole], operations: [pocket, plug],
                       notes: "Saved by format 14: Add Toolpath ▸ Inlay… with a whole-board plug and raster flat clearing; the plug is the side included.")
    }

    @Test func wholeBoardInlaySavedByFormatFourteenStillDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("inlay-board-v14", make: Self.savedBoardInlay)
        #expect(p.formatVersion == 14)
        #expect(p == Self.savedBoardInlay())
        #expect(p.operations.map(\.name) == ["Inlay pocket", "Inlay plug"])
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.severity != .info }, "\(job.issues.map(\.message))")
        let data = GoldenPostTests.post(p)
        try GoldenPostTests.check(data, golden: "decoded-inlay-board-v14")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        #expect(InlayTests.lowRapids(job.toolpaths).isEmpty)
    }
}
