import CAMCore
import SwiftUI

struct OperationInspector: View {
    @Binding var op: CAMOperation
    let project: Project
    let workspace: Workspace
    /// Replaces another toolpath in the project (an inlay's other side, when its shared settings are brought in line).
    var updateOperation: (CAMOperation) -> Void = { _ in }
    @Environment(ToolLibraryStore.self) private var library

    var units: LengthUnit { project.displayUnits }

    var body: some View {
        Form {
            Section(op.kind.label) {
                TextField("Name", text: $op.name)
                Toggle("Include in output", isOn: $op.enabled)
                if op.kind.needsShapes {
                    VectorRows(op: $op, project: project, selected: workspace.selectedShapeIDs)
                }
            }
            if let blank = project.stock.rotary, blank.isWrapped, op.indexAngles == nil, op.kind.needsShapes, !op.kind.turnsWholeBlank {
                WrapNoteSection(blank: blank, units: units)
            } else if (project.stock.rotary != nil && op.kind.takesIndexAngles) || op.indexAngles != nil {
                IndexAnglesSection(angles: $op.indexAngles, blank: project.stock.rotary)
            }
            ToolSection(tool: $op.tool, units: units, library: library, material: project.stock.material, machine: project.machine,
                        kind: op.kind, loadFeeds: op.kind.takesLoadFeeds ? $op.adjustFeedsForLoad : nil,
                        wrapped: project.stock.rotary?.isWrapped == true, radialLoad: adaptiveLoad, loopFeedLimit: adaptiveLoopLimit)
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
                        LabeledContent("   \(tp.tile.map { "Tile \($0 + 1) · " } ?? "")T\(tp.tool.number) \(tp.tool.name)", value: formatDuration(seconds[i]))
                        if let lf = tp.loadFeeds, lf.varies { LoadFeedsRow(feeds: lf, units: units, indent: true) }
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
                    if let lf = tp.loadFeeds, lf.varies { LoadFeedsRow(feeds: lf, units: units) }
                    if let e = tp.cuttingExtents {
                        LabeledContent("Deepest cut", value: "\(units.format(-e.min.z)) \(units.symbol)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// An adaptive pocket's optimal load, which thins its chip. (With a clearance tool, the pocket's own bit cuts offset
    /// rings, so its chip isn't thinned.)
    private var adaptiveLoad: Double? {
        if case let .pocket(p) = op.kind, p.strategy == .adaptive, p.clearanceTool == nil { return p.adaptiveSettings.load }
        return nil
    }

    /// The fastest an adaptive pocket's loops can run on this machine, which the recommended feed keeps to.
    private var adaptiveLoopLimit: Double? {
        if case let .pocket(p) = op.kind, p.strategy == .adaptive, p.clearanceTool == nil {
            return p.adaptiveSettings.loopFeedLimit(tool: op.tool, machine: project.machine)
        }
        return nil
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
                if p.strategy == .adaptive {
                    AdaptiveRows(params: p, tool: op.tool, machine: project.machine, units: units, set: set)
                } else {
                    PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction ?? op.tool.cutting.stepoverFraction },
                                                                     set: { var q = p; q.stepoverFraction = $0; set(q) }))
                }
                LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = $0; set(q) }), units: units)
            }
            RestMachiningSection(params: Binding(get: { p }, set: { set($0) }), tool: op.tool, units: units,
                                 earlier: p.restsFromEarlier ? RestMachining.pocketReferences(for: op, in: project) : nil,
                                 left: workspace.job?.toolpaths.last { $0.sourceOperationID == op.id }?.restAreas)
            DepthSection(depth: Binding(get: { p.depth }, set: { var q = p; q.depth = $0; set(q) }), tool: op.tool, stock: project.stock, units: units,
                         defaultPassDepth: p.defaultPassDepth(op.tool),
                         passHelp: p.strategy == .adaptive ? "Defaults to the tool's flute length: adaptive cuts the full depth of its flutes at once" : nil)
            if p.strategy == .adaptive {
                Section("Entry") {
                    Text("Enters each area on a 2° helix, or ramps along it where a helix doesn't fit.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                EntrySection(entry: Binding(get: { p.entry }, set: { var q = p; q.entry = $0; set(q) }), units: units)
            }
            CornersSection(relief: Binding(get: { p.cornerRelief }, set: { var q = p; q.cornerRelief = $0; set(q) }), available: true)
        case let .drill(p):
            let set: (DrillParams) -> Void = { op.kind = .drill($0) }
            Section("Drilling") {
                MaterialDepthRows(title: "Hole depth",
                                  value: Binding(get: { MaterialDepthValue(depth: p.depth, fromBottom: p.fromBottom) },
                                                 set: { var q = p; q.depth = max(0.01, $0.depth); q.fromBottom = $0.fromBottom; set(q) }),
                                  stock: project.stock, units: units)
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
            let stepover = op.tool.stepoverBasis * p.stepoverFraction
            Section("3D Finishing") {
                Picker("Strategy", selection: Binding(get: { p.strategy }, set: {
                    var q = p
                    q.strategy = $0
                    // A rest pass starts from the defaults in the job's units.
                    if $0 == .rest, q.rest == nil { q.rest = .defaults(for: units) }
                    set(q)
                })) {
                    ForEach(Finish3DStrategy.allCases) { Text($0.label).tag($0) }
                }
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
                if p.strategy != .pencil {
                    LabeledContent("Scallop height", value: "\(units.format(scallop(tool: op.tool, stepover: stepover), decimals: 4)) \(units.symbol)")
                }
                if p.strategy.usesRaster {
                    NumberField(title: "Raster angle", value: Binding(get: { p.rasterAngle }, set: { var q = p; q.rasterAngle = $0; set(q) }), suffix: "°", decimals: 1)
                    Toggle("Cross-hatch", isOn: Binding(get: { p.crossHatch }, set: { var q = p; q.crossHatch = $0; set(q) }))
                        .help("A second raster at the raster angle + 90° in the same toolpath: smoother where slopes run along the rows, about twice the time")
                }
                if p.strategy.usesWaterline {
                    NumberField(title: "Steep angle", value: Binding(get: { p.steepAngleInUse }, set: { var q = p; q.steepAngle = $0; set(q) }),
                                suffix: "°", decimals: 0, range: 5...85)
                        .help(p.strategy == .steepShallow
                              ? "Slope from horizontal above which waterline loops take over from the raster. It also sets the Z step"
                              : "Sets the Z step: on a slope this steep the loops are a stepover apart, closer on steeper walls")
                    LabeledContent("Z step", value: "\(units.format(p.waterlineStep(tool: op.tool), decimals: 4)) \(units.symbol)")
                }
                if p.strategy == .steepShallow {
                    LabeledContent("Scallop at the seam",
                                   value: "\(units.format(scallop(tool: op.tool, stepover: stepover / cos(p.steepAngleInUse * .pi / 180)), decimals: 4)) \(units.symbol)")
                    LengthField(title: "Overlap", mm: Binding(get: { p.overlapInUse(tool: op.tool) }, set: { var q = p; q.overlap = max(0, $0); set(q) }),
                                units: units, help: "How far each strategy runs past the seam into the other's area. Automatic: a quarter of the tool diameter")
                    if p.overlap != nil {
                        Button("Automatic overlap") { var q = p; q.overlap = nil; set(q) }.controlSize(.small)
                    }
                }
                LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = max(0, $0); set(q) }), units: units)
                Toggle("Smooth links", isOn: Binding(get: { p.smoothLinks }, set: { var q = p; q.smoothLinks = $0; set(q) }))
                    .help("Turn between raster rows on an arc, and start passes off the model (ramping in, or coming onto a waterline loop from the open side) instead of plunging onto it")
                Text(finishingNote(p.strategy))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if p.strategy == .rest {
                RestFinishSection(params: p, op: op, project: project, units: units,
                                  areas: workspace.job?.toolpaths.first { $0.sourceOperationID == op.id }?.restAreas, set: set)
            }
        case let .vcarve(p):
            let set: (VCarveParams) -> Void = { op.kind = .vcarve($0) }
            InlaySection(params: p, op: $op, project: project, units: units, set: set, updateOperation: updateOperation,
                         select: { workspace.selection = [.operation($0)] })
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
                    if p.vBitClearsFlats, op.tool.shape.isTapered {
                        FlatClearingRows(params: p, tool: op.tool, units: units, set: set)
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
        case let .rotaryFinish(p):
            RotaryFinishSection(params: p, op: op, project: project, units: units) { op.kind = .rotaryFinish($0) }
        case let .rotaryRough(p):
            RotaryRoughSection(params: p, op: op, project: project, units: units) { op.kind = .rotaryRough($0) }
        case let .chamfer(p):
            ChamferSection(params: p, tool: op.tool, units: units) { op.kind = .chamfer($0) }
        case let .fluting(p):
            FlutingSection(params: p, tool: op.tool, units: units) { op.kind = .fluting($0) }
        case let .prism(p):
            PrismSection(params: p, op: op, project: project, units: units) { op.kind = .prism($0) }
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

/// A note under a section in the inspector's caption style.
private struct SectionNote: View {
    let text: String
    var warning = false

    var body: some View {
        if warning {
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pass depth (the tool's stepdown when unset) and the passes it gives for a cut `depth` deep.
private struct PassDepthRows: View {
    let passDepth: Double?
    let depth: Double
    let tool: Tool
    let units: LengthUnit
    let set: (Double) -> Void

    var body: some View {
        LengthField(title: "Pass depth", mm: Binding(get: { passDepth ?? tool.cutting.stepdown }, set: { set(max(0.05, $0)) }),
                    units: units, help: "Deepest cut per pass; defaults to the tool's stepdown")
        let step = max(0.05, passDepth ?? tool.cutting.stepdown)
        LabeledContent("Passes", value: "\(max(1, Int((depth / step - 1e-9).rounded(.up))))")
    }
}

/// A chamfer: which side of the vector the bevel lies, which edge the vector marks (Vectric's Down / Up), its width
/// and depth linked through the bit's angle, passes and sharp corners.
struct ChamferSection: View {
    let params: ChamferParams
    let tool: Tool
    let units: LengthUnit
    let set: (ChamferParams) -> Void

    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

    private var summary: String {
        switch (params.edge, params.side) {
        case (.top, .outside):
            "Slopes down outside the shapes from their outline, as round the top of a raised part. The bit also cuts past the bevel, so cut the part out at least the bevel's width outside its outline."
        case (.top, .inside):
            "Slopes down into the shapes from their outline, as a countersink round the top of a hole."
        case (.top, .both):
            "Slopes down on both sides of the vector, leaving a sharp ridge along it."
        case (.bottom, .inside):
            "Rises into the shapes from their outline: bevels a part's top edge before a profile on the same vectors cuts it out."
        case (.bottom, .outside):
            "Rises outward from the shapes' outline: bevels the rim of a hole or pocket cut on the same vectors."
        case (.bottom, .both):
            "A V-groove along the vector, rising on both sides of it."
        }
    }

    var body: some View {
        let p = params
        let depth = p.depth(with: tool)
        Section("Chamfer") {
            Picker("Side", selection: Binding(get: { p.side }, set: { var q = p; q.side = $0; set(q) })) {
                ForEach(ChamferParams.Side.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Vector is the", selection: Binding(get: { p.edge }, set: { var q = p; q.edge = $0; set(q) })) {
                ForEach(ChamferParams.Edge.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Top edge: the bevel slopes down away from the vector (Vectric's Down). Bottom edge: it rises away from the vector to the surface (Vectric's Up).")
            SectionNote(text: summary)
            LengthField(title: "Width", mm: Binding(get: { p.width }, set: { var q = p; q.width = max(0.01, $0); set(q) }), units: units,
                        help: "The bevel's width across the top; its depth follows from the bit's angle")
            if tool.shape.isTapered {
                LengthField(title: "Depth", mm: Binding(get: { depth }, set: { var q = p; q.width = max(0.01, ChamferParams.width(depth: $0, tool: tool)); set(q) }),
                            units: units, help: "The bevel's height; changing it changes the width through the bit's angle")
                LabeledContent("Angle", value: String(format: "%.1f° from vertical", tool.includedAngle / 2))
            }
            LengthField(title: "Start depth", mm: Binding(get: { p.startDepth }, set: { var q = p; q.startDepth = $0; set(q) }), units: units,
                        help: "Where the top of the bevel is: 0 on the material top, or the floor of a pocket or step", minimum: 0)
            PassDepthRows(passDepth: p.passDepth, depth: depth, tool: tool, units: units) { var q = p; q.passDepth = $0; set(q) }
            Toggle("Sharp corners", isOn: Binding(get: { p.sharpCorners }, set: { var q = p; q.sharpCorners = $0; set(q) }))
                .help("Raise the bit along each corner's bisector so the bevel's faces meet in a crisp line, instead of a rounded corner")
            Picker("Direction", selection: Binding(get: { p.direction }, set: { var q = p; q.direction = $0; set(q) })) {
                ForEach(CutDirection.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if !tool.shape.isTapered {
                SectionNote(text: "Chamfers need a V-bit or engraving bit.", warning: true)
            } else if p.startDepth + depth > min(tool.taperHeight, tool.fluteLength) + 1e-6 {
                SectionNote(text: "Deeper than the bit's V (\(len(min(tool.taperHeight, tool.fluteLength)))): the bevel's top comes out as a step.",
                            warning: true)
            }
        }
    }
}

/// Fluting: the flute's depth and how it ramps in and out (Vectric's flute type, ramp length or %, linear or smooth).
struct FlutingSection: View {
    let params: FlutingParams
    let tool: Tool
    let units: LengthUnit
    let set: (FlutingParams) -> Void

    enum LengthKind: String, CaseIterable, Identifiable {
        case distance, percent
        var id: String { rawValue }
        var label: String { self == .distance ? "Distance" : "Percent" }
    }

    var body: some View {
        let p = params
        Section("Fluting") {
            LengthField(title: "Flute depth", mm: Binding(get: { p.depth }, set: { var q = p; q.depth = max(0.01, $0); set(q) }), units: units,
                        help: "Measured down from the start depth")
            LengthField(title: "Start depth", mm: Binding(get: { p.startDepth }, set: { var q = p; q.startDepth = $0; set(q) }), units: units,
                        help: "Where the flute is measured from: 0 on the material top, or the floor of a pocket or step", minimum: 0)
            Picker("Ramp", selection: Binding(get: { p.ramp }, set: { var q = p; q.ramp = $0; set(q) })) {
                ForEach(FlutingParams.Ramp.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if p.ramp != .none {
                Picker("Ramp length", selection: Binding(get: { p.rampPercent == nil ? LengthKind.distance : .percent }, set: {
                    var q = p
                    q.rampPercent = $0 == .percent ? (p.rampPercent ?? 0.5) : nil
                    set(q)
                })) {
                    ForEach(LengthKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if let percent = p.rampPercent {
                    PercentField(title: "Length of each ramp", fraction: Binding(get: { percent }, set: { var q = p; q.rampPercent = $0; set(q) }))
                    SectionNote(text: p.ramp == .both ? "Of half the flute's length: 100% ramps all the way to the middle."
                                                      : "Of the flute's length: 100% ramps over the whole flute.")
                } else {
                    LengthField(title: "Length of each ramp", mm: Binding(get: { p.rampLength }, set: { var q = p; q.rampLength = max(0, $0); set(q) }), units: units,
                                help: "Length of each ramp; a flute too short for it ramps as far as it can")
                }
                Picker("Ramp shape", selection: Binding(get: { p.rampShape }, set: { var q = p; q.rampShape = $0; set(q) })) {
                    ForEach(FlutingParams.RampShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            PassDepthRows(passDepth: p.passDepth, depth: p.depth, tool: tool, units: units) { var q = p; q.passDepth = $0; set(q) }
            SectionNote(text: "A flute ramped at one end only starts at its vector's start point; one that's the same both ways is cut from the nearer end. Open and closed vectors both work; on a wrapped rotary job a line along the blank becomes a flute round a column.")
            if !FlutingParams.suits(tool.shape) {
                SectionNote(text: "Fluting is meant for a ball nose, core box or V-bit: this bit leaves square-bottomed flutes.", warning: true)
            } else if p.startDepth + p.depth > tool.fluteLength + 1e-6 {
                SectionNote(text: "Deeper than the tool's cutting length.", warning: true)
            }
        }
    }
}

/// Prism carving: the prism's depth (a full prism by default, Vectric's "Set Depth for Full Prism") and passes.
struct PrismSection: View {
    let params: PrismParams
    let op: CAMOperation
    let project: Project
    let units: LengthUnit
    let set: (PrismParams) -> Void

    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

    var body: some View {
        let p = params
        let tool = op.tool
        let full = project.fullPrismDepth(for: op)
        let depth = p.depth ?? full
        Section("Prism") {
            Toggle("Full prism", isOn: Binding(get: { p.depth == nil }, set: { var q = p; q.depth = $0 ? nil : max(0.01, full); set(q) }))
                .help("Deep enough everywhere for the slopes to meet in a ridge, from the widest part of the shapes and the bit's angle")
            if let d = p.depth {
                LengthField(title: "Prism depth", mm: Binding(get: { d }, set: { var q = p; q.depth = max(0.01, $0); set(q) }), units: units,
                            help: "Measured down from the start depth; shallower than a full prism leaves a flat top where the shapes are wide")
            }
            LabeledContent(p.depth == nil ? "Prism depth" : "Full prism depth", value: len(full))
            LengthField(title: "Start depth", mm: Binding(get: { p.startDepth }, set: { var q = p; q.startDepth = $0; set(q) }), units: units,
                        help: "Where the prism is calculated from: 0 on the material top, or the floor of a pocket or step", minimum: 0)
            PassDepthRows(passDepth: p.passDepth, depth: depth, tool: tool, units: units) { var q = p; q.passDepth = $0; set(q) }
            Picker("Direction", selection: Binding(get: { p.direction }, set: { var q = p; q.direction = $0; set(q) })) {
                ForEach(CutDirection.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            SectionNote(text: "The tip runs round the outline at the prism's depth and the shape rises to a ridge along its middle. The bit cuts past the outline too: clear round it with a pocket, or cut it out with a profile.")
            if !tool.shape.isTapered {
                SectionNote(text: "Prism carving needs a V-bit.", warning: true)
            } else if p.startDepth + depth > min(tool.taperHeight, tool.fluteLength) + 1e-6 {
                SectionNote(text: "Deeper than the bit's V (\(len(min(tool.taperHeight, tool.fluteLength)))): its slopes stop at a step. Use a larger V-bit or a smaller depth.",
                            warning: true)
            }
        }
    }
}

/// 3D rotary finishing: the pattern and its stepover (with the scallop it leaves), the allowance, how much of the
/// blank, how closely the tool is dropped, and the layers that cut down to the model first.
struct RotaryFinishSection: View {
    let params: RotaryFinishParams
    let op: CAMOperation
    let project: Project
    let units: LengthUnit
    let set: (RotaryFinishParams) -> Void

    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
    private func prompt(_ mm: Double) -> String { units.fromMM(mm).formatted(.number.precision(.fractionLength(0...units.displayDecimals))) }

    /// Where the models selected for it start and end along the blank, and the farthest they reach from the axis.
    private var extent: (minX: Double, maxX: Double, radius: Double)? {
        let e = project.shapes(for: op).compactMap(\.rotaryExtent)
        guard !e.isEmpty else { return nil }
        return (e.map(\.minX).min()!, e.map(\.maxX).max()!, e.map(\.radius).max()!)
    }

    var body: some View {
        let p = params
        let tool = op.tool
        let blank = project.stock.rotary
        Section("3D Rotary Finishing") {
            Picker("Pattern", selection: Binding(get: { p.pattern }, set: { var q = p; q.pattern = $0; set(q) })) {
                ForEach(RotaryFinishParams.Pattern.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction }, set: { var q = p; q.stepoverFraction = $0; set(q) }))
            LabeledContent(p.pattern == .lines ? "Round the blank" : "Along the blank per \(p.pattern == .spiral ? "turn" : "ring")",
                           value: len(p.stepover(tool)))
            LabeledContent("Scallop height", value: "\(units.format(scallop(tool: tool, stepover: p.stepover(tool)), decimals: 4)) \(units.symbol)")
            LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = max(0, $0); set(q) }), units: units,
                        help: "Material left on the model's surface")
            OptionalLengthField(title: "Start (X)", mm: Binding(get: { p.startX }, set: { var q = p; q.startX = $0; set(q) }), units: units,
                                prompt: extent.map { prompt(max($0.minX, tool.radius)) } ?? "",
                                help: "Where along the blank the finish starts; empty starts at the model's end, with the cutter inside the blank")
            OptionalLengthField(title: "End (X)", mm: Binding(get: { p.endX }, set: { var q = p; q.endX = $0; set(q) }), units: units,
                                prompt: extent.flatMap { e in blank.map { prompt(min(e.maxX, $0.length - tool.radius)) } } ?? "",
                                help: "Where along the blank the finish ends; empty ends at the model's end, with the cutter inside the blank")
        }
        Section("Sampling") {
            LengthField(title: "Sample spacing", mm: Binding(get: { p.sampleSpacing }, set: { var q = p; q.sampleSpacing = max(0.02, $0); set(q) }),
                        units: units, help: "How far apart along the blank the tool is dropped onto the model; smaller is truer but makes longer G-code")
            OptionalRateField(title: "Angle step", value: Binding(get: { p.angleStep }, set: { var q = p; q.angleStep = $0; set(q) }), unit: "°",
                              prompt: extent.map { String(format: "%.2f", p.sampleSpacing / max($0.radius + p.allowance, 1) * 180 / .pi) } ?? "",
                              help: "How far apart round the blank the tool is dropped; empty: the sample spacing at the model's largest radius")
        }
        Section {
            LengthField(title: "Pass depth", mm: Binding(get: { p.passDepth(tool) }, set: { var q = p; q.passDepth = max(0.05, $0); set(q) }),
                        units: units, help: "Deepest cut in one pass; where the model is deeper below the stock, layers cut down to it first")
            PercentField(title: "Layer stepover", fraction: Binding(get: { p.layerStepoverFraction ?? RotaryFinishParams.defaultLayerStepover },
                                                                   set: { var q = p; q.layerStepoverFraction = $0; set(q) }))
        } header: {
            Text("Layers")
        } footer: {
            Text("A ball nose follows the model all the way round as the blank turns, never closer than the model allows. Where it's deeper than the pass depth below the stock, layers no closer to the axis than each layer's radius cut down to it first. Run a Rounding first on a square bar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How a V-bit clears flats itself: rings, or raster lines with a stepover and an angle, and the ridges that leaves.
struct FlatClearingRows: View {
    let params: VCarveParams
    let tool: Tool
    let units: LengthUnit
    let set: (VCarveParams) -> Void

    private func len(_ mm: Double) -> String { "\(units.format(mm, decimals: 3)) \(units.symbol)" }

    var body: some View {
        Picker("V-bit clears flats in", selection: Binding(get: { params.flatRaster != nil }, set: { raster in
            var q = params
            q.flatRaster = raster ? VCarveRaster() : nil
            set(q)
        })) {
            Text("Rings").tag(false)
            Text("Raster").tag(true)
        }
        .pickerStyle(.segmented)
        .help("Offset rings follow the flat's outline; raster lines run straight across it, which suits large flats")
        if let raster = params.flatRaster {
            let auto = params.vBitRasterSpacing(tool)
            OptionalLengthField(title: "Stepover", mm: Binding(get: { raster.stepover }, set: { v in
                var q = params
                q.flatRaster?.stepover = v
                set(q)
            }), units: units, prompt: units.fromMM(auto).formatted(.number.precision(.fractionLength(0...max(3, units.displayDecimals)))),
                                help: "Distance between the lines. Empty: the automatic stepover, which keeps the ridges between them as low as the rings'")
            NumberField(title: "Raster angle", value: Binding(get: { raster.angle }, set: { v in
                var q = params
                q.flatRaster?.angle = v
                set(q)
            }), suffix: "°", decimals: 1)
            let ridge = VCarveParams.vBitRidge(tool, spacing: params.vBitRasterStepover(tool))
            LabeledContent("Ridge height", value: len(ridge))
            if ridge > params.vBitRasterRidge + 1e-6 {
                Label("Taller than the \(len(params.vBitRasterRidge)) the automatic stepover keeps to", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            LabeledContent("Ring spacing", value: len(params.vBitClearingSpacing(tool)))
        }
    }
}

/// A V-carve's inlay role: none, the pocket (female) or the plug (male), with the plug's settings (Vectric's pocket
/// depth, glue gap and surface clearance) and the depths they give. Each side shows the other's, and offers to bring
/// the settings they share (P, the V-bit, the clearance tool) in line when they differ.
struct InlaySection: View {
    let params: VCarveParams
    @Binding var op: CAMOperation
    let project: Project
    let units: LengthUnit
    let set: (VCarveParams) -> Void
    var updateOperation: (CAMOperation) -> Void = { _ in }
    var select: (UUID) -> Void = { _ in }

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
                ForEach(project.inlayPartners(of: op)) { partner in
                    PartnerRow(op: $op, partner: partner, units: units, update: updateOperation, select: select)
                }
                switch inlay.role {
                case .pocket:
                    pocketSettings
                case .plug:
                    plugSettings(inlay)
                }
            }
        }
    }

    @ViewBuilder
    private var pocketSettings: some View {
        let plugs = project.inlayPartners(of: op)
        if plugs.isEmpty {
            Text("The pocket for a V-carve inlay: an ordinary V-carve to its flat depth. Make the plug with a second V-carve set to Plug, using the same V-bit and this flat depth as its pocket depth, or make both together with Add Toolpath ▸ Inlay….")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(plugs) { plug in
                if case let .vcarve(q) = plug.kind, let inlay = q.inlay {
                    LabeledContent("“\(plug.name)”", value: "glue gap \(len(inlay.glueGap)), surface clearance \(len(inlay.surfaceClearance))")
                }
            }
            Text("The pocket for a V-carve inlay: an ordinary V-carve to its flat depth. Its plug's glue gap and surface clearance are set on the plug.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func plugSettings(_ inlay: VCarveInlay) -> some View {
        LengthField(title: "Pocket depth", mm: value(\.pocketDepth, minimum: 0.01), units: units,
                    help: "The flat depth of the V-carve pocket this plug goes into")
        LengthField(title: "Glue gap", mm: value(\.glueGap, minimum: 0), units: units,
                    help: "The gap left between the plug's face and the pocket's floor, for glue")
        LengthField(title: "Surface clearance", mm: value(\.surfaceClearance, minimum: 0.01), units: units,
                    help: "How far the plug board stays above the pocket board when the walls meet: room to clamp it in, and the waste you saw or plane off")
        Picker("Boundary", selection: Binding(get: { inlay.boundary }, set: { b in var q = params; q.inlay?.boundary = b; set(q) })) {
            ForEach(VCarveInlay.Boundary.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Where the carving round the design stops: a margin round it, a closed vector selected round it with the design, or the edges of the plug board")
        switch inlay.boundary {
        case .vector:
            if let boundary = project.plugBoundary(for: op) {
                LabeledContent("Boundary vector", value: boundary.name)
            } else {
                Label("Select a closed vector round the design with it; until then the margin is used.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                LengthField(title: "Boundary margin", mm: value(\.boundaryMargin, minimum: 0.1), units: units,
                            help: "How far past the design the plug is carved")
            }
        case .margin:
            LengthField(title: "Boundary margin", mm: value(\.boundaryMargin, minimum: 0.1), units: units,
                        help: "How far past the design the plug is carved")
        case .board:
            BoardSizeRows(size: Binding(get: { inlay.boardSize }, set: { v in var q = params; q.inlay?.boardSize = v; set(q) }),
                          stock: project.stock, units: units, placed: inlay.boardSize == nil ? nil : project.plugBoard(for: op))
        }
        LabeledContent("Start depth", value: len(inlay.plugStartDepth))
        LabeledContent("Cut depth", value: len(inlay.plugCutDepth))
        Text(inlay.boundary == .board
             ? "Carves the whole plug board, right out to its edges, around the design mirrored left to right, so the design stands proud. Turned over, it goes into the pocket until the walls meet, with the glue gap under its face: start depth = pocket depth − glue gap. Cut it from its own board with the same V-bit as the pocket, glue it in and plane it flush."
             : "Carves around the design, mirrored left to right, so the design stands proud. Turned over, it goes into the pocket until the walls meet, with the glue gap under its face: start depth = pocket depth − glue gap. Cut it from its own board with the same V-bit as the pocket, saw it free inside the carved band, glue it in and plane it flush.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The other side of an inlay, and when the settings the two share differ, what differs and buttons to bring either
/// side in line with the other.
struct PartnerRow: View {
    @Binding var op: CAMOperation
    let partner: CAMOperation
    let units: LengthUnit
    let update: (CAMOperation) -> Void
    let select: (UUID) -> Void

    private func len(_ mm: Double?) -> String { mm.map { "\(units.format($0)) \(units.symbol)" } ?? "no flat depth" }
    private func bit(_ t: Tool) -> String { "T\(t.number) \(t.name)" }

    private var isPlug: Bool { if case let .vcarve(p) = op.kind { p.isPlug } else { false } }

    var body: some View {
        let differences = op.inlayDifferences(from: partner)
        LabeledContent(isPlug ? "Its pocket" : "Its plug") {
            Button("“\(partner.name)”") { select(partner.id) }
                .buttonStyle(.link)
                .help("Select it")
        }
        if !differences.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Doesn't match “\(partner.name)”: " + differences.map(describe).joined(separator: "; ") + ".",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Update “\(partner.name)”") { update(op.inlayPartnerMatched(partner)) }
                        .help("Give “\(partner.name)” this toolpath's pocket depth and V-bit")
                    Button("Match It") { op = partner.inlayPartnerMatched(op) }
                        .help("Take “\(partner.name)”'s pocket depth and V-bit for this toolpath")
                }
                .controlSize(.small)
            }
        }
        if let tools = op.inlayClearanceTools(differingFrom: partner) {
            Text("Flats cleared with \(clearing(tools.mine)) here and \(clearing(tools.theirs)) in “\(partner.name)”: "
                 + "each side can use whichever is quickest for it, since the end mill doesn't affect the fit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clearing(_ t: Tool?) -> String { t.map(bit) ?? "the V-bit" }

    private func describe(_ d: InlayDifference) -> String {
        switch d {
        case let .pocketDepth(mine, theirs):
            let this = isPlug ? "pocket depth" : "flat depth", that = isPlug ? "its flat depth" : "its pocket depth"
            return "\(this) \(len(mine)), \(that) \(len(theirs))"
        case .bit:
            return "this uses \(bit(op.tool)), it uses \(bit(partner.tool))"
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

/// What each 3D finishing strategy does, for the inspector.
func finishingNote(_ strategy: Finish3DStrategy) -> String {
    switch strategy {
    case .raster:
        "Raster passes that follow the model surface; a ball-nose bit gives the smoothest result."
    case .waterline:
        "Constant-Z loops round the model from the top down, best on steep walls. The loops lie flat, so they fit as arcs."
    case .steepShallow:
        "Waterline loops on slopes steeper than the steep angle and raster rows on the rest, overlapping a little, so the scallop stays about the same on both."
    case .pencil:
        "One pass along each concave crease, where the bit touches two faces at once. Run it with a smaller ball nose after the main finish."
    case .rest:
        "Finishes only where the larger bits of the toolpaths it follows couldn't reach: crevices, serifs and tight valleys. Use a smaller ball or tapered ball nose after the main finish."
    }
}

/// Theoretical scallop (cusp) height left between parallel passes of a ball-ended tool on a flat surface.
func scallop(tool: Tool, stepover: Double) -> Double {
    let R = tool.shape == .ballNose ? tool.radius : (tool.shape == .bullNose ? tool.cornerRadius
        : (tool.shape == .taperedBallNose ? tool.tipDiameter / 2 : 0))
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
    /// The pass depth when none is set; nil = the tool's stepdown.
    var defaultPassDepth: Double? = nil
    var passHelp: String? = nil

    var body: some View {
        let step = defaultPassDepth ?? tool.cutting.stepdown
        Section("Depth") {
            LengthField(title: "Start depth", mm: $depth.startDepth, units: units, minimum: 0)
            MaterialDepthRows(title: "Cut depth",
                              value: Binding(get: { MaterialDepthValue(depth: depth.cutDepth, fromBottom: depth.fromBottom) },
                                             set: { var d = depth; d.cutDepth = max(0.01, $0.depth); d.fromBottom = $0.fromBottom; depth = d }),
                              stock: stock, units: units)
            LengthField(title: "Pass depth", mm: Binding(get: { depth.passDepth ?? step }, set: { depth.passDepth = max(0.05, $0) }),
                        units: units, help: passHelp ?? "Defaults to the tool's stepdown")
            let passes = depth.passLevels(toolStepdown: step, firstPassMinimum: tool.firstPassMinimum).count
            if tool.hasUndercut {
                // A dovetail (or a form bit that narrows going up) can't step down: see `ProfileGenerator`.
                LabeledContent("Passes", value: "1, at full depth")
                    .help("The bit is wider at its tip than above it, so stepping down would cut into the wall above each pass")
            } else {
                LabeledContent("Passes", value: "\(passes)")
            }
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
                    Toggle("Leave off reliefs that cut into other parts",
                           isOn: Binding(get: { r.avoidsOtherParts }, set: { relief?.avoidsOtherParts = $0 }))
                        .help("A relief that would cut into a part another toolpath cuts (through a thin wall between them) is left off. "
                            + "Either way it's marked in orange on the canvas and listed under Checks.")
                    if let n = r.overrides?.count, n > 0 {
                        HStack {
                            Text("\(n) corner\(n == 1 ? "" : "s") set on the canvas")
                            Spacer()
                            Button("Reset") { relief?.overrides = nil }
                                .controlSize(.small)
                                .help("Put every corner back to this toolpath's setting")
                        }
                    }
                    Text("Click a corner's circle on the canvas to change that corner: dogbone, T-bone into either side, or none. Right-click it for the choices, and to see why a corner is marked in orange.")
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
/// The Pocket section's rows for adaptive clearing: the optimal load and the minimum loop radius, with what the
/// machine's acceleration lets loops that tight run at.
struct AdaptiveRows: View {
    let params: PocketParams
    let tool: Tool
    let machine: MachineProfile
    let units: LengthUnit
    let set: (PocketParams) -> Void

    var body: some View {
        let s = params.adaptiveSettings
        let radius = s.loopRadius(tool: tool, feed: tool.cutting.feedRate, machine: machine)
        let cap = AdaptiveSettings.loopFeedCap(radius: radius, machine: machine)
        let feed = { (mm: Double) in
            "\(units.fromMM(mm).formatted(.number.precision(.fractionLength(0)))) \(units.feedSymbol)"
        }
        NumberField(title: "Optimal load", value: Binding(get: { s.load * 100 }, set: { v in
            var a = s
            a.optimalLoad = min(max(v / 100, AdaptiveSettings.loadRange.lowerBound), AdaptiveSettings.loadRange.upperBound)
            var q = params
            q.adaptive = a
            set(q)
        }), suffix: "%", decimals: 0)
        .help("The share of the bit's width it cuts, held all the way. 10–15% suits a full-depth cut in hardwood or MDF")
        LabeledContent("Cut width", value: "\(units.format(s.load * tool.diameter, decimals: units == .inch ? 4 : 2)) \(units.symbol)")
        LengthField(title: "Min loop radius", mm: Binding(get: { radius }, set: { v in
            var a = s
            a.minimumLoopRadius = max(0.05, v)
            var q = params
            q.adaptive = a
            set(q)
        }), units: units, help: "The tightest the loops and links between cuts turn. Automatic: what lets the feed run at full speed "
            + "with this machine's acceleration, between a quarter of the bit's diameter and twice it")
        if s.minimumLoopRadius != nil {
            Button("Automatic loop radius") {
                var a = s
                a.minimumLoopRadius = nil
                var q = params
                q.adaptive = a
                set(q)
            }
            .controlSize(.small)
        }
        if cap < 0.95 * tool.cutting.feedRate {
            Label("Loops this tight run at up to \(feed(cap)) with this machine's acceleration, below the \(feed(tool.cutting.feedRate)) feed",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Loops this tight can run at up to \(feed(cap)) with this machine's acceleration.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RestMachiningSection: View {
    @Binding var params: PocketParams
    let tool: Tool
    let units: LengthUnit
    /// With rest from earlier toolpaths on: what it follows.
    var earlier: RestMachining.References? = nil
    /// What's left for this toolpath's bit, from the last generation (nil when unknown).
    var left: [Polyline]? = nil
    @Environment(ToolLibraryStore.self) private var library

    /// Flat-bottomed bits that can clear a pocket floor.
    private var flatTools: [Tool] { library.tools.filter { $0.shape == .flatEndMill || $0.shape == .surfacing } }

    /// The end mill the toggle picks (`ToolLibrary.clearanceTool(for:)`); nil when none is larger than this toolpath's.
    private var suggested: Tool? { ToolLibrary(tools: library.tools).clearanceTool(for: tool) }

    var body: some View {
        Section("Rest machining") {
            Toggle("Clear with a larger tool first", isOn: Binding(get: { params.clearanceTool != nil }, set: { on in
                params.clearanceTool = on ? suggested : nil
            }))
            .disabled(params.clearanceTool == nil && suggested == nil)
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
            } else if suggested == nil {
                Text("No end mill larger than this toolpath's \(tool.name) in the library; add one in the Tool Library to clear with it first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Clears the bulk with a big bit and sends this toolpath's bit only where the big one can't reach.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Rest from earlier toolpaths", isOn: Binding(get: { params.restsFromEarlier }, set: { params.restFromEarlier = $0 ? true : nil }))
                .help("Cut only what the pocket toolpaths before this one, with larger bits on the same shapes, couldn't reach")
            if let earlier {
                if earlier.operations.isEmpty {
                    Text(earlier.warnings.last ?? "")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    LabeledContent("Follows", value: earlier.operations.map { "\($0.name) (T\($0.tool.number))" }.joined(separator: ", "))
                    if let left {
                        let area = Region.nest(left).reduce(0) { $0 + $1.area }
                        let a = units == .inch ? area / (25.4 * 25.4) : area
                        LabeledContent("Left to cut", value: left.isEmpty ? "Nothing"
                            : "\(a.formatted(.number.precision(.fractionLength(units == .inch ? 3 : 1)))) \(units.symbol)²")
                    }
                    Text("\(tool.name) cuts only the corners and narrow parts those bits couldn't reach, and the walls there. "
                        + "The areas are shaded on the canvas.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 3D rest finishing's settings: which toolpaths it follows, the tolerance and margin, and the pencil pass.
struct RestFinishSection: View {
    let params: Finish3DParams
    let op: CAMOperation
    let project: Project
    let units: LengthUnit
    /// The rest areas from the last generation (nil when unknown).
    let areas: [Polyline]?
    let set: (Finish3DParams) -> Void

    private var rest: RestSettings { params.rest ?? .defaults(for: units) }

    private func update(_ change: (inout RestSettings) -> Void) {
        var q = params
        var r = rest
        change(&r)
        q.rest = r
        set(q)
    }

    var body: some View {
        let refs = RestMachining.references(for: op, in: project)
        Section("Rest") {
            Toggle("Follow earlier finishes automatically", isOn: Binding(get: { rest.references == nil }, set: { automatic in
                update { $0.references = automatic ? nil : refs.operations.map(\.id) }
            }))
            .help("Every enabled 3D finishing toolpath before this one on the same model, with a larger bit")
            if rest.references == nil {
                LabeledContent("Follows", value: refs.operations.isEmpty ? "None"
                    : refs.operations.map { "\($0.name) (T\($0.tool.number))" }.joined(separator: ", "))
            } else {
                let candidates = RestMachining.candidates(for: op, in: project)
                if candidates.isEmpty {
                    Text("No other 3D finishing toolpath finishes this model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(candidates) { c in
                    Toggle("\(c.name) (T\(c.tool.number) \(c.tool.name))", isOn: Binding(get: { rest.references?.contains(c.id) == true }, set: { on in
                        update { r in
                            var ids = r.references ?? []
                            ids.removeAll { $0 == c.id }
                            if on { ids.append(c.id) }
                            r.references = ids
                        }
                    }))
                }
            }
            LengthField(title: "Rest tolerance", mm: Binding(get: { rest.tolerance }, set: { v in update { $0.tolerance = max(0.001, v) } }),
                        units: units, help: "Material thicker than this, square to the surface, counts as left over")
            LengthField(title: "Margin", mm: Binding(get: { rest.margin }, set: { v in update { $0.margin = max(0, v) } }), units: units,
                        help: "How far each rest area is grown, so the passes run a little onto the finished surface round it")
            Toggle("Pencil pass along creases", isOn: Binding(get: { rest.pencil }, set: { v in update { $0.pencil = v } }))
                .help("After the raster, one pass along each concave crease inside the rest areas")
            if let areas {
                let area = Region.nest(areas).reduce(0) { $0 + $1.area }
                let a = units == .inch ? area / (25.4 * 25.4) : area
                let count = Region.nest(areas).count
                LabeledContent("Rest areas", value: areas.isEmpty ? "Nothing left"
                    : "\(count) area\(count == 1 ? "" : "s"), \(a.formatted(.number.precision(.fractionLength(units == .inch ? 3 : 1)))) \(units.symbol)²")
            }
            ForEach(Array((refs.warnings + (refs.refusal.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, w in
                Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Works out where each reference's bit couldn't reach (its own scallops don't count) and rasters only there, at the raster "
                + "angle, with links above the model. The areas are shaded on the canvas.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    /// The toolpath's kind: the picker lists only the bits it can cut with (`OperationKind.refusal(for:)`), and the
    /// chip-load chart is read at the diameter that cuts at its depth.
    var kind: OperationKind? = nil
    /// Profiles and pockets: the operation's "Adjust feeds for load" (nil hides it).
    var loadFeeds: Binding<Bool?>? = nil
    /// On a wrapped rotary job, where feeds are inverse time and don't follow the load.
    var wrapped = false
    /// An adaptive pocket's optimal load (a share of the diameter), which thins the chip.
    var radialLoad: Double? = nil
    /// An adaptive pocket's loop feed limit, mm/min.
    var loopFeedLimit: Double? = nil

    var body: some View {
        Section("Tool") {
            let match = library.tools.first { $0.id == tool.id } ?? library.tools.first { $0.number == tool.number && $0.name == tool.name }
            Picker("Tool", selection: Binding(get: { match?.id }, set: { id in
                if let id, let t = library.tool(id: id) { tool = t }
            })) {
                if match == nil {
                    Text("T\(tool.number) \(tool.name) (project copy)").tag(UUID?.none)
                }
                ForEach(library.tools.filter { $0.id == match?.id || kind?.refusal(for: $0) == nil }) { t in
                    Text("T\(t.number) \(t.name)").tag(Optional(t.id))
                }
            }
            if let why = kind?.refusal(for: tool) {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 12) {
                ToolShapeView(tool: tool, units: units).frame(width: 140, height: 150)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.shape.label).font(.headline)
                    Text("\(tool.fluteCount) flute \(tool.fluteDirection.label.lowercased())")
                    if tool.shape.isTapered { Text("\(Int(tool.includedAngle))° included") }
                    let detail = tool.shapeDetail { "\(units.format($0)) \(units.symbol)" }
                    if !detail.isEmpty {
                        Text(detail.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Chip load \(units.format(tool.chipLoad, decimals: 4)) \(units.symbol)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            NumberField(title: "Spindle", value: $tool.cutting.spindleRPM, suffix: "RPM", decimals: 0, range: 1000...60000)
            FeedField(title: "Feed", mmPerMin: $tool.cutting.feedRate, units: units)
            FeedField(title: "Plunge", mmPerMin: $tool.cutting.plungeRate, units: units)
            if let loadFeeds { LoadFeedsToggle(on: loadFeeds, tool: tool, wrapped: wrapped) }
            LengthField(title: "Stepdown", mm: $tool.cutting.stepdown, units: units, minimum: 0.05)
            PercentField(title: tool.shape == .taperedBallNose ? "Stepover (of tip)" : "Stepover", fraction: $tool.cutting.stepoverFraction)
            if ChipLoad.applies(to: tool) {
                ChipLoadRow(tool: $tool, material: material, machine: machine, units: units, radialLoad: radialLoad,
                            loopFeedLimit: loopFeedLimit, depth: kind?.requestedDepth)
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
    /// An adaptive pocket's optimal load: the chip is thinner than the feed per tooth.
    var radialLoad: Double? = nil
    /// An adaptive pocket's loop feed limit (mm/min): the recommended feed keeps to it, slowing the spindle instead.
    var loopFeedLimit: Double? = nil
    /// The toolpath's depth, which sets the chart's diameter for a bit whose width changes with depth and a form bit's
    /// cross-section (`ChipLoad.reading`); nil reads the bit at its full diameter.
    var depth: Double? = nil

    var body: some View {
        let thin = radialLoad.map { ChipLoad.radialThinning(load: $0) } ?? 1
        let rec = ChipLoad.recommendation(for: tool, material: material, machine: machine, thinning: thin, feedLimit: loopFeedLimit,
                                          depth: depth)
        let reading = rec.reading
        let r = reading.range
        let source = reading.source(units)
        let chip = tool.chipLoad * thin
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
                Text(source.prefix(1).uppercased() + source.dropFirst()).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let radialLoad, thin < 1 {
                    Text("Thinned to \(Int((100 * thin).rounded()))% at the \(Int((100 * radialLoad).rounded()))% adaptive load")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        ForEach(reading.notes(units), id: \.self) { note in
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let top = reading.maxRPM, tool.cutting.spindleRPM > top + 0.5 {
            Label("The spindle is set faster than \(Int(top.rounded()).formatted()) RPM, the most for this bit: a bit turned past its rated speed can break.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if rec.belowSpindleMinimum {
            Label("This spindle can't turn as slowly as this bit needs (\(Int(machine.minRPM.rounded()).formatted()) RPM at its slowest).",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        let held = loopFeedLimit.map { rec.feed >= $0 - 1e-6 && $0 < machine.maxFeedRate } ?? false
        if held {
            Text("Held to the fastest its loops can run with this machine's acceleration, with the spindle slowed to keep the chip in range.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Use Recommended: \(units.format(rec.feed, decimals: 0)) \(units == .inch ? "ipm" : "mm/min") @ \(Int(rec.rpm.rounded())) RPM") {
                tool.cutting.feedRate = rec.feed
                tool.cutting.spindleRPM = rec.rpm
            }
            .controlSize(.small)
            .help(reading.chart == .routerBit || reading.outsideChart
                  ? "Chip load at the thin end of the chart range, the spindle no faster than the bit's speed limit, feed held within the machine's cutting cap by lowering RPM"
                  : "Chip load a quarter into the chart range, feed held within the machine's cutting cap by lowering RPM")
        }
    }
}

// MARK: 3D rotary roughing

/// 3D rotary roughing: the pattern each layer clears with, the stepdown between layers and the stepover on each, the
/// allowance left for the finish (with the ridges a flat bottom leaves on the round at the model's narrowest), how
/// much of the blank, and how closely the model is sampled.
struct RotaryRoughSection: View {
    let params: RotaryRoughParams
    let op: CAMOperation
    let project: Project
    let units: LengthUnit
    let set: (RotaryRoughParams) -> Void

    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }
    private func prompt(_ mm: Double) -> String { units.fromMM(mm).formatted(.number.precision(.fractionLength(0...units.displayDecimals))) }

    /// Where the models selected for it start and end along the blank, and the least they come to the axis.
    private var extent: (minX: Double, maxX: Double, narrowest: Double)? {
        let models = project.shapes(for: op).filter { $0.modelSpec != nil }
        let e = models.compactMap(\.rotaryExtent)
        guard !e.isEmpty else { return nil }
        let narrowest = models.compactMap { m in m.modelSpec?.alongAxis.profile.filter { $0 > 0 }.min().map { Double($0) * m.scale } }.min()
        return (e.map(\.minX).min()!, e.map(\.maxX).max()!, narrowest ?? 0)
    }

    var body: some View {
        let p = params
        let tool = op.tool
        let blank = project.stock.rotary
        Section("3D Rotary Roughing") {
            Picker("Pattern", selection: Binding(get: { p.pattern }, set: { var q = p; q.pattern = $0; set(q) })) {
                ForEach(RotaryRoughParams.Pattern.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Auto clears each area in lines its longer way: along the blank at a square bar's corners, round it on a short band")
            LengthField(title: "Stepdown", mm: Binding(get: { p.stepdown(tool) }, set: { var q = p; q.stepdown = max(0.05, $0); set(q) }),
                        units: units, help: "How far in toward the axis each layer is from the last")
            PercentField(title: "Stepover", fraction: Binding(get: { p.stepoverFraction ?? tool.cutting.stepoverFraction },
                                                             set: { var q = p; q.stepoverFraction = $0; set(q) }))
            LabeledContent("On each layer", value: len(p.stepover(tool)))
            LengthField(title: "Allowance", mm: Binding(get: { p.allowance }, set: { var q = p; q.allowance = max(0, $0); set(q) }), units: units,
                        help: "Material left on the model for the finish")
            if let e = extent, e.narrowest > 0 {
                let r = e.narrowest + p.allowance
                LabeledContent("Ridges at its narrowest", value: len(RotaryRoughParams.cusp(tool, radius: max(r, tool.radius))))
                    .help("The most a flat bottom leaves standing across the round \(len(r)) from the axis, on top of the allowance; keep the allowance at least this")
            }
            OptionalLengthField(title: "Start (X)", mm: Binding(get: { p.startX }, set: { var q = p; q.startX = $0; set(q) }), units: units,
                                prompt: extent.map { prompt(max($0.minX, tool.radius)) } ?? "",
                                help: "Where along the blank the roughing starts; empty starts at the model's end, with the cutter inside the blank")
            OptionalLengthField(title: "End (X)", mm: Binding(get: { p.endX }, set: { var q = p; q.endX = $0; set(q) }), units: units,
                                prompt: extent.flatMap { e in blank.map { prompt(min(e.maxX, $0.length - tool.radius)) } } ?? "",
                                help: "Where along the blank the roughing ends; empty ends at the model's end, with the cutter inside the blank")
        }
        Section {
            LengthField(title: "Sample spacing", mm: Binding(get: { p.sampleSpacing }, set: { var q = p; q.sampleSpacing = max(0.05, $0); set(q) }),
                        units: units, help: "How far apart along the blank, and round it, the tool is dropped onto the model to find each layer's area")
        } header: {
            Text("Sampling")
        } footer: {
            Text("A flat or bull-nose end mill clears the stock round the model in layers, each a stepdown nearer the axis, from a square bar or a round blank. Each layer clears only where there's material left: over a square bar's faces it skips the air, and after a Rounding it starts from the rounded size. Near the model it rides on it, no closer than the allowance. Finish with 3D Rotary Finishing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Feeds that follow the load

/// "Adjust feeds for load" under a profile's or pocket's feeds (see `FeedScheduler`).
struct LoadFeedsToggle: View {
    @Binding var on: Bool?
    let tool: Tool
    let wrapped: Bool

    var body: some View {
        let applies = FeedScheduler.suits(tool) && !wrapped
        Toggle("Adjust feeds for load", isOn: Binding(get: { on == true }, set: { on = $0 ? true : nil }))
            .disabled(!applies && on != true)
            .help("Slows the feed only where the bit cuts more than in this toolpath's usual cut: a pocket's first pass, "
                + "inside corners, tight inside arcs. Never faster than the feed above, and never so slow the chip burns.")
        if on == true || !applies {
            if wrapped {
                SectionNote(text: "Wrapped rotary moves are fed in inverse time, so they keep this feed.", warning: on == true)
            } else if !FeedScheduler.suits(tool) {
                SectionNote(text: "Only with end mills, bull noses and surfacing bits: a \(tool.shape.label.lowercased())'s engagement depends on its depth.",
                            warning: on == true)
            } else {
                SectionNote(text: "Down to 55% where the bit cuts more of its width than usual, and on a profile's inside arcs so "
                    + "the edge keeps this feed. The estimate, simulation and G-code use the slower feeds.")
            }
        }
    }
}

/// The range of feeds a toolpath runs at with "Adjust feeds for load".
struct LoadFeedsRow: View {
    let feeds: LoadFeeds
    let units: LengthUnit
    var indent = false

    var body: some View {
        let low = Int((feeds.lowest / feeds.programmed * 100).rounded())
        LabeledContent(indent ? "      Feed" : "Feed",
                       value: "\(units.format(feeds.lowest, decimals: 0))–\(units.format(feeds.programmed, decimals: 0)) \(units.feedSymbol) (\(low)–100%)")
    }
}
