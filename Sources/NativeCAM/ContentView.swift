import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var document: NativeCAMDocument
    @State private var workspace: Workspace
    @State private var canvas: CanvasController
    @State private var showInspector = true
    @State private var isDropTargeted = false
    @State private var alert: AlertInfo?
    @Environment(ToolLibraryStore.self) private var library
    @Environment(\.openWindow) private var openWindow

    private var project: Project { document.project }

    init(document: Binding<NativeCAMDocument>) {
        _document = document
        let ws = Workspace()
        _workspace = State(initialValue: ws)
        let canvas = CanvasController(project: document.project, workspace: ws)
        canvas.setView = { ws.viewPreset = $0 }
        canvas.fit = { ws.fitRequest += 1 }
        _canvas = State(initialValue: canvas)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(project: $document.project, workspace: workspace)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    MetalViewport(scene: workspace.viewportScene(project),
                                  preset: Binding(get: { workspace.viewPreset }, set: { workspace.viewPreset = $0 }),
                                  fitRequest: workspace.fitRequest,
                                  interaction: canvas)
                    ViewportOverlay(workspace: workspace, project: project)
                        .padding(10)
                    if project.shapes.isEmpty && !workspace.isSimulating {
                        EmptyCanvasHint(project: $document.project, workspace: workspace, importAction: importVectors)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if isDropTargeted {
                        DropTargetOverlay()
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
                SimulationBar(workspace: workspace, project: project)
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(project: $document.project, workspace: workspace)
                .inspectorColumnWidth(min: 300, ideal: 330, max: 460)
        }
        .toolbar(id: "nativecam.main") { toolbarContent }
        .toolbarRole(.editor)
        .navigationSubtitle(subtitle)
        .focusedSceneValue(\.workspaceActions, actions)
        .onAppear {
            workspace.regenerate(project, debounce: false)
            workspace.viewPreset = .iso
        }
        .onChange(of: document.project) { _, new in
            workspace.rebuildVectorLines(new) // outlines follow edits instantly; toolpaths catch up in the background
            workspace.regenerate(new)
        }
        .onChange(of: workspace.selection) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showVectors) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showToolpaths) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showRapids) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showToolpathsWhileSimulating) { _, _ in workspace.rebuildLines(project) }
        .onReceive(NotificationCenter.default.publisher(for: DebugCapture.command)) { handleDebug($0.userInfo ?? [:]) }
        .alert(item: $alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
    }

    private var subtitle: String {
        let m = project.machine
        return "\(m.model.shortName) · \(project.displayUnits.format(project.stock.thickness, decimals: 3)) \(project.displayUnits.symbol) \(project.stock.materialName)"
    }

    /// Customizable (right-click the toolbar ▸ Customize Toolbar…), like other document apps.
    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "add-shape", placement: .navigation) {
            Menu {
                AddShapeMenu(project: $document.project, workspace: workspace)
            } label: {
                Label("Add Shape", systemImage: "square.on.circle")
            }
            .help("Draw a rectangle, circle, polygon, star or text")
        }
        ToolbarItem(id: "import", placement: .navigation) {
            Button { importVectors() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Import vectors (DXF, SVG, PDF, AI) or 3D models (STL, OBJ, 3MF, USDZ) — ⌘I, or drop files on the canvas")
        }
        ToolbarItem(id: "add-toolpath", placement: .primaryAction) {
            Menu {
                AddOperationMenu(project: $document.project, workspace: workspace, library: library)
            } label: {
                Label("Add Toolpath", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Create a profile, pocket, drill or V-carve toolpath from the selected shapes")
        }
        ToolbarItem(id: "simulate", placement: .primaryAction) {
            Button { simulate() } label: { Label("Simulate", systemImage: "play") }
                .help("Simulate material removal (⌘R)")
                .disabled(workspace.job?.toolpaths.isEmpty ?? true)
        }
        ToolbarItem(id: "export", placement: .primaryAction) {
            Button { exportGCode() } label: { Label("Export G-code", systemImage: "square.and.arrow.up") }
                .help("Save a .tap file for Mach4 (⌘E)")
                .disabled(workspace.job?.toolpaths.isEmpty ?? true)
        }
        ToolbarItem(id: "tools", placement: .primaryAction) {
            Button { openWindow(id: "tool-library") } label: { Label("Tool Library", systemImage: "wrench.and.screwdriver") }
                .help("Open the tool library (⇧⌘T)")
        }
        ToolbarItem(id: "inspector", placement: .primaryAction) {
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    // MARK: Actions

    private var actions: WorkspaceActions {
        WorkspaceActions(
            importVectors: importVectors,
            simulateGCodeFile: simulateGCodeFile,
            exportGCode: exportGCode,
            regenerate: { workspace.regenerate(project, debounce: false) },
            simulate: simulate,
            stopSimulation: { workspace.stopSimulation(project) },
            optimizeOrder: optimizeOrder,
            setView: { workspace.viewPreset = $0 },
            fit: { workspace.fitRequest += 1 },
            duplicate: { canvas.viewportPerform(.duplicate) },
            canDuplicate: !workspace.selectedShapeIDs.isEmpty,
            toggleInspector: { showInspector.toggle() },
            inspectorShown: showInspector
        )
    }

    /// Developer capture hook (see DebugCapture): put the window in a given state.
    private func handleDebug(_ info: [AnyHashable: Any]) {
        if let sel = info["select"] as? String {
            let parts = sel.split(separator: ":")
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            switch parts.first {
            case "op" where index < project.operations.count: workspace.selection = [.operation(project.operations[index].id)]
            case "shape" where index < project.shapes.count: workspace.selection = [.shape(project.shapes[index].id)]
            case "none": workspace.selection = []
            default: workspace.selection = [.setup]
            }
        }
        if let sim = info["simulate"] as? String {
            if sim == "stop" {
                workspace.stopSimulation(project)
            } else {
                workspace.startSimulation(project)
                workspace.isPlaying = false
                workspace.seek(to: workspace.simDuration * (Double(sim) ?? 1))
            }
        }
        if let v = info["view"] as? String, let preset = ViewPreset(rawValue: v) { workspace.viewPreset = preset }
        if info["tools"] != nil { openWindow(id: "tool-library") }
        if let path = info["import"] as? String { importFiles([URL(fileURLWithPath: path)]) }
        if let i = info["inspector"] as? String { showInspector = i != "hide" }
        if info["optimize"] != nil { optimizeOrder() }
    }

    // MARK: Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in openDropped(url) }
            }
        }
        return accepted
    }

    private func openDropped(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.importExtensions.contains(ext) {
            importFiles([url])
            return
        }
        switch ext {
        case "tap", "nc", "gcode", "ngc", "cnc", "txt":
            simulateFile(url)
        case "nativecam":
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        default:
            NSSound.beep()
        }
    }

    private func simulate() {
        workspace.startSimulation(project)
    }

    /// One document change, so a single ⌘Z puts the old order back.
    private func optimizeOrder() {
        let r = OperationScheduler.optimize(project)
        guard r.changed else {
            let n = r.toolChangesBefore
            alert = AlertInfo(title: "Run order is already optimal",
                              message: n == 0 ? "Every toolpath uses the same tool, so there are no tool changes to save."
                                : "This job has \(n) tool change\(n == 1 ? "" : "s"). Fewer would mean cutting a part free "
                                + "before the work inside it, or swapping the order of toolpaths that overlap.")
            return
        }
        document.project.applyRunOrder(r.order)
    }

    private func importVectors() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.importExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Choose vectors (DXF, SVG, PDF, AI) or 3D models (STL, OBJ, 3MF, USDZ, PLY) to import"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    static let vectorExtensions = ["dxf", "svg", "pdf", "ai"]
    static var importExtensions: [String] { vectorExtensions + ModelImporter.supportedExtensions }

    private func importFiles(_ urls: [URL]) {
        var added: [UUID] = []
        var warnings: [String] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            do {
                if ModelImporter.supportedExtensions.contains(ext) {
                    let result = try ModelImporter.importFile(at: url)
                    warnings.append(contentsOf: result.warnings.map { "\(url.lastPathComponent): \($0)" })
                    let shape = ShapeFactory.model(result, name: name, stock: project.stock)
                    document.project.shapes.append(shape)
                    added.append(shape.id)
                } else {
                    let result = try VectorImporter.importFile(at: url, tolerance: 0.01)
                    warnings.append(contentsOf: result.warnings.map { "\(url.lastPathComponent): \($0)" })
                    let shapes = ShapeFactory.imported(result.polylines, points: result.points, name: name, stock: project.stock)
                    if shapes.isEmpty { warnings.append("\(url.lastPathComponent): no usable vectors found.") }
                    document.project.shapes.append(contentsOf: shapes)
                    added.append(contentsOf: shapes.map(\.id))
                }
            } catch {
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !added.isEmpty { workspace.selection = Set(added.map { .shape($0) }) }
        if !warnings.isEmpty {
            alert = AlertInfo(title: "Import notes", message: warnings.prefix(12).joined(separator: "\n"))
        }
    }

    private func simulateGCodeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gcodeTap, .plainText] + ["nc", "gcode", "ngc", "cnc"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a G-code file to simulate with this project's material and tool library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        simulateFile(url)
    }

    private func simulateFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let program = try GCodeParser.parse(text)
            let fallback = library.tools.first ?? ToolLibrary.starter.tools[0]
            let tps = program.toolpaths(tools: library.tools, stock: project.stock, fallback: fallback)
            workspace.simulateProgram(tps, name: url.lastPathComponent, project: project)
            if !program.warnings.isEmpty {
                alert = AlertInfo(title: "G-code notes", message: program.warnings.joined(separator: "\n"))
            }
        } catch {
            alert = AlertInfo(title: "Couldn't read G-code", message: error.localizedDescription)
        }
    }

    private func exportGCode() {
        guard let job = workspace.job, !job.toolpaths.isEmpty else { return }
        if job.hasErrors {
            let errors = job.issues.filter { $0.severity == .error }.map { "• \($0.operation.map { "\($0): " } ?? "")\($0.message)" }
            let confirm = NSAlert()
            confirm.messageText = "This job has errors"
            confirm.informativeText = errors.joined(separator: "\n") + "\n\nExport anyway?"
            confirm.addButton(withTitle: "Cancel")
            confirm.addButton(withTitle: "Export Anyway")
            confirm.alertStyle = .critical
            guard confirm.runModal() == .alertSecondButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gcodeTap]
        panel.nameFieldStringValue = (project.name.isEmpty ? "Untitled" : project.name) + ".tap"
        panel.message = "Save G-code for Avid Mach4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let gcode = AvidMach4Post(project: project).post(job.toolpaths)
        do {
            try gcode.data(using: .ascii, allowLossyConversion: true)?.write(to: url)
        } catch {
            alert = AlertInfo(title: "Couldn't save G-code", message: error.localizedDescription)
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// View controls floating over the 3D view.
struct ViewportOverlay: View {
    @Bindable var workspace: Workspace
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Picker("View", selection: Binding(get: { workspace.viewPreset ?? .iso }, set: { workspace.viewPreset = $0 })) {
                ForEach(ViewPreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Button { workspace.fitRequest += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to fit (⌘0)")
            Menu {
                Toggle("Vectors", isOn: $workspace.showVectors)
                Toggle("Toolpaths", isOn: $workspace.showToolpaths)
                Toggle("Rapid Moves", isOn: $workspace.showRapids)
                Toggle("3D Model Preview", isOn: $workspace.showModelPreview)
                Divider()
                Toggle("Toolpaths While Simulating", isOn: $workspace.showToolpathsWhileSimulating)
            } label: {
                Label("Show", systemImage: "eye")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose what the canvas shows")
            if workspace.isGenerating {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }
        .controlSize(.small)
        .padding(6)
        .nativeGlass(cornerRadius: 10)
    }
}

/// Shown on an empty canvas: the two ways to get started.
struct EmptyCanvasHint: View {
    @Binding var project: Project
    let workspace: Workspace
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.on.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Vectors Yet").font(.title3.weight(.semibold))
            Text("Draw a shape or add text, or drop DXF, SVG, PDF or 3D model files here.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Menu("Add Shape") { AddShapeMenu(project: $project, workspace: workspace) }
                    .fixedSize()
                Button("Import…", action: importAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .nativeGlass(cornerRadius: 18)
    }
}

/// Highlight shown while files are dragged over the canvas.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding(6)
            Label("Drop vectors or 3D models to import, or a .tap file to simulate", systemImage: "arrow.down.doc")
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .nativeGlass(cornerRadius: 12)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Liquid Glass on macOS 26, a regular material before that.
    @ViewBuilder
    func nativeGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
