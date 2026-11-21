import Foundation
import Testing
@testable import CAMCore

/// A rotary axis mounted along machine Y (Avid's front-mounted chuck, Vectric's "Wrap X2A"): the blank's own frame
/// turned a quarter turn about Z (`RotaryFrame`). Every rotary toolpath is generated in the blank's frame, so an
/// along-Y job is the along-X job turned in machine space: the same A and Z words, X = −Y and Y = X.
struct RotaryAlongYTests {
    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }
    func errors(_ p: Project) -> [String] { CAMEngine.generate(p).issues.filter { $0.severity == .error }.map(\.message) }

    /// The same job on an axis along Y.
    static func alongY(_ p: Project) -> Project {
        var q = p
        q.machine.rotary?.alignment = .y
        return q
    }

    /// Avid's Mach4 post and the generic post for LinuxCNC (mm) and grblHAL (inch): the three that write an axis along Y.
    static let machines: [(String, @Sendable (inout Project) -> Void)] = [
        ("Avid", { _ in }), ("LinuxCNC", ControllerPostTests.controller(.linuxCNC, units: .mm)),
        ("grblHAL", ControllerPostTests.controller(.grblHAL, units: .inch)),
    ]

    /// Each file the machine's post writes for `toolpaths`, with the date pinned.
    func files(_ p: Project, _ toolpaths: [Toolpath]) throws -> ([PostedFile], Dialect) {
        if p.machine.isLegacyAvidMach4 {
            var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            return (post.files(toolpaths), post.dialect)
        }
        var post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date) as? GenericGCodePost)
        post.timeZone = TimeZone(identifier: "UTC")!
        return (post.files(toolpaths), post.dialect)
    }

    // MARK: Turned in machine space

    /// The words of a line of code (no comments), letter by letter, with their text.
    static func words(_ line: String) -> [(Character, String)] {
        let code = GCodeParser.stripComments(line).trimmingCharacters(in: .whitespaces)
        var out: [(Character, String)] = []
        for part in code.split(separator: " ") {
            guard let letter = part.first else { continue }
            out.append((letter, String(part.dropFirst())))
        }
        return out
    }

    static func negated(_ value: String) -> String {
        if value.hasPrefix("-") { return String(value.dropFirst()) }
        return Double(value) == 0 ? value : "-" + value
    }

    /// An along-X line as the along-Y post should write it: X v becomes Y v, Y v becomes X −v, and an arc's I and J
    /// turn the same way. Lines without them stay as they are.
    static func turned(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        var codes: [String] = []
        for (letter, value) in words(line) {
            switch letter {
            case "X": out["Y"] = value
            case "Y": out["X"] = negated(value)
            case "I": out["J"] = value
            case "J": out["I"] = negated(value)
            case "G", "M": codes.append("\(letter)\(value)")
            default: out[String(letter)] = value
            }
        }
        out["codes"] = codes.joined(separator: " ")
        return out
    }

    static func keyed(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        var codes: [String] = []
        for (letter, value) in words(line) {
            if letter == "G" || letter == "M" { codes.append("\(letter)\(value)") } else { out[String(letter)] = value }
        }
        out["codes"] = codes.joined(separator: " ")
        return out
    }

    /// The first line (1-based) where the along-Y program isn't the along-X one turned in machine space, comments
    /// aside; nil when every line is.
    static func firstUnturnedLine(_ alongX: String, _ alongY: String) -> Int? {
        let ending = alongX.contains("\r\n") ? "\r\n" : "\n"
        let xs = alongX.components(separatedBy: ending), ys = alongY.components(separatedBy: ending)
        let codeX = xs.enumerated().filter { !GCodeParser.stripComments($0.element).trimmingCharacters(in: .whitespaces).isEmpty }
        let codeY = ys.filter { !GCodeParser.stripComments($0).trimmingCharacters(in: .whitespaces).isEmpty }
        guard codeX.count == codeY.count else { return 0 }
        for (i, (x, y)) in zip(codeX, codeY).enumerated() where turned(x.element) != keyed(y) {
            return i + 1
        }
        return nil
    }

    /// The first motion where the along-Y program read back isn't the along-X one turned: the same kind, Z, A, feed
    /// and inverse time, X = −Y and Y = X, arc centres too. nil when all are; -1 when the counts differ.
    static func firstUnturnedMotion(_ alongX: String, _ alongY: String, dialect: Dialect) throws -> Int? {
        let unit = dialect.dwell.parserUnit
        let mx = try GCodeParser.parse(alongX, dwellUnit: unit).segments.flatMap(\.motions)
        let my = try GCodeParser.parse(alongY, dwellUnit: unit).segments.flatMap(\.motions)
        guard mx.count == my.count else { return -1 }
        for (i, (a, b)) in zip(mx, my).enumerated() {
            var t = a
            t.end = Vec3(-a.end.y + 0, a.end.x, a.end.z)
            t.center = Vec2(-a.center.y + 0, a.center.x)
            var u = b
            u.end = Vec3(b.end.x + 0, b.end.y, b.end.z)
            u.center = Vec2(b.center.x + 0, b.center.y)
            if t != u { return i }
        }
        return nil
    }

    /// Generates `p` on an axis along X and along Y, posts both for each machine, and checks that the job and every
    /// file is the same turned in machine space, and checks clean.
    func expectTurned(_ name: String, _ p: Project, machines: [(String, @Sendable (inout Project) -> Void)] = machines,
                      sourceLocation: SourceLocation = #_sourceLocation) throws {
        for (machine, configure) in machines {
            var px = p
            configure(&px)
            let py = Self.alongY(px)
            let jx = CAMEngine.generate(px), jy = CAMEngine.generate(py)
            let label = "\(name) on \(machine)"
            // The toolpaths are the blank's: the mounting doesn't change them.
            let same = jx.toolpaths.map(\.motions) == jy.toolpaths.map(\.motions)
            #expect(same, "\(label)", sourceLocation: sourceLocation)
            let ey = jy.issues.filter { $0.severity == .error }.map(\.message)
            #expect(ey.isEmpty, "\(label): \(ey)", sourceLocation: sourceLocation)
            let (fx, dialect) = try files(px, jx.toolpaths)
            let (fy, _) = try files(py, jy.toolpaths)
            #expect(fx.count == fy.count, "\(label)", sourceLocation: sourceLocation)
            for (a, b) in zip(fx, fy) {
                let line = Self.firstUnturnedLine(a.gcode, b.gcode)
                #expect(line == nil, "\(label): code line \(line ?? 0) isn't turned", sourceLocation: sourceLocation)
                let motion = try Self.firstUnturnedMotion(a.gcode, b.gcode, dialect: dialect)
                #expect(motion == nil, "\(label): motion \(motion ?? 0) isn't turned", sourceLocation: sourceLocation)
                let issues = problems(GCodeCheck.run(b.gcode, toolpaths: b.toolpaths, project: py, dialect: dialect))
                #expect(issues.isEmpty, "\(label): \(issues)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func indexedJobsAreTheAlongXJobTurned() throws {
        try expectTurned("Table leg", RotaryIndexTests.leg())
        try expectTurned("Carved leg", RotaryIndexTests.carvedLeg())
    }

    @Test func hardWrittenIndexedJobIsTurnedToo() throws {
        let (p, toolpaths) = GoldenPostTests.rotaryJob()
        let q = Self.alongY(p)
        let x = String(decoding: GoldenPostTests.post(p, toolpaths), as: UTF8.self)
        let y = String(decoding: GoldenPostTests.post(q, toolpaths), as: UTF8.self)
        #expect(Self.firstUnturnedLine(x, y) == nil)
        #expect(try Self.firstUnturnedMotion(x, y, dialect: .avidMach4) == nil)
        #expect(problems(GCodeCheck.run(y, toolpaths: toolpaths, project: q, dialect: .avidMach4)).isEmpty)
        // The slots run along the blank: in Y, with X on the centreline.
        #expect(y.contains("G00 X0.0000 Y3.9370\r\n") && y.contains("G01 Y6.2992 F78.7\r\n"))
    }

    @Test func wrappedJobsAreTheAlongXJobTurned() throws {
        try expectTurned("Engraved F", RotaryWrapTests.engravedF())
        let (p, toolpaths) = RotaryWrapTests.rectangle()
        for (machine, configure) in Self.machines {
            var px = p
            configure(&px)
            let py = Self.alongY(px)
            let (fx, dialect) = try files(px, toolpaths)
            let (fy, _) = try files(py, toolpaths)
            let x = try #require(fx.first?.gcode), y = try #require(fy.first?.gcode)
            #expect(Self.firstUnturnedLine(x, y) == nil, "\(machine)")
            #expect(try Self.firstUnturnedMotion(x, y, dialect: dialect) == nil, "\(machine)")
            #expect(problems(GCodeCheck.run(y, toolpaths: toolpaths, project: py, dialect: dialect)).isEmpty, "\(machine)")
            // The tool moves along the blank in Y and stays on X0; A and its inverse times are the same.
            #expect(y.contains("X0.000 Y130.000") || y.contains("X0.0000 Y5.1181"), "\(machine)")
            #expect(y.contains("A34.377 F"), "\(machine)")
        }
    }

    @Test func roundingIsTheAlongXJobTurned() throws {
        try expectTurned("Rounding", RoundingTests.job())
    }

    @Test func rotaryFinishingIsTheAlongXJobTurned() throws {
        try expectTurned("3D finish", Rotary3DTests.smallFinish())
    }

    @Test func rotaryRoughingIsTheAlongXJobTurned() throws {
        try expectTurned("3D rough", Rotary3DRoughingTests.smallRough())
    }

    @Test func turningByHandIsTheAlongXJobTurned() throws {
        try expectTurned("Leg by hand", RotaryManualIndexTests.handLeg(), machines: [
            ("Avid", { _ in }), ("Grbl", ControllerPostTests.controller(.grbl, units: .inch)),
        ])
    }

    // MARK: Text

    /// The F outline, 20 mm wide and 30 mm tall, its stem on the left, its long arm at the top.
    static let letterF = RotaryWrapTests.letterF

    /// Where each cut lands, seen from above with the blank at A0 on an axis along Y: the tool cuts the top of the
    /// blank, and a turn A about +Y (the other way when Reversed) brings up the material that sat r·A toward −X.
    func topView(_ g: String, project p: Project) throws -> [Vec2] {
        let program = try GCodeParser.parse(g)
        let sign = p.machine.rotary?.reversed == true ? -1.0 : 1.0
        let r = try #require(p.stock.rotary).topRadius
        return program.segments.flatMap(\.motions).filter { $0.kind == .feed && $0.end.z < r }.map { m in
            Vec2(m.end.x - r * sign * (m.a ?? 0) * .pi / 180, m.end.y)
        }
    }

    /// Acceptance: text wrapped round a blank on an axis along Y reads the right way round, not mirrored, either way
    /// the axis turns: the letter is turned a quarter turn, its stem at the front and its arms toward the back.
    @Test func wrappedTextReadsTheRightWayRound() throws {
        for reversed in [false, true] {
            let p = Self.alongY(RotaryWrapTests.engravedF { $0.machine.rotary?.reversed = reversed })
            let job = CAMEngine.generate(p)
            #expect(!job.hasErrors, "\(job.issues.map(\.message))")
            var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let g = post.post(job.toolpaths)
            #expect(problems(GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
            let pts = try topView(g, project: p)
            try expectUnmirroredF(pts, reversed: reversed)
        }
    }

    /// The same letter cut on the top face of an indexed blank.
    @Test func textOnAFaceReadsTheRightWayRound() throws {
        let p = Self.alongY(RotaryWrapTests.job { p in
            var b = p.stock.rotary!
            b.layout = nil
            p.stock.setRotary(b)
            let f = DesignShape(kind: .paths([Self.letterF]), position: Vec2(140, 10))
            p.shapes = [f]
            p.operations = [CAMOperation(name: "Engrave F", kind: .profile(ProfileParams(side: .on, depth: DepthSettings(cutDepth: 1))),
                                         shapeIDs: [f.id], tool: RotaryWrapTests.lib.tool(number: 1)!, indexAngles: [0])]
        })
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let g = post.post(job.toolpaths)
        #expect(problems(GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
        try expectUnmirroredF(try topView(g, project: p), reversed: false)
    }

    /// Seen from above: the F turned a quarter turn anticlockwise, not mirrored. Its stem is at the front end (least
    /// Y), it's 30 mm tall across the blank (in X) and 20 mm wide along it, and its longest arm, reaching furthest
    /// toward the back, is the letter's top, which the turn puts toward −X. A mirrored F would have it toward +X.
    func expectUnmirroredF(_ pts: [Vec2], reversed: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let (x0, x1) = (try #require(xs.min()), try #require(xs.max()))
        let (y0, y1) = (try #require(ys.min()), try #require(ys.max()))
        #expect(abs(x1 - x0 - 30) < 0.1 && abs(y1 - y0 - 20) < 0.1, "\(x0) \(x1) \(y0) \(y1)", sourceLocation: sourceLocation)
        #expect(abs(y0 - 140) < 0.1, sourceLocation: sourceLocation)
        let far = try #require(pts.max { $0.y < $1.y })
        #expect(far.x < x0 + 5.5, "reversed \(reversed): far arm at X \(far.x)", sourceLocation: sourceLocation)
    }

    // MARK: Golden

    /// Acceptance: Avid's Mach4 post for a small wrapped job on an axis along Y (the R2 rectangle), byte for byte.
    @Test func avidMach4WrappedGolden() throws {
        let (p, toolpaths) = RotaryWrapTests.rectangle()
        let q = Self.alongY(p)
        let data = GoldenPostTests.post(q, toolpaths)
        try GoldenPostTests.check(data, golden: "wrapped-rectangle-along-y-mm")
        let g = String(decoding: data, as: UTF8.self)
        #expect(problems(GCodeCheck.run(g, toolpaths: toolpaths, project: q, dialect: .avidMach4)).isEmpty)
        #expect(g.contains("(X ZERO = AXIS CENTRELINE   Y ZERO = FRONT END OF THE BLANK)"))
        #expect(g.contains("(Rotary axis along Y: A turns about +Y)"))
        #expect(g.contains("(Wrapped: sheet Y wraps around D=50.000, A = sheet Y x 360 / {pi x D}, A0 = middle of the sheet)"))
        #expect(g.contains("(Program extents: Y130.000 to Y170.000  A-34.377 to A34.377  Z24.000 to Z27.000)"))
    }

    // MARK: Frame

    @Test func theFrameTurnsTheBlankAQuarterTurnAboutZ() {
        var stock = Stock()
        stock.setRotary(RotaryStock(diameter: 50, length: 300))
        let x = RotaryFrame(stock: stock, alignment: .x), y = RotaryFrame(stock: stock, alignment: .y)
        let p = Vec3(100, 35, -2)
        #expect(x.toWork(p) == stock.toWork(p))
        #expect(y.toWork(p) == Vec3(-10, 100, 23))
        #expect(y.fromWork(y.toWork(p)) == p)
        // On the centreline X is 0, never −0, so it writes as X0.
        #expect(y.toWork(Vec3(5, 25, 0)).x.sign == .plus)
        #expect(y.overAxis(p) == Vec3(0, 100, 23))
        #expect(y.blankTravel(Vec3(600, 1500, 200)) == Vec3(1500, 600, 200))
        let box = y.workBox(min: Vec3(10, 20, -5), max: Vec3(50, 40, 0))
        #expect(box.min == Vec3(-15, 10, 20) && box.max == Vec3(5, 50, 25))
    }

    @Test func aFlatJobIsAlongXWhateverTheRotary() {
        var p = Project()
        p.machine.rotary = RotaryAxis(alignment: .y)
        #expect(RotaryFrame(p).alignment == .x)
        p.stock.setRotary(RotaryStock())
        #expect(RotaryFrame(p).alignment == .y)
    }

    @Test func whichWayTheTopRolls() {
        #expect(RotaryAxis.Alignment.x.topRolls(reversed: false) == "−Y")
        #expect(RotaryAxis.Alignment.x.topRolls(reversed: true) == "+Y")
        #expect(RotaryAxis.Alignment.y.topRolls(reversed: false) == "+X")
        #expect(RotaryAxis.Alignment.y.topRolls(reversed: true, ascii: true) == "-X")
    }

    // MARK: Checks

    @Test func onlyThePostsThatWriteItTakeAnAxisAlongY() {
        for family in [ControllerFamily.centroid, .buildbotics] {
            let p = Self.alongY(RotaryIndexTests.leg(ControllerPostTests.controller(family)))
            #expect(errors(p).contains { $0.contains("along Y only for Avid Mach4, LinuxCNC and grblHAL") }, "\(family)")
            var x = p
            x.machine.rotary?.alignment = .x
            #expect(!errors(x).contains { $0.contains("along Y") }, "\(family)")
        }
        for family in [ControllerFamily.linuxCNC, .grblHAL] {
            let p = Self.alongY(RotaryIndexTests.leg(ControllerPostTests.controller(family)))
            #expect(!errors(p).contains { $0.contains("along Y") }, "\(family)")
        }
        // The machine summary says so too.
        let centroid = Self.alongY(RotaryIndexTests.leg(ControllerPostTests.controller(.centroid))).machine
        #expect(centroid.summary.contains { $0.contains("along Y only for Avid Mach4") })
        let avid = Self.alongY(RotaryIndexTests.leg()).machine
        #expect(avid.summary.contains { $0.contains("G0 A moves at safe Z, the blank along Y") })
        // Turned by hand, nothing turns A: every G-code post writes it.
        let grbl = Self.alongY(RotaryManualIndexTests.handLeg(ControllerPostTests.controller(.grbl)))
        #expect(errors(grbl).isEmpty, "\(errors(grbl))")
    }

    @Test func theSetupTextSaysWhichWayToLook() throws {
        let p = Self.alongY(RotaryWrapTests.engravedF())
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.message.contains("should roll toward +X. If it rolls toward −X, tick Reversed") })
        let html = SetupSheet.html(project: p, job: job, date: GoldenPostTests.date)
        #expect(html.contains("Y at the left end") == false)
        #expect(html.contains("Y at the front end of the blank, X on the rotation axis centreline"))
        #expect(html.contains("<dt>Cutting extents</dt><dd>Y "))
        #expect(html.contains("along the blank, A "))
        // Turned by hand, the stops count angles from the way the top rolls.
        let hand = Self.alongY(RotaryManualIndexTests.handLeg())
        let header = RotaryOutput.header(hand.stock, units: .inch, num: { String($0) }, avid: true, axis: hand.machine.rotary)
        #expect(header.contains("Angles count up as the top of the blank rolls toward +X"))
        #expect(RotaryOutput.setupNote(hand.machine).contains("rolls toward +X"))
    }

    /// The blank's length takes the machine's Y travel, its width X: a blank longer than the X travel fits along Y.
    @Test func theTravelChecksUseYForTheBlanksLength() throws {
        let long = RoundingTests.job { p in
            p.stock.setRotary(RotaryStock(shape: .squareBar, diameter: 50, length: 1000))
            p.machine.travel = Vec3(600, 1500, 200)
        }
        #expect(errors(long).contains { $0.contains("larger than") })
        let y = Self.alongY(long)
        #expect(!errors(y).contains { $0.contains("larger than") }, "\(errors(y))")
        let job = CAMEngine.generate(y)
        let (files, dialect) = try files(y, job.toolpaths)
        let g = try #require(files.first?.gcode)
        let program = try GCodeParser.parse(g, dwellUnit: dialect.dwell.parserUnit)
        let envelope = GCodeCheck.envelope(program, toolpaths: job.toolpaths, project: y).map(\.message)
        #expect(envelope.isEmpty, "\(envelope)")
    }

    /// A file posted for an axis along Y simulates back onto the design the right way round.
    @Test func gcodeReadsBackInTheProjectsFrame() throws {
        let p = RotaryIndexTests.leg()
        let q = Self.alongY(p)
        let tps = CAMEngine.generate(p).toolpaths
        func read(_ project: Project) throws -> [[Motion]] {
            var post = AvidMach4Post(project: project, date: GoldenPostTests.date)
            post.timeZone = TimeZone(identifier: "UTC")!
            let program = try GCodeParser.parse(post.post(tps))
            return program.toolpaths(tools: [], frame: RotaryFrame(project), fallback: RotaryIndexTests.lib.tool(number: 1)!).map(\.motions)
        }
        let x = try read(p), y = try read(q)
        #expect(x.count == y.count && x == y)
    }

    /// Nothing new is saved: an axis along Y was already a setting, which every older build that cuts rotary jobs
    /// refuses with an error, so the format doesn't change.
    @Test func anAxisAlongYKeepsTheFormat() throws {
        let p = RotaryWrapTests.job()
        let q = Self.alongY(p)
        #expect(q.formatVersion == p.formatVersion)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(q))
        #expect(back.machine.rotary?.alignment == .y)
    }
}
