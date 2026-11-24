import Foundation

/// Add Toolpath ▸ Inlay…: the settings for both sides of a V-carve inlay (see `VCarveInlay`), made together so they
/// match: one V-bit, the pocket's flat depth P equal to the plug's pocket depth, and the plug's glue gap G, surface
/// clearance C and boundary. Each side has its own clearance tool, since the fit doesn't depend on it and the quickest
/// end mill for the pocket's flats often isn't the quickest for the plug's (`Project.inlayClearanceTimes`).
public struct InlayPairSettings: Hashable, Sendable {
    public var vBit: Tool
    /// The end mill that clears the pocket's flats; nil = the V-bit clears them itself.
    public var pocketClearanceTool: Tool?
    /// The end mill that clears the plug's flats; nil = the V-bit clears them itself.
    public var plugClearanceTool: Tool?
    /// The sides whose clearance tool was picked by hand (`pickClearance`): starting each side with its quickest end
    /// mill (`withQuickestClearance`) leaves them as they are.
    public var pickedClearance: Set<VCarveInlay.Role> = []
    /// Both sides' clearance tool: reading gives the pocket's, setting it sets both.
    public var clearanceTool: Tool? {
        get { pocketClearanceTool }
        set {
            pocketClearanceTool = newValue
            plugClearanceTool = newValue
        }
    }
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
        self.pocketClearanceTool = clearanceTool
        self.plugClearanceTool = clearanceTool
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
        let pocket = CAMOperation(name: Self.pocketName, kind: .vcarve(VCarveParams(
            flatDepth: pocketDepth, clearanceTool: pocketClearanceTool, inlay: VCarveInlay(role: .pocket),
            flatRaster: pocketClearanceTool == nil ? flatRaster : nil)), shapeIDs: design, tool: vBit)
        var plug = CAMOperation(name: Self.plugName, kind: .vcarve(VCarveParams(
            clearanceTool: plugClearanceTool, inlay: plugInlay, flatRaster: plugClearanceTool == nil ? flatRaster : nil)),
                                shapeIDs: design + (boundary == .vector ? boundaryVector.map { [$0] } ?? [] : []), tool: vBit)
        plug.enabled = false
        return (pocket, plug)
    }

    /// One side's clearance tool.
    public func clearanceTool(_ side: VCarveInlay.Role) -> Tool? {
        side == .pocket ? pocketClearanceTool : plugClearanceTool
    }

    /// Picks `tool` (nil: the V-bit) by hand to clear one side's flats: it stays when the side's quickest end mill is
    /// worked out again.
    public mutating func pickClearance(_ tool: Tool?, for side: VCarveInlay.Role) {
        if side == .pocket { pocketClearanceTool = tool } else { plugClearanceTool = tool }
        pickedClearance.insert(side)
    }

    /// The settings with each side not picked by hand clearing with its quickest end mill in `times` (when there is one).
    public func withQuickestClearance(_ times: InlayClearanceTimes) -> InlayPairSettings {
        var s = self
        for side in VCarveInlay.Role.allCases where !pickedClearance.contains(side) {
            guard let tool = times.quickest(side) else { continue }
            if side == .pocket { s.pocketClearanceTool = tool } else { s.plugClearanceTool = tool }
        }
        return s
    }

    /// What the clearance times depend on: these settings without their clearance tools, picks or raster.
    public var timingKey: InlayPairSettings {
        var s = self
        s.pocketClearanceTool = nil
        s.plugClearanceTool = nil
        s.pickedClearance = []
        s.flatRaster = nil
        return s
    }
}

/// How long one side of an inlay takes with an end mill clearing its flats: the side's run-time estimate on its own,
/// the V-bit's carving and its clean-up of the corners the end mill can't reach included.
public struct InlayClearanceTime: Hashable, Sendable {
    public var tool: Tool
    public var seconds: Double

    public init(tool: Tool, seconds: Double) {
        self.tool = tool
        self.seconds = seconds
    }
}

/// Each flat end mill's time on each side of an inlay (`Project.inlayClearanceTimes`).
public struct InlayClearanceTimes: Hashable, Sendable {
    public var pocket: [InlayClearanceTime]
    public var plug: [InlayClearanceTime]
    /// The settings they were timed for (`InlayPairSettings.timingKey`).
    public var key: InlayPairSettings

    /// Times within this many seconds, or this fraction of the shorter, are a tie.
    public static let tieSeconds = 1.0
    public static let tieFraction = 0.005

    public func times(_ side: VCarveInlay.Role) -> [InlayClearanceTime] { side == .pocket ? pocket : plug }

    /// The side's time with `tool` clearing its flats, when it was timed.
    public func seconds(_ side: VCarveInlay.Role, tool: Tool) -> Double? {
        times(side).first { $0.tool.id == tool.id }?.seconds
    }

    /// The end mill that clears the side quickest; on a tie, the larger, then the lower tool number. nil when none was
    /// timed.
    public func quickest(_ side: VCarveInlay.Role) -> Tool? {
        func better(_ t: InlayClearanceTime, than b: InlayClearanceTime) -> Bool {
            let tie = abs(t.seconds - b.seconds) <= max(Self.tieSeconds, Self.tieFraction * min(t.seconds, b.seconds))
            guard tie else { return t.seconds < b.seconds }
            if abs(t.tool.diameter - b.tool.diameter) > 1e-6 { return t.tool.diameter > b.tool.diameter }
            if abs(t.seconds - b.seconds) > 1e-9 { return t.seconds < b.seconds }
            return t.tool.number < b.tool.number
        }
        var best: InlayClearanceTime?
        for t in times(side) where best.map({ better(t, than: $0) }) ?? true { best = t }
        return best?.tool
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

    /// Times every flat end mill among `tools` clearing the flats on each side of the inlay `settings` makes for the
    /// closed vectors among `ids` (their clearance tools aside): each side's run-time estimate on its own, as it would be
    /// cut, the V-bit's carving and clean-up included. The end mills are timed in parallel. nil when there's no design, or
    /// when `shouldStop` says so (it's asked before each side is timed).
    func inlayClearanceTimes(_ settings: InlayPairSettings, shapes ids: [UUID], tools: [Tool],
                             shouldStop: @Sendable () -> Bool = { false }) -> InlayClearanceTimes? {
        let layout = inlayLayout(ids, boundary: settings.boundary)
        guard let first = layout.design.first else { return nil }
        // The design's sheet as a job of its own, without tiles: only the one side cut.
        var base = sheetCount > 1 ? sheetProject(shape(id: first).map { sheetIndex(of: $0) } ?? 0) : self
        base.tiling = nil
        func seconds(_ op: CAMOperation) -> Double {
            var p = base
            var o = op
            o.enabled = true
            p.operations = [o]
            return CAMEngine.generate(p).estimatedSeconds
        }
        let key = settings.timingKey
        let mills = tools.filter { $0.shape == .flatEndMill }
        // Each end mill on each side: the pocket's at 2k, the plug's at 2k + 1.
        let out = ParallelResults<Double>(count: 2 * mills.count, initial: 0)
        DispatchQueue.concurrentPerform(iterations: 2 * mills.count) { i in
            guard !shouldStop() else { return }
            var s = key
            s.clearanceTool = mills[i / 2]
            let pair = s.operations(design: layout.design, boundaryVector: layout.boundary)
            out[i] = seconds(i % 2 == 0 ? pair.pocket : pair.plug)
        }
        if shouldStop() { return nil }
        let times = out.array
        return InlayClearanceTimes(pocket: mills.indices.map { InlayClearanceTime(tool: mills[$0], seconds: times[2 * $0]) },
                                   plug: mills.indices.map { InlayClearanceTime(tool: mills[$0], seconds: times[2 * $0 + 1]) },
                                   key: key)
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
