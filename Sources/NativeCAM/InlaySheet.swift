import CAMCore
import SwiftUI

/// Add Toolpath ▸ Inlay… on the selected closed vectors, waiting in a sheet.
struct InlayRequest: Identifiable {
    let id = UUID()
    let selection: [UUID]
}

/// Add Toolpath ▸ Inlay…: one dialog for both sides of a V-carve inlay. It makes the pocket and the plug with one V-bit,
/// the pocket's flat depth as the plug's pocket depth, and the plug's glue gap, surface clearance and boundary
/// (`InlayPairSettings`). Each side starts clearing its flats with the flat end mill the run-time estimate says is
/// quickest for it (`Project.inlayClearanceTimes`), worked out in the background and again when a setting it depends on
/// changes, until a tool is picked for that side. Nothing changes until Add Toolpaths.
struct InlaySheet: View {
    let project: Project
    let selection: [UUID]
    let tools: [Tool]
    /// The sheet's height (taller in snapshot checks, to show it all).
    var height: CGFloat
    let onAdd: (InlayPairSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings: InlayPairSettings
    /// The end mills' times for the current settings, once worked out.
    @State private var times: InlayClearanceTimes?
    @State private var timing = false

    init(project: Project, selection: [UUID], tools: [Tool], settings: InlayPairSettings? = nil, times: InlayClearanceTimes? = nil,
         height: CGFloat = 760, onAdd: @escaping (InlayPairSettings) -> Void) {
        self.project = project
        self.selection = selection
        self.tools = tools
        self.height = height
        self.onAdd = onAdd
        _settings = State(initialValue: settings ?? Self.defaults(tools: tools))
        _times = State(initialValue: times)
    }

    /// A 60° V-bit if there is one (the usual inlay bit), Vectric's usual depths and a margin round the design. The first
    /// flat end mill clears the flats until each side's quickest is known.
    static func defaults(tools: [Tool]) -> InlayPairSettings {
        let vBits = tools.filter { $0.shape == .vBit }
        let bit = vBits.first { abs($0.includedAngle - 60) < 0.5 && $0.tipDiameter < 1e-6 } ?? vBits.first
            ?? ToolLibrary.starter.tool(number: 5)!
        return InlayPairSettings(vBit: bit, clearanceTool: tools.first { $0.shape == .flatEndMill })
    }

    private var units: LengthUnit { project.displayUnits }
    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

    private var layout: (design: [UUID], boundary: UUID?) { project.inlayLayout(selection, boundary: settings.boundary) }

    private func binding(_ key: WritableKeyPath<InlayPairSettings, Double>, minimum: Double) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = max(minimum, $0) })
    }

    var body: some View {
        let layout = layout
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inlay").font(.headline)
                Text(layout.design.isEmpty
                     ? "Select the closed vectors of the design first."
                     : "Makes the pocket and the plug for \(layout.design.count == 1 ? "the selected vector" : "\(layout.design.count) selected vectors"), "
                        + "with one V-bit and depths that fit.")
                    .font(.callout).foregroundStyle(layout.design.isEmpty ? .orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                bits
                depths
                boundary(layout)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Toolpaths") {
                    onAdd(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(layout.design.isEmpty || !settings.vBit.shape.isTapered)
            }
            .padding(16)
        }
        .frame(width: 520, height: height)
        .task(id: settings.timingKey) { await timeClearanceTools() }
    }

    /// Times every flat end mill on each side for the current settings (a moment after the last change, in the
    /// background) and starts each side not picked by hand with its quickest.
    private func timeClearanceTools() async {
        let key = settings.timingKey
        guard times?.key != key else {
            timing = false
            return
        }
        timing = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let project = project, selection = selection, tools = tools
        let stop = StopFlag()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                project.inlayClearanceTimes(key, shapes: selection, tools: tools, shouldStop: { stop.isSet })
            }.value
        } onCancel: {
            stop.set()
        }
        guard !Task.isCancelled else { return }
        timing = false
        guard let result else { return }
        times = result
        settings = settings.withQuickestClearance(result)
    }

    /// "1:05" or "1:02:05".
    private func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// A clearance tool's name, with the side's run time when it's known.
    private func label(_ t: Tool, side: VCarveInlay.Role) -> String {
        let name = "T\(t.number) \(t.name)"
        guard let times, times.key == settings.timingKey, let s = times.seconds(side, tool: t) else { return name }
        return "\(name) (\(duration(s)))"
    }

    private func clearancePicker(_ title: String, side: VCarveInlay.Role) -> some View {
        Picker(title, selection: Binding(get: { settings.clearanceTool(side)?.id }, set: { id in
            settings.pickClearance(id.flatMap { id in tools.first { $0.id == id } }, for: side)
        })) {
            Text("None (V-bit only)").tag(UUID?.none)
            ForEach(tools.filter { !$0.shape.isTapered }) { t in Text(label(t, side: side)).tag(Optional(t.id)) }
        }
    }

    @ViewBuilder
    private var bits: some View {
        Section {
            Picker("V-bit", selection: Binding(get: { settings.vBit.id }, set: { id in
                if let t = tools.first(where: { $0.id == id }) { settings.vBit = t }
            })) {
                if !tools.contains(where: { $0.id == settings.vBit.id }) {
                    Text("T\(settings.vBit.number) \(settings.vBit.name)").tag(settings.vBit.id)
                }
                ForEach(tools.filter(\.shape.isTapered)) { t in Text("T\(t.number) \(t.name)").tag(t.id) }
            }
            clearancePicker("Clear the pocket's flats with", side: .pocket)
            clearancePicker("Clear the plug's flats with", side: .plug)
            if timing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Timing the end mills on each side…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.pocketClearanceTool == nil || settings.plugClearanceTool == nil {
                Picker("V-bit clears flats in", selection: Binding(get: { settings.flatRaster != nil }, set: { raster in
                    settings.flatRaster = raster ? VCarveRaster() : nil
                })) {
                    Text("Rings").tag(false)
                    Text("Raster").tag(true)
                }
                .pickerStyle(.segmented)
                if let raster = settings.flatRaster {
                    NumberField(title: "Raster angle", value: Binding(get: { raster.angle }, set: { settings.flatRaster?.angle = $0 }),
                                suffix: "°", decimals: 1)
                }
            }
        } header: {
            Text("Bits")
        } footer: {
            Text(bitsFooter)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bitsFooter: String {
        let none = [settings.pocketClearanceTool, settings.plugClearanceTool].filter { $0 == nil }.count
        var text = switch none {
        case 2: "The V-bit clears the flat areas on both sides itself, with passes close enough that the ridges between them stay under the glue gap: slow over large areas. Raster runs straight lines, which suits large flats."
        case 1: "The end mill clears one side's flat areas first, and the V-bit cleans up the corners it can't reach; on the other side the V-bit clears them itself, slowly over large areas (raster suits large flats)."
        default: "The end mill clears the flat areas first; the V-bit then carves the walls and cleans up the corners the end mill can't reach."
        }
        text += " Each side starts with the end mill that clears it quickest (the time is that side's whole run); the fit doesn't depend on it. A tool you pick stays."
        return text
    }

    @ViewBuilder
    private var depths: some View {
        let inlay = settings.plugInlay
        Section {
            LengthField(title: "Pocket depth", mm: binding(\.pocketDepth, minimum: 0.01), units: units,
                        help: "The pocket's flat depth, and the plug's pocket depth (P)")
            LengthField(title: "Glue gap", mm: binding(\.glueGap, minimum: 0), units: units,
                        help: "The gap left between the plug's face and the pocket's floor, for glue (G)")
            LengthField(title: "Surface clearance", mm: binding(\.surfaceClearance, minimum: 0.01), units: units,
                        help: "How far the plug board stays above the pocket board when the walls meet: room to clamp it in, and the waste you saw or plane off (C)")
            LabeledContent("Plug carved", value: "\(len(inlay.plugStartDepth)) to \(len(inlay.plugCutDepth)) deep")
            if settings.glueGap >= settings.pocketDepth - 1e-9 {
                Label("The glue gap must be less than the pocket depth, or the plug has no walls to fit by.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
            } else if settings.vBit.shape.isTapered, inlay.plugCutDepth > min(settings.vBit.taperHeight, settings.vBit.fluteLength) + 1e-6 {
                Label("The plug is cut deeper than \(settings.vBit.name)'s V is tall. Use a smaller pocket depth or a taller V-bit.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Depths")
        } footer: {
            Text("The plug is carved from the pocket depth less the glue gap, so when its walls meet the pocket's the glue gap is left under its face.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func boundary(_ layout: (design: [UUID], boundary: UUID?)) -> some View {
        Section {
            Picker("Boundary", selection: $settings.boundary) {
                ForEach(VCarveInlay.Boundary.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            switch settings.boundary {
            case .margin:
                LengthField(title: "Boundary margin", mm: binding(\.boundaryMargin, minimum: 0.1), units: units,
                            help: "How far past the design the plug is carved")
            case .vector:
                if let id = layout.boundary, let shape = project.shape(id: id) {
                    LabeledContent("Boundary vector", value: shape.name)
                } else {
                    Label("None of the selected vectors goes round the rest, so the plug is carved to the margin.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                    LengthField(title: "Boundary margin", mm: binding(\.boundaryMargin, minimum: 0.1), units: units,
                                help: "How far past the design the plug is carved")
                }
            case .board:
                BoardSizeRows(size: $settings.boardSize, stock: project.stock, units: units)
            }
        } header: {
            Text("Plug")
        } footer: {
            Text(settings.boundary == .board
                 ? "The plug is carved over its whole board, right out to the edges, around the mirrored design. It's added with Include in output off: export the pocket, then swap them to cut the plug from its own board."
                 : "The plug is carved around the mirrored design, so the design stands proud. It's added with Include in output off: export the pocket, then swap them to cut the plug from its own board.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A whole-board plug's board: the material, or a size entered, centred on the design.
struct BoardSizeRows: View {
    @Binding var size: Vec2?
    let stock: Stock
    let units: LengthUnit
    /// Where a custom-size board sits, when known (the inspector shows it; the dialog doesn't).
    var placed: Rect2? = nil

    var body: some View {
        Picker("Board", selection: Binding(get: { size != nil }, set: { custom in
            size = custom ? Vec2(stock.width, stock.height) : nil
        })) {
            Text("The material (\(units.format(stock.width)) × \(units.format(stock.height)) \(units.symbol))").tag(false)
            Text("Another size").tag(true)
        }
        if let s = size {
            LengthField(title: "Board width", mm: Binding(get: { s.x }, set: { size = Vec2(max(1, $0), s.y) }), units: units)
            LengthField(title: "Board height", mm: Binding(get: { s.y }, set: { size = Vec2(s.x, max(1, $0)) }), units: units)
            if let placed {
                let corner = stock.toWork(Vec3(placed.min, 0))
                LabeledContent("Lower-left corner",
                               value: "X \(units.format(corner.x)), Y \(units.format(corner.y)) \(units.symbol)")
                    .help("Where the board's lower-left corner goes, in the job's work coordinates: it's centred on the design")
            } else {
                Text("Centred on the design.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
