import Foundation
import Testing
@testable import CAMCore

/// Different bits under one T number get no tool change between them (the post, and Mach4's M6 macro, only change
/// tools when the number changes), so the job checks must catch them.
struct ToolNumberTests {
    let lib = ToolLibrary.starter

    /// Three small pockets side by side, one per tool.
    func project(_ tools: [Tool], machine: MachineProfile = MachineProfile()) -> Project {
        let shapes = tools.indices.map { i in
            DesignShape(kind: .rectangle(width: 20, height: 20, cornerRadius: 0), position: Vec2(30 + Double(i) * 40, 40))
        }
        let ops = zip(shapes, tools).enumerated().map { i, pair in
            CAMOperation(name: "Pocket \(i + 1)", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 2))),
                         shapeIDs: [pair.0.id], tool: pair.1)
        }
        var p = Project(stock: Stock(width: 200, height: 100, thickness: 19), shapes: shapes, operations: ops)
        p.machine = machine
        return p
    }

    /// The 1/8" end mill, renumbered to share T1 with the 1/4" end mill.
    var eighthAsT1: Tool {
        var t = lib.tool(number: 2)!
        t.number = 1
        return t
    }

    func issues(_ job: JobResult) -> [JobIssue] { job.issues.filter { $0.message.contains("tool number") } }

    @Test func backToBackBitsWithOneNumberAreAnError() {
        let p = project([lib.tool(number: 1)!, eighthAsT1])
        let job = CAMEngine.generate(p)
        let found = issues(job)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.operation == "Pocket 2")
        #expect(found.first?.message.contains("would cut with the 1/4\" Upcut End Mill") == true)
        // That's the hazard: one tool change for two bits.
        let gcode = AvidMach4Post(project: p).post(job.toolpaths)
        let changes = gcode.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix("M6") }
        #expect(changes == ["T1M6"])
    }

    @Test func twoEntriesForOneBitCanShareANumber() {
        // Same bit, different feeds and name (say, one entry per material): no change is needed, so no issue.
        var copy = lib.tool(number: 1)!
        copy.id = UUID()
        copy.name = "1/4\" Upcut, MDF feeds"
        copy.cutting.feedRate *= 1.5
        copy.notes = "MDF"
        let job = CAMEngine.generate(project([lib.tool(number: 1)!, copy]))
        #expect(issues(job).isEmpty)
    }

    @Test func sharedNumberElsewhereInTheRunIsAWarning() {
        // A tool change separates them, so manual changes still prompt for the right bit, but a reorder could
        // put them back to back.
        let job = CAMEngine.generate(project([lib.tool(number: 1)!, lib.tool(number: 3)!, eighthAsT1]))
        let found = issues(job)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.operation == "Pocket 3")
        #expect(!job.hasErrors)
    }

    @Test func sharedNumberOnAToolChangerIsAnError() {
        var atc = MachineProfile()
        atc.toolChange = .atc
        let job = CAMEngine.generate(project([lib.tool(number: 1)!, lib.tool(number: 3)!, eighthAsT1], machine: atc))
        let found = issues(job)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test func eachToolpathThatWouldUseTheWrongBitIsFlagged() {
        // T1 1/4", then two toolpaths with the 1/8" also numbered T1: both run with the 1/4" still loaded.
        let job = CAMEngine.generate(project([lib.tool(number: 1)!, eighthAsT1, eighthAsT1]))
        let found = issues(job)
        #expect(found.map(\.operation) == ["Pocket 2", "Pocket 3"])
        #expect(found.allSatisfy { $0.severity == .error })
    }

    @Test func demoProjectsHaveNoSharedNumbers() {
        #expect(issues(CAMEngine.generate(Project.demoSign())).isEmpty)
        #expect(issues(CAMEngine.generate(Project.demoRelief())).isEmpty)
    }
}
