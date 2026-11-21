import Foundation
import Testing
@testable import CAMCore

/// The simulation of an indexed rotary job: one height grid per face, carved in that face's frame, and a timeline
/// that turns the blank between toolpaths the way the post does.
struct RotarySimulationTests {
    func session(_ p: Project, cell: Double = 0.5) -> (SimulationSession, JobResult) {
        let job = CAMEngine.generate(p)
        return (SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10_000, cellSize: cell), job)
    }

    func height(_ g: HeightGrid, _ x: Double, _ y: Double) -> Double { Double(g.height(at: Vec2(x, y)) ?? .nan) }

    @Test func eachFaceIsCarvedInItsOwnFrame() {
        var (s, _) = session(RotaryIndexTests.leg())
        s.runToEnd()
        #expect(s.faceAngles == [0, 90, 180, 270])
        #expect(s.faces.count == 4)
        for face in 0..<4 {
            let g = s.grid(face: face)
            // The mortise (1 × 0.75 in at x = 6 in, on the centreline) is 0.25 in deep on every face.
            #expect(abs(height(g, 6.inch, 1.inch) + 0.25.inch) < 0.01, "face \(face)")
            #expect(abs(height(g, 5.7.inch, 1.25.inch) + 0.25.inch) < 0.01, "face \(face)")
            // The pin hole at x = 9 in is drilled 0.5 in deep; the rest of the face is untouched.
            #expect(abs(height(g, 9.inch, 1.inch) + 0.5.inch) < 0.02, "face \(face)")
            #expect(height(g, 2.inch, 1.inch) == 0, "face \(face)")
            #expect(height(g, 6.inch, 0.2.inch) == 0, "face \(face)")
        }
    }

    @Test func faceGridsReachTheFarSideOfTheBlank() {
        // A hole drilled right through a 2 in square bar from one face goes 2 in deep, past the axis.
        let (s, _) = session(RotaryIndexTests.leg())
        let bar = RotaryIndexTests.bar
        #expect(abs(Double(s.grid(face: 0).floorZ) + bar.radius + bar.outerRadius) < 1e-4)
        let through = RotaryIndexTests.leg { p in
            p.operations.removeFirst()
            p.operations[0].indexAngles = [90]
            if case var .drill(d) = p.operations[0].kind { d.depth = 2.inch; p.operations[0].kind = .drill(d) }
        }
        var (t, _) = session(through)
        t.runToEnd()
        #expect(t.faceAngles == [90])
        #expect(height(t.grid(face: 0), 9.inch, 1.inch) < -1.9.inch)
    }

    @Test func theTimelineTurnsTheBlankBetweenFaces() throws {
        let (s, job) = session(RotaryIndexTests.leg())
        let tl = s.timeline
        #expect(tl.turnsBlank)
        let turns = tl.steps.compactMap(\.turn)
        // Mortise at 0, 90, 180, 270, then the pin holes back at 0 and round again, then home to A0.
        #expect(turns == [.init(from: 0, to: 90), .init(from: 90, to: 180), .init(from: 180, to: 270), .init(from: 270, to: 0),
                          .init(from: 0, to: 90), .init(from: 90, to: 180), .init(from: 180, to: 270), .init(from: 270, to: 0)])
        // A turn happens with the tool over the next cut's start, and takes |Δ| at the nominal speed.
        let first = try #require(tl.steps.first { $0.turn != nil && $0.toolpathIndex == 1 })
        #expect(first.start == job.toolpaths[1].start && first.motion.kind == .dwell)
        #expect(abs(first.duration - 90 / SimulationSession.turnSpeed) < 1e-9)
        // Half way through the turn from 90° to 180° the blank is at 135°; while cutting it's at the toolpath's angle.
        let second = try #require(tl.steps.first { $0.turn != nil && $0.toolpathIndex == 2 })
        #expect(abs(tl.blankAngle(at: second.startTime + second.duration / 2)! - 135) < 1e-9)
        #expect(tl.turn(at: second.startTime + second.duration / 2)?.turn == .init(from: 90, to: 180))
        let cut = try #require(tl.steps.first { $0.toolpathIndex == 2 && $0.turn == nil && $0.motion.kind == .feed })
        #expect(tl.blankAngle(at: cut.startTime + cut.duration / 2) == 180)
        #expect(tl.turn(at: cut.startTime) == nil)
        #expect(tl.blankAngle(at: 0) == 0 && tl.blankAngle(at: tl.duration) == 0)
        // Every motion of every toolpath is still there, once, after the turns.
        #expect(tl.steps.filter { $0.turn == nil }.count == job.toolpaths.reduce(0) { $0 + $1.motions.count })
    }

    @Test func theEstimateStillTimesTheCuts() throws {
        // Turns and the time between toolpaths sit between the estimated motions without shifting their durations, so
        // the simulation takes the estimate's time.
        let p = RotaryIndexTests.leg()
        let job = CAMEngine.generate(p)
        let e = try #require(job.estimate)
        let s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10_000, cellSize: 1, estimate: e)
        let between = e.leadInSeconds.reduce(0, +) + e.endSeconds
        let motionTime = e.motionSeconds.joined().reduce(0, +)
        #expect(abs(e.total - between - motionTime) < 1e-6)
        #expect(abs(s.timeline.duration - e.total) < 1e-6)
        // Each cut keeps its own time.
        let cut = try #require(s.timeline.steps.first { $0.toolpathIndex == 1 && $0.motion.kind == .feed })
        let k = try #require(job.toolpaths[1].motions.firstIndex { $0.kind == .feed })
        #expect(abs(cut.duration - e.motionSeconds[1][k]) < 1e-12)
    }

    @Test func flatJobsKeepOneGridAndNoTurns() {
        let p = Project.demoSign()
        let job = CAMEngine.generate(p)
        let s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10_000, cellSize: 2)
        #expect(s.faces.count == 1 && s.faceAngles == [0])
        #expect(!s.timeline.turnsBlank && s.timeline.blankAngle(at: 1) == nil)
        #expect(s.timeline.steps.allSatisfy { $0.turn == nil })
        #expect(s.grid(face: 0).floorZ == Float(-p.stock.thickness))
    }
}
