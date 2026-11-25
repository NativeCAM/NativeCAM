import Foundation

/// A complete job: material, machine, vectors and operations. Toolpaths are derived, never stored.
public struct Project: Hashable, Sendable {
    /// Newest file format this build reads. Format 2 adds machines with a controller other than Avid's Mach4
    /// profile, or with a rotary axis. Format 3 adds rotary stock and index angles: builds that read format 2 would drop the blank and
    /// post the job as a flat sheet, which with Z zeroed on the rotation axis drives the tool into the blank. Flat
    /// projects on Avid's Mach4 profile are still written as format 1 so older builds keep opening them. Format 4 adds
    /// a rotary axis turned by hand, where builds that read format 3 would write A moves the machine can't make. Format 5
    /// adds wrapped rotary jobs: a format-4 build would read the unrolled sheet as one face and cut it indexed. Format 6
    /// adds a V-carve's start depth and inlay plugs, which a format-5 build would carve from the surface as an ordinary
    /// V-carve of the design. Format 7 adds 3D rotary finishing and models placed on a rotary blank, which a format-6
    /// build can't read or would lay flat on the sheet. Format 8 adds chamfer, fluting and prism toolpaths, which a
    /// format-7 build can't read. Format 9 adds tiling: a format-8 build would ignore it and post the whole job as one
    /// file, bigger than the machine's travel. Settings for tiling that's off (or leaves the job in one tile) don't raise it.
    /// Format 10 adds 3D finishing strategies (waterline, steep and shallow, pencil) and cross-hatching, which a format-9
    /// build would ignore and cut as one raster. Format 12 adds 3D rotary roughing, which older builds can't read.
    /// Format 13 adds adaptive pocket clearing, which a format-12 build can't read. Format 14 adds whole-board V-carve
    /// inlay plugs, which a format-13 build can't read. Format 15 adds tapered ball nose, form and dovetail bits, which a
    /// format-14 build can't read. Format 16 adds jobs nested onto several sheets: an older build would ignore which
    /// sheet each part is on and cut them all on top of each other on the first. A job of one sheet doesn't raise it.
    /// Format 17 adds 3D rest finishing, which an older build can't read. Format 18 adds edge profiles, which an older
    /// build can't read. Format 19 adds a chamfer's overcut, which an older build would ignore and cut a V-groove at the
    /// bevel's foot, and chamfers cut with a form bit, which older builds refuse. Format 20 adds size rules on how a
    /// toolpath finds its vectors (`SizeFilter`): an older build would ignore one and pick up every shape on the layer or
    /// of the kind the next time it looks. Format 21 adds constant scallop, spiral and radial 3D finishing, which an older
    /// build can't read. Format 22 adds mouldings (a profile swept along rails), which an older build can't read. Format 25 adds flutes that
    /// follow a 3D model's surface, which an older build would cut from the start depth instead. Format 26 adds adaptive
    /// clearing for 3D roughing's layers, which an older build would ignore and cut each layer in offset rings. Format 27 adds a
    /// cut direction on the toolpaths whose passes run in rows or a pattern (`PassDirection`), which an older build would
    /// ignore and cut its own way. The default direction, each toolpath's old one, doesn't raise it. Format 28 adds a
    /// profile's separate finishing pass (`ProfileFinishPass`), which an older build would ignore and cut the part to the
    /// roughing's size. Format 29 adds a profile's triangular tabs, tabs placed by hand and chosen start points
    /// (`TabSettings.formatVersion`), which an older build would ignore and cut its own evenly spaced rectangular tabs,
    /// starting each loop elsewhere. Format 30 adds strips under a cut-out's tabs in flat 3D roughing and finishing
    /// (`CAMOperation.holdsTabsFormatVersion`), which an older build would ignore, holding the whole floor or cutting it
    /// through, with the cut-out's tabs elsewhere on the wall.
    public static let currentFormatVersion = 30

    /// The format this project is written as: the oldest one that can hold it.
    public var formatVersion: Int {
        let byHand = stock.rotary != nil && machine.rotary?.turnsByHand == true ? 4 : 1
        let parts = operations.map(\.requiredFormatVersion) + shapes.map(\.kind.requiredFormatVersion)
            + operations.compactMap { $0.vectorSelection?.requiredFormatVersion }
        // Only tiling that splits the job: one tile is the same file a format-8 build writes.
        let tiled = tiling?.enabled == true && TileLayout(self) != nil ? 9 : 1
        let sheets = sheetCount > 1 ? 16 : 1
        let strips = HoldingTabs.Job(self).hasStrips ? CAMOperation.holdsTabsFormatVersion : 1
        return parts.reduce(max(machine.requiredFormatVersion, stock.requiredFormatVersion, byHand, tiled, sheets, strips), max)
    }

    /// Keeps every spiral climbing exactly once around the blank per pitch: on a wrapped job, a spiral's turn is the
    /// sheet's height, which changes with the wrap diameter. Call it after changing the blank.
    public mutating func fitSpiralsToSheet() {
        guard stock.rotary?.isWrapped == true else { return }
        for i in shapes.indices {
            guard case var .spiral(spec) = shapes[i].kind, abs(spec.around - stock.height) > 1e-9 else { continue }
            spec.around = stock.height
            shapes[i].kind = .spiral(spec)
        }
    }

    /// Keeps the 3D models placed for the stock. On a rotary blank each lies along the axis and is centred on it (its
    /// place across the sheet and its rotation there don't apply); one new to the blank is laid along its longest axis,
    /// scaled to fit (`RotaryPlacement.fitScale`) and put in the middle of the blank. On a flat sheet each lies flat
    /// again. Call it after changing the blank or adding a model.
    public mutating func placeModelsOnBlank() {
        for i in shapes.indices {
            guard case var .model(spec) = shapes[i].kind else { continue }
            if let blank = stock.rotary {
                if spec.rotary == nil {
                    spec.rotary = RotaryPlacement(longestOf: spec.mesh)
                    shapes[i].scale = RotaryPlacement.fitScale(spec.alongAxis, blank: blank)
                    shapes[i].position.x = blank.length / 2
                }
                shapes[i].position.y = stock.height / 2
                shapes[i].rotation = 0
            } else {
                spec.rotary = nil
            }
            shapes[i].kind = .model(spec)
        }
    }

    public var name: String
    public var displayUnits: LengthUnit
    /// Changing it keeps depths tied to the material thickness fitted to it (`fitDepthsToMaterial()`).
    public var stock: Stock { didSet { if stock.thickness != oldValue.thickness { fitDepthsToMaterial() } } }
    public var machine: MachineProfile
    public var shapes: [DesignShape]
    /// Changing them keeps depths tied to the material thickness fitted to it (`fitDepthsToMaterial()`).
    public var operations: [CAMOperation] { didSet { fitDepthsToMaterial() } }
    public var notes: String
    /// Cutting the job in tiles bigger than the machine's travel; nil (off) in every older file.
    public var tiling: TilingSettings?
    /// The sheets after the first on a job nested onto several (each shape says which it's on); empty = one sheet.
    public var additionalSheets: [MaterialSheet] = []
    /// Layers made by name with no shapes on them yet (applying a template whose layers the design doesn't have), so
    /// vectors can be put on them. `layerNames` lists them after the shapes' own. An older build drops them, which
    /// changes no cut, so they don't raise the format.
    public var namedLayers: [String] = []

    public init(name: String = "Untitled", displayUnits: LengthUnit = .inch, stock: Stock = Stock(),
                machine: MachineProfile = .avidPRO6060, shapes: [DesignShape] = [], operations: [CAMOperation] = [],
                notes: String = "", tiling: TilingSettings? = nil) {
        self.name = name
        self.displayUnits = displayUnits
        self.stock = stock
        self.machine = machine
        self.shapes = shapes
        self.operations = operations
        self.notes = notes
        self.tiling = tiling
        fitDepthsToMaterial()
    }

    /// Keeps every depth tied to the material thickness (`DepthSettings.fromBottom`, `DrillParams.fromBottom`) at
    /// its distance from the material's bottom. Changing `stock` or `operations` calls it.
    public mutating func fitDepthsToMaterial() {
        let t = stock.thickness
        for i in operations.indices {
            let kind: OperationKind
            switch operations[i].kind {
            case var .profile(p) where p.depth.fromBottom != nil:
                p.depth.fit(thickness: t)
                kind = .profile(p)
            case var .pocket(p) where p.depth.fromBottom != nil:
                p.depth.fit(thickness: t)
                kind = .pocket(p)
            case var .drill(p) where p.fromBottom != nil:
                p.fit(thickness: t)
                kind = .drill(p)
            default:
                continue
            }
            if kind != operations[i].kind { operations[i].kind = kind }
        }
    }

    public func shape(id: UUID) -> DesignShape? { shapes.first { $0.id == id } }

    /// The shapes `op` cuts. With a size rule (`VectorSelection.size`), imported vectors keep only the outlines of the
    /// size (`SizeFilter.cutPart(of:)`).
    public func shapes(for op: CAMOperation) -> [DesignShape] {
        let found = op.shapeIDs.compactMap { shape(id: $0) }
        guard let size = op.vectorSelection?.size else { return found }
        return found.compactMap { size.cutPart(of: $0) }
    }

    /// The inlay pocket a V-carve inlay plug goes into: the one sharing a shape with it (the plug mirrors the same
    /// design), or else the project's only one.
    public func inlayPocket(for plug: CAMOperation) -> CAMOperation? {
        let pockets = operations.filter { $0.id != plug.id && { if case let .vcarve(p) = $0.kind { p.inlay?.role == .pocket } else { false } }($0) }
        return pockets.first { !Set($0.shapeIDs).isDisjoint(with: plug.shapeIDs) } ?? (pockets.count == 1 ? pockets.first : nil)
    }

    /// The selected vector a V-carve inlay plug set to carve inside one does: the one of its shapes holding all the
    /// others. nil when there's none (it then uses the boundary margin) or the plug uses the margin anyway.
    public func plugBoundary(for op: CAMOperation) -> DesignShape? {
        guard case let .vcarve(p) = op.kind, p.isPlug, p.inlay?.boundary == .vector else { return nil }
        let shapes = shapes(for: op).filter { !$0.isKeepOut }
        let outlines = shapes.map { $0.polylines(tolerance: 0.05).filter { $0.isClosed && $0.count >= 3 } }
        return VCarveGenerator.plugBoundaryIndex(outlines: outlines).map { shapes[$0] }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> Project {
        try JSONDecoder().decode(Project.self, from: data)
    }
}

extension Project: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, displayUnits, stock, machine, shapes, operations, notes, tiling, additionalSheets
        case namedLayers = "layers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Project.currentFormatVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "This project was saved by a newer version of NativeCAM (format \(version))."])
        }
        name = try c.decode(String.self, forKey: .name)
        displayUnits = try c.decode(LengthUnit.self, forKey: .displayUnits)
        stock = try c.decode(Stock.self, forKey: .stock)
        machine = try c.decode(MachineProfile.self, forKey: .machine)
        shapes = try c.decode([DesignShape].self, forKey: .shapes)
        operations = try c.decode([CAMOperation].self, forKey: .operations)
        notes = try c.decode(String.self, forKey: .notes)
        tiling = try c.decodeIfPresent(TilingSettings.self, forKey: .tiling)
        additionalSheets = try c.decodeIfPresent([MaterialSheet].self, forKey: .additionalSheets) ?? []
        namedLayers = try c.decodeIfPresent([String].self, forKey: .namedLayers) ?? []
        fitDepthsToMaterial()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(name, forKey: .name)
        try c.encode(displayUnits, forKey: .displayUnits)
        try c.encode(stock, forKey: .stock)
        try c.encode(machine, forKey: .machine)
        try c.encode(shapes, forKey: .shapes)
        // Flat 3D toolpaths that leave strips under a cut-out's tabs are marked so (format 30).
        let holding = HoldingTabs.Job(self)
        try c.encode(operations.map { StampedOperation(op: $0, holdsTabs: holding.decisions[$0.id]?.strips != nil) }, forKey: .operations)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(tiling, forKey: .tiling)
        if !additionalSheets.isEmpty { try c.encode(additionalSheets, forKey: .additionalSheets) }
        if !namedLayers.isEmpty { try c.encode(namedLayers, forKey: .namedLayers) }
    }
}

/// An operation as saved, with `"holdsTabs": true` when it's a flat 3D toolpath that leaves strips under a cut-out's
/// tabs (`CAMOperation.holdsTabsFormatVersion`). Read back, the key is ignored: the strips are worked out from the job.
private struct StampedOperation: Encodable {
    var op: CAMOperation
    var holdsTabs: Bool
    private enum CodingKeys: String, CodingKey { case holdsTabs }

    func encode(to encoder: Encoder) throws {
        try op.encode(to: encoder)
        guard holdsTabs else { return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(true, forKey: .holdsTabs)
    }
}
