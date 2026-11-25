import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for flutes that follow a 3D model (#91): a column face read from an STL written for the tests
/// (`Fixtures/flutes-on-model/column.stl`) fluted on a flat job (inch), and a turned table leg with a taper and a bead
/// fluted on a wrapped rotary job (mm), each posted for Avid's Mach4 default; a saved format-25 project; and saved
/// projects for the edge cases (`Fixtures/flutes-on-model`), each test asserting what NativeCAM does with it.
struct FlutesOnModelCatalogTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("flutes-on-model")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "91F00000-0000-4000-8000-%012d", n))! }

    static let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose

    // MARK: The column face

    /// The column face: 8 in long (X), 2.5 in wide (Y), 0.5 in thick at its edges, its top rising 0.25 in along its
    /// length and 0.15 in across it to a convex crown 0.9 in above its bottom. mm, in the STL's own frame (its lower-left
    /// corner at the origin).
    static let columnLength = 8.inch, columnWidth = 2.5.inch
    static func columnTop(_ x: Double, _ y: Double) -> Double {
        let u = (x - columnLength / 2) / (columnLength / 2), v = (y - columnWidth / 2) / (columnWidth / 2)
        return 0.5.inch + 0.25.inch * (1 - u * u) + 0.15.inch * (1 - v * v)
    }

    static let columnHeight = 0.9.inch

    /// The column face as a binary STL, as `column.stl` was written: a 48 × 16 grid over the top, walls round it and
    /// a bottom.
    static func columnSTL() -> Data {
        let nx = 48, ny = 16
        func top(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let x = columnLength * Double(i) / Double(nx), y = columnWidth * Double(j) / Double(ny)
            return SIMD3(Float(x), Float(y), Float(columnTop(x, y)))
        }
        func base(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, 0) }
        var tris: [MeshImportTests.Tri] = []
        for i in 0..<nx {
            for j in 0..<ny {
                let a = top(i, j), b = top(i + 1, j), c = top(i + 1, j + 1), d = top(i, j + 1)
                tris += [(a, b, c), (a, c, d)]
            }
        }
        // Walls: along each edge of the top, down to the bottom.
        func wall(_ p: SIMD3<Float>, _ q: SIMD3<Float>) {
            tris += [(p, base(p), base(q)), (p, base(q), q)]
        }
        for i in 0..<nx {
            wall(top(i + 1, 0), top(i, 0))
            wall(top(i, ny), top(i + 1, ny))
        }
        for j in 0..<ny {
            wall(top(0, j), top(0, j + 1))
            wall(top(nx, j + 1), top(nx, j))
        }
        let o = SIMD3<Float>(0, 0, 0), x = SIMD3<Float>(Float(columnLength), 0, 0)
        let xy = SIMD3<Float>(Float(columnLength), Float(columnWidth), 0), y = SIMD3<Float>(0, Float(columnWidth), 0)
        tris += [(o, xy, x), (o, y, xy)]
        return MeshImportTests.binarySTL(tris, header: "NativeCAM test column face, 8 x 2.5 in, mm, Z up")
    }

    /// The column read from `column.stl` (written from `columnSTL()` in update mode when it's missing, never replaced).
    static let columnMesh: MeshModel = {
        let url = dir.appendingPathComponent("column.stl")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? columnSTL().write(to: url)
        }
        // swiftlint:disable:next force_try
        var mesh = try! STLImporter.importSTL(data: Data(contentsOf: url), name: "Column").mesh
        mesh.id = id(1)
        return mesh
    }()

    static let columnCentre = Vec2(5.inch, 2.inch)
    static let columnStock = Stock(width: 10.inch, height: 4.inch, thickness: 1.inch, materialName: "Cherry",
                                   clearanceHeight: 0.5.inch, plungeHeight: 0.2.inch)

    static func column() -> DesignShape {
        DesignShape(id: id(2), name: "Column", kind: .model(ModelSpec(mesh: columnMesh, depth: columnHeight)), position: columnCentre)
    }

    /// The column's top in design coordinates (Z below the material top, which its crown touches).
    static func columnSurface(_ p: Vec2) -> Double {
        columnTop(p.x - columnCentre.x + columnLength / 2, p.y - columnCentre.y + columnWidth / 2) - columnHeight
    }

    /// A flute line along the column at `y` (in from its centre line), from `x0` to `x1` (design X).
    static func fluteLine(_ n: Int, y: Double, from x0: Double = 1.5.inch, to x1: Double = 8.5.inch) -> DesignShape {
        DesignShape(id: id(n), name: "Flute \(n - 10)", kind: .paths([Polyline([Vec2(0, 0), Vec2(x1 - x0, 0)], closed: false)]),
                    position: Vec2(x0, columnCentre.y + y))
    }

    static let fluteDepth = 0.1.inch

    /// Three flutes along the column face, 0.1 in deep below its surface with smooth 1 in ramps at both ends, in one
    /// pass with the 1/4" ball nose.
    static func flatProject(_ params: FlutingParams? = nil, lines: [DesignShape]? = nil) -> Project {
        let lines = lines ?? [fluteLine(11, y: -0.6.inch), fluteLine(12, y: 0), fluteLine(13, y: 0.6.inch)]
        let p = params ?? FlutingParams(depth: fluteDepth, ramp: .both, rampLength: 1.inch, rampShape: .smooth, passDepth: fluteDepth,
                                        surfaceModelID: id(2))
        let op = CAMOperation(id: id(20), name: "Flutes", kind: .fluting(p), shapeIDs: lines.map(\.id), tool: ball)
        return Project(name: "Fluted column", displayUnits: .inch, stock: columnStock, machine: .avidPRO6060,
                       shapes: [column()] + lines, operations: [op])
    }

    // MARK: The table leg

    /// A turned table leg 200 mm long: a 22 mm radius block at its top, a cove down to 20 mm, a taper to 15 mm, a bead
    /// 3.5 mm proud and a last taper to 13 mm (radius, mm, at x along it).
    static func legRadius(_ x: Double) -> Double {
        switch x {
        case ..<15: return 22
        case ..<20: return 20 + 2 * (1 + cos(.pi * (x - 15) / 5)) / 2
        case ..<150: return 20 - 5 * (x - 20) / 130
        case ..<158: return 15
        case ..<172: return 15 + 3.5 * sin(.pi * (x - 158) / 14)
        default: return 15 - 2 * (x - 172) / 28
        }
    }

    static let legBlank = RotaryStock(shape: .cylinder, diameter: 50, length: 260, layout: .wrapped)
    /// Where the leg starts along the blank (it's centred on it).
    static let legStart = 30.0

    static func leg() -> DesignShape {
        let profile = (0...240).map { i -> (x: Double, r: Double) in
            let x = 200 * Double(i) / 240
            return (x, legRadius(x))
        }
        var mesh = MeshModel.revolved(name: "Leg", profile: profile, segments: 180)
        mesh.id = id(3)
        return DesignShape(id: id(4), name: "Leg", kind: .model(ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(alongAxis: .x))),
                           position: Vec2(legBlank.length / 2, .pi * legBlank.diameter / 2))
    }

    static let legDepth = 1.5

    /// Six flutes along the leg from 25 mm to 185 mm along it (over the taper, the bead and the last taper), 1.5 mm
    /// deep below its surface with smooth 12 mm ramps, in one pass with the 1/4" ball nose.
    static func rotaryProject(from along: Double = 25, length: Double = 160) -> Project {
        var stock = Stock(materialName: "Maple", materialKind: .hardwood)
        stock.setRotary(legBlank)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 100)
        machine.outputUnits = .mm
        let around = Double.pi * legBlank.diameter
        let lines = (0..<6).map { k in
            DesignShape(id: id(30 + k), name: "Flute \(k + 1)", kind: .paths([Polyline([Vec2(0, 0), Vec2(length, 0)], closed: false)]),
                        position: Vec2(legStart + along, around * (Double(k) + 0.5) / 6))
        }
        var tool = ball
        tool.cutting.spindleRPM = 16000
        let op = CAMOperation(id: id(40), name: "Leg flutes",
                              kind: .fluting(FlutingParams(depth: legDepth, ramp: .both, rampLength: 12, rampShape: .smooth,
                                                           passDepth: legDepth, surfaceModelID: id(4))),
                              shapeIDs: lines.map(\.id), tool: tool)
        return Project(name: "Fluted leg", displayUnits: .mm, stock: stock, machine: machine, shapes: [leg()] + lines, operations: [op])
    }

    // MARK: Helpers

    /// Checks `p`'s posted file against its golden. Warnings other than the rotary axis's speed fail, unless they
    /// contain `allowing`.
    static func checkGolden(_ p: Project, _ name: String, allowing: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        let unexpected = job.issues.filter { issue in
            issue.severity != .info && !issue.message.contains("rotary axis turns at most")
                && !(allowing.map { issue.message.contains($0) } ?? false)
        }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.message))", sourceLocation: sourceLocation)
        #expect(job.toolpaths.allSatisfy { !$0.isEmpty }, sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    static func flatCutter(_ p: Project) throws -> TriangleDropCutter {
        try #require(TriangleDropCutter(tool: ball, allowance: 0,
                                        triangles: Model3DGenerator.triangles(of: p.shapes.filter { $0.modelSpec != nil })))
    }

    /// The points every `step` mm along the feed moves of `tp` (lines and arcs), with how many of its moves are arcs.
    static func feedPoints(_ tp: Toolpath, step: Double = 0.02) -> (points: [Vec3], arcs: Int) {
        var points: [Vec3] = []
        var arcs = 0
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            if m.kind.isArc {
                arcs += 1
                points.append(s)
                points += m.samples(from: s, maxStep: step)
            } else {
                let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
                for k in 0...n { points.append(s + (m.end - s) * (Double(k) / Double(n))) }
            }
        }
        return (points, arcs)
    }

    /// How far below `depth` under the drop-cutter surface the feed moves of `tp` go (0 or less: never).
    static func flatGouge(_ tp: Toolpath, _ cutter: TriangleDropCutter, depth: Double) -> (gouge: Double, arcs: Int) {
        let f = feedPoints(tp)
        var hint: Int32 = -1
        var worst = -Double.infinity
        for q in f.points {
            let z = cutter.z(at: q.xy, hint: &hint)
            if z.isFinite { worst = max(worst, z - depth - q.z) }
        }
        return (worst, f.arcs)
    }

    /// The posted file of `p` read back into toolpaths in design coordinates.
    static func posted(_ p: Project) throws -> [Toolpath] {
        let job = CAMEngine.generate(p)
        let text = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        return try GCodeParser.parse(text).toolpaths(tools: [ball], frame: RotaryFrame(p), fallback: ball)
    }

    // MARK: The column STL

    @Test func theColumnSTLIsTheColumn() {
        let size = Self.column().modelSpec!.naturalSize
        #expect(abs(size.x - Self.columnLength) < 0.01)
        #expect(abs(size.y - Self.columnWidth) < 0.01)
        #expect(abs(size.z - Self.columnHeight) < 0.01)
        // The crown is at the material top, the edges 0.4 in below it.
        #expect(abs(Self.columnSurface(Self.columnCentre)) < 1e-9)
    }

    // MARK: Flat

    /// In simulation, each flute's bottom along its middle (clear of the ramps) is 0.1 in below the column's surface
    /// everywhere, though the surface falls 0.2 in along it; a flute from a start depth on the same lines isn't.
    @Test func flatFlutesKeepTheirDepthBelowTheSurface() throws {
        let p = Self.flatProject()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.2)
        tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
        var depths: [Double] = []
        var surfaceRange = (lo: Double.infinity, hi: -Double.infinity)
        for y in [-0.6.inch, 0, 0.6.inch] {
            for x in stride(from: 2.6.inch, through: 7.4.inch, by: 2.0) {
                let q = Vec2(x, Self.columnCentre.y + y)
                let cut = Double(try #require(sim.grid.height(at: q)))
                let surface = Self.columnSurface(q)
                depths.append(surface - cut)
                surfaceRange = (min(surfaceRange.lo, surface), max(surfaceRange.hi, surface))
            }
        }
        let lo = depths.min() ?? 0, hi = depths.max() ?? 0
        #expect(surfaceRange.hi - surfaceRange.lo > 3, "the surface falls \(surfaceRange.hi - surfaceRange.lo) mm along the flutes")
        // The ball touches a sloping surface a little uphill of its tip, so the depth under its centre is a few
        // hundredths of a millimetre less than 0.1 in where the surface slopes most.
        #expect(hi < Self.fluteDepth + 0.02, "\(hi) mm deep at most")
        #expect(lo > Self.fluteDepth - 0.08, "\(lo) mm deep at least")
        #expect(hi - lo < 0.08, "depth varies by \(hi - lo) mm")

        // From a start depth, the same flutes are a constant depth below the material top instead.
        var flat = p
        flat.operations[0].kind = .fluting(FlutingParams(depth: Self.fluteDepth, ramp: .both, rampLength: 1.inch, rampShape: .smooth,
                                                         passDepth: Self.fluteDepth))
        let plain = try #require(CAMEngine.generate(flat).toolpaths.first)
        let deepest = plain.cuttingExtents.map { -$0.min.z } ?? 0
        #expect(abs(deepest - Self.fluteDepth) < 1e-6)
    }

    /// The flutes' ramps follow the surface: each pass starts and ends with the bit just touching the model.
    @Test func flatRampsStartOnTheSurface() throws {
        let p = Self.flatProject()
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let cutter = try Self.flatCutter(p)
        var ends: [(Vec3, Vec3)] = []
        var run: [Vec3] = []
        var position = tp.start
        for m in tp.motions {
            if m.kind == .rapid {
                if run.count > 1 { ends.append((run[0], run[run.count - 1])) }
                run = []
            } else if m.kind != .dwell {
                if run.isEmpty { run = [position] }
                run.append(m.end)
            }
            position = m.end
        }
        if run.count > 1 { ends.append((run[0], run[run.count - 1])) }
        // Each flute's run starts with the plunge from the plunge height down to the surface.
        #expect(ends.count == 3)
        for (first, last) in ends {
            #expect(abs(cutter.z(at: last.xy) - last.z) < 1e-6, "ends \(cutter.z(at: last.xy) - last.z) mm below the surface")
            #expect(first.z > 0)
        }
    }

    /// No move, as posted or as generated, goes deeper than the flute's depth below the drop-cutter surface.
    @Test func flatFlutesNeverGouge() throws {
        let p = Self.flatProject()
        let cutter = try Self.flatCutter(p)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let generated = Self.flatGouge(tp, cutter, depth: Self.fluteDepth)
        // Arc fitting's merged moves may sample up to its numeric slack (`ArcFitter.surfaceEpsilon`) below.
        #expect(generated.gouge < ArcFitter.surfaceEpsilon + 0.0001, "\(generated.gouge) mm past the flute depth")
        // The posted inch file rounds to 0.0001 in (0.00254 mm).
        for posted in try Self.posted(p) {
            let g = Self.flatGouge(posted, cutter, depth: Self.fluteDepth)
            #expect(g.gouge < 0.003, "posted: \(g.gouge) mm past the flute depth")
        }
    }

    /// A ring of flute round the crown, posted with arcs: the arcs fitted to it are checked against the surface (#128),
    /// so it goes no deeper below it than the same flute posted as straight moves.
    @Test func arcsOnAFluteAreCheckedAgainstTheSurface() throws {
        let ring = DesignShape(id: Self.id(14), name: "Ring", kind: .circle(radius: 0.8.inch), position: Self.columnCentre)
        let p = Self.flatProject(lines: [ring])
        #expect(p.machine.outputArcs)
        let op = p.operations[0]
        #expect(ArcFitter.surface(for: op, tool: op.tool, project: p) != nil)
        let cutter = try Self.flatCutter(p)
        let fitted = try #require(CAMEngine.generate(p).toolpaths.first)
        var straight = p
        straight.machine.outputArcs = false
        let unfitted = try #require(CAMEngine.generate(straight).toolpaths.first)
        let withArcs = Self.flatGouge(fitted, cutter, depth: Self.fluteDepth)
        let without = Self.flatGouge(unfitted, cutter, depth: Self.fluteDepth)
        #expect(withArcs.arcs > 0)
        #expect(withArcs.gouge <= max(without.gouge, 0) + 0.001, "arcs \(withArcs.gouge) mm, straight moves \(without.gouge) mm")
        #expect(without.gouge < 0.0002)
    }

    @Test func flatGolden() throws {
        try Self.checkGolden(Self.flatProject(), "flutes-on-model-flat-inch")
    }

    // MARK: Rotary

    static func rotaryCutter(_ p: Project) throws -> RotaryDropCutter {
        var triangles: [Double] = []
        for m in p.shapes where m.modelSpec != nil {
            m.forEachBlankTriangle { a, b, c in triangles += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        }
        return try #require(RotaryDropCutter(tool: Self.ball, allowance: 0, triangles: triangles))
    }

    /// Along each flute's middle (clear of its ramps) the bit is exactly 1.5 mm in from where it touches the leg, so
    /// the flute follows the taper and rides over the bead; over the tapers that's the leg's own radius less 1.5 mm.
    @Test func rotaryFlutesFollowTheLegsProfile() throws {
        let p = Self.rotaryProject()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        let cutter = try Self.rotaryCutter(p)
        let top = try #require(p.stock.rotary).topRadius, cy = p.stock.originPoint.y
        var off = 0.0, taper = 0.0, overBead = -Double.infinity
        var count = 0
        for m in tp.motions where m.kind == .feed {
            let along = m.end.x - Self.legStart
            guard along > 25 + 12.5 && along < 185 - 12.5 else { continue }
            let r = top + m.end.z
            let touch = cutter.tipRadius(x: m.end.x, angle: (m.end.y - cy) / top)
            off = max(off, abs(touch - Self.legDepth - r))
            if (40...140).contains(along) || (174...180).contains(along) {
                taper = max(taper, abs(Self.legRadius(along) - Self.legDepth - r))
            }
            if (163...167).contains(along) { overBead = max(overBead, r) }
            count += 1
        }
        #expect(count > 100)
        #expect(off < 1e-6, "\(off) mm off the depth below the drop-cutter surface")
        // The taper is gentle and the mesh fine (180 sides), so the ball's tip sits on the surface within 0.02 mm.
        #expect(taper < 0.02, "\(taper) mm off the leg's radius less the depth")
        // Over the bead's crest the flute rises with it.
        #expect(overBead > 18.5 - Self.legDepth - 0.05, "\(overBead) mm from the axis over the bead")
    }

    /// No posted move goes deeper than the flute's depth below the rotary drop-cutter surface: X, A and the distance
    /// from the axis read back from the file, sampled along each move as the controller moves them (linearly), and
    /// the feed is written as inverse time (G93).
    @Test func rotaryFlutesNeverGouge() throws {
        let p = Self.rotaryProject()
        let cutter = try Self.rotaryCutter(p)
        let text = String(decoding: GoldenPostTests.post(p), as: UTF8.self)
        #expect(text.contains("G93"))
        let motions = try GCodeParser.parse(text).segments.flatMap(\.motions)
        var worst = -Double.infinity
        var checked = 0
        var previous: Motion?
        for m in motions {
            defer { previous = m }
            guard m.kind == .feed, let s = previous, let a0 = s.a, let a1 = m.a else { continue }
            let dx: Double = abs(m.end.x - s.end.x)
            let round: Double = abs(a1 - a0) * Double.pi / 180 * 25
            let n = max(1, Int((max(dx, round) / 0.05).rounded(.up)))
            for k in 0...n {
                let t = Double(k) / Double(n)
                let x: Double = s.end.x + (m.end.x - s.end.x) * t
                let degrees: Double = a0 + (a1 - a0) * t
                let a = degrees * Double.pi / 180
                let r = s.end.z + (m.end.z - s.end.z) * t
                let touch = cutter.tipRadius(x: x, angle: a)
                if touch.isFinite { worst = max(worst, touch - Self.legDepth - r) }
            }
            checked += 1
        }
        #expect(checked > 100)
        // The mm file rounds to 0.001 mm and 0.001°. Wrapping joins the flutes' moves only where they're exactly in
        // line, so nothing it joins dips below them.
        #expect(worst < 0.002, "\(worst) mm past the flute depth")
    }

    @Test func rotaryGolden() throws {
        try Self.checkGolden(Self.rotaryProject(), "flutes-on-model-rotary-mm")
    }

    /// A rotary job cut on faces can't have flutes follow a model: refused, saying why.
    @Test func aFacesRotaryJobIsRefused() throws {
        var p = Self.rotaryProject()
        var blank = try #require(p.stock.rotary)
        blank.layout = nil
        p.stock.setRotary(blank)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.isEmpty)
        #expect(tp.warnings.contains { $0.contains("not on a rotary job cut on faces") }, "\(tp.warnings)")
    }

    // MARK: Unchanged output and the format

    /// Flutes from the material top or a start depth are saved as they always were (no new key, format 8); following a
    /// model is format 25, and round-trips.
    @Test func followingAModelIsFormat25() throws {
        #expect(Project.currentFormatVersion >= 25)
        #expect(Self.flatProject().formatVersion == 25)
        #expect(Self.flatProject().operations[0].requiredFormatVersion == 25)
        let top = FlutingParams(depth: 3)
        #expect(top.follow == .materialTop)
        #expect(FlutingParams(startDepth: 2, depth: 3).follow == .startDepth)
        let json = String(decoding: try JSONEncoder().encode(top), as: UTF8.self)
        #expect(!json.contains("surfaceModelID"))
        var p = Self.flatProject()
        p.operations[0].kind = .fluting(top)
        #expect(p.formatVersion == 8)
        let model = FlutingParams(depth: 3, surfaceModelID: Self.id(2))
        #expect(model.follow == .model)
        #expect(try JSONDecoder().decode(FlutingParams.self, from: JSONEncoder().encode(model)) == model)
    }

    // MARK: Saved project

    /// Every setting away from its default, saved as format 25: flutes on the column following it, ramped at the start
    /// only over 40% of their length with linear ramps in two passes, and flutes beside them from a start depth.
    static func savedProject() -> Project {
        let lines = [fluteLine(11, y: -0.6.inch, from: 1.75.inch, to: 8.25.inch), fluteLine(12, y: 0.6.inch, from: 1.75.inch, to: 8.25.inch)]
        let plain = DesignShape(id: id(15), name: "Plain flute", kind: .paths([Polyline([Vec2(0, 0), Vec2(3.inch, 0)], closed: false)]),
                                position: Vec2(0.5.inch, 0.4.inch))
        let ops = [
            CAMOperation(id: id(21), name: "Flutes on the column",
                         kind: .fluting(FlutingParams(depth: 0.08.inch, ramp: .start, rampLength: 0.5.inch, rampPercent: 0.4, rampShape: .linear,
                                                      passDepth: 0.04.inch, surfaceModelID: id(2))),
                         shapeIDs: lines.map(\.id), tool: ball),
            CAMOperation(id: id(22), name: "Plain flute",
                         kind: .fluting(FlutingParams(startDepth: 0.05.inch, depth: 0.06.inch, ramp: .end, rampLength: 0.75.inch)),
                         shapeIDs: [plain.id], tool: ball),
        ]
        return Project(name: "Flutes on a model (format 25)", displayUnits: .inch, stock: columnStock, machine: .avidPRO6060,
                       shapes: [column()] + lines + [plain], operations: ops,
                       notes: "Saved by format 25 to pin flutes that follow a 3D model's surface.")
    }

    @Test func savedFlutesOnModelProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("flutes-on-model-v25", make: Self.savedProject)
        #expect(p.formatVersion == 25)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "decoded-flutes-on-model-v25")
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

    /// The column's footprint in design coordinates: min and max corners.
    static var columnFootprint: (min: Vec2, max: Vec2) {
        (Vec2(columnCentre.x - columnLength / 2, columnCentre.y - columnWidth / 2),
         Vec2(columnCentre.x + columnLength / 2, columnCentre.y + columnWidth / 2))
    }

    /// The points every `step` mm along every move of `tp`, rapids and plunges included.
    static func allPoints(_ tp: Toolpath, step: Double = 0.02) -> [Vec3] {
        var points: [Vec3] = []
        tp.forEachMotion { s, m in
            guard m.kind != .dwell else { return }
            if m.kind.isArc {
                points.append(s)
                points += m.samples(from: s, maxStep: step)
            } else {
                let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
                for k in 0...n { points.append(s + (m.end - s) * (Double(k) / Double(n))) }
            }
        }
        return points
    }

    /// A flat flute running off the column (#138), as generated and as posted: no move goes deeper than the flute's
    /// depth below the drop-cutter surface it's over, and nothing past the column's footprint goes below the material
    /// top, where a ball centred past the column's end would slide down the end wall and notch the board.
    static func checkFlatRunOff(_ p: Project, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        let warned = job.issues.contains { $0.severity == .warning && $0.message.contains("runs off the edge of the 3D model") }
        #expect(warned, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        let tp = try #require(job.toolpaths.first, sourceLocation: sourceLocation)
        #expect(!tp.isEmpty, sourceLocation: sourceLocation)
        let cutter = try Self.flatCutter(p)
        let generated = Self.flatGouge(tp, cutter, depth: Self.fluteDepth).gouge
        #expect(generated < ArcFitter.surfaceEpsilon + 0.0001, "\(generated) mm past the flute depth", sourceLocation: sourceLocation)
        // The generated cut starts and ends with the bit's centre on the footprint.
        let ext = try #require(tp.cuttingExtents, sourceLocation: sourceLocation)
        let foot = Self.columnFootprint
        let inX = ext.min.x >= foot.min.x - 1e-6 && ext.max.x <= foot.max.x + 1e-6
        #expect(inX, "cuts X \(ext.min.x) to \(ext.max.x), the column is \(foot.min.x) to \(foot.max.x)", sourceLocation: sourceLocation)
        // As posted: the inch file rounds to 0.0001 in (0.00254 mm), so points within that of the footprint count as on it.
        var gouge = -Double.infinity, outsideLowest = Double.infinity, outsideCount = 0
        var hint: Int32 = -1
        for t in try Self.posted(p) {
            for q in Self.allPoints(t) {
                let z = cutter.z(at: q.xy, hint: &hint)
                if z.isFinite { gouge = max(gouge, z - Self.fluteDepth - q.z) }
                let inX = q.x >= foot.min.x - 0.003 && q.x <= foot.max.x + 0.003
                let inY = q.y >= foot.min.y - 0.003 && q.y <= foot.max.y + 0.003
                if !(inX && inY) {
                    outsideLowest = min(outsideLowest, q.z)
                    outsideCount += 1
                }
            }
        }
        #expect(gouge < 0.003, "posted: \(gouge) mm past the flute depth", sourceLocation: sourceLocation)
        #expect(outsideCount > 0, sourceLocation: sourceLocation)
        #expect(outsideLowest > -0.003, "posted: \(outsideLowest) mm off the column's footprint", sourceLocation: sourceLocation)
    }

    /// A flute drawn past both ends of the column: cut only where the bit's centre is over the model, ramping in and
    /// out at its ends, with a warning in Checks; never past its depth below the surface, and never below the material
    /// top past the column's ends (#138: it plunged to Z-0.3698 at X0.8751, a radius past the end, against the end wall).
    @Test func aFluteRunningOffTheModelIsCutOnlyOnIt() throws {
        let p = try Self.edgeCase("runs-off-edge") {
            Self.flatProject(lines: [Self.fluteLine(11, y: 0, from: 0.25.inch, to: 9.75.inch)])
        }
        try Self.checkFlatRunOff(p)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let cutter = try Self.flatCutter(p)
        // The cut starts and ends with the bit just touching the model at its edge (the ends of the ramps), not at
        // full depth, and with its centre on the column's end.
        let firstFeed = try #require(tp.motions.first { $0.kind == .feed })
        let lastFeed = try #require(tp.motions.last { $0.kind == .feed })
        #expect(abs(cutter.z(at: firstFeed.end.xy) - firstFeed.end.z) < 1e-6)
        #expect(abs(cutter.z(at: lastFeed.end.xy) - lastFeed.end.z) < 1e-6)
        let foot = Self.columnFootprint
        #expect(abs(firstFeed.end.x - foot.min.x) < 0.01, "starts at X \(firstFeed.end.x)")
        #expect(abs(lastFeed.end.x - foot.max.x) < 0.01, "ends at X \(lastFeed.end.x)")
        try Self.checkGolden(p, "flutes-on-model-runs-off-edge", allowing: "runs off the edge of the 3D model")
    }

    /// A flute drawn past the column's start end only, ramping at its far end: it plunges straight to full depth, with
    /// the bit's centre on the column's end, not past it.
    @Test func aFluteRunningOffTheModelsStartPlungesOnIt() throws {
        let p = try Self.edgeCase("runs-off-start") {
            Self.flatProject(FlutingParams(depth: Self.fluteDepth, ramp: .end, rampLength: 1.inch, rampShape: .smooth,
                                           passDepth: Self.fluteDepth, surfaceModelID: Self.id(2)),
                             lines: [Self.fluteLine(11, y: 0, from: 0.25.inch, to: 6.inch)])
        }
        try Self.checkFlatRunOff(p)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.min.x - Self.columnFootprint.min.x) < 0.01, "starts at X \(ext.min.x)")
        try Self.checkGolden(p, "flutes-on-model-runs-off-start", allowing: "runs off the edge of the 3D model")
    }

    /// A flute drawn past the column's far end only, ramping at its start: it runs at full depth to the column's end
    /// and lifts off there, with the bit's centre on it.
    @Test func aFluteRunningOffTheModelsEndStopsOnIt() throws {
        let p = try Self.edgeCase("runs-off-end") {
            Self.flatProject(FlutingParams(depth: Self.fluteDepth, ramp: .start, rampLength: 1.inch, rampShape: .smooth,
                                           passDepth: Self.fluteDepth, surfaceModelID: Self.id(2)),
                             lines: [Self.fluteLine(11, y: 0, from: 4.inch, to: 9.75.inch)])
        }
        try Self.checkFlatRunOff(p)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.max.x - Self.columnFootprint.max.x) < 0.01, "ends at X \(ext.max.x)")
        try Self.checkGolden(p, "flutes-on-model-runs-off-end", allowing: "runs off the edge of the 3D model")
    }

    /// Flutes drawn past both ends of the turned leg on the wrapped rotary job: cut only along the leg, ramping in and
    /// out at its ends. As posted, no move goes deeper than the flute's depth below the rotary drop-cutter surface,
    /// and nothing past the leg's ends comes in from the blank's surface.
    @Test func rotaryFlutesRunningOffTheModelAreCutOnlyOnIt() throws {
        let p = try Self.edgeCase("runs-off-rotary") { Self.rotaryProject(from: -10, length: 220) }
        let job = CAMEngine.generate(p)
        let warned = job.issues.contains { $0.severity == .warning && $0.message.contains("run off the edge of the 3D model") }
        #expect(warned, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        let ext = try #require(tp.cuttingExtents)
        let legEnd = Self.legStart + 200
        #expect(ext.min.x >= Self.legStart - 1e-6 && ext.min.x < Self.legStart + 0.01, "starts at X \(ext.min.x)")
        #expect(ext.max.x <= legEnd + 1e-6 && ext.max.x > legEnd - 0.01, "ends at X \(ext.max.x)")

        let cutter = try Self.rotaryCutter(p)
        let top = try #require(p.stock.rotary).topRadius
        let text = String(decoding: GoldenPostTests.post(p), as: UTF8.self)
        let motions = try GCodeParser.parse(text).segments.flatMap(\.motions)
        var worst = -Double.infinity, outsideLowest = Double.infinity
        var outsideCount = 0, checked = 0
        var previous: Motion?
        var angle: Double?
        for m in motions {
            defer {
                previous = m
                if let a = m.a { angle = a }
            }
            guard m.kind != .dwell, let s = previous else { continue }
            let a0 = angle, a1 = m.a ?? angle
            let dx: Double = abs(m.end.x - s.end.x)
            let dr: Double = abs(m.end.z - s.end.z)
            var round = 0.0
            if let from = a0, let to = a1 { round = abs(to - from) * Double.pi / 180 * top }
            let n = max(1, Int((max(dx, dr, round) / 0.05).rounded(.up)))
            for k in 0...n {
                let t = Double(k) / Double(n)
                let x: Double = s.end.x + (m.end.x - s.end.x) * t
                let r: Double = s.end.z + (m.end.z - s.end.z) * t
                if x < Self.legStart - 0.002 || x > legEnd + 0.002 {
                    outsideLowest = min(outsideLowest, r)
                    outsideCount += 1
                }
                guard m.kind == .feed, let from = a0, let to = a1 else { continue }
                let degrees: Double = from + (to - from) * t
                let touch = cutter.tipRadius(x: x, angle: degrees * Double.pi / 180)
                if touch.isFinite { worst = max(worst, touch - Self.legDepth - r) }
            }
            checked += 1
        }
        #expect(checked > 100)
        #expect(worst < 0.002, "\(worst) mm past the flute depth")
        // The mm file rounds to 0.001 mm.
        #expect(outsideCount > 0)
        #expect(outsideLowest > top - 0.002, "\(outsideLowest) mm from the axis past the leg's ends; the blank's is \(top) mm")
        try Self.checkGolden(p, "flutes-on-model-runs-off-rotary", allowing: "run off the edge of the 3D model")
    }

    // MARK: #139

    /// On a blank much bigger than the leg, flutes following it are measured from the leg's surface for the bit's
    /// cutting length, not from the blank's (the 3D finish before them has cleared the wood between); a flute deeper
    /// than the cutting length below the surface still warns.
    @Test func theCuttingLengthCheckCountsFromTheModel() throws {
        var p = Self.rotaryProject()
        var blank = try #require(p.stock.rotary)
        blank.diameter = 3.inch
        p.stock.setRotary(blank)
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let deepest = -(try #require(tp.cuttingExtents)).min.z
        #expect(deepest > Self.ball.fluteLength, "the flutes are \(deepest) mm in from the blank's surface")
        let warns = job.issues.contains { $0.message.contains("exceeds the cutting length") }
        #expect(!warns, "\(job.issues.map(\.message))")

        var deep = p
        guard case var .fluting(f) = deep.operations[0].kind else { Issue.record("not fluting"); return }
        f.depth = Self.ball.fluteLength + 1
        f.passDepth = f.depth
        deep.operations[0].kind = .fluting(f)
        let deepJob = CAMEngine.generate(deep)
        let deepWarns = deepJob.issues.contains { $0.message.contains("exceeds the cutting length") }
        #expect(deepWarns, "\(deepJob.issues.map(\.message))")
    }

    /// The setup sheet names the model flutes follow and says their depth is below its surface.
    @Test func theSetupSheetNamesTheModel() {
        let p = Self.flatProject()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p), date: GoldenPostTests.date)
        #expect(html.contains("flutes 0.100 in below the surface of “Column”"), "\(html)")
    }

    /// The template line under the vectors of flutes whose model has been deleted says the model is missing, not the
    /// layer the flute lines happen to be on.
    @Test func theTemplateLineSaysTheModelIsMissing() throws {
        let missing = try Self.edgeCase("missing-model") { Project() }
        let line = try #require(missing.templateLine(for: missing.operations[0], units: .inch))
        #expect(line.contains("3D model these flutes follow is missing"), "\(line)")
        let present = Self.flatProject()
        let ok = try #require(present.templateLine(for: present.operations[0], units: .inch))
        #expect(!ok.contains("missing"), "\(ok)")
        #expect(ok.hasPrefix("In a template: "), "\(ok)")
    }

    /// Flutes set to follow a model that's no longer in the job: refused, with one empty toolpath and a warning saying
    /// so, and nothing posted for them.
    @Test func aMissingModelIsRefused() throws {
        let p = try Self.edgeCase("missing-model") {
            var p = Self.flatProject()
            p.shapes.removeAll { $0.id == Self.id(2) }
            return p
        }
        #expect(!p.shapes.contains { $0.modelSpec != nil })
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.isEmpty)
        #expect(job.issues.contains { $0.severity == .warning && $0.message.contains("isn't in the job") }, "\(job.issues.map(\.message))")
        #expect(!job.issues.contains { $0.message == "Toolpath is empty." })
    }
}
