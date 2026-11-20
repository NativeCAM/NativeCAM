import Foundation
import Testing
@testable import CAMCore

/// R2, wrapped rotary: pockets, V-carving and spirals around the blank.
struct RotaryWrapCutTests {
    static let lib = ToolLibrary.starter

    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }

    /// A pocket and V-carved text on the 50 × 300 mm wrapped dowel.
    static func pocketAndText(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        RotaryWrapTests.job { p in
            let c = RotaryWrapTests.middle
            let pocket = DesignShape(kind: .rectangle(width: 40, height: 20, cornerRadius: 3), position: Vec2(80, c))
            let text = DesignShape(kind: .text(TextSpec(string: "NC", fontName: "Helvetica-Bold", capHeight: 18)), position: Vec2(200, c))
            p.shapes = [pocket, text]
            p.operations = [
                CAMOperation(name: "Pocket", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 2))), shapeIDs: [pocket.id],
                             tool: lib.tool(number: 2)!),
                CAMOperation(name: "Carve", kind: .vcarve(VCarveParams()), shapeIDs: [text.id], tool: lib.tool(number: 5)!),
            ]
            configure(&p)
        }
    }

    @Test func pocketsAndVCarvingWrapEndToEnd() throws {
        let p = Self.pocketAndText()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        #expect(job.toolpaths.count == 2 && job.toolpaths.allSatisfy { $0.wrapDiameter == 50 && !$0.motions.contains { $0.kind.isArc } })
        let machines: [(String, @Sendable (inout Project) -> Void)] = [
            ("Avid", { _ in }), ("LinuxCNC", ControllerPostTests.controller(.linuxCNC, units: .mm)),
            ("grblHAL", ControllerPostTests.controller(.grblHAL, units: .inch)),
        ]
        for (name, configure) in machines {
            let q = Self.pocketAndText(configure)
            let tps = CAMEngine.generate(q).toolpaths
            let post = try #require(PostProcessors.post(for: q, date: GoldenPostTests.date))
            for f in post.files(tps) {
                #expect(f.gcode.contains("G93"), "\(name)")
                let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: q, dialect: post.dialect)
                #expect(problems(issues).isEmpty, "\(name): \(problems(issues))")
            }
        }
    }

    @Test func vCarvingIsMergedAndStaysUnderTheInverseTimeCap() throws {
        let p = Self.pocketAndText()
        let op = p.operations[1]
        let ctx = GenerationContext(stock: p.stock, machine: p.machine, flattenTolerance: 0.01, arcTolerance: 0.005)
        let raw = try #require(CAMEngine.generate(op, shapes: p.shapes(for: op), context: ctx).first)
        let prepared = RotaryWrap.prepare(raw, diameter: 50, clearanceZ: p.stock.clearanceHeight, tolerance: 0.01)
        let feeds = { (t: Toolpath) in t.motions.filter { $0.kind != .rapid && $0.kind != .dwell }.count }
        #expect(feeds(prepared) < feeds(raw), "\(feeds(prepared)) of \(feeds(raw))")
        // No carved move is so short that its time would be capped.
        let job = CAMEngine.generate(p)
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let program = try GCodeParser.parse(post.post(job.toolpaths))
        let times = program.segments.flatMap(\.motions).compactMap(\.inverseTime)
        #expect(!times.isEmpty && times.allSatisfy { $0 < RotaryWrap.maxInverseTime }, "\(times.max() ?? 0)")
    }

    @Test func aMoveTooShortForItsFeedIsCapped() throws {
        let (p, _) = RotaryWrapTests.rectangle()
        let c = RotaryWrapTests.middle
        // A thousandth of a degree at 24 mm from the axis: 0.0004 mm, which would need F2.4 million.
        var tp = Toolpath(id: UUID(), name: "Tiny", tool: Self.lib.tool(number: 1)!, spindleRPM: 18000, start: Vec3(150, c, 12.7),
                          motions: [.rapid(Vec3(150, c, 1)), .feed(Vec3(150, c, -1), 500), .feed(Vec3(150, c + 0.0005, -1), 1000),
                                    .rapid(Vec3(150, c + 0.0005, 12.7))])
        tp.wrapDiameter = 50
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let g = post.post([tp])
        #expect(g.contains("G93 G01 A0.001 F999999.9999"))
        #expect(problems(GCodeCheck.run(g, toolpaths: [tp], project: p, dialect: .avidMach4)).isEmpty)
    }

    // MARK: Spirals

    static func ropeTwist(leftHanded: Bool = false, _ configure: (inout Project) -> Void = { _ in }) -> Project {
        RotaryWrapTests.job { p in
            let spiral = DesignShape(kind: .spiral(SpiralSpec(starts: 3, pitch: 60, length: 240, around: p.stock.height,
                                                              leftHanded: leftHanded)),
                                     position: Vec2(150, RotaryWrapTests.middle))
            p.shapes = [spiral]
            p.operations = [CAMOperation(name: "Twist", kind: .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 3))),
                                         shapeIDs: [spiral.id], tool: lib.tool(number: 7)!)]
            configure(&p)
        }
    }

    /// Feed moves at full depth along a spiral, as (ΔX, ΔA) in the posted file.
    func cuts(_ g: String, below radius: Double) throws -> [(dx: Double, da: Double)] {
        var out: [(Double, Double)] = []
        var prev: Motion?
        for m in try GCodeParser.parse(g).segments.flatMap(\.motions) {
            defer { prev = m }
            guard let s = prev, m.inverseTime != nil, m.end.z < radius, s.end.z < radius, let a0 = s.a, let a1 = m.a else { continue }
            out.append((m.end.x - s.end.x, a1 - a0))
        }
        return out
    }

    /// Acceptance (toolpath half of the rope twist): three starts climb 360° every 60 mm, past the seam and on round,
    /// the right way for the hand of the twist.
    @Test func aRopeTwistTurnsOncePerPitch() throws {
        for left in [false, true] {
            let p = Self.ropeTwist(leftHanded: left)
            let job = CAMEngine.generate(p)
            #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
            var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let g = post.post(job.toolpaths)
            #expect(problems(GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
            let moves = try cuts(g, below: 25 - 2.9)
            #expect(!moves.isEmpty)
            for (dx, da) in moves {
                // 6° per mm along X; never more than 90° in one move.
                #expect(abs(abs(da / dx) - 6) < 0.01 && abs(da) <= RotaryWrap.maxTurnPerMove + 1e-6, "\(dx) \(da)")
                // Seen from above with the tool at the top, the blank's surface angle from +Y is 90° − A. A right-hand
                // helix about +X advances that angle as X increases.
                #expect((da / dx < 0) != left, "left \(left): \(da / dx)")
            }
            // Each line turns four times along its 240 mm, so A runs well past one turn, unwound.
            let a: [Double] = try GCodeParser.parse(g).segments.flatMap(\.motions).compactMap(\.a)
            let span: Double = (a.max() ?? 0) - (a.min() ?? 0)
            #expect(span >= 4 * 360 - 1, "\(span)")
        }
    }

    @Test func spiralsAreFormatFourAndFollowTheSheet() throws {
        var p = Self.ropeTwist()
        #expect(p.formatVersion == 4)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.shapes == p.shapes)
        // The lines are straight on the sheet, three starts a third of the way round apart, four turns high.
        guard case let .spiral(spec) = p.shapes[0].kind else { Issue.record("not a spiral"); return }
        let lines = spec.lines
        #expect(lines.count == 3 && lines.allSatisfy { !$0.isClosed && $0.count == 2 })
        #expect(abs((lines[0].points[0].y - lines[0].points[1].y) - 4 * p.stock.height) < 1e-9)
        #expect(abs(lines[1].points[0].y - lines[0].points[0].y - p.stock.height / 3) < 1e-9)
        // Turning the blank down to a smaller wrap diameter refits the spiral to the new sheet.
        var blank = try #require(p.stock.rotary)
        blank.wrapDiameter = 44
        p.stock.setRotary(blank)
        #expect(CAMEngine.generate(p).issues.contains { $0.message.contains("its turns won't meet") })
        p.fitSpiralsToSheet()
        guard case let .spiral(fitted) = p.shapes[0].kind else { return }
        #expect(abs(fitted.around - .pi * 44) < 1e-9)
        #expect(!CAMEngine.generate(p).issues.contains { $0.message.contains("its turns won't meet") })
    }

    @Test func aPocketAcrossTheSeamCarriesOnRound() throws {
        let p = Self.pocketAndText { p in
            p.shapes[0].position.y = 2 // straddles the seam at the bottom edge of the sheet
            p.operations.removeLast()
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors && !job.issues.contains { $0.message.contains("beyond the material") }, "\(job.issues.map(\.message))")
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let g = post.post(job.toolpaths)
        #expect(problems(GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
        // The seam is at ±180°: the pocket runs from just past −180° to below it, unwound, with no jump of a turn.
        let a: [Double] = try GCodeParser.parse(g).segments.flatMap(\.motions).filter { $0.kind == .feed }.compactMap(\.a)
        let low: Double = a.min() ?? 0, high: Double = a.max() ?? 0
        #expect(low < -180 && high > -180 && high - low < 60, "\(low) \(high)")
    }
}
