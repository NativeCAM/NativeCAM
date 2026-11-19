import Foundation

/// Plunge drilling at shape centres (circles use their centre; other shapes their placement point).
/// Cycles are expanded into plain G0/G1 moves, which every Mach4 profile runs the same way.
enum DrillGenerator {
    static func generate(op: CAMOperation, params: DrillParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var warnings: [String] = []
        var points: [Vec2] = []
        for shape in shapes {
            switch shape.kind {
            case let .circle(radius):
                points.append(shape.position)
                if radius * shape.scale > tool.radius * 1.05 {
                    warnings.append("\(shape.name): hole is larger than the tool; use a pocket or inside profile to size it.")
                }
            case let .paths(paths) where paths.allSatisfy({ $0.isClosed }):
                // Imported circles: use each loop's centre.
                for loop in shape.polylines(tolerance: context.flattenTolerance) { points.append(loop.bounds.center) }
                _ = paths
            default:
                points.append(shape.position)
            }
        }
        let depth = max(0, params.depth)
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        if depth <= 0 { warnings.append("Drill depth must be greater than zero.") }
        let ordered = nearestNeighborOrder(points, from: context.stock.homePosition.xy, start: { $0 }, end: { $0 })
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
}
