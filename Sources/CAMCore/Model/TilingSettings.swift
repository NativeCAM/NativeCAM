import Foundation

/// Cutting a job bigger than the machine's travel in tiles, one after another, moving the material between them
/// (Vectric's Toolpath Tiling Manager, Carbide Create Pro's tiling). Off by default.
///
/// Tiles are laid out from the material's lower-left corner, one tile pitch apart. Every tile's file is written in its
/// own coordinates (its frame, a pitch-sized rectangle, takes the place of the material for the XY zero), so after the
/// material moves by exactly the pitch every file runs with the same XY zero. Each tile also reaches `overlap` past its
/// tile lines, so a cut that crosses one runs on into the next tile before it breaks (see `TileSplitter`).
public struct TilingSettings: Hashable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The material slides through the machine along Y (open front and back), moving one tile height each time.
        case feedThroughY
        /// The material slides through along X.
        case feedThroughX
        /// Tiles in X and Y, for separate boards or a board moved both ways.
        case grid
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .feedThroughY: "Feed-through in Y"
            case .feedThroughX: "Feed-through in X"
            case .grid: "Individual tiles"
            }
        }
        public var tilesX: Bool { self != .feedThroughY }
        public var tilesY: Bool { self != .feedThroughX }
        public var isFeedThrough: Bool { self != .grid }
    }

    public var enabled: Bool
    public var mode: Mode
    /// Tile width (how far apart tiles are along X), mm; nil = the machine's X travel less a margin. Not used in
    /// feed-through in Y, where a tile is the material's whole width.
    public var tileWidth: Double?
    /// Tile height (how far the material moves along Y between tiles), mm; nil = the machine's Y travel less a margin.
    /// Not used in feed-through in X.
    public var tileHeight: Double?
    /// How far each tile reaches past its tile lines into the next, mm; nil = the largest tool's radius plus a margin.
    public var overlap: Double?
    /// Put the short (remainder) tile first rather than last.
    public var smallestFirst: Bool
    /// Registration holes for dowels, so each move of the material lands exactly one pitch on; nil = none.
    public var registration: RegistrationHoles?

    public init(enabled: Bool = false, mode: Mode = .feedThroughY, tileWidth: Double? = nil, tileHeight: Double? = nil,
                overlap: Double? = nil, smallestFirst: Bool = false, registration: RegistrationHoles? = nil) {
        self.enabled = enabled
        self.mode = mode
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.overlap = overlap
        self.smallestFirst = smallestFirst
        self.registration = registration
    }

    /// Room left between the tile's reach and the machine's travel when the tile size is automatic, mm.
    public static let travelMargin = 1.inch
    /// Overlap beyond the largest tool's radius when the overlap is automatic, mm.
    public static let overlapMargin = 0.125.inch

    /// Registration holes are drilled whenever they're turned on and the material feeds through.
    public var usesRegistration: Bool { registration?.enabled == true && mode.isFeedThrough }
}

/// Holes drilled through the material into the spoilboard so a dowel registers each move of the material.
///
/// Tile 1 drills a pair of holes into the spoilboard just in front of the material (they stay put on the machine), and
/// every tile but the last drills a pair through the material exactly one pitch further on. After the material moves
/// one pitch, those holes are over the spoilboard holes: drop a dowel through each and the tile is in place.
public struct RegistrationHoles: Hashable, Codable, Sendable {
    public var enabled: Bool
    /// Hole (dowel) diameter, mm.
    public var diameter: Double
    /// How far the holes are in from the material's sides (across the feed direction), mm.
    public var edgeOffset: Double
    /// How deep the holes go into the spoilboard below the material, mm.
    public var spoilboardDepth: Double
    /// The bit that drills them; nil = the job's largest flat end mill that fits the hole.
    public var tool: Tool?

    public init(enabled: Bool = true, diameter: Double = 0.25.inch, edgeOffset: Double = 1.inch,
                spoilboardDepth: Double = 0.25.inch, tool: Tool? = nil) {
        self.enabled = enabled
        self.diameter = diameter
        self.edgeOffset = edgeOffset
        self.spoilboardDepth = spoilboardDepth
        self.tool = tool
    }

    public var radius: Double { diameter / 2 }

    /// Clearance between a spoilboard hole and the material's leading edge, mm.
    public static let edgeGap = 0.25.inch

    /// Bits that can bore a straight-sided hole.
    public static func canDrill(_ tool: Tool) -> Bool { !tool.shape.isTapered }

    /// The bit the holes are cut with: the one chosen, or the largest straight-sided bit in the job that fits the hole
    /// (the job's own bits first, so it needs no extra tool change).
    public func resolvedTool(in project: Project) -> Tool? {
        if let tool { return tool }
        let candidates = project.operations.filter(\.enabled).flatMap { [$0.clearanceTool, $0.tool].compactMap { $0 } }
            .filter { Self.canDrill($0) && $0.shape != .surfacing && $0.diameter <= diameter + 1e-6 }
        return candidates.max { $0.diameter < $1.diameter }
    }
}

/// Where the tiles of a tiled job are, worked out from the project's tiling settings.
public struct TileLayout: Hashable, Sendable {
    public struct Tile: Hashable, Sendable, Identifiable {
        /// Run order, from 0.
        public var index: Int
        public var column: Int
        public var row: Int
        /// The tile's pitch-sized frame in job coordinates. Its corner takes the place of the material's for the XY
        /// zero, so it's the same on the machine for every tile.
        public var frame: Rect2
        /// The part of the material the tile is responsible for: its frame, clipped to the material.
        public var core: Rect2
        public var id: Int { index }
        /// 1-based, as the files and setup sheet count them.
        public var number: Int { index + 1 }
        /// Job coordinates minus this offset are the tile's coordinates.
        public var offset: Vec2 { frame.min }
    }

    public var mode: TilingSettings.Mode
    /// Tile size: the frame every tile shares, mm.
    public var pitch: Vec2
    public var overlap: Double
    public var columns: Int
    public var rows: Int
    /// Tile lines between columns and between rows, job X and Y.
    public var seamsX: [Double]
    public var seamsY: [Double]
    public var tiles: [Tile]
    /// The registration holes, when they're on and the layout feeds through.
    public var registration: RegistrationLayout?

    public var count: Int { tiles.count }

    /// The layout for a project, or nil when tiling is off or doesn't apply (a rotary job, or material that fits in one
    /// tile).
    public init?(_ project: Project) {
        guard let settings = project.tiling, settings.enabled, project.stock.rotary == nil else { return nil }
        let stock = project.stock
        let overlap = Self.overlap(project)
        let pitch = Self.pitch(project)
        func axis(_ length: Double, _ pitch: Double, tiled: Bool) -> (count: Int, start: Double) {
            guard tiled, pitch > 1e-6 else { return (1, 0) }
            let n = max(1, Int((length / pitch - 1e-6).rounded(.up)))
            // The short tile first: frames line up with the material's far edge instead, so every move is still one pitch.
            return (n, n > 1 && settings.smallestFirst ? length - Double(n) * pitch : 0)
        }
        let x = axis(stock.width, pitch.x, tiled: settings.mode.tilesX)
        let y = axis(stock.height, pitch.y, tiled: settings.mode.tilesY)
        guard x.count * y.count > 1 else { return nil }
        let size = Vec2(x.count > 1 ? pitch.x : stock.width, y.count > 1 ? pitch.y : stock.height)
        self.mode = settings.mode
        self.pitch = size
        self.overlap = overlap
        columns = x.count
        rows = y.count
        seamsX = (1..<max(1, x.count)).map { x.start + Double($0) * size.x }
        seamsY = (1..<max(1, y.count)).map { y.start + Double($0) * size.y }
        var tiles: [Tile] = []
        for r in 0..<y.count {
            for c in 0..<x.count {
                let frame = Rect2(x: x.start + Double(c) * size.x, y: y.start + Double(r) * size.y, width: size.x, height: size.y)
                let core = Rect2(min: Vec2(max(frame.min.x, 0), max(frame.min.y, 0)),
                                 max: Vec2(min(frame.max.x, stock.width), min(frame.max.y, stock.height)))
                tiles.append(Tile(index: tiles.count, column: c, row: r, frame: frame, core: core))
            }
        }
        self.tiles = tiles
        registration = settings.usesRegistration ? RegistrationLayout(project, tiles: tiles, mode: settings.mode, pitch: size) : nil
    }

    /// The overlap: the setting, or the largest tool's radius plus a margin (rounded up to 1/16 in or 0.5 mm).
    public static func overlap(_ project: Project) -> Double {
        if let o = project.tiling?.overlap { return max(0, o) }
        let step = project.displayUnits == .inch ? 0.0625.inch : 0.5
        let auto = largestToolRadius(project) + TilingSettings.overlapMargin
        return (auto / step - 1e-9).rounded(.up) * step
    }

    /// The radius of the largest bit any enabled toolpath (or its clearing, or the registration holes) cuts with, mm.
    public static func largestToolRadius(_ project: Project) -> Double {
        var tools = project.operations.filter(\.enabled).flatMap { [$0.tool, $0.clearanceTool].compactMap { $0 } }
        if project.tiling?.usesRegistration == true, let t = project.tiling?.registration?.resolvedTool(in: project) { tools.append(t) }
        return tools.map(\.radius).max() ?? 0.125.inch
    }

    /// Tile size along X and Y: the settings, or each axis's travel less what the tile reaches past its frame (the
    /// overlap and the largest tool's radius each side, and the registration holes) and a margin, rounded down to a
    /// whole inch or 10 mm.
    public static func pitch(_ project: Project) -> Vec2 {
        let t = project.tiling ?? TilingSettings()
        return Vec2(t.tileWidth ?? automaticPitch(project, alongX: true), t.tileHeight ?? automaticPitch(project, alongX: false))
    }

    public static func automaticPitch(_ project: Project, alongX: Bool) -> Double {
        let travel = alongX ? project.machine.travel.x : project.machine.travel.y
        let reach = overlap(project) + largestToolRadius(project)
        var low = reach
        if let t = project.tiling, t.usesRegistration, let holes = t.registration, (t.mode == .feedThroughX) == alongX {
            // The spoilboard holes sit in front of the tile's leading edge.
            low = max(low, holes.diameter + RegistrationHoles.edgeGap)
        }
        let step = project.displayUnits == .inch ? 1.inch : 10
        let room = travel - TilingSettings.travelMargin - low - reach
        return max(step, (room / step + 1e-9).rounded(.down) * step)
    }

    /// The column a job X falls in when tile lines are shifted `shift` mm into the later tile.
    public func column(ofX x: Double, shift: Double = 0) -> Int { seamsX.filter { x > $0 + shift }.count }
    public func row(ofY y: Double, shift: Double = 0) -> Int { seamsY.filter { y > $0 + shift }.count }

    /// The tile whose share of the job a point is in, with tile lines shifted `shift` mm into the later tile.
    public func tileIndex(at p: Vec2, shift: Double = 0) -> Int { row(ofY: p.y, shift: shift) * columns + column(ofX: p.x, shift: shift) }

    /// How far the material moves from tile `index - 1` to tile `index` (the frame's offset; the material itself moves
    /// the other way on the machine).
    public func move(to index: Int) -> Vec2 {
        guard index > 0, index < tiles.count else { return .zero }
        return tiles[index].offset - tiles[index - 1].offset
    }

    /// The stock every tile's file is written for: the job's, sized to the tile's frame, so its XY zero is at the same
    /// place on the frame for every tile.
    public func tileStock(_ stock: Stock) -> Stock {
        var s = stock
        s.width = pitch.x
        s.height = pitch.y
        return s
    }

    /// Distance from a point to the nearest tile line, mm (infinity with none).
    public func distanceToSeam(_ p: Vec2) -> Double {
        let dx = seamsX.map { abs(p.x - $0) }.min() ?? .infinity
        let dy = seamsY.map { abs(p.y - $0) }.min() ?? .infinity
        return min(dx, dy)
    }
}

/// Where a feed-through job's registration holes go.
public struct RegistrationLayout: Hashable, Sendable {
    public var radius: Double
    public var depth: Double
    /// The spoilboard holes, in tile coordinates: fixed on the machine, so the same for every tile.
    public var spoilboard: [Vec2]
    /// How far the material moves between tiles, as a tile-coordinate vector (the pitch along the feed).
    public var step: Vec2
    /// The holes each tile drills, in its own coordinates: tile 1 the spoilboard holes and the first pair through the
    /// material, every other tile but the last the next pair, one pitch on from the spoilboard holes.
    public var drilled: [[Vec2]]
    /// Where the dowels stand while each tile cuts, in its coordinates (none in tile 1).
    public var dowels: [[Vec2]]

    init(_ project: Project, tiles: [TileLayout.Tile], mode: TilingSettings.Mode, pitch: Vec2) {
        let holes = project.tiling?.registration ?? RegistrationHoles()
        let stock = project.stock
        radius = holes.radius
        depth = stock.thickness + max(0, holes.spoilboardDepth)
        // Just in front of the tile's leading edge, in from each side by the edge offset.
        let lead = -(holes.radius + RegistrationHoles.edgeGap)
        let fixed: [Vec2], step: Vec2
        if mode == .feedThroughX {
            fixed = [Vec2(lead, holes.edgeOffset), Vec2(lead, stock.height - holes.edgeOffset)]
            step = Vec2(pitch.x, 0)
        } else {
            fixed = [Vec2(holes.edgeOffset, lead), Vec2(stock.width - holes.edgeOffset, lead)]
            step = Vec2(0, pitch.y)
        }
        let next = fixed.map { $0 + step }
        let last = tiles.count - 1
        spoilboard = fixed
        self.step = step
        drilled = tiles.map { t in t.index == 0 ? fixed + (last > 0 ? next : []) : (t.index < last ? next : []) }
        dowels = tiles.map { $0.index == 0 ? [] : fixed }
    }

    /// The holes through the material, in job coordinates, with the index of the tile that drills each. Tile 1's
    /// spoilboard holes are included when any of them lands on the material.
    public func materialHoles(_ tiles: [TileLayout.Tile], stock: Stock) -> [(point: Vec2, tile: Int)] {
        var out: [(Vec2, Int)] = []
        for t in tiles {
            for p in drilled[t.index] {
                let q = p + t.offset
                if stock.bounds.insetBy(-radius).contains(q) { out.append((q, t.index)) }
            }
        }
        return out
    }
}
