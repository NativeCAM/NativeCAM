import Foundation
import Testing
@testable import CAMCore

/// Avid Mach4 post: structure mirrors Avid's own Vectric/Fusion posts; output must parse back to the same motion.
struct PostTests {
    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func demo(_ configure: (inout Project) -> Void = { _ in }) -> (Project, JobResult, String) {
        var p = Project.demoSign()
        configure(&p)
        let job = CAMEngine.generate(p)
        return (p, job, AvidMach4Post(project: p, date: Self.fixedDate).post(job.toolpaths))
    }

    func lines(_ g: String) -> [String] {
        g.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    @Test func headerToolChangesAndFooterMatchAvidDialect() {
        let (_, _, g) = demo()
        let l = lines(g)
        #expect(l.contains("G00 G94 G20 G17 G90 G40 G49 G80"))
        #expect(l.contains("G91.1"))
        // Manual tool changes: T#M6 without G43 (Avid's M6 macro + touch plate handles length).
        #expect(l.contains("T5M6"))
        #expect(l.contains("T1M6"))
        #expect(!g.contains("G43"))
        #expect(l.filter { $0 == "M07" }.count == 2) // dust collector on after each tool change
        #expect(l.contains("S18000 M03"))
        #expect(Array(l.suffix(3)) == ["M05", "M09", "M30"])
        // Safety block comes before any motion.
        let safety = l.firstIndex(of: "G00 G94 G20 G17 G90 G40 G49 G80")!
        let firstMove = l.firstIndex { $0.hasPrefix("G00 Z") || $0.hasPrefix("G01") }!
        #expect(safety < firstMove)
        // Tool change retracts and stops the spindle first.
        let second = l.firstIndex(of: "T1M6")!
        #expect(l[..<second].suffix(4).contains("M05"))
    }

    @Test func everyLineIsCRLFAndCommentsAreSafe() {
        let (_, _, g) = demo()
        #expect(!g.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(g.allSatisfy { $0.isASCII })
        for line in lines(g) where line.hasPrefix("(") {
            #expect(line.hasSuffix(")"))
            #expect(!line.dropFirst().dropLast().contains("("), "nested paren: \(line)")
            #expect(!line.contains("\""), "quote in comment: \(line)")
        }
        #expect(!g.contains("-0.0000"))
    }

    @Test func atcAddsToolLengthOffsets() {
        let (_, _, g) = demo { $0.machine.toolChange = .atc }
        let l = lines(g)
        #expect(l.contains("G43 H5"))
        #expect(l.contains("G43 H1"))
    }

    @Test func manualPauseModeUsesM0() {
        let (_, _, g) = demo { $0.machine.toolChange = .manualPause }
        let code = lines(g).filter { !$0.hasPrefix("(") }
        #expect(!code.contains { $0.contains("M6") })
        #expect(code.contains("M00"))
    }

    @Test func metricOutputAndBedZero() {
        let (p, _, g) = demo {
            $0.machine.outputUnits = .mm
            $0.stock.zZero = .machineBed
        }
        let l = lines(g)
        #expect(l.contains("G00 G94 G21 G17 G90 G40 G49 G80"))
        // With Z zero on the bed, the safe Z is thickness + clearance.
        let safe = String(format: "G00 Z%.3f", p.stock.thickness + p.stock.clearanceHeight)
        #expect(l.contains(safe))
    }

    @Test func arcsAreUnder180DegreesWithIJ() throws {
        let (_, _, g) = demo()
        let program = try GCodeParser.parse(g)
        var arcs = 0
        for seg in program.segments {
            var p = seg.start
            for m in seg.motions {
                if m.kind.isArc {
                    arcs += 1
                    #expect(abs(m.arcSweep(from: p)) < .pi)
                    // Start and end radius agree (Mach4 rejects inconsistent arcs).
                    #expect(abs(p.xy.distance(to: m.center) - m.end.xy.distance(to: m.center)) < 0.005)
                }
                p = m.end
            }
        }
        #expect(arcs > 10)
    }

    @Test func gcodeParsesBackToTheSameMotion() throws {
        let (p, job, g) = demo()
        let program = try GCodeParser.parse(g)
        #expect(program.warnings.isEmpty, "\(program.warnings)")
        #expect(program.units == .inch)
        let parsed = program.toolpaths(tools: ToolLibrary.starter.tools, stock: p.stock, fallback: Fixture.endMill)
        // Compare the sequence of cutting endpoints (rounding to 0.0001" = 0.00254 mm).
        let original = job.toolpaths.flatMap { $0.motions.filter { $0.kind != .rapid && $0.kind != .dwell }.map(\.end) }
        let back = parsed.flatMap { $0.motions.filter { $0.kind != .rapid && $0.kind != .dwell }.map(\.end) }
        #expect(original.count == back.count)
        var worst = 0.0
        for (a, b) in zip(original, back) { worst = max(worst, a.distance(to: b)) }
        #expect(worst < 0.003)
        // Tool numbers survive.
        #expect(Set(parsed.map(\.tool.number)) == Set([1, 5]))
    }

    @Test func spinUpDwellAndLineNumbers() {
        let (_, _, g) = demo {
            $0.machine.spindleSpinUpDwell = 4
            $0.machine.lineNumbers = true
        }
        let l = lines(g)
        #expect(l.contains { $0.hasSuffix("G04 P4.00") })
        #expect(l.allSatisfy { $0.hasPrefix("N") })
    }

    @Test func parserHandlesForeignDialects() throws {
        let g = """
        %
        G21 G90 ; metric
        T2 M6
        S12000 M3
        G0 X10 Y10 Z5
        G1 Z-1 F300
        G2 X20 Y10 R5
        G91 G1 X5
        G90 G3 X10 Y10 I-7.5 J0 (back home)
        M30
        """
        let program = try GCodeParser.parse(g)
        #expect(program.units == .mm)
        let seg = try #require(program.segments.first)
        #expect(seg.toolNumber == 2 && seg.spindleRPM == 12000)
        #expect(seg.motions.count == 5)
        #expect(seg.motions[2].kind == .arcCW)
        #expect(abs(seg.motions[2].center.distance(to: Vec2(15, 10))) < 1e-9)
        #expect(seg.motions[3].end == Vec3(25, 10, -1))
    }
}

struct SimulationTests {
    @Test func demoSignSimulatesWithoutRapidCollisions() {
        let p = Project.demoSign()
        let job = CAMEngine.generate(p)
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates, cellSize: 1.0)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        #expect(s.grid.removedVolume > 0)
        // The cut-out goes all the way through somewhere, and the centre of the sign is still there.
        #expect(s.grid.heights.contains { $0 <= s.grid.floorZ + 1e-4 })
        #expect(s.grid.height(at: Vec2(12.inch, 8.inch)) == 0)
    }

    @Test func scrubbingBackMatchesForward() {
        let p = Project.demoSign()
        let job = CAMEngine.generate(p)
        var a = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 2)
        let mid = a.timeline.duration * 0.4
        a.seek(to: a.timeline.duration * 0.8)
        a.seek(to: mid) // backwards: replays from the start
        var b = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 2)
        b.seek(to: mid * 0.5)
        b.seek(to: mid) // forwards in two steps
        #expect(a.grid.heights == b.grid.heights)
        #expect(a.toolState?.position == b.toolState?.position)
    }

    @Test func ballNoseLeavesRoundBottom() {
        let ball = ToolLibrary.starter.tool(number: 7)!
        let stock = Fixture.stock
        let tp = Toolpath(id: UUID(), name: "groove", tool: ball, spindleRPM: 18000, start: Vec3(20, 50, 5),
                          motions: [.rapid(Vec3(20, 50, 1)), .feed(Vec3(20, 50, -3), 300), .feed(Vec3(150, 50, -3), 1000)])
        let grid = Fixture.simulate([tp], stock: stock, cell: 0.1)
        let R = ball.radius
        for target in [0.0, 1.0, 2.0, 3.0] {
            // Evaluate at the exact cell centre the grid stores.
            let row = Int(((50 + target - grid.origin.y) / grid.cellSize).rounded())
            let col = Int(((80 - grid.origin.x) / grid.cellSize).rounded())
            let dy = grid.origin.y + Double(row) * grid.cellSize - 50
            let expected = -3 + (R - (R * R - dy * dy).squareRoot())
            let h = Double(grid.heights[grid.index(col, row)])
            #expect(abs(h - expected) < 0.01, "dy=\(dy): \(h) vs \(expected)")
        }
    }

    @Test func detectsRapidThroughMaterial() {
        let tool = Fixture.endMill
        let tp = Toolpath(id: UUID(), name: "bad", tool: tool, spindleRPM: 18000, start: Vec3(20, 20, 5),
                          motions: [.rapid(Vec3(20, 20, -2)), .rapid(Vec3(100, 20, -2))])
        var s = SimulationSession(toolpaths: [tp], stock: Fixture.stock, rapidRate: 5000, cellSize: 1)
        s.runToEnd()
        #expect(!s.rapidCollisions.isEmpty)
    }
}
