import Foundation
import Testing
@testable import CAMCore

/// #204: with an end mill clearing a V-carve's flats, the V-bit cleaned the corners the end mill can't reach only on an
/// inlay. An ordinary V-carve was left with a nub in every square corner of its flats, standing r(1 − sin(θ/2))/tan α
/// proud of the floor (r the end mill's radius, θ the corner's angle, α the V-bit's half angle): 0.93 mm with a 1/4"
/// end mill in a 90° corner and a 90° V-bit, 1.61 mm with a 60° one, and more in the A's sharper feet.
///
/// The design is `Fixtures/svg/vcarve-corners-flat.svg`: FLAT in block capitals 2.4" tall with 0.6" strokes, imported
/// into `Fixtures/projects/vcarve-corners-<angle>-v1.nativecam` and carved to a 1/8" flat depth with the starter 1/4"
/// upcut end mill clearing the flats, once with the 90° V-bit and once with the 60°, on the default Avid PRO6060.
struct VCarveCornerTests {
    static let library = ToolLibrary.starter
    static var endMill: Tool { library.tool(number: 1)! }
    static func vBit(_ angle: Int) -> Tool { library.tool(number: angle == 90 ? 6 : 5)! }
    static let flatDepth = 0.125.inch
    static let arcTolerance = 0.005
    static let angles = [90, 60]

    /// The FLAT drawing imported as File ▸ Import does, in an inch job on the default Avid PRO6060.
    static func importedFLAT() -> Project {
        let stock = Stock(width: 9.inch, height: 3.5.inch, thickness: 0.75.inch, materialName: "Walnut")
        guard let url = Bundle.module.url(forResource: "vcarve-corners-flat", withExtension: "svg", subdirectory: "Fixtures/svg"),
              let shapes = try? VectorImporter.importFile(at: url).shapes(name: "vcarve-corners-flat", stock: stock) else {
            return Project(name: "FLAT V-carve", displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: [])
        }
        return Project(name: "FLAT V-carve", displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: shapes)
    }

    /// The V-carve of every shape in `project` with the `angle`° V-bit, the 1/4" end mill clearing the flats.
    static func carve(_ angle: Int, shapes: [DesignShape]) -> CAMOperation {
        CAMOperation(id: UUID(uuidString: String(format: "204C0E00-0000-0000-0000-%012d", angle))!, name: "V-carve FLAT",
                     kind: .vcarve(VCarveParams(flatDepth: flatDepth, clearanceTool: endMill)), shapeIDs: shapes.map(\.id),
                     tool: vBit(angle))
    }

    static func made(_ angle: Int) -> Project {
        var p = importedFLAT()
        p.name = "FLAT V-carve (\(angle)° V-bit)"
        p.operations = [carve(angle, shapes: p.shapes)]
        return p
    }

    static func saved(_ angle: Int) throws -> Project {
        try GoldenPostTests.savedProject("vcarve-corners-\(angle)-v1") { made(angle) }
    }

    @Test(arguments: angles)
    func theFLATProjectsAreSavedAsMade(angle: Int) throws {
        let p = try Self.saved(angle)
        #expect(p.formatVersion == 1)
        #expect(try Project.decode(p.encoded()) == p)
        // F, L, the A with its counter, and T: the same outlines as the drawing gives today, where it was drawn.
        let saved = p.shapes.flatMap { $0.polylines(tolerance: 0.01) }
        let fresh = Self.importedFLAT().shapes.flatMap { $0.polylines(tolerance: 0.01) }
        #expect(saved.count == 5 && saved == fresh)
        #expect(abs(saved.bounds.min.x - 0.4.inch) < 0.01 && abs(saved.bounds.width - 8.2.inch) < 0.01, "\(saved.bounds)")
        #expect(abs(saved.bounds.min.y - 0.55.inch) < 0.01 && abs(saved.bounds.height - 2.4.inch) < 0.01, "\(saved.bounds)")
        #expect(p.operations == [Self.carve(angle, shapes: p.shapes)])
    }

    // MARK: The carve, measured

    /// One FLAT carve: the job, the design's regions, the flats and the parts of them the end mill can't reach, the
    /// V-bit's toolpath split into the corner cleaning in front and the carve after it, and the material simulated
    /// with the corner cleaning and without it (as the build before #204 cut it).
    struct Measured: Sendable {
        let project: Project
        let toolpaths: [Toolpath]
        let vBit: Tool
        let t: Double
        let rCap: Double
        let regions: [Region]
        let flats: [Region]
        let corners: [Region]
        /// Index of the V-bit's toolpath, and how many of its motions clean the corners.
        let vBitIndex: Int
        let cornerMotions: Int
        let after: HeightGrid
        let before: HeightGrid

        init(_ angle: Int) throws {
            let project = try VCarveCornerTests.saved(angle)
            let toolpaths = CAMEngine.generate(project).toolpaths
            let vBit = VCarveCornerTests.vBit(angle)
            let rCap = flatDepth * vBit.halfAngleTangent
            let loops = project.shapes.flatMap { $0.polylines(tolerance: 0.01) }.filter(\.isClosed)
            let regions = Region.build(from: loops, fill: .evenOdd)
            let flats = regions.flatMap { $0.offset(by: -rCap, arcTolerance: arcTolerance) }
            guard let i = toolpaths.firstIndex(where: { $0.tool.id == vBit.id }) else { throw NoVBitToolpath() }
            // The carve starts where the toolpath does (the start of its first path); the corners are cleaned before
            // the bit first comes back over it.
            let carving = toolpaths[i]
            let split = carving.motions.firstIndex { $0.end.xy.isApprox(carving.start.xy, tolerance: 1e-9) } ?? 0
            var without = toolpaths
            without[i].motions = Array(carving.motions[split...])
            (self.project, self.toolpaths, self.vBit, t, self.rCap) = (project, toolpaths, vBit, vBit.halfAngleTangent, rCap)
            (self.regions, self.flats) = (regions, flats)
            corners = VCarveGenerator.unreached(flats, by: endMill, arcTolerance: arcTolerance)
            (vBitIndex, cornerMotions) = (i, split)
            after = VCarveCornerTests.simulate(toolpaths, stock: project.stock)
            before = VCarveCornerTests.simulate(without, stock: project.stock)
        }

        /// The tallest the floor stands proud of the flat depth, mm, at cells inside the flats (and away from their
        /// edges by `margin`): over all the flats, and in each corner (nil for one with no cell inside), with how many
        /// cells were measured.
        func proud(_ grid: HeightGrid, margin: Double = 0.05) -> (flats: Double, corners: [Double?], cells: Int, cornerCells: Int) {
            let inner = flats.flatMap { $0.offset(by: -margin, arcTolerance: arcTolerance) }
            let bounds = inner.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
            var most = -Double.infinity, inCorners = [Double?](repeating: nil, count: corners.count), cells = 0, cornerCells = 0
            for r in 0..<grid.rows {
                let y = grid.origin.y + Double(r) * grid.cellSize
                guard y >= bounds.min.y, y <= bounds.max.y else { continue }
                for c in 0..<grid.columns {
                    let p = Vec2(grid.origin.x + Double(c) * grid.cellSize, y)
                    guard p.x >= bounds.min.x, p.x <= bounds.max.x, inner.contains(where: { $0.contains(p) }) else { continue }
                    let h = Double(grid.heights[grid.index(c, r)]) + flatDepth
                    cells += 1
                    most = max(most, h)
                    if let k = corners.firstIndex(where: { $0.bounds.insetBy(-1e-6).contains(p) && $0.contains(p) }) {
                        cornerCells += 1
                        inCorners[k] = max(inCorners[k] ?? -.infinity, h)
                    }
                }
            }
            return (most, inCorners, cells, cornerCells)
        }

        /// The corner of the flats at the F's top left, a square corner of the outline at (0.4", 2.95").
        var squareCorner: Int? {
            let p = Vec2(0.4.inch + rCap + 0.3, 2.95.inch - rCap - 0.3)
            return corners.firstIndex { $0.contains(p) }
        }
    }

    struct NoVBitToolpath: Error {}

    static let cell = 0.1

    /// The material left by `toolpaths`, one after the other, on a 0.1 mm grid.
    static func simulate(_ toolpaths: [Toolpath], stock: Stock) -> HeightGrid {
        var sim = MaterialSimulator(stock: stock, cellSize: cell)
        for tp in toolpaths {
            tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
        }
        return sim.grid
    }

    static let measured90: Result<Measured, any Error> = Result { try Measured(90) }
    static let measured60: Result<Measured, any Error> = Result { try Measured(60) }
    static func measured(_ angle: Int) throws -> Measured { try (angle == 90 ? measured90 : measured60).get() }

    /// The nub a flat end mill of radius `r` leaves in a corner of angle `corner` (degrees) for a V-bit whose half angle
    /// has tangent `t` to clean up: the V-bit's tip runs along the flat's edges, so the floor stands proud of the flat
    /// depth by the distance from the edges at the end mill's nearest point to the corner, over t.
    static func nub(endMillRadius r: Double, corner: Double, t: Double) -> Double {
        r * (1 - sin(corner.radians / 2)) / t
    }

    @Test(arguments: angles)
    func noFlatCornerStandsProudOfTheFloor(angle: Int) throws {
        let m = try Self.measured(angle)
        // Every letter has corners the end mill can't reach: the corners are cleaned before the carve, and every part
        // of the flats is measured, the corners included.
        #expect(m.corners.count >= 20, "\(m.corners.count) corners")
        #expect(m.cornerMotions > 0)
        let before = m.proud(m.before), after = m.proud(m.after)
        #expect(after.cells > 100_000 && after.cornerCells > 2_000, "\(after.cells) cells measured, \(after.cornerCells) in the corners")
        let tolerance = 2 * VCarveParams.flatClearingRidge + 0.02
        // Without the V-bit cleaning them (as before #204), every corner stood proud, a square one as tall as the issue
        // says (to within the grid), the A's sharper feet more.
        let square = Self.nub(endMillRadius: Self.endMill.radius, corner: 90, t: m.t)
        let f = try #require(m.squareCorner)
        let squareBefore = try #require(before.corners[f])
        // The nub's peak lies between cells, up to a cell's diagonal from the nearest, on a floor sloping at 1/t.
        let sampling = Self.cell * 2.squareRoot() / m.t
        #expect(squareBefore > square - sampling && squareBefore < square + 0.05,
                "before: the F's square corner stood \(squareBefore) mm proud, not \(square) mm")
        let measured = before.corners.compactMap { $0 }
        #expect(measured.count == m.corners.count, "\(m.corners.count - measured.count) corners not measured")
        #expect(measured.allSatisfy { $0 > tolerance }, "before: \(measured)")
        // Now no corner, and no part of the flats, stands taller than the V-bit's ridges between its rings (twice the
        // ridge in the middle of a flat).
        let worst = after.corners.compactMap { $0 }.max() ?? 0
        #expect(worst <= tolerance, "\(angle)° V-bit: a corner stands \(worst) mm proud of the floor")
        #expect(after.flats <= tolerance, "\(angle)° V-bit: the floor stands \(after.flats) mm proud somewhere")
        // And nothing is cut below the flat depth.
        #expect(Self.lowest(m.after) >= -Self.flatDepth - 1e-4, "the floor is cut to \(Self.lowest(m.after)) mm")
    }

    static func lowest(_ grid: HeightGrid) -> Double { Double(grid.heights.min() ?? 0) }

    /// Every point the bit's tip is fed through below the surface, a feed or arc's at most `step` apart, with its depth.
    static func cuttingPoints(_ tp: Toolpath, motions: Range<Int>? = nil, step: Double = 0.05) -> [Vec3] {
        var out: [Vec3] = []
        var at = tp.start
        for (i, m) in tp.motions.enumerated() {
            defer { at = m.end }
            guard motions?.contains(i) ?? true, m.kind == .feed || m.kind.isArc else { continue }
            var from = at
            for q in m.samples(from: at, maxStep: step) {
                let n = max(1, Int((from.distance(to: q) / step).rounded(.up)))
                for k in 0...n {
                    let p = from.lerp(to: q, Double(k) / Double(n))
                    if p.z < -1e-9 { out.append(p) }
                }
                from = q
            }
        }
        return out
    }

    /// How far the V-bit's cone may come past the walls, mm: the carve's own path is simplified to within 0.01 mm
    /// (`VCarveGenerator`'s `simplifyTol`) in any direction, and a point moved δ sideways and δ down comes δ·√(1 + t²)
    /// closer to the wall its cone has to stay inside.
    static func wallTolerance(t: Double) -> Double { 0.01 * (1 + t * t).squareRoot() + 0.001 }

    /// Distance from `p` to the nearest outline of the design.
    static func distance(_ p: Vec2, to regions: [Region]) -> Double {
        regions.flatMap(\.loops).map { $0.closestPoint(to: p).distance }.min() ?? .infinity
    }

    @Test(arguments: angles)
    func theCornerCleaningStaysInTheCornersAtTheFlatDepth(angle: Int) throws {
        let m = try Self.measured(angle)
        let carving = m.toolpaths[m.vBitIndex]
        let block = 0..<m.cornerMotions
        // No sideways rapid below the surface in the corner cleaning, or anywhere else in the job.
        let low = InlayTests.lowRapids(m.toolpaths)
        #expect(low.isEmpty, "\(low.count) sideways rapids below Z 0, first \(low.first ?? "")")
        // Every point the bit is fed through cleaning the corners: at the flat depth (or plunging to it), never below,
        // inside a corner the end mill can't reach, so inside the flats. A V-bit at the flat depth anywhere in a flat (rCap
        // or more in from the outline) has its cone inside the carve's own walls.
        let points = Self.cuttingPoints(carving, motions: block)
        #expect(points.count > 1000)
        var deepest = 0.0, belowFlat = 0, outsideCorners = 0, nearestOutline = Double.infinity
        for p in points {
            deepest = min(deepest, p.z)
            if p.z < -Self.flatDepth - 1e-6 { belowFlat += 1 }
            let inCorner = m.corners.contains { $0.contains(p.xy) }
                || m.corners.flatMap(\.loops).contains { $0.closestPoint(to: p.xy).distance < 1e-3 }
            if !inCorner { outsideCorners += 1 }
            nearestOutline = min(nearestOutline, Self.distance(p.xy, to: m.regions) - (-p.z) * m.t)
        }
        #expect(belowFlat == 0, "\(belowFlat) points below the flat depth; deepest \(deepest) mm")
        #expect(outsideCorners == 0, "\(outsideCorners) of \(points.count) points outside the corners")
        #expect(nearestOutline >= -1e-6, "the cone comes \(-nearestOutline) mm past the V-carve's walls")
    }

    @Test(arguments: angles)
    func nothingIsCutBeyondTheVCarvesWalls(angle: Int) throws {
        let m = try Self.measured(angle)
        // Each toolpath, move by move: the V-bit's cone stays inside the walls (rising from the outline at its angle) and
        // above the flat depth; the end mill stays in the flats at the flat depth.
        for (i, tp) in m.toolpaths.enumerated() {
            let vBit = i == m.vBitIndex
            var deepest = 0.0, worst = Double.infinity
            for p in Self.cuttingPoints(tp) {
                deepest = min(deepest, p.z)
                let room = Self.distance(p.xy, to: m.regions) - (vBit ? (-p.z) * m.t : m.rCap + tp.tool.radius)
                worst = min(worst, room)
            }
            #expect(deepest >= -Self.flatDepth - 1e-6, "\(tp.name) goes to \(deepest) mm")
            // The carve's own path is simplified (see `wallTolerance`); the flats are rounded at the outline's inside
            // corners to within Clipper's arc tolerance.
            #expect(worst >= -(vBit ? Self.wallTolerance(t: m.t) : Self.arcTolerance + 1e-3), "\(tp.name) cuts \(-worst) mm past the walls")
        }
        // The material the whole job leaves: nowhere deeper than the V-carve's own shape, the flat depth or the walls
        // rising from the outline, whichever is higher; untouched outside the design.
        let g = m.after
        var worst = 0.0, at = Vec2.zero
        for r in 0..<g.rows {
            for c in 0..<g.columns {
                let h = Double(g.heights[g.index(c, r)])
                guard h < -1e-4 else { continue }
                let p = Vec2(g.origin.x + Double(c) * g.cellSize, g.origin.y + Double(r) * g.cellSize)
                let inside = m.regions.contains { $0.contains(p) }
                let shape = inside ? -min(Self.flatDepth, Self.distance(p, to: m.regions) / m.t) : 0
                if h - shape < worst { (worst, at) = (h - shape, p) }
            }
        }
        #expect(worst >= -Self.wallTolerance(t: m.t) / m.t, "\(angle)° V-bit: cut \(-worst) mm deeper than the V-carve's shape at \(at)")
    }

    // MARK: Goldens

    /// The FLAT carves post for Mach4 in inches, as File ▸ Export G-code does: no warnings, nothing deeper than the flat
    /// depth, no sideways rapid below the surface, and the file passes the export checks.
    @Test(arguments: angles)
    func golden(angle: Int) throws {
        let p = try Self.saved(angle)
        let job = CAMEngine.generate(p)
        let warnings = job.issues.filter { $0.severity != .info }.map(\.message)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(job.toolpaths.map(\.tool.number) == [1, Self.vBit(angle).number])
        #expect(InlayTests.lowRapids(job.toolpaths).isEmpty)
        var deepest = 0.0
        for tp in job.toolpaths {
            tp.forEachMotion { _, m in deepest = min(deepest, m.end.z) }
        }
        #expect(deepest >= -Self.flatDepth - 1e-6, "\(deepest)")
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: "vcarve-corners-\(angle)-inch")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }
}
