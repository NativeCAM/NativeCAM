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

    func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let lib = try? ToolLibrary.decode(data) else { return }
        let existing = Set(tools.map(\.id))
        tools.append(contentsOf: lib.tools.filter { !existing.contains($0.id) })
    }
}

struct ToolLibraryView: View {
    @Environment(ToolLibraryStore.self) private var store
    @State private var selection: UUID?
    @State private var units: LengthUnit = AppDefaults.displayUnits

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
                    Button("Import Tools…") { store.importJSON() }
                    Button("Export Tools…") { store.exportJSON() }
                    Divider()
                    Button("Reset to Starter Library", role: .destructive) { store.resetToStarter() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .navigationTitle("Tool Library")
        .onAppear { if selection == nil { selection = store.tools.first?.id } }
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
