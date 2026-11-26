import Foundation
import Testing
@testable import CAMCore

/// The multi-sheet nesting goldens after #182: nested under two bit widths apart (the saved two-sheet shelf, from before
/// #193 raised the default spacing), evenly spaced tabs on edges facing a neighbour move along their loops instead of
/// being cut away. Every part
/// on every sheet keeps its full tab count, and each tab stands at its set thickness in the simulated material.
struct NestedSheetTabsTests {
    /// Each sheet's files: the saved two-sheet shelf (`projects/nesting-multisheet-v16`) and the frames-and-coasters demo
    /// nested as `NestingFixtureTests` nests it.
    static func jobs() throws -> [(name: String, project: Project)] {
        let saved = try GoldenPostTests.savedProject("nesting-multisheet-v16", make: NestSheetsJobTests.twoSheetShelf)
        let demo = Project.demoNestingSheets()
        let (job, r, s) = try NestingFixtureTests.nest(demo, sheets: 3)
        return [("decoded-nesting-multisheet-v16", saved), ("nest-multisheet", job.apply(r, to: demo, settings: s).project)]
    }

    /// The direction into the kerf at a tab: square to the chord between its ends on the wall, out of its part.
    static func outward(_ mark: TabMark, part outlines: [Polyline]) -> Vec2 {
        let along = mark.to - mark.from
        var n = Vec2(-along.y, along.x).normalized
        if outlines.contains(where: { $0.contains(mark.point + n * 0.5) }) { n = n * -1 }
        return n
    }

    @Test func everyNestedPartKeepsEveryTabAtItsThickness() throws {
        for (name, project) in try Self.jobs() { try Self.checkEveryTab(name, project) }
    }

    /// Checks that every part each sheet's file cuts out keeps its full tab count at its set thickness (`NestSpacingTests`
    /// uses it too).
    static func checkEveryTab(_ name: String, _ project: Project) throws {
        do {
            let job = CAMEngine.generate(project)
            #expect(!job.hasErrors, "\(name)")
            let export = try #require(JobExport.files(project, job: job, date: GoldenPostTests.date))
            for (k, file) in export.files.enumerated() {
                let sheet = "\(name) sheet \(k + 1)"
                let ops = file.project.operations.filter { op in
                    if case let .profile(p) = op.kind { return p.side == .outside && p.tabs.enabled } else { return false }
                }
                try #require(ops.count == 1, "\(sheet)")
                guard case let .profile(params) = ops[0].kind else { continue }
                let tp = try #require(file.toolpaths.first { $0.id == ops[0].id }, "\(sheet)")
                #expect(!tp.warnings.contains { $0.contains("cut away") }, "\(sheet): \(tp.warnings)")
                // Every part this sheet cuts out has its full count of tabs on each of its walls (a frame's window too).
                let parts = file.project.shapes(for: ops[0]).filter { !$0.isKeepOut }
                let marks = Dictionary(grouping: tp.tabMarks ?? [], by: \.shapeID)
                for part in parts {
                    let walls = part.polylines().filter(\.isClosed).count
                    #expect(marks[part.id]?.count == params.tabs.count * walls,
                            "\(sheet): “\(part.name)” has \(marks[part.id]?.count ?? 0) tabs on \(walls) walls")
                }
                // In the simulated material, every tab stands at its thickness all across its kerf.
                var sim = MaterialSimulator(stock: file.project.stock, cellSize: 0.5)
                for t in file.toolpaths {
                    var at = t.start
                    for m in t.motions {
                        sim.apply(m, from: at, tool: t.tool)
                        at = m.end
                    }
                }
                let tabTop = -params.depth.cutDepth + params.tabs.thickness
                let r = ops[0].tool.radius
                for part in parts {
                    let outlines = part.polylines()
                    for mark in marks[part.id] ?? [] {
                        let n = Self.outward(mark, part: outlines)
                        for d in stride(from: 1.0, through: 2 * r - 1, by: 1) {
                            let h = Double(sim.grid.height(at: mark.point + n * d) ?? -.infinity)
                            #expect(h >= tabTop - 0.3, "\(sheet): “\(part.name)”'s tab at \(mark.point) is \(h) at \(d) mm out, under \(tabTop)")
                        }
                    }
                }
            }
        }
    }
}
