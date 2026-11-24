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
    static func rotaryProject() -> Project {
        var stock = Stock(materialName: "Maple", materialKind: .hardwood)
        stock.setRotary(legBlank)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 100)
        machine.outputUnits = .mm
        let around = Double.pi * legBlank.diameter
        let lines = (0..<6).map { k in
            DesignShape(id: id(30 + k), name: "Flute \(k + 1)", kind: .paths([Polyline([Vec2(0, 0), Vec2(160, 0)], closed: false)]),
                        position: Vec2(legStart + 25, around * (Double(k) + 0.5) / 6))
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

    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        let unexpected = job.issues.filter { $0.severity != .info && !$0.message.contains("rotary axis turns at most") }
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

    /// A flute drawn past both ends of the column: cut only where the bit reaches the model, ramping in and out at its
    /// ends, with a warning in Checks, and never past its depth below the surface.
    @Test func aFluteRunningOffTheModelIsCutOnlyOnIt() throws {
        let p = try Self.edgeCase("runs-off-edge") {
            Self.flatProject(lines: [Self.fluteLine(11, y: 0, from: 0.25.inch, to: 9.75.inch)])
        }
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .warning && $0.message.contains("runs off the edge of the 3D model") },
                "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(!tp.isEmpty)
        let ext = try #require(tp.cuttingExtents)
        let modelMin = Self.columnCentre.x - Self.columnLength / 2, modelMax = Self.columnCentre.x + Self.columnLength / 2
        #expect(ext.min.x > modelMin - Self.ball.radius - 0.01 && ext.min.x < modelMin + 0.01, "starts at \(ext.min.x)")
        #expect(ext.max.x < modelMax + Self.ball.radius + 0.01 && ext.max.x > modelMax - 0.01, "ends at \(ext.max.x)")
        let cutter = try Self.flatCutter(p)
        #expect(Self.flatGouge(tp, cutter, depth: Self.fluteDepth).gouge < ArcFitter.surfaceEpsilon + 0.0001)
        // The cut ends with the bit just touching the model at its edge (the end of the ramp), not at full depth.
        let lastFeed = try #require(tp.motions.last { $0.kind == .feed })
        #expect(abs(cutter.z(at: lastFeed.end.xy) - lastFeed.end.z) < 1e-6)
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
