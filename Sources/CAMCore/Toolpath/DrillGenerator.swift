import Foundation

/// Plunge drilling at shape centres (circles use their centre; other shapes their placement point).
/// Cycles are expanded into plain G0/G1 moves, which every Mach4 profile runs the same way.
enum DrillGenerator {
    static func generate(op: CAMOperation, params: DrillParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        if let helix = params.helix { return helicalBore(op: op, params: params, helix: helix, shapes: shapes, context: context) }
        let tool = op.tool
        var warnings: [String] = []
        for shape in shapes {
            if case let .circle(radius) = shape.kind, radius * shape.scale > tool.radius * 1.05 {
                warnings.append("\(shape.name): hole is larger than the tool; choose Drill ▸ Method ▸ Helical bore, or use a pocket or inside profile, to size it.")
            }
        }
        let points = holeCentres(shapes, tolerance: context.flattenTolerance)
        let depth = max(0, params.depth)
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        if depth <= 0 { warnings.append("Drill depth must be greater than zero.") }
        let ordered = TourOptimizer.order(count: points.count, from: context.stock.homePosition.xy,
                                          start: { points[$0] }, end: { points[$0] }).map { points[$0] }
        for p in ordered where depth > 0 {
            plunge(&b, at: p, depth: depth, params: params, tool: tool)
        }
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
    }

    /// One hole plunged at `p`, in pecks if asked, with the dwell at the bottom.
    static func plunge(_ b: inout ToolpathBuilder, at p: Vec2, depth: Double, params: DrillParams, tool: Tool) {
        let backoff = min(0.5, depth * 0.1) // chip-break retract distance (mm)
        let reentryClearance = 0.5
        b.enter(at: Vec3(p, b.plungeZ))
        if params.peckDepth <= 0 || params.peckDepth >= depth {
            b.feed(Vec3(p, -depth), rate: tool.cutting.plungeRate)
        } else {
            var reached = 0.0
            while reached < depth - 1e-9 {
                let target = min(depth, reached + params.peckDepth)
                if reached > 0 && params.fullRetract {
                    // Come back down quickly to just above the previous peck (G83-style).
                    b.rapid(Vec3(p, -reached + reentryClearance))
                }
                b.feed(Vec3(p, -target), rate: tool.cutting.plungeRate)
                reached = target
                if reached < depth - 1e-9 {
                    // Full retract clears chips out of the hole; otherwise just back off to break the chip (G73-style).
                    b.rapid(Vec3(p, params.fullRetract ? b.plungeZ : -reached + backoff))
                }
            }
        }
        b.dwell(params.dwell)
        b.retract()
    }

    /// Drill ▸ Method ▸ Helical bore: holes larger than 1.05 × the bit bored to their drawn size on a helix
    /// (`BoreHelix.cut`), the rest plunged as Plunge does, in one tour.
    static func helicalBore(op: CAMOperation, params: DrillParams, helix: HelixBore, shapes: [DesignShape],
                            context: GenerationContext) -> Toolpath {
        let tool = op.tool
        let u = context.units
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        func refused(_ why: String) -> Toolpath {
            var tp = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: [])
            tp.errors = [why]
            return tp
        }
        if context.stock.rotary != nil {
            return refused("Helical boring isn't available on a rotary job: its helix is about Z. Choose Drill ▸ Method ▸ Plunge.")
        }
        guard tool.shape == .flatEndMill || tool.shape == .bullNose || tool.shape == .ballNose else {
            return refused("\(tool.name) can't bore a hole on a helix: it needs an end mill that cuts on its side. Choose an end "
                + "mill, or Drill ▸ Method ▸ Plunge.")
        }
        let depth = max(0, params.depth)
        var warnings: [String] = []
        if depth <= 0 { warnings.append("Drill depth must be greater than zero.") }
        let holes = Self.holes(shapes, tolerance: context.flattenTolerance)
        let ordered = TourOptimizer.order(count: holes.count, from: context.stock.homePosition.xy,
                                          start: { holes[$0].center }, end: { holes[$0].center }).map { holes[$0] }
        var notes: [String] = []
        var plunged: [String] = [], smaller: [String] = [], wide: [String] = []
        var bores: [BoredHole] = []
        for hole in ordered where depth > 0 {
            guard let d = hole.diameter, d > tool.diameter * HelixBore.plungeRatio else {
                if let d = hole.diameter, d < tool.diameter - 1e-3 { smaller.append(hole.name) } else { plunged.append(hole.name) }
                plunge(&b, at: hole.center, depth: depth, params: params, tool: tool)
                bores.append(BoredHole(center: hole.center, diameter: hole.diameter, bored: false, reach: 0))
                continue
            }
            if d > tool.diameter * HelixBore.pocketRatio { wide.append(hole.name) }
            bores.append(BoreHelix.cut(&b, center: hole.center, diameter: d, depth: depth, tool: tool, settings: helix,
                                       arcs: context.machine.outputArcs))
        }
        func list(_ names: [String]) -> String {
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.count == 1 ? unique[0] : unique.dropLast().joined(separator: ", ") + " and " + unique.last!
        }
        if !plunged.isEmpty {
            notes.append("\(list(plunged)): no more than 1.05 × the bit (\(fmt(tool.diameter))) across, so plunged at the bit's size.")
        }
        if !smaller.isEmpty {
            notes.append("\(list(smaller)): smaller than the bit (\(fmt(tool.diameter))), so plunged at the bit's size, larger than drawn.")
        }
        if !wide.isEmpty {
            notes.append("\(list(wide)): more than 8 × the bit across; a pocket would clear it faster than rings of helixes.")
        }
        if helix.allowanceInUse > 0, bores.contains(where: \.bored) {
            if helix.allowanceInUse < 0.05 || helix.allowanceInUse > 0.5 {
                warnings.append("The finishing allowance (\(fmt(helix.allowanceInUse))) is outside \(u.format(0.05))–\(u.format(0.5)) \(u.symbol): too little rubs, "
                    + "too much loads the finishing lap.")
            }
        }
        var tp = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        tp.bores = bores
        tp.notes = notes.isEmpty ? nil : notes
        return tp
    }

    /// One hole a Drill toolpath cuts: its centre, and its drawn diameter when it's round.
    struct Hole {
        var center: Vec2
        var diameter: Double?
        var name: String
    }

    /// The holes, as `holeCentres` finds them, with the diameter of each round one: a circle's, or an imported closed
    /// outline's when it's round to within 1% (`SizeFilter.circleDiameter`).
    static func holes(_ shapes: [DesignShape], tolerance: Double) -> [Hole] {
        var out: [Hole] = []
        for shape in shapes {
            switch shape.kind {
            case let .circle(radius):
                out.append(Hole(center: shape.position, diameter: 2 * radius * shape.scale, name: shape.name))
            case let .paths(paths) where paths.allSatisfy({ $0.isClosed }):
                for loop in shape.polylines(tolerance: tolerance) {
                    out.append(Hole(center: loop.bounds.center, diameter: SizeFilter.circleDiameter(loop), name: shape.name))
                }
            default:
                out.append(Hole(center: shape.position, diameter: nil, name: shape.name))
            }
        }
        return out
    }

    /// The radius each hole a Drill toolpath cuts leaves, bored or plunged, with its centre: the drawn radius of a
    /// hole Helical bore bores, otherwise the bit's.
    static func cutHoles(_ shapes: [DesignShape], params: DrillParams, tool: Tool, tolerance: Double) -> [(center: Vec2, radius: Double)] {
        guard params.helix != nil else { return holeCentres(shapes, tolerance: tolerance).map { ($0, tool.radius) } }
        return holes(shapes, tolerance: tolerance).map { h in
            guard let d = h.diameter, d > tool.diameter * HelixBore.plungeRatio else { return (h.center, tool.radius) }
            return (h.center, d / 2)
        }
    }

    /// Where the holes go: a circle's centre, each closed loop's centre for imported circles, otherwise the shape's
    /// placement point.
    static func holeCentres(_ shapes: [DesignShape], tolerance: Double) -> [Vec2] {
        var points: [Vec2] = []
        for shape in shapes {
            switch shape.kind {
            case .circle:
                points.append(shape.position)
            case let .paths(paths) where paths.allSatisfy({ $0.isClosed }):
                for loop in shape.polylines(tolerance: tolerance) { points.append(loop.bounds.center) }
            default:
                points.append(shape.position)
            }
        }
        return points
    }
}
