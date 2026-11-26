import Foundation
import Testing
@testable import CAMCore

/// The CAM test catalog for #204: a V-carve with a flat depth and a clearance end mill has the V-bit clean the corners
/// and narrow places of the flat the end mill can't reach, as an inlay always did, so no nub stands proud of the floor.
/// Lettering ("LET", Helvetica Bold, 3" capitals, a 1/16" flat) with the starter 1/4" upcut end mill, once with the
/// 90° V-bit and once with the 60°, saved in `Fixtures/vcarve-corners` and posted on Avid's Mach4 default.
struct VCarveCornerCatalogTests {
    static let folder = GoldenPostTests.fixtures.appendingPathComponent("vcarve-corners")
    static let flat = 0.0625.inch

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "204C0000-0000-4000-8000-%012d", n))! }

    /// The lettered job with the starter V-bit `vBit` (5: 60°, 6: 90°) and the starter 1/4" upcut end mill.
    static func lettered(vBit number: Int) -> Project {
        let library = ToolLibrary.starter
        let stock = Stock(width: 8.inch, height: 4.5.inch, thickness: 0.75.inch, materialName: "Maple")
        let text = DesignShape(id: id(1), name: "LET", kind: .text(TextSpec(string: "LET", capHeight: 3.inch)),
                               position: Vec2(4.inch, 2.25.inch))
        let params = VCarveParams(flatDepth: flat, clearanceTool: library.tool(number: 1)!)
        let op = CAMOperation(id: id(2), name: "V-carve LET", kind: .vcarve(params), shapeIDs: [text.id],
                              tool: library.tool(number: number)!)
        return Project(name: "Lettered V-carve, \(number == 5 ? 60 : 90)° V-bit", displayUnits: .inch, stock: stock,
                       machine: .avidPRO6060, shapes: [text], operations: [op])
    }

    /// Loads a saved fixture. Update mode writes a missing one from `make`, but never replaces one.
    static func fixture(_ name: String, make: () -> Project) throws -> Project {
        let url = folder.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func ninety() throws -> Project { try fixture("lettered-90", make: { lettered(vBit: 6) }) }
    static func sixty() throws -> Project { try fixture("lettered-60", make: { lettered(vBit: 5) }) }

    // MARK: Goldens

    @Test func lettered90Golden() throws {
        try CutDirectionCatalogTests.checkGolden(Self.ninety(), "vcarve-corners-90-inch")
    }

    @Test func lettered60Golden() throws {
        try CutDirectionCatalogTests.checkGolden(Self.sixty(), "vcarve-corners-60-inch")
    }

    // MARK: The corners

    /// The design's regions, the flats (rCap in from the outline) and the corners the end mill leaves.
    static func geometry(_ p: Project) throws -> (regions: [Region], flats: [Region], corners: [Region], op: CAMOperation,
                                                   params: VCarveParams) {
        let op = try #require(p.operations.first)
        guard case let .vcarve(params) = op.kind, let clear = params.clearanceTool else { throw CornerError.notAVCarve }
        // The tolerances CAMEngine generates with.
        let ctx = GenerationContext(stock: p.stock, machine: p.machine, flattenTolerance: 0.01,
                                    arcTolerance: min(0.005, p.machine.arcFitTolerance / 2), units: p.displayUnits)
        let loops = p.shapes.flatMap { $0.polylines(tolerance: ctx.flattenTolerance) }.filter(\.isClosed)
        let regions = Region.build(from: loops, fill: .evenOdd)
        let rCap = op.tool.tipDiameter / 2 + flat * op.tool.halfAngleTangent
        let flats = regions.flatMap { $0.offset(by: -rCap, arcTolerance: ctx.arcTolerance) }
        let corners = VCarveGenerator.unreached(flats, by: clear, arcTolerance: ctx.arcTolerance)
        return (regions, flats, corners, op, params)
    }

    enum CornerError: Error { case notAVCarve }

    /// Every corner of the flat comes down to the floor: simulated at 0.1 mm, no cell in a corner the end mill can't
    /// reach stands more than the tolerance above the flat depth. The tolerance is the tallest ridge the V-bit's own
    /// clearing may leave (twice `flatClearingRidge` in the middle of a flat, #204 measured nubs of 0.93 mm at 90° and
    /// 1.6 mm at 60° without it) plus a cell's worth of slack.
    @Test(arguments: [90, 60])
    func noFlatCornerStandsProud(_ angle: Int) throws {
        let p = try angle == 90 ? Self.ninety() : Self.sixty()
        let g = try Self.geometry(p)
        #expect(!g.corners.isEmpty, "the end mill reaches the whole flat, so there's nothing to test")
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        #expect(job.toolpaths.count == 2)
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.1)
        for tp in job.toolpaths { tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) } }
        let grid = sim.grid
        let tolerance = 2 * VCarveParams.flatClearingRidge + 0.05
        let inset = g.corners.flatMap { $0.offset(by: -0.05, arcTolerance: 0.005) }
        var proud = 0.0, proudAt = Vec2.zero, cells = 0, lowest = 0.0, cutOutside = 0.0
        // A cell's centre just outside the outline can still be under the cone's edge, so allow a cell's diagonal.
        let grownRegions = g.regions.flatMap { $0.offset(by: 0.15, arcTolerance: 0.005) }
        let bounds = g.regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
        for row in 0..<grid.rows {
            for col in 0..<grid.columns {
                let q = Vec2(grid.origin.x + (Double(col) + 0.5) * grid.cellSize, grid.origin.y + (Double(row) + 0.5) * grid.cellSize)
                let h = Double(grid.heights[grid.index(col, row)])
                lowest = min(lowest, h)
                guard bounds.insetBy(-1).contains(q) else { continue }
                if inset.contains(where: { $0.contains(q) }) {
                    cells += 1
                    if h + Self.flat > proud { proud = h + Self.flat; proudAt = q }
                } else if !grownRegions.contains(where: { $0.contains(q) }) {
                    // Outside the letters the V-bit's cone never reaches (at the start depth 0, only the outline).
                    cutOutside = max(cutOutside, -h)
                }
            }
        }
        #expect(cells > 50, "only \(cells) cells in the corners")
        #expect(proud <= tolerance, "\(angle)°: a corner stands \(proud) mm proud of the floor at \(proudAt)")
        // Nothing below the floor anywhere, and nothing past the walls.
        #expect(lowest >= -Self.flat - 0.01, "\(angle)°: cut to \(lowest) mm, below the \(Self.flat) mm floor")
        #expect(cutOutside <= 0.01, "\(angle)°: cut \(cutOutside) mm deep outside the letters")
    }

    /// The V-bit's corner rings run at the flat depth and inside the flats, so its cone (rCap across there) stays inside
    /// the carve's walls: every V-bit feed at the floor is inside the flat (rCap in from the outline), and none is lower.
    @Test(arguments: [90, 60])
    func cornerPassesStayOnTheFloorAndInsideTheWalls(_ angle: Int) throws {
        let p = try angle == 90 ? Self.ninety() : Self.sixty()
        let g = try Self.geometry(p)
        let job = CAMEngine.generate(p)
        let vBit = try #require(job.toolpaths.last)
        #expect(vBit.tool.id == g.op.tool.id)
        var atFloor: [Vec2] = [], lowest = 0.0
        vBit.forEachMotion { _, m in
            let e = m.end
            lowest = min(lowest, e.z)
            if m.kind == .feed, abs(e.z + Self.flat) < 1e-4 { atFloor.append(e.xy) }
        }
        #expect(lowest >= -Self.flat - 1e-6, "\(angle)°: the V-bit goes to \(lowest) mm")
        // The carve's own path also reaches the floor along the flats' edges, so allow a little past them.
        let grown = g.flats.flatMap { $0.offset(by: 0.02, arcTolerance: 0.005) }
        let outside = atFloor.filter { q in !grown.contains { $0.contains(q) } }
        #expect(!atFloor.isEmpty)
        #expect(outside.isEmpty, "\(angle)°: \(outside.count) V-bit moves at the floor outside the flat, first \(outside.first.map { "\($0)" } ?? "")")
        // The corners are cleaned: some of the V-bit's floor moves are in them.
        #expect(atFloor.contains { q in g.corners.contains { $0.contains(q) } })
    }
}
