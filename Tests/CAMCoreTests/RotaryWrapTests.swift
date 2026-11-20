import Foundation
import Testing
@testable import CAMCore

/// R2, wrapped rotary: the design sheet is the blank unrolled, design Y turns into A as the tool cuts, and moves that
/// turn the blank are fed in inverse time (G93), worked out from the length of the tool tip's path.
struct RotaryWrapTests {
    static let lib = ToolLibrary.starter
    static let dowel = RotaryStock(shape: .cylinder, diameter: 50, length: 300, layout: .wrapped)

    /// A wrapped job on a 50 × 300 mm dowel on Avid's Mach4 profile (mm output), with nothing on it yet.
    static func job(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        var stock = Stock(materialName: "Maple")
        stock.setRotary(dowel)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 100)
        machine.outputUnits = .mm
        var p = Project(name: "Wrapped", displayUnits: .mm, stock: stock, machine: machine)
        configure(&p)
        return p
    }

    /// The sheet's middle line: the top of the blank at A0.
    static var middle: Double { .pi * 50 / 2 }

    /// A 40 × 30 mm rectangle engraved 1 mm deep on the line, built by hand (like the golden coverage jobs) so it
    /// freezes the post rather than the generators: two sides along X (G94) and two around the blank (G93).
    static func rectangle(_ configure: (inout Project) -> Void = { _ in }) -> (Project, [Toolpath]) {
        let p = job(configure)
        let c = middle, safe = p.stock.clearanceHeight
        let tp = Toolpath(id: UUID(uuidString: "60D0E000-0000-0000-0002-000000000001")!, name: "Rectangle", tool: lib.tool(number: 1)!,
                          spindleRPM: 18000, start: Vec3(130, c - 15, safe), motions: [
            .rapid(Vec3(130, c - 15, 2)), .feed(Vec3(130, c - 15, -1), 500),
            .feed(Vec3(170, c - 15, -1), 1000), .feed(Vec3(170, c + 15, -1), 1000),
            .feed(Vec3(130, c + 15, -1), 1000), .feed(Vec3(130, c - 15, -1), 1000),
            .rapid(Vec3(130, c - 15, safe)),
        ])
        var wrapped = tp
        wrapped.wrapDiameter = 50
        return (p, [wrapped])
    }

    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }
    func errors(_ p: Project) -> [String] { CAMEngine.generate(p).issues.filter { $0.severity == .error }.map(\.message) }
    func warnings(_ p: Project) -> [String] { CAMEngine.generate(p).issues.filter { $0.severity == .warning }.map(\.message) }

    func avid(_ p: Project, _ toolpaths: [Toolpath]) -> String {
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        return post.post(toolpaths)
    }

    func generic(_ p: Project, _ toolpaths: [Toolpath]) throws -> (String, GenericGCodePost) {
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
        post.timeZone = TimeZone(identifier: "UTC")!
        return (post.post(toolpaths), post)
    }

    // MARK: Sheet

    @Test func theSheetIsTheBlankUnrolledWithZZeroAtTheWrapDiameter() throws {
        var s = Stock(clearanceHeight: 1)
        s.setRotary(Self.dowel)
        #expect(s.width == 300 && abs(s.height - .pi * 50) < 1e-9 && s.thickness == 25 && s.matchesRotaryBlank)
        #expect(s.requiredFormatVersion == 5)
        // The middle of the sheet is the top of the blank over the axis.
        #expect(s.toWork(Vec3(0, Self.middle, -1)) == Vec3(0, 0, 24))
        // Wrapping at a finished diameter below the blank's: Z zero there, and safe Z clears the blank itself.
        var smaller = Self.dowel
        smaller.wrapDiameter = 46
        s.setRotary(smaller)
        #expect(abs(s.height - .pi * 46) < 1e-9 && s.thickness == 23 && s.matchesRotaryBlank)
        #expect(s.toWork(Vec3(0, s.height / 2, 0)).z == 23)
        #expect(s.clearanceHeight >= 2 + s.safeDistance - 1e-9)
        // Faces jobs keep their sheet and format.
        var faces = Self.dowel
        faces.layout = nil
        s.setRotary(faces)
        #expect(s.height == 50 && s.thickness == 25 && s.requiredFormatVersion == 3)
    }

    @Test func wrappedProjectsAreFormatFiveAndRoundTrip() throws {
        var p = Self.job()
        p.stock.rotary?.wrapDiameter = 48
        p.stock.setRotary(p.stock.rotary)
        #expect(p.formatVersion == 5)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.stock.rotary == p.stock.rotary && back.stock == p.stock)
    }

    // MARK: Inverse time

    @Test func tipLengthAndInverseTimeMatchHandValues() {
        // A quarter turn at 25 mm from the axis: a quarter of the circumference.
        let quarter = RotaryWrap.tipLength(x0: 0, r0: 25, degrees0: 0, x1: 0, r1: 25, degrees1: 90)
        #expect(abs(quarter - 25 * .pi / 2) < 1e-12)
        #expect(abs(RotaryWrap.inverseTime(length: quarter, feed: 1000) - 1000 / (25 * .pi / 2)) < 1e-12)
        // A helix: X and the arc around make the two sides of a right triangle.
        let helix = RotaryWrap.tipLength(x0: 0, r0: 20, degrees0: 0, x1: 30, r1: 20, degrees1: 180 / .pi * 2)
        #expect(abs(helix - 50) < 1e-12)
        // A ramp in r: Simpson's rule against a fine sum.
        let ramp = RotaryWrap.tipLength(x0: 0, r0: 25, degrees0: 0, x1: 10, r1: 20, degrees1: 120)
        var fine = 0.0
        let n = 100_000
        for i in 0..<n {
            let t = (Double(i) + 0.5) / Double(n), r = 25 - 5 * t
            fine += (100 + 25 + r * r * pow(120 * .pi / 180, 2)).squareRoot() / Double(n)
        }
        #expect(abs(ramp - fine) < 1e-6 * fine)
        // A move too short for its feed is capped, never infinite.
        #expect(RotaryWrap.inverseTime(length: 0, feed: 1000) == RotaryWrap.maxInverseTime)
        #expect(RotaryWrap.inverseTime(length: 1e-6, feed: 1000) == RotaryWrap.maxInverseTime)
    }

    /// Acceptance: golden G93 values for a known rectangle.
    @Test func aKnownRectanglePostsTheRightInverseTimes() throws {
        let (p, tps) = Self.rectangle()
        let g = avid(p, tps)
        let lines = g.components(separatedBy: "\r\n")
        // ±15 mm around the 50 mm blank is ±34.377°; the cut is 1 mm deep, 24 mm from the axis.
        let a: Double = 15 * 360 / (Double.pi * 50)
        #expect(abs(a - 34.377) < 5e-4)
        // The side around the blank, as written: 24 mm × 2 × 34.377° (in radians) of tip travel at 1000 mm/min.
        let length = 24 * (2 * 34.377 * .pi / 180)
        let f = String(format: "%.4f", 1000 / length)
        #expect(abs(1000 / length - 1000 / 28.8) < 0.01)
        let body = Array(lines.drop { !$0.hasPrefix("(Toolpath: Rectangle") }.dropFirst().prefix(11))
        #expect(body == [
            "G00 Z\(String(format: "%.3f", 25 + p.stock.clearanceHeight))",
            "G00 X130.000 Y0.000",
            "G00 A-34.377",
            "G00 Z27.000",
            "G01 Z24.000 F500",
            "G01 X170.000 F1000",
            "G93 G01 A34.377 F\(f)",
            "G94 G01 X130.000 F1000",
            "G93 G01 A-34.377 F\(f)",
            "G00 Z\(String(format: "%.3f", 25 + p.stock.clearanceHeight))",
            "G94",
        ], "\(body)")
        // The blank turns back to A0 after the final lift, then the tool parks.
        let last = try #require(lines.lastIndex(of: "G00 A0.000"))
        #expect(lines[last - 1].hasPrefix("G00 Z") && lines[last + 1].hasPrefix("G00 X"))
        #expect(g.contains("(Wrapped: sheet Y wraps around D=50.000, A = Y x 360 / {pi x D}, A0 = middle of the sheet)"))
        #expect(g.contains("(Feeds: G93 inverse time on moves that turn A, G94 otherwise)"))
        let issues = GCodeCheck.run(g, toolpaths: tps, project: p, dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(problems(issues))")
    }

    @Test func rectangleGoldens() throws {
        let (p, tps) = Self.rectangle()
        try GoldenPostTests.check(GoldenPostTests.post(p, tps), golden: "wrapped-rectangle-mm")
        let (inchJob, inchPaths) = Self.rectangle { $0.machine.outputUnits = .inch }
        let inch = GoldenPostTests.post(inchJob, inchPaths)
        try GoldenPostTests.check(inch, golden: "wrapped-rectangle-inch")
        let inchIssues = GCodeCheck.run(String(decoding: inch, as: UTF8.self), toolpaths: inchPaths, project: inchJob, dialect: .avidMach4)
        #expect(problems(inchIssues).isEmpty, "\(problems(inchIssues))")
        for (name, family) in [("linuxcnc", ControllerFamily.linuxCNC), ("grblhal", .grblHAL)] {
            let (pg, tpg) = Self.rectangle { p in
                p.machine.model = .custom
                p.machine.controller = ControllerProfile(family: family)
                p.machine.outputUnits = .mm
            }
            let (g, post) = try generic(pg, tpg)
            try GoldenPostTests.check(Data(g.utf8), golden: "\(name)-wrapped-rectangle")
            #expect(g.contains("G93 G1 A34.377 F"), "\(name)")
            let issues = GCodeCheck.run(g, toolpaths: tpg, project: pg, dialect: post.dialect)
            #expect(problems(issues).isEmpty, "\(name): \(problems(issues))")
        }
    }

    // MARK: Direction

    /// The F outline, 20 mm wide and 30 mm tall, its stem on the left, its long arm at the top.
    static let letterF = Polyline([Vec2(0, 0), Vec2(5, 0), Vec2(5, 12), Vec2(14, 12), Vec2(14, 17), Vec2(5, 17), Vec2(5, 25),
                                   Vec2(20, 25), Vec2(20, 30), Vec2(0, 30)], closed: true)

    static func engravedF(_ configure: (inout Project) -> Void = { _ in }) -> Project {
        job { p in
            let f = DesignShape(kind: .paths([letterF]), position: Vec2(140, middle - 15))
            let op = CAMOperation(name: "Engrave F", kind: .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 1))),
                                  shapeIDs: [f.id], tool: lib.tool(number: 1)!)
            p.shapes = [f]
            p.operations = [op]
            configure(&p)
        }
    }

    /// Where each cut in the posted file lands on the blank, unrolled as seen from above with the blank at A0: X along
    /// the axis, v around it from the top line toward +Y. The machine turns the blank by A about +X (the other way
    /// when Reversed), so the tool at the top cuts the material that sat r·A toward +Y at A0.
    func developed(_ g: String, project p: Project) throws -> [Vec2] {
        let program = try GCodeParser.parse(g)
        let sign = p.machine.rotary?.reversed == true ? -1.0 : 1.0
        let r = p.stock.rotary!.topRadius
        return program.segments.flatMap(\.motions).filter { $0.kind == .feed && $0.end.z < r }.map { m in
            Vec2(m.end.x, r * sign * (m.a ?? 0) * .pi / 180)
        }
    }

    /// Acceptance: wrapped text reads correctly, not mirrored, whichever way the rotary turns.
    @Test func wrappedTextReadsTheRightWayRound() throws {
        for reversed in [false, true] {
            let p = Self.engravedF { $0.machine.rotary?.reversed = reversed }
            let tps = CAMEngine.generate(p).toolpaths
            let g = avid(p, tps)
            #expect(problems(GCodeCheck.run(g, toolpaths: tps, project: p, dialect: .avidMach4)).isEmpty)
            let pts = try developed(g, project: p)
            let vs = pts.map(\.y), xs = pts.map(\.x)
            let (v0, v1) = (try #require(vs.min()), try #require(vs.max()))
            // The letter keeps its size, centred on the top line.
            #expect(abs(v1 - v0 - 30) < 0.1 && abs((v0 + v1) / 2) < 0.1, "\(v0) \(v1)")
            // Its longest arm (furthest along X) is at the top, as drawn; a mirrored F would have it at the bottom.
            let far = try #require(pts.max { $0.x < $1.x })
            #expect(far.y > v1 - 5.5, "reversed \(reversed): far arm at v = \(far.y)")
            // The stem is on the left.
            #expect(abs((try #require(xs.min())) - 140) < 0.1)
            // A Reversed axis writes the angles with the other sign.
            let written = try GCodeParser.parse(g).segments.flatMap(\.motions).compactMap(\.a)
            #expect((written.max() ?? 0) > 30 && (written.min() ?? 0) < -30)
        }
    }

    // MARK: Engine

    @Test func profilesWrapEndToEnd() throws {
        let p = Self.engravedF()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.wrapDiameter == 50)
        // No arcs reach the post, and links stay at safe Z whenever the blank turns.
        #expect(!tp.motions.contains { $0.kind.isArc })
        tp.forEachMotion { s, m in
            if m.kind == .rapid && abs(m.end.y - s.y) > 1e-9 { #expect(min(s.z, m.end.z) >= p.stock.clearanceHeight - 1e-9) }
        }
        let machines: [(String, @Sendable (inout Project) -> Void)] = [
            ("Avid", { _ in }), ("LinuxCNC", ControllerPostTests.controller(.linuxCNC, units: .mm)),
            ("grblHAL", ControllerPostTests.controller(.grblHAL, units: .inch)),
        ]
        for (name, configure) in machines {
            let q = Self.engravedF(configure)
            let tps = CAMEngine.generate(q).toolpaths
            let post = try #require(PostProcessors.post(for: q, date: GoldenPostTests.date))
            let g = post.post(tps)
            #expect(g.contains("G93"), "\(name)")
            let issues = GCodeCheck.run(g, toolpaths: tps, project: q, dialect: post.dialect)
            #expect(problems(issues).isEmpty, "\(name): \(problems(issues))")
            // The air cut runs the same moves a set height out from the axis, and still checks clean.
            if let air = AirCut.files(q, toolpaths: tps, height: 10, date: GoldenPostTests.date) {
                for f in air.files {
                    let issues = GCodeCheck.run(f.gcode, toolpaths: f.toolpaths, project: air.project, dialect: air.post.dialect)
                    #expect(problems(issues).isEmpty, "\(name) air cut: \(problems(issues))")
                }
            }
        }
    }

    @Test func drillingIsRadialAtEachHolesAngle() throws {
        let p = Self.job { p in
            let t2 = Self.lib.tool(number: 2)!
            // Three holes a third of the way round from each other.
            let holes = (0..<3).map { k in
                DesignShape(kind: .circle(radius: t2.radius), position: Vec2(150, Self.middle + Double(k) * .pi * 50 / 3))
            }
            p.shapes = holes
            p.operations = [CAMOperation(name: "Holes", kind: .drill(DrillParams(depth: 8)), shapeIDs: holes.map(\.id), tool: t2)]
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let g = avid(p, job.toolpaths)
        let turns = g.components(separatedBy: "\r\n").filter { $0.contains(" A") && !$0.hasPrefix("(") }
        // Every hole is drilled straight in: the blank turns only in rapids, never while the drill is down.
        #expect(!g.components(separatedBy: "\r\n").contains { $0.hasPrefix("G93") })
        #expect(turns.allSatisfy { $0.hasPrefix("G00") }, "\(turns)")
        for a in ["A0.000", "A120.000", "A240.000"] { #expect(turns.contains { $0.hasSuffix(a) }, "\(a) in \(turns)") }
        #expect(problems(GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
    }

    @Test func shortLinesThatStayInLineAreMerged() {
        // A straight run cut into 100 tiny pieces, with one real corner in the middle.
        var motions: [Motion] = []
        for i in 1...50 { motions.append(.feed(Vec3(Double(i) * 0.02, 0, -1), 800)) }
        for i in 1...50 { motions.append(.feed(Vec3(1, Double(i) * 0.02, -1), 800)) }
        let merged = RotaryWrap.merged(motions, start: Vec3(0, 0, -1), tolerance: 0.005)
        #expect(merged.map(\.end) == [Vec3(1, 0, -1), Vec3(1, 1, -1)])
        // A change of feed always starts a new move.
        motions[70].feed = 400
        #expect(RotaryWrap.merged(motions, start: Vec3(0, 0, -1), tolerance: 0.005).count == 4)
    }

    // MARK: Job checks

    @Test func whatAWrappedJobCantCutIsReported() {
        func has(_ text: String, _ severity: Severity = .error, _ configure: (inout Project) -> Void) {
            let issues = CAMEngine.generate(Self.engravedF(configure)).issues
            #expect(issues.contains { $0.severity == severity && $0.message.contains(text) }, "\(text): \(issues.map(\.message))")
        }
        has("need a round blank") { p in
            var b = p.stock.rotary!
            b.shape = .squareBar
            p.stock.setRotary(b)
        }
        has("bigger than the blank") { p in
            var b = p.stock.rotary!
            b.wrapDiameter = 60
            p.stock.setRotary(b)
        }
        has("Turn the blank down to", .warning) { p in
            var b = p.stock.rotary!
            b.wrapDiameter = 44
            p.stock.setRotary(b)
        }
        has("each shape's place on the sheet sets the angle") { $0.operations[0].indexAngles = [0, 90] }
        has("3D Roughing and 3D Finishing cut flat sheets") { p in
            p.operations[0].kind = .finish3D(Finish3DParams())
        }
        has("no inverse-time feed (G93)", .error, ControllerPostTests.controller(.centroid, units: .mm))
        has("can't be done by hand") { $0.machine.rotary?.turnsByHand = true }
        has("narrower around the blank", .warning) { p in
            p.operations[0].kind = .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 4)))
        }
        // A shallow engraving is clean.
        let clean = Self.engravedF()
        #expect(errors(clean).isEmpty && !warnings(clean).contains { $0.contains("narrower") }, "\(errors(clean))")
        // Cutting across the seam isn't "beyond the material edges".
        let acrossSeam = Self.engravedF { $0.shapes[0].position.y = -10 }
        #expect(!warnings(acrossSeam).contains { $0.contains("beyond the material") }, "\(warnings(acrossSeam))")
    }

    @Test func controllersWithoutG93GetFeedsWorkedOutPerMove() throws {
        let (p, tps) = Self.rectangle { p in
            p.machine.model = .custom
            p.machine.controller = ControllerProfile(family: .linuxCNC)
            p.machine.outputUnits = .mm
        }
        for rule in [Dialect.RotaryFeed.allAxes, .linearAxesOnly] {
            var dialect = Dialect.linuxCNC
            dialect.inverseTime = false
            dialect.rotaryFeed = rule
            var post = GenericGCodePost(project: p, dialect: dialect, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let g = post.post(tps)
            #expect(!g.contains("G93"))
            let around = try #require(g.components(separatedBy: "\n").first { $0.hasPrefix("G1 A34.377") })
            // 28.8 mm of tip travel at 1000 mm/min takes 1.728 s: over all axes that's 68.754 "mm" of A in that time,
            // and with F on the rotary alone (NIST), 68.754° in that time.
            let length = 24 * (2 * 34.377 * .pi / 180)
            let want = 1000 * 2 * 34.377 / length
            #expect(around == "G1 A34.377 F\(String(format: "%.0f", want))", "\(rule): \(around)")
            let issues = GCodeCheck.run(g, toolpaths: tps, project: p, dialect: dialect)
            #expect(problems(issues).isEmpty, "\(rule): \(problems(issues))")
        }
    }

    // MARK: Reading G93 back

    @Test func inverseTimeFilesAreTimedByTheirFWords() throws {
        // The timed MDI test: a quarter turn with 10 mm of X at F10 takes exactly 6 s, whatever the radius.
        let mdi = try GCodeParser.parse("G21 G90\nG0 X0 Z30 A0\nG93 G1 X10 A90 F10\nG94 G1 X20 F600\n")
        let moves = mdi.segments.flatMap(\.motions)
        let turn = try #require(moves.first { $0.inverseTime != nil })
        #expect(turn.inverseTime == 10 && turn.a == 90)
        #expect(abs(turn.duration(from: Vec3(0, 0, 30), rapidRate: 5000) - 6) < 1e-12)
        // Back in G94, F is a feed again.
        let after = try #require(moves.last)
        #expect(after.inverseTime == nil && after.feed == 600)
        #expect(mdi.warnings.allSatisfy { !$0.contains("G93") })

        // A Vectric-style wrap file stays in G93 throughout (F on every line); a Fusion-style one switches per move.
        let vectric = """
        G21 G90 G93
        G0 Z30.000
        G0 X10.000 Y0.000 A0.000
        G1 Z24.000 F120.0
        G1 X40.000 A45.000 F35.5
        G1 X40.000 A90.000 F42.1
        G0 Z30.000
        G94
        M30
        """
        let v = try GCodeParser.parse(vectric)
        let times = v.segments.flatMap(\.motions).compactMap(\.inverseTime)
        #expect(times == [120, 35.5, 42.1])
        let timed: [Motion] = v.segments.flatMap(\.motions).filter { $0.inverseTime != nil }
        let total = timed.map { $0.duration(from: .zero, rapidRate: 1) }.reduce(0, +)
        let want: Double = 60 / 120 + 60 / 35.5 + 60 / 42.1
        #expect(abs(total - want) < 1e-9)
        let fusion = "G21 G90 G94\nG0 X0 Z30 A0\nG1 Z24 F500\nG93 G1 X5 A30 F40.0000\nG1 A60\nG94 G1 X10 F500\nM30\n"
        let f = try GCodeParser.parse(fusion)
        #expect(f.warnings.contains { $0.contains("has no F word") })
    }

    // MARK: Lint

    @Test func inverseTimeRulesAreChecked() throws {
        let (p, tps) = Self.rectangle()
        let g = avid(p, tps)
        func lint(_ edit: (inout [String]) throws -> Void) throws -> String {
            var lines = g.components(separatedBy: "\r\n")
            try edit(&lines)
            return problems(GCodeCheck.lint(lines.joined(separator: "\r\n"), project: p, dialect: .avidMach4)).joined(separator: " | ")
        }
        // F missing from a G93 move.
        #expect(try lint { l in
            let i = try #require(l.firstIndex { $0.hasPrefix("G93 G01") })
            l[i] = String(l[i][..<l[i].range(of: " F")!.lowerBound])
        }.contains("without an F word"))
        // An arc in G93.
        #expect(try lint { l in
            let i = try #require(l.firstIndex { $0.hasPrefix("G93 G01") })
            l.insert("G02 X171.000 I0.500 J0.000 F50.0000", at: i + 1)
        }.contains("An arc in inverse-time mode"))
        // A stop while still in G93.
        #expect(try lint { l in
            let i = try #require(l.firstIndex(of: "G94"))
            l.insert("M00", at: i)
        }.contains("M0 runs in inverse-time mode"))
        // Leaving G93 without restating the feed.
        #expect(try lint { l in
            let i = try #require(l.firstIndex { $0.hasPrefix("G94 G01") })
            l[i] = "G94 G01 X130.000"
        }.contains("without a new F word"))
        // The file as written is clean, and turning the blank in a cut isn't "below safe Z".
        #expect(try lint { _ in }.isEmpty)
        // The read-back catches a wrong inverse time.
        var bad = g.components(separatedBy: "\r\n")
        let i = try #require(bad.firstIndex { $0.hasPrefix("G93 G01") })
        bad[i] = bad[i].replacingOccurrences(of: " F", with: " F1")
        let text = problems(GCodeCheck.run(bad.joined(separator: "\r\n"), toolpaths: tps, project: p, dialect: .avidMach4)).joined()
        #expect(text.contains("Inverse-time F"), "\(text)")
    }

    @Test func setupSheetSaysTheDesignWraps() {
        let p = Self.engravedF()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p))
        #expect(html.contains("Designs wrap around 50.0 mm") && html.contains("above the wrap diameter"))
    }
}
