import CAMCore
import SwiftUI

// Controls for indexed (3+1) rotary jobs: the blank in Job Setup, the machine's rotary axis, and each toolpath's
// index angles. The engine reports every setup it can't cut (`RotaryIndex.issues`); these controls only make the
// valid choices the easy ones.

// MARK: Rotary blank

/// The "Rotary blank" switch and the blank's shape and size, for the Material section. Every change goes through
/// `Stock.setRotary(_:)`, which keeps the design sheet sized to one face of the blank.
struct RotaryBlankRows: View {
    @Binding var project: Project
    let units: LengthUnit

    /// The blank a job starts on when it's switched to rotary: a 2 in × 12 in dowel, or 50 × 300 mm.
    static func defaultBlank(_ units: LengthUnit) -> RotaryStock {
        units == .mm ? RotaryStock(diameter: 50, length: 300) : RotaryStock()
    }

    var body: some View {
        Toggle("Rotary blank", isOn: Binding(get: { project.stock.rotary != nil }, set: { on in
            if on {
                project.stock.setRotary(Self.defaultBlank(units))
            } else {
                // Index angles only mean something on a rotary blank; a flat job with angles can't be cut.
                project.stock.setRotary(nil)
                for i in project.operations.indices { project.operations[i].indexAngles = nil }
            }
        }))
        .help("Turn the blank on the machine's rotary axis and cut its faces one at a time (indexed, 3+1)")
        if let blank = project.stock.rotary {
            Picker("Shape", selection: value(\.shape)) {
                ForEach(RotaryStock.Shape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LengthField(title: blank.shape == .cylinder ? "Diameter" : "Size across faces", mm: value(\.diameter), units: units,
                        help: blank.shape == .cylinder ? "Measure the blank with calipers" : "Width of the bar from one face to the opposite face",
                        minimum: 1)
            LengthField(title: "Length", mm: value(\.length), units: units, help: "Along the rotation axis (machine X)", minimum: 1)
            if project.machine.rotary == nil {
                HStack(alignment: .firstTextBaseline) {
                    Label("This machine has no rotary axis set up.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button("Add Rotary Axis") { project.machine.rotary = RotaryAxis() }
                        .controlSize(.small)
                        .help("Adds an A axis along X to this document's machine; check it under Rotary Axis below")
                }
            }
        }
    }

    private func value<T>(_ key: WritableKeyPath<RotaryStock, T>) -> Binding<T> {
        Binding(get: { (project.stock.rotary ?? Self.defaultBlank(units))[keyPath: key] }, set: { v in
            guard var blank = project.stock.rotary else { return }
            blank[keyPath: key] = v
            project.stock.setRotary(blank)
        })
    }
}

/// Width, height and thickness of a rotary job's design sheet, which follow the blank and can't be typed in.
struct RotarySheetRows: View {
    @Binding var stock: Stock
    let units: LengthUnit

    var body: some View {
        LengthValue(title: "Width (X)", mm: stock.width, units: units)
        LengthValue(title: "Height (Y)", mm: stock.height, units: units)
        LengthValue(title: "Thickness (Z)", mm: stock.thickness, units: units)
        if !stock.matchesRotaryBlank {
            HStack(alignment: .firstTextBaseline) {
                Label("The sheet doesn't match the blank.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Spacer(minLength: 4)
                Button("Fit to Blank") { stock.setRotary(stock.rotary) }.controlSize(.small)
            }
        }
        Text("The design sheet is one face of the blank: X along the axis, Y across the face with the axis under its middle, and the thickness down to the axis. Each toolpath cuts it at its index angles.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A length shown in display units that can't be edited, lined up with `LengthField`.
struct LengthValue: View {
    let title: String
    let mm: Double
    let units: LengthUnit

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text(units.fromMM(mm), format: .number.precision(.fractionLength(0...units.displayDecimals)))
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(units.symbol).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            }
        }
    }
}

// MARK: Rotary zero

/// Where X zero sits along a rotary blank. Y zero is always on the axis centreline, so the flat job's corner
/// choices collapse to these three.
enum RotaryXZero: String, CaseIterable, Identifiable {
    case left, middle, right
    var id: String { rawValue }

    init(_ origin: XYOrigin) {
        switch origin {
        case .lowerLeft, .upperLeft: self = .left
        case .lowerRight, .upperRight: self = .right
        case .center: self = .middle
        }
    }

    var origin: XYOrigin {
        switch self {
        case .left: .lowerLeft
        case .middle: .center
        case .right: .lowerRight
        }
    }

    var label: String {
        switch self {
        case .left: "Left end"
        case .middle: "Middle"
        case .right: "Right end"
        }
    }
}

/// The Zero section's rows for a rotary job: X zero along the blank, and Y and Z on the rotation axis.
struct RotaryZeroRows: View {
    @Binding var stock: Stock
    let machine: MachineProfile

    var body: some View {
        let blank = stock.rotary ?? RotaryStock()
        // Avid's Mach4 profile and its EX (CNC12) controller both have a Rotary tab with these touch-off routines.
        let avid = machine.isLegacyAvidMach4 || machine.controller?.family == .centroid
        Picker("X zero", selection: Binding(get: { RotaryXZero(stock.xyOrigin) }, set: { stock.xyOrigin = $0.origin })) {
            ForEach(RotaryXZero.allCases) { Text($0.label).tag($0) }
        }
        RotaryOriginDiagram(shape: blank.shape, xZero: RotaryXZero(stock.xyOrigin))
            .frame(height: 70)
        LabeledContent("Y zero", value: "Axis centreline")
        LabeledContent("Z zero", value: "Rotation axis")
        if blank.shape == .squareBar {
            LabeledContent("A zero", value: "A face square to the spindle")
        }
        Text("Touch off Z on the rotation axis and Y on its centreline"
             + (avid ? " (Avid: Rotary tab ▸ Z Axis Touch, then Y Axis Touch)" : "")
             + ", and set X by hand. Every Z in the file is measured from the axis, not the top of the blank."
             + (blank.shape == .squareBar ? (avid ? " Home A to square the jaws, and so the bar's faces, to the spindle." : "") : ""))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small picture of the blank seen from above, with X zero marked on the axis centreline.
struct RotaryOriginDiagram: View {
    let shape: RotaryStock.Shape
    let xZero: RotaryXZero

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(x: size.width / 2 - 75, y: 16, width: 150, height: size.height - 32)
            let wood = Color(red: 0.85, green: 0.72, blue: 0.53)
            if shape == .cylinder {
                // Shade a dowel so it reads as round.
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [wood.opacity(0.65), wood, wood.opacity(0.65)]),
                    startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            } else {
                ctx.fill(Path(rect), with: .color(wood))
            }
            ctx.stroke(Path(rect), with: .color(.secondary))
            // Chuck and tailstock stand off each end.
            ctx.fill(Path(roundedRect: CGRect(x: rect.minX - 12, y: rect.minY - 6, width: 10, height: rect.height + 12), cornerRadius: 2),
                     with: .color(.secondary.opacity(0.5)))
            ctx.fill(Path(roundedRect: CGRect(x: rect.maxX + 2, y: rect.midY - 6, width: 10, height: 12), cornerRadius: 2),
                     with: .color(.secondary.opacity(0.5)))
            var axis = Path()
            axis.move(to: CGPoint(x: rect.minX - 16, y: rect.midY))
            axis.addLine(to: CGPoint(x: rect.maxX + 16, y: rect.midY))
            ctx.stroke(axis, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            let x: CGFloat = switch xZero {
            case .left: rect.minX
            case .middle: rect.midX
            case .right: rect.maxX
            }
            let p = CGPoint(x: x, y: rect.midY)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.red))
            var xArrow = Path(); xArrow.move(to: p); xArrow.addLine(to: CGPoint(x: p.x + 22, y: p.y))
            var yArrow = Path(); yArrow.move(to: p); yArrow.addLine(to: CGPoint(x: p.x, y: p.y - 22))
            ctx.stroke(xArrow, with: .color(.red), lineWidth: 2)
            ctx.stroke(yArrow, with: .color(.green), lineWidth: 2)
        }
        .accessibilityLabel("X zero at the \(xZero.label.lowercased()) of the blank, on the axis centreline")
    }
}

// MARK: Machine rotary axis

/// Whether the machine has a rotary axis, which way it turns and how high its centre is. NativeCAM can only turn
/// an A axis along X so far, so the letter and alignment are shown but can't be changed to anything else.
struct RotaryAxisRows: View {
    @Binding var machine: MachineProfile
    let units: LengthUnit

    var body: some View {
        Toggle("Rotary axis", isOn: Binding(get: { machine.rotary != nil }, set: { machine.rotary = $0 ? (machine.rotary ?? RotaryAxis()) : nil }))
            .help("A chuck and tailstock that turn the blank while the router cuts it")
        if let axis = machine.rotary {
            Picker("Axis letter", selection: Binding(get: { axis.letter }, set: { if $0 == .a { machine.rotary?.letter = $0 } })) {
                ForEach(RotaryAxis.Letter.allCases) { letter in
                    Text(letter == .a ? "A" : "\(letter.rawValue) (not supported yet)").tag(letter)
                        .selectionDisabled(letter != .a)
                }
            }
            Picker("Runs along", selection: Binding(get: { axis.alignment }, set: { if $0 == .x { machine.rotary?.alignment = $0 } })) {
                ForEach(RotaryAxis.Alignment.allCases) { alignment in
                    Text(alignment == .x ? "X" : "Y (not supported yet)").tag(alignment)
                        .selectionDisabled(alignment != .x)
                }
            }
            Toggle("Reversed", isOn: Binding(get: { axis.reversed }, set: { machine.rotary?.reversed = $0 }))
                .help("Jog A positive: the top of the blank should roll toward −Y. If it rolls toward +Y, turn this on, or anything around the blank comes out mirrored.")
            OptionalLengthField(title: "Centre height", mm: Binding(get: { axis.centerHeight }, set: { machine.rotary?.centerHeight = $0 }),
                                units: units, prompt: "Not measured",
                                help: "Height of the chuck centre above the spoilboard, so NativeCAM can check that a job fits under the Z travel")
            Text("NativeCAM turns an A axis along X so far. To check Reversed, jog A positive: the top of the blank should roll toward −Y.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A length that may be unknown: empty shows `prompt`, and clearing the field (or entering 0) sets it back to nil.
struct OptionalLengthField: View {
    let title: String
    @Binding var mm: Double?
    let units: LengthUnit
    var prompt: String = ""
    var help: String? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { mm.map { units.fromMM($0) } }, set: { v in
                    mm = v.map { units.toMM($0) }.flatMap { $0 > 0 ? $0 : nil }
                }), format: .number.precision(.fractionLength(0...units.displayDecimals)), prompt: Text(prompt))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 70)
                Text(units.symbol).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            }
        } label: {
            Text(title)
        }
        .help(help ?? "")
    }
}

// MARK: Index angles

extension OperationKind {
    /// The toolpaths that cut at index angles on a rotary job so far.
    var takesIndexAngles: Bool {
        switch self {
        case .profile, .pocket, .drill: true
        case .vcarve, .rough3D, .finish3D: false
        }
    }
}

/// The angles a toolpath turns the blank to, in cutting order, with a helper for faces spaced evenly around it.
/// A square bar only offers quarter turns, where a face is square to the spindle.
struct IndexAnglesSection: View {
    @Binding var angles: [Double]?
    /// The job's rotary blank. nil on a flat job, where the section only offers to clear angles left over.
    let blank: RotaryStock?
    @State private var faces = 4

    private static let quarterTurns: [Double] = [0, 90, 180, 270]
    private var list: [Double] { angles ?? [0] }
    private var square: Bool { blank?.shape == .squareBar }

    /// nil (the default, 0° only) when the list is just 0°.
    private func store(_ new: [Double]) { angles = new == [0] ? nil : new }

    var body: some View {
        Section {
            if blank == nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("Angles \(list.map(RotaryIndex.label).joined(separator: ", ")) are set, but the material isn't a rotary blank.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Clear Angles") { angles = nil }.controlSize(.small)
                }
            } else {
                ForEach(Array(list.enumerated()), id: \.offset) { i, angle in
                    LabeledContent(i == 0 ? "Cut at" : "Then") {
                        HStack(spacing: 6) {
                            angleEditor(i, angle)
                            Button { var l = list; l.remove(at: i); store(l) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(list.count == 1)
                                .help("Remove this angle")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Angle") { if let a = nextAngle() { store(list + [a]) } }
                        .disabled(nextAngle() == nil)
                        .help(square ? "Adds the next face of the bar not yet in the list" : "Adds the next angle not yet in the list")
                }
                LabeledContent("Spread evenly") {
                    HStack(spacing: 8) {
                        if square {
                            Picker("Faces", selection: squareFaces) {
                                ForEach([1, 2, 4], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        } else {
                            Text("\(faces)").monospacedDigit()
                            Stepper("Faces", value: $faces, in: 1...72).labelsHidden()
                        }
                        let n = square ? squareFaces.wrappedValue : faces
                        Button(n == 1 ? "0° Only" : "Every \(RotaryIndex.label(360 / Double(n)))") {
                            store((0..<n).map { Double($0) * 360 / Double(n) })
                        }
                        .help("Cut the same shapes on \(n) face\(n == 1 ? "" : "s") spaced evenly around the blank, 360°/\(n) apart")
                    }
                }
            }
        } header: {
            Text("Index Angles")
        } footer: {
            if blank != nil {
                Text("The blank turns to each angle in turn, with the tool at safe Z, and the shapes are cut on the face under the spindle. 0° is the face that's up at A0."
                     + (square ? " A square bar turns in quarter turns, so a face is square to the spindle." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func angleEditor(_ i: Int, _ angle: Double) -> some View {
        let set: (Double) -> Void = { v in var l = list; l[i] = v; store(l) }
        if square {
            let odd = !Self.quarterTurns.contains(RotaryIndex.normalized(angle))
            Picker("Angle", selection: Binding(get: { angle }, set: set)) {
                ForEach(Self.quarterTurns, id: \.self) { Text(RotaryIndex.label($0)).tag($0) }
                if odd { Text("\(RotaryIndex.label(angle)) (not a face)").tag(angle) }
            }
            .labelsHidden().fixedSize()
        } else {
            HStack(spacing: 4) {
                TextField("Angle", value: Binding(get: { angle }, set: set), format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(minWidth: 70)
                Text("°").foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            }
        }
    }

    /// The first angle not in the list yet, trying quarter turns first, then finer steps on a round blank. nil once
    /// every face of a square bar is listed.
    private func nextAngle() -> Double? {
        let used = Set(list.map(RotaryIndex.normalized))
        for step in square ? [90.0] : [90, 45, 30, 15, 5, 1] {
            if let a = stride(from: 0.0, to: 360, by: step).first(where: { !used.contains($0) }) { return a }
        }
        return nil
    }

    /// Faces spaced evenly around a square bar: 1, 2 or 4.
    private var squareFaces: Binding<Int> {
        Binding(get: { [1, 2, 4].contains(faces) ? faces : 4 }, set: { faces = $0 })
    }
}

/// Cutting length and time for a toolpath that cuts at several index angles: every angle's toolpath added up.
struct IndexedResultSection: View {
    let toolpaths: [Toolpath]
    let job: JobResult
    let rapidRate: Double
    let units: LengthUnit

    var body: some View {
        Section("Result (\(toolpaths.count) angles)") {
            let length = toolpaths.reduce(0) { $0 + $1.cuttingLength }
            let seconds = toolpaths.reduce(0) { $0 + (job.estimatedSeconds(toolpath: $1.id) ?? $1.estimatedSeconds(rapidRate: rapidRate)) }
            LabeledContent("Cutting length", value: "\(units.format(length, decimals: 1)) \(units.symbol)")
            LabeledContent("Estimated time", value: formatDuration(seconds))
            if let deepest = toolpaths.compactMap({ $0.cuttingExtents.map { -$0.min.z } }).max() {
                LabeledContent("Deepest cut", value: "\(units.format(deepest)) \(units.symbol)")
            }
        }
    }
}
