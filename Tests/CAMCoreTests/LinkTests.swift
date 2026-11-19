import Foundation
import Testing
@testable import CAMCore

/// Minimum-retract links must never change what gets cut, only how the tool travels.
struct LinkTests {
    func simulate(_ job: JobResult, _ p: Project, cell: Double = 0.5) -> SimulationSession {
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: cell)
        s.runToEnd()
        return s
    }

    func check(_ project: Project, cell: Double = 0.5) throws {
        var full = project
        full.stock.retractMode = .full
        var minimum = project
        minimum.stock.retractMode = .minimum
        let jf = CAMEngine.generate(full), jm = CAMEngine.generate(minimum)
        let sf = simulate(jf, full, cell: cell), sm = simulate(jm, minimum, cell: cell)
        #expect(sm.rapidCollisions.isEmpty, "rapid through material at \(sm.rapidCollisions.prefix(3))")
        var worst: Float = 0
        for (a, b) in zip(sf.grid.heights, sm.grid.heights) { worst = max(worst, abs(a - b)) }
        #expect(worst < 0.02, "finished part differs by \(worst) mm")
        let tf = try #require(jf.estimate).total, tm = try #require(jm.estimate).total
        #expect(tm <= tf + 0.01, "minimum \(tm) s vs full \(tf) s")
    }

    @Test func demoSignLinksAreSafeAndFaster() throws { try check(.demoSign(), cell: 1.0) }
    @Test func demoReliefLinksAreSafeAndFaster() throws { try check(.demoRelief(), cell: 1.0) }

    @Test func linksRiseOnlyToTheSafeDistance() throws {
        let p = Project.demoSign()
        let job = CAMEngine.generate(p)
        let vcarve = try #require(job.toolpaths.first { $0.name.contains("V-carve") })
        // Links between paths (the closing retract at the very end still goes to safe Z, as it should).
        var links = vcarve.motions
        while links.last?.kind == .rapid { links.removeLast() }
        let highest = links.filter { $0.kind == .rapid }.map(\.end.z).max() ?? 0
        #expect(highest <= p.stock.safeDistance + 0.01, "V-carve links rise to \(highest) mm")
        #expect(highest < p.stock.clearanceHeight)
    }

    @Test func clampsForceLinksOverTheTopAndCannotBeCut() throws {
        let holes = [Vec2(30, 75), Vec2(170, 75)].map { DesignShape(kind: .circle(radius: 3), position: $0) }
        var clamp = DesignShape(name: "Clamp", kind: .rectangle(width: 20, height: 40, cornerRadius: 0), position: Vec2(100, 75))
        clamp.keepOutHeight = 30
        let lib = ToolLibrary.starter
        let drill = CAMOperation(kind: .drill(DrillParams(depth: 5)), shapeIDs: holes.map(\.id), tool: lib.tool(number: 1)!)
        var p = Project(displayUnits: .mm, stock: Stock(width: 200, height: 150, thickness: 20, clearanceHeight: 40, plungeHeight: 2),
                        shapes: holes + [clamp], operations: [drill])
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let crossing = tp.motions.filter { $0.kind == .rapid }.map(\.end.z).max() ?? 0
        #expect(crossing >= 30 + p.stock.safeDistance - 1e-6, "link over the clamp at \(crossing) mm")
        #expect(!job.issues.contains { $0.severity == .error })
        // A pocket overlapping the clamp is an error.
        let pocketShape = DesignShape(kind: .rectangle(width: 30, height: 30, cornerRadius: 0), position: Vec2(100, 75))
        p.shapes.append(pocketShape)
        p.operations = [CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [pocketShape.id], tool: lib.tool(number: 1)!)]
        #expect(CAMEngine.generate(p).issues.contains { $0.severity == .error && $0.message.contains("clamp") })
    }

    @Test func staysDownAcrossAlreadyClearedArea() throws {
        let lib = ToolLibrary.starter
        let pocket = DesignShape(kind: .rectangle(width: 120, height: 80, cornerRadius: 0), position: Vec2(100, 75))
        let a = DesignShape(kind: .rectangle(width: 10, height: 10, cornerRadius: 0), position: Vec2(90, 75))
        let b = DesignShape(kind: .rectangle(width: 10, height: 10, cornerRadius: 0), position: Vec2(108, 75))
        let ops = [
            CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 5, passDepth: 5))), shapeIDs: [pocket.id], tool: lib.tool(number: 1)!),
            CAMOperation(kind: .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 5, passDepth: 5))), shapeIDs: [a.id, b.id], tool: lib.tool(number: 1)!),
        ]
        let p = Project(displayUnits: .mm, stock: Stock(width: 200, height: 150, thickness: 20, clearanceHeight: 10, plungeHeight: 2),
                        shapes: [pocket, a, b], operations: ops)
        let job = CAMEngine.generate(p)
        let profile = try #require(job.toolpaths.last)
        // Between the two squares the tool feeds across at depth: no rapid goes back up to clearance mid-path.
        let midRapidsUp = profile.motions.dropLast(1).filter { $0.kind == .rapid && $0.end.z > 0 }
        #expect(midRapidsUp.count <= 1, "\(midRapidsUp.count) retracts between the squares")
    }

    @Test func cutOutStartsBelowWhatRoughingCleared() throws {
        let p = Project.demoRelief()
        let job = CAMEngine.generate(p)
        let cutOut = try #require(job.toolpaths.first { $0.name.contains("Cut out") })
        let firstCutZ = try #require(cutOut.motions.first { $0.kind != .rapid && $0.end.z < -0.01 }).end.z
        // Roughing took the surroundings down to about -0.38 in; the cut-out's first pass shouldn't be in air above that.
        #expect(firstCutZ < -0.3.inch, "first cut at \(firstCutZ / 25.4) in")
    }
}
