import Foundation

/// V-carving by maximal inscribed circles.
///
/// For each sample point p on the outline with inward normal n, the largest circle inside the shape that
/// touches the outline at p has centre c = p + r·n. A V-bit whose cone meets the surface at radius r has its
/// tip at depth (r − tipRadius) / tan(halfAngle), so driving the tip along c(p) at that depth carves walls that
/// meet the outline exactly at the surface and rise to sharp corners. Each outline loop yields one path that runs
/// along the shape's medial axis. Depth is capped by the bit's taper height and the optional flat depth.
///
/// A start depth S carves as if the material top were S lower: the circles are inscribed at depth S, the tip runs
/// S deeper, and the flat depth and pass depths count down from S. Above S the cone still cuts, S·tan(halfAngle)
/// past the outline at the surface (inside an existing pocket that's air). An inlay plug carves the area around its
/// design instead, mirrored (see `plugRegions` and `VCarveInlay`).
///
/// Cut direction (`VCarveParams.directionInUse`): each carve path runs with the outline it traces on the tool's right
/// (outer loops counter-clockwise, holes clockwise), climbing; going conventional, each runs the other way. The flats'
/// rings and edge passes go the same way, and raster lines are cut one way (`PocketGenerator.cutRaster`) or zig-zag.
enum VCarveGenerator {
    /// Tallest ridge the V-bit may leave between its passes when it clears a flat bottom itself, mm. In the middle of
    /// a flat, past its last ring, a ridge can be up to twice this (plus tipRadius / tan(halfAngle)).
    static let flatClearingRidge = VCarveParams.flatClearingRidge
    /// The same for an inlay pocket, whose floor has to stay below the plug's face (the glue gap).
    static let inlayPocketRidge = VCarveParams.inlayPocketRidge

    static func generate(op: CAMOperation, params: VCarveParams, clearanceTool: Tool?, shapes: [DesignShape],
                         context: GenerationContext) -> [Toolpath] {
        let tool = op.tool
        var warnings: [String] = []
        if !tool.shape.isTapered {
            warnings.append("V-carving needs a V-bit or engraving bit; '\(tool.name)' is a \(tool.shape.label).")
        }
        let t = tool.shape.isTapered ? tool.halfAngleTangent : 1
        let tip = tool.shape.isTapered ? tool.tipDiameter / 2 : 0
        let maxDepthByTool = tool.shape.isTapered ? min(tool.taperHeight, tool.fluteLength) : tool.fluteLength
        let start = params.carveStartDepth
        let flatDepth = params.carveFlatDepth
        // Below the start depth the bit reaches only as far as its cone is tall (measured from the material top).
        let reach = maxDepthByTool - start
        if reach <= 1e-6 {
            warnings.append("The start depth is deeper than the bit's cutting length, so it can't carve from there.")
            let b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
            return [b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)]
        }
        let depthCap = min(flatDepth ?? .infinity, reach)
        let rCap = tip + depthCap * t
        let spacing = max(0.05, params.sampleSpacing)
        let direction = params.directionInUse
        let walls: CutDirection = direction == .conventional ? .conventional : .climb

        let regions: [Region]
        if let inlay = params.inlay, inlay.role == .plug {
            // A whole-board plug's carving reaches rCap past the board, so its floor runs right out to the edges.
            let plug = plugRegions(inlay, shapes: shapes, stock: context.stock, edge: rCap.isFinite ? rCap : 0,
                                   tolerance: context.flattenTolerance, arcTolerance: context.arcTolerance)
            regions = plug.regions
            if inlay.boundary == .vector && !plug.boundaryFound {
                warnings.append("None of the selected vectors goes round the rest, so the plug is carved to the boundary margin "
                    + "instead. Select a closed vector round the design with it.")
            }
            if let board = plug.board?.insetBy(-1e-6), !plug.design.isEmpty,
               !(board.contains(plug.design.min) && board.contains(plug.design.max)) {
                let u = context.units
                let size = plug.board ?? board
                warnings.append("The design runs off the plug board (\(u.format(size.width)) × \(u.format(size.height)) \(u.symbol)), "
                    + "so the plug isn't whole. Use a larger board, or move the design onto it.")
            }
            if regions.isEmpty { warnings.append("A plug needs a closed design; none was selected.") }
        } else {
            let loops = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }.filter { $0.isClosed }
            regions = Region.build(from: loops, fill: .evenOdd)
            if regions.isEmpty { warnings.append("V-carving needs closed shapes; none were selected.") }
        }

        // Pass levels for deep carves (depth limit per pass below the material top, counted down from the start
        // depth; the last pass is unlimited).
        var passLimits: [Double] = []
        if let pd = params.passDepth, pd > 0, depthCap.isFinite {
            var d = pd
            while d < depthCap - 1e-6 { passLimits.append(start + d); d += pd }
        }
        passLimits.append(.infinity)

        var paths: [[Vec3]] = []
        for region in regions {
            let segs = region.loops.flatMap { loop in (0..<loop.segmentCount).map { loop.segment($0) } }
            let grid = SegmentGrid(segments: segs, cell: max(rCap * 2, spacing * 4, 0.5))
            for loop in region.loops {
                var pts = carvePath(loop: loop, segments: segs, grid: grid, spacing: spacing, rCap: rCap, tip: tip, t: t)
                if start > 0 { pts = pts.map { Vec3($0.x, $0.y, $0.z - start) } }
                if walls == .conventional { pts.reverse() }
                if pts.count > 1 { paths.append(pts) }
            }
        }

        var toolpaths: [Toolpath] = []
        // The flat bottom: where the V reaches the flat depth, beyond rCap from the outline (at the start depth).
        let flatRegions = (flatDepth ?? 0) > 0 ? regions.flatMap { $0.offset(by: -rCap, arcTolerance: context.arcTolerance) } : []
        // Optional flat-area clearing with a second tool, cut before the V-bit.
        if let flat = flatDepth, let clear = clearanceTool, flat > 0, !flatRegions.isEmpty {
            var cb = ToolpathBuilder(stock: context.stock, tool: clear, startXY: nil)
            var depth = DepthSettings(cutDepth: start + flat)
            // Carving inside an earlier pocket: skip the depths it already cleared over the flat area.
            if start > 0, let cleared = clearedDepth(over: flatRegions, radius: clear.radius, context: context),
               cleared > 0.05, cleared < depth.cutDepth - 0.05 {
                depth.startDepth = cleared
            }
            let pp = PocketParams(strategy: .offset, direction: walls, depth: depth)
            let w = PocketGenerator.generate(regions: flatRegions, tool: clear, params: pp, context: context, builder: &cb)
            cb.retract()
            var tp = cb.build(id: UUID(), name: "\(op.name) – flat clearing", tool: clear, rpm: clear.cutting.spindleRPM,
                              warnings: w)
            tp.id = deterministicID(op.id, salt: 1)
            toolpaths.append(tp)
        }

        let ordered = TourOptimizer.order(count: paths.count, from: context.stock.homePosition.xy,
                                          start: { paths[$0][0].xy }, end: { paths[$0][paths[$0].count - 1].xy }).map { paths[$0] }
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: ordered.first?.first?.xy)
        // The flat bottom the V-bit clears itself: all of it without a clearance tool (as Vectric does), and with one, the
        // corners and narrow places the clearance tool can't reach, so nothing stands proud of the floor (#204).
        if let flat = flatDepth, flat > 0, tool.shape.isTapered, !flatRegions.isEmpty {
            let rest = vBitFlatAreas(flatRegions, clearanceTool: clearanceTool, arcTolerance: context.arcTolerance)
            if !rest.isEmpty {
                // Raster lines only where the V-bit clears the whole flat; the corners a clearance tool leaves are slivers.
                if clearanceTool == nil, let raster = params.flatRaster {
                    let stepover = params.vBitRasterStepover(tool)
                    let ridge = VCarveParams.vBitRidge(tool, spacing: stepover), limit = params.vBitRasterRidge
                    if ridge > limit + 1e-6 {
                        let u = context.units
                        warnings.append("The raster's stepover of \(u.format(stepover)) \(u.symbol) leaves ridges up to "
                            + "\(u.format(ridge)) \(u.symbol) tall between its lines, above the \(u.format(limit)) \(u.symbol) the "
                            + "automatic stepover (\(u.format(params.vBitRasterSpacing(tool))) \(u.symbol)) keeps to.")
                    }
                    clearFlatRaster(rest, tool: tool, start: start, flat: flat, passDepth: params.passDepth, stepover: stepover,
                                    angle: raster.angle, direction: direction, context: context, builder: &b)
                } else {
                    clearFlat(rest, tool: tool, start: start, flat: flat, passDepth: params.passDepth,
                              spacing: params.vBitClearingSpacing(tool), direction: walls, context: context, builder: &b)
                }
            }
        }
        let simplifyTol = min(0.01, context.arcTolerance * 2)
        for limit in passLimits {
            for path in ordered {
                let limited = path.map { Vec3($0.x, $0.y, max($0.z, -limit)) }
                let simplified = simplify3D(limited, tolerance: simplifyTol)
                b.enter(at: simplified[0])
                b.follow(Array(simplified.dropFirst()))
                b.retract()
            }
        }
        toolpaths.append(b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings))
        return toolpaths
    }

    /// Clears `regions` (beyond the carve's flat-depth line) at the flat depth with the V-bit itself: offset rings
    /// `spacing` apart, close enough at `VCarveParams.vBitClearingSpacing` that the cones of neighbouring rings, and of
    /// the carve's own path along the edge, leave ridges no taller than the limit. The first ring is half a spacing in,
    /// so even a sliver of flat gets one.
    static func clearFlat(_ regions: [Region], tool: Tool, start: Double, flat: Double, passDepth: Double?, spacing: Double,
                          direction: CutDirection = .climb, context: GenerationContext, builder b: inout ToolpathBuilder) {
        // PocketGenerator sees a "tool" whose radius is the ring spacing and keeps its centre that far in, less the
        // negative allowance; the real bit's feeds come from the builder.
        var footprint = tool
        footprint.diameter = 2 * spacing
        footprint.cutting.stepoverFraction = 0.5
        let depth = DepthSettings(startDepth: start, cutDepth: start + flat, passDepth: passDepth ?? flat)
        let pp = PocketParams(strategy: .offset, direction: direction, depth: depth, allowance: -spacing / 2, stepoverFraction: 0.5)
        // Its warnings don't apply: a flat too narrow for a ring is already covered by the carve's own path.
        _ = PocketGenerator.generate(regions: regions, tool: footprint, params: pp, context: context, builder: &b)
        b.retract()
    }

    /// Clears `regions` as `clearFlat` does, in raster lines `stepover` apart at `angle` (degrees), then a pass round
    /// each flat's edge. Like the first ring, the edge pass (and the ends of the lines) is half a stepover in, so the
    /// cones never reach the V walls. Each flat is cleared on its own, all its depths, nearest first; its lines go in
    /// zig-zag runs up (or down) the flat, linked at depth inside it, so a design's separate flats, or the two sides of an
    /// island, don't each cost a retract on every line. Climbing or conventional, the lines are cut one way instead
    /// (`PocketGenerator.cutRaster`), and the edge pass goes the same way.
    static func clearFlatRaster(_ regions: [Region], tool: Tool, start: Double, flat: Double, passDepth: Double?, stepover: Double,
                                angle: Double, direction: PassDirection = .both, context: GenerationContext,
                                builder b: inout ToolpathBuilder) {
        let s = max(0.02, stepover)
        let depth = DepthSettings(startDepth: start, cutDepth: start + flat, passDepth: passDepth ?? flat)
        let levels = depth.passLevels(toolStepdown: passDepth ?? flat, firstPassMinimum: tool.firstPassMinimum)
        let pp = PocketParams(strategy: .raster, direction: direction == .conventional ? .conventional : .climb, depth: depth,
                              rasterAngle: angle)
        // Where the bit's centre goes: half a stepover in from the flat's edge (a flat too narrow for that is already
        // covered by the carve's own path).
        var areas = regions.flatMap { $0.offset(by: -s / 2, arcTolerance: context.arcTolerance) }
        while !areas.isEmpty {
            let here = b.position.xy
            let i = areas.indices.min { areas[$0].outer.closestPoint(to: here).distance < areas[$1].outer.closestPoint(to: here).distance }!
            let area = areas.remove(at: i)
            let safe = area.offset(by: 0.01, arcTolerance: context.arcTolerance)
            let lines = PocketGenerator.rasterLines([area], stepover: s, angle: angle)
            var zAbove = -start
            for z in levels {
                var first = true
                if direction == .both {
                    rasterRuns(lines, z: z, safe: safe, first: &first, builder: &b)
                } else {
                    PocketGenerator.cutRaster(lines, z: z, zAbove: zAbove, stepover: s, safe: safe, params: pp, passes: direction,
                                              first: &first, builder: &b)
                }
                for loop in area.loops {
                    let oriented = direction == .conventional ? loop.reversed : loop
                    PocketGenerator.cutLoop(oriented, z: z, zAbove: zAbove, params: pp, stepover: s, safe: safe, first: &first, builder: &b)
                }
                zAbove = z
            }
        }
        b.retract()
    }

    /// Cuts raster `lines` at `z` in runs: from the nearest unused end, each line, then a link at depth to the nearest
    /// end of an unused line in the next row (the row before, once the run has turned) wherever the link stays inside
    /// `safe`. A run ends where there's none; the next starts from the nearest unused end.
    static func rasterRuns(_ lines: [PocketGenerator.RasterLine], z: Double, safe: [Region], first: inout Bool,
                           builder b: inout ToolpathBuilder) {
        var byRow: [Int: [Int]] = [:]
        for (i, l) in lines.enumerated() { byRow[l.row, default: []].append(i) }
        var used = [Bool](repeating: false, count: lines.count)
        var left = lines.count
        func ends(_ i: Int) -> [(p: Vec2, reversed: Bool)] { [(lines[i].a, false), (lines[i].b, true)] }
        while left > 0 {
            // The nearest unused end starts a run.
            var best: (i: Int, reversed: Bool, d: Double)?
            for i in lines.indices where !used[i] {
                for e in ends(i) {
                    let d = e.p.distanceSquared(to: b.position.xy)
                    if best == nil || d < best!.d { best = (i, e.reversed, d) }
                }
            }
            guard var (i, reversed, _) = best else { break }
            var direction = 1
            var linked = false
            while true {
                let (s0, e0) = reversed ? (lines[i].b, lines[i].a) : (lines[i].a, lines[i].b)
                if linked {
                    b.feed(Vec3(s0, z))
                } else if !first, abs(b.position.z - z) < 1e-6, PocketGenerator.segmentInside(b.position.xy, s0, safe) {
                    b.feed(Vec3(s0, z))
                } else {
                    b.enter(at: Vec3(s0, z))
                }
                b.feed(Vec3(e0, z))
                first = false
                used[i] = true
                left -= 1
                // The next line: in the next row up the run, or once there's none, back the other way.
                var next: (i: Int, reversed: Bool, d: Double)?
                for dir in [direction, -direction] {
                    for j in byRow[lines[i].row + dir] ?? [] where !used[j] {
                        for e in ends(j) {
                            let d = e.p.distanceSquared(to: e0)
                            if next.map({ d < $0.d }) ?? true, PocketGenerator.segmentInside(e0, e.p, safe) { next = (j, e.reversed, d) }
                        }
                    }
                    if next != nil { direction = dir; break }
                }
                guard let n = next else { break }
                (i, reversed) = (n.i, n.reversed)
                linked = true
            }
        }
    }

    /// The parts of a carve's flats (`flatRegions`, at the flat depth) the V-bit clears itself: all of them without a
    /// clearance tool, and with one only what it can't reach (`unreached`). Every ring `clearFlat` cuts there stays
    /// inside these areas at the flat depth, so the V-bit's corner passes go neither below the floor nor past the walls.
    static func vBitFlatAreas(_ flatRegions: [Region], clearanceTool: Tool?, arcTolerance: Double) -> [Region] {
        guard let clearanceTool else { return flatRegions }
        return unreached(flatRegions, by: clearanceTool, arcTolerance: arcTolerance)
    }

    /// The parts of `regions` a flat end mill can't reach: the corners it rounds off and places narrower than it.
    static func unreached(_ regions: [Region], by tool: Tool, arcTolerance: Double) -> [Region] {
        let r = tool.radius
        let reached = regions.flatMap { $0.offset(by: -r, arcTolerance: arcTolerance) }.flatMap { $0.offset(by: r, arcTolerance: arcTolerance) }
        let rest = Clipper.difference(regions.flatMap(\.loops), minus: reached.flatMap(\.loops))
        // Drop the hair-thin slivers left where the two outlines coincide.
        return Region.build(from: rest, fill: .nonZero).filter { !$0.offset(by: -0.01, arcTolerance: arcTolerance).isEmpty }
    }

    /// The deepest level earlier toolpaths cleared everywhere over `regions` (positive, mm below the top); nil without a
    /// material model.
    static func clearedDepth(over regions: [Region], radius: Double, context: GenerationContext) -> Double? {
        guard let top = context.materialTop, !regions.isEmpty else { return nil }
        var highest = -Double.infinity
        let bounds = regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
        let step = max(1.0, radius)
        var y = bounds.min.y + step / 2
        while y < bounds.max.y {
            var x = bounds.min.x + step / 2
            while x < bounds.max.x {
                let p = Vec2(x, y)
                if regions.contains(where: { $0.contains(p) }) { highest = max(highest, top(p, radius)) }
                x += step
            }
            y += step
        }
        for loop in regions.flatMap(\.loops) {
            let walker = LoopWalker(loop)
            let n = max(8, Int(walker.length / step))
            for k in 0..<n { highest = max(highest, top(walker.point(at: walker.length * Double(k) / Double(n)), radius)) }
        }
        return highest.isFinite ? -highest : nil
    }

    /// The area an inlay plug carves, mirrored left to right about the centre of the design's bounds: inside the
    /// boundary and outside the design, so the design stands proud. The boundary is the outermost selected vector
    /// (its largest loop) when `useVector` and one holds all the others, or else the design's outline grown by
    /// `margin`. Built even-odd, so the design's outer loops become islands and its holes (the middle of an O) are
    /// carved too.
    static func plugRegions(shapes: [DesignShape], margin: Double, tolerance: Double, arcTolerance: Double,
                            useVector: Bool = false) -> [Region] {
        plugRegions(plugLayout(shapes: shapes, tolerance: tolerance, useVector: useVector), margin: margin, arcTolerance: arcTolerance)
    }

    /// The area a plug carves with its own settings (see the other `plugRegions`): with a whole-board boundary, the
    /// board (`VCarveInlay.board(around:stock:)`) grown by `edge`, so the carving's floor (`edge` in from its outline)
    /// reaches the board's edges and corners. Also returns the design's mirrored bounds, the board, and
    /// whether a selected-vector boundary was found.
    static func plugRegions(_ inlay: VCarveInlay, shapes: [DesignShape], stock: Stock, edge: Double, tolerance: Double,
                            arcTolerance: Double) -> (regions: [Region], design: Rect2, board: Rect2?, boundaryFound: Bool) {
        let layout = plugLayout(shapes: shapes, tolerance: tolerance, useVector: inlay.boundary == .vector)
        guard !layout.design.isEmpty else { return ([], .empty, nil, layout.boundary != nil) }
        let bounds = layout.design.bounds
        var board: Rect2?
        var outline: Polyline?
        if inlay.boundary == .board {
            let rect = inlay.board(around: bounds.center, stock: stock)
            board = rect
            // Grown with square corners: the carve then rises once into each corner, not at every step of a rounded one.
            let g = rect.insetBy(-max(0, edge))
            outline = Polyline([g.min, Vec2(g.max.x, g.min.y), g.max, Vec2(g.min.x, g.max.y)], closed: true)
        }
        let regions = plugRegions(layout, margin: inlay.boundaryMargin, arcTolerance: arcTolerance, board: outline)
        // Mirroring about the middle keeps the design's bounds where they are.
        return (regions, bounds, board, layout.boundary != nil)
    }

    /// `board`: a boundary in place of the selected vector or the margin, already where the plug is cut (the whole
    /// board isn't mirrored: it's the board).
    static func plugRegions(_ layout: (design: [Polyline], boundary: Polyline?), margin: Double, arcTolerance: Double,
                            board: Polyline? = nil) -> [Region] {
        guard !layout.design.isEmpty else { return [] }
        let center = layout.design.bounds.center
        let mirror = Transform2D.translation(-center).then(.scale(-1, 1)).then(.translation(center))
        let design = layout.design.map { $0.transformed(mirror) }
        let boundary: [Polyline]
        if let board {
            boundary = [board]
        } else if let outline = layout.boundary {
            boundary = [outline.transformed(mirror)]
        } else {
            let outers = Region.build(from: design, fill: .evenOdd).map(\.outer)
            boundary = Clipper.offset(outers, delta: max(margin, 0.01), arcTolerance: arcTolerance)
        }
        return Region.build(from: boundary + design, fill: .evenOdd)
    }

    /// Splits a plug's shapes into its design's closed loops and, with `useVector`, the boundary (see
    /// `plugBoundaryIndex`).
    static func plugLayout(shapes: [DesignShape], tolerance: Double, useVector: Bool) -> (design: [Polyline], boundary: Polyline?) {
        let outlines = shapes.map { $0.polylines(tolerance: tolerance).filter { $0.isClosed && $0.count >= 3 } }
        let boundary = useVector ? plugBoundaryIndex(outlines: outlines) : nil
        let design = outlines.indices.filter { $0 != boundary }.flatMap { outlines[$0] }
        return (design, boundary.flatMap { outlines[$0].max { $0.area < $1.area } })
    }

    /// The shape (index into `outlines`, each shape's closed loops) whose largest loop holds every loop of the
    /// others, when there are others.
    static func plugBoundaryIndex(outlines: [[Polyline]]) -> Int? {
        guard outlines.count > 1 else { return nil }
        let largest = outlines.map { loops in loops.max { $0.area < $1.area } }
        guard let i = largest.indices.max(by: { (largest[$0]?.area ?? 0) < (largest[$1]?.area ?? 0) }), let outer = largest[i] else { return nil }
        let others = outlines.indices.filter { $0 != i }.flatMap { outlines[$0] }
        return !others.isEmpty && others.allSatisfy({ loop in loop.points.allSatisfy { outer.contains($0) } }) ? i : nil
    }

    /// Convex vertices turning less than this are treated as points on a curve, not corners (10°).
    static let minimumCornerTurn = 10.0 * Double.pi / 180

    /// Medial-axis path for one loop of a region (loop oriented with the region interior on its left).
    static func carvePath(loop: Polyline, segments: [(Vec2, Vec2)], grid: SegmentGrid?, spacing: Double, rCap: Double,
                          tip: Double, t: Double) -> [Vec3] {
        var out: [Vec3] = []
        let n = loop.count
        guard n >= 3 else { return [] }
        var scratch = SegmentGrid.Scratch(count: segments.count)
        func emit(_ p: Vec2, _ normal: Vec2, exclude: Set<Int>) {
            // Only segments within 2·rCap of p can limit a circle of radius <= rCap that touches p.
            let candidates = grid.map { $0.query(p, radius: 2 * rCap + 1e-6, scratch: &scratch) }
            let r = min(maxInscribedRadius(p: p, n: normal, segments: segments, candidates: candidates, exclude: exclude), rCap)
            let c = p + normal * r
            let depth = max(0, (r - tip) / t)
            out.append(Vec3(c, -depth))
        }
        // Global segment index of this loop's edge i is found by matching endpoints.
        let edgeIndex: [Int] = (0..<n).map { i in
            let (a, b) = loop.segment(i)
            return segments.firstIndex { $0.0.isApprox(a, tolerance: 1e-9) && $0.1.isApprox(b, tolerance: 1e-9) } ?? -1
        }
        for i in 0..<n {
            let (a, b) = loop.segment(i)
            let d = b - a
            let len = d.length
            guard len > 1e-9 else { continue }
            let dir = d / len
            let normal = dir.perpLeft
            let count = max(1, Int((len / spacing).rounded(.up)))
            for k in 0..<count {
                let s = (Double(k) + 0.5) / Double(count)
                emit(a + d * s, normal, exclude: [edgeIndex[i]])
            }
            // Vertex at the end of edge i.
            let (_, c2) = loop.segment((i + 1) % n)
            let nextDir = (c2 - b).normalized
            let turn = dir.cross(nextDir)
            let turnAngle = atan2(turn, dir.dot(nextDir))
            if turnAngle > minimumCornerTurn {
                // Real convex corner: the carve rises to the surface at the corner tip. Gentle turns are just a
                // flattened curve; rising there would send the bit up and down along every curve (air cutting).
                out.append(Vec3(b, 0))
            } else if turn < -1e-9 {
                // Reflex corner: sweep the normal around the corner, circles all touch at the vertex.
                let a0 = normal.angle
                var a1 = nextDir.perpLeft.angle
                while a1 > a0 { a1 -= 2 * .pi }
                while a1 < a0 - 2 * .pi { a1 += 2 * .pi }
                let sweep = a1 - a0 // negative (clockwise)
                let steps = max(2, Int((abs(sweep) * max(rCap, spacing) / spacing).rounded(.up)))
                let excl: Set<Int> = [edgeIndex[i], edgeIndex[(i + 1) % n]]
                for k in 1..<steps {
                    emit(b, Vec2.fromAngle(a0 + sweep * Double(k) / Double(steps)), exclude: excl)
                }
            }
        }
        if let first = out.first { out.append(first) }
        return out
    }

    /// Radius of the largest circle centred on p + r·n (|n| = 1) that touches the boundary at p and no closer.
    /// Exact against every segment: tangency to a segment's interior, or passing through an endpoint.
    static func maxInscribedRadius(p: Vec2, n: Vec2, segments: [(Vec2, Vec2)], candidates: [Int]? = nil,
                                   exclude: Set<Int>) -> Double {
        var best = Double.infinity
        let eps = 1e-9
        let indices = candidates ?? Array(segments.indices)
        for idx in indices where !exclude.contains(idx) {
            let (a, b) = segments[idx]
            let d = b - a
            let len = d.length
            guard len > eps else { continue }
            let m = (d / len).perpLeft // inward normal of this edge
            // Tangent to the edge's line from the inside: m·(p - a) + r m·n = r.
            let denom = 1 - m.dot(n)
            if denom > eps {
                let r = m.dot(p - a) / denom
                if r > eps && r < best {
                    let c = p + n * r
                    let foot = c - m * r
                    let u = (foot - a).dot(d) / (len * len)
                    if u >= 0 && u <= 1 { best = r }
                }
            }
            // Through endpoint a (each endpoint appears as some segment's `a` for closed loops).
            let q = a - p
            let nq = n.dot(q)
            if nq > eps {
                let r = q.lengthSquared / (2 * nq)
                if r > eps && r < best { best = r }
            }
        }
        return best
    }

    /// Uniform bucket grid over segments for radius queries.
    struct SegmentGrid {
        let cell: Double
        let origin: Vec2
        let cols: Int
        let rows: Int
        var buckets: [[Int]]

        struct Scratch {
            var stamp: [Int]
            var generation = 0
            init(count: Int) { stamp = [Int](repeating: -1, count: count) }
        }

        init(segments: [(Vec2, Vec2)], cell: Double) {
            var bounds = Rect2.empty
            for (a, b) in segments { bounds = bounds.union(a).union(b) }
            if bounds.isEmpty { bounds = Rect2(x: 0, y: 0, width: 1, height: 1) }
            self.cell = cell
            origin = bounds.min
            cols = max(1, Int((bounds.width / cell).rounded(.up)) + 1)
            rows = max(1, Int((bounds.height / cell).rounded(.up)) + 1)
            buckets = Array(repeating: [], count: cols * rows)
            for (i, (a, b)) in segments.enumerated() {
                let x0 = Int((min(a.x, b.x) - origin.x) / cell), x1 = Int((max(a.x, b.x) - origin.x) / cell)
                let y0 = Int((min(a.y, b.y) - origin.y) / cell), y1 = Int((max(a.y, b.y) - origin.y) / cell)
                for y in max(0, y0)...min(rows - 1, y1) {
                    for x in max(0, x0)...min(cols - 1, x1) { buckets[y * cols + x].append(i) }
                }
            }
        }

        func query(_ p: Vec2, radius: Double, scratch: inout Scratch) -> [Int] {
            scratch.generation += 1
            let g = scratch.generation
            let x0 = max(0, Int((p.x - radius - origin.x) / cell)), x1 = min(cols - 1, Int((p.x + radius - origin.x) / cell))
            let y0 = max(0, Int((p.y - radius - origin.y) / cell)), y1 = min(rows - 1, Int((p.y + radius - origin.y) / cell))
            guard x0 <= x1, y0 <= y1 else { return [] }
            var out: [Int] = []
            for y in y0...y1 {
                for x in x0...x1 {
                    for i in buckets[y * cols + x] where scratch.stamp[i] != g {
                        scratch.stamp[i] = g
                        out.append(i)
                    }
                }
            }
            return out
        }
    }

    static func deterministicID(_ id: UUID, salt: UInt8) -> UUID {
        var u = id.uuid
        u.15 ^= salt
        return UUID(uuid: u)
    }
}
