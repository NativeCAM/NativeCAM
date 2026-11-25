import Foundation

// MARK: - How a toolpath finds its vectors

/// Kinds of shape a toolpath can find for itself (see `VectorSelection.kind`). Keep-out shapes never count.
public enum ShapeFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case text, circles, models, open, closed, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: "Text"
        case .circles: "Circles"
        case .models: "3D models"
        case .open: "Open vectors"
        case .closed: "Closed vectors"
        case .all: "All vectors"
        }
    }

    /// What the design has none of, for messages: "no text", "no circles".
    var noun: String {
        switch self {
        case .text: "text"
        case .circles: "circles"
        case .models: "3D models"
        case .open: "open vectors"
        case .closed: "closed vectors"
        case .all: "vectors"
        }
    }

    public func matches(_ shape: DesignShape) -> Bool {
        guard !shape.isKeepOut else { return false }
        switch self {
        case .all: return true
        case .text: if case .text = shape.kind { return true } else { return false }
        case .circles: if case .circle = shape.kind { return true } else { return false }
        case .models: return shape.modelSpec != nil
        case .open: return shape.modelSpec == nil && shape.polylines(tolerance: 0.1).contains { !$0.isClosed }
        case .closed:
            guard shape.modelSpec == nil else { return false }
            let outlines = shape.polylines(tolerance: 0.1)
            return !outlines.isEmpty && outlines.allSatisfy(\.isClosed)
        }
    }

    /// The order a template tries kinds in when a toolpath's shapes are exactly every shape of one: the narrowest first.
    static let inferenceOrder: [ShapeFilter] = [.text, .circles, .models, .open, .closed, .all]
}

/// A range of lengths (mm); a missing end is open.
public struct SizeRange: Hashable, Codable, Sendable {
    public var min: Double?
    public var max: Double?

    public init(min: Double? = nil, max: Double? = nil) {
        self.min = min
        self.max = max
    }

    public func contains(_ value: Double, tolerance: Double) -> Bool {
        if let min, value < min - tolerance { return false }
        if let max, value > max + tolerance { return false }
        return true
    }

    public var isOpen: Bool { min == nil && max == nil }

    /// The ends that are set (mm).
    var ends: [Double] { [min, max].compactMap { $0 } }

    /// "7.5–8.5 mm", "at least 30 mm", "up to 2 in". A length that's a round number in `units` is shown exactly
    /// (to 1/64 in); any other is rounded to 0.001 in or 0.01 mm. `SizeFilter.label` picks the units a rule reads in.
    public func label(_ units: LengthUnit) -> String {
        func f(_ v: Double) -> String {
            let exact = SizeFilter.isRound(v, in: units)
            return SizeFilter.trimmed(units.format(v, decimals: exact ? (units == .inch ? 6 : 3) : (units == .inch ? 3 : 2)))
        }
        switch (min, max) {
        case let (lo?, hi?): return abs(lo - hi) < 1e-9 ? "\(f(lo)) \(units.symbol)" : "\(f(lo))–\(f(hi)) \(units.symbol)"
        case let (lo?, nil): return "at least \(f(lo)) \(units.symbol)"
        case let (nil, hi?): return "up to \(f(hi)) \(units.symbol)"
        case (nil, nil): return "any size"
        }
    }
}

/// A size rule a toolpath that finds its vectors by layer or kind can add (Vectric's circle-diameter filter): circles
/// by diameter, or closed shapes by the width and height of their bounding box. Every part that's set must hold, each
/// to within `tolerance`. Lengths in mm, in design coordinates (after the shape's scale).
public struct SizeFilter: Hashable, Codable, Sendable {
    public static let defaultTolerance = 0.05

    /// Only circles, with a diameter in this range.
    public var diameter: SizeRange?
    /// Only closed shapes, with a bounding box this wide.
    public var width: SizeRange?
    /// Only closed shapes, with a bounding box this tall.
    public var height: SizeRange?
    public var tolerance: Double

    public init(diameter: SizeRange? = nil, width: SizeRange? = nil, height: SizeRange? = nil,
                tolerance: Double = SizeFilter.defaultTolerance) {
        self.diameter = diameter
        self.width = width
        self.height = height
        self.tolerance = tolerance
    }

    /// Circles from `min` to `max` mm across.
    public static func circles(_ min: Double?, _ max: Double?, tolerance: Double = defaultTolerance) -> SizeFilter {
        SizeFilter(diameter: SizeRange(min: min, max: max), tolerance: tolerance)
    }

    /// Closed shapes whose bounding box is in these ranges (mm).
    public static func box(width: SizeRange?, height: SizeRange?, tolerance: Double = defaultTolerance) -> SizeFilter {
        SizeFilter(width: width, height: height, tolerance: tolerance)
    }

    /// True when no part limits anything: the same as no filter.
    public var isEmpty: Bool { (diameter?.isOpen ?? true) && (width?.isOpen ?? true) && (height?.isOpen ?? true) }

    /// True when it measures circles' diameters (else bounding boxes, or nothing).
    public var measuresDiameter: Bool { !(diameter?.isOpen ?? true) }

    /// True when the shape is this size. Imported vectors (`ShapeKind.paths`, one shape per layer) are measured
    /// outline by outline: the shape counts when any outline does, and the toolpath cuts only those
    /// (`Project.shapes(for:)`), so an imported layer of holes drills just the ones of the size.
    public func matches(_ shape: DesignShape) -> Bool {
        guard !shape.isKeepOut, shape.modelSpec == nil else { return false }
        if case .paths = shape.kind { return shape.polylines(tolerance: 0.01).contains(where: matches) }
        if measuresDiameter {
            guard case let .circle(r) = shape.kind, diameter!.contains(2 * r * abs(shape.scale), tolerance: Swift.max(0, tolerance)) else {
                return false
            }
        }
        guard boxRanges != nil else { return true }
        let outlines = shape.polylines(tolerance: 0.01)
        guard !outlines.isEmpty, outlines.allSatisfy(\.isClosed) else { return false }
        return fitsBox(outlines.bounds)
    }

    /// True when one outline (in design coordinates) is this size: a circle of the diameter, a closed outline whose
    /// bounding box fits.
    public func matches(_ outline: Polyline) -> Bool {
        guard outline.isClosed, outline.count >= 3 else { return false }
        if measuresDiameter {
            guard let d = Self.circleDiameter(outline), diameter!.contains(d, tolerance: Swift.max(0, tolerance)) else { return false }
        }
        return boxRanges == nil || fitsBox(outline.bounds)
    }

    /// The part of `shape` a toolpath with this rule cuts: imported vectors keep only the outlines of the size; other
    /// shapes are cut whole. nil when nothing of it is the size.
    public func cutPart(of shape: DesignShape) -> DesignShape? {
        guard case let .paths(paths) = shape.kind else { return shape }
        let t = shape.transform
        let kept = paths.filter { matches($0.transformed(t)) }
        guard !kept.isEmpty else { return nil }
        guard kept.count != paths.count else { return shape }
        var part = shape
        part.kind = .paths(kept)
        return part
    }

    /// The diameter of a closed outline that's a circle (every point as far from the middle of its bounding box, to
    /// within 1% and 0.02 mm), else nil. Imported circles come in as flattened outlines.
    public static func circleDiameter(_ outline: Polyline) -> Double? {
        guard outline.isClosed, outline.count >= 8 else { return nil }
        let b = outline.bounds
        let c = Vec2((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2)
        let radii = outline.points.map { ($0 - c).length }
        guard let lo = radii.min(), let hi = radii.max(), hi > 0 else { return nil }
        let w = b.max.x - b.min.x, h = b.max.y - b.min.y
        guard hi - lo <= Swift.max(0.02, 0.01 * hi), abs(w - h) <= Swift.max(0.02, 0.01 * hi) * 2 else { return nil }
        return 2 * hi
    }

    private var boxRanges: (SizeRange?, SizeRange?)? {
        let w = width.flatMap { $0.isOpen ? nil : $0 }
        let h = height.flatMap { $0.isOpen ? nil : $0 }
        return w == nil && h == nil ? nil : (w, h)
    }

    private func fitsBox(_ b: Rect2) -> Bool {
        guard let (w, h) = boxRanges else { return true }
        let tol = Swift.max(0, tolerance)
        if let w, !w.contains(b.max.x - b.min.x, tolerance: tol) { return false }
        if let h, !h.contains(b.max.y - b.min.y, tolerance: tol) { return false }
        return true
    }

    /// "circles 7.5–8.5 mm across", "at least 30 mm wide, up to 120 mm tall", in the units the rule reads best in
    /// (`labelUnits`): a rule made in mm keeps its mm on an inch design.
    public func label(_ units: LengthUnit) -> String {
        let u = labelUnits(units)
        var parts: [String] = []
        if let d = diameter, !d.isOpen { parts.append("circles \(d.label(u)) across") }
        if let w = width, !w.isOpen { parts.append("\(w.label(u)) wide") }
        if let h = height, !h.isOpen { parts.append("\(h.label(u)) tall") }
        return parts.isEmpty ? "any size" : parts.joined(separator: ", ")
    }

    /// The units to show the rule in: the design's when every length in it is a round number in them, else the other
    /// units when every length is round in those (the units it was made in: 7.5 mm rather than 0.2953 in), else the
    /// design's, rounded.
    public func labelUnits(_ units: LengthUnit) -> LengthUnit {
        let lengths = [diameter, width, height].compactMap { $0 }.flatMap(\.ends)
        if lengths.allSatisfy({ Self.isRound($0, in: units) }) { return units }
        let other: LengthUnit = units == .inch ? .mm : .inch
        return lengths.allSatisfy { Self.isRound($0, in: other) } ? other : units
    }

    /// True when `mm` is a round number in `units`: a whole 0.01 mm, or a whole 0.001 in or 1/64 in.
    static func isRound(_ mm: Double, in units: LengthUnit) -> Bool {
        func whole(_ x: Double) -> Bool { abs(x - x.rounded()) < 1e-6 }
        let v = units.fromMM(mm)
        return units == .inch ? whole(v * 1000) || whole(v * 64) : whole(v * 100)
    }

    /// "8.000" → "8", "7.500" → "7.5".
    static func trimmed(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

/// How a toolpath finds its shapes, so a template's toolpaths find theirs in another design (Vectric's "Automatic"
/// vector selection, by layer or vector type), optionally narrowed by size (`SizeFilter`).
public enum VectorSelection: Hashable, Sendable {
    /// The shapes on these layers (`DesignShape.layer`; letter case and surrounding spaces don't matter), of this size.
    case layers([String], size: SizeFilter? = nil)
    /// Every shape of a kind, of this size.
    case kind(ShapeFilter, size: SizeFilter? = nil)
    /// The shapes selected when the template is applied. In a project, the same as nil: chosen by hand.
    case selection

    /// The size rule, if any (an empty one counts as none).
    public var size: SizeFilter? {
        switch self {
        case let .layers(_, size), let .kind(_, size): size.flatMap { $0.isEmpty ? nil : $0 }
        case .selection: nil
        }
    }

    /// The same rule with another size rule (or none); `.selection` takes none.
    public func sized(_ size: SizeFilter?) -> VectorSelection {
        let s = size.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case let .layers(names, _): return .layers(names, size: s)
        case let .kind(filter, _): return .kind(filter, size: s)
        case .selection: return .selection
        }
    }

    /// The layers a layer rule looks on (empty for the others).
    public var layerNames: [String] {
        if case let .layers(names, _) = self { return names }
        return []
    }

    /// The format a toolpath with this rule needs: one with a size rule is format 20, since an older build would
    /// ignore it and pick up every shape on the layer or of the kind the next time it looks.
    public var requiredFormatVersion: Int { size == nil ? 1 : 20 }

    public var label: String { label(.mm) }

    public func label(_ units: LengthUnit) -> String {
        let base: String
        switch self {
        case let .layers(names, _): base = (names.count == 1 ? "Layer " : "Layers ") + Self.quoted(names)
        case let .kind(filter, _): base = filter.label
        case .selection: return "Selected vectors"
        }
        guard let size else { return base }
        if case .kind(.circles, _) = self, size.measuresDiameter, size.width == nil, size.height == nil, let d = size.diameter {
            return "Circles \(d.label(size.labelUnits(units))) across"
        }
        return "\(base) (\(size.label(units)))"
    }

    /// The warning Checks shows for a toolpath that found no shapes.
    public var emptyMessage: String {
        let fix = "then choose Toolpaths ▸ Recalculate All, or select vectors and click Use Selected Shapes."
        let sized = size.map { " (\($0.label(.mm)))" } ?? ""
        switch self {
        case let .layers(names, _):
            return "No vectors on \(names.count == 1 ? "layer" : "layers") \(Self.quoted(names))\(sized). Put vectors on it, \(fix)"
        case let .kind(filter, _):
            let what = size == nil || label(.mm).hasPrefix("Circles ") == false ? "\(filter.noun)\(sized)" : label(.mm).lowercased()
            return "The design has no \(what). Add some, \(fix)"
        case .selection:
            return "No shapes selected."
        }
    }

    public func matches(_ shape: DesignShape) -> Bool {
        guard !shape.isKeepOut else { return false }
        let found: Bool
        switch self {
        case let .layers(names, _): found = names.contains { Self.sameLayer($0, shape.layer) }
        case let .kind(filter, size):
            // Imported circles are outlines, not circles: a diameter rule finds them among the imported vectors.
            let importedCircles: Bool = { if case .paths = shape.kind { filter == .circles && size?.measuresDiameter == true } else { false } }()
            found = importedCircles || filter.matches(shape)
        case .selection: return false
        }
        return found && (size?.matches(shape) ?? true)
    }

    public static func sameLayer(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    static func quoted(_ names: [String]) -> String { names.map { "“\($0)”" }.joined(separator: ", ") }
}

extension VectorSelection: Codable {
    private enum CodingKeys: String, CodingKey { case layers, kind, selection, size }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = try c.decodeIfPresent(SizeFilter.self, forKey: .size)
        if let names = try c.decodeIfPresent([String].self, forKey: .layers) {
            self = .layers(names, size: size)
        } else if let filter = try c.decodeIfPresent(ShapeFilter.self, forKey: .kind) {
            self = .kind(filter, size: size)
        } else {
            self = .selection
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .layers(names, _): try c.encode(names, forKey: .layers)
        case let .kind(filter, _): try c.encode(filter, forKey: .kind)
        case .selection: try c.encode(true, forKey: .selection)
        }
        try c.encodeIfPresent(size, forKey: .size)
    }
}

extension Project {
    /// The layers the design's shapes are on, in the order they first appear, then the layers made with no shapes
    /// on them (`namedLayers`).
    public var layerNames: [String] {
        var names: [String] = []
        for s in shapes where !names.contains(where: { VectorSelection.sameLayer($0, s.layer) }) { names.append(s.layer) }
        for n in namedLayers where !names.contains(where: { VectorSelection.sameLayer($0, n) }) { names.append(n) }
        return names
    }

    /// True when the design has a layer of this name (letter case and surrounding spaces don't matter).
    public func hasLayer(_ name: String) -> Bool { layerNames.contains { VectorSelection.sameLayer($0, name) } }

    /// Makes empty layers with these names (those the design doesn't have yet), so vectors can be put on them.
    public mutating func addLayers(_ names: [String]) {
        for n in names {
            let name = n.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !hasLayer(name) { namedLayers.append(name) }
        }
    }

    /// The shapes a rule finds, in design order; for `.selection`, the shapes of `selection` that can be machined.
    public func shapeIDs(matching rule: VectorSelection, selection: [UUID] = []) -> [UUID] {
        if case .selection = rule {
            return selection.filter { id in shape(id: id).map { !$0.isKeepOut } ?? false }
        }
        return shapes.filter { rule.matches($0) }.map(\.id)
    }

    /// The rule a template would use for a toolpath whose shapes were chosen by hand: the layers its shapes are on
    /// when it has every shape on them, else a kind when it has every shape of it, else the selection when applied.
    /// nil for a toolpath that needs no shapes (rounding).
    public func inferredVectorSelection(for op: CAMOperation) -> VectorSelection? {
        guard op.kind.needsShapes else { return nil }
        let mine = shapes(for: op).filter { !$0.isKeepOut }
        guard !mine.isEmpty else { return .selection }
        let ids = Set(mine.map(\.id))
        var layers: [String] = []
        for s in mine where !layers.contains(where: { VectorSelection.sameLayer($0, s.layer) }) { layers.append(s.layer) }
        if Set(shapeIDs(matching: .layers(layers))) == ids { return .layers(layers) }
        for filter in ShapeFilter.inferenceOrder where Set(shapeIDs(matching: .kind(filter))) == ids { return .kind(filter) }
        // Circles of one size range, when they're every circle that size: on their layers, else anywhere.
        let diameters = mine.compactMap { s -> Double? in if case let .circle(r) = s.kind { 2 * r * abs(s.scale) } else { nil } }
        if diameters.count == mine.count, let lo = diameters.min(), let hi = diameters.max() {
            let size = SizeFilter.circles(lo, hi)
            for rule in [VectorSelection.layers(layers, size: size), .kind(.circles, size: size)] where Set(shapeIDs(matching: rule)) == ids {
                return rule
            }
        }
        return .selection
    }

    /// The line under a toolpath's vectors saying how a template would find them, for a toolpath without a rule of its
    /// own. Flutes set to follow a 3D model that's no longer in the job say so instead: what's left of their shapes is
    /// only the flute lines, so the inferred rule would read as a layer that wasn't chosen (#139).
    public func templateLine(for op: CAMOperation, units: LengthUnit) -> String? {
        if case let .fluting(f) = op.kind, let id = f.surfaceModelID,
           !shapes.contains(where: { $0.id == id && $0.modelSpec != nil && !$0.isKeepOut }) {
            return "In a template: nothing yet, as the 3D model these flutes follow is missing. Choose one under Follow."
        }
        guard let inferred = inferredVectorSelection(for: op) else { return nil }
        return inferred == .selection ? "In a template: the vectors selected when it's applied." : "In a template: \(inferred.label(units))."
    }

    /// How a template saved from this project finds a toolpath's shapes: its own rule, or the inferred one.
    public func templateVectorSelection(for op: CAMOperation) -> VectorSelection? {
        guard op.kind.needsShapes else { return nil }
        if let rule = op.vectorSelection, rule != .selection { return rule }
        return inferredVectorSelection(for: op)
    }

    /// Gives every toolpath that finds its own shapes (by layer or kind) the shapes its rule finds now. Returns true
    /// when any changed.
    @discardableResult
    public mutating func bindVectors() -> Bool {
        var changed = false
        for i in operations.indices {
            guard operations[i].kind.needsShapes, let rule = operations[i].vectorSelection, rule != .selection else { continue }
            let ids = shapeIDs(matching: rule)
            if ids != operations[i].shapeIDs {
                operations[i].shapeIDs = ids
                changed = true
            }
        }
        return changed
    }

    /// Puts shapes on a layer, and has toolpaths that find their shapes by layer pick them up (or drop them).
    public mutating func setLayer(_ name: String, of ids: Set<UUID>) {
        let layer = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Default" : name
        for i in shapes.indices where ids.contains(shapes[i].id) { shapes[i].layer = layer }
        bindVectors()
    }
}

// MARK: - Tool matching

extension Tool {
    /// True when `other` is the same bit: shape, flute direction, diameter and, where the shape has them, angle, tip
    /// and corner radius. Numbers, names, feeds and lengths don't count.
    public func sameGeometry(as other: Tool) -> Bool {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.005 }
        guard shape == other.shape, fluteDirection == other.fluteDirection, near(diameter, other.diameter) else { return false }
        if shape.usesAngle && abs(includedAngle - other.includedAngle) > 0.05 { return false }
        if shape.isTapered && !near(tipDiameter, other.tipDiameter) { return false }
        if shape.usesCornerRadius && !near(cornerRadius, other.cornerRadius) { return false }
        switch shape {
        case .taperedBallNose:
            if !near(tipDiameter, other.tipDiameter) || abs(includedAngle - other.includedAngle) > 0.05 { return false }
        case .dovetail:
            if abs(includedAngle - other.includedAngle) > 0.05 || !near(fluteLength, other.fluteLength) { return false }
        case .form:
            let a = cuttingEdge, b = other.cuttingEdge
            if a.count != b.count || zip(a, b).contains(where: { !near($0.x, $1.x) || !near($0.y, $1.y) }) { return false }
        default:
            break
        }
        return true
    }
}

extension ToolLibrary {
    /// The library's tool that is the same bit as `tool` (`Tool.sameGeometry`): the same entry if it's there, else
    /// the one most like it (same flute count, then the same number), else the lowest numbered.
    public func matching(_ tool: Tool) -> Tool? {
        let candidates = tools.filter { $0.sameGeometry(as: tool) }
        if let same = candidates.first(where: { $0.id == tool.id }) { return same }
        return candidates.min { a, b in
            func rank(_ t: Tool) -> (Int, Int, Int) { (t.fluteCount == tool.fluteCount ? 0 : 1, t.number == tool.number ? 0 : 1, t.number) }
            return rank(a) < rank(b)
        }
    }
}

// MARK: - Templates

/// A saved set of toolpaths, in run order, with their tools and every setting, to apply to another design (Vectric's
/// toolpath templates). Saved as JSON with the `.nativecamtemplate` extension. Each toolpath keeps how it finds its
/// shapes (`CAMOperation.vectorSelection`) instead of the shapes themselves; depths tied to the material thickness
/// (`DepthSettings.fromBottom`) stay tied to it.
public struct ToolpathTemplate: Hashable, Sendable {
    public static let fileExtension = "nativecamtemplate"
    static let fileType = "NativeCAM toolpath template"

    public var name: String
    /// The toolpaths, in run order, with no shapes (`shapeIDs` empty) and each one's rule for finding them.
    public var operations: [CAMOperation]
    /// The job's material, zero and heights, if saved with it.
    public var jobSetup: JobSetup?

    public init(name: String, operations: [CAMOperation], jobSetup: JobSetup? = nil) {
        self.name = name
        self.operations = operations
        self.jobSetup = jobSetup
    }

    /// The toolpaths `operationIDs` picks from `project` (all of them when nil), in run order.
    public init(name: String, project: Project, operationIDs: Set<UUID>? = nil, includeJobSetup: Bool = true) {
        self.name = name
        operations = project.operations.filter { operationIDs?.contains($0.id) ?? true }.map { Self.templateCopy(of: $0, in: project) }
        jobSetup = includeJobSetup ? JobSetup(project) : nil
    }

    /// The project file format this template needs: the newest its toolpaths need. A build that reads an older
    /// format refuses it, as it does projects.
    public var formatVersion: Int {
        (operations.map(\.requiredFormatVersion) + operations.compactMap { $0.vectorSelection?.requiredFormatVersion }).reduce(1, max)
    }

    /// The layers the template's toolpaths find their vectors on that `project` doesn't have, in the template's order.
    public func missingLayers(in project: Project) -> [String] {
        var missing: [String] = []
        for op in operations where op.kind.needsShapes {
            for name in op.vectorSelection?.layerNames ?? [] where !project.hasLayer(name) {
                if !missing.contains(where: { VectorSelection.sameLayer($0, name) }) { missing.append(name) }
            }
        }
        return missing
    }

    /// `op` as a template keeps it: no shapes but the rule that finds them, no corner overrides (they belong to this
    /// design's shapes), and a depth through the material on a flat sheet tied to the thickness, so the template cuts
    /// through material of any thickness.
    static func templateCopy(of op: CAMOperation, in project: Project) -> CAMOperation {
        var copy = op
        copy.vectorSelection = project.templateVectorSelection(for: op)
        copy.shapeIDs = []
        let t = project.stock.thickness
        let flat = project.stock.rotary == nil
        func through(_ depth: Double) -> Double? { flat && depth >= t - 1e-6 ? t - depth : nil }
        switch copy.kind {
        case var .profile(p):
            p.cornerRelief?.overrides = nil
            if p.depth.fromBottom == nil { p.depth.fromBottom = through(p.depth.cutDepth) }
            copy.kind = .profile(p)
        case var .pocket(p):
            p.cornerRelief?.overrides = nil
            if p.depth.fromBottom == nil { p.depth.fromBottom = through(p.depth.cutDepth) }
            copy.kind = .pocket(p)
        case var .drill(p):
            if p.fromBottom == nil { p.fromBottom = through(p.depth) }
            copy.kind = .drill(p)
        default:
            break
        }
        return copy
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ToolpathTemplate {
        try JSONDecoder().decode(ToolpathTemplate.self, from: data)
    }
}

extension ToolpathTemplate: Codable {
    private enum CodingKeys: String, CodingKey { case type, formatVersion, name, toolpaths, jobSetup }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? c.decode(String.self, forKey: .type)) == Self.fileType else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This file isn't a NativeCAM toolpath template."])
        }
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Project.currentFormatVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "This template was saved by a newer version of NativeCAM (format \(version)). Update NativeCAM to use it."])
        }
        name = try c.decode(String.self, forKey: .name)
        operations = try c.decode([CAMOperation].self, forKey: .toolpaths)
        jobSetup = try c.decodeIfPresent(JobSetup.self, forKey: .jobSetup)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.fileType, forKey: .type)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(name, forKey: .name)
        try c.encode(operations, forKey: .toolpaths)
        try c.encodeIfPresent(jobSetup, forKey: .jobSetup)
    }
}

extension ToolpathTemplate {
    /// The job setup a template can carry: material, zero, heights and the machine it was made for. Not the
    /// material's width and height (the design's own) or a rotary blank.
    public struct JobSetup: Hashable, Codable, Sendable {
        /// nil when saved from a rotary job, whose thickness is the blank's.
        public var thickness: Double?
        public var materialName: String
        public var materialKind: MaterialKind?
        public var xyOrigin: XYOrigin
        public var zZero: ZZero
        public var clearanceHeight: Double
        public var plungeHeight: Double
        public var parkHeight: Double
        public var retractMode: RetractMode?
        public var linkSafeDistance: Double?
        /// The machine the template was made for: its library entry and a name for messages. Applying a template
        /// never changes the machine.
        public var machineName: String
        public var machineLibraryID: String?

        public init(_ project: Project) {
            let s = project.stock
            thickness = s.rotary == nil ? s.thickness : nil
            materialName = s.materialName
            materialKind = s.materialKind
            xyOrigin = s.xyOrigin
            zZero = s.zZero
            clearanceHeight = s.clearanceHeight
            plungeHeight = s.plungeHeight
            parkHeight = s.homePosition.z
            retractMode = s.retractMode
            linkSafeDistance = s.linkSafeDistance
            machineName = Self.machineName(project.machine)
            machineLibraryID = project.machine.libraryID
        }

        static func machineName(_ m: MachineProfile) -> String { "\(m.model.shortName) (\(m.controllerLabel))" }

        /// One setting applying it would change.
        public struct Change: Hashable, Sendable {
            public var setting: String
            public var from: String
            public var to: String
            /// A change that moves where the G-code's zero is, which the machine has to be set up for.
            public var movesZero: Bool
        }

        /// What applying this to `project` would change.
        public func changes(to project: Project) -> [Change] {
            var p = project
            return apply(to: &p)
        }

        /// Sets `project`'s stock from this, returning what changed.
        @discardableResult
        public func apply(to project: inout Project) -> [Change] {
            let u = project.displayUnits
            func len(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
            var changes: [Change] = []
            var s = project.stock
            func set<T: Equatable>(_ path: WritableKeyPath<Stock, T>, _ value: T, _ setting: String, zero: Bool = false,
                                   describe: (T) -> String) {
                guard s[keyPath: path] != value else { return }
                changes.append(Change(setting: setting, from: describe(s[keyPath: path]), to: describe(value), movesZero: zero))
                s[keyPath: path] = value
            }
            if let t = thickness, s.rotary == nil, abs(t - s.thickness) > 1e-6 {
                set(\.thickness, t, "Thickness", describe: len)
            }
            set(\.materialName, materialName, "Material") { $0 }
            set(\.materialKind, materialKind, "Material type") { ($0 ?? .plywood).label }
            set(\.xyOrigin, xyOrigin, "XY zero", zero: true) { $0.label }
            if s.rotary == nil { set(\.zZero, zZero, "Z zero", zero: true) { $0.label } }
            set(\.clearanceHeight, clearanceHeight, "Safe Z", describe: len)
            set(\.plungeHeight, plungeHeight, "Plunge height", describe: len)
            set(\.homePosition.z, parkHeight, "Park height", describe: len)
            set(\.retractMode, retractMode, "Retracts") { ($0 ?? .minimum).label }
            set(\.linkSafeDistance, linkSafeDistance, "Link clearance") { len($0 ?? 0.2.inch) }
            project.stock = s
            return changes
        }

        /// A note when `project` is set up for another machine than the template was made for, else nil.
        public func machineNote(for project: Project) -> String? {
            let m = project.machine
            let same = machineLibraryID != nil && m.libraryID != nil ? machineLibraryID == m.libraryID : machineName == Self.machineName(m)
            return same ? nil : "Made for \(machineName); this job is for \(Self.machineName(m)). Check the feeds and speeds suit it."
        }
    }

    /// What applying a template does: the project with its toolpaths added, and what the toolpaths found.
    public struct Application: Sendable {
        public struct Row: Hashable, Sendable, Identifiable {
            public var id: UUID
            public var name: String
            public var kind: String
            /// How the toolpath found its shapes; nil for one that needs none.
            public var rule: VectorSelection?
            public var shapeCount: Int
            /// True when it needs shapes and found none: it's added empty, and Checks says why.
            public var isEmpty: Bool
            /// True when it isn't added: every layer it finds its vectors on is missing, and the choice was to skip.
            public var skipped: Bool = false
        }

        public struct ToolUse: Hashable, Sendable, Identifiable {
            public var id: UUID { tool.id }
            /// The tool as the toolpaths use it: the library's own when it has the same bit, with the template's feeds.
            public var tool: Tool
            /// True when the library has the same bit (`Tool.sameGeometry`).
            public var inLibrary: Bool
            /// The template's tool number, when the tool now has another one.
            public var templateNumber: Int?
            /// True when the library's bit has other feeds and speeds than the template's, which the toolpaths use.
            public var feedsDiffer: Bool
        }

        public var project: Project
        public var addedOperationIDs: [UUID]
        public var rows: [Row]
        public var tools: [ToolUse]
        /// What the template's job setup changed (empty when not used).
        public var setupChanges: [JobSetup.Change]
        public var machineNote: String?
        /// The layers the toolpaths find vectors on that the design didn't have (`ToolpathTemplate.missingLayers`).
        public var missingLayers: [String] = []
        /// The ones made, empty, with `MissingLayers.create`.
        public var createdLayers: [String] = []

        /// The toolpaths left out with `MissingLayers.skip`.
        public var skippedCount: Int { rows.filter(\.skipped).count }

        /// The template's tools the library doesn't have, to offer adding.
        public var newTools: [Tool] { tools.filter { !$0.inLibrary }.map(\.tool) }
        public var emptyCount: Int { rows.filter { $0.isEmpty && !$0.skipped }.count }
    }

    /// What applying a template does about layers its toolpaths look on that the design doesn't have.
    public enum MissingLayers: String, Sendable, CaseIterable {
        /// Adds the toolpaths empty, and Checks lists them. Only for callers that showed the layers and were told to.
        case addEmpty
        /// Makes the layers, empty and named, so vectors can be put on them; the toolpaths are added bound to them.
        case create
        /// Leaves out each toolpath whose layers are all missing.
        case skip
    }

    /// Adds the template's toolpaths after `project`'s own. Each finds its shapes by its rule (`selection` for those
    /// that take the shapes selected now); one that finds none is added empty, and Checks says why. Each tool becomes
    /// the library's (or the project's) tool with the same geometry, keeping the template's feeds and speeds; a tool
    /// that's new keeps its number unless another bit has it. With `useJobSetup`, the template's material, zero and
    /// heights replace the project's first, and depths tied to the thickness follow the new one.
    /// `missingLayers` says what's done about layers the design doesn't have: the app and the command line ask first.
    public func apply(to project: Project, library: ToolLibrary, selection: [UUID] = [], useJobSetup: Bool = false,
                      missingLayers choice: MissingLayers = .addEmpty) -> Application {
        var p = project
        let setupChanges = useJobSetup ? jobSetup.map { $0.apply(to: &p) } ?? [] : []
        let missing = missingLayers(in: project)
        if choice == .create { p.addLayers(missing) }

        // Tools: the template's, resolved once each.
        let projectTools = project.operations.flatMap { [$0.tool] + ($0.clearanceTool.map { [$0] } ?? []) }
        var taken = library.tools + projectTools
        var resolved: [UUID: Tool] = [:]
        var uses: [Application.ToolUse] = []
        func resolve(_ t: Tool) -> Tool {
            if let done = resolved[t.id] { return done }
            var use: Application.ToolUse
            if let m = library.matching(t) {
                var r = m
                r.cutting = t.cutting
                use = Application.ToolUse(tool: r, inLibrary: true, templateNumber: r.number == t.number ? nil : t.number, feedsDiffer: m.cutting != t.cutting)
            } else if let m = projectTools.first(where: { $0.sameGeometry(as: t) }) {
                var r = m
                r.cutting = t.cutting
                use = Application.ToolUse(tool: r, inLibrary: false, templateNumber: r.number == t.number ? nil : t.number, feedsDiffer: false)
            } else {
                var r = t
                if taken.contains(where: { $0.number == r.number && !$0.sameGeometry(as: r) }) {
                    r.number = (taken.map(\.number).max() ?? 0) + 1
                }
                use = Application.ToolUse(tool: r, inLibrary: false, templateNumber: r.number == t.number ? nil : t.number, feedsDiffer: false)
            }
            taken.append(use.tool)
            if !uses.contains(where: { $0.tool.id == use.tool.id }) { uses.append(use) }
            resolved[t.id] = use.tool
            return use.tool
        }

        var added: [UUID] = []
        var rows: [Application.Row] = []
        for source in operations {
            var op = source
            op.id = UUID()
            let looksOn = op.kind.needsShapes ? source.vectorSelection?.layerNames ?? [] : []
            if choice == .skip, !looksOn.isEmpty, looksOn.allSatisfy({ !project.hasLayer($0) }) {
                rows.append(Application.Row(id: op.id, name: op.name, kind: op.kind.label, rule: source.vectorSelection, shapeCount: 0,
                                            isEmpty: true, skipped: true))
                continue
            }
            op.tool = resolve(op.tool)
            switch op.kind {
            case var .pocket(q):
                q.clearanceTool = q.clearanceTool.map(resolve)
                op.kind = .pocket(q)
            case var .vcarve(q):
                q.clearanceTool = q.clearanceTool.map(resolve)
                op.kind = .vcarve(q)
            default:
                break
            }
            let rule = op.kind.needsShapes ? source.vectorSelection ?? .selection : nil
            switch rule {
            case .selection?:
                op.shapeIDs = p.shapeIDs(matching: .selection, selection: selection)
                op.vectorSelection = nil
            case let rule?:
                op.shapeIDs = p.shapeIDs(matching: rule)
            case nil:
                op.shapeIDs = []
                op.vectorSelection = nil
            }
            p.operations.append(op)
            added.append(op.id)
            rows.append(Application.Row(id: op.id, name: op.name, kind: op.kind.label, rule: rule, shapeCount: op.shapeIDs.count,
                            isEmpty: op.kind.needsShapes && op.shapeIDs.isEmpty))
        }
        p.fitDepthsToMaterial()
        return Application(project: p, addedOperationIDs: added, rows: rows, tools: uses, setupChanges: setupChanges,
                           machineNote: jobSetup?.machineNote(for: project), missingLayers: missing,
                           createdLayers: choice == .create ? missing : [])
    }
}
