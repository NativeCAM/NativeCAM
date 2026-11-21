import Foundation

/// 3D rotary roughing (research_notes/Rotary milling/rotary_milling.md §2.4, approach B): a flat or bull-nose end mill
/// clears the stock round a 3D model laid along the rotation axis, from a square bar or a round blank, in layers a
/// radial stepdown apart, leaving an allowance for 3D rotary finishing (`Rotary3DGenerator`).
///
/// The exact rotary drop-cutter (`RotaryDropCutter`) gives the tool's tip radius r_tip(x, θ) at every station and angle
/// on a grid, once, with the allowance on the model. Each layer ρ then works in the blank unrolled at its own radius,
/// the plane (x, s = ρ·θ), so lengths there are true on the layer and a straight line in it is a helix the controller
/// cuts at exactly ρ:
/// - **Where to clear**: where the tool's centre may go, {r_tip ≤ the layer above's radius}, near the material still
///   standing proud of the layer (within a tool radius of it): marching squares on the grids, with Clipper for the
///   rest. On a square bar the upper layers only meet the corners, so the air over the faces is skipped.
/// - **How**: the existing pocket clearing (`PocketGenerator.clearCentres`), raster or offset, with its stay-down links.
/// - **How deep**: at ρ wherever the model is clear of the tool there, and riding on the model (at r_tip, never
///   closer) in the band where it's between this layer and the last. So a layer is flat and exact at its radius, and
///   on slopes the layers leave the allowance (plus the ridges a flat bottom leaves on a round) rather than steps.
///   Every point is dropped exactly, and segments whose middle would dip into the model are split, as R3's are.
///
/// The stock is followed as it's cut, on a radial grid like the simulation's (`RadialSimulator`): it starts as the
/// blank (a square bar out to its corners) less what roundings and roughings before it took, and each stroke is cut
/// into it as it's laid down. It decides what's still to clear on the next layer and where rapids down stop (above
/// the most material under the tool's footprint), and it's handed on (`Result.left`) so a finish after the roughing
/// cuts only what it left.
///
/// The toolpath is laid out on the unrolled sheet like every wrapped one: X along the blank, sheet Y = centre + angle ×
/// the sheet's radius, Z from that radius. `RotaryWrap.prepare` joins its moves and lowers feeds the rotary axis
/// couldn't keep up with.
enum Rotary3DRoughing {
    typealias Point = Rotary3DGenerator.Point
    typealias Stroke = Rotary3DGenerator.Stroke

    struct Result {
        var toolpath: Toolpath
        /// The stock as the roughing leaves it (nil when it cut nothing).
        var left: RadialGrid?
    }

    /// Most cells the stock grid (and so the drop-cutter grid) may have before its spacing is widened.
    static let maxCells = 2_000_000

    static func generate(op: CAMOperation, params p: RotaryRoughParams, shapes: [DesignShape], context ctx: GenerationContext) -> Result {
        let stock = ctx.stock, tool = op.tool
        let clearance = max(stock.clearanceHeight, stock.plungeHeight)
        var tp = Toolpath(id: op.id, name: op.name, tool: tool, spindleRPM: tool.cutting.spindleRPM,
                          start: Vec3(0, stock.originPoint.y, clearance), motions: [])
        let len = ctx.length
        func stop(_ warnings: [String]) -> Result {
            tp.warnings = warnings
            return Result(toolpath: tp, left: nil)
        }
        guard let blank = stock.rotary else { return stop(["3D rotary roughing needs a rotary blank."]) }
        let models = shapes.filter { $0.modelSpec != nil && !$0.isKeepOut }
        guard !models.isEmpty else { return stop(["3D rotary roughing needs a 3D model: select one and use Use Selected Shapes."]) }
        var triangles: [Double] = []
        for m in models {
            m.forEachBlankTriangle { a, b, c in
                triangles.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
            }
        }
        let allowance = max(0, p.allowance)
        // The tool grown by the allowance all round (a flat end mill becomes a bull nose), so it stays the allowance
        // clear of the model square to its surface: beside a shoulder as well as above it.
        let grown = CutterProfile(tool: tool).flatMap { RotaryDropCutter(profile: $0, allowance: allowance, triangles: triangles) }
        guard let cutter = grown ?? RotaryDropCutter(tool: tool, allowance: allowance, triangles: triangles) else {
            return stop(["The model has no triangles to rough."])
        }
        var warnings: [String] = []
        switch tool.shape {
        case .flatEndMill, .surfacing, .bullNose: break
        default:
            warnings.append("3D rotary roughing is meant for a flat or bull-nose end mill: '\(tool.name)' is a "
                + "\(tool.shape.label.lowercased()), which clears slowly and leaves ridges between its passes. Rough with an end "
                + "mill and finish with the ball nose.")
        }

        // How much of the blank: the model's length, keeping the cutter inside the blank's ends.
        let R = tool.radius
        let x0 = p.startX ?? max(cutter.minX, R)
        let x1 = p.endX ?? min(cutter.maxX, blank.length - R)
        guard x1 > x0 + 1e-6 else {
            return stop(warnings + ["The roughing's start and end along the blank leave nothing to cut between them."])
        }
        if p.startX == nil, cutter.minX < R - 1 {
            warnings.append("The model starts \(len(R - cutter.minX)) too close to the chuck end of the blank for the cutter; "
                + "the roughing stops short of it. Move the model along the blank or use a longer blank.")
        }
        if p.endX == nil, cutter.maxX > blank.length - R + 1 {
            warnings.append("The model ends \(len(cutter.maxX - blank.length + R)) too close to the tailstock end of the blank "
                + "for the cutter; the roughing stops short of it. Move the model along the blank or use a longer blank.")
        }
        let stockRadius: @Sendable (Double) -> Double = ctx.rotaryStockRadius ?? { _ in blank.outerRadius }
        warnings += Rotary3DGenerator.fitWarnings(models, blank: blank, stockRadius: stockRadius, range: x0...x1, context: ctx)

        // The stock before this toolpath: the blank, less what roundings and roughings before it took.
        var sim = RadialSimulator(stock: stock, cellSize: max(0.05, p.sampleSpacing), maxCells: maxCells)
        let earlier = ctx.rotaryMaterial
        sim.lower { x, a in min(stockRadius(x), earlier?(x, a, 0) ?? .infinity) }
        let g0 = sim.grid
        let cell = g0.cellSize
        if cell > max(0.05, p.sampleSpacing) * 1.05 {
            warnings.append("The sample spacing was widened to \(len(cell)) to keep the model's grid to a size that generates "
                + "in reasonable time.")
        }

        // The tool's tip radius over the grid, between the roughing's ends: columns whose middles are in the range.
        let cA = max(0, Int(((x0 - g0.originX) / cell - 1e-9).rounded(.up)))
        let cB = min(g0.columns - 1, Int(((x1 - g0.originX) / cell + 1e-9).rounded(.down)))
        guard cB >= cA else { return stop(warnings + ["The roughing's start and end are too close together to rough between."]) }
        let cols = cB - cA + 1, rows = g0.rows
        let step = g0.angleStep
        var queries: [(x: Double, angle: Double)] = []
        queries.reserveCapacity(cols * rows)
        for j in 0..<rows {
            let a = g0.angle(row: j)
            for c in cA...cB { queries.append((g0.originX + Double(c) * cell, a)) }
        }
        var tip = cutter.tipRadii(queries)
        guard let lowest = tip.filter(\.isFinite).min() else {
            return stop(warnings + ["None of the model is within reach between the roughing's start and end."])
        }
        // Where none of the model is in reach, the floor is the model's deepest.
        let deepest = max(0, lowest)
        for i in tip.indices where !tip[i].isFinite || tip[i] < deepest { tip[i] = deepest }
        let tipF = tip.map(Float.init)

        // The layers, from the farthest the stock reaches in the range in to the model's deepest.
        var stockTop = 0.0
        for j in 0..<rows {
            for c in cA...cB { stockTop = max(stockTop, Double(g0.radii[j * g0.columns + c])) }
        }
        let stepdown = p.stepdown(tool)
        let stepover = p.stepover(tool)
        guard stockTop > deepest + 0.01 else {
            return stop(warnings + ["Nothing to rough: the stock is already within the allowance of the model."])
        }
        let layerCount = max(1, Int(((stockTop - deepest) / stepdown - 1e-9).rounded(.up)))
        let radii = (1...layerCount).map { stockTop - Double($0) * (stockTop - deepest) / Double(layerCount) }

        let top = blank.topRadius, cy = stock.originPoint.y
        func sheet(_ q: Point, _ offset: Double) -> Vec3 { Vec3(q.x, cy + (q.angle + offset) * top, q.r - top) }
        let feed = tool.cutting.feedRate, plungeRate = tool.cutting.plungeRate
        let tolerance = max(0.002, ctx.flattenTolerance)
        var motions: [Motion] = []
        var last: (point: Point, offset: Double)?
        var atSafe = true
        var deepestCut = Double.infinity
        var cutAny = false

        for (k, rho) in radii.enumerated() {
            let above = k == 0 ? stockTop : radii[k - 1]
            let around = 2 * Double.pi * rho
            // Grid index space (u along the blank, v round it) to the plane unrolled at this layer.
            func plane(_ q: Vec2) -> Vec2 { Vec2(g0.originX + (Double(cA) + q.x) * cell, rho * (q.y + 0.5) * step) }
            func planeLoops(_ loops: [Polyline]) -> [Polyline] { loops.map { Polyline($0.points.map(plane), closed: true) } }

            // Where the tool's centre may go on this layer: no closer to the model than the layer above's radius.
            let level = Float(above) + 1e-4
            let centres = planeLoops(GridContours.loops(mask: tipF.map { $0 <= level }, columns: cols, rows: rows, origin: .zero,
                                                         cellSize: 1, field: tipF, level: level, steepSlope: 2 * cell,
                                                         interpolationLimit: 0.25))
            guard !centres.isEmpty else { continue }
            // The material still proud of what this layer can take there: of the layer, and of the closest the tool
            // gets to the model anywhere it could reach it from.
            let g = sim.grid
            let proud = proudMask(g, tip: tip, cA: cA, cols: cols, rho: rho, reach: R)
            let material = planeLoops(GridContours.loops(mask: proud, columns: cols, rows: rows, origin: .zero, cellSize: 1))
            guard !material.isEmpty else { continue }
            // Round the seam: the material on either side reaches across it.
            func shifted(_ d: Double) -> [Polyline] { material.map { Polyline($0.points.map { Vec2($0.x, $0.y + d) }, closed: true) } }
            let wrapped = material + shifted(around) + shifted(-around)
            let near = Clipper.offset(wrapped, delta: R, arcTolerance: ctx.arcTolerance)
            let strip = Polyline([Vec2(x0, 0), Vec2(x1, 0), Vec2(x1, around), Vec2(x0, around)], closed: true)
            let areas = Region.nest(Clipper.intersection(Clipper.intersection(centres, near, fill: .nonZero), [strip], fill: .nonZero))
                .filter { $0.area > cell * cell }
            guard !areas.isEmpty else { continue }

            // Clear each area in the plane, at the layer (local Z = ρ − the layer above's radius, 0 at the layer above).
            var b = ToolpathBuilder(stock: stock, tool: tool, startXY: nil)
            var from = last.map { l -> Vec2 in
                let a = (l.point.angle + .pi).truncatingRemainder(dividingBy: 2 * .pi)
                return Vec2(l.point.x, rho * (a < 0 ? a + 2 * .pi : a))
            } ?? Vec2(x0, 0)
            var remaining = areas
            while !remaining.isEmpty {
                let i = remaining.indices.min { remaining[$0].outer.closestPoint(to: from).distance < remaining[$1].outer.closestPoint(to: from).distance }!
                let area = remaining.remove(at: i)
                let (strategy, angle) = Self.strategy(p.pattern, area: area, around: around)
                PocketGenerator.clearCentres([area], strategy: strategy, rasterAngle: angle, stepover: stepover, tool: tool,
                                             z: rho - above, zAbove: 0, context: ctx, builder: &b)
                from = b.position.xy
            }

            // Into strokes on the blank: each run of feeds after a rapid, started at the foot of its plunge.
            var strokes: [Stroke] = []
            var run: [Point]?
            var at = b.start
            func point(_ v: Vec3) -> Point { Point(x: v.x, angle: -.pi + v.y / rho, r: above + min(0, v.z)) }
            for m in b.motions {
                defer { if m.kind != .dwell { at = m.end } }
                switch m.kind {
                case .feed:
                    guard var pts = run else {
                        run = [point(m.end)]
                        continue
                    }
                    // Dropped closely enough for the drop-cutter to see the model between the corners of the path.
                    let a = point(at), c = point(m.end)
                    let d = Vec2(c.x - a.x, rho * (c.angle - a.angle)).length
                    let n = max(1, Int((d / cell).rounded(.up)))
                    for t in 1...n {
                        let f = Double(t) / Double(n)
                        pts.append(Point(x: a.x + (c.x - a.x) * f, angle: a.angle + (c.angle - a.angle) * f, r: a.r + (c.r - a.r) * f))
                    }
                    run = pts
                case .rapid:
                    if let pts = run, pts.count > 1 { strokes.append(Stroke(points: pts, lead: nil)) }
                    run = nil
                default:
                    continue
                }
            }
            if let pts = run, pts.count > 1 { strokes.append(Stroke(points: pts, lead: nil)) }
            guard !strokes.isEmpty else { continue }

            // No closer to the model than the drop-cutter allows, anywhere along the path.
            var queries: [(x: Double, angle: Double)] = []
            for s in strokes { for q in s.points { queries.append((q.x, q.angle)) } }
            let exact = cutter.tipRadii(queries)
            var n = 0
            for s in strokes.indices {
                for j in strokes[s].points.indices {
                    let r = exact[n]
                    n += 1
                    if r.isFinite { strokes[s].points[j].r = max(strokes[s].points[j].r, r) }
                }
            }
            Rotary3DGenerator.refine(&strokes, cutter: cutter, material: { _, _ in deepest }, floor: rho, tolerance: tolerance)

            // Laid down one after another, each from safe Z, cut into the stock as it goes.
            for stroke in strokes {
                guard let first = stroke.points.first else { continue }
                // The same direction round the blank the fewest turns from where the last stroke ended.
                let offset = last.map { (($0.point.angle + $0.offset - first.angle) / (2 * .pi)).rounded() * 2 * .pi } ?? 0
                var cut: [Motion] = []
                var position = last.map { sheet($0.point, $0.offset) } ?? Vec3(first.x, cy + first.angle * top, clearance)
                if motions.isEmpty { tp.start = Vec3(first.x, cy + first.angle * top, clearance) }
                if !atSafe, let l = last { cut.append(.rapid(Vec3(l.point.x, cy + (l.point.angle + l.offset) * top, clearance))) }
                let over = sheet(first, offset)
                if cut.last?.end ?? position != Vec3(over.x, over.y, clearance) { cut.append(.rapid(Vec3(over.x, over.y, clearance))) }
                // Down to just above the most material under the tool's footprint there, then the plunge; straight down
                // to a start that's already that far clear of it.
                let plunge = sim.grid.highest(x: first.x, angle: first.angle, reach: R) + stock.plungeHeight - top
                if plunge <= over.z + 1e-9 {
                    cut.append(.rapid(over))
                } else {
                    if plunge < clearance - 1e-9 { cut.append(.rapid(Vec3(over.x, over.y, plunge))) }
                    cut.append(.feed(over, plungeRate))
                }
                var prev = first
                for q in stroke.points.dropFirst() {
                    let dr = q.r - prev.r
                    let lateral = Vec2(q.x - prev.x, (q.r + prev.r) / 2 * (q.angle - prev.angle)).length
                    var f = feed
                    if dr < 0, lateral < -dr { f = min(f, plungeRate * (lateral * lateral + dr * dr).squareRoot() / -dr) }
                    cut.append(.feed(sheet(q, offset), f))
                    deepestCut = min(deepestCut, q.r)
                    prev = q
                }
                deepestCut = min(deepestCut, first.r)
                // Cut into the stock model as laid down (the first rapid is from where the last stroke left the tool).
                for m in cut {
                    sim.apply(m, from: position, tool: tool)
                    position = m.end
                }
                motions += cut
                last = (prev, offset)
                atSafe = false
                cutAny = true
            }
        }
        guard cutAny, let l = last else {
            return stop(warnings + ["Nothing to rough: the stock is already within the allowance of the model."])
        }
        motions.append(.rapid(Vec3(l.point.x, cy + (l.point.angle + l.offset) * top, clearance)))
        // Join the moves that lie on one line of the sheet, then slow those the rotary axis couldn't keep up with, as
        // the post will write them (`turnLimitedFeed`).
        motions = RotaryWrap.merged(motions, start: tp.start, tolerance: ctx.flattenTolerance / 2)
        let turnSpeed = RotaryWrap.turnSpeed(ctx.machine)
        var at = tp.start
        for i in motions.indices {
            defer { at = motions[i].end }
            guard motions[i].kind == .feed else { continue }
            let a = Point(x: at.x, angle: (at.y - cy) / top, r: top + at.z)
            let b = Point(x: motions[i].end.x, angle: (motions[i].end.y - cy) / top, r: top + motions[i].end.z)
            motions[i].feed = turnLimitedFeed(motions[i].feed, from: a, to: b, turnSpeed: turnSpeed)
        }
        tp.motions = motions

        // Checks: reach, flutes, layer depth, the allowance against the ridges a flat bottom leaves on a round.
        let cutDeep = stockTop - deepestCut
        if tool.stickout < cutDeep + 1 {
            warnings.append("Cuts \(len(cutDeep)) in from the stock's surface, but '\(tool.name)' sticks out only \(len(tool.stickout)) "
                + "from the collet, so the collet nut could hit the blank. Let the bit out further (and set its stickout), or use a "
                + "smaller blank.")
        }
        if cutDeep > tool.fluteLength + 1e-6 {
            warnings.append("Roughs \(len(cutDeep)) in from the stock's surface, more than the cutting length of '\(tool.name)' "
                + "(\(len(tool.fluteLength))), so its shank rubs where the cut has a wall: at the ends of the roughing and beside "
                + "the model's shoulders. Use a bit with longer flutes.")
        }
        let layerDepth = (stockTop - deepest) / Double(layerCount)
        if layerDepth > tool.fluteLength + 1e-6 {
            warnings.append("Cuts up to \(len(layerDepth)) deep in one layer, more than the cutting length of '\(tool.name)' "
                + "(\(len(tool.fluteLength))). Lower the stepdown.")
        } else if layerDepth > 1.5 * tool.cutting.stepdown + 1e-6 {
            warnings.append("Cuts up to \(len(layerDepth)) deep in one layer, more than '\(tool.name)' should take "
                + "(its stepdown is \(len(tool.cutting.stepdown))). Lower the stepdown.")
        }
        let cusp = RotaryRoughParams.cusp(tool, radius: max(deepestCut, R))
        if allowance + 1e-6 < cusp {
            warnings.append("The allowance (\(len(allowance))) is less than the ridges '\(tool.name)' leaves across the round "
                + "\(len(deepestCut)) from the axis, where its flat bottom meets the curve only along its middle (up to "
                + "\(len(cusp))): the finish takes uneven cuts. Leave at least \(len(cusp)).")
        }
        warnings += Rotary3DGenerator.reachWarnings(triangles, range: x0...x1, context: ctx)
        tp.warnings = warnings
        return Result(toolpath: tp, left: sim.grid)
    }

    /// The feed for a move from `a` to `b` (mm/min): `feed`, or less where the rotary axis would turn faster than
    /// `turnSpeed` (degrees per minute) to keep it (`Rotary3DGenerator.clampFeed`), allowing for how the post writes
    /// it: A to a thousandth of a degree and lengths to a ten-thousandth of an inch, so a short move's written turn can
    /// be a little more, and its written length a little less, than planned. Riding over the model the roughing makes
    /// many short moves, where that matters.
    static func turnLimitedFeed(_ feed: Double, from a: Point, to b: Point, turnSpeed: Double) -> Double {
        let degrees = abs(b.angle - a.angle) * 180 / .pi
        guard degrees > 1e-9 else { return feed }
        let pieces = Double(max(1, Int((degrees / RotaryWrap.maxTurnPerMove - 1e-12).rounded(.up))))
        let length = RotaryWrap.tipLength(x0: a.x, r0: a.r, degrees0: 0, x1: b.x, r1: b.r, degrees1: degrees) / pieces
        let written = (degrees / pieces) / (degrees / pieces + 0.002) * max(0, 1 - 0.008 / max(length, 1e-9))
        let limit = Rotary3DGenerator.clampFeed(feed / max(written, 1e-9), from: a, to: b, turnSpeed: turnSpeed) * written
        return limit < feed ? max(1, limit.rounded(.down)) : feed
    }

    /// The pocket strategy and raster angle (degrees, in the unrolled plane: 0 along the blank, 90 round it) for one area.
    static func strategy(_ pattern: RotaryRoughParams.Pattern, area: Region, around: Double) -> (PocketStrategy, Double) {
        switch pattern {
        case .around: return (.raster, 90)
        case .along: return (.raster, 0)
        case .offset: return (.offset, 0)
        case .auto:
            let b = area.bounds
            return (.raster, b.height >= b.width ? 90 : 0)
        }
    }

    /// The grid cells (in the drop-cutter grid's columns, all rows) where the stock stands proud of what layer `rho`
    /// can take: farther out than the layer, and than the lowest any tool position within `reach` of it can cut it to.
    /// A flat bottom tangent at angle φ off the cell's ray stands tip ÷ cos φ out along that ray, so the model itself,
    /// standing in the stock (a square end the bar's own size), isn't counted as something to clear.
    static func proudMask(_ g: RadialGrid, tip: [Double], cA: Int, cols: Int, rho: Double, reach: Double) -> [Bool] {
        let rows = g.rows
        let wc = max(0, Int((reach / g.cellSize).rounded(.down)))
        // The lowest tip within reach along the blank, for each cell.
        var along = [Double](repeating: 0, count: tip.count)
        for j in 0..<rows {
            for c in 0..<cols {
                var m = Double.infinity
                for d in max(0, c - wc)...min(cols - 1, c + wc) { m = min(m, tip[j * cols + d]) }
                along[j * cols + c] = m
            }
        }
        let widest = min(rows / 4, Int((asin(min(1, reach / max(rho, reach, 1e-6))) / g.angleStep).rounded(.down)))
        let stretch = (0...widest).map { 1 / cos(Double($0) * g.angleStep) }
        let sines = (0...widest).map { sin(Double($0) * g.angleStep) }
        var mask = [Bool](repeating: false, count: tip.count)
        for j in 0..<rows {
            for c in 0..<cols {
                // (Each cell on its own ray: the areas are grown by a tool radius round what's proud, which takes in
                // anything between them.)
                let stock = Double(g.radii[j * g.columns + cA + c])
                guard stock > rho + 0.02 else { continue }
                // Tool positions round the blank whose footprint reaches the stock there (it's `stock` out).
                var m = along[j * cols + c]
                var d = 1
                while d <= widest, stock * sines[d] <= reach {
                    let lo = along[((j - d) % rows + rows) % rows * cols + c], hi = along[(j + d) % rows * cols + c]
                    m = min(m, min(lo, hi) * stretch[d])
                    d += 1
                }
                mask[j * cols + c] = stock > max(rho, m) + 0.02
            }
        }
        return mask
    }
}
