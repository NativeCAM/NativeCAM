import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for rest machining (#83): a 3D rest pass and a pocket resting from an earlier pocket, each posted
/// for Avid's Mach4 default and compared byte for byte (`Fixtures/golden`); a saved format-17 project; and saved projects
/// for the edge cases (`Fixtures/rest-machining`), each test asserting what NativeCAM does with it. The posts write rest
/// toolpaths like any other, so other controllers have no goldens of their own here.
struct RestCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("rest-machining")

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "2E570000-0000-4000-8002-%012d", n))! }

    /// Posts `p` for Avid's Mach4 profile, compares it with the golden and runs the export checks on it.
    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    // MARK: Goldens

    /// The valley finished with the 1/4" ball, then rested with the 1/16" tapered ball nose, in inches.
    static func taperedRest() -> Project { RestFinishingTests.valleyProject(units: .inch, name: "Tapered ball rest") }

    /// The slotted pocket cleared with the 1/4" end mill, then the 1/8" resting from it, in inches.
    static func pocketRest() -> Project {
        var p = RestFromEarlierTests.project(units: .inch)
        p.name = "Pocket rest from earlier"
        p.machine.outputArcs = true
        return p
    }

    @Test func taperedRestGolden() throws {
        let p = Self.taperedRest()
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "rest-3d-tapered-inch")
    }

    @Test func pocketRestGolden() throws {
        let p = Self.pocketRest()
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "rest-pocket-earlier-inch")
    }

    // MARK: Saved project

    /// Every new setting away from its default, saved as format 17: the valley finished by the 1/4" ball and rested by
    /// the tapered ball nose (its reference named, a tolerance and margin of its own, cross-hatched, with the pencil pass),
    /// and the slotted pocket cleared by the 1/4" end mill then rested from by the 1/8".
    static func savedProject() -> Project {
        var valley = RestFinishingTests.valley(meshID: id(1), shapeID: id(2))
        valley.position = Vec2(40, 30)
        let slotted = RestFromEarlierTests.slotted
        var finishTool = RestFinishingTests.ball
        finishTool.id = id(3)
        let ops = [
            CAMOperation(id: id(4), name: "Finish valley",
                         kind: .finish3D(Finish3DParams(stepoverFraction: 0.2, rasterAngle: 0, boundary: .model)), shapeIDs: [valley.id],
                         tool: finishTool),
            CAMOperation(id: id(5), name: "Rest valley",
                         kind: .finish3D(Finish3DParams(stepoverFraction: 0.25, rasterAngle: 90, allowance: 0, boundary: .model, strategy: .rest,
                                                        crossHatch: true,
                                                        rest: RestSettings(references: [id(4)], tolerance: 0.03, margin: 0.4, pencil: true))),
                         shapeIDs: [valley.id], tool: RestFinishingTests.tapered),
            RestFromEarlierTests.pocket(id(6), "Pocket 1/4\"", tool: RestFromEarlierTests.quarter, shapes: [slotted]),
            RestFromEarlierTests.pocket(id(7), "Rest 1/8\"", tool: RestFromEarlierTests.eighth, rest: true, shapes: [slotted]),
        ]
        return Project(name: "Rest machining (format 17)", displayUnits: .mm, stock: Fixture.stock, machine: .avidPRO6060,
                       shapes: [valley, slotted], operations: ops, notes: "Saved by format 17 to pin rest machining.")
    }

    @Test func savedRestProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("rest-3d-v17", make: Self.savedProject)
        #expect(p.formatVersion == 17)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 4 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "decoded-rest-3d-v17")
    }

    // MARK: Edge cases

    /// The valley with its two finishes, with `change` applied.
    static func valley(_ change: (inout Project) -> Void) -> Project {
        var p = RestFinishingTests.valleyProject(name: "Rest edge case")
        change(&p)
        return p
    }

    static func setReferences(_ p: inout Project, _ ids: [UUID]?) {
        guard let k = p.operations.firstIndex(where: { $0.id == RestFinishingTests.id(3) }),
              case var .finish3D(fp) = p.operations[k].kind else { return }
        fp.rest?.references = ids
        p.operations[k].kind = .finish3D(fp)
    }

    /// A reference with a smaller bit than the rest pass's: refused, saying why, and nothing posted for it.
    @Test func referenceSmallerThanTheRestToolIsRefused() throws {
        let p = try Self.edgeCase("reference-smaller") {
            Self.valley { p in
                p.operations[0].tool = RestFinishingTests.eighthBall
                p.operations[1].tool = RestFinishingTests.ball
                Self.setReferences(&p, [RestFinishingTests.id(2)])
            }
        }
        let job = CAMEngine.generate(p)
        let rest = try #require(job.toolpaths.first { $0.id == RestFinishingTests.id(3) })
        #expect(rest.isEmpty)
        #expect(rest.warnings.contains { $0.contains("isn't smaller than '1/8\" Ball Nose'") })
        let gcode = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!gcode.contains("Rest valley"))
    }

    /// A gentle cap finished with the 1/4" ball, inside its outline: the ball reaches it all, so the rest pass has nothing
    /// to cut. It's empty, says so, and posts nothing.
    @Test func nothingLeftToCut() throws {
        let p = try Self.edgeCase("nothing-left") {
            Self.valley { p in
                let cap = DesignShape(id: RestFinishingTests.id(11), name: "Cap",
                                      kind: .model(ModelSpec(mesh: hemisphereMesh(radius: 9, rings: 24, segments: 64), depth: 3)),
                                      position: Vec2(15, 10))
                p.shapes = [cap]
                for k in p.operations.indices {
                    guard case var .finish3D(fp) = p.operations[k].kind else { continue }
                    fp.boundary = .model
                    p.operations[k].kind = .finish3D(fp)
                }
            }
        }
        let job = CAMEngine.generate(p)
        let rest = try #require(job.toolpaths.first { $0.id == RestFinishingTests.id(3) })
        #expect(rest.isEmpty)
        #expect(rest.restAreas == [])
        #expect(rest.warnings.contains { $0.hasPrefix("Nothing left to cut") })
        #expect(job.issues.contains { $0.operation == "Rest valley" && $0.message.hasPrefix("Nothing left to cut") })
        #expect(!job.issues.contains { $0.message == "Toolpath is empty." })
        let gcode = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!gcode.contains("Rest valley") && !gcode.contains("T12"))
    }

    /// A reference that's turned off: Checks says the rest pass still assumes it was cut, and the rest areas are worked
    /// out as if it had been.
    @Test func disabledReferenceIsReported() throws {
        let p = try Self.edgeCase("reference-disabled") {
            Self.valley { p in
                p.operations[0].enabled = false
                Self.setReferences(&p, [RestFinishingTests.id(2)])
            }
        }
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.map(\.id) == [RestFinishingTests.id(3)])
        let rest = try #require(job.toolpaths.first)
        #expect(!rest.isEmpty)
        #expect(rest.warnings.contains { $0.contains("“Finish valley”, one of its references, is turned off") })
        let enabled = CAMEngine.generate(RestFinishingTests.valleyProject()).toolpaths.last
        #expect(rest.restAreas == enabled?.restAreas)
    }

    /// A reference that runs after the rest pass: Checks says so, and Optimize Run Order puts it first.
    @Test func referenceThatRunsLaterIsReportedAndReordered() throws {
        let p = try Self.edgeCase("reference-runs-later") {
            Self.valley { p in
                p.operations.swapAt(0, 1)
                Self.setReferences(&p, [RestFinishingTests.id(2)])
            }
        }
        #expect(p.operations.map(\.name) == ["Rest valley", "Finish valley"])
        let job = CAMEngine.generate(p)
        let rest = try #require(job.toolpaths.first { $0.id == RestFinishingTests.id(3) })
        #expect(rest.warnings.contains { $0.hasPrefix("Runs before “Finish valley”, one of its references") })
        #expect(!job.issues.contains { $0.message.contains("Runs before its roughing") })
        let order = OperationScheduler.optimize(p)
        #expect(order.outOfOrder == [.init(operation: RestFinishingTests.id(2), mustPrecede: RestFinishingTests.id(3))])
        #expect(order.order == [RestFinishingTests.id(2), RestFinishingTests.id(3)])
        var fixed = p
        fixed.applyRunOrder(order.order)
        let after = CAMEngine.generate(fixed).toolpaths.first { $0.id == RestFinishingTests.id(3) }
        #expect(after?.warnings.isEmpty == true)
    }

    /// A pocket resting from a larger round pocket that reached all of it: empty, says so, posts nothing.
    @Test func pocketWithNothingLeft() throws {
        let p = try Self.edgeCase("pocket-nothing-left") {
            RestFromEarlierTests.project(shapes: [DesignShape(id: Self.id(20), name: "Round pocket", kind: .circle(radius: 20),
                                                              position: Vec2(100, 75))])
        }
        let job = CAMEngine.generate(p)
        let rest = try #require(job.toolpaths.last)
        #expect(rest.isEmpty && rest.warnings.contains { $0.hasPrefix("Nothing left to cut") })
        #expect(job.toolpaths.filter { !$0.isEmpty }.count == 1)
    }
}
