import Foundation

/// Reorders operations to minimize tool changes without breaking machining dependencies.
///
/// On a manual-change machine every tool change is a stop for a collet swap and a touch-off, minutes that dwarf any
/// air-time saving, so the fewest changes win and the user's order breaks ties. An operation stays after:
/// - everything inside the outline it cuts through (parts are cut free last, never finished while held by tabs),
/// - 3D roughing of the same model (when it's the finish), and
/// - any earlier operation whose area overlaps its own (the user's order may carry intent there).
/// Disabled operations aren't machined, so they keep their place next to the operation they followed.
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
        // Per-shape boxes grown by the tool radius (the area the operation can touch).
        let boxes: [[Rect2]] = enabled.map { idx in
            let op = ops[idx]
            return project.shapes(for: op).map(\.bounds).filter { !$0.isEmpty }.map { $0.insetBy(-op.tool.radius) }
        }
        func cutsThrough(_ op: CAMOperation) -> Bool {
            if case let .profile(p) = op.kind { return p.depth.cutDepth >= thickness - 0.01 }
            return false
        }
        func inside(_ inner: [Rect2], _ outer: [Rect2]) -> Bool {
            !inner.isEmpty && inner.allSatisfy { r in
                outer.contains { $0.contains(r.min, tolerance: 1e-6) && $0.contains(r.max, tolerance: 1e-6) }
            }
        }
        func overlaps(_ a: [Rect2], _ b: [Rect2]) -> Bool {
            a.contains { r in b.contains { $0.intersects(r) } }
        }
        // before[j]: bit mask of the operations that must come before j (indices into `enabled`).
        // Hard rules first (machining dependencies), then the user's order wherever areas overlap.
        var before = [UInt64](repeating: 0, count: m)
        var late: [Result.Late] = []
        for j in 0..<m {
            for i in 0..<m where i != j {
                let a = ops[enabled[i]], b = ops[enabled[j]]
                let aFreesB = cutsThrough(a) && inside(boxes[j], boxes[i])
                var hard = false
                if cutsThrough(b), inside(boxes[i], boxes[j]), !aFreesB {
                    hard = true
                } else if case .finish3D = b.kind, case .rough3D = a.kind, !Set(a.shapeIDs).isDisjoint(with: b.shapeIDs) {
                    hard = true
                } else if i < j, !aFreesB, overlaps(boxes[i], boxes[j]) {
                    before[j] |= 1 << UInt64(i)
                }
                if hard {
                    before[j] |= 1 << UInt64(i)
                    if i > j { late.append(.init(operation: a.id, mustPrecede: b.id)) }
                }
            }
        }
        let tools = enabled.map { ops[$0].tool.number }
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

    static func changes(_ seq: [Int], _ tools: [Int]) -> Int {
        zip(seq, seq.dropFirst()).filter { tools[$0.0] != tools[$0.1] }.count
    }

    /// Fewest tool changes over all orders that respect `before`; among those, the one closest to the user's order
    /// (lexicographically smallest). Memoized over (done set, current tool).
    static func exact(before: [UInt64], tools: [Int]) -> [Int]? {
        let m = before.count
        guard m > 0 else { return [] }
        let full: UInt64 = m == 64 ? .max : (1 << UInt64(m)) - 1
        struct Key: Hashable { var done: UInt64; var tool: Int }
        var memo: [Key: Int] = [:]
        func cost(_ done: UInt64, _ tool: Int) -> Int {
            if done == full { return 0 }
            let key = Key(done: done, tool: tool)
            if let c = memo[key] { return c }
            var best = Int.max
            for k in 0..<m where done & (1 << UInt64(k)) == 0 && before[k] & ~done == 0 {
                let step = tool >= 0 && tools[k] != tool ? 1 : 0
                let rest = cost(done | (1 << UInt64(k)), tools[k])
                if rest != .max { best = min(best, step + rest) }
            }
            memo[key] = best
            return best
        }
        guard cost(0, -1) != .max else { return nil }
        var seq: [Int] = []
        var done: UInt64 = 0, tool = -1
        while done != full {
            let target = cost(done, tool)
            guard let k = (0..<m).first(where: { k in
                done & (1 << UInt64(k)) == 0 && before[k] & ~done == 0
                    && (tool >= 0 && tools[k] != tool ? 1 : 0) + cost(done | (1 << UInt64(k)), tools[k]) == target
            }) else { return nil }
            seq.append(k)
            done |= 1 << UInt64(k)
            tool = tools[k]
        }
        return seq
    }

    /// Stable same-tool-first topological order (for very long job lists).
    static func greedy(before: [UInt64], tools: [Int]) -> [Int]? {
        let m = before.count
        guard m <= 64 else { return nil }
        var done: UInt64 = 0
        var seq: [Int] = []
        var tool: Int?
        while seq.count < m {
            let ready = (0..<m).filter { done & (1 << UInt64($0)) == 0 && before[$0] & ~done == 0 }
            guard let first = ready.first else { return nil }
            let k = ready.first { tools[$0] == tool } ?? first
            seq.append(k)
            done |= 1 << UInt64(k)
            tool = tools[k]
        }
        return seq
    }
}

public extension Project {
    /// Puts the operations in the given order (ids not listed keep their relative order at the end).
    mutating func applyRunOrder(_ ids: [UUID]) {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let indexed = operations.enumerated().map { (rank[$1.id] ?? ids.count + $0, $1) }
        operations = indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
