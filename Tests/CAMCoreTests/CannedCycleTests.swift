import Foundation
import Testing
@testable import CAMCore

/// Drilling cycles in G-code from other CAM programs are expanded into the moves the controller makes (LinuxCNC's
/// and Fanuc's reading), so imported files simulate their holes.
struct CannedCycleTests {
    static let header = "G21 G90\nT1 M6\nS18000 M3\nG0 Z10\nG0 X0 Y0\n"

    /// Motions after the header's two positioning rapids, as (kind, x, y, z) for easy comparison.
    func moves(_ body: String, header: String = Self.header,
               controller: Dialect? = nil) throws -> (moves: [String], warnings: [String]) {
        let program = try GCodeParser.parse(header + body, controller: controller)
        let all = program.segments.flatMap(\.motions)
        let skip = header.split(separator: "\n").filter { $0.hasPrefix("G0 ") }.count
        let text = all.dropFirst(skip).map { m -> String in
            func f(_ v: Double) -> String { String(format: "%g", (v * 1000).rounded() / 1000) }
            switch m.kind {
            case .rapid: return "R \(f(m.end.x)) \(f(m.end.y)) \(f(m.end.z))"
            case .feed: return "F \(f(m.end.x)) \(f(m.end.y)) \(f(m.end.z)) @\(f(m.feed))"
            case .dwell: return "D \(f(m.feed))"
            default: return "arc"
            }
        }
        return (text, program.warnings)
    }

    @Test func g81RetractsToTheStartingHeightUnderG98() throws {
        let r = try moves("G98 G81 X10 Y10 Z-5 R2 F300\nX20\nG80\n")
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "R 10 10 10",
            "R 20 10 10", "R 20 10 2", "F 20 10 -5 @300", "R 20 10 10",
        ])
        #expect(r.warnings.isEmpty)
    }

    @Test func g99RetractsOnlyToR() throws {
        let r = try moves("G99 G81 X10 Y10 Z-5 R2 F300\nX20\nG80\n")
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "R 10 10 2",
            "R 20 10 2", "F 20 10 -5 @300", "R 20 10 2",
        ])
    }

    @Test func g83PecksOutToRAndBackDown() throws {
        let r = try moves("G98 G83 X10 Y10 Z-5 R2 Q3 F300\nG80\n")
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2",
            "F 10 10 -1 @300", "R 10 10 2",
            "R 10 10 -0.746", "F 10 10 -4 @300", "R 10 10 2",
            "R 10 10 -3.746", "F 10 10 -5 @300",
            "R 10 10 10",
        ])
    }

    @Test func g73OnlyBacksOffToBreakTheChip() throws {
        let r = try moves("G99 G73 X10 Y10 Z-5 R2 Q3 F300\nG80\n")
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2",
            "F 10 10 -1 @300", "R 10 10 -0.746",
            "F 10 10 -4 @300", "R 10 10 -3.746",
            "F 10 10 -5 @300",
            "R 10 10 2",
        ])
    }

    @Test func g82DwellsAtTheBottomInEitherUnit() throws {
        let seconds = try moves("G99 G82 X10 Y10 Z-5 R2 P0.5 F300\nG80\n")
        #expect(seconds.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "R 10 10 2"])
        let millis = try moves("G99 G82 X10 Y10 Z-5 R2 P500 F300\nG80\n")
        #expect(millis.moves == seconds.moves)
        #expect(millis.warnings.contains { $0.contains("milliseconds") })
    }

    @Test func g85FeedsBackOut() throws {
        let r = try moves("G98 G85 X10 Y10 Z-5 R2 F300\nG80\n")
        #expect(r.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "F 10 10 2 @300", "R 10 10 10"])
    }

    @Test func inchCyclesAreConverted() throws {
        let header = "G20 G90\nT1 M6\nS18000 M3\nG0 Z0.5\nG0 X0 Y0\n"
        let r = try moves("G99 G81 X1 Y1 Z-0.25 R0.1 F10\nG80\n", header: header)
        #expect(r.moves == ["R 25.4 25.4 12.7", "R 25.4 25.4 2.54", "F 25.4 25.4 -6.35 @254", "R 25.4 25.4 2.54"])
    }

    @Test func incrementalCyclesRepeatWithL() throws {
        // G91: R is measured from the starting Z (10 - 8 = 2) and Z from R (2 - 7 = -5); L3 steps 10 mm each time.
        let r = try moves("G91 G98 G81 X10 Z-7 R-8 L3 F300\nG80 G90\n")
        #expect(r.moves == [
            "R 10 0 10", "R 10 0 2", "F 10 0 -5 @300", "R 10 0 10",
            "R 20 0 10", "R 20 0 2", "F 20 0 -5 @300", "R 20 0 10",
            "R 30 0 10", "R 30 0 2", "F 30 0 -5 @300", "R 30 0 10",
        ])
    }

    @Test func startingBelowRClimbsFirst() throws {
        let header = "G21 G90\nT1 M6\nS18000 M3\nG0 Z1\nG0 X0 Y0\n"
        let r = try moves("G98 G81 X10 Y0 Z-5 R2 F300\nG80\n", header: header)
        // Up to R before moving across, and G98 then returns to R (higher than the start).
        #expect(r.moves == ["R 0 0 2", "R 10 0 2", "F 10 0 -5 @300", "R 10 0 2"])
    }

    @Test func g80EndsTheCycleSoLaterMovesAreNormal() throws {
        let r = try moves("G99 G81 X10 Y10 Z-5 R2 F300\nG80\nG0 X50 Y50\nG1 Z-1 F100\n")
        #expect(Array(r.moves.suffix(2)) == ["R 50 50 2", "F 50 50 -1 @100"])
    }

    @Test func unsupportedAndIncompleteCyclesWarn() throws {
        let tap = try moves("G84 X10 Y10 Z-5 R2 F300\nX20\nG80\n")
        #expect(tap.moves.isEmpty)
        #expect(tap.warnings.contains { $0.contains("G84") })
        let noR = try moves("G81 X10 Y10 Z-5 F300\nG80\n")
        #expect(noR.moves.isEmpty)
        #expect(noR.warnings.contains { $0.contains("R or Z") })
        let noQ = try moves("G99 G83 X10 Y10 Z-5 R2 F300\nG80\n")
        #expect(noQ.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "R 10 10 2"])
        #expect(noQ.warnings.contains { $0.contains("Q depth") })
    }

    @Test func cycleHolesShowInTheSimulation() throws {
        let gcode = Self.header + "G98 G83 X40 Y30 Z-5 R2 Q2 F300\nX80\nG80\nG0 Z10\nM5\nM30\n"
        let program = try GCodeParser.parse(gcode)
        let stock = Fixture.stock
        let tps = program.toolpaths(tools: [Fixture.endMill], stock: stock, fallback: Fixture.endMill)
        let grid = Fixture.simulate(tps, stock: stock, cell: 0.5)
        #expect(abs(Double(try #require(grid.height(at: Vec2(40, 30)))) + 5) < 1e-3)
        #expect(abs(Double(try #require(grid.height(at: Vec2(80, 30)))) + 5) < 1e-3)
        #expect(abs(Double(try #require(grid.height(at: Vec2(60, 30))))) < 1e-3)
        #expect(!program.warnings.contains { $0.contains("expanded") })
    }

    // MARK: Tapping and boring, read for a controller that runs them

    static let mach4 = Dialect.avidMach4

    @Test func g84FeedsInReversesAndFeedsOutToRThenRapidsUnderG98() throws {
        let r = try moves("G98 G84 X10 Y10 Z-5 R2 F300\nX20\nG80\n", controller: Self.mach4)
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "F 10 10 2 @300", "R 10 10 10",
            "R 20 10 10", "R 20 10 2", "F 20 10 -5 @300", "D 0.5", "F 20 10 2 @300", "R 20 10 10",
        ])
        #expect(r.warnings.isEmpty)
    }

    @Test func g84KeepsRZAndPThroughARunUnderG99() throws {
        // The third hole changes Z only; R, P and F carry on.
        let r = try moves("G99 G84 X10 Y10 Z-5 R2 P0.3 F300\nX20\nX30 Z-8\nG80\n", controller: Self.mach4)
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "D 0.3", "F 10 10 2 @300",
            "R 20 10 2", "F 20 10 -5 @300", "D 0.5", "D 0.3", "F 20 10 2 @300",
            "R 30 10 2", "F 30 10 -8 @300", "D 0.5", "D 0.3", "F 30 10 2 @300",
        ])
    }

    @Test func g74MovesLikeG84() throws {
        for retract in ["G98", "G99"] {
            let left = try moves("\(retract) G74 X10 Y10 Z-5 R2 P0.2 F300\nX20\nG80\n", controller: Self.mach4)
            let right = try moves("\(retract) G84 X10 Y10 Z-5 R2 P0.2 F300\nX20\nG80\n", controller: Self.mach4)
            #expect(left.moves == right.moves)
            #expect(left.moves.count == (retract == "G98" ? 14 : 11))
        }
    }

    @Test func inchTapsAreConverted() throws {
        // The Mach4 Mill manual's example: a 3/8-16 tap at 1000 rpm, 0.0625 in a turn.
        let header = "G20 G90\nT1 M6\nS1000 M3\nG0 Z0.5\nG0 X0 Y0\n"
        let r = try moves("G84 G99 X1.0 Y-1.0 Z-.500 R.25 F62.5\nX2.0\nG80\n", header: header, controller: Self.mach4)
        #expect(r.moves == [
            "R 25.4 -25.4 12.7", "R 25.4 -25.4 6.35", "F 25.4 -25.4 -12.7 @1587.5", "D 0.5", "F 25.4 -25.4 6.35 @1587.5",
            "R 50.8 -25.4 6.35", "F 50.8 -25.4 -12.7 @1587.5", "D 0.5", "F 50.8 -25.4 6.35 @1587.5",
        ])
    }

    @Test func linuxCNCTapsFeedAllTheWayOutToTheRetractHeight() throws {
        let g98 = try moves("G98 G84 X10 Y10 Z-5 R2 P0.3 F300\nG80\n", controller: .linuxCNC)
        #expect(g98.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "D 0.3", "F 10 10 10 @300"])
        let g99 = try moves("G99 G74 X10 Y10 Z-5 R2 P0.3 F300\nG80\n", controller: .linuxCNC)
        #expect(g99.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "D 0.3", "F 10 10 2 @300"])
        #expect(g98.warnings.isEmpty && g99.warnings.isEmpty)
    }

    @Test func aQWordOnATapIsNotAPeck() throws {
        let r = try moves("G99 G84 X10 Y10 Z-5 R2 Q2 F300\nG80\n", controller: Self.mach4)
        #expect(r.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "F 10 10 2 @300"])
        #expect(r.warnings.contains { $0.contains("one pass") })
    }

    @Test func g88StopsForARetractByHandAtEachHole() throws {
        let body = "G99 G88 X10 Y10 Z-5 R2 P0.5 F300\nX20\nG80\n"
        let program = try GCodeParser.parse(Self.header + body, controller: Self.mach4)
        // Body lines 6 and 7 each stop at the bottom, like an M0.
        #expect(program.pauses.map(\.line) == [6, 7])
        #expect(program.pauses.allSatisfy { $0.message?.contains("by hand") == true })
        let g99 = try moves(body, controller: Self.mach4)
        #expect(g99.moves == [
            "R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 0.5", "D 10", "R 10 10 2",
            "R 20 10 2", "F 20 10 -5 @300", "D 0.5", "D 10", "R 20 10 2",
        ])
        // G98: wound out to R by hand, then a rapid on up to the starting height.
        let g98 = try moves("G98 G88 X10 Y10 Z-5 R2 F300\nG80\n", controller: Self.mach4)
        #expect(g98.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @300", "D 10", "R 10 10 2", "R 10 10 10"])
        #expect(g98.warnings.isEmpty)
    }

    @Test func g76StepsOffTheWallByIAndJBeforeRetracting() throws {
        let r = try moves("G98 G76 X10 Y10 Z-5 R2 I-0.5 J0 P0.2 F100\nX20\nG80\n", controller: Self.mach4)
        #expect(r.moves == [
            "R 10 10 10", "R 10 10 2", "F 10 10 -5 @100", "D 0.2", "D 0.5", "R 9.5 10 -5", "R 9.5 10 10", "R 10 10 10",
            "R 20 10 10", "R 20 10 2", "F 20 10 -5 @100", "D 0.2", "D 0.5", "R 19.5 10 -5", "R 19.5 10 10", "R 20 10 10",
        ])
        #expect(r.warnings.isEmpty)
    }

    @Test func g76ShiftsByQTheControllersWay() throws {
        // Mach4 reads Q the way Fanuc's parameter 5101 sets it (+X by default); CNC12's parameter 136 starts at +Y.
        let mach4 = try moves("G99 G76 X10 Y10 Z-5 R2 Q0.5 F100\nG80\n", controller: Self.mach4)
        #expect(mach4.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @100", "D 0.5", "R 10.5 10 -5", "R 10.5 10 2",
                                "R 10 10 2"])
        let centroid = try moves("G99 G76 X10 Y10 Z-5 R2 Q0.5 F100\nG80\n", controller: .centroid)
        #expect(centroid.moves == ["R 10 10 10", "R 10 10 2", "F 10 10 -5 @100", "D 0.5", "R 10 10.5 -5", "R 10 10.5 2",
                                   "R 10 10 2"])
        // Inches: the manual's own example, shifting X-.025 at the bottom.
        let header = "G20 G90\nT1 M6\nS2500 M3\nG0 Z0.5\nG0 X0 Y0\n"
        let inch = try moves("G76 G99 X1.0 Y-1.0 Z-1.0 R.25 I-.025 J0 F10.0\nG80\n", header: header, controller: Self.mach4)
        #expect(inch.moves == ["R 25.4 -25.4 12.7", "R 25.4 -25.4 6.35", "F 25.4 -25.4 -25.4 @254", "D 0.5",
                               "R 24.765 -25.4 -25.4", "R 24.765 -25.4 6.35", "R 25.4 -25.4 6.35"])
    }

    @Test func g87GoesDownThroughTheHoleAndBoresUpward() throws {
        // The Mach4 Mill manual's example: R is under the part, Z above it, the tool shifted -0.1 in X going through.
        let header = "G20 G90\nT1 M6\nS2500 M3\nG0 Z0.5\nG0 X0 Y0\n"
        let r = try moves("G87 G98 X1.0 Y-1.0 Z-0.85 R-1.05 I-.10 F10.0\nX2.0 Y-1.0\nG80\n", header: header,
                          controller: Self.mach4)
        #expect(r.moves == [
            "R 25.4 -25.4 12.7", "D 0.5", "R 22.86 -25.4 12.7", "R 22.86 -25.4 -26.67", "R 25.4 -25.4 -26.67",
            "F 25.4 -25.4 -21.59 @254", "D 0.5", "R 22.86 -25.4 -21.59", "R 22.86 -25.4 12.7", "R 25.4 -25.4 12.7",
            "R 50.8 -25.4 12.7", "D 0.5", "R 48.26 -25.4 12.7", "R 48.26 -25.4 -26.67", "R 50.8 -25.4 -26.67",
            "F 50.8 -25.4 -21.59 @254", "D 0.5", "R 48.26 -25.4 -21.59", "R 48.26 -25.4 12.7", "R 50.8 -25.4 12.7",
        ])
        #expect(r.warnings.contains { $0.contains("Back boring") })
    }

    @Test func g87AlwaysReturnsToTheStartingHeight() throws {
        // R is under the part, so G99 can't end the cycle there; P dwells at the top of the bore.
        let r = try moves("G99 G87 X10 Y10 Z-15 R-22 Q1 P0.4 F100\nG80\n", controller: Self.mach4)
        #expect(r.moves == [
            "R 10 10 10", "D 0.5", "R 11 10 10", "R 11 10 -22", "R 10 10 -22", "F 10 10 -15 @100", "D 0.4", "D 0.5",
            "R 11 10 -15", "R 11 10 10", "R 10 10 10",
        ])
        let upsideDown = try moves("G98 G87 X10 Y10 Z-22 R-15 Q1 F100\nG80\n", controller: Self.mach4)
        #expect(upsideDown.warnings.contains { $0.contains("not above its R level") })
    }

    @Test func controllersThatDontRunACycleKeepSkippingIt() throws {
        let body = "G98 G87 X10 Y10 Z-15 R-22 Q1 F100\nX20\nG80\n"
        let linux = try moves(body, controller: .linuxCNC)
        #expect(linux.moves.isEmpty)
        #expect(linux.warnings == ["G87 on LinuxCNC is accepted but not implemented, so it isn't simulated."])
        let thread = try moves("G98 G76 X10 Y10 Z-5 R2 Q0.5 F100\nG80\n", controller: .linuxCNC)
        #expect(thread.moves.isEmpty)
        #expect(thread.warnings.contains { $0.contains("lathe threading") })
        let masso = try moves("G99 G84 X10 Y10 Z-5 R2 F300\nX20\nG80\n", controller: .masso)
        #expect(masso.moves.isEmpty)
        #expect(masso.warnings.contains { $0.contains("Masso") && $0.contains("G84") })
        let centroid = try moves("G99 G88 X10 Y10 Z-5 R2 F300\nG80\n", controller: .centroid)
        #expect(centroid.moves.isEmpty)
        #expect(centroid.warnings.contains { $0.contains("G88") && $0.contains("Centroid") })
        let grblHAL = Dialect.grblFamily(ControllerProfile(family: .grblHAL), toolChange: .manualM6)
        let experimental = try moves("G99 G84 X10 Y10 Z-5 R2 P0.5 F300\nG80\n", controller: grblHAL)
        #expect(experimental.moves.isEmpty)
        #expect(experimental.warnings.contains { $0.contains("experimental") })
        // A drilling cycle after a skipped one runs as usual (the skipped hole is never visited, so Y is still 0).
        let after = try moves("G99 G84 X10 Y10 Z-5 R2 F300\nG81 X20 Z-5\nG80\n", controller: .masso)
        #expect(after.moves == ["R 20 0 10", "R 20 0 2", "F 20 0 -5 @300", "R 20 0 2"])
    }

    @Test func tappedAndBackBoredHolesShowInTheSimulation() throws {
        // A tapped hole at (40, 30); a drilled hole at (80, 30), then back bored from under the part.
        let gcode = Self.header + "G99 G84 X40 Y30 Z-5 R2 F300\nG80\n"
            + "G98 G81 X80 Y30 Z-21 R2 F300\nG80\n"
            + "G98 G87 X80 Y30 Z-15 R-22 I-1 F100\nG80\nG0 Z10\nM5\nM30\n"
        let program = try GCodeParser.parse(gcode, controller: Self.mach4)
        let stock = Fixture.stock
        let tps = program.toolpaths(tools: [Fixture.endMill], stock: stock, fallback: Fixture.endMill)
        var session = SimulationSession(toolpaths: tps, stock: stock, rapidRate: 10000, cellSize: 0.5)
        session.runToEnd()
        let grid = session.grid
        #expect(abs(Double(try #require(grid.height(at: Vec2(40, 30)))) + 5) < 1e-3)
        #expect(abs(Double(try #require(grid.height(at: Vec2(60, 30))))) < 1e-3)
        // The back bore shows as a hole right through, and going down through the drilled hole isn't a crash.
        #expect(Double(try #require(grid.height(at: Vec2(80, 30)))) <= -20)
        #expect(session.rapidCollisions.isEmpty)
    }

    @Test func runTimeCountsTheFeedsInAndOutDwellsAndStops() throws {
        let gcode = Self.header + "G98 G84 X10 Y10 Z-5 R2 P0.3 F300\nG88 X20 Z-5 P0.2\nG80\n"
        let program = try GCodeParser.parse(gcode, controller: Self.mach4)
        let stock = Fixture.stock
        let tps = program.toolpaths(tools: [Fixture.endMill], stock: stock, fallback: Fixture.endMill)
        // Tap: 7 mm in and 7 mm out at 300 mm/min, the reversal and P. Bore: 7 mm in, P, and the stop.
        let feeds = 3 * 7 / 300.0 * 60
        let stops = GCodeParser.tapReversalSeconds + 0.3 + 0.2 + GCodeParser.manualRetractSeconds
        // The header's climb to Z10, then each hole's rapids (the bore wound out to R by hand counts as one).
        let rapids = 10 + (2 * 100.0).squareRoot() + 8 + 8 + 10 + 8 + 7 + 8
        let timeline = SimulationTimeline(toolpaths: tps, rapidRate: 10000)
        #expect(abs(timeline.duration - (feeds + stops + rapids / 10000 * 60)) < 1e-6)
        // The planner's estimate adds acceleration, never less.
        let estimate = CycleTimeEstimator.estimate(tps, project: Project(name: "Tap", displayUnits: .mm, stock: stock))
        #expect(estimate.feedSeconds >= feeds - 1e-9)
        #expect(estimate.overheadSeconds >= stops - 1e-9)
    }
}
