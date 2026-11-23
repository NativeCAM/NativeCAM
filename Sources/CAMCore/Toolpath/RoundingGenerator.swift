import Foundation

/// Turns a rotary blank round (research_notes/Rotary milling/rotary_milling.md §2.4, "Rounding"; Vectric's Rounding
/// Toolpath): layers from the farthest the blank reaches (a square bar's corners) in to the finished radius, each cut
/// all the way round, so no layer is deeper than the pass depth.
///
/// The toolpath is a wrapped one, laid out on the unrolled sheet like any other: X along the blank, sheet Y turning
/// into the angle (one turn is 2π × the sheet's radius), Z measured from the sheet's radius. The angle only ever
/// increases, so the rotary turns one way throughout.
///
/// - **Around** (radial): each layer ramps in over one turn at one end, spirals along the blank by the stepover per
///   turn, and finishes with a full turn at the other end; the next layer comes back.
/// - **Along** (raster): passes parallel to the axis, stepping round by the stepover at the largest radius. On a
///   square bar it skips the angles where the layer would only cut air (the faces, until the layers reach them).
enum RoundingGenerator {
    static func generate(op: CAMOperation, params p: RoundingParams, context ctx: GenerationContext) -> Toolpath {
        let stock = ctx.stock, tool = op.tool
        let clearance = max(stock.clearanceHeight, stock.plungeHeight)
        var tp = Toolpath(id: op.id, name: op.name, tool: tool, spindleRPM: tool.cutting.spindleRPM,
                          start: Vec3(0, stock.originPoint.y, clearance), motions: [])
        guard let blank = stock.rotary else {
            tp.warnings = ["Rounding needs a rotary blank."]
            return tp
        }
        let top = blank.topRadius, cy = stock.originPoint.y
        let finish = finishedRadius(p, blank: blank)
        let outer = blank.outerRadius
        guard finish < outer - 1e-6 else {
            tp.warnings = ["The blank is already no bigger than \(ctx.length(2 * finish)) round, so there's nothing to cut."]
            return tp
        }
        let x0 = p.startX ?? tool.radius, x1 = p.endX ?? blank.length - tool.radius
        guard x1 > x0 + 1e-6 else {
            tp.warnings = ["The rounding's start and end along the blank leave nothing to cut between them."]
            return tp
        }
        let pass = max(0.05, p.passDepth ?? tool.cutting.stepdown)
        let step = max(0.01, (p.stepoverFraction ?? tool.cutting.stepoverFraction) * tool.stepoverBasis)
        let layers = max(1, Int(((outer - finish) / pass - 1e-9).rounded(.up)))
        let radii = (1...layers).map { outer - Double($0) * (outer - finish) / Double(layers) }
        let feed = tool.cutting.feedRate
        func point(_ x: Double, _ angle: Double, _ r: Double) -> Vec3 { Vec3(x, cy + angle * top, r - top) }

        // In over the start, just clear of the blank's farthest reach.
        let above = outer + max(0.5, stock.plungeHeight)
        var motions: [Motion] = []
        var angle = 0.0
        tp.start = point(x0, angle, top + clearance)
        motions.append(.rapid(point(x0, angle, above)))
        var r = above, x = x0

        switch p.method {
        case .radial:
            for rho in radii {
                let far = x == x0 ? x1 : x0
                // One turn ramping in, the spiral along the blank, a full turn at the far end.
                angle += 2 * .pi
                motions.append(.feed(point(x, angle, rho), feed))
                angle += abs(far - x) / step * 2 * .pi
                motions.append(.feed(point(far, angle, rho), feed))
                angle += 2 * .pi
                motions.append(.feed(point(far, angle, rho), feed))
                x = far
                r = rho
            }
        case .raster:
            let count = max(3, Int((2 * .pi * outer / step).rounded(.up)))
            let turn = 2 * .pi / Double(count)
            var previous = outer
            for rho in radii {
                // The angles where this layer meets material the previous one left. Across its width the tool's bottom
                // is a plane tangent at the layer's radius, so at φ off its axis it only reaches in to ρ / cos φ: right
                // over a square bar's face it cuts nothing.
                let half = asin(min(1, tool.radius / max(rho, 1e-6)))
                let lines = (0..<count).filter { j in
                    let a = Double(j) * turn
                    return (-4...4).contains { k in
                        let phi = half * Double(k) / 4
                        return min(blank.surfaceRadius(atDegrees: (a + phi) * 180 / .pi), previous) > rho / cos(phi) + 1e-6
                    }
                }
                previous = rho
                guard let first = lines.first else { continue }
                let base = (angle / (2 * .pi)).rounded(.up) * 2 * .pi
                // Turn to the first line at the last layer's radius, ramp down along it, and come back at depth.
                angle = base + Double(first) * turn
                motions.append(.feed(point(x, angle, r), feed))
                let far = x == x0 ? x1 : x0
                motions.append(.feed(point(far, angle, rho), feed))
                motions.append(.feed(point(x, angle, rho), feed))
                for j in lines.dropFirst() {
                    angle = base + Double(j) * turn
                    motions.append(.feed(point(x, angle, rho), feed))
                    x = x == x0 ? x1 : x0
                    motions.append(.feed(point(x, angle, rho), feed))
                }
                r = rho
            }
        }
        motions.append(.rapid(Vec3(x, cy + angle * top, clearance)))
        tp.motions = motions
        return tp
    }

    /// The radius a rounding turns the blank down to.
    static func finishedRadius(_ p: RoundingParams, blank: RotaryStock) -> Double {
        p.finishedDiameter(on: blank) / 2
    }
}
