import Foundation
import Testing
@testable import CAMCore

/// The starter tool library: its feeds and speeds against the chip-load chart (#23), and the larger end mill rest
/// machining picks (#22).
struct StarterLibraryTests {
    static let lib = ToolLibrary.starter

    /// Inches per tooth, for readable failure messages.
    static func perTooth(_ mm: Double) -> String { String(format: "%.4f in", mm / LengthUnit.mmPerInch) }

    // MARK: Feeds and speeds

    @Test func everyChartedStarterToolIsInsideTheChartForTheMaterialsItClaims() {
        let charted = Self.lib.tools.filter { ChipLoad.applies(to: $0) }
        #expect(charted.map(\.number) == [1, 2, 3, 4, 7, 10])
        for tool in charted {
            for material in ToolLibrary.starterMaterials {
                let range = ChipLoad.range(material, diameter: tool.diameter)
                let chip = tool.chipLoad
                #expect(range.contains(chip),
                        "T\(tool.number) \(tool.name): \(Self.perTooth(chip)) is outside \(material.label)'s \(Self.perTooth(range.lowerBound))–\(Self.perTooth(range.upperBound))")
            }
        }
    }

    /// Thicker chips come from a slower spindle, not a faster feed: every feed stays within the cutting cap of Avid's
    /// slowest drives, and every speed within the default spindle's range.
    @Test func everyStarterToolFitsTheSlowestAvidDriveAndTheSpindle() {
        let spindle = MachineProfile.avidPRO6060
        for tool in Self.lib.tools {
            let rpm = tool.cutting.spindleRPM
            #expect(tool.cutting.feedRate <= 250.inch + 1e-9, "T\(tool.number) \(tool.name) feeds faster than 250 in/min")
            #expect(rpm >= spindle.minRPM && rpm <= spindle.maxRPM, "T\(tool.number) \(tool.name) at \(Int(rpm)) RPM")
        }
    }

    /// A job in each claimed material raises no chip-load warning for any charted starter tool.
    @Test func starterToolsRaiseNoChipLoadIssueInPlywoodOrHardwood() {
        let shape = DesignShape(kind: .rectangle(width: 50, height: 50, cornerRadius: 0), position: Vec2(100, 75))
        for material in ToolLibrary.starterMaterials {
            for tool in Self.lib.tools where ChipLoad.applies(to: tool) {
                let op = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [shape.id], tool: tool)
                let stock = Stock(width: 200, height: 150, thickness: 19, materialKind: material)
                let job = CAMEngine.generate(Project(stock: stock, shapes: [shape], operations: [op]))
                let chipIssues = job.issues.filter { $0.message.hasPrefix("Chip load") }
                #expect(chipIssues.isEmpty, "T\(tool.number) in \(material.label): \(chipIssues.map(\.message))")
            }
        }
    }

    /// Existing tools keep their fixed IDs, numbers and names, so projects and saved libraries still match them; new
    /// tools only add numbers.
    @Test func starterNumbersAndIDsAreStable() {
        let names = Self.lib.tools.map { "T\($0.number) \($0.name)" }
        #expect(names == ["T1 1/4\" Upcut End Mill", "T2 1/8\" Upcut End Mill", "T3 1/4\" Downcut End Mill",
                          "T4 1/4\" Compression End Mill", "T5 60° V-Bit 1/2\"", "T6 90° V-Bit 1/2\"", "T7 1/4\" Ball Nose",
                          "T8 1-1/4\" Surfacing Bit", "T9 30° Engraving 0.010\" Tip", "T10 1/2\" Upcut End Mill"])
        for tool in Self.lib.tools {
            #expect(tool.id.uuidString == String(format: "4E415449-5645-4341-4D00-%012d", tool.number))
        }
    }

    @Test func halfInchEndMillHasFullGeometry() throws {
        let half = try #require(Self.lib.tool(number: 10))
        #expect(half.shape == .flatEndMill && half.fluteDirection == .upcut && half.fluteCount == 2)
        #expect(half.diameter == 0.5.inch && half.shankDiameter == 0.5.inch && half.fluteLength == 1.25.inch)
        #expect(half.stickout > half.fluteLength)
        #expect(half.cutting.stepdown == 0.25.inch && half.cutting.plungeRate > 0)
    }

    // MARK: Clearance tool for rest machining

    @Test func quarterInchPocketClearsWithTheHalfInchEndMill() throws {
        let quarter = try #require(Self.lib.tool(number: 1))
        #expect(Self.lib.clearanceTool(for: quarter)?.number == 10)
        let eighth = try #require(Self.lib.tool(number: 2))
        // The 1/4" upcut, not the downcut or compression bit of the same size.
        #expect(Self.lib.clearanceTool(for: eighth)?.number == 1)
        let half = try #require(Self.lib.tool(number: 10))
        #expect(Self.lib.clearanceTool(for: half) == nil)
    }

    /// The pick for a 1/4" pocket cuts the pocket with two bits and no "isn't larger" warning.
    @Test func thePickedToolGivesARestMachinedPocketWithoutWarnings() throws {
        let quarter = try #require(Self.lib.tool(number: 1))
        let large = try #require(Self.lib.clearanceTool(for: quarter))
        let square = Fixture.rect(100, 80, at: Vec2(100, 75))
        let op = CAMOperation(name: "Pocket", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 6), clearanceTool: large)),
                              shapeIDs: [square.id], tool: quarter)
        let job = CAMEngine.generate(Fixture.project(shapes: [square], ops: [op]))
        #expect(!job.hasErrors)
        #expect(job.toolpaths.map(\.tool.number) == [10, 1])
        let warnings = job.issues.filter { $0.severity == .warning }.map(\.message)
        #expect(warnings.isEmpty, "\(warnings)")
    }

    /// Without the 1/2" (a library saved before it was added), a 1/4" pocket has nothing to clear with: the surfacing
    /// bit is larger but isn't offered.
    @Test func noLargerEndMillPicksNothing() throws {
        let old = ToolLibrary(tools: Self.lib.tools.filter { $0.number != 10 })
        let quarter = try #require(old.tool(number: 1))
        #expect(old.clearanceTool(for: quarter) == nil)
        #expect(old.clearanceTool(for: try #require(old.tool(number: 2)))?.number == 1)
    }

    @Test func prefersABitHalfAsBigAgainThenTheLargestLargerOne() {
        func mill(_ n: Int, _ d: Double, _ direction: FluteDirection = .upcut) -> Tool {
            Tool(number: n, name: "T\(n)", shape: .flatEndMill, fluteDirection: direction, diameter: d.inch, fluteLength: 1.inch,
                 cutting: CuttingData(spindleRPM: 18000, feedRate: 100.inch, plungeRate: 20.inch, stepdown: 0.1.inch, stepoverFraction: 0.4))
        }
        let eighth = mill(1, 0.125)
        // A 5/32" is barely larger; the 1/4" is worth the tool change.
        #expect(ToolLibrary(tools: [eighth, mill(2, 0.15625), mill(3, 0.25), mill(4, 0.5)]).clearanceTool(for: eighth)?.number == 3)
        // Exactly half as big again counts.
        #expect(ToolLibrary(tools: [eighth, mill(2, 0.1875), mill(3, 0.25)]).clearanceTool(for: eighth)?.number == 2)
        // Nothing half as big again: the largest that's still larger.
        #expect(ToolLibrary(tools: [eighth, mill(2, 0.15), mill(3, 0.16)]).clearanceTool(for: eighth)?.number == 3)
        // Same size: the upcut, then the lowest number.
        let sameSize = ToolLibrary(tools: [eighth, mill(5, 0.25, .downcut), mill(7, 0.25), mill(6, 0.25)])
        #expect(sameSize.clearanceTool(for: eighth)?.number == 6)
        // Equal or smaller bits and non-end-mills are never picked.
        var ball = mill(8, 0.5)
        ball.shape = .ballNose
        #expect(ToolLibrary(tools: [eighth, mill(2, 0.125), mill(3, 0.0625), ball]).clearanceTool(for: eighth) == nil)
    }
}
