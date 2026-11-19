import Foundation

/// 3D roughing (layered area clearing) and 3D finishing (raster drop-cutter) for placed 3D models.
///
/// Both work from a top-surface height grid of the models (a z-buffer looking down), which is exact for 3-axis
/// machining: a vertical tool can only ever reach what is visible from above.
enum Model3DGenerator {

    // MARK: Shared setup

    struct Setup {
        let models: [DesignShape]
        /// Where the tool centre may go.
        let boundary: [Region]
        let surface: SurfaceGrid
        /// Lowest model bottom (design Z).
        let baseZ: Double
        let stock: Stock
    }

    static func setup(shapes: [DesignShape], boundary: ModelBoundary, tool: Tool, stock: Stock,
                      preferredCell: Double, warnings: inout [String]) -> Setup? {
        let models = shapes.filter { $0.modelSpec != nil }
        if models.isEmpty {
            warnings.append("3D toolpaths need a 3D model; none of the selected shapes is one.")
            return nil
        }
        if models.count < shapes.count {
            warnings.append("Only the 3D models in the selection are used; \(shapes.count - models.count) vector shape(s) were ignored.")
        }
        let outlineRegions = Region.build(from: models.flatMap { $0.polylines(tolerance: 0.05) }, fill: .nonZero)
        let regions: [Region] = boundary == .material ? [Region(outer: Polyline(
            [Vec2(0, 0), Vec2(stock.width, 0), Vec2(stock.width, stock.height), Vec2(0, stock.height)], closed: true))] : outlineRegions
        guard !regions.isEmpty else {
            warnings.append("The model has no outline from above; check its up axis.")
            return nil
        }
        let margin = tool.radius + preferredCell * 2
        let area = regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }.insetBy(-margin)
        let cell = ModelRaster.cellSize(for: area, preferred: preferredCell)
        let surface = ModelRaster.surface(of: models, over: area, cellSize: cell)
        let base = models.compactMap { $0.modelSpec?.bottomZ }.min() ?? 0
        if base < -stock.thickness - 1e-6 {
            warnings.append("The model is deeper than the material; the bottom of the model will be cut off.")
        }
        return Setup(models: models, boundary: regions, surface: surface, baseZ: base, stock: stock)
    }

    /// Lowest Z the tool may reach at each cell so `allowance` stays on the model.
    static func targets(_ s: Setup, boundary: ModelBoundary, allowance: Double) -> [Float] {
        let g = s.surface
        let a = Float(allowance)
        let outside: Float = boundary == .material ? Float(s.baseZ) + a : .infinity
        let stockRect = s.stock.bounds
        var t = [Float](repeating: .infinity, count: g.heights.count)
        for r in 0..<g.rows {
            for c in 0..<g.columns {
                let i = g.index(c, r)
                guard stockRect.contains(g.center(c, r)) else { t[i] = -.infinity; continue } // no material out here
                t[i] = g.covered[i] ? min(0, g.heights[i] + a) : outside
            }
        }
        return t
    }

    // MARK: 3D roughing

    static func rough(op: CAMOperation, params: Rough3DParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let cell = max(0.2, min(1.0, tool.diameter / 10))
        guard let s = setup(shapes: shapes, boundary: params.boundary, tool: tool, stock: context.stock,
                            preferredCell: cell, warnings: &warnings) else {
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        let g = s.surface
        let target = targets(s, boundary: params.boundary, allowance: params.allowance)
        let deepest = target.filter { $0.isFinite }.min().map(Double.init) ?? 0
        guard deepest < -1e-3 else {
            warnings.append("Nothing to rough: the model sits at the material surface.")
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        let step = max(0.05, params.passDepth ?? tool.cutting.stepdown)
        let n = max(1, Int((abs(deepest) / step - 1e-9).rounded(.up)))
        let levels = (1...n).map { deepest * Double($0) / Double(n) }
        let boundaryLoops = s.boundary.flatMap(\.loops)
        var previous = 0.0
        var clipped = Set<String>()
        for z in levels {
            // Cells where the target is at or below this level can be cleared to it.
            let zf = Float(z) + 1e-4
            let mask = target.map { $0 <= zf }
            let loops = GridContours.loops(mask: mask, columns: g.columns, rows: g.rows, origin: g.origin, cellSize: g.cellSize)
                .map { $0.simplified(tolerance: g.cellSize * 0.25) }
            let clearable = Clipper.intersection(loops, boundaryLoops, fill: .nonZero)
            let regions = Region.nest(clearable)
            if !regions.isEmpty {
                // The pocket engine keeps the tool radius inside each region, plus a margin covering grid sampling
                // (half a cell) and outline simplification (a quarter cell) so steep walls can't be nicked.
                let pp = PocketParams(strategy: .offset, direction: .climb,
                                      depth: DepthSettings(startDepth: -previous, cutDepth: -z, passDepth: abs(z - previous) + 1),
                                      allowance: g.cellSize * 1.0, stepoverFraction: params.stepoverFraction)
                let w = PocketGenerator.generate(regions: regions, tool: tool, params: pp, context: context, builder: &b)
                for m in w where !m.contains("too large") { clipped.insert(m) }
                b.retract()
            }
            previous = z
        }
        warnings.append(contentsOf: clipped.sorted())
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }

    // MARK: 3D finishing

    static func finish(op: CAMOperation, params: Finish3DParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let stepover = max(0.02, tool.diameter * params.stepoverFraction)
        let cell = max(0.08, min(0.5, min(stepover / 2, tool.radius / 6)))
        guard let s = setup(shapes: shapes, boundary: params.boundary, tool: tool, stock: context.stock,
                            preferredCell: cell, warnings: &warnings) else {
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        if tool.shape == .flatEndMill || tool.shape == .surfacing {
            warnings.append("A ball-nose bit gives a much smoother 3D finish than '\(tool.name)'.")
        }
        // Surface the tool must stay above: model + allowance; uncut material (0) outside the model in outline mode.
        var surface = targets(s, boundary: params.boundary, allowance: params.allowance)
        for i in surface.indices where surface[i] == .infinity { surface[i] = 0 }
        // Ball and flat cutters drop exactly onto the triangles; the grid then only carries the material around the model.
        var triangles: [Double] = []
        for m in s.models {
            m.forEachModelTriangle { a, b, c in triangles += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        }
        let exact = TriangleDropCutter(tool: tool, allowance: params.allowance, triangles: triangles)
        if exact != nil {
            for i in surface.indices where s.surface.covered[i] { surface[i] = -.infinity }
        }
        let grid = DropCutter(grid: s.surface, surface: surface, tool: tool)
        let dropper = CombinedDrop(exact: exact, grid: grid)
        let floor = s.baseZ + params.allowance

        // Raster lines across the boundary, clipped to it.
        let rot = Transform2D.rotation(-params.rasterAngle.radians)
        let unrot = Transform2D.rotation(params.rasterAngle.radians)
        let boundaryLoops = s.boundary.flatMap(\.loops)
        let rb = boundaryLoops.map { $0.transformed(rot) }.bounds
        var raw: [Polyline] = []
        var y = rb.min.y + stepover / 2
        while y < rb.max.y {
            raw.append(Polyline([unrot.apply(Vec2(rb.min.x - 1, y)), unrot.apply(Vec2(rb.max.x + 1, y))], closed: false))
            y += stepover
        }
        struct Segment { var row: Int; var along: Double; var a: Vec2; var b: Vec2 }
        var segments: [Segment] = []
        for seg in Clipper.clipOpen(raw, to: boundaryLoops, fill: .nonZero) {
            guard let p = seg.points.first, let q = seg.points.last else { continue }
            let pr = rot.apply(p), qr = rot.apply(q)
            let row = Int(((pr.y - rb.min.y - stepover / 2) / stepover).rounded())
            let (a, bb) = pr.x <= qr.x ? (p, q) : (q, p)
            segments.append(Segment(row: row, along: min(pr.x, qr.x), a: a, b: bb))
        }
        segments.sort { $0.row != $1.row ? $0.row < $1.row : $0.along < $1.along }
        if segments.isEmpty {
            warnings.append("No finishing passes fit inside the boundary.")
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }

        // Drop the tool along every segment, in parallel.
        let ds = max(s.surface.cellSize, 0.15)
        let tolerance = min(0.01, context.arcTolerance * 2)
        final class Box: @unchecked Sendable { var paths: [[Vec3]] = [] }
        let box = Box()
        box.paths = Array(repeating: [], count: segments.count)
        let segs = segments
        DispatchQueue.concurrentPerform(iterations: segs.count) { i in
            let sgm = segs[i]
            let len = sgm.a.distance(to: sgm.b)
            let n = max(1, Int((len / ds).rounded(.up)))
            var pts: [Vec3] = []
            pts.reserveCapacity(n + 1)
            for k in 0...n {
                let p = sgm.a.lerp(to: sgm.b, Double(k) / Double(n))
                pts.append(Vec3(p, max(floor, min(0, dropper.z(at: p)))))
            }
            box.paths[i] = simplify3D(pts, tolerance: tolerance)
        }

        // Zig-zag: alternate direction per row, link neighbours at depth when the hop is short.
        var lastRow = Int.min
        var forward = true
        for (i, sgm) in segments.enumerated() {
            if sgm.row != lastRow { forward = (sgm.row % 2 == 0); lastRow = sgm.row }
            let path = forward ? box.paths[i] : box.paths[i].reversed()
            guard let first = path.first else { continue }
            let hop = b.position.xy.distance(to: first.xy)
            if b.position.z < s.stock.plungeHeight && hop <= stepover * 3 && i > 0 {
                // Short hop: follow the surface (drop-cutter) so the link can't gouge.
                let n = max(1, Int((hop / ds).rounded(.up)))
                let from = b.position.xy
                for k in 1...n {
                    let p = from.lerp(to: first.xy, Double(k) / Double(n))
                    b.feed(Vec3(p, max(floor, min(0, dropper.z(at: p)))))
                }
            } else {
                b.enter(at: first)
            }
            b.follow(Array(path.dropFirst()))
        }
        b.retract()
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }
}

/// Exact triangle drop where available, combined with the height-grid drop for the surrounding material.
struct CombinedDrop: Sendable {
    let exact: TriangleDropCutter?
    let grid: DropCutter
    func z(at p: Vec2) -> Double { max(exact?.z(at: p) ?? -.infinity, grid.z(at: p)) }
}

/// Drop-cutter on a height grid: the lowest tool-tip Z at an XY position that doesn't cut into the surface.
struct DropCutter: Sendable {
    let grid: SurfaceGrid
    let surface: [Float]
    let radius: Double
    /// Tool profile height above the tip, sampled at `table.count` radii from 0 to `radius`.
    let table: [Float]

    init(grid: SurfaceGrid, surface: [Float], tool: Tool) {
        self.grid = grid
        self.surface = surface
        radius = tool.radius
        table = (0...512).map { Float(tool.profileHeight(atRadius: tool.radius * Double($0) / 512) ?? 0) }
    }

    func z(at p: Vec2) -> Double {
        let g = grid
        let cs = g.cellSize
        let c0 = max(0, Int(((p.x - radius - g.origin.x) / cs).rounded(.up)))
        let c1 = min(g.columns - 1, Int(((p.x + radius - g.origin.x) / cs).rounded(.down)))
        let r0 = max(0, Int(((p.y - radius - g.origin.y) / cs).rounded(.up)))
        let r1 = min(g.rows - 1, Int(((p.y + radius - g.origin.y) / cs).rounded(.down)))
        guard c0 <= c1, r0 <= r1 else { return -.infinity }
        let r2 = radius * radius
        let scale = Float(512 / max(radius, 1e-9))
        var best: Float = -.infinity
        surface.withUnsafeBufferPointer { s in
            table.withUnsafeBufferPointer { t in
                for r in r0...r1 {
                    let dy = g.origin.y + Double(r) * cs - p.y
                    let dy2 = dy * dy
                    if dy2 > r2 { continue }
                    let row = r * g.columns
                    for c in c0...c1 {
                        let h = s[row + c]
                        if h <= best { continue } // can't raise the tool
                        let dx = g.origin.x + Double(c) * cs - p.x
                        let d2 = dx * dx + dy2
                        if d2 > r2 { continue }
                        let x = Float(d2.squareRoot()) * scale
                        let k = min(511, Int(x))
                        let f = x - Float(k)
                        let prof = t[k] + (t[k + 1] - t[k]) * f
                        let v = h - prof
                        if v > best { best = v }
                    }
                }
            }
        }
        return Double(best)
    }
}
