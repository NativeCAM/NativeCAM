import Foundation
import Testing
@testable import CAMCore

/// Shapes and checks shared by the nesting tests.
enum NestFixture {
    static func rect(_ w: Double, _ h: Double, at c: Vec2 = .zero) -> Polyline {
        Polyline([c + Vec2(-w / 2, -h / 2), c + Vec2(w / 2, -h / 2), c + Vec2(w / 2, h / 2), c + Vec2(-w / 2, h / 2)], closed: true)
    }

    /// An L: `w` × `h` with a `w - t` × `h - t` corner cut away at the top right.
    static func ell(_ w: Double, _ h: Double, _ t: Double, at c: Vec2 = .zero) -> Polyline {
        Polyline([Vec2(0, 0), Vec2(w, 0), Vec2(w, t), Vec2(t, t), Vec2(t, h), Vec2(0, h)].map { $0 + c }, closed: true)
    }

    static func triangle(_ w: Double, _ h: Double, at c: Vec2 = .zero) -> Polyline {
        Polyline([c, c + Vec2(w, 0), c + Vec2(0, h)], closed: true)
    }

    static func circle(_ r: Double, at c: Vec2 = .zero) -> Polyline {
        Polyline(Curves.circle(center: c, radius: r, tolerance: 0.01), closed: true)
    }

    /// A mixed set: rectangles, Ls, triangles, discs. Spread out where they start, as if drawn anywhere.
    static var mixed: [Nesting.Part] {
        var parts: [Nesting.Part] = []
        for i in 0..<4 { parts.append(Nesting.Part(outlines: [rect(120, 60, at: Vec2(Double(i) * 200, 900))])) }
        for i in 0..<4 { parts.append(Nesting.Part(outlines: [ell(140, 100, 30, at: Vec2(Double(i) * 200, 1100))])) }
        for i in 0..<4 { parts.append(Nesting.Part(outlines: [triangle(110, 80, at: Vec2(Double(i) * 200, 1300))])) }
        for i in 0..<3 { parts.append(Nesting.Part(outlines: [circle(35, at: Vec2(Double(i) * 200, 1500))])) }
        return parts
    }

    static let sheet = Rect2(x: 0, y: 0, width: 600, height: 400)

    static func settings(_ rotation: Nesting.Rotation = .quarterTurns, grain: Bool = false, evaluations: Int = 30,
                         spacing: Double = 6, margin: Double = 10) -> Nesting.Settings {
        Nesting.Settings(spacing: spacing, edgeMargin: margin, rotation: rotation, keepGrain: grain, timeLimit: 3600, seed: 7,
                         maxEvaluations: evaluations)
    }

    static func placedOutlines(_ parts: [Nesting.Part], _ result: Nesting.Result) -> [(Int, [Polyline])] {
        parts.indices.compactMap { i in result.placements[i].map { p in (i, parts[i].outlines.map(p.apply)) } }
    }

    /// Area two outline sets share when the first is grown by `grow`, mm².
    static func overlap(_ a: [Polyline], _ b: [Polyline], grow: Double) -> Double {
        let grown = grow > 0 ? Clipper.offset(a, delta: grow, arcTolerance: 0.001) : a
        return Clipper.intersection(grown, b).reduce(0) { $0 + abs($1.signedArea) }
    }

    /// The smallest gap between any two placed parts, by growing each pair until it overlaps (to 0.05 mm).
    static func checkSpacing(_ parts: [Nesting.Part], _ result: Nesting.Result, spacing: Double) -> [String] {
        let placed = placedOutlines(parts, result)
        var bad: [String] = []
        for x in placed.indices {
            for y in placed.indices where y > x {
                let a = placed[x].1, b = placed[y].1
                if overlap(a, b, grow: 0) > 1e-6 { bad.append("parts \(placed[x].0) and \(placed[y].0) overlap") }
                if overlap(a, b, grow: spacing - 0.02) > 1e-6 { bad.append("parts \(placed[x].0) and \(placed[y].0) closer than \(spacing)") }
            }
        }
        return bad
    }

    static func checkMargin(_ parts: [Nesting.Part], _ result: Nesting.Result, sheet: Rect2, margin: Double) -> [String] {
        let usable = sheet.insetBy(margin - 0.001)
        return placedOutlines(parts, result).compactMap { i, o in
            let b = o.bounds
            return usable.contains(b.min) && usable.contains(b.max) ? nil : "part \(i) is outside the margin: \(b)"
        }
    }

    /// Naïve layout: parts in rows across the sheet by their bounding boxes, as drawn, no turns.
    static func rowLayoutLength(_ parts: [Nesting.Part], sheet: Rect2, spacing: Double, margin: Double) -> Double? {
        let usable = sheet.insetBy(margin)
        var x = usable.min.x, y = usable.min.y, rowHeight = 0.0, farthest = 0.0
        // Rows run along the short side so the used length is comparable: here the sheet is wider than tall, so rows
        // go up the sheet (columns).
        for part in parts {
            let b = part.bounds
            if y + b.height > usable.max.y + 1e-9 {
                x += rowHeight + spacing
                y = usable.min.y
                rowHeight = 0
            }
            if x + b.width > usable.max.x + 1e-9 { return nil }
            farthest = max(farthest, x + b.width)
            y += b.height + spacing
            rowHeight = max(rowHeight, b.width)
        }
        return farthest - sheet.min.x
    }
}

struct MinkowskiTests {
    @Test func convexSumOfTwoSquaresIsTheBiggerSquare() throws {
        let sum = Clipper.minkowskiSum(NestFixture.rect(10, 10), NestFixture.rect(4, 4))
        #expect(sum.count == 1)
        let loop = try #require(sum.first)
        #expect(abs(loop.area - 196) < 1e-6)
        #expect(loop.bounds.min.isApprox(Vec2(-7, -7), tolerance: 1e-9))
    }

    @Test func nonConvexSumMatchesTheSumOfItsConvexPieces() throws {
        // The L is two rectangles; its sum with a square is the union of their sums.
        let l = NestFixture.ell(100, 80, 20)
        let sq = NestFixture.rect(10, 10)
        let sum = Clipper.minkowskiSum(l, sq)
        let pieces = [Polyline([Vec2(0, 0), Vec2(100, 0), Vec2(100, 20), Vec2(0, 20)], closed: true),
                      Polyline([Vec2(0, 0), Vec2(20, 0), Vec2(20, 80), Vec2(0, 80)], closed: true)]
        let expected = Clipper.union(pieces.flatMap { Clipper.minkowskiSum($0, sq) })
        let a = sum.reduce(0) { $0 + $1.signedArea }, b = expected.reduce(0) { $0 + $1.signedArea }
        #expect(abs(a - b) < 1e-3)
        let xor = Clipper.boolean(.xor, subjects: sum, clips: expected).reduce(0) { $0 + $1.area }
        #expect(xor < 1e-3)
    }

    /// Awkward outlines: concave arcs, a star, a letter with a curved inside, an L, a disc, a long thin bar.
    static var awkward: [Polyline] {
        let bracket = Polyline([Vec2(0, 0), Vec2(60, 0)] + Curves.arc(center: Vec2(60, 60), radius: 48, startAngle: 1.5 * .pi,
                                                                   sweep: -.pi / 2, tolerance: 0.05) + [Vec2(0, 60)], closed: true).deduplicated()
        let star = Polyline((0..<14).map { i in Vec2.fromAngle(.pi / 2 + .pi * Double(i) / 7, length: i % 2 == 0 ? 40 : 18) }, closed: true)
        let letter = TextOutliner.outlines(for: TextSpec(string: "S", capHeight: 60), tolerance: 0.05).max { $0.area < $1.area }!
        return [bracket, star, letter, NestFixture.ell(70, 50, 15), NestFixture.circle(20), NestFixture.rect(120, 8)]
    }

    /// The convolution (one loop per pair, positive winding) gives the same sum as unioning every pair of convex pieces,
    /// and as Clipper2's quads, for every pair of awkward outlines both ways round.
    @Test func convolutionMatchesTheSumOfConvexPieces() throws {
        let shapes = Self.awkward
        for (i, a) in shapes.enumerated() {
            for (j, b) in shapes.enumerated() {
                let pa = try #require(Clipper.convexPieces([a])), pb = try #require(Clipper.convexPieces([b]))
                let fast = Clipper.minkowskiSum(a, b)
                let exact = Clipper.minkowskiSum(pieces: pa, pb)
                let quads = Clipper.minkowskiSumQuads(a, b)
                // Rounding to Clipper's 0.1 µm grid moves edges by up to that: allow it along the whole boundary.
                let rounding = exact.reduce(0) { $0 + $1.length } * 1e-4
                let xor = Clipper.boolean(.xor, subjects: fast, clips: exact).reduce(0) { $0 + $1.area }
                #expect(xor < rounding, "shapes \(i) and \(j): \(xor) mm² differ")
                let xorQuads = Clipper.boolean(.xor, subjects: fast, clips: quads).reduce(0) { $0 + $1.area }
                #expect(xorQuads < rounding, "shapes \(i) and \(j) against the quads: \(xorQuads) mm² differ")
            }
        }
    }

    @Test func convexPiecesCoverTheOutlineExactly() throws {
        for (i, shape) in Self.awkward.enumerated() {
            let pieces = try #require(Clipper.convexPieces([shape]))
            let union = Clipper.union(pieces.map { Polyline($0, closed: true) })
            let xor = Clipper.boolean(.xor, subjects: union, clips: [shape]).reduce(0) { $0 + $1.area }
            #expect(xor < 1e-6, "shape \(i)")
            let convex = pieces.allSatisfy { Clipper.strictlyConvex($0) != nil }
            #expect(convex, "shape \(i)")
        }
    }

    /// A part touching another along its no-fit polygon's edge doesn't overlap it; moved just inside, it does.
    @Test func noFitPolygonEdgeTouchesWithoutOverlap() throws {
        let fixed = NestFixture.ell(100, 80, 20)
        let moving = NestFixture.triangle(30, 30, at: Vec2(-10, -10))
        let nfp = Clipper.minkowskiSum(fixed, Polyline(moving.points.map { -$0 }, closed: true))
        let outer = try #require(nfp.max { $0.area < $1.area })
        for p in outer.points {
            let placed = moving.transformed(.translation(p))
            #expect(NestFixture.overlap([fixed], [placed], grow: 0) < 1e-3)
        }
        // The L's inside corner: a point of the no-fit polygon's edge there, then a little toward the corner.
        let corner = Vec2(20, 20)
        let nearest = outer.closestPoint(to: corner + Vec2(15, 15)).point
        let inside = nearest + (corner - nearest).normalized * 0.5
        #expect(outer.contains(inside))
        #expect(NestFixture.overlap([fixed], [moving.transformed(.translation(inside))], grow: 0) > 1e-3)
    }
}

struct NestingEngineTests {
    @Test func partsNeverOverlapAndKeepTheSpacingAndEdgeMargin() throws {
        let parts = NestFixture.mixed
        let settings = NestFixture.settings()
        let result = Nesting.nest(parts, sheet: NestFixture.sheet, settings: settings)
        #expect(result.placedCount == parts.count)
        let spacing = NestFixture.checkSpacing(parts, result, spacing: settings.spacing)
        #expect(spacing.isEmpty, "\(spacing)")
        let margin = NestFixture.checkMargin(parts, result, sheet: NestFixture.sheet, margin: settings.edgeMargin)
        #expect(margin.isEmpty, "\(margin)")
        let problems = Nesting.violations(parts, placements: result.placements, sheet: NestFixture.sheet, settings: settings)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func aPartsOwnReachKeepsOthersFurtherAway() throws {
        // Two squares, one whose toolpaths reach 25 mm outside it (lead-ins, say), with 5 mm spacing.
        let parts = [Nesting.Part(outlines: [NestFixture.rect(50, 50)], reach: 25),
                     Nesting.Part(outlines: [NestFixture.rect(50, 50, at: Vec2(200, 0))])]
        let settings = NestFixture.settings(.none, spacing: 5, margin: 0)
        let result = Nesting.nest(parts, sheet: Rect2(x: 0, y: 0, width: 300, height: 60), settings: settings)
        #expect(result.placedCount == 2)
        let placed = NestFixture.placedOutlines(parts, result)
        let a = try #require(placed.first { $0.0 == 0 }?.1), b = try #require(placed.first { $0.0 == 1 }?.1)
        #expect(NestFixture.overlap(a, b, grow: 24.9) < 1e-6)
        // And no further than it needs: side by side, 25 mm apart.
        let gap = abs(a.bounds.center.x - b.bounds.center.x) - 50
        #expect(abs(gap - 25) < 0.3, "gap \(gap)")
    }

    static let turnCases: [(Nesting.Rotation, Bool, [Double])] = [
        (.none, false, [0]), (.quarterTurns, false, [0, 90, 180, 270]), (.quarterTurns, true, [0, 180]),
        (.steps(6), false, [0, 60, 120, 180, 240, 300]), (.steps(6), true, [0, 180]), (.steps(5), true, [0]),
    ]

    @Test(arguments: NestingEngineTests.turnCases)
    func onlyAllowedTurnsAreUsed(rotation: Nesting.Rotation, grain: Bool, allowed: [Double]) throws {
        #expect(rotation.angles(keepGrain: grain) == allowed)
        let parts = NestFixture.mixed
        let result = Nesting.nest(parts, sheet: NestFixture.sheet, settings: NestFixture.settings(rotation, grain: grain, evaluations: 20))
        let used = Set(result.placements.compactMap { $0?.rotation })
        #expect(used.isSubset(of: Set(allowed)), "\(used)")
        #expect(result.placedCount > 0)
    }

    @Test func aPartFitsOnlyWhenItMayTurn() throws {
        // 300 × 40 doesn't fit a 100 × 400 sheet lying down, does standing up, and the grain keeps it lying down.
        let part = [Nesting.Part(outlines: [NestFixture.rect(300, 40)])]
        let sheet = Rect2(x: 0, y: 0, width: 100, height: 400)
        let fixed = Nesting.nest(part, sheet: sheet, settings: NestFixture.settings(.none, margin: 5))
        #expect(fixed.placedCount == 0)
        let turned = Nesting.nest(part, sheet: sheet, settings: NestFixture.settings(.quarterTurns, margin: 5))
        #expect(turned.placedCount == 1)
        let angle = try #require(turned.placements[0]?.rotation)
        #expect(angle == 90 || angle == 270)
        let grain = Nesting.nest(part, sheet: sheet, settings: NestFixture.settings(.quarterTurns, grain: true, margin: 5))
        #expect(grain.placedCount == 0)
        #expect(grain.unplaced == [0])
    }

    @Test func aPartExactlyTheSheetsSizeFits() throws {
        let part = [Nesting.Part(outlines: [NestFixture.rect(200, 100, at: Vec2(500, 500))])]
        let result = Nesting.nest(part, sheet: Rect2(x: 0, y: 0, width: 220, height: 120), settings: NestFixture.settings(.none, margin: 10))
        #expect(result.placedCount == 1)
        let p = try #require(result.placements[0])
        #expect(p.position.isApprox(Vec2(110, 60), tolerance: 1e-3))
    }

    @Test func clampsAreAvoided() throws {
        // Clamps along the bottom edge and one in the middle of the sheet.
        let clamps = [NestFixture.rect(60, 40, at: Vec2(60, 30)), NestFixture.rect(60, 40, at: Vec2(300, 30)),
                      NestFixture.rect(40, 40, at: Vec2(300, 200))]
        let obstacles = clamps.map { Nesting.Obstacle(outlines: [$0]) }
        let parts = NestFixture.mixed
        let settings = NestFixture.settings()
        let result = Nesting.nest(parts, sheet: NestFixture.sheet, obstacles: obstacles, settings: settings)
        #expect(result.placedCount >= parts.count - 2)
        for (i, outlines) in NestFixture.placedOutlines(parts, result) {
            let near = NestFixture.overlap(outlines, clamps, grow: settings.spacing - 0.02)
            #expect(near < 1e-6, "part \(i) is within the spacing of a clamp")
        }
        let problems = Nesting.violations(parts, placements: result.placements, sheet: NestFixture.sheet, obstacles: obstacles,
                                          settings: settings)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func beatsANaiveRowLayout() throws {
        // Brackets and gussets: Ls and triangles nest into each other; boxes round them don't.
        var parts: [Nesting.Part] = []
        for i in 0..<8 { parts.append(Nesting.Part(outlines: [NestFixture.ell(150, 110, 35, at: Vec2(Double(i) * 200, 900))])) }
        for i in 0..<8 { parts.append(Nesting.Part(outlines: [NestFixture.triangle(120, 90, at: Vec2(Double(i) * 200, 1200))])) }
        let sheet = Rect2(x: 0, y: 0, width: 1200, height: 600)
        let settings = NestFixture.settings(evaluations: 40)
        let result = Nesting.nest(parts, sheet: sheet, settings: settings)
        #expect(result.placedCount == parts.count)
        let naive = try #require(NestFixture.rowLayoutLength(parts, sheet: sheet, spacing: settings.spacing, margin: settings.edgeMargin))
        let naiveUtilization = result.placedArea / (naive * sheet.height)
        #expect(result.usedLength < 0.8 * naive, "nested \(result.usedLength) mm, rows \(naive) mm")
        #expect(result.utilization > naiveUtilization)
        let problems = Nesting.violations(parts, placements: result.placements, sheet: sheet, settings: settings)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func theSearchImprovesOnTheFirstLayout() throws {
        let parts = NestFixture.mixed
        let first = Nesting.nest(parts, sheet: NestFixture.sheet, settings: NestFixture.settings(evaluations: 1))
        let searched = Nesting.nest(parts, sheet: NestFixture.sheet, settings: NestFixture.settings(evaluations: 60))
        #expect(searched.fitness <= first.fitness)
        #expect(searched.evaluations == 60)
    }

    @Test func theSameSeedGivesTheSameLayout() throws {
        let parts = NestFixture.mixed
        let a = Nesting.nest(parts, sheet: NestFixture.sheet, settings: NestFixture.settings(evaluations: 40))
        let b = Nesting.nest(parts, sheet: NestFixture.sheet, settings: NestFixture.settings(evaluations: 40))
        #expect(a.placements == b.placements)
        #expect(a.fitness == b.fitness)
    }

    @Test func partsThatDontFitAreReported() throws {
        // Twelve 100 × 100 squares; a 340 × 340 sheet (10 mm margin, 6 mm spacing) holds nine.
        let parts = (0..<12).map { Nesting.Part(outlines: [NestFixture.rect(100, 100, at: Vec2(Double($0) * 150, 1000))]) }
        let result = Nesting.nest(parts, sheet: Rect2(x: 0, y: 0, width: 340, height: 340), settings: NestFixture.settings(evaluations: 10))
        #expect(result.placedCount == 9)
        #expect(result.unplaced.count == 3)
        #expect(abs(result.sheetUtilization - 90_000 / (340.0 * 340)) < 1e-6)
    }

    @Test func stoppingKeepsTheBestLayoutSoFar() throws {
        let parts = NestFixture.mixed
        let result = Nesting.nest(parts, sheet: NestFixture.sheet, settings: NestFixture.settings(evaluations: 1000), shouldStop: { true })
        #expect(result.evaluations == 1)
        #expect(result.placedCount == parts.count)
    }
}

struct NestPartsTests {
    static func project(_ shapes: [DesignShape], _ ops: [CAMOperation] = [], stock: Stock = Stock(width: 600, height: 400, thickness: 18)) -> Project {
        Fixture.project(shapes: shapes, ops: ops, stock: stock)
    }

    static func through(_ shapes: [DesignShape], leads: LeadSettings? = nil) -> CAMOperation {
        CutFixture.profile(shapes, depth: DepthSettings(cutDepth: 18.5, passDepth: 6), leads: leads)
    }

    @Test func aPartIsAnOutlineAndEverythingInsideIt() throws {
        let panel = Fixture.rect(200, 100, at: Vec2(150, 100))
        let hole = DesignShape(kind: .circle(radius: 10), position: Vec2(100, 100))
        let label = DesignShape(kind: .text(TextSpec(string: "A", capHeight: 30)), position: Vec2(180, 100))
        let other = Fixture.rect(80, 80, at: Vec2(450, 300))
        let parts = NestJob.parts(of: Self.project([panel, hole, label, other]))
        #expect(parts.count == 2)
        let first = try #require(parts.first { $0.shapeIDs.contains(panel.id) })
        #expect(Set(first.shapeIDs) == Set([panel.id, hole.id, label.id]))
        #expect(first.outlines.count == 1)
        #expect(abs(first.area - 20_000) < 1)
    }

    @Test func anImportedShapeOfSeveralOutlinesIsSeveralParts() throws {
        // One shape (a DXF layer) holding three panels, one with a hole and a line engraved inside it.
        let paths = [NestFixture.rect(100, 50, at: Vec2(-150, 0)), NestFixture.circle(10, at: Vec2(-150, 0)),
                     Polyline([Vec2(-180, -10), Vec2(-120, -10)], closed: false),
                     NestFixture.rect(60, 60, at: Vec2(0, 0)), NestFixture.ell(80, 80, 20, at: Vec2(100, -40))]
        let shape = DesignShape(kind: .paths(paths), position: Vec2(300, 200))
        let parts = NestJob.parts(of: Self.project([shape]))
        #expect(parts.count == 3)
        let pieces = parts.map { $0.pieces.first?.paths ?? [] }.sorted { $0.first ?? 0 < $1.first ?? 0 }
        #expect(pieces == [[0, 1, 2], [3], [4]])
    }

    @Test func holesAndTextMoveWithTheirPart() throws {
        let panel = Fixture.rect(200, 100, at: Vec2(400, 300))
        let hole = DesignShape(kind: .circle(radius: 10), position: Vec2(340, 290))
        let label = DesignShape(kind: .text(TextSpec(string: "B", capHeight: 30)), position: Vec2(440, 300))
        let project = Self.project([panel, hole, label], [Self.through([panel]), CutFixture.pocket([hole])])
        let job = try NestJob.prepare(project, selection: [])
        let result = job.nest(NestFixture.settings())
        #expect(result.placedCount == 1)
        let moved = job.apply(result, to: project, settings: NestFixture.settings()).project
        let p = try #require(result.placements[0])
        for (before, after) in zip(project.shapes, moved.shapes) {
            let expected = before.polylines().map(p.apply)
            let got = after.polylines()
            let d = zip(expected.flatMap(\.points), got.flatMap(\.points)).map { $0.distance(to: $1) }.max() ?? 0
            #expect(d < 1e-6, "\(before.name) moved \(d) mm away from where the part took it")
        }
        // It went to the sheet's lower left corner, a margin in.
        let b = moved.shapes[0].bounds
        #expect(abs(b.min.x - 10) < 0.01 && abs(b.min.y - 10) < 0.01, "\(b)")
    }

    @Test func toolpathsFollowTheirShapes() throws {
        let a = Fixture.rect(100, 60, at: Vec2(450, 300)), b = Fixture.rect(80, 80, at: Vec2(300, 200))
        let project = Self.project([a, b], [Self.through([a, b])])
        let job = try NestJob.prepare(project, selection: [])
        var settings = job.defaultSettings
        settings.maxEvaluations = 10
        let applied = job.apply(job.nest(settings), to: project, settings: settings).project
        let tp = try #require(CAMEngine.generate(applied).toolpaths.first)
        let ext = try #require(tp.cuttingExtents)
        let shapes = applied.shapes.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
        let r = Fixture.endMill.radius
        #expect(abs(ext.min.x - (shapes.min.x - r)) < 0.05 && abs(ext.min.y - (shapes.min.y - r)) < 0.05)
        #expect(abs(ext.max.x - (shapes.max.x + r)) < 0.05 && abs(ext.max.y - (shapes.max.y + r)) < 0.05)
    }

    @Test func reachCountsTheBitButNotLeadInsWhichKeepClearByThemselves() throws {
        let a = Fixture.rect(100, 60, at: Vec2(150, 150)), b = Fixture.rect(80, 80, at: Vec2(400, 200))
        let plain = Self.through([a]), leads = Self.through([b], leads: CutFixture.arc)
        let project = Self.project([a, b], [plain, leads])
        let d = Fixture.endMill.diameter, r = CutFixture.arc.radius
        // Measured with them, the lead-ins reach d + r, or a little more beside a corner.
        let reach = NestJob.reach(of: CAMEngine.generate(project).toolpaths, in: project)
        let plainReach = try #require(reach[plain.id]), leadReach = try #require(reach[leads.id])
        #expect(abs(plainReach - d) < 0.05, "\(plainReach)")
        #expect(leadReach > d + r - 0.05 && leadReach < d + 2 * r, "\(leadReach) vs \(d + r)")
        // Nesting measures without them (they're shortened or left off near another part), and notes their full reach.
        let job = try NestJob.prepare(project, selection: [])
        #expect(abs(job.defaultSpacing - (d + 3)) < 1e-9)
        let first = try #require(job.parts.first { $0.shapeIDs == [a.id] })
        let second = try #require(job.parts.first { $0.shapeIDs == [b.id] })
        #expect(abs(first.reach - d) < 0.05 && abs(second.reach - d) < 0.05, "\(first.reach), \(second.reach)")
        #expect(first.leadReach == nil)
        #expect(second.leadToolpath == leads.name)
        #expect(abs((second.leadReach ?? 0) - (d + r)) < 1e-9)
        // A toolpath that's turned off still counts: it's usually cut in another run.
        var off = project
        off.operations[0].enabled = false
        let offJob = try NestJob.prepare(off, selection: [])
        let offPart = try #require(offJob.parts.first { $0.shapeIDs == [a.id] })
        #expect(abs(offPart.reach - d) < 0.05, "\(offPart.reach)")
    }

    /// 3D toolpaths count as well: on the relief demo each toolpath's reach is at least how far its cutting extents
    /// pass the medallion's outline (plus the bit's radius), and the part keeps the furthest of them.
    @Test func reachCounts3DToolpaths() throws {
        let project = Project.demoRelief()
        let toolpaths = NestJob.reachToolpaths(project)
        let reach = NestJob.reach(of: toolpaths, in: project)
        let outline = project.shapes[1].bounds
        for tp in toolpaths {
            let ext = try #require(tp.cuttingExtents)
            let past = max(outline.min.x - ext.min.x, outline.min.y - ext.min.y, ext.max.x - outline.max.x, ext.max.y - outline.max.y)
            let measured = try #require(reach[tp.sourceOperationID])
            #expect(measured >= past + tp.tool.radius - 0.01, "\(tp.name): \(measured) vs \(past + tp.tool.radius)")
        }
        let job = try NestJob.prepare(project, selection: [], toolpaths: toolpaths)
        #expect(job.parts.count == 1)
        let part = try #require(job.parts.first)
        let furthest = try #require(reach.values.max())
        #expect(abs(part.reach - furthest) < 1e-9)
        #expect(job.parts.first?.shapeIDs.count == 2)
    }

    /// Nested closer than their lead-ins reach, parts still aren't cut into: the lead-ins are shortened or left off.
    @Test func tightlyNestedPartsWithLeadInsAreNotCutInto() throws {
        // Six 40 mm squares drawn off the sheet (so none of their lead-ins fit where they are), cut out with arc
        // lead-ins and nested at the bit's width plus 1 mm.
        let squares = (0..<6).map { i in Fixture.rect(40, 40, at: Vec2(30 + Double(i) * 60, 250)) }
        let project = Self.project(squares, [CutFixture.profile(squares, leads: CutFixture.arc)],
                                   stock: Stock(width: 200, height: 150, thickness: 18))
        let job = try NestJob.prepare(project, selection: [])
        var settings = job.defaultSettings
        settings.spacing = Fixture.endMill.diameter + 1
        settings.edgeMargin = 5
        settings.maxEvaluations = 5
        let result = job.nest(settings)
        #expect(result.placedCount == 6)
        let nested = job.apply(result, to: project, settings: settings).project
        let grid = Fixture.simulate(CAMEngine.generate(nested).toolpaths, stock: nested.stock, cell: 0.25)
        let outlines = nested.shapes.compactMap { $0.polylines().first }
        let cut = CutFixture.cells(grid).filter { p, h in
            h < -1e-6 && outlines.contains { $0.contains(p) && $0.closestPoint(to: p).distance > 0.3 }
        }.count
        #expect(cut == 0, "\(cut) cells of the parts were cut")
    }

    @Test func onlyTheSelectedPartsMoveAndTheOthersAreAvoided() throws {
        let stay = Fixture.rect(100, 100, at: Vec2(60, 60))
        let clamp = { var s = Fixture.rect(40, 40, at: Vec2(200, 30)); s.keepOutHeight = 20; return s }()
        let movers = (0..<4).map { Fixture.rect(70, 50, at: Vec2(450, 80 + Double($0) * 70)) }
        let hole = DesignShape(kind: .circle(radius: 5), position: Vec2(450, 80))
        let project = Self.project([stay, clamp, hole] + movers, [Self.through([stay] + movers)])
        // Selecting the hole picks its part.
        let job = try NestJob.prepare(project, selection: Set([hole.id] + movers.dropFirst().map(\.id)))
        #expect(job.parts.count == 4)
        #expect(job.fixed.count == 1)
        #expect(job.keepOuts.count == 1)
        var settings = job.defaultSettings
        settings.maxEvaluations = 10
        let result = job.nest(settings)
        #expect(result.placedCount == 4)
        let applied = job.apply(result, to: project, settings: settings).project
        #expect(applied.shapes[0] == project.shapes[0])
        #expect(applied.shapes[1] == project.shapes[1])
        let fixedOutline = [NestFixture.rect(100, 100, at: Vec2(60, 60))], clampOutline = [NestFixture.rect(40, 40, at: Vec2(200, 30))]
        for mover in applied.shapes.suffix(4) {
            let o = mover.polylines()
            #expect(NestFixture.overlap(o, fixedOutline, grow: settings.spacing - 0.02) < 1e-6)
            #expect(NestFixture.overlap(o, clampOutline, grow: settings.spacing - 0.02) < 1e-6)
        }
    }

    @Test func partsThatDontFitStayOrGoBesideTheSheet() throws {
        // Ten 100 mm squares, drawn in rows of three; a 340 mm sheet holds nine. If where the odd one out was drawn is
        // now taken, it goes beside the sheet; otherwise it stays.
        let squares = (0..<10).map { i in
            var s = Fixture.rect(100, 100, at: Vec2(60 + Double(i % 3) * 105, 60 + Double(i / 3) * 105))
            s.name = "Square \(i + 1)"
            return s
        }
        let project = Self.project(squares, [], stock: Stock(width: 340, height: 340, thickness: 18))
        let job = try NestJob.prepare(project, selection: [], toolpaths: [])
        var settings = job.defaultSettings
        settings.spacing = 6
        settings.edgeMargin = 10
        settings.maxEvaluations = 5
        let result = job.nest(settings)
        #expect(result.placedCount == 9)
        let applied = job.apply(result, to: project, settings: settings)
        #expect(applied.movedAside.count + applied.leftInPlace.count == 1)
        for name in applied.movedAside {
            let i = try #require(job.parts.firstIndex { $0.name == name })
            let shape = try #require(applied.project.shapes.first { $0.id == job.parts[i].shapeIDs[0] })
            #expect(shape.bounds.min.x > 340, "\(shape.bounds)")
        }
    }

    @Test func rotaryJobsAreRefused() throws {
        var project = Self.project([Fixture.rect(50, 50, at: Vec2(100, 100))])
        project.stock.rotary = RotaryStock()
        #expect(throws: NestJob.Refusal.rotary) { try NestJob.prepare(project, selection: [], toolpaths: []) }
    }

    @Test func turningAPartTurnsEveryShapeInIt() throws {
        let panel = Fixture.rect(200, 50, at: Vec2(300, 200))
        let hole = DesignShape(kind: .circle(radius: 8), position: Vec2(230, 200))
        let motion = RigidMotion(pivot: Vec2(300, 200), rotation: 90, position: Vec2(100, 150))
        let moved = [panel, hole].map { $0.moved(motion) }
        #expect(moved[0].bounds.size.isApprox(Vec2(50, 200), tolerance: 1e-6))
        #expect(moved[1].position.isApprox(Vec2(100, 80), tolerance: 1e-9))
        #expect(moved[0].rotation == 90)
    }

    @Test func cornerChoicesOnASplitShapeMoveWithTheirVectors() throws {
        let paths = [NestFixture.rect(100, 50, at: Vec2(-100, 0)), NestFixture.rect(60, 60, at: Vec2(100, 0))]
        let shape = DesignShape(kind: .paths(paths), position: Vec2(300, 200))
        let corner = Vec2(130, 30)
        var op = Self.through([shape])
        if case var .profile(p) = op.kind {
            p.cornerRelief = CornerReliefSettings(overrides: [CornerOverride(shapeID: shape.id, point: corner, choice: .asCut)])
            op.kind = .profile(p)
        }
        let project = Self.project([shape], [op])
        let job = try NestJob.prepare(project, selection: [], toolpaths: [])
        #expect(job.parts.count == 2)
        let result = job.nest(NestFixture.settings())
        let applied = job.apply(result, to: project, settings: NestFixture.settings()).project
        guard case let .paths(after) = applied.shapes[0].kind, case let .profile(q) = applied.operations[0].kind else {
            Issue.record("shape or toolpath changed kind")
            return
        }
        let point = try #require(q.cornerRelief?.overrides?.first?.point)
        let onTheSquare = after[1].closestPoint(to: point).distance
        #expect(onTheSquare < 1e-6)
        let squareCorners = after[1].points.map { $0.distance(to: point) }.min() ?? 1
        #expect(squareCorners < 1e-6)
    }
}
