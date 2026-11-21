import AppKit
import CAMCore
import SwiftUI

struct InspectorView: View {
    @Binding var project: Project
    @Bindable var workspace: Workspace

    var body: some View {
        Group {
            if let id = workspace.selectedOperationID, let index = project.operations.firstIndex(where: { $0.id == id }) {
                OperationInspector(op: $project.operations[index], project: project, workspace: workspace)
            } else if workspace.selectedShapeIDs.count == 1, let index = project.shapes.firstIndex(where: { $0.id == workspace.selectedShapeIDs[0] }) {
                let id = project.shapes[index].id
                ShapeInspector(shape: $project.shapes[index], units: project.displayUnits, stock: project.stock,
                               layers: project.layerNames, setLayer: { project.setLayer($0, of: [id]) })
            } else if workspace.selectedShapeIDs.count > 1 {
                let ids = Set(workspace.selectedShapeIDs)
                let layers = Set(project.shapes.filter { ids.contains($0.id) }.map(\.layer))
                MultiShapeInspector(count: ids.count, layer: layers.count == 1 ? layers.first : nil, layers: project.layerNames,
                                    setLayer: { project.setLayer($0, of: ids) })
            } else {
                SetupInspector(project: $project)
            }
        }
    }
}

// MARK: Job setup

struct SetupInspector: View {
    @Binding var project: Project

    var units: LengthUnit { project.displayUnits }

    var body: some View {
        Form {
            Section("Job") {
                TextField("Name", text: $project.name)
                Picker("Display units", selection: $project.displayUnits) {
                    Text("Inches").tag(LengthUnit.inch)
                    Text("Millimetres").tag(LengthUnit.mm)
                }
            }
            Section("Material") {
                TextField("Material", text: $project.stock.materialName)
                Picker("Material type", selection: Binding(get: { project.stock.material }, set: { project.stock.materialKind = $0 })) {
                    ForEach(MaterialKind.allCases) { Text($0.label).tag($0) }
                }
                .help("Used for chip-load recommendations and warnings")
                RotaryBlankRows(project: $project, units: units)
                if project.stock.rotary == nil {
                    LengthField(title: "Width (X)", mm: $project.stock.width, units: units, minimum: 1)
                    LengthField(title: "Height (Y)", mm: $project.stock.height, units: units, minimum: 1)
                    LengthField(title: "Thickness (Z)", mm: $project.stock.thickness, units: units,
                                help: "Measure your material with calipers; through-cuts are set relative to this.", minimum: 0.1)
                } else {
                    RotarySheetRows(stock: $project.stock, units: units)
                }
            }
            Section("Zero") {
                if project.stock.rotary == nil {
                    Picker("XY zero", selection: $project.stock.xyOrigin) {
                        ForEach(XYOrigin.allCases) { Text($0.label).tag($0) }
                    }
                    OriginDiagram(origin: project.stock.xyOrigin)
                        .frame(height: 70)
                    Picker("Z zero", selection: $project.stock.zZero) {
                        ForEach(ZZero.allCases) { Text($0.label).tag($0) }
                    }
                    Text(project.stock.zZero == .materialTop
                         ? "Touch off Z on top of the material with the touch plate."
                         : "Touch off Z on the spoilboard; material thickness must be accurate.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    RotaryZeroRows(stock: $project.stock, machine: project.machine)
                }
            }
            Section("Heights") {
                // A rotary blank turns at safe Z, so safe Z can't go below what clears its corners.
                LengthField(title: "Safe Z (clearance)", mm: $project.stock.clearanceHeight, units: units,
                            help: project.stock.rotary == nil ? "Rapids between cuts happen at this height above the material."
                                : "Rapids between cuts, and every turn of the blank, happen at this height above the face.",
                            minimum: max(0.5, project.stock.minimumRotaryClearance ?? 0))
                LengthField(title: "Plunge start", mm: $project.stock.plungeHeight, units: units,
                            help: "Rapids stop this far above the material; feeds start here.", minimum: 0.1)
                Picker("Between cuts", selection: Binding(get: { project.stock.retract }, set: { project.stock.retractMode = $0 })) {
                    ForEach(RetractMode.allCases) { Text($0.label).tag($0) }
                }
                .help("Minimum lifts only above the material still there, stays down across cleared areas and drops quickly onto floors already cut")
                if project.stock.retract == .minimum {
                    LengthField(title: "Safe distance", mm: Binding(get: { project.stock.safeDistance }, set: {
                        project.stock.linkSafeDistance = max(0.5, $0)
                        // On a rotary blank the margin over its corners grows with it.
                        if let least = project.stock.minimumRotaryClearance {
                            project.stock.clearanceHeight = max(project.stock.clearanceHeight, least)
                        }
                    }), units: units, help: "Links travel at least this far above remaining material (and tabs). Raise it for bowed sheets.")
                }
                if project.stock.rotary == nil {
                    LengthField(title: "Park X", mm: $project.stock.homePosition.x, units: units)
                    LengthField(title: "Park Y", mm: $project.stock.homePosition.y, units: units)
                }
                LengthField(title: "Park Z", mm: $project.stock.homePosition.z, units: units, minimum: 1)
                if project.stock.rotary != nil {
                    Text("Rotary jobs park over the middle of the blank, clear of the chuck and tailstock."
                         + (project.stock.rotary?.isWrapped == true ? " Wrapped toolpaths always go up to safe Z between cuts, since the blank turns as the tool moves across." : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TilingSection(project: $project)
            SavedMachineSection(machine: $project.machine)
            MachineSection(machine: $project.machine, units: units)
        }
        .formStyle(.grouped)
    }
}

/// Cutting a job bigger than the machine's travel in tiles, with registration holes for dowels (Vectric's Toolpath
/// Tiling Manager, in Job Setup).
struct TilingSection: View {
    @Binding var project: Project

    var units: LengthUnit { project.displayUnits }

    private var tiling: Binding<TilingSettings> {
        Binding(get: { project.tiling ?? TilingSettings() }, set: { project.tiling = $0 })
    }

    var body: some View {
        Section {
            if project.stock.rotary != nil {
                Text("Rotary jobs can't be tiled: the blank can't move through the machine.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Cut in tiles", isOn: tiling.enabled)
                    .help("Split a job bigger than the machine's travel into tiles, cut one after another as the material moves")
                if tiling.wrappedValue.enabled { settings }
            }
        } header: {
            Text("Tiling")
        } footer: {
            if project.stock.rotary == nil, tiling.wrappedValue.enabled {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        let t = tiling.wrappedValue
        Picker("Tiles", selection: tiling.mode) {
            ForEach(TilingSettings.Mode.allCases) { Text($0.label).tag($0) }
        }
        .help("Feed-through: the material slides through the machine (open front and back) one tile at a time. Individual tiles: separate boards, or a board moved both ways.")
        if t.mode.tilesX {
            AutomaticLengthRow(title: t.mode == .grid ? "Tile width" : "Tile length (move)", value: tiling.tileWidth,
                               automatic: TileLayout.automaticPitch(project, alongX: true), units: units,
                               help: "How far apart tiles are along X: how far the material moves. Automatic is the X travel less the overlap, the largest bit and a margin.")
        }
        if t.mode.tilesY {
            AutomaticLengthRow(title: t.mode == .grid ? "Tile height" : "Tile length (move)", value: tiling.tileHeight,
                               automatic: TileLayout.automaticPitch(project, alongX: false), units: units,
                               help: "How far apart tiles are along Y: how far the material moves. Automatic is the Y travel less the overlap, the largest bit and a margin.")
        }
        AutomaticLengthRow(title: "Overlap", value: tiling.overlap, automatic: automaticOverlap, units: units,
                           help: "How far each tile reaches past its tile lines, so a cut that crosses one runs on before it breaks. At least the largest bit's radius; automatic adds 1/8 in.")
        Picker("Short tile", selection: tiling.smallestFirst) {
            Text("Last").tag(false)
            Text("First").tag(true)
        }
        .help("Where the remainder tile goes when the material isn't a whole number of tiles long")
        if t.mode.isFeedThrough {
            Toggle("Registration holes", isOn: Binding(get: { t.registration?.enabled == true }, set: { on in
                var r = tiling.wrappedValue.registration ?? RegistrationHoles()
                r.enabled = on
                tiling.wrappedValue.registration = r
            }))
            .help("Drill dowel holes into the spoilboard and through the material one tile apart, so each move lands exactly")
            if let reg = t.registration, reg.enabled { registration(reg) }
        }
    }

    @ViewBuilder
    private func registration(_ reg: RegistrationHoles) -> some View {
        let set: (RegistrationHoles) -> Void = { tiling.wrappedValue.registration = $0 }
        LengthField(title: "Dowel diameter", mm: Binding(get: { reg.diameter }, set: { var r = reg; r.diameter = $0; set(r) }),
                    units: units, help: "The hole size: the dowel or pin you'll register with.", minimum: 1)
        LengthField(title: "In from the edges", mm: Binding(get: { reg.edgeOffset }, set: { var r = reg; r.edgeOffset = $0; set(r) }),
                    units: units, help: "How far the pair of holes is in from each side of the material. Keep them in waste, clear of the design.",
                    minimum: 0)
        LengthField(title: "Into the spoilboard", mm: Binding(get: { reg.spoilboardDepth }, set: { var r = reg; r.spoilboardDepth = $0; set(r) }),
                    units: units, help: "How deep the holes go into the spoilboard below the material.", minimum: 1)
        let tools = jobTools.filter { RegistrationHoles.canDrill($0) }
        Picker("Bit", selection: Binding(get: { reg.tool?.id }, set: { id in
            var r = reg
            r.tool = id.flatMap { id in tools.first { $0.id == id } }
            set(r)
        })) {
            Text(reg.tool == nil ? "Automatic (\(reg.resolvedTool(in: project).map { "T\($0.number) \($0.name)" } ?? "none fits"))" : "Automatic")
                .tag(UUID?.none)
            ForEach(tools) { tool in Text("T\(tool.number) \(tool.name)").tag(UUID?.some(tool.id)) }
        }
        .help("The bit that drills the holes, cut first in each tile. Automatic picks the job's largest straight bit that fits the hole.")
    }

    /// The bits the job's enabled toolpaths use, once each.
    private var jobTools: [Tool] {
        var out: [Tool] = []
        for op in project.operations where op.enabled {
            for t in [op.clearanceTool, op.tool].compactMap({ $0 }) where !out.contains(where: { $0.isSameBit(as: t) && $0.number == t.number }) {
                out.append(t)
            }
        }
        if let chosen = project.tiling?.registration?.tool, !out.contains(where: { $0.id == chosen.id }) { out.append(chosen) }
        return out
    }

    private var automaticOverlap: Double {
        var p = project
        p.tiling?.overlap = nil
        return TileLayout.overlap(p)
    }

    private var summary: String {
        guard let layout = TileLayout(project) else {
            return "The material fits in one tile at this size, so the job is cut as usual."
        }
        let u = units
        func len(_ mm: Double) -> String { "\(u.format(mm, decimals: u == .inch ? 3 : 1)) \(u.symbol)" }
        var s: String
        switch layout.mode {
        case .feedThroughY: s = "\(layout.count) tiles; the material moves \(len(layout.pitch.y)) along Y between them."
        case .feedThroughX: s = "\(layout.count) tiles; the material moves \(len(layout.pitch.x)) along X between them."
        case .grid: s = "\(layout.count) tiles, \(layout.columns) across and \(layout.rows) up."
        }
        s += " Tile lines are yellow on the canvas, overlaps red. Export saves a file per tile and a setup sheet page for each, with where to move the material"
        s += layout.registration == nil ? "." : " and where the dowels go."
        return s
    }
}

/// A length that's worked out automatically unless one is typed in.
struct AutomaticLengthRow: View {
    let title: String
    @Binding var value: Double?
    let automatic: Double
    let units: LengthUnit
    var help: String? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if value == nil {
                    Text("\(units.format(automatic, decimals: units == .inch ? 3 : 1)) \(units.symbol)").foregroundStyle(.secondary)
                } else {
                    TextField(title, value: Binding(get: { units.fromMM(value ?? automatic) }, set: { value = max(0.1, units.toMM($0)) }),
                              format: .number.precision(.fractionLength(0...units.displayDecimals)))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(minWidth: 70)
                    Text(units.symbol).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                }
                Toggle("Auto", isOn: Binding(get: { value == nil }, set: { value = $0 ? nil : automatic }))
                    .toggleStyle(.checkbox)
            }
        }
        .help(help ?? "")
    }
}

/// Use a machine from the library in this document, or set up a new one.
struct SavedMachineSection: View {
    @Binding var machine: MachineProfile
    @State private var settingUp = false

    var body: some View {
        Section {
            let library = MachineLibraryFile.library
            LabeledContent("Machine") {
                Menu(library.machine(id: machine.libraryID ?? "")?.name ?? machine.displayName) {
                    ForEach(library.machines) { m in
                        Button(m.name) { machine = m.snapshot }
                    }
                    Divider()
                    Button("Set Up a New Machine…") { settingUp = true }
                }
                .fixedSize()
            }
        } footer: {
            if let id = machine.libraryID, let saved = MachineLibraryFile.library.machine(id: id), saved.revision > (machine.libraryRevision ?? 0) {
                HStack {
                    Text("“\(saved.name)” has changed since this document took a copy.").font(.caption).foregroundStyle(.secondary)
                    Button("Use the New Settings") { machine = saved.snapshot }.controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $settingUp) {
            MachineSetupView(offerUseHere: true) { setup, forNew, here in
                MachineLibraryFile.add(setup, makeDefault: forNew)
                if here, let saved = MachineLibraryFile.library.machine(id: setup.id) { machine = saved.snapshot }
            }
        }
    }
}

struct MachineSection: View {
    @Binding var machine: MachineProfile
    let units: LengthUnit

    var body: some View {
        Section("Machine") {
            Picker("Controller", selection: Binding<String>(
                get: { machine.controller?.family.rawValue ?? "" },
                set: { raw in
                    machine.controller = raw.isEmpty ? nil : ControllerProfile(family: ControllerFamily(rawValue: raw), sender: machine.controller?.sender)
                })) {
                Text("Avid Mach4 profile").tag("")
                ForEach([ControllerFamily.grbl, .grblHAL, .fluidNC, .carbideMotion, .linuxCNC, .masso, .centroid, .buildbotics, .openSBP, .richAuto],
                        id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
                if let c = machine.controller, Dialect.for(machine) == nil {
                    Text("\(c.family.label) (no post yet)").tag(c.family.rawValue)
                }
            }
            if let family = machine.controller?.family, family == .grbl || family == .grblHAL || family == .fluidNC {
                TextField("Sends files with", text: Binding(get: { machine.controller?.sender ?? "" }, set: { s in
                    machine.controller?.sender = s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
                }), prompt: Text("gSender, CNCjs, UGS…"))
                .help("gSender and CNCjs can pause on M6, so NativeCAM keeps a job in one file; with anything else it saves a file per tool")
            }
            Picker("Model", selection: Binding(get: { machine.model }, set: { m in
                machine.model = m
                if let area = m.workArea { machine.travel = area }
            })) {
                ForEach(AvidModel.allCases) { Text($0.label).tag($0) }
            }
            if machine.model == .custom {
                LengthField(title: "X travel", mm: $machine.travel.x, units: units, minimum: 10)
                LengthField(title: "Y travel", mm: $machine.travel.y, units: units, minimum: 10)
                LengthField(title: "Z travel", mm: $machine.travel.z, units: units, minimum: 10)
            } else {
                LabeledContent("Work area", value: "\(units.format(machine.travel.x, decimals: 2)) × \(units.format(machine.travel.y, decimals: 2)) × \(units.format(machine.travel.z, decimals: 2)) \(units.symbol)")
            }
            Picker("Spindle", selection: $machine.spindle) {
                ForEach(SpindleKind.allCases) { Text($0.label).tag($0) }
            }
            .help(machine.spindle.detail)
            if machine.spindle == .vfdSpindle {
                NumberField(title: "Min RPM", value: $machine.minRPM, decimals: 0, range: 0...60000)
                NumberField(title: "Max RPM", value: $machine.maxRPM, decimals: 0, range: 0...60000)
            }
            NumberField(title: "Spin-up dwell", value: $machine.spindleSpinUpDwell, suffix: "s", decimals: 1, range: 0...30)
                .help("Adds a dwell after the spindle starts. Leave at 0 if the controller already waits for the spindle.")
            Picker("Tool changes", selection: $machine.toolChange) {
                ForEach(ToolChangeMode.allCases) { Text($0.label).tag($0) }
            }
            Text(machine.isLegacyAvidMach4 ? machine.toolChange.detail : (machine.summary.dropFirst().first ?? machine.toolChange.detail))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Dust collector (M\(Dialect.for(machine)?.dustOn ?? 7)/M9)", isOn: $machine.dustCollection)
        }
        Section("Rotary Axis") {
            RotaryAxisRows(machine: $machine, units: units)
        }
        Section("G-code Output") {
            VectricPostControls(machine: $machine)
            Picker("Units", selection: $machine.outputUnits) {
                Text("Inches (G20)").tag(LengthUnit.inch)
                Text("Millimetres (G21)").tag(LengthUnit.mm)
            }
            .disabled(machine.customPost != nil)
            .help(machine.customPost != nil ? "The imported post decides the units" : "")
            Toggle("Fit arcs (G2/G3)", isOn: $machine.outputArcs)
            if machine.outputArcs {
                LengthField(title: "Arc tolerance", mm: $machine.arcFitTolerance, units: units, minimum: 0.001)
            }
            LengthField(title: "Roughing corner rounding", mm: Binding(get: { machine.cornerSmoothing }, set: { machine.roughingSmoothing = max(0, $0) }),
                        units: units, help: "How far clearing passes inside a pocket and 3D roughing may round off corners so the machine "
                            + "keeps moving. Finished pocket walls stay exact; 0 turns it off.")
            Toggle("Line numbers", isOn: $machine.lineNumbers)
        }
        Section {
            Picker("Drives", selection: Binding(get: { machine.driveTier }, set: { tier in
                machine.drive = tier
                machine.maxFeedRate = tier.cutSpeed
                machine.rapidRateForEstimates = tier.rapidSpeed
            })) {
                ForEach(DriveTier.allCases) { Text($0.label).tag($0) }
            }
            FeedField(title: "Max cutting feed", mmPerMin: $machine.maxFeedRate, units: units)
            FeedField(title: "Rapid X/Y", mmPerMin: $machine.rapidRateForEstimates, units: units)
            FeedField(title: "Rapid Z", mmPerMin: Binding(get: { machine.axisRapid.z }, set: { machine.rapidRateZ = $0 }), units: units)
            AccelerationField(title: "Acceleration X/Y", mmPerS2: Binding(get: { machine.axisAcceleration.x }, set: { machine.accelerationXY = $0 }), units: units)
            AccelerationField(title: "Acceleration Z", mmPerS2: Binding(get: { machine.axisAcceleration.z }, set: { machine.accelerationZ = $0 }), units: units)
            LengthField(title: "Corner tolerance", mm: Binding(get: { machine.cornerDeviation }, set: { machine.junctionDeviation = max(0.001, $0) }),
                        units: units, help: "How far the controller may round a corner to keep speed (junction deviation)")
            IntField(title: "Look-ahead lines", value: Binding(get: { machine.plannerLookahead }, set: { machine.lookaheadLines = $0 }), range: 1...1000)
            NumberField(title: "Tool change time", value: Binding(get: { machine.toolChangeTime }, set: { machine.toolChangeSeconds = max(0, $0) }),
                        suffix: "s", decimals: 0, range: 0...3600)
        } header: {
            Text("Motion (for run-time estimates)")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                MachineImportButtons(machine: $machine, units: units)
                Text(machine.isLegacyAvidMach4
                     ? "Avid doesn't publish acceleration; 50 in/s² is what Mach4 reportedly ships with. Import your Machine.ini for accurate estimates."
                     : "Makers rarely publish acceleration. Import your controller's settings (Grbl's $$, Machine.ini, a LinuxCNC or FluidNC config) for accurate estimates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Acceleration in in/s² or mm/s² (stored as mm/s²).
struct AccelerationField: View {
    let title: String
    @Binding var mmPerS2: Double
    let units: LengthUnit

    var body: some View {
        NumberField(title: title, value: Binding(get: { units.fromMM(mmPerS2) }, set: { mmPerS2 = max(0.1, units.toMM($0)) }),
                    suffix: units == .inch ? "in/s²" : "mm/s²", decimals: units == .inch ? 1 : 0)
    }
}

/// Small picture of the stock with the XY zero marked.
struct OriginDiagram: View {
    let origin: XYOrigin

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(x: size.width / 2 - 55, y: 8, width: 110, height: size.height - 16)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(red: 0.85, green: 0.72, blue: 0.53)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.secondary))
            let p: CGPoint
            switch origin {
            case .lowerLeft: p = CGPoint(x: rect.minX, y: rect.maxY)
            case .lowerRight: p = CGPoint(x: rect.maxX, y: rect.maxY)
            case .upperLeft: p = CGPoint(x: rect.minX, y: rect.minY)
            case .upperRight: p = CGPoint(x: rect.maxX, y: rect.minY)
            case .center: p = CGPoint(x: rect.midX, y: rect.midY)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.red))
            var x = Path(); x.move(to: p); x.addLine(to: CGPoint(x: p.x + 22, y: p.y))
            var y = Path(); y.move(to: p); y.addLine(to: CGPoint(x: p.x, y: p.y - 22))
            ctx.stroke(x, with: .color(.red), lineWidth: 2)
            ctx.stroke(y, with: .color(.green), lineWidth: 2)
        }
    }
}

// MARK: Shapes

struct ShapeInspector: View {
    @Binding var shape: DesignShape
    let units: LengthUnit
    var stock: Stock? = nil
    /// The design's layers, and how to put this shape on one (through the project, so toolpaths that find their
    /// vectors by layer follow). Without it, no layer row.
    var layers: [String] = []
    var setLayer: ((String) -> Void)? = nil

    /// A model on a rotary blank: it lies along the axis, so only its place along the blank and its size are set here.
    private var onBlank: RotaryStock? {
        guard shape.modelSpec?.rotary != nil else { return nil }
        return stock?.rotary
    }

    static let fonts = ["Helvetica-Bold", "Helvetica", "Futura-Bold", "AvenirNext-Bold", "Georgia-Bold", "Times-Bold",
                        "GillSans-Bold", "Copperplate-Bold", "Didot-Bold", "Impact", "MarkerFelt-Wide", "Chalkduster",
                        "BradleyHandITCTT-Bold", "SnellRoundhand-Bold", "Zapfino"]

    var body: some View {
        Form {
            Section(shape.kind.label) {
                TextField("Name", text: $shape.name)
                if let setLayer {
                    LayerField(current: shape.layer, layers: layers, commit: setLayer)
                }
                if onBlank != nil {
                    LengthField(title: "Middle (X)", mm: $shape.position.x, units: units, help: "Where the middle of the model's length is along the blank")
                } else {
                    LengthField(title: "Center X", mm: $shape.position.x, units: units)
                    LengthField(title: "Center Y", mm: $shape.position.y, units: units)
                    NumberField(title: "Rotation", value: $shape.rotation, suffix: "°", decimals: 2)
                }
                NumberField(title: "Scale", value: Binding(get: { shape.scale * 100 }, set: { shape.scale = max(0.001, $0 / 100) }),
                            suffix: "%", decimals: 2)
                if shape.modelSpec == nil {
                    let b = shape.bounds
                    LabeledContent("Size", value: "\(units.format(b.width)) × \(units.format(b.height)) \(units.symbol)")
                }
            }
            Section("Geometry") { geometry }
            if shape.modelSpec == nil {
                Section {
                    Toggle("Clamp / keep-out zone", isOn: Binding(get: { shape.isKeepOut }, set: { shape.keepOutHeight = $0 ? 1.inch : nil }))
                    if let h = shape.keepOutHeight {
                        LengthField(title: "Height above material", mm: Binding(get: { h }, set: { shape.keepOutHeight = max(0, $0) }), units: units)
                    }
                } footer: {
                    Text("Marks a clamp or fixture: toolpaths may not cut inside it, and moves that cross it go over the top.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var geometry: some View {
        switch shape.kind {
        case let .rectangle(w, h, r):
            LengthField(title: "Width", mm: Binding(get: { w }, set: { shape.kind = .rectangle(width: max(0.01, $0), height: h, cornerRadius: r) }), units: units)
            LengthField(title: "Height", mm: Binding(get: { h }, set: { shape.kind = .rectangle(width: w, height: max(0.01, $0), cornerRadius: r) }), units: units)
            LengthField(title: "Corner radius", mm: Binding(get: { r }, set: { shape.kind = .rectangle(width: w, height: h, cornerRadius: max(0, $0)) }), units: units)
        case let .circle(r):
            LengthField(title: "Diameter", mm: Binding(get: { r * 2 }, set: { shape.kind = .circle(radius: max(0.01, $0 / 2)) }), units: units)
        case let .ellipse(rx, ry):
            LengthField(title: "Width", mm: Binding(get: { rx * 2 }, set: { shape.kind = .ellipse(radiusX: max(0.01, $0 / 2), radiusY: ry) }), units: units)
            LengthField(title: "Height", mm: Binding(get: { ry * 2 }, set: { shape.kind = .ellipse(radiusX: rx, radiusY: max(0.01, $0 / 2)) }), units: units)
        case let .polygon(n, r):
            IntField(title: "Sides", value: Binding(get: { n }, set: { shape.kind = .polygon(sides: $0, radius: r) }), range: 3...64)
            LengthField(title: "Radius", mm: Binding(get: { r }, set: { shape.kind = .polygon(sides: n, radius: max(0.01, $0)) }), units: units)
        case let .star(n, ro, ri):
            IntField(title: "Points", value: Binding(get: { n }, set: { shape.kind = .star(points: $0, outerRadius: ro, innerRadius: ri) }), range: 3...64)
            LengthField(title: "Outer radius", mm: Binding(get: { ro }, set: { shape.kind = .star(points: n, outerRadius: max(0.01, $0), innerRadius: ri) }), units: units)
            LengthField(title: "Inner radius", mm: Binding(get: { ri }, set: { shape.kind = .star(points: n, outerRadius: ro, innerRadius: max(0.01, $0)) }), units: units)
        case let .text(spec):
            TextField("Text", text: Binding(get: { spec.string }, set: { var s = spec; s.string = $0; shape.kind = .text(s) }), axis: .vertical)
            Picker("Font", selection: Binding(get: { spec.fontName }, set: { var s = spec; s.fontName = $0; shape.kind = .text(s) })) {
                ForEach(Self.fonts + (Self.fonts.contains(spec.fontName) ? [] : [spec.fontName]), id: \.self) { name in
                    Text(name).font(.custom(name, size: 13)).tag(name)
                }
            }
            TextField("Font name", text: Binding(get: { spec.fontName }, set: { var s = spec; s.fontName = $0; shape.kind = .text(s) }))
                .help("Any installed font's PostScript name")
            LengthField(title: "Cap height", mm: Binding(get: { spec.capHeight }, set: { var s = spec; s.capHeight = max(0.5, $0); shape.kind = .text(s) }), units: units)
            LengthField(title: "Letter spacing", mm: Binding(get: { spec.letterSpacing }, set: { var s = spec; s.letterSpacing = $0; shape.kind = .text(s) }), units: units)
        case let .spiral(spec):
            let set: (SpiralSpec) -> Void = { shape.kind = .spiral($0) }
            IntField(title: "Starts", value: Binding(get: { spec.starts }, set: { var s = spec; s.starts = $0; set(s) }), range: 1...24)
            LengthField(title: "Pitch", mm: Binding(get: { spec.pitch }, set: { var s = spec; s.pitch = max(0.5, $0); set(s) }), units: units,
                        help: "Distance along the blank for one turn of each line")
            LengthField(title: "Length", mm: Binding(get: { spec.length }, set: { var s = spec; s.length = max(0.5, $0); set(s) }), units: units,
                        help: "Along the blank (X)")
            Picker("Twist", selection: Binding(get: { spec.leftHanded }, set: { var s = spec; s.leftHanded = $0; set(s) })) {
                Text("Right hand").tag(false)
                Text("Left hand").tag(true)
            }
            .pickerStyle(.segmented)
            LabeledContent("Turns", value: spec.turns.formatted(.number.precision(.fractionLength(0...2))))
            Text("Each line climbs once around the blank per pitch: on the unrolled sheet it runs past the seam and keeps going. Cut it on the line with a ball nose or V-bit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case let .paths(paths):
            LabeledContent("Contours", value: "\(paths.count) (\(paths.filter(\.isClosed).count) closed)")
            Text("Imported vectors can be moved, rotated and scaled.").font(.caption).foregroundStyle(.secondary)
        case let .model(spec) where onBlank != nil:
            RotaryModelRows(shape: $shape, spec: spec, blank: onBlank!, units: units)
        case let .model(spec):
            let natural = spec.naturalSize
            let set: (ModelSpec) -> Void = { shape.kind = .model($0) }
            LabeledContent("Triangles", value: spec.mesh.triangleCount.formatted())
            Picker("Up axis", selection: Binding(get: { spec.upAxis }, set: { var s = spec; s.upAxis = $0; set(s) })) {
                ForEach(UpAxis.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Flip upside down", isOn: Binding(get: { spec.flipped }, set: { var s = spec; s.flipped = $0; set(s) }))
            LengthField(title: "Width (X)", mm: Binding(get: { natural.x * shape.scale },
                                                       set: { if natural.x > 0 { shape.scale = max(0.001, $0 / natural.x) } }), units: units)
            LengthField(title: "Height (Y)", mm: Binding(get: { natural.y * shape.scale },
                                                        set: { if natural.y > 0 { shape.scale = max(0.001, $0 / natural.y) } }), units: units)
            LengthField(title: "Carve depth (Z)", mm: Binding(get: { spec.depth }, set: { var s = spec; s.depth = max(0.05, $0); set(s) }), units: units,
                        help: "Distance from the model's highest point to its lowest")
            HStack {
                Spacer()
                Button("Proportional Depth") { var s = spec; s.depth = spec.proportionalDepth(scale: shape.scale); set(s) }
                    .help("Use the model's true Z proportions at the current width")
            }
            LengthField(title: "Top below surface", mm: Binding(get: { spec.topOffset }, set: { var s = spec; s.topOffset = max(0, $0); set(s) }), units: units,
                        help: "0 puts the model's highest point at the top of the material")
            Text("Machine it with 3D Roughing, then 3D Finishing (Add Toolpath).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A 3D model on a rotary blank: which of its axes lies along the blank, which way round, turned how far about the
/// axis, and its size, with buttons to fit it to the blank or show it at the size it was drawn.
struct RotaryModelRows: View {
    @Binding var shape: DesignShape
    let spec: ModelSpec
    let blank: RotaryStock
    let units: LengthUnit

    private func len(_ mm: Double) -> String { "\(units.format(mm)) \(units.symbol)" }

    var body: some View {
        let placement = spec.rotary ?? RotaryPlacement(longestOf: spec.mesh)
        let mesh = spec.alongAxis
        let set: (RotaryPlacement) -> Void = { var s = spec; s.rotary = $0; shape.kind = .model(s) }
        LabeledContent("Triangles", value: spec.mesh.triangleCount.formatted())
        Picker("Along the blank", selection: Binding(get: { placement.alongAxis }, set: { var q = placement; q.alongAxis = $0; set(q) })) {
            ForEach(UpAxis.allCases) { Text("Model's \($0.rawValue.uppercased()) axis").tag($0) }
        }
        .help("Which of the model's own axes lies along the rotation axis")
        Toggle("End for end", isOn: Binding(get: { placement.reversed }, set: { var q = placement; q.reversed = $0; set(q) }))
            .help("Turn the model round so its other end is toward the chuck")
        NumberField(title: "Turn", value: Binding(get: { placement.turn }, set: { var q = placement; q.turn = $0; set(q) }), suffix: "°", decimals: 1)
            .help("Turn the model about the rotation axis: which side of it is on top at A0")
        LengthField(title: "Length", mm: Binding(get: { Double(mesh.length) * shape.scale },
                                                 set: { if mesh.length > 0 { shape.scale = max(0.001, $0 / Double(mesh.length)) } }), units: units,
                    help: "Along the blank")
        LengthField(title: "Diameter", mm: Binding(get: { 2 * Double(mesh.maxRadius) * shape.scale },
                                                   set: { if mesh.maxRadius > 0 { shape.scale = max(0.001, $0 / (2 * Double(mesh.maxRadius))) } }),
                    units: units, help: "Across the model at its widest, round the axis")
        HStack {
            Spacer()
            Button("Actual Size") { shape.scale = 1 }
                .help("The size the model was drawn at")
            Button("Fit to Blank") {
                shape.scale = RotaryPlacement.fitScale(mesh, blank: blank)
                shape.position.x = blank.length / 2
            }
            .help("As wide as the blank is round and no longer than it, in the middle of it")
        }
        if let e = shape.rotaryExtent {
            if 2 * e.radius > blank.diameter + 1e-6 {
                Label("\(len(2 * e.radius)) across, wider than the \(len(blank.diameter)) blank", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if e.minX < -1e-6 || e.maxX > blank.length + 1e-6 {
                Label("Runs past the end of the \(len(blank.length)) blank", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        Text("Lies along the rotation axis, centred on it. Finish it with 3D Rotary Finishing (Add Toolpath).")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct MultiShapeInspector: View {
    let count: Int
    /// The layer they're all on, or nil when they're on different ones.
    var layer: String? = nil
    var layers: [String] = []
    var setLayer: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square").font(.largeTitle).foregroundStyle(.secondary)
            Text("\(count) shapes selected")
            Text("Use Add Toolpath to machine them together.").font(.caption).foregroundStyle(.secondary)
            if let setLayer {
                Form {
                    LayerField(current: layer, layers: layers, commit: setLayer)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 76)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
