import Foundation

/// Where an import puts a drawing on the material.
public enum ImportPlacement: Hashable, Sendable {
    /// As File ▸ Import does: the file's coordinates when the whole drawing fits on the material, else centred on it.
    case auto
    /// The file's coordinates, whether or not the drawing fits (`ImportedFile.fitsMaterial` says whether it does).
    case keep
    /// Centred on the material.
    case center
    /// The drawing's bounding-box lower-left corner here (mm, design coordinates).
    case at(Vec2)
}

/// How `Project.importFile(at:options:)` imports. The defaults are File ▸ Import's.
public struct ImportOptions: Hashable, Sendable {
    /// The unit of files that carry none (a DXF without `$INSUNITS`, STL, OBJ, PLY). nil = the importers' defaults:
    /// inches for a DXF, millimetres for a mesh. A file that states its unit keeps it; SVG and PDF always use their own.
    public var unit: LengthUnit?
    /// Every imported vector shape goes on this layer instead of the file's (3D models keep theirs). nil = the file's
    /// layers.
    public var layer: String?
    /// Where a drawing goes. 3D models are always centred and fitted, whatever this says.
    public var placement: ImportPlacement
    /// On a job nested onto several sheets, the sheet the shapes go on (from 0; past the last counts as the last).
    public var sheet: Int
    /// A 3D model's carved depth (mm). nil = in proportion to its size, kept 0.02 in shallower than the material.
    public var modelDepth: Double?
    /// A 3D model's up axis. nil = the importer's suggestion.
    public var upAxis: UpAxis?
    /// Maximum chord deviation (mm) when curves are flattened.
    public var tolerance: Double

    public init(unit: LengthUnit? = nil, layer: String? = nil, placement: ImportPlacement = .auto, sheet: Int = 0,
                modelDepth: Double? = nil, upAxis: UpAxis? = nil, tolerance: Double = 0.01) {
        self.unit = unit
        self.layer = layer
        self.placement = placement
        self.sheet = sheet
        self.modelDepth = modelDepth
        self.upAxis = upAxis
        self.tolerance = tolerance
    }
}

/// What one imported file added.
public struct ImportedFile: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case vectors, model }

    /// Where the unit the file was read in came from.
    public enum UnitSource: Hashable, Sendable {
        /// The file states it (DXF `$INSUNITS`, SVG root units, 3MF, USD).
        case file
        /// The file carries none, so the importer's default was used.
        case assumed
        /// The file carries none, so `ImportOptions.unit` was used.
        case given
    }

    public var fileName: String
    public var kind: Kind
    /// The unit read, when it's inches or millimetres (nil for, say, SVG pixels or a 3MF in metres: see `unitScale`).
    public var unit: LengthUnit?
    public var unitSource: UnitSource
    /// Millimetres per file unit.
    public var unitScale: Double
    /// The shapes added, in the order they were added.
    public var shapeIDs: [UUID]
    /// The importer's notes: unit guesses, chains left open, duplicates removed, skipped entities.
    public var warnings: [String]
    /// The drawing's bounds in the file (mm), before it was placed.
    public var fileBounds: Rect2
    /// The added shapes' bounds as placed (mm, design coordinates).
    public var placedBounds: Rect2
    /// Whether the drawing was moved from the file's coordinates.
    public var moved: Bool
    /// Whether the added shapes lie on the material (their sheet's).
    public var fitsMaterial: Bool
    /// The sheet the shapes went on (from 0).
    public var sheet: Int
}

/// A toolpath whose vectors a rule found again (`Project.bindVectorChanges()`).
public struct VectorBindingChange: Hashable, Sendable {
    public var operationID: UUID
    public var name: String
    public var rule: VectorSelection
    public var oldShapeIDs: [UUID]
    public var newShapeIDs: [UUID]
}

extension ImportResult {
    /// Points (DXF POINTs) as the small circles a Drill toolpath drills.
    static func marks(_ pts: [Vec2]) -> [Polyline] {
        pts.map { Polyline(Curves.circle(center: $0, radius: 0.5, tolerance: 0.01), closed: true) }
    }

    /// The drawing's bounds as the file has it (mm), points drawn as their marks.
    public var drawingBounds: Rect2 { (polylines + Self.marks(points)).bounds }
}

extension DesignShape {
    /// A placed 3D model, as File ▸ Import places one: centred on the material, scaled down to 90% of it if larger,
    /// carved in proportion to its size but no deeper than the material less 0.02 in (unless `depth` says how deep).
    public static func importedModel(_ result: MeshImportResult, name: String, stock: Stock, depth: Double? = nil,
                                     upAxis: UpAxis? = nil) -> DesignShape {
        let spec = ModelSpec(mesh: result.mesh, upAxis: upAxis ?? result.suggestedUpAxis, depth: 1)
        let size = spec.naturalSize
        var scale = 1.0
        if size.x > 0, size.y > 0 {
            scale = min(1, stock.width * 0.9 / size.x, stock.height * 0.9 / size.y)
        }
        var s = spec
        s.depth = depth ?? max(0.1, min(spec.proportionalDepth(scale: scale), stock.thickness - 0.02.inch))
        return DesignShape(name: name, kind: .model(s), position: Vec2(stock.width / 2, stock.height / 2), scale: scale)
    }
}

extension Project {
    /// The shape put on sheet `k` of a job nested onto several (the last when `k` is past it).
    public func placedOnSheet(_ shape: DesignShape, sheet k: Int) -> DesignShape {
        var s = shape
        let k = min(k, sheetCount - 1)
        s.sheet = k > 0 ? k : nil
        return s
    }

    /// Imports a vector file or a 3D model and adds its shapes, as File ▸ Import does: one shape per layer, points as
    /// drill marks, 3D models centred, fitted and kept shallower than the material (and, on a rotary blank, laid along
    /// the axis). It doesn't rebind toolpaths: call `bindVectors()` or `bindVectorChanges()` after the last file.
    /// Throws when the file can't be read; then the project is unchanged. A vector file with nothing usable in it adds
    /// no shapes and returns an empty `shapeIDs`.
    @discardableResult
    public mutating func importFile(at url: URL, options: ImportOptions = ImportOptions()) throws -> ImportedFile {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let k = min(max(0, options.sheet), sheetCount - 1)
        let sheetStock = stock(forSheet: k)
        var shapes: [DesignShape]
        var file: ImportedFile
        if ModelImporter.supportedExtensions.contains(ext) {
            let result = try ModelImporter.importFile(at: url, assumedUnit: options.unit ?? .mm)
            let ownUnit = ["3mf", "usdz", "usd", "usda", "usdc"].contains(ext)
            let shape = DesignShape.importedModel(result, name: name, stock: sheetStock, depth: options.modelDepth,
                                                  upAxis: options.upAxis)
            shapes = [shape]
            file = ImportedFile(fileName: url.lastPathComponent, kind: .model, unit: Self.unit(mmPerUnit: result.unitScale),
                                unitSource: ownUnit ? .file : options.unit == nil ? .assumed : .given, unitScale: result.unitScale,
                                shapeIDs: [], warnings: result.warnings, fileBounds: .empty, placedBounds: .empty, moved: true,
                                fitsMaterial: true, sheet: k)
        } else {
            let result = try VectorImporter.importFile(at: url, tolerance: options.tolerance,
                                                       defaultDXFUnit: options.unit ?? .inch)
            shapes = result.shapes(name: name, stock: sheetStock, placement: options.placement)
            let source: ImportedFile.UnitSource = result.sourceUnits != nil || ext != "dxf" && ext != "svg" ? .file
                : ext == "dxf" && options.unit != nil ? .given : .assumed
            file = ImportedFile(fileName: url.lastPathComponent, kind: .vectors, unit: Self.unit(mmPerUnit: result.unitScale),
                                unitSource: source, unitScale: result.unitScale, shapeIDs: [], warnings: result.warnings,
                                fileBounds: result.drawingBounds, placedBounds: .empty, moved: false, fitsMaterial: true, sheet: k)
        }
        // Vector shapes only: a toolpath finding its vectors on the layer shouldn't also pick up a 3D model.
        if file.kind == .vectors, let layer = options.layer?.trimmingCharacters(in: .whitespaces), !layer.isEmpty {
            for i in shapes.indices { shapes[i].layer = layer }
        }
        shapes = shapes.map { placedOnSheet($0, sheet: k) }
        self.shapes.append(contentsOf: shapes)
        // On a rotary blank a model lies along the axis, scaled to fit.
        if file.kind == .model { placeModelsOnBlank() }
        let ids = Set(shapes.map(\.id))
        let placed = self.shapes.filter { ids.contains($0.id) }
        file.shapeIDs = placed.map(\.id)
        file.placedBounds = placed.map { $0.modelBounds ?? $0.bounds }.reduce(Rect2.empty) { $0.union($1) }
        if file.kind == .vectors, !placed.isEmpty {
            file.moved = (file.placedBounds.min - file.fileBounds.min).length > 1e-6
        }
        let material = sheetStock.bounds.insetBy(-0.001)
        file.fitsMaterial = placed.isEmpty || material.contains(file.placedBounds.min) && material.contains(file.placedBounds.max)
        return file
    }

    static func unit(mmPerUnit scale: Double) -> LengthUnit? {
        abs(scale - 1) < 1e-9 ? .mm : abs(scale - LengthUnit.mmPerInch) < 1e-9 ? .inch : nil
    }

    /// Gives every toolpath that finds its own shapes (by layer or kind) the shapes its rule finds now, and returns
    /// each toolpath whose shapes changed. Toolpaths whose shapes were chosen by hand are never touched.
    @discardableResult
    public mutating func bindVectorChanges() -> [VectorBindingChange] {
        var changes: [VectorBindingChange] = []
        for i in operations.indices {
            guard operations[i].kind.needsShapes, let rule = operations[i].vectorSelection, rule != .selection else { continue }
            let ids = shapeIDs(matching: rule)
            if ids != operations[i].shapeIDs {
                changes.append(VectorBindingChange(operationID: operations[i].id, name: operations[i].name, rule: rule,
                                                   oldShapeIDs: operations[i].shapeIDs, newShapeIDs: ids))
                operations[i].shapeIDs = ids
            }
        }
        return changes
    }
}
