import Foundation
import Testing
import simd
@testable import CAMCore

/// Hemisphere of radius `radius` resting on z = 0 (Z up), closed with a base disk.
func hemisphereMesh(radius R: Float = 30, rings: Int = 48, segments: Int = 96) -> MeshModel {
    var pos: [Float] = []
    var idx: [UInt32] = []
    func add(_ v: SIMD3<Float>) -> UInt32 { pos += [v.x, v.y, v.z]; return UInt32(pos.count / 3 - 1) }
    var grid: [[UInt32]] = []
    for i in 0...rings {
        let lat = Float(i) / Float(rings) * .pi / 2 // 0 = equator, pi/2 = top
        var ring: [UInt32] = []
        let count = i == rings ? 1 : segments
        for j in 0..<count {
            let lon = Float(j) / Float(segments) * 2 * .pi
            ring.append(add(SIMD3(R * cos(lat) * cos(lon), R * cos(lat) * sin(lon), R * sin(lat))))
        }
        grid.append(ring)
    }
    for i in 0..<rings {
        for j in 0..<segments {
            let a = grid[i][j], b = grid[i][(j + 1) % segments]
            if i + 1 == rings {
                idx += [a, b, grid[rings][0]]
            } else {
                let c = grid[i + 1][(j + 1) % segments], d = grid[i + 1][j]
                idx += [a, b, c, a, c, d]
            }
        }
    }
    let center = add(.zero)
    for j in 0..<segments { idx += [center, grid[0][(j + 1) % segments], grid[0][j]] }
    return MeshModel(name: "Hemisphere", positions: pos, indices: idx)
}

enum Model3DFixture {
    static let R = 30.0
    static var stock: Stock { Stock(width: 200, height: 150, thickness: 40, clearanceHeight: 10, plungeHeight: 2) }
    static let center = Vec2(100, 75)

    static func shape(depth: Double = 30, topOffset: Double = 0) -> DesignShape {
        DesignShape(name: "Dome", kind: .model(ModelSpec(mesh: hemisphereMesh(), depth: depth, topOffset: topOffset)), position: center)
    }

    /// Exact model surface (design Z) at p, or nil outside the dome.
    static func modelZ(_ p: Vec2, depth: Double = 30, topOffset: Double = 0) -> Double? {
        let r = p.distance(to: center)
        guard r <= R else { return nil }
        return -topOffset - (R - (R * R - r * r).squareRoot()) * depth / R
    }

    static func project(_ shape: DesignShape, ops: [CAMOperation]) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputArcs = false
        return Project(name: "3D", displayUnits: .mm, stock: stock, machine: machine, shapes: [shape], operations: ops)
    }
}

struct Model3DTests {
    @Test func orientationMapsChosenAxisToZ() {
        #expect(ModelGeometry.orient(SIMD3(1, 2, 3), up: .z, flipped: false) == SIMD3(1, 2, 3))
        #expect(ModelGeometry.orient(SIMD3(0, 10, 0), up: .y, flipped: false) == SIMD3(0, 0, 10))
        #expect(ModelGeometry.orient(SIMD3(10, 0, 0), up: .x, flipped: false) == SIMD3(0, 0, 10))
        #expect(ModelGeometry.orient(SIMD3(0, 0, 10), up: .z, flipped: true) == SIMD3(0, 0, -10))
    }

    @Test func orientedSizeAndSilhouette() throws {
        let spec = ModelSpec(mesh: hemisphereMesh(), depth: 30)
        let o = spec.oriented
        #expect(abs(o.size.x - 60) < 0.01 && abs(o.size.y - 60) < 0.01 && abs(o.size.z - 30) < 0.01)
        #expect(o.silhouette.count == 1)
        let area = try #require(o.silhouette.first).area
        #expect(abs(area - .pi * 900) / (.pi * 900) < 0.015, "silhouette area \(area)")
        // The design shape's outline is the silhouette placed at the shape position.
        let b = Model3DFixture.shape().bounds
        #expect(abs(b.center.x - 100) < 0.2 && abs(b.width - 60) < 0.5)
    }

    @Test func heightGridMatchesTheModel() {
        let shape = Model3DFixture.shape()
        let area = Rect2(x: 60, y: 35, width: 80, height: 80)
        let g = ModelRaster.surface(of: [shape], over: area, cellSize: 0.5)
        var worst = 0.0
        for p in [Vec2(100, 75), Vec2(115, 75), Vec2(100, 95), Vec2(80, 60), Vec2(124, 80)] {
            let expected = Model3DFixture.modelZ(p)!
            let got = Double(g.height(at: p) ?? 99)
            worst = max(worst, abs(got - expected))
        }
        #expect(worst < 0.12, "max height error \(worst)")
        #expect(g.height(at: Vec2(100, 75 + 31)) == nil)
        // Contours of the footprint come back counter-clockwise.
        let loops = GridContours.loops(mask: g.covered, columns: g.columns, rows: g.rows, origin: g.origin, cellSize: g.cellSize)
        #expect(loops.count == 1 && loops[0].isCounterClockwise)
    }

    @Test func depthAndTopOffsetScaleZ() {
        let shape = Model3DFixture.shape(depth: 12, topOffset: 3)
        let g = ModelRaster.surface(of: [shape], over: Rect2(x: 60, y: 35, width: 80, height: 80), cellSize: 0.5)
        #expect(abs(Double(g.height(at: Model3DFixture.center)!) + 3) < 0.05)
        let p = Vec2(115, 75)
        #expect(abs(Double(g.height(at: p)!) - Model3DFixture.modelZ(p, depth: 12, topOffset: 3)!) < 0.08)
    }

    @Test func projectWithModelRoundTrips() throws {
        let p = Model3DFixture.project(Model3DFixture.shape(), ops: [])
        let data = try p.encoded()
        let back = try Project.decode(data)
        let a = try #require(p.shapes[0].modelSpec), b = try #require(back.shapes[0].modelSpec)
        #expect(a.mesh.positions == b.mesh.positions && a.mesh.indices == b.mesh.indices)
        #expect(back == p)
    }

    func simulate(_ tp: Toolpath, cell: Double) -> HeightGrid {
        var s = SimulationSession(toolpaths: [tp], stock: Model3DFixture.stock, rapidRate: 10000, cellSize: cell)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        return s.grid
    }

    @Test func roughingNeverCutsIntoTheModelAndClearsToWithinALayer() throws {
        let allowance = 0.5
        let tool = ToolLibrary.starter.tool(number: 1)! // 1/4" flat, stepdown 0.125"
        let op = CAMOperation(kind: .rough3D(Rough3DParams(allowance: allowance)), shapeIDs: [], tool: tool)
        var shape = Model3DFixture.shape()
        shape.id = UUID()
        var o = op
        o.shapeIDs = [shape.id]
        let job = CAMEngine.generate(Model3DFixture.project(shape, ops: [o]))
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        let grid = simulate(tp, cell: 0.5)
        var gouge = 0.0, leftover = 0.0, outsideTouched = 0
        for r in 0..<grid.rows {
            for c in 0..<grid.columns {
                let p = Vec2(grid.origin.x + Double(c) * grid.cellSize, grid.origin.y + Double(r) * grid.cellSize)
                let h = Double(grid.heights[grid.index(c, r)])
                let d = p.distance(to: Model3DFixture.center)
                if let m = Model3DFixture.modelZ(p) {
                    // The allowance can't reach above the material top.
                    gouge = max(gouge, min(0, m + allowance) - h)
                    if d < 22 { leftover = max(leftover, h - (m + allowance)) }
                } else if d > Model3DFixture.R + 0.75, h < -1e-6 {
                    outsideTouched += 1
                }
            }
        }
        #expect(gouge < 0.3, "cut \(gouge) mm into the allowance")
        // Terraces: at most one layer plus the safety margin on the slope.
        #expect(leftover < tool.cutting.stepdown + 1.0, "left \(leftover) mm above the allowance")
        #expect(outsideTouched == 0)
    }

    @Test func finishingFollowsTheSurfaceWithoutGouging() throws {
        let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose
        var shape = Model3DFixture.shape()
        shape.id = UUID()
        let op = CAMOperation(kind: .finish3D(Finish3DParams(stepoverFraction: 0.1)), shapeIDs: [shape.id], tool: ball)
        let job = CAMEngine.generate(Model3DFixture.project(shape, ops: [op]))
        let tp = try #require(job.toolpaths.first)
        let grid = simulate(tp, cell: 0.25)
        var gouge = 0.0, error = 0.0
        var worstAt = Vec2.zero
        for r in 0..<grid.rows {
            for c in 0..<grid.columns {
                let p = Vec2(grid.origin.x + Double(c) * grid.cellSize, grid.origin.y + Double(r) * grid.cellSize)
                guard let m = Model3DFixture.modelZ(p) else { continue }
                let h = Double(grid.heights[grid.index(c, r)])
                if m - h > gouge { gouge = m - h; worstAt = p }
                if p.distance(to: Model3DFixture.center) < 22 { error = max(error, h - m) }
            }
        }
        #expect(gouge < 0.08, "gouged \(gouge) mm at \(worstAt), r = \(worstAt.distance(to: Model3DFixture.center))")
        #expect(error < 0.25, "surface error \(error) mm")
    }

    @Test func wholeMaterialBoundaryCutsAroundTheModelToItsBase() throws {
        let tool = ToolLibrary.starter.tool(number: 1)!
        var shape = Model3DFixture.shape(depth: 10)
        shape.id = UUID()
        let op = CAMOperation(kind: .rough3D(Rough3DParams(allowance: 0.5, boundary: .material)), shapeIDs: [shape.id], tool: tool)
        let tp = try #require(CAMEngine.generate(Model3DFixture.project(shape, ops: [op])).toolpaths.first)
        let grid = simulate(tp, cell: 1)
        let h = Double(try #require(grid.height(at: Vec2(30, 30))))
        #expect(abs(h - (-10 + 0.5)) < 0.3, "outside height \(h)")
    }

    @Test func vectorShapesAreIgnoredWithAWarning() {
        let rect = DesignShape(kind: .rectangle(width: 10, height: 10, cornerRadius: 0), position: Vec2(20, 20))
        let op = CAMOperation(kind: .finish3D(Finish3DParams()), shapeIDs: [rect.id], tool: ToolLibrary.starter.tool(number: 7)!)
        let job = CAMEngine.generate(Project(stock: Model3DFixture.stock, shapes: [rect], operations: [op]))
        #expect(job.issues.contains { $0.message.contains("3D model") })
    }
}
