import Foundation
import Testing
@testable import CAMCore

/// A whole job with leads and corner reliefs: frozen as a golden file for the Avid Mach4 post and exported for other
/// controllers, inch and mm, with and without arcs, through every export check.
struct LeadReliefJobTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// A cabinet-style part: a pocket with dogbones, a through mortise on line leads with T-bones and a ramp, and a
    /// cut-out with a notch on arc leads with dogbones, overlap and tabs.
    static func job(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        let bit = ToolLibrary.starter.tool(number: 1)!
        let stock = Stock(width: 300, height: 200, thickness: 18, clearanceHeight: 10, plungeHeight: 2)
        let outline = DesignShape(id: id(1), name: "Side", kind: .paths([Polyline([
            Vec2(50, 40), Vec2(250, 40), Vec2(250, 160), Vec2(170, 160), Vec2(170, 130), Vec2(130, 130), Vec2(130, 160), Vec2(50, 160),
        ], closed: true)]), position: .zero)
        let mortise = DesignShape(id: id(2), name: "Mortise", kind: .rectangle(width: 60, height: 18, cornerRadius: 0), position: Vec2(100, 100))
        let recess = DesignShape(id: id(3), name: "Recess", kind: .rectangle(width: 40, height: 30, cornerRadius: 0), position: Vec2(200, 90))
        let ops = [
            CAMOperation(id: id(11), name: "Recess", kind: .pocket(PocketParams(
                depth: DepthSettings(cutDepth: 6, passDepth: 3), cornerRelief: CornerReliefSettings())), shapeIDs: [recess.id], tool: bit),
            CAMOperation(id: id(12), name: "Mortise", kind: .profile(ProfileParams(
                side: .inside, depth: DepthSettings(cutDepth: 18.5, passDepth: 6.5), entry: EntrySettings(kind: .ramp, rampLength: 20),
                leads: LeadSettings(kind: .line, length: 5, angle: 45),
                cornerRelief: CornerReliefSettings(style: .tBone, tBoneSide: .longer))), shapeIDs: [mortise.id], tool: bit),
            CAMOperation(id: id(13), name: "Cut out", kind: .profile(ProfileParams(
                side: .outside, depth: DepthSettings(cutDepth: 18.5, passDepth: 6.5),
                tabs: TabSettings(enabled: true, count: 3, width: 8, thickness: 2),
                leads: LeadSettings(kind: .arc, radius: 6.35, sweep: 90, overlap: 2),
                cornerRelief: CornerReliefSettings())), shapeIDs: [outline.id], tool: bit),
        ]
        var p = Project(name: "Leads and reliefs", displayUnits: .mm, stock: stock, machine: .avidPRO6060,
                        shapes: [outline, mortise, recess], operations: ops)
        configure(&p)
        return p
    }

    static func controller(_ family: ControllerFamily) -> (inout Project) -> Void {
        { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: family)
        }
    }

    @Test func jobUsesEveryOptionCleanly() throws {
        let p = Self.job()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let notes = job.issues.map(\.message).filter { $0.contains("Lead") || $0.contains("relie") }
        #expect(notes.isEmpty, "\(notes)")
        #expect(job.toolpaths.count == 3)
        for tp in job.toolpaths { #expect(CutFixture.reversals(tp) > 0, "\(tp.name) has its reliefs") }
    }

    @Test func goldenAvidOutput() throws {
        let p = Self.job()
        let toolpaths = CAMEngine.generate(p).toolpaths
        let data = GoldenPostTests.post(p, toolpaths)
        try GoldenPostTests.check(data, golden: "features-leads-reliefs")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }

    @Test func everyControllerUnitAndArcSettingPassesTheExportChecks() throws {
        let setups: [(String, (inout Project) -> Void)] = [
            ("avid", { _ in }), ("grbl", Self.controller(.grbl)), ("linuxcnc", Self.controller(.linuxCNC)),
            ("shopbot", Self.controller(.openSBP)),
        ]
        for (name, setup) in setups {
            for units in [LengthUnit.inch, .mm] {
                for arcs in [true, false] {
                    let p = Self.job { p in
                        setup(&p)
                        p.machine.outputUnits = units
                        p.machine.outputArcs = arcs
                    }
                    let label = "\(name) \(units) arcs \(arcs)"
                    let job = CAMEngine.generate(p)
                    #expect(!job.hasErrors, "\(label): \(job.issues.filter { $0.severity == .error }.map(\.message))")
                    let post = try #require(PostProcessors.post(for: p), "\(label)")
                    for file in post.files(job.toolpaths) {
                        let issues = GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: p, dialect: post.dialect)
                            .filter { $0.severity != .info }
                        #expect(issues.isEmpty, "\(label): \(issues.map(\.text))")
                    }
                }
            }
        }
    }

    @Test func simulationFindsNoRapidsThroughMaterial() throws {
        let p = Self.job()
        let job = CAMEngine.generate(p)
        var session = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10_000, cellSize: 0.5)
        session.runToEnd()
        #expect(session.rapidCollisions.isEmpty, "\(session.rapidCollisions.count) rapids through material")
        #expect(job.estimatedSeconds > 0 && job.estimatedSeconds.isFinite)
    }
}
