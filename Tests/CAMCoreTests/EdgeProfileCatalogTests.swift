import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for edge profiles (#84): a full roundover in horizontal passes, a cove round a frame's holes and
/// an ogee cut partway, each posted for Avid's Mach4 default and compared byte for byte (`Fixtures/golden`); a saved
/// format-18 project; and saved projects for the edge cases (`Fixtures/edge-profile`), each test asserting what NativeCAM
/// does with it. The posts write edge profiles like any other toolpath, so other controllers have no goldens of their
/// own here.
struct EdgeProfileCatalogTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("edge-profile")

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func id(_ n: Int) -> UUID { EdgeProfileTests.id(100 + n) }

    /// Posts `p` for Avid's Mach4 profile, compares it with the golden and runs the export checks on it.
    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    static func project(_ name: String, shapes: [DesignShape], ops: [CAMOperation]) -> Project {
        Project(name: name, displayUnits: .inch, stock: EdgeProfileTests.stock, machine: .avidPRO6060, shapes: shapes, operations: ops)
    }

    // MARK: Goldens

    /// The 1/2" roundover round the 6 × 4" board with 1/2" corner radii: three passes of equal cross-section and a finish.
    static func roundoverPasses() -> Project {
        let board = EdgeProfileTests.board(id(1))
        return project("Edge roundover", shapes: [board], ops: [EdgeProfileTests.edge(tool: EdgeProfileTests.roundover, shapes: [board.id],
                                                                                    id: id(2), name: "Round over")])
    }

    /// A frame's opening and two round holes, the smaller too small for the bit, coved with the 3/8" cove.
    static func coveHoles() -> Project {
        let frame = EdgeProfileTests.board(id(3))
        let opening = DesignShape(id: id(4), name: "Opening", kind: .rectangle(width: 2.5.inch, height: 2.inch, cornerRadius: 0.375.inch),
                                  position: Vec2(3.5.inch, 3.inch))
        let hole = DesignShape(id: id(5), name: "Hole", kind: .circle(radius: 0.5.inch), position: Vec2(6.inch, 3.inch))
        let pin = DesignShape(id: id(6), name: "Pin hole", kind: .circle(radius: 0.125.inch), position: Vec2(6.inch, 4.25.inch))
        let op = EdgeProfileTests.edge(EdgeProfileParams(edges: .holes), tool: EdgeProfileTests.cove,
                                       shapes: [frame.id, opening.id, hole.id, pin.id], id: id(7), name: "Cove the holes")
        return project("Edge cove holes", shapes: [frame, opening, hole, pin], ops: [op])
    }

    /// The ogee cut partway round a hexagon: 1/4" of its 3/8" profile, stood 1/32" off the edge, stepping in by at most
    /// 1/8" a pass, conventional, with no finishing pass. The hexagon's corners roll round.
    static func ogeePartial() -> Project {
        let hex = DesignShape(id: id(8), name: "Hexagon", kind: .polygon(sides: 6, radius: 2.inch), position: Vec2(4.inch, 3.inch))
        let params = EdgeProfileParams(depth: 0.25.inch, offset: 0.03125.inch, bandWidth: 0.125.inch, finish: 0, direction: .conventional)
        let op = EdgeProfileTests.edge(params, tool: EdgeProfileTests.ogee, shapes: [hex.id], id: id(9), name: "Ogee partway")
        return project("Edge ogee partial", shapes: [hex], ops: [op])
    }

    @Test func roundoverPassesGolden() throws {
        let p = Self.roundoverPasses()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty && tp.warnings.isEmpty)
        try Self.checkGolden(p, "edge-roundover-passes-inch")
    }

    @Test func coveHolesGolden() throws {
        let p = Self.coveHoles()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(tp.warnings.contains { $0.contains("1 hole is too small") }, "\(tp.warnings)")
        try Self.checkGolden(p, "edge-cove-holes-inch")
    }

    @Test func ogeePartialGolden() throws {
        let p = Self.ogeePartial()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty && tp.warnings.isEmpty, "\(tp.warnings)")
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.min.z + 0.25.inch) < 1e-6)
        try Self.checkGolden(p, "edge-ogee-partial-inch")
    }

    // MARK: Saved project

    /// Every new setting away from its default, saved as format 18: a roundover on the board's outside, in vertical
    /// passes 0.2" deep, stood 1/64" off, 0.6" deep (a step above the profile), conventional, plunging, on line leads,
    /// with a 0.01" finish; a cove round the opening by band width; then the cut-out, with tabs, that both run before.
    static func savedProject() -> Project {
        let board = EdgeProfileTests.board(id(10))
        let opening = DesignShape(id: id(11), name: "Opening", kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.5.inch),
                                  position: Vec2(4.inch, 3.inch))
        let outside = EdgeProfileParams(edges: .outside, depth: 0.6.inch, offset: 0.015625.inch, passes: .vertical, passCount: 2,
                                        passDepth: 0.2.inch, finish: 0.01.inch, direction: .conventional,
                                        entry: EntrySettings(kind: .plunge, rampLength: 1.inch),
                                        leads: LeadSettings(kind: .line, length: 0.375.inch, angle: 60))
        let holes = EdgeProfileParams(edges: .holes, bandWidth: 0.15.inch)
        var round = EdgeProfileTests.form(.roundover, radius: 0.5.inch, number: 5, id: 990)
        round.fluteLength = 0.875.inch
        var cut = EdgeProfileTests.cutOut(shapes: [board.id, opening.id], id: id(14))
        cut.tool.id = id(15)
        let ops = [
            EdgeProfileTests.edge(outside, tool: round, shapes: [board.id], id: id(12), name: "Round over, stepped"),
            EdgeProfileTests.edge(holes, tool: EdgeProfileTests.cove, shapes: [board.id, opening.id], id: id(13), name: "Cove the opening"),
            cut,
        ]
        var p = project("Edge profiles (format 18)", shapes: [board, opening], ops: ops)
        p.notes = "Saved by format 18 to pin edge profiles."
        return p
    }

    @Test func savedEdgeProfileProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("edge-profile-v18", make: Self.savedProject)
        #expect(p.formatVersion == 18)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 3 && job.toolpaths.allSatisfy { !$0.isEmpty })
        #expect(job.reorder == nil)
        try Self.checkGolden(p, "decoded-edge-profile-v18")
    }

    /// With `NATIVECAM_EDGE_PROJECTS=<dir>`, writes the goldens' jobs there, for checking the app with
    /// `-NativeCAMSnapshotProject`. Off in normal runs.
    @Test func writeProjectsForTheApp() throws {
        guard let dir = ProcessInfo.processInfo.environment["NATIVECAM_EDGE_PROJECTS"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.roundoverPasses().encoded().write(to: url.appendingPathComponent("edge-roundover.nativecam"))
        try Self.coveHoles().encoded().write(to: url.appendingPathComponent("edge-cove-holes.nativecam"))
        try Self.ogeePartial().encoded().write(to: url.appendingPathComponent("edge-ogee-partial.nativecam"))
    }

    // MARK: Edge cases

    /// A cove 0.7" deep run after the cut-out, past the tabs' tops (0.77" − 0.125"): warned about, and Optimize Run
    /// Order puts it before the cut-out.
    @Test func profileDepthReachingTheTabsAfterTheCutOut() throws {
        let p = try Self.edgeCase("tabs-reached-after-cut-out") {
            let board = EdgeProfileTests.board(Self.id(20))
            let cove = EdgeProfileTests.form(.cove, radius: 0.5.inch, number: 6, id: 991)
            return Self.project("Tabs reached", shapes: [board], ops: [
                EdgeProfileTests.cutOut(shapes: [board.id], id: Self.id(21)),
                EdgeProfileTests.edge(EdgeProfileParams(depth: 0.7.inch), tool: cove, shapes: [board.id], id: Self.id(22), name: "Deep cove"),
            ])
        }
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .warning && $0.operation == "Deep cove" && $0.message.contains("reaches the tabs") },
                "\(job.issues.map(\.message))")
        let r = try #require(job.reorder)
        #expect(r.order.first == Self.id(22))
    }

    /// A board with a square notch: its two inside corners are sharper than the roundover's pilot can follow, which
    /// Checks notes as information; the rest of the edge is profiled as usual.
    @Test func insideCornerSharperThanTheBit() throws {
        let p = try Self.edgeCase("inside-corner-sharper") {
            let outline = Polyline([Vec2(1, 1), Vec2(7, 1), Vec2(7, 5), Vec2(5, 5), Vec2(5, 4), Vec2(3, 4), Vec2(3, 5), Vec2(1, 5)]
                .map { $0 * 25.4 }, closed: true)
            let shape = DesignShape(id: Self.id(23), name: "Notched board", kind: .paths([outline]), position: .zero)
            return Self.project("Inside corners", shapes: [shape], ops: [
                EdgeProfileTests.edge(tool: EdgeProfileTests.form(.roundover, radius: 0.25.inch, number: 5, id: 992), shapes: [shape.id],
                                      id: Self.id(24), name: "Round over"),
            ])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        #expect(job.issues.contains { $0.severity == .info && $0.message.hasPrefix("2 inside corners are sharper") },
                "\(job.issues.map(\.message))")
        #expect(!job.hasErrors)
    }

    /// A dovetail on an edge profile: refused, saying why, and nothing is posted for it.
    @Test func dovetailIsRefused() throws {
        let p = try Self.edgeCase("dovetail-refused") {
            let board = EdgeProfileTests.board(Self.id(25))
            let tail = Tool(id: Self.id(26), number: 8, name: "1/2\" dovetail", shape: .dovetail, fluteDirection: .straight, diameter: 0.5.inch,
                            shankDiameter: 0.25.inch, fluteLength: 0.5.inch, includedAngle: 28, cutting: EdgeProfileTests.cutting)
            return Self.project("Dovetail refused", shapes: [board], ops: [
                EdgeProfileTests.edge(EdgeProfileParams(depth: 0.375.inch), tool: tail, shapes: [board.id], id: Self.id(27), name: "Dovetail edge"),
            ])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.motions.isEmpty)
        #expect(tp.warnings.contains { $0.contains("a dovetail bit") && $0.contains("Profile toolpath") }, "\(tp.warnings)")
        let posted = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(!posted.contains("G01"))
    }

    /// A hole smaller than the cove's pilot: skipped, with a warning, while the outside edge and the larger hole are cut.
    @Test func holeTooSmallForTheBit() throws {
        let p = try Self.edgeCase("hole-too-small") {
            let board = EdgeProfileTests.board(Self.id(28))
            let small = DesignShape(id: Self.id(29), name: "Small hole", kind: .circle(radius: 0.2.inch), position: Vec2(2.5.inch, 3.inch))
            let big = DesignShape(id: Self.id(30), name: "Big hole", kind: .circle(radius: 0.75.inch), position: Vec2(5.inch, 3.inch))
            return Self.project("Hole too small", shapes: [board, small, big], ops: [
                EdgeProfileTests.edge(EdgeProfileParams(edges: .both), tool: EdgeProfileTests.cove, shapes: [board.id, small.id, big.id],
                                      id: Self.id(31), name: "Cove all round"),
            ])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("1 hole is too small") }, "\(tp.warnings)")
        // Nothing is cut within the small hole's reach; the big hole and the outside are.
        var nearSmall = false, nearBig = false
        tp.forEachMotion { _, m in
            guard m.kind != .rapid, m.end.z < -1e-6 else { return }
            if m.end.xy.distance(to: Vec2(2.5.inch, 3.inch)) < 0.5.inch { nearSmall = true }
            if m.end.xy.distance(to: Vec2(5.inch, 3.inch)) < 0.75.inch { nearBig = true }
        }
        #expect(!nearSmall && nearBig)
        let ext = try #require(tp.cuttingExtents)
        #expect(ext.max.x > 7.inch)
    }
}
