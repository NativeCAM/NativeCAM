import Foundation

/// A tiled job: each tile's toolpaths, in job coordinates and in the order they cut. `JobResult.toolpaths` is all of
/// them one tile after another (the assembled job, for the canvas, the simulation and the estimate); each tile's file
/// cuts `toolpaths(inTile:)`.
public struct TiledJob: Sendable {
    public var layout: TileLayout
    /// Each tile's toolpaths in job coordinates.
    public var tiles: [[Toolpath]]

    /// Tile `index`'s toolpaths in its own coordinates (job XY less the tile's offset), as its file cuts them.
    public func toolpaths(inTile index: Int) -> [Toolpath] {
        let o = layout.tiles[index].offset
        return tiles[index].map { TileSplitter.translated($0, by: Vec2(-o.x, -o.y)) }
    }
}

/// Splits a job's toolpaths into tiles (see `TilingSettings`).
///
/// Each cut belongs to the tile whose share of the job it's in. A tile's share is its core (its frame on the
/// material) with the tile lines shifted a little into the next tile, so a cut that crosses a tile line runs on past
/// it into the overlap before it breaks, and the break is never on the seam itself. Where a cut breaks, the tool
/// retracts and the tile that cuts the rest comes back down onto the same point: straight down at the plunge rate, or
/// ramping along the cut when the toolpath ramps in (and always for a surfacing bit).
///
/// The share depends only on where a point is, not on which way the cut was going, so every depth pass over a point is
/// cut in the same tile, in order. Toolpaths that rely on another one having cut first (a rest-machined pocket's
/// larger bit, a V-carve's flat clearing, a 3D rough before its finish) have their tile lines shifted apart by both
/// bits' radii, the earlier one further into the next tile, so near a tile line the later toolpath never reaches
/// material the earlier one leaves for a later tile. Everything else that reads what earlier toolpaths cut (start
/// depths, leads) is told the material near tile lines is uncut (see `CAMEngine`), and the links between cuts are
/// worked out again per tile from the material as the tiles really leave it, one after another.
enum TileSplitter {
    struct Source {
        var toolpath: Toolpath
        var operation: CAMOperation
    }

    /// The operation every registration toolpath belongs to (it isn't one of the project's).
    static let registrationOperation = UUID(uuidString: "7E61E000-0000-4000-8000-000000000000")!

    /// Things to know about one tiled pass.
    struct Result {
        var job: TiledJob
        var toolpaths: [Toolpath]
        var issues: [JobIssue]
    }

    static func run(_ sources: [Source], project: Project, layout: TileLayout, keepOuts: [KeepOut], clearanceZ: Double,
                    newModel: () -> MaterialSimulator) -> Result {
        let stock = project.stock, machine = project.machine
        let u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var issues: [JobIssue] = []
        let (shift, short) = shifts(sources, overlap: layout.overlap)
        for s in short {
            issues.append(JobIssue(.warning, "The overlap (\(fmt(layout.overlap))) is too narrow to keep “\(s.earlier)” cutting ahead of "
                + "“\(s.later)” at the tile lines, so near them it can meet material the other hasn't cleared yet. Make the "
                + "overlap at least \(fmt(s.needed)).", operation: s.later))
        }
        let shares = sources.enumerated().map { i, s in split(s.toolpath, layout: layout, shift: shift[i]) }
        let holes = registrationToolpaths(project, layout: layout, issues: &issues)

        var model = newModel()
        var tiles: [[Toolpath]] = Array(repeating: [], count: layout.count)
        for tile in layout.tiles {
            let k = tile.index
            // Dowels stand in last tile's holes while this one cuts: links go over them at safe Z.
            let dowels = (layout.registration?.dowels[k] ?? []).map { p in
                KeepOut(outline: ProtectedRegions.circle(p + tile.offset, radius: layout.registration!.radius + 0.5, tolerance: 0.05),
                        height: 0)
            }
            let settings = LinkOptimizer.Settings(safeDistance: stock.safeDistance, clearanceZ: clearanceZ, stayDownLimit: 0,
                                                  floorZ: -stock.thickness, keepOuts: keepOuts + dowels)
            var pieces: [(tp: Toolpath, op: CAMOperation?)] = []
            if let reg = holes[k] { pieces.append((reg, nil)) }
            for (i, s) in sources.enumerated() {
                guard let built = assemble(shares[i][k], tool: s.toolpath.tool, stock: stock, ramp: rampLength(s)) else { continue }
                var tp = s.toolpath
                tp.id = pieceID(s.toolpath.id, tile: k)
                tp.operationID = s.toolpath.sourceOperationID
                tp.start = built.start
                tp.motions = built.motions
                tp.warnings = []
                pieces.append((tp, s.operation))
            }
            for (raw, op) in pieces {
                var tp = raw
                tp.tile = k
                let uncut = op.map { $0.adjustsFeedsForLoad && FeedScheduler.suits(tp.tool) } == true ? model.grid : nil
                if stock.retract == .minimum {
                    var s = settings
                    s.stayDownLimit = max(3 * tp.tool.diameter, 10)
                    tp = LinkOptimizer.optimize(tp, model: &model, settings: s)
                } else {
                    tp.forEachMotion { s, m in model.apply(m, from: s, tool: tp.tool) }
                }
                issues.append(contentsOf: CAMEngine.keepOutIssues(tp, keepOuts: keepOuts, clearanceZ: clearanceZ))
                if machine.outputArcs { tp = ArcFitter.fit(tp, tolerance: machine.arcFitTolerance) }
                if let op {
                    let (scheduled, notes) = FeedScheduler.apply(tp, operation: op, uncut: uncut, wrapped: false, project: project)
                    tp = scheduled
                    issues.append(contentsOf: notes)
                }
                if let op { issues.append(contentsOf: CAMEngine.validate(tp, operation: op, project: project, checkTravel: false)) }
                tiles[k].append(tp)
            }
        }
        issues.append(contentsOf: travelIssues(tiles, layout: layout, project: project))
        issues.append(contentsOf: registrationIssues(tiles, layout: layout, project: project, keepOuts: keepOuts))
        let job = TiledJob(layout: layout, tiles: tiles)
        // One of each: the same check on a toolpath in two tiles says the same thing.
        var seen = Set<String>()
        issues = issues.filter { seen.insert($0.id).inserted }
        return Result(job: job, toolpaths: tiles.flatMap { $0 }, issues: issues)
    }

    // MARK: Order

    /// Whether `later` relies on `earlier` having cut first: the clearing a toolpath of the same operation did, or a 3D
    /// rough of the same model.
    static func depends(_ later: Source, on earlier: Source) -> Bool {
        if later.operation.id == earlier.operation.id { return true }
        if case .finish3D = later.operation.kind, case .rough3D = earlier.operation.kind,
           !Set(later.operation.shapeIDs).isDisjoint(with: earlier.operation.shapeIDs) { return true }
        return false
    }

    /// How far each toolpath's tile lines are shifted into the later tile, mm. A toolpath that others rely on has its
    /// lines at least both bits' radii further on than theirs (longest path through the dependencies, centred on the
    /// tile line); the rest run half the overlap on. Also the pairs the overlap is too narrow for.
    static func shifts(_ sources: [Source], overlap: Double)
        -> (shifts: [Double], short: [(earlier: String, later: String, needed: Double)]) {
        let n = sources.count
        var after: [[Int]] = Array(repeating: [], count: n)
        for k in 0..<n {
            for i in 0..<k where depends(sources[k], on: sources[i]) { after[i].append(k) }
        }
        let involved = Set((0..<n).filter { !after[$0].isEmpty } + after.flatMap { $0 })
        func r(_ i: Int) -> Double { sources[i].toolpath.tool.radius }
        var h = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in after[i] { h[i] = max(h[i], h[k] + r(i) + r(k)) }
        }
        let top = involved.map { h[$0] }.max() ?? 0
        let shifts = (0..<n).map { i in involved.contains(i) ? min(overlap, max(-overlap, h[i] - top / 2)) : overlap / 2 }
        var short: [(String, String, Double)] = []
        for i in 0..<n {
            for k in after[i] where shifts[i] - shifts[k] < r(i) + r(k) - 1e-6 {
                short.append((sources[i].toolpath.name, sources[k].toolpath.name, top / 2))
            }
        }
        return (shifts, short)
    }

    // MARK: Splitting

    /// Each tile's share of a toolpath's motions, each with its start: cuts are split where they cross a tile line
    /// (shifted by `shift`), straight up-and-down rapids stay with the tile they're over, and sideways rapids are dropped
    /// (each tile links its own share again).
    static func split(_ tp: Toolpath, layout: TileLayout, shift: Double) -> [[(start: Vec3, motion: Motion)]] {
        var out = Array(repeating: [(start: Vec3, motion: Motion)](), count: layout.count)
        func tile(_ p: Vec2) -> Int { layout.tileIndex(at: p, shift: shift) }
        func cut(_ a: Vec3, _ b: Vec3, feed: Double) {
            for (p, q) in pieces(from: a, to: b, layout: layout, shift: shift) {
                out[tile(p.xy.lerp(to: q.xy, 0.5))].append((p, .feed(q, feed)))
            }
        }
        var pos = tp.start
        for m in tp.motions {
            switch m.kind {
            case .rapid:
                if pos.xy.isApprox(m.end.xy, tolerance: 1e-6) { out[tile(pos.xy)].append((pos, m)) }
            case .dwell:
                out[tile(pos.xy)].append((pos, m))
            case .feed:
                cut(pos, m.end, feed: m.feed)
            case .arcCW, .arcCCW:
                // Generators write lines (arcs are fitted afterwards, per tile); an arc read from elsewhere is cut as lines.
                var p = pos
                for q in m.samples(from: pos, maxStep: 0.25) {
                    cut(p, q, feed: m.feed)
                    p = q
                }
            }
            if m.kind != .dwell { pos = m.end }
        }
        return out
    }

    /// A straight move cut where it crosses the tile lines shifted by `shift`.
    static func pieces(from a: Vec3, to b: Vec3, layout: TileLayout, shift: Double) -> [(Vec3, Vec3)] {
        var ts: [Double] = []
        for x in layout.seamsX {
            let X = x + shift
            if (a.x - X) * (b.x - X) < 0 { ts.append((X - a.x) / (b.x - a.x)) }
        }
        for y in layout.seamsY {
            let Y = y + shift
            if (a.y - Y) * (b.y - Y) < 0 { ts.append((Y - a.y) / (b.y - a.y)) }
        }
        guard !ts.isEmpty else { return [(a, b)] }
        var out: [(Vec3, Vec3)] = []
        var p = a
        for t in ts.sorted() where t > 1e-12 && t < 1 - 1e-12 {
            let q = a.lerp(to: b, t)
            if p.distance(to: q) > 1e-9 { out.append((p, q)) }
            p = q
        }
        out.append((p, b))
        return out
    }

    /// How far a toolpath ramps back into a cut, mm, or nil to plunge: as the operation enters, and always for a
    /// surfacing bit, which can't plunge.
    static func rampLength(_ s: Source) -> Double? {
        switch s.operation.kind {
        case let .profile(p) where p.entry.kind == .ramp && p.entry.rampLength > 0: return p.entry.rampLength
        case let .pocket(p) where p.entry.kind == .ramp && p.entry.rampLength > 0: return p.entry.rampLength
        default: return s.toolpath.tool.shape == .surfacing ? 2 * s.toolpath.tool.diameter : nil
        }
    }

    /// One tile's share of a toolpath as motions: each gap between its pieces linked up to safe Z, across, down to the
    /// plunge height and back into the cut. nil when the share cuts nothing.
    static func assemble(_ kept: [(start: Vec3, motion: Motion)], tool: Tool, stock: Stock, ramp: Double?) -> (start: Vec3, motions: [Motion])? {
        guard kept.contains(where: { $0.motion.kind == .feed }) else { return nil }
        let clearance = max(stock.clearanceHeight, stock.plungeHeight)
        let plungeZ = max(0.1, stock.plungeHeight)
        let start = Vec3(kept[0].start.xy, max(clearance, kept[0].start.z))
        var out: [Motion] = []
        var cur = start
        func rapid(_ p: Vec3) {
            guard p.distance(to: cur) > 1e-9 else { return }
            out.append(.rapid(p))
            cur = p
        }
        func feed(_ p: Vec3, _ f: Double) {
            guard p.distance(to: cur) > 1e-9 else { return }
            out.append(.feed(p, f))
            cur = p
        }
        /// The deepest this share has cut at `p` so far (a pass above it), or the material top.
        func floor(at p: Vec2) -> Double {
            var z = 0.0
            for m in out where m.kind != .rapid && m.end.xy.isApprox(p, tolerance: 0.05) { z = min(z, m.end.z) }
            return z
        }
        /// Back down into the cut at `q`, from straight above it.
        func enter(_ q: Vec3, following rest: ArraySlice<(start: Vec3, motion: Motion)>) {
            guard let length = ramp else { return feed(q, tool.cutting.plungeRate) }
            let top = max(q.z, floor(at: q.xy))
            feed(Vec3(q.xy, top), tool.cutting.plungeRate)
            guard top - q.z > 1e-6 else { return feed(q, tool.cutting.plungeRate) }
            // Zig-zag along the cut ahead, never below it, then back to `q` at depth.
            var path: [Vec3] = [q]
            var travelled = 0.0
            var rate = tool.cutting.feedRate
            for item in rest {
                guard item.motion.kind == .feed, item.start.distance(to: path[path.count - 1]) < 1e-6 else { break }
                let a = path[path.count - 1], b = item.motion.end
                let d = a.xy.distance(to: b.xy)
                if path.count == 1 { rate = item.motion.feed }
                if travelled + d >= length, d > 1e-9 {
                    path.append(a.lerp(to: b, (length - travelled) / d))
                    travelled = length
                    break
                }
                path.append(b)
                travelled += d
            }
            guard travelled > 1 else { return feed(q, tool.cutting.plungeRate) }
            let slope = max(0.1, tool.cutting.stepdown) / length
            let legs = 2 * max(1, Int((((top - q.z) / slope) / (2 * travelled) - 1e-9).rounded(.up)))
            let total = Double(legs) * travelled
            var done = 0.0
            for leg in 0..<legs {
                let points = leg % 2 == 0 ? Array(path.dropFirst()) : Array(path.reversed().dropFirst())
                var p = cur
                for target in points {
                    done += p.xy.distance(to: target.xy)
                    let z = max(target.z, top + (q.z - top) * min(1, done / total))
                    feed(Vec3(target.xy, z), rate)
                    p = target
                }
            }
            feed(q, rate)
        }
        for (j, item) in kept.enumerated() {
            let q = item.start
            if q.distance(to: cur) > 1e-6 {
                if !cur.xy.isApprox(q.xy, tolerance: 1e-6) {
                    if cur.z < clearance - 1e-9 { rapid(Vec3(cur.xy, clearance)) }
                    rapid(Vec3(q.xy, cur.z))
                }
                if q.z > cur.z + 1e-9 {
                    rapid(q)
                } else if q.z < cur.z - 1e-9 {
                    if cur.z > plungeZ { rapid(Vec3(q.xy, max(q.z, plungeZ))) }
                    if q.z < cur.z - 1e-9 { enter(q, following: kept[j...]) }
                }
            }
            out.append(item.motion)
            if item.motion.kind != .dwell { cur = item.motion.end }
        }
        if cur.z < clearance - 1e-9 { rapid(Vec3(cur.xy, clearance)) }
        return (start, out)
    }

    /// A toolpath moved by `d` in XY (job to tile coordinates and back).
    static func translated(_ tp: Toolpath, by d: Vec2) -> Toolpath {
        var t = tp
        let d3 = Vec3(d, 0)
        t.start = tp.start + d3
        t.motions = tp.motions.map { m in
            var r = m
            r.end = m.end + d3
            if m.kind.isArc { r.center = m.center + d }
            return r
        }
        t.reliefCorners = nil
        return t
    }

    /// A toolpath's ID in a tile: its own, changed in bytes no other derived ID uses.
    static func pieceID(_ id: UUID, tile: Int) -> UUID {
        var u = id.uuid
        u.9 ^= 0xA5
        u.10 ^= UInt8(truncatingIfNeeded: tile + 1)
        u.11 ^= UInt8(truncatingIfNeeded: (tile + 1) >> 8)
        return UUID(uuid: u)
    }

    // MARK: Registration holes

    /// Each tile's registration holes as a toolpath in job coordinates (nil for a tile that drills none), cut first in
    /// the tile with the chosen bit: plunged in pecks when the bit is the hole's size, otherwise bored in helixes.
    static func registrationToolpaths(_ project: Project, layout: TileLayout, issues: inout [JobIssue]) -> [Toolpath?] {
        let none = [Toolpath?](repeating: nil, count: layout.count)
        guard let reg = layout.registration, let settings = project.tiling?.registration else { return none }
        let u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        let name = "Registration holes"
        guard let tool = settings.resolvedTool(in: project) else {
            issues.append(JobIssue(.error, "No bit in the job fits a \(fmt(settings.diameter)) registration hole. Choose the bit that "
                + "drills them in Job Setup ▸ Tiling.", operation: name))
            return none
        }
        guard RegistrationHoles.canDrill(tool) else {
            issues.append(JobIssue(.error, "\(tool.name) is tapered and can't bore a straight registration hole. Choose an end "
                + "mill or drill.", operation: name))
            return none
        }
        guard tool.diameter <= settings.diameter + 0.01 else {
            issues.append(JobIssue(.error, "\(tool.name) (\(fmt(tool.diameter))) is wider than the \(fmt(settings.diameter)) "
                + "registration holes.", operation: name))
            return none
        }
        if reg.depth > tool.fluteLength + 1e-6 {
            issues.append(JobIssue(.warning, "The holes are \(fmt(reg.depth)) deep (through the material and "
                + "\(fmt(settings.spoilboardDepth)) into the spoilboard), more than \(tool.name)'s cutting length "
                + "(\(fmt(tool.fluteLength))).", operation: name))
        }
        return layout.tiles.map { tile in
            let points = reg.drilled[tile.index].map { $0 + tile.offset }
            guard !points.isEmpty else { return nil }
            let motions = bore(points, radius: reg.radius, depth: reg.depth, tool: tool, stock: project.stock)
            let id = pieceID(registrationOperation, tile: tile.index)
            return Toolpath(id: id, name: name, tool: tool, spindleRPM: tool.cutting.spindleRPM,
                            start: Vec3(points[0], max(project.stock.clearanceHeight, project.stock.plungeHeight)),
                            motions: motions, operationID: registrationOperation)
        }
    }

    /// Holes of `radius` to `depth` below the material top at `points`, in order.
    static func bore(_ points: [Vec2], radius: Double, depth: Double, tool: Tool, stock: Stock) -> [Motion] {
        var b = ToolpathBuilder(stock: stock, tool: tool, startXY: points.first)
        let r = tool.radius
        let ring = radius - r
        let step = max(0.1, tool.cutting.stepdown)
        for c in points {
            if ring < 0.05 {
                // The bit is the hole's size: plunge in pecks, clearing chips between them.
                var reached = 0.0
                b.enter(at: Vec3(c, b.plungeZ))
                while reached < depth - 1e-9 {
                    if reached > 0 { b.rapid(Vec3(c, -reached + 0.5)) }
                    reached = min(depth, reached + step)
                    b.feed(Vec3(c, -reached), rate: tool.cutting.plungeRate)
                    if reached < depth - 1e-9 { b.rapid(Vec3(c, b.plungeZ)) }
                }
                b.retract()
                continue
            }
            // Rings out from the middle (so no core is left standing in the spoilboard), each a helix down to depth
            // and a lap round the bottom.
            let inner = 0.9 * r
            var rings: [Double] = [ring]
            if ring > inner {
                let n = Int(((ring - inner) / (0.8 * tool.diameter)).rounded(.up))
                rings = (0...n).map { k -> Double in inner + (ring - inner) * Double(k) / Double(n) }
            }
            let feed = tool.cutting.feedRate
            for rho in rings {
                let circumference = 2 * Double.pi * rho
                let pitch = min(step, max(0.2, circumference * tan(10 * Double.pi / 180)))
                let segments = max(24, Int((circumference / 1.0).rounded(.up)))
                b.enter(at: Vec3(c + Vec2(rho, 0), 0))
                let total = max(1, Int((depth / pitch * Double(segments)).rounded(.up)))
                for k in 1...total {
                    let turn = Double(k) / Double(segments)
                    let p = c + Vec2.fromAngle(2 * Double.pi * turn, length: rho)
                    b.feed(Vec3(p, -min(depth, turn * pitch)), rate: feed)
                }
                let a0 = 2 * Double.pi * Double(total) / Double(segments)
                for k in 1...segments {
                    let p = c + Vec2.fromAngle(a0 + 2 * Double.pi * Double(k) / Double(segments), length: rho)
                    b.feed(Vec3(p, -depth), rate: feed)
                }
                b.feed(Vec3(c, -depth), rate: feed)
                b.retract()
            }
        }
        return b.build(id: registrationOperation, name: "", tool: tool, rpm: tool.cutting.spindleRPM, warnings: []).motions
    }

    // MARK: Checks

    /// Each tile's reach against the machine's travel.
    static func travelIssues(_ tiles: [[Toolpath]], layout: TileLayout, project: Project) -> [JobIssue] {
        let travel = project.machine.travel, u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var issues: [JobIssue] = []
        for (k, tps) in tiles.enumerated() {
            let all = tps.compactMap(\.cuttingExtents)
            guard let first = all.first else { continue }
            let lo = all.reduce(first.min) { Vec3(min($0.x, $1.min.x), min($0.y, $1.min.y), 0) }
            let hi = all.reduce(first.max) { Vec3(max($0.x, $1.max.x), max($0.y, $1.max.y), 0) }
            for (axis, span, limit, tiled) in [("X", hi.x - lo.x, travel.x, layout.mode.tilesX), ("Y", hi.y - lo.y, travel.y, layout.mode.tilesY)]
            where span > limit + 1e-3 {
                let fix = tiled ? "Make the tiles smaller or the overlap narrower."
                    : "Feed-through in \(axis == "X" ? "Y" : "X") doesn't split the material across; use Individual tiles."
                issues.append(JobIssue(.error, "Tile \(k + 1) cuts across \(fmt(span)) in \(axis), more than the machine's "
                    + "\(fmt(limit)) of travel. \(fix)"))
            }
        }
        return issues
    }

    /// Registration holes on the design, under a clamp, or too near the material's edge.
    static func registrationIssues(_ tiles: [[Toolpath]], layout: TileLayout, project: Project, keepOuts: [KeepOut]) -> [JobIssue] {
        guard let reg = layout.registration, tiles.flatMap({ $0 }).contains(where: { $0.sourceOperationID == registrationOperation })
        else { return [] }
        let u = project.displayUnits, stock = project.stock
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        func at(_ p: Vec2) -> String { "X \(u.format(p.x)), Y \(u.format(p.y))" }
        let name = "Registration holes"
        var issues: [JobIssue] = []
        func add(_ severity: Severity, _ message: String) { issues.append(JobIssue(severity, message, operation: name)) }
        let r = reg.radius
        let holes = reg.materialHoles(layout.tiles, stock: stock)
        let cuts = tiles.flatMap { $0 }.filter { $0.sourceOperationID != registrationOperation }
        // The shapes the job's toolpaths cut, and the parts they leave.
        let used = Set(project.operations.filter(\.enabled).flatMap(\.shapeIDs))
        let shapes = project.shapes.filter { used.contains($0.id) && !$0.isKeepOut }
        let outlines = shapes.map { ($0.name, $0.polylines(tolerance: 0.1)) }
        let parts = ProtectedRegions(project, flattenTolerance: 0.05, arcTolerance: 0.02)
        let reach = Rect2(min: Vec2(-r, -r), max: Vec2(stock.width + r, stock.height + r))
        let zones = parts.zones(toolRadius: r, cut: [], walls: [], near: reach, arcTolerance: 0.02)
        for (p, tile) in holes {
            let place = "The registration hole tile \(tile + 1) drills at \(at(p))"
            let edge = min(p.x, p.y, stock.width - p.x, stock.height - p.y)
            if edge < r + 1.5 {
                add(.warning, "\(place) is \(fmt(max(0, edge - r))) from the material's edge, too close to hold a dowel. Increase "
                    + "the edge offset.")
            }
            for tp in cuts {
                var near = false
                tp.forEachMotion { s, m in
                    guard !near, m.kind != .rapid, m.kind != .dwell, min(s.z, m.end.z) < 0 else { return }
                    if distancePointSegment(p, s.xy, m.end.xy) < r + tp.tool.radius + 0.25 { near = true }
                }
                if near {
                    add(.error, "\(place) is where “\(tp.name)” cuts\(tile + 1 < layout.count ? ", and a dowel stands in it while tile \(tile + 2) cuts" : ""). "
                        + "Change the edge offset or the tile size so the holes land in waste.")
                }
            }
            for (shape, loops) in outlines {
                let inside = loops.contains { $0.isClosed && $0.count >= 3 && $0.contains(p) }
                let touching = loops.contains { $0.count >= 2 && $0.closestPoint(to: p).distance < r + 0.5 }
                if inside || touching {
                    add(.error, "\(place) drills through the design (“\(shape)”). Change the edge offset or the tile size so the "
                        + "holes land in waste.")
                }
            }
            for zone in zones where zone.contains(p) {
                add(.error, "\(place) cuts into the part “\(zone.name)” leaves.")
            }
        }
        // The spoilboard holes in front of the material, and the material holes, against clamps.
        let spoilboard = reg.spoilboard.map { $0 + layout.tiles[0].offset }
        for p in spoilboard + holes.map(\.point) {
            for k in keepOuts where k.outline.contains(p) || k.outline.closestPoint(to: p).distance < r + 0.5 {
                add(.error, "A registration hole at \(at(p)) is under a clamp or keep-out area. Move the clamp or change the edge offset.")
            }
        }
        add(.info, "Holes go \(fmt(reg.depth - stock.thickness)) into the spoilboard. After each move, drop a "
            + "\(fmt(2 * r)) dowel through each hole the last tile drilled into the spoilboard hole under it (see the setup sheet).")
        var seen = Set<String>()
        return issues.filter { seen.insert($0.id).inserted }
    }
}
