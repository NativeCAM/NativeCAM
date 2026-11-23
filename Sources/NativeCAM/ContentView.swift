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
    @State private var debugSetup: DebugSetup?
    @State private var debugPost: DebugPost?
    @State private var pendingTemplate: PendingTemplate?
    @State private var nesting: NestRequest?
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
        .onChange(of: workspace.selection) { _, _ in
            // A shape picked in the sidebar on another sheet shows that sheet.
            if let id = workspace.selectedShapeIDs.first, let shape = project.shape(id: id), !workspace.isShown(shape, in: project) {
                workspace.show(sheet: project.sheetIndex(of: shape), project: project)
            }
            workspace.rebuildLines(project)
        }
        .onChange(of: workspace.showVectors) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showToolpaths) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showRapids) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showModelPreview) { _, _ in workspace.rebuildLines(project) }
        .onChange(of: workspace.showToolpathsWhileSimulating) { _, _ in workspace.rebuildLines(project) }
        .onReceive(NotificationCenter.default.publisher(for: DebugCapture.command)) { handleDebug($0.userInfo ?? [:]) }
        .sheet(item: $debugPost) { d in
            VectricPostSheet(pp: d.pp, machine: project.machine, applied: false) { _ in }
        }
        .sheet(item: $debugSetup) { d in
            MachineSetupView(offerUseHere: true, start: (d.selection, d.step)) { _, _, _ in }
        }
        .sheet(item: $pendingTemplate) { pending in
            ApplyTemplateSheet(template: pending.template, project: project, library: ToolLibrary(tools: library.tools),
                               selection: pending.selection) { result, addTools in
                finishApplying(result, addTools: addTools)
            }
        }
        .sheet(item: $nesting) { request in
            NestPartsSheet(session: request.session) { applied in finishNesting(applied) }
        }
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
                .help("Save G-code for the machine (⌘E)")
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
            exportAirCut: exportAirCut,
            exportSetupSheet: exportSetupSheet,
            regenerate: recalculateAll,
            simulate: simulate,
            stopSimulation: { workspace.stopSimulation(project) },
            optimizeOrder: optimizeOrder,
            nestParts: nestParts,
            canNest: !project.shapes.isEmpty && !workspace.isSimulating,
            saveTemplate: saveTemplate,
            applyTemplate: applyTemplate,
            chooseTemplate: chooseTemplate,
            hasToolpaths: !project.operations.isEmpty,
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
        if info["nest"] != nil { nestParts() }
        if let path = info["vectricpp"] as? String, let text = try? String(contentsOfFile: path, encoding: .utf8),
           let pp = try? VectricPost.parse(text) {
            debugPost = DebugPost(pp: pp)
        }
        if let setup = info["machinesetup"] as? String {
            // "sienci-altmill-4x4:summary" opens the setup assistant on that machine at that step.
            let parts = setup.split(separator: ":").map(String.init)
            let step = parts.count > 1 ? MachineSetupView.Step.allCases.first { "\($0)" == parts[1] } ?? .machine : .machine
            debugSetup = DebugSetup(selection: parts.first ?? "generic", step: step)
        }
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
        case "tap", "nc", "gcode", "ngc", "cnc", "txt", "sbp":
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

    /// Toolpaths ▸ Nest Parts…: the selected parts (or every part), nested in a sheet with a preview; nothing moves
    /// until Apply.
    private func nestParts() {
        if project.stock.rotary != nil {
            alert = AlertInfo(title: "Can't nest a rotary job", message: NestJob.Refusal.rotary.localizedDescription
                + " Nest the parts in a flat job, then copy them over.")
            return
        }
        nesting = NestRequest(session: NestSession(project: project, selection: Set(workspace.selectedShapeIDs)))
    }

    /// One document change, so a single ⌘Z puts every part back where it was.
    private func finishNesting(_ outcome: Result<NestJob.Applied, NestCheckFailure>) {
        let applied: NestJob.Applied
        switch outcome {
        case let .success(a): applied = a
        case let .failure(failure):
            alert = AlertInfo(title: "Nothing was moved",
                              message: "The layout didn't pass the final check, so the parts stay where they were: "
                                + failure.problems.prefix(4).joined(separator: " ") + " Please report this.")
            return
        }
        document.project = applied.project
        workspace.show(sheet: min(workspace.sheet, applied.sheetCount - 1), project: applied.project)
        if !applied.movedAside.isEmpty {
            alert = AlertInfo(title: "Some parts didn't fit",
                              message: "Moved beside the sheet, where nested parts would otherwise cut into them: "
                                + applied.movedAside.joined(separator: ", ")
                                + ". Their toolpaths are off the material now: nest again with more sheets allowed, or turn the toolpaths off.")
        }
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
                    let shape = workspace.placedOnSheet(ShapeFactory.model(result, name: name, stock: workspace.shown(project).stock), of: project)
                    document.project.shapes.append(shape)
                    // On a rotary blank it lies along the axis, scaled to fit.
                    document.project.placeModelsOnBlank()
                    added.append(shape.id)
                } else {
                    let result = try VectorImporter.importFile(at: url, tolerance: 0.01)
                    warnings.append(contentsOf: result.warnings.map { "\(url.lastPathComponent): \($0)" })
                    let shapes = result.shapes(name: name, stock: workspace.shown(project).stock).map { workspace.placedOnSheet($0, of: project) }
                    if shapes.isEmpty { warnings.append("\(url.lastPathComponent): no usable vectors found.") }
                    document.project.shapes.append(contentsOf: shapes)
                    added.append(contentsOf: shapes.map(\.id))
                }
            } catch {
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !added.isEmpty {
            // Toolpaths that find their vectors by layer or kind pick up the new ones.
            var p = document.project
            if p.bindVectors() { document.project = p }
            workspace.selection = Set(added.map { .shape($0) })
        }
        if !warnings.isEmpty {
            alert = AlertInfo(title: "Import notes", message: warnings.prefix(12).joined(separator: "\n"))
        }
    }

    /// Toolpaths ▸ Recalculate All: toolpaths that find their vectors by layer or kind look again (one change, so ⌘Z
    /// puts the old shapes back), then everything is regenerated at once.
    private func recalculateAll() {
        var p = project
        if p.bindVectors() { document.project = p }
        workspace.regenerate(document.project, debounce: false)
    }

    // MARK: Templates

    private func saveTemplate() {
        let selected = project.operations.filter { workspace.selection.contains(.operation($0.id)) }.map(\.id)
        let options = TemplateSaveOptions(selectedCount: selected.count, totalCount: project.operations.count)
        let panel = NSSavePanel()
        panel.title = "Save Toolpaths as Template"
        panel.message = "Templates in this folder are listed under Toolpaths ▸ Apply Template."
        panel.prompt = "Save Template"
        panel.allowedContentTypes = [.nativecamTemplate]
        panel.directoryURL = TemplateLibrary.ensureFolder()
        panel.nameFieldStringValue = project.name
        let accessory = NSHostingView(rootView: TemplateSaveAccessory(options: options))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = options.offersSelection && options.onlySelected ? Set(selected) : nil
        let template = ToolpathTemplate(name: url.deletingPathExtension().lastPathComponent, project: project, operationIDs: ids,
                                        includeJobSetup: options.includeJobSetup)
        do {
            try template.encoded().write(to: url, options: .atomic)
            TemplateLibrary.shared.refresh()
        } catch {
            alert = AlertInfo(title: "Couldn't save the template", message: error.localizedDescription)
        }
    }

    private func chooseTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.nativecamTemplate]
        panel.directoryURL = TemplateLibrary.ensureFolder()
        panel.message = "Choose a toolpath template to add its toolpaths to this job"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyTemplate(url)
    }

    /// Reads a template and shows what it would add; nothing changes until Add Toolpaths.
    private func applyTemplate(_ url: URL) {
        do {
            let template = try ToolpathTemplate.decode(Data(contentsOf: url))
            pendingTemplate = PendingTemplate(template: template, selection: workspace.selectedShapeIDs)
        } catch {
            alert = AlertInfo(title: "Couldn't open “\(url.deletingPathExtension().lastPathComponent)”", message: error.localizedDescription)
        }
    }

    /// One document change, so a single ⌘Z takes the template's toolpaths (and job setup) off again.
    private func finishApplying(_ result: ToolpathTemplate.Application, addTools: Bool) {
        if addTools {
            let known = Set(library.tools.map(\.id))
            library.tools.append(contentsOf: result.newTools.filter { !known.contains($0.id) })
        }
        document.project = result.project
        if let first = result.addedOperationIDs.first { workspace.selection = [.operation(first)] }
    }

    private func simulateGCodeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gcodeTap, .plainText] + ["nc", "gcode", "ngc", "cnc", "sbp"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a G-code file to simulate with this project's material and tool library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        simulateFile(url)
    }

    private func simulateFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            // Tapping and boring cycles are read the way this project's controller runs them.
            let program = url.pathExtension.lowercased() == "sbp" ? OpenSBPParser.parse(text)
                : try GCodeParser.parse(text, controller: Dialect.for(project.machine))
            let fallback = library.tools.first ?? ToolLibrary.starter.tools[0]
            // Read in the project's frame, so a file for a rotary axis along Y lands on the design the right way round.
            let tps = program.toolpaths(tools: library.tools, frame: RotaryFrame(project), fallback: fallback)
            workspace.simulateProgram(tps, name: url.lastPathComponent, project: project)
            if !program.warnings.isEmpty {
                alert = AlertInfo(title: "G-code notes", message: program.warnings.joined(separator: "\n"))
            }
        } catch {
            alert = AlertInfo(title: "Couldn't read G-code", message: error.localizedDescription)
        }
    }

    private func exportGCode() { export(airCut: nil) }

    /// Asks how far to raise Z, then exports the job as an air cut.
    private func exportAirCut() {
        guard workspace.job?.toolpaths.isEmpty == false else { return }
        let u = project.displayUnits
        let ask = NSAlert()
        ask.messageText = "Export Air Cut"
        ask.informativeText = "Saves the same program with every Z raised, so the machine traces the job above the material "
            + "with X and Y unchanged. Zero the machine as usual, and make sure Z can rise this far above your safe height."
        let field = NSTextField(string: u == .inch ? "1.0" : "25")
        field.frame = NSRect(x: 0, y: 0, width: 90, height: 22)
        let label = NSTextField(labelWithString: "\(u.symbol) higher")
        let row = NSStackView(views: [field, label])
        row.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        ask.accessoryView = row
        ask.addButton(withTitle: "Continue")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), value > 0 else {
            alert = AlertInfo(title: "Can't export an air cut", message: "Enter a height above zero.")
            return
        }
        export(airCut: u.toMM(value))
    }

    /// Posts the job (raised for an air cut when `airCut` is set), checks the files NativeCAM is about to save, and
    /// saves them: one file, or one per tool when the controller can't stop for a tool change; on a tiled job, that for
    /// each tile, with a setup sheet beside them.
    private func export(airCut height: Double?) {
        guard let job = workspace.job, !job.toolpaths.isEmpty else { return }
        guard let output = JobExport.files(project, job: job, airCut: height) else { return noPost() }
        let post = output.post
        // Problems in the job, then in each file itself: read back against the controller and the toolpaths.
        let jobErrors = job.issues.filter { $0.severity == .error }.map { "• \($0.operation.map { "\($0): " } ?? "")\($0.message)" }
        var fileLines: [String] = []
        var fileErrors = false
        var allChecks: [GCodeCheck.Issue] = []
        for file in output.files {
            let checks = GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: file.project, dialect: post.dialect)
            allChecks += checks
            let shown = checks.filter { $0.severity != .info }
            fileErrors = fileErrors || shown.contains { $0.severity == .error }
            let label = output.files.count > 1 ? "G-code\(file.suffix ?? "")" : "G-code"
            fileLines += shown.map { "• \(label): \($0.text)" }
        }
        if !jobErrors.isEmpty || !fileLines.isEmpty {
            var lines = jobErrors + fileLines
            if lines.count > 10 { lines = Array(lines.prefix(10)) + ["• …and \(lines.count - 10) more"] }
            let confirm = NSAlert()
            let errors = !jobErrors.isEmpty || fileErrors
            confirm.messageText = errors ? "This job has errors" : "Check before running this file"
            confirm.informativeText = lines.joined(separator: "\n") + (errors ? "\n\nExport anyway?" : "")
            if errors {
                confirm.addButton(withTitle: "Cancel")
                confirm.addButton(withTitle: "Export Anyway")
                confirm.alertStyle = .critical
                guard confirm.runModal() == .alertSecondButtonReturn else { return }
            } else {
                confirm.addButton(withTitle: "Export")
                confirm.addButton(withTitle: "Cancel")
                confirm.alertStyle = .warning
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: post.fileExtension, conformingTo: .plainText) ?? .plainText]
        let base = project.name.isEmpty ? "Untitled" : project.name
        panel.nameFieldStringValue = base + (height == nil ? "" : " (air cut)") + "." + post.fileExtension
        if let tiled = job.tiling {
            panel.message = "Saves \(output.files.count) files, one \(output.files.count > tiled.layout.count ? "per tool in each tile" : "per tile"), "
                + "named after this one, and a setup sheet with a page for each tile."
        } else if let sheets = job.sheets {
            panel.message = "Saves \(output.files.count) files, one \(output.files.count > sheets.count ? "per tool on each sheet" : "per sheet"), "
                + "named after this one, and a setup sheet with a page for each sheet."
        } else if output.files.count > 1 {
            panel.message = "\(post.name) can't stop for a tool change, so each tool gets its own file "
                + "(\(output.files.count) files, named after this one). Re-zero Z before running each."
        } else {
            panel.message = height == nil ? "Save G-code for \(post.name)" : "Save an air cut for \(post.name)"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if output.files.count == 1 {
                try output.files[0].gcode.data(using: .ascii, allowLossyConversion: true)?.write(to: url)
            } else {
                // "Sign.nc" becomes "Sign 1 of 2 - T5.nc", "Sign 2 of 2 - T1.nc", or "Sign - tile 1 of 2.nc" (the air-cut
                // marker is in the suffix).
                var stem = url.deletingPathExtension().lastPathComponent
                if height != nil, stem.hasSuffix(" (air cut)") { stem = String(stem.dropLast(" (air cut)".count)) }
                let names = JobExport.fileNames(output.files, base: stem + "." + post.fileExtension, fileExtension: post.fileExtension)
                let folder = url.deletingLastPathComponent()
                for (file, name) in zip(output.files, names) {
                    try file.gcode.data(using: .ascii, allowLossyConversion: true)?.write(to: folder.appendingPathComponent(name))
                }
                // A tiled job's setup sheet says where to move the material and the dowels before each file; a nested
                // job's, which sheet each file cuts.
                if job.tiling != nil || job.sheets != nil {
                    let sheet = SetupSheet.html(project: project, job: job, gcodeFile: stem + "." + post.fileExtension, checks: allChecks)
                    try Data(sheet.utf8).write(to: folder.appendingPathComponent(stem + " setup sheet.html"))
                }
            }
        } catch {
            alert = AlertInfo(title: "Couldn't save G-code", message: error.localizedDescription)
        }
    }

    private func noPost() {
        alert = AlertInfo(title: "Can't export G-code",
                          message: PostProcessors.unavailableReason(for: project.machine) ?? "No post processor for this machine.")
    }

    /// Saves a printable setup sheet: material and zero, tools in order, run order with times, clamps, open checks.
    private func exportSetupSheet() {
        guard let job = workspace.job, !job.toolpaths.isEmpty else { return }
        var checks: [GCodeCheck.Issue] = []
        if let output = JobExport.files(project, job: job) {
            for file in output.files {
                checks += GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: file.project, dialect: output.post.dialect)
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (project.name.isEmpty ? "Untitled" : project.name) + " setup sheet.html"
        panel.message = "Save a setup sheet to print or keep beside the machine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(SetupSheet.html(project: project, job: job, checks: checks).utf8).write(to: url)
        } catch {
            alert = AlertInfo(title: "Couldn't save the setup sheet", message: error.localizedDescription)
        }
    }
}

/// Toolpaths ▸ Nest Parts… open in a sheet.
struct NestRequest: Identifiable {
    let id = UUID()
    let session: NestSession
}

/// A template read and waiting for Add Toolpaths, with the shapes selected when it was chosen.
struct PendingTemplate: Identifiable {
    let id = UUID()
    var template: ToolpathTemplate
    var selection: [UUID]
}

/// Developer capture state for the Vectric post sheet.
struct DebugPost: Identifiable {
    let id = UUID()
    var pp: VectricPost
}

/// Developer capture state for the machine setup assistant.
struct DebugSetup: Identifiable {
    let id = UUID()
    var selection: String
    var step: MachineSetupView.Step
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
