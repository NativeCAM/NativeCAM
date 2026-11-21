import Foundation

/// 3D rotary finishing (research_notes/Rotary milling/rotary_milling.md §2.2–2.3): a radial tool follows a 3D model
/// laid along the rotation axis, all the way round it, as the blank turns.
///
/// The tool's tip radius at every point of the path comes from the exact rotary drop-cutter (`RotaryDropCutter`), so
/// the path never cuts into the model at its points; between them, a segment whose middle would dip more than the
/// tolerance below the model's is split. Patterns (`RotaryFinishParams.Pattern`):
/// - **Spiral**: a full turn at the start, one continuous helix along the blank advancing a stepover per turn, and a
///   full turn at the end. A is never wound back, so there's no seam.
/// - **Rings**: a full turn at one station, a step along the blank following the surface, the next turn.
/// - **Along X**: zig-zag passes along the blank at fixed angles, turning between them along the surface by
///   Δθ = stepover ÷ the model's largest radius.
///
/// Where the model is deeper below the stock than the pass depth, layers cut down to it first (a clamped stack, §2.4
/// "Approach A"): each layer runs the same pattern at the layers' stepover with the tool no closer to the axis than the
/// layer's radius, and leaves out what it would only cut air on. The finish then follows the model everywhere. Rotary
/// roughing that clears each layer as an area (R4) will make the layers much quicker.
///
/// The toolpath is laid out on the unrolled sheet like every wrapped one (`RoundingGenerator`): X along the blank,
/// sheet Y = centre + angle × the sheet's radius, Z from that radius. The angle only ever increases, so the rotary
/// turns one way throughout. Feeds are lowered where the rotary axis couldn't otherwise keep up near the axis (see
/// `clampFeed`), so the inverse-time F words the post writes are times the machine can keep to.
enum Rotary3DGenerator {
    /// A point of the path: station along the blank, unwound angle (radians) and tip radius from the axis (mm).
    struct Point {
        var x: Double
        var angle: Double
        var r: Double = 0
    }

    /// One continuous run of cutting moves, and how it joins the run before it.
    struct Stroke {
        var points: [Point]
        /// Points between the previous stroke's last point and this one's first (a ring's step along the blank, a
        /// line's turn to the next angle), when the two are cut one after the other; nil starts it from safe Z.
        var lead: [Point]?
    }

    /// Largest number of points a toolpath is dropped at before the spacing is widened.
    static let maxPoints = 12_000_000

    static func generate(op: CAMOperation, params p: RotaryFinishParams, shapes: [DesignShape], context ctx: GenerationContext) -> Toolpath {
        let stock = ctx.stock, tool = op.tool
        let clearance = max(stock.clearanceHeight, stock.plungeHeight)
        var tp = Toolpath(id: op.id, name: op.name, tool: tool, spindleRPM: tool.cutting.spindleRPM,
                          start: Vec3(0, stock.originPoint.y, clearance), motions: [])
        let len = ctx.length
        guard let blank = stock.rotary else {
            tp.warnings = ["3D rotary finishing needs a rotary blank."]
            return tp
        }
        let models = shapes.filter { $0.modelSpec != nil && !$0.isKeepOut }
        guard !models.isEmpty else {
            tp.warnings = ["3D rotary finishing needs a 3D model: select one and use Use Selected Shapes."]
            return tp
        }
        var triangles: [Double] = []
        for m in models {
            m.forEachBlankTriangle { a, b, c in
                triangles.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
            }
        }
        guard let cutter = RotaryDropCutter(tool: tool, allowance: p.allowance, triangles: triangles) else {
            tp.warnings = ["The model has no triangles to finish."]
            return tp
        }
        var warnings: [String] = []
        switch tool.shape {
        case .ballNose, .bullNose: break
        case .flatEndMill, .surfacing:
            warnings.append("A ball-nose bit gives a much smoother 3D finish than '\(tool.name)'.")
        default:
            if cutter.kind != .profile {
                warnings.append("'\(tool.name)' is a \(tool.shape.label.lowercased()) whose shape 3D rotary finishing can't follow exactly, "
                    + "so it follows the model as if it were a flat end mill of its diameter: it never cuts into the model, but leaves "
                    + "material in hollows. Check its angle, or use a ball nose.")
            }
        }

        let top = blank.topRadius, cy = stock.originPoint.y
        let stockRadius: @Sendable (Double) -> Double = ctx.rotaryStockRadius ?? { _ in blank.outerRadius }
        /// The material before this toolpath at station x and angle a: the blank, or what a rounding left of it.
        func material(_ x: Double, _ a: Double) -> Double {
            min(stockRadius(x), blank.surfaceRadius(atDegrees: a * 180 / .pi))
        }

        // How much of the blank: the model's length, keeping the cutter inside the blank's ends.
        let x0 = p.startX ?? max(cutter.minX, tool.radius)
        let x1 = p.endX ?? min(cutter.maxX, blank.length - tool.radius)
        guard x1 > x0 + 1e-6 else {
            tp.warnings = warnings + ["The finish's start and end along the blank leave nothing to cut between them."]
            return tp
        }
        if p.startX == nil, cutter.minX < tool.radius - 1 {
            warnings.append("The model starts \(len(tool.radius - cutter.minX)) too close to the chuck end of the blank for the cutter; "
                + "the finish stops short of it. Move the model along the blank or use a longer blank.")
        }
        if p.endX == nil, cutter.maxX > blank.length - tool.radius + 1 {
            warnings.append("The model ends \(len(cutter.maxX - blank.length + tool.radius)) too close to the tailstock end of the blank "
                + "for the cutter; the finish stops short of it. Move the model along the blank or use a longer blank.")
        }
        warnings += fitWarnings(models, blank: blank, stockRadius: stockRadius, range: x0...x1, context: ctx)

        // Sampling: points along the blank and round it.
        let surfaceMax = min(cutter.maxRadius + p.allowance, blank.outerRadius)
        var spacing = max(0.02, p.sampleSpacing)
        var step = p.angleStep.map { max(0.01, $0) * .pi / 180 } ?? spacing / max(surfaceMax, 1)
        let stepover = p.stepover(tool)
        let length = x1 - x0
        func estimate() -> Int {
            let perTurn = 2 * Double.pi / step
            switch p.pattern {
            case .spiral, .rings: return Int((length / stepover + 3) * perTurn)
            case .lines: return Int((2 * .pi * surfaceMax / stepover) * (length / spacing + perTurn / max(1, 2 * .pi * surfaceMax / stepover)))
            }
        }
        if estimate() > maxPoints {
            let f = Double(estimate()) / Double(maxPoints)
            step *= f.squareRoot()
            spacing *= f.squareRoot()
            warnings.append("The sampling was widened to \(len(spacing)) along the blank and \(String(format: "%.2f", step * 180 / .pi))° round it "
                + "to keep the toolpath to a size the machine can load.")
        }
        let perTurn = max(36, Int((2 * Double.pi / step).rounded(.up)))

        // How deep the model goes below the stock, from a coarse look all the way round: it decides the layers.
        let stations = max(2, min(400, Int((length / max(spacing, 1)).rounded(.up)) + 1))
        var probes: [(x: Double, angle: Double)] = []
        for i in 0..<stations {
            for j in 0..<180 { probes.append((x0 + length * Double(i) / Double(stations - 1), 2 * .pi * Double(j) / 180)) }
        }
        guard let deepest = cutter.tipRadii(probes).filter(\.isFinite).min().map({ max(0, $0) }) else {
            tp.warnings = warnings + ["None of the model is within reach between the finish's start and end."]
            return tp
        }
        let pass = p.passDepth(tool)
        var stockTop = 0.0
        for i in 0...64 { stockTop = max(stockTop, stockRadius(x0 + length * Double(i) / 64)) }
        stockTop = min(stockTop, blank.outerRadius)
        let layerCount = max(0, Int(((stockTop - deepest) / pass - 1e-6).rounded(.up)) - 1)

        // The layers, then the finish, each pass the other way along the blank from the last.
        var passes: [(strokes: [Stroke], layer: Double?)] = []
        var forward = true
        for k in 0..<layerCount {
            let rho = stockTop - Double(k + 1) * pass
            let above = k == 0 ? Double.infinity : stockTop - Double(k) * pass
            let (a, b) = forward ? (x0, x1) : (x1, x0)
            var strokes = pattern(p.pattern, from: a, to: b, stepover: p.layerStepover(tool), perTurn: perTurn, spacing: spacing,
                                  outer: surfaceMax)
            evaluate(&strokes, cutter: cutter, material: material)
            // Where this layer would only cut air (the model, or the layer before, is already there), leave it out.
            func cuts(_ q: Point) -> Bool { max(q.r, rho) < min(material(q.x, q.angle), max(q.r, above)) - 0.01 }
            strokes = trimmed(strokes, pattern: p.pattern, perTurn: perTurn, cuts: cuts)
            guard !strokes.isEmpty else { continue }
            for i in strokes.indices {
                for j in strokes[i].points.indices { strokes[i].points[j].r = max(strokes[i].points[j].r, rho) }
                if strokes[i].lead != nil { for j in strokes[i].lead!.indices { strokes[i].lead![j].r = max(strokes[i].lead![j].r, rho) } }
            }
            passes.append((strokes, rho))
            forward.toggle()
        }
        let lastLayer = passes.last?.layer
        var finish = pattern(p.pattern, from: forward ? x0 : x1, to: forward ? x1 : x0, stepover: stepover, perTurn: perTurn,
                             spacing: spacing, outer: surfaceMax)
        evaluate(&finish, cutter: cutter, material: material)
        // The most the finish takes in one go: what the last layer left above the model.
        var engagement = passes.isEmpty ? 0 : pass
        for s in finish {
            for q in s.points + (s.lead ?? []) {
                engagement = max(engagement, min(material(q.x, q.angle), max(q.r, lastLayer ?? .infinity)) - q.r)
            }
        }
        passes.append((finish, nil))

        // Split segments whose middle would dip into the model.
        let tolerance = max(0.002, ctx.flattenTolerance)
        for i in passes.indices { refine(&passes[i].strokes, cutter: cutter, material: material, floor: passes[i].layer, tolerance: tolerance) }

        // Lay the passes end to end, each starting a whole number of turns on from where the last one ended.
        let feed = tool.cutting.feedRate
        let aMax = RotaryWrap.turnSpeed(ctx.machine)
        func sheet(_ q: Point, _ offset: Double) -> Vec3 { Vec3(q.x, cy + (q.angle + offset) * top, q.r - top) }
        var motions: [Motion] = []
        var offset = 0.0
        var last: (point: Point, offset: Double)?
        var slowest = feed, slowestRadius = Double.infinity
        for (n, pass) in passes.enumerated() {
            if let l = last { offset = ((l.point.angle + l.offset) / (2 * .pi)).rounded(.up) * 2 * .pi }
            if n == 0, let first = pass.strokes.first?.points.first { tp.start = Vec3(first.x, cy + first.angle * top, clearance) }
            for stroke in pass.strokes {
                guard let first = stroke.points.first else { continue }
                var run: [Point] = []
                if let lead = stroke.lead, let l = last, l.offset == offset {
                    run = lead + stroke.points
                } else {
                    // From safe Z: up, across (the blank turns here, clear of it), down to just above the stock, plunge.
                    if let l = last { motions.append(.rapid(Vec3(l.point.x, cy + (l.point.angle + l.offset) * top, clearance))) }
                    let over = sheet(first, offset)
                    motions.append(.rapid(Vec3(over.x, over.y, clearance)))
                    let plunge = material(first.x, first.angle) + stock.plungeHeight - top
                    if plunge < clearance - 1e-9, plunge > over.z { motions.append(.rapid(Vec3(over.x, over.y, plunge))) }
                    motions.append(.feed(over, tool.cutting.plungeRate))
                    run = Array(stroke.points.dropFirst())
                    last = (first, offset)
                }
                for q in run {
                    motions.append(.feed(sheet(q, offset), feed))
                    last = (q, offset)
                }
            }
        }
        if let l = last { motions.append(.rapid(Vec3(l.point.x, cy + (l.point.angle + l.offset) * top, clearance))) }
        // Join the moves that lie on one line of the sheet (a helix at one radius), then slow those the rotary axis
        // couldn't keep up with: one feed per joined move, so the post's inverse times stay few and sensible.
        motions = RotaryWrap.merged(motions, start: tp.start, tolerance: ctx.flattenTolerance / 2)
        var at = tp.start
        for i in motions.indices {
            defer { at = motions[i].end }
            guard motions[i].kind == .feed else { continue }
            let a = Point(x: at.x, angle: (at.y - cy) / top, r: top + at.z)
            let b = Point(x: motions[i].end.x, angle: (motions[i].end.y - cy) / top, r: top + motions[i].end.z)
            let f = clampFeed(motions[i].feed, from: a, to: b, turnSpeed: aMax)
            guard f < motions[i].feed else { continue }
            motions[i].feed = f
            if f < slowest - 1e-9 { slowest = f; slowestRadius = max(0, min(a.r, b.r)) }
        }
        tp.motions = motions

        // Checks: reach, flutes, pass depth, the rotary's speed, the model's shape.
        let cutDeep = stockTop - max(0, deepest)
        if tool.stickout < cutDeep + 1 {
            warnings.append("Cuts \(len(cutDeep)) in from the stock's surface, but '\(tool.name)' sticks out only \(len(tool.stickout)) "
                + "from the collet, so the collet nut could hit the blank. Let the bit out further (and set its stickout), or use a "
                + "smaller blank.")
        }
        let perPass = engagement
        if perPass > tool.fluteLength + 1e-6 {
            warnings.append("Cuts up to \(len(perPass)) deep in one pass, more than the cutting length of '\(tool.name)' "
                + "(\(len(tool.fluteLength))). Lower the pass depth.")
        } else if perPass > 1.5 * tool.cutting.stepdown + 1e-6 {
            warnings.append("Cuts up to \(len(perPass)) deep in one pass, more than '\(tool.name)' should take "
                + "(its stepdown is \(len(tool.cutting.stepdown))). Lower the pass depth.")
        }
        if slowest < feed * 0.5 {
            warnings.append(RotaryWrap.slowingWarning(RotaryWrap.Slowing(feed: slowest, set: feed, radius: slowestRadius), context: ctx))
        }
        if blank.shape == .squareBar, ctx.rotaryStockRadius == nil {
            warnings.append("Starts from a square bar: add a Rounding toolpath before it, or the first layers cut the corners in "
                + "interrupted passes.")
        }
        warnings += reachWarnings(triangles, range: x0...x1, context: ctx)
        tp.warnings = warnings
        return tp
    }

    /// The feed for a move from `a` to `b`, mm/min: `feed`, or less when the rotary axis would have to turn faster than
    /// `turnSpeed` (degrees per minute) to keep it (`RotaryWrap.turnLimitedFeed`, which every wrapped toolpath's feeds go
    /// through again once `RotaryWrap.prepare` has joined them). A move that turns more than a quarter turn is split
    /// into equal pieces afterward (`RotaryWrap.split`); the limit is the fastest piece's.
    static func clampFeed(_ feed: Double, from a: Point, to b: Point, turnSpeed: Double) -> Double {
        let degrees = abs(b.angle - a.angle) * 180 / .pi
        return RotaryWrap.turnLimitedFeed(feed, x0: a.x, r0: a.r, degrees0: a.angle * 180 / .pi,
                                          x1: b.x, r1: b.r, degrees1: b.angle * 180 / .pi,
                                          pieces: Int((degrees / RotaryWrap.maxTurnPerMove - 1e-12).rounded(.up)), turnSpeed: turnSpeed)
    }

    // MARK: Patterns

    /// The points of one pass of `kind` from station `a` to `b` (either way along the blank), starting at angle 0.
    static func pattern(_ kind: RotaryFinishParams.Pattern, from a: Double, to b: Double, stepover s: Double, perTurn n: Int,
                        spacing h: Double, outer: Double) -> [Stroke] {
        let d = 2 * Double.pi / Double(n)
        let span = b - a
        switch kind {
        case .spiral:
            var pts: [Point] = []
            let turns = abs(span) / s
            let steps = max(1, Int((turns * Double(n)).rounded(.up)))
            pts.reserveCapacity(2 * n + steps + 1)
            for j in 0...n { pts.append(Point(x: a, angle: Double(j) * d)) }
            let climb = 2 * .pi * turns / Double(steps)
            for j in 1...steps { pts.append(Point(x: a + span * Double(j) / Double(steps), angle: 2 * .pi + Double(j) * climb)) }
            let end = 2 * .pi + Double(steps) * climb
            for j in 1...n { pts.append(Point(x: b, angle: end + Double(j) * d)) }
            return [Stroke(points: pts, lead: nil)]
        case .rings:
            let count = max(1, Int((abs(span) / s - 1e-9).rounded(.up)))
            var strokes: [Stroke] = []
            for k in 0...count {
                let x = a + span * Double(k) / Double(count)
                let base = 2 * Double.pi * Double(k)
                let ring = (0...n).map { Point(x: x, angle: base + Double($0) * d) }
                var lead: [Point]?
                if k > 0 {
                    let prev = a + span * Double(k - 1) / Double(count)
                    let m = max(1, Int((abs(x - prev) / h).rounded(.up)))
                    lead = (1..<m).map { Point(x: prev + (x - prev) * Double($0) / Double(m), angle: base) }
                }
                strokes.append(Stroke(points: ring, lead: lead))
            }
            return strokes
        case .lines:
            let count = max(3, Int((2 * .pi * max(outer, 0.5) / s).rounded(.up)))
            let turn = 2 * Double.pi / Double(count)
            let m = max(1, Int((abs(span) / h).rounded(.up)))
            var strokes: [Stroke] = []
            for j in 0..<count {
                let angle = Double(j) * turn
                let (p, q) = j % 2 == 0 ? (a, b) : (b, a)
                let line = (0...m).map { Point(x: p + (q - p) * Double($0) / Double(m), angle: angle) }
                var lead: [Point]?
                if j > 0 {
                    let k = max(1, Int((turn / d).rounded(.up)))
                    lead = (1..<k).map { Point(x: p, angle: angle - turn + turn * Double($0) / Double(k)) }
                }
                strokes.append(Stroke(points: line, lead: lead))
            }
            return strokes
        }
    }

    /// Drops the tool at every point of `strokes`. Where nothing of the model is in reach, the tool rides on the stock.
    static func evaluate(_ strokes: inout [Stroke], cutter: RotaryDropCutter, material: (Double, Double) -> Double) {
        var queries: [(x: Double, angle: Double)] = []
        for s in strokes {
            for q in s.lead ?? [] { queries.append((q.x, q.angle)) }
            for q in s.points { queries.append((q.x, q.angle)) }
        }
        let r = cutter.tipRadii(queries)
        var i = 0
        func value(_ q: Point) -> Double {
            defer { i += 1 }
            return r[i].isFinite ? max(0, r[i]) : material(q.x, q.angle)
        }
        for k in strokes.indices {
            if strokes[k].lead != nil { for j in strokes[k].lead!.indices { strokes[k].lead![j].r = value(strokes[k].lead![j]) } }
            for j in strokes[k].points.indices { strokes[k].points[j].r = value(strokes[k].points[j]) }
        }
    }

    /// Leaves out what a layer would only cut air on: a spiral's turns at either end, and whole rings or lines. A
    /// stroke whose neighbour before it was left out starts from safe Z.
    static func trimmed(_ strokes: [Stroke], pattern: RotaryFinishParams.Pattern, perTurn n: Int, cuts: (Point) -> Bool) -> [Stroke] {
        switch pattern {
        case .spiral:
            guard let s = strokes.first, let first = s.points.firstIndex(where: cuts), let lastCut = s.points.lastIndex(where: cuts) else { return [] }
            let from = max(0, first - n), to = min(s.points.count - 1, lastCut + n)
            return [Stroke(points: Array(s.points[from...to]), lead: nil)]
        case .rings, .lines:
            var out: [Stroke] = []
            var previousKept = false
            for s in strokes {
                guard s.points.contains(where: cuts) || (s.lead ?? []).contains(where: cuts) else { previousKept = false; continue }
                out.append(Stroke(points: s.points, lead: previousKept ? s.lead : nil))
                previousKept = true
            }
            return out
        }
    }

    /// Splits the segments between points (leads included) whose middle would dip more than `tolerance` below where
    /// the tool has to be there, up to four times over.
    static func refine(_ strokes: inout [Stroke], cutter: RotaryDropCutter, material: (Double, Double) -> Double,
                       floor: Double?, tolerance: Double) {
        for k in strokes.indices {
            var run = (strokes[k].lead ?? []) + strokes[k].points
            let leadCount = strokes[k].lead?.count ?? 0
            // Index of the stroke's first point in `run`, which moves as points are added in the lead.
            var firstPoint = leadCount
            var check = Array(repeating: true, count: max(0, run.count - 1))
            for _ in 0..<4 {
                var queries: [(x: Double, angle: Double)] = []
                var which: [Int] = []
                for i in check.indices where check[i] {
                    let a = run[i], b = run[i + 1]
                    queries.append(((a.x + b.x) / 2, (a.angle + b.angle) / 2))
                    which.append(i)
                }
                guard !queries.isEmpty else { break }
                let r = cutter.tipRadii(queries)
                var insert: [Int: Point] = [:]
                for (n, i) in which.enumerated() {
                    let q = queries[n]
                    var v = r[n].isFinite ? max(0, r[n]) : material(q.x, q.angle)
                    if let floor { v = max(v, floor) }
                    if v > (run[i].r + run[i + 1].r) / 2 + tolerance { insert[i] = Point(x: q.x, angle: q.angle, r: v) }
                }
                guard !insert.isEmpty else { break }
                var next: [Point] = []
                var nextCheck: [Bool] = []
                next.reserveCapacity(run.count + insert.count)
                var newFirst = firstPoint
                for i in run.indices {
                    next.append(run[i])
                    guard i < run.count - 1 else { break }
                    if let mid = insert[i] {
                        next.append(mid)
                        nextCheck += [true, true]
                        if i < firstPoint { newFirst += 1 }
                    } else {
                        nextCheck.append(false)
                    }
                }
                run = next
                check = nextCheck
                firstPoint = newFirst
            }
            if strokes[k].lead != nil {
                strokes[k].lead = Array(run[..<firstPoint])
                strokes[k].points = Array(run[firstPoint...])
            } else {
                strokes[k].points = run
            }
        }
    }

    // MARK: Checks

    /// Whether the models fit the blank (or what a rounding leaves of it) and are on it.
    static func fitWarnings(_ models: [DesignShape], blank: RotaryStock, stockRadius: (Double) -> Double, range: ClosedRange<Double>,
                            context ctx: GenerationContext) -> [String] {
        let len = ctx.length
        var out: [String] = []
        for m in models {
            guard let e = m.rotaryExtent, let spec = m.modelSpec else { continue }
            if e.minX < -1e-6 || e.maxX > blank.length + 1e-6 {
                out.append("The model “\(m.name)” runs past the end of the blank (it's \(len(e.maxX - e.minX)) long, the blank "
                    + "\(len(blank.length))). Move it along the blank or scale it down.")
            }
            // The farthest the model reaches against the round stock there, along its length.
            let mesh = spec.alongAxis
            var excess = 0.0
            for i in 0..<RotaryMesh.slices {
                let local = (Double(i) + 0.5) / Double(RotaryMesh.slices) * Double(mesh.length) - Double(mesh.length) / 2
                let x = m.position.x + local * m.scale
                guard x >= 0, x <= blank.length else { continue }
                let r = mesh.profileRadius(at: local) * m.scale
                excess = max(excess, r - min(stockRadius(x), blank.radius))
            }
            if excess > 0.01 {
                out.append("The model “\(m.name)” is up to \(len(2 * excess)) bigger across than the stock it's cut from "
                    + "(\(len(2 * e.radius)) across at most): where it's bigger, the part comes out the stock's size. "
                    + "Scale it to fit the blank.")
            }
        }
        return out
    }

    /// Where the model's surface is hidden from a tool coming in toward the axis: rays from the axis that cross the
    /// surface more than once (undercuts), or twice (the axis isn't inside the model there).
    static func reachWarnings(_ triangles: [Double], range: ClosedRange<Double>, context ctx: GenerationContext) -> [String] {
        guard let probe = RotaryDropCutter(probe: triangles, angleBins: 360) else { return [] }
        let stations = 200, angles = 180
        let lo = max(range.lowerBound, probe.minX), hi = min(range.upperBound, probe.maxX)
        guard hi > lo else { return [] }
        let counts = ParallelResults<Int>(count: stations * angles, initial: 0)
        RotaryDropCutter.concurrently(stations * angles, chunk: 64) { r in
            for i in r {
                let x = lo + (hi - lo) * (Double(i / angles) + 0.5) / Double(stations)
                let a = -Double.pi + 2 * .pi * (Double(i % angles) + 0.5) / Double(angles)
                counts[i] = probe.crossings(x: x, angle: a).count
            }
        }
        let all = counts.array
        var hidden = 0, outside = 0
        var first: Double?, lastX = 0.0
        for i in all.indices where all[i] >= 2 {
            if all[i] == 2 { outside += 1 } else { hidden += 1 }
            let x = lo + (hi - lo) * (Double(i / angles) + 0.5) / Double(stations)
            first = min(first ?? x, x)
            lastX = max(lastX, x)
        }
        guard let from = first else { return [] }
        let u = ctx.units
        let share = Double(hidden + outside) / Double(all.count) * 100
        let percent = share < 1 ? "under 1" : "\(Int(share.rounded()))"
        let where_ = "between X \(u.format(from)) and \(u.format(lastX)) \(u.symbol)"
        if hidden >= outside {
            return ["Parts of the model are hidden from the tool behind other parts of it (undercuts a tool pointing at the axis "
                + "can't reach), \(where_): about \(percent)% of the directions round it. The finish leaves them as the tool's shadow."]
        }
        return ["The rotation axis isn't inside the model everywhere \(where_) (about \(percent)% of the directions round it): check "
            + "which of the model's axes lies along the blank, or that it's a closed solid."]
    }
}

/// The rotary blank with its 3D models on it, for showing before anything is cut: a radial grid like the
/// simulation's (`RadialGrid`), each ray out to the farthest the models reach along it, or the blank's own surface
/// where no model is.
public enum RotaryModelPreview {
    public static func surface(_ project: Project, maxCells: Int = 400_000) -> RadialGrid? {
        guard project.stock.rotary != nil else { return nil }
        let models = project.shapes.filter { $0.modelSpec?.rotary != nil && !$0.isKeepOut }
        guard !models.isEmpty else { return nil }
        var triangles: [Double] = []
        for m in models {
            m.forEachBlankTriangle { a, b, c in triangles.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]) }
        }
        guard let probe = RotaryDropCutter(probe: triangles, angleBins: 360) else { return nil }
        var g = RadialGrid(stock: project.stock, cellSize: nil, maxCells: maxCells)
        let cols = g.columns, rows = g.rows
        let out = ParallelResults<Float>(count: cols * rows, initial: .nan)
        let grid = g
        RotaryDropCutter.concurrently(cols * rows, chunk: 512) { range in
            for i in range {
                let x = grid.originX + Double(i % cols) * grid.cellSize
                guard x >= probe.minX, x <= probe.maxX, let r = probe.crossings(x: x, angle: grid.angle(row: i / cols)).outer else { continue }
                out[i] = Float(r)
            }
        }
        let hits = out.array
        for i in hits.indices where !hits[i].isNaN { g.radii[i] = hits[i] }
        return g
    }
}
