import Foundation
import Testing
@testable import CAMCore

/// A flat end mill leaving an allowance keeps it square to the model's surface: beside a vertical shoulder as well as
/// above it. Dropped with the flat test, the allowance only raised the tool, so its side came right up to the
/// shoulder's face; the drop-cutters now drop it grown by the allowance all round (a bull nose the allowance wider).
struct FlatAllowanceTests {
    static let endMill = ToolLibrary.starter.tool(number: 1)! // 1/4" flat
    static let allowance = 0.5

    /// A ball as small as can be, grown by `allowance`: dropped on the model, its tip is the model grown by the
    /// allowance as the tool sees it.
    static var point: Tool {
        var t = ToolLibrary.starter.tool(number: 7)!
        t.diameter = 0.002
        return t
    }

    /// 3D rotary finishing a turned part with a shoulder: 8 mm from the axis for 40 mm, then 16 mm for 40 mm, from a
    /// 36 mm round blank. Simulated, the finish (and the layers down to it) never cuts within the allowance of the
    /// shoulder's face or anywhere else on the part, and still finishes the small diameter to the allowance up to a
    /// stepover from that. (The spiral passes each angle once a turn, so the last turn before the tool has to climb onto
    /// the shoulder can be up to a stepover short of it, as it always could.)
    @Test func aRotaryFinishKeepsItsAllowanceBesideAShoulder() throws {
        let a = Self.allowance
        let mesh = MeshModel.revolved(name: "Shoulder", profile: [(0, 8), (40, 8), (40, 16), (80, 16)], segments: 256)
        let params = RotaryFinishParams(allowance: a)
        let p = Rotary3DTests.job(mesh: mesh, blank: RotaryStock(diameter: 36, length: 120), params: params, tool: Self.endMill)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let finish = try #require(job.toolpaths.first)
        var s = SimulationSession(toolpaths: [finish], stock: p.stock, rapidRate: 5000, cellSize: 0.25)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        let g = try #require(s.radialGrid)
        let blank = try #require(p.stock.rotary)
        // The part runs from 20 to 100 along the blank, with its shoulder at 60.
        var tri: [Double] = []
        for m in p.shapes where m.modelSpec != nil {
            m.forEachBlankTriangle { a, b, c in tri += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        }
        let grown = try #require(RotaryDropCutter(tool: Self.point, allowance: a, triangles: tri))
        var gouge = 0.0, gougeAt = ""
        var left = 0.0, leftAt = ""
        for c in 0..<g.columns {
            let x = g.originX + Double(c) * g.cellSize
            for j in 0..<g.rows {
                let angle = g.angle(row: j)
                let r = Double(g.radii[j * g.columns + c])
                let limit = grown.tipRadius(x: x, angle: angle) + 0.001
                guard limit.isFinite else { continue }
                let inside = min(blank.radius, limit) - r
                if inside > gouge {
                    gouge = inside
                    gougeAt = "x \(x) angle \(angle): \(r) under \(limit)"
                }
                // The small diameter, from a tool radius past its end up to a stepover short of the allowance from
                // the shoulder.
                guard x > 24, x < 60 - a - params.stepover(Self.endMill) - 0.25 else { continue }
                if r - (8 + a) > left {
                    left = r - (8 + a)
                    leftAt = "x \(x) angle \(angle): \(r)"
                }
            }
        }
        #expect(gouge < 0.02, "cuts \(gouge) inside the part with its allowance at \(gougeAt)")
        #expect(left < 0.05, "leaves \(left) more than the allowance at \(leftAt)")
    }

    /// 3-axis 3D finishing (raster rows straight across it) a block with a 10 mm vertical shoulder across its middle.
    /// Simulated, the finish never cuts within the allowance of the shoulder's face or anywhere else on the block, and
    /// still finishes the low side right up to the allowance from the shoulder.
    @Test func aThreeAxisFinishKeepsItsAllowanceBesideAShoulder() throws {
        let a = Self.allowance
        // 60 long in X and 40 wide: 4 high for 30, then 14 high. Placed at (100, 75), so its top is Z 0, the low side
        // Z −10 and the shoulder at X 100.
        var block = DesignShape(name: "Shoulder", kind: .model(ModelSpec(mesh: extrudedProfile([(0, 4), (30, 4), (30, 14), (60, 14)], width: 40),
                                                                       depth: 14)),
                                position: Model3DFixture.center)
        block.id = UUID()
        let op = CAMOperation(kind: .finish3D(Finish3DParams(stepoverFraction: 0.2, rasterAngle: 0, allowance: a)),
                              shapeIDs: [block.id], tool: Self.endMill)
        let p = Model3DFixture.project(block, ops: [op])
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(!tp.isEmpty)
        var s = SimulationSession(toolpaths: [tp], stock: p.stock, rapidRate: 10000, cellSize: 0.25)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        let g = s.grid
        var tri: [Double] = []
        block.forEachModelTriangle { a, b, c in tri += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        let grown = try #require(TriangleDropCutter(tool: Self.point, allowance: a, triangles: tri))
        var gouge = 0.0, gougeAt = Vec2.zero
        var left = 0.0, leftAt = Vec2.zero
        for r in 0..<g.rows {
            for c in 0..<g.columns {
                let q = Vec2(g.origin.x + Double(c) * g.cellSize, g.origin.y + Double(r) * g.cellSize)
                // Inside the block's outline, where the tool's centre may go.
                guard q.x > 70, q.x < 130, q.y > 55, q.y < 95 else { continue }
                let h = Double(g.heights[g.index(c, r)])
                let limit = grown.z(at: q) + 0.001
                guard limit.isFinite else { continue }
                // The allowance can't reach above the material top.
                if min(0, limit) - h > gouge {
                    gouge = min(0, limit) - h
                    gougeAt = q
                }
                // The low side, a tool radius in from the block's sides and end, up to the allowance from the shoulder.
                guard q.x > 74, q.x < 100 - a - 0.25, q.y > 59, q.y < 91 else { continue }
                if h - (-10 + a) > left {
                    left = h - (-10 + a)
                    leftAt = q
                }
            }
        }
        #expect(gouge < 0.02, "cuts \(gouge) inside the block with its allowance at \(gougeAt)")
        #expect(left < 0.05, "leaves \(left) more than the allowance at \(leftAt)")
    }
}
