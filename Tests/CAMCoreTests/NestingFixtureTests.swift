import Foundation
import Testing
@testable import CAMCore

/// The nesting fixtures (#86): golden G-code for a job nested onto two sheets and for a part nested in another's hole,
/// and what NativeCAM does with the edge cases (a part bigger than the sheet, a hole too small for any part, a sheet left
/// empty). The drawings are in `Fixtures/svg/nest-*.svg`, the saved project in `Fixtures/projects`.
struct NestingFixtureTests {
    /// An SVG fixture imported as File ▸ Import does, as one shape, cut out through by one outside profile with the
    /// starter 1/4" end mill, on an 18 mm sheet `width` × `height`.
    static func imported(_ name: String, width: Double, height: Double) throws -> Project {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Fixtures/svg"),
                               "missing fixture \(name).svg")
        let stock = Stock(width: width, height: height, thickness: 18)
        let result = try VectorImporter.importFile(at: url, tolerance: 0.01)
        let shapes = result.shapes(name: name, stock: stock)
        var p = Fixture.project(shapes: shapes, ops: [NestPartsTests.through(shapes)], stock: stock)
        p.name = name
        return p
    }

    /// Nests every part with a fixed seed and number of layouts, at the default spacing unless `spacing` is given (and
    /// then the same edge margin).
    static func nest(_ project: Project, sheets: Int, evaluations: Int = 10, spacing: Double? = nil) throws -> (job: NestJob, result: Nesting.Result, settings: Nesting.Settings) {
        let job = try NestJob.prepare(project, selection: [])
        var s = job.defaultSettings
        if let spacing {
            s.spacing = spacing
            s.edgeMargin = spacing
        }
        s.maxSheets = sheets
        s.maxEvaluations = evaluations
        s.seed = 86
        let r = job.nest(s)
        #expect(job.check(r, settings: s).isEmpty, "\(job.check(r, settings: s))")
        return (job, r, s)
    }

    /// Posts each of a job's files for Avid's Mach4 profile and checks it against its golden and the export checks.
    static func checkFiles(_ project: Project, golden: (Int) -> String, count: Int) throws {
        let job = CAMEngine.generate(project)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error })")
        let export = try #require(JobExport.files(project, job: job, date: GoldenPostTests.date))
        try #require(export.files.count == count)
        for (k, file) in export.files.enumerated() {
            var post = AvidMach4Post(project: file.project, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let data = post.post(file.toolpaths).data(using: .ascii, allowLossyConversion: true)!
            try GoldenPostTests.check(data, golden: golden(k))
            let text = String(decoding: data, as: UTF8.self)
            let issues = GCodeCheck.run(text, toolpaths: file.toolpaths, project: file.project, dialect: .avidMach4)
            #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
        }
    }

    // MARK: Goldens

    /// The frames and coasters demo nested onto two 24" × 48" sheets, with brackets and coasters in the frames' windows:
    /// a file per sheet on the Avid Mach4 default.
    @Test func aJobNestedOntoTwoSheetsPostsAFilePerSheet() throws {
        let p = Project.demoNestingSheets()
        let (job, r, s) = try Self.nest(p, sheets: 3)
        #expect(r.placedCount == job.parts.count)
        #expect(r.sheetCount == 2)
        #expect(!r.inHoles.isEmpty)
        let nested = job.apply(r, to: p, settings: s).project
        #expect(nested.sheetCount == 2 && nested.formatVersion == 16)
        try Self.checkFiles(nested, golden: { "nest-multisheet-sheet-\($0 + 1)" }, count: 2)
    }

    /// The default spacing before #193, one 1/4" bit's width plus 1/8 in (3 mm in a metric job), which these fixtures
    /// were sized and saved for. They test the nesting, not its default, so they pass it explicitly.
    static func oneBitSpacing(_ project: Project) -> Double { 0.25.inch + NestJob.spacingMargin(project.displayUnits) }

    /// `nest-part-in-part.svg`: the rectangle and the disc fit on the 260 × 200 sheet only in the frame's window. They go
    /// there, keep their gap from its edge and are cut out before it. (The window is sized for parts `oneBitSpacing`
    /// apart.)
    @Test func smallPartsNestedInAFramesWindowPostAndAreCutFirst() throws {
        let p = try Self.imported("nest-part-in-part", width: 260, height: 200)
        let (job, r, s) = try Self.nest(p, sheets: 1, spacing: Self.oneBitSpacing(p))
        try #require(job.parts.count == 3)
        let frame = try #require(job.parts.firstIndex { !$0.holes.isEmpty })
        #expect(job.parts[frame].holes.count == 1)
        #expect(r.placedCount == 3 && r.sheetCount == 1)
        #expect(r.insideOf.enumerated().allSatisfy { i, outer in i == frame ? outer == nil : outer == frame })
        let applied = job.apply(r, to: p, settings: s)
        #expect(applied.inHoles.count == 2)
        let nested = applied.project
        #expect(OperationScheduler.optimize(nested).outOfOrder.isEmpty)
        // In the one profile, both parts' last full-depth cuts come before the window's first.
        let tp = try #require(CAMEngine.generate(nested).toolpaths.first)
        // The 140 × 90 window, turned or not.
        let lines = nested.shapes.flatMap { $0.polylines() }
        let window = try #require(lines.first { l in
            let w = l.bounds.width, h = l.bounds.height
            return l.isClosed && ((abs(w - 140) < 0.5 && abs(h - 90) < 0.5) || (abs(w - 90) < 0.5 && abs(h - 140) < 0.5))
        })
        let r0 = Fixture.endMill.radius
        var lastInner = -1, firstWindow = Int.max, index = 0
        tp.forEachMotion { _, m in
            defer { index += 1 }
            guard m.kind == .feed || m.kind.isArc, m.end.z < -17.9 else { return }
            let onWindow = abs(window.closestPoint(to: m.end.xy).distance - r0) < 0.05 && window.contains(m.end.xy)
            if onWindow { firstWindow = min(firstWindow, index) } else if window.contains(m.end.xy) { lastInner = index }
        }
        #expect(lastInner >= 0 && firstWindow < Int.max)
        #expect(lastInner < firstWindow, "inner parts' last full-depth cut \(lastInner), window's first \(firstWindow)")
        try GoldenPostTests.check(GoldenPostTests.post(nested), golden: "nest-part-in-part")
    }

    /// The two-sheet shelf saved as format 16, posted for Avid's Mach4 profile: each sheet's file, byte for byte.
    @Test func savedTwoSheetJobDecodesAndPostsEachSheet() throws {
        let p = try GoldenPostTests.savedProject("nesting-multisheet-v16", make: NestSheetsJobTests.twoSheetShelf)
        #expect(p.formatVersion == 16)
        #expect(p.sheetCount == 2)
        #expect(try Project.decode(p.encoded()) == p)
        try Self.checkFiles(p, golden: { "decoded-nesting-multisheet-v16-sheet-\($0 + 1)" }, count: 2)
    }

    /// The frames and coasters demo nested as `nativecam-cli nest --sheets 10 --evaluations 300` does: 300 layouts with
    /// the default seed, up to 10 sheets.
    /// The saved `nesting-part-in-part-v16` was nested at the default before #193 (`oneBitSpacing`), so it's repeated at
    /// that spacing.
    static func framesNest() throws -> (job: NestJob, result: Nesting.Result, settings: Nesting.Settings) {
        let demo = Project.demoNestingSheets()
        let job = try NestJob.prepare(demo, selection: [])
        var s = job.defaultSettings
        s.spacing = oneBitSpacing(demo)
        s.edgeMargin = s.spacing
        s.maxSheets = 10
        s.maxEvaluations = 300
        return (job, job.nest(s), s)
    }

    /// `framesNest()` applied: 11 parts on the first sheet and 8 on the second, 7 of them in the frames' windows, as the
    /// website's tutorial found it. Saved as `nesting-part-in-part-v16`.
    static func nestedFramesAndCoasters() -> Project {
        guard let (job, r, s) = try? framesNest() else { return Project.demoNestingSheets() }
        return job.apply(r, to: Project.demoNestingSheets(), settings: s).project
    }

    /// #104: the setup sheet's cover counts the parts nesting placed on each sheet, those in the frames' windows too,
    /// and nesting the job again finds each of them as a part of its own, cut in the same order.
    @Test func partsInHolesAreCountedAndNestAgainOnTheirOwn() throws {
        let p = try GoldenPostTests.savedProject("nesting-part-in-part-v16", make: Self.nestedFramesAndCoasters)
        #expect(p.formatVersion == 16 && p.sheetCount == 2)
        // What the nest placed on each sheet, and in the windows.
        let placed = try Self.framesNest().result
        let perSheet = placed.sheets.map(\.partCount)
        #expect(perSheet == [11, 8])
        #expect(placed.inHoles.count == 7)
        // The cover's Sheets table lists the same (it once counted a part in a window as part of its frame).
        let job = CAMEngine.generate(p)
        let html = SetupSheet.html(project: p, job: job, gcodeFile: "Frames.tap", date: GoldenPostTests.date)
        let table = try #require(html.components(separatedBy: "<h2>Sheets</h2>").dropFirst().first?.components(separatedBy: "</table>").first)
        let counts = try Regex(#"class="num">(\d+)</td>"#)
        let listed = table.matches(of: counts).compactMap { Int($0.output[1].substring ?? "") }
        #expect(listed == perSheet, "\(listed) on the cover, \(perSheet) placed")
        #expect(NestJob.parts(of: p.sheetProject(0)).count + NestJob.parts(of: p.sheetProject(1)).count == 12)
        // Nesting it again: 19 parts, each frame, coaster and bracket on its own, and the frames' windows free to use.
        let again = try NestJob.prepare(p, selection: [])
        #expect(again.parts.count == 19)
        let prefixes = ["Frame", "Coaster", "Bracket"]
        let loose = again.parts.filter { part in prefixes.contains { part.name.hasPrefix($0) } }
        #expect(loose.count == 12)
        #expect(loose.allSatisfy { $0.shapeIDs.count == 1 })
        #expect(again.partsWithHoles == 2)
        // A frame nested on its own leaves what's in its window where it is.
        let frame = try #require(p.shapes.first { $0.name == "Frame 1" })
        let alone = try NestJob.prepare(p, selection: [frame.id])
        #expect(alone.parts.map(\.shapeIDs) == [[frame.id]])
        // The run order is the same, and it still cuts each part in a window before freeing the window.
        #expect(OperationScheduler.optimize(p).outOfOrder.isEmpty)
        // At today's default spacing (#193) the parts need a third sheet.
        var s = again.defaultSettings
        s.maxSheets = 3
        s.maxEvaluations = 10
        s.seed = 86
        let r = again.nest(s)
        #expect(r.placedCount == 19)
        #expect(again.check(r, settings: s).isEmpty, "\(again.check(r, settings: s))")
        let renested = again.apply(r, to: p, settings: s).project
        #expect(renested.operations == p.operations)
        #expect(OperationScheduler.optimize(renested).outOfOrder.isEmpty)
    }

    /// #105: the frames and coasters demo opens with parts off its sheet, so with an error and warnings; Checks says why
    /// and points to Nest Parts, as a note that adds no warning of its own. Once nested, it goes.
    @Test func theFramesDemoSaysToNestItsParts() throws {
        let demo = CAMEngine.generate(Project.demoNestingSheets())
        #expect(demo.hasErrors)
        let note = try #require(demo.issues.first { $0.message.contains("Nest Parts") })
        #expect(note.severity == .info)
        #expect(note.message.contains("other shapes lie off the material"), "\(note.message)")
        let nested = try GoldenPostTests.savedProject("nesting-part-in-part-v16", make: Self.nestedFramesAndCoasters)
        #expect(!CAMEngine.generate(nested).issues.contains { $0.message.contains("Nest Parts") })
        // A shape off the material that nothing cuts (a reference drawing) needs no note.
        var drawing = Project.demoNestingSheets()
        drawing.operations = []
        #expect(CAMEngine.offMaterialNote(drawing) == nil)
    }

    // MARK: Edge cases

    /// `nest-too-big.svg`: the 700 mm rail fits no 600 × 400 sheet either way round. It's left out (where it was, or
    /// beside the sheet), no sheet is added for it, and the squares nest on the first sheet.
    @Test func aPartBiggerThanTheSheetIsLeftOutWithoutAddingSheets() throws {
        let p = try Self.imported("nest-too-big", width: 600, height: 400)
        let (job, r, s) = try Self.nest(p, sheets: 3)
        try #require(job.parts.count == 4)
        let rail = try #require(job.parts.firstIndex { $0.bounds.width > 600 || $0.bounds.height > 600 })
        #expect(r.unplaced == [rail])
        #expect(r.placedCount == 3)
        #expect(r.sheetCount == 1)
        let applied = job.apply(r, to: p, settings: s)
        #expect(applied.sheetCount == 1 && applied.project.sheetCount == 1)
        #expect(applied.leftInPlace + applied.movedAside == [job.parts[rail].name])
        #expect(applied.project.formatVersion == 1)
    }

    /// `nest-small-hole.svg`: the panel's 20 mm hole is cut through from inside, so it counts, but nothing fits in it
    /// with the gap all round: the rectangle and the disc nest beside the panel.
    @Test func aHoleTooSmallForAnyPartStaysEmpty() throws {
        let p = try Self.imported("nest-small-hole", width: 400, height: 200)
        let (job, r, _) = try Self.nest(p, sheets: 1)
        try #require(job.parts.count == 3)
        let panel = try #require(job.parts.firstIndex { !$0.holes.isEmpty })
        let hole = job.parts[panel].holes[0]
        #expect(abs(hole.reach - Fixture.endMill.diameter) < 0.1, "\(hole.reach)")
        #expect(job.parts.allSatisfy { hole.accepts(group: $0.group) })
        #expect(job.partsWithHoles == 1)
        #expect(r.placedCount == 3)
        #expect(r.inHoles.isEmpty)
        #expect(r.insideOf.allSatisfy { $0 == nil })
    }

    /// Three sheets with nothing left on the second (its parts taken off it).
    static func gappedSheets() -> Project {
        var p = NestSheetsJobTests.squaresJob()
        p.name = "Gapped sheets"
        p.additionalSheets = [MaterialSheet(width: 340, height: 340), MaterialSheet(width: 340, height: 340)]
        for i in p.shapes.indices where i >= 6 { p.shapes[i].sheet = 2 }
        let keep = Set(p.shapes.prefix(9).map(\.id))
        p.shapes = p.shapes.filter { keep.contains($0.id) }
        p.operations[0].shapeIDs = p.operations[0].shapeIDs.filter { keep.contains($0) }
        return p
    }

    /// `projects/nesting-empty-sheet-v16.nativecam`: a job of three sheets whose second has nothing on it. Checks say
    /// so, Export skips it (the others keep their numbers), the setup sheet says it has no file, and nesting again
    /// closes the gap. Parts that fit on fewer sheets than allowed never leave an empty one.
    @Test func aSheetLeftEmptyGetsNoFileAndNestingAgainClosesTheGap() throws {
        let p = try GoldenPostTests.savedProject("nesting-empty-sheet-v16", make: Self.gappedSheets)
        #expect(p.formatVersion == 16 && p.sheetCount == 3)
        #expect(p.shapes(onSheet: 1).isEmpty)
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .warning && $0.message.hasPrefix("Sheet 2 has nothing to cut") })
        #expect(job.sheets?.map(\.cutsAnything) == [true, false, true])
        let export = try #require(JobExport.files(p, job: job, date: GoldenPostTests.date))
        #expect(export.files.map(\.suffix) == [" - sheet 1 of 3", " - sheet 3 of 3"])
        let html = SetupSheet.html(project: p, job: job, gcodeFile: "Gapped.tap", date: GoldenPostTests.date)
        #expect(html.contains("Nothing to cut: no file"))
        #expect(html.components(separatedBy: "<section class=\"tile\">").count == 3)
        // Nesting again: the nine squares fit on the first sheet (`oneBitSpacing` apart, as the sheet is sized for), and
        // the empty sheets go.
        let (nestJob, r, s) = try Self.nest(p, sheets: 3, evaluations: 5, spacing: Self.oneBitSpacing(p))
        #expect(r.placedCount == 9 && r.sheetCount == 1)
        let again = nestJob.apply(r, to: p, settings: s).project
        #expect(again.sheetCount == 1 && again.additionalSheets.isEmpty)
        #expect(again.formatVersion == 1)
        // Room to spare: allowing more sheets than needed adds none.
        let few = NestSheetsJobTests.squaresJob()
        let fewer = try Self.nest(few, sheets: 5, evaluations: 5, spacing: Self.oneBitSpacing(few))
        #expect(fewer.result.sheetCount == 2)
        #expect(fewer.job.apply(fewer.result, to: few, settings: fewer.settings).project.sheetCount == 2)
    }
}
