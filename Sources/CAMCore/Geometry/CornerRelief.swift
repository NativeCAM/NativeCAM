import Foundation

/// Dogbone and T-bone reliefs: short out-and-back spikes added to a tool-centre loop at the inside corners a round
/// bit can't reach, so the bit's edge just touches the drawn corner and square parts fit.
///
/// The offset that makes a tool-centre loop rounds every corner the bit can follow (round joins), so a sharp vertex
/// that turns toward the waste is a corner the bit can't reach: the corners of an inside cut or pocket, the inside
/// corners of an outside cut (finger joints, notches, holes in a part) and of islands. Its corner angle θ (180° minus
/// the turn) is the angle of the cut-away wedge, 90° for a square corner.
///
/// The drawn corner is found by casting a ray from the vertex C along the bisector w against the toolpath's own
/// drawn loops, which hits it at H. With o the distance from the drawn wall to the tool centre (radius + allowance),
/// a sharp corner is o / sin(θ/2) from C; a hit farther out isn't a corner but a pinch between separate features (an
/// island near a wall), so it's left alone, as is a corner the bit already reaches (rounded at or above its radius).
/// - Dogbone: out along w to C + (h − o)·w, where the bit just touches H.
/// - T-bone: along one wall's tool line to the point nearest H, so the notch is only in the other wall.
/// A relief that would come within o of any other drawn geometry is skipped and counted.
enum CornerRelief {
    struct Relief: Hashable, Sendable {
        /// The loop vertex the relief leaves from and returns to.
        var corner: Vec2
        /// Where the tool centre goes.
        var tip: Vec2
    }

    struct Plan {
        var reliefs: [Relief] = []
        /// Corners left alone because their relief would cut into other drawn geometry.
        var blocked = 0
    }

    /// Distance tolerance for matching the drawn corner, mm.
    static let tolerance = 0.02
    /// Vertices closer than this count as one corner (tiny chamfers from imported drawings), mm.
    static let mergeDistance = 0.05

    /// A relievable corner of a tool-centre loop, with each relief it could get (already checked against the
    /// drawn geometry).
    struct Corner {
        struct Option {
            /// Where the tool centre goes.
            var tip: Vec2
            /// The relief would cut into other drawn geometry.
            var blocked: Bool
        }
        /// The loop vertex C.
        var vertex: Vec2
        /// The drawn corner H.
        var hit: Design.Hit
        /// Directions of travel along the incoming and outgoing walls.
        var din: Vec2
        var dout: Vec2
        /// Straight runs of the incoming and outgoing walls, and the last-resort tie-break between them.
        var lengthIn: Double
        var lengthOut: Double
        var lowerIsOutgoing: Bool
        var dogbone: Option
        /// T-bones with the notch in each wall; nil where the bit already reaches the corner along that wall.
        var teeIntoIncoming: Option?
        var teeIntoOutgoing: Option?

        enum Pick: Hashable { case asCut, dogbone, teeIntoIncoming, teeIntoOutgoing }

        /// What the toolpath's settings alone would cut here.
        func standard(_ s: CornerReliefSettings) -> Pick {
            switch s.style {
            case .dogbone: return .dogbone
            case .tBone:
                return CornerRelief.notchGoesIntoOutgoingWall(lengthIn: lengthIn, lengthOut: lengthOut, din: din, dout: dout,
                                                              lowerIsOutgoing: lowerIsOutgoing, side: s.tBoneSide)
                    ? .teeIntoOutgoing : .teeIntoIncoming
            }
        }

        func option(_ pick: Pick) -> Option? {
            switch pick {
            case .asCut: nil
            case .dogbone: dogbone
            case .teeIntoIncoming: teeIntoIncoming
            case .teeIntoOutgoing: teeIntoOutgoing
            }
        }
    }

    /// Plans the reliefs for one tool-centre loop from the settings alone (no per-corner choices). `wasteOnLeft` is
    /// the waste side for the loop's direction; `offset` is the distance from the drawn wall to the tool centre
    /// (tool radius + allowance).
    static func plan(_ loop: Polyline, wasteOnLeft: Bool, design: Design, offset o: Double,
                     settings: CornerReliefSettings) -> Plan {
        var plan = Plan()
        for corner in corners(loop, wasteOnLeft: wasteOnLeft, design: design, offset: o, maxCornerAngle: settings.maxCornerAngle) {
            guard let option = corner.option(corner.standard(settings)) else { continue }
            if option.blocked {
                plan.blocked += 1
                continue
            }
            plan.reliefs.append(Relief(corner: corner.vertex, tip: option.tip))
        }
        return plan
    }

    /// The loop's corners the bit can't reach and that are no wider than `maxCornerAngle` (degrees).
    static func corners(_ loop: Polyline, wasteOnLeft: Bool, design: Design, offset o: Double, maxCornerAngle: Double) -> [Corner] {
        let pts = loop.points
        let n = pts.count
        guard loop.isClosed, n >= 3, o > 1e-6, !design.loops.isEmpty else { return [] }
        let maxAngle = min(179, max(1, maxCornerAngle)) * .pi / 180
        // Half a degree of slack, so a corner exactly at the limit (a hexagon at 120°) counts.
        let minTurn = .pi - maxAngle - 0.5 * .pi / 180

        func neighbour(_ i: Int, _ step: Int) -> Int? {
            var j = i
            for _ in 0..<(n - 1) {
                j = (j + step + n) % n
                if pts[j].distance(to: pts[i]) >= mergeDistance { return j }
            }
            return nil
        }
        struct Candidate { var i: Int; var turn: Double; var din: Vec2; var dout: Vec2; var a: Int; var c: Int }
        var candidates: [Candidate] = []
        for i in 0..<n {
            guard let a = neighbour(i, -1), let c = neighbour(i, 1) else { continue }
            let din = (pts[i] - pts[a]).normalized, dout = (pts[c] - pts[i]).normalized
            var turn = atan2(din.cross(dout), din.dot(dout))
            if !wasteOnLeft { turn = -turn }
            guard turn >= minTurn, turn < .pi - 1e-3 else { continue }
            // A corner split over vertices closer than the merge distance: keep its sharpest vertex.
            if let k = candidates.lastIndex(where: { pts[$0.i].distance(to: pts[i]) < mergeDistance }) {
                if turn > candidates[k].turn { candidates[k] = Candidate(i: i, turn: turn, din: din, dout: dout, a: a, c: c) }
                continue
            }
            candidates.append(Candidate(i: i, turn: turn, din: din, dout: dout, a: a, c: c))
        }
        if candidates.count > 1, let first = candidates.first, let last = candidates.last,
           pts[first.i].distance(to: pts[last.i]) < mergeDistance {
            if last.turn > first.turn { candidates[0] = last }
            candidates.removeLast()
        }

        var out: [Corner] = []
        for cand in candidates {
            let c = pts[cand.i]
            let half = (.pi - cand.turn) / 2
            let bisector = cand.din - cand.dout
            guard bisector.length > 1e-9 else { continue }
            let w = bisector.normalized
            let reach = o / sin(half)
            guard let hit = design.ray(from: c, direction: w, maxDistance: reach + tolerance) else { continue }
            let depth = hit.distance - o
            guard depth >= 0.01 else { continue }
            // Both walls must be offsets of the drawn corner's own loop, close to it along that loop; otherwise
            // the sharp vertex is where two separate features (or the two sides of a narrow inlet) meet.
            let window = 2 * reach + tolerance
            let delta = min(o, 0.5 * c.distance(to: pts[cand.a]), 0.5 * c.distance(to: pts[cand.c]))
            guard design.isWall(near: c - cand.din * delta, of: hit, within: window, searchRadius: o + 0.1),
                  design.isWall(near: c + cand.dout * delta, of: hit, within: window, searchRadius: o + 0.1) else { continue }

            func option(_ tip: Vec2) -> Corner.Option {
                Corner.Option(tip: tip, blocked: design.blocks(from: c, to: tip, clearance: o - 0.01, except: hit, within: window + 2 * o))
            }
            // A T-bone travels along one wall's tool line until the bit touches H, so the notch is in the other wall.
            func tee(along e: Vec2) -> Corner.Option? {
                let along = (hit.point - c).dot(e)
                return along >= 0.01 ? option(c + e * along) : nil
            }
            let midIn = (pts[cand.a] + c) * 0.5, midOut = (c + pts[cand.c]) * 0.5
            out.append(Corner(vertex: c, hit: hit, din: cand.din, dout: cand.dout,
                              lengthIn: straightRun(pts, from: cand.i, step: -1, direction: cand.din),
                              lengthOut: straightRun(pts, from: cand.i, step: 1, direction: cand.dout),
                              lowerIsOutgoing: abs(midOut.y - midIn.y) > 1e-9 ? midOut.y < midIn.y : midOut.x < midIn.x,
                              dogbone: option(c + w * depth),
                              teeIntoIncoming: tee(along: -cand.dout), teeIntoOutgoing: tee(along: cand.din)))
        }
        return out
    }

    // MARK: Per-corner choices

    /// An operation's shapes with their outlines, to trace a drawn corner back to the shape it's on.
    struct ShapeIndex {
        struct Entry {
            var shape: DesignShape
            var outlines: [Polyline]
            var bounds: Rect2
            /// Design coordinates to the shape's own.
            var inverse: Transform2D
        }
        let entries: [Entry]

        /// How close a drawn corner must be to a shape's outline to belong to it, mm.
        static let ownerTolerance = 0.05

        init(_ shapes: [DesignShape], tolerance: Double) {
            entries = shapes.compactMap { shape in
                guard let inverse = shape.transform.inverted else { return nil }
                let outlines = shape.polylines(tolerance: tolerance)
                return Entry(shape: shape, outlines: outlines, bounds: outlines.bounds, inverse: inverse)
            }
        }

        /// The shape whose outline passes nearest `p` (ties to the one listed first), and `p` in its coordinates.
        func owner(of p: Vec2) -> (entry: Entry, local: Vec2)? {
            var best: (Entry, Double)?
            for e in entries where e.bounds.contains(p, tolerance: Self.ownerTolerance) {
                for outline in e.outlines {
                    let d = outline.closestPoint(to: p).distance
                    if d <= Self.ownerTolerance, d < (best?.1 ?? .infinity) - 1e-9 { best = (e, d) }
                }
            }
            return best.map { ($0.0, $0.0.inverse.apply(p)) }
        }
    }

    struct Choices {
        var reliefs: [Relief] = []
        var corners: [ReliefCorner] = []
        /// Chosen reliefs left off because they'd cut into other drawn geometry.
        var blocked = 0
    }

    /// Chooses each corner's relief: its own choice when one matches, otherwise the settings. `matched` collects
    /// the indices of the overrides that found their corner.
    static func choose(_ corners: [Corner], settings: CornerReliefSettings, shapes: ShapeIndex, matched: inout Set<Int>) -> Choices {
        let overrides = settings.overrides ?? []
        var out = Choices()
        for corner in corners {
            let owner = shapes.owner(of: corner.hit.point)
            // The two walls in a fixed order (by their angle in the shape's own coordinates), so the same wall has
            // the same number whichever way the loop runs.
            func localAngle(_ v: Vec2) -> Double {
                let u = owner.map { $0.entry.inverse.applyLinear(v) } ?? v
                var a = u.angle * 180 / .pi
                a = a.truncatingRemainder(dividingBy: 180)
                if a < 0 { a += 180 }
                return a >= 180 - 1e-9 ? 0 : a
            }
            var walls = [(wall: ReliefCorner.Wall(direction: corner.din, localAngle: localAngle(corner.din)), pick: Corner.Pick.teeIntoIncoming),
                         (wall: ReliefCorner.Wall(direction: corner.dout, localAngle: localAngle(corner.dout)), pick: Corner.Pick.teeIntoOutgoing)]
            if walls[1].wall.localAngle < walls[0].wall.localAngle - 1e-9 { walls.swapAt(0, 1) }
            func relief(_ pick: Corner.Pick) -> ReliefCorner.Relief {
                switch pick {
                case .asCut: .asCut
                case .dogbone: .dogbone
                case .teeIntoIncoming, .teeIntoOutgoing: .tBone(wall: walls.firstIndex { $0.pick == pick } ?? 0)
                }
            }

            let standard = corner.standard(settings)
            var pick = standard
            if let owner {
                let reach = ShapeIndex.ownerTolerance / max(abs(owner.entry.shape.scale), 1e-6)
                let candidates = overrides.indices.filter { overrides[$0].shapeID == owner.entry.shape.id }
                if let k = candidates.min(by: { overrides[$0].point.distance(to: owner.local) < overrides[$1].point.distance(to: owner.local) }),
                   overrides[k].point.distance(to: owner.local) <= reach {
                    matched.insert(k)
                    switch overrides[k].choice {
                    case .asCut: pick = .asCut
                    case .dogbone: pick = .dogbone
                    case let .tBone(angle):
                        func gap(_ a: Double) -> Double {
                            let d = abs(a - angle).truncatingRemainder(dividingBy: 180)
                            return min(d, 180 - d)
                        }
                        pick = gap(walls[0].wall.localAngle) <= gap(walls[1].wall.localAngle) ? walls[0].pick : walls[1].pick
                    }
                }
            }
            let option = corner.option(pick)
            let blocked = option?.blocked ?? false
            let tip = blocked ? nil : option?.tip
            if let tip { out.reliefs.append(Relief(corner: corner.vertex, tip: tip)) }
            if blocked { out.blocked += 1 }
            out.corners.append(ReliefCorner(point: corner.hit.point, walls: walls.map(\.wall), relief: relief(pick),
                                            standard: relief(standard), tip: tip, blocked: blocked,
                                            shapeID: owner?.entry.shape.id, localPoint: owner?.local ?? corner.hit.point))
        }
        return out
    }

    /// Checks messages for corners left off and for choices that no longer find their corner.
    static func warnings(blocked: Int, unmatched: Int) -> [String] {
        var out: [String] = []
        if blocked > 0 {
            out.append(blocked == 1 ? "1 corner wasn't relieved: its relief would cut into nearby geometry."
                : "\(blocked) corners weren't relieved: their reliefs would cut into nearby geometry.")
        }
        if unmatched > 0 {
            out.append(unmatched == 1
                ? "1 corner choice no longer matches a corner (its shape changed or left this toolpath), so it's ignored. Reset it under Corners."
                : "\(unmatched) corner choices no longer match a corner (their shapes changed or left this toolpath), so they're ignored. Reset them under Corners.")
        }
        return out
    }

    /// Adds each relief's out-and-back spike at its corner vertex.
    static func insert(_ reliefs: [Relief], into loop: Polyline) -> Polyline {
        guard !reliefs.isEmpty, loop.isClosed else { return loop }
        var out: [Vec2] = []
        out.reserveCapacity(loop.count + reliefs.count * 2)
        for p in loop.points {
            out.append(p)
            if let r = reliefs.first(where: { $0.corner.isApprox(p, tolerance: 1e-9) }) {
                out.append(r.tip)
                out.append(p)
            }
        }
        return Polyline(out, closed: true)
    }

    /// T-bone side: decided from the walls themselves (their length or direction), never from the direction of
    /// travel, so climb and conventional cut the same notch. `lowerIsOutgoing` breaks ties between walls alike in
    /// every way (the wall whose midpoint is lower, then further left).
    static func notchGoesIntoOutgoingWall(lengthIn lenIn: Double, lengthOut lenOut: Double, din: Vec2, dout: Vec2,
                                          lowerIsOutgoing: Bool, side: TBoneSide) -> Bool {
        func alongX() -> Bool {
            let ax = abs(dout.x) - abs(din.x)
            return abs(ax) > 1e-9 ? ax > 0 : lowerIsOutgoing
        }
        func alongY() -> Bool {
            let ay = abs(dout.y) - abs(din.y)
            return abs(ay) > 1e-9 ? ay > 0 : lowerIsOutgoing
        }
        switch side {
        case .longer: return abs(lenOut - lenIn) > 1e-6 ? lenOut > lenIn : alongX()
        case .shorter: return abs(lenOut - lenIn) > 1e-6 ? lenOut < lenIn : alongX()
        case .alongX: return alongX()
        case .alongY: return alongY()
        }
    }

    /// Length of the straight run of the loop leaving vertex `i` (backward for step −1), within 2° of `direction`.
    static func straightRun(_ pts: [Vec2], from i: Int, step: Int, direction: Vec2) -> Double {
        let n = pts.count
        let limit = cos(2 * Double.pi / 180)
        var total = 0.0
        var j = i
        for _ in 0..<n {
            let k = (j + step + n) % n
            let seg = step > 0 ? pts[k] - pts[j] : pts[j] - pts[k]
            let l = seg.length
            if l > 1e-12 {
                if (seg / l).dot(direction) < limit { break }
                total += l
            }
            j = k
            if j == i { break }
        }
        return total
    }

    // MARK: Drawn geometry

    /// The drawn loops a toolpath was offset from, indexed for ray casts and nearest-point queries.
    struct Design {
        let loops: [Polyline]
        let bounds: [Rect2]
        /// cumulative[k][j]: arc length from loop k's first point to its point j; the last entry is the length.
        let cumulative: [[Double]]

        init(_ loops: [Polyline]) {
            let closed = loops.filter { $0.isClosed && $0.count >= 2 }
            self.loops = closed
            bounds = closed.map(\.bounds)
            cumulative = closed.map { l in
                var c = [0.0]
                c.reserveCapacity(l.count + 1)
                for j in 0..<l.count { c.append(c[j] + l.points[j].distance(to: l.points[(j + 1) % l.count])) }
                return c
            }
        }

        struct Hit {
            var distance: Double
            var point: Vec2
            var loop: Int
            /// Arc-length position of the hit along its loop.
            var s: Double
        }

        /// First drawn boundary along a ray, within `maxDistance`.
        func ray(from o: Vec2, direction w: Vec2, maxDistance: Double) -> Hit? {
            let reach = Rect2.empty.union(o).union(o + w * maxDistance)
            var best: Hit?
            for (k, loop) in loops.enumerated() where bounds[k].intersects(reach) {
                let p = loop.points
                for j in 0..<p.count {
                    let a = p[j], b = p[(j + 1) % p.count]
                    let e = b - a
                    let denom = w.cross(e)
                    guard abs(denom) > 1e-12 else { continue }
                    let ao = a - o
                    let t = ao.cross(e) / denom
                    let u = ao.cross(w) / denom
                    guard t >= 0, t <= maxDistance, u >= -1e-9, u <= 1 + 1e-9 else { continue }
                    if t < (best?.distance ?? .infinity) {
                        let uc = min(1, max(0, u))
                        best = Hit(distance: t, point: a + e * uc, loop: k, s: cumulative[k][j] + e.length * uc)
                    }
                }
            }
            return best
        }

        /// Arc distance along loop k between position s and the stretch [s0, s1].
        func along(_ k: Int, _ s: Double, _ s0: Double, _ s1: Double) -> Double {
            if s >= s0 && s <= s1 { return 0 }
            let L = cumulative[k].last ?? 0
            func circ(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, L - d) }
            return min(circ(s, s0), circ(s, s1))
        }

        /// Whether the drawn boundary nearest `p` is on the hit's loop within `window` of it (so the tool edge at
        /// `p` is an offset of the corner's own wall).
        func isWall(near p: Vec2, of hit: Hit, within window: Double, searchRadius: Double) -> Bool {
            var bestD = Double.infinity, bestLoop = -1, bestS = 0.0
            for (k, loop) in loops.enumerated() where bounds[k].contains(p, tolerance: searchRadius) {
                let c = loop.closestPoint(to: p)
                if c.distance < bestD {
                    bestD = c.distance
                    bestLoop = k
                    let a = loop.points[c.segment], b = loop.points[(c.segment + 1) % loop.count]
                    bestS = cumulative[k][c.segment] + a.distance(to: b) * c.t
                }
            }
            guard bestLoop == hit.loop, bestD <= searchRadius else { return false }
            return along(bestLoop, bestS, hit.s, hit.s) <= window
        }

        /// Whether the straight move a→b passes within `clearance` of drawn geometry other than the stretch of the
        /// hit's loop within `window` of it.
        func blocks(from a: Vec2, to b: Vec2, clearance: Double, except hit: Hit, within window: Double) -> Bool {
            let box = Rect2.empty.union(a).union(b).insetBy(-clearance)
            for (k, loop) in loops.enumerated() where bounds[k].intersects(box) {
                let p = loop.points
                for j in 0..<p.count {
                    let q0 = p[j], q1 = p[(j + 1) % p.count]
                    if k == hit.loop, along(k, hit.s, cumulative[k][j], cumulative[k][j + 1]) <= window { continue }
                    if segmentDistance(a, b, q0, q1) < clearance { return true }
                }
            }
            return false
        }
    }

    static func segmentDistance(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(distancePointSegment(a, c, d), distancePointSegment(b, c, d),
                   distancePointSegment(c, a, b), distancePointSegment(d, a, b))
    }
}

/// An inside corner a toolpath relieves (or was told not to), for showing and changing it on the canvas.
public struct ReliefCorner: Hashable, Codable, Sendable {
    public enum Relief: Hashable, Codable, Sendable {
        /// Left as the bit cuts it.
        case asCut
        case dogbone
        /// A T-bone with its notch in `walls[wall]`.
        case tBone(wall: Int)
    }

    public struct Wall: Hashable, Codable, Sendable {
        /// Unit direction of the wall, design coordinates.
        public var direction: Vec2
        /// The wall's direction in its shape's own coordinates, degrees in [0, 180).
        public var localAngle: Double
    }

    /// The drawn corner, design XY.
    public var point: Vec2
    /// Its two walls, in a fixed order.
    public var walls: [Wall]
    /// The relief this corner gets.
    public var relief: Relief
    /// The relief the toolpath's settings alone would give it.
    public var standard: Relief
    /// Where the bit's centre goes for the relief; nil when nothing is cut here.
    public var tip: Vec2?
    /// The chosen relief would cut into other geometry, so it's left off.
    public var blocked: Bool
    /// The shape the corner is on, and the corner in that shape's own coordinates.
    public var shapeID: UUID?
    public var localPoint: Vec2

    /// The corner has its own choice.
    public var isChanged: Bool { relief != standard }

    /// The relief after this one when stepping through them: dogbone, T-bone into each wall, none.
    public var nextRelief: Relief {
        let order: [Relief] = [.dogbone, .tBone(wall: 0), .tBone(wall: 1), .asCut]
        let i = order.firstIndex(of: relief) ?? -1
        return order[(i + 1) % order.count]
    }
}

public extension CornerReliefSettings {
    /// These settings with `corner` given `relief`; nil, or the relief the settings already give it, puts the corner
    /// back to following the settings.
    func setting(_ relief: ReliefCorner.Relief?, for corner: ReliefCorner) -> CornerReliefSettings {
        var s = self
        var list = (overrides ?? []).filter {
            !($0.shapeID == corner.shapeID && $0.point.distance(to: corner.localPoint) <= CornerRelief.ShapeIndex.ownerTolerance)
        }
        if let relief, relief != corner.standard, let id = corner.shapeID {
            let choice: CornerOverride.Choice
            switch relief {
            case .asCut: choice = .asCut
            case .dogbone: choice = .dogbone
            case let .tBone(wall): choice = .tBone(wallAngle: corner.walls[min(max(wall, 0), corner.walls.count - 1)].localAngle)
            }
            list.append(CornerOverride(shapeID: id, point: corner.localPoint, choice: choice))
        }
        s.overrides = list.isEmpty ? nil : list
        return s
    }
}
