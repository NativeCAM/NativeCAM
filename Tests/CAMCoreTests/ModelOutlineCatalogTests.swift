import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for a 3D model's outline from above (#202): the exact union of its triangles' shadows
/// (`ModelSections.outline`), which 2D profiles, holding tabs, protected regions, Nest Parts and the 3D "Model outline"
/// boundary cut to. Two faceted discs read from STLs written for the tests (`Fixtures/model-outline`), each cut out by
/// an outside profile posted for Avid's Mach4 default; an open mesh; and a large relief, timed.
struct ModelOutlineCatalogTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("model-outline")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "202A0000-0000-4000-8000-%012d", n))! }

    static let endMill = ToolLibrary.starter.tool(number: 1)! // 1/4" upcut

    // MARK: Meshes

    /// A disc `sides`-sided, its corners at `radius` mm from its centre, `thickness` mm thick, centred on the origin
    /// with its bottom at z = 0: a fan top and bottom and a wall of quads.
    static func discSTL(radius: Double, sides: Int, thickness: Double, header: String) -> Data {
        func rim(_ j: Int, _ z: Double) -> SIMD3<Float> {
            let a = 2 * Double.pi * Double(j % sides) / Double(sides)
            return SIMD3(Float(radius * cos(a)), Float(radius * sin(a)), Float(z))
        }
        let top = SIMD3<Float>(0, 0, Float(thickness)), bottom = SIMD3<Float>(0, 0, 0)
        var tris: [MeshImportTests.Tri] = []
        for j in 0..<sides {
            tris.append((top, rim(j, thickness), rim(j + 1, thickness)))
            tris.append((bottom, rim(j + 1, 0), rim(j, 0)))
            tris.append((rim(j, 0), rim(j + 1, 0), rim(j + 1, thickness)))
            tris.append((rim(j, 0), rim(j + 1, thickness), rim(j, thickness)))
        }
        return MeshImportTests.binarySTL(tris, header: header)
    }

    /// An open mesh: a domed sheet 80 × 50 mm on a 40 × 25 grid with no walls or bottom, every other row of triangles
    /// wound the other way (as a careless exporter leaves it), and a hole 8 × 10 mm through its middle.
    static func openSheetSTL() -> Data {
        let nx = 40, ny = 25, w = 80.0, h = 50.0
        func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let x = w * Double(i) / Double(nx) - w / 2, y = h * Double(j) / Double(ny) - h / 2
            let z = 5 + 3 * cos(x / w * .pi) * cos(y / h * .pi)
            return SIMD3(Float(x), Float(y), Float(z))
        }
        var tris: [MeshImportTests.Tri] = []
        for i in 0..<nx {
            for j in 0..<ny {
                let a = p(i, j), b = p(i + 1, j), c = p(i + 1, j + 1), d = p(i, j + 1)
                let cx = Double(i) + 0.5 - Double(nx) / 2, cy = Double(j) + 0.5 - Double(ny) / 2
                if abs(cx) < 2.5, abs(cy) < 2.5 { continue } // the hole: 4 × 5 cells of 2 mm
                if j % 2 == 0 { tris += [(a, b, c), (a, c, d)] } else { tris += [(a, c, b), (a, d, c)] }
            }
        }
        return MeshImportTests.binarySTL(tris, header: "NativeCAM test open sheet, 80 x 50 mm, mixed winding")
    }

    /// A relief `n` × `n` cells over 200 × 150 mm: ripples on a plinth with walls and a bottom, its edge a wavy outline
    /// (each wall vertex pushed out by up to 1.5 mm). 2n² + 8n + 2(4n - 2) triangles about.
    static func reliefTriangles(_ n: Int) -> [MeshImportTests.Tri] {
        let w = 200.0, h = 150.0
        func edgeWobble(_ x: Double, _ y: Double) -> Double { 1.5 * sin(x * 0.21) * cos(y * 0.17) }
        func top(_ i: Int, _ j: Int) -> SIMD3<Float> {
            var x = w * Double(i) / Double(n) - w / 2, y = h * Double(j) / Double(n) - h / 2
            if i == 0 { x -= edgeWobble(x, y) } else if i == n { x += edgeWobble(x, y) }
            if j == 0 { y -= edgeWobble(x, y) } else if j == n { y += edgeWobble(x, y) }
            let z = 6 + 2 * sin(x * 0.13) * cos(y * 0.11) + 0.8 * sin(x * 0.61 + y * 0.37)
            return SIMD3(Float(x), Float(y), Float(z))
        }
        func base(_ q: SIMD3<Float>) -> SIMD3<Float> { SIMD3(q.x, q.y, 0) }
        var tris: [MeshImportTests.Tri] = []
        tris.reserveCapacity(2 * n * n + 16 * n)
        for i in 0..<n {
            for j in 0..<n {
                let a = top(i, j), b = top(i + 1, j), c = top(i + 1, j + 1), d = top(i, j + 1)
                tris += [(a, b, c), (a, c, d)]
            }
        }
        // Walls round the edge, and a bottom fanned from its middle.
        var ring: [SIMD3<Float>] = []
        for i in 0..<n { ring.append(top(i, 0)) }
        for j in 0..<n { ring.append(top(n, j)) }
        for i in stride(from: n, to: 0, by: -1) { ring.append(top(i, n)) }
        for j in stride(from: n, to: 0, by: -1) { ring.append(top(0, j)) }
        let mid = SIMD3<Float>(0, 0, 0)
        for k in ring.indices {
            let p = ring[k], q = ring[(k + 1) % ring.count]
            tris += [(p, base(p), base(q)), (p, base(q), q), (mid, base(q), base(p))]
        }
        return tris
    }

    /// Loads a mesh fixture, writing it in update mode when it's missing (never replaced).
    static func mesh(_ file: String, id n: Int, make: () -> Data) -> MeshModel {
        let url = dir.appendingPathComponent(file)
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? make().write(to: url, options: .atomic)
        }
        // swiftlint:disable:next force_try
        var mesh = try! STLImporter.importSTL(data: Data(contentsOf: url), name: file).mesh
        mesh.id = id(n)
        return mesh
    }

    static let disc60 = mesh("disc-r60-256.stl", id: 1) {
        discSTL(radius: 60, sides: 256, thickness: 12, header: "NativeCAM test disc, R 60 mm, 256 sides, 12 mm, mm")
    }

    static let disc205 = mesh("disc-r205-720.stl", id: 2) {
        discSTL(radius: 205.74, sides: 720, thickness: 19.05, header: "NativeCAM test disc, R 205.74 mm, 720 sides, 3/4 in, mm")
    }

    static let openSheet = mesh("open-sheet.stl", id: 3, make: openSheetSTL)

    static let relief = mesh("relief.stl", id: 4) {
        MeshImportTests.binarySTL(reliefTriangles(120), header: "NativeCAM test relief, 200 x 150 mm, 120 x 120 grid, mm")
    }

    // MARK: Measuring

    /// The non-zero winding number of `p` round `loops`.
    static func winding(_ p: Vec2, _ loops: [Polyline]) -> Int {
        var w = 0
        for loop in loops {
            for k in 0..<loop.count {
                let a = loop.points[k], b = loop.points[(k + 1) % loop.count]
                if a.y <= p.y {
                    if b.y > p.y, (b - a).cross(p - a) > 0 { w += 1 }
                } else if b.y <= p.y, (b - a).cross(p - a) < 0 {
                    w -= 1
                }
            }
        }
        return w
    }

    static func distance(_ p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let d = b - a, l2 = d.dot(d)
        let t = l2 > 0 ? max(0, min(1, (p - a).dot(d) / l2)) : 0
        return p.distance(to: a + d * t)
    }

    static func distance(_ p: Vec2, to loops: [Polyline]) -> Double {
        var best = Double.infinity
        for loop in loops {
            for k in 0..<loop.count { best = min(best, distance(p, toSegment: loop.points[k], loop.points[(k + 1) % loop.count])) }
        }
        return best
    }

    /// Mesh vertices (in the outline's frame) neither inside the outline nor within `tolerance` mm of it.
    static func verticesOutside(_ o: OrientedMesh, tolerance: Double = 1e-4) -> [Vec2] {
        var out: [Vec2] = []
        var seen = Set<Vec2>()
        for v in o.positions {
            let p = Vec2(Double(v.x), Double(v.y))
            guard seen.insert(p).inserted else { continue }
            if winding(p, o.silhouette) == 0, distance(p, to: o.silhouette) > tolerance { out.append(p) }
        }
        return out
    }

    /// Points along a toolpath's cutting moves at or below `z`, every 0.25 mm or so (arcs included).
    static func cuttingPoints(_ tp: Toolpath, below z: Double) -> [Vec2] {
        var pts: [Vec2] = []
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell, min(s.z, m.end.z) <= z + 1e-9 else { return }
            let a = Vec2(s.x, s.y), b = Vec2(m.end.x, m.end.y)
            if m.kind.isArc {
                let r = a.distance(to: m.center)
                let a0 = atan2(a.y - m.center.y, a.x - m.center.x)
                var a1 = atan2(b.y - m.center.y, b.x - m.center.x)
                if m.kind == .arcCCW { while a1 <= a0 + 1e-12 { a1 += 2 * .pi } } else { while a1 >= a0 - 1e-12 { a1 -= 2 * .pi } }
                if a.isApprox(b, tolerance: 1e-9) { a1 = a0 + (m.kind == .arcCCW ? 2 : -2) * .pi }
                let n = max(2, Int(abs(a1 - a0) * r / 0.25))
                for k in 0...n {
                    let t = a0 + (a1 - a0) * Double(k) / Double(n)
                    pts.append(m.center + Vec2(cos(t), sin(t)) * r)
                }
            } else {
                let n = max(1, Int(a.distance(to: b) / 0.25))
                for k in 0...n { pts.append(a + (b - a) * (Double(k) / Double(n))) }
            }
        }
        return pts
    }

    // MARK: The outline holds the whole mesh

    @Test(arguments: ["disc60", "disc205", "openSheet", "relief"])
    func everyVertexLiesInsideOrOnTheOutline(_ which: String) {
        let mesh = [("disc60", Self.disc60), ("disc205", Self.disc205), ("openSheet", Self.openSheet), ("relief", Self.relief)]
            .first { $0.0 == which }!.1
        let o = ModelGeometry.oriented(ModelSpec(mesh: mesh, upAxis: .z, depth: 10))
        #expect(!o.silhouette.isEmpty)
        let outside = Self.verticesOutside(o)
        #expect(outside.isEmpty, "\(outside.count) vertices outside, e.g. \(outside.prefix(3))")
    }

    @Test func aDiscsOutlineIsItsPolygon() {
        let o = ModelGeometry.oriented(ModelSpec(mesh: Self.disc205, upAxis: .z, depth: 19.05))
        #expect(o.silhouette.count == 1)
        let loop = o.silhouette[0]
        #expect(loop.isCounterClockwise)
        let n = 720.0, r = 205.74
        let polygonArea = n / 2 * r * r * sin(2 * .pi / n)
        #expect(abs(loop.area - polygonArea) < 0.05, "\(loop.area) vs \(polygonArea)")
        // Every corner of the outline is a corner of the disc: none cut short, none added outside.
        #expect(loop.points.allSatisfy { abs($0.length - r) < 1e-3 })
    }

    @Test func anOpenMeshWithMixedWindingKeepsItsHole() {
        let o = ModelGeometry.oriented(ModelSpec(mesh: Self.openSheet, upAxis: .z, depth: 8))
        let outers = o.silhouette.filter(\.isCounterClockwise), holes = o.silhouette.filter { !$0.isCounterClockwise }
        #expect(outers.count == 1 && holes.count == 1)
        #expect(abs((outers.first?.area ?? 0) - 80 * 50) < 1e-3)
        #expect(abs((holes.first?.area ?? 0) - 8 * 10) < 1e-3)
        // Its middle is outside the outline, its corners inside.
        #expect(Self.winding(.zero, o.silhouette) == 0)
        #expect(Self.winding(Vec2(39, 24), o.silhouette) != 0)
    }

    /// A relief of 130k triangles: its outline must take well under a second (the raster it replaced took about 0.1 s).
    @Test func aLargeReliefsOutlineIsQuick() {
        let tris = Self.reliefTriangles(254)
        var pos: [SIMD3<Float>] = []
        pos.reserveCapacity(tris.count * 3)
        for t in tris { pos += [t.0, t.1, t.2] }
        let idx = (0..<UInt32(pos.count)).map { $0 }
        #expect(tris.count > 130_000)
        let clock = ContinuousClock()
        var loops: [Polyline] = []
        let took = clock.measure { loops = ModelSections.outline(positions: pos, indices: idx) }
        print("Outline of a \(tris.count)-triangle relief: \(took)")
        #expect(loops.count == 1)
        #expect(took < .seconds(3), "\(took)")
    }

    // MARK: Outside profiles on the discs

    static func discJob(_ name: String, mesh: MeshModel, thickness: Double, units: LengthUnit) -> Project {
        let width = (Double(mesh.bounds.max.x - mesh.bounds.min.x) + 40).rounded(.up)
        let centre = Vec2(width / 2, width / 2)
        let model = DesignShape(id: id(10), name: "Disc", kind: .model(ModelSpec(mesh: mesh, upAxis: .z, depth: thickness)),
                                position: centre)
        let op = CAMOperation(id: id(11), name: "Cut out disc",
                              kind: .profile(ProfileParams(side: .outside, direction: .climb,
                                                           depth: DepthSettings(cutDepth: thickness + 0.5))),
                              shapeIDs: [model.id], tool: endMill)
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        let stock = Stock(width: width, height: width, thickness: thickness, materialName: "MDF", clearanceHeight: 10,
                          plungeHeight: 2, materialKind: .mdf)
        return Project(name: name, displayUnits: units, stock: stock, machine: machine, shapes: [model], operations: [op])
    }

    /// The bit's edge never comes inside the disc's polygon: its centre stays a bit radius or more from it (to within
    /// 2 µm of arc fitting), and where it passes a corner it's a bit radius or more outside the corner's radius.
    static func checkDisc(_ p: Project, radius: Double, sides: Int, golden: String,
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))", sourceLocation: sourceLocation)
        let tp = try #require(job.toolpaths.first, sourceLocation: sourceLocation)
        let centre = p.shapes[0].position
        let polygon = [Polyline((0..<sides).map { j in
            centre + Vec2.fromAngle(2 * .pi * Double(j) / Double(sides), length: radius)
        }, closed: true)]
        let pts = cuttingPoints(tp, below: -0.1)
        #expect(pts.count > 100, sourceLocation: sourceLocation)
        let r = Self.endMill.radius
        let nearest = pts.map { distance($0, to: polygon) }.min() ?? 0
        #expect(pts.allSatisfy { winding($0, polygon) == 0 }, sourceLocation: sourceLocation)
        #expect(nearest >= r - 2e-3, "bit edge \(nearest - r) mm from the disc", sourceLocation: sourceLocation)
        // The bit's edge reaches no nearer the centre than the disc's flats, and is at the corners' radius or more.
        let closest = pts.map { $0.distance(to: centre) }.min() ?? 0
        #expect(closest - r >= radius * cos(.pi / Double(sides)) - 2e-3, "\(closest - r)", sourceLocation: sourceLocation)
        let cornerDirs = (0..<sides).map { Vec2.fromAngle(2 * .pi * Double($0) / Double(sides), length: 1) }
        var atCorners = Double.infinity
        for q in pts {
            let d = q - centre, len = d.length
            if cornerDirs.contains(where: { abs($0.cross(d / len)) < 1e-4 && $0.dot(d) > 0 }) { atCorners = min(atCorners, len - r) }
        }
        if atCorners.isFinite {
            #expect(atCorners >= radius - 2e-3, "bit edge at a corner \(atCorners) mm out", sourceLocation: sourceLocation)
        }
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: golden, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity == .error }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    /// The 256-sided R 60 mm disc, cut out in mm. The traced outline put the bit's edge at 59.86 mm, 0.13 mm in.
    @Test func outsideProfileOnTheSmallDiscStaysOutsideIt() throws {
        let p = Self.discJob("Disc R60", mesh: Self.disc60, thickness: 12, units: .mm)
        try Self.checkDisc(p, radius: 60, sides: 256, golden: "model-outline-disc-r60-mm")
    }

    /// The 720-sided R 205.74 mm disc, cut out in inches. The traced outline put the bit's edge at 205.24 mm: 0.020" in.
    @Test func outsideProfileOnTheLargeDiscStaysOutsideIt() throws {
        let p = Self.discJob("Disc R205", mesh: Self.disc205, thickness: 19.05, units: .inch)
        try Self.checkDisc(p, radius: 205.74, sides: 720, golden: "model-outline-disc-r205-inch")
    }

    // MARK: Nest Parts

    /// Three R 60 mm model discs, each cut out by its outside profile, nest on a 500 × 300 mm sheet with the job's
    /// checks clean: each part's outline is its exact polygon, so the bit stays clear of the next disc.
    @Test func modelDiscsNestOnTheirExactOutlines() throws {
        var shapes: [DesignShape] = []
        var ops: [CAMOperation] = []
        for k in 0..<3 {
            let model = DesignShape(id: Self.id(30 + k), name: "Disc \(k + 1)",
                                    kind: .model(ModelSpec(mesh: Self.disc60, upAxis: .z, depth: 12)),
                                    position: Vec2(70 + 130 * Double(k), 70))
            shapes.append(model)
            ops.append(CAMOperation(id: Self.id(40 + k), name: "Cut out disc \(k + 1)",
                                    kind: .profile(ProfileParams(side: .outside, direction: .climb, depth: DepthSettings(cutDepth: 12.5))),
                                    shapeIDs: [model.id], tool: Self.endMill))
        }
        let stock = Stock(width: 500, height: 300, thickness: 12, materialName: "MDF", clearanceHeight: 10, plungeHeight: 2,
                          materialKind: .mdf)
        let p = Project(name: "Discs", displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: shapes, operations: ops)
        let job = try NestJob.prepare(p, selection: [])
        var s = job.defaultSettings
        s.maxSheets = 1
        s.maxEvaluations = 10
        s.seed = 202
        let clock = ContinuousClock()
        var r: Nesting.Result?
        let took = clock.measure { r = job.nest(s) }
        let result = try #require(r)
        #expect(result.placements.allSatisfy { $0 != nil })
        #expect(job.check(result, settings: s).isEmpty, "\(job.check(result, settings: s))")
        #expect(took < .seconds(10), "\(took)")
        let nested = job.apply(result, to: p, settings: s).project
        let generated = CAMEngine.generate(nested)
        #expect(!generated.hasErrors, "\(generated.issues.filter { $0.severity == .error }.map(\.message))")
    }
}
