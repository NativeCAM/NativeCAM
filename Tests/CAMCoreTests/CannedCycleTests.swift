import Foundation
import Testing
@testable import CAMCore

/// Drilling cycles in G-code from other CAM programs are expanded into the moves the controller makes (LinuxCNC's
/// and Fanuc's reading), so imported files simulate their holes.
struct CannedCycleTests {
    static let header = "G21 G90\nT1 M6\nS18000 M3\nG0 Z10\nG0 X0 Y0\n"

    /// Motions after the header's two positioning rapids, as (kind, x, y, z) for easy comparison.
    func moves(_ body: String, header: String = Self.header) throws -> (moves: [String], warnings: [String]) {
        let program = try GCodeParser.parse(header + body)
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
}
