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
        /// Boundary actually used (falls back to the model outline when "Selected vectors" has no vectors).
        let mode: ModelBoundary
        let surface: SurfaceGrid
        /// Cells inside the boundary (vectors/material modes): cut down to the model base where there's no model.
        let inside: [Bool]
        /// Lowest model bottom (design Z), raised to `floorHold` when that's higher.
        let baseZ: Double
        let stock: Stock
        /// The lowest design Z the toolpath may cut to anywhere, to keep a part on the tabs of its cut-out
        /// (`PartHold`); nil = no limit.
        var floorHold: Double? = nil
        /// Per cell, the top (design Z) of the strip left under a cut-out's tab there (`HoldingTabs`); nil without strips,
        /// -infinity on cells no strip covers.
        var stripTop: [Float]? = nil

        /// Raises `t` (a target or surface per cell, for `allowance`) to the strips' tops plus the allowance, so the strips
        /// stand under the cut-out's tabs. Cells off the material (-infinity, uncovered) stay as they are; covered cells
        /// finishing leaves to the exact cutter (-infinity) are raised too, so a strip over the model's edge keeps its top.
        func raiseStrips(_ t: inout [Float], allowance: Double) {
            guard let stripTop else { return }
            let a = Float(allowance)
            for i in t.indices where stripTop[i] > -.infinity && t[i] != .infinity && (t[i] > -.infinity || surface.covered[i]) {
                t[i] = max(t[i], min(0, stripTop[i] + a))
            }
        }
    }

    /// `reach` widens the "cut down to the base" area beyond where the tool centre may go: finishing passes the tool
    /// radius, because the band its flank touches was cleared by roughing (whose automatic margin is wider).
    static func setup(shapes: [DesignShape], boundary: ModelBoundary, margin: Double, reach: Double = 0, tool: Tool, stock: Stock,
                      preferredCell: Double, hold: Double? = nil, strips: [HoldingTabs.Strip] = [], warnings: inout [String]) -> Setup? {
        guard let (models, regions, mode) = boundaryRegions(shapes: shapes, boundary: boundary, margin: margin, stock: stock,
                                                            warnings: &warnings) else { return nil }
        let pad = tool.radius + preferredCell * 2
        let area = regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }.insetBy(-pad)
        let cell = ModelRaster.cellSize(for: area, preferred: preferredCell)
        let surface = ModelRaster.surface(of: models, over: area, cellSize: cell)
        let maskRegions = reach > 0 && mode == .vectors ? regions.flatMap { $0.offset(by: reach) } : regions
        let inside = mode == .model ? [Bool](repeating: false, count: surface.heights.count) : regionMask(maskRegions, surface)
        let base = models.compactMap { $0.modelSpec?.bottomZ }.min() ?? 0
        if base < -stock.thickness - 1e-6 {
            warnings.append("The model is deeper than the material; the bottom of the model will be cut off.")
        }
        var stripTop: [Float]?
        if !strips.isEmpty, mode == .vectors {
            var tops = [Float](repeating: -.infinity, count: surface.heights.count)
            for st in strips {
                let mask = regionMask([Region(outer: st.outline)], surface)
                for i in mask.indices where mask[i] { tops[i] = max(tops[i], Float(st.top)) }
            }
            stripTop = tops
        }
        return Setup(models: models, boundary: regions, mode: mode, surface: surface, inside: inside,
                     baseZ: hold.map { max(base, $0) } ?? base, stock: stock, floorHold: hold, stripTop: stripTop)
    }

    /// The models among `shapes` and where the tool centre may go over them (`Setup.boundary`), with the boundary
    /// actually used; nil (and a warning) when there's no model or it has no outline from above.
    static func boundaryRegions(shapes: [DesignShape], boundary: ModelBoundary, margin: Double, stock: Stock,
                                warnings: inout [String]) -> (models: [DesignShape], regions: [Region], mode: ModelBoundary)? {
        let models = shapes.filter { $0.modelSpec != nil }
        if models.isEmpty {
            warnings.append("3D toolpaths need a 3D model; none of the selected shapes is one.")
            return nil
        }
        let vectorShapes = shapes.filter { $0.modelSpec == nil }
        if boundary != .vectors && !vectorShapes.isEmpty {
            warnings.append("Only the 3D models in the selection are used; \(vectorShapes.count) vector shape(s) were ignored. Choose \"Selected vectors\" to use them as the machining boundary.")
        }
        let stockRegion = Region(outer: Polyline(
            [Vec2(0, 0), Vec2(stock.width, 0), Vec2(stock.width, stock.height), Vec2(0, stock.height)], closed: true))
        let outlineRegions = Region.build(from: models.flatMap { $0.polylines(tolerance: 0.05) }, fill: .nonZero)
        var mode = boundary
        var regions: [Region]
        switch boundary {
        case .model:
            regions = outlineRegions
        case .material:
            regions = [stockRegion]
        case .vectors:
            let loops = vectorShapes.flatMap { $0.polylines(tolerance: 0.05) }.filter(\.isClosed)
            let grown = Region.build(from: loops, fill: .evenOdd).flatMap { $0.offset(by: max(0, margin)) }
            regions = Region.nest(Clipper.intersection(grown.flatMap(\.loops), stockRegion.loops, fill: .nonZero))
            if regions.isEmpty {
                warnings.append("\"Selected vectors\" needs a closed vector (such as the cut-out outline) selected with the model; using the model outline instead.")
                regions = outlineRegions
                mode = .model
            }
        }
        guard !regions.isEmpty else {
            warnings.append("The model has no outline from above; check its up axis.")
            return nil
        }
        return (models, regions, mode)
    }

    /// The models' triangles in design coordinates, 9 doubles each, for `TriangleDropCutter`.
    static func triangles(of models: [DesignShape]) -> [Double] {
        var triangles: [Double] = []
        for m in models {
            m.forEachModelTriangle { a, b, c in
                func add(_ v: SIMD3<Double>) {
                    triangles.append(v.x)
                    triangles.append(v.y)
                    triangles.append(v.z)
                }
                add(a)
                add(b)
                add(c)
            }
        }
        return triangles
    }

    /// Scanline fill of regions (even-odd over their outer and hole loops) onto the grid's cell centres.
    static func regionMask(_ regions: [Region], _ g: SurfaceGrid) -> [Bool] {
        var mask = [Bool](repeating: false, count: g.heights.count)
        let edges = regions.flatMap(\.loops).flatMap { loop in (0..<loop.segmentCount).map { loop.segment($0) } }
        for r in 0..<g.rows {
            let y = g.origin.y + Double(r) * g.cellSize
            var xs: [Double] = []
            for (a, b) in edges where (a.y <= y) != (b.y <= y) {
                xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let c0 = max(0, Int(((xs[k] - g.origin.x) / g.cellSize).rounded(.up)))
                let c1 = min(g.columns - 1, Int(((xs[k + 1] - g.origin.x) / g.cellSize).rounded(.down)))
                if c0 <= c1 { for c in c0...c1 { mask[g.index(c, r)] = true } }
                k += 2
            }
        }
        return mask
    }

    /// Lowest Z the tool may reach at each cell so `allowance` stays on the model. Outside the boundary the
    /// material is treated as uncut (Z 0), so neither roughing nor a finishing ball reaches into it.
    static func targets(_ s: Setup, allowance: Double) -> [Float] {
        let g = s.surface
        let a = Float(allowance)
        let base = Float(s.baseZ) + a
        let stockRect = s.stock.bounds
        var t = [Float](repeating: .infinity, count: g.heights.count)
        for r in 0..<g.rows {
            for c in 0..<g.columns {
                let i = g.index(c, r)
                guard stockRect.contains(g.center(c, r)) else { t[i] = -.infinity; continue } // no material out here
                if g.covered[i] {
                    t[i] = min(0, g.heights[i] + a)
                    if let h = s.floorHold { t[i] = max(t[i], Float(h) + a) } // the allowance above the held floor, as `base`
                } else if s.mode == .model {
                    t[i] = .infinity
                } else {
                    t[i] = s.inside[i] ? base : 0
                }
            }
        }
        s.raiseStrips(&t, allowance: allowance)
        return t
    }

    // MARK: 3D roughing

    static func rough(op: CAMOperation, params: Rough3DParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let clearing = params.clearingInUse
        if clearing == .adaptive, context.stock.rotary != nil {
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: [
                "Adaptive 3D roughing isn't available on rotary jobs yet (its layers are worked out flat, not round the blank), "
                    + "so this toolpath isn't cut. Choose Offset or Raster clearing."])
        }
        let cell = max(0.2, min(1.0, tool.diameter / 10))
        guard let s = setup(shapes: shapes, boundary: params.boundary, margin: params.boundaryMargin ?? Rough3DParams.autoMargin(tool: tool),
                            tool: tool, stock: context.stock, preferredCell: cell, hold: context.floorHold, strips: context.holdingStrips, warnings: &warnings) else {
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        if tool.shape == .taperedBallNose {
            warnings.append("3D roughing is meant for an end mill: '\(tool.name)' is a tapered ball nose, which clears slowly with "
                + "its small tip and leaves ridges between its passes. Rough with an end mill and finish with the tapered ball nose.")
        }
        let g = s.surface
        let target = targets(s, allowance: params.allowance)
        let deepest = target.filter { $0.isFinite }.min().map(Double.init) ?? 0
        guard deepest < -1e-3 else {
            warnings.append("Nothing to rough: the model sits at the material surface.")
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        var clipped = Set<String>()
        var notes: [String] = []
        let layers = roughLayers(s, target: target, deepest: deepest, params: params, tool: tool)
        if clearing == .adaptive {
            var narrow: [Double]? = []
            for a in adaptiveSchedule(layers, setup: s, target: target, params: params, tool: tool, context: context) {
                let safe = a.boundary.flatMap { $0.offset(by: 0.01, arcTolerance: context.arcTolerance) }
                for m in AdaptiveClearing.cut(boundary: a.boundary, tool: tool, params: a.params, levels: [a.z], context: context,
                                              reliefs: [], safe: safe, cleared: a.seed, narrow: &narrow, builder: &b) {
                    clipped.insert(m)
                }
            }
            // A layer that's only a narrow band (round a relief's foot, say) has no room for the loops, so falling back
            // to the stepdown there is expected: noted, not warned about.
            for z in (narrow ?? []).sorted(by: >) {
                notes.append("The layer \(context.length(-z)) deep is a band too narrow for adaptive clearing's loops, so it was "
                    + "cleared normally, in passes of the tool's stepdown (\(context.length(tool.cutting.stepdown))).")
            }
        }
        for layer in layers where clearing != .adaptive && !layer.regions.isEmpty {
            let z = layer.z, previous = layer.above
            // The pocket engine keeps the tool radius inside each region, plus a margin covering grid sampling
            // (interpolated contours sit within three quarters of a cell of a steep wall, closer on slopes),
            // outline simplification (a quarter cell) and a quarter cell spare, so walls can't be nicked.
            let pp = PocketParams(strategy: clearing == .raster ? .raster : .offset, direction: params.wallDirection,
                                  depth: DepthSettings(startDepth: -previous, cutDepth: -z, passDepth: abs(z - previous) + 1),
                                  allowance: g.cellSize * 1.25, rasterAngle: params.rasterAngle ?? 0,
                                  stepoverFraction: params.stepoverFraction)
            // Roughing leaves an allowance, so its outermost rings may be rounded too (never outward).
            let w = PocketGenerator.generate(regions: layer.regions, tool: tool, params: pp, context: context,
                                             smoothBoundary: true, rasterPasses: clearing == .raster ? params.directionInUse : .both,
                                             builder: &b)
            for m in w where !m.contains("too large") { clipped.insert(m) }
            b.retract()
        }
        warnings.append(contentsOf: clipped.sorted())
        var tp = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        if clearing == .adaptive { tp.radialLoad = params.adaptiveSettings.load }
        if !notes.isEmpty { tp.notes = notes }
        return tp
    }

    /// One layer of 3D roughing.
    ///
    /// (Cut direction: offset rings, adaptive clearing and the pass round a raster layer's walls follow
    /// `Rough3DParams.wallDirection`; raster lines are cut one way or zig-zag, `PocketGenerator.cutRaster`.)
    struct RoughLayer {
        /// The layer's depth, and the one above it (0 for the first).
        var z: Double
        var above: Double
        /// The level the cells are compared at (a hair below `z`).
        var level: Float
        /// Cells whose target is at or below the layer: the tool may clear them to it.
        var mask: [Bool]
        /// Those cells' outline inside the boundary: where the layer is cleared, its walls the model at that depth.
        var regions: [Region]
    }

    /// The layers from the material top down to `deepest`, evenly spaced no more than the layer depth apart.
    static func roughLayers(_ s: Setup, target: [Float], deepest: Double, params: Rough3DParams, tool: Tool) -> [RoughLayer] {
        let g = s.surface
        let step = max(0.05, params.passDepth ?? tool.cutting.stepdown)
        let n = max(1, Int((abs(deepest) / step - 1e-9).rounded(.up)))
        let levels = (1...n).map { deepest * Double($0) / Double(n) }
        let boundaryLoops = s.boundary.flatMap(\.loops)
        // Only the model's own surface is worth interpolating; steps from boundaries and the base floor are not.
        let field = zip(target, g.covered).map { $1 ? $0 : Float.nan }
        var previous = 0.0
        var layers: [RoughLayer] = []
        for z in levels {
            // Cells where the target is at or below this level can be cleared to it.
            let zf = Float(z) + 1e-4
            let mask = target.map { $0 <= zf }
            // Sub-cell contours (smooth on slopes, no stair-steps for the controller to crawl through).
            let loops = GridContours.loops(mask: mask, columns: g.columns, rows: g.rows, origin: g.origin, cellSize: g.cellSize,
                                           field: field, level: zf, steepSlope: 2, interpolationLimit: 0.25)
                .map { $0.simplified(tolerance: g.cellSize * 0.25) }
            let clearable = Clipper.intersection(loops, boundaryLoops, fill: .nonZero)
            layers.append(RoughLayer(z: z, above: previous, level: zf, mask: mask, regions: Region.nest(clearable)))
            previous = z
        }
        return layers
    }

    /// What adaptive clearing walks at one level: the tool-centre boundary, the pocket settings and what's cleared already.
    struct AdaptiveLayer {
        var z: Double
        var boundary: [Region]
        var params: PocketParams
        var seed: [Polyline]
        /// A step-up: a layer between two clearing depths, where only the terraces the deeper clearing left are cut.
        var stepUp: Bool
    }

    /// Adaptive 3D roughing's levels, in cutting order. The layers are grouped by the clearing depth
    /// (`Rough3DParams.clearingDepthInUse`): each group's deepest layer is cleared first, from the group's top, its
    /// walk holding the load through the full depth; then each layer above it in the group, top down, clears only the
    /// terrace left between the model and the deeper clearing (a step-up), so the finish meets steps no taller than
    /// the layer depth. With the clearing depth no deeper than the layer depth, every layer is cleared in full.
    static func adaptiveSchedule(_ layers: [RoughLayer], setup s: Setup, target: [Float], params: Rough3DParams, tool: Tool,
                                 context: GenerationContext) -> [AdaptiveLayer] {
        guard let first = layers.first else { return [] }
        let tol = context.arcTolerance
        let g = s.surface
        // Adaptive clearing counts what earlier toolpaths cut at each layer as cleared already.
        let tops = materialTops(target, grid: g, context: context)
        func earlier(_ layer: RoughLayer) -> [Polyline] {
            tops.map { alreadyCleared(mask: layer.mask, tops: $0, level: layer.level, grid: g, arcTolerance: tol) } ?? []
        }
        let spacing = abs(first.z - first.above)
        let k = max(1, Int((params.clearingDepthInUse(tool) / max(spacing, 1e-9) + 1e-6).rounded(.down)))
        var out: [AdaptiveLayer] = []
        var start = 0
        while start < layers.count {
            let end = min(layers.count, start + k) - 1
            let top = layers[start].above
            if let bulk = adaptiveLayer(layers[end], above: top, seed: earlier(layers[end]), params: params, tool: tool,
                                        cell: g.cellSize, arcTolerance: tol) {
                out.append(bulk)
                // What the bulk clearing reached: its tool-centre area grown by the bit's radius, less a hair.
                let reach = bulk.boundary.flatMap { $0.offset(by: tool.radius - 0.02, arcTolerance: tol) }.flatMap(\.loops)
                for j in start..<end {
                    let seed = Clipper.union(reach + earlier(layers[j]), fill: .nonZero)
                    if var up = adaptiveLayer(layers[j], above: layers[j].above, seed: seed, params: params, tool: tool,
                                              cell: g.cellSize, arcTolerance: tol) {
                        up.stepUp = true
                        out.append(up)
                    }
                }
            } else {
                // The bit fits nowhere at the group's bottom: clear each layer above it in full.
                for j in start..<end {
                    if let a = adaptiveLayer(layers[j], above: layers[j].above, seed: earlier(layers[j]), params: params, tool: tool,
                                             cell: g.cellSize, arcTolerance: tol) {
                        out.append(a)
                    }
                }
            }
            start = end + 1
        }
        return out
    }

    /// One level of adaptive 3D roughing: the layer's regions cleared from `above` down to it by `AdaptiveClearing`,
    /// holding its load, then a pass round the walls. `seed` is what's already cleared at the layer. nil when the bit
    /// doesn't fit anywhere in the layer, or it's already clear.
    static func adaptiveLayer(_ layer: RoughLayer, above: Double, seed: [Polyline], params: Rough3DParams, tool: Tool, cell: Double,
                              arcTolerance tol: Double) -> AdaptiveLayer? {
        guard !layer.regions.isEmpty else { return nil }
        // The same margin offset roughing keeps for the grid's sampling (see `rough`).
        let allowance = cell * 1.25
        let boundary = layer.regions.flatMap { $0.offset(by: -(tool.radius + allowance), arcTolerance: tol) }
        guard !boundary.isEmpty else { return nil }
        if !seed.isEmpty {
            let reach = boundary.flatMap { $0.offset(by: tool.radius, arcTolerance: tol) }.flatMap(\.loops)
            let left = Region.nest(Clipper.difference(reach, minus: seed)).reduce(0) { $0 + $1.area }
            if left < 0.25 * tool.diameter * tool.diameter { return nil }
        }
        let pp = PocketParams(strategy: .adaptive, direction: params.wallDirection,
                              depth: DepthSettings(startDepth: -above, cutDepth: -layer.z, passDepth: abs(layer.z - above) + 1),
                              allowance: allowance, stepoverFraction: params.stepoverFraction, adaptive: params.adaptive)
        return AdaptiveLayer(z: layer.z, boundary: boundary, params: pp, seed: seed, stepUp: false)
    }

    /// The highest material earlier toolpaths left at each cell this toolpath could cut (+∞ elsewhere); nil when
    /// nothing is known about them.
    static func materialTops(_ target: [Float], grid g: SurfaceGrid, context: GenerationContext) -> [Float]? {
        guard let top = context.materialTop else { return nil }
        return (0..<target.count).map { i in
            guard target[i].isFinite, target[i] < 0 else { return .infinity }
            return Float(top(g.center(i % g.columns, i / g.columns), 0))
        }
    }

    /// The area earlier toolpaths cleared down to `level` inside the layer's `mask` (from `tops`, the highest material
    /// left at each cell), as Clipper polygons, shrunk by a cell so that nothing is counted as cleared that isn't.
    static func alreadyCleared(mask: [Bool], tops: [Float], level: Float, grid g: SurfaceGrid, arcTolerance: Double) -> [Polyline] {
        let gone = mask.indices.map { mask[$0] && tops[$0] <= level }
        guard gone.contains(true) else { return [] }
        let loops = GridContours.loops(mask: gone, columns: g.columns, rows: g.rows, origin: g.origin, cellSize: g.cellSize)
        return Region.build(from: loops, fill: .evenOdd).flatMap { $0.offset(by: -g.cellSize, arcTolerance: arcTolerance) }.flatMap(\.loops)
    }

    /// Adaptive 3D roughing's walk at each level it cuts, in order (for tests that measure its load).
    static func adaptivePlans(op: CAMOperation, params: Rough3DParams, shapes: [DesignShape],
                              context: GenerationContext) -> [(layer: AdaptiveLayer, plan: AdaptiveClearing.Plan)] {
        var warnings: [String] = []
        let tool = op.tool
        let cell = max(0.2, min(1.0, tool.diameter / 10))
        guard let s = setup(shapes: shapes, boundary: params.boundary, margin: params.boundaryMargin ?? Rough3DParams.autoMargin(tool: tool),
                            tool: tool, stock: context.stock, preferredCell: cell, hold: context.floorHold, strips: context.holdingStrips, warnings: &warnings) else { return [] }
        let target = targets(s, allowance: params.allowance)
        guard let deepest = target.filter({ $0.isFinite }).min().map(Double.init), deepest < -1e-3 else { return [] }
        let layers = roughLayers(s, target: target, deepest: deepest, params: params, tool: tool)
        return adaptiveSchedule(layers, setup: s, target: target, params: params, tool: tool, context: context).map { a in
            (a, AdaptiveClearing.plan(boundary: a.boundary, tool: tool, params: a.params, levels: [a.z], context: context, cleared: a.seed))
        }
    }

    // MARK: 3D finishing

    static func finish(op: CAMOperation, params: Finish3DParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        if params.strategy == .rest { return restFinish(op: op, params: params, shapes: shapes, context: context) }
        let tool = op.tool
        var warnings: [String] = []
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let stepover = params.stepoverInUse(tool: tool)
        let cell = max(0.08, min(0.5, min(stepover / 2, tool.radius / 6)))
        guard let s = setup(shapes: shapes, boundary: params.boundary, margin: params.boundaryMargin ?? Finish3DParams.autoMargin(tool: tool),
                            reach: tool.radius + cell, tool: tool, stock: context.stock, preferredCell: cell, hold: context.floorHold, strips: context.holdingStrips, warnings: &warnings) else {
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        if tool.shape == .flatEndMill || tool.shape == .surfacing {
            warnings.append("A ball-nose bit gives a much smoother 3D finish than '\(tool.name)'.")
        }
        if params.strategy.usesScallopTarget, params.scallopHeight != nil, tool.scallopRadius == nil {
            warnings.append("'\(tool.name)' has no rounded tip to hold a scallop height with, so the stepover sets the spacing.")
        }
        // Surface the tool must stay above: model + allowance; uncut material (0) outside the model in outline mode.
        var surface = targets(s, allowance: params.allowance)
        for i in surface.indices where surface[i] == .infinity { surface[i] = 0 }
        // The cutter drops exactly onto the triangles (every bit shape but a V with no angle); the grid then only
        // carries the material around the model.
        let exact = TriangleDropCutter(tool: tool, allowance: params.allowance, triangles: triangles(of: s.models))
        if exact != nil {
            for i in surface.indices where s.surface.covered[i] { surface[i] = -.infinity }
            // The strips under a cut-out's tabs stand over the model's edge too: the grid carries them there.
            s.raiseStrips(&surface, allowance: params.allowance)
        }
        let grid = DropCutter(grid: s.surface, surface: surface, tool: tool)
        let dropper = CombinedDrop(exact: exact, grid: grid)
        let floor = s.baseZ + params.allowance
        let f = Finishing(setup: s, tool: tool, params: params, dropper: dropper, floor: floor, stepover: stepover, cell: cell,
                          ds: max(s.surface.cellSize, 0.15), tolerance: min(0.01, context.arcTolerance * 2), context: context)
        let boundaryLoops = s.boundary.flatMap(\.loops)
        switch params.strategy {
        case .raster:
            if !raster(over: boundaryLoops, f, &b) {
                warnings.append("No finishing passes fit inside the boundary.")
                return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
            }
        case .waterline:
            let map = f.buildMap()
            let pieces = waterPieces(map, levels: waterlineLevels(map, step: params.waterlineStep(tool: tool)), area: boundaryLoops, f)
            if pieces.isEmpty { warnings.append("No waterline passes fit inside the boundary.") }
            cutWaterline(pieces, map, f, &b)
        case .steepShallow:
            let map = f.buildMap()
            let steep = steepAreas(map, angle: params.steepAngleInUse)
            let overlap = params.overlapInUse(tool: tool)
            func grown(_ loops: [Polyline]) -> [Polyline] { overlap > 1e-6 ? Clipper.offset(loops, delta: overlap) : loops }
            if !steep.isEmpty {
                let steepArea = Clipper.intersection(grown(steep), boundaryLoops, fill: .nonZero)
                cutWaterline(waterPieces(map, levels: waterlineLevels(map, step: params.waterlineStep(tool: tool)), area: steepArea, f),
                             map, f, &b)
            }
            let shallow = steep.isEmpty ? boundaryLoops
                : Clipper.intersection(grown(Clipper.difference(boundaryLoops, minus: steep, fill: .nonZero)), boundaryLoops, fill: .nonZero)
            if !shallow.isEmpty { _ = raster(over: shallow, f, &b) }
            if b.motions.isEmpty { warnings.append("No finishing passes fit inside the boundary.") }
        case .pencil:
            guard tool.shape == .ballNose || tool.shape == .taperedBallNose else {
                warnings.append("Pencil cleanup needs a ball-nose bit; '\(tool.name)' isn't one.")
                return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
            }
            pencil(f.buildMap(), f, &b, warnings: &warnings)
        case .constantScallop, .spiral, .radial:
            if !pattern(f, &b, warnings: &warnings) {
                warnings.append("No finishing passes fit inside the boundary.")
                return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
            }
        case .rest:
            break // `restFinish`
        }
        b.retract()
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }
}

extension Model3DGenerator {
    /// Splits each move of a dropped path whose middle is more than `tolerance` below the surface `z` (it would cut into
    /// the model), or which is steep (more than 3 in 1) with its middle that far off the surface either way, and its
    /// halves in turn, until none is or they're under 2 µm long. Samples a fixed distance apart can straddle the place
    /// where the tool rolls over a wall's top edge and drops to the floor (its height jumps there), and the straight
    /// move between them would clip the edge; split, the tool goes straight up or down at the foot of the step
    /// instead. A gentle move bridging a hollow is left alone: it leaves material rather than cutting any. `low` keeps
    /// the surface from going below a height (a link that mustn't dip).
    static func refineDrops(_ pts: [Vec3], tolerance: Double, above low: Double = -.infinity, hint: inout Int32,
                            z: (Vec2, inout Int32) -> Double) -> [Vec3] {
        guard pts.count >= 2 else { return pts }
        var out: [Vec3] = [pts[0]]
        out.reserveCapacity(pts.count)
        func split(_ a: Vec3, _ b: Vec3, depth: Int, hint: inout Int32) {
            if depth > 0, a.xy.distanceSquared(to: b.xy) > 4e-6 {
                let m = a.xy.lerp(to: b.xy, 0.5)
                let zm = max(low, z(m, &hint))
                let off = zm - (a.z + b.z) / 2
                let steep = abs(b.z - a.z) > 3 * a.xy.distance(to: b.xy)
                if off > tolerance || (steep && -off > tolerance) {
                    let mid = Vec3(m, zm)
                    split(a, mid, depth: depth - 1, hint: &hint)
                    split(mid, b, depth: depth - 1, hint: &hint)
                    return
                }
            }
            out.append(b)
        }
        for i in 1..<pts.count { split(pts[i - 1], pts[i], depth: 16, hint: &hint) }
        return out
    }
}

/// Exact triangle drop where available, combined with the height-grid drop for the surrounding material.
struct CombinedDrop: Sendable {
    let exact: TriangleDropCutter?
    let grid: DropCutter
    func z(at p: Vec2) -> Double { max(exact?.z(at: p) ?? -.infinity, grid.z(at: p)) }
    /// `z(at:)` testing the exact cutter's `hint` triangle first (see `TriangleDropCutter.z(at:hint:)`).
    func z(at p: Vec2, hint: inout Int32) -> Double { max(exact?.z(at: p, hint: &hint) ?? -.infinity, grid.z(at: p)) }
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
