import Foundation
import Testing
import simd
@testable import CAMCore

struct EstimatorTests {
    typealias B = CycleTimeEstimator.Block
    func line(_ len: Double, dir: SIMD3<Double> = SIMD3(1, 0, 0), v: Double = 50, a: Double = 1000) -> B {
        B(length: len, vMax: v, accel: a, startDir: dir, endDir: dir, stopBefore: false, stopAfter: false, isRapid: false, ref: nil)
    }

    @Test func trapezoidAndTriangleProfiles() {
        // Long move: cruise plus one accel and one decel ramp (v/a extra).
        #expect(abs(CycleTimeEstimator.trapezoid(length: 1000, v0: 0, v1: 0, vMax: 50, accel: 1000) - 20.05) < 1e-9)
        // Short move never reaches cruise: 2·√(L/a).
        #expect(abs(CycleTimeEstimator.trapezoid(length: 1, v0: 0, v1: 0, vMax: 50, accel: 1000) - 2 * (0.001).squareRoot()) < 1e-9)
    }

    @Test func collinearMovesDontStopAndCornersSlow() {
        let straight = CycleTimeEstimator.plan([line(1000), line(1000)], deviation: 0.05, lookahead: 20).reduce(0, +)
        #expect(abs(straight - (2000 / 50 + 0.05)) < 1e-6)
        let corner = CycleTimeEstimator.plan([line(1000), line(1000, dir: SIMD3(0, 1, 0))], deviation: 0.05, lookahead: 20).reduce(0, +)
        let fullStop = 2 * (1000.0 / 50 + 0.05)
        #expect(corner > straight && corner < fullStop)
        // Junction speed for 90°: v² = a·δ·sin45/(1 − sin45).
        let s = (0.5).squareRoot()
        let vj = (1000 * 0.05 * s / (1 - s)).squareRoot()
        #expect(vj > 10 && vj < 12)
    }

    @Test func lookaheadLimitsSpeedOnTinySegments() {
        // 0.1 mm segments, 20-line window: v ≤ √(2·a·20·0.1) ≈ 63 mm/s at 1000 mm/s² even if 200 mm/s is allowed.
        let blocks = (0..<2000).map { _ in line(0.1, v: 200) }
        let t = CycleTimeEstimator.plan(blocks, deviation: 0.05, lookahead: 20).reduce(0, +)
        let capped = 200.0 / (2 * 1000 * 20 * 0.1).squareRoot()
        #expect(t > 200.0 / 200 * capped * 0.9)
    }

    func project(_ ops: [CAMOperation], shapes: [DesignShape]) -> Project {
        Project(displayUnits: .mm, stock: Stock(width: 200, height: 150, thickness: 20, clearanceHeight: 10, plungeHeight: 2),
                shapes: shapes, operations: ops)
    }

    @Test func jobEstimateIncludesAccelerationAndToolChanges() throws {
        let lib = ToolLibrary.starter
        let rect = DesignShape(kind: .rectangle(width: 80, height: 60, cornerRadius: 0), position: Vec2(100, 75))
        let p1 = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 6))), shapeIDs: [rect.id], tool: lib.tool(number: 1)!)
        let p2 = CAMOperation(kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 3))), shapeIDs: [rect.id], tool: lib.tool(number: 2)!)
        let job = CAMEngine.generate(project([p1, p2], shapes: [rect]))
        let e = try #require(job.estimate)
        #expect(e.total > e.constantVelocity)
        #expect(e.overheadSeconds >= MachineProfile.avidPRO6060.toolChangeTime)
        #expect(e.motionSeconds.count == 2 && e.motionSeconds[0].count == job.toolpaths[0].motions.count)
        #expect(abs(e.toolpathSeconds.reduce(0, +) + e.overheadSeconds - e.total) < e.total * 0.05 + 30)
        // Slower acceleration means a longer job.
        var slow = project([p1, p2], shapes: [rect])
        slow.machine.accelerationXY = 5.inch
        #expect(try #require(CAMEngine.generate(slow).estimate).total > e.total)
    }

    @Test func arcsAreLimitedByCentripetalAcceleration() throws {
        // A 5 mm radius circle at 10 m/min: √(a·R) = √(1270·5) ≈ 80 mm/s caps the 167 mm/s feed.
        let c = Vec2(50, 50)
        let start = Vec3(55, 50, -1)
        let tp = Toolpath(id: UUID(), name: "circle", tool: ToolLibrary.starter.tool(number: 1)!, spindleRPM: 18000, start: Vec3(55, 50, 5),
                          motions: [.feed(start, 500),
                                    Motion(kind: .arcCCW, end: Vec3(45, 50, -1), center: c, feed: 10000),
                                    Motion(kind: .arcCCW, end: start, center: c, feed: 10000)])
        var p = project([], shapes: [])
        p.machine.accelerationXY = 1270
        let e = CycleTimeEstimator.estimate([tp], project: p)
        let arcTime = e.motionSeconds[0][1] + e.motionSeconds[0][2]
        let cap = (1270.0 * 5).squareRoot()
        #expect(arcTime >= 2 * .pi * 5 / cap * 0.99)
    }
}
