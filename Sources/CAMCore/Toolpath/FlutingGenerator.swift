import Foundation

/// Fluting: the bit follows each vector from its start point, its depth ramping down from the start depth to the
/// flute depth and back up again as `FlutingParams.depth(at:fluteLength:)` gives (Vectric's Fluting toolpath). Open
/// and closed vectors both work; a closed one is cut round from its first point. A flute that's the same both ways
/// (ramps at both ends, or none) may start from whichever end of its vector is nearer.
///
/// Passes: no pass cuts more than the pass depth deeper than the one before. Each follows the whole flute with its
/// depths scaled to the pass (its ramps graduated, as Vectric puts it), so the last pass runs the full length and
/// leaves an even finish. A flute that's the same both ways is cut back and forth; otherwise each pass starts again
/// from the flute's start.
///
/// On a wrapped rotary job the flutes are cut on the unrolled sheet and wrapped round the blank like any other
/// toolpath (`RotaryWrap`): a line along X becomes a flute along a column.
enum FlutingGenerator {
    /// How closely a smooth ramp is sampled along the flute, mm.
    static let smoothSpacing = 0.5

    static func generate(op: CAMOperation, params: FlutingParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        if !FlutingParams.suits(tool.shape) {
            warnings.append("Fluting is meant for a ball nose, core box or V-bit; '\(tool.name)' is a \(tool.shape.label), so the "
                + "flutes come out square-bottomed.")
        }
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        let polys = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
            .filter { ($0.isClosed && $0.count >= 3) || (!$0.isClosed && $0.count >= 2) }
            .filter { $0.length > 1e-6 }
        guard !polys.isEmpty, params.depth > 1e-6 else {
            warnings.append(polys.isEmpty ? "Fluting needs vectors to follow; none were selected." : "The flute depth must be more than 0.")
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        if tool.shape.isTapered, params.startDepth + params.depth > min(tool.taperHeight, tool.fluteLength) + 1e-6 {
            warnings.append("The flutes are \(context.length(params.startDepth + params.depth)) deep, deeper than '\(tool.name)''s "
                + "V (\(context.length(min(tool.taperHeight, tool.fluteLength)))), so their sides come out as steps.")
        }
        let step = max(0.05, params.passDepth ?? tool.cutting.stepdown)
        let passes = max(1, Int((params.depth / step - 1e-9).rounded(.up)))
        let symmetric = params.ramp == .both || params.ramp == .none
        let simplifyTol = min(0.01, context.arcTolerance * 2)
        for (i, reversed) in order(polys, symmetric: symmetric, passes: passes, from: context.stock.homePosition.xy) {
            let samples = Self.samples(reversed ? polys[i].reversed : polys[i], params: params)
            for k in 1...passes {
                let scale = Double(k) / Double(passes)
                var pts = samples.map { Vec3($0.point, -(params.startDepth + scale * $0.depth)) }
                if symmetric && !polys[i].isClosed && k % 2 == 0 { pts.reverse() }
                pts = simplify3D(pts, tolerance: simplifyTol)
                b.enter(at: pts[0])
                b.follow(Array(pts.dropFirst()))
            }
            b.retract()
        }
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }

    /// The order the flutes are cut in, and which are cut from their far end. A flute that ramps at one end only keeps
    /// its direction (its start point sets which end ramps), so only the order changes. One that's the same both ways
    /// may be cut from whichever end is nearer, nearest first; after an odd number of back-and-forth passes the tool is
    /// at its other end.
    static func order(_ polys: [Polyline], symmetric: Bool, passes: Int, from origin: Vec2) -> [(index: Int, reversed: Bool)] {
        func ends(_ line: Polyline) -> (first: Vec2, last: Vec2) {
            (line.points[0], line.isClosed ? line.points[0] : line.points[line.count - 1])
        }
        guard symmetric else {
            return TourOptimizer.order(count: polys.count, from: origin, start: { ends(polys[$0]).first },
                                       end: { ends(polys[$0]).last }).map { ($0, false) }
        }
        var remaining = Array(polys.indices)
        var out: [(index: Int, reversed: Bool)] = []
        var cursor = origin
        while !remaining.isEmpty {
            var best = (k: 0, reversed: false, d: Double.infinity)
            for (k, i) in remaining.enumerated() {
                let (first, last) = ends(polys[i])
                if first.distanceSquared(to: cursor) < best.d { best = (k, false, first.distanceSquared(to: cursor)) }
                if !polys[i].isClosed, last.distanceSquared(to: cursor) < best.d { best = (k, true, last.distanceSquared(to: cursor)) }
            }
            let i = remaining.remove(at: best.k)
            out.append((i, best.reversed))
            let (first, last) = ends(polys[i])
            let start = best.reversed ? last : first, far = best.reversed ? first : last
            cursor = passes % 2 == 1 ? far : start
        }
        return out
    }

    /// Points along a flute with its full depth below the start depth at each: the vector's vertices, where each ramp
    /// ends, and along a smooth ramp every `smoothSpacing`. A closed vector ends back at its first point.
    static func samples(_ line: Polyline, params: FlutingParams) -> [(point: Vec2, depth: Double)] {
        var pts = line.points
        if line.isClosed { pts.append(pts[0]) }
        var arc = [0.0]
        for (a, c) in zip(pts, pts.dropFirst()) { arc.append(arc[arc.count - 1] + a.distance(to: c)) }
        let length = arc[arc.count - 1]
        let ramp = params.rampLength(onFluteOf: length)
        var stations = Set(arc)
        if ramp > 1e-9 {
            let starts = params.ramp == .both || params.ramp == .start
            let ends = params.ramp == .both || params.ramp == .end
            if starts { stations.insert(ramp) }
            if ends { stations.insert(length - ramp) }
            if params.rampShape == .smooth {
                let n = max(16, Int((ramp / smoothSpacing).rounded(.up)))
                for j in 1..<n {
                    let s = ramp * Double(j) / Double(n)
                    if starts { stations.insert(s) }
                    if ends { stations.insert(length - s) }
                }
            }
        }
        var out: [(point: Vec2, depth: Double)] = []
        var seg = 0
        for s in stations.filter({ $0 >= -1e-9 && $0 <= length + 1e-9 }).sorted() {
            while seg < pts.count - 2, arc[seg + 1] < s { seg += 1 }
            let span = arc[seg + 1] - arc[seg]
            let p = span > 1e-12 ? pts[seg].lerp(to: pts[seg + 1], (s - arc[seg]) / span) : pts[seg]
            if let last = out.last, last.point.distance(to: p) < 1e-9 { continue }
            out.append((p, params.depth(at: s, fluteLength: length)))
        }
        return out
    }
}
