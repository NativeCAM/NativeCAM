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

    var units: LengthUnit { project.displayUnits }

    var body: some View {
        let rule = op.vectorSelection == .selection ? nil : op.vectorSelection
        let base = rule?.sized(nil)
        let layers = project.layerNames
        Picker("Vectors", selection: Binding(get: { base }, set: { new in
            // Changing the layer or kind keeps the size rule.
            setRule(new?.sized(rule?.size))
        })) {
            Text("Chosen by hand").tag(VectorSelection?.none)
            Divider()
            ForEach(layers, id: \.self) { Text("Layer “\($0)”").tag(VectorSelection?.some(.layers([$0]))) }
            if case let .layers(names, _)? = base, names.count != 1 || !layers.contains(names[0]) {
                Text(VectorSelection.layers(names).label).tag(base)
            }
            Divider()
            ForEach(ShapeFilter.allCases) { Text($0.label).tag(VectorSelection?.some(.kind($0))) }
        }
        .help("Toolpaths that find their vectors by layer or kind pick them up again, and keep finding them in a template")
        if let rule {
            SizeFilterRows(size: Binding(get: { rule.size }, set: { setRule(rule.sized($0)) }), units: units, project: project,
                           rule: rule)
        }
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
            Text(inferred == .selection ? "In a template: the vectors selected when it's applied." : "In a template: \(inferred.label(units)).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setRule(_ new: VectorSelection?) {
        var o = op
        o.vectorSelection = new
        if let new { o.shapeIDs = project.shapeIDs(matching: new) }
        op = o
    }
}

/// A layer or kind rule's size filter: any size, circles by diameter, or closed shapes by bounding box (Vectric's
/// circle-diameter filter). Saved in the project and in templates (format 20).
struct SizeFilterRows: View {
    enum Mode: Hashable { case any, diameter, box }

    @Binding var size: SizeFilter?
    let units: LengthUnit
    let project: Project
    let rule: VectorSelection

    var mode: Mode {
        guard let size else { return .any }
        return size.measuresDiameter ? .diameter : .box
    }

    var body: some View {
        Picker("Size", selection: Binding(get: { mode }, set: { set($0) })) {
            Text("Any size").tag(Mode.any)
            Text("Circle diameter").tag(Mode.diameter)
            Text("Width and height").tag(Mode.box)
        }
        .help("Find only the circles of a diameter, or the closed shapes of a size, so one template drills the small holes and pockets the big ones")
        if let size {
            if size.measuresDiameter {
                LengthField(title: "Diameter from", mm: bound(\.diameter, \.min), units: units, minimum: 0)
                LengthField(title: "Diameter to", mm: bound(\.diameter, \.max), units: units, minimum: 0)
            } else {
                LengthField(title: "Width from", mm: bound(\.width, \.min), units: units, minimum: 0)
                LengthField(title: "Width to", mm: bound(\.width, \.max), units: units, minimum: 0)
                LengthField(title: "Height from", mm: bound(\.height, \.min), units: units, minimum: 0)
                LengthField(title: "Height to", mm: bound(\.height, \.max), units: units, minimum: 0)
            }
            LengthField(title: "Tolerance", mm: Binding(get: { size.tolerance }, set: { t in
                var s = size
                s.tolerance = t
                self.size = s
            }), units: units, help: "How far outside the range a size may be and still count", minimum: 0)
            Text((size.measuresDiameter ? "Only \(size.label(units))" : "Only closed shapes \(size.label(units))")
                 + " are picked up. Imported vectors are measured outline by outline.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bound(_ part: WritableKeyPath<SizeFilter, SizeRange?>, _ end: WritableKeyPath<SizeRange, Double?>) -> Binding<Double> {
        Binding(get: { size?[keyPath: part]?[keyPath: end] ?? 0 }, set: { v in
            guard var s = size else { return }
            var r = s[keyPath: part] ?? SizeRange()
            r[keyPath: end] = v
            s[keyPath: part] = r
            size = s
        })
    }

    /// A new filter starts from the sizes the rule finds now, so it changes nothing until narrowed.
    private func set(_ new: Mode) {
        guard new != mode else { return }
        let found = project.shapes.filter { rule.sized(nil).matches($0) }
        switch new {
        case .any:
            size = nil
        case .diameter:
            let d = found.flatMap { $0.polylines(tolerance: 0.01) }.compactMap(SizeFilter.circleDiameter)
            size = .circles(d.min() ?? 0, d.max() ?? 25.4)
        case .box:
            let boxes = found.filter { ShapeFilter.closed.matches($0) }.map { $0.bounds }
            let w = boxes.map { $0.max.x - $0.min.x }, h = boxes.map { $0.max.y - $0.min.y }
            size = .box(width: SizeRange(min: w.min() ?? 0, max: w.max() ?? project.stock.width),
                        height: SizeRange(min: h.min() ?? 0, max: h.max() ?? project.stock.height))
        }
    }
}
