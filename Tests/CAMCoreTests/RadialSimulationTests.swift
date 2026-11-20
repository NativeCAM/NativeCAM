import Foundation
import Testing
@testable import CAMCore

/// R2, wrapped rotary simulation: wrapped toolpaths carve a radial grid (the distance from the axis to the surface
/// all the way round), and their run time follows the post's inverse-time feeds.
struct RadialSimulationTests {
    static let lib = ToolLibrary.starter

    func session(_ p: Project) -> SimulationSession {
        let job = CAMEngine.generate(p)
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates,
                                  cellSize: 0.25, durations: job.estimate?.motionSeconds)
        s.runToEnd()
        return s
    }

    @Test func theRadialGridIsTheUnrolledSheet() throws {
        let p = RotaryWrapTests.job()
        let sim = RadialSimulator(stock: p.stock, cellSize: 0.5)
        let g = sim.grid
        // Rows go once round at the sheet's radius, and every cell starts on the blank's surface.
        #expect(abs(Double(g.rows) * g.cellSize - .pi * 50) < 1e-9 && g.radii.allSatisfy { $0 == 25 })
        #expect(g.row(atAngle: 0) == g.rows / 2 && g.row(atAngle: -.pi + 1e-9) == 0 && g.row(atAngle: 2 * .pi) == g.rows / 2)
        // Laid flat it covers the sheet exactly: row 0 at the bottom edge (the seam), the top line in the middle.
        let flat = g.unrolled
        #expect(abs(flat.origin.y - g.cellSize / 2) < 1e-9 && abs(Double(flat.rows) * flat.cellSize - p.stock.height) < 1e-9)
        #expect(flat.heights.allSatisfy { $0 == 0 } && flat.floorZ == -25)
        // A square bar starts with its corners further out.
        var bar = Stock()
        bar.setRotary(RotaryStock(shape: .squareBar, diameter: 40, length: 100))
        let sq = RadialSimulator(stock: bar, cellSize: 0.5).grid
        #expect(abs(Double(sq.initial[sq.row(atAngle: 0)]) - 20) < 0.05)
        // The corner is sharp, so the nearest row centre falls just short of it.
        #expect(abs(Double(sq.initial[sq.row(atAngle: .pi / 4)]) - 20 * 2.0.squareRoot()) < 0.5)
    }

    /// A ring cut once round at a constant depth with a flat end mill: its volume is known exactly.
    @Test func aRingCutAllTheWayRoundHasTheRightVolume() throws {
        let (p, _) = RotaryWrapTests.rectangle()
        let c = RotaryWrapTests.middle, safe = p.stock.clearanceHeight
        let mill = Self.lib.tool(number: 1)!
        var ring = Toolpath(id: UUID(), name: "Ring", tool: mill, spindleRPM: 18000, start: Vec3(150, c, safe), motions: [
            .rapid(Vec3(150, c, 1)), .feed(Vec3(150, c, -2), 300), .feed(Vec3(150, c + .pi * 50, -2), 1000), .rapid(Vec3(150, c + .pi * 50, safe)),
        ])
        ring.wrapDiameter = 50
        var s = SimulationSession(toolpaths: [ring], stock: p.stock, rapidRate: 5000, cellSize: 0.2)
        s.runToEnd()
        let grid = try #require(s.radialGrid)
        let want = Double.pi * (25 * 25 - 23 * 23) * mill.diameter
        #expect(abs(grid.removedVolume - want) < 0.03 * want, "\(grid.removedVolume) vs \(want)")
        // The floor is 23 mm from the axis all the way round, and the blank outside the cutter is untouched.
        for a in stride(from: -3.0, through: 3.0, by: 0.5) {
            #expect(abs(Double(try #require(grid.radius(at: 150, angle: a))) - 23) < 0.01)
            #expect(try #require(grid.radius(at: 150 + mill.radius + 1, angle: a)) == 25)
        }
        #expect(s.faces.isEmpty && s.faceAngles.isEmpty && s.isWrapped(toolpath: 0))
    }

    /// Acceptance: a simulated rope twist. Three grooves climb round the blank, each 360° per 60 mm pitch along X,
    /// with uncut blank between them, across the seam and on round.
    @Test func aSimulatedRopeTwistHasThreeHelicalGrooves() throws {
        let p = RotaryWrapCutTests.ropeTwist()
        let s = session(p)
        let g = try #require(s.radialGrid)
        guard case let .spiral(spec) = p.shapes[0].kind else { Issue.record("not a spiral"); return }
        // The first start's line crosses the sheet's middle (A0) at the middle of the twist; right hand, so its angle
        // falls as X grows.
        let x0 = p.shapes[0].position.x
        for x in stride(from: x0 - 100, through: x0 + 100, by: 12.5) {
            for k in 0..<3 {
                let groove = -(x - x0) / spec.pitch * 2 * .pi + Double(k) * 2 * .pi / 3
                let bottom = try #require(g.radius(at: x, angle: groove))
                let between = try #require(g.radius(at: x, angle: groove + .pi / 3))
                #expect(bottom < 22.2, "x \(x) start \(k): groove \(bottom)")
                #expect(between > 24.99, "x \(x) start \(k): between grooves \(between)")
            }
        }
        // The 1/4" ball nose leaves a round-bottomed groove 3 mm deep.
        let floor = try #require(g.radius(at: x0, angle: 0))
        #expect(abs(Double(floor) - 22) < 0.05, "\(floor)")
    }

    @Test func theFReadsTheRightWayRoundOnTheGrid() throws {
        let p = RotaryWrapTests.engravedF()
        let g = try #require(session(p).radialGrid)
        // Cells cut by the engraving, as (station, material angle).
        var cut: [(x: Double, a: Double)] = []
        for j in 0..<g.rows {
            for c in 0..<g.columns where g.radii[j * g.columns + c] < 24.5 {
                cut.append((g.originX + Double(c) * g.cellSize, g.angle(row: j)))
            }
        }
        let a0 = try #require(cut.map(\.a).min()), a1 = try #require(cut.map(\.a).max())
        // 30 mm of letter on a 25 mm radius is 1.2 rad, centred on the top line (plus the cutter's width).
        #expect(abs((a0 + a1) / 2) < 0.02 && abs(a1 - a0 - 1.2) < 0.3)
        // The long arm, furthest along X, is at the top of the letter: at the larger angle, which comes under the
        // tool as the blank turns positive, toward +Y at A0.
        let far = try #require(cut.max { $0.x < $1.x })
        #expect(far.a > (a0 + a1) / 2 + 0.3, "\(far)")
    }

    @Test func theBlankTurnsAsAWrappedToolpathCuts() throws {
        let (p, tps) = RotaryWrapTests.rectangle()
        let s = SimulationSession(toolpaths: tps, stock: p.stock, rapidRate: 5000)
        let steps = s.timeline.steps
        // Before cutting it turns to the start's angle, then each move round the blank turns it on.
        let turn = try #require(steps.first { $0.turn != nil })
        #expect(abs((turn.turn?.to ?? 0) + 15 / 25 * 180 / .pi) < 1e-9)
        let around = try #require(steps.first { $0.endAngle.map { $0 > 30 } == true && $0.motion.kind == .feed })
        let mid = around.startTime + around.duration / 2
        #expect(abs((s.blankAngle(at: mid) ?? 99)) < 1e-6)
        // It turns back to A0 at the end, as the post does.
        #expect(s.timeline.steps.last?.turn?.to == 0)
    }

    @Test func runTimeFollowsTheInverseTimeFeeds() throws {
        let (p, tps) = RotaryWrapTests.rectangle()
        let estimate = CycleTimeEstimator.estimate(tps, project: p)
        // The two moves round the blank: 28.8 mm of tip travel each at 1000 mm/min, 1.728 s (a little more for
        // acceleration), not the 30 mm on the sheet.
        let tp = tps[0]
        let around = tp.motions.indices.filter { i in
            i > 0 && tp.motions[i].kind == .feed && abs(tp.motions[i].end.y - tp.motions[i - 1].end.y) > 1
        }
        #expect(around.count == 2)
        for i in around {
            let t = estimate.motionSeconds[0][i]
            #expect(t >= 60 * 28.8 / 1000 - 1e-6 && t < 60 * 28.8 / 1000 * 1.25, "\(t)")
        }
        // A move read back in inverse time takes exactly what its F word says.
        let parsed = try GCodeParser.parse("G21 G90\nG0 X0 Z30 A0\nG93 G1 A360 F10\nG94\n")
        let read = parsed.toolpaths(tools: [Self.lib.tool(number: 1)!], stock: Stock(), fallback: Self.lib.tool(number: 1)!)
        let e = CycleTimeEstimator.estimate(read, project: Project(name: "MDI", displayUnits: .mm, stock: Stock()))
        let turn = try #require(read.first?.motions.firstIndex { $0.inverseTime != nil })
        #expect(abs(e.motionSeconds[0][turn] - 6) < 1e-9, "\(e.motionSeconds)")
    }
}
