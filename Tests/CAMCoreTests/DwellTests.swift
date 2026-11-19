import Foundation
import Testing
@testable import CAMCore

/// `G4 P` is seconds on LinuxCNC and in Mach4's manual, milliseconds on Masso and Fanuc-style controls (unless
/// written with a decimal point). Reading every P as seconds turned a Masso file's 2-second dwell into 2,000.
struct DwellTests {
    func dwells(_ gcode: String, _ unit: GCodeParser.DwellUnit = .automatic) throws -> (seconds: [Double], warnings: [String]) {
        let program = try GCodeParser.parse(gcode, dwellUnit: unit)
        return (program.segments.flatMap(\.motions).filter { $0.kind == .dwell }.map(\.feed), program.warnings)
    }

    @Test func wholeMillisecondsAreRecognised() throws {
        let r = try dwells("G21\nT1 M6\nS18000 M3\nG04 P2000\nG01 X10 F500\nG4 P500\n")
        #expect(r.seconds == [2, 0.5])
        #expect(r.warnings.contains { $0.contains("milliseconds") })
    }

    @Test func decimalsAndSmallWholeNumbersAreSeconds() throws {
        let r = try dwells("G20\nG04 P2\nG4 P0.5\nG04 P4.00\nG04 P1500.0\n")
        #expect(r.seconds == [2, 0.5, 4, 1500])
        #expect(r.warnings.isEmpty)
    }

    @Test func anExplicitUnitWins() throws {
        #expect(try dwells("G4 P2\nG4 P2000\n", .milliseconds).seconds == [0.002, 2])
        #expect(try dwells("G4 P2\nG4 P2000\n", .seconds).seconds == [2, 2000])
    }

    @Test func nativeCAMDwellsReadBackAsWritten() throws {
        // The Avid post always writes seconds with a decimal point (G04 P4.00), right under every reading.
        var p = Project.demoSign()
        p.machine.spindleSpinUpDwell = 4
        let gcode = AvidMach4Post(project: p).post(CAMEngine.generate(p).toolpaths)
        let r = try dwells(gcode)
        #expect(!r.seconds.isEmpty)
        #expect(r.seconds.allSatisfy { $0 == 4 })
        #expect(!r.warnings.contains { $0.contains("milliseconds") })
    }
}
