import Foundation

/// What a restart file's post needs from the full program it replaces (`Restart`), for the file's first toolpath.
public struct RestartSeed: Hashable, Sendable {
    /// The A value the full program had last written before the restart toolpath; nil when it had written none.
    public var lastA: Double?
    /// On a wrapped toolpath restarted part way through, the whole turns the full program added to its A words, so
    /// every A word equals the full file's (`WrappedWriter.approach`). nil otherwise.
    public var wrapOffset: Double?
    /// The message of the stop with the tool over the restart point at safe Z; nil for no stop.
    public var pause: String?

    public init(lastA: Double? = nil, wrapOffset: Double? = nil, pause: String? = nil) {
        self.lastA = lastA
        self.wrapOffset = wrapOffset
        self.pause = pause
    }
}

/// A restart file: the rest of a job from a point part way through it, for after a broken bit, a power cut or an
/// E-stop. Like an air cut (`AirCut`), it's an export-time choice and nothing is saved in the project.
///
/// The restart cuts down the full job's toolpaths rather than generating a subset, so later toolpaths keep the
/// material the earlier ones left, and the rotary state is the full program's: every A word equals the full file's.
/// The file goes through the normal post and `GCodeCheck`, so it starts as every NativeCAM file does: the safety
/// line, the tool change (always, even when the bit didn't change, so Z is measured again), the spindle and its
/// spin-up dwell, the dust collector and G94. Then, for the restart toolpath:
///
/// 1. up to safe Z, then over the restart point, then the turn of the blank;
/// 2. a stop (`MSG` + `M00`), on by default, so the operator can check the position, then the spindle and its
///    dwell again;
/// 3. down to the plunge height, and from there the toolpath's own entry at the start of the pass, or a feed straight
///    down at the tool's plunge rate in exact mode.
///
/// It's never a diagonal, and never a rapid to depth.
public enum Restart {
    /// Where the restart starts in the chosen toolpath.
    public enum Start: Hashable, Sendable {
        /// The start of the toolpath.
        case toolpath
        /// Pass n (from 1) of the toolpath (`passStarts`).
        case pass(Int)
        /// The cutting move on line n (from 1, as a text editor counts) of the full file, or the next one after it.
        /// `Request.toolpath` is ignored.
        case line(Int)
    }

    public struct Request: Hashable, Sendable {
        /// The file of the job that was running, from 0 (`JobExport.files`): a tile, a sheet or one tool's file.
        public var file: Int
        /// The toolpath, from 0 in the file's run order (its toolpaths that cut anything).
        public var toolpath: Int
        public var start: Start
        /// Restart at the move itself, fed straight down to it, rather than at the start of its pass. Refused where the
        /// feed down would cut material.
        public var exact: Bool
        /// Stop with the tool over the restart point at safe Z, before it feeds down.
        public var pauseAbove: Bool
        /// Raise every Z by this much (mm) for an air cut of the restart; nil for none.
        public var airCut: Double?
        /// The text of the file that was running, when it's at hand: the restart names its "Created" stamp, and it's
        /// an error when this project no longer writes the same program.
        public var runningFile: String?
        /// The name of the file that was running, for the header.
        public var runningFileName: String?

        public init(file: Int = 0, toolpath: Int = 0, start: Start = .toolpath, exact: Bool = false, pauseAbove: Bool = true,
                    airCut: Double? = nil, runningFile: String? = nil, runningFileName: String? = nil) {
            self.file = file
            self.toolpath = toolpath
            self.start = start
            self.exact = exact
            self.pauseAbove = pauseAbove
            self.airCut = airCut
            self.runningFile = runningFile
            self.runningFileName = runningFileName
        }
    }

    /// Where a restart starts, resolved from a `Request`.
    public struct Point: Hashable, Sendable {
        public var file: Int
        /// The toolpath, from 0 in the file's run order.
        public var toolpath: Int
        /// The first of the toolpath's motions the restart cuts again.
        public var motion: Int
        /// The pass that motion is in (from 1), and how many the toolpath has.
        public var pass: Int
        public var passCount: Int
        /// Where the cut resumes: the tool tip before `motion` (design coordinates, mm).
        public var position: Vec3
        /// The full-file line asked for, and its text.
        public var line: Int?
        public var lineText: String?
        /// True when the restart feeds straight down to `position` rather than running the pass's own entry.
        public var exact: Bool
        /// True when the restart is the whole toolpath, unchanged.
        public var atToolpathStart: Bool { motion == 0 }
    }

    /// Why a restart can't be written.
    public struct Refusal: Error, Hashable, Sendable, LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Output: Sendable {
        /// The restart file, its toolpaths and the project to check it against, as raised for an air cut.
        public var file: JobExport.File
        /// The file of the full job it replaces.
        public var full: JobExport.File
        public var post: any PostProcessor
        public var point: Point
        public var seed: RestartSeed
        /// The restart's toolpaths at their real heights: the cut-down one, then the rest of the file.
        public var toolpaths: [Toolpath]
        /// The restart's own findings (warnings) and `GCodeCheck` on the file.
        public var issues: [GCodeCheck.Issue]
        /// How long the restart runs, seconds.
        public var remainingSeconds: Double
        /// The A value the blank is at over the restart point, as written; nil on a flat job or a blank turned by hand.
        public var expectedA: Double?
        /// The header's comment lines (without comment marks), for showing.
        public var header: [String]
        /// How many files the full job has.
        public var fileCount: Int
    }

    /// The message of the stop above the restart point.
    public static let pauseMessage = "Restart: check the tool is over the restart point, then go on"

    /// The first motion of each pass of a toolpath: after a rapid that ends at or above the plunge height (and at 0 for
    /// the first), with a cutting move before the next such rapid. Rapids that stay below the plunge height (a
    /// minimum-retract link, a rapid down a cleared column) don't start a pass.
    public static func passStarts(_ tp: Toolpath, stock: Stock) -> [Int] {
        var out: [Int] = []
        var candidate: Int? = 0
        for (k, m) in tp.motions.enumerated() {
            switch m.kind {
            case .rapid:
                if m.end.z >= stock.plungeHeight - 1e-6 { candidate = k + 1 }
            case .dwell:
                continue
            default:
                if let c = candidate {
                    out.append(c)
                    candidate = nil
                }
            }
        }
        return out
    }

    /// The restart request for the play head of a simulation: the file and toolpath `toolpath` (a toolpath of `job`) is
    /// cut in, and the pass holding the move that starts at `start`. nil when the toolpath isn't in any of the job's files.
    public static func request(at toolpath: Toolpath, start: Vec3, project: Project, job: JobResult) -> Request? {
        guard let export = JobExport.files(project, job: job) else { return nil }
        for (f, file) in export.files.enumerated() {
            let paths = file.toolpaths.filter { !$0.isEmpty }
            guard let i = paths.firstIndex(where: { $0.id == toolpath.id }) else { continue }
            let tp = paths[i]
            // The motion that starts at the play head (the file's toolpath can differ: arcs cut as lines, a tile's frame).
            var k = 0, p = tp.start
            for (j, m) in tp.motions.enumerated() {
                if p.distance(to: start) < 1e-6 && m.kind != .rapid { k = j; break }
                if m.kind != .dwell { p = m.end }
            }
            let pass = max(1, passStarts(tp, stock: file.project.stock).lastIndex { $0 <= k }.map { $0 + 1 } ?? 1)
            return Request(file: f, toolpath: i, start: pass == 1 ? .toolpath : .pass(pass))
        }
        return nil
    }

    /// The restart file for `request`, checked. Throws a `Refusal` when it can't be written safely.
    public static func make(_ project: Project, job: JobResult, request: Request, date: Date = Date(),
                            cellSize: Double? = nil) throws -> Output {
        if job.toolpaths.contains(where: { $0.stopMessage != nil }) {
            throw Refusal("A calibration program isn't a job to restart: run it again from the start.")
        }
        if project.machine.customPost != nil, project.stock.rotary != nil {
            throw Refusal("A restart on a rotary job needs NativeCAM's own post for the controller: an imported Vectric post "
                + "can't be given the A position the full program had reached.")
        }
        guard let export = JobExport.files(project, job: job, date: date) else {
            throw Refusal(PostProcessors.unavailableReason(for: project.machine) ?? "No post processor for this machine.")
        }
        guard export.files.indices.contains(request.file) else {
            throw Refusal("The job has \(export.files.count) file\(export.files.count == 1 ? "" : "s"); there's no file \(request.file + 1).")
        }
        let full = export.files[request.file]
        let paths = full.toolpaths.filter { !$0.isEmpty }
        let stock = full.project.stock
        let dialect = export.post.dialect

        // The toolpath and motion the restart starts at.
        var i = request.toolpath, k = 0
        var line: Int?, lineText: String?
        switch request.start {
        case .toolpath, .pass:
            guard paths.indices.contains(i) else {
                throw Refusal("The file has \(paths.count) toolpaths; toolpath \(i + 1) is past its end.")
            }
            if case let .pass(n) = request.start {
                let passes = passStarts(paths[i], stock: stock)
                guard n >= 1, n <= passes.count else {
                    throw Refusal("“\(paths[i].name)” has \(passes.count) pass\(passes.count == 1 ? "" : "es"); pass \(n) is past its end.")
                }
                k = n == 1 ? 0 : passes[n - 1]
            }
        case let .line(n):
            line = n
            let text = request.runningFile ?? full.gcode
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            if n >= 1, n <= lines.count { lineText = String(lines[n - 1]) }
            guard n >= 1, let found = GCodeCheck.locate(line: n, in: full.gcode, toolpaths: paths, project: full.project, dialect: dialect) else {
                throw Refusal(n < 1 ? "Lines count from 1." : "Line \(n) is past the last cutting move of the file: there's nothing left to cut.")
            }
            i = found.toolpath
            k = found.motion
        }
        let tp = paths[i]
        let passes = passStarts(tp, stock: stock)
        // Snap back to the start of the pass unless the restart is exact; the first pass is the toolpath's start.
        let pass = max(1, passes.lastIndex { $0 <= k }.map { $0 + 1 } ?? 1)
        if !request.exact || k <= (passes.first ?? 0) { k = pass == 1 ? 0 : passes[pass - 1] }
        var position = tp.start
        for m in tp.motions[0..<k] where m.kind != .dwell { position = m.end }
        let exact = request.exact && k > 0 && position.z < stock.plungeHeight - 1e-6
        let point = Point(file: request.file, toolpath: i, motion: k, pass: pass, passCount: passes.count, position: position,
                          line: line, lineText: lineText, exact: exact)

        // The cut-down toolpath: over the restart point at safe Z, down to the plunge height, then (exact) a feed down
        // to the point at the plunge rate, then the toolpath's own moves.
        var cut = tp
        var approach: [Motion] = []
        if k > 0 {
            cut.start = Vec3(position.xy, max(stock.clearanceHeight, position.z))
            if position.z < stock.plungeHeight - 1e-6 {
                approach = [.rapid(Vec3(position.xy, stock.plungeHeight)), .feed(position, tp.tool.cutting.plungeRate)]
            } else if position.z < cut.start.z - 1e-9 {
                approach = [.rapid(position)]
            }
            cut.motions = approach + tp.motions[k...]
            cut.spindleOffStop = nil
        }
        let restart = [cut] + paths[(i + 1)...]

        // The full program's rotary state before the restart toolpath.
        var seed = RestartSeed(pause: request.pauseAbove ? pauseMessage : nil)
        var expectedA: Double?
        if let rotary = RotaryOutput(full.project) {
            let frame = RotaryFrame(full.project)
            let writer = WrappedWriter(frame: frame, rotary: rotary, units: full.project.machine.outputUnits, decimals: 4, feedDecimals: 1,
                                       feeds: .inverseTime, turnSpeed: .infinity, rapidWord: "G0", feedWord: "G1", dwell: { _ in "" })
            let before = rotaryState(paths[0..<i], rotary: rotary, writer: writer, stock: stock)
            seed.lastA = before
            if tp.wrapDiameter != nil {
                struct State: WrapModalState { var x: Double?, y: Double?, z: Double?, feed: Double?, a: Double? }
                var state = State()
                let offset = writer.approach(tp, state: &state, after: before).offset
                if k > 0 { seed.wrapOffset = offset }
                var at = State()
                _ = writer.approach(cut, state: &at, after: before, offset: offset)
                expectedA = at.a
            } else if !rotary.manual, let angle = tp.indexAngle {
                expectedA = RotaryOutput.nearestTurn(rotary.value(angle), after: before)
            }
        }

        var issues: [GCodeCheck.Issue] = []
        if project.machine.spindleSpinUpDwell <= 0 {
            issues.append(GCodeCheck.Issue(.warning, "The machine's spin-up dwell is 0 s, so the restart feeds in as soon as the spindle "
                + "is told to start. Wait for it to reach speed at the stop, or set a dwell in Material & Machine."))
        }
        if request.pauseAbove, project.machine.customPost != nil {
            issues.append(GCodeCheck.Issue(.warning, "An imported Vectric post can't write the stop above the restart point: "
                + "the restart feeds down without stopping."))
        }

        // Simulate what the full program had cut before the restart point, then the approach.
        if k > 0 {
            // The files of the same tile and sheet before this one (a job split per tool) cut the same material.
            let earlier = export.files[..<request.file].filter { $0.tile == full.tile && $0.sheet == full.sheet }
                .flatMap { $0.toolpaths.filter { !$0.isEmpty } }
            var partial = tp
            partial.motions = Array(tp.motions[0..<k])
            // The approach, and the toolpath's own rapids after it up to its first cut (a rapid down a cleared column).
            var down = cut
            down.motions = approach + tp.motions[k...].prefix { $0.kind == .rapid }
            let sim = approachCheck(prefix: earlier + paths[0..<i] + [partial], approach: down, stock: stock,
                                    machine: full.project.machine, cellSize: cellSize)
            if sim.collisions > 0 {
                throw Refusal("The approach to the restart point rapids through material the simulation still has there at that point of the job. "
                    + "Restart at the start of the pass or of the toolpath instead.")
            }
            let r = tp.tool.radius
            let tolerance = max(1.0, Double.pi * r * r * 0.1)
            if exact, sim.removed > tolerance {
                throw Refusal("Exact restart refused: the feed straight down to the restart point would cut "
                    + String(format: "%.0f", sim.removed) + " mm³ of material the earlier moves hadn't cleared, and could break the bit. "
                    + "Restart at the start of the pass instead.")
            }
        }

        // Post the restart, raised for an air cut when asked.
        var postProject = full.project
        var postPaths = restart
        if let height = request.airCut { (postProject, postPaths) = AirCut.raise(full.project, restart, by: height) }
        guard let post = PostProcessors.post(for: postProject, date: date, restart: seed) else {
            throw Refusal(PostProcessors.unavailableReason(for: project.machine) ?? "No post processor for this machine.")
        }
        let posted = post.files(postPaths)
        let header = headerLines(project: full.project, full: full, request: request, point: point, paths: paths, expectedA: expectedA,
                                 rotary: RotaryOutput(full.project), date: date, airCut: request.airCut)
        let headerText = header.map { comment($0, dialect: dialect) }.compactMap { $0 }.map { $0 + dialect.lineEnding }.joined()
        let gcode = headerText + posted.map(\.gcode).joined()
        let checkPaths = posted.flatMap(\.toolpaths)
        issues += GCodeCheck.run(gcode, toolpaths: checkPaths, project: postProject, dialect: post.dialect, restart: seed)

        if let running = request.runningFile, let difference = firstDifference(running, full.gcode) {
            issues.append(GCodeCheck.Issue(.error, line: difference,
                "The file that was running isn't what this project writes now (they differ from line \(difference)), so the restart "
                + "would cut something else from the half-cut part. Restart from the project as it was when that file was written."))
        }

        var suffix = request.airCut == nil ? "" : " (air cut)"
        suffix += " (restart at toolpath \(i + 1)" + (point.atToolpathStart ? "" : " pass \(pass)") + ")"
        suffix += full.suffix ?? ""
        let file = JobExport.File(suffix: suffix, gcode: gcode, toolpaths: checkPaths, project: postProject, tile: full.tile, sheet: full.sheet)
        let remaining = CycleTimeEstimator.estimate(restart, project: full.project).total
        return Output(file: file, full: full, post: post, point: point, seed: seed, toolpaths: restart, issues: issues,
                      remainingSeconds: remaining, expectedA: expectedA, header: header, fileCount: export.files.count)
    }

    /// The A value last written after `paths`, as the posts write them (`RotaryOutput.cutRange`).
    static func rotaryState(_ paths: ArraySlice<Toolpath>, rotary: RotaryOutput, writer: WrappedWriter, stock: Stock) -> Double? {
        struct State: WrapModalState { var x: Double?, y: Double?, z: Double?, feed: Double?, a: Double? }
        var state = State()
        var lastA: Double?
        for tp in paths {
            state.z = writer.round(stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z)
            if tp.wrapDiameter != nil {
                let approach = writer.approach(tp, state: &state, after: lastA)
                _ = writer.motions(tp, state: &state, offset: approach.offset)
                lastA = state.a ?? lastA
                continue
            }
            if !rotary.manual, let angle = tp.indexAngle {
                let target = RotaryOutput.nearestTurn(rotary.value(angle), after: lastA)
                state.a = target
                lastA = target
            }
        }
        return lastA
    }

    /// Simulates `prefix`, then `approach`, and returns what the approach removed (mm³) and how many of its rapids hit
    /// material.
    static func approachCheck(prefix: [Toolpath], approach: Toolpath, stock: Stock, machine: MachineProfile, cellSize: Double?)
        -> (removed: Double, collisions: Int) {
        let toolpaths = prefix.filter { !$0.motions.isEmpty } + [approach]
        var session = SimulationSession(toolpaths: toolpaths, stock: stock, rapidRate: machine.rapidRateForEstimates, cellSize: cellSize,
                                        turnSpeed: machine.rotary?.drivenTurnSpeed)
        func removed(_ s: SimulationSession) -> Double {
            s.faces.indices.reduce(0) { $0 + s.grid(face: $1).removedVolume } + (s.radialGrid?.removedVolume ?? 0)
        }
        let last = toolpaths.count - 1
        let start = session.timeline.steps.first { $0.toolpathIndex == last }?.startTime ?? session.timeline.duration
        session.seek(to: start)
        let before = (removed(session), session.rapidCollisions.count)
        session.runToEnd()
        return (max(0, removed(session) - before.0), session.rapidCollisions.count - before.1)
    }

    /// The header's lines.
    static func headerLines(project: Project, full: JobExport.File, request: Request, point: Point, paths: [Toolpath],
                            expectedA: Double?, rotary: RotaryOutput?, date: Date, airCut: Double?) -> [String] {
        let tp = paths[point.toolpath]
        let name = request.runningFileName ?? ((project.name.isEmpty ? "Untitled" : project.name) + (full.suffix ?? ""))
        var out = ["RESTART of \(name)"]
        if let running = request.runningFile,
           let created = running.split(whereSeparator: { $0.isNewline }).first(where: { $0.contains("Created:") }) {
            let stamp = created.components(separatedBy: "Created:").last?.trimmingCharacters(in: CharacterSet(charactersIn: " )")) ?? ""
            out.append("Full file created \(stamp)")
        } else {
            out.append("Full file: this project as it is now. Check it matches")
        }
        var at = "Starts at toolpath \(point.toolpath + 1) of \(paths.count): \(tp.name)"
        at += point.atToolpathStart ? ", from its start" : ", pass \(point.pass) of \(point.passCount)"
        out.append(at)
        if let line = point.line {
            out.append("Line \(line) of the full file" + (point.lineText.map { ": \($0.trimmingCharacters(in: .whitespaces))" } ?? ""))
        }
        if point.exact { out.append("Exact: feeds straight down to that move") }
        out.append("Load T\(tp.tool.number) \(tp.tool.name), the same bit")
        out.append("After a power cut or E-stop: re-home, check XY zero on setup sheet")
        out.append("Re-zero Z with the touch plate at the tool change, same bit or not")
        out.append("Jog Z clear of the work before Cycle Start")
        if let rotary, let a = expectedA {
            let turns = Int((a / 360).rounded(.towardZero))
            let rest = a - Double(turns) * 360
            out.append("A over the restart point: \(rotary.word(value: a))"
                + (turns == 0 ? "" : " = \(turns) turns + \(String(format: "%.3f", rest)) deg"))
        } else if let rotary, rotary.manual, let angle = tp.indexAngle {
            out.append("The blank is turned by hand: the restart asks for \(RotaryIndex.label(rotary.position(angle))) first")
        }
        if request.pauseAbove { out.append("Stops over the restart point at safe Z, spindle off, to check it") }
        if let airCut {
            let u = project.machine.outputUnits
            out.append("AIR CUT: Z raised \(String(format: "%.\(u == .inch ? 4 : 3)f", u.fromMM(airCut))) \(u.symbol), X and Y unchanged")
        }
        return out
    }

    /// A comment line in the dialect, cleaned for strict parsers; nil when the controller's files carry no comments.
    static func comment(_ text: String, dialect: Dialect) -> String? {
        guard dialect.writesComments else { return nil }
        var cleaned = text.replacingOccurrences(of: "(", with: "{")
            .replacingOccurrences(of: ")", with: "}")
            .replacingOccurrences(of: "\"", with: "in")
            .replacingOccurrences(of: "°", with: "deg")
            .replacingOccurrences(of: "“", with: "'")
            .replacingOccurrences(of: "”", with: "'")
            .unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
            .map(String.init).joined()
        if let limit = dialect.maxLineLength, cleaned.count > limit - 2 { cleaned = String(cleaned.prefix(max(0, limit - 2))) }
        return dialect.language == .openSBP ? "'" + cleaned : "(" + cleaned + ")"
    }

    /// The first line (from 1) where two programs differ, leaving out their "Created" lines; nil when they're the same.
    static func firstDifference(_ a: String, _ b: String) -> Int? {
        let x = a.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        let y = b.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for n in 0..<max(x.count, y.count) {
            let l = n < x.count ? x[n] : nil, r = n < y.count ? y[n] : nil
            if let l, let r, l.contains("Created:"), r.contains("Created:") { continue }
            if l != r { return n + 1 }
        }
        return nil
    }
}
