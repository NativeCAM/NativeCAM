import Foundation

/// Plunge drilling at shape centres (circles use their centre; other shapes their placement point).
/// Cycles are expanded into plain G0/G1 moves, which every Mach4 profile runs the same way.
enum DrillGenerator {
    static func generate(op: CAMOperation, params: DrillParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        for shape in shapes {
            if case let .circle(radius) = shape.kind, radius * shape.scale > tool.radius * 1.05 {
                warnings.append("\(shape.name): hole is larger than the tool; use a pocket or inside profile to size it.")
            }
        }
        let points = holeCentres(shapes, tolerance: context.flattenTolerance)
        let depth = max(0, params.depth)
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        if depth <= 0 { warnings.append("Drill depth must be greater than zero.") }
        let ordered = TourOptimizer.order(count: points.count, from: context.stock.homePosition.xy,
                                          start: { points[$0] }, end: { points[$0] }).map { points[$0] }
        let backoff = min(0.5, depth * 0.1) // chip-break retract distance (mm)
        let reentryClearance = 0.5

        for p in ordered where depth > 0 {
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
        return b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
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
