import Foundation

/// What "Adjust feeds for load" did to a toolpath (see `FeedScheduler`), for the inspector and the setup sheet.
public struct LoadFeeds: Hashable, Codable, Sendable {
    /// The feed the toolpath was programmed with, mm/min.
    public var programmed: Double
    /// The slowest feed it now cuts at, mm/min (`programmed` when nothing needed slowing).
    public var lowest: Double
    /// The engagement taken as the toolpath's usual cut, degrees of the bit's edge (90° is half its width).
    public var usualEngagement: Double
    /// Where the chart's thinnest chip for the bit held a slowdown back: the share of the programmed feed the load
    /// called for, and the share it got. nil when it never did.
    public var wanted: Double?
    public var held: Double?

    public init(programmed: Double, lowest: Double, usualEngagement: Double, wanted: Double? = nil, held: Double? = nil) {
        self.programmed = programmed
        self.lowest = lowest
        self.usualEngagement = usualEngagement
        self.wanted = wanted
        self.held = held
    }

    /// True when some of the toolpath cuts slower than programmed.
    public var varies: Bool { lowest < programmed - 1e-6 }
}

/// Feeds that follow the load: "Adjust feeds for load" on a profile or pocket (`CAMOperation.adjustFeedsForLoad`).
///
/// One feed for a whole toolpath has to suit its hardest cut: a pocket's first, full-width pass, the material an
/// offset ring meets in an inside corner, a tight inside arc. Slowing the whole toolpath for those costs time and
/// thins the chip everywhere else; this slows only them.
///
/// - **Engagement.** How much of the bit's edge is in material at each point, as the angle φ it spans (0–180°; 90° is
///   half the bit's width), measured on the bit's leading half every eighth of a diameter. The material is the
///   model of the job before this toolpath (`HeightGrid`), less what this toolpath has already swept at or above the
///   tip's height: the union of the bit's discs along each earlier move, the region Clipper2's round-ended offset of
///   the path would give, tested exactly by distance from each move through a spatial grid rather than by a polygon
///   union per move. That covers first passes in solid wood, offset rings, the corners an inside-out pocket leaves,
///   ramps, tabs and earlier toolpaths' cuts (those at the model's 0.5–1 mm resolution).
/// - **The usual cut.** The programmed feed is taken to be right for the toolpath's usual cut, the median engagement
///   along it: a pocket's offset rings; a finishing pass's light cut; for a profile cutting a part out of solid wood,
///   a full-width slot all the way round, which then keeps its feed.
/// - **Feed rule**, where the bit is engaged more than usual (φ > φ₀):
///   - the chip: hold it at the usual cut's, F·sin φ₀ / sin φ with both angles capped at 90° (radial chip thinning);
///   - the load: past half the bit's width the chip stops growing but the force on the bit doesn't (it goes as
///     1 − cos φ), so the feed falls with the square root of the extra force, sharing it equally between a thinner chip
///     and a higher load: a full-width slot after half-width cuts runs at 1/√2;
///   - never below 55% for load, nor where the chip would be thinner than the chart's minimum for the bit in the job's
///     material (`ChipLoad`, the same floor its chip-load check uses): thinner chips rub and burn wood;
///   - a profile's inside arcs (material on the arc's outside only): the edge on the outside travels (ρ + r)/ρ as fast
///     as the centre, so the centre's feed is F·(R − r)/R, R = ρ + r being the outer wall's radius. A pocket's rings
///     follow the engagement alone, which already rises on a concave ring. Outside arcs (material on the centre's
///     side) are left alone, and so is a slot round an arc, where the thinner chip inside makes up for the
///     thicker one outside, and an arc tighter than half the bit's radius (a pocket's smoothed corners), where the bit
///     pivots inside its own width: that's a corner, which the engagement covers;
///   - never faster than the programmed feed, and a slowed move no faster than the machine's maximum.
/// - **Few F words.** Each move's share is rounded down to one of `levels` (taking the faster one within 10%); an arc
///   keeps one feed (the slowest any point of it needs); a slowdown starts a sample early and holds until the cut has
///   run at the faster level's share without the 10%; and every stretch at one feed but the last before a plunge or
///   retract is at least half a diameter long: a shorter slowdown runs on, a shorter speed-up is dropped. Lines are
///   split where the feed changes; arcs never are. How Mach4 blends through a change of F is unmeasured.
///
/// Wrapped rotary toolpaths are fed in inverse time (G93) and keep the programmed feed. Spindle speed doesn't change.
public enum FeedScheduler {
    /// The shares of the programmed feed a toolpath can run at, fastest first.
    public static let levels: [Double] = [1, 0.85, 0.70, 0.55, 0.45, 0.35, 0.25]
    /// The slowest share a load reduction goes to (inside arcs can go slower).
    public static let minimumLoadShare = 0.55
    /// A share within this much (relative) of the next level up takes that level.
    static let roundingTolerance = 0.10
    /// Points sampled on the bit's leading half per engagement measurement (5° each).
    static let directions = 36
    /// Engagement below this many degrees counts as cutting air (links, cleared areas) for the usual cut.
    static let engagedAngle = 10.0
    /// Material within this much of the tip's height counts as cut (mm).
    static let zTolerance = 0.01
    /// Arcs whose centre radius is less than this share of the bit's radius are corners, not inside arcs.
    public static let minimumArcRadius = 0.5

    /// Bits whose side cuts straight up and down, so the engagement in plan is the whole story: end mills, bull noses
    /// and surfacing bits.
    public static func suits(_ tool: Tool) -> Bool {
        switch tool.shape {
        case .flatEndMill, .bullNose, .surfacing: true
        case .ballNose, .vBit, .engraving, .drill: false
        }
    }

    /// Spacing of the engagement samples along the path, mm.
    public static func sampleSpacing(_ tool: Tool) -> Double { min(1, max(0.25, tool.diameter / 8)) }

    /// Shortest stretch at one feed, mm.
    public static func minimumRun(_ tool: Tool) -> Double { max(tool.diameter / 2, 2) }

    /// Inside-arc compensation: the share of the feed at the tool's centre that moves the edge on the arc's outside at
    /// the full feed, F_centre = F·(R − r)/R, where `pathRadius` ρ is the centre's radius and R = ρ + r the outer wall's.
    public static func insideArcFactor(pathRadius rho: Double, toolRadius r: Double) -> Double {
        guard rho > 1e-9 else { return 0 }
        let R = rho + max(0, r)
        return (R - r) / R
    }

    /// The share of the programmed feed for engagement `phi` when the usual cut is `usual` (degrees).
    public static func loadShare(engagement phi: Double, usual: Double) -> Double {
        guard phi > usual + 1e-9 else { return 1 }
        let rad = Double.pi / 180
        let s0 = sin(min(usual, 90) * rad), s1 = sin(min(phi, 90) * rad)
        let chip = s1 > 1e-12 ? s0 / s1 : 1
        let ref = max(usual, 90)
        let force = phi > ref + 1e-9 ? ((1 - cos(ref * rad)) / (1 - cos(phi * rad))).squareRoot() : 1
        return min(1, chip, force)
    }

    /// Index into `levels` for share `k`: the fastest level no more than `tolerance` above it, and no slower than
    /// `floor` allows.
    static func level(_ k: Double, floor: Double = 0, tolerance: Double = roundingTolerance) -> Int {
        var i = levels.firstIndex { $0 <= k * (1 + tolerance) + 1e-12 } ?? levels.count - 1
        while i > 0 && levels[i] < floor - 1e-9 { i -= 1 }
        return i
    }

    // MARK: Engagement

    /// Degrees of the bit's leading half in material on each side of its direction of travel.
    struct Engagement: Hashable {
        var left: Double
        var right: Double
        var total: Double { left + right }
    }

    /// The region a toolpath has cut so far: every move's swept disc, each clearing everything above the height its
    /// tip was at (the highest along it, so a ramp's sweep is split into short pieces).
    struct SweptRegion {
        struct Piece {
            var a: Vec2
            var b: Vec2
            /// Arcs only: the centre, the radius (negative for a line), the start angle and the signed sweep.
            var center = Vec2.zero
            var radius = -1.0
            var startAngle = 0.0
            var sweep = 0.0
            /// The piece clears all material at or above this height.
            var z: Double
        }

        let r: Double
        let cell: Double
        private(set) var pieces: [Piece] = []
        private var buckets: [SIMD2<Int32>: [Int32]] = [:]

        init(toolRadius: Double) {
            r = toolRadius
            cell = max(2 * toolRadius, 0.5)
        }

        func key(_ p: Vec2) -> SIMD2<Int32> {
            SIMD2(Int32(clamping: Int((p.x / cell).rounded(.down))), Int32(clamping: Int((p.y / cell).rounded(.down))))
        }

        /// Files `piece` under every grid cell within one of the cells of `points` (spaced at most half a cell apart
        /// along it), which holds every cell with a point within the tool's radius of it.
        private mutating func insert(_ piece: Piece, along points: [Vec2]) {
            let index = Int32(pieces.count)
            pieces.append(piece)
            var keys = Set<SIMD2<Int32>>()
            for p in points {
                let k = key(p)
                for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { keys.insert(k &+ SIMD2(dx, dy)) } }
            }
            for k in keys { buckets[k, default: []].append(index) }
        }

        mutating func addLine(_ a: Vec3, _ b: Vec3, spacing: Double) {
            let len = a.xy.distance(to: b.xy)
            if len < 1e-9 {
                // Straight down (or up): the bottom of the move clears its whole column.
                insert(Piece(a: a.xy, b: a.xy, z: min(a.z, b.z)), along: [a.xy])
                return
            }
            // A ramp clears less under its high end: in pieces, each clearing above its higher end.
            let pieces = abs(b.z - a.z) > zTolerance ? max(1, Int((len / spacing).rounded(.up))) : 1
            for k in 0..<pieces {
                let p = a.lerp(to: b, Double(k) / Double(pieces)), q = a.lerp(to: b, Double(k + 1) / Double(pieces))
                let n = max(1, Int((p.xy.distance(to: q.xy) / (cell / 2)).rounded(.up)))
                insert(Piece(a: p.xy, b: q.xy, z: max(p.z, q.z)), along: (0...n).map { p.xy.lerp(to: q.xy, Double($0) / Double(n)) })
            }
        }

        mutating func addArc(from s: Vec3, _ m: Motion, spacing: Double) {
            let c = m.center
            let rho = s.xy.distance(to: c)
            let sweep = m.arcSweep(from: s)
            let a0 = (s.xy - c).angle
            let length = abs(sweep) * rho
            guard rho > 1e-9, length > 1e-9 else { addLine(s, m.end, spacing: spacing); return }
            let pieces = abs(m.end.z - s.z) > zTolerance ? max(1, Int((length / spacing).rounded(.up))) : 1
            for k in 0..<pieces {
                let t0 = Double(k) / Double(pieces), t1 = Double(k + 1) / Double(pieces)
                let start = a0 + sweep * t0, part = sweep * (t1 - t0)
                let z = max(s.z + (m.end.z - s.z) * t0, s.z + (m.end.z - s.z) * t1)
                let n = max(1, Int((abs(part) * rho / (cell / 2)).rounded(.up)))
                let pts = (0...n).map { c + Vec2.fromAngle(start + part * Double($0) / Double(n), length: rho) }
                insert(Piece(a: pts[0], b: pts[pts.count - 1], center: c, radius: rho, startAngle: start, sweep: part, z: z), along: pts)
            }
        }

        mutating func add(_ m: Motion, from s: Vec3, spacing: Double) {
            switch m.kind {
            case .feed: addLine(s, m.end, spacing: spacing)
            case .arcCW, .arcCCW: addArc(from: s, m, spacing: spacing)
            case .rapid, .dwell: break
            }
        }

        /// True when `q` was swept by a piece that clears height `z`.
        func covers(_ q: Vec2, z: Double, cache: inout (key: SIMD2<Int32>, list: [Int32]?)) -> Bool {
            let k = key(q)
            if k != cache.key { cache = (k, buckets[k]) }
            guard let list = cache.list else { return false }
            let limit = r - 1e-6
            for i in list {
                let p = pieces[Int(i)]
                guard p.z <= z + zTolerance else { continue }
                if Self.distance(q, p) < limit { return true }
            }
            return false
        }

        static func distance(_ q: Vec2, _ p: Piece) -> Double {
            if p.radius < 0 {
                let ab = p.b - p.a
                let l2 = ab.lengthSquared
                guard l2 > 1e-18 else { return q.distance(to: p.a) }
                let t = max(0, min(1, (q - p.a).dot(ab) / l2))
                return q.distance(to: p.a + ab * t)
            }
            let v = q - p.center
            let d = v.length
            var off = v.angle - p.startAngle
            if p.sweep >= 0 {
                off = off.truncatingRemainder(dividingBy: 2 * .pi)
                if off < 0 { off += 2 * .pi }
                if off <= p.sweep { return abs(d - p.radius) }
            } else {
                off = (-off).truncatingRemainder(dividingBy: 2 * .pi)
                if off < 0 { off += 2 * .pi }
                if off <= -p.sweep { return abs(d - p.radius) }
            }
            return min(q.distance(to: p.a), q.distance(to: p.b))
        }
    }

    /// Unit offsets (forward, left) of the points sampled on the bit's leading half, right side first.
    static let leadingHalf: [(forward: Double, left: Double)] = (0..<directions).map { i in
        let theta = -Double.pi / 2 + (Double(i) + 0.5) * Double.pi / Double(directions)
        return (cos(theta), sin(theta))
    }

    /// Engagement of a bit of the region's radius at `p` with its tip at `z`, moving along unit `t`. `material` gives
    /// the top of the material before this toolpath (nil off the stock); `floorZ` is the stock's bottom.
    static func engagement(at p: Vec2, z: Double, direction t: Vec2, region: SweptRegion,
                           material: (Vec2) -> Double?, floorZ: Double) -> Engagement {
        let n = t.perpLeft
        let r = region.r
        let above = max(z, floorZ) + zTolerance
        var left = 0, right = 0
        var cache: (key: SIMD2<Int32>, list: [Int32]?) = (SIMD2(Int32.min, Int32.min), nil)
        for (i, u) in leadingHalf.enumerated() {
            let q = p + t * (r * u.forward) + n * (r * u.left)
            guard let top = material(q), top > above, !region.covers(q, z: z, cache: &cache) else { continue }
            if i < directions / 2 { right += 1 } else { left += 1 }
        }
        let step = 180.0 / Double(directions)
        return Engagement(left: Double(left) * step, right: Double(right) * step)
    }

    // MARK: Scheduling

    /// How the scheduler treats a move.
    enum Role {
        /// A line or arc at the programmed feed that moves in XY: measured and slowed where it needs to be.
        case measured
        /// A straight up-and-down move at the programmed feed (a tab's step up): it takes the feed of the cut around it,
        /// so it doesn't add F words of its own.
        case neutral
    }

    /// The scheduler's role for `m`, or nil for a move it leaves alone (rapids, dwells, plunges and other feeds).
    static func role(_ m: Motion, from s: Vec3, programmed: Double) -> Role? {
        guard m.kind == .feed || m.kind.isArc, m.inverseTime == nil, m.a == nil,
              abs(m.feed - programmed) <= 1e-6 * max(1, programmed) else { return nil }
        return m.kind.isArc || s.xy.distance(to: m.end.xy) > 1e-6 ? .measured : .neutral
    }

    struct SamplePoint { var p: Vec2; var z: Double; var t: Vec2 }

    /// Points along a move, at most `spacing` apart, both ends included, with the direction of travel at each.
    static func samplePoints(_ m: Motion, from s: Vec3, spacing: Double) -> [SamplePoint] {
        if m.kind.isArc {
            let c = m.center
            let rho = s.xy.distance(to: c)
            let sweep = m.arcSweep(from: s)
            let a0 = (s.xy - c).angle
            let n = max(2, Int((abs(sweep) * rho / spacing).rounded(.up)))
            return (0...n).map { j in
                let f = Double(j) / Double(n)
                let radial = Vec2.fromAngle(a0 + sweep * f)
                return SamplePoint(p: c + radial * rho, z: s.z + (m.end.z - s.z) * f,
                                   t: sweep > 0 ? radial.perpLeft : radial.perpRight)
            }
        }
        let d = m.end.xy - s.xy
        let t = d.normalized
        let n = max(1, Int((d.length / spacing).rounded(.up)))
        return (0...n).map { j in
            let f = Double(j) / Double(n)
            return SamplePoint(p: s.xy.lerp(to: m.end.xy, f), z: s.z + (m.end.z - s.z) * f, t: t)
        }
    }

    /// One schedulable move, measured.
    struct Cut {
        var index: Int
        var start: Vec3
        var engagements: [Engagement]
        var length: Double
    }

    /// One piece of a cut at one feed: a stretch between two samples of a line, or a whole arc.
    struct Atom {
        var length: Double
        /// Level index rounding down with the tolerance (going slower), and without it (going back up); -1 for a
        /// neutral move, which takes the level around it.
        var down: Int
        var up: Int
    }

    /// `tp` with its cutting feeds slowed where the bit is loaded more than in its usual cut. `material` is the top of
    /// the material before this toolpath at a point (nil off the stock) and `floorZ` the stock's bottom; `chipFloor` is
    /// the thinnest chip (mm per tooth) to allow a load reduction to make, nil for none; `maxFeed` the machine's.
    /// `insideArcs` compensates inside arcs (contours: profiles); a pocket's rings follow the engagement alone, which
    /// already rises on a concave ring.
    static func schedule(_ tp: Toolpath, material: (Vec2) -> Double?, floorZ: Double = -.infinity, chipFloor: Double?,
                         maxFeed: Double, insideArcs: Bool = true) -> Toolpath {
        let tool = tp.tool
        let r = tool.radius
        let programmed = tool.cutting.feedRate
        guard r > 1e-6, programmed > 0, !tp.motions.isEmpty else { return tp }
        let spacing = sampleSpacing(tool)

        // Measure every schedulable move against what the toolpath had cut before it.
        var region = SweptRegion(toolRadius: r)
        var cuts: [Int: Cut] = [:]
        var neutral = Set<Int>()
        var position = tp.start
        for (i, m) in tp.motions.enumerated() {
            switch role(m, from: position, programmed: programmed) {
            case .measured:
                let points = samplePoints(m, from: position, spacing: spacing)
                let e = points.map { engagement(at: $0.p, z: $0.z, direction: $0.t, region: region, material: material, floorZ: floorZ) }
                cuts[i] = Cut(index: i, start: position, engagements: e, length: m.length(from: position))
            case .neutral: neutral.insert(i)
            case nil: break
            }
            region.add(m, from: position, spacing: spacing)
            position = m.end
        }
        guard !cuts.isEmpty else { return tp }

        // The usual cut: the median engagement along the cuts that are in material (in move order, so ties always
        // resolve the same way).
        var weighted: [(phi: Double, w: Double)] = []
        for index in cuts.keys.sorted() {
            let cut = cuts[index]!
            let w = cut.length / Double(cut.engagements.count)
            for e in cut.engagements where e.total >= engagedAngle { weighted.append((e.total, w)) }
        }
        guard !weighted.isEmpty else {
            var out = tp
            out.loadFeeds = LoadFeeds(programmed: programmed, lowest: programmed, usualEngagement: 0)
            return out
        }
        weighted.sort { $0.phi < $1.phi }
        let half = weighted.reduce(0) { $0 + $1.w } / 2
        var acc = 0.0
        var usual = weighted[weighted.count - 1].phi
        for s in weighted {
            acc += s.w
            if acc >= half { usual = s.phi; break }
        }

        // Shares per sample: the load rule held at 55% and the chip floor.
        let fz = tp.spindleRPM > 0 && tool.fluteCount > 0 ? programmed / (tp.spindleRPM * Double(tool.fluteCount)) : 0
        func floorShare(_ e: Engagement) -> Double {
            guard let chipFloor, fz > 0 else { return 0 }
            let s = sin(min(e.total, 90) * .pi / 180)
            return s > 1e-9 ? min(1, chipFloor / (fz * s)) : 0
        }
        var wanted: Double?, held: Double?
        /// Levels (rounding down, and without the tolerance) one sample needs, its centre feed scaled by `factor`.
        /// The load share is held at 55% and where the chip at the sample's engagement would be too thin; the edge's
        /// chip is the load share's whatever an arc does to the centre's feed.
        func need(_ e: Engagement, factor: Double = 1) -> (down: Int, up: Int) {
            let k = loadShare(engagement: e.total, usual: usual)
            let chip = floorShare(e)
            let floor = k < 1 - 1e-12 ? max(minimumLoadShare, chip) : chip
            let load = max(k, floor)
            let lowest = max(levels[levels.count - 1], floor * factor)
            let down = level(load * factor, floor: lowest)
            if factor >= 1 - 1e-9, chip > max(k, minimumLoadShare) + 1e-9, level(max(k, minimumLoadShare)) > down {
                wanted = min(wanted ?? 1, levels[level(max(k, minimumLoadShare))])
                held = min(held ?? 1, levels[down])
            }
            return (down, level(load * factor, floor: lowest, tolerance: 0))
        }
        func atoms(_ cut: Cut, motion m: Motion) -> [Atom] {
            let e = cut.engagements
            if m.kind.isArc {
                // An inside arc cuts on its outside (right of a CCW arc's direction, left of a CW one's) and not on its
                // centre's side: in a slot round an arc the thicker chip outside is matched by a thinner one inside, so
                // the bit is loaded as in a straight slot. An arc tighter than half the bit's radius (a smoothed corner)
                // is a corner: the bit pivots inside its own width, and the engagement there is what loads it.
                // Judged where the outside cuts (a ramp's first samples are above the wood on both sides).
                let ccw = m.kind == .arcCCW
                let cutting = e.filter { (ccw ? $0.right : $0.left) >= engagedAngle }
                let alone = cutting.filter { (ccw ? $0.left : $0.right) < engagedAngle }.count
                let rho = cut.start.xy.distance(to: m.center)
                let factor = insideArcs && 2 * alone > cutting.count && rho >= minimumArcRadius * r
                    ? insideArcFactor(pathRadius: rho, toolRadius: r) : 1
                // One feed for the whole arc: the slowest any point of it needs.
                let needs = e.map { need($0, factor: factor) }
                return [Atom(length: cut.length, down: needs.map(\.down).max() ?? 0, up: needs.map(\.up).max() ?? 0)]
            }
            let needs = e.map { need($0) }
            let n = e.count - 1
            return (0..<n).map { j in
                Atom(length: cut.length / Double(n), down: max(needs[j].down, needs[j + 1].down), up: max(needs[j].up, needs[j + 1].up))
            }
        }

        // Chains of consecutive cuts; anything else between them (a plunge, a rapid) changes the F word anyway.
        let minimum = minimumRun(tool)
        var chosen: [Int: [Int]] = [:]
        var i = 0
        while i < tp.motions.count {
            guard cuts[i] != nil || neutral.contains(i) else { i += 1; continue }
            var chain: [(motion: Int, atoms: [Atom])] = []
            var p = i > 0 ? tp.motions[i - 1].end : tp.start
            while i < tp.motions.count, cuts[i] != nil || neutral.contains(i) {
                if let cut = cuts[i] {
                    chain.append((i, atoms(cut, motion: tp.motions[i])))
                } else {
                    chain.append((i, [Atom(length: tp.motions[i].length(from: p), down: -1, up: -1)]))
                }
                p = tp.motions[i].end
                i += 1
            }
            let flat = chain.flatMap(\.atoms)
            let levelsOut = runs(flat, minimum: minimum)
            var k = 0
            for c in chain {
                chosen[c.motion] = Array(levelsOut[k..<(k + c.atoms.count)])
                k += c.atoms.count
            }
        }

        // Rewrite the moves: lines split where their feed changes, arcs whole.
        func feed(_ level: Int) -> Double { level == 0 ? programmed : min(levels[level] * programmed, maxFeed) }
        var motions: [Motion] = []
        motions.reserveCapacity(tp.motions.count)
        var lowest = programmed
        position = tp.start
        for (index, m) in tp.motions.enumerated() {
            defer { position = m.end }
            guard let lv = chosen[index] else { motions.append(m); continue }
            if m.kind.isArc {
                var out = m
                out.feed = feed(lv[0])
                lowest = min(lowest, out.feed)
                motions.append(out)
                continue
            }
            var j = 0
            while j < lv.count {
                var e = j
                while e + 1 < lv.count && lv[e + 1] == lv[j] { e += 1 }
                let end = e + 1 == lv.count ? m.end : position.lerp(to: m.end, Double(e + 1) / Double(lv.count))
                let f = feed(lv[j])
                lowest = min(lowest, f)
                motions.append(Motion(kind: .feed, end: end, feed: f))
                j = e + 1
            }
        }
        var out = tp
        out.motions = motions
        out.loadFeeds = LoadFeeds(programmed: programmed, lowest: lowest, usualEngagement: usual, wanted: wanted, held: held)
        return out
    }

    /// Levels for a chain of atoms: each slowdown at once, each speed-up only to the level the atom needs without the
    /// rounding tolerance, and every stretch at one level at least `minimum` long except the last (a stretch cut short
    /// by a slowdown runs at the slower level from its start instead; a short last stretch that's faster than the one
    /// before runs at that one's).
    static func runs(_ atoms: [Atom], minimum: Double) -> [Int] {
        var out = [Int](repeating: 0, count: atoms.count)
        guard let first = atoms.firstIndex(where: { $0.down >= 0 }) else { return out }
        // Closed stretches (start, level, length), then the open one.
        var closed: [(start: Int, level: Int, length: Double)] = []
        var start = 0, current = atoms[first].down, length = 0.0
        for (j, a) in atoms.enumerated() {
            if j > first && a.down >= 0 {
                if a.down > current {
                    if length < minimum - 1e-9 {
                        // Too short to keep: it runs at the slower level, joining the stretch before if that's at it.
                        for k in start..<j { out[k] = a.down }
                        current = a.down
                        if let last = closed.last, last.level == current {
                            closed.removeLast()
                            start = last.start
                            length += last.length
                        }
                    } else {
                        closed.append((start, current, length))
                        start = j; current = a.down; length = 0
                    }
                } else if a.up < current && length >= minimum - 1e-9 {
                    closed.append((start, current, length))
                    start = j; current = a.up; length = 0
                }
            }
            out[j] = current
            length += a.length
        }
        // A short last stretch faster than the one before it runs at that one's.
        if length < minimum - 1e-9, let last = closed.last, last.level > current {
            for k in start..<atoms.count { out[k] = last.level }
        }
        return out
    }

    // MARK: Job

    /// Applies "Adjust feeds for load" to one of `op`'s toolpaths, given the job's material model before it cuts
    /// (`uncut`). Returns the toolpath and notes for the job's checks.
    static func apply(_ tp: Toolpath, operation op: CAMOperation, uncut: HeightGrid?, wrapped: Bool, project: Project) -> (Toolpath, [JobIssue]) {
        guard op.adjustsFeedsForLoad, !tp.isEmpty else { return (tp, []) }
        if wrapped {
            return (tp, [JobIssue(.info, "Feeds aren't adjusted for load on a wrapped rotary job: its moves are fed in inverse "
                + "time (G93), so they keep the programmed feed.", operation: tp.name)])
        }
        guard suits(tp.tool), let grid = uncut else { return (tp, []) }
        let tool = tp.tool
        let material = project.stock.material
        // The same floor as the chip-load check (`CAMEngine.chipLoadIssues`).
        let chipFloor = ChipLoad.applies(to: tool)
            ? ChipLoad.range(material, diameter: tool.diameter).lowerBound * (tool.shape == .flatEndMill ? 0.9 : 0.8) : nil
        var contour = false
        if case .profile = op.kind { contour = true }
        let out = schedule(tp, material: { p in grid.height(at: p).map(Double.init) }, floorZ: Double(grid.floorZ),
                           chipFloor: chipFloor, maxFeed: project.machine.maxFeedRate, insideArcs: contour)
        var issues: [JobIssue] = []
        // Only a sizeable slowdown held back is worth a note: a light pass's chip is often near the floor already.
        if let lf = out.loadFeeds, let wanted = lf.wanted, wanted <= 0.7 + 1e-9, let held = lf.held, let chipFloor {
            let inch = String(format: "%.4f in", chipFloor / LengthUnit.mmPerInch)
            let pct = { (s: Double) in "\(Int((s * 100).rounded()))%" }
            let got = held >= 1 - 1e-9 ? "so they aren't slowed" : "so they only slow to \(pct(held))"
            issues.append(JobIssue(.info, "Adjust feeds for load would slow the hardest cuts to \(pct(wanted)) of the feed, but "
                + "the chip there would be thinner than \(inch), the least for this bit in \(material.label.lowercased()), "
                + "\(got). A lower spindle speed would let them slow without burning.", operation: tp.name))
        }
        return (out, issues)
    }
}
