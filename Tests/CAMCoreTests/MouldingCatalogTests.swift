import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for mouldings (#87): profiles and rails read from an SVG written for the tests
/// (`Fixtures/moulding/moulding.svg`); goldens for a picture frame (inch) and a curved trim (mm) posted for Avid's Mach4
/// default; a saved format-22 project; and saved projects for the edge cases (`Fixtures/moulding`), each test asserting
/// what NativeCAM does with it. The posts write these toolpaths like any other 3D roughing and finish, so other
/// controllers have no goldens of their own here.
struct MouldingCatalogTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("moulding")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "87A00000-0000-4000-8000-%012d", n))! }

    // MARK: The drawing

    static let drawing: ImportResult = {
        // swiftlint:disable:next force_try
        try! SVGImporter.importSVG(data: Data(contentsOf: dir.appendingPathComponent("moulding.svg")))
    }()

    /// The polylines on one of the drawing's layers.
    static func layer(_ name: String) -> [Polyline] {
        zip(drawing.polylines, drawing.polylineLayers).filter { $0.1 == name }.map(\.0)
    }

    /// A layer as a vector shape, moved so its lower-left corner is at `corner` (nil: centred at `centre`).
    static func shape(_ name: String, id: UUID, corner: Vec2? = nil, centre: Vec2 = Vec2(50, 50)) -> DesignShape {
        let lines = layer(name)
        let b = lines.bounds
        let at = corner.map { $0 + (b.center - b.min) } ?? centre
        return DesignShape(id: id, name: name, kind: .paths(lines.transformed(.translation(-b.center))), position: at)
    }

    static let endMill = ToolLibrary.starter.tool(number: 1)! // 1/4" end mill
    static let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose

    static func moulding(_ n: Int, name: String, profile: DesignShape, rails: [DesignShape], params: (UUID) -> MouldingParams,
                         tool: Tool = ball) -> CAMOperation {
        CAMOperation(id: id(n), name: name, kind: .moulding(params(profile.id)), shapeIDs: [profile.id] + rails.map(\.id), tool: tool)
    }

    // MARK: The picture frame

    static let frameStock = Stock(width: 14.inch, height: 12.inch, thickness: 0.75.inch, clearanceHeight: 0.5.inch, plungeHeight: 0.2.inch)

    /// A 12 × 10 in frame: the ogee (1.5 in across, 0.5 in tall) inside the rectangle, roughed with a 1/4" end mill and
    /// finished at a constant scallop with a 1/4" ball nose.
    static func frameProject() -> Project {
        let rail = shape("FrameRail", id: id(1), corner: Vec2(1.inch, 1.inch))
        let profile = shape("Profile", id: id(2), centre: Vec2(7.inch, 6.inch))
        let op = moulding(10, name: "Frame", profile: profile, rails: [rail]) { pid in
            MouldingParams(profileID: pid, side: .left,
                           finish: Finish3DParams(stepoverFraction: 0.15, boundary: .model, strategy: .constantScallop),
                           roughing: MouldingRoughing(tool: endMill))
        }
        return Project(name: "Picture frame", displayUnits: .inch, stock: frameStock, machine: .avidPRO6060,
                       shapes: [rail, profile], operations: [op])
    }

    // MARK: The curved trim

    static let trimStock = Stock(width: 350, height: 130, thickness: 19, clearanceHeight: 10, plungeHeight: 3)

    /// The cove along the open curved rail, on its left, with the finish a new moulding starts with.
    static func trimProject() -> Project {
        let rail = shape("CurvedRail", id: id(3), corner: Vec2(20, 15))
        let profile = shape("TrimProfile", id: id(4), centre: Vec2(330, 115))
        let finish = MouldingParams.suggestedFinish(rails: rail.polylines())
        let op = moulding(11, name: "Curved trim", profile: profile, rails: [rail]) { pid in
            MouldingParams(profileID: pid, side: .left, finish: finish)
        }
        return Project(name: "Curved trim", displayUnits: .mm, stock: trimStock, machine: .avidPRO6060,
                       shapes: [rail, profile], operations: [op])
    }

    /// Posts `p` for Avid's Mach4 profile, compares it with the golden and runs the export checks on it.
    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        #expect(job.toolpaths.allSatisfy { !$0.isEmpty }, sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    /// The swept surface of `p`'s first moulding.
    static func surface(_ p: Project) throws -> (shape: DesignShape, sweep: MouldingSweep, warnings: [String]) {
        let op = try #require(p.operations.first)
        guard case let .moulding(params) = op.kind else { throw Refused() }
        return try MouldingGenerator.surface(op: op, params: params, shapes: p.shapes(for: op)).get()
    }

    struct Refused: Error {}

    /// Simulates `p`'s toolpaths and compares the result with the swept surface over the cells the surface covers:
    /// the deepest the cut goes below it (a gouge, beyond `slack`), and how much it leaves above it at the 95th percentile.
    static func compare(_ p: Project, cell: Double, slack: Double) throws -> (gouge: Double, left95: Double, cells: Int) {
        let job = CAMEngine.generate(p)
        var sim = MaterialSimulator(stock: p.stock, cellSize: cell)
        for tp in job.toolpaths {
            tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
        }
        let grid = sim.grid
        let model = try surface(p).shape
        let want = ModelRaster.surface(of: [model], over: Rect2(min: grid.origin, max: Vec2(grid.origin.x + Double(grid.columns - 1) * grid.cellSize,
                                                                                            grid.origin.y + Double(grid.rows - 1) * grid.cellSize)),
                                       cellSize: grid.cellSize)
        var gouge = 0.0
        var left: [Double] = []
        for r in 0..<min(grid.rows, want.rows) {
            for c in 0..<min(grid.columns, want.columns) {
                let k = want.index(c, r)
                guard want.covered[k] else { continue }
                let got = Double(grid.heights[grid.index(c, r)])
                let target = Double(want.heights[k])
                gouge = max(gouge, target - got - slack)
                left.append(got - target)
            }
        }
        left.sort()
        let p95 = left.isEmpty ? 0 : left[Int(Double(left.count - 1) * 0.95)]
        return (gouge, p95, left.count)
    }

    // MARK: The drawing's shapes

    @Test func theDrawingHasEveryLayer() {
        for name in ["Profile", "TrimProfile", "ClosedProfile", "FrameRail", "CurvedRail", "TightRail", "SmallRing"] {
            #expect(Self.layer(name).count == 1, "\(name)")
        }
        let ogee = Self.layer("Profile")[0]
        #expect(!ogee.isClosed)
        #expect(abs(ogee.bounds.width - 1.5.inch) < 0.01)
        #expect(abs(ogee.bounds.height - 0.5.inch) < 0.01)
        #expect(Self.layer("FrameRail")[0].isClosed)
    }

    // MARK: The sweep

    @Test func theFrameMitresAtEveryCorner() throws {
        let s = try Self.surface(Self.frameProject())
        #expect(s.warnings.isEmpty)
        #expect(s.sweep.clampedWidth == nil)
        #expect(abs(s.sweep.profileWidth - 1.5.inch) < 0.01)
        #expect(abs(s.sweep.depth - 0.5.inch) < 0.01)
        // On each mitre line (from a rail corner toward the frame's middle, along the diagonal) the surface stands at the
        // profile's height a given distance in from both sides, so the two sides meet without a step.
        let rail = Self.frameProject().shapes[0].polylines()[0]
        let b = rail.bounds
        let grid = ModelRaster.surface(of: [s.shape], over: b, cellSize: 0.25)
        let section = try MouldingSweep.crossSection(Self.layer("Profile")[0], flipped: false, mirrored: false)
        func profileZ(_ w: Double) -> Double {
            for i in 1..<section.count where section[i].x >= w {
                let a = section[i - 1], c = section[i]
                return a.y + (c.y - a.y) * (w - a.x) / max(1e-9, c.x - a.x)
            }
            return section.last!.y
        }
        var worst = 0.0
        for corner in [b.min, Vec2(b.max.x, b.min.y), b.max, Vec2(b.min.x, b.max.y)] {
            let inward = (b.center - corner)
            let dx: Double = inward.x > 0 ? 1 : -1, dy: Double = inward.y > 0 ? 1 : -1
            for w in stride(from: 1.0, to: 1.5.inch - 1, by: 2.0) {
                // A point w in from both sides, on the mitre, and points w in from one side just off it either way.
                for off in [-3.0, 0, 3.0] {
                    let q = corner + Vec2(dx * (w + max(0, off)), dy * (w + max(0, -off)))
                    let z = Double(try #require(grid.height(at: q), "\(q)"))
                    worst = max(worst, abs(z - profileZ(w)))
                }
            }
        }
        #expect(worst < 0.05, "mitre off the profile by \(worst) mm")
    }

    @Test func theFrameIsCutToTheSurfaceWithoutGouging() throws {
        let r = try Self.compare(Self.frameProject(), cell: 0.5, slack: 0.05)
        #expect(r.cells > 10_000)
        #expect(r.gouge <= 0, "cut \(r.gouge) mm past the surface")
        // A 1/4" ball at a 15% stepover leaves scallops under 0.04 mm; the simulator's cells and the steep walls of the
        // ogee add to what's left at the 95th percentile.
        #expect(r.left95 < 0.6, "\(r.left95) mm left at the 95th percentile")
    }

    @Test func theCurvedTrimSweepsSmoothly() throws {
        let p = Self.trimProject()
        let s = try Self.surface(p)
        #expect(s.warnings.isEmpty)
        // The finish a curved rail starts with follows it round.
        guard case let .moulding(params) = p.operations[0].kind else { return }
        #expect(params.finish.strategy == .constantScallop)
        // Smooth: along a line across the trim near its middle, the surface follows the profile, with no facets steps.
        let r = try Self.compare(p, cell: 0.4, slack: 0.05)
        #expect(r.gouge <= 0, "cut \(r.gouge) mm past the surface")
        #expect(r.left95 < 0.6)
    }

    @Test func aStraightOpenRailFinishesAlongItsLength() {
        let rail = Polyline([Vec2(0, 0), Vec2(100, 100)], closed: false)
        let f = MouldingParams.suggestedFinish(rails: [rail])
        #expect(f.strategy == .raster)
        #expect(abs(f.rasterAngle - 45) < 1e-9)
        let frame = MouldingParams.suggestedFinish(rails: Self.frameProject().shapes[0].polylines())
        #expect(frame.strategy == .constantScallop)
    }

    @Test func sideFlipAndMirrorMoveTheSurface() throws {
        let line = Self.layer("Profile")[0]
        let plain = try MouldingSweep.crossSection(line, flipped: false, mirrored: false)
        #expect(plain.first!.x == 0 && plain.first!.y == 0)
        #expect(abs(plain.last!.y + 0.5.inch) < 0.01)
        let mirrored = try MouldingSweep.crossSection(line, flipped: false, mirrored: true)
        #expect(abs(mirrored.first!.y + 0.5.inch) < 0.01) // the low end on the rail
        let flipped = try MouldingSweep.crossSection(line, flipped: true, mirrored: false)
        #expect(abs(flipped.first!.y + 0.5.inch) < 0.01 && abs(flipped.last!.y) < 0.01)
        let rail = Polyline([Vec2(0, 0), Vec2(100, 0)], closed: false)
        let left = try MouldingSweep.sweep(section: plain, rails: [rail], side: .left)
        let right = try MouldingSweep.sweep(section: plain, rails: [rail], side: .right)
        #expect(left.positions.allSatisfy { $0.y >= -1e-9 })
        #expect(right.positions.allSatisfy { $0.y <= 1e-9 })
    }

    // MARK: File format

    @Test func mouldingsAreFormat22() {
        #expect(Project.currentFormatVersion >= 22)
        #expect(Self.frameProject().formatVersion == 22)
        var none = Self.frameProject()
        none.operations = []
        #expect(none.formatVersion == 1)
        let params = MouldingParams(profileID: Self.id(2), side: .right, flipped: true, mirrored: true,
                                    finish: Finish3DParams(strategy: .waterline), roughing: MouldingRoughing(tool: Self.endMill, passDepth: 3))
        #expect(try JSONDecoder().decode(MouldingParams.self, from: JSONEncoder().encode(params)) == params)
    }

    // MARK: Goldens

    @Test func frameGolden() throws {
        try Self.checkGolden(Self.frameProject(), "moulding-frame-inch")
    }

    @Test func curvedRailGolden() throws {
        try Self.checkGolden(Self.trimProject(), "moulding-curved-rail-mm")
    }

    // MARK: Saved project

    /// Every setting away from its default, saved as format 22: the frame roughed with its own allowance, layer depth
    /// and stepover and finished by waterline; and the cove outside the same rail, flipped and mirrored, finished by a
    /// raster at 30° with no roughing.
    static func savedProject() -> Project {
        let stock = Stock(width: 16.inch, height: 14.inch, thickness: 0.75.inch, clearanceHeight: 0.5.inch, plungeHeight: 0.2.inch)
        let rail = shape("FrameRail", id: id(1), corner: Vec2(2.inch, 2.inch))
        let ogee = shape("Profile", id: id(2), centre: Vec2(8.inch, 8.inch))
        let cove = shape("TrimProfile", id: id(4), centre: Vec2(8.inch, 6.inch))
        let ops = [
            moulding(20, name: "Frame", profile: ogee, rails: [rail]) { pid in
                MouldingParams(profileID: pid, side: .left,
                               finish: Finish3DParams(stepoverFraction: 0.2, allowance: 0.1, boundary: .model, strategy: .waterline,
                                                      steepAngle: 30),
                               roughing: MouldingRoughing(tool: endMill, allowance: 0.8, passDepth: 4, stepoverFraction: 0.5))
            },
            moulding(21, name: "Outside cove", profile: cove, rails: [rail]) { pid in
                MouldingParams(profileID: pid, side: .right, flipped: true, mirrored: true,
                               finish: Finish3DParams(stepoverFraction: 0.25, rasterAngle: 30, boundary: .model))
            },
        ]
        return Project(name: "Mouldings (format 22)", displayUnits: .inch, stock: stock, machine: .avidPRO6060,
                       shapes: [rail, ogee, cove], operations: ops,
                       notes: "Saved by format 22 to pin mouldings: a profile swept along a rail, mitred at its corners.")
    }

    @Test func savedMouldingProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("moulding-v22", make: Self.savedProject)
        #expect(p.formatVersion == 22)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 3 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "decoded-moulding-v22")
    }

    // MARK: Edge cases

    /// Loads an edge-case project. Update mode writes a missing one from `make`, but never replaces one.
    static func edgeCase(_ name: String, make: () -> Project) throws -> Project {
        let url = dir.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static let edgeStock = Stock(width: 10.inch, height: 8.inch, thickness: 0.75.inch, clearanceHeight: 0.5.inch, plungeHeight: 0.2.inch)

    /// The ogee on `rail`, on its left (the inside of a closed rail), roughed and finished as the frame is.
    static func ogeeOn(_ railLayer: String, corner: Vec2, name: String) -> Project {
        let rail = shape(railLayer, id: id(5), corner: corner)
        let profile = shape("Profile", id: id(2), centre: Vec2(9.inch, 7.inch))
        let op = moulding(30, name: name, profile: profile, rails: [rail]) { pid in
            MouldingParams(profileID: pid, side: .left,
                           finish: Finish3DParams(stepoverFraction: 0.15, boundary: .model, strategy: .constantScallop),
                           roughing: MouldingRoughing(tool: endMill))
        }
        return Project(name: name, displayUnits: .inch, stock: edgeStock, machine: .avidPRO6060, shapes: [rail, profile], operations: [op])
    }

    /// An L-shaped rail whose corner is rounded to 0.5 in, with the 1.5 in ogee inside the bend: cut back there, with a
    /// warning in Checks, and never gouged.
    @Test func aTightInsideCurveIsClampedAndWarned() throws {
        let p = try Self.edgeCase("tight-inside-curve") { Self.ogeeOn("TightRail", corner: Vec2(1.inch, 1.inch), name: "Tight curve") }
        let s = try Self.surface(p)
        let c = try #require(s.sweep.clampedWidth)
        #expect(c < 0.5.inch + 0.5 && c > 0.5.inch - 2, "cut back to \(c) mm")
        let job = CAMEngine.generate(p)
        let warned = job.issues.contains { $0.severity == .warning && $0.message.contains("turns tighter than the profile is wide") }
        #expect(warned, "\(job.issues.map(\.message))")
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.isEmpty })
        let r = try Self.compare(p, cell: 0.5, slack: 0.05)
        #expect(r.gouge <= 0, "cut \(r.gouge) mm past the surface")
    }

    /// A ring 0.6 in in radius with the 1.5 in ogee inside it: the profile is wider than the rail's radius, so it's cut
    /// back to (about) the radius all the way round, and nothing reaches past the centre.
    @Test func aProfileWiderThanTheRailsRadiusIsClamped() throws {
        let p = try Self.edgeCase("wider-than-radius") { Self.ogeeOn("SmallRing", corner: Vec2(4.inch, 3.inch), name: "Small ring") }
        let s = try Self.surface(p)
        let c = try #require(s.sweep.clampedWidth)
        #expect(c <= 0.6.inch + 0.01, "cut back to \(c) mm")
        let ring = p.shapes[0].polylines()[0]
        let centre = ring.bounds.center
        let farthest = s.sweep.positions.map { Vec2($0.x, $0.y).distance(to: centre) }.max() ?? 0
        let nearest = s.sweep.positions.map { Vec2($0.x, $0.y).distance(to: centre) }.min() ?? 0
        #expect(farthest < 0.6.inch + 0.01)
        #expect(nearest > -1e-9)
        #expect(!s.warnings.isEmpty)
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .warning && $0.message.contains("turns tighter") })
        let r = try Self.compare(p, cell: 0.25, slack: 0.05)
        #expect(r.gouge <= 0, "cut \(r.gouge) mm past the surface")
    }

    /// A closed shape chosen as the profile: refused, with an empty toolpath saying why.
    @Test func aClosedProfileIsRefused() throws {
        let p = try Self.edgeCase("closed-profile") {
            let rail = shape("FrameRail", id: id(1), corner: Vec2(1.inch, 1.inch))
            let profile = shape("ClosedProfile", id: id(6), centre: Vec2(7.inch, 6.inch))
            let op = moulding(31, name: "Closed profile", profile: profile, rails: [rail]) { MouldingParams(profileID: $0) }
            return Project(name: "Closed profile", displayUnits: .inch, stock: frameStock, machine: .avidPRO6060,
                           shapes: [rail, profile], operations: [op])
        }
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 1)
        #expect(job.toolpaths.allSatisfy(\.isEmpty))
        let refused = job.issues.contains { $0.severity == .warning && $0.message.contains("has to be an open cross-section") }
        #expect(refused, "\(job.issues.map(\.message))")
    }
}
