import Foundation
import Testing
@testable import CAMCore

/// #99: Add Toolpath ▸ Inlay… starts each side clearing its flats with the flat end mill the run-time estimate says is
/// quickest for it, and keeps a tool picked by hand. The design is `Fixtures/svg/inlay-joy.svg`: JOY in block capitals
/// 2" tall with 0.42" strokes on a 7" × 4.5" board, where the pocket's flats are narrow and a whole-board plug's are wide.
/// It's imported once into `Fixtures/projects/inlay-joy-v1.nativecam` (no toolpaths), which `scripts/snapshot-check.sh`
/// also makes its inlay pair from.
struct InlayClearanceTests {
    /// The JOY drawing imported as File ▸ Import does, in an inch job on the default Avid PRO6060.
    static func importedJOY() -> Project {
        let stock = Stock(width: 7.inch, height: 4.5.inch, thickness: 0.75.inch, materialName: "Walnut")
        guard let url = Bundle.module.url(forResource: "inlay-joy", withExtension: "svg", subdirectory: "Fixtures/svg"),
              let shapes = try? VectorImporter.importFile(at: url).shapes(name: "inlay-joy", stock: stock) else {
            return Project(name: "JOY inlay", displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: [])
        }
        return Project(name: "JOY inlay", displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: shapes)
    }

    /// The saved JOY project, all of it selected.
    static func joy() throws -> (project: Project, selection: [UUID]) {
        let project = try GoldenPostTests.savedProject("inlay-joy-v1", make: importedJOY)
        return (project, project.shapes.map(\.id))
    }

    @Test func theJOYDesignIsSavedAsImported() throws {
        let (project, ids) = try Self.joy()
        #expect(project.formatVersion == 1)
        let imported = Self.importedJOY()
        // Three letters, the O with its counter; the same outlines as the drawing gives today.
        #expect(ids.count == imported.shapes.count)
        #expect(project.inlayShapes(ids).count == ids.count)
        let saved = project.shapes.flatMap { $0.polylines(tolerance: 0.01) }, fresh = imported.shapes.flatMap { $0.polylines(tolerance: 0.01) }
        #expect(saved.count == 4 && saved.count == fresh.count)
        #expect(abs(saved.bounds.width - 5.2.inch) < 0.01 && abs(saved.bounds.height - 2.inch) < 0.01, "\(saved.bounds)")
    }

    static let library = ToolLibrary.starter
    static var endMills: [Tool] { library.tools.filter { $0.shape == .flatEndMill } }
    static var eighth: Tool { library.tool(number: 2)! }
    static var quarter: Tool { library.tool(number: 1)! }

    /// The dialog's settings for `boundary`, before any clearance tool is chosen.
    static func settings(_ boundary: VCarveInlay.Boundary) -> InlayPairSettings {
        var s = InlayPairSettings(vBit: library.tool(number: 5)!)
        s.boundary = boundary
        return s
    }

    /// Every starter end mill timed on JOY with a whole-board plug, once for the suite. At the time of writing: the pocket
    /// 14:14 with the 1/4" upcut and 3:00 with the 1/8"; the plug 5:04 with the 1/4" upcut, 3:36 with the 1/4"
    /// compression (one pass where the upcut takes two), 2:56 with the 1/2" and 23:05 with the 1/8".
    static let boardTimes: InlayClearanceTimes? = {
        guard let (project, ids) = try? joy() else { return nil }
        return project.inlayClearanceTimes(settings(.board), shapes: ids, tools: library.tools)
    }()

    static func times(_ boundary: VCarveInlay.Boundary) throws -> InlayClearanceTimes {
        try #require(boundary == .board ? boardTimes : nil)
    }

    @Test func everyFlatEndMillIsTimedOnEachSide() throws {
        let times = try Self.times(.board)
        let numbers = Self.endMills.map(\.number)
        #expect(times.pocket.map(\.tool.number) == numbers)
        #expect(times.plug.map(\.tool.number) == numbers)
        #expect(times.key == Self.settings(.board).timingKey)
        // Each time is the side's own run, as Add Toolpaths makes it.
        let (project, ids) = try Self.joy()
        var s = Self.settings(.board)
        s.clearanceTool = Self.eighth
        var p = project
        let added = p.addInlay(s, shapes: ids)
        let pair = try #require(added)
        p.operations = [pair.pocket]
        let pocketTime = CAMEngine.generate(p).estimatedSeconds
        #expect(abs(pocketTime - (times.seconds(.pocket, tool: Self.eighth) ?? 0)) < 1e-6)
    }

    @Test func theJOYPocketAndWholeBoardPlugStartWithTheirQuickestEndMills() throws {
        let times = try Self.times(.board)
        let start = Self.settings(.board).withQuickestClearance(times)
        // The pocket's flats are narrow: the 1/8" end mill fits them, so the V-bit has little left to clear.
        let pocket = try #require(start.pocketClearanceTool)
        #expect(pocket.number == Self.eighth.number)
        let eighthPocket = try #require(times.seconds(.pocket, tool: Self.eighth))
        let quarterPocket = try #require(times.seconds(.pocket, tool: Self.quarter))
        #expect(eighthPocket < quarterPocket / 2, "1/8\" \(eighthPocket) s, 1/4\" \(quarterPocket) s")
        // Round the letters, a whole-board plug's flat is wide open: the estimator's pick is a larger end mill, quicker
        // than any other and much quicker than the pocket's 1/8".
        let plug = try #require(start.plugClearanceTool)
        let plugSeconds = try #require(times.seconds(.plug, tool: plug))
        #expect(plug.diameter > Self.eighth.diameter)
        #expect(times.plug.allSatisfy { $0.seconds >= plugSeconds - InlayClearanceTimes.tieSeconds })
        let eighthPlug = try #require(times.seconds(.plug, tool: Self.eighth))
        #expect(plugSeconds < eighthPlug / 2, "T\(plug.number) \(plugSeconds) s, 1/8\" \(eighthPlug) s")
        // Add Toolpaths makes each side with its own.
        let (project, ids) = try Self.joy()
        var p = project
        let added = p.addInlay(start, shapes: ids)
        let pair = try #require(added)
        guard case let .vcarve(a) = pair.pocket.kind, case let .vcarve(b) = pair.plug.kind else { Issue.record("not V-carves"); return }
        #expect(a.clearanceTool?.id == pocket.id && b.clearanceTool?.id == plug.id)
        // And the pair still matches (#100).
        #expect(pair.pocket.inlayDifferences(from: pair.plug).isEmpty)
    }

    @Test func aToolPickedByHandIsKept() throws {
        let times = try Self.times(.board)
        var s = Self.settings(.board)
        // The 1/4" picked for the pocket stays, though the 1/8" is quicker there; the plug still gets its quickest.
        s.pickClearance(Self.quarter, for: .pocket)
        let kept = s.withQuickestClearance(times)
        #expect(kept.pocketClearanceTool?.id == Self.quarter.id)
        #expect(kept.plugClearanceTool?.id == times.quickest(.plug)?.id)
        // None (the V-bit alone) picked for the plug stays too.
        s.pickClearance(nil, for: .plug)
        let none = s.withQuickestClearance(times)
        #expect(none.pocketClearanceTool?.id == Self.quarter.id && none.plugClearanceTool == nil)
        // Picks don't change what the times depend on, so they aren't worked out again for them.
        #expect(s.timingKey == Self.settings(.board).timingKey)
    }

    @Test func tiesGoToTheLargerBit() throws {
        let quarter = Self.quarter, half = try #require(Self.library.tool(number: 10)), eighth = Self.eighth
        let key = Self.settings(.margin).timingKey
        func times(_ seconds: [(Tool, Double)]) -> InlayClearanceTimes {
            let t = seconds.map { InlayClearanceTime(tool: $0.0, seconds: $0.1) }
            return InlayClearanceTimes(pocket: t, plug: t, key: key)
        }
        // Within a second: the larger.
        #expect(times([(eighth, 100), (quarter, 100.6)]).quickest(.pocket)?.id == quarter.id)
        #expect(times([(half, 200.5), (quarter, 200)]).quickest(.plug)?.id == half.id)
        // Clearly quicker wins whatever its size.
        #expect(times([(eighth, 100), (quarter, 130), (half, 160)]).quickest(.pocket)?.id == eighth.id)
        // Nothing timed (no end mills): no pick, and the settings keep theirs.
        let empty = InlayClearanceTimes(pocket: [], plug: [], key: key)
        #expect(empty.quickest(.pocket) == nil)
        var s = Self.settings(.margin)
        s.clearanceTool = eighth
        #expect(s.withQuickestClearance(empty).plugClearanceTool?.id == eighth.id)
    }
}
