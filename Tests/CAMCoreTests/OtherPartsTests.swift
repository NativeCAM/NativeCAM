import Foundation
import Testing
@testable import CAMCore

/// Leads and corner reliefs keep clear of the parts other toolpaths cut (#30), whatever the run order.
struct OtherPartsTests {
    static let gap = 1.5 * CutFixture.arc.radius

    /// Two 40 mm squares 1.5 × the lead radius apart, one above the other (y 55…95 and 5.5…45.5) and offset 10 mm in
    /// X. The top one's loop starts at its lower right, where its arc lead comes in from below and to the right: right
    /// over the lower square, so it would cut a radius into it.
    static let centres = [Vec2(60, 75), Vec2(70, 35 - gap)]
    static func squares() -> (a: DesignShape, b: DesignShape, stock: Stock) {
        (Fixture.rect(40, 40, at: centres[0]), Fixture.rect(40, 40, at: centres[1]), Fixture.stock)
    }

    /// Cells of either square that were cut (more than a cell in from its edges).
    static func gouged(_ grid: HeightGrid, centres: [Vec2], half: Double) -> Int {
        CutFixture.cells(grid).filter { p, h in
            h < -1e-6 && centres.contains { abs(p.x - $0.x) < half - 0.25 && abs(p.y - $0.y) < half - 0.25 }
        }.count
    }

    static func named(_ op: CAMOperation, _ name: String) -> CAMOperation {
        var op = op
        op.name = name
        return op
    }

    // MARK: Leads

    @Test(arguments: [false, true])
    func leadsStayOutOfAPartCutByAnotherToolpath(reversed: Bool) throws {
        let (a, b, stock) = Self.squares()
        let opA = CutFixture.profile([a], leads: CutFixture.arc), opB = CutFixture.profile([b], leads: CutFixture.arc)
        let (_, job) = CutFixture.job([a, b], reversed ? [opB, opA] : [opA, opB], stock: stock)
        #expect(job.toolpaths.count == 2)
        for tp in job.toolpaths {
            #expect(!tp.warnings.contains { $0.contains("Leads") }, "\(tp.warnings)")
            #expect(!CutFixture.plunges(tp).isEmpty)
        }
        let grid = Fixture.simulate(job.toolpaths, stock: stock, cell: 0.25)
        let cut = Self.gouged(grid, centres: Self.centres, half: 20)
        #expect(cut == 0, "\(cut) cells of the parts were cut (reversed: \(reversed))")
    }

    @Test func leadsDontDependOnTheRunOrder() throws {
        let (a, b, stock) = Self.squares()
        let opA = CutFixture.profile([a], leads: CutFixture.arc), opB = CutFixture.profile([b], leads: CutFixture.arc)
        let (_, forward) = CutFixture.job([a, b], [opA, opB], stock: stock)
        let (_, backward) = CutFixture.job([a, b], [opB, opA], stock: stock)
        for op in [opA, opB] {
            let one = try #require(forward.toolpaths.first { $0.sourceOperationID == op.id })
            let other = try #require(backward.toolpaths.first { $0.sourceOperationID == op.id })
            let p = CutFixture.plunges(one).map(\.1), q = CutFixture.plunges(other).map(\.1)
            #expect(p == q)
        }
        // Turned off, the other toolpath still counts: it's usually cut in another run.
        var off = opB
        off.enabled = false
        let (_, alone) = CutFixture.job([a, b], [opA, off], stock: stock)
        let tp = try #require(alone.toolpaths.first)
        let one = try #require(forward.toolpaths.first { $0.sourceOperationID == opA.id })
        #expect(CutFixture.plunges(tp).map(\.1) == CutFixture.plunges(one).map(\.1))
    }

    enum Kind: String, CaseIterable { case outside, inside, on, pocket, vcarve, drill }

    /// The lower square (or a hole where the top square's lead would land) cut by each kind of toolpath: the top
    /// square's leads keep out of what it leaves. Returns the area its walls bound (its kerf for an "On" cut).
    static func neighbour(_ kind: Kind) -> (shape: DesignShape, op: CAMOperation, inside: (Vec2) -> Bool) {
        let b = Fixture.rect(40, 40, at: centres[1])
        let r = CutFixture.r
        let rect = { (p: Vec2, grow: Double) in abs(p.x - centres[1].x) < 20 + grow && abs(p.y - centres[1].y) < 20 + grow }
        let depth = DepthSettings(cutDepth: 6, passDepth: 3)
        switch kind {
        case .outside: return (b, CutFixture.profile([b]), { rect($0, -0.25) })
        case .inside: return (b, CutFixture.profile([b], side: .inside), { rect($0, -0.25) })
        case .on: return (b, CutFixture.profile([b], side: .on), { rect($0, r - 0.25) })
        case .pocket: return (b, CutFixture.pocket([b]), { rect($0, -0.25) })
        case .vcarve:
            return (b, CAMOperation(kind: .vcarve(VCarveParams()), shapeIDs: [b.id], tool: Fixture.vBit90), { rect($0, -0.25) })
        case .drill:
            let c = Vec2(86, 42)
            let hole = DesignShape(kind: .circle(radius: r), position: c)
            return (hole, CAMOperation(kind: .drill(DrillParams(depth: depth.cutDepth)), shapeIDs: [hole.id], tool: Fixture.endMill),
                    { $0.distance(to: c) < r - 0.25 })
        }
    }

    @Test(arguments: Kind.allCases)
    func leadsKeepClearOfEveryKindOfPart(kind: Kind) throws {
        let a = Fixture.rect(40, 40, at: Self.centres[0])
        let (b, other, inside) = Self.neighbour(kind)
        let opA = CutFixture.profile([a], leads: CutFixture.arc)
        let (_, job) = CutFixture.job([a, b], [other, opA])
        let tp = try #require(job.toolpaths.first { $0.sourceOperationID == opA.id })
        #expect(!tp.warnings.contains { $0.contains("Leads") }, "\(kind): \(tp.warnings)")
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        let cut = CutFixture.cells(grid).filter { p, h in h < -1e-6 && inside(p) }.count
        #expect(cut == 0, "\(kind): the leads cut \(cut) cells of the other toolpath's part")
    }

    @Test func leadsAreLeftOffWhenTheOtherPartLeavesNoRoom() throws {
        // A part cut out by another toolpath in the middle of a hole leaves the hole's waste no room for a lead.
        let hole = DesignShape(kind: .circle(radius: 9), position: Vec2(100, 75))
        let middle = DesignShape(kind: .circle(radius: 2.5), position: Vec2(100, 75))
        let cut = CutFixture.profile([hole], side: .inside, leads: CutFixture.arc)
        let (_, alone) = CutFixture.job([hole], [cut])
        #expect(alone.toolpaths.first?.warnings.isEmpty == true)
        let (_, job) = CutFixture.job([hole, middle], [cut, CutFixture.profile([middle])])
        let tp = try #require(job.toolpaths.first { $0.sourceOperationID == cut.id })
        #expect(tp.warnings.contains("Leads didn't fit on 1 loop; it's entered without one."), "\(tp.warnings)")
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        let gouged = CutFixture.cells(grid).filter { p, h in h < -1e-6 && p.distance(to: Vec2(100, 75)) < 2.5 - 0.25 }
        #expect(gouged.isEmpty)
    }

    @Test func aFinishKeepsItsLeadsAndReliefsInItsRoughsAllowance() throws {
        // A rough leaves 0.5 mm that the finish cuts: that's not another part.
        let mortise = Fixture.rect(60, 20, at: Vec2(100, 75))
        let relief = CornerReliefSettings()
        let finish = CutFixture.profile([mortise], side: .inside, leads: CutFixture.line, relief: relief)
        let rough = CutFixture.profile([mortise], side: .inside, allowance: 0.5, relief: relief)
        let (_, alone) = CutFixture.job([mortise], [finish])
        let (_, both) = CutFixture.job([mortise], [rough, finish])
        let a = try #require(alone.toolpaths.first)
        let b = try #require(both.toolpaths.first { $0.sourceOperationID == finish.id })
        let r = try #require(both.toolpaths.first { $0.sourceOperationID == rough.id })
        #expect(b.warnings.isEmpty, "\(b.warnings)")
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(CutFixture.reversals(b) == CutFixture.reversals(a))
        #expect(b.reliefCorners?.contains { $0.isFlagged } == false)
        #expect(r.reliefCorners?.contains { $0.isFlagged } == false)
        #expect(Fixture.pointsAt(z: -6, b) == Fixture.pointsAt(z: -6, a))
    }

    // MARK: Corner reliefs

    /// Two 40 × 20 mortises side by side (x 60…100 and 100 + wall…140 + wall) with a wall between them that the
    /// relief would break through: a dogbone cuts 0.29 × the bit's radius past each wall, a T-bone into the short
    /// side a whole radius.
    static func mortises(wall: Double) -> (left: DesignShape, right: DesignShape) {
        (Fixture.rect(40, 20, at: Vec2(80, 75)), Fixture.rect(40, 20, at: Vec2(120 + wall, 75)))
    }

    /// Cells of the wall between the mortises that were cut.
    static func brokenWall(_ grid: HeightGrid, wall: Double) -> Int {
        CutFixture.cells(grid).filter { p, h in h < -1e-6 && p.x > 100.1 && p.x < 100 + wall - 0.1 && abs(p.y - 75) < 11 }.count
    }

    @Test(arguments: [(CornerReliefStyle.dogbone, 0.5), (.tBone, 2.0)])
    func reliefsDontBreakThroughAnotherToolpathsWall(style: CornerReliefStyle, wall: Double) throws {
        let (left, right) = Self.mortises(wall: wall)
        let relief = CornerReliefSettings(style: style, tBoneSide: .shorter)
        let ops = [Self.named(CutFixture.profile([left], side: .inside, relief: relief), "Left"),
                   Self.named(CutFixture.profile([right], side: .inside, relief: relief), "Right")]
        let (_, job) = CutFixture.job([left, right], ops)
        #expect(job.toolpaths.count == 2)
        let grid = Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.1)
        let broken = Self.brokenWall(grid, wall: wall)
        #expect(broken == 0, "\(broken) cells of the wall were cut")
        // The far corners keep their reliefs (two corners, two passes), as they would in one toolpath.
        for tp in job.toolpaths { #expect(CutFixture.reversals(tp) == 2 * 2, "\(tp.name)") }
        let (_, together) = CutFixture.job([left, right], [CutFixture.profile([left, right], side: .inside, relief: relief)])
        let one = try #require(together.toolpaths.first)
        #expect(CutFixture.reversals(one) == 4 * 2)
        // The two by the wall are flagged (an orange cross), with a Checks warning naming the other toolpath.
        for (tp, other) in zip(job.toolpaths, ["Right", "Left"]) {
            let corners = try #require(tp.reliefCorners)
            let flagged = corners.filter(\.isFlagged)
            #expect(flagged.count == 2, "\(tp.name)")
            let leftOff = flagged.allSatisfy { $0.blocked && $0.tip == nil && $0.otherPart == other }
            #expect(leftOff, "\(tp.name)")
            let message = "2 corners weren't relieved: their reliefs would cut into a part cut by \u{201C}\(other)\u{201D}."
            #expect(tp.warnings.contains(message), "\(tp.warnings)")
            let inChecks = job.issues.contains { $0.severity == .warning && $0.message == message && $0.operation == tp.name }
            #expect(inChecks)
        }
    }

    @Test func reliefsCanCutIntoOtherPartsWhenAskedAndAreStillFlagged() throws {
        let (left, right) = Self.mortises(wall: 0.5)
        let relief = CornerReliefSettings(avoidsOtherParts: false)
        let ops = [Self.named(CutFixture.profile([left], side: .inside, relief: relief), "Left"),
                   Self.named(CutFixture.profile([right], side: .inside, relief: relief), "Right")]
        let (_, job) = CutFixture.job([left, right], ops)
        for (tp, other) in zip(job.toolpaths, ["Right", "Left"]) {
            #expect(CutFixture.reversals(tp) == 4 * 2, "\(tp.name)")
            let flagged = try #require(tp.reliefCorners).filter(\.isFlagged)
            #expect(flagged.count == 2)
            let cutAnyway = flagged.allSatisfy { !$0.blocked && $0.tip != nil && $0.otherPart == other }
            #expect(cutAnyway)
            let message = "2 corner reliefs cut into a part cut by \u{201C}\(other)\u{201D}. Move the parts apart, or turn on "
                + "Corners \u{25B8} Leave off reliefs that cut into other parts."
            #expect(tp.warnings.contains(message), "\(tp.warnings)")
        }
    }

    @Test func aWallThickerThanTheReliefIsLeftAlone() throws {
        // A dogbone cuts 0.93 mm past the wall here, so 2 mm leaves a wall standing.
        let (left, right) = Self.mortises(wall: 2)
        let ops = [CutFixture.profile([left], side: .inside, relief: CornerReliefSettings()),
                   CutFixture.profile([right], side: .inside, relief: CornerReliefSettings())]
        let (_, job) = CutFixture.job([left, right], ops)
        for tp in job.toolpaths {
            #expect(CutFixture.reversals(tp) == 4 * 2)
            #expect(tp.reliefCorners?.contains { $0.isFlagged } == false)
            #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        }
    }

    @Test(arguments: [PocketStrategy.offset, .raster])
    func pocketReliefsKeepClearOfAnotherToolpathsPart(strategy: PocketStrategy) throws {
        let (left, right) = Self.mortises(wall: 0.5)
        let relieved = CutFixture.pocket([left], strategy: strategy, relief: CornerReliefSettings())
        let (_, job) = CutFixture.job([left, right], [relieved, CutFixture.profile([right], side: .inside)])
        let tp = try #require(job.toolpaths.first)
        let (_, plain) = CutFixture.job([left], [CutFixture.pocket([left], strategy: strategy)])
        let base = try #require(plain.toolpaths.first)
        #expect(CutFixture.reversals(tp) - CutFixture.reversals(base) == 2 * 2, "the two far corners, two passes")
        #expect(tp.reliefCorners?.filter(\.isFlagged).count == 2)
        let grid = Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.1)
        #expect(Self.brokenWall(grid, wall: 0.5) == 0)
    }

    @Test func theOptionIsSavedOnlyWhenOff() throws {
        let on = CornerReliefSettings()
        let json = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        #expect(!json.contains("avoidsOtherParts"))
        let off = CornerReliefSettings(style: .tBone, avoidsOtherParts: false)
        let back = try JSONDecoder().decode(CornerReliefSettings.self, from: try JSONEncoder().encode(off))
        #expect(back == off)
        let old = try JSONDecoder().decode(CornerReliefSettings.self, from: Data(#"{"style":"dogbone","tBoneSide":"longer","maxCornerAngle":120}"#.utf8))
        #expect(old.avoidsOtherParts)
        let p = Fixture.project(shapes: [], ops: [CutFixture.profile([], side: .inside, relief: off)])
        let q = Fixture.project(shapes: [], ops: [CutFixture.profile([], side: .inside, relief: on)])
        #expect(p.formatVersion == q.formatVersion)
    }

    // MARK: Regions

    @Test func aPocketOverTheWholeSheetHasNoWallAtItsEdge() throws {
        // Facing the whole sheet first: its edge is the material's, so a part flush with the corner keeps its leads.
        let sheet = Fixture.rect(200, 150, at: Vec2(100, 75))
        let corner = Fixture.rect(40, 40, at: Vec2(20, 20))
        let face = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 1))), shapeIDs: [sheet.id], tool: Fixture.endMill)
        let cutOut = CutFixture.profile([corner], leads: CutFixture.arc)
        let (_, alone) = CutFixture.job([corner], [cutOut])
        let (_, faced) = CutFixture.job([sheet, corner], [face, cutOut])
        let a = try #require(alone.toolpaths.first)
        let b = try #require(faced.toolpaths.first { $0.sourceOperationID == cutOut.id })
        #expect(!b.warnings.contains { $0.contains("Leads") }, "\(b.warnings)")
        #expect(CutFixture.plunges(a).map { $0.1.xy } == CutFixture.plunges(b).map { $0.1.xy })
    }

    @Test func onAnIndexedBlankOnlyPartsOnTheSameFaceCount() throws {
        var stock = Stock(materialName: "Maple")
        stock.setRotary(RotaryStock(shape: .squareBar, diameter: 2.inch, length: 12.inch))
        let a = Fixture.rect(20, 20, at: Vec2(100, 25)), b = Fixture.rect(20, 20, at: Vec2(130, 25))
        var opA = CutFixture.profile([a], side: .inside, leads: CutFixture.arc)
        opA.indexAngles = [0, 90]
        var opB = CutFixture.profile([b], side: .inside)
        opB.indexAngles = [90, 180]
        let p = Project(name: "Bar", displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: [a, b], operations: [opA, opB])
        let parts = ProtectedRegions(p, flattenTolerance: 0.01, arcTolerance: 0.005)
        #expect(parts.excluding(opA.id, angle: 0).parts.isEmpty)
        #expect(parts.excluding(opA.id, angle: 90).parts.map(\.operation) == [opB.id])
        #expect(parts.excluding(opA.id, angle: -270).parts.map(\.operation) == [opB.id])
        #expect(parts.excluding(opB.id, angle: 180).parts.isEmpty)
    }

    /// Parts are built for leads and reliefs, and (#186) for an outside cut with another toolpath, which is checked
    /// against them; not otherwise.
    @Test func noPartsAreBuiltWithoutLeadsReliefsOrAnOutsideCut() {
        let (a, b, _) = Self.squares()
        let plain = Fixture.project(shapes: [a, b], ops: [CutFixture.profile([a], side: .inside), CutFixture.pocket([b])])
        #expect(!ProtectedRegions.needed(plain))
        let alone = Fixture.project(shapes: [a], ops: [CutFixture.profile([a])])
        #expect(!ProtectedRegions.needed(alone))
        let cutOut = Fixture.project(shapes: [a, b], ops: [CutFixture.profile([a]), CutFixture.pocket([b])])
        #expect(ProtectedRegions.needed(cutOut))
        let relieved = Fixture.project(shapes: [a, b], ops: [CutFixture.profile([a]), CutFixture.pocket([b], relief: CornerReliefSettings())])
        #expect(ProtectedRegions.needed(relieved))
    }

    @Test func aSheetSplitAcrossToolpathsStaysQuick() throws {
        // The 50 notched parts of `LeadTests.aSheetOfPartsStaysQuick`, 12 mm apart, one toolpath per column: the leads
        // and reliefs fit as they do in one toolpath and cut no other part.
        var shapes: [DesignShape] = []
        var ops: [CAMOperation] = []
        for col in 0..<10 {
            var column: [DesignShape] = []
            for row in 0..<5 {
                let o = Vec2(10 + Double(col) * 48, 10 + Double(row) * 48)
                let pts = [Vec2(0, 0), Vec2(36, 0), Vec2(36, 36), Vec2(24, 36), Vec2(24, 24), Vec2(12, 24), Vec2(12, 36), Vec2(0, 36)].map { $0 + o }
                column.append(DesignShape(kind: .paths([Polyline(pts, closed: true)]), position: .zero))
            }
            shapes += column
            ops.append(CutFixture.profile(column, depth: DepthSettings(cutDepth: 18.5, passDepth: 6.5), leads: CutFixture.arc,
                                          relief: CornerReliefSettings()))
        }
        let stock = Stock(width: 500, height: 260, thickness: 18, clearanceHeight: 10, plungeHeight: 2)
        let clock = ContinuousClock()
        var job: JobResult?
        let elapsed = clock.measure { job = CutFixture.job(shapes, ops, stock: stock).1 }
        let toolpaths = try #require(job?.toolpaths)
        #expect(toolpaths.count == 10)
        for tp in toolpaths {
            #expect(tp.warnings.isEmpty, "\(tp.warnings)")
            #expect(CutFixture.reversals(tp) == 5 * 2 * 3, "two reliefs per part, three passes")
        }
        #expect(elapsed < .seconds(20), "took \(elapsed)")
        // No part is cut inside its outline (past its reliefs) by another column's leads.
        let grid = Fixture.simulate(toolpaths, stock: stock, cell: 0.5)
        let outlines = shapes.flatMap { $0.polylines() }
        let gouged = CutFixture.cells(grid).filter { p, h in
            h < -1e-6 && outlines.contains { $0.bounds.contains(p) && $0.contains(p) && $0.closestPoint(to: p).distance > 1.5 }
        }
        #expect(gouged.isEmpty, "\(gouged.count) cells of the parts were cut")
    }
}
