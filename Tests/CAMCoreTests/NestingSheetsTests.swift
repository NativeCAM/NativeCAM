import Foundation
import Testing
@testable import CAMCore

/// Nesting onto more than one sheet, and parts in other parts' holes (#86).
struct NestingSheetsTests {
    static func squares(_ n: Int, size: Double = 100) -> [Nesting.Part] {
        (0..<n).map { i in Nesting.Part(outlines: [NestFixture.rect(size, size, at: Vec2(Double(i) * 150, 900))]) }
    }

    static let small = Rect2(x: 0, y: 0, width: 340, height: 340)

    static func settings(sheets: Int, evaluations: Int = 10, spacing: Double = 6, margin: Double = 10) -> Nesting.Settings {
        var s = NestFixture.settings(evaluations: evaluations, spacing: spacing, margin: margin)
        s.maxSheets = sheets
        return s
    }

    /// Pairs on the same sheet that overlap or come closer than `spacing`, and parts outside their sheet's margin.
    static func problems(_ parts: [Nesting.Part], _ r: Nesting.Result, sheet: Rect2, settings: Nesting.Settings) -> [String] {
        var bad: [String] = []
        let placed = NestFixture.placedOutlines(parts, r)
        for x in placed.indices {
            for y in placed.indices where y > x && r.placements[placed[x].0]?.sheet == r.placements[placed[y].0]?.sheet {
                if NestFixture.overlap(placed[x].1, placed[y].1, grow: settings.spacing - 0.02) > 1e-6 {
                    bad.append("parts \(placed[x].0) and \(placed[y].0) closer than the spacing on one sheet")
                }
            }
            let k = r.placements[placed[x].0]?.sheet ?? 0
            let usable = settings.sheet(k, first: sheet).insetBy(settings.edgeMargin - 0.001)
            let b = placed[x].1.bounds
            if !(usable.contains(b.min) && usable.contains(b.max)) { bad.append("part \(placed[x].0) outside sheet \(k + 1)'s margin") }
        }
        return bad
    }

    // MARK: More sheets

    @Test func partsThatDontFitGoOnTheNextSheet() throws {
        let parts = Self.squares(12)
        let s = Self.settings(sheets: 3)
        let r = Nesting.nest(parts, sheet: Self.small, settings: s)
        #expect(r.placedCount == 12)
        #expect(r.sheetCount == 2)
        #expect(r.sheets.map(\.partCount) == [9, 3])
        #expect(Self.problems(parts, r, sheet: Self.small, settings: s).isEmpty)
        #expect(Nesting.violations(parts, placements: r.placements, sheet: Self.small, settings: s).isEmpty)
        // The last sheet's offcut is what's reported.
        let last = try #require(r.sheets.last)
        #expect(r.usedLength == last.usedLength && r.usedLength < 340)
    }

    @Test func theSheetLimitHolds() throws {
        let parts = Self.squares(25)
        let s = Self.settings(sheets: 2, evaluations: 4)
        let r = Nesting.nest(parts, sheet: Self.small, settings: s)
        #expect(r.sheetCount == 2)
        #expect(r.placedCount == 18)
        #expect(r.unplaced.count == 7)
        #expect(r.placements.compactMap { $0?.sheet }.allSatisfy { $0 < 2 })
        #expect(Self.problems(parts, r, sheet: Self.small, settings: s).isEmpty)
    }

    @Test func laterSheetsMayBeAnotherSize() throws {
        // A long part that only the bigger second sheet holds, and squares that fill the first.
        var parts = Self.squares(9)
        parts.append(Nesting.Part(outlines: [NestFixture.rect(450, 100, at: Vec2(0, 1500))]))
        var s = Self.settings(sheets: 3)
        s.rotation = .none
        s.nextSheetSize = Vec2(600, 340)
        let r = Nesting.nest(parts, sheet: Self.small, settings: s)
        #expect(r.placedCount == 10)
        #expect(r.placements[9]?.sheet == 1)
        #expect(r.sheets.count == 2 && abs(r.sheets[1].sheet.width - 600) < 1e-9)
        #expect(Self.problems(parts, r, sheet: Self.small, settings: s).isEmpty)
        #expect(Nesting.violations(parts, placements: r.placements, sheet: Self.small, settings: s).isEmpty)
    }

    @Test func layoutsOnOneSheetDontChangeWithMoreAllowed() throws {
        let parts = NestFixture.mixed
        let one = Nesting.nest(parts, sheet: NestFixture.sheet, settings: Self.settings(sheets: 1, evaluations: 30))
        let more = Nesting.nest(parts, sheet: NestFixture.sheet, settings: Self.settings(sheets: 4, evaluations: 30))
        #expect(one.sheetCount == 1 && more.sheetCount == 1)
        #expect(one.placements == more.placements)
        #expect(one.fitness == more.fitness)
    }

    @Test func clampsAreOnEverySheetAndPartsThatStayOnTheirOwn() throws {
        let parts = Self.squares(12)
        let clamp = Nesting.Obstacle(outlines: [NestFixture.rect(40, 40, at: Vec2(30, 30))])
        let staying = Nesting.Obstacle(outlines: [NestFixture.rect(100, 100, at: Vec2(290, 290))], sheet: 0)
        let s = Self.settings(sheets: 3)
        let r = Nesting.nest(parts, sheet: Self.small, obstacles: [clamp, staying], settings: s)
        #expect(Nesting.violations(parts, placements: r.placements, sheet: Self.small, obstacles: [clamp, staying], settings: s).isEmpty)
        // The part that stays put takes room on the first sheet only: the second has room for one more square.
        #expect(r.sheets.first?.partCount == 7)
        #expect(r.sheets.count == 2 && r.sheets[1].partCount == 5)
    }

    // MARK: Part in part

    /// A square frame `outer` across with a square window `inner` across, cut by a bit of `reach`.
    static func frame(_ outer: Double, _ inner: Double, at c: Vec2, reach: Double = 6.35, accepts: Set<Int>? = nil) -> Nesting.Part {
        Nesting.Part(outlines: [NestFixture.rect(outer, outer, at: c)], reach: reach,
                     holes: [Nesting.Hole(outline: NestFixture.rect(inner, inner, at: c), reach: reach, accepts: accepts)])
    }

    /// Whether part `inner` lies inside a hole of part `outer` with `gap` all round.
    static func keepsGap(_ parts: [Nesting.Part], _ r: Nesting.Result, inner: Int, outer: Int, gap: Double) throws -> Bool {
        let pi = try #require(r.placements[inner]), po = try #require(r.placements[outer])
        let grown = Clipper.offset(parts[inner].outlines.map(pi.apply), delta: gap - 0.02, arcTolerance: 0.001)
        let holes = parts[outer].holes.map { po.apply($0.outline) }
        return Clipper.difference(grown, minus: holes).reduce(0) { $0 + abs($1.signedArea) } < 1e-6
    }

    @Test func aSmallPartSitsInABigPartsHoleWithItsGap() throws {
        let parts = [Self.frame(200, 150, at: Vec2(500, 500)), Nesting.Part(outlines: [NestFixture.rect(60, 60, at: Vec2(800, 800))], reach: 6.35)]
        // A sheet only the frame fits on: the square has to go in its window.
        let sheet = Rect2(x: 0, y: 0, width: 220, height: 220)
        let s = Self.settings(sheets: 1, spacing: 8, margin: 5)
        let r = Nesting.nest(parts, sheet: sheet, settings: s)
        #expect(r.placedCount == 2)
        #expect(r.insideOf == [nil, 0])
        #expect(try Self.keepsGap(parts, r, inner: 1, outer: 0, gap: 8))
        #expect(Nesting.violations(parts, placements: r.placements, sheet: sheet, settings: s).isEmpty)
        // A hole whose own cut reaches further keeps the part further from its edge.
        var wide = parts
        wide[0].holes[0].reach = 15
        let w = Nesting.nest(wide, sheet: sheet, settings: s)
        #expect(w.insideOf == [nil, 0])
        #expect(try Self.keepsGap(wide, w, inner: 1, outer: 0, gap: 15))
        #expect(Nesting.violations(wide, placements: w.placements, sheet: sheet, settings: s).isEmpty)
    }

    @Test func aHoleOnlyTakesPartsCutBeforeItAndPartInPartCanBeOff() throws {
        let square = Nesting.Part(outlines: [NestFixture.rect(60, 60, at: Vec2(800, 800))], reach: 6.35, group: 1)
        let sheet = Rect2(x: 0, y: 0, width: 220, height: 220)
        let s = Self.settings(sheets: 1, spacing: 8, margin: 5)
        let refusing = [Self.frame(200, 150, at: Vec2(500, 500), accepts: [0]), square]
        #expect(Nesting.nest(refusing, sheet: sheet, settings: s).placements[1] == nil)
        let taking = [Self.frame(200, 150, at: Vec2(500, 500), accepts: [1]), square]
        #expect(Nesting.nest(taking, sheet: sheet, settings: s).insideOf == [nil, 0])
        var off = s
        off.partInPart = false
        #expect(Nesting.nest(taking, sheet: sheet, settings: off).placements[1] == nil)
        // A part in a hole is wrong once part in part is off.
        let r = Nesting.nest(taking, sheet: sheet, settings: s)
        #expect(!Nesting.violations(taking, placements: r.placements, sheet: sheet, settings: off).isEmpty)
    }

    @Test func partsGoInHolesOfPartsInHoles() throws {
        let parts = [Self.frame(300, 250, at: Vec2(1000, 1000)), Self.frame(200, 150, at: Vec2(500, 500)),
                     Nesting.Part(outlines: [NestFixture.rect(60, 60, at: Vec2(800, 800))], reach: 6.35)]
        let sheet = Rect2(x: 0, y: 0, width: 320, height: 320)
        let s = Self.settings(sheets: 1, spacing: 8, margin: 5)
        let r = Nesting.nest(parts, sheet: sheet, settings: s)
        #expect(r.placedCount == 3)
        #expect(r.insideOf == [nil, 0, 1])
        #expect(Nesting.violations(parts, placements: r.placements, sheet: sheet, settings: s).isEmpty)
    }

    @Test func theSameSeedGivesTheSameSheetsAndHoles() throws {
        var parts = Self.squares(10, size: 90)
        parts.append(Self.frame(300, 220, at: Vec2(2000, 0)))
        parts += (0..<4).map { Nesting.Part(outlines: [NestFixture.circle(30, at: Vec2(Double($0) * 100, 3000))]) }
        let s = Self.settings(sheets: 4, evaluations: 25)
        let a = Nesting.nest(parts, sheet: Self.small, settings: s)
        let b = Nesting.nest(parts, sheet: Self.small, settings: s)
        #expect(a.placements == b.placements)
        #expect(a.insideOf == b.insideOf)
        #expect(a.sheetCount == b.sheetCount)
        #expect(!a.inHoles.isEmpty)
        #expect(Nesting.violations(parts, placements: a.placements, sheet: Self.small, settings: s).isEmpty)
    }
}

/// Part in part and more sheets as Toolpaths ▸ Nest Parts finds the parts and moves them.
struct NestSheetsJobTests {
    static let stock = Stock(width: 340, height: 240, thickness: 18)

    /// A 300 × 200 panel with a 180 × 120 window (one imported shape, the window inside it) and an 80 × 60 square, all
    /// cut out through by one outside profile: it cuts the window from inside, after the square inside it.
    static func windowJob() -> (project: Project, panel: DesignShape, square: DesignShape) {
        let panel = DesignShape(kind: .paths([NestFixture.rect(300, 200), NestFixture.rect(180, 120)]), position: Vec2(160, 110))
        let square = Fixture.rect(80, 60, at: Vec2(600, 300))
        let cut = NestPartsTests.through([panel, square])
        return (Fixture.project(shapes: [panel, square], ops: [cut], stock: stock), panel, square)
    }

    @Test func aWindowCutFromInsideIsAHole() throws {
        let (project, panel, square) = Self.windowJob()
        let job = try NestJob.prepare(project, selection: [])
        let p = try #require(job.parts.first { $0.shapeIDs == [panel.id] })
        let q = try #require(job.parts.first { $0.shapeIDs == [square.id] })
        try #require(p.holes.count == 1)
        #expect(abs(p.holes[0].reach - Fixture.endMill.diameter) < 0.1, "\(p.holes[0].reach)")
        #expect(p.holes[0].accepts?.contains(q.group) == true)
        #expect(job.partsWithHoles == 1)
    }

    @Test func loopsCutFromOutsideDrilledOrNotThroughAreNoHoles() throws {
        // A part drawn inside another and cut out from outside.
        let panel = Fixture.rect(300, 200, at: Vec2(160, 110)), inner = Fixture.rect(180, 120, at: Vec2(160, 110))
        let outside = Fixture.project(shapes: [panel, inner], ops: [NestPartsTests.through([panel]), NestPartsTests.through([inner])], stock: Self.stock)
        #expect(try NestJob.prepare(outside, selection: []).parts.allSatisfy { $0.holes.isEmpty })
        // A window only cut part way down.
        let shallow = CutFixture.profile([inner], side: .inside, depth: DepthSettings(cutDepth: 6, passDepth: 6))
        let engraved = Fixture.project(shapes: [panel, inner], ops: [shallow, NestPartsTests.through([panel])], stock: Self.stock)
        #expect(try NestJob.prepare(engraved, selection: []).parts.allSatisfy { $0.holes.isEmpty })
        // A loop with only a hole drilled through it.
        let mark = DesignShape(kind: .circle(radius: 3), position: Vec2(160, 110))
        let drill = CAMOperation(name: "Drill", kind: .drill(DrillParams(depth: 19)), shapeIDs: [mark.id], tool: Fixture.endMill)
        let drilled = Fixture.project(shapes: [panel, inner, mark], ops: [drill, NestPartsTests.through([panel])], stock: Self.stock)
        #expect(try NestJob.prepare(drilled, selection: []).parts.allSatisfy { $0.holes.isEmpty })
    }

    @Test func theInnerPartIsCutOutFirstAndKeepsItsGap() throws {
        let (project, panel, square) = Self.windowJob()
        let job = try NestJob.prepare(project, selection: [])
        var s = job.defaultSettings
        s.maxEvaluations = 10
        let r = job.nest(s)
        #expect(r.placedCount == 2)
        #expect(r.inHoles.count == 1)
        #expect(job.check(r, settings: s).isEmpty)
        let applied = job.apply(r, to: project, settings: s)
        #expect(applied.inHoles == [square.name])
        #expect(applied.sheetCount == 1)
        let p = applied.project
        #expect(OperationScheduler.optimize(p).outOfOrder.isEmpty)
        // In the profile, the square's last cut at full depth comes before the window's first.
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let squareLine = try #require(p.shape(id: square.id)?.polylines().first)
        let window = try #require(p.shape(id: panel.id)?.polylines().last)
        let r0 = Fixture.endMill.radius
        var squareLast = -1, windowFirst = Int.max, index = 0
        tp.forEachMotion { start, m in
            defer { index += 1 }
            guard m.kind == .feed || m.kind.isArc, m.end.z < -17.9 else { return }
            if abs(squareLine.closestPoint(to: m.end.xy).distance - r0) < 0.05, !squareLine.contains(m.end.xy) { squareLast = index }
            if abs(window.closestPoint(to: m.end.xy).distance - r0) < 0.05, window.contains(m.end.xy) { windowFirst = min(windowFirst, index) }
        }
        #expect(squareLast >= 0 && windowFirst < Int.max)
        #expect(squareLast < windowFirst, "square's last full-depth cut \(squareLast), window's first \(windowFirst)")
        // And it sits a whole gap from the window's edge.
        let gap = Nesting.holeGap(s, job.parts[1].reach, job.parts[0].holes[0])
        let grown = Clipper.offset([squareLine], delta: gap - 0.02)
        #expect(Clipper.difference(grown, minus: [window]).reduce(0) { $0 + abs($1.signedArea) } < 1e-6)
    }

    @Test func aHoleCutBeforeTheInnerPartIsntUsed() throws {
        // The window is its own shape, cut by its own profile before the cut-out.
        let panel = Fixture.rect(300, 200, at: Vec2(160, 110)), window = Fixture.rect(180, 120, at: Vec2(160, 110))
        let square = Fixture.rect(80, 60, at: Vec2(600, 300))
        let cutWindow = CutFixture.profile([window], side: .inside, depth: DepthSettings(cutDepth: 18.5, passDepth: 6))
        let project = Fixture.project(shapes: [panel, window, square], ops: [cutWindow, NestPartsTests.through([panel, square])], stock: Self.stock)
        let job = try NestJob.prepare(project, selection: [])
        let p = try #require(job.parts.first { $0.shapeIDs.contains(panel.id) })
        let q = try #require(job.parts.first { $0.shapeIDs == [square.id] })
        try #require(p.holes.count == 1)
        #expect(p.holes[0].accepts?.contains(q.group) == false)
        var s = job.defaultSettings
        s.maxEvaluations = 5
        #expect(job.nest(s).placements[1] == nil)
        // Cut out first and the window after (the order the run-order check warns about): the square is cut before both.
        let swapped = Fixture.project(shapes: [panel, window, square], ops: [NestPartsTests.through([panel, square]), cutWindow], stock: Self.stock)
        let job2 = try NestJob.prepare(swapped, selection: [])
        let p2 = try #require(job2.parts.first { $0.shapeIDs.contains(panel.id) })
        #expect(p2.holes.first?.accepts?.contains(job2.parts.first { $0.shapeIDs == [square.id] }!.group) == true)
    }

    // MARK: Sheets in the project

    /// Twelve 100 mm squares on a sheet that holds nine, cut out by one profile.
    static func squaresJob() -> Project {
        let squares = (0..<12).map { i in
            var s = Fixture.rect(100, 100, at: Vec2(60 + Double(i % 3) * 105, 60 + Double(i / 3) * 105))
            s.name = "Square \(i + 1)"
            return s
        }
        var p = Fixture.project(shapes: squares, ops: [NestPartsTests.through(squares)], stock: Stock(width: 340, height: 340, thickness: 18))
        p.name = "Squares"
        return p
    }

    static func nested(_ project: Project, sheets: Int = 3, next: Vec2? = nil) throws -> NestJob.Applied {
        let job = try NestJob.prepare(project, selection: [])
        var s = job.defaultSettings
        s.spacing = 8
        s.edgeMargin = 10
        s.maxEvaluations = 5
        s.maxSheets = sheets
        s.nextSheetSize = next
        let r = job.nest(s)
        #expect(job.check(r, settings: s).isEmpty)
        return job.apply(r, to: project, settings: s)
    }

    @Test func partsThatDontFitGoOnANewSheetOfTheJob() throws {
        let applied = try Self.nested(Self.squaresJob())
        let p = applied.project
        #expect(applied.sheetCount == 2 && p.sheetCount == 2)
        #expect(applied.movedAside.isEmpty && applied.leftInPlace.isEmpty)
        #expect(p.shapes.filter { p.sheetIndex(of: $0) == 0 }.count == 9)
        #expect(p.shapes.filter { p.sheetIndex(of: $0) == 1 }.count == 3)
        #expect(p.additionalSheets == [MaterialSheet(width: 340, height: 340)])
        // Saved as format 14, and read back the same.
        #expect(p.formatVersion == 14)
        #expect(try Project.decode(p.encoded()) == p)
        // Each sheet is a job of its own: its shapes, and the profile on just those.
        let second = p.sheetProject(1)
        #expect(second.shapes.count == 3 && second.sheetCount == 1)
        #expect(Set(second.operations[0].shapeIDs) == Set(second.shapes.map(\.id)))
        #expect(second.name == "Squares - sheet 2 of 2")
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error })")
        #expect(job.sheets?.count == 2)
        #expect(job.toolpaths.map(\.sheet) == [0, 1])
        #expect(Set(job.toolpaths.map(\.id)).count == job.toolpaths.count)
        #expect(job.toolpaths.allSatisfy { $0.sourceOperationID == p.operations[0].id })
        #expect(job.issues.contains { $0.message.hasPrefix("Nested onto 2 sheets") })
    }

    @Test func eachSheetIsAFileInTravelWithItsNameAndASetupSheetPage() throws {
        let p = try Self.nested(Self.squaresJob()).project
        let job = CAMEngine.generate(p)
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        #expect(export.files.map(\.suffix) == [" - sheet 1 of 2", " - sheet 2 of 2"])
        #expect(export.files.map(\.sheet) == [0, 1])
        #expect(JobExport.fileNames(export.files, base: "Squares.tap", fileExtension: "tap")
            == ["Squares - sheet 1 of 2.tap", "Squares - sheet 2 of 2.tap"])
        for file in export.files {
            #expect(file.project.sheetCount == 1 && file.project.stock.width == 340)
            let issues = GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: file.project, dialect: .avidMach4)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
            // Every cut on the sheet, inside the machine's travel.
            let ext = try #require(SetupSheet.extents(file.toolpaths))
            #expect(ext.min.x >= 0 && ext.max.x <= p.machine.travel.x && ext.min.y >= 0 && ext.max.y <= p.machine.travel.y)
        }
        // An air cut is a file per sheet too.
        let air = try #require(JobExport.files(p, job: job, airCut: 25, date: GoldenPostTests.date))
        #expect(air.files.map(\.suffix) == [" (air cut) - sheet 1 of 2", " (air cut) - sheet 2 of 2"])
        // The setup sheet: the job, then a page for each sheet naming its file.
        let html = SetupSheet.html(project: p, job: job, gcodeFile: "Squares.tap", date: GoldenPostTests.date)
        #expect(html.components(separatedBy: "<section class=\"tile\">").count == 3)
        #expect(html.contains("Squares - sheet 1 of 2.tap") && html.contains("Squares - sheet 2 of 2.tap"))
        #expect(html.contains("<h1>Squares - sheet 2 of 2</h1>"))
    }

    @Test func aJobOfOneSheetIsUnchanged() throws {
        let p = Self.squaresJob()
        #expect(p.sheetCount == 1 && p.formatVersion == 1)
        let text = String(decoding: try p.encoded(), as: UTF8.self)
        #expect(!text.contains("additionalSheets") && !text.contains("\"sheet\""))
        let job = CAMEngine.generate(p)
        #expect(job.sheets == nil)
        #expect(job.toolpaths.allSatisfy { $0.sheet == nil })
        #expect(p.sheetProject(0) == p)
    }

    @Test func theRunOrderCheckKeepsSheetsApart() throws {
        // A panel on the first sheet and, where it would be inside it, a part on the second with its own cut-out
        // after the panel's: on different sheets, neither frees the other.
        var small = Fixture.rect(80, 60, at: Vec2(160, 110))
        small.sheet = 1
        let panel = Fixture.rect(300, 200, at: Vec2(160, 110))
        var p = Fixture.project(shapes: [panel, small], ops: [NestPartsTests.through([panel]), NestPartsTests.through([small])], stock: Self.stock)
        p.additionalSheets = [MaterialSheet(width: 340, height: 240)]
        #expect(OperationScheduler.optimize(p).outOfOrder.isEmpty)
        var one = p
        one.additionalSheets = []
        #expect(!OperationScheduler.optimize(one).outOfOrder.isEmpty)
    }

    @Test func anImportedShapeSplitAcrossSheetsKeepsItsToolpath() throws {
        // Twelve squares in one imported shape.
        let paths = (0..<12).map { i in NestFixture.rect(100, 100, at: Vec2(Double(i % 4) * 110, Double(i / 4) * 110)) }
        let shape = DesignShape(kind: .paths(paths), position: Vec2(200, 160))
        var project = Fixture.project(shapes: [shape], ops: [NestPartsTests.through([shape])], stock: Stock(width: 340, height: 340, thickness: 18))
        project.name = "Imported"
        let p = try Self.nested(project).project
        #expect(p.sheetCount == 2)
        #expect(p.shapes.count == 2)
        #expect(Set(p.operations[0].shapeIDs) == Set(p.shapes.map(\.id)))
        let pathCounts = p.shapes.map { s -> Int in if case let .paths(v) = s.kind { v.count } else { 0 } }
        #expect(pathCounts.sorted() == [3, 9])
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(job.sheets?.map { $0.job.toolpaths.count } == [1, 1])
    }

    @Test func nestingAgainOntoFewerSheetsDropsTheEmptyOnes() throws {
        var p = try Self.nested(Self.squaresJob()).project
        // Three squares fewer: everything fits on the first sheet again.
        let gone = Set(p.shapes.filter { p.sheetIndex(of: $0) == 1 }.map(\.id))
        p.shapes.removeAll { gone.contains($0.id) }
        p.operations[0].shapeIDs.removeAll { gone.contains($0) }
        let again = try Self.nested(p)
        #expect(again.sheetCount == 1 && again.project.additionalSheets.isEmpty)
        #expect(again.project.formatVersion == 1)
    }

    @Test func theFramesDemoNestsOntoTwoSheetsWithPartsInTheWindows() throws {
        let p = Project.demoNestingSheets()
        let job = try NestJob.prepare(p, selection: [])
        // The frames' windows take parts; the top's hand hold, cut by its own profile first, takes none.
        let frames = job.parts.filter { $0.name.hasPrefix("Frame") }
        #expect(frames.count == 2 && frames.allSatisfy { $0.holes.count == 1 && $0.holes[0].accepts?.isEmpty == false })
        let top = try #require(job.parts.first { $0.name == "Top" })
        #expect(top.holes.allSatisfy { $0.accepts?.isEmpty == true })
        var s = job.defaultSettings
        s.maxSheets = 3
        s.maxEvaluations = 20
        let r = job.nest(s)
        #expect(r.placedCount == job.parts.count)
        #expect(r.sheetCount == 2)
        #expect(!r.inHoles.isEmpty)
        #expect(r.inHoles.allSatisfy { r.insideOf[$0].map { job.parts[$0].name.hasPrefix("Frame") } ?? false })
        #expect(job.check(r, settings: s).isEmpty)
        let applied = job.apply(r, to: p, settings: s).project
        #expect(OperationScheduler.optimize(applied).outOfOrder.isEmpty)
        #expect(!CAMEngine.generate(applied).hasErrors)
    }

    // MARK: Saved two-sheet job

    /// The shelf demo on two 24" × 48" sheets, nested once and saved as format 14.
    static func twoSheetShelf() -> Project {
        var p = Project.demoNesting()
        p.name = "Two-sheet shelf"
        p.stock.width = 24.inch
        let job = try! NestJob.prepare(p, selection: [])
        var s = job.defaultSettings
        s.maxEvaluations = 20
        s.maxSheets = 3
        let r = job.nest(s)
        return job.apply(r, to: p, settings: s).project
    }

    /// The two-sheet job saved as format 14, posted for Avid's Mach4 profile: each sheet's file, byte for byte.
    @Test func savedTwoSheetJobDecodesAndPostsEachSheet() throws {
        let p = try GoldenPostTests.savedProject("sheets-v14", make: Self.twoSheetShelf)
        #expect(p.formatVersion == 14)
        #expect(p.sheetCount == 2)
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error })")
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        try #require(export.files.count == 2)
        for (k, file) in export.files.enumerated() {
            var post = AvidMach4Post(project: file.project, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let data = post.post(file.toolpaths).data(using: .ascii, allowLossyConversion: true)!
            try GoldenPostTests.check(data, golden: "decoded-sheets-v14-sheet-\(k + 1)")
            let text = String(decoding: data, as: UTF8.self)
            let issues = GCodeCheck.run(text, toolpaths: file.toolpaths, project: file.project, dialect: .avidMach4)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        }
    }
}
