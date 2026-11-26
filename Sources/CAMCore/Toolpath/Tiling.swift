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
        /// A profile with leads: how it comes back onto its wall, and leaves it, where a tile line breaks it.
        var leads: BreakLeads?

        init(toolpath: Toolpath, operation: CAMOperation, leads: BreakLeads? = nil) {
            self.toolpath = toolpath
            self.operation = operation
            self.leads = leads
        }
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
        var layout = layout
        if layout.mode == .grid, let reg = layout.registration {
            // Individual tiles' holes slide along their tile lines off anything that covers them.
            let blocked = registrationBlocker(project, sources: sources, layout: layout, radius: reg.radius, keepOuts: keepOuts)
            let placed = RegistrationLayout.grid(project, tiles: layout.tiles, columns: layout.columns, blocked: blocked)
            layout.registration = placed.layout
            for m in placed.moves {
                issues.append(JobIssue(.warning, "Registration hole \(m.number) would have been on \(m.reason), so it's moved "
                    + "\(fmt(m.from.distance(to: m.to))) along its tile line, to X \(u.format(m.to.x)), Y \(u.format(m.to.y)). "
                    + "The setup sheet shows where it went.", operation: "Registration holes"))
            }
        }
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
        // Breaks each profile with leads comes back onto (or leaves) its wall at without one.
        var unfitted = [Int](repeating: 0, count: sources.count)
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
                guard let built = assemble(shares[i][k], tool: s.toolpath.tool, stock: stock, ramp: rampLength(s), leads: s.leads,
                                           within: tile.frame.insetBy(-layout.overlap)) else { continue }
                unfitted[i] += built.unfitted
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
                // Flutes that follow a model: the material over it before they cut (#203).
                let uncutForReach = op.map(FluteReach.follows) == true ? model.grid : nil
                if stock.retract == .minimum {
                    var s = settings
                    s.stayDownLimit = max(3 * tp.tool.diameter, 10)
                    tp = LinkOptimizer.optimize(tp, model: &model, settings: s)
                } else {
                    tp.forEachMotion { s, m in model.apply(m, from: s, tool: tp.tool) }
                }
                issues.append(contentsOf: CAMEngine.keepOutIssues(tp, keepOuts: keepOuts, clearanceZ: clearanceZ))
                if machine.outputArcs, op?.kind.fitsArcs != false { tp = ArcFitter.fit(tp, for: op, project: project) }
                if let op {
                    let (scheduled, notes) = FeedScheduler.apply(tp, operation: op, uncut: uncut, wrapped: false, project: project)
                    tp = scheduled
                    issues.append(contentsOf: notes)
                }
                if let op {
                    let over = uncutForReach.flatMap { grid in
                        FluteReach.surface(op, project: project).flatMap { FluteReach.stockOver(tp, surface: $0, grid: grid) }
                    }
                    issues.append(contentsOf: CAMEngine.validate(tp, operation: op, project: project, checkTravel: false, stockOverModel: over))
                }
                tiles[k].append(tp)
            }
        }
        for (i, s) in sources.enumerated() where unfitted[i] > 0 {
            let n = unfitted[i]
            let how = rampLength(s) == nil ? "plunges back in" : "ramps back in"
            issues.append(JobIssue(.info, "There's no room for a lead at \(n == 1 ? "1 place" : "\(n) places") where a tile line breaks "
                + "this profile, so there it \(how) on the cut and lifts straight off it, as it would without leads.",
                operation: s.toolpath.name))
        }
        if let reg = layout.registration, !reg.holes.isEmpty {
            // Each tile's file stops at the start, spindle off, to say which dowels it stands on.
            for k in 1..<layout.count where !reg.pinned(k).isEmpty && !tiles[k].isEmpty {
                tiles[k][0].spindleOffStop = pinMessage(reg.pinned(k), tile: k, of: layout.count)
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
        case let .edgeProfile(p) where p.entry.kind == .ramp && p.entry.rampLength > 0: return p.entry.rampLength
        default: return s.toolpath.tool.shape == .surfacing ? 2 * s.toolpath.tool.diameter : nil
        }
    }

    /// One tile's share of a toolpath as motions: each gap between its pieces linked up to safe Z, across, down to the
    /// plunge height and back into the cut. With `leads` (a profile with leads), the cut is left at a break on a
    /// lead-out and entered on a lead-in, each kept `within` the tile's reach, wherever one fits; `unfitted` counts the
    /// breaks where none does. nil when the share cuts nothing.
    static func assemble(_ kept: [(start: Vec3, motion: Motion)], tool: Tool, stock: Stock, ramp: Double?,
                         leads: BreakLeads? = nil, within bounds: Rect2 = .empty)
        -> (start: Vec3, motions: [Motion], unfitted: Int)? {
        guard kept.contains(where: { $0.motion.kind == .feed }) else { return nil }
        let clearance = max(stock.clearanceHeight, stock.plungeHeight)
        let plungeZ = max(0.1, stock.plungeHeight)
        var unfitted = 0
        /// The lead-in onto the cut that piece `j` starts, when it starts a cut part-way down (a break) and a lead fits.
        func leadIn(_ j: Int) -> [Vec2]? {
            guard let leads, kept[j].start.z < -1e-6, kept[j].motion.kind == .feed else { return nil }
            let d = kept[j].motion.end.xy - kept[j].start.xy
            guard d.length > 1e-6 else { return nil }
            guard let lead = leads.lead(at: kept[j].start.xy, tangent: d.normalized, out: false, within: bounds) else {
                unfitted += 1
                return nil
            }
            return lead
        }
        let firstLead = leadIn(0)
        let start = Vec3(firstLead?[0] ?? kept[0].start.xy, max(clearance, kept[0].start.z))
        var out: [Motion] = []
        var cur = start
        // The last cut kept, while the tool is still at its end: which way it was going, for a lead-out.
        var lastCut: (from: Vec3, feed: Double)?
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
            zigzag(path, top: top, bottom: q.z, length: length, travelled: travelled, rate: rate)
            feed(q, rate)
        }
        /// Down to `bottom` by going back and forth along `path` (which starts where the tool is), an even number of
        /// legs so it ends back at the start, never steeper than a stepdown over the ramp's length.
        func zigzag(_ path: [Vec3], top: Double, bottom: Double, length: Double, travelled: Double, rate: Double) {
            let slope = max(0.1, tool.cutting.stepdown) / length
            let legs = 2 * max(1, Int((((top - bottom) / slope) / (2 * travelled) - 1e-9).rounded(.up)))
            let total = Double(legs) * travelled
            var done = 0.0
            for leg in 0..<legs {
                let points = leg % 2 == 0 ? Array(path.dropFirst()) : Array(path.reversed().dropFirst())
                var p = cur
                for target in points {
                    done += p.xy.distance(to: target.xy)
                    let z = max(target.z, top + (bottom - top) * min(1, done / total))
                    feed(Vec3(target.xy, z), rate)
                    p = target
                }
            }
        }
        /// Back into the cut at `q` along a lead-in from its start, straight above which the tool is: down in the waste
        /// at the lead's start (ramping along the lead when the toolpath ramps), then along it at depth.
        func enter(_ q: Vec3, on lead: [Vec2], rate: Double) {
            let a = lead[0]
            if let length = ramp {
                let top = max(q.z, floor(at: a))
                feed(Vec3(a, top), tool.cutting.plungeRate)
                let path = lead.map { Vec3($0, q.z) }
                let travelled = zip(lead, lead.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                if top - q.z > 1e-6, travelled > 1 { zigzag(path, top: top, bottom: q.z, length: length, travelled: travelled, rate: rate) }
            }
            feed(Vec3(a, q.z), tool.cutting.plungeRate)
            for p in lead.dropFirst() { feed(Vec3(p, q.z), rate) }
        }
        for (j, item) in kept.enumerated() {
            let q = item.start
            if q.distance(to: cur) > 1e-6 {
                // Left part-way round at a break: off the wall on a lead-out, at the depth it was cutting.
                if let leads, leads.settings.leadOut, cur.z < -1e-6, let last = lastCut {
                    let d = cur.xy - last.from.xy
                    if d.length > 1e-6, let lead = leads.lead(at: cur.xy, tangent: d.normalized, out: true, within: bounds) {
                        let z = cur.z
                        for p in lead.dropFirst() { feed(Vec3(p, z), last.feed) }
                    } else {
                        unfitted += 1
                    }
                }
                lastCut = nil
                let lead = j == 0 ? firstLead : (q.z < cur.z - 1e-9 || !cur.xy.isApprox(q.xy, tolerance: 1e-6) ? leadIn(j) : nil)
                let over = lead?[0] ?? q.xy
                if !cur.xy.isApprox(over, tolerance: 1e-6) {
                    if cur.z < clearance - 1e-9 { rapid(Vec3(cur.xy, clearance)) }
                    rapid(Vec3(over, cur.z))
                }
                if let lead {
                    if cur.z > plungeZ { rapid(Vec3(over, max(q.z, plungeZ))) }
                    enter(q, on: lead, rate: item.motion.feed)
                } else if q.z > cur.z + 1e-9 {
                    rapid(q)
                } else if q.z < cur.z - 1e-9 {
                    if cur.z > plungeZ { rapid(Vec3(q.xy, max(q.z, plungeZ))) }
                    if q.z < cur.z - 1e-9 { enter(q, following: kept[j...]) }
                }
            }
            lastCut = item.motion.kind == .feed && !item.start.xy.isApprox(item.motion.end.xy, tolerance: 1e-6)
                ? (item.start, item.motion.feed) : nil
            out.append(item.motion)
            if item.motion.kind != .dwell { cur = item.motion.end }
        }
        // The share ends part-way round: off the wall on a lead-out before lifting.
        if let leads, leads.settings.leadOut, cur.z < -1e-6, let last = lastCut {
            let d = cur.xy - last.from.xy
            if d.length > 1e-6, let lead = leads.lead(at: cur.xy, tangent: d.normalized, out: true, within: bounds) {
                let z = cur.z
                for p in lead.dropFirst() { feed(Vec3(p, z), last.feed) }
            } else {
                unfitted += 1
            }
        }
        if cur.z < clearance - 1e-9 { rapid(Vec3(cur.xy, clearance)) }
        return (start, out, unfitted)
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
        t.restAreas = nil
        t.bores = tp.bores?.map { h in
            var m = h
            m.center = h.center + d
            return m
        }
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

    /// The stop at the start of an individual tile's file: which numbered holes its dowels go through. (No brackets:
    /// the posts write it inside a comment.)
    static func pinMessage(_ holes: [Int], tile: Int, of count: Int) -> String {
        let list = holes.count < 2 ? holes.map(String.init).joined()
            : holes.dropLast().map(String.init).joined(separator: ", ") + " and \(holes[holes.count - 1])"
        return "Tile \(tile + 1) of \(count), spindle off: fit dowels in holes \(list), see the setup sheet, "
            + "clamp the material, then resume."
    }

    /// What a registration hole may not go on, as Checks names it: the design, a part another toolpath leaves, where a
    /// toolpath cuts, or a clamp. For moving individual tiles' holes before they're drilled.
    static func registrationBlocker(_ project: Project, sources: [Source], layout: TileLayout, radius r: Double,
                                    keepOuts: [KeepOut]) -> RegistrationLayout.Blocker {
        let stock = project.stock
        let used = Set(project.operations.filter(\.enabled).flatMap(\.shapeIDs))
        let outlines = project.shapes.filter { used.contains($0.id) && !$0.isKeepOut }
            .map { s in (name: s.name, loops: s.polylines(tolerance: 0.1)) }
            .map { s in (name: s.name, loops: s.loops, bounds: s.loops.reduce(Rect2.empty) { $0.union($1.bounds) }.insetBy(-r - 1)) }
        let parts = ProtectedRegions(project, flattenTolerance: 0.05, arcTolerance: 0.02)
        let reach = Rect2(min: Vec2(-r, -r), max: Vec2(stock.width + r, stock.height + r))
        let zones = parts.zones(toolRadius: r, cut: [], walls: [], near: reach, arcTolerance: 0.02)
        // The cuts near the tile lines, where the holes go.
        let band = layout.overlap + RegistrationHoles.edgeGap + 2 * r + TileLayout.largestToolRadius(project) + 1
        func nearSeam(_ a: Vec2, _ b: Vec2) -> Bool {
            layout.seamsX.contains { x in min(a.x, b.x) < x + band && max(a.x, b.x) > x - band }
                || layout.seamsY.contains { y in min(a.y, b.y) < y + band && max(a.y, b.y) > y - band }
        }
        var cuts: [(a: Vec2, b: Vec2, reach: Double, name: String)] = []
        for s in sources {
            let tp = s.toolpath
            tp.forEachMotion { start, m in
                guard m.kind != .rapid, m.kind != .dwell, min(start.z, m.end.z) < 0, nearSeam(start.xy, m.end.xy) else { return }
                cuts.append((start.xy, m.end.xy, r + tp.tool.radius + 0.25, tp.name))
            }
        }
        return { p in
            if keepOuts.contains(where: { $0.outline.contains(p) || $0.outline.closestPoint(to: p).distance < r + 0.5 }) {
                return "a clamp or keep-out area"
            }
            guard stock.bounds.insetBy(-r).contains(p) else { return nil }
            for o in outlines where o.bounds.contains(p) {
                let inside = o.loops.contains { $0.isClosed && $0.count >= 3 && $0.contains(p) }
                if inside || o.loops.contains(where: { $0.count >= 2 && $0.closestPoint(to: p).distance < r + 0.5 }) {
                    return "the design (“\(o.name)”)"
                }
            }
            if let zone = zones.first(where: { $0.contains(p) }) { return "the part “\(zone.name)” leaves" }
            if let cut = cuts.first(where: { distancePointSegment(p, $0.a, $0.b) < $0.reach }) { return "where “\(cut.name)” cuts" }
            return nil
        }
    }

    /// Holes of `radius` to `depth` below the material top at `points`, in order (`BoreHelix.registrationHoles`).
    static func bore(_ points: [Vec2], radius: Double, depth: Double, tool: Tool, stock: Stock) -> [Motion] {
        BoreHelix.registrationHoles(points, radius: radius, depth: depth, tool: tool, stock: stock, id: registrationOperation)
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
            let numbered = reg.holes.first { $0.point.distance(to: p) < 1e-6 }
            let place = numbered.map { "Registration hole \($0.number), which tile \(tile + 1) drills at \(at(p))," }
                ?? "The registration hole tile \(tile + 1) drills at \(at(p))"
            let pinnedBy = numbered.map { $0.pinnedFor } ?? (tile + 1 < layout.count ? tile + 1 : nil)
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
                    add(.error, "\(place) is where “\(tp.name)” cuts\(pinnedBy.map { ", and a dowel stands in it while tile \($0 + 1) cuts" } ?? ""). "
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
        if reg.holes.isEmpty {
            add(.info, "Holes go \(fmt(reg.depth - stock.thickness)) into the spoilboard. After each move, drop a "
                + "\(fmt(2 * r)) dowel through each hole the last tile drilled into the spoilboard hole under it (see the setup sheet).")
        } else {
            add(.info, "Holes go \(fmt(reg.depth - stock.thickness)) into the spoilboard, two at each tile line. Before each tile "
                + "but the first, drop a \(fmt(2 * r)) dowel through each numbered hole its setup sheet page lists into the "
                + "spoilboard hole under it; each file also stops at its start to name them.")
        }
        var seen = Set<String>()
        return issues.filter { seen.insert($0.id).inserted }
    }
}
