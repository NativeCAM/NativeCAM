import Foundation
import Testing
@testable import CAMCore

/// A 3D toolpath on a model as deep as the board, cut round with Selected vectors or Whole material, cut the part free
/// before its tabbed cut-out ran, and Checks said nothing (#155). The catalog: the demo relief with its model as deep as
/// the board (`Fixtures/part-hold/deep-relief.nativecam`), whose roughing and finishing now hold their floor a tab
/// thickness above the material's bottom, with its Mach4 golden; the same job with tabs as thick as the board, where the
/// floor can't be held (an error, so `post` refuses); and the job with no cut-out, where the finish reaches the bottom
/// (a warning).
struct PartHoldTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("part-hold")

    /// The demo relief, its model made as deep as the 3/4" maple, Selected vectors boundary and a tabbed cut-out, as the
    /// issue reproduced it. Update mode writes it when missing, but never replaces it.
    static func deepRelief() throws -> Project {
        let url = dir.appendingPathComponent("deep-relief.nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            var p = Project.demoRelief()
            if case var .model(m) = p.shapes[0].kind {
                m.depth = p.stock.thickness
                p.shapes[0].kind = .model(m)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try p.encoded().write(to: url, options: .atomic) // the tests run in parallel
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func op(_ p: Project, _ name: String) -> CAMOperation { p.operations.first { $0.name == name }! }

    /// The lowest design Z each toolpath cuts to, collected first and asserted afterwards (an `#expect` inside
    /// `forEachMotion` crashes swiftc).
    static func deepest(_ tp: Toolpath) -> Double {
        var lowest = Double.infinity
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            lowest = min(lowest, s.z, m.end.z)
        }
        return lowest
    }

    @Test func reproHasTheModelAsDeepAsTheBoard() throws {
        let p = try Self.deepRelief()
        guard case let .model(m) = p.shapes[0].kind else { Issue.record("no model"); return }
        #expect(abs(m.bottomZ + p.stock.thickness) < 1e-6)
        guard case let .finish3D(f) = Self.op(p, "Finish relief").kind else { Issue.record("no finish"); return }
        #expect(f.boundary == .vectors)
        guard case let .profile(c) = Self.op(p, "Cut out medallion").kind else { Issue.record("no cut-out"); return }
        #expect(PartHold.holdsPart(c))
    }

    /// The repro with Whole material: strips under the tabs would join nothing (#173), so the whole floor is held.
    static func wholeMaterial() throws -> Project {
        var p = try deepRelief()
        for i in p.operations.indices {
            switch p.operations[i].kind {
            case var .rough3D(r): r.boundary = .material; p.operations[i].kind = .rough3D(r)
            case var .finish3D(f): f.boundary = .material; p.operations[i].kind = .finish3D(f)
            default: break
            }
        }
        return p
    }

    /// With Selected vectors, as the issue reproduced it, the 3D toolpaths now leave strips under the cut-out's tabs
    /// instead of holding the whole floor (#173), and cut the rest to the board's bottom.
    @Test func reproNowLeavesStripsUnderTheTabs() throws {
        let p = try Self.deepRelief()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        for name in ["Rough relief", "Finish relief"] {
            #expect(HoldingTabs.decide(Self.op(p, name), in: p).strips?.strips.count == 4)
            #expect(job.issues.contains { $0.severity == .info && $0.operation == name && $0.message.hasPrefix("Leaves a strip under each of the 4 tabs") })
            #expect(!job.issues.contains { $0.operation == name && $0.message.hasPrefix("Holds its floor") })
        }
        let finish = try #require(job.toolpaths.first { $0.name == "Finish relief" })
        #expect(abs(Self.deepest(finish) + p.stock.thickness) < 0.01)
        // After every toolpath, the material over each of the cut-out's tabs (their length, across the kerf) stands at
        // their top, to within a cell: the finishing ball doesn't round their ends.
        let s = try #require(HoldingTabs.decide(Self.op(p, "Finish relief"), in: p).strips)
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.25)
        for tp in job.toolpaths { tp.forEachMotion { a, m in sim.apply(m, from: a, tool: tp.tool) } }
        let r = Self.op(p, "Cut out medallion").tool.radius
        var short = 0.0
        for st in s.strips {
            for u in stride(from: -(st.width / 2 - 0.25), through: st.width / 2 - 0.25 + 1e-9, by: 0.25) {
                for v in stride(from: 0.25, through: 2 * r - 0.25 + 1e-9, by: 0.25) {
                    short = max(short, s.top - Double(sim.grid.height(at: st.centre + st.tangent * u + st.normal * v) ?? -.infinity))
                }
            }
        }
        #expect(short <= 0.26, "a tab falls \(short) mm short of its top")
    }

    @Test func floorIsHeldAboveTheTabsWithANote() throws {
        let p = try Self.wholeMaterial()
        guard case let .profile(c) = Self.op(p, "Cut out medallion").kind else { Issue.record("no cut-out"); return }
        let held = -(p.stock.thickness - c.tabs.thickness)
        let tabTop = -OperationScheduler.tabTop(c)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        for name in ["Rough relief", "Finish relief"] {
            let tp = try #require(job.toolpaths.first { $0.name == name })
            let low = Self.deepest(tp)
            // Never below the held floor, which stands above the tabs' tops; the finish reaches it.
            #expect(low >= held - 1e-6, "\(name) cuts to \(low)")
            #expect(low > tabTop)
            #expect(job.issues.contains { $0.severity == .info && $0.operation == name && $0.message.hasPrefix("Holds its floor")
                && $0.message.contains("Whole material") })
            #expect(!job.issues.contains { $0.operation == name && $0.message.contains("material's bottom, and 3D") })
        }
        let finish = try #require(job.toolpaths.first { $0.name == "Finish relief" })
        #expect(abs(Self.deepest(finish) - held) < 0.01)
        let rough = try #require(job.toolpaths.first { $0.name == "Rough relief" })
        guard case let .rough3D(r) = Self.op(p, "Rough relief").kind else { Issue.record("no rough"); return }
        #expect(abs(Self.deepest(rough) - (held + r.allowance)) < 0.01)
        // The run order the scheduler wants is the user's: both 3D toolpaths before the cut-out.
        #expect(job.reorder?.outOfOrder.isEmpty ?? true)
        let order = (job.reorder?.order ?? p.operations.map(\.id)).compactMap { id in p.operations.first { $0.id == id }?.name }
        #expect(order == ["Rough relief", "Finish relief", "Cut out medallion"])
    }

    @Test func heldReproMatchesItsMach4Golden() throws {
        let p = try Self.deepRelief()
        let job = CAMEngine.generate(p)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: "part-hold-deep-relief-inch")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }

    /// Tabs as thick as the board leave no floor to hold: an error on both 3D toolpaths, and `post` refuses.
    static func impossible() throws -> Project {
        var p = try deepRelief()
        let k = p.operations.firstIndex { $0.name == "Cut out medallion" }!
        guard case var .profile(c) = p.operations[k].kind else { fatalError() }
        c.tabs.thickness = p.stock.thickness
        p.operations[k].kind = .profile(c)
        return p
    }

    @Test func floorThatCantBeHeldIsAnError() throws {
        let job = CAMEngine.generate(try Self.impossible())
        #expect(job.hasErrors)
        for name in ["Rough relief", "Finish relief"] {
            #expect(job.issues.contains { $0.severity == .error && $0.operation == name && $0.message.contains("can't be held") })
        }
        // Each frees the other, so the scheduler keeps the user's order rather than moving the cut-out first.
        #expect(job.reorder?.outOfOrder.isEmpty ?? true)
        #expect(!job.issues.contains { $0.message.contains("Optimize Run Order") })
    }

    @Test func postRefusesTheFloorThatCantBeHeld() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("part-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = tmp.appendingPathComponent("impossible.nativecam")
        try Self.impossible().encoded().write(to: project)
        let out = tmp.appendingPathComponent("impossible.tap")
        let run = try CommandLineTests.run(["post", project.path, "-o", out.path])
        #expect(run.status == 1, "\(run.output)")
        #expect(run.output.contains("can't be held"))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// With the floor held, or failing to be held, for a tabbed cut-out, the warning that says to add one isn't given
    /// beside it: the job already has it (#168).
    @Test func noAddATabbedProfileAdviceWhenOneHoldsTheFloor() throws {
        for p in [try Self.impossible(), try Self.deepRelief()] {
            let job = CAMEngine.generate(p)
            for name in ["Rough relief", "Finish relief"] {
                #expect(!job.issues.contains { $0.operation == name && $0.message.contains("3D toolpaths leave no tabs") },
                        "\(job.issues.filter { $0.operation == name }.map(\.message))")
            }
        }
        let job = CAMEngine.generate(try Self.impossible())
        #expect(job.issues.contains { $0.severity == .error && $0.operation == "Finish relief" && $0.message.contains("can't be held") })
    }

    /// No cut-out: nothing to hold, and the finish reaching the bottom is a warning, with the through-cut info line.
    @Test func threeDReachingTheBottomWarns() throws {
        var p = try Self.deepRelief()
        p.operations.removeAll { $0.name == "Cut out medallion" }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let finish = try #require(job.toolpaths.first { $0.name == "Finish relief" })
        #expect(abs(Self.deepest(finish) + p.stock.thickness) < 0.01)
        let mine = job.issues.filter { $0.operation == "Finish relief" }
        #expect(mine.contains { $0.severity == .warning && $0.message.contains("Cuts down to the material's bottom") })
        #expect(mine.contains { $0.severity == .info && $0.message == "Cuts through to the bottom of the material." })
        #expect(!job.issues.contains { $0.message.hasPrefix("Holds its floor") })
    }

    /// A drill inside the relief after a finish that cuts round it to the bottom runs on a loose part: the scheduler
    /// keeps it before the finish now that a 3D toolpath counts as cutting through.
    @Test func schedulerKeepsWorkBeforeACutThroughThreeDPass() throws {
        var p = try Self.deepRelief()
        p.operations.removeAll { $0.name == "Cut out medallion" }
        let model = p.shapes[0].bounds
        let hole = DesignShape(id: UUID(), name: "Hole", kind: .circle(radius: 2), position: model.center)
        p.shapes.append(hole)
        let drill = CAMOperation(name: "Drill", kind: .drill(DrillParams(depth: 3)), shapeIDs: [hole.id], tool: Self.op(p, "Rough relief").tool)
        p.operations.append(drill)
        let r = OperationScheduler.optimize(p)
        let finish = Self.op(p, "Finish relief")
        #expect(r.outOfOrder.contains { $0.operation == drill.id && $0.mustPrecede == finish.id })
    }

    /// Reaching the bottom exactly is reported as going past it is.
    @Test func profileToExactlyTheThicknessIsReported() throws {
        var p = Project.demoSign()
        let k = try #require(p.operations.firstIndex { if case .profile = $0.kind { true } else { false } })
        guard case var .profile(c) = p.operations[k].kind else { return }
        c.depth.cutDepth = p.stock.thickness
        c.depth.fromBottom = nil
        p.operations[k].kind = .profile(c)
        let job = CAMEngine.generate(p)
        let mine = job.issues.filter { $0.operation == p.operations[k].name }
        // Exactly at the bottom: no "0.0000 in into the spoilboard" (#168).
        #expect(mine.contains { $0.severity == .info && $0.message == "Cuts through to the bottom of the material." }, "\(mine.map(\.message))")
        #expect(!mine.contains { $0.message.contains("into the spoilboard") })
        // A little past it still gives the figure.
        c.depth.cutDepth = p.stock.thickness + 0.5
        p.operations[k].kind = .profile(c)
        #expect(CAMEngine.generate(p).issues.contains { $0.operation == p.operations[k].name
            && $0.message.hasPrefix("Cuts through the material (") && $0.message.hasSuffix("into the spoilboard).") })
    }

    /// Tabs with no thickness hold nothing, whatever their count: the one test the checks share (`PartHold.holdsPart`).
    @Test func tabsThatHoldNothingDontCount() throws {
        var c = ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 10))
        c.tabs = TabSettings(enabled: true, count: 4, thickness: 0)
        #expect(!PartHold.holdsPart(c))
        let cutOut = CAMOperation(name: "Cut out", kind: .profile(c), shapeIDs: [], tool: ToolLibrary.starter.tool(number: 1)!)
        #expect(!OperationScheduler.clearsTabs(1, of: cutOut, in: Project.demoSign()))
        c.tabs.thickness = 3
        #expect(PartHold.holdsPart(c))
        c.tabs.count = 0
        #expect(!PartHold.holdsPart(c))
    }
}
