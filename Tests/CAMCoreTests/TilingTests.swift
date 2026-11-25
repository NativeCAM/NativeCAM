import Foundation
import Testing
@testable import CAMCore

/// Tiling: jobs bigger than the machine's travel, cut one tile at a time as the material moves (issue #26).
struct TilingTests {
    static let lib = ToolLibrary.starter
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "71E50000-0000-0000-0000-%012d", n))! }

    /// An 8 ft board, 12 in wide, on the PRO6060 (61.375 in of travel): feeds through in Y in two tiles 59 in apart. A
    /// panel cut out along almost all of it, a slot pocketed and a star V-carved across the tile line, and two holes.
    static func longBoard(registration: Bool = true, configure: (inout Project) -> Void = { _ in }) -> Project {
        let quarter = lib.tool(number: 1)!, eighth = lib.tool(number: 2)!, vBit = lib.tool(number: 5)!
        let panel = DesignShape(id: id(1), name: "Panel", kind: .rectangle(width: 8.inch, height: 90.inch, cornerRadius: 1.inch),
                                position: Vec2(6.inch, 48.inch))
        let slot = DesignShape(id: id(2), name: "Slot", kind: .rectangle(width: 2.inch, height: 20.inch, cornerRadius: 0),
                               position: Vec2(4.inch, 59.inch))
        let star = DesignShape(id: id(3), name: "Star", kind: .star(points: 5, outerRadius: 1.5.inch, innerRadius: 0.7.inch),
                               position: Vec2(8.inch, 59.inch))
        let hole1 = DesignShape(id: id(4), name: "Hole 1", kind: .circle(radius: 0.0625.inch), position: Vec2(4.inch, 20.inch))
        let hole2 = DesignShape(id: id(5), name: "Hole 2", kind: .circle(radius: 0.0625.inch), position: Vec2(8.inch, 75.inch))
        let ops = [
            CAMOperation(id: id(11), name: "Slot", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))),
                         shapeIDs: [slot.id], tool: quarter),
            CAMOperation(id: id(12), name: "Star", kind: .vcarve(VCarveParams()), shapeIDs: [star.id], tool: vBit),
            CAMOperation(id: id(13), name: "Holes", kind: .drill(DrillParams(depth: 0.5.inch)), shapeIDs: [hole1.id, hole2.id], tool: eighth),
            CAMOperation(id: id(14), name: "Cut out panel", kind: .profile(ProfileParams(
                side: .outside, depth: DepthSettings(cutDepth: 0.77.inch), tabs: TabSettings(enabled: true, count: 6))),
                         shapeIDs: [panel.id], tool: quarter),
        ]
        var p = Project(name: "Long board", displayUnits: .inch,
                        stock: Stock(width: 12.inch, height: 96.inch, thickness: 0.75.inch, materialName: "Poplar"),
                        machine: .avidPRO6060, shapes: [panel, slot, star, hole1, hole2], operations: ops,
                        tiling: TilingSettings(enabled: true, mode: .feedThroughY, registration: registration ? RegistrationHoles() : nil))
        configure(&p)
        return p
    }

    static func untiled(_ p: Project) -> Project {
        var q = p
        q.tiling?.enabled = false
        return q
    }

    // MARK: Layout

    @Test func feedThroughLayoutUsesTheTravelLessAMargin() throws {
        let p = Self.longBoard(registration: false)
        let layout = try #require(TileLayout(p))
        // The V-bit is the largest (1/4 in radius): overlap 1/4 + 1/8 in; the tile is 61.375 in less 1 in and the reach.
        #expect(abs(layout.overlap - 0.375.inch) < 1e-9)
        #expect(abs(layout.pitch.y - 59.inch) < 1e-9)
        #expect(abs(layout.pitch.x - 12.inch) < 1e-9)
        #expect(layout.count == 2)
        #expect(layout.columns == 1)
        #expect(layout.rows == 2)
        #expect(layout.seamsY.count == 1)
        #expect(abs(layout.seamsY[0] - 59.inch) < 1e-9)
        #expect(layout.tiles[0].offset == .zero)
        #expect(abs(layout.tiles[1].core.max.y - 96.inch) < 1e-9)
        #expect(abs(layout.move(to: 1).y - 59.inch) < 1e-9)
    }

    @Test func smallestTileFirstLinesTheFramesUpWithTheFarEnd() throws {
        let p = Self.longBoard(registration: false) { $0.tiling?.smallestFirst = true }
        let layout = try #require(TileLayout(p))
        // 96 in in two 59 in tiles: the short one (37 in) first, so its frame starts 22 in before the material.
        #expect(abs(layout.tiles[0].frame.min.y + 22.inch) < 1e-9)
        #expect(abs(layout.tiles[0].core.height - 37.inch) < 1e-9)
        #expect(abs(layout.seamsY[0] - 37.inch) < 1e-9)
        #expect(abs(layout.move(to: 1).y - 59.inch) < 1e-9)
    }

    @Test func gridLaysTilesOutRowByRowFromTheLowerLeft() throws {
        var p = Self.longBoard(registration: false)
        p.stock.width = 30.inch
        p.stock.height = 30.inch
        p.tiling = TilingSettings(enabled: true, mode: .grid, tileWidth: 16.inch, tileHeight: 16.inch)
        let layout = try #require(TileLayout(p))
        #expect(layout.columns == 2)
        #expect(layout.rows == 2)
        #expect(layout.tiles.map(\.column) == [0, 1, 0, 1])
        #expect(layout.tiles.map(\.row) == [0, 0, 1, 1])
        #expect(abs(layout.tiles[3].core.width - 14.inch) < 1e-9)
        #expect(layout.tileIndex(at: Vec2(20.inch, 5.inch)) == 1)
        #expect(layout.tileIndex(at: Vec2(5.inch, 20.inch)) == 2)
    }

    @Test func tilingOffOrOneTileLeavesTheJobAlone() throws {
        let off = Self.untiled(Self.longBoard())
        #expect(TileLayout(off) == nil)
        #expect(CAMEngine.generate(off).tiling == nil)
        var small = Self.longBoard()
        small.stock.height = 40.inch
        #expect(TileLayout(small) == nil)
        let job = CAMEngine.generate(small)
        #expect(job.tiling == nil)
        #expect(job.issues.contains { $0.message.hasPrefix("The material fits in one tile") })
    }

    @Test func rotaryJobsCantBeTiled() {
        var p = Self.longBoard()
        p.stock.setRotary(RotaryStock(diameter: 2.inch, length: 12.inch))
        p.machine.rotary = RotaryAxis()
        #expect(TileLayout(p) == nil)
        let job = CAMEngine.generate(p)
        #expect(job.tiling == nil)
        #expect(job.issues.contains { $0.severity == .error && $0.message.hasPrefix("Rotary jobs can't be tiled") })
    }

    // MARK: Splitting

    /// Cutting points (below the top) along every cutting move, about `step` mm apart.
    static func cutPoints(_ tps: [Toolpath], step: Double = 1) -> [(point: Vec3, toolpath: Toolpath)] {
        var out: [(Vec3, Toolpath)] = []
        for tp in tps {
            tp.forEachMotion { s, m in
                guard m.kind != .rapid, m.kind != .dwell else { return }
                let points = m.kind.isArc ? m.samples(from: s, maxStep: step) : {
                    let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
                    return (1...n).map { s.lerp(to: m.end, Double($0) / Double(n)) }
                }()
                for p in points where p.z < -0.01 { out.append((p, tp)) }
            }
        }
        return out
    }

    /// Cutting segments bucketed by XY cell, for finding the nearest one quickly.
    struct SegmentIndex {
        var cell: Double
        var buckets: [Int: [(Vec3, Vec3, Toolpath)]] = [:]
        init(_ tps: [Toolpath], cell: Double = 5) {
            self.cell = cell
            for tp in tps {
                tp.forEachMotion { s, m in
                    guard m.kind != .rapid, m.kind != .dwell else { return }
                    var a = s
                    for b in m.samples(from: s, maxStep: 0.5) {
                        let lo = Vec2(min(a.x, b.x), min(a.y, b.y)), hi = Vec2(max(a.x, b.x), max(a.y, b.y))
                        for cx in Int((lo.x / cell).rounded(.down))...Int((hi.x / cell).rounded(.down)) {
                            for cy in Int((lo.y / cell).rounded(.down))...Int((hi.y / cell).rounded(.down)) {
                                buckets[cx &* 100_003 &+ cy, default: []].append((a, b, tp))
                            }
                        }
                        a = b
                    }
                }
            }
        }
        /// The toolpaths with a cutting move within `tolerance` of `p` (in 3D).
        func near(_ p: Vec3, tolerance: Double) -> [Toolpath] {
            let key = Int((p.x / cell).rounded(.down)) &* 100_003 &+ Int((p.y / cell).rounded(.down))
            var out: [Toolpath] = []
            for (a, b, tp) in buckets[key] ?? [] {
                let ab = b - a
                let l2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
                let t = l2 < 1e-18 ? 0 : max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y + (p.z - a.z) * ab.z) / l2))
                if p.distance(to: a.lerp(to: b, t)) <= tolerance { out.append(tp) }
            }
            return out
        }
    }

    /// Every cut the untiled job makes, the tiles make too (in job coordinates), by the same operation; and where two
    /// tiles cut the same place, it's in an overlap band.
    @Test func tilesCoverTheJobAndOnlyRecutInsideTheOverlaps() throws {
        // Full retracts: every cutting move then comes from the generators (no stay-down links across cleared floors).
        let p = Self.longBoard(registration: false) { $0.stock.retractMode = .full }
        let tiled = CAMEngine.generate(p)
        let whole = CAMEngine.generate(Self.untiled(p))
        let job = try #require(tiled.tiling)
        #expect(job.layout.count == 2)
        let index = SegmentIndex(tiled.toolpaths)
        var missing = 0, outside = 0
        for (q, tp) in Self.cutPoints(whole.toolpaths) {
            let hits = index.near(q, tolerance: 0.05).filter { $0.sourceOperationID == tp.sourceOperationID }
            if hits.isEmpty { missing += 1; continue }
            if Set(hits.compactMap(\.tile)).count > 1, job.layout.distanceToSeam(q.xy) > job.layout.overlap + 0.05 { outside += 1 }
        }
        #expect(missing == 0)
        #expect(outside == 0)
        // And the tiles cut nothing the job doesn't, apart from coming back down onto a cut where it broke.
        let original = SegmentIndex(whole.toolpaths)
        var extra = 0
        for (q, tp) in Self.cutPoints(tiled.toolpaths) {
            let same = original.near(q, tolerance: 0.05).filter { $0.sourceOperationID == tp.sourceOperationID }
            if same.isEmpty, job.layout.distanceToSeam(q.xy) > job.layout.overlap + 0.05 { extra += 1 }
        }
        #expect(extra == 0)
        // Every toolpath broke where it crossed the tile line, and each tile has its own share.
        for op in p.operations where op.kind.needsShapes {
            let tiles = Set(tiled.toolpaths.filter { $0.sourceOperationID == op.id }.compactMap(\.tile))
            #expect(!tiles.isEmpty, "\(op.name)")
        }
        #expect(Set(tiled.toolpaths.filter { $0.sourceOperationID == Self.id(14) }.compactMap(\.tile)) == [0, 1])
        #expect(Set(tiled.toolpaths.filter { $0.sourceOperationID == Self.id(11) }.compactMap(\.tile)) == [0, 1])
        #expect(Set(tiled.toolpaths.filter { $0.sourceOperationID == Self.id(12) }.compactMap(\.tile)) == [0, 1])
    }

    /// The tiles, simulated one after another in job coordinates, leave the same material as the job cut in one go.
    @Test func assembledSimulationMatchesTheUntiledJob() throws {
        let p = Self.longBoard(registration: false)
        let tiled = CAMEngine.generate(p)
        let whole = CAMEngine.generate(Self.untiled(p))
        #expect(tiled.tiling != nil)
        var a = SimulationSession(toolpaths: tiled.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 1)
        var b = SimulationSession(toolpaths: whole.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 1)
        a.runToEnd()
        b.runToEnd()
        let ga = a.grid, gb = b.grid
        try #require(ga.heights.count == gb.heights.count)
        var worst: Float = 0, off = 0
        for i in ga.heights.indices {
            let d = abs(ga.heights[i] - gb.heights[i])
            worst = max(worst, d)
            if d > 0.02 { off += 1 }
        }
        #expect(off * 2000 < ga.heights.count, "\(off) of \(ga.heights.count) cells differ, worst \(worst) mm")
        #expect(worst < 0.5)
        #expect(a.rapidCollisions.isEmpty)
    }

    /// Each tile's file fits the machine, though the job as a whole doesn't.
    @Test func everyTileFileStaysWithinTheMachinesTravel() throws {
        let p = Self.longBoard()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        #expect(export.files.count == 2)
        for file in export.files {
            let program = try GCodeParser.parse(file.gcode)
            #expect(GCodeCheck.envelope(program, toolpaths: file.toolpaths, project: file.project).isEmpty)
            let issues = GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: file.project, dialect: export.post.dialect)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        }
        // Untiled, the same job is too long for the machine.
        let whole = CAMEngine.generate(Self.untiled(p))
        #expect(whole.issues.contains { $0.message.contains("larger than the") })
    }

    @Test func feedThroughInXAndGridTilesBothSplitTheJob() throws {
        // The same board turned on its side and fed through in X.
        var x = Self.longBoard(registration: false)
        x.stock.width = 96.inch
        x.stock.height = 12.inch
        for i in x.shapes.indices {
            let s = x.shapes[i]
            x.shapes[i].position = Vec2(s.position.y, s.position.x)
            x.shapes[i].rotation = 90
        }
        x.tiling?.mode = .feedThroughX
        let fx = CAMEngine.generate(x)
        let layoutX = try #require(fx.tiling?.layout)
        #expect(layoutX.columns == 2)
        #expect(layoutX.rows == 1)
        #expect(!fx.hasErrors, "\(fx.issues.filter { $0.severity == .error }.map(\.message))")
        // A square sheet in four tiles.
        var g = Self.longBoard(registration: false)
        g.stock.width = 30.inch
        g.stock.height = 30.inch
        g.shapes = [DesignShape(id: Self.id(1), name: "Disc", kind: .circle(radius: 13.inch), position: Vec2(15.inch, 15.inch))]
        g.operations = [CAMOperation(id: Self.id(14), name: "Cut out disc", kind: .profile(ProfileParams(
            side: .outside, depth: DepthSettings(cutDepth: 0.3.inch))), shapeIDs: [Self.id(1)], tool: Self.lib.tool(number: 1)!)]
        g.machine.model = .custom
        g.machine.travel = Vec3(20.inch, 20.inch, 6.inch)
        g.tiling = TilingSettings(enabled: true, mode: .grid)
        let fg = CAMEngine.generate(g)
        let layoutG = try #require(fg.tiling?.layout)
        #expect(layoutG.columns == 2)
        #expect(layoutG.rows == 2)
        #expect(Set(fg.toolpaths.compactMap(\.tile)) == [0, 1, 2, 3])
        #expect(!fg.hasErrors, "\(fg.issues.filter { $0.severity == .error }.map(\.message))")
        // Each tile's cuts stay in its share of the job, plus the overlap and the bit.
        for (k, tps) in try #require(fg.tiling).tiles.enumerated() {
            let reach = layoutG.tiles[k].core.insetBy(-(layoutG.overlap + 0.125.inch + 0.01))
            for (q, _) in Self.cutPoints(tps) { #expect(reach.contains(q.xy)) }
        }
    }

    // MARK: Registration holes

    @Test func registrationHolesAreOnePitchApartAndOffTheDesign() throws {
        let p = Self.longBoard()
        let job = CAMEngine.generate(p)
        let layout = try #require(job.tiling?.layout)
        let reg = try #require(layout.registration)
        let pitch = layout.pitch.y
        // Tile 1 drills the spoilboard pair in front of the material and the pair for tile 2 exactly one pitch on; the
        // last tile drills none, and its dowels stand where the spoilboard holes are.
        #expect(reg.drilled[0].count == 4)
        #expect(reg.drilled[1].isEmpty)
        #expect(reg.dowels[0].isEmpty)
        #expect(reg.dowels[1] == reg.spoilboard)
        for (fixed, next) in zip(reg.spoilboard, reg.drilled[0].suffix(2)) {
            #expect(abs(next.y - fixed.y - pitch) < 1e-9)
            #expect(abs(next.x - fixed.x) < 1e-9)
        }
        #expect(reg.spoilboard.allSatisfy { $0.y + reg.radius < 0 })
        // In job coordinates the holes through the material are where tile 2's dowels go, after it moves one pitch.
        let holes = reg.materialHoles(layout.tiles, stock: p.stock)
        #expect(holes.count == 2)
        #expect(holes.allSatisfy { $0.tile == 0 })
        let dowels = reg.dowels[1].map { $0 + layout.tiles[1].offset }
        for (h, d) in zip(holes.map(\.point), dowels) { #expect(h.distance(to: d) < 1e-9) }
        // They're cut first in tile 1, with the 1/4" end mill that cuts the slot, through the material and a quarter
        // inch into the spoilboard.
        let first = try #require(job.tiling?.tiles[0].first)
        #expect(first.sourceOperationID == TileSplitter.registrationOperation)
        #expect(first.tool.number == 1)
        let bottom = try #require(first.cuttingExtents).min.z
        #expect(abs(bottom + 1.inch) < 1e-6)
        let complaints = job.issues.filter { $0.operation == "Registration holes" && $0.severity != .info }
        #expect(complaints.isEmpty, "\(complaints.map(\.message))")
    }

    /// With a bit smaller than the hole they're bored in rings, leaving no core standing in the spoilboard.
    @Test func registrationHolesAreBoredWithASmallerBit() throws {
        let p = Self.longBoard { $0.tiling?.registration?.diameter = 0.5.inch }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.tiling?.tiles[0].first)
        #expect(tp.tool.diameter < 0.5.inch)
        let layout = try #require(TileLayout(p))
        let holes = try #require(layout.registration).materialHoles(layout.tiles, stock: p.stock)
        var sim = SimulationSession(toolpaths: [tp], stock: p.stock, rapidRate: 10000, cellSize: 0.2)
        sim.runToEnd()
        let floor = -Float(p.stock.thickness) + 0.05
        for h in holes {
            for d in [Vec2(0, 0), Vec2(2, 0), Vec2(0, -2), Vec2(4, 4)] {
                let z = try #require(sim.grid.height(at: h.point + d))
                #expect(z < floor)
            }
        }
    }

    @Test func registrationHolesOnTheDesignOrAClampAreErrors() throws {
        // An edge offset that puts the holes on the panel's outline.
        let onPart = CAMEngine.generate(Self.longBoard { $0.tiling?.registration?.edgeOffset = 2.inch })
        let errors = onPart.issues.filter { $0.severity == .error && $0.operation == "Registration holes" }.map(\.message)
        #expect(errors.contains { $0.contains("“Cut out panel” cuts") })
        #expect(errors.contains { $0.contains("drills through the design (“Panel”)") })
        // A clamp over a spoilboard hole.
        var clamped = Self.longBoard()
        var clamp = DesignShape(name: "Clamp", kind: .rectangle(width: 2.inch, height: 1.inch, cornerRadius: 0),
                                position: Vec2(1.inch, -0.4.inch))
        clamp.keepOutHeight = 1.inch
        clamped.shapes.append(clamp)
        let clampIssues = CAMEngine.generate(clamped).issues
        #expect(clampIssues.contains { $0.severity == .error && $0.message.contains("under a clamp") })
        // A V-bit can't bore one; nor can a bit wider than the hole.
        let vBit = CAMEngine.generate(Self.longBoard { $0.tiling?.registration?.tool = Self.lib.tool(number: 5) })
        #expect(vBit.issues.contains { $0.severity == .error && $0.message.contains("tapered") })
        let wide = CAMEngine.generate(Self.longBoard { $0.tiling?.registration?.tool = Self.lib.tool(number: 10) })
        #expect(wide.issues.contains { $0.severity == .error && $0.message.contains("wider than") })
        // Individual tiles have their own (see TilingRegistrationTests), numbered.
        let grid = Self.longBoard { $0.tiling?.mode = .grid }
        #expect(TileLayout(grid)?.registration?.holes.isEmpty == false)
    }

    // MARK: Export

    @Test func exportNamesOneFilePerTileInOrder() throws {
        let p = Self.longBoard()
        let job = CAMEngine.generate(p)
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        #expect(export.files.map(\.suffix) == [" - tile 1 of 2", " - tile 2 of 2"])
        #expect(export.files.map(\.tile) == [0, 1])
        let names = JobExport.fileNames(export.files, base: "Long board.tap", fileExtension: "tap")
        #expect(names == ["Long board - tile 1 of 2.tap", "Long board - tile 2 of 2.tap"])
        #expect(export.files[0].gcode.hasPrefix("(Long board - tile 1 of 2)"))
        // Each file is posted for its tile: a 12 × 59 in frame, the zero at its lower-left corner.
        #expect(export.files[1].project.stock.height == 59.inch)
        #expect(export.files[1].project.stock.width == 12.inch)
        // Ten tiles or more sort in order.
        #expect(JobExport.tileSuffix(2, of: 12) == " - tile 03 of 12")
        // Air cuts are tiled the same way.
        let air = try #require(JobExport.files(p, job: job, airCut: 25, date: GoldenPostTests.date))
        #expect(air.files.map(\.suffix) == [" (air cut) - tile 1 of 2", " (air cut) - tile 2 of 2"])
    }

    /// A controller that can't stop for a tool change gets a file per tool in each tile, numbered within the tile.
    @Test func exportSplitsEachTileByToolWhenTheControllerNeedsIt() throws {
        var p = Self.longBoard()
        p.machine.model = .custom
        p.machine.controller = ControllerProfile(family: .grbl)
        let job = CAMEngine.generate(p)
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        let suffixes = export.files.compactMap(\.suffix)
        #expect(suffixes.first == " - tile 1 of 2 - 1 of 4 - T1")
        #expect(suffixes.contains(" - tile 2 of 2 - 3 of 4 - T2"))
        #expect(suffixes == suffixes.sorted())
        #expect(job.issues.contains { $0.message.contains("one per tool in each tile") })
    }

    @Test func setupSheetHasAPagePerTile() throws {
        let p = Self.longBoard()
        let job = CAMEngine.generate(p)
        let html = SetupSheet.html(project: p, job: job, gcodeFile: "Long board.tap", date: GoldenPostTests.date)
        #expect(html.components(separatedBy: "<section class=\"tile\">").count == 3)
        #expect(html.contains("<h2>Tile 1 of 2</h2>"))
        #expect(html.contains("<h2>Tile 2 of 2</h2>"))
        #expect(html.contains("Long board - tile 1 of 2.tap"))
        #expect(html.contains("Long board - tile 2 of 2.tap"))
        #expect(html.contains("Move the material 59.000 in toward Y−; keep the XY zero."))
        // Where tile 2's dowels go, in work coordinates, and what tile 1 drills for them.
        #expect(html.contains("dowel through each, at X 1.000 in, Y -0.375 in and X 11.000 in, Y -0.375 in"))
        #expect(html.contains("the holes for tile 2's dowels at X 1.000 in, Y 58.625 in and X 11.000 in, Y 58.625 in"))
        #expect(html.components(separatedBy: "<svg class=\"preview\"").count == 3)
        // Untiled jobs have no tile pages.
        let plain = Self.untiled(p)
        #expect(!SetupSheet.html(project: plain, job: CAMEngine.generate(plain)).contains("<section class=\"tile\">"))
    }

    // MARK: Breaks

    /// A profile that ramps in ramps back in where a tile line breaks it, never plunging into the material.
    @Test func rampingProfilesRampBackInAtTileLines() throws {
        let p = Self.longBoard(registration: false) { p in
            p.stock.retractMode = .full
            p.operations = [CAMOperation(id: Self.id(14), name: "Cut out panel", kind: .profile(ProfileParams(
                side: .outside, depth: DepthSettings(cutDepth: 0.77.inch), entry: EntrySettings(kind: .ramp, rampLength: 1.inch))),
                                         shapeIDs: [Self.id(1)], tool: Self.lib.tool(number: 1)!)]
        }
        let job = CAMEngine.generate(p)
        #expect(job.tiling != nil)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        // Straight down only into a slot already cut that deep (an earlier pass's); any other descent moves along the cut.
        var model = MaterialSimulator(stock: p.stock, cellSize: 0.5)
        var plunges = 0, ramps = 0
        for tp in job.toolpaths {
            tp.forEachMotion { s, m in
                if m.kind == .feed, m.end.z < s.z - 1e-6, m.end.z < -1e-6 {
                    if s.xy.distance(to: m.end.xy) < 1e-3 {
                        let top = Double(LinkOptimizer.maxHeight(model.grid, around: m.end.xy, radius: tp.tool.radius * 0.5))
                        if top > m.end.z + 0.1 { plunges += 1 }
                    } else {
                        ramps += 1
                    }
                }
                model.apply(m, from: s, tool: tp.tool)
            }
        }
        #expect(plunges == 0)
        #expect(ramps > 0)
        try Self.expectSameResult(p, job)
    }

    /// A rest-machined pocket across a tile line: the larger bit's share reaches further past the tile line than the
    /// smaller one's, by both bits' radii, so the smaller one never meets material the larger one leaves for later.
    @Test func restMachiningKeepsTheLargerBitAheadAtTileLines() throws {
        let half = Self.lib.tool(number: 10)!, eighth = Self.lib.tool(number: 2)!
        let p = Self.longBoard(registration: false) { p in
            p.operations = [CAMOperation(id: Self.id(11), name: "Slot", kind: .pocket(PocketParams(
                depth: DepthSettings(cutDepth: 0.25.inch), clearanceTool: half)), shapeIDs: [Self.id(2)], tool: eighth)]
        }
        let job = CAMEngine.generate(p)
        let tiled = try #require(job.tiling)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let seam = tiled.layout.seamsY[0]
        func reach(_ tool: Int, tile: Int) -> Double {
            let tps = tiled.tiles[tile].filter { $0.tool.number == tool }
            let ys = Self.cutPoints(tps, step: 0.5).map(\.point.y)
            return tile == 0 ? (ys.max() ?? 0) - seam : (ys.min() ?? 0) - seam
        }
        let apart = half.radius + eighth.radius - 0.05
        #expect(reach(10, tile: 0) > reach(2, tile: 0) + apart)
        #expect(reach(10, tile: 1) > reach(2, tile: 1) + apart)
        try Self.expectSameResult(p, job)
    }

    /// A 3D model across a tile line: its rough and its finish split the same way as flat toolpaths (Z follows the cut
    /// where it breaks), the rough runs on further than the finish, and the result is the job's.
    @Test func threeDRoughAndFinishSplitAcrossATileLine() throws {
        let flat = Self.lib.tool(number: 1)!, ball = Self.lib.tool(number: 7)!
        var dome = Model3DFixture.shape(depth: 10)
        dome.id = Self.id(31)
        dome.position = Vec2(100, 150)
        let outline = DesignShape(id: Self.id(34), name: "Edge", kind: .circle(radius: 40), position: Vec2(100, 150))
        var machine = MachineProfile.avidPRO6060
        machine.model = .custom
        machine.travel = Vec3(250, 200, 150)
        let p = Project(name: "Dome", displayUnits: .mm, stock: Stock(width: 200, height: 300, thickness: 40, clearanceHeight: 10, plungeHeight: 2),
                        machine: machine, shapes: [dome, outline], operations: [
                            CAMOperation(id: Self.id(32), name: "Rough", kind: .rough3D(Rough3DParams(allowance: 0.5, boundary: .vectors)),
                                         shapeIDs: [dome.id, outline.id], tool: flat),
                            CAMOperation(id: Self.id(33), name: "Finish", kind: .finish3D(Finish3DParams(boundary: .vectors)),
                                         shapeIDs: [dome.id, outline.id], tool: ball),
                        ], tiling: TilingSettings(enabled: true, mode: .feedThroughY, tileHeight: 150))
        let job = CAMEngine.generate(p)
        let tiled = try #require(job.tiling)
        #expect(tiled.layout.seamsY == [150])
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        #expect(!job.issues.contains { $0.message == "Toolpath is empty." })
        let shifts = TileSplitter.shifts([TileSplitter.Source(toolpath: job.toolpaths[0], operation: p.operations[0]),
                                          TileSplitter.Source(toolpath: job.toolpaths[1], operation: p.operations[1])],
                                         overlap: tiled.layout.overlap).shifts
        #expect(shifts[0] - shifts[1] >= flat.radius + ball.radius - 1e-9)
        for id in [Self.id(32), Self.id(33)] {
            #expect(Set(job.toolpaths.filter { $0.sourceOperationID == id }.compactMap(\.tile)) == [0, 1])
        }
        try Self.expectSameResult(p, job)
    }

    /// The tiles leave the same material as the job cut in one go.
    static func expectSameResult(_ p: Project, _ job: JobResult, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var a = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 1)
        var b = SimulationSession(toolpaths: CAMEngine.generate(untiled(p)).toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 1)
        a.runToEnd()
        b.runToEnd()
        var off = 0
        for (x, y) in zip(a.grid.heights, b.grid.heights) where abs(x - y) > 0.02 { off += 1 }
        #expect(off * 2000 < a.grid.heights.count, "\(off) cells differ", sourceLocation: sourceLocation)
        #expect(a.rapidCollisions.isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: File format

    @Test func tilingRaisesTheFormatOnlyWhenItSplitsTheJob() throws {
        let p = Self.longBoard()
        #expect(p.formatVersion == 9)
        #expect(Self.untiled(p).formatVersion == 1)
        var fits = p
        fits.stock.height = 40.inch
        #expect(fits.formatVersion == 1)
        // Tiling that's off still round-trips, and a file without it has no tiling key.
        let off = Self.untiled(p)
        #expect(try Project.decode(off.encoded()) == off)
        var none = p
        none.tiling = nil
        let text = String(decoding: try none.encoded(), as: UTF8.self)
        #expect(!text.contains("tiling"))
    }

    /// The two-tile feed-through job saved as format 9, posted for Avid's Mach4 profile: each tile's file, byte for byte.
    @Test func savedTiledJobDecodesAndPostsEachTile() throws {
        let p = try GoldenPostTests.savedProject("tiled-v9") { Self.longBoard() }
        #expect(p.formatVersion == 9)
        #expect(p == Self.longBoard())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        try #require(export.files.count == 2)
        for (k, file) in export.files.enumerated() {
            var post = AvidMach4Post(project: file.project, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let data = post.post(file.toolpaths).data(using: .ascii, allowLossyConversion: true)!
            try GoldenPostTests.check(data, golden: "decoded-tiled-v9-tile-\(k + 1)")
            let text = String(decoding: data, as: UTF8.self)
            let issues = GCodeCheck.run(text, toolpaths: file.toolpaths, project: file.project, dialect: .avidMach4)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        }
    }
}
