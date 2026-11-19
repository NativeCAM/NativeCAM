import Foundation
import Testing
@testable import CAMCore

struct SchedulerTests {
    let lib = ToolLibrary.starter

    @Test func groupsToolsWithoutCuttingPartsFreeEarly() {
        // User order: pocket (T1), V-carve (T5), drill (T1), cut-out (T1) = 2 tool changes.
        var p = Project.demoSign()
        let ops = p.operations
        let vcarve = ops.first { $0.name.contains("V-carve") }!, pocket = ops.first { $0.name.contains("Pocket") }!
        let drill = ops.first { $0.name.contains("Drill") }!, cut = ops.first { $0.name.contains("Cut out") }!
        p.operations = [pocket, vcarve, drill, cut]
        let r = OperationScheduler.optimize(p)
        #expect(r.toolChangesBefore == 2 && r.toolChangesAfter == 1)
        #expect(r.order.last == cut.id)
        let names = r.order.compactMap { id in p.operations.first { $0.id == id }?.name }
        #expect(names.firstIndex(of: drill.name)! < names.firstIndex(of: cut.name)!)
    }

    @Test func reliefKeepsFinishBeforeCutOut() {
        let p = Project.demoRelief()
        let r = OperationScheduler.optimize(p)
        // rough (T1), finish (T7), cut-out (T1): the finish can't move after the cut-out, so two changes remain.
        #expect(r.order == p.operations.map(\.id))
        #expect(r.toolChangesAfter == 2)
    }

    @Test func overlappingOperationsKeepUserOrder() {
        let a = DesignShape(kind: .rectangle(width: 50, height: 50, cornerRadius: 0), position: Vec2(60, 60))
        let b = DesignShape(kind: .rectangle(width: 20, height: 20, cornerRadius: 0), position: Vec2(60, 60))
        let c = DesignShape(kind: .circle(radius: 5), position: Vec2(150, 60))
        let ops = [
            CAMOperation(name: "Pocket A", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [a.id], tool: lib.tool(number: 1)!),
            CAMOperation(name: "V-carve B", kind: .vcarve(VCarveParams()), shapeIDs: [b.id], tool: lib.tool(number: 5)!),
            CAMOperation(name: "Pocket C", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [c.id], tool: lib.tool(number: 1)!),
        ]
        let p = Project(stock: Stock(width: 200, height: 150, thickness: 19), shapes: [a, b, c], operations: ops)
        let r = OperationScheduler.optimize(p)
        // C (T1, elsewhere) joins A; B (overlaps A) stays after A.
        #expect(r.order == [ops[0].id, ops[2].id, ops[1].id])
        #expect(r.toolChangesAfter == 1)
    }

    @Test func disabledOperationsStayWithTheirNeighbour() {
        var p = Project.demoSign()
        let ops = p.operations
        let vcarve = ops[0], pocket = ops[1], drill = ops[2], cut = ops[3]
        var off = drill
        off.id = UUID()
        off.name = "Spare drill"
        off.enabled = false
        p.operations = [pocket, off, vcarve, drill, cut]
        let r = OperationScheduler.optimize(p)
        #expect(r.changed)
        #expect(r.order == [vcarve.id, pocket.id, off.id, drill.id, cut.id])
        p.applyRunOrder(r.order)
        #expect(p.operations.map(\.id) == r.order)
    }

    @Test func nestedCutOutsGoInnerFirst() {
        // A ring part whose outside cut-out comes first in the list: the hole and the label inside must go first.
        let outer = DesignShape(kind: .circle(radius: 60), position: Vec2(100, 100))
        let hole = DesignShape(kind: .circle(radius: 20), position: Vec2(100, 100))
        let label = DesignShape(kind: .rectangle(width: 10, height: 10, cornerRadius: 0), position: Vec2(100, 140))
        let through = DepthSettings(cutDepth: 19.5)
        let ops = [
            CAMOperation(name: "Cut out", kind: .profile(ProfileParams(side: .outside, depth: through)), shapeIDs: [outer.id], tool: lib.tool(number: 1)!),
            CAMOperation(name: "Hole", kind: .profile(ProfileParams(side: .inside, depth: through)), shapeIDs: [hole.id], tool: lib.tool(number: 2)!),
            CAMOperation(name: "Label", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 2))), shapeIDs: [label.id], tool: lib.tool(number: 2)!),
        ]
        let p = Project(stock: Stock(width: 200, height: 200, thickness: 19), shapes: [outer, hole, label], operations: ops)
        let r = OperationScheduler.optimize(p)
        // Same single change either way, but the original cuts the ring free first: that's fixed.
        #expect(r.order == [ops[1].id, ops[2].id, ops[0].id])
        #expect(r.toolChangesBefore == 1 && r.toolChangesAfter == 1)
        #expect(Set(r.outOfOrder.map(\.operation)) == [ops[1].id, ops[2].id])
        #expect(r.changed)
        let job = CAMEngine.generate(p)
        #expect(job.issues.filter { $0.severity == .warning && $0.message.contains("cut its part free") }.count == 2)
        var fixed = p
        fixed.applyRunOrder(r.order)
        #expect(!OperationScheduler.optimize(fixed).changed)
    }

    @Test func engineSuggestsButNeverReorders() {
        var p = Project.demoSign()
        let ops = p.operations
        p.operations = [ops[1], ops[0], ops[2], ops[3]] // pocket, V-carve, drill, cut-out: 2 changes
        let job = CAMEngine.generate(p)
        #expect(job.reorder?.toolChangesAfter == 1)
        #expect(job.issues.contains { $0.severity == .info && $0.message.contains("saves 1 tool change") })
        #expect(job.toolpaths.map(\.name) == p.operations.map(\.name))
        #expect(CAMEngine.generate(.demoSign()).reorder == nil)
    }
}
