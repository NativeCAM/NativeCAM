import Foundation

/// A form bit's cutting edge. Each preset is one of the common router bits; a custom profile takes its points as given.
///
/// Heights are measured up from the bottom of the cutting edge (the bit's tip, where depths are measured to), radii out
/// from its axis. A bearing below the cutting edge isn't part of the profile: depths reach the bottom of the cutting
/// edge, so take the bearing off or keep it clear of the material.
public struct FormProfile: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Rounds a part's edge over: a concave quarter circle on the bit.
        case roundover
        /// Cuts a concave quarter circle into the edge: a convex quarter circle on the bit.
        case cove
        /// Roman ogee: a cove at the bottom (`radius`) running into a roundover at the top (`upperRadius`).
        case ogee
        /// The points as given.
        case custom

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .roundover: "Roundover"
            case .cove: "Cove"
            case .ogee: "Ogee"
            case .custom: "Custom profile"
            }
        }
    }

    public var kind: Kind
    /// Roundover or cove radius, or an ogee's lower (cove) radius, mm.
    public var radius: Double
    /// An ogee's upper (roundover) radius, mm.
    public var upperRadius: Double
    /// Diameter at the bottom of the profile, where a pilot or bearing would ride the edge, mm.
    public var pilotDiameter: Double
    /// A custom profile's cutting edge from the bottom up: x = radius, y = height above the tip, mm.
    public var points: [Vec2]

    public init(kind: Kind, radius: Double = 0.25.inch, upperRadius: Double = 0.125.inch, pilotDiameter: Double = 0.5.inch,
                points: [Vec2] = []) {
        self.kind = kind
        self.radius = radius
        self.upperRadius = upperRadius
        self.pilotDiameter = pilotDiameter
        self.points = points
    }

    /// Height of the shaped part of the edge (above it the edge runs straight up to the top of the flutes).
    public var profileHeight: Double {
        switch kind {
        case .roundover, .cove: max(0, radius)
        case .ogee: max(0, radius) + max(0, upperRadius)
        case .custom: points.map(\.y).max() ?? 0
        }
    }

    /// The cutting edge from the axis at the tip outward and up to the top of the flutes (`fluteLength`), as a polyline
    /// whose arcs are within `tolerance` of the true circles (points on the circles).
    public func edge(fluteLength: Double, tolerance: Double = 0.002) -> [Vec2] {
        let p = max(0, pilotDiameter / 2)
        var pts = [Vec2(0, 0)]
        if p > 1e-9, kind != .custom { pts.append(Vec2(p, 0)) }
        func arc(_ c: Vec2, _ rho: Double, from a0: Double, to a1: Double) {
            guard rho > 1e-9 else { return }
            let step = 2 * acos(max(-1, 1 - min(tolerance, rho) / rho))
            let n = max(4, min(256, Int((abs(a1 - a0) / max(step, 1e-3)).rounded(.up))))
            for i in 1...n {
                let a = a0 + (a1 - a0) * Double(i) / Double(n)
                pts.append(Vec2(c.x + rho * cos(a), c.y + rho * sin(a)))
            }
        }
        switch kind {
        case .roundover:
            // Centred out at the tip's level: upright at the bottom (along the part's side), level at the top (onto its face).
            arc(Vec2(p + radius, 0), radius, from: .pi, to: .pi / 2)
        case .cove:
            // Centred one radius up over the pilot's edge: level at the bottom, upright at the top.
            arc(Vec2(p, radius), radius, from: -.pi / 2, to: 0)
        case .ogee:
            let r1 = max(0, radius), r2 = max(0, upperRadius)
            arc(Vec2(p, r1), r1, from: -.pi / 2, to: 0)
            arc(Vec2(p + r1 + r2, r1), r2, from: .pi, to: .pi / 2)
        case .custom:
            for q in points {
                let v = Vec2(max(0, q.x), max(0, q.y))
                if let last = pts.last, last.distance(to: v) < 1e-9 { continue }
                pts.append(v)
            }
        }
        if let last = pts.last, fluteLength > last.y + 1e-9 { pts.append(Vec2(last.x, fluteLength)) }
        return pts
    }

    /// Why the profile can't describe a bit, or nil.
    var problem: String? {
        switch kind {
        case .roundover, .cove:
            if radius <= 1e-6 { return "has no profile radius" }
        case .ogee:
            if radius <= 1e-6 || upperRadius <= 1e-6 { return "needs both ogee radii" }
        case .custom:
            if points.count < 2 || (points.map(\.x).max() ?? 0) <= 1e-6 { return "needs at least two profile points" }
            for (a, b) in zip(points, points.dropFirst()) where b.y < a.y - 1e-9 {
                return "has profile points whose heights go down; list them from the tip up"
            }
        }
        if pilotDiameter < 0 { return "has a negative pilot diameter" }
        return nil
    }
}

/// A tapered ball nose's tip: a ball of radius `rho` that the cone of half-angle `alpha` (from the axis) touches, out to
/// the footprint radius `R`.
struct TaperedBall {
    let rho: Double
    let alpha: Double
    let R: Double

    init(_ tool: Tool) {
        rho = max(0, tool.tipDiameter / 2)
        alpha = max(0, tool.includedAngle / 2).radians
        R = tool.radius
    }

    /// Where the cone touches the ball.
    var tangentRadius: Double { rho * cos(alpha) }
    var tangentHeight: Double { rho * (1 - sin(alpha)) }

    func height(atRadius r: Double) -> Double {
        let r = min(max(0, r), R)
        if r <= tangentRadius { return rho - (max(0, rho * rho - r * r)).squareRoot() }
        let t = tan(alpha)
        return t > 1e-12 ? tangentHeight + (r - tangentRadius) / t : tangentHeight
    }

    func radius(atHeight h: Double) -> Double {
        guard h > 0 else { return 0 }
        if h <= tangentHeight { return min(R, (max(0, rho * rho - (rho - h) * (rho - h))).squareRoot()) }
        return min(R, tangentRadius + (h - tangentHeight) * tan(alpha))
    }

    /// The cone's radius at height h, without the footprint's limit (the shank side of the taper).
    func coneRadius(atHeight h: Double) -> Double { tangentRadius + max(0, h - tangentHeight) * tan(alpha) }
}

/// Evaluating a cutting edge given as a polyline (x = radius, y = height above the tip, heights never going down).
enum ToolProfile {
    /// The bit's radius at height h: the widest the edge is there.
    static func radius(_ edge: [Vec2], atHeight h: Double) -> Double {
        guard let first = edge.first else { return 0 }
        if h <= first.y { return edge.filter { $0.y <= first.y + 1e-12 }.map(\.x).max() ?? 0 }
        var best = -Double.infinity
        for (a, b) in zip(edge, edge.dropFirst()) {
            if abs(b.y - a.y) < 1e-12 {
                if abs(h - a.y) < 1e-12 { best = max(best, a.x, b.x) }
            } else if h >= a.y - 1e-12, h <= b.y + 1e-12 {
                best = max(best, a.x + (b.x - a.x) * (h - a.y) / (b.y - a.y))
            }
        }
        return best.isFinite ? best : edge[edge.count - 1].x
    }

    /// Height above the tip of the lowest point of the bit at distance r from its axis (what reaches down to the
    /// material there): where the edge first gets that wide.
    static func lowerEnvelope(_ edge: [Vec2], atRadius r: Double) -> Double {
        guard let first = edge.first else { return 0 }
        if first.x >= r { return first.y }
        for (a, b) in zip(edge, edge.dropFirst()) where b.x >= r {
            if a.x >= r { return a.y }
            return a.y + (b.y - a.y) * (r - a.x) / (b.x - a.x)
        }
        return edge[edge.count - 1].y
    }

    /// The lower envelope as a polyline whose radii never go down (a vertical step where the edge comes back out past
    /// an undercut), from the axis to the widest point.
    static func envelope(_ edge: [Vec2]) -> [Vec2] {
        guard let first = edge.first else { return [] }
        var out = [first]
        var widest = first.x
        for (a, b) in zip(edge, edge.dropFirst()) where b.x > widest + 1e-12 {
            if a.x < widest - 1e-12 {
                out.append(Vec2(widest, a.y + (b.y - a.y) * (widest - a.x) / (b.x - a.x)))
            }
            out.append(b)
            widest = b.x
        }
        return out
    }

    /// How much wider the bit is low down than higher up, at most, over heights from the tip to `depth`: how far a
    /// cut at that depth overhangs the bit, so how far it must move off the wall before it can lift out.
    static func undercut(_ edge: [Vec2], toDepth depth: Double) -> Double {
        var widest = 0.0, most = 0.0
        for q in edge where q.y <= depth + 1e-9 {
            widest = max(widest, q.x)
            most = max(most, widest - q.x)
        }
        return max(most, widest - radius(edge, atHeight: depth))
    }

    /// Side silhouette of a tapered ball nose, form or dovetail bit (`Tool.silhouette`).
    static func silhouette(_ tool: Tool, segments: Int) -> [Vec2] {
        let shank = tool.shankDiameter / 2
        var pts: [Vec2]
        switch tool.shape {
        case .taperedBallNose:
            let b = TaperedBall(tool)
            pts = [Vec2(0, 0)]
            let a1 = min(asin(min(1, b.R / max(b.rho, 1e-9))), .pi / 2 - b.alpha)
            for i in 1...max(1, segments) {
                let a = a1 * Double(i) / Double(max(1, segments))
                pts.append(Vec2(b.rho * sin(a), b.rho - b.rho * cos(a)))
            }
            if b.R > b.tangentRadius + 1e-9 { pts.append(Vec2(b.R, b.height(atRadius: b.R))) }
            let cutTop = max(tool.fluteLength, pts[pts.count - 1].y)
            pts.append(Vec2(b.R, cutTop))
            // The taper carries on above the flutes until it meets the shank.
            let t = tan(b.alpha)
            if shank > b.R + 1e-9, t > 1e-9 {
                pts.append(Vec2(shank, max(cutTop, b.tangentHeight + (shank - b.tangentRadius) / t)))
            } else {
                pts.append(Vec2(shank, cutTop))
            }
        case .form, .dovetail:
            pts = tool.cuttingEdge
            let top = max(tool.fluteLength, pts.last?.y ?? 0)
            if let last = pts.last, last.y < top - 1e-9 { pts.append(Vec2(last.x, top)) }
            pts.append(Vec2(shank, top))
        default:
            return tool.silhouette(segments: segments)
        }
        pts.append(Vec2(shank, max(tool.stickout, pts[pts.count - 1].y)))
        return pts
    }
}

public extension Tool {
    /// The cutting edge of a form, dovetail or tapered ball nose bit, from the axis at the tip outward and up to the top
    /// of the flutes (x = radius, y = height above the tip). Empty for other shapes.
    var cuttingEdge: [Vec2] {
        switch shape {
        case .form:
            return form?.edge(fluteLength: fluteLength) ?? [Vec2(0, 0), Vec2(radius, 0), Vec2(radius, fluteLength)]
        case .dovetail:
            let R = radius
            return [Vec2(0, 0), Vec2(R, 0), Vec2(max(0, R - fluteLength * halfAngleTangent), fluteLength)]
        case .taperedBallNose:
            let b = TaperedBall(self)
            var pts = [Vec2(0, 0)]
            let n = 24
            let a1 = min(asin(min(1, b.R / max(b.rho, 1e-9))), .pi / 2 - b.alpha)
            for i in 1...n {
                let a = a1 * Double(i) / Double(n)
                pts.append(Vec2(b.rho * sin(a), b.rho - b.rho * cos(a)))
            }
            if b.R > b.tangentRadius + 1e-9 { pts.append(Vec2(b.R, b.height(atRadius: b.R))) }
            if let last = pts.last, fluteLength > last.y + 1e-9 { pts.append(Vec2(last.x, fluteLength)) }
            return pts
        default:
            return []
        }
    }

    /// A dovetail's diameter at the top of its flutes (its neck).
    var dovetailSmallDiameter: Double { max(0, diameter - 2 * fluteLength * halfAngleTangent) }

    /// Flat-bottomed seen from below: end mills, surfacing bits and dovetails (widest at their tip).
    var isFlatBottomed: Bool { shape == .flatEndMill || shape == .surfacing || shape == .dovetail }

    /// Whether the bit is wider low down than higher up on its cutting edge (a dovetail, or a form bit that narrows), so
    /// it can't lift straight out of a cut, step down or ramp without cutting into the wall above.
    var hasUndercut: Bool {
        shape.cutsEdgesOnly && ToolProfile.undercut(cuttingEdge, toDepth: fluteLength) > 1e-6
    }

    /// How far a cut `depth` deep overhangs the bit: how far it must move off the wall before lifting out. Past the
    /// flutes the shank counts too.
    func undercut(toDepth depth: Double) -> Double {
        guard shape.cutsEdgesOnly else { return 0 }
        var u = ToolProfile.undercut(cuttingEdge, toDepth: min(depth, fluteLength))
        if depth > fluteLength + 1e-9 {
            let widest = cuttingEdge.map(\.x).max() ?? radius
            u = max(u, widest - shankDiameter / 2)
        }
        return max(0, u)
    }

    /// The diameter that engages a cut `depth` deep (the chip-load chart's diameter): the widest the bit is from its tip
    /// up to that depth. The full diameter for shapes whose width doesn't change with depth.
    func cuttingDiameter(atDepth depth: Double) -> Double {
        switch shape {
        case .taperedBallNose:
            return 2 * radius(atHeight: max(0, min(depth, fluteLength)))
        case .form, .dovetail:
            let d = max(0, min(depth, fluteLength))
            let edge = cuttingEdge
            let widest = edge.filter { $0.y <= d + 1e-9 }.map(\.x).max() ?? 0
            return 2 * max(widest, ToolProfile.radius(edge, atHeight: d))
        default:
            return diameter
        }
    }

    /// Sets the diameter a tapered ball nose or form bit's other dimensions give: a tapered ball nose's at the top of
    /// its flutes (where the taper reaches the shank, if that's lower), a form bit's widest point. Other shapes keep
    /// theirs (a dovetail's diameter is its own, at its tip).
    mutating func fitDiameterToShape() {
        switch shape {
        case .taperedBallNose:
            var wide = self
            wide.diameter = .greatestFiniteMagnitude
            let b = TaperedBall(wide)
            var r = b.coneRadius(atHeight: fluteLength)
            if fluteLength < b.tangentHeight { r = b.radius(atHeight: fluteLength) }
            if shankDiameter > 1e-6 { r = min(r, shankDiameter / 2) }
            diameter = max(0.01, 2 * r)
        case .form:
            guard let f = form else { return }
            diameter = max(0.01, 2 * (f.edge(fluteLength: fluteLength).map(\.x).max() ?? 0))
        default:
            break
        }
    }

    /// Why the bit's dimensions don't describe a bit NativeCAM can cut with, or nil when they do. Only the tapered ball
    /// nose, form and dovetail shapes, whose dimensions depend on each other, are checked.
    var geometryProblem: String? {
        let name = self.name.isEmpty ? "T\(number)" : "'\(self.name)'"
        switch shape {
        case .taperedBallNose:
            if tipDiameter <= 1e-6 { return "\(name) has no tip radius." }
            let half = includedAngle / 2
            if half < 0.1 - 1e-9 || half > 45 + 1e-9 {
                return "\(name)'s taper (\(half.formatted(.number.precision(.fractionLength(0...2))))° per side) is outside 0.1–45°."
            }
            if diameter < TaperedBall(self).tangentRadius * 2 - 0.005 { return "\(name)'s diameter is smaller than its tip." }
        case .dovetail:
            if includedAngle / 2 < 0.5 - 1e-9 { return "\(name) has no dovetail angle: use an end mill." }
            if dovetailSmallDiameter <= 1e-6 {
                return "\(name) narrows to nothing below the top of its flutes: check its angle, diameter and cutting length."
            }
        case .form:
            guard let f = form else { return "\(name) has no profile." }
            if let p = f.problem { return "\(name) \(p)." }
            let widest = 2 * (f.edge(fluteLength: fluteLength).map(\.x).max() ?? 0)
            if abs(widest - diameter) > 0.01 {
                return "\(name)'s diameter doesn't match its profile, which is \(widest.formatted(.number.precision(.fractionLength(0...3)))) mm across."
            }
        default:
            break
        }
        return nil
    }
}

public extension Tool {
    /// The dimensions that set a tapered ball nose, form or dovetail bit apart from others of its diameter, for tool
    /// lists (" 0.5 mm tip, 1.79° per side"); empty for other shapes. `length` formats a length in the job's units.
    func shapeDetail(_ length: (Double) -> String) -> String {
        func degrees(_ d: Double) -> String { "\(d.formatted(.number.precision(.fractionLength(0...2))))°" }
        switch shape {
        case .taperedBallNose:
            return " \(length(tipDiameter / 2)) tip radius, \(degrees(includedAngle / 2)) per side"
        case .dovetail:
            return " \(degrees(includedAngle / 2)), \(length(dovetailSmallDiameter)) neck"
        case .form:
            guard let f = form else { return "" }
            switch f.kind {
            case .roundover, .cove: return " (\(f.kind.label.lowercased()), \(length(f.radius)) radius)"
            case .ogee: return " (ogee, \(length(f.radius)) and \(length(f.upperRadius)) radii)"
            case .custom: return " (custom profile)"
            }
        default:
            return ""
        }
    }
}
