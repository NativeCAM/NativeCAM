import Foundation
import Testing
@testable import CAMCore

/// #47: a wrapped rotary job's run-time estimate, its simulation and the posted program's own time agree.
struct RotaryJobTimeTests {
    /// The words of one line of G-code, comments left out ("T1M6" is two words).
    static func words(_ raw: Substring) -> [(letter: Character, value: Double)] {
        let line = raw.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        var out: [(letter: Character, value: Double)] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            i = line.index(after: i)
            guard c.isLetter else { continue }
            var j = i
            while j < line.endIndex, line[j].isNumber || line[j] == "." || line[j] == "-" { j = line.index(after: j) }
            if let v = Double(line[i..<j]) { out.append((c, v)) }
            i = j
        }
        return out
    }

    /// The posted program's own time at constant speed, from its words alone: a move in G93 takes 1/F minutes, a G94
    /// feed its length ÷ F, a rapid as long as its slowest axis at that axis's rapid speed (A at the turn speed), and
    /// each tool change after the first the machine's tool-change time (the first bit is in before Cycle Start).
    static func programSeconds(_ gcode: String, machine: MachineProfile, units: LengthUnit) -> Double {
        let rapidXY = units.fromMM(machine.axisRapid.x), rapidZ = units.fromMM(machine.axisRapid.z)
        let turn = machine.rotary?.drivenTurnSpeed ?? RotaryAxis.nominalTurnSpeed
        var at = [Character: Double]()
        var rapid = true, inverse = false
        var feed = 1.0, minutes = 0.0
        var toolChanges = 0
        for line in gcode.split(whereSeparator: \.isNewline) {
            var to = at
            var moved = false
            for w in words(line) {
                switch w.letter {
                case "G" where w.value == 0: rapid = true
                case "G" where w.value == 1: rapid = false
                case "G" where w.value == 93: inverse = true
                case "G" where w.value == 94: inverse = false
                case "X", "Y", "Z", "A":
                    to[w.letter] = w.value
                    moved = true
                case "F": feed = w.value
                case "M" where w.value == 6: toolChanges += 1
                default: break
                }
            }
            guard moved else { continue }
            func d(_ k: Character) -> Double { abs((to[k] ?? 0) - (at[k] ?? 0)) }
            if rapid {
                minutes += max(d("X") / rapidXY, d("Y") / rapidXY, d("Z") / rapidZ, d("A") / turn)
            } else if inverse {
                minutes += 1 / feed
            } else {
                minutes += (d("X") * d("X") + d("Y") * d("Y") + d("Z") * d("Z")).squareRoot() / feed
            }
            at = to
        }
        return minutes * 60 + Double(max(0, toolChanges - 1)) * machine.toolChangeTime
    }

    /// The last A value the program turns to.
    static func lastA(_ gcode: String) -> Double? {
        gcode.split(whereSeparator: \.isNewline).compactMap { line in words(line).last { $0.letter == "A" }?.value }.last
    }

    /// How fast A turns, degrees per minute, on each G93 move from the line containing `marker` on.
    static func turnRates(_ gcode: String, from marker: String) -> [Double] {
        var a = 0.0, feed = 1.0
        var inverse = false, reading = false
        var rates: [Double] = []
        for line in gcode.split(whereSeparator: \.isNewline) {
            if line.contains(marker) { reading = true }
            var to = a
            for w in words(line) {
                if w.letter == "G" && w.value == 93 { inverse = true }
                if w.letter == "G" && w.value == 94 { inverse = false }
                if w.letter == "A" { to = w.value }
                if w.letter == "F" { feed = w.value }
            }
            if reading && inverse && to != a && line.contains("G01") { rates.append(abs(to - a) * feed) }
            a = to
        }
        return rates
    }

    @Test func thePawnsSimulationEstimateAndProgramTakeTheSameTime() throws {
        let p = Project.demoPawn()
        let job = CAMEngine.generate(p)
        let estimate = try #require(job.estimate)
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let gcode = post.post(job.toolpaths)
        let program = Self.programSeconds(gcode, machine: p.machine, units: p.machine.outputUnits)
        // About 20 minutes, which the estimate (with acceleration) puts a little over the program at constant speed.
        #expect(program > 18 * 60 && program < 22 * 60, "\(program)")
        #expect(estimate.total >= program - 1 && estimate.total < program * 1.02, "\(estimate.total) vs \(program)")

        // The simulation runs at the estimate's pace, the time between toolpaths included.
        let sim = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates,
                                    cellSize: 2, estimate: estimate, turnSpeed: p.machine.rotary?.drivenTurnSpeed)
        #expect(abs(sim.timeline.duration - estimate.total) < 0.5, "\(sim.timeline.duration) vs \(estimate.total)")

        // Without the estimate it times each move by its own feed, as the post's inverse times do: the program's time
        // less the tool change and the moves between toolpaths it doesn't know about.
        let plain = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates, cellSize: 2)
        let cutting = program - p.machine.toolChangeTime
        #expect(abs(plain.timeline.duration - cutting) < cutting * 0.02, "\(plain.timeline.duration) vs \(cutting)")
    }

    @Test func thePawnsBlankStopsOnTheNearestWholeTurnAsThePostDoes() throws {
        let p = Project.demoPawn()
        let job = CAMEngine.generate(p)
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let gcode = post.post(job.toolpaths)
        let home = try #require(Self.lastA(gcode))
        // Over 300 turns: the program stops on a whole turn rather than wind them all back.
        #expect(home > 300 * 360 && home.truncatingRemainder(dividingBy: 360) == 0, "\(home)")
        let sim = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates, cellSize: 2,
                                    estimate: job.estimate)
        let turns = sim.timeline.steps.compactMap(\.turn)
        let last = try #require(turns.last)
        #expect(abs(last.to - home) < 0.01, "\(turns.map(\.to)) vs A\(home)")
        // No turn between toolpaths winds the blank back either: after the rounding the finish starts where it is.
        let longest = turns.map { abs($0.to - $0.from) }.max() ?? 0
        #expect(longest <= 360, "\(turns)")
        let atEnd = try #require(sim.blankAngle(at: sim.timeline.duration))
        #expect(abs(atEnd - home) < 0.01)
    }

    /// The finish's feeds keep A within the turn speed even where the post splits a move that comes in toward the axis
    /// into quarter turns: the piece nearest the axis turns fastest, and the feed is slowed for it.
    @Test func thePawnsFinishNeverAsksATurnFasterThanTheTurnSpeed() throws {
        let p = Project.demoPawn()
        let job = CAMEngine.generate(p)
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let rates = Self.turnRates(post.post(job.toolpaths), from: "(Toolpath: Finish pawn")
        #expect(rates.count > 1000)
        // Within the 90° a second the finish assumes, allowing for the post's rounding.
        let fastest = rates.max() ?? 0
        #expect(fastest <= RotaryAxis.nominalTurnSpeed * 1.001, "\(fastest)°/min")
    }
}
