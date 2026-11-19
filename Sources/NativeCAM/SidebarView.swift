import CAMCore
import SwiftUI

struct SidebarView: View {
    @Binding var project: Project
    @Bindable var workspace: Workspace
    @Environment(ToolLibraryStore.self) private var library

    var body: some View {
        List(selection: $workspace.selection) {
            Section("Job Setup") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Material & Machine")
                        Text("\(fmt(project.stock.width)) × \(fmt(project.stock.height)) × \(fmt(project.stock.thickness)) \(project.displayUnits.symbol)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "shippingbox") }
                .tag(SidebarItem.setup)
            }

            Section {
                ForEach(project.shapes) { shape in
                    Label(shape.name, systemImage: icon(for: shape.kind))
                        .tag(SidebarItem.shape(shape.id))
                        .contextMenu {
                            Button("Duplicate") { duplicate(shape) }
                            Button("Delete", role: .destructive) { delete(shapes: [shape.id]) }
                        }
                }
                .onMove { project.shapes.move(fromOffsets: $0, toOffset: $1) }
                if project.shapes.isEmpty {
                    Text("Add a shape or import DXF/SVG vectors.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Design")
                    Spacer()
                    Menu {
                        AddShapeMenu(project: $project, workspace: workspace)
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
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
                                Text("T\(op.tool.number) \(op.tool.name)").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: icon(for: op.kind)) }
                        Spacer()
                        Toggle("", isOn: Binding(get: { op.enabled }, set: { project.operations[index].enabled = $0 }))
                            .labelsHidden().toggleStyle(.checkbox)
                            .help("Include in output")
                    }
                    .tag(SidebarItem.operation(op.id))
                    .contextMenu {
                        Button("Duplicate") { duplicate(op) }
                        Button("Delete", role: .destructive) { delete(operation: op.id) }
                    }
                }
                .onMove { project.operations.move(fromOffsets: $0, toOffset: $1) }
                if project.operations.isEmpty {
                    Text("Select shapes, then add a toolpath.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Toolpaths (run order)")
                    Spacer()
                    Menu {
                        AddOperationMenu(project: $project, workspace: workspace, library: library)
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }

            if let issues = workspace.job?.issues, !issues.isEmpty {
                Section("Checks") {
                    ForEach(issues) { issue in
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
                    }
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
            Button("V-Carve") { add(.vcarve) }
            Divider()
            Button("3D Roughing") { add(.rough3D) }
            Button("3D Finishing") { add(.finish3D) }
        }
        .disabled(selected.isEmpty)
        if selected.isEmpty {
            Divider()
            Text("Select shapes in the Design list first")
        }
    }

    enum Kind { case profile, pocket, drill, vcarve, rough3D, finish3D }

    private func add(_ kind: Kind) {
        let shapes = workspace.selectedShapeIDs
        guard !shapes.isEmpty else { return }
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
            return CAMOperation(name: "V-Carve", kind: .vcarve(VCarveParams()), shapeIDs: shapes, tool: vBit)
        case .rough3D:
            return CAMOperation(name: "3D Roughing", kind: .rough3D(Rough3DParams()), shapeIDs: shapes, tool: endMill)
        case .finish3D:
            let ball = pick({ $0.shape == .ballNose }, 7)
            return CAMOperation(name: "3D Finishing", kind: .finish3D(Finish3DParams()), shapeIDs: shapes, tool: ball)
        }
    }
}
