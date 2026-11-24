import Dispatch
import Foundation

/// True-shape nesting: arranges parts on a sheet so they never overlap, keep a spacing between them, stay a margin
/// inside the sheet's edges and keep clear of fixed obstacles (clamps, keep-outs, parts that stay where they are),
/// using as little of the sheet as it can.
///
/// The method is the one SVGnest (Jack Qiao, MIT licence, https://github.com/Jack000/SVGnest) and Deepnest
/// (https://github.com/deepnest-next/deepnest, MIT with a GPL-3 `deepnest.js`) describe:
/// - **No-fit polygons.** For a fixed part A and a moving part B, the no-fit polygon is A ⊕ (−B), the Minkowski sum
///   of A and B turned half a turn. B's reference point inside it means the two overlap, on its edge that they touch.
///   Grown by the gap the pair needs, it is everywhere B can't go. Each sum is the convolution of one outline with the
///   other's convex pieces (`Clipper.minkowskiSum(loops:convexPieces:)`, with Clipper2's triangulation and unions,
///   Boost licence), made once for each pair of different outlines and relative turn and shared by copies of a part.
/// - **Bottom-left fill.** Parts go on one at a time, in a given order and turn. Each goes at the corner of the free
///   region (the sheet's inner-fit rectangle less every no-fit polygon) that keeps all the parts so far packed toward
///   the sheet's start edge: the left for a sheet wider than it is tall, the bottom otherwise, so what's left over is
///   one strip across the sheet.
/// - **Search.** A genetic search over the order and the turns (order crossover, swap and turn mutations, the best
///   layout always kept), seeded with the largest-first order and the best turn for each part, until a time limit,
///   an evaluation count or a stop.
///
/// - **More sheets.** Each layout fills the sheets one after another, as Deepnest does: the parts in order on the first
///   sheet, those that didn't fit on the next, and so on up to the sheet limit. Fewer sheets win, then the shortest
///   last sheet.
/// - **Part in part.** A part's holes (`Part.holes`, through-cut openings) are taken out of its no-fit polygons where
///   another part fits inside one with its gap all round: the positions where the moving part lies inside the hole
///   shrunk by the gap, which is the hole eroded by the part (the complement of the sum of the moving part and a frame
///   round the hole).
///
/// No code is ported from SVGnest, Deepnest or libnest2d: this is a Swift implementation of the published method.
public enum Nesting {
    /// The turns a part may take, about its own centre.
    public enum Rotation: Hashable, Codable, Sendable {
        /// Parts keep the turn they have now.
        case none
        /// 0°, 90°, 180° and 270°.
        case quarterTurns
        /// `n` evenly spaced turns (360° / n apart), 1 to 72.
        case steps(Int)

        /// The allowed turns, degrees counter-clockwise from the part's turn now. Keeping the grain allows only the
        /// turns along it: 0° and 180° (when the steps include it).
        public func angles(keepGrain: Bool) -> [Double] {
            let n: Int
            switch self {
            case .none: n = 1
            case .quarterTurns: n = 4
            case let .steps(k): n = max(1, min(72, k))
            }
            // Keeping the grain: of n evenly spaced turns, 0° and (for an even n) 180°.
            let count = keepGrain ? (n % 2 == 0 ? 2 : 1) : n
            return (0..<count).map { 360 * Double($0) / Double(count) }
        }
    }

    public struct Settings: Hashable, Codable, Sendable {
        /// Least gap between two parts' outlines, and between a part and an obstacle, mm. A part whose toolpaths cut
        /// further than this outside its outline (`Part.reach`) keeps that far away instead.
        public var spacing: Double
        /// Least gap between a part's outline and the sheet's edges, mm.
        public var edgeMargin: Double
        public var rotation: Rotation
        /// Only turns along the grain (0° and 180°): the parts are drawn with the grain running the way it should.
        public var keepGrain: Bool
        /// How long the search may run, seconds. The first layout (largest parts first, each at its best turn) is
        /// always finished.
        public var timeLimit: Double
        /// Seed for the search's random choices: the same seed and evaluation count give the same layout.
        public var seed: UInt64
        /// Stop after this many layouts, whatever the time (tests use it for a repeatable result); nil = time only.
        public var maxEvaluations: Int?
        /// Layouts in each generation of the search.
        public var populationSize: Int
        /// Parts may sit in other parts' holes (`Part.holes`) where they fit with their gap all round.
        public var partInPart: Bool
        /// Most sheets the parts may use: those that don't fit on one go on the next. 1 = one sheet.
        public var maxSheets: Int
        /// Size of every sheet after the first (width, height), mm; nil = the same as the first.
        public var nextSheetSize: Vec2?

        public init(spacing: Double, edgeMargin: Double, rotation: Rotation = .quarterTurns, keepGrain: Bool = false,
                    timeLimit: Double = 5, seed: UInt64 = 1, maxEvaluations: Int? = nil, populationSize: Int = 10,
                    partInPart: Bool = true, maxSheets: Int = 1, nextSheetSize: Vec2? = nil) {
            self.spacing = spacing
            self.edgeMargin = edgeMargin
            self.rotation = rotation
            self.keepGrain = keepGrain
            self.timeLimit = timeLimit
            self.seed = seed
            self.maxEvaluations = maxEvaluations
            self.populationSize = populationSize
            self.partInPart = partInPart
            self.maxSheets = maxSheets
            self.nextSheetSize = nextSheetSize
        }

        public var angles: [Double] { rotation.angles(keepGrain: keepGrain) }

        /// Sheets the layout may use, at least one.
        public var sheetLimit: Int { max(1, maxSheets) }

        /// Sheet `index` (from 0): the first as given, every later one `nextSheetSize` from the same corner.
        public func sheet(_ index: Int, first: Rect2) -> Rect2 {
            guard index > 0, let size = nextSheetSize else { return first }
            return Rect2(min: first.min, max: first.min + size)
        }
    }

    /// One part to nest: closed outer outlines (design coordinates, where it is now) that move as one.
    public struct Part: Sendable {
        public var outlines: [Polyline]
        /// How far its toolpaths cut outside its outline, mm (cutter edge): no other part or obstacle may come closer.
        public var reach: Double
        /// Openings cut right through it that other parts may sit in (inside its outlines).
        public var holes: [Hole]
        /// Parts of the same group are cut by the same toolpaths, in the same order: a hole says which groups may go in it.
        public var group: Int

        public init(outlines: [Polyline], reach: Double = 0, holes: [Hole] = [], group: Int = 0) {
            self.outlines = outlines.filter { $0.isClosed && $0.count >= 3 }.map { $0.oriented(counterClockwise: true) }
            self.reach = reach
            self.holes = holes.filter { $0.outline.isClosed && $0.outline.count >= 3 && $0.outline.area > 1e-6 }
            self.group = group
        }

        /// Its outer outlines' area, mm².
        public var area: Double { Clipper.union(outlines).reduce(0) { $0 + $1.signedArea } }
        /// What's left of it once its holes are cut, mm²: the area it takes up on the sheet.
        public var materialArea: Double { max(0, area - holes.reduce(0) { $0 + $1.outline.area }) }
        public var bounds: Rect2 { outlines.bounds }
    }

    /// An opening right through a part, where another part may go (part in part).
    public struct Hole: Sendable {
        /// Its edge, design coordinates.
        public var outline: Polyline
        /// How far the part's own toolpaths cut into it from its edge, mm (to the cutter's edge): a part inside keeps at
        /// least that far from the edge.
        public var reach: Double
        /// The groups (`Part.group`) of parts that may go in it, because all their toolpaths run before the hole is cut
        /// free; nil = any part.
        public var accepts: Set<Int>?
        /// Where the first toolpath that cuts it free is in the run order, and whether that's a profile (which cuts
        /// the loops inside the hole before the hole): what `accepts` is worked out from (`NestJob`).
        public var freedAt: Int?
        public var freedByProfile = false

        public init(outline: Polyline, reach: Double, accepts: Set<Int>? = nil) {
            self.outline = outline.isClosed ? outline.oriented(counterClockwise: true) : outline
            self.reach = reach
            self.accepts = accepts
        }

        public func accepts(group: Int) -> Bool { accepts?.contains(group) ?? true }
    }

    /// Something fixed on the sheet that parts keep clear of: a clamp, a keep-out, a part that stays where it is.
    public struct Obstacle: Sendable {
        public var outlines: [Polyline]
        /// How far its own toolpaths cut outside it, mm (0 for a clamp).
        public var reach: Double
        /// The sheet it's on (from 0); nil = every sheet (a clamp holds each sheet the same way).
        public var sheet: Int?

        public init(outlines: [Polyline], reach: Double = 0, sheet: Int? = nil) {
            self.outlines = outlines.filter { $0.isClosed && $0.count >= 3 }.map { $0.oriented(counterClockwise: true) }
            self.reach = reach
            self.sheet = sheet
        }

        public func isOn(sheet k: Int) -> Bool { sheet == nil || sheet == k }
    }

    /// Where a part goes: turned `rotation` degrees counter-clockwise about `pivot` (the centre of its outlines'
    /// bounding box where it is now), then moved so the pivot lands on `position`, on sheet `sheet` (from 0; every
    /// sheet has its own coordinates, from its lower-left corner).
    public struct Placement: Hashable, Sendable {
        public var pivot: Vec2
        public var rotation: Double
        public var position: Vec2
        public var sheet: Int

        public init(pivot: Vec2, rotation: Double, position: Vec2, sheet: Int = 0) {
            self.pivot = pivot
            self.rotation = rotation
            self.position = position
            self.sheet = sheet
        }

        public var transform: Transform2D {
            Transform2D.translation(-pivot).then(.rotation(rotation.radians)).then(.translation(position))
        }

        public func apply(_ p: Vec2) -> Vec2 { transform.apply(p) }
        public func apply(_ outline: Polyline) -> Polyline { outline.transformed(transform) }
    }

    /// How a layout uses one sheet.
    public struct SheetUse: Sendable, Hashable {
        /// The sheet, and its region parts go in: the sheet less the edge margin.
        public var sheet: Rect2
        public var usable: Rect2
        /// True when parts are packed toward the sheet's left edge (a sheet wider than tall), false for the bottom.
        public var alongX: Bool
        /// Parts on it, and their area (less their holes), mm².
        public var partCount: Int
        public var placedArea: Double
        /// How far along the sheet the parts reach from its start edge (left or bottom), and the sheet's length that
        /// way, mm.
        public var usedLength: Double
        public var sheetLength: Double
        /// Placed area over the strip of the sheet the parts use (from its start edge to the farthest part, the
        /// sheet's full width across), and over the whole sheet, 0–1.
        public var utilization: Double
        public var sheetUtilization: Double
    }

    public struct Result: Sendable {
        /// One entry per part, in the order given: where it goes, or nil when it didn't fit.
        public var placements: [Placement?]
        /// Each sheet the layout uses, in order (at least one).
        public var sheets: [SheetUse]
        /// For each part, the part whose hole it sits in (nil when it isn't in one).
        public var insideOf: [Int?]
        /// The last sheet's region parts go in: the sheet less the edge margin.
        public var usable: Rect2
        /// True when parts are packed toward the last sheet's left edge (a sheet wider than tall), false for the bottom.
        public var alongX: Bool
        /// The parts' total area, and the area of those placed (outer outlines less holes), mm².
        public var totalArea: Double
        public var placedArea: Double
        /// How far along the last sheet the parts reach from its start edge (left or bottom), mm: what's left after it
        /// is the offcut.
        public var usedLength: Double
        /// The last sheet's length along the packing direction, mm.
        public var sheetLength: Double
        /// The last sheet's placed area over the strip of it the parts use (from its start edge to the farthest part,
        /// the sheet's full width across), 0–1.
        public var utilization: Double
        /// Placed area over the whole of every sheet used, 0–1.
        public var sheetUtilization: Double
        /// Layouts tried, and seconds spent.
        public var evaluations: Int
        public var elapsed: Double
        /// Lower is better: unplaced parts first, then fewer sheets, then how far along the last sheet the layout
        /// reaches.
        public var fitness: Double

        public var placedCount: Int { placements.count(where: { $0 != nil }) }
        public var unplaced: [Int] { placements.indices.filter { placements[$0] == nil } }
        public var sheetCount: Int { sheets.count }
        /// Parts sitting in another part's hole.
        public var inHoles: [Int] { insideOf.indices.filter { insideOf[$0] != nil } }
    }

    /// Nests `parts` on `sheet`, clear of `obstacles`. `progress` gets the best layout so far as the search improves it
    /// (from a background thread); `shouldStop` ends the search early, keeping the best layout found.
    public static func nest(_ parts: [Part], sheet: Rect2, obstacles: [Obstacle] = [], settings: Settings,
                            progress: (@Sendable (Result) -> Void)? = nil,
                            shouldStop: @escaping @Sendable () -> Bool = { false }) -> Result {
        let engine = Engine(parts: parts, sheet: sheet, obstacles: obstacles, settings: settings)
        return engine.search(progress: progress, shouldStop: shouldStop)
    }

    /// The least gap two things need: the spacing, or more where either one's toolpaths reach further.
    public static func gap(_ settings: Settings, _ reachA: Double, _ reachB: Double) -> Double {
        max(settings.spacing, reachA, reachB, 0)
    }

    /// The least gap a part needs from the edge of a hole it sits in: the spacing, or more where its own toolpaths or
    /// the hole's reach further.
    public static func holeGap(_ settings: Settings, _ partReach: Double, _ hole: Hole) -> Double {
        max(settings.spacing, partReach, hole.reach, 0)
    }

    /// For each placed part, the part whose hole it sits in (the smallest hole holding a point inside it), or nil.
    public static func insideOf(_ parts: [Part], placements: [Placement?]) -> [Int?] {
        var out = [Int?](repeating: nil, count: parts.count)
        let probes: [Vec2?] = parts.indices.map { i in
            guard let p = placements[i], let first = parts[i].outlines.first else { return nil }
            return (first.interiorPoint() ?? first.points.first).map(p.apply)
        }
        for i in parts.indices {
            guard let probe = probes[i], let sheet = placements[i]?.sheet else { continue }
            var best: (index: Int, area: Double)?
            for j in parts.indices where j != i && !parts[j].holes.isEmpty {
                guard let q = placements[j], q.sheet == sheet else { continue }
                for hole in parts[j].holes {
                    let h = q.apply(hole.outline)
                    guard h.bounds.contains(probe), h.contains(probe) else { continue }
                    if best == nil || hole.outline.area < best!.area { best = (j, hole.outline.area) }
                }
            }
            out[i] = best?.index
        }
        return out
    }

    /// Whether part `i` sits, through holes inside holes, in part `outer`.
    static func within(_ i: Int, _ outer: Int, _ inside: [Int?]) -> Bool {
        var k = inside[i], steps = 0
        while let j = k, steps < inside.count {
            if j == outer { return true }
            k = inside[j]
            steps += 1
        }
        return false
    }

    /// Checks a layout with the parts' exact outlines: each pair at least their gap apart (or a part well inside a
    /// hole of another, when part in part is on and the hole takes it), every part on a sheet within the limit and the
    /// edge margin inside it, and clear of every obstacle on its sheet. Returns what's wrong (empty when nothing is).
    /// `tolerance` (mm) allows for rounding.
    public static func violations(_ parts: [Part], placements: [Placement?], sheet: Rect2, obstacles: [Obstacle] = [],
                                  settings: Settings, tolerance: Double = 0.01) -> [String] {
        var problems: [String] = []
        let placed: [(index: Int, sheet: Int, outlines: [Polyline], bounds: Rect2)] = parts.indices.compactMap { i in
            guard let p = placements[i] else { return nil }
            let o = parts[i].outlines.map(p.apply)
            return (i, p.sheet, o, o.bounds)
        }
        for p in placed {
            guard p.sheet >= 0, p.sheet < settings.sheetLimit else {
                problems.append("Part \(p.index + 1) is on sheet \(p.sheet + 1), past the limit of \(settings.sheetLimit).")
                continue
            }
            let usable = settings.sheet(p.sheet, first: sheet).insetBy(settings.edgeMargin).insetBy(-tolerance)
            if !(usable.contains(p.bounds.min) && usable.contains(p.bounds.max)) {
                problems.append("Part \(p.index + 1) is closer than the edge margin to the sheet's edge.")
            }
        }
        func tooClose(_ a: [Polyline], _ boundsA: Rect2, _ b: [Polyline], _ boundsB: Rect2, gap: Double) -> Bool {
            let need = gap - tolerance
            guard boundsA.insetBy(-need).intersects(boundsB) else { return false }
            let grown = need > 0 ? Clipper.offset(a, delta: need, arcTolerance: 0.002) : a
            let overlap = Clipper.intersection(grown, b)
            return overlap.reduce(0) { $0 + abs($1.signedArea) } > 1e-6
        }
        let inside = settings.partInPart ? insideOf(parts, placements: placements) : [Int?](repeating: nil, count: parts.count)
        /// Part `inner` in a hole of part `outer`: inside the hole with its gap all round, and a part the hole takes.
        func holeProblem(_ inner: Int, in outer: Int) -> String? {
            guard let pi = placements[inner], let po = placements[outer] else { return nil }
            let outlines = parts[inner].outlines.map(pi.apply)
            guard let probe = outlines.first.flatMap({ $0.interiorPoint() ?? $0.points.first }),
                  let hole = parts[outer].holes.filter({ po.apply($0.outline).contains(probe) }).min(by: { $0.outline.area < $1.outline.area })
            else { return nil }
            if !hole.accepts(group: parts[inner].group) {
                return "Part \(inner + 1) sits in a hole of part \(outer + 1) that's cut free before part \(inner + 1) is."
            }
            let need = holeGap(settings, parts[inner].reach, hole) - tolerance
            let grown = need > 0 ? Clipper.offset(outlines, delta: need, arcTolerance: 0.002) : outlines
            let outside = Clipper.difference(grown, minus: [po.apply(hole.outline)]).reduce(0) { $0 + abs($1.signedArea) }
            return outside > 1e-6 ? "Part \(inner + 1) is closer than its gap to the edge of part \(outer + 1)'s hole." : nil
        }
        for x in placed.indices {
            for y in placed.indices where y > x && placed[x].sheet == placed[y].sheet {
                let a = placed[x], b = placed[y]
                if inside[b.index] == a.index || inside[a.index] == b.index {
                    let (inner, outer) = inside[b.index] == a.index ? (b.index, a.index) : (a.index, b.index)
                    if let problem = holeProblem(inner, in: outer) { problems.append(problem) }
                    continue
                }
                // In a hole of a part that's itself in the other's hole: the checks along the way cover it.
                if within(b.index, a.index, inside) || within(a.index, b.index, inside) { continue }
                // Both in the same hole, or not in holes at all: an ordinary pair.
                if tooClose(a.outlines, a.bounds, b.outlines, b.bounds, gap: gap(settings, parts[a.index].reach, parts[b.index].reach)) {
                    problems.append("Parts \(a.index + 1) and \(b.index + 1) are closer than their gap.")
                }
            }
            for (k, o) in obstacles.enumerated() where o.isOn(sheet: placed[x].sheet) {
                let a = placed[x]
                if tooClose(a.outlines, a.bounds, o.outlines, o.outlines.bounds, gap: gap(settings, parts[a.index].reach, o.reach)) {
                    problems.append("Part \(a.index + 1) is closer than its gap to obstacle \(k + 1).")
                }
            }
        }
        return problems
    }
}

// MARK: - Engine

extension Nesting {
    typealias IntPoint = Clipper.IntPoint
    typealias IntPath = Clipper.IntPath

    /// The outlines no-fit polygons are made from are simplified to this, then grown by it so they still hold the
    /// exact outline, mm.
    static let simplifyTolerance = 0.05
    /// Round corners of grown no-fit polygons are this close to true arcs (and grown this much more), mm.
    static let arcTolerance = 0.02
    /// Outlines with more points than this are simplified harder (up to `maxSimplify`).
    static let vertexBudget = 100
    static let maxSimplify = 0.5

    struct Spot: Sendable {
        var part: Int
        var angle: Int
        var position: IntPoint
        var sheet: Int
    }

    struct Layout: Sendable {
        var spots: [Spot]
        var fitness: Double
        var placedArea: Double
        /// What the parts cover on each sheet filled, in order (empty where none went).
        var extents: [Rect2]
    }

    struct Individual: Sendable {
        var order: [Int]
        var genes: [Int]
        var layout: Layout?
    }

    struct PairKey: Hashable, Sendable {
        var fixed: Int
        var moving: Int
        var angle: Int
        var obstacle: Bool
    }

    final class Cache: @unchecked Sendable {
        private var values: [PairKey: [IntPath]] = [:]
        private let lock = NSLock()

        func value(_ key: PairKey, make: () -> [IntPath]) -> [IntPath] {
            lock.lock()
            if let v = values[key] {
                lock.unlock()
                return v
            }
            lock.unlock()
            let v = make()
            lock.lock()
            values[key] = v
            lock.unlock()
            return v
        }
    }

    /// A hole as the engine keeps it: its edge about the part's pivot (at the part's turn 0), its reach and the groups
    /// it takes.
    struct LocalHole: Sendable {
        var loop: Polyline
        var reach: Double
        var accepts: Set<Int>?
    }

    final class Engine: @unchecked Sendable {
        let settings: Settings
        let sheet: Rect2
        /// Every sheet the parts may go on, its usable region and which way it packs.
        let sheets: [Rect2]
        let usables: [Rect2]
        let alongXs: [Bool]
        let angleCount: Int
        let parts: [Part]
        /// Per part: the centre it turns about, its area (less its holes) and its geometry (shared by identical parts).
        let pivots: [Vec2]
        let areas: [Double]
        let keys: [Int]
        /// Per geometry: reach, exact bounds at each turn, and the simplified outline at each turn as loops and as
        /// convex pieces (local, about the pivot); the holes other parts may go in and the group it belongs to.
        let reach: [Double]
        let bounds: [[Rect2]]
        let loops: [[[[Vec2]]]]
        let pieces: [[[[Vec2]]]]
        let holes: [[LocalHole]]
        let groups: [Int]
        let obstacleLoops: [[[Vec2]]]
        let obstaclePieces: [[[Vec2]]]
        let obstacleReach: [Double]
        let obstacleSheets: [Int?]
        let totalArea: Double
        let cache = Cache()

        init(parts: [Part], sheet: Rect2, obstacles: [Obstacle], settings: Settings) {
            self.settings = settings
            self.sheet = sheet
            self.parts = parts
            sheets = (0..<settings.sheetLimit).map { settings.sheet($0, first: sheet) }
            usables = sheets.map { $0.insetBy(settings.edgeMargin) }
            alongXs = usables.map { $0.width >= $0.height }
            let angles = settings.angles
            angleCount = angles.count
            var pivots: [Vec2] = [], areas: [Double] = [], keys: [Int] = []
            var reach: [Double] = [], bounds: [[Rect2]] = [], loops: [[[[Vec2]]]] = [], pieces: [[[[Vec2]]]] = []
            var holes: [[LocalHole]] = [], groups: [Int] = []
            var seen: [[Int64]: Int] = [:]
            for part in parts {
                // On Clipper's grid, so copies of a part (their outlines snapped to it) have identical local outlines.
                let c = part.bounds.isEmpty ? Vec2.zero : part.bounds.center
                let pivot = Vec2((c.x * Clipper.scale).rounded() / Clipper.scale, (c.y * Clipper.scale).rounded() / Clipper.scale)
                let local = part.outlines.map { $0.transformed(.translation(-pivot)) }
                let usableHoles = settings.partInPart ? part.holes : []
                let localHoles = usableHoles.map { LocalHole(loop: $0.outline.transformed(.translation(-pivot)), reach: $0.reach, accepts: $0.accepts) }
                pivots.append(pivot)
                areas.append(settings.partInPart ? part.materialArea : part.area)
                // Identical outlines (copies of one part) share their no-fit polygons.
                var signature: [Int64] = [Int64((part.reach * 1000).rounded())]
                for loop in local {
                    signature.append(Int64(loop.count))
                    for p in loop.points { signature += [Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded())] }
                }
                if settings.partInPart {
                    signature += [-1, Int64(part.group)]
                    for hole in localHoles {
                        signature += [-2, Int64((hole.reach * 1000).rounded()), Int64(hole.loop.count)]
                        signature += (hole.accepts.map { $0.sorted().map(Int64.init) } ?? [-3])
                        for p in hole.loop.points { signature += [Int64((p.x * 1e4).rounded()), Int64((p.y * 1e4).rounded())] }
                    }
                }
                if let k = seen[signature] {
                    keys.append(k)
                    continue
                }
                let k = reach.count
                seen[signature] = k
                keys.append(k)
                reach.append(part.reach)
                holes.append(localHoles)
                groups.append(part.group)
                let outline = Engine.conservative(local)
                let baseLoops = outline.map { $0.oriented(counterClockwise: true).deduplicated().points }
                let basePieces = Engine.pieces(outline)
                bounds.append(angles.map { a in local.map { $0.transformed(.rotation(a.radians)) }.bounds })
                loops.append(angles.map { a in baseLoops.map { Engine.rotated($0, degrees: a) } })
                pieces.append(angles.map { a in basePieces.map { Engine.rotated($0, degrees: a) } })
            }
            self.pivots = pivots
            self.areas = areas
            self.keys = keys
            self.reach = reach
            self.bounds = bounds
            self.loops = loops
            self.pieces = pieces
            self.holes = holes
            self.groups = groups
            let obstacleOutlines = obstacles.map { Engine.conservative($0.outlines) }
            obstacleLoops = obstacleOutlines.map { $0.map { $0.oriented(counterClockwise: true).deduplicated().points } }
            obstaclePieces = obstacleOutlines.map { Engine.pieces($0) }
            obstacleReach = obstacles.map(\.reach)
            obstacleSheets = obstacles.map(\.sheet)
            totalArea = areas.reduce(0, +)
        }

        /// A polygon set holding `loops` exactly and at most `2 × tolerance` bigger: simplified (every dropped point
        /// within the tolerance of the simplified edge), then grown by the tolerance with mitred corners (which hold
        /// the round growth). Simplified harder until it fits the vertex budget.
        /// If simplifying ever leaves part of the exact outline outside (a sliver folded over), the exact outline is
        /// used instead.
        static func conservative(_ loops: [Polyline]) -> [Polyline] {
            let exact = Clipper.union(loops).filter { $0.signedArea > 0 }
            var tolerance = simplifyTolerance
            while true {
                let reduced = loops.map { $0.simplified(tolerance: tolerance) }.filter { $0.count >= 3 }
                // Nothing to drop (a rectangle, a polygon): the exact outline it is.
                if reduced.count == loops.count && zip(reduced, loops).allSatisfy({ $0.count == $1.count }) && loops.reduce(0, { $0 + $1.count }) <= vertexBudget {
                    return exact
                }
                // Non-zero first, so a loop simplification folded over still counts all of its area.
                let simplified = Clipper.union(reduced, fill: .nonZero)
                let grown = Clipper.offset(simplified, delta: tolerance + 1e-4, join: .miter, miterLimit: 4)
                let outer = Clipper.union(grown).filter { $0.signedArea > 0 }
                let count = outer.reduce(0) { $0 + $1.count }
                if count <= vertexBudget || tolerance >= maxSimplify {
                    let outside = Clipper.difference(exact, minus: outer).reduce(0) { $0 + abs($1.signedArea) }
                    return outer.isEmpty || outside > 1e-6 ? exact : outer
                }
                tolerance = min(maxSimplify, tolerance * 2)
            }
        }

        /// A polygon set inside the hole `loop` and at least `inset` in from its edge everywhere: simplified, then
        /// shrunk by the inset and the simplification's tolerance (with round joins, slack for whose chords is in
        /// `inset`). Simplified harder until it fits the vertex budget.
        static func conservativeHole(_ loop: Polyline, inset: Double) -> [Polyline] {
            var tolerance = simplifyTolerance
            while true {
                let reduced = loop.count > 4 ? loop.simplified(tolerance: tolerance) : loop
                if reduced.count <= vertexBudget || tolerance >= maxSimplify {
                    let shrunk = Clipper.offset([reduced.count >= 3 ? reduced : loop], delta: -(inset + tolerance + 1e-4),
                                                join: .round, arcTolerance: arcTolerance)
                    return Clipper.union(shrunk).filter { $0.signedArea > 0 }
                }
                tolerance = min(maxSimplify, tolerance * 2)
            }
        }

        /// Convex pieces of an outline (`Clipper.convexPieces`); an outline that can't be split (it never should) is
        /// covered by its convex hull instead, which is bigger but safe.
        static func pieces(_ outline: [Polyline]) -> [[Vec2]] {
            if let p = Clipper.convexPieces(outline), !p.isEmpty { return p }
            return Clipper.strictlyConvex(convexHull(outline.flatMap(\.points))).map { [$0] } ?? []
        }

        /// Counter-clockwise convex hull (monotone chain).
        static func convexHull(_ points: [Vec2]) -> [Vec2] {
            let p = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
            guard p.count > 2 else { return p }
            var lower: [Vec2] = [], upper: [Vec2] = []
            for q in p {
                while lower.count >= 2 && (lower[lower.count - 1] - lower[lower.count - 2]).cross(q - lower[lower.count - 1]) <= 0 { lower.removeLast() }
                lower.append(q)
            }
            for q in p.reversed() {
                while upper.count >= 2 && (upper[upper.count - 1] - upper[upper.count - 2]).cross(q - upper[upper.count - 1]) <= 0 { upper.removeLast() }
                upper.append(q)
            }
            return Array(lower.dropLast() + upper.dropLast())
        }

        /// A piece turned about the origin: exactly, for quarter turns.
        static func rotated(_ piece: [Vec2], degrees: Double) -> [Vec2] {
            let quarter = (degrees / 90).rounded()
            if abs(degrees - quarter * 90) < 1e-9 {
                let q = ((Int(quarter) % 4) + 4) % 4
                return piece.map { v in
                    switch q {
                    case 1: Vec2(-v.y, v.x)
                    case 2: Vec2(-v.x, -v.y)
                    case 3: Vec2(v.y, -v.x)
                    default: v
                    }
                }
            }
            let t = Transform2D.rotation(degrees.radians)
            return piece.map(t.apply)
        }

        func degrees(_ k: Int) -> Double { 360 * Double(k) / Double(angleCount) }

        /// The gap a pair of geometries (or a geometry and an obstacle) needs, with the slack for round corners.
        func pairGap(_ a: Double, _ b: Double) -> Double { Nesting.gap(settings, a, b) + Nesting.arcTolerance }

        /// No-fit polygon of geometry `moving` at turn `angle` round geometry `fixed` at turn 0, grown by their gap,
        /// less where `moving` fits in one of `fixed`'s holes.
        func nfp(fixed: Int, moving: Int, angle: Int) -> [IntPath] {
            cache.value(PairKey(fixed: fixed, moving: moving, angle: angle, obstacle: false)) {
                let outer = Engine.grownSum((loops[fixed][0], pieces[fixed][0]), (loops[moving][angle], pieces[moving][angle]),
                                            gap: pairGap(reach[fixed], reach[moving]))
                let free = holes[fixed].filter { $0.accepts?.contains(groups[moving]) ?? true }
                    .flatMap { holeRoom($0, moving: moving, angle: angle) }
                guard !free.isEmpty else { return outer }
                var paths = Clipper.booleanInt(.difference, fill: .nonZero, subjects: outer, openSubjects: [], clips: free).closed
                if Clipper.intArea(paths) < 0 { paths = paths.map { $0.reversed() } }
                return paths
            }
        }

        /// Where geometry `moving` at turn `angle` may put its pivot inside `hole` (local to the fixed part at turn 0)
        /// with its gap from the hole's edge all round: the hole, shrunk by the gap, eroded by the part. That's
        /// everywhere a frame round the shrunk hole, summed with the part turned half a turn, doesn't reach.
        func holeRoom(_ hole: LocalHole, moving: Int, angle: Int) -> [IntPath] {
            let b = bounds[moving][angle]
            // Quick rejections: a part bigger than the hole either way, or with more area.
            let hb = hole.loop.bounds
            guard b.width < hb.width, b.height < hb.height, areaOf(moving) < hole.loop.area else { return [] }
            let gap = Nesting.holeGap(settings, reach[moving], Hole(outline: hole.loop, reach: hole.reach)) + Nesting.arcTolerance
            let room = Engine.conservativeHole(hole.loop, inset: gap)
            guard !room.isEmpty else { return [] }
            // The part's (conservative) outline at this turn, and its box: the pivot has to keep the box in the room's.
            let partLoops = loops[moving][angle]
            let pb = partLoops.flatMap { $0 }.reduce(Rect2.empty) { $0.union($1) }
            let rb = room.bounds
            let lo = rb.min - pb.min, hi = rb.max - pb.max
            guard hi.x > lo.x, hi.y > lo.y else { return [] }
            // A frame big enough that a part with its pivot in [lo, hi] and not wholly in the room crosses it.
            let pad = pb.size + Vec2(1, 1)
            let outer = Rect2(min: rb.min - pad, max: rb.max + pad)
            let frame = [Engine.rectangle(outer)] + room.map { $0.oriented(counterClockwise: false) }
            guard let framePieces = Clipper.convexPieces(frame), !framePieces.isEmpty else { return [] }
            let reflected = partLoops.map { $0.map { -$0 } }
            let reach = Clipper.minkowskiSum(loops: reflected, convexPieces: framePieces)
            let free = Clipper.difference([Engine.rectangle(Rect2(min: lo, max: hi))], minus: reach)
                .filter { $0.signedArea > 1e-9 }
            return free.map(Clipper.toInt)
        }

        /// The (material) area of a geometry: that of the first part using it.
        func areaOf(_ key: Int) -> Double { areas[keys.firstIndex(of: key) ?? 0] }

        static func rectangle(_ r: Rect2) -> Polyline {
            Polyline([r.min, Vec2(r.max.x, r.min.y), r.max, Vec2(r.min.x, r.max.y)], closed: true)
        }

        func obstacleNFP(_ o: Int, moving: Int, angle: Int) -> [IntPath] {
            cache.value(PairKey(fixed: o, moving: moving, angle: angle, obstacle: true)) {
                Engine.grownSum((obstacleLoops[o], obstaclePieces[o]), (loops[moving][angle], pieces[moving][angle]),
                                gap: pairGap(obstacleReach[o], reach[moving]))
            }
        }

        /// No-fit polygon: the fixed outline summed with the moving one turned half a turn (whichever has fewer convex
        /// pieces split into them, the other convolved with each), grown by the gap.
        static func grownSum(_ fixed: (loops: [[Vec2]], pieces: [[Vec2]]), _ moving: (loops: [[Vec2]], pieces: [[Vec2]]),
                             gap: Double) -> [IntPath] {
            let reflected = (loops: moving.loops.map { $0.map { -$0 } }, pieces: moving.pieces.map { $0.map { -$0 } })
            let merged = reflected.pieces.count <= fixed.pieces.count
                ? Clipper.minkowskiSum(loops: fixed.loops, convexPieces: reflected.pieces)
                : Clipper.minkowskiSum(loops: reflected.loops, convexPieces: fixed.pieces)
            let grown = Clipper.offset(merged, delta: gap, join: .round, arcTolerance: arcTolerance)
            var paths = grown.map(Clipper.toInt)
            // Outer loops positive, holes negative (the non-zero fill of the forbidden region relies on it).
            if Clipper.intArea(paths) < 0 { paths = paths.map { $0.reversed() } }
            return paths
        }

        static func rotate(_ path: IntPath, degrees: Double) -> IntPath {
            let quarter = (degrees / 90).rounded()
            if abs(degrees - quarter * 90) < 1e-9 {
                switch ((Int(quarter) % 4) + 4) % 4 {
                case 1: return path.map { IntPoint(x: -$0.y, y: $0.x) }
                case 2: return path.map { IntPoint(x: -$0.x, y: -$0.y) }
                case 3: return path.map { IntPoint(x: $0.y, y: -$0.x) }
                default: return path
                }
            }
            let c = cos(degrees.radians), s = sin(degrees.radians)
            return path.map { p in
                let x = Double(p.x), y = Double(p.y)
                return IntPoint(x: Int64((x * c - y * s).rounded()), y: Int64((x * s + y * c).rounded()))
            }
        }

        /// Where part `i` at turn `k` may put its pivot inside sheet `sheet`'s usable region (in Clipper units), widened
        /// by one unit so a part exactly the sheet's size still has a place; nil when it doesn't fit.
        func innerFit(_ i: Int, _ k: Int, sheet: Int) -> IntPath? {
            let b = bounds[keys[i]][k]
            let usable = usables[sheet]
            let s = Clipper.scale
            let x0 = Int64(((usable.min.x - b.min.x) * s).rounded(.up)), x1 = Int64(((usable.max.x - b.max.x) * s).rounded(.down))
            let y0 = Int64(((usable.min.y - b.min.y) * s).rounded(.up)), y1 = Int64(((usable.max.y - b.max.y) * s).rounded(.down))
            guard x1 >= x0 - 1, y1 >= y0 - 1 else { return nil }
            return [IntPoint(x: x0 - 1, y: y0 - 1), IntPoint(x: x1 + 1, y: y0 - 1), IntPoint(x: x1 + 1, y: y1 + 1), IntPoint(x: x0 - 1, y: y1 + 1)]
        }

        /// Lays parts out in `order`, each at its gene's turn (or, with `tryAllTurns`, the turn that packs best), on the
        /// first sheet; those that don't fit go on the next sheet in the same order, and so on. A part that doesn't fit
        /// at its gene's turn tries the others.
        func place(order: [Int], genes: [Int], tryAllTurns: Bool) -> Layout {
            var spots: [Spot] = []
            var extents: [Rect2] = []
            var placedArea = 0.0
            var remaining = order
            for sheet in sheets.indices where !remaining.isEmpty {
                var left: [Int] = []
                let first = spots.count
                var extent = Rect2.empty
                for i in remaining {
                    guard let spot = placeOne(i, gene: genes[i], tryAllTurns: tryAllTurns, sheet: sheet,
                                              on: spots[first...], extent: extent) else {
                        left.append(i)
                        continue
                    }
                    spots.append(spot)
                    let b = bounds[keys[i]][spot.angle]
                    let at = Vec2(Double(spot.position.x) / Clipper.scale, Double(spot.position.y) / Clipper.scale)
                    extent = extent.union(Rect2(min: b.min + at, max: b.max + at))
                    placedArea += areas[i]
                }
                // A sheet after the first that takes none of what's left: the next one, the same, wouldn't either.
                if sheet > 0 && spots.count == first { break }
                extents.append(extent)
                remaining = left
            }
            return Layout(spots: spots, fitness: fitness(spots: spots, placedArea: placedArea, extents: extents),
                          placedArea: placedArea, extents: extents)
        }

        /// Where part `i` goes on `sheet`, next to the parts already there, or nil when there's no room.
        func placeOne(_ i: Int, gene: Int, tryAllTurns: Bool, sheet: Int, on spots: ArraySlice<Spot>, extent: Rect2) -> Spot? {
            let key = keys[i]
            let turns = [gene] + (0..<angleCount).filter { $0 != gene }
            let s = Clipper.scale
            var best: (score: Double, tie: Double, k: Int, at: IntPoint)?
            for k in turns {
                guard let fit = innerFit(i, k, sheet: sheet) else { continue }
                var forbidden: [IntPath] = []
                for spot in spots {
                    let rel = ((k - spot.angle) % angleCount + angleCount) % angleCount
                    let base = nfp(fixed: keys[spot.part], moving: key, angle: rel)
                    let turn = degrees(spot.angle)
                    for path in base {
                        let r = Engine.rotate(path, degrees: turn)
                        forbidden.append(r.map { IntPoint(x: $0.x + spot.position.x, y: $0.y + spot.position.y) })
                    }
                }
                for o in obstaclePieces.indices where obstacleSheets[o] == nil || obstacleSheets[o] == sheet {
                    forbidden += obstacleNFP(o, moving: key, angle: k)
                }
                let free = forbidden.isEmpty ? [fit]
                    : Clipper.booleanInt(.difference, fill: .nonZero, subjects: [fit], openSubjects: [], clips: forbidden).closed
                let b = bounds[key][k]
                for path in free {
                    for p in path {
                        let at = Vec2(Double(p.x) / s, Double(p.y) / s)
                        let e = extent.union(Rect2(min: b.min + at, max: b.max + at))
                        let (score, tie) = self.score(e, at, sheet: sheet)
                        if best == nil || score < best!.score - 1e-9 || (abs(score - best!.score) <= 1e-9 && tie < best!.tie) {
                            best = (score, tie, k, p)
                        }
                    }
                }
                if best != nil && !tryAllTurns { break }
            }
            return best.map { Spot(part: i, angle: $0.k, position: $0.at, sheet: sheet) }
        }

        /// How far along the sheet a layout reaches (weighted double) and how far across: lower packs tighter toward the
        /// start edge. The tie-break prefers the lower-left place.
        func score(_ extent: Rect2, _ at: Vec2, sheet: Int) -> (Double, Double) {
            let usable = usables[sheet], alongX = alongXs[sheet]
            let along = alongX ? extent.max.x - usable.min.x : extent.max.y - usable.min.y
            let across = alongX ? extent.max.y - usable.min.y : extent.max.x - usable.min.x
            let tie = alongX ? at.x * 1e6 + at.y : at.y * 1e6 + at.x
            return (2 * along + across, tie)
        }

        func fitness(spots: [Spot], placedArea: Double, extents: [Rect2]) -> Double {
            let unplaced = parts.count - spots.count
            let missing = totalArea > 0 ? (totalArea - placedArea) / totalArea : 0
            guard let last = extents.lastIndex(where: { !$0.isEmpty }) else { return 3 * Double(unplaced) + 1000 * missing + 3 }
            let extent = extents[last], usable = usables[last], alongX = alongXs[last]
            let lengthAlong = max(alongX ? usable.width : usable.height, 1e-9)
            let lengthAcross = max(alongX ? usable.height : usable.width, 1e-9)
            let along = (alongX ? extent.max.x - usable.min.x : extent.max.y - usable.min.y) / lengthAlong
            let across = (alongX ? extent.max.y - usable.min.y : extent.max.x - usable.min.x) / lengthAcross
            // An unplaced part costs more than any difference in length (each term ≤ 1), so more parts always win; then
            // each sheet more than the whole length of the last one.
            return 3 * Double(unplaced) + 1000 * missing + 4 * Double(last) + 2 * along + across
        }

        func result(_ layout: Layout, evaluations: Int, elapsed: Double) -> Result {
            var placements = [Placement?](repeating: nil, count: parts.count)
            let s = Clipper.scale
            for spot in layout.spots {
                placements[spot.part] = Placement(pivot: pivots[spot.part], rotation: degrees(spot.angle),
                                                  position: Vec2(Double(spot.position.x) / s, Double(spot.position.y) / s),
                                                  sheet: spot.sheet)
            }
            // Every sheet up to the last with parts on it (the first even when it has none).
            let used = max(1, (layout.extents.lastIndex(where: { !$0.isEmpty }) ?? 0) + 1)
            let uses: [SheetUse] = (0..<used).map { k in
                let sheet = sheets[k], alongX = alongXs[k]
                let extent = k < layout.extents.count ? layout.extents[k] : .empty
                let on = layout.spots.filter { $0.sheet == k }
                let area = on.reduce(0) { $0 + areas[$1.part] }
                let length = alongX ? sheet.width : sheet.height
                let across = alongX ? sheet.height : sheet.width
                let reach = extent.isEmpty ? 0 : (alongX ? extent.max.x - sheet.min.x : extent.max.y - sheet.min.y)
                return SheetUse(sheet: sheet, usable: usables[k], alongX: alongX, partCount: on.count, placedArea: area,
                                usedLength: reach, sheetLength: length,
                                utilization: reach > 0 ? min(1, area / (reach * across)) : 0,
                                sheetUtilization: area / max(sheet.width * sheet.height, 1e-9))
            }
            let last = uses[uses.count - 1]
            let totalSheet = uses.reduce(0) { $0 + $1.sheet.width * $1.sheet.height }
            return Result(placements: placements, sheets: uses,
                          insideOf: settings.partInPart ? Nesting.insideOf(parts, placements: placements) : [Int?](repeating: nil, count: parts.count),
                          usable: last.usable, alongX: last.alongX, totalArea: totalArea,
                          placedArea: layout.placedArea, usedLength: last.usedLength, sheetLength: last.sheetLength,
                          utilization: last.utilization, sheetUtilization: layout.placedArea / max(totalSheet, 1e-9),
                          evaluations: evaluations, elapsed: elapsed, fitness: layout.fitness)
        }

        // MARK: Search

        func search(progress: (@Sendable (Result) -> Void)?, shouldStop: @Sendable () -> Bool) -> Result {
            let started = DispatchTime.now().uptimeNanoseconds
            func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 }
            var rng = SplitMix64(seed: settings.seed)
            // Largest first, each at the turn that packs best.
            let byArea = parts.indices.sorted { areas[$0] > areas[$1] || (areas[$0] == areas[$1] && $0 < $1) }
            warmUp()
            let seedLayout = place(order: byArea, genes: [Int](repeating: 0, count: parts.count), tryAllTurns: true)
            var seedGenes = [Int](repeating: 0, count: parts.count)
            for spot in seedLayout.spots { seedGenes[spot.part] = spot.angle }
            var best = seedLayout
            var evaluations = 1
            progress?(result(best, evaluations: evaluations, elapsed: elapsed()))
            // One part: the first layout already tried every turn.
            let canSearch = parts.count > 1
            func done() -> Bool {
                if !canSearch || shouldStop() { return true }
                if let m = settings.maxEvaluations { return evaluations >= m }
                return elapsed() >= settings.timeLimit
            }
            let size = max(2, settings.populationSize)
            var population = [Individual(order: byArea, genes: seedGenes, layout: seedLayout)]
            while population.count < size {
                population.append(mutate(population[0], rate: 0.3, rng: &rng))
            }
            while !done() {
                // Evaluate the new layouts in parallel; each one's result goes in its own slot, so the outcome doesn't
                // depend on which thread finishes first.
                // A `let`, so the parallel loop reads a value nothing can change under it.
                let unevaluated = population.indices.filter { population[$0].layout == nil }
                let pending = settings.maxEvaluations.map { Array(unevaluated.prefix(max(0, $0 - evaluations))) } ?? unevaluated
                if pending.isEmpty { break }
                let slots = Slots(count: pending.count)
                let snapshot = population
                DispatchQueue.concurrentPerform(iterations: pending.count) { n in
                    let ind = snapshot[pending[n]]
                    slots.set(n, place(order: ind.order, genes: ind.genes, tryAllTurns: false))
                }
                for (n, i) in pending.enumerated() { population[i].layout = slots.get(n) }
                evaluations += pending.count
                population = population.filter { $0.layout != nil }
                population.sort { $0.layout!.fitness < $1.layout!.fitness }
                if population[0].layout!.fitness < best.fitness - 1e-12 {
                    best = population[0].layout!
                    progress?(result(best, evaluations: evaluations, elapsed: elapsed()))
                }
                // Next generation: the best kept as it is, the rest children of fitter parents.
                var next = [population[0]]
                while next.count < size {
                    let a = pick(population, rng: &rng)
                    var b = pick(population, rng: &rng)
                    if population.count > 1 { while b == a { b = pick(population, rng: &rng) } }
                    let (c1, c2) = crossover(population[a], population[b], rng: &rng)
                    next.append(mutate(c1, rate: 0.1, rng: &rng))
                    if next.count < size { next.append(mutate(c2, rate: 0.1, rng: &rng)) }
                }
                population = next
            }
            let final = result(best, evaluations: evaluations, elapsed: elapsed())
            progress?(final)
            return final
        }

        /// Works out every no-fit polygon the first layout will need, on all cores, when there aren't too many (copies
        /// of a part share theirs). Otherwise they're made as layouts need them.
        func warmUp() {
            let geometries = reach.count
            var wanted: [PairKey] = []
            for a in 0..<geometries {
                for b in 0..<geometries {
                    for k in 0..<angleCount { wanted.append(PairKey(fixed: a, moving: b, angle: k, obstacle: false)) }
                }
            }
            for o in obstaclePieces.indices {
                for b in 0..<geometries {
                    for k in 0..<angleCount { wanted.append(PairKey(fixed: o, moving: b, angle: k, obstacle: true)) }
                }
            }
            // A `let`, so the parallel loop reads a value nothing can change under it.
            let keys = wanted
            guard keys.count > 1, keys.count <= 20_000 else { return }
            DispatchQueue.concurrentPerform(iterations: keys.count) { i in
                let key = keys[i]
                _ = key.obstacle ? obstacleNFP(key.fixed, moving: key.moving, angle: key.angle)
                    : nfp(fixed: key.fixed, moving: key.moving, angle: key.angle)
            }
        }

        /// A parent by rank: the fittest is most likely.
        func pick(_ population: [Individual], rng: inout SplitMix64) -> Int {
            let n = population.count
            let total = n * (n + 1) / 2
            var r = Int(rng.next() % UInt64(max(1, total)))
            for i in 0..<n {
                r -= n - i
                if r < 0 { return i }
            }
            return n - 1
        }

        /// Order crossover: the first parent's order up to a cut, then the second's for the rest; each part keeps the
        /// turn of the parent it came from.
        func crossover(_ a: Individual, _ b: Individual, rng: inout SplitMix64) -> (Individual, Individual) {
            let n = a.order.count
            guard n > 1 else { return (Individual(order: a.order, genes: b.genes), Individual(order: b.order, genes: a.genes)) }
            let cut = 1 + Int(rng.next() % UInt64(n - 1))
            func child(_ p: Individual, _ q: Individual) -> Individual {
                let head = Array(p.order[..<cut])
                let taken = Set(head)
                var genes = q.genes
                for i in head { genes[i] = p.genes[i] }
                return Individual(order: head + q.order.filter { !taken.contains($0) }, genes: genes)
            }
            return (child(a, b), child(b, a))
        }

        /// Swaps neighbouring parts (of different shapes: swapping copies changes nothing) and changes turns, each with
        /// probability `rate`; always changes something when it can.
        func mutate(_ ind: Individual, rate: Double, rng: inout SplitMix64) -> Individual {
            var order = ind.order
            var genes = ind.genes
            var changed = false
            let n = order.count
            func swapNext(_ i: Int) -> Bool {
                var j = i + 1
                while j < n && keys[order[j]] == keys[order[i]] { j += 1 }
                guard j < n else { return false }
                order.swapAt(i, j)
                return true
            }
            for i in 0..<max(0, n - 1) where rng.unit() < rate {
                changed = swapNext(i) || changed
            }
            if angleCount > 1 {
                for i in 0..<n where rng.unit() < rate {
                    genes[i] = Int(rng.next() % UInt64(angleCount))
                    changed = true
                }
            }
            if !changed {
                if angleCount > 1 && (n < 2 || rng.unit() < 0.5) {
                    let i = Int(rng.next() % UInt64(max(1, n)))
                    genes[i] = (genes[i] + 1 + Int(rng.next() % UInt64(angleCount - 1))) % angleCount
                } else if n > 1 {
                    _ = swapNext(Int(rng.next() % UInt64(n - 1)))
                }
            }
            return Individual(order: order, genes: genes)
        }
    }

    /// One result slot per layout evaluated in parallel.
    final class Slots: @unchecked Sendable {
        private var values: [Layout?]
        private let lock = NSLock()
        init(count: Int) { values = [Layout?](repeating: nil, count: count) }
        func set(_ i: Int, _ v: Layout) {
            lock.lock()
            values[i] = v
            lock.unlock()
        }

        func get(_ i: Int) -> Layout? {
            lock.lock()
            defer { lock.unlock() }
            return values[i]
        }
    }

    /// A small, fast, seedable random number generator (SplitMix64), so a seed always gives the same search.
    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
