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
                ShapeInspector(shape: $project.shapes[index], units: project.displayUnits)
            } else if workspace.selectedShapeIDs.count > 1 {
                MultiShapeInspector(count: workspace.selectedShapeIDs.count)
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
                    Text("Rotary jobs park over the middle of the blank, clear of the chuck and tailstock.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SavedMachineSection(machine: $project.machine)
            MachineSection(machine: $project.machine, units: units)
        }
        .formStyle(.grouped)
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

    static let fonts = ["Helvetica-Bold", "Helvetica", "Futura-Bold", "AvenirNext-Bold", "Georgia-Bold", "Times-Bold",
                        "GillSans-Bold", "Copperplate-Bold", "Didot-Bold", "Impact", "MarkerFelt-Wide", "Chalkduster",
                        "BradleyHandITCTT-Bold", "SnellRoundhand-Bold", "Zapfino"]

    var body: some View {
        Form {
            Section(shape.kind.label) {
                TextField("Name", text: $shape.name)
                LengthField(title: "Center X", mm: $shape.position.x, units: units)
                LengthField(title: "Center Y", mm: $shape.position.y, units: units)
                NumberField(title: "Rotation", value: $shape.rotation, suffix: "°", decimals: 2)
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
        case let .paths(paths):
            LabeledContent("Contours", value: "\(paths.count) (\(paths.filter(\.isClosed).count) closed)")
            Text("Imported vectors can be moved, rotated and scaled.").font(.caption).foregroundStyle(.secondary)
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

struct MultiShapeInspector: View {
    let count: Int
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square").font(.largeTitle).foregroundStyle(.secondary)
            Text("\(count) shapes selected")
            Text("Use Add Toolpath to machine them together.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
