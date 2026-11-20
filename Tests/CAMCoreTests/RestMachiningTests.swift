import Foundation
import Testing
@testable import CAMCore

/// Rest machining: a pocket cleared with a larger bit first, then finished with the operation's own, which only goes
/// where the larger one couldn't reach.
struct RestMachiningTests {
    static let lib = ToolLibrary.starter
    static var eighth: Tool { lib.tool(number: 2)! }
    static var quarter: Tool { lib.tool(number: 1)! }
    /// A 1/2" upcut end mill as T10, with cutting data of its own (written before the starter library had one).
    static var half: Tool {
        Tool(id: UUID(uuidString: "4E415449-5645-4341-4D02-000000000010")!, number: 10, name: "1/2\" Upcut End Mill",
             shape: .flatEndMill, diameter: 0.5.inch, fluteLength: 1.25.inch,
             cutting: CuttingData(spindleRPM: 10000, feedRate: 380.inch, plungeRate: 50.inch, stepdown: 0.25.inch, stepoverFraction: 0.45))
    }

    static func pocket(_ shapes: [DesignShape], tool: Tool = eighth, clearance: Tool? = half, depth: Double = 6,
                       strategy: PocketStrategy = .offset, name: String = "Pocket") -> CAMOperation {
        CAMOperation(name: name, kind: .pocket(PocketParams(strategy: strategy, depth: DepthSettings(cutDepth: depth), clearanceTool: clearance)),
                     shapeIDs: shapes.map(\.id), tool: tool)
    }

    /// Cutting moves below the surface (end points).
    static func cuts(_ tp: Toolpath) -> [Vec3] {
        tp.motions.filter { $0.kind != .rapid && $0.kind != .dwell && $0.end.z < -1e-6 }.map(\.end)
    }

    /// The pocket's regions as the generator builds them.
    static func regions(_ shapes: [DesignShape]) -> [Region] {
        Region.build(from: shapes.flatMap { $0.polylines(tolerance: 0.01) }.filter(\.isClosed), fill: .evenOdd)
    }

    /// An 60 × 40 mm pocket with a 10 mm slot (narrower than a 1/2" bit) 25 mm long out of the middle of its top.
    static let slotted = DesignShape(kind: .paths([Polyline([Vec2(70, 50), Vec2(130, 50), Vec2(130, 90), Vec2(105, 90), Vec2(105, 115),
                                                             Vec2(95, 115), Vec2(95, 90), Vec2(70, 90)], closed: true)]),
                                     position: .zero)

    // MARK: Geometry

    @Test func squarePocketSendsTheSmallBitOnlyToTheCornersAndWalls() throws {
        let square = Fixture.rect(80, 80, at: Vec2(100, 75))
        let op = Self.pocket([square])
        let job = CAMEngine.generate(Fixture.project(shapes: [square], ops: [op]))
        #expect(!job.hasErrors)
        try #require(job.toolpaths.count == 2)
        let (clearing, rest) = (job.toolpaths[0], job.toolpaths[1])
        #expect(clearing.tool.number == 10 && clearing.name == "Pocket – clearing" && clearing.operationID == op.id)
        #expect(rest.tool.number == 2 && rest.id == op.id && rest.name == "Pocket")

        // What only the 1/8" reaches: the four corners.
        let corners = [Vec2(60, 35), Vec2(140, 35), Vec2(60, 115), Vec2(140, 115)]
        let restRegion = PocketGenerator.restRegion(Self.regions([square]), large: Self.half, small: Self.eighth, allowance: 0,
                                                    arcTolerance: 0.005)
        #expect(restRegion.count == 4)
        for corner in corners {
            let near = restRegion.filter { (r: Region) -> Bool in r.bounds.center.distance(to: corner) < Self.half.radius }
            #expect(near.count == 1)
        }

        // The 1/2" stays its radius plus the rest margin off the walls.
        let keep = Self.half.radius + PocketParams.restMargin(for: Self.eighth) - 0.01
        let clear = Self.cuts(clearing).allSatisfy { (p: Vec3) -> Bool in abs(p.x - 100) <= 40 - keep && abs(p.y - 75) <= 40 - keep }
        #expect(clear)
        // The 1/8" makes the wall pass, which reaches into every corner, and cuts nowhere else.
        let r = Self.eighth.radius
        let small = Self.cuts(rest)
        #expect(!small.isEmpty)
        let onWall = small.allSatisfy { (p: Vec3) -> Bool in
            let dx: Double = abs(abs(p.x - 100) - (40 - r)), dy: Double = abs(abs(p.y - 75) - (40 - r))
            return min(dx, dy) < 0.01 && abs(p.x - 100) <= 40 - r + 0.01 && abs(p.y - 75) <= 40 - r + 0.01
        }
        #expect(onWall)
        for corner in corners {
            let inset = corner + Vec2(corner.x < 100 ? r : -r, corner.y < 75 ? r : -r)
            let reached = small.contains { (p: Vec3) -> Bool in p.xy.distance(to: inset) < 0.01 && abs(p.z + 6) < 1e-6 }
            #expect(reached, "corner \(corner)")
        }
        // All 1/8" depths, the 1/2" in one pass.
        let smallDepths = Set(small.map { (p: Vec3) -> Double in (p.z * 1000).rounded() })
        let largeDepths = Set(Self.cuts(clearing).map { (p: Vec3) -> Double in (p.z * 1000).rounded() })
        #expect(smallDepths.count == 4)
        #expect(largeDepths == [-6000])
    }

    @Test func slotNarrowerThanTheLargeBitIsInTheRestRegion() throws {
        let op = Self.pocket([Self.slotted])
        let job = CAMEngine.generate(Fixture.project(shapes: [Self.slotted], ops: [op]))
        #expect(!job.hasErrors)
        try #require(job.toolpaths.count == 2)
        let restRegion = PocketGenerator.restRegion(Self.regions([Self.slotted]), large: Self.half, small: Self.eighth, allowance: 0,
                                                    arcTolerance: 0.005)
        #expect(restRegion.contains { $0.contains(Vec2(100, 105)) })
        #expect(!restRegion.contains { $0.contains(Vec2(100, 70)) })
        // The 1/2" can't get into the slot: its centre only rises into the mouth until it meets the slot's corners.
        let keep = Self.half.radius + PocketParams.restMargin(for: Self.eighth)
        let mouth = 90 - (keep * keep - 25).squareRoot()
        let large = Self.cuts(job.toolpaths[0]).map(\.y)
        #expect(large.allSatisfy { $0 < mouth + 0.01 })
        #expect(large.contains { $0 > mouth - 1 })
        // The 1/8" clears the slot's middle, past what the wall pass reaches.
        let inner: Double = 5 - 1.5 * Self.eighth.radius
        let middle = Self.cuts(job.toolpaths[1]).filter { (p: Vec3) -> Bool in abs(p.z + 6) < 1e-6 && abs(p.x - 100) < inner && p.y > 95 }
        #expect(!middle.isEmpty)
        #expect(!job.issues.contains { $0.message.contains("reaches the whole pocket") })
    }

    /// Simulated, the two-tool pocket comes out the same as one cut with the small bit alone: no slivers left between
    /// the bits' cuts, nothing cut past the small bit's walls.
    @Test(arguments: [PocketStrategy.offset, .raster])
    func twoToolPocketMatchesSmallBitAlone(strategy: PocketStrategy) throws {
        let island = DesignShape(kind: .circle(radius: 6), position: Vec2(85, 70))
        let shapes = [Self.slotted, island]
        func grid(_ clearance: Tool?) -> HeightGrid {
            let project = Fixture.project(shapes: shapes, ops: [Self.pocket(shapes, clearance: clearance, strategy: strategy)])
            let job = CAMEngine.generate(project)
            #expect(!job.hasErrors)
            return Fixture.simulate(job.toolpaths, stock: project.stock, cell: 0.25)
        }
        let two = grid(Self.half), one = grid(nil)
        var cut = 0, different = 0
        for i in one.heights.indices {
            if one.heights[i] < -5.99 { cut += 1 }
            if abs(one.heights[i] - two.heights[i]) > 0.01 { different += 1 }
        }
        #expect(cut > 30_000)
        #expect(different == 0, "\(different) cells differ (\(strategy))")
    }

    @Test func clearingFirstIsQuickerThanTheSmallBitAlone() {
        func seconds(_ clearance: Tool?) -> Double {
            var p = Project.demoSign()
            let k = p.operations.firstIndex { $0.name == "Pocket plaque" }!
            p.operations[k].tool = Self.eighth
            p.operations[k].kind = .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch), clearanceTool: clearance))
            return CAMEngine.generate(p).estimatedSeconds
        }
        let alone = seconds(nil), cleared = seconds(Self.half)
        #expect(cleared < 0.75 * alone, "\(cleared) s with the 1/2\" first, \(alone) s with the 1/8\" alone")
    }

    // MARK: Run order

    static func spread() -> (shapes: [DesignShape], ops: [CAMOperation]) {
        let a = Fixture.rect(30, 30, at: Vec2(30, 30)), b = Fixture.rect(30, 30, at: Vec2(90, 30))
        let star = Fixture.rect(25, 25, at: Vec2(150, 30))
        let holes = [Vec2(30, 120), Vec2(90, 120)].map { DesignShape(kind: .circle(radius: 2), position: $0) }
        let ops = [
            Self.pocket([a], depth: 3, name: "Pocket A"),
            CAMOperation(name: "Drill", kind: .drill(DrillParams(depth: 5)), shapeIDs: holes.map(\.id), tool: Self.eighth),
            Self.pocket([b], depth: 3, name: "Pocket B"),
            CAMOperation(name: "Carve", kind: .vcarve(VCarveParams(flatDepth: 1, clearanceTool: Self.quarter)), shapeIDs: [star.id],
                         tool: Fixture.vBit90),
        ]
        return ([a, b, star] + holes, ops)
    }

    /// Tool changes between the toolpaths a job actually cuts.
    static func changes(_ toolpaths: [Toolpath]) -> Int {
        let numbers = toolpaths.filter { !$0.isEmpty }.map(\.tool.number)
        return zip(numbers, numbers.dropFirst()).filter { $0 != $1 }.count
    }

    @Test func pocketsSharingBitsChangeToolsOnceEach() throws {
        let (shapes, all) = Self.spread()
        var p = Fixture.project(shapes: shapes, ops: Array(all.prefix(3)))
        // Pocket A (1/2" then 1/8"), drill (1/8"), pocket B (1/2" then 1/8"): three changes as listed.
        let r = OperationScheduler.optimize(p)
        #expect(r.toolChangesBefore == 3 && r.toolChangesAfter == 1)
        #expect(r.order == [all[0].id, all[2].id, all[1].id])
        p.applyRunOrder(r.order)
        let tps = CAMEngine.generate(p).toolpaths
        // Both pockets' clearing with the 1/2", then their rest and the drilling with the 1/8".
        #expect(tps.map(\.name) == ["Pocket A – clearing", "Pocket B – clearing", "Pocket A", "Pocket B", "Drill"])
        #expect(tps.map(\.tool.number) == [10, 10, 2, 2, 2])
        #expect(Self.changes(tps) == 1)
    }

    /// The scheduler counts tool changes exactly as the engine cuts the job, in every order.
    @Test func schedulerCountsChangesAsTheEngineCuts() {
        let (shapes, ops) = Self.spread()
        func permutations(_ a: [CAMOperation]) -> [[CAMOperation]] {
            a.count <= 1 ? [a] : a.indices.flatMap { i in permutations(Array(a[..<i] + a[(i + 1)...])).map { [a[i]] + $0 } }
        }
        for order in permutations(ops) {
            let p = Fixture.project(shapes: shapes, ops: order)
            let r = OperationScheduler.optimize(p)
            let names = order.map(\.name).joined(separator: ", ")
            #expect(r.toolChangesBefore == Self.changes(CAMEngine.generate(p).toolpaths), "\(names)")
            #expect(r.toolChangesAfter <= r.toolChangesBefore)
        }
    }

    @Test func blocksGroupNeighboursSharingAClearanceTool() {
        #expect(OperationScheduler.blocks([10, 10, nil, 10, 4, 4, nil, nil]) == [[0, 1], [2], [3], [4, 5], [6], [7]])
        #expect(OperationScheduler.blocks([]) == [])
    }

    // MARK: Checks

    @Test func warnsWhenTheClearanceToolIsNoLarger() {
        let square = Fixture.rect(60, 60, at: Vec2(100, 75))
        let job = CAMEngine.generate(Fixture.project(shapes: [square], ops: [Self.pocket([square], tool: Self.quarter, clearance: Self.eighth)]))
        let warned = job.issues.contains { (i: JobIssue) -> Bool in i.operation == "Pocket" && i.message.contains("isn't larger than this toolpath's tool") }
        #expect(warned)
    }

    @Test func warnsWhenTheLargeBitReachesEverywhere() {
        let round = DesignShape(kind: .circle(radius: 30), position: Vec2(100, 75))
        let job = CAMEngine.generate(Fixture.project(shapes: [round], ops: [Self.pocket([round])]))
        let warned = job.issues.contains { (i: JobIssue) -> Bool in i.operation == "Pocket" && i.message.contains("reaches the whole pocket") }
        #expect(warned)
        // A square's corners are rest, so it doesn't say so there.
        let square = Fixture.rect(60, 60, at: Vec2(100, 75))
        let other = CAMEngine.generate(Fixture.project(shapes: [square], ops: [Self.pocket([square])]))
        #expect(!other.issues.contains { $0.message.contains("reaches the whole pocket") })
    }

    @Test func largeBitThatDoesNotFitLeavesItAllToTheSmallOne() throws {
        let narrow = Fixture.rect(12, 40, at: Vec2(100, 75))
        let job = CAMEngine.generate(Fixture.project(shapes: [narrow], ops: [Self.pocket([narrow])]))
        #expect(job.toolpaths.count == 1)
        #expect(job.issues.contains { $0.message.contains("too large to fit in the pocket, so this toolpath's tool clears all of it") })
        let tp = try #require(job.toolpaths.first)
        #expect(tp.tool.number == 2 && !tp.isEmpty)
    }

    @Test func checksDepthAgainstBothBits() {
        var short = Self.half
        short.fluteLength = 10
        let square = Fixture.rect(60, 60, at: Vec2(100, 75))
        let job = CAMEngine.generate(Fixture.project(shapes: [square], ops: [Self.pocket([square], clearance: short, depth: 15)]))
        func flutes(_ name: String, _ bit: String) -> Bool {
            job.issues.contains { (i: JobIssue) -> Bool in i.operation == name && i.message.contains("exceeds the cutting length of \(bit)") }
        }
        #expect(flutes("Pocket – clearing", "1/2\""))
        #expect(flutes("Pocket", "1/8\""))
    }

    @Test func warnsWhenTheClearanceToolIsNotFlat() {
        let square = Fixture.rect(60, 60, at: Vec2(100, 75))
        let ball = Self.lib.tool(number: 7)!
        let job = CAMEngine.generate(Fixture.project(shapes: [square], ops: [Self.pocket([square], clearance: ball)]))
        #expect(job.issues.contains { $0.message.contains("Clear with a flat end mill") })
    }

    // MARK: File format and setup sheet

    @Test func clearanceToolRoundTripsWithoutANewFormat() throws {
        let square = Fixture.rect(60, 60, at: Vec2(100, 75))
        let two = Fixture.project(shapes: [square], ops: [Self.pocket([square])])
        let one = Fixture.project(shapes: [square], ops: [Self.pocket([square], clearance: nil)])
        #expect(try Project.decode(two.encoded()) == two)
        // An older build cuts the same pocket with the small bit alone, so the format stays as it was.
        #expect(two.formatVersion == one.formatVersion)
        let saved = String(decoding: try two.encoded(), as: UTF8.self)
        #expect(saved.contains("\"clearanceTool\""))
        #expect(!String(decoding: try one.encoded(), as: UTF8.self).contains("clearanceTool"))
    }

    @Test func setupSheetSaysWhatEachBitCuts() {
        let square = Fixture.rect(60, 60, at: Vec2(100, 75))
        let p = Fixture.project(shapes: [square], ops: [Self.pocket([square])])
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p))
        #expect(html.contains("<h2>Rest machining</h2>"))
        #expect(html.contains("T10 1/2&quot; Upcut End Mill clears the pocket first"))
        #expect(html.contains("T2 1/8&quot; Upcut End Mill then cuts only the corners"))
    }
}
