import Foundation

/// Toolpaths ▸ Nest Parts: the parts in a design, how far each one's toolpaths cut outside it, and moving them where
/// `Nesting` puts them on the sheet.
///
/// A part is a closed outline and everything inside or overlapping it (an outermost shape with the holes, text and
/// other vectors drawn inside it), moved as one, except what sits in a hole its toolpaths cut free: a part nested
/// there (part in part) is a part of its own. An imported shape holding several separate outlines (a DXF with
/// every part on one layer) gives one part per outline. Selecting any shape of a part nests the whole part; with
/// nothing selected every part is nested. Parts not nested, clamps and keep-outs stay where they are and the nested
/// parts keep clear of them.
///
/// On a job of several sheets, every part on every sheet can be nested again; parts that don't fit go on the next
/// sheet, up to the limit set. A part may sit in another's hole (part in part) when the hole is cut right through and
/// everything that cuts the inner part runs before the hole is cut free: earlier in the run order, or in the same
/// profile, which cuts loops inside others first.
public struct NestJob: Sendable {
    /// One piece of a part: a whole shape, or some of an imported shape's vectors.
    public struct Piece: Hashable, Sendable {
        public var shapeID: UUID
        /// Indices into the shape's vectors (`.paths`) when the part holds only some of them; nil = the whole shape.
        public var paths: [Int]?
    }

    public struct Part: Identifiable, Sendable {
        public var id: Int
        public var name: String
        public var pieces: [Piece]
        /// Closed outer outlines, design coordinates (empty for a part made only of open vectors).
        public var outlines: [Polyline]
        /// Open vectors outside every closed outline (only for a part with no outline).
        public var openLines: [Polyline]
        public var area: Double
        /// How far its toolpaths cut outside its outline (to the cutter's edge), mm, and the toolpath that does.
        /// Lead-ins don't count: they're shortened or left off where they'd cut into another part.
        public var reach: Double
        public var reachToolpath: String?
        /// How far its profiles' lead-ins reach outside it at full size, mm, and the toolpath, when that's further than
        /// `reach`.
        public var leadReach: Double?
        public var leadToolpath: String?
        /// The sheet it's on now, from 0.
        public var sheet: Int = 0
        /// Openings in it, cut right through, that other parts may sit in (part in part), each with how far its
        /// toolpaths cut into it and which groups of parts it takes.
        public var holes: [Nesting.Hole] = []
        /// Parts cut by the same toolpaths share a group (see `Nesting.Hole.accepts`).
        public var group: Int = 0

        public var shapeIDs: [UUID] {
            var seen = Set<UUID>()
            return pieces.map(\.shapeID).filter { seen.insert($0).inserted }
        }

        public var isClosed: Bool { !outlines.isEmpty }
        public var bounds: Rect2 { outlines.isEmpty ? openLines.bounds : outlines.bounds }
    }

    public enum Refusal: Error, LocalizedError, Equatable {
        case rotary
        case nothingToNest

        public var errorDescription: String? {
            switch self {
            case .rotary: "Nesting lays parts out on a flat sheet, and this job's material is a rotary blank."
            case .nothingToNest: "There are no closed shapes to nest. Draw or import the parts' outlines first."
            }
        }
    }

    /// The first material sheet, design coordinates.
    public var sheet: Rect2
    /// The size of the job's sheets after the first, when it has any, mm.
    public var nextSheetSize: Vec2?
    /// How many sheets the job has now.
    public var sheetCount: Int
    /// The parts to nest.
    public var parts: [Part]
    /// Parts that stay where they are (not selected, made only of open vectors, or cutting across the material).
    public var fixed: [Part]
    /// Clamp and keep-out outlines.
    public var keepOuts: [Polyline]
    /// Why some selected shapes stay where they are.
    public var notes: [String]
    /// The largest bit cutting the parts out (an outside or on-the-line profile), when there is one.
    public var cutOutTool: Tool?
    /// Spacing to start with: the cut-out bit's diameter plus a margin.
    public var defaultSpacing: Double

    /// How many sheets Nest Parts (and `nativecam-cli nest`) may use until a limit is set: parts that don't fit on the
    /// sheets a job has go on new ones, up to this many (or as many as the job has, if more).
    public static let defaultSheetLimit = 10

    /// Margin added to the cut-out bit for the default spacing: 1/8 in, or 3 mm in a metric job.
    public static func spacingMargin(_ units: LengthUnit) -> Double { units == .inch ? 0.125.inch : 3 }

    /// Finds the parts, generating the toolpaths (`reachToolpaths`) for how far each one cuts outside its shapes.
    /// `selection` is the selected shapes (empty = nest every part).
    public static func prepare(_ project: Project, selection: Set<UUID>) throws(Refusal) -> NestJob {
        if project.stock.rotary != nil { throw .rotary }
        return try prepare(project, selection: selection, toolpaths: reachToolpaths(project))
    }

    /// The job's toolpaths as the reach is measured from them: every one, turned on or not (one that's off is usually
    /// cut in another run), on the whole material (tiling off) and without lead-ins, which keep clear of other parts by
    /// themselves.
    public static func reachToolpaths(_ project: Project) -> [Toolpath] {
        var p = project
        p.tiling = nil
        var ops = p.operations
        for i in ops.indices {
            ops[i].enabled = true
            guard case var .profile(q) = ops[i].kind, q.leads != nil else { continue }
            q.leads = nil
            ops[i].kind = .profile(q)
        }
        p.operations = ops
        return CAMEngine.generate(p).toolpaths
    }

    /// Finds the parts. `toolpaths` are the job's, generated where the shapes are now (`reachToolpaths`), for how far
    /// each toolpath cuts outside its shapes.
    public static func prepare(_ project: Project, selection: Set<UUID>, toolpaths: [Toolpath]) throws(Refusal) -> NestJob {
        if project.stock.rotary != nil { throw .rotary }
        let sheet = Rect2(x: 0, y: 0, width: project.stock.width, height: project.stock.height)
        // A part nested in another's hole before is a part of its own again.
        var all = separateParts(of: project, toolpaths: toolpaths)
        let reach = reach(of: toolpaths, in: project)
        measureHoles(&all, toolpaths: toolpaths, in: project)
        let selectedShapes = selection.intersection(project.shapes.map(\.id))
        var nest: [Part] = [], fixed: [Part] = [], notes: [String] = []
        let tooFar = min(sheet.width, sheet.height) / 2
        for var part in all {
            for op in project.operations where !Set(op.shapeIDs).isDisjoint(with: part.shapeIDs) {
                if let r = reach[op.id], r > part.reach {
                    part.reach = r
                    part.reachToolpath = op.name
                }
                if let r = leadReach(op), r > (part.leadReach ?? 0) {
                    part.leadReach = r
                    part.leadToolpath = op.name
                }
            }
            if let lead = part.leadReach, lead <= part.reach + 1e-6 {
                part.leadReach = nil
                part.leadToolpath = nil
            }
            let chosen = selectedShapes.isEmpty || !selectedShapes.isDisjoint(with: part.shapeIDs)
            if !chosen {
                fixed.append(part)
            } else if !part.isClosed {
                fixed.append(part)
                notes.append("“\(part.name)” is open vectors only, so it stays where it is.")
            } else if part.reach > tooFar {
                fixed.append(part)
                notes.append("“\(part.name)” stays where it is: “\(part.reachToolpath ?? "a toolpath")” cuts across the material round it.")
            } else {
                nest.append(part)
            }
        }
        if nest.isEmpty && notes.isEmpty { throw .nothingToNest }
        assignGroups(&nest, in: project)
        let keepOuts = project.shapes.filter(\.isKeepOut).flatMap { s in
            s.polylines(tolerance: 0.05).filter { $0.isClosed && $0.count >= 3 }
        }
        // The largest bit cutting the nested parts out: outside or on-the-line profiles, else any toolpath on them.
        let nestedShapes = Set(nest.flatMap(\.shapeIDs))
        let ops = project.operations.filter { !Set($0.shapeIDs).isDisjoint(with: nestedShapes) }
        let profiles = ops.filter { if case let .profile(p) = $0.kind { p.side != .inside } else { false } }
        let cutOut = (profiles.isEmpty ? ops : profiles).map(\.tool).max { $0.diameter < $1.diameter }
        let spacing = (cutOut?.diameter ?? 0.25.inch) + spacingMargin(project.displayUnits)
        let next = project.additionalSheets.first.map { Vec2($0.width, $0.height) }
        return NestJob(sheet: sheet, nextSheetSize: next, sheetCount: project.sheetCount, parts: nest, fixed: fixed,
                       keepOuts: keepOuts, notes: notes, cutOutTool: cutOut, defaultSpacing: spacing)
    }

    /// Settings to start with: the default spacing, the same edge margin, quarter turns, parts in holes, and as many
    /// sheets as the job has now (at least one).
    public var defaultSettings: Nesting.Settings {
        Nesting.Settings(spacing: defaultSpacing, edgeMargin: defaultSpacing, rotation: .quarterTurns,
                         maxSheets: sheetCount, nextSheetSize: nextSheetSize)
    }

    /// The parts as the nesting engine takes them.
    public var nestingParts: [Nesting.Part] {
        parts.map { Nesting.Part(outlines: $0.outlines, reach: $0.reach, holes: $0.holes, group: $0.group) }
    }

    /// Parts with a hole another of the parts may sit in.
    public var partsWithHoles: Int {
        let groups = Set(parts.map(\.group))
        return parts.count { $0.holes.contains { $0.accepts.map { !$0.isDisjoint(with: groups) } ?? true } }
    }

    /// Parts whose holes are all cut free before the parts that could go in them: their holes stay empty.
    public var partsWithClosedHoles: [Part] {
        let groups = Set(parts.map(\.group))
        return parts.filter { !$0.holes.isEmpty && !$0.holes.contains { $0.accepts.map { !$0.isDisjoint(with: groups) } ?? true } }
    }

    /// What the parts keep clear of: parts that stay put (open vectors as thin strips) on their sheets, and clamps and
    /// keep-outs on every sheet.
    public var obstacles: [Nesting.Obstacle] {
        fixed.map { part in
            let outline = part.isClosed ? part.outlines
                : Clipper.offset(part.openLines, delta: 0.01, join: .round, end: .round)
            return Nesting.Obstacle(outlines: outline, reach: part.reach, sheet: part.sheet)
        } + keepOuts.map { Nesting.Obstacle(outlines: [$0]) }
    }

    /// Checks a layout with the parts' exact outlines before anything moves (`Nesting.violations`): empty when every
    /// part keeps its gaps, the edge margin and its distance from what stays put.
    public func check(_ result: Nesting.Result, settings: Nesting.Settings) -> [String] {
        Nesting.violations(nestingParts, placements: result.placements, sheet: sheet, obstacles: obstacles, settings: settings)
    }

    // MARK: Holes (part in part)

    /// Finds each closed part's holes: openings inside its outlines (with nothing of the part inside them) that its
    /// toolpaths cut free, right through the material and all the way round from the inside (`holeCut`). Each gets
    /// how far those toolpaths reach into it from its edge (the cutter's edge), and the run-order position of the first
    /// toolpath that frees it, the hole's cut or the part's cut-out (`freedAt`).
    static func measureHoles(_ parts: inout [Part], toolpaths: [Toolpath], in project: Project) {
        let thickness = project.stock.thickness
        let index = Dictionary(project.operations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in parts.indices where parts[p].isClosed {
            let part = parts[p]
            let candidates = holeLoops(part, in: project)
            guard !candidates.isEmpty else { continue }
            let shapeIDs = Set(part.shapeIDs)
            let opIDs = Set(project.operations.filter { !Set($0.shapeIDs).isDisjoint(with: shapeIDs) }.map(\.id))
            let mine = toolpaths.filter { opIDs.contains($0.sourceOperationID) && ($0.sheet ?? 0) == part.sheet }
            // Toolpaths on the part that cut right through somewhere: the cut-out frees everything inside it.
            let through = Set(mine.filter { tp in tp.cuttingExtents.map { $0.min.z <= -thickness + 0.05 } ?? false }
                .map(\.sourceOperationID))
            var holes: [Nesting.Hole] = []
            for loop in candidates {
                let cut = holeCut(loop, toolpaths: mine, thickness: thickness)
                guard cut.freed else { continue }
                // Freed by whatever cuts into it or cuts the part out: the first of those in the run order.
                guard let first = cut.operations.union(through).compactMap({ index[$0] }).min() else { continue }
                var hole = Nesting.Hole(outline: loop, reach: cut.reach)
                hole.freedAt = first
                if case .profile = project.operations[first].kind { hole.freedByProfile = true }
                holes.append(hole)
            }
            parts[p].holes = holes
        }
    }

    /// The loops inside a part's outlines that its closed vectors, filled even-odd as a profile reads them, leave
    /// open, with none of the part inside them: its holes.
    static func holeLoops(_ part: Part, in project: Project) -> [Polyline] {
        var closed: [Polyline] = []
        for piece in part.pieces {
            guard let shape = project.shape(id: piece.shapeID) else { continue }
            let all = shape.polylines(tolerance: 0.05)
            let lines = piece.paths.map { $0.filter { $0 < all.count }.map { all[$0] } } ?? all
            closed += lines.filter { $0.isClosed && $0.count >= 3 && $0.area > 1e-6 }
        }
        let regions = Region.build(from: closed, fill: .evenOdd)
        let holes = regions.flatMap(\.holes).map { $0.oriented(counterClockwise: true) }
        // A hole with some of the part inside it (an island) isn't free to use.
        return holes.filter { hole in
            !regions.contains { island in
                guard island.outer.area < hole.area, let probe = island.outer.interiorPoint() else { return false }
                return hole.bounds.contains(probe) && hole.contains(probe)
            }
        }
    }

    /// What `toolpaths` do to a hole: how far they cut into it from its edge (to the cutter's edge, mm; 0 when they
    /// don't reach it), the operations that do, and whether they cut it free. Free means a cutter running inside it,
    /// along its edge, reaches every part of the edge (all but a few corners a round bit can't) and cuts right through
    /// the material along nearly all of it (tabs aside). A loop cut from outside (a part drawn inside another), drilled
    /// or only engraved is no hole.
    static func holeCut(_ hole: Polyline, toolpaths: [Toolpath], thickness: Double)
        -> (reach: Double, freed: Bool, operations: Set<UUID>) {
        var reach = 0.0
        var ops = Set<UUID>()
        // Cutter centres inside the hole, about a radius in from its edge: a cut along the edge from inside.
        struct Edge { var at: Vec2; var radius: Double; var through: Bool }
        var edge: [Edge] = []
        let box = hole.bounds
        for tp in toolpaths {
            let r = tp.tool.radius
            let near = box.insetBy(-r - 0.01)
            var hit = false
            func visit(_ q: Vec3) {
                guard q.z < -0.01, near.contains(q.xy) else { return }
                let d = hole.closestPoint(to: q.xy).distance
                let inside = hole.contains(q.xy)
                let into = (inside ? d : -d) + r
                guard into > 1e-6 else { return }
                reach = max(reach, into)
                hit = true
                if inside && d >= 0.5 * r - 0.01 && d <= r + 0.5 {
                    edge.append(Edge(at: q.xy, radius: r, through: q.z <= -thickness + 0.05))
                }
            }
            var pos = tp.start
            for m in tp.motions {
                defer { pos = m.end }
                switch m.kind {
                case .rapid, .dwell:
                    continue
                case .arcCW, .arcCCW:
                    for q in m.samples(from: pos, maxStep: 0.5) { visit(q) }
                case .feed:
                    // Only the part of the move near the hole needs the fine steps.
                    guard Rect2(min: Vec2(min(pos.x, m.end.x), min(pos.y, m.end.y)), max: Vec2(max(pos.x, m.end.x), max(pos.y, m.end.y))).intersects(near) else { continue }
                    let n = max(1, Int((pos.distance(to: m.end) / 0.5).rounded(.up)))
                    for k in 1...n { visit(pos.lerp(to: m.end, Double(k) / Double(n))) }
                }
            }
            if hit { ops.insert(tp.sourceOperationID) }
        }
        guard !edge.isEmpty else { return (reach, false, ops) }
        // Points round the hole's edge, every 2 mm (at least 24).
        let perimeter = hole.length
        let count = max(24, min(4000, Int((perimeter / 2).rounded(.up))))
        let samples = (0..<count).map { hole.point(atDistance: perimeter * Double($0) / Double(count)) }
        // A grid of the edge cuts, for finding those near each point.
        let cell = max(0.5, (edge.map(\.radius).max() ?? 1) * 1.5 + 0.1)
        struct Key: Hashable { var x: Int; var y: Int }
        func key(_ p: Vec2) -> Key { Key(x: Int((p.x / cell).rounded(.down)), y: Int((p.y / cell).rounded(.down))) }
        var grid: [Key: [Int]] = [:]
        for (i, e) in edge.enumerated() { grid[key(e.at), default: []].append(i) }
        var reached = 0, cutThrough = 0
        for s in samples {
            let k = key(s)
            var any = false, through = false
            for dx in -1...1 {
                for dy in -1...1 {
                    for i in grid[Key(x: k.x + dx, y: k.y + dy)] ?? [] where edge[i].at.distance(to: s) <= edge[i].radius * 1.5 + 0.1 {
                        any = true
                        if edge[i].through { through = true }
                    }
                }
            }
            if any { reached += 1 }
            if through { cutThrough += 1 }
        }
        let freed = Double(reached) >= 0.95 * Double(count) && Double(cutThrough) >= 0.8 * Double(count)
        return (reach, freed, ops)
    }

    /// Groups the parts by the toolpaths that cut them, and says which groups each hole takes: those whose every
    /// toolpath runs before the hole is freed, or is the profile that frees it (it cuts the loops inside first).
    static func assignGroups(_ parts: inout [Part], in project: Project) {
        let index = Dictionary(project.operations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groupOf: [[Int]: Int] = [:]
        var members: [[Int]] = []
        for p in parts.indices {
            let ids = Set(parts[p].shapeIDs)
            let ops = project.operations.filter { !Set($0.shapeIDs).isDisjoint(with: ids) }.compactMap { index[$0.id] }.sorted()
            if let g = groupOf[ops] {
                parts[p].group = g
            } else {
                groupOf[ops] = members.count
                parts[p].group = members.count
                members.append(ops)
            }
        }
        for p in parts.indices {
            for h in parts[p].holes.indices {
                let hole = parts[p].holes[h]
                guard let freed = hole.freedAt else { continue }
                parts[p].holes[h].accepts = Set(members.indices.filter { g in
                    members[g].allSatisfy { $0 < freed || ($0 == freed && hole.freedByProfile) }
                })
            }
        }
    }

    /// Nests the parts.
    public func nest(_ settings: Nesting.Settings, progress: (@Sendable (Nesting.Result) -> Void)? = nil,
                     shouldStop: @escaping @Sendable () -> Bool = { false }) -> Nesting.Result {
        Nesting.nest(nestingParts, sheet: sheet, obstacles: obstacles, settings: settings, progress: progress,
                     shouldStop: shouldStop)
    }

    // MARK: Applying a layout

    public struct Applied: Sendable {
        public var project: Project
        /// Parts that didn't fit and now overlap the nested ones where they were, so they were put beside the sheet.
        public var movedAside: [String]
        /// Parts that didn't fit and stay where they were.
        public var leftInPlace: [String]
        /// Sheets the job has now.
        public var sheetCount: Int = 1
        /// Parts put in another part's hole.
        public var inHoles: [String] = []
    }

    /// Where each part goes: placed parts where the layout puts them, on the sheet it says; a part that didn't fit
    /// stays where it is on its sheet, unless that's now too close to a nested part there (it would be cut into), when
    /// it goes beside the sheet, past its right edge.
    public func motions(for result: Nesting.Result, settings: Nesting.Settings) -> (motions: [RigidMotion?], aside: Set<Int>) {
        var motions = [RigidMotion?](repeating: nil, count: parts.count)
        var placedOutlines: [(outlines: [Polyline], reach: Double, sheet: Int)] = []
        for (i, placement) in result.placements.enumerated() {
            guard let p = placement else { continue }
            motions[i] = RigidMotion(pivot: p.pivot, rotation: p.rotation, position: p.position)
            placedOutlines.append((parts[i].outlines.map(p.apply), parts[i].reach, p.sheet))
        }
        let aside = Set(result.unplaced.filter { i in
            let part = parts[i]
            return placedOutlines.contains { placed in
                guard placed.sheet == part.sheet else { return false }
                let gap = Nesting.gap(settings, part.reach, placed.reach)
                guard part.bounds.insetBy(-gap).intersects(placed.outlines.bounds) else { return false }
                let grown = Clipper.offset(part.outlines, delta: gap)
                return Clipper.intersection(grown, placed.outlines).contains { abs($0.signedArea) > 1e-6 }
            }
        })
        // In columns past the sheet's right edge (and anything else that stays put there), a new column when one runs
        // past the top: each sheet's own.
        for k in Set(aside.map { parts[$0].sheet }).sorted() {
            let sheetRect = settings.sheet(k, first: sheet)
            let staying = result.unplaced.filter { !aside.contains($0) && parts[$0].sheet == k }.map { parts[$0].bounds }
                + fixed.filter { $0.sheet == k }.map(\.bounds)
            var x = staying.reduce(sheetRect.max.x) { $1.isEmpty ? $0 : max($0, $1.max.x) }
            var y = sheetRect.min.y, columnWidth = 0.0
            for i in aside.sorted() where parts[i].sheet == k {
                let part = parts[i]
                let b = part.bounds
                let gap = Nesting.gap(settings, part.reach, part.reach)
                if y > sheetRect.min.y && y + b.height > sheetRect.max.y {
                    x += columnWidth + gap
                    y = sheetRect.min.y
                    columnWidth = 0
                }
                let target = Vec2(x + gap + b.width / 2, y + b.height / 2)
                motions[i] = RigidMotion(pivot: b.center, rotation: 0, position: target)
                y += b.height + gap
                columnWidth = max(columnWidth, b.width + gap)
            }
        }
        return (motions, aside)
    }

    /// The project with the parts moved as the layout says, each onto its sheet (one change, so a single Undo puts
    /// them back). Toolpaths follow their shapes when they're generated again. The job gets the sheets the layout uses
    /// (and keeps any a part that stays put is on), sized as the settings say; empty sheets at the end go.
    public func apply(_ result: Nesting.Result, to project: Project, settings: Nesting.Settings) -> Applied {
        let (motions, aside) = motions(for: result, settings: settings)
        var p = project
        // The sheet each part ends up on.
        let target = parts.indices.map { result.placements[$0]?.sheet ?? parts[$0].sheet }
        // A whole shape moves as one; an imported shape split between parts moves each part's vectors within it.
        var owners: [UUID: Set<Int>] = [:]
        for (i, part) in (parts + fixed).enumerated() {
            for piece in part.pieces { owners[piece.shapeID, default: []].insert(i) }
        }
        var whole: [UUID: RigidMotion] = [:]
        var wholeSheet: [UUID: Int] = [:]
        var split: [UUID: [(paths: Set<Int>, motion: RigidMotion)]] = [:]
        // Vectors of a split shape and the sheet they end up on.
        var splitSheets: [UUID: [(paths: Set<Int>, sheet: Int)]] = [:]
        for (i, part) in parts.enumerated() {
            let m = motions[i]
            for piece in part.pieces {
                if let paths = piece.paths, owners[piece.shapeID]?.count ?? 0 > 1 {
                    if let m, !m.isIdentity { split[piece.shapeID, default: []].append((Set(paths), m)) }
                    splitSheets[piece.shapeID, default: []].append((Set(paths), target[i]))
                } else {
                    if let m, !m.isIdentity { whole[piece.shapeID] = m }
                    wholeSheet[piece.shapeID] = target[i]
                }
            }
        }
        // Vectors of a split shape that stay put stay on their sheet.
        for part in fixed {
            for piece in part.pieces where splitSheets[piece.shapeID] != nil {
                if let paths = piece.paths { splitSheets[piece.shapeID, default: []].append((Set(paths), part.sheet)) }
            }
        }
        var added: [(after: UUID, shape: DesignShape)] = []
        for i in p.shapes.indices {
            let id = p.shapes[i].id
            if let m = whole[id] { p.shapes[i] = p.shapes[i].moved(m) }
            if let k = wholeSheet[id] { p.shapes[i].sheet = k > 0 ? k : nil }
            if let moves = split[id] {
                let before = p.shapes[i]
                for move in moves { p.shapes[i] = p.shapes[i].movingPaths(move.paths, by: move.motion) }
                p.operations = Self.movingCornerChoices(p.operations, shape: before, moves: moves)
            }
            if let pieces = splitSheets[id] {
                // The shape goes where most of its vectors go (where it is, on a tie); vectors bound for other sheets
                // become shapes of their own there.
                let now = project.sheetIndex(of: project.shapes[i])
                let counts = Dictionary(grouping: pieces, by: \.sheet).mapValues { $0.reduce(0) { $0 + $1.paths.count } }
                let home = counts.max { $0.value < $1.value || ($0.value == $1.value && ($0.key == now || ($1.key != now && $0.key > $1.key))) }?.key ?? now
                p.shapes[i].sheet = home > 0 ? home : nil
                let away = Dictionary(grouping: pieces.filter { $0.sheet != home }, by: \.sheet)
                for (k, group) in away.sorted(by: { $0.key < $1.key }) {
                    let indices = group.reduce(Set<Int>()) { $0.union($1.paths) }
                    guard let (kept, moved) = Self.splitting(p.shapes[i], paths: indices) else { continue }
                    p.operations = Self.sharing(p.operations, shape: id, with: moved.id, paths: indices, original: p.shapes[i])
                    p.shapes[i] = kept
                    var m = moved
                    m.sheet = k > 0 ? k : nil
                    added.append((id, m))
                }
            }
        }
        for (after, shape) in added.reversed() {
            let at = (p.shapes.firstIndex { $0.id == after } ?? p.shapes.count - 1) + 1
            p.shapes.insert(shape, at: at)
        }
        // Sheets: those the parts now use (and any a part that stays put is on).
        let used = max(target.max() ?? 0, fixed.map(\.sheet).max() ?? 0,
                       p.shapes.filter { !$0.isKeepOut }.map { max(0, $0.sheet ?? 0) }.max() ?? 0)
        let size = settings.nextSheetSize ?? Vec2(project.stock.width, project.stock.height)
        let nested = result.sheetCount
        p.additionalSheets = (1..<max(1, used + 1)).map { k in
            k < nested || k > project.additionalSheets.count ? MaterialSheet(width: size.x, height: size.y) : project.additionalSheets[k - 1]
        }
        // Parts on a sheet past the last (they had no place on the sheets they were on) stay on the last.
        p.removeEmptySheets()
        let left = result.unplaced.filter { !aside.contains($0) }.map { parts[$0].name }
        return Applied(project: p, movedAside: aside.sorted().map { parts[$0].name }, leftInPlace: left,
                       sheetCount: p.sheetCount, inHoles: result.inHoles.map { parts[$0].name })
    }

    /// An imported shape split in two: the vectors at `paths` as a new shape (same place, layer and settings, its own
    /// ID), and the rest. nil when that would leave either one empty, or the shape isn't imported vectors.
    static func splitting(_ shape: DesignShape, paths: Set<Int>) -> (kept: DesignShape, moved: DesignShape)? {
        guard case let .paths(all) = shape.kind else { return nil }
        let moving = all.indices.filter { paths.contains($0) }, staying = all.indices.filter { !paths.contains($0) }
        guard !moving.isEmpty, !staying.isEmpty else { return nil }
        var kept = shape, moved = shape
        kept.kind = .paths(staying.map { all[$0] })
        moved.id = UUID()
        moved.kind = .paths(moving.map { all[$0] })
        return (kept, moved)
    }

    /// Every operation on `shape` also cuts `newShape` (the vectors split from it), right after it; corner choices on
    /// those vectors go with them.
    static func sharing(_ operations: [CAMOperation], shape: UUID, with newShape: UUID, paths: Set<Int>,
                        original: DesignShape) -> [CAMOperation] {
        guard case let .paths(all) = original.kind else { return operations }
        func moved(_ settings: CornerReliefSettings?) -> CornerReliefSettings? {
            guard var s = settings, let overrides = s.overrides else { return settings }
            s.overrides = overrides.map { o in
                guard o.shapeID == shape else { return o }
                let near = paths.contains { i in i < all.count && all[i].closestPoint(to: o.point).distance < 1e-3 }
                guard near else { return o }
                var c = o
                c.shapeID = newShape
                return c
            }
            return s
        }
        return operations.map { op in
            guard let at = op.shapeIDs.firstIndex(of: shape) else { return op }
            var op = op
            op.shapeIDs.insert(newShape, at: at + 1)
            switch op.kind {
            case var .profile(q):
                q.cornerRelief = moved(q.cornerRelief)
                op.kind = .profile(q)
            case var .pocket(q):
                q.cornerRelief = moved(q.cornerRelief)
                op.kind = .pocket(q)
            default:
                break
            }
            return op
        }
    }

    /// Corner choices are kept in a shape's own coordinates; for an imported shape whose vectors moved within it, the
    /// choices on the moved vectors move with them.
    static func movingCornerChoices(_ operations: [CAMOperation], shape: DesignShape,
                                    moves: [(paths: Set<Int>, motion: RigidMotion)]) -> [CAMOperation] {
        guard case let .paths(paths) = shape.kind else { return operations }
        func moved(_ settings: CornerReliefSettings?) -> CornerReliefSettings? {
            guard var s = settings, let overrides = s.overrides else { return settings }
            s.overrides = overrides.map { o in
                guard o.shapeID == shape.id else { return o }
                for move in moves {
                    let near = move.paths.contains { i in i < paths.count && paths[i].closestPoint(to: o.point).distance < 1e-3 }
                    if near, let local = shape.localMotion(move.motion) {
                        var c = o
                        c.point = local.apply(o.point)
                        return c
                    }
                }
                return o
            }
            return s
        }
        return operations.map { op in
            guard op.shapeIDs.contains(shape.id) else { return op }
            var op = op
            switch op.kind {
            case var .profile(q):
                q.cornerRelief = moved(q.cornerRelief)
                op.kind = .profile(q)
            case var .pocket(q):
                q.cornerRelief = moved(q.cornerRelief)
                op.kind = .pocket(q)
            default:
                break
            }
            return op
        }
    }

    // MARK: Finding the parts

    /// One piece of the design as the parts are found: a whole shape, or one outline of an imported shape with the
    /// vectors inside it.
    struct Raw {
        var piece: Piece
        var sheet: Int
        var name: String
        /// Its closed vectors.
        var closed: [Polyline]
        /// Its outer outlines, filled (holes and all).
        var fills: [Polyline]
        var open: [Polyline]
        var bounds: Rect2
        var area: Double
        /// Open vectors that aren't entirely inside the piece's outlines.
        var strayLines: [Polyline]
    }

    /// Every part in the design (keep-outs aside), nested or not, by the shapes alone: a part sitting in another's hole
    /// is part of it here (see `separateParts(of:toolpaths:)`).
    public static func parts(of project: Project) -> [Part] {
        let raws = raws(of: project)
        return groups(raws, among: Array(raws.indices)).enumerated().map { part($1, id: $0, raws) }
    }

    /// Every part in the design (keep-outs aside), nested or not, with a part sitting in another part's hole (as
    /// nesting puts it there, part in part) a part of its own: the pieces lying inside a hole of the rest that
    /// `toolpaths` cut free (`holeCut`) are parts apart from it, so each can be nested on its own. Pieces inside a loop
    /// that isn't cut right through from inside (a pocket's or an engraved ring's) stay with their part. Toolpaths cut in
    /// the order they did: which part a piece belongs to doesn't change the run order.
    public static func separateParts(of project: Project, toolpaths: [Toolpath]) -> [Part] {
        let raws = raws(of: project)
        guard !toolpaths.isEmpty else { return groups(raws, among: Array(raws.indices)).enumerated().map { part($1, id: $0, raws) } }
        let thickness = project.stock.thickness
        // Whether the toolpaths on a group's shapes cut `hole` free, on the group's sheet.
        func freed(_ hole: Polyline, group: [Int]) -> Bool {
            let shapeIDs = Set(group.map { raws[$0].piece.shapeID })
            let opIDs = Set(project.operations.filter { !Set($0.shapeIDs).isDisjoint(with: shapeIDs) }.map(\.id))
            let sheet = raws[group[0]].sheet
            let mine = toolpaths.filter { opIDs.contains($0.sourceOperationID) && ($0.sheet ?? 0) == sheet }
            return holeCut(hole, toolpaths: mine, thickness: thickness).freed
        }
        // Whether a piece lies inside `hole` (and none of its own vectors is the hole).
        func inside(_ r: Raw, _ hole: Polyline) -> Bool {
            let box = hole.bounds.insetBy(1e-3)
            guard box.contains(r.bounds.min), box.contains(r.bounds.max) else { return false }
            return (r.closed + r.open).allSatisfy { line in line.points.allSatisfy { hole.contains($0) } }
        }
        func separated(_ group: [Int]) -> [[Int]] {
            guard group.count > 1 else { return [group] }
            let loops = group.flatMap { raws[$0].closed }
            let holes = Region.build(from: loops, fill: .evenOdd).flatMap(\.holes).sorted { $0.area > $1.area }
            for hole in holes {
                let within = group.filter { inside(raws[$0], hole) }
                guard !within.isEmpty, within.count < group.count, freed(hole, group: group) else { continue }
                let rest = group.filter { !within.contains($0) }
                return separated(rest) + groups(raws, among: within).flatMap(separated)
            }
            return [group]
        }
        let all = groups(raws, among: Array(raws.indices)).flatMap(separated).sorted { $0.min()! < $1.min()! }
        return all.enumerated().map { part($1, id: $0, raws) }
    }

    /// The design's pieces (keep-outs aside).
    static func raws(of project: Project) -> [Raw] {
        var raws: [Raw] = []
        for shape in project.shapes where !shape.isKeepOut {
            let lines = shape.polylines(tolerance: 0.05)
            let groups: [[Int]]
            if case .paths = shape.kind, lines.count > 1 { groups = separateOutlines(lines) } else { groups = [Array(lines.indices)] }
            for (g, group) in groups.enumerated() {
                let members = group.map { lines[$0] }
                let closed = members.filter { $0.isClosed && $0.count >= 3 && $0.area > 1e-6 }
                let fills = Region.build(from: closed, fill: .evenOdd).map(\.outer)
                let openLines = members.filter { !$0.isClosed || $0.count < 3 }
                let stray = fills.isEmpty ? [] : openLines.filter { line in
                    !line.points.allSatisfy { p in fills.contains { $0.contains(p) } }
                }
                let name = groups.count > 1 ? "\(shape.name) \(g + 1)" : shape.name
                raws.append(Raw(piece: Piece(shapeID: shape.id, paths: groups.count > 1 ? group : nil),
                                sheet: project.sheetIndex(of: shape), name: name, closed: closed,
                                fills: fills, open: fills.isEmpty ? openLines : [], bounds: members.bounds,
                                area: fills.reduce(0) { $0 + $1.area }, strayLines: stray))
            }
        }
        return raws
    }

    /// The pieces at `indices` grouped into parts: pieces whose outlines overlap (or with open vectors over an outline)
    /// are one part. Each group is in index order, the groups in the order of their first piece.
    static func groups(_ raws: [Raw], among indices: [Int]) -> [[Int]] {
        var parent = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i]! != i {
                parent[i] = parent[parent[i]!]!
                i = parent[i]!
            }
            return i
        }
        func touches(_ a: Raw, _ b: Raw) -> Bool {
            guard a.sheet == b.sheet, a.bounds.insetBy(-1e-6).intersects(b.bounds) else { return false }
            if !a.fills.isEmpty && !b.fills.isEmpty {
                return Clipper.intersection(a.fills, b.fills).contains { abs($0.signedArea) > 1e-4 }
            }
            let (lines, fills) = a.fills.isEmpty ? (a.open, b.fills) : (b.open, a.fills)
            guard !fills.isEmpty else { return false }
            if lines.contains(where: { $0.points.contains { p in fills.contains { $0.contains(p) } } }) { return true }
            return !Clipper.clipOpen(lines, to: fills).isEmpty
        }
        let sorted = indices.sorted()
        for (n, i) in sorted.enumerated() {
            for j in sorted[(n + 1)...] where root(i) != root(j) && touches(raws[i], raws[j]) {
                parent[root(j)] = root(i)
            }
        }
        var members: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in sorted {
            let r = root(i)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(i)
        }
        return order.map { members[$0]! }
    }

    /// The part made of the pieces at `group`.
    static func part(_ group: [Int], id n: Int, _ raws: [Raw]) -> Part {
        let fills = group.flatMap { raws[$0].fills }
        // Open vectors reaching outside the outlines (a line drawn past a part's edge) count as part of it.
        let strips = fills.isEmpty ? [] : Clipper.offset(group.flatMap { raws[$0].strayLines }, delta: 0.01, join: .round, end: .round)
        let outlines = fills.isEmpty ? [] : Clipper.union(fills + strips).filter { $0.signedArea > 0 }
        let largest = group.max { raws[$0].area < raws[$1].area || (raws[$0].area == raws[$1].area && $0 > $1) }!
        return Part(id: n, name: raws[largest].name, pieces: group.map { raws[$0].piece }, outlines: outlines,
                    openLines: fills.isEmpty ? group.flatMap { raws[$0].open } : [],
                    area: outlines.reduce(0) { $0 + $1.area }, reach: 0, reachToolpath: nil, sheet: raws[group[0]].sheet)
    }

    /// An imported shape's vectors grouped by outermost closed outline: each group is an outline and every vector
    /// inside it. Open vectors outside every outline are a group each.
    static func separateOutlines(_ lines: [Polyline]) -> [[Int]] {
        let closed = lines.indices.filter { lines[$0].isClosed && lines[$0].count >= 3 && lines[$0].area > 1e-6 }
            .sorted { lines[$0].area > lines[$1].area || (lines[$0].area == lines[$1].area && $0 < $1) }
        let boxes = lines.map(\.bounds)
        func inside(_ i: Int, _ outer: Int) -> Bool {
            let probe = lines[i].isClosed ? (lines[i].interiorPoint() ?? lines[i].points[0]) : lines[i].points[0]
            return boxes[outer].contains(probe, tolerance: 1e-9) && lines[outer].contains(probe)
                && lines[i].points.allSatisfy { boxes[outer].contains($0, tolerance: 1e-6) }
        }
        var owner: [Int: Int] = [:]
        var roots: [Int] = []
        for (n, i) in closed.enumerated() {
            // The smallest larger outline holding it: its outermost one is that one's owner.
            if let container = closed[..<n].reversed().first(where: { inside(i, $0) }) {
                owner[i] = owner[container] ?? container
            } else {
                roots.append(i)
            }
        }
        for i in lines.indices where owner[i] == nil && !roots.contains(i) {
            if let container = closed.reversed().first(where: { $0 != i && inside(i, $0) }) {
                owner[i] = owner[container] ?? container
            }
        }
        var groups: [Int: [Int]] = [:]
        for r in roots { groups[r] = [r] }
        var loose: [[Int]] = []
        for i in lines.indices where !roots.contains(i) {
            if let o = owner[i] { groups[o, default: [o]].append(i) } else { loose.append([i]) }
        }
        return roots.sorted().map { groups[$0]!.sorted() } + loose
    }

    // MARK: How far toolpaths reach

    /// How far an outside or on-the-line profile's full-size lead-ins reach outside its shapes (the cutter's edge),
    /// mm: the bit's width and the allowance, plus how far the lead swings out from the cut.
    public static func leadReach(_ op: CAMOperation) -> Double? {
        guard case let .profile(p) = op.kind, let lead = p.leads, p.side != .inside else { return nil }
        let swing: Double
        switch lead.kind {
        case .arc:
            let sweep = min(180, max(15, lead.sweep)).radians
            swing = lead.radius * (1 - cos(sweep))
        case .line:
            swing = lead.length * sin(min(90, max(10, lead.angle)).radians)
        }
        let cut = p.side == .on ? op.tool.diameter / 2 : op.tool.diameter + max(0, p.allowance)
        return cut + swing
    }

    /// For each operation with toolpaths: how far its cutting moves (below the material top) reach outside its own
    /// shapes, to the cutter's edge, mm. An outside profile reaches its bit's diameter (plus any lead-ins), a pocket
    /// nothing; a 3D roughing set to the whole material, across the sheet.
    public static func reach(of toolpaths: [Toolpath], in project: Project) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        let ops = Dictionary(project.operations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        struct Key: Hashable { var op: UUID; var sheet: Int }
        var fields: [Key: ShapeField] = [:]
        for tp in toolpaths {
            let opID = tp.operationID ?? tp.id
            guard let op = ops[opID] else { continue }
            // A toolpath on a sheet of a nested job is measured from the operation's shapes on that sheet.
            let key = Key(op: opID, sheet: tp.sheet ?? 0)
            let field = fields[key] ?? ShapeField(project.shapes(for: op).filter { !$0.isKeepOut && project.sheetIndex(of: $0) == key.sheet })
            fields[key] = field
            guard !field.isEmpty else { continue }
            let r = field.farthest(cuttingPointsOf: tp) + tp.tool.diameter / 2
            if r > (out[opID] ?? -1) { out[opID] = r }
        }
        return out
    }

    /// Where an operation's shapes are, for the distance from a point to the nearest of them (0 inside a closed one).
    struct ShapeField {
        var fills: [[Polyline]]
        var lines: [[Polyline]]
        var bounds: [Rect2]

        init(_ shapes: [DesignShape]) {
            fills = []
            lines = []
            bounds = []
            for s in shapes {
                let all = s.polylines(tolerance: 0.05)
                let closed = all.filter { $0.isClosed && $0.count >= 3 && $0.area > 1e-6 }
                fills.append(Region.build(from: closed, fill: .evenOdd).map(\.outer))
                lines.append(all)
                bounds.append(all.bounds)
            }
        }

        var isEmpty: Bool { bounds.allSatisfy(\.isEmpty) }

        func distance(_ p: Vec2, shape i: Int) -> Double {
            if fills[i].contains(where: { $0.contains(p) }) { return 0 }
            return lines[i].reduce(Double.infinity) { min($0, $1.closestPoint(to: p).distance) }
        }

        static func boxDistance(_ b: Rect2, _ p: Vec2) -> Double {
            let dx = max(b.min.x - p.x, 0, p.x - b.max.x), dy = max(b.min.y - p.y, 0, p.y - b.max.y)
            return (dx * dx + dy * dy).squareRoot()
        }

        /// The farthest any cutting point of `tp` (tool centre, below the material top) is from the shapes.
        func farthest(cuttingPointsOf tp: Toolpath) -> Double {
            var farthest = 0.0
            var last = 0
            var seen = Set<Int64>()
            func visit(_ q: Vec3) {
                guard q.z < -0.01 else { return }
                let key = Int64((q.x * 20).rounded()) &* 1_000_003 &+ Int64((q.y * 20).rounded())
                guard seen.insert(key).inserted else { return }
                let p = q.xy
                // The shape nearest the last point is usually nearest this one: a point no farther than the
                // farthest so far can't change it.
                var d = distance(p, shape: last)
                if d <= farthest { return }
                for i in bounds.indices where i != last && ShapeField.boxDistance(bounds[i], p) < d {
                    let di = distance(p, shape: i)
                    if di < d {
                        d = di
                        last = i
                        if d <= farthest { return }
                    }
                }
                farthest = max(farthest, d)
            }
            var pos = tp.start
            for m in tp.motions {
                defer { pos = m.end }
                switch m.kind {
                case .rapid, .dwell:
                    continue
                case .arcCW, .arcCCW:
                    for q in m.samples(from: pos, maxStep: 1) { visit(q) }
                case .feed:
                    let n = max(1, Int((pos.distance(to: m.end) / 5).rounded(.up)))
                    for k in 1...n { visit(pos.lerp(to: m.end, Double(k) / Double(n))) }
                }
            }
            return farthest
        }
    }
}
