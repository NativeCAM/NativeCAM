import Foundation
import Testing
import simd
@testable import CAMCore

/// Raster rows across a vertical wall (#52). Where the ball rolls off the wall's top edge its height jumps between
/// two samples, and the straight move between them clipped the edge (0.25 mm deep with a 1/4" ball); split at the
/// jump, the tool goes straight up or down at the foot of the wall instead.
struct WallEdgeGougeTests {
    static let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose
    /// A 20° ramp up to a 60° wall and a flat top, 55 mm long and 40 wide, ending in a 29 mm vertical wall.
    static let profile: [(x: Float, z: Float)] = {
        let t20 = Float(tan(20.0 * .pi / 180)), t60 = Float(tan(60.0 * .pi / 180))
        let z30 = 1 + 30 * t20, z40 = z30 + 10 * t60
        return [(0, 1), (30, z30), (40, z40), (55, z40)]
    }()
    static let height = Double(profile.last!.z)
    static let centre = Vec2(100, 75)

    @Test func rowsDontClipTheTopOfAVerticalWall() throws {
        var block = DesignShape(name: "Wall", kind: .model(ModelSpec(mesh: extrudedProfile(Self.profile, width: 40), depth: Self.height)),
                                position: Self.centre)
        block.id = UUID()
        let outline = DesignShape(kind: .rectangle(width: 75, height: 60, cornerRadius: 0), position: Self.centre)
        // Rows along X, straight over the 29 mm wall at x = 55.
        let op = CAMOperation(kind: .finish3D(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 0, boundary: .vectors)),
                              shapeIDs: [block.id, outline.id], tool: Self.ball)
        var project = Model3DFixture.project(block, ops: [op])
        project.shapes.append(outline)
        let tp = try #require(CAMEngine.generate(project).toolpaths.first)
        let sweep = BallSweep([tp], radius: Self.ball.radius)
        // Model x = 55 is design x = centre + 27.5; model y from design y = centre - 20.
        var worst = Double.infinity
        var at = SIMD3<Double>.zero
        for y in stride(from: 5.0, through: 35.0, by: 0.25) {
            let py = Self.centre.y + y - 20
            // Down the wall's face, and along the flat top up to its edge.
            for z in stride(from: 0.25, through: Self.height, by: 0.25) {
                let p = SIMD3(Self.centre.x + 27.5, py, z - Self.height)
                let r = sweep.residual(at: p)
                if r < worst { worst = r; at = p }
            }
            for x in stride(from: 54.0, through: 55.0, by: 0.05) {
                let p = SIMD3(Self.centre.x + x - 27.5, py, 0)
                let r = sweep.residual(at: p)
                if r < worst { worst = r; at = p }
            }
        }
        #expect(worst > -0.012, "cut \(-worst) mm into the wall at \(at)")
    }
}
