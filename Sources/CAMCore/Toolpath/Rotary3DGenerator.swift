import Foundation

/// 3D rotary finishing (research_notes/Rotary milling/rotary_milling.md §2.2–2.3): a radial tool follows a 3D model
/// laid along the rotation axis, all the way round it, as the blank turns.
///
/// The tool's tip radius at every point of the path comes from the exact rotary drop-cutter (`RotaryDropCutter`), so
/// the path never cuts into the model at its points; between them, a segment whose middle would dip more than the
/// tolerance below the model's is split. Every bit leaves the allowance square to the model's surface (a flat end mill
/// is dropped grown by it all round, as `Rotary3DRoughing` drops its tool), so beside a shoulder as well as on top of
/// it. Patterns (`RotaryFinishParams.Pattern`):
/// - **Spiral**: a full turn at the start, one continuous helix along the blank advancing a stepover per turn, and a
///   full turn at the end. A is never wound back, so there's no seam.
/// - **Rings**: a full turn at one station, a step along the blank following the surface, the next turn.
/// - **Along X**: zig-zag passes along the blank at fixed angles, turning between them along the surface by
///   Δθ = stepover ÷ the model's largest radius.
///
/// A flat bottom can't roll up onto a shoulder as a ball nose does, so with one, spirals and rings add a turn at the
/// foot of each shoulder (`fillShoulders`); along X, the passes meet the shoulder along their way.
///
/// Where the model is deeper below the stock than the pass depth, layers cut down to it first (a clamped stack, §2.4
/// "Approach A"): each layer runs the same pattern at the layers' stepover with the tool no closer to the axis than the
/// layer's radius, and leaves out what it would only cut air on. The finish then follows the model everywhere. After a
/// 3D rotary roughing (`Rotary3DRoughing`) it starts from what that left, and needs no layers unless some of it is
/// thicker than the pass depth.
///
/// Cut direction (`RotaryFinishParams.directionInUse`), judged on the unrolled blank (`PassDirection`): turning
/// forward, a spiral or rings that step +X along the blank climb, and coming back −X go conventional; lines along X,
/// stepping round the blank, climb travelling −X. Both ways, the layers and the finish alternate along the blank and
/// lines zig-zag, as they always have; climbing or conventional, every pass starts from the same end (back along the
/// blank at safe Z between them) and every line runs the same way.
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
        let roughed = ctx.rotaryMaterial
        /// The material before this toolpath at station x and angle a: the blank, or what a rounding or a 3D rotary
        /// roughing left of it.
        func material(_ x: Double, _ a: Double) -> Double {
            min(stockRadius(x), blank.surfaceRadius(atDegrees: a * 180 / .pi), roughed?(x, a, 0) ?? .infinity)
        }
        /// The most material under the tool's footprint at station x and angle a, along its axis: where a rapid down to
        /// it has to stop (a square bar's corner, or the end of a rounding, can be under the edge of the tool).
        func highest(_ x: Double, _ a: Double) -> Double {
            let r = tool.radius
            var round = 0.0
            for i in 0...8 { round = max(round, stockRadius(x - r + 2 * r * Double(i) / 8)) }
            let surface = highestOfBlank(blank, angle: a, reach: r)
            return min(round, surface, roughed?(x, a, r) ?? .infinity)
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
        let probeTips = cutter.tipRadii(probes)
        guard let deepest = probeTips.filter(\.isFinite).min().map({ max(0, $0) }) else {
            tp.warnings = warnings + ["None of the model is within reach between the finish's start and end."]
            return tp
        }
        let pass = p.passDepth(tool)
        var stockTop = 0.0
        for i in 0...64 { stockTop = max(stockTop, stockRadius(x0 + length * Double(i) / 64)) }
        stockTop = min(stockTop, blank.outerRadius)
        var layerCount = max(0, Int(((stockTop - deepest) / pass - 1e-6).rounded(.up)) - 1)
        if roughed != nil {
            // After a 3D rotary roughing: layers only if what it left is anywhere thicker than a pass.
            var thickest = 0.0
            for (q, r) in zip(probes, probeTips) where r.isFinite { thickest = max(thickest, material(q.x, q.angle) - max(0, r)) }
            if thickest <= pass + 1e-6 { layerCount = 0 }
        }

        // A flat bottom can't roll up onto a shoulder: spirals and rings get a pass at the foot of each (`fillShoulders`).
        let flatBottom = Self.hasFlatBottom(tool) && p.pattern != .lines
        func drop(_ q: [(x: Double, angle: Double)]) -> [Double] {
            let r = cutter.tipRadii(q)
            return q.indices.map { r[$0].isFinite ? max(0, r[$0]) : material(q[$0].x, q[$0].angle) }
        }

        // The layers, then the finish, each pass the other way along the blank from the last (both ways), or each from
        // the same end: +X climbs, −X is conventional. Lines one way all run −X (climb) or +X.
        let direction = p.directionInUse
        let lineTravel: Double? = direction == .both ? nil : (direction == .climb ? -1 : 1)
        var passes: [(strokes: [Stroke], layer: Double?)] = []
        var forward = direction != .conventional
        for k in 0..<layerCount {
            let rho = stockTop - Double(k + 1) * pass
            let above = k == 0 ? Double.infinity : stockTop - Double(k) * pass
            let (a, b) = forward ? (x0, x1) : (x1, x0)
            var strokes = pattern(p.pattern, from: a, to: b, stepover: p.layerStepover(tool), perTurn: perTurn, spacing: spacing,
                                  outer: surfaceMax, lineTravel: lineTravel)
            evaluate(&strokes, cutter: cutter, material: material)
            if flatBottom { fillShoulders(&strokes, pattern: p.pattern, threshold: pass, floor: rho, spacing: spacing, drop: drop) }
            // Where this layer would only cut air (the model, or the layer before, is already there), leave it out.
            func cuts(_ q: Point) -> Bool { max(q.r, rho) < min(material(q.x, q.angle), max(q.r, above)) - 0.01 }
            strokes = trimmed(strokes, pattern: p.pattern, perTurn: perTurn, cuts: cuts)
            guard !strokes.isEmpty else { continue }
            for i in strokes.indices {
                for j in strokes[i].points.indices { strokes[i].points[j].r = max(strokes[i].points[j].r, rho) }
                if strokes[i].lead != nil { for j in strokes[i].lead!.indices { strokes[i].lead![j].r = max(strokes[i].lead![j].r, rho) } }
            }
            passes.append((strokes, rho))
            if direction == .both { forward.toggle() }
        }
        let lastLayer = passes.last?.layer
        var finish = pattern(p.pattern, from: forward ? x0 : x1, to: forward ? x1 : x0, stepover: stepover, perTurn: perTurn,
                             spacing: spacing, outer: surfaceMax, lineTravel: lineTravel)
        evaluate(&finish, cutter: cutter, material: material)
        if flatBottom { fillShoulders(&finish, pattern: p.pattern, threshold: pass, floor: nil, spacing: spacing, drop: drop) }
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

        // Lay the passes end to end, each turned by whole turns so that it starts at the first angle on from where the
        // last one ended (the first from A0): a layer trimmed to where it cuts can start several turns into its
        // pattern, and the blank turns at safe Z only as far as it must to get there, less than a turn.
        let feed = tool.cutting.feedRate
        let aMax = RotaryWrap.turnSpeed(ctx.machine)
        func sheet(_ q: Point, _ offset: Double) -> Vec3 { Vec3(q.x, cy + (q.angle + offset) * top, q.r - top) }
        var motions: [Motion] = []
        var offset = 0.0
        var last: (point: Point, offset: Double, pass: Int)?
        var slowest = feed, slowestRadius = Double.infinity
        for (n, pass) in passes.enumerated() {
            if let first = pass.strokes.first?.points.first {
                offset = Self.nextTurn(from: last.map { $0.point.angle + $0.offset } ?? 0, to: first.angle)
                if n == 0 { tp.start = Vec3(first.x, cy + (first.angle + offset) * top, clearance) }
            }
            for stroke in pass.strokes {
                guard let first = stroke.points.first else { continue }
                var run: [Point] = []
                if let lead = stroke.lead, let l = last, l.pass == n {
                    run = lead + stroke.points
                } else {
                    // From safe Z: up, across (the blank turns here, clear of it), down to just above the stock, plunge.
                    if let l = last { motions.append(.rapid(Vec3(l.point.x, cy + (l.point.angle + l.offset) * top, clearance))) }
                    let over = sheet(first, offset)
                    motions.append(.rapid(Vec3(over.x, over.y, clearance)))
                    let plunge = highest(first.x, first.angle) + stock.plungeHeight - top
                    if plunge < clearance - 1e-9, plunge > over.z { motions.append(.rapid(Vec3(over.x, over.y, plunge))) }
                    motions.append(.feed(over, tool.cutting.plungeRate))
                    run = Array(stroke.points.dropFirst())
                    last = (first, offset, n)
                }
                for q in run {
                    motions.append(.feed(sheet(q, offset), feed))
                    last = (q, offset, n)
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
        if blank.shape == .squareBar, ctx.rotaryStockRadius == nil, roughed == nil {
            warnings.append("Starts from a square bar: add a Rounding toolpath before it, or the first layers cut the corners in "
                + "interrupted passes.")
        }
        warnings += reachWarnings(triangles, range: x0...x1, context: ctx)
        tp.warnings = warnings
        return tp
    }

    /// The whole turns (radians, a multiple of 2π) to add to a pass whose first point is at `angle` so that it starts at
    /// the first angle on from `after`, where the blank is: never behind it, and less than a turn ahead, so the blank
    /// keeps turning one way and turns at safe Z no further than it must.
    static func nextTurn(from after: Double, to angle: Double) -> Double {
        ((after - angle) / (2 * .pi) - 1e-9).rounded(.up) * 2 * .pi
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
    /// `lineTravel` (lines): every line runs that way along X (+1 or −1), each from safe Z, instead of zig-zag.
    static func pattern(_ kind: RotaryFinishParams.Pattern, from a: Double, to b: Double, stepover s: Double, perTurn n: Int,
                        spacing h: Double, outer: Double, lineTravel: Double? = nil) -> [Stroke] {
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
                var (p, q) = j % 2 == 0 ? (a, b) : (b, a)
                if let travel = lineTravel { (p, q) = travel > 0 ? (min(a, b), max(a, b)) : (max(a, b), min(a, b)) }
                let line = (0...m).map { Point(x: p + (q - p) * Double($0) / Double(m), angle: angle) }
                var lead: [Point]?
                if j > 0, lineTravel == nil {
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

    // MARK: Shoulders

    /// Whether `tool` has a flat bottom, which can't roll up onto a shoulder the way a ball or a bull nose does: flat end
    /// mills and surfacing bits, and any bit followed as a flat end mill because its profile can't be.
    static func hasFlatBottom(_ tool: Tool) -> Bool {
        switch tool.shape {
        case .flatEndMill, .surfacing: return true
        case .ballNose, .bullNose: return false
        default: return CutterProfile(tool: tool) == nil
        }
    }

    /// Adds a pass at the foot of each shoulder that a flat bottom would otherwise leave a band beside (#72). Its tip
    /// jumps from the low side of a shoulder to the top at one station, and a spiral passes each angle once a turn
    /// (rings, once a ring), so the last pass on the low side can stop up to a stepover short of the jump, leaving a band
    /// that wide standing at the shoulder's foot. Wherever a point's tip radius (no lower than `floor`) differs by more
    /// than `threshold` from the next turn's or ring's at the same angle, the station where it jumps is found by
    /// bisection along the blank, and a turn is added there, on the low side of the jump, before the pattern goes on to
    /// the next turn (and climbs, or comes down). Angles where nothing jumps follow the turn before again. Everything
    /// after it is turned a whole turn on, so A still only ever increases. `drop` gives the tool's tip radius at
    /// stations and angles; every point added is dropped there.
    static func fillShoulders(_ strokes: inout [Stroke], pattern: RotaryFinishParams.Pattern, threshold: Double, floor: Double?,
                              spacing h: Double, drop: ([(x: Double, angle: Double)]) -> [Double]) {
        func clamp(_ r: Double) -> Double { floor.map { max(r, $0) } ?? r }
        /// Where the tip ends on the low side of a jump between a point (station `x`, `angle`, tip radius `r`) and the
        /// next pass at that angle (at station `nextX`, with tip radius `nextR`): the station and the tip radius there,
        /// or nil when the two don't differ by more than the threshold.
        func feet(_ pairs: [(x: Double, angle: Double, r: Double, nextX: Double, nextR: Double)]) -> [(x: Double, r: Double)?] {
            var open: [Int] = [], lo: [Double] = [], hi: [Double] = [], limit: [Double] = []
            for (i, q) in pairs.enumerated() {
                let a = clamp(q.r), b = clamp(q.nextR)
                guard abs(a - b) > threshold else { continue }
                open.append(i)
                lo.append(a <= b ? q.x : q.nextX)
                hi.append(a <= b ? q.nextX : q.x)
                limit.append(min(a, b) + threshold)
            }
            guard !open.isEmpty else { return pairs.map { _ in nil } }
            // Twelve halvings: within a 4,096th of the step along the blank.
            for _ in 0..<12 {
                let r = drop(open.indices.map { ((lo[$0] + hi[$0]) / 2, pairs[open[$0]].angle) })
                for k in open.indices {
                    let mid = (lo[k] + hi[k]) / 2
                    if clamp(r[k]) > limit[k] { hi[k] = mid } else { lo[k] = mid }
                }
            }
            let r = drop(open.indices.map { (lo[$0], pairs[open[$0]].angle) })
            var out: [(x: Double, r: Double)?] = pairs.map { _ in nil }
            for k in open.indices { out[open[k]] = (lo[k], r[k]) }
            return out
        }
        /// Points between `a` and `b` (both left out) no more than the sample spacing apart along the blank, dropped.
        func between(_ a: Point, _ b: Point) -> [Point] {
            let m = Int((abs(b.x - a.x) / h).rounded(.up))
            guard m > 1 else { return [] }
            var pts = (1..<m).map { Point(x: a.x + (b.x - a.x) * Double($0) / Double(m), angle: a.angle + (b.angle - a.angle) * Double($0) / Double(m)) }
            let r = drop(pts.map { ($0.x, $0.angle) })
            for i in pts.indices { pts[i].r = r[i] }
            return pts
        }

        switch pattern {
        case .lines:
            return
        case .spiral:
            guard let pts = strokes.first?.points, pts.count > 2 else { return }
            var step = 0.0
            for (a, b) in zip(pts, pts.dropFirst()) { step = max(step, b.angle - a.angle) }
            // Each point and the next turn's point nearest its angle, where they differ by more than the threshold.
            var pairs: [(x: Double, angle: Double, r: Double, nextX: Double, nextR: Double)] = []
            var index: [Int] = []
            var j = 0
            for (i, q) in pts.enumerated() {
                let target = q.angle + 2 * .pi
                while j + 1 < pts.count, pts[j + 1].angle <= target { j += 1 }
                var k = j
                if k + 1 < pts.count, abs(pts[k + 1].angle - target) < abs(pts[k].angle - target) { k += 1 }
                guard abs(pts[k].angle - target) <= step + 1e-9 else { continue }
                guard abs(clamp(q.r) - clamp(pts[k].r)) > threshold else { continue }
                pairs.append((q.x, q.angle, q.r, pts[k].x, pts[k].r))
                index.append(i)
            }
            var foot: [Int: (x: Double, r: Double)] = [:]
            for (n, f) in feet(pairs).enumerated() { if let f { foot[index[n]] = f } }
            guard !foot.isEmpty else { return }
            // A turn at a time (and a step or two over, for the angles' rounding): each is cut again at the foot after
            // its last point, where the spiral itself jumps.
            let flagged = foot.keys.sorted()
            var ends: [Int] = []
            var c = 0
            while c < flagged.count {
                let first = pts[flagged[c]].angle
                var e = c
                while e + 1 < flagged.count, pts[flagged[e + 1]].angle < first + 2 * .pi + 2 * step { e += 1 }
                ends.append(flagged[e])
                c = e + 1
            }
            var out: [Point] = []
            var shift = 0.0, from = 0
            for end in ends {
                out += pts[from...end].map { Point(x: $0.x, angle: $0.angle + shift, r: $0.r) }
                var k = end
                while k > 0, pts[k - 1].angle > pts[end].angle - 2 * .pi + 1e-9 { k -= 1 }
                let turn = (k...end).map { i in
                    Point(x: foot[i]?.x ?? pts[i].x, angle: pts[i].angle + 2 * .pi + shift, r: foot[i]?.r ?? pts[i].r)
                }
                out += between(out[out.count - 1], turn[0]) + turn
                shift += 2 * .pi
                if end + 1 < pts.count {
                    let next = pts[end + 1]
                    out += between(turn[turn.count - 1], Point(x: next.x, angle: next.angle + shift))
                }
                from = end + 1
            }
            if from < pts.count { out += pts[from...].map { Point(x: $0.x, angle: $0.angle + shift, r: $0.r) } }
            strokes[0].points = out
        case .rings:
            var out: [Stroke] = []
            var shift = 0.0
            var after: Point?
            for (k, ring) in strokes.enumerated() {
                var this = ring
                for i in this.points.indices { this.points[i].angle += shift }
                if let lead = this.lead {
                    // After a ring at a foot: the step along the blank to this ring starts from that one's end.
                    if let from = after, let to = this.points.first {
                        this.lead = between(Point(x: from.x, angle: to.angle), to)
                    } else {
                        this.lead = lead.map { Point(x: $0.x, angle: $0.angle + shift, r: $0.r) }
                    }
                }
                out.append(this)
                after = nil
                guard k + 1 < strokes.count, strokes[k + 1].points.count == ring.points.count,
                      let x = ring.points.first?.x, let nextX = strokes[k + 1].points.first?.x else { continue }
                let next = strokes[k + 1].points
                let found = feet(ring.points.indices.map { (x, ring.points[$0].angle, ring.points[$0].r, nextX, next[$0].r) })
                guard found.contains(where: { $0 != nil }) else { continue }
                // A ring at the foot, turning from where the next ring would have started.
                let base = next[0].angle + shift
                let turn = ring.points.indices.map { i in
                    Point(x: found[i]?.x ?? x, angle: base + ring.points[i].angle - ring.points[0].angle, r: found[i]?.r ?? ring.points[i].r)
                }
                out.append(Stroke(points: turn, lead: between(Point(x: x, angle: base), turn[0])))
                after = turn[turn.count - 1]
                shift += 2 * .pi
            }
            strokes = out
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
    /// the tool has to be there, up to four times over. A stroke with a lead is cut straight on from the one before, so
    /// the move from that one's last point to its first is checked too: a ring's step along the blank can meet a
    /// shoulder there.
    static func refine(_ strokes: inout [Stroke], cutter: RotaryDropCutter, material: (Double, Double) -> Double,
                       floor: Double?, tolerance: Double) {
        for k in strokes.indices {
            let joined = strokes[k].lead != nil && k > 0 ? strokes[k - 1].points.last : nil
            let skip = joined == nil ? 0 : 1
            var run = (joined.map { [$0] } ?? []) + (strokes[k].lead ?? []) + strokes[k].points
            let leadCount = skip + (strokes[k].lead?.count ?? 0)
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
                strokes[k].lead = Array(run[skip..<firstPoint])
                strokes[k].points = Array(run[firstPoint...])
            } else {
                strokes[k].points = run
            }
        }
    }

    /// The most of the blank's own section under a tool pointed at the axis at `angle` (radians), reaching `reach`
    /// either side of its axis, measured along that axis (mm): the radius on a round blank; on a square bar the highest
    /// of its faces and corners within the footprint (a face's highest point is at the footprint's edge, or a corner).
    static func highestOfBlank(_ blank: RotaryStock, angle a: Double, reach: Double) -> Double {
        guard blank.shape == .squareBar else { return blank.radius }
        // In the section, along the tool's axis (height) and across it (lateral).
        let corner = blank.outerRadius
        func local(_ phi: Double) -> (l: Double, h: Double) { (corner * sin(phi - a), corner * cos(phi - a)) }
        var most = 0.0
        for k in 0..<4 {
            let p = local(.pi / 4 + Double(k) * .pi / 2), q = local(.pi / 4 + Double(k + 1) * .pi / 2)
            // The part of this face within the footprint, |l| ≤ reach; the height is linear along it.
            var s0 = 0.0, s1 = 1.0
            let dl = q.l - p.l
            if abs(dl) < 1e-12 {
                guard abs(p.l) <= reach else { continue }
            } else {
                let a0 = (-reach - p.l) / dl, a1 = (reach - p.l) / dl
                s0 = max(s0, min(a0, a1))
                s1 = min(s1, max(a0, a1))
                guard s0 <= s1 else { continue }
            }
            most = max(most, p.h + (q.h - p.h) * s0, p.h + (q.h - p.h) * s1)
        }
        return most
    }

    // MARK: Checks

    /// Whether the models fit the blank (or what a rounding leaves of it) and are on it.
    static func fitWarnings(_ models: [DesignShape], blank: RotaryStock, stockRadius: (Double) -> Double, range: ClosedRange<Double>,
                            context ctx: GenerationContext) -> [String] {
        let len = ctx.length
        var out: [String] = []
        for m in models {
            guard let e = m.rotaryExtent else { continue }
            if e.minX < -1e-6 || e.maxX > blank.length + 1e-6 {
                out.append("The model “\(m.name)” runs past the end of the blank (it's \(len(e.maxX - e.minX)) long, the blank "
                    + "\(len(blank.length))). Move it along the blank or scale it down.")
            }
            // The farthest the model reaches past the stock there, in the direction it reaches: on a round blank its
            // radius against the stock's, on a square bar against the bar's faces and corners. The stock's section is
            // convex, so the model is inside it wherever its corners are.
            var excess = 0.0
            m.forEachBlankTriangle { a, b, c in
                for v in [a, b, c] where v.x >= 0 && v.x <= blank.length {
                    let r = (v.y * v.y + v.z * v.z).squareRoot()
                    guard r > 1e-9 else { continue }
                    let surface = blank.surfaceRadius(atDegrees: atan2(v.y, v.z) * 180 / .pi)
                    excess = max(excess, r - min(stockRadius(v.x), surface))
                }
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
