import Foundation

/// Curve flattening helpers shared by design shapes, text outlines and the DXF/SVG importers.
public enum Curves {
    /// Segment count so a circular arc of `radius` and `sweep` (radians) deviates at most `tolerance`.
    public static func arcSegments(radius: Double, sweep: Double, tolerance: Double) -> Int {
        guard radius > tolerance, tolerance > 0 else { return max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up))) }
        let maxStep = 2 * acos(max(-1, min(1, 1 - tolerance / radius)))
        let n = Int((abs(sweep) / max(maxStep, 1e-6)).rounded(.up))
        return max(n, max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up))))
    }

    /// Points along a circular arc, including both ends. Positive sweep = counter-clockwise.
    public static func arc(center: Vec2, radius: Double, startAngle: Double, sweep: Double, tolerance: Double) -> [Vec2] {
        let n = arcSegments(radius: radius, sweep: sweep, tolerance: tolerance)
        return (0...n).map { i in
            center + Vec2.fromAngle(startAngle + sweep * Double(i) / Double(n), length: radius)
        }
    }

    /// Closed circle polygon (first point not repeated).
    public static func circle(center: Vec2, radius: Double, tolerance: Double) -> [Vec2] {
        var pts = arc(center: center, radius: radius, startAngle: 0, sweep: 2 * .pi, tolerance: tolerance)
        pts.removeLast()
        return pts
    }

    /// Appends a flattened quadratic Bézier (excluding p0) to `out`.
    public static func flattenQuad(_ p0: Vec2, _ c: Vec2, _ p1: Vec2, tolerance: Double, into out: inout [Vec2]) {
        // Deviation of a quadratic is bounded by |p0 - 2c + p1| / 4.
        let dd = (p0 - c * 2 + p1).length
        let n = max(1, min(512, Int(((dd / 4) / max(tolerance, 1e-6)).squareRoot().rounded(.up))))
        for i in 1...n {
            let t = Double(i) / Double(n)
            let mt = 1 - t
            out.append(p0 * (mt * mt) + c * (2 * mt * t) + p1 * (t * t))
        }
    }

    /// Appends a flattened cubic Bézier (excluding p0) to `out`.
    public static func flattenCubic(_ p0: Vec2, _ c1: Vec2, _ c2: Vec2, _ p1: Vec2, tolerance: Double, into out: inout [Vec2]) {
        let d1 = (p0 - c1 * 2 + c2).length
        let d2 = (c1 - c2 * 2 + p1).length
        let dd = max(d1, d2)
        // Wang's formula: n = sqrt(3 * dd / (4 * tol)).
        let n = max(1, min(1024, Int((3 * dd / (4 * max(tolerance, 1e-6))).squareRoot().rounded(.up))))
        for i in 1...n {
            let t = Double(i) / Double(n)
            let mt = 1 - t
            let a = mt * mt * mt, b = 3 * mt * mt * t, cc = 3 * mt * t * t, d = t * t * t
            out.append(p0 * a + c1 * b + c2 * cc + p1 * d)
        }
    }

    /// SVG/DXF-style elliptical arc from p0 to p1 (endpoint parameterisation, SVG spec F.6.5).
    /// Appends points excluding p0.
    public static func flattenEllipticalArc(from p0: Vec2, to p1: Vec2, rx rxIn: Double, ry ryIn: Double,
                                            xAxisRotation: Double, largeArc: Bool, sweep: Bool,
                                            tolerance: Double, into out: inout [Vec2]) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if p0.isApprox(p1, tolerance: 1e-12) { return }
        if rx < 1e-12 || ry < 1e-12 { out.append(p1); return }
        let phi = xAxisRotation.radians
        let cphi = cos(phi), sphi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cphi * dx + sphi * dy
        let y1p = -sphi * dx + cphi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? (max(0, num) / den).squareRoot() : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cphi * cxp - sphi * cyp + (p0.x + p1.x) / 2
        let cy = sphi * cxp + cphi * cyp + (p0.y + p1.y) / 2
        func ang(_ u: Vec2, _ v: Vec2) -> Double { atan2(u.cross(v), u.dot(v)) }
        let u = Vec2((x1p - cxp) / rx, (y1p - cyp) / ry)
        let v = Vec2((-x1p - cxp) / rx, (-y1p - cyp) / ry)
        let theta1 = ang(Vec2(1, 0), u)
        var dtheta = ang(u, v)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }
        let n = arcSegments(radius: max(rx, ry), sweep: dtheta, tolerance: tolerance)
        for i in 1...n {
            let t = theta1 + dtheta * Double(i) / Double(n)
            let x = rx * cos(t), y = ry * sin(t)
            out.append(Vec2(cphi * x - sphi * y + cx, sphi * x + cphi * y + cy))
        }
        out[out.count - 1] = p1
    }

    /// Points of an ellipse arc given centre, major-axis vector and ratio (DXF ELLIPSE parameterisation).
    public static func ellipse(center: Vec2, majorAxis: Vec2, ratio: Double, startParam: Double, endParam: Double,
                               tolerance: Double) -> [Vec2] {
        var sweep = endParam - startParam
        if sweep <= 0 { sweep += 2 * .pi }
        let a = majorAxis.length
        let minor = majorAxis.perpLeft * ratio
        let n = arcSegments(radius: a, sweep: sweep, tolerance: tolerance)
        return (0...n).map { i in
            let t = startParam + sweep * Double(i) / Double(n)
            return center + majorAxis * cos(t) + minor * sin(t)
        }
    }
}
