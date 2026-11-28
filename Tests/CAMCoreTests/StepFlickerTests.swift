import Foundation
import Testing
@testable import CAMCore

/// 3D finishing passes that run along a step in the CL surface (#208). A bit's radius from the top edge of a vertical
/// wall, which side of the step the tool goes on turns on a micron: the material round a model is a grid of points, so
/// a ball a hair inside that radius of a wall of it catches each point and drops between them. A pass there sawed up
/// and down the wall every grid cell. The website's 12 × 10 in picture frames (`Fixtures/step-flicker`, listed in its
/// README) have their edges on the finishing grid since #205 made their outline exact, which put constant-scallop
/// passes on that knife edge along two rails of the flipped frame: 612 plunges down its 1/2 in wall, and its finish
/// 25% slower than before #205. Now such a stretch is moved a few microns off the knife edge, onto the foot of the
/// step (`Model3DGenerator.steadied`).
struct StepFlickerTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("step-flicker")

    static func project(_ name: String) throws -> Project {
        try Project.decode(Data(contentsOf: dir.appendingPathComponent(name + ".nativecam")))
    }

    /// What the moulding's finish does: its feed moves, those under 0.1 mm long, its moves up or down more than 0.2 in
    /// within 0.25 mm in plan (a pass sawing up and down a wall), the box every motion stays in, and its time. Collected
    /// inside `forEachMotion`, asserted after (an `#expect` inside it crashes swiftc).
    struct Finish {
        var feeds = 0, short = 0, saws = 0
        var box = Rect2.empty
        var seconds = 0.0
    }

    static func finish(_ p: Project) throws -> Finish {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let i = try #require(job.toolpaths.firstIndex { $0.name == "Frame" })
        var f = Finish()
        job.toolpaths[i].forEachMotion { s, m in
            f.box = f.box.union(m.end.xy)
            guard m.kind != .rapid else { return }
            f.feeds += 1
            if s.distance(to: m.end) < 0.1 { f.short += 1 }
            if abs(m.end.z - s.z) > 0.2.inch, s.xy.distance(to: m.end.xy) < 0.25 { f.saws += 1 }
        }
        f.seconds = CycleTimeEstimator.estimate(job.toolpaths, project: p).toolpathSeconds[i]
        return f
    }

    static func expectBox(_ b: Rect2, x: ClosedRange<Double>, y: ClosedRange<Double>, sourceLocation: SourceLocation = #_sourceLocation) {
        let tolerance = 0.0002.inch
        #expect(abs(b.min.x - x.lowerBound.inch) < tolerance && abs(b.max.x - x.upperBound.inch) < tolerance, "\(b)",
                sourceLocation: sourceLocation)
        #expect(abs(b.min.y - y.lowerBound.inch) < tolerance && abs(b.max.y - y.upperBound.inch) < tolerance, "\(b)",
                sourceLocation: sourceLocation)
    }

    /// The flipped ogee's deep side is on the rail, a 1/2 in wall down from the uncut wood round the frame. Before
    /// this fix: 11,582 feed moves, 2,654 under 0.1 mm, 612 saws and 19:42; before #205 (when one rail sawed), 8,737,
    /// 986, 308 and 15:47. Its extents are the frame's own all the same.
    @Test func theFlippedFramesFinishDoesntSawAlongItsWall() throws {
        let f = try Self.finish(Self.project("frame-flipped"))
        #expect(f.saws <= 20, "\(f.saws) moves up or down the wall")
        #expect(f.feeds < 8_500, "\(f.feeds) feed moves")
        #expect(f.short < 1_000, "\(f.short) feed moves under 0.1 mm")
        #expect(f.seconds < 12.5 * 60, "\(f.seconds) s")
        Self.expectBox(f.box, x: 2.0125...13.9875, y: 2.0124...11.9875)
    }

    /// The ogee outside the rail: before this fix 385 saws and 20:02 (15:08 before #205).
    @Test func theOutsideFramesFinishDoesntSawAlongItsWall() throws {
        let f = try Self.finish(Self.project("frame-outside"))
        #expect(f.saws <= 20, "\(f.saws) moves up or down the wall")
        #expect(f.short < 400, "\(f.short) feed moves under 0.1 mm")
        #expect(f.seconds < 15.5 * 60, "\(f.seconds) s")
        Self.expectBox(f.box, x: 0.5124...15.4875, y: 0.5124...13.4875)
    }

    /// The ogee inside the rail, its high side on it, never sawed: its finish takes what it did (11:40).
    @Test func theInsideFramesFinishIsAsItWas() throws {
        let f = try Self.finish(Self.project("frame-inside"))
        #expect(abs(f.seconds - 700) < 15, "\(f.seconds) s")
        Self.expectBox(f.box, x: 2.0125...13.9875, y: 2.0125...11.9875)
    }

    /// Moved onto the foot of the step, the flipped frame's finish still cuts nothing it shouldn't: simulated, no cell
    /// of the swept surface is cut below it, and the uncut wood round the frame and in its opening (every cell more
    /// than a millimetre and a half from the surface) is left at the material top.
    @Test func theSteadiedFinishCutsNothingItShouldnt() throws {
        let p = try Self.project("frame-flipped")
        let r = try MouldingCatalogTests.compare(p, cell: 0.5, slack: 0.05)
        #expect(r.cells > 10_000)
        #expect(r.gouge <= 0, "cut \(r.gouge) mm past the surface")
        let job = CAMEngine.generate(p)
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.5)
        for tp in job.toolpaths {
            tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
        }
        let g = sim.grid
        let model = try MouldingCatalogTests.surface(p).shape
        let area = Rect2(min: g.origin, max: Vec2(g.origin.x + Double(g.columns - 1) * g.cellSize, g.origin.y + Double(g.rows - 1) * g.cellSize))
        let surface = ModelRaster.surface(of: [model], over: area, cellSize: g.cellSize)
        let reach = 3 // cells: 1.5 mm
        var deepest = 0.0, uncut = 0
        for r in 0..<min(g.rows, surface.rows) {
            for c in 0..<min(g.columns, surface.columns) {
                var near = false
                for dr in -reach...reach where !near {
                    for dc in -reach...reach {
                        let rr = r + dr, cc = c + dc
                        if rr >= 0, cc >= 0, rr < surface.rows, cc < surface.columns, surface.covered[surface.index(cc, rr)] { near = true; break }
                    }
                }
                guard !near else { continue }
                uncut += 1
                deepest = max(deepest, -Double(g.heights[g.index(c, r)]))
            }
        }
        #expect(uncut > 100_000)
        #expect(deepest < 0.05, "cut \(deepest) mm into the wood round the frame")
    }
}
