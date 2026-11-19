import Foundation
import Testing
@testable import CAMCore

/// Helpers shared by toolpath tests.
enum Fixture {
    static let lib = ToolLibrary.starter
    static var endMill: Tool { lib.tool(number: 1)! }   // 1/4" flat
    static var vBit90: Tool { lib.tool(number: 6)! }
    static var stock: Stock { Stock(width: 200, height: 150, thickness: 20, clearanceHeight: 10, plungeHeight: 2) }

    static func project(shapes: [DesignShape], ops: [CAMOperation], stock: Stock = stock) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputArcs = false
        return Project(name: "Test", displayUnits: .mm, stock: stock, machine: machine, shapes: shapes, operations: ops)
    }

    static func rect(_ w: Double, _ h: Double, at c: Vec2) -> DesignShape {
        DesignShape(kind: .rectangle(width: w, height: h, cornerRadius: 0), position: c)
    }

    /// XY points of the feed moves at a given Z.
    static func pointsAt(z: Double, _ tp: Toolpath) -> [Vec2] {
        tp.motions.filter { $0.kind != .rapid && abs($0.end.z - z) < 1e-6 }.map(\.end.xy)
    }

    static func simulate(_ tps: [Toolpath], stock: Stock, cell: Double = 0.25) -> HeightGrid {
        var s = SimulationSession(toolpaths: tps, stock: stock, rapidRate: 10000, cellSize: cell)
        s.runToEnd()
        return s.grid
    }
}

struct ProfileTests {
    @Test func outsideProfileClimbsClockwiseAroundPart() throws {
        let shape = Fixture.rect(100, 50, at: Vec2(100, 75))
        let op = CAMOperation(kind: .profile(ProfileParams(side: .outside, direction: .climb, depth: DepthSettings(cutDepth: 12, passDepth: 4))),
                           shapeIDs: [shape.id], tool: Fixture.endMill)
        let job = CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op]))
        let tp = try #require(job.toolpaths.first)
        let r = Fixture.endMill.radius
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.min.x - (50 - r)) < 0.01)
        #expect(abs(ext.max.x - (150 + r)) < 0.01)
        #expect(abs(ext.min.z + 12) < 1e-9)
        // Three passes at -4, -8, -12.
        for z in [-4.0, -8.0, -12.0] { #expect(Fixture.pointsAt(z: z, tp).count > 4, "pass at \(z)") }
        // Clockwise path at the final depth.
        let loop = Polyline(Fixture.pointsAt(z: -12, tp), closed: true)
        #expect(loop.signedArea < 0)
        // Never cuts the part itself: every cutting point is at least r outside the rectangle.
        let part = Polyline([Vec2(50, 50), Vec2(150, 50), Vec2(150, 100), Vec2(50, 100)], closed: true)
        for m in tp.motions where m.kind == .feed && m.end.z < 0 {
            #expect(part.closestPoint(to: m.end.xy).distance >= r - 0.01)
        }
    }

    @Test func insideProfileClimbsCounterClockwise() throws {
        let shape = Fixture.rect(60, 40, at: Vec2(100, 75))
        let op = CAMOperation(kind: .profile(ProfileParams(side: .inside, direction: .climb, depth: DepthSettings(cutDepth: 5))),
                           shapeIDs: [shape.id], tool: Fixture.endMill)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op])).toolpaths.first)
        let loop = Polyline(Fixture.pointsAt(z: -5, tp), closed: true)
        #expect(loop.signedArea > 0)
        let b = loop.bounds
        #expect(abs(b.min.x - (70 + Fixture.endMill.radius)) < 0.01)
    }

    @Test func conventionalReversesDirection() throws {
        let shape = Fixture.rect(60, 40, at: Vec2(100, 75))
        let op = CAMOperation(kind: .profile(ProfileParams(side: .outside, direction: .conventional, depth: DepthSettings(cutDepth: 3))),
                           shapeIDs: [shape.id], tool: Fixture.endMill)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op])).toolpaths.first)
        #expect(Polyline(Fixture.pointsAt(z: -3, tp), closed: true).signedArea > 0)
    }

    @Test func holesAreCutBeforeTheOutsideOfAPart() throws {
        let outer = Fixture.rect(120, 80, at: Vec2(100, 75))
        let hole = DesignShape(kind: .circle(radius: 15), position: Vec2(100, 75))
        let op = CAMOperation(kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 20.5))),
                           shapeIDs: [outer.id, hole.id], tool: Fixture.endMill)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [outer, hole], ops: [op])).toolpaths.first)
        // The first cutting move must be in the hole (near the centre), not on the outer contour.
        let firstCut = try #require(tp.motions.first { $0.kind == .feed && $0.end.z < 0 })
        #expect(firstCut.end.xy.distance(to: Vec2(100, 75)) < 15)
        // Hole contour is offset into the hole (part = ring between them).
        let deep = Fixture.pointsAt(z: -20.5, tp).filter { $0.distance(to: Vec2(100, 75)) < 30 }
        for p in deep { #expect(abs(p.distance(to: Vec2(100, 75)) - (15 - Fixture.endMill.radius)) < 0.02) }
    }

    @Test func tabsLeaveMaterialAtTabHeight() throws {
        let shape = Fixture.rect(100, 60, at: Vec2(100, 75))
        let tabs = TabSettings(enabled: true, count: 4, width: 8, thickness: 3)
        let op = CAMOperation(kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 20, passDepth: 5), tabs: tabs)),
                           shapeIDs: [shape.id], tool: Fixture.endMill)
        let stock = Fixture.stock
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op])).toolpaths.first)
        let tabZ = -20 + 3.0
        #expect(tp.motions.contains { $0.kind == .feed && abs($0.end.z - tabZ) < 1e-6 })
        // Simulate: the slot is cut through except 4 bridges of material left at the tab height.
        let grid = Fixture.simulate([tp], stock: stock, cell: 0.5)
        let r = Fixture.endMill.radius
        // Sample around the slot centre line; count runs of cells at tab height.
        let walker = LoopWalker(Polyline([Vec2(50 - r, 45 - r), Vec2(150 + r, 45 - r), Vec2(150 + r, 105 + r), Vec2(50 - r, 105 + r)], closed: true))
        var inTab = false, bridges = 0, through = 0
        var s = 0.0
        while s < walker.length {
            guard let h = grid.height(at: walker.point(at: s)) else { s += 0.5; continue }
            let isTab = abs(Double(h) - tabZ) < 0.2
            if isTab && !inTab { bridges += 1 }
            if h <= grid.floorZ + 1e-3 { through += 1 }
            inTab = isTab
            s += 0.5
        }
        #expect(bridges == 4)
        #expect(through > 500)
    }

    @Test func rampEntryHasNoVerticalPlungesIntoMaterialAfterTheFirst() throws {
        let shape = Fixture.rect(100, 60, at: Vec2(100, 75))
        let op = CAMOperation(kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 12, passDepth: 4),
                                                        entry: EntrySettings(kind: .ramp, rampLength: 30))),
                           shapeIDs: [shape.id], tool: Fixture.endMill)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op])).toolpaths.first)
        var vertical = 0
        tp.forEachMotion { s, m in
            if m.kind == .feed && m.end.z < s.z - 1e-6 && s.z < -1e-6 && s.xy.distance(to: m.end.xy) < 1e-6 { vertical += 1 }
        }
        #expect(vertical == 0)
    }

    @Test func rampedCutOutIsThroughAllTheWayAround() throws {
        // Long straight edges are where a missing ramp-end vertex would leave material behind.
        let shape = Fixture.rect(180, 120, at: Vec2(100, 75))
        var stock = Fixture.stock
        stock.width = 220; stock.height = 160
        let op = CAMOperation(kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 20.5, passDepth: 3),
                                                           entry: EntrySettings(kind: .ramp, rampLength: 40))),
                              shapeIDs: [shape.id], tool: Fixture.endMill)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op], stock: stock)).toolpaths.first)
        let grid = Fixture.simulate([tp], stock: stock, cell: 0.5)
        let r = Fixture.endMill.radius
        let path = LoopWalker(Polyline([Vec2(10 - r, 15 - r), Vec2(190 + r, 15 - r), Vec2(190 + r, 135 + r), Vec2(10 - r, 135 + r)], closed: true))
        var notThrough = 0
        var s = 0.0
        while s < path.length {
            if let h = grid.height(at: path.point(at: s)), h > grid.floorZ + 1e-3 { notThrough += 1 }
            s += 1
        }
        #expect(notThrough == 0)
    }
}

struct PocketTests {
    func checkPocket(strategy: PocketStrategy) throws {
        let pocket = Fixture.rect(80, 50, at: Vec2(100, 75))
        let island = DesignShape(kind: .circle(radius: 8), position: Vec2(100, 75))
        let op = CAMOperation(kind: .pocket(PocketParams(strategy: strategy, depth: DepthSettings(cutDepth: 6, passDepth: 3))),
                           shapeIDs: [pocket.id, island.id], tool: Fixture.endMill)
        let project = Fixture.project(shapes: [pocket, island], ops: [op])
        let job = CAMEngine.generate(project)
        #expect(!job.hasErrors)
        let tp = try #require(job.toolpaths.first)
        let grid = Fixture.simulate([tp], stock: project.stock, cell: 0.5)
        let r = Fixture.endMill.radius
        var uncut = 0, gouged = 0, total = 0
        for row in 0..<grid.rows {
            for col in 0..<grid.columns {
                let p = Vec2(grid.origin.x + Double(col) * grid.cellSize, grid.origin.y + Double(row) * grid.cellSize)
                let h = Double(grid.heights[grid.index(col, row)])
                let inPocket = abs(p.x - 100) < 40 && abs(p.y - 75) < 25
                let dIsland = p.distance(to: Vec2(100, 75))
                if inPocket && dIsland > 8 {
                    // Interior cells away from the sharp outer corners (an end mill can't reach them) must be at depth.
                    let nearCorner = abs(abs(p.x - 100) - 40) < r && abs(abs(p.y - 75) - 25) < r
                    if !nearCorner {
                        total += 1
                        if h > -6 + 0.01 { uncut += 1 }
                    }
                }
                // Outside the pocket or on the island: untouched (allow half a cell of rasterisation slop).
                let outside = abs(p.x - 100) > 40 + grid.cellSize || abs(p.y - 75) > 25 + grid.cellSize
                if (outside || dIsland < 8 - grid.cellSize) && h < -1e-6 { gouged += 1 }
            }
        }
        #expect(total > 10_000)
        #expect(uncut == 0, "\(uncut) uncut cells (\(strategy))")
        #expect(gouged == 0, "\(gouged) gouged cells (\(strategy))")
    }

    @Test func offsetPocketClearsAroundIsland() throws { try checkPocket(strategy: .offset) }
    @Test func rasterPocketClearsAroundIsland() throws { try checkPocket(strategy: .raster) }

    @Test func toolTooBigWarns() throws {
        let tiny = Fixture.rect(4, 4, at: Vec2(100, 75))
        let op = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 2))), shapeIDs: [tiny.id], tool: Fixture.endMill)
        let job = CAMEngine.generate(Fixture.project(shapes: [tiny], ops: [op]))
        #expect(job.issues.contains { $0.message.contains("too large") })
    }
}

struct DrillTests {
    @Test func peckDrillingReachesDepthInIncrements() throws {
        let holes = [Vec2(20, 20), Vec2(180, 20), Vec2(100, 130)].map { DesignShape(kind: .circle(radius: 3), position: $0) }
        let op = CAMOperation(kind: .drill(DrillParams(depth: 10, peckDepth: 3, fullRetract: true, dwell: 0.5)),
                           shapeIDs: holes.map(\.id), tool: Fixture.endMill)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: holes, ops: [op])).toolpaths.first)
        let bottoms = tp.motions.filter { $0.kind == .feed && abs($0.end.z + 10) < 1e-9 }
        #expect(bottoms.count == 3)
        let pecks = tp.motions.filter { $0.kind == .feed && $0.end.z < 0 }
        #expect(pecks.count == 3 * 4) // 3, 6, 9, 10
        #expect(tp.motions.filter { $0.kind == .dwell }.count == 3)
        // Every peck feeds straight down.
        tp.forEachMotion { s, m in if m.kind == .feed { #expect(s.xy.distance(to: m.end.xy) < 1e-9) } }
    }
}

struct VCarveTests {
    @Test func rectangleCarvesTo45DegreeWalls() throws {
        let shape = Fixture.rect(30, 12, at: Vec2(100, 75))
        let op = CAMOperation(kind: .vcarve(VCarveParams(sampleSpacing: 0.2)), shapeIDs: [shape.id], tool: Fixture.vBit90)
        let project = Fixture.project(shapes: [shape], ops: [op])
        let tp = try #require(CAMEngine.generate(project).toolpaths.first)
        let ext = try #require(tp.cuttingExtents)
        // Inscribed radius of a 30 x 12 rectangle is 6 → 90° bit depth 6 mm.
        #expect(abs(ext.min.z + 6) < 0.05)
        let grid = Fixture.simulate([tp], stock: project.stock, cell: 0.2)
        // With a 90° bit the carved depth equals the distance to the nearest edge.
        var worst = 0.0
        for p in [Vec2(100, 75), Vec2(90, 72), Vec2(110, 78), Vec2(87, 75), Vec2(100, 70.5), Vec2(114, 75)] {
            let d = min(15 - abs(p.x - 100), 6 - abs(p.y - 75))
            let h = Double(try #require(grid.height(at: p)))
            worst = max(worst, abs(h + d))
        }
        #expect(worst < 0.25, "max depth error \(worst) mm")
        // Nothing outside the rectangle is touched.
        #expect(try #require(grid.height(at: Vec2(100, 75 + 6.5))) == 0)
        #expect(try #require(grid.height(at: Vec2(115.5, 75))) == 0)
    }

    @Test func flatDepthCapsTheCarve() throws {
        let shape = Fixture.rect(40, 30, at: Vec2(100, 75))
        let op = CAMOperation(kind: .vcarve(VCarveParams(flatDepth: 3)), shapeIDs: [shape.id], tool: Fixture.vBit90)
        let tp = try #require(CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op])).toolpaths.first)
        #expect(abs(try #require(tp.cuttingExtents).min.z + 3) < 1e-6)
    }

    @Test func flatClearingAddsASecondToolpath() throws {
        let shape = Fixture.rect(40, 30, at: Vec2(100, 75))
        let op = CAMOperation(kind: .vcarve(VCarveParams(flatDepth: 3, clearanceTool: Fixture.endMill)), shapeIDs: [shape.id], tool: Fixture.vBit90)
        let tps = CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op])).toolpaths
        #expect(tps.count == 2)
        #expect(tps[0].tool.number == Fixture.endMill.number)
        #expect(tps[1].tool.number == Fixture.vBit90.number)
    }
}

struct ArcFitTests {
    @Test func circleBecomesAFewArcsWithinTolerance() {
        let pts = Curves.circle(center: Vec2(50, 50), radius: 20, tolerance: 0.002)
        let motions = (pts + [pts[0]]).dropFirst().map { Motion.feed(Vec3($0, -1), 1000) }
        let tp = Toolpath(id: UUID(), name: "c", tool: Fixture.endMill, spindleRPM: 18000, start: Vec3(pts[0], -1), motions: Array(motions))
        let fitted = ArcFitter.fit(tp, tolerance: 0.01)
        let arcs = fitted.motions.filter { $0.kind.isArc }
        // Greedy fitting gives two arcs just under 180° (Mach4's limit) plus at most a tiny closing move.
        #expect(arcs.count >= 2 && arcs.count <= 4)
        #expect(fitted.motions.count <= 4)
        fitted.forEachMotion { s, m in
            guard m.kind.isArc else { return }
            #expect(abs(m.center.distance(to: Vec2(50, 50))) < 0.01)
            #expect(abs(m.arcSweep(from: s)) < .pi)
            #expect(m.kind == .arcCCW)
        }
        #expect(abs(fitted.cuttingLength - 2 * .pi * 20) < 0.05)
    }

    @Test func helicalRampFitsAsHelicalArcs() {
        var pts: [Vec3] = []
        for i in 0...200 {
            let a = Double(i) / 200 * 2 * .pi
            pts.append(Vec3(Vec2(10, 10) + Vec2.fromAngle(-a, length: 5), -Double(i) / 200 * 3))
        }
        let tp = Toolpath(id: UUID(), name: "h", tool: Fixture.endMill, spindleRPM: 18000, start: pts[0],
                          motions: pts.dropFirst().map { .feed($0, 500) })
        let fitted = ArcFitter.fit(tp, tolerance: 0.01)
        #expect(fitted.motions.filter { $0.kind != .arcCW }.count <= 1)
        #expect(fitted.motions.count <= 4)
        #expect(abs(fitted.motions.last!.end.z + 3) < 1e-9)
    }

    @Test func straightLinesMerge() {
        let motions = (1...50).map { Motion.feed(Vec3(Double($0), 0, -1), 1000) }
        let tp = Toolpath(id: UUID(), name: "l", tool: Fixture.endMill, spindleRPM: 1, start: Vec3(0, 0, -1), motions: motions)
        #expect(ArcFitter.fit(tp, tolerance: 0.01).motions.count == 1)
    }
}

struct ValidationTests {
    @Test func flagsDepthBeyondFluteAndThroughCuts() throws {
        let shape = Fixture.rect(50, 50, at: Vec2(100, 75))
        let deep = CAMOperation(kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 30))),
                             shapeIDs: [shape.id], tool: Fixture.endMill) // flute 1" = 25.4 mm, stock 20 mm
        let job = CAMEngine.generate(Fixture.project(shapes: [shape], ops: [deep]))
        #expect(job.issues.contains { $0.message.contains("cutting length") })
        #expect(job.issues.contains { $0.message.contains("spoilboard") })
    }

    @Test func detectsSidewaysRapidBelowSurface() {
        let tp = Toolpath(id: UUID(), name: "bad", tool: Fixture.endMill, spindleRPM: 18000, start: Vec3(0, 0, 5),
                          motions: [.rapid(Vec3(10, 10, -2)), .feed(Vec3(20, 10, -2), 100)])
        let op = CAMOperation(kind: .drill(DrillParams(depth: 1)), shapeIDs: [], tool: Fixture.endMill)
        let issues = CAMEngine.validate(tp, operation: op, project: Fixture.project(shapes: [], ops: []))
        #expect(issues.contains { $0.severity == .error && $0.message.contains("rapid") })
    }
}
