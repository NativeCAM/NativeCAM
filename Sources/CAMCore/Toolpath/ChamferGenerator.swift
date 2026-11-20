import Foundation

/// Chamfers, and the prisms built on them: a V-bit bevels the edges of closed vectors at its own angle.
///
/// Each face of the bevel is a plane through an edge of the vector, sloping at the bit's half angle α from vertical,
/// `width` across and d = width / tan α deep. A cone whose side lies on that plane has its tip on a line parallel to
/// the edge at depth d, offset from the vector toward the bevel by
///
///     top edge (the vector is the bevel's top; it slopes down away from it):  tipRadius + width
///     bottom edge (the vector is the bevel's bottom; it rises away from it):  −tipRadius
///
/// So the tip runs along the vector's offset by that distance, made by Clipper for all the shapes at once. Every
/// point of that offset is at least the distance from every vector (the offsets of shapes close together merge rather
/// than cross), so the cone never cuts past any shape's bevel.
///
/// Corners. Where a corner turns away from the bevel, its two faces meet in a hip the offset's lines reach: running
/// them on to the mitre where they meet keeps it crisp (`sharpCorners`; still no nearer the vector than the distance),
/// an arc rounds it. Where the faces meet in a valley instead, the offset's two lines meet in a point the cone can't
/// reach the valley from, and with `sharpCorners` the bit rises from there along the corner's bisector, its tip on the
/// line where the faces meet, as a V-carve does at a corner: as far as the faces go (the top of the bevel), or until
/// another edge is nearer (past a prism's ridge, or where the cone would reach into another shape's bevel). A top-edge
/// bevel's valleys are on the inside of a turn; a bottom-edge bevel's are on the outside, where it rises from the
/// vector's corner into the material.
enum ChamferGenerator {
    /// What to bevel and how.
    struct Bevel {
        var regions: [Region]
        var side: ChamferParams.Side
        var edge: ChamferParams.Edge
        var width: Double
        var startDepth: Double
        var passDepth: Double?
        var sharpCorners: Bool
        var direction: CutDirection
    }

    /// One closed tip path, at the bevel's full depth except where it rises into a corner.
    struct TipPath {
        var points: [Vec3]
        /// Whether the cut may start at each point (not on a rise).
        var startable: [Bool]
    }

    /// Turns gentler than this are a flattened curve, not a corner to rise into (as `VCarveGenerator`'s).
    static let minimumCornerTurn = VCarveGenerator.minimumCornerTurn
    /// How far a mitre may reach from the corner, in multiples of the tip's offset (Clipper's miter limit): corners
    /// down to about 11° stay sharp.
    static let miterLimit = 10.0
    /// Distances that agree to this are the same (Clipper's integer grid and the corner geometry), mm.
    static let tolerance = 0.01

    static func generate(op: CAMOperation, params: ChamferParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        let empty = { (w: [String]) in
            ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
                .build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: w)
        }
        guard tool.shape.isTapered else {
            return empty(["Chamfers need a V-bit or engraving bit; '\(tool.name)' is a \(tool.shape.label)."])
        }
        let polys = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
        let open = polys.filter { !$0.isClosed && $0.count >= 2 }.count
        if open > 0 {
            warnings.append("\(open) open vector\(open == 1 ? "" : "s") can't be chamfered and \(open == 1 ? "was" : "were") skipped; "
                + "chamfers bevel the edges of closed shapes. Use Fluting to cut along a line.")
        }
        let regions = Region.build(from: polys.filter { $0.isClosed && $0.count >= 3 }, fill: .evenOdd)
        guard !regions.isEmpty else { return empty(warnings + ["Chamfers need closed shapes; none were selected."]) }
        guard params.width > 1e-6 else { return empty(warnings + ["The chamfer's width must be more than 0."]) }
        let depth = params.depth(with: tool)
        let reach = min(tool.taperHeight, tool.fluteLength)
        if params.startDepth + depth > reach + 1e-6 {
            let u = LengthUnit.mm
            warnings.append("The bevel reaches \(u.format(params.startDepth + depth)) mm deep, but '\(tool.name)' only cuts "
                + "\(u.format(reach)) mm down its V, so its top comes out as a step instead. Use a narrower chamfer or a larger V-bit.")
        }
        let bevel = Bevel(regions: regions, side: params.side, edge: params.edge, width: params.width, startDepth: params.startDepth,
                          passDepth: params.passDepth, sharpCorners: params.sharpCorners, direction: params.direction)
        return toolpath(bevel, op: op, context: context, warnings: warnings)
    }

    /// Cuts `bevel` with the operation's tool: each tip path in turn, nearest first, every pass on one before the next.
    static func toolpath(_ bevel: Bevel, op: CAMOperation, context: GenerationContext, warnings: [String]) -> Toolpath {
        let tool = op.tool
        var warnings = warnings
        let depth = bevel.width / tool.halfAngleTangent
        let levels = DepthSettings(startDepth: bevel.startDepth, cutDepth: bevel.startDepth + depth, passDepth: bevel.passDepth)
            .passLevels(toolStepdown: tool.cutting.stepdown)
        var paths = tipPaths(bevel, tool: tool, arcTolerance: context.arcTolerance)
        if paths.isEmpty { warnings.append("The bevel has nowhere to go: the shapes are too small for it.") }
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        var cursor = context.stock.homePosition.xy
        while !paths.isEmpty, !levels.isEmpty {
            // Nearest path next, entered at its nearest point off a rise.
            var best = (path: 0, point: 0, d: Double.infinity)
            for (i, path) in paths.enumerated() {
                for (k, p) in path.points.enumerated() where path.startable[k] {
                    let d = p.xy.distanceSquared(to: cursor)
                    if d < best.d { best = (i, k, d) }
                }
            }
            let path = paths.remove(at: best.path)
            let pts = Array(path.points[best.point...] + path.points[..<best.point]) + [path.points[best.point]]
            for z in levels {
                let pass = pts.map { Vec3($0.x, $0.y, max($0.z, z)) }
                b.enter(at: pass[0])
                b.follow(Array(pass.dropFirst()))
            }
            b.retract()
            cursor = pts[0].xy
        }
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }

    /// The closed paths the bit's tip follows to cut `bevel` at full depth, rises included, each oriented for the
    /// bevel's cut direction (climb keeps the bevel the cone finishes on the tool's right).
    static func tipPaths(_ bevel: Bevel, tool: Tool, arcTolerance: Double) -> [TipPath] {
        let t = tool.halfAngleTangent, rt = tool.tipDiameter / 2
        guard t > 1e-9, bevel.width > 1e-9 else { return [] }
        let w = bevel.width, d = w / t
        let top = bevel.edge == .top
        let start = bevel.startDepth
        let loops = bevel.regions.flatMap(\.loops)
        let segments = loops.flatMap { loop in (0..<loop.segmentCount).map { loop.segment($0) } }
        let grid = VCarveGenerator.SegmentGrid(segments: segments, cell: max(2 * (rt + w), 1))
        var scratch = VCarveGenerator.SegmentGrid.Scratch(count: segments.count)
        func nearest(_ p: Vec2, within r: Double) -> Double {
            var best = Double.infinity
            for i in grid.query(p, radius: r, scratch: &scratch) {
                best = min(best, distancePointSegment(p, segments[i].0, segments[i].1))
            }
            return best
        }
        // Both sides of a bottom-edge bevel meet on the vector: one path along it, its rises on either side.
        let both = bevel.side == .both && !top
        /// The tip's offset from the vector toward the bevel when it's `u` below the start depth.
        func offset(_ u: Double) -> Double { both ? (d - u) * t : top ? rt + u * t : (d - u) * t - rt }
        let sides: [Double]
        switch bevel.side {
        case .outside: sides = [1]
        case .inside: sides = [-1]
        case .both: sides = top ? [1, -1] : [0]
        }

        var out: [TipPath] = []
        for sigma in sides {
            let oFinal = offset(d)
            let delta = sigma * oFinal
            let tipLoops = abs(delta) < 1e-6 ? loops
                : Clipper.offset(loops, delta: delta, join: bevel.sharpCorners ? .miter : .round, miterLimit: miterLimit,
                                 arcTolerance: arcTolerance)
            var points = tipLoops.map { $0.points.map { Vec3($0, -(start + d)) } }
            var startable = tipLoops.map { [Bool](repeating: true, count: $0.count) }
            // The tip paths' points by place, to find the one a corner's rise starts from.
            var index: [Int64: [(loop: Int, point: Int)]] = [:]
            func key(_ p: Vec2) -> Int64 { Int64((p.x / 0.05).rounded()) &* 1_000_003 &+ Int64((p.y / 0.05).rounded()) }
            for (i, loop) in tipLoops.enumerated() {
                for (k, p) in loop.points.enumerated() { index[key(p), default: []].append((i, k)) }
            }
            func vertex(near p: Vec2) -> (loop: Int, point: Int)? {
                var best: (loop: Int, point: Int)?, bestD = tolerance
                for dx in -1...1 {
                    for dy in -1...1 {
                        for c in index[key(p + Vec2(Double(dx) * 0.05, Double(dy) * 0.05)), default: []] {
                            let q = tipLoops[c.loop].points[c.point]
                            if q.distance(to: p) < bestD { bestD = q.distance(to: p); best = c }
                        }
                    }
                }
                return best
            }
            // Rises, found from the vector's own corners and inserted at the tip path's matching vertex.
            var rises: [Int: [Int: Vec3]] = [:]
            if bevel.sharpCorners {
                for loop in loops {
                    let n = loop.count
                    guard n >= 3 else { continue }
                    for i in 0..<n {
                        let v = loop.points[i]
                        let a = (v - loop.points[(i + n - 1) % n]).normalized, bOut = (loop.points[(i + 1) % n] - v).normalized
                        let turn = atan2(a.cross(bOut), a.dot(bOut))
                        guard abs(turn) > minimumCornerTurn, abs(turn) < .pi - 1e-3 else { continue }
                        // The bisector into the inside of the turn, and the side that is (+1 right, outside the shapes).
                        let u = (bOut - a).normalized
                        let insideSide: Double = turn > 0 ? -1 : 1
                        let c = cos(abs(turn) / 2)
                        for beveled in (sigma == 0 ? [1.0, -1.0] : [sigma]) {
                            let bevelInside = beveled == insideSide
                            guard top == bevelInside else { continue }
                            let toward = bevelInside ? u : u * -1
                            func at(_ o: Double) -> Vec2 { v + toward * (o / c) }
                            let from = at(oFinal), to = at(offset(0))
                            guard let hit = vertex(near: from) else { continue }
                            // Up the line where the faces meet, while no other edge is nearer than its own two.
                            var end: Vec3?
                            let steps = 32
                            for k in 1...steps {
                                let lambda = Double(k) / Double(steps)
                                let p = from.lerp(to: to, lambda)
                                let u = d * (1 - lambda)
                                let need = offset(u)
                                if need > tolerance, nearest(p, within: need + 1) < need - tolerance { break }
                                end = Vec3(p, -(start + u))
                            }
                            if let end { rises[hit.loop, default: [:]][hit.point] = end }
                        }
                    }
                }
            }
            for (i, byPoint) in rises {
                for k in byPoint.keys.sorted(by: >) {
                    let base = points[i][k]
                    points[i].insert(contentsOf: [byPoint[k]!, base], at: k + 1)
                    startable[i].insert(contentsOf: [false, false], at: k + 1)
                }
            }
            // A path's left is toward the inside of its own (offset) shape. The cone finishes the bevel facing the
            // vector on a top-edge bevel, facing away from it on a bottom-edge one; climb keeps that on the right.
            let finishedLeft = sigma != 0 && (top == (sigma > 0))
            let reverse = (bevel.direction == .climb) == finishedLeft
            for i in points.indices where points[i].count >= 3 {
                out.append(reverse ? TipPath(points: points[i].reversed(), startable: startable[i].reversed())
                                   : TipPath(points: points[i], startable: startable[i]))
            }
        }
        return out
    }
}

/// Prism carving: the shape rises from the prism depth at its outline to a ridge along its middle, each slope at the
/// bit's half angle. It is a bottom-edge chamfer inside the shape as wide as the prism is deep times tan(half angle):
/// the tip runs round the outline at that depth, and at the shape's inside corners rises along the valley to the ridge.
/// Too shallow for the widest part, the prism has a flat top there.
enum PrismGenerator {
    static func generate(op: CAMOperation, params: PrismParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        let empty = { (w: [String]) in
            ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
                .build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: w)
        }
        guard tool.shape.isTapered else {
            return empty(["Prism carving needs a V-bit; '\(tool.name)' is a \(tool.shape.label)."])
        }
        var warnings: [String] = []
        let polys = shapes.flatMap { $0.polylines(tolerance: context.flattenTolerance) }
        let open = polys.filter { !$0.isClosed && $0.count >= 2 }.count
        if open > 0 { warnings.append("\(open) open vector\(open == 1 ? "" : "s") can't be prism carved and \(open == 1 ? "was" : "were") skipped.") }
        let regions = Region.build(from: polys.filter { $0.isClosed && $0.count >= 3 }, fill: .evenOdd)
        guard !regions.isEmpty else { return empty(warnings + ["Prism carving needs closed shapes; none were selected."]) }
        let full = fullDepth(regions, tool: tool)
        let depth = params.depth ?? full
        guard depth > 1e-6 else { return empty(warnings + ["The prism's depth must be more than 0."]) }
        let reach = min(tool.taperHeight, tool.fluteLength)
        let u = LengthUnit.mm
        if params.startDepth + depth > reach + 1e-6 {
            warnings.append("The prism is \(u.format(params.startDepth + depth)) mm deep, but '\(tool.name)' only cuts \(u.format(reach)) mm "
                + "down its V, so its slopes stop at a step. Use a larger V-bit, a smaller prism depth or smaller shapes.")
        }
        let bevel = ChamferGenerator.Bevel(regions: regions, side: .inside, edge: .bottom, width: depth * tool.halfAngleTangent,
                                           startDepth: params.startDepth, passDepth: params.passDepth, sharpCorners: true,
                                           direction: params.direction)
        return ChamferGenerator.toolpath(bevel, op: op, context: context, warnings: warnings)
    }

    /// The shallowest prism depth whose slopes meet in a ridge everywhere: the radius of the largest circle inside the
    /// shapes over tan(half the bit's angle). Found with the V-carve's search for the circles inscribed along the
    /// outline, uncapped.
    static func fullDepth(_ regions: [Region], tool: Tool) -> Double {
        guard tool.shape.isTapered, tool.halfAngleTangent > 1e-9 else { return 0 }
        var widest = 0.0
        for region in regions {
            let segs = region.loops.flatMap { loop in (0..<loop.segmentCount).map { loop.segment($0) } }
            let bounds = region.bounds
            let cap = max(0.01, min(bounds.width, bounds.height) / 2)
            let perimeter = region.loops.reduce(0) { $0 + $1.length }
            let spacing = max(0.2, perimeter / 4000)
            let grid = VCarveGenerator.SegmentGrid(segments: segs, cell: max(cap / 2, spacing * 4, 0.5))
            for loop in region.loops {
                let path = VCarveGenerator.carvePath(loop: loop, segments: segs, grid: grid, spacing: spacing, rCap: cap, tip: 0, t: 1)
                widest = max(widest, path.map { -$0.z }.max() ?? 0)
            }
        }
        return widest / tool.halfAngleTangent
    }

}

public extension Project {
    /// The depth below its start depth that gives a full prism (slopes meeting in a ridge everywhere) for `op`'s shapes
    /// and bit: Vectric's "Set Depth for Full Prism". 0 without closed shapes or a V-bit.
    func fullPrismDepth(for op: CAMOperation) -> Double {
        let loops = shapes(for: op).filter { !$0.isKeepOut }.flatMap { $0.polylines(tolerance: 0.01) }
            .filter { $0.isClosed && $0.count >= 3 }
        return PrismGenerator.fullDepth(Region.build(from: loops, fill: .evenOdd), tool: op.tool)
    }
}
