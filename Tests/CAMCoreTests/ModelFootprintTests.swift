import Foundation
import Testing
@testable import CAMCore

/// #185: an imported model's footprint. Its outline from above is traced from a grid of cells about 1/400 of the model
/// across, so its `bounds` can be up to a cell larger than the mesh (the 20 mm 3MF cube's read 20.05 mm). Its toolpaths
/// drop the cutter onto the mesh's own triangles, so they cut the model to its true size; the import report gives the
/// mesh's size (`modelBounds`).
struct ModelFootprintTests {
    static let endMill = ToolLibrary.starter.tool(number: 1)!   // 1/4" upcut, flat

    /// The 20 mm cube from `Fixtures/import/cli-cube.3mf`, centred on the import target's material, scale 1.
    static func cube() throws -> (project: Project, shape: DesignShape) {
        var p = try CLIImportTests.project("cli-import-target")
        let file = try p.importFile(at: CLIImportTests.file("cli-cube.3mf"))
        let id = try #require(file.shapeIDs.first)
        let shape = try #require(p.shape(id: id))
        #expect(shape.scale == 1)
        return (p, shape)
    }

    @Test func reportedFootprintIsTheMeshs() throws {
        let (_, shape) = try Self.cube()
        let mesh = try #require(shape.modelBounds)
        #expect(abs(mesh.width - 20) < 1e-4 && abs(mesh.height - 20) < 1e-4, "\(mesh)")
        #expect((mesh.center - shape.position).length < 1e-4)
        // The traced outline is the grid's: larger, by no more than a cell (20 mm / 400) and a half on each side.
        let traced = shape.bounds
        #expect(traced.width >= mesh.width - 1e-6 && traced.width <= mesh.width + 2 * 0.05 + 1e-6, "\(traced)")
        // What import reports for the file.
        var q = try CLIImportTests.project("cli-import-target")
        let file = try q.importFile(at: CLIImportTests.file("cli-cube.3mf"))
        #expect(abs(file.placedBounds.width - 20) < 1e-4, "\(file.placedBounds)")
    }

    /// The drop-cutter the 3D toolpaths use, on the model's triangles: a flat end mill stays on the cube's top until
    /// its edge passes the cube's, a bit radius past it, at 10 mm + r from the centre exactly (not 10.025 mm + r).
    @Test func dropCutterSeesTheMeshsSize() throws {
        let (_, shape) = try Self.cube()
        let cutter = try #require(TriangleDropCutter(tool: Self.endMill, allowance: 0, triangles: Model3DGenerator.triangles(of: [shape])))
        let c = shape.position, r = Self.endMill.radius
        let top = cutter.z(at: c)
        for direction in [Vec2(1, 0), Vec2(-1, 0), Vec2(0, 1), Vec2(0, -1)] {
            // Bisect for where the cutter leaves the top.
            var inside = 0.0, outside = 20.0
            for _ in 0..<60 {
                let mid = (inside + outside) / 2
                if cutter.z(at: c + direction * mid) > top - 1e-6 { inside = mid } else { outside = mid }
            }
            #expect(abs(inside - (10 + r)) < 1e-3, "\(direction): leaves the top \(inside) mm out, not \(10 + r)")
        }
    }

    /// A 3D finishing toolpath over the cube, raster along X: on the raster through its middle the end mill rides the
    /// top for the cube's width plus the bit's, 20 mm + 2r, not 20.05 mm + 2r.
    @Test func finishingToolpathCutsTheMeshsSize() throws {
        var (p, shape) = try Self.cube()
        let params = Finish3DParams(stepoverFraction: 0.1, rasterAngle: 0, boundary: .material)
        p.operations = [CAMOperation(name: "Finish cube", kind: .finish3D(params), shapeIDs: [shape.id], tool: Self.endMill)]
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        var top = -Double.infinity
        var points: [Vec3] = []
        tp.forEachMotion { s, m in
            guard m.kind == .feed else { return }
            points.append(s)
            points.append(m.end)
            top = max(top, m.end.z)
        }
        // The raster nearest the cube's middle, and the stretch of it on the top.
        let rows = Set(points.map { ($0.y * 1000).rounded() / 1000 })
        let row = try #require(rows.min { abs($0 - shape.position.y) < abs($1 - shape.position.y) })
        let onTop = points.filter { abs($0.y - row) < 1e-3 && $0.z > top - 1e-4 }
        let span = (onTop.map(\.x).max() ?? 0) - (onTop.map(\.x).min() ?? 0)
        let r = Self.endMill.radius
        #expect(abs(span - (20 + 2 * r)) < 0.01, "on the top for \(span) mm, not \(20 + 2 * r)")
    }
}
