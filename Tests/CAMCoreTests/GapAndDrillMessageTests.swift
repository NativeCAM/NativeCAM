import Foundation
import Testing
@testable import CAMCore

/// The wording of three messages, in inch and mm jobs: the on-line cut refusal states the real gap to the other part
/// (#194), and Drill's warnings suggest Helical bore and give the finishing allowance's range in the job's units (#196).
struct GapAndDrillMessageTests {
    typealias Inside = PartGapInsideTests
    typealias Bore = HelicalBoreCatalogTests

    /// The number before " in" / " mm" after "comes within " in a refusal, in mm.
    static func reported(_ message: String, units: LengthUnit) -> Double? {
        guard let r = message.range(of: "comes within ") else { return nil }
        let rest = message[r.upperBound...]
        guard let number = rest.split(separator: " ").first, let value = Double(number) else { return nil }
        #expect(rest.dropFirst(number.count).hasPrefix(" \(units.symbol) "), "\(message)")
        return units.toMM(value)
    }

    /// A groove 0.115 in and 0.125 in from a pocket: refused, stating the gap less the pocket's 0.1 mm band, the same way
    /// the outside-cut refusal does, not a constant bit radius less the tolerance.
    static let lineCases: [(name: String, gap: Double)] = [("line-into-pocket", 0.115.inch), ("line-at-bit-radius-from-pocket", 0.125.inch)]

    @Test(arguments: lineCases.indices, LengthUnit.allCases)
    func onLineRefusalStatesTheRealGap(_ k: Int, _ units: LengthUnit) throws {
        let (name, gap) = Self.lineCases[k]
        var p = try Inside.saved(name) { Inside.lineBesidePocket(gap: gap) }
        p.displayUnits = units
        let job = CAMEngine.generate(p)
        let groove = try #require(job.toolpaths.first { $0.name == "Cut groove" })
        let error = try #require(groove.errors?.first)
        let stated = try #require(Self.reported(error, units: units), "\(error)")
        let expected = gap - ProtectedRegions.bandWidth
        // To the shown precision (0.0001 in, 0.001 mm), less what the offsets' arc tolerance moves the band.
        #expect(abs(stated - expected) < 0.01, "\(name) \(units): \(error)")
        // Still the bit's reach either side of the line.
        #expect(error.contains("closer than its \(units.format(0.125.inch)) \(units.symbol) reach either side of the line"), "\(error)")
    }

    @Test func theTwoGroovesStateDifferentGaps() throws {
        let messages = try Self.lineCases.map { c in
            let p = try Inside.saved(c.name) { Inside.lineBesidePocket(gap: c.gap) }
            return try #require(CAMEngine.generate(p).toolpaths.first { $0.name == "Cut groove" }?.errors?.first)
        }
        #expect(messages[0] != messages[1])
        #expect(messages[0].contains("within 0.1111 in"), "\(messages[0])")
        #expect(messages[1].contains("within 0.1211 in"), "\(messages[1])")
    }

    /// Plunge with a hole bigger than the bit: Helical bore is suggested first, then a pocket or inside profile.
    @Test(arguments: LengthUnit.allCases)
    func plungeWarningSuggestsHelicalBoreFirst(_ units: LengthUnit) throws {
        let hole = Bore.circle(1, "Bolt hole", diameter: 0.5.inch, at: Vec2(50, 50))
        var p = Bore.project("Plunged bolt hole", shapes: [hole], ops: [Bore.drill(11, "Holes", shapes: [hole], depth: 0.25.inch, helix: nil)])
        p.displayUnits = units
        let job = CAMEngine.generate(p)
        let warning = try #require(job.issues.first { $0.message.contains("hole is larger than the tool") }?.message)
        #expect(warning == "Bolt hole: hole is larger than the tool; choose Drill ▸ Method ▸ Helical bore, or use a pocket or inside "
            + "profile, to size it.")
        let helical = try #require(warning.range(of: "Helical bore")), pocket = try #require(warning.range(of: "pocket"))
        #expect(helical.lowerBound < pocket.lowerBound)
    }

    /// A finishing allowance outside 0.05–0.5 mm: the range is in the job's units, like the allowance itself.
    @Test(arguments: [(LengthUnit.inch, "The finishing allowance (0.0394 in) is outside 0.0020–0.0197 in"),
                      (LengthUnit.mm, "The finishing allowance (1.000 mm) is outside 0.050–0.500 mm")])
    func allowanceWarningStatesItsRangeInTheJobsUnits(_ units: LengthUnit, _ expected: String) throws {
        let hole = Bore.circle(1, "Bolt hole", diameter: 0.5.inch, at: Vec2(50, 50))
        let helix = HelixBore(direction: .conventional, finishAllowance: 1)
        var p = Bore.project("Wide allowance", shapes: [hole], ops: [Bore.drill(11, "Holes", shapes: [hole], depth: 0.25.inch, helix: helix)])
        p.displayUnits = units
        let job = CAMEngine.generate(p)
        let warning = try #require(job.issues.first { $0.message.contains("finishing allowance") }?.message)
        #expect(warning.hasPrefix(expected + ": too little rubs, too much loads the finishing lap."), "\(warning)")
    }
}
