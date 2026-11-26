import Foundation

/// A folder of toolpaths in the run order: a run of consecutive toolpaths (`CAMOperation.groupID`), one level deep.
///
/// The run order stays one flat list (`Project.operations`); a group only names a run of it. Its checkbox sets each
/// member's own "Include in output" and its eye each member's `hidden`, so there's no group-level switch an older
/// build could ignore: groups change no cut and don't raise the file format.
public struct ToolpathGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Folded in the sidebar; nil or false = open. Display only.
    public var isCollapsed: Bool?

    public init(id: UUID = UUID(), name: String, isCollapsed: Bool? = nil) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    public var collapsed: Bool { isCollapsed == true }
}

/// A row of the sidebar's run-order list: a group's header, or a toolpath (in a group, under an open header).
public enum RunOrderRow: Hashable, Sendable {
    case group(UUID)
    case operation(UUID)
}

/// Whether a group's members are included in the output: all, none or some.
public enum GroupInclusion: Hashable, Sendable {
    case all, none, mixed
}

public extension Project {
    // MARK: Keeping groups whole

    /// Pulls every group's members together at its first member's place, keeping their order; nothing else moves.
    /// Setting `operations` calls it, so a group stays in one piece through any edit. Unlike `normalizeGroups()` it
    /// keeps a `groupID` that names no group yet (a group being made).
    mutating func keepGroupsTogether() {
        guard operations.contains(where: { $0.groupID != nil }) else { return }
        let grouped = Self.together(operations)
        if grouped.map(\.id) != operations.map(\.id) { operations = grouped }
    }

    /// Keeps the groups sound: clears a `groupID` naming no group, drops groups with no members and repeated groups,
    /// pulls each group's members together at its first member's place, and lists the groups in run order. Every edit
    /// that adds, removes or moves toolpaths or groups ends with it (template apply, import, Recalculate All, loading).
    mutating func normalizeGroups() {
        var seen = Set<UUID>()
        var groups = toolpathGroups.filter { seen.insert($0.id).inserted }
        let known = Set(groups.map(\.id))
        var ops = operations
        for i in ops.indices where ops[i].groupID.map({ !known.contains($0) }) == true { ops[i].groupID = nil }
        ops = Self.together(ops)
        let order = ops.compactMap(\.groupID).reduce(into: [UUID]()) { if $0.last != $1 { $0.append($1) } }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        groups = groups.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        if ops != operations { operations = ops }
        if groups != toolpathGroups { toolpathGroups = groups }
    }

    /// `ops` with each group's members moved up to its first member, in order.
    private static func together(_ ops: [CAMOperation]) -> [CAMOperation] {
        var members: [UUID: [CAMOperation]] = [:]
        for op in ops { if let g = op.groupID { members[g, default: []].append(op) } }
        var out: [CAMOperation] = []
        out.reserveCapacity(ops.count)
        var placed = Set<UUID>()
        for op in ops {
            guard let g = op.groupID else { out.append(op); continue }
            if placed.insert(g).inserted { out += members[g] ?? [] }
        }
        return out
    }

    /// The project with what's only shown, not cut, set to its default: every toolpath shown and every group open. Two
    /// projects with the same cutting state generate the same job.
    var cuttingState: Project {
        var p = self
        if p.operations.contains(where: { $0.hidden != nil }) {
            var ops = p.operations
            for i in ops.indices { ops[i].hidden = nil }
            p.operations = ops
        }
        for i in p.toolpathGroups.indices { p.toolpathGroups[i].isCollapsed = nil }
        return p
    }

    // MARK: Reading groups

    func toolpathGroup(id: UUID) -> ToolpathGroup? { toolpathGroups.first { $0.id == id } }

    /// The group's toolpaths, in run order.
    func members(ofGroup id: UUID) -> [CAMOperation] { operations.filter { $0.groupID == id } }

    /// Whether the group's members are included in the output (their own "Include in output").
    func inclusion(ofGroup id: UUID) -> GroupInclusion {
        let m = members(ofGroup: id)
        let on = m.filter(\.enabled).count
        return on == m.count ? .all : on == 0 ? .none : .mixed
    }

    /// The sidebar's rows: each group's header, then its members unless it's folded; ungrouped toolpaths in place.
    func runOrderRows() -> [RunOrderRow] {
        var rows: [RunOrderRow] = []
        var last: UUID?
        for op in operations {
            if let g = op.groupID {
                if g != last { rows.append(.group(g)) }
                last = g
                if toolpathGroup(id: g)?.collapsed != true { rows.append(.operation(op.id)) }
            } else {
                last = nil
                rows.append(.operation(op.id))
            }
        }
        return rows
    }

    /// The run of the run order each toolpath is in, from 0: each group is one run, and so is each stretch of
    /// ungrouped toolpaths between them. Optimize Run Order reorders inside runs and keeps them in order. With no groups
    /// every toolpath is in run 0.
    var runSegments: [Int] {
        var out: [Int] = []
        var segment = 0
        var current: UUID??
        for op in operations {
            if let c = current, c != op.groupID { segment += 1 }
            current = .some(op.groupID)
            out.append(segment)
        }
        return out
    }

    /// The name a new group gets: "Group n", the lowest n no group has.
    func nextGroupName(_ base: String = "Group") -> String {
        let names = Set(toolpathGroups.map(\.name))
        var n = 1
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Editing groups

    /// Puts `ids` in a new group at the first one's place in the run order, in their run order, taking them out of
    /// any group they were in. Returns the new group's id, or nil when `ids` names no toolpath.
    @discardableResult
    mutating func groupOperations(_ ids: Set<UUID>, name: String? = nil) -> UUID? {
        guard let first = operations.firstIndex(where: { ids.contains($0.id) }) else { return nil }
        let group = ToolpathGroup(name: name ?? nextGroupName())
        var ops = operations
        // Members of a group the first one splits keep together before or after it: the new group goes where its first
        // member was, unless that's inside another group, when it goes after that group.
        var moved = ops.filter { ids.contains($0.id) }
        for i in moved.indices { moved[i].groupID = group.id }
        let before = ops[..<first].filter { !ids.contains($0.id) }
        ops.removeAll { ids.contains($0.id) }
        var at = before.count
        if at > 0, at < ops.count, let g = ops[at - 1].groupID, ops[at].groupID == g {
            at = (ops.lastIndex { $0.groupID == g } ?? at - 1) + 1
        }
        ops.insert(contentsOf: moved, at: at)
        toolpathGroups.append(group)
        operations = ops
        normalizeGroups()
        return group.id
    }

    /// Moves `ids` to the end of group `group`, taking them out of any other.
    mutating func moveOperations(_ ids: Set<UUID>, toGroup group: UUID) {
        guard toolpathGroup(id: group) != nil else { return }
        var ops = operations
        var moved = ops.filter { ids.contains($0.id) && $0.groupID != group }
        guard !moved.isEmpty else { return }
        for i in moved.indices { moved[i].groupID = group }
        ops.removeAll { ids.contains($0.id) && $0.groupID != group }
        let at = (ops.lastIndex { $0.groupID == group }.map { $0 + 1 }) ?? ops.count
        ops.insert(contentsOf: moved, at: at)
        operations = ops
        normalizeGroups()
    }

    /// Takes `ids` out of their groups. Each goes just after its old group, so the group stays in one piece.
    mutating func removeFromGroup(_ ids: Set<UUID>) {
        var ops = operations
        for g in toolpathGroups.map(\.id) {
            guard let first = ops.firstIndex(where: { ids.contains($0.id) && $0.groupID == g }) else { continue }
            var leaving = ops.filter { ids.contains($0.id) && $0.groupID == g }
            for i in leaving.indices { leaving[i].groupID = nil }
            let stayBefore = ops[..<first].filter { !(ids.contains($0.id) && $0.groupID == g) }.count
            ops.removeAll { ids.contains($0.id) && $0.groupID == g }
            // After what's left of the group, or where they were when none is left.
            let at = ops.lastIndex { $0.groupID == g }.map { $0 + 1 } ?? stayBefore
            ops.insert(contentsOf: leaving, at: at)
        }
        operations = ops
        normalizeGroups()
    }

    /// Ungroups `group`: its toolpaths stay where they are, ungrouped.
    mutating func ungroup(_ group: UUID) {
        var ops = operations
        for i in ops.indices where ops[i].groupID == group { ops[i].groupID = nil }
        operations = ops
        toolpathGroups.removeAll { $0.id == group }
        normalizeGroups()
    }

    /// Deletes `group`, and its toolpaths too unless `keepToolpaths` (they're then ungrouped in place).
    mutating func deleteGroup(_ group: UUID, keepToolpaths: Bool) {
        if keepToolpaths { ungroup(group); return }
        operations.removeAll { $0.groupID == group }
        toolpathGroups.removeAll { $0.id == group }
        normalizeGroups()
    }

    /// A copy of `group` and its toolpaths (with new ids), just after it. Returns the copy's id.
    @discardableResult
    mutating func duplicateGroup(_ group: UUID) -> UUID? {
        guard let g = toolpathGroup(id: group), let last = operations.lastIndex(where: { $0.groupID == group }) else { return nil }
        let copy = ToolpathGroup(name: g.name + " copy", isCollapsed: g.isCollapsed)
        let ops = members(ofGroup: group).map { op -> CAMOperation in
            var c = op
            c.id = UUID()
            c.name = op.name + " copy"
            c.groupID = copy.id
            return c
        }
        toolpathGroups.append(copy)
        operations.insert(contentsOf: ops, at: last + 1)
        normalizeGroups()
        return copy.id
    }

    mutating func renameGroup(_ group: UUID, to name: String) {
        guard let i = toolpathGroups.firstIndex(where: { $0.id == group }) else { return }
        toolpathGroups[i].name = name
    }

    mutating func setGroupCollapsed(_ group: UUID, _ collapsed: Bool) {
        guard let i = toolpathGroups.firstIndex(where: { $0.id == group }) else { return }
        toolpathGroups[i].isCollapsed = collapsed ? true : nil
    }

    /// The group checkbox: sets each member's "Include in output". There's no group-level switch.
    mutating func setGroupIncluded(_ group: UUID, _ included: Bool) {
        var ops = operations
        for i in ops.indices where ops[i].groupID == group { ops[i].enabled = included }
        if ops != operations { operations = ops }
    }

    /// The group's eye: hides or shows each member in the 3D view.
    mutating func setGroupHidden(_ group: UUID, _ hidden: Bool) {
        setHidden(Set(members(ofGroup: group).map(\.id)), hidden)
    }

    /// Hides or shows `ids` in the 3D view (display only).
    mutating func setHidden(_ ids: Set<UUID>, _ hidden: Bool) {
        var ops = operations
        for i in ops.indices where ids.contains(ops[i].id) { ops[i].hidden = hidden ? true : nil }
        if ops != operations { operations = ops }
    }

    /// Show Only Selected: hides every toolpath but `ids`, and shows those.
    mutating func showOnly(_ ids: Set<UUID>) {
        var ops = operations
        for i in ops.indices { ops[i].hidden = ids.contains(ops[i].id) ? nil : true }
        if ops != operations { operations = ops }
    }

    // MARK: Dragging

    /// Moves sidebar rows (`runOrderRows()`) as a drag in the run-order list does. A toolpath joins the group of the
    /// rows it lands among: dropped just under an open group's header, or between two of its members, it joins that
    /// group; dropped after a group's last member it leaves the group, unless it was in it already. A group's header
    /// moves the whole group, and never into another group (it goes after that one). Folded groups move as one row.
    mutating func moveRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        let rows = runOrderRows()
        let movedRows = source.sorted().filter { rows.indices.contains($0) }.map { rows[$0] }
        guard !movedRows.isEmpty else { return }
        let movedGroups = Set(movedRows.compactMap { if case let .group(g) = $0 { g } else { nil } })
        var movedOps: [UUID] = []
        for row in movedRows {
            switch row {
            case let .group(g): movedOps += members(ofGroup: g).map(\.id)
            case let .operation(id): if !movedOps.contains(id) { movedOps.append(id) }
            }
        }
        let movedSet = Set(movedOps)
        let byID = Dictionary(operations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func isMoved(_ row: RunOrderRow) -> Bool {
            switch row {
            case let .group(g): movedGroups.contains(g)
            case let .operation(id): movedSet.contains(id)
            }
        }
        let prev = rows[..<min(destination, rows.count)].last { !isMoved($0) }
        let next = rows[min(destination, rows.count)...].first { !isMoved($0) }
        func group(of row: RunOrderRow?) -> UUID? {
            if case let .operation(id) = row { return byID[id]?.groupID }
            return nil
        }
        // Which group the moved toolpaths land in.
        var target: UUID?
        var insertAfter: UUID?    // the operation the moved ones go after; nil = at the start
        var insertBeforeGroup: UUID?
        switch prev {
        case let .group(g)?:
            if toolpathGroup(id: g)?.collapsed == true {
                insertAfter = operations.last { $0.groupID == g && !movedSet.contains($0.id) }?.id
            } else {
                target = g
                insertBeforeGroup = g
            }
        case let .operation(id)?:
            insertAfter = id
            if let g = group(of: prev) {
                let wasIn = movedOps.allSatisfy { byID[$0]?.groupID == g }
                if group(of: next) == g || wasIn { target = g }
            }
        case nil:
            break
        }
        // A group never goes inside another: past the end of the group it would land in.
        if !movedGroups.isEmpty, let g = target {
            target = nil
            insertBeforeGroup = nil
            insertAfter = operations.last { $0.groupID == g && !movedSet.contains($0.id) }?.id
        }
        var moving = movedOps.compactMap { byID[$0] }
        for i in moving.indices where moving[i].groupID.map({ !movedGroups.contains($0) }) ?? true {
            moving[i].groupID = target
        }
        var ops = operations.filter { !movedSet.contains($0.id) }
        let at: Int
        if let g = insertBeforeGroup {
            at = ops.firstIndex { $0.groupID == g } ?? ops.count
        } else if let a = insertAfter {
            at = (ops.firstIndex { $0.id == a }.map { $0 + 1 }) ?? ops.count
        } else {
            at = 0
        }
        ops.insert(contentsOf: moving, at: at)
        operations = ops
        normalizeGroups()
    }
}
