import Foundation
import Testing
@testable import CAMCore

/// #49: no posted move asks the rotary axis to turn faster than its turn speed, on any wrapped toolpath. #50: the Avid
/// post's extents comment gives the A range the program really cuts at.
struct RotaryTurnSpeedTests {
    /// One feed move (G1) of a posted program: the A it starts and ends at, and its F word in the mode it was read in.
    struct FeedMove {
        var from: Double?
        var to: Double?
        var feed: Double
        var inverse: Bool
        var line: Substring
    }

    /// The feed moves of a posted program, in order. Rapids, arcs and canned cycles are left out.
    static func feedMoves(_ gcode: String) -> [FeedMove] {
        var moves: [FeedMove] = []
        var a: Double?
        var feed = 0.0
        var mode = 0.0
        var inverse = false
        for line in gcode.split(whereSeparator: \.isNewline) {
            let code = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            var to = a
            var moved = false
            for w in RotaryJobTimeTests.words(code) {
                switch w.letter {
                case "G" where w.value == 93: inverse = true
                case "G" where w.value == 94: inverse = false
                case "G" where [0, 1, 2, 3].contains(w.value) || (w.value >= 73 && w.value <= 89): mode = w.value
                case "X", "Y", "Z": moved = true
                case "A":
                    to = w.value
                    moved = true
                case "F": feed = w.value
                default: break
                }
            }
            if moved && mode == 1 { moves.append(FeedMove(from: a, to: to, feed: feed, inverse: inverse, line: line)) }
            a = to
        }
        return moves
    }

    /// How fast A turns on each feed move that turns it, degrees per minute: |ΔA| × F in G93. A G94 move that turns A is
    /// returned as infinitely fast: none of these posts writes one (they feed every such move in inverse time).
    static func turnRates(_ moves: [FeedMove]) -> [(rate: Double, line: Substring)] {
        moves.compactMap { m in
            guard let from = m.from, let to = m.to, to != from else { return nil }
            return (m.inverse ? abs(to - from) * m.feed : .infinity, m.line)
        }
    }

    /// The A values a posted program's feed moves start and end at.
    static func cutRange(_ gcode: String) -> ClosedRange<Double>? {
        let values = feedMoves(gcode).flatMap { [$0.from, $0.to].compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return lo...hi
    }

    /// The A range the header's "(Program extents: …)" comment gives, if it gives one.
    static func extentsRange(_ gcode: String) -> ClosedRange<Double>? {
        guard let line = gcode.split(whereSeparator: \.isNewline).first(where: { $0.contains("(Program extents:") }) else { return nil }
        let parts = line.components(separatedBy: "  ").filter { $0.hasPrefix("A") && $0.contains(" to A") }
        guard let part = parts.first else { return nil }
        let ends = part.components(separatedBy: " to ").compactMap { Double($0.dropFirst()) }
        guard ends.count == 2 else { return nil }
        return ends[0]...ends[1]
    }

    /// Every golden file and every example's G-code.
    static func postedFiles() throws -> [(name: String, gcode: String)] {
        let examples = GoldenPostTests.fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples")
        var files: [(name: String, gcode: String)] = []
        for dir in [GoldenPostTests.goldens, examples] {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tap") }.sorted()
            for name in names {
                files.append((name, String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)))
            }
        }
        return files
    }

    static func avid(_ p: Project, _ toolpaths: [Toolpath]) -> String {
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        return post.post(toolpaths)
    }

    // MARK: #49, the turn speed

    /// No rotary golden or example sets a turn speed (the demo pawn's is checked below), so each is held to the nominal
    /// 90° a second: no move in any of them, rounding, wrapped 2.5D or 3D finishing, asks A to turn faster.
    @Test func noPostedMoveAsksATurnFasterThanTheTurnSpeed() throws {
        var checked: [String] = []
        for (name, gcode) in try Self.postedFiles() where gcode.contains("G93") {
            let rates = Self.turnRates(Self.feedMoves(gcode))
            guard !rates.isEmpty else { continue }
            checked.append(name)
            let over = rates.filter { $0.rate > RotaryAxis.nominalTurnSpeed }
            let shown = over.prefix(3).map { "\($0.line) (\(Int($0.rate.rounded()))°/min)" }
            #expect(over.isEmpty, "\(name): \(over.count) moves over, \(shown)")
        }
        // Wrapped rectangles (Avid, LinuxCNC, grblHAL), the rounding, both 3D finishes and the pawn.
        for name in ["wrapped-rectangle-mm.tap", "linuxcnc-wrapped-rectangle.tap", "grblhal-wrapped-rectangle.tap",
                     "rounding-square-mm.tap", "rotary-finish-mm.tap", "decoded-rotary-finish-v7.tap", "Demo Pawn.tap"] {
            #expect(checked.contains(name), "\(name) in \(checked)")
        }
        let pawn = try Project.decode(Data(contentsOf: GoldenPostTests.fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("examples/Demo Pawn.nativecam")))
        let axis = try #require(pawn.machine.rotary)
        #expect(axis.turnSpeed == nil)
    }

    /// The pawn's rounding asked A for up to 20,183°/min at the 1/4 in end mill's feed. Now its feed comes down near
    /// the axis to what A can keep, and the job's checks say so in inches.
    @Test func thePawnsRoundingSlowsForTheTurnSpeedAndSaysSo() throws {
        let p = Project.demoPawn()
        let job = CAMEngine.generate(p)
        let rounding = try #require(job.toolpaths.first)
        #expect(rounding.name.hasPrefix("Round"))
        let set = rounding.tool.cutting.feedRate
        let slowest = rounding.motions.filter { $0.kind == .feed }.map(\.feed).min() ?? set
        #expect(slowest < set * 0.5, "\(slowest) of \(set) mm/min")
        let notes = job.issues.filter { $0.operation == rounding.name && $0.message.contains("rotary axis turns at most 5,400°/min") }
        #expect(notes.count == 1, "\(job.issues.map(\.message))")
        let note = notes.first?.message ?? ""
        #expect(note.contains("isn't set, so NativeCAM assumes 90° a second"), "\(note)")
        #expect(note.contains(" in/min at "), "\(note)")
        #expect(note.contains(" in from the axis"), "\(note)")
        #expect(!note.contains("mm"), "\(note)")

        // As posted: the rounding's fastest turn is just under the turn speed, so the clamp costs no more than it must.
        let gcode = Self.avid(p, job.toolpaths)
        let body = gcode.components(separatedBy: "(Toolpath: Finish pawn")[0]
        let rates = Self.turnRates(Self.feedMoves(body)).map(\.rate)
        let fastest = rates.max() ?? 0
        let limit = RotaryAxis.nominalTurnSpeed
        #expect(rates.count > 100)
        #expect(fastest <= limit, "\(fastest)°/min")
        #expect(fastest > limit * 0.98, "\(fastest)°/min")
    }

    /// With the turn speed set, it's the limit: every posted move keeps to it, the checks give it, and the estimate
    /// still times the program as written.
    @Test func aSetTurnSpeedIsTheLimit() throws {
        var p = Project.demoPawn()
        p.machine.rotary?.turnSpeed = 3600
        let job = CAMEngine.generate(p)
        let gcode = Self.avid(p, job.toolpaths)
        let rates = Self.turnRates(Self.feedMoves(gcode)).map(\.rate)
        let fastest = rates.max() ?? 0
        #expect(rates.count > 1000)
        #expect(fastest <= 3600, "\(fastest)°/min")
        let notes = job.issues.map(\.message).filter { $0.contains("rotary axis turns at most 3,600°/min") }
        #expect(notes.count == 2, "\(job.issues.map(\.message))")
        #expect(notes.allSatisfy { !$0.contains("isn't set") })
        let estimate = try #require(job.estimate)
        let program = RotaryJobTimeTests.programSeconds(gcode, machine: p.machine, units: p.machine.outputUnits)
        #expect(estimate.total >= program - 1, "\(estimate.total) vs \(program)")
        #expect(estimate.total < program * 1.02, "\(estimate.total) vs \(program)")
    }

    /// The clamp is the 3D finish's rule, for a move cut in pieces: a whole turn ramping in from 30 mm to 10 mm from the
    /// axis is cut as four quarter turns, and the last, nearest the axis, sets the feed.
    @Test func aMoveSplitIntoPiecesIsLimitedByItsFastestPiece() {
        let whole = RotaryWrap.turnLimitedFeed(10_000, x0: 0, r0: 30, degrees0: 0, x1: 0, r1: 10, degrees1: 360, pieces: 1, turnSpeed: 5400)
        let split = RotaryWrap.turnLimitedFeed(10_000, x0: 0, r0: 30, degrees0: 0, x1: 0, r1: 10, degrees1: 360, pieces: 4, turnSpeed: 5400)
        let last = RotaryWrap.tipLength(x0: 0, r0: 15, degrees0: 270, x1: 0, r1: 10, degrees1: 360)
        let expected = (0.995 * 5400 * last / 90).rounded(.down)
        #expect(split < whole)
        #expect(split == expected, "\(split) vs \(expected)")
        // Slow enough already: left as it is.
        let slow = RotaryWrap.turnLimitedFeed(500, x0: 0, r0: 30, degrees0: 0, x1: 0, r1: 10, degrees1: 360, pieces: 4, turnSpeed: 5400)
        #expect(slow == 500)
        // A move that doesn't turn is never slowed.
        let along = RotaryWrap.turnLimitedFeed(10_000, x0: 0, r0: 1, degrees0: 5, x1: 50, r1: 1, degrees1: 5, pieces: 1, turnSpeed: 5400)
        #expect(along == 10_000)
    }

    /// A wrapped engraving on a thin dowel at a fast feed: the moves round it slow down, the ones along it don't.
    @Test func wrappedCutsAreLimitedToo() throws {
        let (p, tps) = RotaryWrapTests.rectangle { $0.machine.rotary?.turnSpeed = 1800 }
        let ctx = GenerationContext(stock: p.stock, machine: p.machine, units: .inch)
        let raw = try #require(tps.first)
        var fast = raw
        for i in fast.motions.indices where fast.motions[i].kind == .feed { fast.motions[i].feed = 3000 }
        fast.wrapDiameter = nil
        let prepared = RotaryWrap.prepare(fast, diameter: 50, clearanceZ: p.stock.clearanceHeight, context: ctx)
        var at = prepared.start
        var around: [Double] = [], along: [Double] = []
        for m in prepared.motions {
            defer { at = m.end }
            guard m.kind == .feed else { continue }
            if abs(m.end.y - at.y) > 1e-9 { around.append(m.feed) } else if abs(m.end.x - at.x) > 1e-9 { along.append(m.feed) }
        }
        // 24 mm from the axis, 1800°/min is 754 mm/min round it.
        let slowed = around.filter { $0 < 754 && $0 > 740 }
        let full = along.filter { $0 == 3000 }
        #expect(around.count == 2 && slowed.count == 2, "\(around)")
        #expect(along.count == 2 && full.count == 2, "\(along)")
        let note = try #require(prepared.warnings.first { $0.contains("rotary axis turns at most 1,800°/min") })
        #expect(note.contains("from the 118.1 in/min set"), "\(note)")
        #expect(note.contains("at 0.9449 in from the axis"), "\(note)")
    }

    // MARK: #50, the extents comment

    /// The pawn's finish starts a whole number of turns on from where the rounding left the blank: the comment gives the
    /// A words the program is cut with, those turns included.
    @Test func thePawnsExtentsGiveTheAItIsCutAt() throws {
        let p = Project.demoPawn()
        let gcode = Self.avid(p, CAMEngine.generate(p).toolpaths)
        let comment = try #require(Self.extentsRange(gcode))
        let posted = try #require(Self.cutRange(gcode))
        #expect(comment == posted, "\(comment) vs \(posted)")
        #expect(comment.lowerBound == 0, "\(comment)")
        #expect(comment.upperBound == 112_475.906, "\(comment)")
        #expect(gcode.contains("(Program extents: X0.7500 to X5.2500  A0.000 to A112475.906  Z0.1574 to Z0.9750)"))
    }

    /// Every rotary golden and example whose extents comment gives A gives the range its feed moves are posted at.
    @Test func everyExtentsCommentMatchesThePostedA() throws {
        var checked = 0
        for (name, gcode) in try Self.postedFiles() {
            guard let comment = Self.extentsRange(gcode) else { continue }
            checked += 1
            let posted = Self.cutRange(gcode)
            #expect(posted == comment, "\(name): \(comment) vs \(String(describing: posted))")
        }
        #expect(checked >= 7, "\(checked)")
    }

    /// A job with a rounding and a face cut after it: the range covers the face's angle as the program turns to it,
    /// whole turns on from where the rounding left the blank.
    @Test func theExtentsCoverAFaceCutAfterARounding() throws {
        var p = RoundingTests.job { $0.stock.setRotary(RotaryStock(shape: .squareBar, diameter: 30, length: 60)) }
        let slot = DesignShape(kind: .paths([Polyline([Vec2(20, 15), Vec2(40, 15)], closed: false)]), position: .zero)
        var op = CAMOperation(name: "Slot", kind: .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 1))),
                              shapeIDs: [slot.id], tool: RoundingTests.lib.tool(number: 1)!)
        op.indexAngles = [90]
        p.shapes = [slot]
        p.operations.append(op)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 2)
        let gcode = Self.avid(p, job.toolpaths)
        let comment = try #require(Self.extentsRange(gcode))
        let posted = try #require(Self.cutRange(gcode))
        #expect(comment == posted, "\(comment) vs \(posted)")
        // The face is cut at 90° plus the whole turns the rounding made.
        let face = try #require(Self.feedMoves(gcode.components(separatedBy: "(Toolpath: Slot")[1]).first?.to)
        let turn = face.truncatingRemainder(dividingBy: 360)
        #expect(face > 360, "\(face)")
        #expect(turn == 90, "\(face)")
        #expect(comment.contains(face), "\(face) in \(comment)")
    }
}
