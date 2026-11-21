import CAMCore
import SwiftUI

/// A depth with how it's measured: down from the material top, or tied to the thickness (through the material, or
/// leaving some above its bottom), so it follows the thickness when it changes or in a template applied to other
/// material.
struct MaterialDepthValue: Hashable {
    var depth: Double
    var fromBottom: Double?
}

struct MaterialDepthRows: View {
    enum Mode: String, CaseIterable, Identifiable {
        case fromTop, through, leave
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fromTop: "From top"
            case .through: "Through"
            case .leave: "Thickness −"
            }
        }
    }

    let title: String
    @Binding var value: MaterialDepthValue
    let stock: Stock
    let units: LengthUnit

    private var mode: Mode { value.fromBottom.map { $0 <= 1e-9 ? .through : .leave } ?? .fromTop }

    var body: some View {
        // Tied to the thickness only on a flat sheet (a rotary job's thickness is the blank's radius).
        if stock.rotary == nil || value.fromBottom != nil {
            Picker(title, selection: Binding(get: { mode }, set: { set($0) })) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("From top: a fixed depth. Through and Thickness −: measured from the material's bottom, so the depth follows the thickness")
        }
        switch mode {
        case .fromTop:
            LengthField(title: stock.rotary == nil ? "Depth" : title, mm: Binding(get: { value.depth }, set: { value = MaterialDepthValue(depth: $0) }),
                        units: units, minimum: 0.01)
        case .through:
            LengthField(title: "Past the bottom", mm: Binding(get: { -(value.fromBottom ?? 0) }, set: { tie(-max(0, $0)) }), units: units,
                        help: "How far into the spoilboard the cut goes")
        case .leave:
            LengthField(title: "Leave", mm: Binding(get: { value.fromBottom ?? 0 }, set: { tie(max(0.01, $0)) }), units: units,
                        help: "Material left above the bottom")
        }
        if mode != .fromTop {
            Text("\(units.format(value.depth)) \(units.symbol) deep in this \(units.format(stock.thickness)) \(units.symbol) material. "
                 + "Follows the thickness if it changes, and in templates.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tie(_ fromBottom: Double) {
        value = MaterialDepthValue(depth: MaterialDepth.depth(fromBottom: fromBottom, thickness: stock.thickness), fromBottom: fromBottom)
    }

    private func set(_ new: Mode) {
        let t = stock.thickness
        switch new {
        case .fromTop: value.fromBottom = nil
        case .through: tie(value.depth > t ? t - value.depth : -MaterialDepth.defaultOvercut)
        case .leave: tie(value.depth < t - 0.01 ? t - value.depth : 0.125.inch)
        }
    }
}

/// How a toolpath finds its vectors: chosen by hand, or every shape on a layer or of a kind (picked up again when a
/// shape's layer changes, vectors are imported, or on Recalculate All, and kept when it's saved in a template).
struct VectorRows: View {
    @Binding var op: CAMOperation
    let project: Project
    let selected: [UUID]

    var body: some View {
        let rule = op.vectorSelection == .selection ? nil : op.vectorSelection
        let layers = project.layerNames
        Picker("Vectors", selection: Binding(get: { rule }, set: { new in
            var o = op
            o.vectorSelection = new
            if let new { o.shapeIDs = project.shapeIDs(matching: new) }
            op = o
        })) {
            Text("Chosen by hand").tag(VectorSelection?.none)
            Divider()
            ForEach(layers, id: \.self) { Text("Layer “\($0)”").tag(VectorSelection?.some(.layers([$0]))) }
            if case let .layers(names)? = rule, names.count != 1 || !layers.contains(names[0]) {
                Text(VectorSelection.layers(names).label).tag(rule)
            }
            Divider()
            ForEach(ShapeFilter.allCases) { Text($0.label).tag(VectorSelection?.some(.kind($0))) }
        }
        .help("Toolpaths that find their vectors by layer or kind pick them up again, and keep finding them in a template")
        LabeledContent("Shapes", value: "\(op.shapeIDs.count)")
        Button("Use Selected Shapes") {
            var o = op
            o.shapeIDs = selected
            o.vectorSelection = nil
            op = o
        }
        .disabled(selected.isEmpty)
        .help("Select shapes in the Design list, then click to assign them to this toolpath")
        if rule == nil, let inferred = project.inferredVectorSelection(for: op) {
            Text(inferred == .selection ? "In a template: the vectors selected when it's applied." : "In a template: \(inferred.label).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
