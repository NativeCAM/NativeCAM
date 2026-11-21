import Foundation

/// Toolpaths ▸ Nest Parts: the parts in a design, how far each one's toolpaths cut outside it, and moving them where
/// `Nesting` puts them on the sheet.
///
/// A part is a closed outline and everything inside or overlapping it (an outermost shape with the holes, text and
/// other vectors drawn inside it), moved as one. An imported shape holding several separate outlines (a DXF with
/// every part on one layer) gives one part per outline. Selecting any shape of a part nests the whole part; with
/// nothing selected every part is nested. Parts not nested, clamps and keep-outs stay where they are and the nested
/// parts keep clear of them.
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

    /// The material sheet, design coordinates.
    public var sheet: Rect2
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
        let all = parts(of: project)
        let reach = reach(of: toolpaths, in: project)
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
        let keepOuts = project.shapes.filter(\.isKeepOut).flatMap { s in
            s.polylines(tolerance: 0.05).filter { $0.isClosed && $0.count >= 3 }
        }
        // The largest bit cutting the nested parts out: outside or on-the-line profiles, else any toolpath on them.
        let nestedShapes = Set(nest.flatMap(\.shapeIDs))
        let ops = project.operations.filter { !Set($0.shapeIDs).isDisjoint(with: nestedShapes) }
        let profiles = ops.filter { if case let .profile(p) = $0.kind { p.side != .inside } else { false } }
        let cutOut = (profiles.isEmpty ? ops : profiles).map(\.tool).max { $0.diameter < $1.diameter }
        let spacing = (cutOut?.diameter ?? 0.25.inch) + spacingMargin(project.displayUnits)
        return NestJob(sheet: sheet, parts: nest, fixed: fixed, keepOuts: keepOuts, notes: notes, cutOutTool: cutOut,
                       defaultSpacing: spacing)
    }

    /// Settings to start with: the default spacing, the same edge margin, quarter turns.
    public var defaultSettings: Nesting.Settings {
        Nesting.Settings(spacing: defaultSpacing, edgeMargin: defaultSpacing, rotation: .quarterTurns)
    }

    /// The parts as the nesting engine takes them.
    public var nestingParts: [Nesting.Part] { parts.map { Nesting.Part(outlines: $0.outlines, reach: $0.reach) } }

    /// What the parts keep clear of: parts that stay put (open vectors as thin strips), clamps and keep-outs.
    public var obstacles: [Nesting.Obstacle] {
        fixed.map { part in
            let outline = part.isClosed ? part.outlines
                : Clipper.offset(part.openLines, delta: 0.01, join: .round, end: .round)
            return Nesting.Obstacle(outlines: outline, reach: part.reach)
        } + keepOuts.map { Nesting.Obstacle(outlines: [$0]) }
    }

    /// Checks a layout with the parts' exact outlines before anything moves (`Nesting.violations`): empty when every
    /// part keeps its gaps, the edge margin and its distance from what stays put.
    public func check(_ result: Nesting.Result, settings: Nesting.Settings) -> [String] {
        Nesting.violations(nestingParts, placements: result.placements, sheet: sheet, obstacles: obstacles, settings: settings)
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
    }

    /// Where each part goes: placed parts where the layout puts them; a part that didn't fit stays where it is, unless
    /// that's now too close to a nested part (it would be cut into), when it goes beside the sheet, past its right
    /// edge.
    public func motions(for result: Nesting.Result, settings: Nesting.Settings) -> (motions: [RigidMotion?], aside: Set<Int>) {
        var motions = [RigidMotion?](repeating: nil, count: parts.count)
        var placedOutlines: [(outlines: [Polyline], reach: Double)] = []
        for (i, placement) in result.placements.enumerated() {
            guard let p = placement else { continue }
            motions[i] = RigidMotion(pivot: p.pivot, rotation: p.rotation, position: p.position)
            placedOutlines.append((parts[i].outlines.map(p.apply), parts[i].reach))
        }
        let aside = Set(result.unplaced.filter { i in
            let part = parts[i]
            return placedOutlines.contains { placed in
                let gap = Nesting.gap(settings, part.reach, placed.reach)
                guard part.bounds.insetBy(-gap).intersects(placed.outlines.bounds) else { return false }
                let grown = Clipper.offset(part.outlines, delta: gap)
                return Clipper.intersection(grown, placed.outlines).contains { abs($0.signedArea) > 1e-6 }
            }
        })
        // In columns past the sheet's right edge (and anything else that stays put there), a new column when one runs
        // past the top.
        let staying = result.unplaced.filter { !aside.contains($0) }.map { parts[$0].bounds } + fixed.map(\.bounds)
        var x = staying.reduce(sheet.max.x) { $1.isEmpty ? $0 : max($0, $1.max.x) }
        var y = sheet.min.y, columnWidth = 0.0
        for i in aside.sorted() {
            let part = parts[i]
            let b = part.bounds
            let gap = Nesting.gap(settings, part.reach, part.reach)
            if y > sheet.min.y && y + b.height > sheet.max.y {
                x += columnWidth + gap
                y = sheet.min.y
                columnWidth = 0
            }
            let target = Vec2(x + gap + b.width / 2, y + b.height / 2)
            motions[i] = RigidMotion(pivot: b.center, rotation: 0, position: target)
            y += b.height + gap
            columnWidth = max(columnWidth, b.width + gap)
        }
        return (motions, aside)
    }

    /// The project with the parts moved as the layout says (one change, so a single Undo puts them back). Toolpaths
    /// follow their shapes when they're generated again.
    public func apply(_ result: Nesting.Result, to project: Project, settings: Nesting.Settings) -> Applied {
        let (motions, aside) = motions(for: result, settings: settings)
        var p = project
        // A whole shape moves as one; an imported shape split between parts moves each part's vectors within it.
        var owners: [UUID: Set<Int>] = [:]
        for (i, part) in (parts + fixed).enumerated() {
            for piece in part.pieces { owners[piece.shapeID, default: []].insert(i) }
        }
        var whole: [UUID: RigidMotion] = [:]
        var split: [UUID: [(paths: Set<Int>, motion: RigidMotion)]] = [:]
        for (i, part) in parts.enumerated() {
            guard let m = motions[i], !m.isIdentity else { continue }
            for piece in part.pieces {
                if let paths = piece.paths, owners[piece.shapeID]?.count ?? 0 > 1 {
                    split[piece.shapeID, default: []].append((Set(paths), m))
                } else {
                    whole[piece.shapeID] = m
                }
            }
        }
        for i in p.shapes.indices {
            let id = p.shapes[i].id
            if let m = whole[id] {
                p.shapes[i] = p.shapes[i].moved(m)
            } else if let moves = split[id] {
                let before = p.shapes[i]
                for move in moves { p.shapes[i] = p.shapes[i].movingPaths(move.paths, by: move.motion) }
                p.operations = Self.movingCornerChoices(p.operations, shape: before, moves: moves)
            }
        }
        let left = result.unplaced.filter { !aside.contains($0) }.map { parts[$0].name }
        return Applied(project: p, movedAside: aside.sorted().map { parts[$0].name }, leftInPlace: left)
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

    /// Every part in the design (keep-outs aside), nested or not.
    public static func parts(of project: Project) -> [Part] {
        struct Raw {
            var piece: Piece
            var name: String
            var fills: [Polyline]
            var open: [Polyline]
            var bounds: Rect2
            var area: Double
            /// Open vectors that aren't entirely inside the piece's outlines.
            var strayLines: [Polyline]
        }
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
                raws.append(Raw(piece: Piece(shapeID: shape.id, paths: groups.count > 1 ? group : nil), name: name,
                                fills: fills, open: fills.isEmpty ? openLines : [], bounds: members.bounds,
                                area: fills.reduce(0) { $0 + $1.area }, strayLines: stray))
            }
        }
        // Pieces whose outlines overlap (or with open vectors over an outline) are one part.
        var parent = Array(raws.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func touches(_ a: Raw, _ b: Raw) -> Bool {
            guard a.bounds.insetBy(-1e-6).intersects(b.bounds) else { return false }
            if !a.fills.isEmpty && !b.fills.isEmpty {
                return Clipper.intersection(a.fills, b.fills).contains { abs($0.signedArea) > 1e-4 }
            }
            let (lines, fills) = a.fills.isEmpty ? (a.open, b.fills) : (b.open, a.fills)
            guard !fills.isEmpty else { return false }
            if lines.contains(where: { $0.points.contains { p in fills.contains { $0.contains(p) } } }) { return true }
            return !Clipper.clipOpen(lines, to: fills).isEmpty
        }
        for i in raws.indices {
            for j in raws.indices where j > i && root(i) != root(j) && touches(raws[i], raws[j]) {
                parent[root(j)] = root(i)
            }
        }
        var members: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in raws.indices {
            let r = root(i)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(i)
        }
        return order.enumerated().map { n, r in
            let group = members[r]!
            let fills = group.flatMap { raws[$0].fills }
            // Open vectors reaching outside the outlines (a line drawn past a part's edge) count as part of it.
            let strips = fills.isEmpty ? [] : Clipper.offset(group.flatMap { raws[$0].strayLines }, delta: 0.01, join: .round, end: .round)
            let outlines = fills.isEmpty ? [] : Clipper.union(fills + strips).filter { $0.signedArea > 0 }
            let largest = group.max { raws[$0].area < raws[$1].area || (raws[$0].area == raws[$1].area && $0 > $1) }!
            return Part(id: n, name: raws[largest].name, pieces: group.map { raws[$0].piece }, outlines: outlines,
                        openLines: fills.isEmpty ? group.flatMap { raws[$0].open } : [],
                        area: outlines.reduce(0) { $0 + $1.area }, reach: 0, reachToolpath: nil)
        }
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
        var fields: [UUID: ShapeField] = [:]
        for tp in toolpaths {
            let opID = tp.operationID ?? tp.id
            guard let op = ops[opID] else { continue }
            let field = fields[opID] ?? ShapeField(project.shapes(for: op).filter { !$0.isKeepOut })
            fields[opID] = field
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
