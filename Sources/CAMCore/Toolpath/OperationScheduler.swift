import Foundation

/// Reorders operations to minimize tool changes without breaking machining dependencies.
///
/// On a manual-change machine every tool change is a stop for a collet swap and a touch-off, minutes that dwarf any
/// air-time saving, so the fewest changes win and the user's order breaks ties. An operation stays after:
/// - everything inside the outline it cuts through (parts are cut free last, never finished while held by tabs; a
///   chamfer, flute, prism or edge profile on the outline itself counts as inside it). An edge profile that stays above
///   the tabs a cut-out leaves may run after it, the tabs still holding the part, so there the user's order stands,
///   and a new one is put before the cut-out,
/// - 3D roughing of the same model (when it's the finish; 3D rotary roughing before 3D rotary finishing),
/// - the toolpaths a rest toolpath rests on (`RestMachining.dependencies`), and
/// - any earlier operation whose area overlaps its own (the user's order may carry intent there).
/// Disabled operations aren't machined, so they keep their place next to the operation they followed.
///
/// An operation with a clearance tool (a rest-machined pocket, a V-carve's flat clearing) cuts with two tools, the
/// clearance tool first. Operations next to each other in the run order that share a clearance tool cut as one block:
/// all their clearing, then each its own tool in order (`blocks`). Several pockets cleared with the same 1/2" bit and
/// finished with the same 1/8" one change tools once each way, and a block never needs more changes than cutting
/// its operations one by one. The search counts changes the same way, so it can bring such operations together.
public enum OperationScheduler {
    public struct Result: Sendable, Equatable {
        public var order: [UUID]
        public var toolChangesBefore: Int
        public var toolChangesAfter: Int
        /// Operations the current order runs too late: after the cut that frees their part (`freedBy`) or, for a
        /// 3D finish, before its roughing.
        public var outOfOrder: [Late]
        public var changed: Bool { toolChangesAfter < toolChangesBefore || !outOfOrder.isEmpty }

        public struct Late: Sendable, Equatable {
            public var operation: UUID
            /// The operation it has to come before.
            public var mustPrecede: UUID
        }
    }

    /// Exact search is used up to this many enabled operations; beyond it a greedy same-tool-first pass.
    static let exactLimit = 18

    public static func optimize(_ project: Project) -> Result {
        let ops = project.operations
        let enabled = ops.indices.filter { ops[$0].enabled }
        let m = enabled.count
        let thickness = project.stock.thickness
        // Per-shape boxes grown by the tool radius (the area the operation can touch), on the shape's sheet: boxes on
        // different sheets of a nested job never meet.
        func areas(_ op: CAMOperation, grow: Double) -> [Area] {
            project.shapes(for: op).compactMap { shape in
                let b = shape.bounds
                return b.isEmpty ? nil : Area(sheet: project.sheetIndex(of: shape), rect: b.insetBy(-grow))
            }
        }
        let boxes: [[Area]] = enabled.map { areas(ops[$0], grow: ops[$0].tool.radius) }
        // The part an operation works on, for whether a cut-out frees it: its area, but a chamfer, flute or prism
        // shapes the part drawn, however wide its V-bit (a chamfer on a part's outline comes before its cut-out).
        let parts: [[Area]] = enabled.indices.map { k in
            let op = ops[enabled[k]]
            return op.kind.followsVectors ? areas(op, grow: 0) : boxes[k]
        }
        // On rotary stock a profile to the full thickness only reaches the axis, and the blank stays in the chuck.
        let flat = project.stock.rotary == nil
        // Anything that reaches the material's bottom frees what it cuts round: a profile, a pocket's islands, and a 3D
        // toolpath cutting round its model down to its base there. A 3D toolpath a tabbed cut-out holds stops above the
        // tabs (`PartHold`), so it frees nothing; one that can't be held is an error in the checks, and is kept after
        // what it would free here too.
        func cutsThrough(_ op: CAMOperation) -> Bool {
            guard flat else { return false }
            switch op.kind {
            case let .profile(p): return p.depth.cutDepth >= thickness - 0.01
            case let .pocket(p): return p.depth.cutDepth >= thickness - 0.01
            case .rough3D, .finish3D:
                guard PartHold.reachesBottom(op, in: project) else { return false }
                return PartHold.hold(for: op, in: project)?.possible != true
            default: return false
            }
        }
        /// An edge profile on a part a cut-out leaves on tabs, clear of them: the tabs still hold the part after the
        /// cut-out, so the edge profile may run on either side of it (the user's order stands).
        func heldByTabs(_ edge: CAMOperation, _ cutOut: CAMOperation) -> Bool {
            guard case let .edgeProfile(e) = edge.kind else { return false }
            return Self.clearsTabs(e.depth(for: edge.tool), of: cutOut, in: project)
        }
        func inside(_ inner: [Area], _ outer: [Area]) -> Bool {
            !inner.isEmpty && inner.allSatisfy { r in
                outer.contains { $0.sheet == r.sheet && $0.rect.contains(r.rect.min, tolerance: 1e-6) && $0.rect.contains(r.rect.max, tolerance: 1e-6) }
            }
        }
        func overlaps(_ a: [Area], _ b: [Area]) -> Bool {
            a.contains { r in b.contains { $0.sheet == r.sheet && $0.rect.intersects(r.rect) } }
        }
        /// A 3D roughing (flat or rotary) that has to come before a finish of the same model.
        func roughs(_ a: CAMOperation, before b: CAMOperation) -> Bool {
            guard !Set(a.shapeIDs).isDisjoint(with: b.shapeIDs) else { return false }
            switch (a.kind, b.kind) {
            case (.rough3D, .finish3D), (.rotaryRough, .rotaryFinish): return true
            default: return false
            }
        }
        // What each rest toolpath rests on (`RestMachining.dependencies`).
        let restsOn: [Set<UUID>] = enabled.map { Set(RestMachining.dependencies(of: ops[$0], in: project)) }
        // before[j]: bit mask of the operations that must come before j (indices into `enabled`).
        // Hard rules first (machining dependencies), then the user's order wherever areas overlap.
        var before = [UInt64](repeating: 0, count: m)
        var late: [Result.Late] = []
        for j in 0..<m {
            for i in 0..<m where i != j {
                let a = ops[enabled[i]], b = ops[enabled[j]]
                let aFreesB = cutsThrough(a) && inside(parts[j], boxes[i]) && !heldByTabs(b, a)
                // Each frees the other (a 3D toolpath to the bottom round a part and the part's cut-out): whichever runs
                // first frees it, so neither order is safe and the user's stands.
                let both = aFreesB && cutsThrough(b) && inside(parts[i], boxes[j]) && !heldByTabs(a, b)
                var hard = false
                if cutsThrough(b), inside(parts[i], boxes[j]), !aFreesB, !heldByTabs(a, b) {
                    hard = true
                } else if roughs(a, before: b) {
                    hard = true
                } else if restsOn[j].contains(a.id) {
                    // A rest toolpath after what it rests on.
                    hard = true
                } else if !a.kind.needsShapes, b.kind.needsShapes {
                    // Rounding turns the blank down before anything is cut on it.
                    hard = true
                } else if i < j, !aFreesB || both, !roughs(b, before: a), !restsOn[i].contains(b.id), overlaps(boxes[i], boxes[j]) {
                    before[j] |= 1 << UInt64(i)
                }
                if hard {
                    before[j] |= 1 << UInt64(i)
                    if i > j { late.append(.init(operation: a.id, mustPrecede: b.id)) }
                }
            }
        }
        let tools = enabled.map { Tools(clearance: ops[$0].clearanceTool?.number, own: ops[$0].tool.number) }
        let original = Array(0..<m)
        let scheduled = m <= exactLimit ? exact(before: before, tools: tools) : greedy(before: before, tools: tools)
        let changesBefore = changes(original, tools)
        let changesAfter = scheduled.map { changes($0, tools) } ?? changesBefore
        // Take the new order when it fixes a dependency or saves a change; never make things worse
        // (and leave the order alone when constraints contradict each other).
        let better = scheduled.map { !late.isEmpty || changes($0, tools) < changesBefore } ?? false
        let pick = better ? scheduled! : original
        if !better { late = [] }

        // Re-insert disabled operations right after the operation they followed.
        var order: [UUID] = ops.prefix { !$0.enabled }.map(\.id)
        for k in pick {
            let idx = enabled[k]
            order.append(ops[idx].id)
            var t = idx + 1
            while t < ops.count, !ops[t].enabled { order.append(ops[t].id); t += 1 }
        }
        return Result(order: order, toolChangesBefore: changesBefore,
                      toolChangesAfter: better ? changesAfter : changesBefore, outOfOrder: late)
    }

    /// Whether an edge profile `depth` deep (its tip below the material top) stays above the tabs `cutOut` leaves: a
    /// profile with tabs whose tops are at least that deep. Tabs are at the bottom of the cut, so a top-edge profile
    /// normally clears them.
    public static func clearsTabs(_ depth: Double, of cutOut: CAMOperation, in project: Project) -> Bool {
        guard case let .profile(p) = cutOut.kind, PartHold.holdsPart(cutOut, in: project) else { return false }
        return depth <= tabTop(p) + 1e-6
    }

    /// How far below the material top a profile's tabs reach up to, mm.
    public static func tabTop(_ p: ProfileParams) -> Double { p.depth.cutDepth - p.tabs.thickness }

    /// A box on one sheet of the job.
    struct Area {
        var sheet: Int
        var rect: Rect2
    }

    /// The tool numbers an operation cuts with: its clearance tool's (if any), then its own.
    struct Tools: Hashable {
        var clearance: Int?
        var own: Int
    }

    /// Where a run order stands: the tool in the spindle at the end (-1 before the first), and the clearance tool
    /// of the block the last operation is in (nil when it has none).
    struct State: Hashable {
        var tool = -1
        var block: Int?
    }

    /// Tool changes for cutting an operation with `t` next, and the state after it. Joining the open block (same
    /// clearance tool) slips its clearing in with the block's others, so only its own tool can add a change.
    static func step(_ s: State, _ t: Tools) -> (changes: Int, state: State) {
        func change(_ a: Int, _ b: Int) -> Int { a >= 0 && a != b ? 1 : 0 }
        guard let c = t.clearance else { return (change(s.tool, t.own), State(tool: t.own)) }
        if s.block == c { return (change(s.tool, t.own), State(tool: t.own, block: c)) }
        return (change(s.tool, c) + change(c, t.own), State(tool: t.own, block: c))
    }

    /// The order operations cut in, given each one's clearance tool number (nil for none), in run order: runs of
    /// neighbours sharing a clearance tool form a block that cuts all its clearing first; each other operation is a
    /// block of its own.
    public static func blocks(_ clearance: [Int?]) -> [[Int]] {
        var out: [[Int]] = []
        for (k, c) in clearance.enumerated() {
            if let c, let last = out.last?.last, clearance[last] == c { out[out.count - 1].append(k) } else { out.append([k]) }
        }
        return out
    }

    static func changes(_ seq: [Int], _ tools: [Tools]) -> Int {
        var state = State(), total = 0
        for k in seq {
            let (c, next) = step(state, tools[k])
            total += c
            state = next
        }
        return total
    }

    /// Fewest tool changes over all orders that respect `before`; among those, the one closest to the user's order
    /// (lexicographically smallest). Memoized over (done set, state).
    static func exact(before: [UInt64], tools: [Tools]) -> [Int]? {
        let m = before.count
        guard m > 0 else { return [] }
        let full: UInt64 = m == 64 ? .max : (1 << UInt64(m)) - 1
        struct Key: Hashable { var done: UInt64; var state: State }
        var memo: [Key: Int] = [:]
        func cost(_ done: UInt64, _ state: State) -> Int {
            if done == full { return 0 }
            let key = Key(done: done, state: state)
            if let c = memo[key] { return c }
            var best = Int.max
            for k in 0..<m where done & (1 << UInt64(k)) == 0 && before[k] & ~done == 0 {
                let (step, next) = step(state, tools[k])
                let rest = cost(done | (1 << UInt64(k)), next)
                if rest != .max { best = min(best, step + rest) }
            }
            memo[key] = best
            return best
        }
        guard cost(0, State()) != .max else { return nil }
        var seq: [Int] = []
        var done: UInt64 = 0, state = State()
        while done != full {
            let target = cost(done, state)
            guard let k = (0..<m).first(where: { k in
                let (c, next) = step(state, tools[k])
                return done & (1 << UInt64(k)) == 0 && before[k] & ~done == 0 && c + cost(done | (1 << UInt64(k)), next) == target
            }) else { return nil }
            seq.append(k)
            done |= 1 << UInt64(k)
            state = step(state, tools[k]).state
        }
        return seq
    }

    /// Stable topological order that takes whatever adds no tool change first (for very long job lists).
    static func greedy(before: [UInt64], tools: [Tools]) -> [Int]? {
        let m = before.count
        guard m <= 64 else { return nil }
        var done: UInt64 = 0
        var seq: [Int] = []
        var state = State()
        while seq.count < m {
            let ready = (0..<m).filter { done & (1 << UInt64($0)) == 0 && before[$0] & ~done == 0 }
            guard let first = ready.first else { return nil }
            let k = ready.first { step(state, tools[$0]).changes == 0 } ?? first
            seq.append(k)
            done |= 1 << UInt64(k)
            state = step(state, tools[k]).state
        }
        return seq
    }
}

public extension Project {
    /// Adds a new operation to the run order: at the end, except an edge profile, which goes just before the first
    /// profile that cuts one of its parts out (inside or outside, on the same shapes), so the part is still held while
    /// its edge is shaped. Returns where it went.
    @discardableResult
    mutating func addOperation(_ op: CAMOperation) -> Int {
        if op.kind.isEdgeProfile, let k = operations.firstIndex(where: { other in
            guard case let .profile(p) = other.kind, p.side != .on else { return false }
            return !Set(other.shapeIDs).isDisjoint(with: op.shapeIDs)
        }) {
            operations.insert(op, at: k)
            return k
        }
        operations.append(op)
        return operations.count - 1
    }

    /// Puts the operations in the given order (ids not listed keep their relative order at the end).
    mutating func applyRunOrder(_ ids: [UUID]) {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let indexed = operations.enumerated().map { (rank[$1.id] ?? ids.count + $0, $1) }
        operations = indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
