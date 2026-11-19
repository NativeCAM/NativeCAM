import AppKit
import CAMCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The app-wide tool library, saved to ~/Library/Application Support/NativeCAM/tools.json.
@MainActor
@Observable
final class ToolLibraryStore {
    static let shared = ToolLibraryStore()

    var tools: [Tool] { didSet { save() } }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeCAM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tools.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let lib = try? ToolLibrary.decode(data) {
            tools = lib.tools
        } else {
            tools = ToolLibrary.starter.tools
        }
    }

    func tool(id: UUID) -> Tool? { tools.first { $0.id == id } }

    private func save() {
        guard let data = try? ToolLibrary(tools: tools).encoded() else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func add(_ shape: ToolShape) -> Tool {
        let next = (tools.map(\.number).max() ?? 0) + 1
        let template = ToolLibrary.starter.tools.first { $0.shape == shape } ?? ToolLibrary.starter.tools[0]
        var t = template
        t.id = UUID()
        t.number = next
        t.shape = shape
        t.name = "New \(shape.label)"
        tools.append(t)
        return t
    }

    func resetToStarter() { tools = ToolLibrary.starter.tools }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "NativeCAM Tools.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? ToolLibrary(tools: tools).encoded() else { return }
        try? data.write(to: url)
    }

    /// Asks for a tool library file: NativeCAM .json, Fusion 360 .tools/.json or Vectric .vtdb.
    func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ToolLibraryImporter.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a tool library: Fusion 360 (.tools or .json), Vectric (.vtdb) or NativeCAM (.json)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Adds imported tools after the existing ones, numbered on from the highest T number (the source library's numbers
    /// rarely fit this one). Tools already in the library (same ID) are skipped. Returns the tools added.
    @discardableResult
    func add(_ imported: [Tool]) -> [Tool] {
        let existing = Set(tools.map(\.id))
        var next = (tools.map(\.number).max() ?? 0) + 1
        var added: [Tool] = []
        for var t in imported where !existing.contains(t.id) {
            t.number = next
            next += 1
            added.append(t)
        }
        tools.append(contentsOf: added)
        return added
    }
}

/// A library file read and waiting for the user to pick tools from it.
struct PendingToolImport: Identifiable {
    let id = UUID()
    let fileName: String
    let result: ToolImport
}

struct ToolLibraryView: View {
    @Environment(ToolLibraryStore.self) private var store
    @State private var selection: UUID?
    @State private var units: LengthUnit = AppDefaults.displayUnits
    @State private var pendingImport: PendingToolImport?
    @State private var importError: String?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(Array(store.tools.enumerated()), id: \.element.id) { index, tool in
                        HStack {
                            ToolShapeView(tool: tool, showDimensions: false).frame(width: 22, height: 34)
                            VStack(alignment: .leading) {
                                Text("T\(tool.number)  \(tool.name)")
                                Text("\(tool.shape.label) · ⌀ \(units.format(tool.diameter)) \(units.symbol)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(tool.id)
                        .cardRow(index, of: store.tools.count) // same cards as the editor beside it and the main sidebar
                        .contextMenu {
                            Button("Duplicate") { duplicate(tool) }
                            Button("Delete", role: .destructive) { store.tools.removeAll { $0.id == tool.id } }
                        }
                    }
                    .onMove { store.tools.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    SectionTitle("Tools", prominent: true)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                Menu {
                    ForEach(ToolShape.allCases) { shape in
                        Button(shape.label) { selection = store.add(shape).id }
                    }
                } label: { Label("Add Tool", systemImage: "plus") }
            }
        } detail: {
            if let id = selection, let index = store.tools.firstIndex(where: { $0.id == id }) {
                ToolEditor(tool: $store.tools[index], units: units)
            } else {
                Text("Select a tool").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Units", selection: $units) {
                    Text("in").tag(LengthUnit.inch)
                    Text("mm").tag(LengthUnit.mm)
                }
                .pickerStyle(.segmented)
                Menu {
                    Button("Import Tools…") { beginImport() }
                    Button("Export Tools…") { store.exportJSON() }
                    Divider()
                    Button("Reset to Starter Library", role: .destructive) { store.resetToStarter() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .navigationTitle("Tool Library")
        .onAppear { if selection == nil { selection = store.tools.first?.id } }
        .onReceive(NotificationCenter.default.publisher(for: DebugCapture.command)) { note in
            // Developer capture hook: open the import sheet for a given library file.
            if let path = note.userInfo?["importtools"] as? String { load(URL(fileURLWithPath: path)) }
        }
        .sheet(item: $pendingImport) { pending in
            ImportToolsSheet(pending: pending, units: units) { chosen in
                let added = store.add(chosen)
                if let first = added.first { selection = first.id }
            }
        }
        .alert("Can't import tools", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func beginImport() {
        guard let url = store.chooseImportFile() else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do {
            let result = try ToolLibraryImporter.load(url: url)
            if result.tools.isEmpty {
                importError = "“\(url.lastPathComponent)” has no tools NativeCAM can use"
                    + (result.skipped.isEmpty ? "." : " (\(result.skipped.count) skipped: \(Set(result.skipped.map(\.reason)).sorted().joined(separator: ", "))).")
            } else {
                pendingImport = PendingToolImport(fileName: url.lastPathComponent, result: result)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func duplicate(_ tool: Tool) {
        var t = tool
        t.id = UUID()
        t.number = (store.tools.map(\.number).max() ?? 0) + 1
        t.name += " copy"
        store.tools.append(t)
        selection = t.id
    }
}

/// Full geometry + cutting data editor with a live drawing of the tool.
struct ToolEditor: View {
    @Binding var tool: Tool
    let units: LengthUnit

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $tool.name)
                    IntField(title: "Tool number (T#)", value: $tool.number, range: 1...999)
                    Picker("Type", selection: $tool.shape) {
                        ForEach(ToolShape.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Flutes", selection: $tool.fluteDirection) {
                        ForEach(FluteDirection.allCases) { Text($0.label).tag($0) }
                    }
                    IntField(title: "Number of flutes", value: $tool.fluteCount, range: 1...8)
                }
                Section("Geometry") {
                    LengthField(title: tool.shape.isTapered ? "Max diameter" : "Diameter", mm: $tool.diameter, units: units, minimum: 0.1)
                    if tool.shape.usesAngle {
                        NumberField(title: "Included angle", value: $tool.includedAngle, suffix: "°", decimals: 1, range: 5...170)
                    }
                    if tool.shape.isTapered {
                        LengthField(title: "Tip diameter", mm: $tool.tipDiameter, units: units, minimum: 0)
                        LabeledContent("V depth to full diameter", value: "\(units.format(tool.taperHeight)) \(units.symbol)")
                    }
                    if tool.fluteDirection == .compression {
                        LengthField(title: "Upcut length", mm: Binding(get: { tool.upcutLength ?? tool.diameter }, set: { tool.upcutLength = max(0.1, $0) }),
                                    units: units, help: "First passes go at least this deep (+0.5 mm) so the top face doesn't fray")
                    }
                    if tool.shape.usesCornerRadius {
                        LengthField(title: "Corner radius", mm: $tool.cornerRadius, units: units, minimum: 0)
                    }
                    LengthField(title: "Cutting length", mm: $tool.fluteLength, units: units, minimum: 0.1)
                    LengthField(title: "Shank diameter", mm: $tool.shankDiameter, units: units, minimum: 0.1)
                    LengthField(title: "Stickout", mm: $tool.stickout, units: units, minimum: 0.1)
                }
                Section("Feeds & Speeds") {
                    NumberField(title: "Spindle", value: $tool.cutting.spindleRPM, suffix: "RPM", decimals: 0, range: 1000...60000)
                    FeedField(title: "Feed", mmPerMin: $tool.cutting.feedRate, units: units)
                    FeedField(title: "Plunge", mmPerMin: $tool.cutting.plungeRate, units: units)
                    LengthField(title: "Stepdown", mm: $tool.cutting.stepdown, units: units, minimum: 0.05)
                    PercentField(title: "Stepover", fraction: $tool.cutting.stepoverFraction)
                    LabeledContent("Chip load", value: "\(units.format(tool.chipLoad, decimals: 4)) \(units.symbol)/tooth")
                    LengthField(title: "Set feed from chip load", mm: Binding(get: { tool.chipLoad }, set: { tool.cutting.feedRate = tool.feedRate(forChipLoad: $0) }),
                                units: units, help: "Type a chip load to compute the feed")
                }
                Section("Notes") {
                    TextField("Notes", text: $tool.notes, axis: .vertical).lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
            VStack(spacing: 8) {
                ToolShapeView(tool: tool, units: units)
                    .frame(width: 240, height: 380)
                    .padding(.top, 20)
                Text(tool.name).font(.headline).multilineTextAlignment(.center)
                Text("\(tool.shape.label) · \(tool.fluteCount) flute \(tool.fluteDirection.label.lowercased())")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(width: 280)
            .background(.background.secondary)
        }
    }
}

/// App-wide defaults for new documents (Settings window).
enum AppDefaults {
    private static let machineKey = "defaultMachine"
    private static let unitsKey = "defaultUnits"
    private static let stockKey = "defaultStock"

    static var machine: MachineProfile {
        get { decode(machineKey) ?? .avidPRO6060 }
        set { encode(newValue, machineKey) }
    }

    static var stock: Stock {
        get { decode(stockKey) ?? Stock() }
        set { encode(newValue, stockKey) }
    }

    static var displayUnits: LengthUnit {
        get { LengthUnit(rawValue: UserDefaults.standard.string(forKey: unitsKey) ?? "") ?? .inch }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: unitsKey) }
    }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// Settings window (⌘,) with the standard Mac tabbed layout.
struct AppSettingsView: View {
    @State private var machine = AppDefaults.machine
    @State private var units = AppDefaults.displayUnits
    @State private var stock = AppDefaults.stock

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Units", selection: $units) {
                        Text("Inches").tag(LengthUnit.inch)
                        Text("Millimetres").tag(LengthUnit.mm)
                    }
                } footer: {
                    Text("Used for new documents. Each document can switch units in Job Setup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Default Material") {
                    TextField("Material", text: $stock.materialName)
                    LengthField(title: "Width", mm: $stock.width, units: units, minimum: 1)
                    LengthField(title: "Height", mm: $stock.height, units: units, minimum: 1)
                    LengthField(title: "Thickness", mm: $stock.thickness, units: units, minimum: 0.1)
                    Picker("XY zero", selection: $stock.xyOrigin) {
                        ForEach(XYOrigin.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Z zero", selection: $stock.zZero) {
                        ForEach(ZZero.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                MachineSection(machine: $machine, units: units)
            }
            .formStyle(.grouped)
            .tabItem { Label("Machine", systemImage: "cube.transparent") }
        }
        .frame(width: 540, height: 560)
        .onChange(of: machine) { _, v in AppDefaults.machine = v }
        .onChange(of: units) { _, v in AppDefaults.displayUnits = v }
        .onChange(of: stock) { _, v in AppDefaults.stock = v }
    }
}

// MARK: Importing from other programs

/// Pick which tools to bring in from a Fusion 360, Vectric or NativeCAM library. Vendor libraries hold hundreds of bits,
/// so nothing is selected to begin with (except for NativeCAM's own libraries); search and the shape filter narrow
/// the list, grouped by the folders of the source library.
struct ImportToolsSheet: View {
    let pending: PendingToolImport
    let units: LengthUnit
    let onImport: ([Tool]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []
    @State private var search = ""
    @State private var shape: ToolShape?
    @State private var showSkipped = false

    init(pending: PendingToolImport, units: LengthUnit, onImport: @escaping ([Tool]) -> Void) {
        self.pending = pending
        self.units = units
        self.onImport = onImport
        _chosen = State(initialValue: pending.result.format == .nativeCAM ? Set(pending.result.tools.map(\.id)) : [])
    }

    private var shown: [ImportedTool] {
        let words = search.lowercased().split(separator: " ")
        return pending.result.tools.filter { item in
            (shape == nil || item.tool.shape == shape)
                && words.allSatisfy { (item.tool.name + " " + item.group).lowercased().contains($0) }
        }
    }

    /// Groups in the order the source library lists them, without a top folder they all share.
    private var groups: [(name: String, tools: [ImportedTool])] {
        var order: [String] = []
        var byGroup: [String: [ImportedTool]] = [:]
        for t in shown {
            if byGroup[t.group] == nil { order.append(t.group) }
            byGroup[t.group, default: []].append(t)
        }
        return order.map { (trimmedGroup($0), byGroup[$0] ?? []) }
    }

    private var sharedRoot: String? {
        let roots = Set(pending.result.tools.map { $0.group.components(separatedBy: " ▸ ").first ?? "" })
        guard roots.count == 1, let root = roots.first, !root.isEmpty,
              pending.result.tools.contains(where: { $0.group.contains(" ▸ ") }) else { return nil }
        return root
    }

    private func trimmedGroup(_ g: String) -> String {
        guard let root = sharedRoot, g.hasPrefix(root + " ▸ ") else { return g }
        return String(g.dropFirst(root.count + 3))
    }

    private var anyEstimated: Bool { pending.result.tools.contains { ImportToolRow.estimates(in: $0.tool).isEmpty == false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Tools").font(.title3.weight(.semibold))
                Text("“\(pending.fileName)” · \(pending.result.format.rawValue)" + (sharedRoot.map { " · \($0)" } ?? "")
                     + " · \(pending.result.tools.count) tools")
                    .foregroundStyle(.secondary)
                if anyEstimated {
                    Label("Marked tools have values the library doesn't give (hover to see which); NativeCAM filled them "
                          + "conservatively. Check them in the editor before cutting.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            HStack {
                TextField("Search names (e.g. 1/4 downcut)", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: $shape) {
                    Text("All types").tag(ToolShape?.none)
                    Divider()
                    ForEach(ToolShape.allCases.filter { s in pending.result.tools.contains { $0.tool.shape == s } }) { s in
                        Text(s.label).tag(ToolShape?.some(s))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            List {
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(Array(group.tools.enumerated()), id: \.element.id) { index, item in
                            ImportToolRow(item: item, units: units, isOn: Binding(
                                get: { chosen.contains(item.id) },
                                set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                            .cardRow(index, of: group.tools.count)
                        }
                    } header: {
                        SectionTitle(group.name.isEmpty ? "Tools" : group.name, prominent: true)
                    }
                }
                if shown.isEmpty {
                    Placeholder("No tools match.")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10) // cards line up with the search field

            if !pending.result.skipped.isEmpty {
                DisclosureGroup(isExpanded: $showSkipped) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(pending.result.skipped.enumerated()), id: \.offset) { _, s in
                                Text("\(s.name) — \(s.reason)").font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                } label: {
                    Text("\(pending.result.skipped.count) tools can't be imported (\(skippedSummary))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            HStack {
                Button("Select All Shown") { chosen.formUnion(shown.map(\.id)) }
                    .disabled(shown.isEmpty)
                Button("Select None") { chosen.removeAll() }
                    .disabled(chosen.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Tool" : "Add \(chosen.count) Tools") {
                    onImport(pending.result.tools.filter { chosen.contains($0.id) }.map(\.tool))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 640, height: 640)
    }

    private var skippedSummary: String {
        let counts = Dictionary(grouping: pending.result.skipped, by: \.reason).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }
}

private struct ImportToolRow: View {
    let item: ImportedTool
    let units: LengthUnit
    @Binding var isOn: Bool

    /// Guesses worth checking before cutting: the cutting length and the feeds and speeds. (Stepdown and stepover
    /// guesses are noted too, but each toolpath sets those anyway.)
    static func estimates(in tool: Tool) -> [String] {
        tool.notes.split(separator: "\n").map(String.init).filter { line in
            line.contains("Cutting length estimated")
                || (line.contains("conservative defaults") && ["feed", "speed", "plunge"].contains { line.contains($0) })
        }
    }

    private var estimated: [String] { Self.estimates(in: item.tool) }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            ToolShapeView(tool: item.tool, showDimensions: false).frame(width: 18, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.tool.name).lineLimit(1)
                Text("\(item.tool.shape.label) · ⌀ \(units.format(item.tool.diameter)) \(units.symbol) · \(item.tool.fluteCount) flute"
                     + (item.tool.fluteCount == 1 ? "" : "s"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !estimated.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(estimated.joined(separator: "\n"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}
