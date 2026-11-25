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
///
/// Following a 3D model (`FlutingParams.surfaceModelID`), each flute's depth is measured down from the model's surface
/// under it instead of from the start depth: the bit is dropped onto the model with the exact drop-cutter at closely
/// spaced stations (`onSurface`), so the flute keeps its depth into a curved surface and its ramps follow the surface. On
/// a wrapped rotary job the rotary drop-cutter does the same on the model laid along the axis, for fluting a turning
/// after its 3D rotary finish. Where a vector runs off the model the flute is cut only where the bit's centre is over
/// the model's footprint (and the bit reaches it), so its ramps start and end on the model: a ball centred past the
/// model's end would touch its top edge with its side and slide down the end wall, notching the stock beyond (#138).
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
        // Following a model, the model itself (when it's among the selected shapes) isn't a flute.
        let vectors = params.surfaceModelID == nil ? shapes : shapes.filter { $0.modelSpec == nil }
        let polys = vectors.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
            .filter { ($0.isClosed && $0.count >= 3) || (!$0.isClosed && $0.count >= 2) }
            .filter { $0.length > 1e-6 }
        guard !polys.isEmpty, params.depth > 1e-6 else {
            warnings.append(polys.isEmpty ? "Fluting needs vectors to follow; none were selected." : "The flute depth must be more than 0.")
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        let measured = params.surfaceModelID == nil ? params.startDepth + params.depth : params.depth
        if tool.shape.isTapered, measured > min(tool.taperHeight, tool.fluteLength) + 1e-6 {
            warnings.append("The flutes are \(context.length(measured)) deep, deeper than '\(tool.name)''s "
                + "V (\(context.length(min(tool.taperHeight, tool.fluteLength)))), so their sides come out as steps.")
        }
        let step = max(0.05, params.passDepth ?? tool.cutting.stepdown)
        let passes = max(1, Int((params.depth / step - 1e-9).rounded(.up)))
        let symmetric = params.ramp == .both || params.ramp == .none
        if let modelID = params.surfaceModelID {
            let surface: Surface
            switch Surface.make(modelID: modelID, tool: tool, project: context.project, stock: context.stock) {
            case let .failure(refusal):
                return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings + [refusal.message])
            case let .success(s): surface = s
            }
            var trimmed = 0, missed = 0
            for (i, reversed) in order(polys, symmetric: symmetric, passes: passes, from: context.stock.homePosition.xy) {
                let flute = onSurface(reversed ? polys[i].reversed : polys[i], surface: surface, params: params, passes: passes,
                                      tolerance: min(0.01, context.arcTolerance * 2))
                if flute.pieces.isEmpty { missed += 1 } else if flute.trimmed { trimmed += 1 }
                for piece in flute.pieces {
                    for (k, pass) in piece.passes.enumerated() {
                        let pts = symmetric && !piece.closed && k % 2 == 1 ? pass.reversed() : pass
                        b.enter(at: pts[0])
                        b.follow(Array(pts.dropFirst()))
                    }
                    b.retract()
                }
            }
            if missed > 0 {
                warnings.append("\(missed == 1 ? "A flute isn't" : "\(missed) flutes aren't") over the 3D model '\(surface.name)', "
                    + "so \(missed == 1 ? "it isn't" : "they aren't") cut. Move \(missed == 1 ? "it" : "them") onto the model.")
            }
            if trimmed > 0 {
                warnings.append("\(trimmed == 1 ? "A flute runs" : "\(trimmed) flutes run") off the edge of the 3D model "
                    + "'\(surface.name)'. \(trimmed == 1 ? "It's" : "They're") cut only where the bit is over the model, ramping "
                    + "at its edge.")
            }
            return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
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

    // MARK: Following a 3D model

    /// Why flutes can't follow the model they're set to.
    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The surface of the 3D model flutes follow: the tool-tip height (sheet Z) at which the bit just touches the model,
    /// from the exact drop-cutter (`TriangleDropCutter`) on a flat job, or the rotary one (`RotaryDropCutter`) on a
    /// wrapped rotary job, where sheet Y is the angle round the blank and Z the distance out from the wrap radius.
    /// Probes with no width (`flatProbe`, `rotaryProbe`) say where the bit's centre is over the model's footprint.
    struct Surface: Sendable {
        let name: String
        let flat: TriangleDropCutter?
        let rotary: RotaryDropCutter?
        let flatProbe: TriangleDropCutter?
        let rotaryProbe: RotaryDropCutter?
        /// Wrapped jobs: the sheet's radius (its Z = 0) and the line across the sheet that's on top at A0.
        let top: Double, centreY: Double

        /// Tip Z at `p` on the sheet, or -infinity where the bit doesn't reach the model.
        func z(at p: Vec2, hint: inout Int32) -> Double {
            if let flat { return flat.z(at: p, hint: &hint) }
            guard let rotary else { return -.infinity }
            let r = rotary.tipRadius(x: p.x, angle: (p.y - centreY) / top, hint: &hint)
            return r.isFinite ? r - top : -.infinity
        }

        func z(at p: Vec2) -> Double {
            var hint: Int32 = -1
            return z(at: p, hint: &hint)
        }

        /// Whether `p` on the sheet is over the model's footprint: a vertical line through it (on a wrapped job, a ray
        /// from the axis) meets the model.
        func over(_ p: Vec2, hint: inout Int32) -> Bool {
            if let flatProbe { return flatProbe.z(at: p, hint: &hint).isFinite }
            guard let rotaryProbe else { return false }
            return rotaryProbe.tipRadius(x: p.x, angle: (p.y - centreY) / top, hint: &hint).isFinite
        }

        func over(_ p: Vec2) -> Bool {
            var hint: Int32 = -1
            return over(p, hint: &hint)
        }

        /// The surface of the model `modelID` in `project`, or why there's none to follow.
        static func make(modelID: UUID, tool: Tool, project: Project?, stock: Stock) -> Result<Surface, Refusal> {
            guard let model = project?.shapes.first(where: { $0.id == modelID && $0.modelSpec != nil && !$0.isKeepOut }) else {
                return .failure(Refusal(message: "The 3D model these flutes follow isn't in the job. Choose one under Follow, or "
                    + "follow the material top."))
            }
            if let blank = stock.rotary {
                guard blank.isWrapped else {
                    return .failure(Refusal(message: "Flutes can follow a 3D model on a flat job or a wrapped rotary job, not on "
                        + "a rotary job cut on faces. Follow the material top, or wrap the job."))
                }
                var triangles: [Double] = []
                model.forEachBlankTriangle { a, b, c in
                    triangles.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
                }
                guard let cutter = RotaryDropCutter(tool: tool, allowance: 0, triangles: triangles),
                      let probe = RotaryDropCutter(probe: triangles) else {
                    return .failure(Refusal(message: "The 3D model '\(model.name)' has no triangles to follow."))
                }
                return .success(Surface(name: model.name, flat: nil, rotary: cutter, flatProbe: nil, rotaryProbe: probe,
                                        top: blank.topRadius, centreY: stock.originPoint.y))
            }
            let triangles = Model3DGenerator.triangles(of: [model])
            guard let cutter = TriangleDropCutter(tool: tool, allowance: 0, triangles: triangles),
                  let probe = TriangleDropCutter(probe: triangles) else {
                return .failure(Refusal(message: "The 3D model '\(model.name)' has no triangles to follow."))
            }
            return .success(Surface(name: model.name, flat: cutter, rotary: nil, flatProbe: probe, rotaryProbe: nil, top: 0, centreY: 0))
        }
    }

    /// Spacing of the drop-cutter samples along a flute on a model, mm.
    static let surfaceSpacing = 0.2
    /// How far below the depth asked for a straight move between samples may dip before it's split, mm.
    static let sagTolerance = 0.0001

    /// A flute on a model: the pieces of its vector the bit reaches the model along, each with its passes (the points
    /// each feeds through). `trimmed` when some of the vector is off the model.
    struct FluteOnSurface {
        struct Piece {
            /// The whole of a closed vector, cut round from its start.
            var closed: Bool
            var passes: [[Vec3]]
        }
        var pieces: [Piece] = []
        var trimmed = false
    }

    /// A flute along `line` on `surface`: dropped at stations every `surfaceSpacing` (and at the vector's corners), cut
    /// into the pieces where the bit's centre is over the model's footprint and the bit reaches it, and each piece ramped as a flute of its own length, its depth
    /// below the surface (`FlutingParams.depth(at:fluteLength:)`) scaled to each pass. A move between stations is split
    /// until none dips more than `sagTolerance` below the depth asked for; then moves are merged only where the merged
    /// move stays between that depth and `tolerance` above it (`mergeAbove`). So no move goes deeper than the flute's
    /// depth below the surface.
    static func onSurface(_ line: Polyline, surface: Surface, params: FlutingParams, passes: Int, tolerance: Double) -> FluteOnSurface {
        var pts = line.points
        if line.isClosed { pts.append(pts[0]) }
        var arc = [0.0]
        for (a, c) in zip(pts, pts.dropFirst()) { arc.append(arc[arc.count - 1] + a.distance(to: c)) }
        let length = arc[arc.count - 1]
        guard length > 1e-9 else { return FluteOnSurface() }
        func point(_ s: Double) -> Vec2 {
            var lo = 0, hi = arc.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if arc[mid] <= s { lo = mid } else { hi = mid }
            }
            let span = arc[hi] - arc[lo]
            return span > 1e-12 ? pts[lo].lerp(to: pts[hi], min(1, max(0, (s - arc[lo]) / span))) : pts[lo]
        }
        var hint: Int32 = -1, probeHint: Int32 = -1
        func z(_ s: Double) -> Double { surface.z(at: point(s), hint: &hint) }
        /// Whether the bit is on the model at `s`: its centre over the footprint, and touching the model there. Past the
        /// footprint the drop-cutter still reaches the model's edge with the side of the ball, its tip below the edge.
        func on(_ s: Double) -> Bool { surface.over(point(s), hint: &probeHint) && z(s).isFinite }

        // Stations: the corners, and every `surfaceSpacing` along each segment between them.
        var stations: [Double] = []
        for k in 0..<(arc.count - 1) {
            let span = arc[k + 1] - arc[k]
            guard span > 1e-9 else { continue }
            let n = max(1, Int((span / surfaceSpacing).rounded(.up)))
            for j in 0..<n { stations.append(arc[k] + span * Double(j) / Double(n)) }
        }
        stations.append(length)
        let onModel = stations.map(on)

        // The spans over the model, their ends found to within 0.005 mm of where the bit stops being on it (and on its
        // side of that, so a flute never starts or ends with its centre past the model's footprint).
        func edge(inside: Double, outside: Double) -> Double {
            var a = inside, b = outside
            while abs(b - a) > 0.005 {
                let m = (a + b) / 2
                if on(m) { a = m } else { b = m }
            }
            return a
        }
        var spans: [(start: Double, end: Double)] = []
        var i = 0
        while i < stations.count {
            guard onModel[i] else { i += 1; continue }
            var j = i
            while j + 1 < stations.count, onModel[j + 1] { j += 1 }
            let a = i > 0 ? edge(inside: stations[i], outside: stations[i - 1]) : stations[i]
            let b = j + 1 < stations.count ? edge(inside: stations[j], outside: stations[j + 1]) : stations[j]
            if b - a > 1e-3 { spans.append((a, b)) }
            i = j + 1
        }
        var out = FluteOnSurface()
        let whole = spans.count == 1 && spans[0].start < 1e-9 && spans[0].end > length - 1e-9
        out.trimmed = !whole && !spans.isEmpty
        // A closed vector that's off the model somewhere is cut as open pieces, the one across its start in one piece.
        if line.isClosed, spans.count >= 2, spans[0].start < 1e-9, spans[spans.count - 1].end > length - 1e-9 {
            let last = spans.removeLast()
            spans[0] = (last.start - length, spans[0].end)
        }
        let scales = (1...passes).map { Double($0) / Double(passes) }
        for (a, b) in spans {
            let L = b - a
            /// Distance along the vector of the point `t` along the piece.
            func along(_ t: Double) -> Double {
                let s = a + t
                return s < 0 ? s + length : s
            }
            /// Distance along the piece of the point `s` along the vector.
            func into(_ s: Double) -> Double { a < 0 && s > length + a - 1e-12 ? s - length - a : s - a }
            var ts: Set<Double> = [0, L]
            var corners: Set<Double> = []
            for s in stations {
                let t = into(s)
                if t > 1e-9 && t < L - 1e-9 { ts.insert(t) }
            }
            for s in arc {
                let t = into(s)
                if t > 1e-9 && t < L - 1e-9 { ts.insert(t); corners.insert(t) }
            }
            let ramp = params.rampLength(onFluteOf: L)
            if ramp > 1e-9 {
                if params.ramp == .both || params.ramp == .start { ts.insert(min(L, ramp)) }
                if params.ramp == .both || params.ramp == .end { ts.insert(max(0, L - ramp)) }
                if params.rampShape == .smooth {
                    let n = max(16, Int((ramp / smoothSpacing).rounded(.up)))
                    for j in 1..<n {
                        let t = ramp * Double(j) / Double(n)
                        if params.ramp == .both || params.ramp == .start { ts.insert(t) }
                        if params.ramp == .both || params.ramp == .end { ts.insert(L - t) }
                    }
                }
            }
            let stationsHere = ts.filter { $0 >= 0 && $0 <= L }.sorted()
            func target(_ zs: Double, _ t: Double, _ scale: Double) -> Double { zs - scale * params.depth(at: t, fluteLength: L) }
            // Split each gap until the straight move across it dips no more than the sag tolerance below the target.
            var ordered: [Double] = [], zs: [Double] = []
            func add(_ t: Double, _ zt: Double) {
                ordered.append(t)
                zs.append(zt)
            }
            func split(_ t0: Double, _ z0: Double, _ t1: Double, _ z1: Double, _ level: Int) {
                let tm = (t0 + t1) / 2, zm = z(along(tm))
                let sags = level < 10 && zm.isFinite && scales.contains { s in
                    (target(z0, t0, s) + target(z1, t1, s)) / 2 < target(zm, tm, s) - sagTolerance
                }
                if sags {
                    split(t0, z0, tm, zm, level + 1)
                    split(tm, zm, t1, z1, level + 1)
                } else {
                    add(t1, z1)
                }
            }
            var previous: (t: Double, z: Double)?
            for t in stationsHere {
                let zt = z(along(t))
                guard zt.isFinite else { continue }
                if let p = previous { split(p.t, p.z, t, zt, 0) } else { add(t, zt) }
                previous = (t, zt)
            }
            guard ordered.count >= 2 else { continue }
            let xy = ordered.map { point(along($0)) }
            let breaks = Set(ordered.indices.filter { corners.contains(ordered[$0]) })
            let piecePasses = scales.map { scale in
                mergeAbove(ordered.indices.map { Vec3(xy[$0], target(zs[$0], ordered[$0], scale)) }, breaks: breaks, tolerance: tolerance)
            }
            out.pieces.append(FluteOnSurface.Piece(closed: line.isClosed && whole, passes: piecePasses))
        }
        return out
    }

    /// Drops points of `pts` where the straight move that replaces them passes on or above each dropped point and no
    /// more than `tolerance` above it: a one-sided simplification, so the path never goes below the points it was given.
    /// The points at `breaks` (indices: the vector's corners, where the path turns in plan) are always kept, and a merged
    /// move replaces at most `longest` points.
    static func mergeAbove(_ pts: [Vec3], breaks: Set<Int>, tolerance: Double, longest: Int = 400) -> [Vec3] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        var anchor = 0
        while anchor < pts.count - 1 {
            var best = anchor + 1
            var j = anchor + 2
            while j < pts.count, j - anchor <= longest, !breaks.contains(j - 1) {
                let a = pts[anchor], c = pts[j]
                let total = a.xy.distance(to: c.xy)
                guard total > 1e-12 else { break }
                var fits = true
                for m in (anchor + 1)..<j {
                    let zc = a.z + (c.z - a.z) * (a.xy.distance(to: pts[m].xy) / total)
                    let gap = zc - pts[m].z
                    if gap < -1e-7 || gap > tolerance {
                        fits = false
                        break
                    }
                }
                if !fits { break }
                best = j
                j += 1
            }
            out.append(pts[best])
            anchor = best
        }
        return out
    }
}
