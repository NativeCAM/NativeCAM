import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for chamfer options (#90): a V-bit chamfer with an overcut and a round-nose chamfer, each posted
/// for Avid's Mach4 default and compared byte for byte (`Fixtures/golden`); a saved format-19 project; and saved
/// projects for the edge cases (`Fixtures/chamfer`), each test asserting what NativeCAM does with it. The posts write
/// chamfers like any other toolpath, so other controllers have no goldens of their own here.
struct ChamferCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("chamfer")

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "C4A3F000-0000-4000-8090-%012d", n))! }

    static var vBit: Tool {
        var t = Fixture.vBit90
        t.id = id(900)
        return t
    }

    static var roundover: Tool { EdgeProfileTests.form(.roundover, radius: 0.25.inch, number: 5, id: 960) }

    static func project(_ name: String, shapes: [DesignShape], ops: [CAMOperation]) -> Project {
        Project(name: name, displayUnits: .inch, stock: EdgeProfileTests.stock, machine: .avidPRO6060, shapes: shapes, operations: ops)
    }

    static func chamfer(_ params: ChamferParams, tool: Tool, shapes: [UUID], id opID: UUID, name: String) -> CAMOperation {
        CAMOperation(id: opID, name: name, kind: .chamfer(params), shapeIDs: shapes, tool: tool)
    }

    // MARK: Goldens

    /// A 90° V-bit chamfer 1/8" wide round the top of the 6 × 4" board's outline, with a 0.02" overcut.
    static func overcut() -> Project {
        let board = EdgeProfileTests.board(id(1))
        return project("Chamfer overcut", shapes: [board], ops: [
            chamfer(ChamferParams(side: .outside, edge: .top, width: 0.125.inch, overcut: 0.02.inch), tool: vBit, shapes: [board.id],
                    id: id(2), name: "Chamfer with overcut"),
        ])
    }

    /// A 1/4" roundover chamfer 3/16" wide on the board's top edge before its cut-out (bottom edge, inside).
    static func roundNose() -> Project {
        let board = EdgeProfileTests.board(id(3))
        return project("Chamfer round nose", shapes: [board], ops: [
            chamfer(ChamferParams(side: .inside, edge: .bottom, width: 0.1875.inch), tool: roundover, shapes: [board.id],
                    id: id(4), name: "Round-nose chamfer"),
        ])
    }

    @Test func overcutGolden() throws {
        let p = Self.overcut()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty && tp.warnings.isEmpty, "\(tp.warnings)")
        try EdgeProfileCatalogTests.checkGolden(p, "chamfer-overcut-inch")
    }

    @Test func roundNoseGolden() throws {
        let p = Self.roundNose()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty && tp.warnings.isEmpty, "\(tp.warnings)")
        let depth = try #require(EdgeProfileParams.formDepth(reaching: 0.1875.inch, tool: Self.roundover))
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.min.z + depth) < 1e-6)
        try EdgeProfileCatalogTests.checkGolden(p, "chamfer-roundnose-inch")
    }

    // MARK: Saved project

    /// Both options saved as format 19: a top-edge chamfer on both sides of a hexagon with a 0.03" overcut, conventional,
    /// from a 0.05" start depth in passes of 0.05"; and a 3/8" cove chamfer 1/4" wide outside the board, its top edge on
    /// the vector.
    static func savedProject() -> Project {
        let board = EdgeProfileTests.board(id(10))
        let hex = DesignShape(id: id(11), name: "Hexagon", kind: .polygon(sides: 6, radius: 1.inch), position: Vec2(4.inch, 3.inch))
        var cove = EdgeProfileTests.cove
        cove.id = id(901)
        cove.number = 7
        let ops = [
            chamfer(ChamferParams(side: .both, edge: .top, width: 0.1.inch, startDepth: 0.05.inch, passDepth: 0.05.inch,
                                  direction: .conventional, overcut: 0.03.inch),
                    tool: vBit, shapes: [hex.id], id: id(12), name: "Hexagon overcut"),
            chamfer(ChamferParams(side: .outside, edge: .top, width: 0.25.inch), tool: cove, shapes: [board.id], id: id(13),
                    name: "Cove chamfer"),
        ]
        var p = project("Chamfer options (format 19)", shapes: [board, hex], ops: ops)
        p.notes = "Saved by format 19 to pin chamfer overcuts and round-nose chamfers."
        return p
    }

    @Test func savedChamferProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("chamfer-v19", make: Self.savedProject)
        #expect(p.formatVersion == 19)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try EdgeProfileCatalogTests.checkGolden(p, "decoded-chamfer-v19")
    }

    /// With `NATIVECAM_CHAMFER_PROJECTS=<dir>`, writes the goldens' jobs there, for checking the app with
    /// `-NativeCAMSnapshotProject`. Off in normal runs.
    @Test func writeProjectsForTheApp() throws {
        guard let dir = ProcessInfo.processInfo.environment["NATIVECAM_CHAMFER_PROJECTS"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.overcut().encoded().write(to: url.appendingPathComponent("chamfer-overcut.nativecam"))
        try Self.roundNose().encoded().write(to: url.appendingPathComponent("chamfer-roundnose.nativecam"))
    }

    // MARK: Edge cases

    /// Two plaques 0.3" apart, chamfered round their tops 1/8" wide with a 0.04" overcut: each flat would end 0.165"
    /// out, past the midline between them. Checks warns, and both are still chamfered.
    @Test func overcutReachingTheNextShape() throws {
        let p = try Self.edgeCase("overcut-reaches-next-shape") {
            let a = DesignShape(id: Self.id(20), name: "Left", kind: .rectangle(width: 2.5.inch, height: 3.inch, cornerRadius: 0),
                                position: Vec2(2.6.inch, 3.inch))
            let b = DesignShape(id: Self.id(21), name: "Right", kind: .rectangle(width: 2.5.inch, height: 3.inch, cornerRadius: 0),
                                position: Vec2(5.4.inch, 3.inch))
            return Self.project("Overcut crowded", shapes: [a, b], ops: [
                Self.chamfer(ChamferParams(side: .outside, edge: .top, width: 0.125.inch, overcut: 0.04.inch), tool: Self.vBit,
                             shapes: [a.id, b.id], id: Self.id(22), name: "Crowded overcut"),
            ])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(job.issues.contains { $0.severity == .warning && $0.operation == "Crowded overcut"
            && $0.message.contains("The overcut reaches the next shape") }, "\(job.issues.map(\.message))")
    }

    /// A 1/4" roundover asked for a chamfer 5/16" wide: more of the profile than the bit has. Refused, saying so, and
    /// nothing is posted for it.
    @Test func roundNoseWiderThanTheProfile() throws {
        let p = try Self.edgeCase("roundnose-too-wide") {
            let board = EdgeProfileTests.board(Self.id(23))
            return Self.project("Round nose too wide", shapes: [board], ops: [
                Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 0.3125.inch), tool: Self.roundover, shapes: [board.id],
                             id: Self.id(24), name: "Too wide"),
            ])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.motions.isEmpty)
        #expect(tp.warnings.contains { $0.contains("needs more of the profile than the bit has") }, "\(tp.warnings)")
        let posted = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!posted.contains("G01"))
    }

    /// A chamfer with a dovetail bit: refused, saying why, and nothing is posted for it.
    @Test func dovetailIsRefused() throws {
        let p = try Self.edgeCase("dovetail-refused") {
            let board = EdgeProfileTests.board(Self.id(25))
            let tail = Tool(id: Self.id(26), number: 8, name: "1/2\" dovetail", shape: .dovetail, fluteDirection: .straight,
                            diameter: 0.5.inch, shankDiameter: 0.25.inch, fluteLength: 0.5.inch, includedAngle: 28,
                            cutting: EdgeProfileTests.cutting)
            return Self.project("Dovetail chamfer", shapes: [board], ops: [
                Self.chamfer(ChamferParams(side: .inside, edge: .bottom), tool: tail, shapes: [board.id], id: Self.id(27),
                             name: "Dovetail chamfer"),
            ])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.motions.isEmpty)
        #expect(tp.warnings.contains { $0.contains("a dovetail bit") && $0.contains("Profile toolpath") }, "\(tp.warnings)")
        let posted = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!posted.contains("G01"))
    }
}
