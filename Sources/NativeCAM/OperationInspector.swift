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
                LabeledContent("Shapes", value: "\(op.shapeIDs.count)")
                Button("Use Selected Shapes") { op.shapeIDs = workspace.selectedShapeIDs }
                    .disabled(workspace.selectedShapeIDs.isEmpty)
                    .help("Select shapes in the Design list, then click to assign them to this toolpath")
            }
            ToolSection(tool: $op.tool, units: units, library: library, material: project.stock.material, machine: project.machine)
            parameters
            if let tp = workspace.job?.toolpaths.first(where: { $0.sourceOperationID == op.id }) {
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
            DepthSection(depth: Binding(get: { p.depth }, set: { var q = p; q.depth = $0; set(q) }), tool: op.tool, stock: project.stock, units: units)
            EntrySection(entry: Binding(get: { p.entry }, set: { var q = p; q.entry = $0; set(q) }), units: units)
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
            Section("V-carve") {
                Toggle("Flat bottom", isOn: Binding(get: { p.flatDepth != nil }, set: { var q = p; q.flatDepth = $0 ? 0.125.inch : nil; set(q) }))
                if let flat = p.flatDepth {
                    LengthField(title: "Flat depth", mm: Binding(get: { flat }, set: { var q = p; q.flatDepth = max(0.01, $0); set(q) }), units: units)
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
        }
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
