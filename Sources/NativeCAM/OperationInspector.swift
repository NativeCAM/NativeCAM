import CAMCore
import SwiftUI

struct OperationInspector: View {
    @Binding var op: CAMOperation
    let project: Project
    let workspace: Workspace
    @Environment(ToolLibraryStore.self) private var library

    var units: LengthUnit { project.displayUnits }

    var body: some View {
        Form {
            Section(op.kind.label) {
                TextField("Name", text: $op.name)
                Toggle("Include in output", isOn: $op.enabled)
                if op.kind.needsShapes {
                    LabeledContent("Shapes", value: "\(op.shapeIDs.count)")
                    Button("Use Selected Shapes") { op.shapeIDs = workspace.selectedShapeIDs }
                        .disabled(workspace.selectedShapeIDs.isEmpty)
                        .help("Select shapes in the Design list, then click to assign them to this toolpath")
                }
            }
            if let blank = project.stock.rotary, blank.isWrapped, op.indexAngles == nil, op.kind.needsShapes {
                WrapNoteSection(blank: blank, units: units)
            } else if (project.stock.rotary != nil && op.kind.takesIndexAngles) || op.indexAngles != nil {
                IndexAnglesSection(angles: $op.indexAngles, blank: project.stock.rotary)
            }
            ToolSection(tool: $op.tool, units: units, library: library, material: project.stock.material, machine: project.machine)
            parameters
            if project.stock.rotary != nil, let job = workspace.job,
               case let tps = job.toolpaths.filter({ $0.sourceOperationID == op.id }), tps.count > 1 {
                IndexedResultSection(toolpaths: tps, job: job, rapidRate: project.machine.rapidRateForEstimates, units: units)
            } else if let job = workspace.job, case let tps = job.toolpaths.filter({ $0.sourceOperationID == op.id }), tps.count > 1 {
                // A rest-machined pocket: the larger bit's clearing, then this toolpath's own.
                Section("Result") {
                    let rate = project.machine.rapidRateForEstimates
                    let seconds = tps.map { job.estimatedSeconds(toolpath: $0.id) ?? $0.estimatedSeconds(rapidRate: rate) }
                    LabeledContent("Cutting length", value: "\(units.format(tps.reduce(0) { $0 + $1.cuttingLength }, decimals: 1)) \(units.symbol)")
                    LabeledContent("Estimated time", value: formatDuration(seconds.reduce(0, +)))
                    ForEach(Array(tps.enumerated()), id: \.element.id) { i, tp in
                        LabeledContent("   T\(tp.tool.number) \(tp.tool.name)", value: formatDuration(seconds[i]))
                    }
                    if let deepest = tps.compactMap({ $0.cuttingExtents.map { -$0.min.z } }).max() {
                        LabeledContent("Deepest cut", value: "\(units.format(deepest)) \(units.symbol)")
                    }
                }
            } else if let tp = workspace.job?.toolpaths.first(where: { $0.sourceOperationID == op.id }) {
                Section("Result") {
                    LabeledContent("Cutting length", value: "\(units.format(tp.cuttingLength, decimals: 1)) \(units.symbol)")
                    LabeledContent("Estimated time", value: formatDuration(workspace.job?.estimatedSeconds(toolpath: tp.id)
                                                                          ?? tp.estimatedSeconds(rapidRate: project.machine.rapidRateForEstimates)))
                    if let e = tp.cuttingExtents {
                        LabeledContent("Deepest cut", value: "\(units.format(-e.min.z)) \(units.symbol)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var parameters: some View {
        switch op.kind {
        case let .profile(p):
            let set: (ProfileParams) -> Void = { op.kind = .profile($0) }
            Section("Profile") {
                Picker("Side", selection: Binding(get: { p.side }, set: { var q = p; q.side = $0; set(q) })) {
                    ForEach(CutSide.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Direction", selection: Binding(get: { p.direction }, set: { var q = p; q.direction = $0; set(q) })) {
                    ForEach(CutDirection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = $0; set(q) }), units: units,
                            help: "Material left on the wall for a finishing pass")
            }
            DepthSection(depth: Binding(get: { p.depth }, set: { var q = p; q.depth = $0; set(q) }), tool: op.tool, stock: project.stock, units: units)
            EntrySection(entry: Binding(get: { p.entry }, set: { var q = p; q.entry = $0; set(q) }), units: units)
            LeadsSection(leads: Binding(get: { p.leads }, set: { var q = p; q.leads = $0; set(q) }), side: p.side, tool: op.tool, units: units)
            CornersSection(relief: Binding(get: { p.cornerRelief }, set: { var q = p; q.cornerRelief = $0; set(q) }),
                           available: p.side != .on)
            Section("Tabs") {
                Toggle("Add tabs", isOn: Binding(get: { p.tabs.enabled }, set: { var q = p; q.tabs.enabled = $0; set(q) }))
                if p.tabs.enabled {
                    IntField(title: "Tabs per contour", value: Binding(get: { p.tabs.count }, set: { var q = p; q.tabs.count = $0; set(q) }), range: 1...40)
                    LengthField(title: "Tab length", mm: Binding(get: { p.tabs.width }, set: { var q = p; q.tabs.width = max(0.1, $0); set(q) }), units: units)
                    LengthField(title: "Tab thickness", mm: Binding(get: { p.tabs.thickness }, set: { var q = p; q.tabs.thickness = max(0.1, $0); set(q) }), units: units)
                }
            }
        case let .pocket(p):
            let set: (PocketParams) -> Void = { op.kind = .pocket($0) }
            Section("Pocket") {
                Picker("Strategy", selection: Binding(get: { p.strategy }, set: { var q = p; q.strategy = $0; set(q) })) {
                    ForEach(PocketStrategy.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if p.strategy == .raster {
                    NumberField(title: "Raster angle", value: Binding(get: { p.rasterAngle }, set: { var q = p; q.rasterAngle = $0; set(q) }), suffix: "°", decimals: 1)
                }
                Picker("Direction", selection: Binding(get: { p.direction }, set: { var q = p; q.direction = $0; set(q) })) {
                    ForEach(CutDirection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction ?? op.tool.cutting.stepoverFraction },
                                                                 set: { var q = p; q.stepoverFraction = $0; set(q) }))
                LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = $0; set(q) }), units: units)
            }
            RestMachiningSection(params: Binding(get: { p }, set: { set($0) }), tool: op.tool, units: units)
            DepthSection(depth: Binding(get: { p.depth }, set: { var q = p; q.depth = $0; set(q) }), tool: op.tool, stock: project.stock, units: units)
            EntrySection(entry: Binding(get: { p.entry }, set: { var q = p; q.entry = $0; set(q) }), units: units)
            CornersSection(relief: Binding(get: { p.cornerRelief }, set: { var q = p; q.cornerRelief = $0; set(q) }), available: true)
        case let .drill(p):
            let set: (DrillParams) -> Void = { op.kind = .drill($0) }
            Section("Drilling") {
                LengthField(title: "Hole depth", mm: Binding(get: { p.depth }, set: { var q = p; q.depth = max(0.01, $0); set(q) }), units: units)
                Button("Through material (+0.02 in)") { var q = p; q.depth = project.stock.thickness + 0.02.inch; set(q) }
                LengthField(title: "Peck depth", mm: Binding(get: { p.peckDepth }, set: { var q = p; q.peckDepth = max(0, $0); set(q) }), units: units,
                            help: "0 = single plunge")
                Toggle("Full retract between pecks", isOn: Binding(get: { p.fullRetract }, set: { var q = p; q.fullRetract = $0; set(q) }))
                NumberField(title: "Dwell at bottom", value: Binding(get: { p.dwell }, set: { var q = p; q.dwell = max(0, $0); set(q) }), suffix: "s", decimals: 1)
            }
        case let .rough3D(p):
            let set: (Rough3DParams) -> Void = { op.kind = .rough3D($0) }
            Section("3D Roughing") {
                Picker("Machine", selection: Binding(get: { p.boundary }, set: { var q = p; q.boundary = $0; set(q) })) {
                    ForEach(ModelBoundary.allCases) { Text($0.label).tag($0) }
                }
                if p.boundary == .vectors {
                    LengthField(title: "Boundary margin", mm: Binding(get: { p.boundaryMargin ?? Rough3DParams.autoMargin(tool: op.tool) },
                                                                    set: { var q = p; q.boundaryMargin = max(0, $0); set(q) }), units: units,
                                help: "How far past the selected vectors roughing clears. Automatic: tool diameter + 1 mm")
                    BoundaryNote(automatic: p.boundaryMargin == nil) { var q = p; q.boundaryMargin = nil; set(q) }
                }
                LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = max(0, $0); set(q) }), units: units,
                            help: "Material left on the model for the finishing pass")
                LengthField(title: "Layer depth", mm: Binding(get: { p.passDepth ?? op.tool.cutting.stepdown }, set: { var q = p; q.passDepth = max(0.05, $0); set(q) }),
                            units: units)
                PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction ?? op.tool.cutting.stepoverFraction },
                                                                 set: { var q = p; q.stepoverFraction = $0; set(q) }))
                Text("Clears the model in layers with a flat end mill, leaving the allowance for finishing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case let .finish3D(p):
            let set: (Finish3DParams) -> Void = { op.kind = .finish3D($0) }
            Section("3D Finishing") {
                Picker("Machine", selection: Binding(get: { p.boundary }, set: { var q = p; q.boundary = $0; set(q) })) {
                    ForEach(ModelBoundary.allCases) { Text($0.label).tag($0) }
                }
                if p.boundary == .vectors {
                    LengthField(title: "Boundary margin", mm: Binding(get: { p.boundaryMargin ?? Finish3DParams.autoMargin(tool: op.tool) },
                                                                    set: { var q = p; q.boundaryMargin = max(0, $0); set(q) }), units: units,
                                help: "How far past the selected vectors the tool centre may go. Automatic: tool radius + 0.5 mm")
                    BoundaryNote(automatic: p.boundaryMargin == nil) { var q = p; q.boundaryMargin = nil; set(q) }
                }
                PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction }, set: { var q = p; q.stepoverFraction = $0; set(q) }))
                LabeledContent("Scallop height", value: "\(units.format(scallop(tool: op.tool, stepover: op.tool.diameter * p.stepoverFraction), decimals: 4)) \(units.symbol)")
                NumberField(title: "Raster angle", value: Binding(get: { p.rasterAngle }, set: { var q = p; q.rasterAngle = $0; set(q) }), suffix: "°", decimals: 1)
                LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = max(0, $0); set(q) }), units: units)
                Text("Raster passes that follow the model surface; a ball-nose bit gives the smoothest result.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case let .vcarve(p):
            let set: (VCarveParams) -> Void = { op.kind = .vcarve($0) }
            InlaySection(params: p, op: $op, project: project, units: units, set: set)
            Section("V-carve") {
                if !p.isPlug {
                    LengthField(title: "Start depth", mm: Binding(get: { p.startDepth }, set: { var q = p; q.startDepth = $0; set(q) }),
                                units: units,
                                help: "Depth the carve is calculated from: 0 on the material top, or an existing pocket's depth to carve inside it",
                                minimum: 0)
                    if p.inlay?.role != .pocket || p.flatDepth == nil {
                        Toggle("Flat bottom", isOn: Binding(get: { p.flatDepth != nil }, set: { var q = p; q.flatDepth = $0 ? 0.125.inch : nil; set(q) }))
                    }
                }
                if let flat = p.carveFlatDepth {
                    if let f = p.flatDepth, !p.isPlug {
                        LengthField(title: "Flat depth", mm: Binding(get: { f }, set: { var q = p; q.flatDepth = max(0.01, $0); set(q) }), units: units,
                                    help: "Measured down from the start depth, as in Vectric VCarve")
                        if p.startDepth > 1e-9 {
                            LabeledContent("Deepest cut", value: "\(units.format(p.startDepth + flat)) \(units.symbol)")
                        }
                    }
                    Picker("Clear flat area with", selection: Binding(get: { p.clearanceTool?.id }, set: { id in
                        var q = p
                        q.clearanceTool = id.flatMap { library.tool(id: $0) }
                        set(q)
                    })) {
                        Text("None (V-bit only)").tag(UUID?.none)
                        ForEach(library.tools.filter { !$0.shape.isTapered }) { t in
                            Text("T\(t.number) \(t.name)").tag(Optional(t.id))
                        }
                    }
                }
                Toggle("Multiple passes", isOn: Binding(get: { p.passDepth != nil }, set: { var q = p; q.passDepth = $0 ? op.tool.cutting.stepdown : nil; set(q) }))
                if let pd = p.passDepth {
                    LengthField(title: "Max pass depth", mm: Binding(get: { pd }, set: { var q = p; q.passDepth = max(0.05, $0); set(q) }), units: units)
                }
                LengthField(title: "Sample spacing", mm: Binding(get: { p.sampleSpacing }, set: { var q = p; q.sampleSpacing = max(0.05, $0); set(q) }), units: units,
                            help: "Smaller is smoother but makes longer G-code")
                if op.tool.shape.isTapered {
                    LabeledContent("Max V depth", value: "\(units.format(op.tool.taperHeight)) \(units.symbol)")
                }
            }
        case let .rounding(p):
            let set: (RoundingParams) -> Void = { op.kind = .rounding($0) }
            let blank = project.stock.rotary
            let auto = blank.map { RoundingParams().finishedDiameter(on: $0) }
            Section("Rounding") {
                OptionalLengthField(title: "Finished diameter", mm: Binding(get: { p.finishedDiameter }, set: { var q = p; q.finishedDiameter = $0; set(q) }),
                                    units: units,
                                    prompt: auto.map { units.fromMM($0).formatted(.number.precision(.fractionLength(0...units.displayDecimals))) } ?? "",
                                    help: "Empty: the wrap diameter on a wrapped job, the blank's own (across the faces) otherwise")
                Picker("Passes", selection: Binding(get: { p.method }, set: { var q = p; q.method = $0; set(q) })) {
                    ForEach(RoundingParams.Method.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LengthField(title: "Layer depth", mm: Binding(get: { p.passDepth ?? op.tool.cutting.stepdown }, set: { var q = p; q.passDepth = max(0.05, $0); set(q) }),
                            units: units)
                PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction ?? op.tool.cutting.stepoverFraction },
                                                                 set: { var q = p; q.stepoverFraction = $0; set(q) }))
                OptionalLengthField(title: "Start (X)", mm: Binding(get: { p.startX }, set: { var q = p; q.startX = $0; set(q) }), units: units,
                                    prompt: units.fromMM(op.tool.radius).formatted(.number.precision(.fractionLength(0...units.displayDecimals))),
                                    help: "Where along the blank the rounding starts; empty keeps the cutter just inside the end")
                OptionalLengthField(title: "End (X)", mm: Binding(get: { p.endX }, set: { var q = p; q.endX = $0; set(q) }), units: units,
                                    prompt: blank.map { units.fromMM($0.length - op.tool.radius).formatted(.number.precision(.fractionLength(0...units.displayDecimals))) } ?? "",
                                    help: "Where along the blank the rounding ends; empty keeps the cutter just inside the end")
                Text(p.method == .radial
                     ? "Turns the blank round in layers, each a spiral along it: smooth, and best when the rotary is quick."
                     : "Turns the blank round in layers of passes along it, stepping round between them; on a square bar it skips the faces until the layers reach them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A V-carve's inlay role: none, the pocket (female) or the plug (male), with the plug's settings (Vectric's pocket
/// depth, glue gap and surface clearance) and the depths they give.
struct InlaySection: View {
    let params: VCarveParams
    @Binding var op: CAMOperation
    let project: Project
    let units: LengthUnit
    let set: (VCarveParams) -> Void

    enum Choice: String, CaseIterable, Identifiable {
        case none, pocket, plug
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

    /// The pocket this plug goes into, and its flat depth.
    private var pocket: (op: CAMOperation, flat: Double?)? {
        guard let p = project.inlayPocket(for: op), case let .vcarve(q) = p.kind else { return nil }
        return (p, q.flatDepth)
    }

    private func choose(_ choice: Choice) {
        var q = params
        switch choice {
        case .none:
            q.inlay = nil
        case .pocket:
            q.inlay = VCarveInlay(role: .pocket)
            q.flatDepth = q.flatDepth ?? VCarveInlay.defaultPocketDepth
        case .plug:
            var inlay = params.inlay ?? VCarveInlay(role: .plug)
            inlay.role = .plug
            // Start from settings that seat in this project's pocket, cut with its bit.
            if let pocket {
                if let flat = pocket.flat { inlay.pocketDepth = flat }
                if !pocket.op.tool.isSameBit(as: op.tool) { op.tool = pocket.op.tool }
                if case let .vcarve(pq) = pocket.op.kind, q.clearanceTool == nil { q.clearanceTool = pq.clearanceTool }
            }
            q.inlay = inlay
        }
        set(q)
    }

    private func value(_ key: WritableKeyPath<VCarveInlay, Double>, minimum: Double) -> Binding<Double> {
        Binding(get: { params.inlay?[keyPath: key] ?? 0 }, set: { v in
            var q = params
            q.inlay?[keyPath: key] = max(minimum, v)
            set(q)
        })
    }

    var body: some View {
        Section("Inlay") {
            Picker("Inlay", selection: Binding(get: {
                switch params.inlay?.role {
                case .pocket: Choice.pocket
                case .plug: Choice.plug
                case nil: Choice.none
                }
            }, set: choose)) {
                ForEach(Choice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if let inlay = params.inlay {
                switch inlay.role {
                case .pocket:
                    Text("The pocket for a V-carve inlay: an ordinary V-carve to its flat depth. Make the plug with a second V-carve set to Plug, using the same V-bit and this flat depth as its pocket depth.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .plug:
                    plugSettings(inlay)
                }
            }
        }
    }

    @ViewBuilder
    private func plugSettings(_ inlay: VCarveInlay) -> some View {
        LengthField(title: "Pocket depth", mm: value(\.pocketDepth, minimum: 0.01), units: units,
                    help: "The flat depth of the V-carve pocket this plug goes into")
        if let pocket, let flat = pocket.flat, abs(flat - inlay.pocketDepth) > 0.005 {
            HStack(alignment: .firstTextBaseline) {
                Label("“\(pocket.op.name)” is \(len(flat)) deep", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
                Spacer(minLength: 4)
                Button("Match") { var q = params; q.inlay?.pocketDepth = flat; set(q) }
                    .controlSize(.small)
                    .help("Set the pocket depth to that pocket's flat depth")
            }
        }
        LengthField(title: "Glue gap", mm: value(\.glueGap, minimum: 0), units: units,
                    help: "The gap left between the plug's face and the pocket's floor, for glue")
        LengthField(title: "Surface clearance", mm: value(\.surfaceClearance, minimum: 0.01), units: units,
                    help: "How far the plug board stays above the pocket board when the walls meet: room to clamp it in, and the waste you saw or plane off")
        Picker("Boundary", selection: Binding(get: { inlay.boundary }, set: { b in var q = params; q.inlay?.boundary = b; set(q) })) {
            ForEach(VCarveInlay.Boundary.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Where the carving round the design stops: a margin round it, or a closed vector selected round it with the design")
        if inlay.boundary == .vector {
            if let boundary = project.plugBoundary(for: op) {
                LabeledContent("Boundary vector", value: boundary.name)
            } else {
                Label("Select a closed vector round the design with it; until then the margin is used.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        if inlay.boundary == .margin || project.plugBoundary(for: op) == nil {
            LengthField(title: "Boundary margin", mm: value(\.boundaryMargin, minimum: 0.1), units: units,
                        help: "How far past the design the plug is carved")
        }
        LabeledContent("Start depth", value: len(inlay.plugStartDepth))
        LabeledContent("Cut depth", value: len(inlay.plugCutDepth))
        Text("Carves around the design, mirrored left to right, so the design stands proud. Turned over, it goes into the pocket until the walls meet, with the glue gap under its face: start depth = pocket depth − glue gap. Cut it from its own board with the same V-bit as the pocket, saw it free inside the carved band, glue it in and plane it flush.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Explains the "Selected vectors" boundary and offers a way back to the automatic margin.
struct BoundaryNote: View {
    let automatic: Bool
    let reset: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Stays inside the closed vectors in this toolpath's shapes (select the model with the cut-out outline).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !automatic {
                Spacer(minLength: 4)
                Button("Automatic", action: reset).controlSize(.small)
            }
        }
    }
}

/// Theoretical scallop (cusp) height left between parallel passes of a ball-ended tool on a flat surface.
func scallop(tool: Tool, stepover: Double) -> Double {
    let R = tool.shape == .ballNose ? tool.radius : (tool.shape == .bullNose ? tool.cornerRadius : 0)
    guard R > 0, stepover < 2 * R else { return 0 }
    return R - (R * R - stepover * stepover / 4).squareRoot()
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct DepthSection: View {
    @Binding var depth: DepthSettings
    let tool: Tool
    let stock: Stock
    let units: LengthUnit

    var body: some View {
        Section("Depth") {
            LengthField(title: "Start depth", mm: $depth.startDepth, units: units, minimum: 0)
            LengthField(title: "Cut depth", mm: $depth.cutDepth, units: units, minimum: 0.01)
            HStack {
                Spacer()
                Button("Through (+0.02 in)") { depth.cutDepth = stock.thickness + 0.02.inch }
                    .help("Material thickness plus a small breakthrough into the spoilboard")
            }
            LengthField(title: "Pass depth", mm: Binding(get: { depth.passDepth ?? tool.cutting.stepdown }, set: { depth.passDepth = max(0.05, $0) }),
                        units: units, help: "Defaults to the tool's stepdown")
            let passes = depth.passLevels(toolStepdown: tool.cutting.stepdown, firstPassMinimum: tool.firstPassMinimum).count
            LabeledContent("Passes", value: "\(passes)")
            if depth.cutDepth > stock.thickness + 0.04.inch {
                Label("Deeper than the material (\(units.format(stock.thickness)) \(units.symbol))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
            if depth.cutDepth > tool.fluteLength {
                Label("Deeper than the tool's cutting length", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
        }
    }
}

struct EntrySection: View {
    @Binding var entry: EntrySettings
    let units: LengthUnit

    var body: some View {
        Section("Entry") {
            Picker("Entry", selection: $entry.kind) {
                ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if entry.kind == .ramp {
                LengthField(title: "Ramp length", mm: $entry.rampLength, units: units, minimum: 1)
            }
        }
    }
}

/// Lead-in and lead-out moves for a profile's closed loops.
struct LeadsSection: View {
    @Binding var leads: LeadSettings?
    let side: CutSide
    let tool: Tool
    let units: LengthUnit

    enum Choice: String, CaseIterable, Identifiable {
        case none, arc, line
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private func value<T>(_ key: WritableKeyPath<LeadSettings, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { leads?[keyPath: key] ?? fallback }, set: { leads?[keyPath: key] = $0 })
    }

    var body: some View {
        Section("Leads") {
            if side == .on {
                Text("Leads need an inside or outside cut.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Lead", selection: Binding(get: { leads.map { $0.kind == .arc ? Choice.arc : .line } ?? .none }, set: { choice in
                    switch choice {
                    case .none: leads = nil
                    case .arc, .line:
                        // New leads start at the bit's diameter.
                        var l = leads ?? LeadSettings(radius: tool.diameter, length: tool.diameter)
                        l.kind = choice == .arc ? .arc : .line
                        leads = l
                    }
                })) {
                    ForEach(Choice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if let l = leads {
                    if l.kind == .arc {
                        LengthField(title: "Radius", mm: value(\.radius, tool.diameter), units: units, help: "Radius of the arc onto the cut",
                                    minimum: 0.1)
                        NumberField(title: "Sweep", value: value(\.sweep, 90), suffix: "°", decimals: 0, range: 15...180)
                            .help("How far round the arc turns onto the cut")
                    } else {
                        LengthField(title: "Length", mm: value(\.length, tool.diameter), units: units, minimum: 0.1)
                        NumberField(title: "Angle", value: value(\.angle, 45), suffix: "°", decimals: 0, range: 10...90)
                            .help("Angle between the lead and the cut; 90° comes in square to it")
                    }
                    Toggle("Lead out", isOn: value(\.leadOut, true))
                    LengthField(title: "Overlap", mm: value(\.overlap, 0), units: units,
                                help: "How far the last lap runs past its start before leading out, to hide the seam", minimum: 0)
                    Text("Each loop starts and ends with a short move in the waste, so the bit never plunges or stops against the finished edge. Ramps run along the lead.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Dogbone and T-bone relief for inside corners.
struct CornersSection: View {
    @Binding var relief: CornerReliefSettings?
    /// False for "On" profiles, which have no waste side.
    let available: Bool

    enum Choice: String, CaseIterable, Identifiable {
        case rounded, dogbone, tBone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rounded: "Rounded"
            case .dogbone: "Dogbone"
            case .tBone: "T-bone"
            }
        }
    }

    var body: some View {
        Section("Corners") {
            if !available {
                Text("Corner reliefs need an inside or outside cut.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Inside corners", selection: Binding(get: {
                    relief.map { $0.style == .dogbone ? Choice.dogbone : .tBone } ?? .rounded
                }, set: { choice in
                    switch choice {
                    case .rounded: relief = nil
                    case .dogbone, .tBone:
                        var r = relief ?? CornerReliefSettings()
                        r.style = choice == .dogbone ? .dogbone : .tBone
                        relief = r
                    }
                })) {
                    ForEach(Choice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if let r = relief {
                    if r.style == .tBone {
                        Picker("T-bone side", selection: Binding(get: { r.tBoneSide }, set: { relief?.tBoneSide = $0 })) {
                            ForEach(TBoneSide.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    NumberField(title: "Corners up to", value: Binding(get: { r.maxCornerAngle }, set: { relief?.maxCornerAngle = $0 }),
                                suffix: "°", decimals: 0, range: 10...170)
                        .help("A square corner is 90°. Flatter corners are left rounded.")
                    if let n = r.overrides?.count, n > 0 {
                        HStack {
                            Text("\(n) corner\(n == 1 ? "" : "s") set on the canvas")
                            Spacer()
                            Button("Reset") { relief?.overrides = nil }
                                .controlSize(.small)
                                .help("Put every corner back to this toolpath's setting")
                        }
                    }
                    Text("Click a corner's circle on the canvas to change that corner: dogbone, T-bone into either side, or none. Right-click it for the choices.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Cuts just past each inside corner the bit can't reach, so square parts fit. A dogbone cuts into the corner; a T-bone cuts into one side only, which is easier to hide and better for slots about as wide as the bit.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Rest machining for a pocket: a larger end mill clears it first, and this toolpath's tool only cuts what that
/// one can't reach.
struct RestMachiningSection: View {
    @Binding var params: PocketParams
    let tool: Tool
    let units: LengthUnit
    @Environment(ToolLibraryStore.self) private var library

    /// Flat-bottomed bits that can clear a pocket floor.
    private var flatTools: [Tool] { library.tools.filter { $0.shape == .flatEndMill || $0.shape == .surfacing } }

    /// The smallest end mill at least half as big again as this toolpath's (a 1/4" for a 1/8"), else the largest
    /// larger one.
    private var suggested: Tool? {
        let mills = library.tools.filter { $0.shape == .flatEndMill && $0.diameter > tool.diameter + 1e-6 }
        return mills.filter { $0.diameter >= 1.5 * tool.diameter - 1e-6 }.min { $0.diameter < $1.diameter }
            ?? mills.max { $0.diameter < $1.diameter }
    }

    var body: some View {
        Section("Rest machining") {
            Toggle("Clear with a larger tool first", isOn: Binding(get: { params.clearanceTool != nil }, set: { on in
                params.clearanceTool = on ? suggested ?? flatTools.first : nil
            }))
            .disabled(params.clearanceTool == nil && flatTools.isEmpty)
            if let large = params.clearanceTool {
                let inLibrary = flatTools.contains { $0.id == large.id }
                Picker("Larger tool", selection: Binding(get: { large.id }, set: { id in
                    if let t = library.tool(id: id) { params.clearanceTool = t }
                })) {
                    if !inLibrary { Text("T\(large.number) \(large.name) (project copy)").tag(large.id) }
                    ForEach(flatTools) { t in Text("T\(t.number) \(t.name)").tag(t.id) }
                }
                let leave = params.allowance + PocketParams.restMargin(for: tool)
                if large.diameter > tool.diameter + 1e-6 {
                    Text("\(large.name) clears the pocket first with its own stepover, pass depth and feeds, leaving "
                        + "\(units.format(leave)) \(units.symbol) on the walls. \(tool.name) then cuts only the corners and narrow parts "
                        + "the larger bit can't reach, and the final pass round the walls. Toolpaths next to each other that clear "
                        + "with the same bit share its tool change.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Choose a tool larger than this toolpath's \(tool.name).")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Clears the bulk with a big bit and sends this toolpath's bit only where the big one can't reach.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Tool choice plus the operation's own copy of feeds and speeds.
struct ToolSection: View {
    @Binding var tool: Tool
    let units: LengthUnit
    let library: ToolLibraryStore
    var material: MaterialKind = .plywood
    var machine: MachineProfile = .avidPRO6060

    var body: some View {
        Section("Tool") {
            let match = library.tools.first { $0.id == tool.id } ?? library.tools.first { $0.number == tool.number && $0.name == tool.name }
            Picker("Tool", selection: Binding(get: { match?.id }, set: { id in
                if let id, let t = library.tool(id: id) { tool = t }
            })) {
                if match == nil {
                    Text("T\(tool.number) \(tool.name) (project copy)").tag(UUID?.none)
                }
                ForEach(library.tools) { t in Text("T\(t.number) \(t.name)").tag(Optional(t.id)) }
            }
            HStack(alignment: .center, spacing: 12) {
                ToolShapeView(tool: tool, units: units).frame(width: 140, height: 150)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.shape.label).font(.headline)
                    Text("\(tool.fluteCount) flute \(tool.fluteDirection.label.lowercased())")
                    if tool.shape.isTapered { Text("\(Int(tool.includedAngle))° included") }
                    Text("Chip load \(units.format(tool.chipLoad, decimals: 4)) \(units.symbol)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            NumberField(title: "Spindle", value: $tool.cutting.spindleRPM, suffix: "RPM", decimals: 0, range: 1000...60000)
            FeedField(title: "Feed", mmPerMin: $tool.cutting.feedRate, units: units)
            FeedField(title: "Plunge", mmPerMin: $tool.cutting.plungeRate, units: units)
            LengthField(title: "Stepdown", mm: $tool.cutting.stepdown, units: units, minimum: 0.05)
            PercentField(title: "Stepover", fraction: $tool.cutting.stepoverFraction)
            if ChipLoad.applies(to: tool) {
                ChipLoadRow(tool: $tool, material: material, machine: machine, units: units)
            }
        }
    }
}

/// Chip load against the chart for the job's material, with a one-click recommendation.
struct ChipLoadRow: View {
    @Binding var tool: Tool
    let material: MaterialKind
    let machine: MachineProfile
    let units: LengthUnit

    var body: some View {
        let r = ChipLoad.range(material, diameter: tool.diameter)
        let chip = tool.chipLoad
        let floor = r.lowerBound * (tool.shape == .flatEndMill ? 0.9 : 0.8)
        let status: (String, Color) = chip < floor ? ("exclamationmark.triangle.fill", .orange)
            : chip > r.upperBound * 1.25 ? ("exclamationmark.circle", .secondary) : ("checkmark.circle.fill", .green)
        let inch = { (mm: Double) in String(format: "%.4f", mm / LengthUnit.mmPerInch) }
        LabeledContent {
            Label("\(inch(chip)) in", systemImage: status.0).foregroundStyle(status.1).labelStyle(.titleAndIcon)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Chip load")
                Text("\(material.label): \(inch(r.lowerBound))–\(inch(r.upperBound)) in").font(.caption).foregroundStyle(.secondary)
            }
        }
        let rec = ChipLoad.recommend(for: tool, material: material, machine: machine)
        HStack {
            Spacer()
            Button("Use Recommended: \(units.format(rec.feed, decimals: 0)) \(units == .inch ? "ipm" : "mm/min") @ \(Int(rec.rpm.rounded())) RPM") {
                tool.cutting.feedRate = rec.feed
                tool.cutting.spindleRPM = rec.rpm
            }
            .controlSize(.small)
            .help("Chip load a quarter into the chart range, feed held within the machine's cutting cap by lowering RPM")
        }
    }
}
