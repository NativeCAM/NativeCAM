import Foundation
import Testing
@testable import CAMCore

/// Adaptive (constant-engagement) pocket clearing.
struct AdaptiveClearingTests {
    static var quarter: Tool { Fixture.endMill }
    static var eighth: Tool { Fixture.lib.tool(number: 2)! }
    static var half: Tool { RestMachiningTests.half }

    static func params(depth: Double = 12, direction: CutDirection = .climb, adaptive: AdaptiveSettings? = nil, clearance: Tool? = nil,
                       relief: CornerReliefSettings? = nil, strategy: PocketStrategy = .adaptive) -> PocketParams {
        PocketParams(strategy: strategy, direction: direction, depth: DepthSettings(cutDepth: depth), cornerRelief: relief,
                     clearanceTool: clearance, adaptive: adaptive)
    }

    static func pocket(_ shapes: [DesignShape], tool: Tool = quarter, _ p: PocketParams = params(), loadFeeds: Bool? = nil) -> CAMOperation {
        CAMOperation(name: "Pocket", kind: .pocket(p), shapeIDs: shapes.map(\.id), tool: tool, adjustFeedsForLoad: loadFeeds)
    }

    static func boundary(_ shapes: [DesignShape], tool: Tool, allowance: Double = 0) -> [Region] {
        let regions = Region.build(from: shapes.flatMap { $0.polylines(tolerance: 0.01) }.filter(\.isClosed), fill: .evenOdd)
        return regions.flatMap { $0.offset(by: -(tool.radius + allowance), arcTolerance: 0.005) }
    }

    static func plan(_ shapes: [DesignShape], tool: Tool = quarter, _ p: PocketParams = params()) -> AdaptiveClearing.Plan {
        let context = GenerationContext(stock: Fixture.stock, machine: .avidPRO6060)
        return AdaptiveClearing.plan(boundary: boundary(shapes, tool: tool, allowance: p.allowance), tool: tool, params: p,
                                     levels: p.passLevels(tool), context: context)
    }

    static func settings(_ tool: Tool = quarter, _ p: PocketParams = params()) -> AdaptiveClearing.Settings {
        AdaptiveClearing.Settings(tool: tool, params: p, machine: .avidPRO6060, arcTolerance: 0.005)
    }

    static func bounds(_ shapes: [DesignShape]) -> Rect2 {
        shapes.reduce(Rect2.empty) { $0.union($1.polylines(tolerance: 0.01).bounds) }
    }

    static let rectangle = Fixture.rect(60, 40, at: Vec2(100, 75))
    static let lShape = DesignShape(kind: .paths([Polyline([Vec2(40, 30), Vec2(160, 30), Vec2(160, 70), Vec2(90, 70), Vec2(90, 120),
                                                             Vec2(40, 120)], closed: true)]), position: .zero)
    static let islanded = [Fixture.rect(80, 60, at: Vec2(100, 75)), DesignShape(kind: .circle(radius: 10), position: Vec2(90, 70))]

    static func shapes(_ name: String) -> [DesignShape] {
        switch name {
        case "L": [lShape]
        case "island": islanded
        case "circle": [DesignShape(kind: .circle(radius: 30), position: Vec2(100, 75))]
        case "slot": [RestMachiningTests.slotted]
        default: [rectangle]
        }
    }

    // MARK: An independent measure of what each move cuts

    /// A fine bitmap of the material cut at one level, painted move by move with each move's swept capsule: a measure
    /// of the walk's load and links that shares nothing with its own polygon model.
    struct Raster {
        let origin: Vec2
        let cell: Double
        let w: Int, h: Int
        var cut: [Bool]

        init(bounds: Rect2, cell: Double) {
            origin = bounds.min
            self.cell = cell
            w = Int((bounds.width / cell).rounded(.up)) + 1
            h = Int((bounds.height / cell).rounded(.up)) + 1
            cut = [Bool](repeating: false, count: w * h)
        }

        /// Cuts every cell whose centre is within `r` of the segment a–b; returns the area newly cut.
        mutating func sweep(_ a: Vec2, _ b: Vec2, _ r: Double) -> Double {
            let lo = Int(((min(a.y, b.y) - r - origin.y) / cell).rounded(.down))
            let hi = Int(((max(a.y, b.y) + r - origin.y) / cell).rounded(.up))
            var count = 0
            for j in max(0, lo)...min(h - 1, hi) {
                let y = origin.y + (Double(j) + 0.5) * cell
                guard let iv = ClearedModel.capsule(a, b, r, y) else { continue }
                let i0 = max(0, Int(((iv.lo - origin.x) / cell - 0.5).rounded(.up)))
                let i1 = min(w - 1, Int(((iv.hi - origin.x) / cell - 0.5).rounded(.down)))
                guard i0 <= i1 else { continue }
                for i in i0...i1 where !cut[j * w + i] {
                    cut[j * w + i] = true
                    count += 1
                }
            }
            return Double(count) * cell * cell
        }
    }

    struct Replay {
        /// The load (area cut per mm over the optimal load's width) on windows of at least 1 mm, leaving out the
        /// first and last two bit radii of each pass (entries and run-outs).
        var loads: [(load: Double, length: Double)] = []
        /// The most any link cut, mm² per mm (over at least 1 mm).
        var linkCut = 0.0
        var links = 0
    }

    static func replay(_ level: AdaptiveClearing.Level, settings s: AdaptiveClearing.Settings, bounds: Rect2) -> Replay {
        var raster = Raster(bounds: bounds.insetBy(-2 * s.toolRadius), cell: 0.025)
        var out = Replay()
        for move in level.moves {
            switch move {
            case let .helix(c, rho, _, _):
                _ = raster.sweep(c, c + Vec2(1e-6, 0), rho + s.toolRadius)
            case let .ramp(p, q):
                _ = raster.sweep(p, q, s.toolRadius)
            case let .cut(pts, _):
                let total = zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                var along = 0.0, area = 0.0, length = 0.0
                for k in 1..<pts.count {
                    let d = pts[k - 1].distance(to: pts[k])
                    let a = raster.sweep(pts[k - 1], pts[k], s.toolRadius)
                    along += d
                    guard along > 2 * s.toolRadius, along < total - 2 * s.toolRadius else { continue }
                    area += a
                    length += d
                    if length >= 1 {
                        out.loads.append((area / length / s.load, length))
                        area = 0
                        length = 0
                    }
                }
            case let .link(pts, _):
                out.links += 1
                // Per mm, over at least a millimetre (so a link of a hair's length doesn't look like a cut).
                var area = 0.0, length = 0.0
                for k in 1..<pts.count {
                    area += raster.sweep(pts[k - 1], pts[k], s.toolRadius)
                    length += pts[k - 1].distance(to: pts[k])
                    if length >= 1 || k == pts.count - 1 {
                        out.linkCut = max(out.linkCut, area / max(length, 1))
                        area = 0
                        length = 0
                    }
                }
            case .lift:
                break
            }
        }
        return out
    }

    // MARK: The load

    /// Measured on a fine raster of its own, the walk's cuts hold the optimal load: nine-tenths of their length within
    /// 15% of it, and nothing over 1.4×, once in.
    @Test(arguments: ["rectangle", "L", "island"])
    func holdsTheLoadAlongItsCuts(_ name: String) throws {
        let shapes = Self.shapes(name)
        let level = try #require(Self.plan(shapes).levels.first)
        let replay = Self.replay(level, settings: Self.settings(), bounds: Self.bounds(shapes))
        let total = replay.loads.reduce(0) { $0 + $1.length }
        let inBand = replay.loads.filter { abs($0.load - 1) <= 0.15 }.reduce(0) { $0 + $1.length }
        let worst = replay.loads.map(\.load).max() ?? 0
        #expect(total > 1000)
        #expect(inBand >= 0.9 * total, "\(name): \(Int(100 * inBand / total))% of \(Int(total)) mm within 15% of the load")
        #expect(worst <= 1.4, "\(name): worst \(worst)")
    }

    /// The walk's own figures agree: most steps hold the load within its 5% tolerance (the rest are the ends of
    /// passes, running out of material), and none takes more than the overload it allows.
    @Test func stepsTakeTheOptimalLoad() throws {
        let level = try #require(Self.plan([Self.rectangle]).levels.first)
        let loads = level.moves.flatMap { m -> [Double] in
            if case let .cut(_, l) = m { return l }
            return []
        }
        #expect(loads.count > 500)
        let held = loads.filter { abs($0 - 1) <= AdaptiveClearing.loadTolerance + 1e-9 }.count
        #expect(Double(held) >= 0.85 * Double(loads.count), "\(held) of \(loads.count) steps")
        #expect(loads.allSatisfy { $0 <= AdaptiveClearing.overload + 1e-9 })
    }

    // MARK: The result

    /// Simulated, an adaptive pocket comes out the same as an offset one: nothing left standing (no islands of
    /// uncut material or slivers between passes), nothing cut past the walls or into the island.
    @Test(arguments: ["rectangle", "L", "island", "circle", "slot", "eighth", "conventional"])
    func clearsWhatAnOffsetPocketDoes(_ name: String) throws {
        let shapes = Self.shapes(name)
        let tool = name == "eighth" ? Self.eighth : Self.quarter
        let depth = name == "eighth" ? 10.0 : 12
        let direction: CutDirection = name == "conventional" ? .conventional : .climb
        func grid(_ strategy: PocketStrategy) -> HeightGrid {
            let op = Self.pocket(shapes, tool: tool, Self.params(depth: depth, direction: direction, strategy: strategy))
            let project = Fixture.project(shapes: shapes, ops: [op])
            let job = CAMEngine.generate(project)
            #expect(!job.hasErrors)
            return Fixture.simulate(job.toolpaths, stock: project.stock, cell: 0.25)
        }
        let adaptive = grid(.adaptive), offset = grid(.offset)
        var cut = 0, left = 0, over = 0
        for i in offset.heights.indices {
            let a = Double(adaptive.heights[i]), o = Double(offset.heights[i])
            if o < -depth + 0.01 { cut += 1 }
            if a > o + 0.05 { left += 1 }
            if a < o - 0.05 { over += 1 }
        }
        #expect(cut > 20_000)
        #expect(left == 0, "\(name): \(left) cells left standing")
        #expect(over == 0, "\(name): \(over) cells cut deeper")
    }

    /// The bit's centre only goes where the pocket lets it: never past the walls or into the island.
    @Test func staysInsideTheWallsAndOffTheIsland() throws {
        let job = CAMEngine.generate(Fixture.project(shapes: Self.islanded, ops: [Self.pocket(Self.islanded)]))
        let tp = try #require(job.toolpaths.first)
        let r = Self.quarter.radius
        let island = Vec2(90, 70)
        var cutting = 0, outside = 0
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell, m.end.z < -1e-6 else { return }
            cutting += 1
            for p in m.samples(from: s, maxStep: 0.5) {
                // (Round joins sit within the arc tolerance inside the island's offset circle.)
                let inWalls = abs(p.x - 100) <= 40 - r + 1e-3 && abs(p.y - 75) <= 30 - r + 1e-3
                if !inWalls || p.xy.distance(to: island) < 10 + r - 0.006 { outside += 1 }
            }
        }
        #expect(cutting > 1000)
        #expect(outside == 0)
    }

    // MARK: Links and loops

    /// Links stay down only through cleared area: measured on the raster, none cuts more than a whisker.
    @Test(arguments: ["rectangle", "L", "island"])
    func staysDownOnlyThroughClearedArea(_ name: String) throws {
        let shapes = Self.shapes(name)
        let level = try #require(Self.plan(shapes).levels.first)
        let s = Self.settings()
        let replay = Self.replay(level, settings: s, bounds: Self.bounds(shapes))
        #expect(replay.links > 20)
        // The walk lets a link graze at most a tenth of the load on either side.
        #expect(replay.linkCut <= 0.25 * s.load, "a link cut \(replay.linkCut) mm² per mm")
        let lifts = level.moves.filter { if case .lift = $0 { true } else { false } }.count
        #expect(lifts <= replay.links / 10, "\(lifts) lifts for \(replay.links) links")
    }

    /// Links turn on arcs no tighter than the minimum loop radius (or go straight), and cuts never turn toward the
    /// material tighter than it.
    @Test(arguments: [nil, 4.0, 10.0])
    func loopsRespectTheMinimumRadius(_ radius: Double?) throws {
        let p = Self.params(adaptive: AdaptiveSettings(minimumLoopRadius: radius))
        let s = Self.settings(Self.quarter, p)
        if let radius { #expect(s.loopRadius == radius) }
        let level = try #require(Self.plan([Self.lShape], p).levels.first)
        var arcs = 0, tight = 0, sharp = 0
        for move in level.moves {
            switch move {
            case let .link(pts, rho?):
                #expect(abs(rho - s.loopRadius) < 1e-9)
                arcs += 1
                for k in 2..<max(2, pts.count) {
                    let (a, b, c) = (pts[k - 2], pts[k - 1], pts[k])
                    let cross = abs((b - a).cross(c - b))
                    guard cross > 1e-9 else { continue }
                    if a.distance(to: b) * b.distance(to: c) * c.distance(to: a) / (2 * cross) < 0.99 * rho { tight += 1 }
                }
            case let .cut(pts, _):
                for k in 2..<max(2, pts.count) {
                    let d0 = pts[k - 1] - pts[k - 2], d1 = pts[k] - pts[k - 1]
                    let turn = atan2(d0.cross(d1), d0.dot(d1))
                    // Climbing keeps the material on the right: right turns (negative) are toward it.
                    if turn < 0 && -turn > d1.length / s.loopRadius + 1e-6 { sharp += 1 }
                }
            default:
                break
            }
        }
        #expect(arcs > 10)
        #expect(tight == 0)
        #expect(sharp == 0)
    }

    @Test func automaticLoopRadiusLetsTheFeedRunAtFullSpeed() {
        let machine = MachineProfile.avidPRO6060
        let tool = Self.quarter
        let r = AdaptiveSettings.automaticLoopRadius(tool: tool, feed: tool.cutting.feedRate, machine: machine)
        // 220 in/min at 50 in/s²: (3.667 in/s)² / 50 in/s² = 0.269 in.
        #expect(abs(r - 0.2689.inch) < 0.001.inch)
        let cap = AdaptiveSettings.loopFeedCap(radius: r, machine: machine)
        #expect(abs(cap - tool.cutting.feedRate) < 1)
        // Kept between a quarter of the diameter and twice it.
        let slow = AdaptiveSettings.automaticLoopRadius(tool: tool, feed: 10.inch, machine: machine)
        let fast = AdaptiveSettings.automaticLoopRadius(tool: tool, feed: 2000.inch, machine: machine)
        #expect(slow == 0.25 * tool.diameter)
        #expect(fast == 2 * tool.diameter)
    }

    /// A minimum loop radius tighter than the feed allows says what the loops will be held to.
    @Test func warnsWhenLoopsHoldTheFeedBack() {
        func messages(_ radius: Double?) -> [String] {
            let op = Self.pocket([Self.rectangle], Self.params(adaptive: AdaptiveSettings(minimumLoopRadius: radius)))
            return CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [op])).issues.map(\.message)
        }
        let tight = messages(2)
        let held = tight.filter { $0.hasPrefix("Adaptive loops 2.000 mm in radius hold the feed to") }
        #expect(held.count == 1)
        #expect(held.first?.contains("below the programmed 5,588 mm/min") == true)
        #expect(!messages(nil).contains { $0.hasPrefix("Adaptive loops") })
    }

    // MARK: Entry

    /// Each area starts on a helix at its deepest point, at the bit's radius (a hole with no core), climbing
    /// counter-clockwise (conventional, clockwise).
    @Test(arguments: [CutDirection.climb, .conventional])
    func entersOnAHelix(_ direction: CutDirection) throws {
        let level = try #require(Self.plan([Self.rectangle], Self.params(direction: direction)).levels.first)
        guard case let .helix(c, rho, _, ccw) = level.moves.first else {
            Issue.record("starts with \(String(describing: level.moves.first))")
            return
        }
        #expect(c.distance(to: Vec2(100, 75)) < 0.1)
        #expect(abs(rho - Self.quarter.radius) < 1e-9)
        #expect(ccw == (direction == .climb))
    }

    /// The helix descends gently: no feed move below the surface drops more than 2°.
    @Test func helixRampsTwoDegrees() throws {
        let job = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle])]))
        let tp = try #require(job.toolpaths.first)
        var steepest = 0.0
        tp.forEachMotion { s, m in
            guard m.kind == .feed, m.end.z < -1e-6, s.z < -1e-6 else { return }
            let run = s.xy.distance(to: m.end.xy), drop = s.z - m.end.z
            if drop > 1e-9 { steepest = max(steepest, atan2(drop, run)) }
        }
        #expect(steepest > 0)
        #expect(steepest <= AdaptiveClearing.rampAngle * 1.05)
    }

    /// A slot too narrow for a helix ramps along itself instead.
    @Test func rampsWhereNoHelixFits() throws {
        let slot = Fixture.rect(60, 7, at: Vec2(100, 75))
        let level = try #require(Self.plan([slot]).levels.first)
        guard case let .ramp(p, q) = level.moves.first else {
            Issue.record("starts with \(String(describing: level.moves.first))")
            return
        }
        #expect(p.distance(to: q) > 40)
        #expect(abs(p.y - 75) < 0.5)
        #expect(abs(q.y - 75) < 0.5)
    }

    /// Pass depth defaults to the flute length; deeper than that it clears in as few full-depth levels as fit.
    @Test func passDepthDefaultsToTheFluteLength() throws {
        let p = Self.params(depth: 40)
        #expect(p.defaultPassDepth(Self.quarter) == Self.quarter.fluteLength)
        #expect(p.passLevels(Self.quarter) == [-20, -40])
        var q = p
        q.depth.passDepth = 10
        #expect(q.passLevels(Self.quarter).count == 4)
        let offsetPass = Self.params(strategy: .offset).defaultPassDepth(Self.quarter)
        #expect(offsetPass == Self.quarter.cutting.stepdown)
        let stock = Stock(width: 200, height: 150, thickness: 45, clearanceHeight: 10, plungeHeight: 2)
        let job = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle], p)], stock: stock))
        let tp = try #require(job.toolpaths.first)
        let floors = Set(tp.motions.filter { $0.kind != .rapid }.map { ($0.end.z * 1000).rounded() / 1000 })
        #expect(floors.contains(-20))
        #expect(floors.contains(-40))
        #expect(!floors.contains(-Self.quarter.cutting.stepdown))
    }

    // MARK: Walls, reliefs, rest machining

    /// The walls get one pass at the full depth, as an offset pocket's last ring is; nothing is cut at the bit's
    /// stepdown.
    @Test func finishesTheWallsInOnePass() throws {
        let job = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle])]))
        let tp = try #require(job.toolpaths.first)
        let r = Self.quarter.radius
        let corners = tp.motions.filter { m in
            m.kind == .feed && abs(m.end.z + 12) < 1e-6 && abs(abs(m.end.x - 100) - (30 - r)) < 1e-3 && abs(abs(m.end.y - 75) - (20 - r)) < 1e-3
        }
        #expect(corners.count >= 4)
        #expect(!tp.motions.contains { abs($0.end.z + Self.quarter.cutting.stepdown) < 1e-6 })
    }

    /// Corner reliefs plunge sideways into each corner, too heavy at the full flute depth, so with them the walls are
    /// cut at the bit's stepdown, and the reliefs reach each corner at each of those depths.
    @Test func cornerReliefsAreCutAtTheStepdown() throws {
        let op = Self.pocket([Self.rectangle], Self.params(relief: CornerReliefSettings()))
        let job = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [op]))
        #expect(!job.hasErrors)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.reliefCorners?.count == 4)
        let r = Self.quarter.radius
        let levels = Self.params(strategy: .offset).passLevels(Self.quarter)
        #expect(levels.count == 3)
        for z in levels {
            // A dogbone takes the bit's centre to within r of each corner.
            let deep = tp.motions.filter { abs($0.end.z - z) < 1e-6 }.map(\.end.xy)
            let reached = [Vec2(70, 55), Vec2(130, 55), Vec2(70, 95), Vec2(130, 95)].allSatisfy { c in
                deep.contains { $0.distance(to: c) <= r + 0.01 }
            }
            #expect(reached, "reliefs at \(z)")
        }
    }

    /// Rest machining with an adaptive clearance tool: the 1/2" clears adaptively at its own flute length, the 1/8" its
    /// rest at its stepdown, and the result is the 1/8" pocket alone.
    @Test func clearanceToolCanBeAdaptive() throws {
        let shapes = [RestMachiningTests.slotted, DesignShape(kind: .circle(radius: 6), position: Vec2(85, 70))]
        func job(_ clearance: Tool?) -> (JobResult, Project) {
            let p = Fixture.project(shapes: shapes, ops: [Self.pocket(shapes, tool: Self.eighth, Self.params(depth: 12, clearance: clearance))])
            return (CAMEngine.generate(p), p)
        }
        let (two, project) = job(Self.half)
        #expect(!two.hasErrors)
        try #require(two.toolpaths.count == 2)
        let clearing = two.toolpaths[0]
        #expect(clearing.tool.number == 10)
        #expect(clearing.name == "Pocket – clearing")
        // One level for the 1/2" (its flutes are longer than the pocket is deep; offset would take two), the 1/8"'s
        // stepdown for its rest.
        let flat = { (tp: Toolpath, z: Double) in tp.motions.contains { $0.kind != .rapid && abs($0.end.z - z) < 1e-6 } }
        var level: Double?
        clearing.forEachMotion { s, m in
            if level == nil, m.kind != .rapid, m.end.z < -1e-6, abs(m.end.z - s.z) < 1e-9, s.xy.distance(to: m.end.xy) > 1e-6 { level = m.end.z }
        }
        #expect(level == -12)
        let smallLevels = DepthSettings(cutDepth: 12).passLevels(toolStepdown: Self.eighth.cutting.stepdown)
        let restAtEach = smallLevels.allSatisfy { flat(two.toolpaths[1], $0) }
        #expect(restAtEach)
        let (one, _) = job(nil)
        let a = Fixture.simulate(two.toolpaths, stock: project.stock, cell: 0.25)
        let b = Fixture.simulate(one.toolpaths, stock: project.stock, cell: 0.25)
        var different = 0
        for i in a.heights.indices where abs(a.heights[i] - b.heights[i]) > 0.01 { different += 1 }
        #expect(different == 0, "\(different) cells differ")
    }

    /// Where the walk can't hold its load (a slot narrower than its loops), what it left is cleared at the bit's
    /// stepdown first, and the job says so. A plain rectangle needs none of that.
    @Test func narrowSlotsFallBackToTheStepdown() throws {
        let slotted = RestMachiningTests.slotted
        let job = CAMEngine.generate(Fixture.project(shapes: [slotted], ops: [Self.pocket([slotted])]))
        #expect(job.issues.contains { $0.message.hasPrefix("Adaptive clearing couldn't hold its load everywhere") })
        let tp = try #require(job.toolpaths.first)
        let stepdown = DepthSettings(cutDepth: 12).passLevels(toolStepdown: Self.quarter.cutting.stepdown)
        #expect(stepdown == [-4, -8, -12])
        let inSlot = tp.motions.contains { abs($0.end.z + 4) < 1e-6 && $0.end.y > 92 }
        #expect(inSlot)
        let plain = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle])]))
        #expect(!plain.issues.contains { $0.message.contains("couldn't hold its load") })
    }

    // MARK: Time

    /// A 1" deep pocket in hardwood with a 1/4" bit: adaptive cuts it in one level at 12% of the bit's width, offset in
    /// six at 40%. At the same feed adaptive takes longer (it loops back through air between cuts); fed for its thinner
    /// chip it's quicker than that. Both reported.
    @Test func deepPocketTimeComparesWithOffset() throws {
        let shape = Fixture.rect(100, 60, at: Vec2(100, 75))
        var stock = Stock(width: 200, height: 150, thickness: 30, clearanceHeight: 10, plungeHeight: 2)
        stock.materialKind = .hardwood
        func seconds(_ strategy: PocketStrategy, feed: Double? = nil) -> Double {
            var tool = Self.quarter
            if let feed { tool.cutting.feedRate = feed }
            let op = Self.pocket([shape], tool: tool, Self.params(depth: 1.inch, strategy: strategy))
            var project = Fixture.project(shapes: [shape], ops: [op], stock: stock)
            project.machine.outputArcs = true
            let job = CAMEngine.generate(project)
            #expect(!job.hasErrors)
            return job.estimatedSeconds
        }
        let offset = seconds(.offset), adaptive = seconds(.adaptive)
        // The chip at 12%: 2√(0.12 × 0.88) = 0.65 of the feed per tooth, so the feed over 0.65 keeps it.
        let thinning = 2 * (0.12 * 0.88).squareRoot()
        let fed = seconds(.adaptive, feed: Self.quarter.cutting.feedRate / thinning)
        print("Deep hardwood pocket, 100 × 60 × 25.4 mm, 1/4\" bit: offset \(Int(offset)) s, adaptive \(Int(adaptive)) s at the same feed, "
            + "\(Int(fed)) s fed for its chip")
        #expect(adaptive > 0.7 * offset)
        #expect(adaptive < 2 * offset)
        #expect(fed < adaptive)
    }

    // MARK: Other features

    /// "Adjust feeds for load" mostly leaves adaptive alone: its load is already steady.
    @Test func feedSchedulingMostlyLeavesItAlone() throws {
        let op = Self.pocket([Self.rectangle], loadFeeds: true)
        let job = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [op]))
        let tp = try #require(job.toolpaths.first)
        let f = tp.tool.cutting.feedRate
        var full = 0.0, slowed = 0.0
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell, abs(m.end.z - s.z) < 1e-9 else { return }
            let d = m.length(from: s)
            if m.feed >= f - 1e-6 { full += d } else { slowed += d }
        }
        #expect(slowed <= 0.1 * (full + slowed), "\(Int(slowed)) of \(Int(full + slowed)) mm slowed")
    }

    /// At a light load the chip thins: the chip-load check allows for it, says so when it's below the chart for the
    /// bit, and suggests a feed for the thinner chip, so raising the feed for adaptive doesn't then read as too thick.
    @Test func chipLoadCheckAllowsForTheThinnerChip() throws {
        func job(_ tool: Tool, _ load: Double) -> JobResult {
            let op = Self.pocket([Self.rectangle], tool: tool, Self.params(depth: 6, adaptive: AdaptiveSettings(optimalLoad: load)))
            return CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [op]))
        }
        func chip(_ job: JobResult) -> [String] { job.issues.map(\.message).filter { $0.hasPrefix("Chip load") } }
        // The starter 1/8" at 120 in/min, 18,000 RPM: 0.0033 in a tooth, 0.0022 in at 12%.
        let thin = chip(job(Self.eighth, 0.12))
        #expect(thin.count == 1)
        let expected = "Chip load 0.0022 in at the 12% adaptive load (a light cut thins the chip to 65% of the feed per tooth) "
            + "is below the 0.0030 in–0.0050 in range for this bit in plywood"
        let says = thin.first?.hasPrefix(expected) ?? false
        #expect(says)
        let first = try #require(job(Self.eighth, 0.12).toolpaths.first)
        #expect(first.radialLoad == 0.12)
        // At 40% the chip is nearly the feed per tooth, in range.
        #expect(chip(job(Self.eighth, 0.4)).isEmpty)
        // The suggested feed for the thinner chip.
        let rec = ChipLoad.recommend(for: Self.eighth, material: .plywood, machine: .avidPRO6060, thinning: ChipLoad.radialThinning(load: 0.12))
        var fast = Self.eighth
        fast.cutting.feedRate = rec.feed
        fast.cutting.spindleRPM = rec.rpm
        #expect(chip(job(fast, 0.12)).isEmpty)
        // The same feed in an offset pocket, where the chip isn't thinned, is in range or thick, never thin.
        let offset = CAMEngine.generate(Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle], tool: fast,
                                                                                                    Self.params(depth: 6, strategy: .offset))]))
        #expect(!chip(offset).contains { $0.contains("below") })
        let half = ChipLoad.radialThinning(load: 0.5), twelve = ChipLoad.radialThinning(load: 0.12)
        #expect(half == 1)
        #expect(abs(twelve - 0.65) < 0.001)
    }

    /// Wrapped round a rotary blank, the strategy isn't available yet: the pocket says so and cuts nothing.
    @Test func wrappedRotaryJobsRefuseAdaptive() throws {
        var project = Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle], Self.params(depth: 3))])
        project.machine.rotary = RotaryAxis(centerHeight: 4.inch)
        project.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 3.inch, length: 8.inch, layout: .wrapped))
        let job = CAMEngine.generate(project)
        let tp = try #require(job.toolpaths.first)
        #expect(tp.cuttingExtents == nil)
        #expect(job.issues.contains { $0.message.hasPrefix("Adaptive clearing isn't available on wrapped rotary jobs yet") })
    }

    @Test func dubinsPathsMeetTheirEnds() throws {
        let cases: [(Vec2, Double, Vec2, Double)] = [
            (Vec2(0, 0), 0, Vec2(20, 0), 0), (Vec2(0, 0), 0, Vec2(0, 5), .pi), (Vec2(0, 0), .pi / 2, Vec2(10, -3), -.pi / 2),
            (Vec2(0, 0), 0, Vec2(2, 1), .pi), (Vec2(5, 5), 1, Vec2(-7, 2), -2),
        ]
        for (a, ha, b, hb) in cases {
            let path = try #require(Dubins.shortest(from: a, heading: ha, to: b, heading: hb, radius: 3))
            let pts = path.points(radius: 3, tolerance: 0.001)
            #expect(pts[0].distance(to: a) < 1e-6)
            #expect(pts[pts.count - 1].distance(to: b) < 1e-3, "\(pts[pts.count - 1]) for \(b)")
            let end = pts[pts.count - 1] - pts[pts.count - 2]
            #expect(abs(remainder(end.angle - hb, 2 * .pi)) < 0.05)
            let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            #expect(abs(length - path.length) < 0.01 * path.length + 0.01)
            #expect(path.length >= a.distance(to: b) - 1e-9)
        }
    }

    // MARK: File format

    /// Adaptive clearing is format 13; other pockets keep their format, whatever adaptive settings they carry.
    @Test func adaptiveIsFormatThirteen() throws {
        let adaptive = Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle])])
        #expect(adaptive.formatVersion == 13)
        #expect(try Project.decode(adaptive.encoded()) == adaptive)
        let offset = Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle], Self.params(strategy: .offset))])
        #expect(offset.formatVersion < 13)
        var p = Self.params(adaptive: AdaptiveSettings(optimalLoad: 0.2, minimumLoopRadius: 5))
        p.strategy = .offset
        let carried = Fixture.project(shapes: [Self.rectangle], ops: [Self.pocket([Self.rectangle], p)])
        #expect(carried.formatVersion == offset.formatVersion)
    }

    /// A 3" × 2" recess 3/4" deep in hardwood with a 1/4" bit, cleared adaptively at 15% round a round boss, on the
    /// default PRO6060.
    static func savedAdaptive() -> Project {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "ADA97000-0000-0000-0000-%012d", n))! }
        let recess = DesignShape(id: id(1), name: "Recess", kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.25.inch),
                                 position: Vec2(3.inch, 2.5.inch))
        let boss = DesignShape(id: id(2), name: "Boss", kind: .circle(radius: 0.3.inch), position: Vec2(2.4.inch, 2.3.inch))
        let params = PocketParams(strategy: .adaptive, depth: DepthSettings(cutDepth: 0.75.inch), adaptive: AdaptiveSettings(optimalLoad: 0.15))
        let op = CAMOperation(id: id(11), name: "Recess", kind: .pocket(params), shapeIDs: [recess.id, boss.id],
                              tool: ToolLibrary.starter.tool(number: 1)!)
        var stock = Stock(width: 6.inch, height: 5.inch, thickness: 1.inch, materialName: "Hard maple")
        stock.materialKind = .hardwood
        return Project(name: "Adaptive recess", displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: [recess, boss],
                       operations: [op], notes: "Saved by the first build with adaptive clearing, as format 13.")
    }

    @Test func adaptivePocketSavedByFormatThirteenStillDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("adaptive-v13", make: Self.savedAdaptive)
        #expect(p.formatVersion == 13)
        let made = Self.savedAdaptive()
        #expect(p.operations == made.operations)
        #expect(p.shapes == made.shapes)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        try GoldenPostTests.check(GoldenPostTests.post(p), golden: "decoded-adaptive-v13")
    }
}
