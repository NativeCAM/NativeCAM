import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for the tapered ball nose, form and dovetail bits (#82): one small job per shape posted for
/// Avid's Mach4 default and compared byte for byte (`Fixtures/golden`), and saved projects for the edge cases
/// (`Fixtures/bit-shapes`), each test asserting what NativeCAM does with it. Only Avid's post names a bit's shape (in
/// its header), so other controllers' output doesn't depend on these shapes and has no goldens of its own here.
struct BitShapeFixtureTests {
    static let edgeCases = GoldenPostTests.fixtures.appendingPathComponent("bit-shapes")

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = edgeCases.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: edgeCases, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "B1750000-0000-4000-8000-%012d", 1000 + n))! }

    static func project(_ name: String, units: LengthUnit, stock: Stock, shapes: [DesignShape], ops: [CAMOperation]) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        return Project(name: name, displayUnits: units, stock: stock, machine: machine, shapes: shapes, operations: ops)
    }

    static func numbered(_ tool: Tool, _ n: Int, id: Int) -> Tool {
        var t = tool
        t.number = n
        t.id = Self.id(id)
        return t
    }

    static func profile(_ side: CutSide, depth: Double) -> OperationKind { BitShapeTests.profile(side, depth: depth) }

    // MARK: Goldens: one small job per shape

    /// A 20 mm dome finished with a tapered ball nose (0.5 mm tip radius, 5° per side), in millimetres.
    static func taperedBallFinish() -> Project {
        let dome = DesignShape(id: id(1), name: "Dome",
                               kind: .model(ModelSpec(mesh: hemisphereMesh(radius: 10, rings: 16, segments: 32), depth: 6)),
                               position: Vec2(20, 20))
        let tool = numbered(BitShapeTests.taperedBall(tipRadius: 0.5, perSide: 5, flute: 15, shank: 6.35), 3, id: 11)
        let finish = CAMOperation(id: id(2), name: "Finish dome", kind: .finish3D(Finish3DParams(stepoverFraction: 0.8, rasterAngle: 0)),
                                  shapeIDs: [dome.id], tool: tool)
        return project("Tapered ball finish", units: .mm, stock: Stock(width: 40, height: 40, thickness: 12), shapes: [dome],
                       ops: [finish])
    }

    /// A dovetail pin round a rectangle and a sliding-dovetail slot right across the board, in inches.
    static func dovetailProfile() -> Project {
        let pin = DesignShape(id: id(3), name: "Pin", kind: .rectangle(width: 3.inch, height: 1.5.inch, cornerRadius: 0),
                              position: Vec2(3.inch, 2.5.inch))
        let slot = DesignShape(id: id(4), name: "Slot", kind: .paths([Polyline([Vec2(-0.5.inch, 0.75.inch), Vec2(6.5.inch, 0.75.inch)],
                                                                                closed: false)]), position: .zero)
        let tool = numbered(BitShapeTests.dovetail(perSide: 14, diameter: 0.5.inch, height: 0.5.inch), 4, id: 12)
        let ops = [
            CAMOperation(id: id(5), name: "Dovetail pin", kind: profile(.outside, depth: 0.375.inch), shapeIDs: [pin.id], tool: tool),
            CAMOperation(id: id(6), name: "Sliding dovetail", kind: profile(.on, depth: 0.25.inch), shapeIDs: [slot.id], tool: tool),
        ]
        return project("Dovetail profile", units: .inch, stock: Stock(width: 6.inch, height: 4.inch, thickness: 0.75.inch),
                       shapes: [pin, slot], ops: ops)
    }

    /// A roundover round a rounded rectangle, a cove inside a circle and an ogee round a hexagon, in millimetres.
    static func formBitProfile() -> Project {
        let board = DesignShape(id: id(7), name: "Board", kind: .rectangle(width: 120, height: 70, cornerRadius: 10), position: Vec2(80, 55))
        let hole = DesignShape(id: id(8), name: "Hole", kind: .circle(radius: 20), position: Vec2(80, 55))
        let hex = DesignShape(id: id(9), name: "Hex", kind: .polygon(sides: 6, radius: 18), position: Vec2(180, 110))
        let round = numbered(BitShapeTests.form(.roundover, radius: 6.35, pilot: 12.7), 5, id: 13)
        let cove = numbered(BitShapeTests.form(.cove, radius: 4, pilot: 6), 6, id: 14)
        let ogee = numbered(BitShapeTests.form(.ogee, radius: 3, upper: 2.5, pilot: 6), 7, id: 15)
        let ops = [
            CAMOperation(id: id(10), name: "Cove the hole", kind: profile(.inside, depth: 4), shapeIDs: [hole.id], tool: cove),
            CAMOperation(id: id(11), name: "Round over", kind: profile(.outside, depth: 6.35), shapeIDs: [board.id], tool: round),
            CAMOperation(id: id(12), name: "Ogee the hex", kind: profile(.outside, depth: 5.5), shapeIDs: [hex.id], tool: ogee),
        ]
        return project("Form bit profile", units: .mm, stock: Stock(width: 220, height: 150, thickness: 19), shapes: [board, hole, hex],
                       ops: ops)
    }

    @Test func taperedBallFinishGolden() throws {
        let p = Self.taperedBallFinish()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.toolpaths.allSatisfy { !$0.motions.isEmpty })
        try GoldenPostTests.check(GoldenPostTests.post(p), golden: "tapered-ball-finish-mm")
    }

    @Test func dovetailProfileGolden() throws {
        let p = Self.dovetailProfile()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.motions.isEmpty })
        try GoldenPostTests.check(GoldenPostTests.post(p), golden: "dovetail-profile-inch")
    }

    @Test func formBitProfileGolden() throws {
        let p = Self.formBitProfile()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.toolpaths.count == 3 && job.toolpaths.allSatisfy { !$0.motions.isEmpty })
        try GoldenPostTests.check(GoldenPostTests.post(p), golden: "form-bit-profile-mm")
    }

    // MARK: Edge cases

    /// A dovetail cut deeper than its flutes: it still cuts, once, and the check warns about the depth; the shank
    /// (narrower than the neck) overhangs further, so the leads off the wall are longer.
    @Test func dovetailDeeperThanItsFlutes() throws {
        let p = try Self.edgeCase("dovetail-past-flutes") {
            let square = BitShapeTests.square()
            var square2 = square
            square2.id = Self.id(20)
            let tool = Self.numbered(BitShapeTests.dovetail(perSide: 14, diameter: 12.7, height: 12.7), 8, id: 21)
            let op = CAMOperation(id: Self.id(22), name: "Too deep", kind: Self.profile(.outside, depth: 16), shapeIDs: [square2.id], tool: tool)
            return BitShapeTests.project([square2], [op])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let tool = p.operations[0].tool
        #expect(job.issues.contains { $0.message.contains("exceeds the cutting length") })
        #expect(tp.warnings.contains { $0.contains("one pass at full depth") })
        let undercut = tool.undercut(toDepth: 16)
        #expect(abs(undercut - (6.35 - 3.175)) < 1e-9)
        var lifts: [Vec2] = []
        tp.forEachMotion { s, m in
            if m.end.z > s.z + 1e-6, s.z < -1e-6 { lifts.append(s.xy) }
        }
        let square = Polyline([Vec2(10, 10), Vec2(50, 10), Vec2(50, 50), Vec2(10, 50)], closed: true)
        #expect(!lifts.isEmpty)
        for q in lifts {
            let off = square.closestPoint(to: q).point.distance(to: q)
            #expect(off >= 6.35 + undercut - 1e-6, "lifts \(off) from the part")
        }
    }

    /// A taper of 0°: a tapered ball nose with no taper and a dovetail with no angle aren't those bits. Every toolpath
    /// refuses them, saying so, and cuts nothing.
    @Test func zeroTaperIsRefused() throws {
        let p = try Self.edgeCase("zero-taper") {
            let square = BitShapeTests.square()
            var shape = square
            shape.id = Self.id(23)
            var ball = BitShapeTests.taperedBall(tipRadius: 0.5, perSide: 5, flute: 15, shank: 6.35)
            ball.includedAngle = 0
            var tail = BitShapeTests.dovetail()
            tail.includedAngle = 0
            let ops = [
                CAMOperation(id: Self.id(24), name: "Flute", kind: .fluting(FlutingParams(depth: 2)), shapeIDs: [shape.id],
                             tool: Self.numbered(ball, 9, id: 25)),
                CAMOperation(id: Self.id(26), name: "Profile", kind: Self.profile(.on, depth: 2), shapeIDs: [shape.id],
                             tool: Self.numbered(ball, 9, id: 25)),
                CAMOperation(id: Self.id(27), name: "Dovetail", kind: Self.profile(.outside, depth: 6), shapeIDs: [shape.id],
                             tool: Self.numbered(tail, 10, id: 28)),
            ]
            return BitShapeTests.project([shape], ops)
        }
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.allSatisfy { $0.motions.isEmpty })
        let warnings = job.toolpaths.flatMap(\.warnings)
        #expect(warnings.filter { $0.contains("outside 0.1–45°") }.count == 2)
        #expect(warnings.contains { $0.contains("no dovetail angle") })
    }

    /// A custom profile whose heights go down isn't a bit: refused, saying how to list the points.
    @Test func formProfileWhoseHeightsGoDownIsRefused() throws {
        let p = try Self.edgeCase("form-heights-go-down") {
            var shape = BitShapeTests.square()
            shape.id = Self.id(29)
            var bit = BitShapeTests.form(.custom, flute: 6, points: [Vec2(2, 0), Vec2(4, 3), Vec2(5, 1), Vec2(6, 6)])
            bit.fitDiameterToShape()
            let op = CAMOperation(id: Self.id(30), name: "Folded", kind: Self.profile(.outside, depth: 4), shapeIDs: [shape.id],
                                  tool: Self.numbered(bit, 11, id: 31))
            return BitShapeTests.project([shape], [op])
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.motions.isEmpty)
        #expect(tp.warnings.contains { $0.contains("heights go down") })
    }

    /// A custom profile that narrows going up (not monotonic in radius) is cut like a dovetail: one pass at full depth,
    /// no tabs, and leads off the wall at least its undercut long.
    @Test func formProfileThatNarrowsIsCutLikeADovetail() throws {
        let p = try Self.edgeCase("form-narrows") {
            var shape = BitShapeTests.square()
            shape.id = Self.id(32)
            var params = ProfileParams(side: .outside, depth: DepthSettings(startDepth: 0, cutDepth: 6))
            params.tabs.enabled = true
            let op = CAMOperation(id: Self.id(33), name: "Bead", kind: .profile(params), shapeIDs: [shape.id],
                                  tool: Self.numbered(BitShapeTests.undercutCustom, 12, id: 34))
            return BitShapeTests.project([shape], [op])
        }
        let tool = p.operations[0].tool
        #expect(tool.hasUndercut && tool.geometryProblem == nil)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("one pass at full depth") })
        #expect(tp.warnings.contains { $0.contains("tabs were left off") })
        var depths = Set<Double>()
        var lifts: [Vec2] = []
        tp.forEachMotion { s, m in
            if m.end.z > s.z + 1e-6, s.z < -1e-6 { lifts.append(s.xy) }
            guard m.kind != .rapid, m.kind != .dwell else { return }
            if s.xy.distance(to: m.end.xy) > 1e-6 { depths.insert((m.end.z * 1e6).rounded() / 1e6) }
        }
        #expect(depths == [-6])
        // The tool centre rides 2 mm (the profile's tip radius) off the part; lifting, it's the undercut further off.
        let need = 2 + tool.undercut(toDepth: 6)
        let square = Polyline([Vec2(10, 10), Vec2(50, 10), Vec2(50, 50), Vec2(10, 50)], closed: true)
        #expect(!lifts.isEmpty)
        for q in lifts { #expect(square.closestPoint(to: q).point.distance(to: q) >= need - 1e-6) }
    }
}
