import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for the reach of flutes that follow a 3D model (#203): the stickout error and the cutting-length
/// warning measure the bit's reach from the material actually left above each flute move, not from the flute's depth
/// below the model alone. Saved projects in `Fixtures/flute-reach`, each with an Avid Mach4 golden:
///
/// - the turned leg sunk about an inch inside a bigger wrapped blank, fluted *before* its 3D rotary finish: the bit
///   would go through the uncut stock to the leg, past its 1" stickout, so it's an error;
/// - the same, fluted *after* the finish: the finish has cleared the stock, so no error or warning, as before #203;
/// - the column face sunk 0.9" into a 2" board under a 0.3" pocket: what's left above it plus the flute depth is
///   more than the bit's cutting length but less than its stickout, so it's the warning and not the error.
struct FluteReachCatalogTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("flute-reach")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "20300000-0000-4000-8000-%012d", n))! }

    /// The 1/4" ball nose let out 1" from the collet: less than the uncut stock over the sunk models.
    static let shortBall: Tool = {
        var t = FlutesOnModelCatalogTests.ball
        t.stickout = 1.inch
        t.cutting.spindleRPM = 16000
        return t
    }()

    /// A second 1/4" ball nose, let out 2.5" for the 3D finish that cuts down to the sunk leg.
    static let longBall: Tool = {
        var t = FlutesOnModelCatalogTests.ball
        t.id = id(1)
        t.number = 17
        t.name = "1/4\" Ball Nose, long"
        t.stickout = 2.5.inch
        t.cutting.spindleRPM = 16000
        return t
    }()

    // MARK: The sunk leg

    /// The flutes' leg (`FlutesOnModelCatalogTests.leg()`, 13 to 22 mm radius) in a 3.75" blank, 47.6 mm radius: 25 to
    /// 35 mm of stock over it.
    static let bigBlank = RotaryStock(shape: .cylinder, diameter: 3.75.inch, length: 260, layout: .wrapped)

    /// The leg's 3D rotary finish with the long ball, over the length the flutes run along.
    static func finish() -> CAMOperation {
        CAMOperation(id: id(10), name: "Finish leg",
                     kind: .rotaryFinish(RotaryFinishParams(stepoverFraction: 0.3, startX: 50, endX: 220, sampleSpacing: 1,
                                                            passDepth: 3.175)),
                     shapeIDs: [FlutesOnModelCatalogTests.id(4)], tool: longBall)
    }

    /// The leg's six flutes with the short ball, in the big blank, cut before or after its 3D finish.
    static func legProject(flutesFirst: Bool) -> Project {
        var p = FlutesOnModelCatalogTests.rotaryProject()
        p.name = flutesFirst ? "Leg fluted before its finish" : "Leg fluted after its finish"
        p.stock.setRotary(bigBlank)
        p.operations[0].tool = shortBall
        p.operations = flutesFirst ? [p.operations[0], finish()] : [finish(), p.operations[0]]
        return p
    }

    // MARK: The sunk column

    /// The column face sunk 0.9" into a 2" board (its crown 0.9" below the top, its edges 1.3"), under a 0.3" pocket a
    /// little bigger than it, then fluted with the short ball: 0.6" to 0.79" of stock left over the flutes, and up to 0.1"
    /// more for their depth, past the ball's 0.75" cutting length but within its 1" stickout.
    static func sunkColumnProject() -> Project {
        var p = FlutesOnModelCatalogTests.flatProject()
        p.name = "Sunk column under a pocket"
        p.stock.thickness = 2.inch
        let column = p.shapes.firstIndex { $0.modelSpec != nil }!
        if case var .model(spec) = p.shapes[column].kind {
            spec.topOffset = 0.9.inch
            p.shapes[column].kind = .model(spec)
        }
        let foot = FlutesOnModelCatalogTests.columnFootprint
        let margin = 0.5.inch
        let w = foot.max.x - foot.min.x + 2 * margin, h = foot.max.y - foot.min.y + 2 * margin
        let area = DesignShape(id: id(20), name: "Pocket over the column", kind: .rectangle(width: w, height: h, cornerRadius: 0),
                               position: Vec2(foot.min.x - margin + w / 2, foot.min.y - margin + h / 2))
        p.shapes.append(area)
        let endMill = ToolLibrary.starter.tool(number: 1)! // 1/4" upcut end mill
        let pocket = CAMOperation(id: id(21), name: "Clear over the column",
                                  kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.3.inch))), shapeIDs: [area.id], tool: endMill)
        p.operations[0].tool = shortBall
        p.operations.insert(pocket, at: 0)
        return p
    }

    // MARK: Helpers

    /// Loads a saved project. Update mode writes a missing one from `make`, but never replaces one.
    static func saved(_ name: String, make: () -> Project) throws -> Project {
        let url = dir.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func flutes(_ job: JobResult) -> [JobIssue] { job.issues.filter { $0.operation?.hasPrefix("Flutes") == true || $0.operation?.hasPrefix("Leg flutes") == true } }

    static func posted(_ p: Project, _ job: JobResult, golden: String) throws {
        try GoldenPostTests.check(GoldenPostTests.post(p, job.toolpaths), golden: golden)
    }

    // MARK: Tests

    /// Fluted before its finish, the ball would go through 25 to 35 mm of uncut stock to the leg and 1.5 mm into it, past
    /// its 1" stickout: an error naming the stock over the model, not the flutes' 1.5 mm depth.
    @Test func flutesBeforeTheFinishAreAnError() throws {
        let p = try Self.saved("leg-flutes-before-finish") { Self.legProject(flutesFirst: true) }
        #expect(p == Self.legProject(flutesFirst: true))
        let job = CAMEngine.generate(p)
        let errors = Self.flutes(job).filter { $0.severity == .error }
        #expect(errors.count == 1, "\(job.issues.map(\.message))")
        let error = try #require(errors.first)
        #expect(error.message.contains("collet nut would hit the stock"), "\(error.message)")
        #expect(error.message.contains("stock over the 3D model"), "\(error.message)")
        #expect(job.hasErrors)
        try Self.posted(p, job, golden: "flute-reach-leg-before-finish")
    }

    /// Fluted after its finish, the finish has cleared the stock over the leg: no error and no cutting-length warning,
    /// as before #203, and the flutes are the same moves as before.
    @Test func flutesAfterTheFinishAreFine() throws {
        let p = try Self.saved("leg-flutes-after-finish") { Self.legProject(flutesFirst: false) }
        #expect(p == Self.legProject(flutesFirst: false))
        let job = CAMEngine.generate(p)
        let bad = Self.flutes(job).filter { $0.severity != .info }
        #expect(bad.isEmpty, "\(bad.map(\.message))")
        #expect(!job.issues.contains { $0.severity == .error }, "\(job.issues.map(\.message))")
        // The flutes themselves don't change with their order.
        let before = CAMEngine.generate(Self.legProject(flutesFirst: true)).toolpaths.first { $0.name == "Leg flutes" }
        let after = job.toolpaths.first { $0.name == "Leg flutes" }
        #expect(before?.motions == after?.motions)
        try Self.posted(p, job, golden: "flute-reach-leg-after-finish")

        // The finish counts as having cleared the stock: with a bit let out less than the flutes' 1.5 mm, the error is
        // the flute depth's, not the stock's.
        var stubby = p
        stubby.operations[1].tool.stickout = 1
        let short = Self.flutes(CAMEngine.generate(stubby)).filter { $0.severity == .error }
        #expect(short.count == 1 && short[0].message.hasPrefix("Depth 1.500 mm is more than"), "\(short.map(\.message))")
    }

    /// The column sunk under a 0.3" pocket: 0.6" to 0.79" left over the flutes plus their 0.1" is past the ball's 0.75"
    /// cutting length (a warning) but within its 1" stickout (no error). Without the pocket, the 0.9" to 1.09" over the
    /// column plus 0.1" is past the stickout: the error.
    @Test func flutesOnAColumnSunkUnderAPocket() throws {
        let p = try Self.saved("column-sunk-under-pocket", make: Self.sunkColumnProject)
        #expect(p == Self.sunkColumnProject())
        let job = CAMEngine.generate(p)
        let issues = Self.flutes(job)
        #expect(!issues.contains { $0.severity == .error }, "\(issues.map(\.message))")
        let warning = issues.first { $0.message.contains("exceeds the cutting length") }
        #expect(warning?.message.contains("stock over the 3D model") == true, "\(issues.map(\.message))")
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        try Self.posted(p, job, golden: "flute-reach-column-sunk-under-pocket")

        var bare = p
        bare.operations.removeFirst()
        let bareJob = CAMEngine.generate(bare)
        #expect(Self.flutes(bareJob).contains { $0.severity == .error && $0.message.contains("collet nut would hit the stock") },
                "\(bareJob.issues.map(\.message))")
    }

    /// On the column as the flutes' catalog has it (its crown at the material top), the flutes keep the result they
    /// always had: no warning, though there's up to 0.23" of stock over the column's sides.
    @Test func flutesOnAColumnAtTheTopAreUnchanged() {
        let job = CAMEngine.generate(FlutesOnModelCatalogTests.flatProject())
        #expect(!job.issues.contains { $0.severity != .info }, "\(job.issues.map(\.message))")
    }
}
