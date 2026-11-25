import Foundation
import Testing
@testable import CAMCore

/// #156: restart files (`Restart`), for after a broken bit, a power cut or an E-stop part way through a job. The inputs
/// are in `Fixtures/restart` (see its README); the goldens are `golden/restart-*.tap`.
struct RestartTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("restart")

    static func fixture(_ name: String, _ configure: (inout Project) -> Void = { _ in }) throws -> Project {
        var p = try Project.decode(Data(contentsOf: fixtures.appendingPathComponent(name + ".nativecam")))
        configure(&p)
        return p
    }

    /// Hand-built toolpaths saved as JSON, for the refusals no generator writes.
    static func handBuilt(_ name: String) throws -> [Toolpath] {
        try JSONDecoder().decode([Toolpath].self, from: Data(contentsOf: fixtures.appendingPathComponent(name + ".toolpaths.json")))
    }

    /// Simulation cells for the tests: coarse enough to keep the suite quick.
    static let cell = 0.5

    static func restart(_ p: Project, job: JobResult? = nil, _ request: Restart.Request) throws -> Restart.Output {
        try Restart.make(p, job: job ?? CAMEngine.generate(p), request: request, date: GoldenPostTests.date, cellSize: cell)
    }

    static func errors(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity == .error }.map(\.text) }

    /// The restart's G-code with the post's "Created" line pinned (the posts write local time).
    static func pinned(_ gcode: String) -> String {
        gcode.replacingOccurrences(of: #"Created: \d{4}-\d\d-\d\d \d\d:\d\d"#, with: "Created: 2027-01-15 08:00", options: .regularExpression)
    }

    static func golden(_ output: Restart.Output, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try GoldenPostTests.check(pinned(output.file.gcode).data(using: .ascii, allowLossyConversion: true)!, golden: name,
                                  sourceLocation: sourceLocation)
    }

    static func lines(_ gcode: String) -> [String] {
        gcode.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)
    }

    // MARK: The approach

    @Test func aPassRestartGoesUpOverThenStopsThenDown() throws {
        let p = try Self.fixture("pocket-ramp")
        let r = try Self.restart(p, Restart.Request(toolpath: 0, start: .pass(2)))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(r.point.pass == 2 && r.point.passCount == 2 && !r.point.exact)
        let l = Self.lines(r.file.gcode)
        // Tool change, dust collection, spindle and dwell, then safe Z, XY, the stop, the spindle again and down.
        let m6 = try #require(l.firstIndex(of: "T1M6"))
        let section = Array(l[m6...].prefix(15))
        #expect(Array(section.prefix(4)) == ["T1M6", "M07", "S13000 M03", "G04 P2.00"], "\(section)")
        // The spindle is off for the stop, as for every program stop.
        #expect(section[5] == "G00 Z0.5000" && section[6].hasPrefix("G00 X") && section[7] == "M05" && section[8].hasPrefix("(MSG,Restart:"),
                "\(section)")
        #expect(Array(section[9...12]) == ["M00", "S13000 M03", "G04 P2.00", "G00 Z0.5000"], "\(section)")
        #expect(section[13].hasPrefix("G00 Z0.") && !section[13].contains("X"), "\(section)")
        // The header's advice.
        for advice in ["RESTART of Ramped pocket", "pass 2 of 2", "re-home, check XY zero", "Re-zero Z with the touch plate",
                       "Jog Z clear of the work before Cycle Start", "Load T1"] {
            #expect(r.file.gcode.contains(advice), "\(advice)")
        }
        #expect(!r.file.gcode.contains("G53"))
        try Self.golden(r, "restart-pass-pocket-inch")
    }

    @Test func aToolpathStartEqualsTheFullFileFromThere() throws {
        let p = try Self.fixture("sign")
        let r = try Self.restart(p, Restart.Request(toolpath: 1, start: .toolpath, pauseAbove: false))
        #expect(r.point.atToolpathStart)
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        // From the pocket's comment on, the restart is the full file's text, word for word.
        let full = Self.lines(r.full.gcode), mine = Self.lines(r.file.gcode)
        let a = try #require(full.firstIndex { $0.hasPrefix("(Toolpath: Pocket plaque") })
        let b = try #require(mine.firstIndex { $0.hasPrefix("(Toolpath: Pocket plaque") })
        #expect(Array(full[a...]) == Array(mine[b...]))
        // The zero spin-up dwell of the default PRO6060 is a warning, not a forced minimum.
        #expect(r.issues.contains { $0.severity == .warning && $0.message.contains("spin-up dwell is 0 s") })
        #expect(!mine.contains { $0.hasPrefix("G04") })
        try Self.golden(r, "restart-toolpath-start-inch")
    }

    @Test func exactModeFeedsStraightDownInMillimetres() throws {
        let p = try Self.fixture("pocket-ramp") { $0.machine.outputUnits = .mm }
        let job = CAMEngine.generate(p)
        let tp = job.toolpaths[0]
        // A motion part way through the second level, at depth.
        let passes = Restart.passStarts(tp, stock: p.stock)
        let k = passes[1] + 40
        #expect(tp.motions[k - 1].end.z < -1)
        let post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date))
        let full = post.post(job.toolpaths)
        let line = try #require(Self.lineOf(motion: k, toolpath: 0, gcode: full, toolpaths: job.toolpaths, project: p))
        let r = try Self.restart(p, job: job, Restart.Request(start: .line(line), exact: true))
        #expect(r.point.exact && r.point.motion == k)
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        let l = Self.lines(r.file.gcode)
        let stop = try #require(l.firstIndex(of: "M00"))
        // After the stop: spindle, dwell, safe Z, the plunge height, then a feed down at the plunge rate.
        #expect(l[stop + 4] == "G00 Z2.540" && l[stop + 5].hasPrefix("G01 Z-") && l[stop + 5].hasSuffix("F1270"), "\(l[stop...].prefix(7))")
        #expect(l.contains { $0.hasPrefix("G00 G94 G21 ") })
        try Self.golden(r, "restart-exact-pocket-mm")
    }

    /// The full-file line of a toolpath's motion (the first cutting move at or after it), as `GCodeCheck.locate` maps it.
    static func lineOf(motion k: Int, toolpath i: Int, gcode: String, toolpaths: [Toolpath], project: Project) -> Int? {
        let paths = toolpaths.filter { !$0.isEmpty }
        guard let program = GCodeCheck.program(gcode, project: project, dialect: .avidMach4) else { return nil }
        let written = GCodeCheck.writtenMoves(program, dialect: .avidMach4)
        let expected = GCodeCheck.expectedMoves(paths, project: project, dialect: .avidMach4)
        return zip(expected, written).first { e, _ in e.toolpathIndex == i && (e.motionIndex ?? -1) >= k }?.1.line
    }

    @Test func aLineInsideAnArcRestartsAtTheArcsStart() throws {
        let p = try Self.fixture("sign")
        let r0 = try Self.restart(p, Restart.Request(toolpath: 1))
        let full = Self.lines(r0.full.gcode)
        // An arc in the pocket's second level.
        let pocket = try #require(full.firstIndex { $0.hasPrefix("(Toolpath: Pocket plaque") })
        let arc = try #require(full.indices.dropFirst(pocket + 200).first { full[$0].hasPrefix("G03") || full[$0].hasPrefix("G02") })
        let r = try Self.restart(p, Restart.Request(start: .line(arc + 1), exact: true))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(r.point.lineText == full[arc])
        // The first cutting move after the feed down is that arc, written from its true start.
        let l = Self.lines(r.file.gcode)
        let stop = try #require(l.firstIndex(of: "M00"))
        let firstArc = try #require(l[stop...].first { $0.hasPrefix("G02") || $0.hasPrefix("G03") })
        #expect(firstArc.prefix(3) == full[arc].prefix(3))
        #expect(firstArc.components(separatedBy: " F")[0] == full[arc].components(separatedBy: " F")[0], "\(firstArc) vs \(full[arc])")
        // Snapped (the default), the same line goes back to the start of its pass.
        let snapped = try Self.restart(p, Restart.Request(start: .line(arc + 1)))
        #expect(!snapped.point.exact && snapped.point.pass == r.point.pass && snapped.point.motion < r.point.motion)
        try Self.golden(r, "restart-line-in-arc")
    }

    @Test func aLineOnAMinimumRetractLinkSnapsToTheNextFeed() throws {
        let p = try Self.fixture("sign")
        let r0 = try Self.restart(p, Restart.Request(toolpath: 1))
        let full = Self.lines(r0.full.gcode)
        // The pocket's second level starts with a rapid down into the first level's floor (a minimum-retract link).
        let pocket = try #require(full.firstIndex { $0.hasPrefix("(Toolpath: Pocket plaque") })
        let link = try #require(full.indices.dropFirst(pocket + 3).first { full[$0].hasPrefix("G00 Z-") })
        let exact = try Self.restart(p, Restart.Request(start: .line(link + 1), exact: true))
        // The rapid isn't a cutting move: the restart starts at the feed after it, whose start is the bottom of the rapid.
        #expect(exact.point.lineText == full[link])
        #expect(exact.point.exact && abs(exact.point.position.z - (-0.0856).inch) < 0.01)
        #expect(Self.errors(exact.issues).isEmpty, "\(Self.errors(exact.issues))")
        let snapped = try Self.restart(p, Restart.Request(start: .line(link + 1)))
        #expect(snapped.point.pass == 2 && snapped.point.position.z >= p.stock.plungeHeight)
    }

    // MARK: Every pass boundary

    /// The material the full file leaves, against what the full program cut before the restart point plus the
    /// restart file read back, at every pass boundary.
    @Test(arguments: ["sign", "pocket-ramp"])
    func everyPassRestartLeavesTheFullJobsMaterial(_ name: String) throws {
        let p = try Self.fixture(name)
        let job = CAMEngine.generate(p)
        let base = try Self.restart(p, job: job, Restart.Request())
        let paths = base.full.toolpaths.filter { !$0.isEmpty }
        let project = base.full.project
        let finished = Self.simulate(paths, stock: project.stock).grid
        var failures: [String] = []
        var count = 0
        for (i, tp) in paths.enumerated() {
            for n in 1...Restart.passStarts(tp, stock: project.stock).count {
                let r = try Self.restart(p, job: job, Restart.Request(toolpath: i, start: n == 1 ? .toolpath : .pass(n)))
                count += 1
                let errors = Self.errors(r.issues)
                if !errors.isEmpty { failures.append("\(tp.name) pass \(n): \(errors)") }
                let program = try GCodeParser.parse(r.file.gcode)
                let parsed = program.toolpaths(tools: paths.map(\.tool), frame: RotaryFrame(project), fallback: tp.tool)
                var partial = tp
                partial.motions = Array(tp.motions[0..<r.point.motion])
                let grid = Self.simulate(paths[0..<i] + [partial] + parsed, stock: project.stock).grid
                let bad = Self.differences(finished, grid)
                if bad > 0 { failures.append("\(tp.name) pass \(n): \(bad) cells differ by more than a cell's shift") }
                failures += Self.sameMovesAfterTheApproach(r, project: project)
            }
        }
        #expect(count > paths.count)
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    /// The wrapped pocket: the restart's toolpaths (the simulator can't read a wrapped file back as a wrapped job) leave
    /// the full job's material, and the file's moves after the approach equal the full file's, A included.
    @Test func everyPassOfAWrappedPocketLeavesTheFullJobsMaterial() throws {
        let p = try Self.fixture("wrapped-rectangle")
        let job = CAMEngine.generate(p)
        let paths = job.toolpaths.filter { !$0.isEmpty }
        let finished = try #require(Self.simulate(paths, stock: p.stock).radialGrid)
        var failures: [String] = []
        let tp = paths[0]
        let passes = Restart.passStarts(tp, stock: p.stock).count
        #expect(passes >= 2)
        for n in 2...passes {
            let r = try Self.restart(p, job: job, Restart.Request(start: .pass(n)))
            let errors = Self.errors(r.issues)
            if !errors.isEmpty { failures.append("pass \(n): \(errors)") }
            var partial = tp
            partial.motions = Array(tp.motions[0..<r.point.motion])
            let grid = try #require(Self.simulate([partial] + r.toolpaths, stock: p.stock).radialGrid)
            let bad = Self.differences(finished.radii, grid.radii, columns: grid.columns, rows: grid.rows)
            if bad > 0 { failures.append("pass \(n): \(bad) cells differ") }
            failures += Self.sameMovesAfterTheApproach(r, project: p)
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    static func simulate(_ toolpaths: [Toolpath], stock: Stock) -> SimulationSession {
        var s = SimulationSession(toolpaths: toolpaths.filter { !$0.motions.isEmpty }, stock: stock, rapidRate: 5000, cellSize: cell)
        s.runToEnd()
        return s
    }

    /// Cells whose heights differ by more than 0.05 mm from every cell within one of them in the other grid.
    static func differences(_ a: HeightGrid, _ b: HeightGrid) -> Int {
        differences(a.heights, b.heights, columns: a.columns, rows: a.rows)
    }

    static func differences(_ a: [Float], _ b: [Float], columns: Int, rows: Int) -> Int {
        var bad = 0
        for r in 0..<rows {
            for c in 0..<columns {
                let v = a[r * columns + c]
                guard abs(v - b[r * columns + c]) > 0.05 else { continue }
                var near = false
                for dr in -1...1 {
                    for dc in -1...1 {
                        let rr = r + dr, cc = c + dc
                        guard rr >= 0, rr < rows, cc >= 0, cc < columns else { continue }
                        if abs(b[rr * columns + cc] - v) <= 0.05 { near = true }
                    }
                }
                if !near { bad += 1 }
            }
        }
        return bad
    }

    /// Where the restart file's cutting moves after its approach differ from the full file's from the restart point:
    /// their ends, A words and feeds (inverse time included), read back from both files.
    static func sameMovesAfterTheApproach(_ r: Restart.Output, project: Project) -> [String] {
        let dialect = r.post.dialect
        guard let fullProgram = GCodeCheck.program(r.full.gcode, project: r.full.project, dialect: dialect),
              let restartProgram = GCodeCheck.program(r.file.gcode, project: r.file.project, dialect: dialect) else { return ["unreadable"] }
        let paths = r.full.toolpaths.filter { !$0.isEmpty }
        let expected = GCodeCheck.expectedMoves(paths, project: r.full.project, dialect: dialect).filter { $0.kind != .dwell }
        let written = GCodeCheck.writtenMoves(fullProgram, dialect: dialect).filter { $0.motion.kind != .dwell }
        guard let from = expected.prefix(written.count).firstIndex(where: { e in
            e.toolpathIndex > r.point.toolpath || (e.toolpathIndex == r.point.toolpath && (e.motionIndex ?? -1) >= r.point.motion)
        }) else { return ["no full-file move at the restart point"] }
        let fullTail = Array(written[from...])
        var mine = GCodeCheck.writtenMoves(restartProgram, dialect: dialect).filter { $0.motion.kind != .dwell }
        if r.point.exact { mine.removeFirst() }
        guard mine.count == fullTail.count else { return ["\(mine.count) moves after the approach, \(fullTail.count) in the full file"] }
        for (a, b) in zip(mine, fullTail) {
            if a.motion.end.distance(to: b.motion.end) > 1e-6 || a.motion.kind != b.motion.kind {
                return ["line \(a.line): ends at \(a.motion.end), full file line \(b.line) at \(b.motion.end)"]
            }
            if a.motion.a != b.motion.a { return ["line \(a.line): A \(String(describing: a.motion.a)) vs \(String(describing: b.motion.a))"] }
            if abs(a.motion.feed - b.motion.feed) > 1e-6 || a.motion.inverseTime != b.motion.inverseTime {
                return ["line \(a.line): feed \(a.motion.feed)/\(String(describing: a.motion.inverseTime)) vs line \(b.line)"]
            }
        }
        return []
    }

    // MARK: Rotary

    @Test func aWrappedRestartContinuesTheFullFilesAWords() throws {
        let p = try Self.fixture("wrapped-rounding")
        let job = CAMEngine.generate(p)
        let base = try Self.restart(p, job: job, Restart.Request(toolpath: 1))
        let full = Self.lines(base.full.gcode)
        // A line well into the rounding, several turns round.
        let n = try #require(full.indices.first { full[$0].contains(" A4") && full[$0].hasPrefix("G01 Z") && $0 > 500 })
        let r = try Self.restart(p, job: job, Restart.Request(start: .line(n + 1), exact: true))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(Self.sameMovesAfterTheApproach(r, project: p).isEmpty, "\(Self.sameMovesAfterTheApproach(r, project: p))")
        let a = try #require(r.expectedA)
        #expect(a > 3600)
        let l = Self.lines(r.file.gcode)
        // A at safe Z, before the stop; the first turning line goes into G93 with its F.
        let turn = try #require(l.firstIndex(of: "G00 A\(String(format: "%.3f", a))"))
        let stop = try #require(l.firstIndex(of: "M00"))
        #expect(turn < stop && l[turn - 2] == "G00 Z40.435")
        let g93 = try #require(l.first { $0.hasPrefix("G93") })
        #expect(g93.hasPrefix("G93 G01") && g93.contains(" F"))
        #expect(r.file.gcode.contains("A over the restart point: A\(String(format: "%.3f", a)) = \(Int(a / 360)) turns"))
        // The rounding's G94 comes back before the slot.
        #expect(l.firstIndex(of: "G94")! > l.firstIndex(of: g93)!)
        try Self.golden(r, "restart-wrapped-g93")
    }

    @Test func anIndexedFaceAfterRoundingKeepsTheTurnsTheRoundingMade() throws {
        let p = try Self.fixture("wrapped-rounding")
        let r = try Self.restart(p, Restart.Request(toolpath: 1))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        // The slot is cut a whole number of turns on, where the rounding left the blank: no unwinding first.
        let a = try #require(r.expectedA)
        #expect(a > 3600 && abs(a.remainder(dividingBy: 360)) < 1e-6)
        #expect(Self.lines(r.full.gcode).contains("G00 A\(String(format: "%.3f", a))"))
        try Self.golden(r, "restart-indexed-after-rounding")
    }

    @Test func aBlankTurnedByHandIsAskedForFirst() throws {
        let p = try Self.fixture("by-hand-grbl")
        let job = CAMEngine.generate(p)
        let r = try Self.restart(p, job: job, Restart.Request(file: 1, toolpath: 1))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(r.fileCount == 2 && r.file.suffix == " (restart at toolpath 2) 2 of 2 - T2")
        let l = Self.lines(r.file.gcode)
        // The stop to turn the blank comes before the tool's first move.
        let turn = try #require(l.firstIndex { $0.contains("Turn the blank") || $0.contains("turn the blank") })
        let firstMove = try #require(l.firstIndex { $0.hasPrefix("G0 X") })
        #expect(turn < firstMove)
        try Self.golden(r, "restart-by-hand-grbl")
    }

    @Test func wrappedRestartsOnTheGenericPost() throws {
        for (name, family, units) in [("linuxcnc", ControllerFamily.linuxCNC, LengthUnit.mm), ("grblhal", .grblHAL, .inch)] {
            let p = try Self.fixture("wrapped-rectangle", ControllerPostTests.controller(family, units: units))
            let r = try Self.restart(p, Restart.Request(start: .pass(2)))
            #expect(Self.errors(r.issues).isEmpty, "\(name): \(Self.errors(r.issues))")
            #expect(Self.sameMovesAfterTheApproach(r, project: p).isEmpty, "\(name): \(Self.sameMovesAfterTheApproach(r, project: p))")
            try Self.golden(r, "restart-\(name)-wrapped")
        }
    }

    // MARK: Files of a job

    @Test func aSplitJobRestartsOneToolsFile() throws {
        let p = try Self.fixture("split-per-tool-grbl")
        let r = try Self.restart(p, Restart.Request(file: 1, toolpath: 0, start: .pass(2)))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(r.file.suffix == " (restart at toolpath 1 pass 2) 2 of 2 - T1")
        #expect(Set(r.toolpaths.map(\.tool.number)) == [1])
        #expect(!r.file.gcode.contains("T5"))
        try Self.golden(r, "restart-split-grbl")
    }

    @Test func aTileKeepsItsDowelStopOnlyFromTheToolpathStart() throws {
        let p = try Self.fixture("tiled")
        let job = CAMEngine.generate(p)
        let start = try Self.restart(p, job: job, Restart.Request(file: 1, toolpath: 0))
        let mid = try Self.restart(p, job: job, Restart.Request(file: 1, toolpath: 0, start: .pass(2)))
        let dowel = try #require(start.toolpaths[0].spindleOffStop)
        #expect(start.file.gcode.contains("MSG,\(dowel.prefix(20))"))
        #expect(mid.toolpaths[0].spindleOffStop == nil && !mid.file.gcode.contains("MSG,\(dowel.prefix(20))"))
        #expect(start.file.suffix == " (restart at toolpath 1) - tile 2 of 4")
        for r in [start, mid] { #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))") }
        try Self.golden(start, "restart-tile-2-start")
        try Self.golden(mid, "restart-tile-2-mid")
    }

    // MARK: Options

    @Test func aRouterIsToldItsDialAgainAfterTheStop() throws {
        let p = try Self.fixture("pocket-ramp") { $0.machine.spindle = .router }
        let r = try Self.restart(p, Restart.Request(start: .pass(2)))
        let l = Self.lines(r.file.gcode)
        let stop = try #require(l.firstIndex(of: "M00"))
        #expect(l[stop + 1].hasPrefix("(Set router speed dial to about 13000 RPM") && l[..<stop].contains { $0.hasPrefix("(Set router speed dial") })
        try Self.golden(r, "restart-router-dial")
    }

    @Test func anAirCutRestartRaisesEveryZ() throws {
        let p = try Self.fixture("sign")
        let r = try Self.restart(p, Restart.Request(toolpath: 1, start: .pass(2), airCut: 1.inch))
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(r.file.suffix == " (air cut) (restart at toolpath 2 pass 2)")
        #expect(r.file.gcode.contains("AIR CUT: Z raised 1.0000 in"))
        #expect(Self.lines(r.file.gcode).contains("G00 Z1.5000"))
        try Self.golden(r, "restart-air-cut")
    }

    @Test func noStopWhenTurnedOff() throws {
        let p = try Self.fixture("pocket-ramp")
        let r = try Self.restart(p, Restart.Request(start: .pass(2), pauseAbove: false))
        #expect(!r.file.gcode.contains("M00") && r.seed.pause == nil)
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
    }

    @Test func aThreeDFinishRestartsAtAPass() throws {
        var p = Project.demoRelief()
        p.machine.spindleSpinUpDwell = 2
        let job = CAMEngine.generate(p)
        let paths = job.toolpaths.filter { !$0.isEmpty }
        // The raster finish, a few rows from its end, exactly at a move (its rows don't lift between them).
        let i = try #require(paths.firstIndex { $0.name == "Finish relief" })
        let post = try #require(PostProcessors.post(for: p, date: GoldenPostTests.date))
        let full = post.post(job.toolpaths)
        let k = paths[i].motions.count - 400
        let line = try #require(Self.lineOf(motion: k, toolpath: i, gcode: full, toolpaths: job.toolpaths, project: p))
        let r = try Self.restart(p, job: job, Restart.Request(start: .line(line), exact: true))
        #expect(r.point.toolpath == i && r.point.exact)
        #expect(Self.errors(r.issues).isEmpty, "\(Self.errors(r.issues))")
        #expect(Self.sameMovesAfterTheApproach(r, project: p).isEmpty, "\(Self.sameMovesAfterTheApproach(r, project: p))")
        try Self.golden(r, "restart-3d-finish")
    }

    @Test func theRunningFileIsNamedAndCompared() throws {
        let p = try Self.fixture("sign")
        let job = CAMEngine.generate(p)
        let running = try Self.restart(p, job: job, Restart.Request()).full.gcode
        let same = try Self.restart(p, job: job, Restart.Request(toolpath: 1, runningFile: running, runningFileName: "Sign.tap"))
        #expect(Self.errors(same.issues).isEmpty)
        #expect(same.file.gcode.contains("(RESTART of Sign.tap)") && same.file.gcode.contains("(Full file created 2"))
        // A project edited since: the file that was running no longer matches.
        var edited = Self.lines(running)
        let k = try #require(edited.firstIndex { $0.hasPrefix("G01 X") })
        edited[k] = "G01 X1.0000 Y1.0000"
        let changed = try Self.restart(p, job: job, Restart.Request(toolpath: 1, runningFile: edited.joined(separator: "\r\n")))
        #expect(Self.errors(changed.issues).contains { $0.contains("isn't what this project writes now") })
    }

    // MARK: Refusals

    @Test func aPointPastTheEndIsRefused() throws {
        let p = try Self.fixture("sign")
        let job = CAMEngine.generate(p)
        for request in [Restart.Request(toolpath: 4), Restart.Request(toolpath: 1, start: .pass(3)), Restart.Request(start: .line(5000)),
                        Restart.Request(file: 1)] {
            #expect(throws: Restart.Refusal.self, "\(request.start)") { try Self.restart(p, job: job, request) }
        }
        // The last lines of the file (the footer) are past the last cutting move too.
        let last = Self.lines(try Self.restart(p, job: job, Restart.Request()).full.gcode).count - 2
        #expect(throws: Restart.Refusal.self) { try Self.restart(p, job: job, Restart.Request(start: .line(last))) }
    }

    @Test func aCalibrationProgramIsRefused() throws {
        let program = try Calibration.timing(machine: .avidPRO6060, date: GoldenPostTests.date)
        let job = JobResult(toolpaths: program.toolpaths, issues: [])
        do {
            _ = try Self.restart(program.project, job: job, Restart.Request(toolpath: 1))
            Issue.record("A calibration program was restarted")
        } catch let r as Restart.Refusal {
            #expect(r.message.contains("calibration program"))
        }
    }

    @Test func aRotaryJobOnAVectricPostIsRefused() throws {
        // Built here rather than saved: a Vectric post writes the rounding's unrolled sheet as Y, which the fixture-wide
        // travel check would (rightly) flag.
        var p = RoundingTests.job()
        p.machine.customPost = try VectricPost.parse(VectricPostTests.mach4Style)
        do {
            _ = try Self.restart(p, Restart.Request())
            Issue.record("A rotary job on a Vectric post was restarted")
        } catch let r as Restart.Refusal {
            #expect(r.message.contains("imported Vectric post"))
        }
    }

    @Test func anExactPlungeIntoMaterialIsRefused() throws {
        let p = try Self.fixture("sign")
        let job = JobResult(toolpaths: try Self.handBuilt("exact-into-material"), issues: [])
        let line = try #require(Self.lines(try Self.restart(p, job: job, Restart.Request()).full.gcode).firstIndex { $0.hasPrefix("G01 X3.1496") })
        do {
            _ = try Self.restart(p, job: job, Restart.Request(start: .line(line + 1), exact: true))
            Issue.record("An exact plunge into material was written")
        } catch let r as Restart.Refusal {
            #expect(r.message.hasPrefix("Exact restart refused"), "\(r.message)")
        }
        // Snapped back to the start of the pass, it's fine.
        let snapped = try Self.restart(p, job: job, Restart.Request(start: .line(line + 1)))
        #expect(snapped.point.atToolpathStart)
    }

    @Test func anApproachThroughMaterialIsRefused() throws {
        let p = try Self.fixture("sign")
        let job = JobResult(toolpaths: try Self.handBuilt("rapid-into-material"), issues: [])
        do {
            _ = try Self.restart(p, job: job, Restart.Request(start: .pass(2)))
            Issue.record("An approach through material was written")
        } catch let r as Restart.Refusal {
            #expect(r.message.contains("rapids through material"), "\(r.message)")
        }
    }

    @Test func thePlayHeadGivesThePassItIsIn() throws {
        let p = try Self.fixture("pocket-ramp")
        let job = CAMEngine.generate(p)
        let tp = job.toolpaths[0]
        let passes = Restart.passStarts(tp, stock: p.stock)
        // Part way through the second pass.
        var start = tp.start
        for m in tp.motions[0..<(passes[1] + 30)] where m.kind != .dwell { start = m.end }
        let request = try #require(Restart.request(at: tp, start: start, project: p, job: job))
        #expect(request.file == 0 && request.toolpath == 0 && request.start == .pass(2))
        let second = try #require(Restart.request(at: job.toolpaths[1], start: job.toolpaths[1].start, project: p, job: job))
        #expect(second.toolpath == 1 && second.start == .toolpath)
    }

    // MARK: Command line

    @Test func theCommandLineWritesARestartAndRefusesOne() throws {
        let dir = try CommandLineTests.folder()
        let project = Self.fixtures.appendingPathComponent("pocket-ramp.nativecam").path
        let out = dir.appendingPathComponent("Pocket.tap").path
        let ok = try CommandLineTests.run(["post", project, "-o", out, "--restart-toolpath", "1", "--restart-pass", "2"])
        #expect(ok.status == 0, "\(ok.output)")
        let written = dir.appendingPathComponent("Pocket (restart at toolpath 1 pass 2).tap").path
        #expect(FileManager.default.fileExists(atPath: written), "\(ok.output)")
        #expect(ok.output.contains("Estimated run time of the restart"))
        let refused = try CommandLineTests.run(["post", project, "-o", out, "--restart-toolpath", "1", "--restart-pass", "9", "--force"])
        #expect(refused.status == 1 && refused.output.contains("Restart refused"), "\(refused.output)")
    }
}
