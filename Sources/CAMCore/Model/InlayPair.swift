import Foundation

/// Add Toolpath ▸ Inlay…: the settings for both sides of a V-carve inlay (see `VCarveInlay`), made together so they
/// match: one V-bit and clearance tool, the pocket's flat depth P equal to the plug's pocket depth, and the plug's glue
/// gap G, surface clearance C and boundary.
public struct InlayPairSettings: Hashable, Sendable {
    public var vBit: Tool
    /// The end mill that clears the flats on both sides; nil = the V-bit clears them itself.
    public var clearanceTool: Tool?
    /// P: the pocket's flat depth, and the plug's pocket depth, mm.
    public var pocketDepth: Double
    /// G, mm.
    public var glueGap: Double
    /// C, mm.
    public var surfaceClearance: Double
    public var boundary: VCarveInlay.Boundary
    public var boundaryMargin: Double
    /// Whole board: the plug board's size, mm; nil = the material.
    public var boardSize: Vec2?
    /// How the V-bit clears flats on both sides when there's no clearance tool: raster lines, or rings (nil).
    public var flatRaster: VCarveRaster?

    public static let pocketName = "Inlay pocket"
    public static let plugName = "Inlay plug"

    public init(vBit: Tool, clearanceTool: Tool? = nil, pocketDepth: Double = VCarveInlay.defaultPocketDepth,
                glueGap: Double = VCarveInlay.defaultGlueGap, surfaceClearance: Double = VCarveInlay.defaultSurfaceClearance,
                boundary: VCarveInlay.Boundary = .margin, boundaryMargin: Double = VCarveInlay.defaultBoundaryMargin,
                boardSize: Vec2? = nil, flatRaster: VCarveRaster? = nil) {
        self.vBit = vBit
        self.clearanceTool = clearanceTool
        self.pocketDepth = pocketDepth
        self.glueGap = glueGap
        self.surfaceClearance = surfaceClearance
        self.boundary = boundary
        self.boundaryMargin = boundaryMargin
        self.boardSize = boardSize
        self.flatRaster = flatRaster
    }

    /// The plug's inlay settings.
    public var plugInlay: VCarveInlay {
        VCarveInlay(role: .plug, pocketDepth: pocketDepth, glueGap: glueGap, surfaceClearance: surfaceClearance, boundary: boundary,
                    boundaryMargin: boundaryMargin, boardSize: boundary == .board ? boardSize : nil)
    }

    /// The two toolpaths for `design` (the pocket's shapes) and, with a selected-vector boundary, the vector round it
    /// (the plug's too). The plug starts with Include in output off: the sides are cut from separate boards, one at a time.
    public func operations(design: [UUID], boundaryVector: UUID?) -> (pocket: CAMOperation, plug: CAMOperation) {
        let raster = clearanceTool == nil ? flatRaster : nil
        let pocket = CAMOperation(name: Self.pocketName, kind: .vcarve(VCarveParams(
            flatDepth: pocketDepth, clearanceTool: clearanceTool, inlay: VCarveInlay(role: .pocket), flatRaster: raster)),
                                  shapeIDs: design, tool: vBit)
        var plug = CAMOperation(name: Self.plugName, kind: .vcarve(VCarveParams(
            clearanceTool: clearanceTool, inlay: plugInlay, flatRaster: raster)),
                                shapeIDs: design + (boundary == .vector ? boundaryVector.map { [$0] } ?? [] : []), tool: vBit)
        plug.enabled = false
        return (pocket, plug)
    }
}

public extension Project {
    /// The shapes among `ids` an inlay can be made from, in the order given: those with a closed outline, other than
    /// keep-out zones and 3D models.
    func inlayShapes(_ ids: [UUID]) -> [DesignShape] {
        ids.compactMap { shape(id: $0) }.filter { s in
            !s.isKeepOut && s.modelSpec == nil && s.polylines(tolerance: 0.05).contains { $0.isClosed && $0.count >= 3 }
        }
    }

    /// Splits the closed vectors among `ids` into an inlay's design and, for a selected-vector boundary, the vector
    /// round all the rest (nil when none is; the plug then uses the margin).
    func inlayLayout(_ ids: [UUID], boundary: VCarveInlay.Boundary) -> (design: [UUID], boundary: UUID?) {
        let shapes = inlayShapes(ids)
        guard boundary == .vector else { return (shapes.map(\.id), nil) }
        let outlines = shapes.map { $0.polylines(tolerance: 0.05).filter { $0.isClosed && $0.count >= 3 } }
        guard let i = VCarveGenerator.plugBoundaryIndex(outlines: outlines) else { return (shapes.map(\.id), nil) }
        return (shapes.indices.filter { $0 != i }.map { shapes[$0].id }, shapes[i].id)
    }

    /// Adds a matching inlay pocket and plug for the closed vectors among `ids` after the other toolpaths, and returns
    /// them; nil when there are none.
    @discardableResult
    mutating func addInlay(_ settings: InlayPairSettings, shapes ids: [UUID]) -> (pocket: CAMOperation, plug: CAMOperation)? {
        let layout = inlayLayout(ids, boundary: settings.boundary)
        guard !layout.design.isEmpty else { return nil }
        let pair = settings.operations(design: layout.design, boundaryVector: layout.boundary)
        operations += [pair.pocket, pair.plug]
        return pair
    }

    /// The plug board a whole-board plug carves (`VCarveInlay.board(around:stock:)`); nil for anything else.
    func plugBoard(for op: CAMOperation) -> Rect2? {
        guard case let .vcarve(p) = op.kind, let inlay = p.inlay, inlay.role == .plug, inlay.boundary == .board else { return nil }
        let design = VCarveGenerator.plugLayout(shapes: shapes(for: op).filter { !$0.isKeepOut }, tolerance: 0.01, useVector: false).design
        guard !design.isEmpty else { return nil }
        return inlay.board(around: design.bounds.center, stock: stock)
    }

    /// The other side of a V-carve inlay: a plug's pocket (`inlayPocket(for:)`), or the plugs that go into a pocket.
    func inlayPartners(of op: CAMOperation) -> [CAMOperation] {
        guard case let .vcarve(p) = op.kind, let inlay = p.inlay else { return [] }
        switch inlay.role {
        case .plug: return inlayPocket(for: op).map { [$0] } ?? []
        case .pocket:
            return operations.filter { other in
                guard other.id != op.id, case let .vcarve(q) = other.kind, q.isPlug else { return false }
                return inlayPocket(for: other)?.id == op.id
            }
        }
    }
}

/// A setting the two sides of an inlay share that differs between them, so the plug won't fit as made. The end mill
/// that clears each side's flats isn't one: the V walls and the depths decide the fit, so each side may clear with
/// whichever end mill is quickest for it (`inlayClearanceTools(differingFrom:)`).
public enum InlayDifference: Hashable, Sendable {
    /// P: a pocket's flat depth, a plug's pocket depth (this side's, the other's; nil for a pocket without a flat).
    case pocketDepth(Double?, Double?)
    /// The V-bit.
    case bit
}

public extension CAMOperation {
    /// P as this side of an inlay has it: a pocket's flat depth, a plug's pocket depth. nil for anything else.
    var inlayPocketDepth: Double? {
        guard case let .vcarve(p) = kind, let inlay = p.inlay else { return nil }
        return inlay.role == .plug ? inlay.pocketDepth : p.flatDepth
    }

    /// The settings the two sides share for the plug to fit (P and the V-bit) that differ between this side of an inlay
    /// and `other`.
    func inlayDifferences(from other: CAMOperation) -> [InlayDifference] {
        guard case let .vcarve(a) = kind, case let .vcarve(b) = other.kind, a.inlay != nil, b.inlay != nil else { return [] }
        var out: [InlayDifference] = []
        let p = inlayPocketDepth, q = other.inlayPocketDepth
        if (p == nil) != (q == nil) || abs((p ?? 0) - (q ?? 0)) > 0.005 { out.append(.pocketDepth(p, q)) }
        if !tool.isSameBit(as: other.tool) { out.append(.bit) }
        return out
    }

    /// The end mills clearing the flats on this side of an inlay and on `other` (nil: the V-bit clears them itself), when
    /// they differ; nil when they're the same. Information only: which end mill clears the flats doesn't affect the fit.
    func inlayClearanceTools(differingFrom other: CAMOperation) -> (mine: Tool?, theirs: Tool?)? {
        guard case let .vcarve(a) = kind, case let .vcarve(b) = other.kind, a.inlay != nil, b.inlay != nil else { return nil }
        switch (a.clearanceTool, b.clearanceTool) {
        case (nil, nil): return nil
        case let (x?, y?) where x.isSameBit(as: y): return nil
        default: return (a.clearanceTool, b.clearanceTool)
        }
    }

    /// `other`, the other side of an inlay, given this side's shared settings: P and the V-bit. Its clearance tool stays
    /// its own, since it doesn't affect the fit. A pocket without a flat depth leaves its plug's pocket depth as it is.
    func inlayPartnerMatched(_ other: CAMOperation) -> CAMOperation {
        guard case let .vcarve(a) = kind, case var .vcarve(b) = other.kind, a.inlay != nil, var inlay = b.inlay else { return other }
        var out = other
        if let depth = inlayPocketDepth {
            if inlay.role == .plug {
                inlay.pocketDepth = depth
                b.inlay = inlay
            } else {
                b.flatDepth = depth
            }
        }
        out.kind = .vcarve(b)
        if !tool.isSameBit(as: other.tool) { out.tool = tool }
        return out
    }
}
