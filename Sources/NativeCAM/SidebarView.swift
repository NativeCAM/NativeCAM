import CAMCore
import SwiftUI

struct SidebarView: View {
    @Binding var project: Project
    @Bindable var workspace: Workspace
    @Environment(ToolLibraryStore.self) private var library

    var body: some View {
        List(selection: $workspace.selection) {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Material & Machine")
                        Text("\(fmt(project.stock.width)) × \(fmt(project.stock.height)) × \(fmt(project.stock.thickness)) \(project.displayUnits.symbol)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "shippingbox") }
                .tag(SidebarItem.setup)
                .cardRow(0, of: 1)
            } header: {
                SectionTitle("Job Setup")
            }

            Section {
                ForEach(Array(project.shapes.enumerated()), id: \.element.id) { index, shape in
                    HStack {
                        Label(shape.name, systemImage: shape.isKeepOut ? "exclamationmark.shield" : icon(for: shape.kind))
                        // On a job of several sheets, the sheet each shape is on (clamps are on every sheet).
                        if project.sheetCount > 1 && !shape.isKeepOut {
                            Spacer(minLength: 4)
                            Text("Sheet \(project.sheetIndex(of: shape) + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                        .tag(SidebarItem.shape(shape.id))
                        .cardRow(index, of: project.shapes.count)
                        .contextMenu {
                            Button("Duplicate") { duplicate(shape) }
                            Button("Delete", role: .destructive) { delete(shapes: [shape.id]) }
                        }
                }
                .onMove { project.shapes.move(fromOffsets: $0, toOffset: $1) }
                if project.shapes.isEmpty {
                    Placeholder("Add a shape, or import vectors or a 3D model.")
                }
            } header: {
                HStack {
                    SectionTitle("Design")
                    Spacer()
                    Menu {
                        AddShapeMenu(project: $project, workspace: workspace)
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(.trailing, 6)
            }

            Section {
                let rows = project.runOrderRows()
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    switch row {
                    case let .group(g):
                        groupRow(g)
                            .tag(SidebarItem.toolpathGroup(g))
                            .cardRow(index, of: rows.count)
                    case let .operation(id):
                        if let k = project.operations.firstIndex(where: { $0.id == id }) {
                            operationRow(k)
                                .tag(SidebarItem.operation(id))
                                .cardRow(index, of: rows.count)
                        }
                    }
                }
                // A toolpath dropped among a group's rows joins it; a group's header moves the whole group.
                .onMove { project.moveRows(fromOffsets: $0, toOffset: $1) }
                if project.operations.isEmpty {
                    Placeholder("Select shapes, then add a toolpath.")
                }
            } header: {
                HStack {
                    SectionTitle("Toolpaths (run order)")
                    Spacer()
                    if let r = workspace.job?.reorder {
                        Button {
                            project.applyRunOrder(OperationScheduler.optimize(project).order)
                        } label: { Image(systemName: "arrow.up.arrow.down") }
                            .buttonStyle(.borderless)
                            .help(r.outOfOrder.isEmpty
                                ? "Optimize run order: \(r.toolChangesBefore) → \(r.toolChangesAfter) tool changes (⌘Z to undo)"
                                : "Fix run order: finish the work inside each part before cutting it free (⌘Z to undo)")
                    }
                    Menu {
                        AddOperationMenu(project: $project, workspace: workspace, library: library)
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(.trailing, 6)
            }

            if let issues = workspace.job?.issues, !issues.isEmpty {
                Section {
                    ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                if let op = issue.operation { Text(op).font(.caption).foregroundStyle(.secondary) }
                                Text(issue.message).font(.callout).lineLimit(1...4).fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" :
                                    issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(issue.severity == .error ? .red : issue.severity == .warning ? .orange : .secondary)
                        }
                        .selectionDisabled()
                        .cardRow(index, of: issues.count)
                    }
                } header: {
                    SectionTitle("Checks")
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { deleteSelection() }
    }

    private func fmt(_ mm: Double) -> String { project.displayUnits.format(mm, decimals: project.displayUnits == .inch ? 3 : 1) }

    // MARK: Run order rows

    /// A toolpath's row: colour, name and tool, its eye and its "Include in output" checkbox, indented in a group.
    @ViewBuilder
    private func operationRow(_ index: Int) -> some View {
        let op = project.operations[index]
        HStack(spacing: 6) {
            Circle()
                .fill(Color(simd: workspace.colorForOperation(index)))
                .frame(width: 8, height: 8)
                .opacity(op.isHidden ? 0.35 : 1)
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(op.name).foregroundStyle(op.enabled ? .primary : .secondary)
                    // A clearance tool cuts first: "T10, then T2 1/8" Upcut End Mill".
                    Text("\(op.clearanceTool.map { "T\($0.number), then " } ?? "")T\(op.tool.number) \(op.tool.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: icon(for: op.kind)) }
            Spacer()
            EyeButton(hidden: op.isHidden) { project.setHidden([op.id], !op.isHidden) }
            Toggle("", isOn: Binding(get: { op.enabled }, set: { project.operations[index].enabled = $0 }))
                .labelsHidden().toggleStyle(.checkbox)
                .help("Include in output")
        }
        .padding(.leading, op.groupID == nil ? 0 : 14)
        .contextMenu { operationMenu(op) }
    }

    /// A group's header: fold, name, its tools and run time, its worst open check when folded, its eye and its checkbox,
    /// which sets each member's "Include in output".
    @ViewBuilder
    private func groupRow(_ g: UUID) -> some View {
        let group = project.toolpathGroup(id: g) ?? ToolpathGroup(id: g, name: "Group")
        let members = project.members(ofGroup: g)
        let allHidden = !members.isEmpty && members.allSatisfy(\.isHidden)
        HStack(spacing: 6) {
            Button {
                project.setGroupCollapsed(g, !group.collapsed)
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .frame(width: 8)
            }
            .buttonStyle(.borderless)
            .help(group.collapsed ? "Show the group's toolpaths" : "Fold the group")
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).fontWeight(.semibold)
                        .foregroundStyle(project.inclusion(ofGroup: g) == .none ? .secondary : .primary)
                    Text(groupSummary(members)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "folder") }
            Spacer()
            if group.collapsed, let badge = groupBadge(members) {
                Label("\(badge.count)", systemImage: badge.severity == .error ? "xmark.octagon.fill" : badge.severity == .warning
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .labelStyle(.titleAndIcon).font(.caption)
                    .foregroundStyle(badge.severity == .error ? .red : badge.severity == .warning ? .orange : .secondary)
                    .help("\(badge.count) check\(badge.count == 1 ? "" : "s") on the group's toolpaths: see Checks")
            }
            EyeButton(hidden: allHidden) { project.setGroupHidden(g, !allHidden) }
            Toggle(sources: groupInclusionBindings(g, count: members.count), isOn: \.self) { EmptyView() }
                .labelsHidden().toggleStyle(.checkbox)
                .help("Include the group's toolpaths in output")
        }
        .contextMenu { groupMenu(g) }
    }

    /// One binding per member for the group's three-state checkbox; setting any sets them all in one change.
    private func groupInclusionBindings(_ g: UUID, count: Int) -> [Binding<Bool>] {
        project.members(ofGroup: g).map { op in
            Binding(get: { project.operations.first { $0.id == op.id }?.enabled ?? false },
                    set: { v in if project.inclusion(ofGroup: g) != (v ? .all : .none) { project.setGroupIncluded(g, v) } })
        }
    }

    /// "T1, T5 · 4:12": the tools the group's included toolpaths use, in order, and their run time.
    private func groupSummary(_ members: [CAMOperation]) -> String {
        var tools: [Int] = []
        for op in members where op.enabled {
            for t in [op.clearanceTool?.number, op.tool.number].compactMap({ $0 }) where !tools.contains(t) { tools.append(t) }
        }
        let ids = Set(members.filter(\.enabled).map(\.id))
        var seconds = 0.0
        if let job = workspace.job, let e = job.estimate {
            for (tp, t) in zip(job.toolpaths, e.toolpathSeconds) where ids.contains(tp.sourceOperationID) { seconds += t }
        }
        let n = members.count
        let what = tools.isEmpty ? "\(n) toolpath\(n == 1 ? "" : "s"), none included" : tools.map { "T\($0)" }.joined(separator: ", ")
        return seconds > 0 ? "\(what) · \(formatDuration(seconds))" : what
    }

    /// The worst open check on the group's toolpaths, and how many there are.
    private func groupBadge(_ members: [CAMOperation]) -> (severity: Severity, count: Int)? {
        let names = Set(members.map(\.name))
        let issues = (workspace.job?.issues ?? []).filter { $0.operation.map(names.contains) ?? false }
        let order: [Severity] = [.error, .warning, .info]
        guard let worst = order.first(where: { s in issues.contains { $0.severity == s } }) else { return nil }
        return (worst, issues.count)
    }

    /// The toolpaths a menu item acts on: the selection when the clicked one is in it, else the clicked one.
    private func targets(_ op: CAMOperation) -> Set<UUID> {
        let selected = workspace.selectedOperationIDs(in: project)
        return selected.contains(op.id) ? selected : [op.id]
    }

    @ViewBuilder
    private func operationMenu(_ op: CAMOperation) -> some View {
        let ids = targets(op)
        Button("Group Selected") { group(ids) }
        if !project.toolpathGroups.isEmpty {
            Menu("Move to Group") {
                ForEach(project.toolpathGroups) { g in
                    Button(g.name) { project.moveOperations(ids, toGroup: g.id) }.disabled(ids.allSatisfy { id in
                        project.operations.first { $0.id == id }?.groupID == g.id })
                }
            }
        }
        if project.operations.contains(where: { ids.contains($0.id) && $0.groupID != nil }) {
            Button("Remove from Group") { project.removeFromGroup(ids) }
        }
        Divider()
        Button(op.isHidden ? "Show" : "Hide") { project.setHidden(ids, !op.isHidden) }
        Button("Hide Others") { project.showOnly(ids) }
        Button(ids.count == 1 ? "Export Toolpath…" : "Export Selected Toolpaths…") {
            workspace.subsetExport = SubsetExportRequest(operationIDs: ids, group: nil)
        }
        Divider()
        Button("Duplicate") { duplicate(op) }
        Button("Delete", role: .destructive) { delete(operations: ids) }
    }

    @ViewBuilder
    private func groupMenu(_ g: UUID) -> some View {
        let members = Set(project.members(ofGroup: g).map(\.id))
        Button("Rename…") { rename(g) }
        Button("Ungroup") { project.ungroup(g); workspace.selection = Set(members.map { .operation($0) }) }
        Button("Duplicate") {
            if let copy = project.duplicateGroup(g) { workspace.selection = [.toolpathGroup(copy)] }
        }
        Divider()
        Button("Export Group…") { workspace.subsetExport = SubsetExportRequest(operationIDs: members, group: g) }
        Button("Hide Others") { project.showOnly(members) }
        Divider()
        Button("Delete Group…", role: .destructive) { deleteGroup(g) }
    }

    /// Group Selected: the toolpaths into a new group, named "Group n", then selected.
    private func group(_ ids: Set<UUID>) {
        guard let g = project.groupOperations(ids) else { return }
        workspace.selection = [.toolpathGroup(g)]
    }

    private func rename(_ g: UUID) {
        guard let group = project.toolpathGroup(id: g) else { return }
        let ask = NSAlert()
        ask.messageText = "Rename Group"
        let field = NSTextField(string: group.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        ask.accessoryView = field
        ask.addButton(withTitle: "Rename")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty, new != name { project.renameGroup(g, to: new) }
    }

    /// Delete Group…: asks whether its toolpaths go too, or stay ungrouped.
    private func deleteGroup(_ g: UUID) {
        guard let group = project.toolpathGroup(id: g) else { return }
        let n = project.members(ofGroup: g).count
        let ask = NSAlert()
        ask.messageText = "Delete the group “\(group.name)”?"
        ask.informativeText = "Delete its \(n) toolpath\(n == 1 ? "" : "s") too, or keep them in the run order, ungrouped."
        ask.addButton(withTitle: "Keep Toolpaths")
        ask.addButton(withTitle: "Delete Toolpaths")
        ask.addButton(withTitle: "Cancel")
        switch ask.runModal() {
        case .alertFirstButtonReturn: project.deleteGroup(g, keepToolpaths: true)
        case .alertSecondButtonReturn: project.deleteGroup(g, keepToolpaths: false); workspace.selection = [.setup]
        default: break
        }
    }

    private func icon(for kind: ShapeKind) -> String {
        switch kind {
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .ellipse: "oval"
        case .polygon: "hexagon"
        case .star: "star"
        case .text: "textformat"
        case .paths: "scribble.variable"
        case .model: "cube"
        case .spiral: "tornado"
        }
    }

    private func icon(for kind: OperationKind) -> String {
        switch kind {
        case .profile: "square.dashed"
        case .pocket: "square.fill.on.square"
        case .drill: "circle.dotted"
        case .vcarve: "angle"
        case .rough3D: "square.stack.3d.down.right"
        case .finish3D: "mountain.2"
        case .rounding: "cylinder"
        case .rotaryFinish: "rotate.3d"
        case .rotaryRough: "cylinder.split.1x2"
        case .chamfer: "skew"
        case .fluting: "line.diagonal"
        case .prism: "triangle"
        case .edgeProfile: "rectangle.roundedtop"
        case .moulding: "photo.artframe"
        }
    }

    private func duplicate(_ shape: DesignShape) {
        var copy = shape
        copy.id = UUID()
        copy.name = shape.name + " copy"
        copy.position += Vec2(0.5.inch, -0.5.inch)
        project.shapes.append(copy)
        workspace.selection = [.shape(copy.id)]
    }

    private func duplicate(_ op: CAMOperation) {
        var copy = op
        copy.id = UUID()
        copy.name = op.name + " copy"
        // In a group, the copy goes at the group's end (groups stay in one piece); otherwise at the end of the run order.
        if let g = op.groupID, let last = project.operations.lastIndex(where: { $0.groupID == g }) {
            project.operations.insert(copy, at: last + 1)
        } else {
            project.operations.append(copy)
        }
        workspace.selection = [.operation(copy.id)]
    }

    private func delete(shapes ids: Set<UUID>) {
        var p = project
        p.shapes.removeAll { ids.contains($0.id) }
        for i in p.operations.indices { p.operations[i].shapeIDs.removeAll { ids.contains($0) } }
        // A last sheet left with nothing on it goes too (in the same Undo step).
        p.removeEmptySheets()
        project = p
        workspace.selection = [.setup]
    }

    /// One change: a group left empty goes too.
    private func delete(operations ids: Set<UUID>) {
        var p = project
        p.operations.removeAll { ids.contains($0.id) }
        p.normalizeGroups()
        project = p
        workspace.selection = [.setup]
    }

    private func deleteSelection() {
        let shapeIDs = Set(workspace.selectedShapeIDs)
        if !shapeIDs.isEmpty { delete(shapes: shapeIDs) }
        // A group selected on its own asks first, as Delete Group… does.
        if let g = workspace.selectedGroupID, workspace.selectedOperationID == nil { deleteGroup(g); return }
        let ops = workspace.selectedOperationIDs(in: project)
        if !ops.isEmpty { delete(operations: ops) }
    }
}

extension Color {
    init(simd c: SIMD4<Float>) {
        self.init(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w))
    }
}

/// "Add Shape" menu items.
struct AddShapeMenu: View {
    @Binding var project: Project
    let workspace: Workspace

    var body: some View {
        Button("Rectangle") { add(ShapeFactory.rectangle(workspace.shown(project))) }
        Button("Circle") { add(ShapeFactory.circle(workspace.shown(project))) }
        Button("Ellipse") { add(ShapeFactory.ellipse(workspace.shown(project))) }
        Button("Polygon") { add(ShapeFactory.polygon(workspace.shown(project))) }
        Button("Star") { add(ShapeFactory.star(workspace.shown(project))) }
        Divider()
        Button("Text") { add(ShapeFactory.text(workspace.shown(project))) }
        if project.stock.rotary?.isWrapped == true {
            Button("Spiral") { add(ShapeFactory.spiral(workspace.shown(project))) }
                .help("Spiral lines that wrap around the blank, for a rope or barley twist")
        }
    }

    private func add(_ shape: DesignShape) {
        let shape = workspace.placedOnSheet(shape, of: project)
        project.shapes.append(shape)
        workspace.selection = [.shape(shape.id)]
    }
}

/// "Add Toolpath" menu items; the new operation uses the selected shapes.
struct AddOperationMenu: View {
    @Binding var project: Project
    let workspace: Workspace
    let library: ToolLibraryStore

    var body: some View {
        let selected = workspace.selectedShapeIDs
        Group {
            Button("Profile (cut out / inside)") { add(.profile) }
            Button("Edge Profile") { add(.edgeProfile) }
                .help("Shape the top edge of parts with a roundover, cove, ogee or custom form bit, round their outside, their holes or both, before they're cut out")
            Button("Pocket") { add(.pocket) }
            Button("Drill") { add(.drill) }
            Button("V-carve") { add(.vcarve) }
            Button("Inlay…") { workspace.inlayRequest = InlayRequest(selection: selected) }
                .help("Make a V-carve inlay's pocket and plug together, with one V-bit and depths that fit")
            Button("Chamfer") { add(.chamfer) }
                .help("Bevel the edges of closed shapes with a V-bit")
            Button("Fluting") { add(.fluting) }
                .help("Cut along vectors with a ball nose or V-bit, ramping in and out at the ends")
            Button("Prism") { add(.prism) }
                .help("Carve shapes as a raised bevel rising to a ridge along their middle, with a V-bit")
            Divider()
            if project.stock.rotary == nil {
                Button("3D Roughing") { add(.rough3D) }
                Button("3D Finishing") { add(.finish3D) }
                Button("Moulding") { add(.moulding) }
                    .help("Sweep an open profile vector along a rail, open or closed, into a 3D surface (picture frames, trim, raised panels), mitred at sharp corners, then rough and finish it. The smallest open vector selected is the profile; the rest are rails")
            } else {
                Button("3D Rotary Roughing") { add(.rotaryRough) }
                    .help("Clear the stock round a 3D model on the blank in layers with an end mill, from a square bar or a round blank, leaving an allowance for the finish")
                Button("3D Rotary Finishing") { add(.rotaryFinish) }
                    .help("Finish a 3D model on the blank all the way round as it turns: a ball nose follows it in a spiral, rings or passes along the blank")
            }
        }
        .disabled(selected.isEmpty)
        if project.stock.rotary != nil {
            Divider()
            Button("Rounding (turn the blank round)") { add(.rounding) }
                .help("Turn a square bar round, or a round blank down to a smaller diameter")
        }
        if selected.isEmpty {
            Divider()
            Text("Select shapes in the Design list first")
        }
    }

    enum Kind { case profile, edgeProfile, pocket, drill, vcarve, chamfer, fluting, prism, rough3D, finish3D, moulding, rounding, rotaryFinish, rotaryRough }

    private func add(_ kind: Kind) {
        let shapes = kind == .rounding ? [] : workspace.selectedShapeIDs
        guard !shapes.isEmpty || kind == .rounding else { return }
        let op = ShapeFactory.operation(kind, shapes: shapes, project: project, library: library.tools)
        project.addOperation(op)
        workspace.selection = [.operation(op.id)]
    }
}

/// Sensible starting shapes and operations, sized to the stock.
enum ShapeFactory {
    static func center(_ p: Project) -> Vec2 { Vec2(p.stock.width / 2, p.stock.height / 2) }
    static func size(_ p: Project, _ fraction: Double) -> Double { min(p.stock.width, p.stock.height) * fraction }

    static func rectangle(_ p: Project) -> DesignShape {
        DesignShape(kind: .rectangle(width: size(p, 0.5), height: size(p, 0.3), cornerRadius: 0), position: center(p))
    }
    static func circle(_ p: Project) -> DesignShape {
        DesignShape(kind: .circle(radius: size(p, 0.15)), position: center(p))
    }
    /// Two starts, four turns over most of the blank's length, climbing the sheet's full height each turn.
    static func spiral(_ p: Project) -> DesignShape {
        let length = p.stock.width * 0.8
        return DesignShape(kind: .spiral(SpiralSpec(starts: 2, pitch: length / 4, length: length, around: p.stock.height)), position: center(p))
    }
    static func ellipse(_ p: Project) -> DesignShape {
        DesignShape(kind: .ellipse(radiusX: size(p, 0.25), radiusY: size(p, 0.15)), position: center(p))
    }
    static func polygon(_ p: Project) -> DesignShape {
        DesignShape(kind: .polygon(sides: 6, radius: size(p, 0.15)), position: center(p))
    }
    static func star(_ p: Project) -> DesignShape {
        DesignShape(kind: .star(points: 5, outerRadius: size(p, 0.2), innerRadius: size(p, 0.08)), position: center(p))
    }
    static func text(_ p: Project) -> DesignShape {
        DesignShape(kind: .text(TextSpec(string: "Text", capHeight: size(p, 0.15))), position: center(p))
    }

    static func operation(_ kind: AddOperationMenu.Kind, shapes: [UUID], project: Project, library: [Tool]) -> CAMOperation {
        func pick(_ match: (Tool) -> Bool, _ fallback: Int) -> Tool {
            library.first(where: match) ?? ToolLibrary.starter.tool(number: fallback)!
        }
        let endMill = pick({ $0.shape == .flatEndMill }, 1)
        let vBit = pick({ $0.shape == .vBit }, 5)
        let t = project.stock.thickness
        // Through cuts on a flat sheet follow its thickness (a rotary job's thickness is the blank's radius).
        let flat = project.stock.rotary == nil
        switch kind {
        case .profile:
            return CAMOperation(name: "Profile", kind: .profile(ProfileParams(
                side: .outside, direction: .climb, depth: flat ? .through(t) : DepthSettings(cutDepth: t + 0.02.inch),
                tabs: TabSettings(enabled: true), entry: EntrySettings(kind: .ramp))), shapeIDs: shapes, tool: endMill)
        case .edgeProfile:
            // The library's first form bit an edge profile takes, or else a 1/4" roundover kept in the project, numbered
            // clear of the library's bits and the project's.
            let params = EdgeProfileParams()
            let kind = OperationKind.edgeProfile(params)
            var bit = library.first { $0.shape == .form && kind.refusal(for: $0) == nil }
                ?? project.operations.map(\.tool).first { $0.shape == .form && kind.refusal(for: $0) == nil }
            if bit == nil {
                var t = ToolLibrary.template(for: .form)
                t.name = "1/4\" Roundover"
                let taken = Set(library.map(\.number) + project.operations.map(\.tool.number))
                t.number = (1...).first { !taken.contains($0) }!
                bit = t
            }
            return CAMOperation(name: "Edge Profile", kind: kind, shapeIDs: shapes, tool: bit!)
        case .pocket:
            return CAMOperation(name: "Pocket", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: min(0.25.inch, t / 2)))),
                                shapeIDs: shapes, tool: endMill)
        case .drill:
            return CAMOperation(name: "Drill", kind: .drill(DrillParams(depth: t + 0.02.inch, peckDepth: endMill.diameter,
                                                                        fromBottom: flat ? -MaterialDepth.defaultOvercut : nil)),
                                shapeIDs: shapes, tool: endMill)
        case .vcarve:
            return CAMOperation(name: "V-carve", kind: .vcarve(VCarveParams()), shapeIDs: shapes, tool: vBit)
        case .chamfer:
            // A 90° bit for 45° bevels. On shapes a profile already cuts, bevel the edge it leaves (the part's top edge
            // before an outside cut-out, a hole's rim with an inside one); otherwise the vector is the bevel's top.
            let bit = pick({ $0.shape == .vBit && abs($0.includedAngle - 90) < 0.5 }, 6)
            let cutBy = project.operations.compactMap { op -> CutSide? in
                guard op.enabled, case let .profile(p) = op.kind, p.side != .on, !Set(op.shapeIDs).isDisjoint(with: shapes) else { return nil }
                return p.side
            }.first
            var params = ChamferParams()
            if let side = cutBy {
                params.side = side == .outside ? .inside : .outside
                params.edge = .bottom
            }
            return CAMOperation(name: "Chamfer", kind: .chamfer(params), shapeIDs: shapes, tool: bit)
        case .fluting:
            let ball = pick({ $0.shape == .ballNose }, 7)
            // With a 3D model among the selected shapes, the flutes follow its surface and the other shapes are the flutes.
            let model = project.shapes.first { shapes.contains($0.id) && $0.modelSpec != nil && !$0.isKeepOut }
            var params = FlutingParams(depth: min(0.125.inch, t / 2))
            params.surfaceModelID = model?.id
            return CAMOperation(name: "Fluting", kind: .fluting(params), shapeIDs: shapes.filter { $0 != model?.id }, tool: ball)
        case .prism:
            let bit = pick({ $0.shape == .vBit && abs($0.includedAngle - 90) < 0.5 }, 6)
            return CAMOperation(name: "Prism", kind: .prism(PrismParams()), shapeIDs: shapes, tool: bit)
        case .rough3D:
            let (ids, boundary) = modelBoundary(shapes, project: project)
            return CAMOperation(name: "3D Roughing", kind: .rough3D(Rough3DParams(boundary: boundary)), shapeIDs: ids, tool: endMill)
        case .finish3D:
            let ball = pick({ $0.shape == .ballNose }, 7)
            let (ids, boundary) = modelBoundary(shapes, project: project)
            return CAMOperation(name: "3D Finishing", kind: .finish3D(Finish3DParams(boundary: boundary)), shapeIDs: ids, tool: ball)
        case .moulding:
            let ball = pick({ $0.shape == .ballNose }, 7)
            return moulding(shapes, project: project, ball: ball, endMill: endMill)
        case .rounding:
            return CAMOperation(name: "Rounding", kind: .rounding(RoundingParams()), shapeIDs: [], tool: endMill)
        case .rotaryFinish:
            let ball = pick({ $0.shape == .ballNose }, 7)
            let models = shapes.filter { project.shape(id: $0)?.modelSpec != nil }
            return CAMOperation(name: "3D Rotary Finishing", kind: .rotaryFinish(RotaryFinishParams()),
                                shapeIDs: models.isEmpty ? shapes : models, tool: ball)
        case .rotaryRough:
            let models = shapes.filter { project.shape(id: $0)?.modelSpec != nil }
            return CAMOperation(name: "3D Rotary Roughing", kind: .rotaryRough(RotaryRoughParams()),
                                shapeIDs: models.isEmpty ? shapes : models, tool: endMill)
        }
    }

    /// A moulding on the selection: the smallest open vector is the profile (the one drawn as a cross-section), the other
    /// vectors are rails. It roughs with an end mill and finishes with a ball nose, along the rail where it can.
    static func moulding(_ selected: [UUID], project: Project, ball: Tool, endMill: Tool) -> CAMOperation {
        let vectors = selected.compactMap { project.shape(id: $0) }.filter { $0.modelSpec == nil }
        let open = vectors.filter { s in
            let lines = s.polylines(tolerance: 0.05)
            return lines.count == 1 && !lines[0].isClosed
        }
        func size(_ s: DesignShape) -> Double { let b = s.bounds; return b.width * b.width + b.height * b.height }
        let profile = vectors.count > 1 ? open.min { size($0) < size($1) } : nil
        let rails = vectors.filter { $0.id != profile?.id }
        let finish = MouldingParams.suggestedFinish(rails: rails.flatMap { $0.polylines(tolerance: 0.05) })
        let params = MouldingParams(profileID: profile?.id ?? UUID(), finish: finish, roughing: MouldingRoughing(tool: endMill))
        return CAMOperation(name: "Moulding", kind: .moulding(params),
                            shapeIDs: (profile.map { [$0.id] } ?? []) + rails.map(\.id), tool: ball)
    }

    /// Picks the 3D machining boundary: vectors selected with the model, or else the cut-out (an outside profile's
    /// closed vector that surrounds the model) so 3D work doesn't machine scrap. Falls back to the model outline.
    static func modelBoundary(_ selected: [UUID], project: Project) -> (ids: [UUID], boundary: ModelBoundary) {
        let shapes = selected.compactMap { project.shape(id: $0) }
        let models = shapes.filter { $0.modelSpec != nil }
        guard !models.isEmpty else { return (selected, .model) }
        if shapes.contains(where: { $0.modelSpec == nil }) { return (selected, .vectors) }
        let modelBounds = models.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
        let cutOuts = project.operations.compactMap { op -> [UUID]? in
            guard op.enabled, case let .profile(p) = op.kind, p.side == .outside else { return nil }
            return op.shapeIDs
        }.flatMap { $0 }
        let surrounding = cutOuts.filter { id in
            guard let s = project.shape(id: id), s.modelSpec == nil else { return false }
            let b = s.bounds
            return b.contains(modelBounds.min) && b.contains(modelBounds.max)
        }
        return surrounding.isEmpty ? (selected, .model) : (selected + Array(Set(surrounding)), .vectors)
    }
}

// MARK: Inspector-style cards

/// A section title styled like the grouped form beside the list: the inspector's small grey headers, or (`prominent`)
/// the bold headers a grouped form uses in a regular window such as the Tool Library.
struct SectionTitle: View {
    let title: String
    var prominent = false
    init(_ title: String, prominent: Bool = false) {
        self.title = title
        self.prominent = prominent
    }
    var body: some View {
        Text(title)
            .font(prominent ? .headline : nil)
            .foregroundStyle(prominent ? .primary : .secondary)
            .padding(.leading, 6)
    }
}

/// The hint shown in an empty section, inset like the rows' text and wrapping instead of truncating.
struct Placeholder: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .lineLimit(1...3).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 6)
            .cardRow(0, of: 1)
            .selectionDisabled()
    }
}

/// One row's slice of a grouped card, drawn like the inspector's `.formStyle(.grouped)` sections (same system fill,
/// corner radius, margins and inset separators), so the sidebar and the inspector read as one design.
struct CardRowBackground: View {
    var isFirst: Bool
    var isLast: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        let r: CGFloat = 10
        UnevenRoundedRectangle(topLeadingRadius: isFirst ? r : 0, bottomLeadingRadius: isLast ? r : 0,
                               bottomTrailingRadius: isLast ? r : 0, topTrailingRadius: isFirst ? r : 0, style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill))
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)).padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 10)
    }
}

extension View {
    /// Places a list row in an inspector-style card: `index` of `count` rows decides the rounded corners.
    func cardRow(_ index: Int, of count: Int) -> some View {
        // 29 pt of content plus the list's own row insets gives the inspector's 37 pt rows.
        padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
            .listRowBackground(CardRowBackground(isFirst: index == 0, isLast: index == count - 1))
            .listRowSeparator(.hidden)
    }
}

/// The eye on a toolpath or group row: hides or shows its lines in the 3D view. Display only: a hidden toolpath still
/// cuts, simulates and exports.
struct EyeButton: View {
    var hidden: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .foregroundStyle(hidden ? .tertiary : .secondary)
        }
        .buttonStyle(.borderless)
        .help(hidden ? "Show in the 3D view (still cut and exported while hidden)" : "Hide in the 3D view (still cut and exported)")
    }
}
