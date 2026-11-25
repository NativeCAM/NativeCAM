import Foundation

/// Adaptive (constant-engagement) pocket clearing: `PocketStrategy.adaptive`.
///
/// Offset rings cut a full-width slot where they start and up to the bit's whole width in every inside corner, so they
/// need shallow passes. This holds the bit's radial load near one figure, the optimal load (a sliver of its width),
/// everywhere, so it can cut the full length of its flutes at once. It's a walk, written here from the published
/// description of the approach FreeCAD's Adaptive and the commercial "adaptive clearing" toolpaths take (no code
/// from any of them):
///
/// - **The cleared region** is kept as polygons (Clipper2): the tool's swept discs, merged every 1.5 radii of travel or
///   45° of turn. The few moves since the last merge are kept as capsules and counted too.
/// - **Each step** tries headings within ±45° of the last until the area the bit cuts per millimetre — the material
///   in its new disc that its old disc and the cleared region don't cover — is within 5% of the optimal load's width.
///   The area is integrated exactly along lines parallel to the step (`ClearedModel.uncut`), not counted on a
///   raster. Turns toward the material are limited to the minimum loop radius; turns away from it never are, so
///   holding the load always wins.
/// - **Passes** start where the cleared region meets uncut material, at the upstream end of each stretch of that
///   frontier, and run until the bit is in air. Between passes the bit stays down when a link through cleared area is
///   at most 3× the direct distance — a Dubins path (arcs no tighter than the minimum loop radius) where one fits,
///   else a straight line or back along its own path — and lifts otherwise.
/// - **Entry** is a helix at the deepest point of each area (as wide as the bit's radius allows, so it bores a hole
///   with no core), ramping 2°, or a ramp along a chord where no helix fits.
/// - **The walls.** The walk stays a hair (a tenth of the load) off the walls, then one pass round them at the full
///   depth finishes them as an offset pocket's last ring would. Where the walk couldn't hold its load (slots or corners
///   too tight for its loops), or the walls have corner reliefs (which swing the bit sideways into each corner), what
///   it left and the walls are cut at the bit's stepdown instead, as an offset pocket would.
enum AdaptiveClearing {
    /// Helix and ramp descent, radians.
    static let rampAngle = 2.0 * .pi / 180
    /// How close to the optimal load a step must come.
    static let loadTolerance = 0.05
    /// The most a step may take, as a multiple of the optimal load, when no heading holds it.
    static let overload = 1.25
    /// Stay down on a link at most this many times the direct distance.
    static let stayDownRatio = 3.0

    /// The walk's settings for one tool.
    struct Settings {
        var toolRadius: Double
        /// The optimal load: the width of material the bit cuts, mm.
        var load: Double
        /// Climb milling keeps the material on the bit's right (M3 spindle).
        var climb: Bool
        var loopRadius: Double
        /// Chord tolerance for arcs and offsets, mm.
        var arcTolerance: Double

        init(tool: Tool, params: PocketParams, machine: MachineProfile, arcTolerance: Double) {
            let s = params.adaptiveSettings
            toolRadius = tool.radius
            load = max(0.01, s.load * tool.diameter)
            climb = params.direction == .climb
            loopRadius = s.loopRadius(tool: tool, feed: tool.cutting.feedRate, machine: machine)
            self.arcTolerance = arcTolerance
        }

        /// What the walk leaves on the walls for the wall pass, mm.
        var finish: Double { max(0.02, 0.1 * load) }
        var maxStep: Double { 0.4 * toolRadius }
        var minStep: Double { max(0.02, 0.04 * toolRadius) }
        /// Material pieces thinner than twice this are left to the clean-up (they'd only make short passes).
        var sliver: Double { max(0.01, 0.15 * load) }
    }

    /// One piece of a level's path, in cutting order. Every point is a tool-centre position at the level's depth.
    enum Move: Equatable {
        /// A helix round `center` from the level above down to the level, then once round at it.
        case helix(center: Vec2, radius: Double, startAngle: Double, ccw: Bool)
        /// A ramp back and forth along a chord, then once along it at the level.
        case ramp(Vec2, Vec2)
        /// A cutting pass; `loads` holds the load of each step (to the next point) as a share of the optimal load.
        case cut([Vec2], loads: [Double])
        /// A link through cleared area at the level; `radius` is its arcs' radius (nil for straight lines or a
        /// path back along the last pass).
        case link([Vec2], radius: Double?)
        /// Up to safe Z and back down at a point in cleared area.
        case lift(Vec2)
    }

    /// One level's walk.
    struct Level {
        var z: Double
        var moves: [Move]
        /// The material the walk cleared at the level (Clipper polygons, outer loops CCW).
        var cleared: [Polyline]
    }

    struct Plan {
        var levels: [Level]
    }

    // MARK: Planning

    /// The walk at each level for the tool-centre `boundary` (the pocket shrunk by the tool radius and allowance).
    /// `cleared`: material already gone at these levels (Clipper polygons), which the walk counts as cut from the start
    /// and opens up from rather than boring a helix (3D roughing's layers, where earlier toolpaths cut some of it).
    static func plan(boundary: [Region], tool: Tool, params: PocketParams, levels: [Double], context: GenerationContext,
                     cleared seed: [Polyline] = []) -> Plan {
        let s = Settings(tool: tool, params: params, machine: context.machine, arcTolerance: context.arcTolerance)
        // The walk's own boundary: the wall pass takes the last `finish`.
        let walk = boundary.flatMap { $0.offset(by: -s.finish, arcTolerance: s.arcTolerance) }
        guard !levels.isEmpty else { return Plan(levels: []) }
        // The pocket's walls are straight down, so every level is the same walk.
        let walker = Walker(settings: s, areas: walk, bounds: boundary.reduce(Rect2.empty) { $0.union($1.bounds) })
        if !seed.isEmpty { walker.cleared.add(seed) }
        walker.run()
        let cleared = walker.cleared.flushed()
        return Plan(levels: levels.map { Level(z: $0, moves: walker.moves, cleared: cleared) })
    }

    // MARK: Cutting

    /// Clears the tool-centre `boundary` adaptively at each of `levels` and finishes the walls (with `reliefs`), into `b`.
    /// `cleared` is material already gone at the levels (see `plan`). Returns warnings.
    static func cut(boundary: [Region], tool: Tool, params: PocketParams, levels: [Double], context: GenerationContext,
                    reliefs: [CornerRelief.Relief], safe: [Region], cleared seed: [Polyline] = [],
                    builder b: inout ToolpathBuilder) -> [String] {
        var narrow: [Double]?
        return cut(boundary: boundary, tool: tool, params: params, levels: levels, context: context, reliefs: reliefs, safe: safe,
                   cleared: seed, narrow: &narrow, builder: &b)
    }

    /// As above. With `narrow` set (3D roughing), a level whose area has no room anywhere for a loop of the minimum
    /// radius (a band narrower than the loops need) isn't warned about when it falls back to the stepdown: there that's
    /// expected, so its depth is added to `narrow` instead, for the caller to note. Where the loops had room and still
    /// couldn't hold the load, it warns as ever.
    static func cut(boundary: [Region], tool: Tool, params: PocketParams, levels: [Double], context: GenerationContext,
                    reliefs: [CornerRelief.Relief], safe: [Region], cleared seed: [Polyline] = [], narrow: inout [Double]?,
                    builder b: inout ToolpathBuilder) -> [String] {
        let s = Settings(tool: tool, params: params, machine: context.machine, arcTolerance: context.arcTolerance)
        var warnings = loopWarnings(tool: tool, settings: s, context: context)
        let plan = plan(boundary: boundary, tool: tool, params: params, levels: levels, context: context, cleared: seed)
        let r = tool.radius
        let tol = context.arcTolerance
        // The bit's ordinary cut, for what the walk leaves behind.
        let stepover = max(0.05, tool.stepoverBasis * (params.stepoverFraction ?? tool.cutting.stepoverFraction))
        var ordinary = params
        ordinary.entry = EntrySettings(kind: .ramp, rampLength: 2 * tool.diameter)
        var wallParams = params
        wallParams.entry = EntrySettings()
        // Everything the bit can reach at the allowance.
        let reach = boundary.flatMap { $0.offset(by: r, arcTolerance: tol) }.flatMap(\.loops)
        var heavyAnywhere = false
        // No loop of the minimum radius fits anywhere in the walk's area, so the walk can only nibble at it.
        let noRoomForLoops = narrow != nil
            && boundary.flatMap { $0.offset(by: -(s.finish + s.loopRadius), arcTolerance: tol) }.isEmpty
        var zAbove = -params.depth.startDepth
        for level in plan.levels {
            let z = level.z
            emit(level, zAbove: zAbove, settings: s, builder: &b)

            // What the walk left that the bit can reach: a hair on the walls, unless it couldn't hold its load somewhere.
            let left = Region.nest(Clipper.difference(reach, minus: level.cleared))
            // (A piece that survives being shrunk by that much is thicker than the load; specks at corners don't count.)
            let heavy = left.contains { piece in
                piece.offset(by: -(s.finish + 0.5 * s.load), arcTolerance: tol).contains { $0.area > 0.1 * s.load * s.load }
            }
            let cleared = Region.nest(level.cleared)
            let pieces = PocketGenerator.restPieces(boundary, reached: cleared, toolRadius: r, arcTolerance: tol)
            // Reliefs plunge the bit sideways into each corner: too heavy a cut at the full length of its flutes.
            let stepped = heavy || !reliefs.isEmpty
            if stepped {
                if heavy, noRoomForLoops {
                    narrow?.append(z)
                } else {
                    heavyAnywhere = heavyAnywhere || heavy
                }
                // The rest at the bit's own stepdown, and the walls (with their reliefs) at each of those depths.
                let tree = heavy || !pieces.isEmpty
                    ? PocketGenerator.restTree(boundary, reached: cleared, stepover: stepover, toolRadius: r, arcTolerance: tol)
                    : boundary.map(PocketGenerator.RingNode.init)
                PocketGenerator.smooth(tree, deviation: context.machine.cornerSmoothing, plannerDeviation: context.machine.cornerDeviation,
                                       stepover: stepover, toolRadius: r, boundary: false, chordTolerance: tol)
                let sub = DepthSettings(startDepth: -zAbove, cutDepth: -z).passLevels(toolStepdown: tool.cutting.stepdown,
                                                                                       firstPassMinimum: tool.firstPassMinimum)
                var above = zAbove
                for zz in sub {
                    var first = false
                    // With leftovers about, links stay as short as an offset pocket's, so none ploughs through one;
                    // with only the walls left, the area inside them is clear.
                    PocketGenerator.cutTree(tree, z: zz, zAbove: above, params: heavy ? ordinary : wallParams,
                                            stepover: heavy ? stepover : .infinity, safe: safe, reliefs: reliefs, first: &first, builder: &b)
                    above = zz
                }
            } else {
                // Thin leftovers (no wider than the load) and the walls, at the full depth: a light cut throughout.
                let tree = pieces.isEmpty ? boundary.map(PocketGenerator.RingNode.init)
                    : PocketGenerator.restTree(boundary, reached: cleared, stepover: stepover, toolRadius: r, arcTolerance: tol)
                PocketGenerator.smooth(tree, deviation: context.machine.cornerSmoothing, plannerDeviation: context.machine.cornerDeviation,
                                       stepover: stepover, toolRadius: r, boundary: false, chordTolerance: tol)
                var first = false
                PocketGenerator.cutTree(tree, z: z, zAbove: zAbove, params: wallParams, stepover: .infinity, safe: safe,
                                        reliefs: [], first: &first, builder: &b)
            }
            b.retract()
            zAbove = z
        }
        if heavyAnywhere {
            warnings.append("Adaptive clearing couldn't hold its load everywhere (a slot or corner too tight for its loops), so it "
                + "clears what it left there in passes of the tool's stepdown (\(context.length(tool.cutting.stepdown))).")
        }
        return warnings
    }

    /// Writes one level's walk into `b`.
    static func emit(_ level: Level, zAbove: Double, settings s: Settings, builder b: inout ToolpathBuilder) {
        let z = level.z
        let z0 = max(zAbove, z)
        for move in level.moves {
            switch move {
            case let .helix(c, rho, a0, ccw):
                let start = c + Vec2.fromAngle(a0, length: rho)
                b.enter(at: Vec3(start, z0))
                let sign = ccw ? 1.0 : -1.0
                let perTurn = 2 * Double.pi * rho * tan(rampAngle)
                let turns = max(1, ((z0 - z) / max(perTurn, 1e-6) - 1e-9).rounded(.up))
                let n = max(12, Int((2 * Double.pi / chordAngle(rho, s.arcTolerance)).rounded(.up)))
                let total = Int((turns * Double(n)).rounded(.up))
                var pts: [Vec3] = []
                pts.reserveCapacity(total + n)
                for i in 1...total {
                    let t = Double(i) / Double(total)
                    let a = a0 + sign * 2 * .pi * turns * t
                    pts.append(Vec3(c + Vec2.fromAngle(a, length: rho), z0 + (z - z0) * t))
                }
                // Once round at the level, so the floor is flat.
                let end = a0 + sign * 2 * .pi * turns
                for i in 1...n {
                    pts.append(Vec3(c + Vec2.fromAngle(end + sign * 2 * .pi * Double(i) / Double(n), length: rho), z))
                }
                b.follow(pts)
            case let .ramp(p, q):
                b.enter(at: Vec3(p, z0))
                let len = max(p.distance(to: q), 1e-6)
                let drop = len * tan(rampAngle)
                var h = z0
                var at = p, other = q
                while h > z + 1e-9 {
                    h = max(z, h - drop)
                    b.feed(Vec3(other, h))
                    swap(&at, &other)
                }
                // Once along the chord at the level, ending at q where the walk starts.
                b.feed(Vec3(other, z))
                if !other.isApprox(q, tolerance: 1e-9) { b.feed(Vec3(q, z)) }
            case let .cut(pts, _):
                guard let first = pts.first else { continue }
                if !b.position.xy.isApprox(first, tolerance: 1e-6) || abs(b.position.z - z) > 1e-6 { b.enter(at: Vec3(first, z)) }
                b.follow(pts.dropFirst().map { Vec3($0, z) })
            case let .link(pts, _):
                b.follow(pts.dropFirst().map { Vec3($0, z) })
            case let .lift(p):
                b.enter(at: Vec3(p, z))
            }
        }
    }

    /// The angle a chord of `rho` subtends within `tolerance`.
    static func chordAngle(_ rho: Double, _ tolerance: Double) -> Double {
        guard rho > tolerance else { return .pi / 2 }
        return min(.pi / 6, 2 * acos(1 - tolerance / rho))
    }

    // MARK: Warnings

    /// Loops of the minimum radius cap the feed at √(a·ρ): say so when that's below the programmed feed.
    static func loopWarnings(tool: Tool, settings s: Settings, context: GenerationContext) -> [String] {
        let feed = tool.cutting.feedRate
        let cap = AdaptiveSettings.loopFeedCap(radius: s.loopRadius, machine: context.machine)
        guard cap < 0.95 * feed else { return [] }
        let a = context.machine.axisAcceleration.x
        let accel = context.units == .inch ? String(format: "%.0f in/s²", a / LengthUnit.mmPerInch) : String(format: "%.0f mm/s²", a)
        let full = AdaptiveSettings.fullSpeedRadius(feed: feed, machine: context.machine)
        return ["Adaptive loops \(context.length(s.loopRadius)) in radius hold the feed to \(context.feed(cap)) with this machine's "
            + "\(accel) X/Y acceleration, below the programmed \(context.feed(feed)). A minimum loop radius of "
            + "\(context.length(full)), or more acceleration in Machine Setup, lets them run at full feed."]
    }
}

// MARK: - Spatial index of segments

/// Segments bucketed in a uniform grid, for the walk's local queries.
struct SegmentGrid {
    private(set) var a: [Vec2] = []
    private(set) var b: [Vec2] = []
    private let origin: Vec2
    private let cell: Double
    private let cols: Int
    private let rows: Int
    private var start: [Int32] = []
    private var items: [Int32] = []
    private var stamp: [UInt32] = []
    private var tick: UInt32 = 0

    init(bounds: Rect2, cell: Double) {
        let w0 = bounds.isEmpty ? 1 : bounds.width, h0 = bounds.isEmpty ? 1 : bounds.height
        // At most about two million cells, however big the area and small the bit.
        let c = max(cell, 1e-3, ((w0 + 2 * cell) * (h0 + 2 * cell) / 2e6).squareRoot())
        origin = bounds.isEmpty ? .zero : bounds.min - Vec2(c, c)
        self.cell = c
        let w = w0 + 2 * c, h = h0 + 2 * c
        cols = max(1, min(4096, Int((w / c).rounded(.up))))
        rows = max(1, min(4096, Int((h / c).rounded(.up))))
        start = [Int32](repeating: 0, count: cols * rows + 1)
    }

    private func col(_ x: Double) -> Int { min(cols - 1, max(0, Int(((x - origin.x) / cell).rounded(.down)))) }
    private func row(_ y: Double) -> Int { min(rows - 1, max(0, Int(((y - origin.y) / cell).rounded(.down)))) }

    /// Replaces the segments with every edge of `loops`.
    mutating func rebuild(_ loops: [Polyline]) {
        a.removeAll(keepingCapacity: true)
        b.removeAll(keepingCapacity: true)
        for loop in loops where loop.count >= 2 {
            for i in 0..<loop.segmentCount {
                let (p, q) = loop.segment(i)
                a.append(p)
                b.append(q)
            }
        }
        var counts = [Int32](repeating: 0, count: cols * rows)
        for i in a.indices {
            for cy in row(min(a[i].y, b[i].y))...row(max(a[i].y, b[i].y)) {
                for cx in col(min(a[i].x, b[i].x))...col(max(a[i].x, b[i].x)) { counts[cy * cols + cx] += 1 }
            }
        }
        start = [Int32](repeating: 0, count: cols * rows + 1)
        for k in 0..<(cols * rows) { start[k + 1] = start[k] + counts[k] }
        items = [Int32](repeating: 0, count: Int(start[cols * rows]))
        var fill = Array(start.dropLast())
        for i in a.indices {
            for cy in row(min(a[i].y, b[i].y))...row(max(a[i].y, b[i].y)) {
                for cx in col(min(a[i].x, b[i].x))...col(max(a[i].x, b[i].x)) {
                    let k = cy * cols + cx
                    items[Int(fill[k])] = Int32(i)
                    fill[k] += 1
                }
            }
        }
        stamp = [UInt32](repeating: 0, count: a.count)
        tick = 0
    }

    /// Calls `body` once with each segment whose cells overlap `rect`.
    mutating func forEach(in rect: Rect2, _ body: (Vec2, Vec2) -> Void) {
        guard !a.isEmpty, !rect.isEmpty else { return }
        tick &+= 1
        if tick == 0 { stamp = [UInt32](repeating: 0, count: a.count); tick = 1 }
        for cy in row(rect.min.y)...row(rect.max.y) {
            for cx in col(rect.min.x)...col(rect.max.x) {
                let k = cy * cols + cx
                for j in start[k]..<start[k + 1] {
                    let i = Int(items[Int(j)])
                    if stamp[i] != tick {
                        stamp[i] = tick
                        body(a[i], b[i])
                    }
                }
            }
        }
    }

    /// Winding number of `loops` (the ones this was built from) round `p`, by a ray towards +x.
    mutating func winding(_ p: Vec2) -> Int {
        guard !a.isEmpty else { return 0 }
        var w = 0
        forEach(in: Rect2(min: p, max: Vec2(origin.x + Double(cols) * cell, p.y))) { s, e in
            if s.y <= p.y {
                if e.y > p.y && (e - s).cross(p - s) > 0 { w += 1 }
            } else if e.y <= p.y && (e - s).cross(p - s) < 0 {
                w -= 1
            }
        }
        return w
    }

    /// True when the segment p–q crosses or touches any segment.
    mutating func crosses(_ p: Vec2, _ q: Vec2) -> Bool {
        var hit = false
        forEach(in: Rect2(min: Vec2(min(p.x, q.x), min(p.y, q.y)), max: Vec2(max(p.x, q.x), max(p.y, q.y)))) { s, e in
            if !hit && segmentsIntersect(p, q, s, e, epsilon: 1e-12) { hit = true }
        }
        return hit
    }
}

// MARK: - The cleared region

/// The material the walk has cleared at one level: merged polygons, plus the capsules swept since the last merge.
final class ClearedModel {
    let radius: Double
    let arcTolerance: Double
    private(set) var polygons: [Polyline] = []
    private var grid: SegmentGrid
    /// Tool-centre path since the last merge; its first point was merged already.
    private(set) var trail: [Vec2] = []
    private var trailLength = 0.0
    private var trailTurn = 0.0
    /// Rows the cut area is integrated over across the disc.
    let rows: Int

    init(radius: Double, load: Double, bounds: Rect2, arcTolerance: Double) {
        self.radius = radius
        self.arcTolerance = arcTolerance
        grid = SegmentGrid(bounds: bounds.insetBy(-2 * radius), cell: max(radius, 0.5))
        rows = min(400, max(64, Int((32 * radius / max(load, 1e-3)).rounded(.up))))
    }

    /// The merged polygons with the trail merged in.
    func flushed() -> [Polyline] {
        flush()
        return polygons
    }

    /// Adds what a helix cuts: the ring between `inner` and `outer` round `c` (a disc when `inner` ≤ 0).
    func addRing(_ c: Vec2, inner: Double, outer: Double) {
        flush()
        var ring = [Self.disc(c, outer, tolerance: arcTolerance)]
        if inner > 1e-3 {
            // The core's polygon is outside its circle, so nothing uncut counts as cut.
            let core = Self.disc(c, inner / cos(AdaptiveClearing.chordAngle(inner, arcTolerance) / 2), tolerance: arcTolerance)
            ring = Clipper.difference(ring, minus: [core])
        }
        merge(ring)
    }

    /// Adds the swept path `pts` (a ramp, a link) at once.
    func addSweep(_ pts: [Vec2]) {
        flush()
        guard let first = pts.first else { return }
        if pts.count < 2 {
            merge([Self.disc(first, radius, tolerance: arcTolerance)])
        } else {
            merge(Clipper.offset([Polyline(pts, closed: false)], delta: radius, join: .round, end: .round, arcTolerance: arcTolerance))
        }
    }

    /// Moves the tool on to `p` (cutting). Merges the trail every 1.5 radii of travel or 45° of turn.
    func advance(to p: Vec2) {
        if trail.isEmpty { trail = [p]; return }
        let last = trail[trail.count - 1]
        guard p.distance(to: last) > 1e-9 else { return }
        if trail.count >= 2 {
            let d0 = last - trail[trail.count - 2], d1 = p - last
            trailTurn += abs(atan2(d0.cross(d1), d0.dot(d1)))
        }
        trail.append(p)
        trailLength += p.distance(to: last)
        if trailLength >= 1.5 * radius || trailTurn >= .pi / 4 { flush() }
    }

    /// Counts `polygons` (Clipper polygons, outer loops CCW) as cleared.
    func add(_ polygons: [Polyline]) {
        flush()
        merge(polygons)
    }

    /// Starts a new trail at `p` without sweeping anything between (after a lift or link that was merged on its own).
    func restart(at p: Vec2) {
        flush()
        trail = [p]
    }

    func flush() {
        guard trail.count >= 2 else { return }
        let path = trail
        trail = [path[path.count - 1]]
        trailLength = 0
        trailTurn = 0
        merge(Clipper.offset([Polyline(path, closed: false)], delta: radius, join: .round, end: .round, arcTolerance: arcTolerance))
    }

    private func merge(_ add: [Polyline]) {
        guard !add.isEmpty else { return }
        polygons = Clipper.union(polygons + add, fill: .nonZero)
        grid.rebuild(polygons)
    }

    /// A polygon with its vertices on the circle (so it's inside it).
    static func disc(_ c: Vec2, _ rho: Double, tolerance: Double) -> Polyline {
        let n = max(16, Int((2 * Double.pi / AdaptiveClearing.chordAngle(rho, tolerance)).rounded(.up)))
        return Polyline((0..<n).map { c + Vec2.fromAngle(2 * .pi * Double($0) / Double(n), length: rho) }, closed: true)
    }

    // MARK: Cut area

    /// What lies on one line across a shape: the interval [lo, hi] along the line's direction.
    private struct Crossing { var row: Int32; var x: Double; var dir: Int8 }
    private var crossings: [Crossing] = []
    private var intervals: [(row: Int32, lo: Double, hi: Double)] = []
    private var edgeCrossings: [(y: Double, sign: Int)] = []

    /// Uncleared area in the disc of radius `radius` at `c2` outside the disc at `c1` (the material a step from `c1` to
    /// `c2` cuts), and how much of it is on the left of the step.
    func crescent(_ c1: Vec2, _ c2: Vec2) -> (area: Double, left: Double) {
        let d = c2 - c1
        let L = d.length
        guard L > 1e-9 else { return (0, 0) }
        return uncut(origin: c1, direction: d / L, radius: radius, step: L)
    }

    /// Uncleared area within `rho` of `p`.
    func material(near p: Vec2, radius rho: Double) -> Double {
        uncut(origin: p, direction: Vec2(1, 0), radius: rho, step: nil).area
    }

    /// The uncleared area of a shape: a disc of radius `R` at `origin` (`step` nil), or the crescent a disc of radius `R`
    /// sweeps moving `step` along `direction` from `origin`. Integrated over lines parallel to `direction`, on each of
    /// which the shape is one interval and the cleared region is the parts where its polygons wind round (and the
    /// trail's capsules), so the integral is exact along the lines; only the spacing across them is sampled.
    private func uncut(origin o: Vec2, direction u: Vec2, radius R: Double, step: Double?) -> (area: Double, left: Double) {
        let v = u.perpLeft
        let n = rows
        let h = 2 * R / Double(n)
        // The local rectangle the shape lies in (x along u from x0 to x1, y across from −R to R), and its world box.
        let x0 = -R, x1 = R + (step ?? 0)
        let mid = o + u * ((x0 + x1) / 2)
        let half = Vec2(abs(u.x) * (x1 - x0) / 2 + abs(v.x) * R, abs(u.y) * (x1 - x0) / 2 + abs(v.y) * R)
        let box = Rect2(min: mid - half, max: mid + half)
        crossings.removeAll(keepingCapacity: true)
        intervals.removeAll(keepingCapacity: true)
        edgeCrossings.removeAll(keepingCapacity: true)
        // Each line's winding where it enters the rectangle: the winding at its lower-left corner, then each edge the
        // rectangle's left side crosses. (Counted with the sign the sweep along a line uses: an edge running up the
        // line's direction of travel is +1, so inside a counter-clockwise loop is −1.)
        let corner = o + u * x0 - v * R
        let base = -grid.winding(corner)
        // Polygon edges: where each line crosses them inside the rectangle, and which way.
        grid.forEach(in: box) { p, q in
            let P = Vec2((p - o).dot(u), (p - o).dot(v)), Q = Vec2((q - o).dot(u), (q - o).dot(v))
            if (P.x <= x0) != (Q.x <= x0) {
                let t = (x0 - P.x) / (Q.x - P.x)
                let y = P.y + t * (Q.y - P.y)
                if y > -R && y < R { edgeCrossings.append((y, Q.x > P.x ? -1 : 1)) }
            }
            guard abs(P.y - Q.y) > 1e-12 else { return }
            let lo = min(P.y, Q.y), hi = max(P.y, Q.y)
            guard hi > -R, lo < R, max(P.x, Q.x) > x0 else { return }
            // Lines y_j = −R + (j + ½)h with lo ≤ y_j < hi.
            let j0 = max(0, Int(((lo + R) / h - 0.5).rounded(.up)))
            let j1 = min(n - 1, Int(((hi + R) / h - 0.5).rounded(.up)) - 1)
            guard j0 <= j1 else { return }
            let dir: Int8 = Q.y > P.y ? 1 : -1
            let slope = (Q.x - P.x) / (Q.y - P.y)
            for j in j0...j1 {
                let y = -R + (Double(j) + 0.5) * h
                let x = P.x + (y - P.y) * slope
                if x > x0 { crossings.append(Crossing(row: Int32(j), x: x, dir: dir)) }
            }
        }
        edgeCrossings.sort { $0.y < $1.y }
        crossings.sort { $0.row != $1.row ? $0.row < $1.row : $0.x < $1.x }
        var k = 0, e = 0
        var start = base
        for j in 0..<n {
            let y = -R + (Double(j) + 0.5) * h
            while e < edgeCrossings.count && edgeCrossings[e].y < y { start += edgeCrossings[e].sign; e += 1 }
            var w = start
            var open = x0
            while k < crossings.count && crossings[k].row < Int32(j) { k += 1 }
            while k < crossings.count && crossings[k].row == Int32(j) {
                let c = crossings[k]
                let before = w
                w += Int(c.dir)
                if before == 0 && w != 0 { open = c.x } else if before != 0 && w == 0 { intervals.append((Int32(j), open, c.x)) }
                k += 1
            }
            if w != 0 { intervals.append((Int32(j), open, x1 + 1)) }
        }
        // The trail's capsules.
        if trail.count >= 2 {
            let r = radius
            for i in 1..<trail.count {
                let A = Vec2((trail[i - 1] - o).dot(u), (trail[i - 1] - o).dot(v))
                let B = Vec2((trail[i] - o).dot(u), (trail[i] - o).dot(v))
                let ylo = min(A.y, B.y) - r, yhi = max(A.y, B.y) + r
                guard yhi > -R, ylo < R, max(A.x, B.x) + r > x0, min(A.x, B.x) - r < x1 else { continue }
                let j0 = max(0, Int(((ylo + R) / h - 0.5).rounded(.up)))
                let j1 = min(n - 1, Int(((yhi + R) / h - 0.5).rounded(.down)))
                guard j0 <= j1 else { continue }
                for j in j0...j1 {
                    let y = -R + (Double(j) + 0.5) * h
                    if let iv = Self.capsule(A, B, r, y) { intervals.append((Int32(j), iv.lo, iv.hi)) }
                }
            }
        }
        intervals.sort { $0.row != $1.row ? $0.row < $1.row : $0.lo < $1.lo }
        var total = 0.0, left = 0.0
        var m = 0
        for j in 0..<n {
            let y = -R + (Double(j) + 0.5) * h
            let w = (max(0, R * R - y * y)).squareRoot()
            let a: Double, b: Double
            if let L = step {
                a = max(w, L - w)
                b = L + w
            } else {
                a = -w
                b = w
            }
            while m < intervals.count && intervals[m].row < Int32(j) { m += 1 }
            guard b > a else { continue }
            // Covered length of [a, b]: merge this line's intervals in order.
            var covered = 0.0
            var cur = a
            var q = m
            while q < intervals.count && intervals[q].row == Int32(j) {
                let lo = max(intervals[q].lo, cur), hi = min(intervals[q].hi, b)
                if hi > lo {
                    covered += hi - lo
                    cur = hi
                }
                q += 1
            }
            let uncovered = max(0, (b - a) - covered) * h
            total += uncovered
            if y > 0 { left += uncovered }
        }
        return (total, left)
    }

    /// Where the line at height `y` crosses the capsule round A–B of radius `r`: the hull of its ends' discs and the
    /// band between them (the capsule is convex).
    static func capsule(_ A: Vec2, _ B: Vec2, _ r: Double, _ y: Double) -> (lo: Double, hi: Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for c in [A, B] {
            let dy = y - c.y
            if abs(dy) < r {
                let w = (r * r - dy * dy).squareRoot()
                lo = min(lo, c.x - w)
                hi = max(hi, c.x + w)
            }
        }
        let d = B - A
        let len = d.length
        if len > 1e-12 {
            let t = d / len, nrm = t.perpLeft
            // Points (x, y) with 0 ≤ (X − A)·t ≤ len and |(X − A)·nrm| ≤ r; both linear in x.
            var xlo = -Double.infinity, xhi = Double.infinity
            func clamp(_ k: Double, _ c: Double, _ mn: Double, _ mx: Double) -> Bool {
                // mn ≤ k·x + c ≤ mx
                if abs(k) < 1e-12 { return c >= mn && c <= mx }
                let x1 = (mn - c) / k, x2 = (mx - c) / k
                xlo = max(xlo, min(x1, x2))
                xhi = min(xhi, max(x1, x2))
                return true
            }
            let dy = y - A.y
            if clamp(t.x, -A.x * t.x + dy * t.y, 0, len), clamp(nrm.x, -A.x * nrm.x + dy * nrm.y, -r, r), xhi > xlo {
                lo = min(lo, xlo)
                hi = max(hi, xhi)
            }
        }
        return hi > lo ? (lo, hi) : nil
    }
}

// MARK: - Dubins paths

/// The shortest path between two headed points that turns no tighter than a radius (Dubins): two arcs and a line, or
/// three arcs.
enum Dubins {
    struct Path {
        var length: Double
        /// (centre, signed sweep: + is counter-clockwise) of the first arc, the line's ends, and the last arc; for
        /// three arcs, the middle arc instead of the line.
        var arcs: [(center: Vec2, from: Vec2, sweep: Double)]
        var line: (Vec2, Vec2)?

        /// Points along it, arcs within `tolerance`.
        func points(radius rho: Double, tolerance: Double) -> [Vec2] {
            var out: [Vec2] = []
            func arc(_ a: (center: Vec2, from: Vec2, sweep: Double)) {
                let a0 = (a.from - a.center).angle
                let n = max(1, Int((abs(a.sweep) / AdaptiveClearing.chordAngle(rho, tolerance)).rounded(.up)))
                if out.isEmpty { out.append(a.from) }
                for i in 1...n { out.append(a.center + Vec2.fromAngle(a0 + a.sweep * Double(i) / Double(n), length: rho)) }
            }
            if let line {
                arc(arcs[0])
                if out.isEmpty { out.append(line.0) }
                out.append(line.1)
                arc(arcs[1])
            } else {
                for a in arcs { arc(a) }
            }
            return out
        }
    }

    static func mod2pi(_ a: Double) -> Double {
        let t = a.truncatingRemainder(dividingBy: 2 * .pi)
        return t < 0 ? t + 2 * .pi : t
    }

    /// The shortest path from `a` heading `ha` to `b` heading `hb` (radians) turning on radius `rho`.
    static func shortest(from a: Vec2, heading ha: Double, to b: Vec2, heading hb: Double, radius rho: Double) -> Path? {
        var best: Path?
        func consider(_ p: Path?) {
            if let p, p.length < (best?.length ?? .infinity) { best = p }
        }
        // s = +1 turns left (counter-clockwise), −1 right.
        func centre(_ p: Vec2, _ h: Double, _ s: Double) -> Vec2 { p + Vec2.fromAngle(h + s * .pi / 2, length: rho) }
        func sweep(_ h0: Double, _ h1: Double, _ s: Double) -> Double { s * mod2pi(s * (h1 - h0)) }
        for s1 in [1.0, -1.0] {
            for s2 in [1.0, -1.0] {
                let c1 = centre(a, ha, s1), c2 = centre(b, hb, s2)
                let V = c2 - c1
                let D = V.length
                var psi: Double
                var len: Double
                if s1 == s2 {
                    psi = D < 1e-12 ? ha : V.angle
                    len = D
                } else {
                    guard D > 2 * rho else { continue }
                    len = (D * D - 4 * rho * rho).squareRoot()
                    psi = V.angle + s1 * atan2(2 * rho, len)
                }
                let p1 = c1 + Vec2.fromAngle(psi - s1 * .pi / 2, length: rho)
                let p2 = c2 + Vec2.fromAngle(psi - s2 * .pi / 2, length: rho)
                let w1 = sweep(ha, psi, s1), w2 = sweep(psi, hb, s2)
                consider(Path(length: rho * (abs(w1) + abs(w2)) + len, arcs: [(c1, a, w1), (c2, p2, w2)], line: (p1, p2)))
            }
        }
        // Three arcs: left-right-left and right-left-right.
        for s in [1.0, -1.0] {
            let c1 = centre(a, ha, s), c3 = centre(b, hb, s)
            let V = c3 - c1
            let D = V.length
            guard D < 4 * rho, D > 1e-12 else { continue }
            let hgt = (4 * rho * rho - D * D / 4).squareRoot()
            for side in [1.0, -1.0] {
                let c2 = (c1 + c3) * 0.5 + V.perpLeft.normalized * (side * hgt)
                let t1 = (c1 + c2) * 0.5, t2 = (c2 + c3) * 0.5
                let h1 = (t1 - c1).angle + s * .pi / 2
                let h2 = (t2 - c3).angle + s * .pi / 2
                let w1 = sweep(ha, h1, s), w2 = sweep(h1, h2, -s), w3 = sweep(h2, hb, s)
                consider(Path(length: rho * (abs(w1) + abs(w2) + abs(w3)), arcs: [(c1, a, w1), (c2, t1, w2), (c3, t2, w3)], line: nil))
            }
        }
        return best
    }
}

// MARK: - The walk

extension AdaptiveClearing {
    /// One level's walk over the tool-centre `areas` (each a separate region the bit can't cross at depth).
    final class Walker {
        let s: Settings
        let areas: [Region]
        let cleared: ClearedModel
        private var indexes: [SegmentGrid]
        private(set) var moves: [Move] = []
        private var position: Vec2?
        private var heading = 0.0
        /// Starts where a pass found nothing to cut, so they aren't tried again.
        private var dead: [Vec2] = []
        private var passes = 0

        init(settings: Settings, areas: [Region], bounds: Rect2) {
            s = settings
            self.areas = areas
            cleared = ClearedModel(radius: settings.toolRadius, load: settings.load, bounds: bounds, arcTolerance: Self.modelTolerance(settings))
            indexes = areas.map { area in
                var g = SegmentGrid(bounds: area.bounds, cell: max(settings.toolRadius, 0.5))
                g.rebuild(area.loops)
                return g
            }
        }

        /// The cleared model's offsets and discs: fine enough for the load.
        static func modelTolerance(_ s: Settings) -> Double { min(max(s.load / 60, 0.002), 0.02) }

        func run() {
            let order = nearestNeighborOrder(Array(areas.indices), from: .zero, start: { self.areas[$0].bounds.center },
                                             end: { self.areas[$0].bounds.center })
            for i in order { clear(area: i) }
            cleared.flush()
        }

        // MARK: Areas

        private func clear(area i: Int) {
            guard enter(area: i) else { return }
            while passes < 20_000 {
                passes += 1
                let from = position
                let (cutAny, end) = pass(area: i)
                if !cutAny, let from { dead.append(from) }
                position = end.0
                heading = end.1
                guard let next = nextStart(area: i) else { break }
                link(area: i, to: next.0, heading: next.1)
            }
        }

        /// Starts the area: from the cleared region if the walk has already opened it up, else a helix (or ramp) at its
        /// deepest point. False when there's nothing here to cut, or no way in.
        private func enter(area i: Int) -> Bool {
            if let start = nextStart(area: i) {
                link(area: i, to: start.0, heading: start.1)
                return true
            }
            guard materialLeft(area: i) else { return false }
            let area = areas[i]
            guard let (centre, depth) = Self.deepest(area, tolerance: s.arcTolerance) else { return false }
            let r = s.toolRadius
            // No wider than the bit's radius, so the helix bores a hole rather than leaving a core standing in it.
            let rho = min(r, 0.95 * depth)
            if rho >= 0.1 * r {
                moves.append(.helix(center: centre, radius: rho, startAngle: 0, ccw: s.climb))
                cleared.addRing(centre, inner: rho - r, outer: rho + r)
                let p = centre + Vec2(rho, 0)
                position = p
                heading = s.climb ? .pi / 2 : -.pi / 2
                cleared.restart(at: p)
                return true
            }
            // A chord through the deepest point, as long as fits.
            var best: (Vec2, Vec2)?
            var bestLength = 0.0
            for k in 0..<16 {
                let d = Vec2.fromAngle(Double(k) * .pi / 16)
                let p = reach(area: i, from: centre, along: -d), q = reach(area: i, from: centre, along: d)
                if p.distance(to: q) > bestLength { bestLength = p.distance(to: q); best = (p, q) }
            }
            guard let (p, q) = best, bestLength >= 0.5 * r else { return false }
            moves.append(.ramp(p, q))
            cleared.addSweep([p, q])
            position = q
            heading = (q - p).angle
            cleared.restart(at: q)
            return true
        }

        /// How far the tool centre can go from `p` along `d` inside area `i`.
        private func reach(area i: Int, from p: Vec2, along d: Vec2) -> Vec2 {
            var lo = 0.0, hi = areas[i].bounds.width + areas[i].bounds.height
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                if segmentInside(area: i, p, p + d * mid) { lo = mid } else { hi = mid }
            }
            return p + d * lo
        }

        /// The point of `area` farthest from its edges, and how far that is (by halving inward offsets).
        static func deepest(_ area: Region, tolerance: Double) -> (Vec2, Double)? {
            let tol = max(tolerance, 0.01)
            var lo = 0.0, hi = 0.5 * min(area.bounds.width, area.bounds.height) + tol
            var inside: [Region] = [area]
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                let shrunk = area.offset(by: -mid, arcTolerance: tol)
                if shrunk.contains(where: { $0.area > 1e-8 }) {
                    lo = mid
                    inside = shrunk
                } else {
                    hi = mid
                }
                if hi - lo < tol { break }
            }
            guard let piece = inside.max(by: { $0.area < $1.area }) else { return nil }
            let c = piece.outer.points.reduce(Vec2.zero, +) / Double(max(1, piece.outer.count))
            let p = piece.contains(c) ? c : (piece.outer.interiorPoint() ?? piece.outer.points[0])
            return (p, lo)
        }

        // MARK: Geometry tests

        private func inside(area i: Int, _ p: Vec2) -> Bool { indexes[i].winding(p) != 0 }

        private func segmentInside(area i: Int, _ p: Vec2, _ q: Vec2) -> Bool {
            inside(area: i, q) && !indexes[i].crosses(p, q)
        }

        /// The material the bit can reach from area `i` that's still uncut, opened so slivers don't count.
        private func material(area i: Int) -> [Region] {
            let tol = s.arcTolerance
            let reach = areas[i].offset(by: s.toolRadius, arcTolerance: tol).flatMap(\.loops)
            let left = Region.nest(Clipper.difference(reach, minus: cleared.flushed()))
            return left.flatMap { $0.offset(by: -s.sliver, arcTolerance: tol) }.flatMap { $0.offset(by: s.sliver, arcTolerance: tol) }
        }

        private func materialLeft(area i: Int) -> Bool { material(area: i).contains { $0.area > 1e-6 } }

        // MARK: Passes

        /// One pass from the current position and heading until the bit is in air (or cornered). Returns whether it cut
        /// anything, and where it ended and which way it was heading.
        private func pass(area i: Int) -> (Bool, (Vec2, Double)) {
            guard var pos = position else { return (false, (.zero, 0)) }
            var theta = heading
            var pts = [pos]
            var loads: [Double] = []
            var turn = 0.0
            var step = s.maxStep
            var light = 0.0
            var cut = 0.0
            cleared.restart(at: pos)
            for _ in 0..<200_000 {
                guard let next = self.step(area: i, from: pos, heading: theta, length: step, turn: turn) else { break }
                pts.append(next.point)
                loads.append(next.load)
                cleared.advance(to: next.point)
                let L = pos.distance(to: next.point)
                cut += next.load * L
                light = next.load < 0.25 ? light + L : 0
                turn = next.turn
                if abs(turn) > 0.25 { step = max(s.minStep, step * 0.6) } else if abs(turn) < 0.07 { step = min(s.maxStep, step * 1.4) }
                pos = next.point
                theta = next.heading
                if light > 1.5 * s.toolRadius { break }
            }
            cleared.flush()
            if pts.count >= 2 { moves.append(.cut(pts, loads: loads)) }
            return (cut > 0.5 * s.toolRadius, (pos, theta))
        }

        struct Step {
            var point: Vec2
            var heading: Double
            var turn: Double
            /// Area cut per mm as a share of the optimal load.
            var load: Double
        }

        /// The next step from `p` heading `theta`: the heading within ±45° (less on turns toward the material) whose cut
        /// is closest to the optimal load. nil when there's nothing left to cut ahead, or every heading would overload.
        private func step(area i: Int, from p: Vec2, heading theta: Double, length: Double, turn last: Double) -> Step? {
            var L = length
            while true {
                if let st = search(area: i, from: p, heading: theta, length: L, turn: last) { return st.ok ? st.step : nil }
                if L <= s.minStep * 1.001 { return nil }
                L = max(s.minStep, L / 2)
            }
        }

        /// nil: no valid heading at this length (try shorter). `ok` false: stop the pass.
        private func search(area i: Int, from p: Vec2, heading theta: Double, length L: Double,
                            turn last: Double) -> (ok: Bool, step: Step?)? {
            let quarter = Double.pi / 4
            // + turns left. Material is on the right when climbing, so right turns are toward it.
            let toward = min(quarter, L / max(s.loopRadius, 1e-6))
            let lo = s.climb ? -toward : -quarter
            let hi = s.climb ? quarter : toward
            func point(_ d: Double) -> Vec2 { p + Vec2.fromAngle(theta + d, length: L) }
            func valid(_ d: Double) -> Bool { segmentInside(area: i, p, point(d)) }
            // The valid run of headings nearest the last turn.
            let k = 9
            let samples = (0..<k).map { lo + (hi - lo) * Double($0) / Double(k - 1) }
            let ok = samples.map(valid)
            guard ok.contains(true) else { return nil }
            let want = min(max(last, lo), hi)
            var runs: [(Int, Int)] = []
            var j = 0
            while j < k {
                if ok[j] {
                    var e = j
                    while e + 1 < k && ok[e + 1] { e += 1 }
                    runs.append((j, e))
                    j = e + 1
                } else {
                    j += 1
                }
            }
            func gap(_ run: (Int, Int)) -> Double {
                want < samples[run.0] ? samples[run.0] - want : (want > samples[run.1] ? want - samples[run.1] : 0)
            }
            let run = runs.min { gap($0) < gap($1) }!
            var vlo = samples[run.0], vhi = samples[run.1]
            if run.0 > 0 {
                var bad = samples[run.0 - 1]
                for _ in 0..<4 { let m = (bad + vlo) / 2; if valid(m) { vlo = m } else { bad = m } }
            }
            if run.1 < k - 1 {
                var bad = samples[run.1 + 1]
                for _ in 0..<4 { let m = (bad + vhi) / 2; if valid(m) { vhi = m } else { bad = m } }
            }
            let target = s.load * L
            var evaluated: [(d: Double, area: Double)] = []
            func area(_ d: Double) -> Double {
                let a = cleared.crescent(p, point(d)).area
                evaluated.append((d, a))
                return a
            }
            func done(_ d: Double, _ a: Double) -> (ok: Bool, step: Step?) {
                (true, Step(point: point(d), heading: theta + d, turn: d, load: a / target))
            }
            // More engagement toward the material: the low end when climbing.
            let more = s.climb ? vlo : vhi, less = s.climb ? vhi : vlo
            let d0 = min(max(want, vlo), vhi)
            let a0 = area(d0)
            if abs(a0 - target) <= loadTolerance * target { return done(d0, a0) }
            if a0 > target {
                let aLess = area(less)
                if aLess > target {
                    // Every heading takes too much: accept a slight overload, else stop here.
                    let best = evaluated.min { $0.area < $1.area }!
                    return best.area <= overload * target ? done(best.d, best.area) : (false, nil)
                }
                return solve(d0, a0, less, aLess, target: target, area: area, done: done)
            } else {
                let aMore = area(more)
                if aMore < target {
                    // Not enough material anywhere ahead: take the most there is, or stop in air.
                    return aMore > 1e-9 || a0 > 1e-9 ? done(aMore >= a0 ? more : d0, max(aMore, a0)) : (false, nil)
                }
                return solve(d0, a0, more, aMore, target: target, area: area, done: done)
            }
        }

        /// Regula falsi (Illinois) between two headings whose cuts straddle the target.
        private func solve(_ da: Double, _ aa: Double, _ db: Double, _ ab: Double, target: Double,
                           area: (Double) -> Double, done: (Double, Double) -> (ok: Bool, step: Step?)) -> (ok: Bool, step: Step?) {
            var (x0, f0) = (da, aa - target), (x1, f1) = (db, ab - target)
            var best = abs(f0) < abs(f1) ? (x0, aa) : (x1, ab)
            var side = 0
            for _ in 0..<12 {
                let x = abs(f1 - f0) > 1e-15 ? x1 - f1 * (x1 - x0) / (f1 - f0) : (x0 + x1) / 2
                let a = area(x)
                let f = a - target
                if abs(f) < abs(best.1 - target) { best = (x, a) }
                if abs(f) <= loadTolerance * target { return done(x, a) }
                if (f > 0) == (f1 > 0) {
                    x1 = x; f1 = f
                    if side == -1 { f0 /= 2 }
                    side = -1
                } else {
                    x0 = x; f0 = f
                    if side == 1 { f1 /= 2 }
                    side = 1
                }
            }
            return best.1 <= overload * target ? done(best.0, best.1) : (false, nil)
        }

        // MARK: Starting passes

        /// Where the next pass starts in area `i`: the upstream end (for the cut direction) of the stretch of frontier
        /// nearest the tool — a point the bit fits at in cleared area, just off uncut material, heading along the
        /// frontier with the material on the cutting side.
        private func nextStart(area i: Int) -> (Vec2, Double)? {
            let pieces = material(area: i).filter { $0.area > 1e-6 }
            guard !pieces.isEmpty else { return nil }
            let r = s.toolRadius
            let gap = 0.05 * s.load + s.arcTolerance
            let spacing = max(0.5 * s.load, 0.1)
            let here = position ?? .zero
            // Candidate starts along each material loop, in loop order: where the bit fits in the area just off it.
            var loops: [[(point: Vec2, heading: Double)?]] = []
            for piece in pieces {
                for loop in piece.loops {
                    let walker = LoopWalker(loop)
                    let n = max(8, Int((walker.length / spacing).rounded(.up)))
                    var cand: [(point: Vec2, heading: Double)?] = []
                    cand.reserveCapacity(n)
                    for k in 0..<n {
                        let t = walker.length * Double(k) / Double(n)
                        let q = walker.point(at: t)
                        let tangent = (walker.point(at: t + 0.01) - walker.point(at: t - 0.01)).normalized
                        // Region loops have their inside (the material) on the left.
                        let p = q + tangent.perpRight * (r + gap)
                        guard tangent.lengthSquared > 0.5, inside(area: i, p), !dead.contains(where: { $0.distance(to: p) < 0.25 * r }) else {
                            cand.append(nil)
                            continue
                        }
                        cand.append((p, (s.climb ? -tangent : tangent).angle))
                    }
                    loops.append(cand)
                }
            }
            // The nearest upstream end of a stretch (climbing walks a loop backwards, so a stretch starts at its last
            // candidate in loop order); checked for cut material only once chosen, as that's the costly test.
            for _ in 0..<64 {
                var best: (loop: Int, k: Int, distance: Double)?
                for (l, cand) in loops.enumerated() {
                    let n = cand.count
                    let all = !cand.contains { $0 == nil }
                    for k in 0..<n {
                        guard let c = cand[k] else { continue }
                        let upstream = s.climb ? cand[(k + 1) % n] == nil : cand[(k + n - 1) % n] == nil
                        guard upstream || all else { continue }
                        let d = c.point.distance(to: here)
                        if d < (best?.distance ?? .infinity) { best = (l, k, d) }
                    }
                }
                guard let best, let c = loops[best.loop][best.k] else { return nil }
                if cleared.material(near: c.point, radius: r - 0.5 * gap) < 0.01 * s.load * r { return (c.point, c.heading) }
                loops[best.loop][best.k] = nil
            }
            return nil
        }

        // MARK: Links

        /// Gets from the current position to `q` (heading `hq`): stays down through cleared area when a link that
        /// short exists, else lifts.
        private func link(area i: Int, to q: Vec2, heading hq: Double) {
            defer {
                position = q
                heading = hq
                cleared.restart(at: q)
            }
            guard let p = position else {
                moves.append(.lift(q))
                return
            }
            let direct = p.distance(to: q)
            guard direct > 1e-6 else { return }
            let allowed = stayDownRatio * direct + s.toolRadius
            // A Dubins path at the minimum loop radius: no stop at either end.
            let rho = s.loopRadius
            if let path = Dubins.shortest(from: p, heading: heading, to: q, heading: hq, radius: rho), path.length <= allowed {
                let pts = path.points(radius: rho, tolerance: s.arcTolerance)
                if clear(area: i, pts) {
                    moves.append(.link(pts, radius: rho))
                    return
                }
            }
            if clear(area: i, [p, q]) {
                moves.append(.link([p, q], radius: nil))
                return
            }
            // Back along the last pass to where a straight line reaches q.
            if case let .cut(trail, _)? = moves.last, trail.count > 2 {
                var back: [Vec2] = [p]
                var length = 0.0
                for k in stride(from: trail.count - 2, through: 0, by: -1) {
                    length += trail[k].distance(to: back[back.count - 1])
                    back.append(trail[k])
                    if length + trail[k].distance(to: q) > allowed { break }
                    if k % 4 == 0 || k == 0, clear(area: i, [trail[k], q]) {
                        moves.append(.link(back + [q], radius: nil))
                        return
                    }
                }
            }
            moves.append(.lift(q))
        }

        /// True when the bit can follow `pts` at depth without leaving area `i` or cutting more than a whisker.
        private func clear(area i: Int, _ pts: [Vec2]) -> Bool {
            let r = s.toolRadius
            let graze = min(0.1 * s.load, 0.05 * r)
            let spacing = max(0.05, min(0.5 * s.load, 0.25 * r))
            for k in 1..<pts.count {
                let a = pts[k - 1], b = pts[k]
                guard segmentInside(area: i, a, b) else { return false }
                let n = max(1, Int((a.distance(to: b) / spacing).rounded(.up)))
                for j in 1...n where cleared.material(near: a.lerp(to: b, Double(j) / Double(n)), radius: r - graze) > 1e-4 * r {
                    return false
                }
            }
            return true
        }
    }
}
