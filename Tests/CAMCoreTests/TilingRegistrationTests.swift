import Foundation
import Testing
@testable import CAMCore

/// Tiling's registration for individual tiles, and leads where a tile line breaks a profile (issue #95).
struct TilingRegistrationTests {
    static let lib = ToolLibrary.starter
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "95E50000-0000-0000-0000-%012d", n))! }

    /// A 30 in square sheet on a machine with 20 in of travel each way: four tiles, 18 in apart, with registration
    /// holes. Two panels cut out across the vertical tile line, a pocket across the horizontal one and a hole in each
    /// tile, all clear of where the holes go.
    static func gridSheet(configure: (inout Project) -> Void = { _ in }) -> Project {
        let quarter = lib.tool(number: 1)!, eighth = lib.tool(number: 2)!
        let lower = DesignShape(id: id(1), name: "Lower panel", kind: .rectangle(width: 8.inch, height: 3.inch, cornerRadius: 0.5.inch),
                                position: Vec2(18.inch, 6.inch))
        let upper = DesignShape(id: id(2), name: "Upper panel", kind: .rectangle(width: 8.inch, height: 3.inch, cornerRadius: 0.5.inch),
                                position: Vec2(18.inch, 24.inch))
        let slot = DesignShape(id: id(3), name: "Slot", kind: .rectangle(width: 3.inch, height: 8.inch, cornerRadius: 0),
                               position: Vec2(6.inch, 18.inch))
        let holes = [Vec2(4, 4), Vec2(26, 4), Vec2(4, 26), Vec2(26, 26)].enumerated().map { i, p in
            DesignShape(id: id(4 + i), name: "Hole \(i + 1)", kind: .circle(radius: 0.0625.inch), position: Vec2(p.x.inch, p.y.inch))
        }
        let ops = [
            CAMOperation(id: id(11), name: "Slot", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))),
                         shapeIDs: [slot.id], tool: quarter),
            CAMOperation(id: id(12), name: "Holes", kind: .drill(DrillParams(depth: 0.5.inch)), shapeIDs: holes.map(\.id), tool: eighth),
            CAMOperation(id: id(13), name: "Cut out panels", kind: .profile(ProfileParams(
                side: .outside, depth: DepthSettings(cutDepth: 0.77.inch))), shapeIDs: [lower.id, upper.id], tool: quarter),
        ]
        var machine = MachineProfile.avidPRO6060
        machine.model = .custom
        machine.travel = Vec3(20.inch, 20.inch, 6.inch)
        var p = Project(name: "Grid sheet", displayUnits: .inch,
                        stock: Stock(width: 30.inch, height: 30.inch, thickness: 0.75.inch, materialName: "Birch ply"),
                        machine: machine, shapes: [lower, upper, slot] + holes, operations: ops,
                        tiling: TilingSettings(enabled: true, mode: .grid, registration: RegistrationHoles()))
        configure(&p)
        return p
    }

    /// The 8 ft board fed through in Y in two tiles, its panel cut out with arc leads across the tile line.
    static func leadBoard() -> Project {
        TilingTests.longBoard(registration: false) { p in
            p.operations = [CAMOperation(id: TilingTests.id(14), name: "Cut out panel", kind: .profile(ProfileParams(
                side: .outside, depth: DepthSettings(cutDepth: 0.77.inch), leads: LeadSettings())),
                                         shapeIDs: [TilingTests.id(1)], tool: lib.tool(number: 1)!)]
        }
    }

    static func errors(_ job: JobResult) -> [String] { job.issues.filter { $0.severity == .error }.map(\.message) }

    // MARK: Registration for individual tiles

    @Test func everyTileLineGetsAPairOfNumberedHoles() throws {
        let p = Self.gridSheet()
        let job = CAMEngine.generate(p)
        #expect(Self.errors(job).isEmpty, "\(Self.errors(job))")
        let layout = try #require(job.tiling?.layout)
        try #require(layout.columns == 2 && layout.rows == 2)
        #expect(abs(layout.pitch.x - 18.inch) < 1e-9)
        let reg = try #require(layout.registration)
        // Two holes at each of the four tile edges a later tile shares with an earlier one, numbered as drilled.
        #expect(reg.holes.map(\.number) == Array(1...8))
        #expect(reg.holes.map(\.drilledBy) == [0, 0, 0, 0, 1, 1, 2, 2])
        #expect(reg.holes.map(\.pinnedFor) == [1, 1, 2, 2, 3, 3, 3, 3])
        #expect(reg.pinned(0).isEmpty)
        #expect(reg.pinned(1) == [1, 2])
        #expect(reg.pinned(2) == [3, 4])
        #expect(reg.pinned(3) == [5, 6, 7, 8])
        // Each hole is just short of its tile line, in the tile that drills it, and lands on a spoilboard hole tile 1
        // drilled once the material moves to the tile that stands on it.
        let g = reg.radius + RegistrationHoles.edgeGap
        for h in reg.holes {
            let drilling = layout.tiles[h.drilledBy], standing = layout.tiles[h.pinnedFor]
            #expect(drilling.core.contains(h.point))
            let spot = h.point - standing.offset
            #expect(abs(min(spot.x, spot.y) + g) < 1e-9)
            #expect(reg.spoilboard.contains { $0.distance(to: spot) < 1e-9 })
            #expect(reg.dowels[h.pinnedFor].contains { $0.distance(to: spot) < 1e-9 })
        }
        // The tiles share four spoilboard holes, all off the material, drilled first in tile 1.
        #expect(reg.spoilboard.count == 4)
        #expect(reg.spoilboard.allSatisfy { min($0.x, $0.y) + reg.radius < 0 })
        let first = try #require(job.tiling?.tiles[0].first)
        #expect(first.sourceOperationID == TileSplitter.registrationOperation)
        #expect(reg.drilled[0].count == 8)
        #expect(reg.drilled[3].isEmpty)
        let complaints = job.issues.filter { $0.operation == "Registration holes" && $0.severity != .info }
        #expect(complaints.isEmpty, "\(complaints.map(\.message))")
    }

    @Test func eachTileStopsAtItsStartToNameItsDowels() throws {
        let p = Self.gridSheet()
        let job = CAMEngine.generate(p)
        let tiles = try #require(job.tiling).tiles
        #expect(tiles[0].allSatisfy { $0.stopMessage == nil })
        let messages = tiles.dropFirst().map { $0.first?.stopMessage }
        #expect(messages[0]?.hasPrefix("Tile 2 of 4: check dowels are in holes 1 and 2,") == true)
        #expect(messages[1]?.hasPrefix("Tile 3 of 4: check dowels are in holes 3 and 4,") == true)
        #expect(messages[2]?.hasPrefix("Tile 4 of 4: check dowels are in holes 5, 6, 7 and 8,") == true)
        // Only the first toolpath of each file stops, and the message fits in a comment.
        for tps in tiles { #expect(tps.dropFirst().allSatisfy { $0.stopMessage == nil }) }
        #expect(messages.allSatisfy { $0?.contains("(") == false && $0?.contains(")") == false })
        // Feed-through stops for nothing.
        let fed = CAMEngine.generate(TilingTests.longBoard())
        #expect(fed.toolpaths.allSatisfy { $0.stopMessage == nil })
    }

    @Test func setupSheetNumbersTheHolesForEachTile() throws {
        let p = Self.gridSheet()
        let job = CAMEngine.generate(p)
        let html = SetupSheet.html(project: p, job: job, gcodeFile: "Grid sheet.tap", date: GoldenPostTests.date)
        #expect(html.components(separatedBy: "<section class=\"tile\">").count == 5)
        #expect(html.contains("Line holes 1 and 2 (tile 1 drilled them) up over the spoilboard holes"))
        #expect(html.contains("Line holes 5 and 6 (tile 2 drilled them) and 7 and 8 (tile 3 drilled them) up over"))
        #expect(html.contains("The spoilboard holes in front of the material at "))
        #expect(html.contains("Holes 5 and 6 for tile 4's dowels at"))
        #expect(html.contains(">8</text>"))
    }

    /// A part over a hole's spot: the hole slides along its tile line to clear it, and Checks says so.
    @Test func aPartOverARegistrationSpotMovesTheHole() throws {
        // A button centred where hole 2 (tile 1's second for tile 2, 11 in up the vertical tile line) would go.
        let spot = Vec2(18.inch - 0.375.inch, 11.inch)
        let p = Self.gridSheet { p in
            let button = DesignShape(id: Self.id(20), name: "Button", kind: .circle(radius: 0.75.inch), position: spot)
            p.shapes.append(button)
            p.operations.append(CAMOperation(id: Self.id(21), name: "Cut out button", kind: .profile(ProfileParams(
                side: .outside, depth: DepthSettings(cutDepth: 0.77.inch))), shapeIDs: [button.id], tool: Self.lib.tool(number: 1)!))
        }
        let job = CAMEngine.generate(p)
        #expect(Self.errors(job).isEmpty, "\(Self.errors(job))")
        let warning = job.issues.first { $0.operation == "Registration holes" && $0.severity == .warning }
        #expect(warning?.message.hasPrefix("Registration hole 2 would have been on the design (“Button”), so it's moved") == true)
        let reg = try #require(job.tiling?.layout.registration)
        let moved = try #require(reg.holes.first { $0.number == 2 })
        // Along the tile line, off the button and the cut round it.
        #expect(abs(moved.point.x - spot.x) < 1e-9)
        #expect(moved.point.distance(to: spot) > 0.75.inch + 0.125.inch + 0.25.inch)
        // Tile 4's pair stays where it was, so the spoilboard has one more hole.
        #expect(reg.spoilboard.count == 5)
        #expect(job.tiling?.tiles[0].first?.sourceOperationID == TileSplitter.registrationOperation)
        // The layout drawn before the job is generated still has it where it would go.
        let drawn = try #require(TileLayout(p)?.registration?.holes.first { $0.number == 2 })
        #expect(drawn.point.distance(to: spot) < 1e-9)
    }

    @Test func savedGridJobDecodesAndPostsEachTile() throws {
        let p = try GoldenPostTests.savedProject("tiled-grid-v9") { Self.gridSheet() }
        #expect(p.formatVersion == 9)
        #expect(p == Self.gridSheet())
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        try #require(export.files.count == 4)
        for (k, file) in export.files.enumerated() {
            var post = AvidMach4Post(project: file.project, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let data = post.post(file.toolpaths).data(using: .ascii, allowLossyConversion: true)!
            try GoldenPostTests.check(data, golden: "decoded-tiled-grid-v9-tile-\(k + 1)")
            let text = String(decoding: data, as: UTF8.self)
            #expect(k == 0 || text.contains("(MSG,Tile \(k + 1) of 4: check dowels are in holes"))
            let issues = GCodeCheck.run(text, toolpaths: file.toolpaths, project: file.project, dialect: .avidMach4)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        }
    }

    // MARK: Leads at tile breaks

    /// Every descent into the material, and how far it is from the nearest point on the panel's outline.
    static func descents(_ tps: [Toolpath], outline: Polyline) -> [(point: Vec3, offWall: Double)] {
        var out: [(Vec3, Double)] = []
        for tp in tps {
            tp.forEachMotion { s, m in
                guard m.kind == .feed, m.end.z < s.z - 1e-6, m.end.z < -1e-6, s.xy.distance(to: m.end.xy) < 1e-3 else { return }
                out.append((m.end, outline.closestPoint(to: m.end.xy).distance))
            }
        }
        return out
    }

    @Test func profilesBrokenAtATileLineComeBackOnTheirLeads() throws {
        let p = Self.leadBoard()
        let job = CAMEngine.generate(p)
        #expect(Self.errors(job).isEmpty, "\(Self.errors(job))")
        #expect(!job.issues.contains { $0.message.hasPrefix("There's no room for a lead") })
        let tiles = try #require(job.tiling).tiles
        let outline = try #require(p.shapes.first { $0.name == "Panel" }?.polylines(tolerance: 0.05).first)
        let r = 0.125.inch
        // Each tile comes down only in the waste, off the wall by the tool's radius and more: at the start of a lead.
        for tps in tiles {
            let down = Self.descents(tps, outline: outline)
            #expect(!down.isEmpty)
            let onWall = down.filter { $0.offWall < r + 1 }
            #expect(onWall.isEmpty, "\(onWall.map(\.point))")
        }
        // Near the tile line, the later tile rejoins the cut at every pass, so it comes down
        // there in the waste at least once a pass.
        let seam = try #require(job.tiling?.layout.seamsY.first)
        let near = Self.descents(tiles[1], outline: outline).filter { abs($0.point.y - seam) < 1.inch }
        let passes = DepthSettings(cutDepth: 0.77.inch).passLevels(toolStepdown: Self.lib.tool(number: 1)!.cutting.stepdown,
                                                                    firstPassMinimum: Self.lib.tool(number: 1)!.firstPassMinimum).count
        #expect(near.count >= passes)
        try TilingTests.expectSameResult(p, job)
    }

    @Test func savedLeadJobDecodesAndPostsEachTile() throws {
        let p = try GoldenPostTests.savedProject("tiled-leads-v9") { Self.leadBoard() }
        #expect(p.formatVersion == 9)
        #expect(p == Self.leadBoard())
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        try #require(export.files.count == 2)
        for (k, file) in export.files.enumerated() {
            var post = AvidMach4Post(project: file.project, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let data = post.post(file.toolpaths).data(using: .ascii, allowLossyConversion: true)!
            try GoldenPostTests.check(data, golden: "decoded-tiled-leads-v9-tile-\(k + 1)")
            let text = String(decoding: data, as: UTF8.self)
            let issues = GCodeCheck.run(text, toolpaths: file.toolpaths, project: file.project, dialect: .avidMach4)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        }
    }

    /// A slot only just wider than the bit, cut inside with leads across the tile line: no lead fits where it breaks,
    /// so it comes back in as it would without leads, and Checks notes it.
    @Test func aBreakWithNoRoomForALeadFallsBackToTheRamp() throws {
        let p = TilingTests.longBoard(registration: false) { p in
            let slot = DesignShape(id: Self.id(30), name: "Narrow slot", kind: .rectangle(width: 0.26.inch, height: 20.inch, cornerRadius: 0),
                                   position: Vec2(6.inch, 59.inch))
            p.shapes = [slot]
            p.operations = [CAMOperation(id: Self.id(31), name: "Narrow slot", kind: .profile(ProfileParams(
                side: .inside, depth: DepthSettings(cutDepth: 0.25.inch), entry: EntrySettings(kind: .ramp, rampLength: 1.inch),
                leads: LeadSettings())), shapeIDs: [slot.id], tool: Self.lib.tool(number: 1)!)]
        }
        let job = CAMEngine.generate(p)
        #expect(Self.errors(job).isEmpty, "\(Self.errors(job))")
        let note = job.issues.first { $0.message.hasPrefix("There's no room for a lead") }
        #expect(note?.severity == .info)
        #expect(note?.operation == "Narrow slot")
        #expect(note?.message.contains("ramps back in") == true)
        // It still ramps back in rather than plunging into material: every straight-down descent is into a slot an
        // earlier pass cut that deep.
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
    }

    /// Individual tiles without registration holes drill nothing and don't stop (the feed-through goldens hold the
    /// rest byte for byte).
    @Test func gridTilesWithoutRegistrationNeitherDrillNorStop() throws {
        let p = Self.gridSheet { $0.tiling?.registration = nil }
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.message.hasPrefix("There's no room for a lead") })
        #expect(job.toolpaths.allSatisfy { $0.stopMessage == nil })
        #expect(job.tiling?.layout.registration == nil)
    }
}
