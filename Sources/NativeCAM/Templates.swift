import AppKit
import CAMCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A toolpath template (`ToolpathTemplate`), declared in the app's Info.plist.
    static let nativecamTemplate = UTType(filenameExtension: ToolpathTemplate.fileExtension, conformingTo: .json) ?? .json
}

/// The templates folder and the templates in it, listed under Toolpaths ▸ Apply Template.
@MainActor
@Observable
final class TemplateLibrary {
    static let shared = TemplateLibrary()

    struct Entry: Identifiable, Hashable {
        var url: URL
        var name: String
        var id: URL { url }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// ~/Library/Application Support/NativeCAM/Templates. The `NativeCAMTemplatesFolder` default points it elsewhere,
    /// for snapshot checks.
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "NativeCAMTemplatesFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeCAM/Templates", isDirectory: true)
    }

    init() {
        refresh()
        // Templates copied into the folder in the Finder show up the next time the app comes forward.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TemplateLibrary.shared.refresh() }
        }
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let found = urls.filter { $0.pathExtension.lowercased() == ToolpathTemplate.fileExtension }
            .map { Entry(url: $0, name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if found != entries { entries = found }
    }

    /// The folder, created if it isn't there yet.
    @discardableResult
    static func ensureFolder() -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func revealFolder() {
        NSWorkspace.shared.open(ensureFolder())
    }
}

/// Toolpaths ▸ Apply Template: the templates in the folder, then Choose… for one elsewhere.
struct TemplateMenuItems: View {
    let templates: TemplateLibrary
    let apply: (URL) -> Void
    let choose: () -> Void

    var body: some View {
        ForEach(templates.entries) { entry in
            Button(entry.name) { apply(entry.url) }
        }
        if templates.entries.isEmpty {
            Button("No Saved Templates") {}.disabled(true)
        }
        Divider()
        Button("Choose…") { choose() }
        Button("Show Templates Folder") { TemplateLibrary.revealFolder() }
    }
}

/// The save panel's options for Save Toolpaths as Template.
@MainActor
@Observable
final class TemplateSaveOptions {
    var includeJobSetup = true
    var onlySelected: Bool
    let selectedCount: Int
    let totalCount: Int

    init(selectedCount: Int, totalCount: Int) {
        self.selectedCount = selectedCount
        self.totalCount = totalCount
        onlySelected = selectedCount > 0 && selectedCount < totalCount
    }

    var offersSelection: Bool { selectedCount > 0 && selectedCount < totalCount }
}

struct TemplateSaveAccessory: View {
    @Bindable var options: TemplateSaveOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if options.offersSelection {
                Picker("Save", selection: $options.onlySelected) {
                    Text("The \(options.selectedCount) selected toolpath\(options.selectedCount == 1 ? "" : "s")").tag(true)
                    Text("All \(options.totalCount) toolpaths").tag(false)
                }
                .pickerStyle(.radioGroup)
            }
            Toggle("Include the job setup (material, zero and heights)", isOn: $options.includeJobSetup)
            Text("Each toolpath finds its vectors by layer or kind when the template is applied: see Vectors in its inspector.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 460, alignment: .leading)
    }
}

/// Toolpaths ▸ Apply Template: what the template's toolpaths find in this design, the tools they use, and the
/// template's job setup, before anything is added.
struct ApplyTemplateSheet: View {
    let template: ToolpathTemplate
    let project: Project
    let library: ToolLibrary
    let selection: [UUID]
    let onApply: (ToolpathTemplate.Application, _ addTools: Bool) -> Void
    /// The sheet's height (taller in snapshot checks, to show it all).
    var height: CGFloat = 600
    @Environment(\.dismiss) private var dismiss
    /// Off unless asked: the template's zero and thickness replace the ones this job is set up for.
    @State private var useJobSetup: Bool
    @State private var addTools = true

    init(template: ToolpathTemplate, project: Project, library: ToolLibrary, selection: [UUID], useJobSetup: Bool = false,
         height: CGFloat = 600, onApply: @escaping (ToolpathTemplate.Application, _ addTools: Bool) -> Void) {
        self.height = height
        self.template = template
        self.project = project
        self.library = library
        self.selection = selection
        self.onApply = onApply
        _useJobSetup = State(initialValue: useJobSetup)
    }

    var units: LengthUnit { project.displayUnits }

    var body: some View {
        let result = template.apply(to: project, library: library, selection: selection, useJobSetup: useJobSetup)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apply “\(template.name)”").font(.headline)
                Text("Adds \(result.rows.count) toolpath\(result.rows.count == 1 ? "" : "s") after this job's own, in the template's order.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                Section {
                    ForEach(result.rows) { row in
                        LabeledContent {
                            Text(status(row)).foregroundStyle(row.isEmpty ? .orange : .secondary)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text(row.name)
                            Text(row.kind)
                        }
                    }
                } header: {
                    Text("Toolpaths")
                } footer: {
                    if result.emptyCount > 0 {
                        Text("A toolpath that finds no vectors is added empty, and Checks lists it: select vectors and click Use Selected "
                             + "Shapes, or put vectors on its layer and choose Recalculate All.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Tools") {
                    ForEach(result.tools) { use in
                        LabeledContent {
                            Text(use.inLibrary ? "In your library" : "Not in your library")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("T\(use.tool.number) \(use.tool.name)")
                            if let note = toolNote(use) { Text(note) }
                        }
                    }
                    if !result.newTools.isEmpty {
                        Toggle("Add \(result.newTools.count == 1 ? "it" : "the \(result.newTools.count) new tools") to the tool library",
                               isOn: $addTools)
                    }
                }
                if let setup = template.jobSetup {
                    let changes = useJobSetup ? result.setupChanges : setup.changes(to: project)
                    Section {
                        Toggle("Use the template's job setup", isOn: $useJobSetup)
                            .disabled(changes.isEmpty && !useJobSetup)
                        if changes.isEmpty {
                            Text("The same as this job's.").foregroundStyle(.secondary)
                        }
                        ForEach(changes, id: \.setting) { change in
                            LabeledContent(change.setting) {
                                Text("\(change.from) → \(change.to)").foregroundStyle(change.movesZero ? .orange : .secondary)
                            }
                        }
                        if changes.contains(where: \.movesZero) {
                            Label("Moves the G-code's zero: set up and touch off the machine to match.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.caption)
                        }
                        if let note = result.machineNote {
                            Label(note, systemImage: "info.circle").foregroundStyle(.secondary).font(.caption)
                        }
                    } header: {
                        Text("Job Setup")
                    } footer: {
                        Text("Off, the toolpaths cut this job's material: depths set through the material or as thickness − x follow its thickness.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Toolpaths") {
                    onApply(result, addTools)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result.rows.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: height)
    }

    private func status(_ row: ToolpathTemplate.Application.Row) -> String {
        guard let rule = row.rule else { return "The whole blank" }
        if row.isEmpty { return rule == .selection ? "Nothing selected: added empty" : "\(rule.label): none, added empty" }
        return "\(rule == .selection ? "Selected" : rule.label) · \(row.shapeCount) \(row.shapeCount == 1 ? "vector" : "vectors")"
    }

    private func toolNote(_ use: ToolpathTemplate.Application.ToolUse) -> String? {
        var parts: [String] = []
        if let n = use.templateNumber { parts.append("T\(n) in the template") }
        if use.feedsDiffer { parts.append("with the template's feeds and speeds") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The layer a shape is on, typed in or picked from the design's layers. Commits on Return or leaving the field.
struct LayerField: View {
    /// The shapes' layer, or nil when the selected shapes are on different ones.
    let current: String?
    let layers: [String]
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Layer") {
            HStack(spacing: 4) {
                TextField("Layer", text: $text, prompt: Text(current == nil ? "Several" : "Default"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(save)
                Menu {
                    ForEach(layers, id: \.self) { name in
                        Button(name) {
                            text = name
                            commit(name)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(layers.isEmpty)
                .help("Put the shape on one of the design's layers")
            }
        }
        .help("Toolpaths that find their vectors by layer pick up the shapes on it")
        .onAppear { text = current ?? "" }
        .onChange(of: current) { _, new in text = new ?? "" }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != current else { return }
        commit(name)
    }
}
