import Foundation
import Testing
@testable import CAMCore

struct SmoothingTests {
    @Test func interpolatedContoursFollowASlopeWithoutStairSteps() {
        // A plane tilted 30° to the grid: the level-0 line is straight, so the contour should be too.
        let cols = 60, rows = 60, cell = 1.0
        let n = Vec2(cos(.pi / 6), sin(.pi / 6))
        var field = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows { for c in 0..<cols { field[r * cols + c] = Float(Vec2(Double(c), Double(r)).dot(n) - 30) } }
        let mask = field.map { $0 <= 0 }
        let stairs = GridContours.loops(mask: mask, columns: cols, rows: rows, origin: .zero, cellSize: cell)
        let smooth = GridContours.loops(mask: mask, columns: cols, rows: rows, origin: .zero, cellSize: cell, field: field, level: 0)
        func onLine(_ loops: [Polyline]) -> Double {
            // Largest distance from the true line among points well inside the grid.
            loops.flatMap(\.points).filter { $0.x > 2 && $0.y > 2 && $0.x < 57 && $0.y < 57 }.map { abs($0.dot(n) - 30) }.max() ?? .infinity
        }
        #expect(onLine(stairs) > 0.3)
        #expect(onLine(smooth) < 0.01)
    }

    @Test func interpolationIsLimitedOnSteepSteps() {
        // A cliff between two cells: linear interpolation would put the edge almost on the low cell; it may move
        // at most a quarter cell from the midpoint.
        let cols = 10, rows = 10
        var field = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows { for c in 0..<cols { field[r * cols + c] = c < 5 ? -10 : 1000 } }
        let mask = field.map { $0 <= -9.9 }
        let loops = GridContours.loops(mask: mask, columns: cols, rows: rows, origin: .zero, cellSize: 1, field: field, level: -9.9)
        let xs = loops.flatMap(\.points).map(\.x)
        #expect(xs.contains { abs($0 - 4.25) < 1e-9 })
        // The cliff edge moved a quarter cell (not to the low cell); border corners sit at x = 4.
        #expect(xs.filter { $0 > 3 }.allSatisfy { $0 >= 4 - 1e-9 && $0 <= 4.25 + 1e-9 })
    }

    @Test func filletsRoundConvexCornersInsideTheLoopOnly() {
        let square = Polyline([Vec2(0, 0), Vec2(50, 0), Vec2(50, 50), Vec2(0, 50)], closed: true) // CCW: all left turns
        let e = 0.25
        let f = square.filletingConvexCorners(deviation: e)
        #expect(f.count > square.count)
        // Shrink-only: everything stays inside the square, and each corner is cut off by exactly the budget.
        #expect(f.points.allSatisfy { $0.x >= -1e-9 && $0.y >= -1e-9 && $0.x <= 50 + 1e-9 && $0.y <= 50 + 1e-9 })
        let cornerGap = f.points.map { $0.distance(to: Vec2(50, 50)) }.min()!
        #expect(cornerGap >= e - 1e-6 && cornerGap < e + 0.02)
        // The same square as a hole (clockwise) has only right turns: nothing moves outward into the region.
        #expect(square.reversed.filletingConvexCorners(deviation: e).points == square.reversed.points)
        // Corners whose neighbours are too short to beat the planner's own rounding are left alone.
        let tiny = Polyline([Vec2(0, 0), Vec2(0.3, 0), Vec2(0.3, 0.3), Vec2(0, 0.3)], closed: true)
        #expect(tiny.filletingConvexCorners(deviation: e, plannerDeviation: 0.05).points == tiny.points)
    }

    @Test func pocketInnerRingsAreRoundedButWallsStayExact() throws {
        let pocket = Fixture.rect(80, 50, at: Vec2(100, 75))
        let op = CAMOperation(kind: .pocket(PocketParams(strategy: .offset, depth: DepthSettings(cutDepth: 6, passDepth: 6))),
                              shapeIDs: [pocket.id], tool: Fixture.endMill)
        var project = Fixture.project(shapes: [pocket], ops: [op])
        let smoothJob = CAMEngine.generate(project)
        project.machine.roughingSmoothing = 0
        let sharpJob = CAMEngine.generate(project)
        let smooth = try #require(smoothJob.toolpaths.first), sharp = try #require(sharpJob.toolpaths.first)
        // The wall ring still reaches each corner exactly.
        let r = Fixture.endMill.radius
        let corner = Vec2(100 + 40 - r, 75 + 25 - r)
        #expect(Fixture.pointsAt(z: -6, smooth).contains { $0.distance(to: corner) < 1e-3 })
        // Inner rings gained fillets and the job got no slower.
        #expect(smooth.motions.count > sharp.motions.count)
        let smoothTime = try #require(smoothJob.estimate).total, sharpTime = try #require(sharpJob.estimate).total
        #expect(smoothTime <= sharpTime + 1e-6)
    }

    @Test func contoursComeOutInAFixedOrder() {
        // Three blobs: each loop starts at its lowest-then-leftmost point and loops are listed in that order, so the
        // same project always posts the same G-code (a dictionary's iteration order changes between runs).
        let cols = 30, rows = 20
        var mask = [Bool](repeating: false, count: cols * rows)
        for (c0, r0) in [(20, 3), (3, 10), (12, 2)] {
            for r in r0..<(r0 + 4) { for c in c0..<(c0 + 5) { mask[r * cols + c] = true } }
        }
        let loops = GridContours.loops(mask: mask, columns: cols, rows: rows, origin: .zero, cellSize: 1)
        #expect(loops.count == 3)
        func key(_ p: Vec2) -> (Double, Double) { (p.y, p.x) }
        for loop in loops {
            let first = loop.points[0]
            #expect(loop.points.allSatisfy { key(first) <= key($0) })
        }
        #expect(zip(loops, loops.dropFirst()).allSatisfy { key($0.0.points[0]) < key($0.1.points[0]) })
    }
}
