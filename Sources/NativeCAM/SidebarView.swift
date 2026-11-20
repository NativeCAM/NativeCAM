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
                    Label(shape.name, systemImage: shape.isKeepOut ? "exclamationmark.shield" : icon(for: shape.kind))
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
                ForEach(Array(project.operations.enumerated()), id: \.element.id) { index, op in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(simd: workspace.colorForOperation(index)))
                            .frame(width: 8, height: 8)
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(op.name).foregroundStyle(op.enabled ? .primary : .secondary)
                                // A clearance tool cuts first: "T10, then T2 1/8" Upcut End Mill".
                                Text("\(op.clearanceTool.map { "T\($0.number), then " } ?? "")T\(op.tool.number) \(op.tool.name)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: icon(for: op.kind)) }
                        Spacer()
                        Toggle("", isOn: Binding(get: { op.enabled }, set: { project.operations[index].enabled = $0 }))
                            .labelsHidden().toggleStyle(.checkbox)
                            .help("Include in output")
                    }
                    .tag(SidebarItem.operation(op.id))
                    .cardRow(index, of: project.operations.count)
                    .contextMenu {
                        Button("Duplicate") { duplicate(op) }
                        Button("Delete", role: .destructive) { delete(operation: op.id) }
                    }
                }
                .onMove { project.operations.move(fromOffsets: $0, toOffset: $1) }
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
        case .chamfer: "skew"
        case .fluting: "line.diagonal"
        case .prism: "triangle"
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
        project.operations.append(copy)
        workspace.selection = [.operation(copy.id)]
    }

    private func delete(shapes ids: Set<UUID>) {
        project.shapes.removeAll { ids.contains($0.id) }
        for i in project.operations.indices { project.operations[i].shapeIDs.removeAll { ids.contains($0) } }
        workspace.selection = [.setup]
    }

    private func delete(operation id: UUID) {
        project.operations.removeAll { $0.id == id }
        workspace.selection = [.setup]
    }

    private func deleteSelection() {
        let shapeIDs = Set(workspace.selectedShapeIDs)
        if !shapeIDs.isEmpty { delete(shapes: shapeIDs) }
        if let op = workspace.selectedOperationID { delete(operation: op) }
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
        Button("Rectangle") { add(ShapeFactory.rectangle(project)) }
        Button("Circle") { add(ShapeFactory.circle(project)) }
        Button("Ellipse") { add(ShapeFactory.ellipse(project)) }
        Button("Polygon") { add(ShapeFactory.polygon(project)) }
        Button("Star") { add(ShapeFactory.star(project)) }
        Divider()
        Button("Text") { add(ShapeFactory.text(project)) }
        if project.stock.rotary?.isWrapped == true {
            Button("Spiral") { add(ShapeFactory.spiral(project)) }
                .help("Spiral lines that wrap around the blank, for a rope or barley twist")
        }
    }

    private func add(_ shape: DesignShape) {
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
            Button("Pocket") { add(.pocket) }
            Button("Drill") { add(.drill) }
            Button("V-carve") { add(.vcarve) }
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
            } else {
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

    enum Kind { case profile, pocket, drill, vcarve, chamfer, fluting, prism, rough3D, finish3D, rounding, rotaryFinish }

    private func add(_ kind: Kind) {
        let shapes = kind == .rounding ? [] : workspace.selectedShapeIDs
        guard !shapes.isEmpty || kind == .rounding else { return }
        let op = ShapeFactory.operation(kind, shapes: shapes, project: project, library: library.tools)
        project.operations.append(op)
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

    /// Imported vectors keep their file coordinates when they fit on the stock, otherwise they're centred.
    /// DXF POINT entities become a separate shape of small circles, ready for a Drill toolpath, aligned with the vectors.
    static func imported(_ polylines: [Polyline], points: [Vec2] = [], name: String, stock: Stock) -> [DesignShape] {
        let marks = points.map { Polyline(Curves.circle(center: $0, radius: 0.5, tolerance: 0.01), closed: true) }
        let all = polylines + marks
        guard !all.isEmpty else { return [] }
        let b = all.bounds
        let fits = stock.bounds.insetBy(-0.001).contains(b.min) && stock.bounds.insetBy(-0.001).contains(b.max)
        let shift = fits ? Vec2.zero : Vec2(stock.width / 2, stock.height / 2) - b.center
        func place(_ polys: [Polyline], _ name: String) -> DesignShape? {
            guard !polys.isEmpty else { return nil }
            let c = polys.bounds.center
            return DesignShape(name: name, kind: .paths(polys.transformed(.translation(-c))), position: c + shift)
        }
        return [place(polylines, name), place(marks, "\(name) points")].compactMap { $0 }
    }

    /// A placed 3D model: centred on the material, scaled down to fit if needed, carved no deeper than the material.
    static func model(_ result: MeshImportResult, name: String, stock: Stock) -> DesignShape {
        let spec = ModelSpec(mesh: result.mesh, upAxis: result.suggestedUpAxis, depth: 1)
        let size = spec.naturalSize
        var scale = 1.0
        if size.x > 0, size.y > 0 {
            scale = min(1, stock.width * 0.9 / size.x, stock.height * 0.9 / size.y)
        }
        var s = spec
        s.depth = max(0.1, min(spec.proportionalDepth(scale: scale), stock.thickness - 0.02.inch))
        return DesignShape(name: name, kind: .model(s), position: Vec2(stock.width / 2, stock.height / 2), scale: scale)
    }

    static func operation(_ kind: AddOperationMenu.Kind, shapes: [UUID], project: Project, library: [Tool]) -> CAMOperation {
        func pick(_ match: (Tool) -> Bool, _ fallback: Int) -> Tool {
            library.first(where: match) ?? ToolLibrary.starter.tool(number: fallback)!
        }
        let endMill = pick({ $0.shape == .flatEndMill }, 1)
        let vBit = pick({ $0.shape == .vBit }, 5)
        let t = project.stock.thickness
        switch kind {
        case .profile:
            return CAMOperation(name: "Profile", kind: .profile(ProfileParams(
                side: .outside, direction: .climb, depth: DepthSettings(cutDepth: t + 0.02.inch),
                tabs: TabSettings(enabled: true), entry: EntrySettings(kind: .ramp))), shapeIDs: shapes, tool: endMill)
        case .pocket:
            return CAMOperation(name: "Pocket", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: min(0.25.inch, t / 2)))),
                                shapeIDs: shapes, tool: endMill)
        case .drill:
            return CAMOperation(name: "Drill", kind: .drill(DrillParams(depth: t + 0.02.inch, peckDepth: endMill.diameter)),
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
            return CAMOperation(name: "Fluting", kind: .fluting(FlutingParams(depth: min(0.125.inch, t / 2))), shapeIDs: shapes, tool: ball)
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
        case .rounding:
            return CAMOperation(name: "Rounding", kind: .rounding(RoundingParams()), shapeIDs: [], tool: endMill)
        case .rotaryFinish:
            let ball = pick({ $0.shape == .ballNose }, 7)
            let models = shapes.filter { project.shape(id: $0)?.modelSpec != nil }
            return CAMOperation(name: "3D Rotary Finishing", kind: .rotaryFinish(RotaryFinishParams()),
                                shapeIDs: models.isEmpty ? shapes : models, tool: ball)
        }
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
