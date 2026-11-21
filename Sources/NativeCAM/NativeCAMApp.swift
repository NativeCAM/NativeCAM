import CAMCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct NativeCAMApp: App {
    @State private var toolLibrary = ToolLibraryStore.shared
    @State private var templates = TemplateLibrary.shared

    init() {
        if let snap = DebugSnapshot.requested {
            DebugSnapshot.run(projectPath: snap.project, outDir: snap.outDir)
        }
        DebugCapture.install()
    }

    var body: some Scene {
        DocumentGroup(newDocument: NativeCAMDocument()) { file in
            ContentView(document: file.$document)
                .environment(toolLibrary)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(templates: templates) }

        Window("Tool Library", id: "tool-library") {
            ToolLibraryView()
                .environment(toolLibrary)
                // Tool list (280) + editor (380) + preview (280): narrower and the split view pushes the list off the
                // window's left edge instead of shrinking it.
                .frame(minWidth: 960, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 760)
        .keyboardShortcut("t", modifiers: [.command, .shift])

        Settings {
            AppSettingsView()
        }
    }
}

extension UTType {
    static let nativecamProject = UTType(exportedAs: "com.nativecam.project", conformingTo: .json)
    static let gcodeTap = UTType(filenameExtension: "tap", conformingTo: .plainText) ?? .plainText
}

/// The saved file: a JSON-encoded `Project`. Toolpaths are regenerated on open.
struct NativeCAMDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.nativecamProject] }

    var project: Project

    init(project: Project? = nil) {
        if let project {
            self.project = project
        } else {
            var p = Project()
            p.machine = AppDefaults.machine
            p.displayUnits = AppDefaults.displayUnits
            p.stock = AppDefaults.stock
            self.project = p
        }
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        project = try Project.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try project.encoded())
    }
}

/// Menu-bar commands routed to the focused document window.
struct AppCommands: Commands {
    let templates: TemplateLibrary
    @FocusedValue(\.workspaceActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Demo Sign Project") { newDocument(NativeCAMDocument(project: .demoSign())) }
            Button("New Demo Relief Project (3D)") { newDocument(NativeCAMDocument(project: .demoRelief())) }
            Button("New Demo Rotary Project (3D)") { newDocument(NativeCAMDocument(project: .demoPawn())) }
            Divider()
            Button("Import…") { actions?.importVectors() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions == nil)
            Button("Simulate G-code File…") { actions?.simulateGCodeFile() }
                .disabled(actions == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export G-code…") { actions?.exportGCode() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(actions == nil)
            Button("Export Air Cut…") { actions?.exportAirCut() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Export Setup Sheet…") { actions?.exportSetupSheet() }
                .disabled(actions == nil)
        }
        CommandMenu("Toolpaths") {
            Button("Recalculate All") { actions?.regenerate() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Simulate") { actions?.simulate() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Stop Simulation") { actions?.stopSimulation() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Optimize Run Order") { actions?.optimizeOrder() }
                .disabled(actions == nil)
                .help("Reorder toolpaths for the fewest tool changes, keeping inside work before cut-outs")
            Divider()
            Button("Save Toolpaths as Template…") { actions?.saveTemplate() }
                .disabled(!(actions?.hasToolpaths ?? false))
            Menu("Apply Template") {
                TemplateMenuItems(templates: templates, apply: { actions?.applyTemplate($0) }, choose: { actions?.chooseTemplate() })
            }
            .disabled(actions == nil)
            Divider()
            Button("Tool Library") { openWindow(id: "tool-library") }
        }
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { actions?.duplicate() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!(actions?.canDuplicate ?? false))
        }
        // View items go in the system View menu (above Show/Customize Toolbar), not a second View menu.
        CommandGroup(before: .toolbar) {
            Button("Top View") { actions?.setView(.top) }.keyboardShortcut("1", modifiers: .command)
            Button("Front View") { actions?.setView(.front) }.keyboardShortcut("2", modifiers: .command)
            Button("Iso View") { actions?.setView(.iso) }.keyboardShortcut("3", modifiers: .command)
            Button("Zoom to Fit") { actions?.fit() }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button(actions?.inspectorShown == false ? "Show Inspector" : "Hide Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}

/// Closures the focused window exposes to menu commands.
struct WorkspaceActions {
    var importVectors: () -> Void
    var simulateGCodeFile: () -> Void
    var exportGCode: () -> Void
    var exportAirCut: () -> Void
    var exportSetupSheet: () -> Void
    var regenerate: () -> Void
    var simulate: () -> Void
    var stopSimulation: () -> Void
    var optimizeOrder: () -> Void
    var saveTemplate: () -> Void
    var applyTemplate: (URL) -> Void
    var chooseTemplate: () -> Void
    var hasToolpaths: Bool
    var setView: (ViewPreset) -> Void
    var fit: () -> Void
    var duplicate: () -> Void
    var canDuplicate: Bool
    var toggleInspector: () -> Void
    var inspectorShown: Bool
}

struct WorkspaceActionsKey: FocusedValueKey { typealias Value = WorkspaceActions }

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}
