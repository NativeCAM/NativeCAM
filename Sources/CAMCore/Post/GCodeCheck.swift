import Foundation

/// Checks an exported file, the one the machine will actually run, before it's saved:
///
/// - `lint`: line by line against the controller's `Dialect` and the machine (units, line length, accepted codes,
///   rotary words for an axis the controller or machine doesn't have, arc radii, feed before the first feed move,
///   tool numbers, dwell format, spindle on before cutting, a lift to safe Z before the first sideways move after a
///   tool change, feed and RPM limits, a program end).
/// - `roundTrip`: reads the file back under the dialect's rules and compares every cutting move, arc, feed, dwell,
///   tool and spindle speed with the toolpaths it came from. This catches post bugs a simulation of the toolpaths
///   can't, such as doubled coordinates or a dwell in the wrong unit.
/// - `envelope`: the program's whole extent, retracts and park included, against the machine's travel.
public enum GCodeCheck {
    public struct Issue: Hashable, Sendable, Identifiable {
        public var severity: Severity
        /// 1-based line in the file, when the issue belongs to one.
        public var line: Int?
        public var message: String
        public var id: String { "\(severity.rawValue):\(line ?? 0):\(message)" }
        public var text: String { (line.map { "Line \($0): " } ?? "") + message }

        public init(_ severity: Severity, line: Int? = nil, _ message: String) {
            self.severity = severity
            self.line = line
            self.message = message
        }
    }

    /// All three checks.
    public static func run(_ gcode: String, toolpaths: [Toolpath], project: Project, dialect: Dialect) -> [Issue] {
        guard dialect.readsBack else {
            return [Issue(.warning, "\(dialect.name) doesn't write G-code NativeCAM can read back, so this file isn't checked. Air-cut it first.")]
        }
        var project = project
        project.machine.outputUnits = dialect.acceptedUnits.count == 1 ? dialect.acceptedUnits.first! : project.machine.outputUnits
        if dialect.language == .openSBP {
            let program = OpenSBPParser.parse(gcode, units: project.machine.outputUnits)
            return lintOpenSBP(gcode, project: project, dialect: dialect)
                + roundTrip(program, toolpaths: toolpaths, project: project, dialect: dialect)
                + envelope(program, toolpaths: toolpaths, project: project)
        }
        var issues = lint(gcode, project: project, dialect: dialect)
        do {
            let program = try GCodeParser.parse(gcode, dwellUnit: dialect.dwell.parserUnit)
            issues += roundTrip(program, toolpaths: toolpaths, project: project, dialect: dialect)
            issues += envelope(program, toolpaths: toolpaths, project: project)
        } catch {
            issues.append(Issue(.error, "The file can't be read back: \(error.localizedDescription)"))
        }
        return issues
    }

    // MARK: Lint

    public static func lint(_ gcode: String, project: Project, dialect: Dialect) -> [Issue] {
        var issues: [Issue] = []
        // One issue per kind, at its first line, with a count of the rest.
        var first: [String: Int] = [:]
        var counts: [String: Int] = [:]
        func add(_ severity: Severity, _ line: Int?, _ key: String, _ message: String) {
            counts[key, default: 0] += 1
            guard first[key] == nil else { return }
            first[key] = issues.count
            issues.append(Issue(severity, line: line, message))
        }

        let machine = project.machine, stock = project.stock
        let expected = machine.outputUnits
        let safeZ = stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z
        let unsupported: Severity = dialect.strict ? .error : .warning
        let name = dialect.name
        let crlf = dialect.lineEnding == "\r\n"
        func length(_ mm: Double) -> String { "\(project.displayUnits.format(mm)) \(project.displayUnits.symbol)" }

        var units: LengthUnit?
        var absolute = true, incrementalArcs = true
        var motion = 0
        var pos: Vec3?
        var feed: Double?
        var spindleOn = false
        // From the start, and after each tool change, the tool must rise to safe Z before moving sideways.
        var awaitingLift = true, lifted = false, afterChange = false
        var ended = false
        // Rotary jobs: the blank may only turn with the tool at safe Z. Z isn't known at the start or after a stop.
        let rotaryJob = stock.rotary != nil
        var rotaryZ: Double?

        var rows = gcode.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        for (index, row) in rows.enumerated() {
            let n = index + 1
            if row.hasSuffix("\r") != crlf {
                add(.error, n, "eol", "Line endings aren't \(crlf ? "CRLF" : "LF") throughout, as \(name) expects.")
            }
            let raw = row.hasSuffix("\r") ? String(row.dropLast()) : row
            if let limit = dialect.maxLineLength, raw.count > limit {
                add(.error, n, "length", "Line is \(raw.count) characters; \(name) reads at most \(limit).")
            }
            var depth = 0
            for ch in raw {
                if ch == "(" { depth += 1; if depth > 1 { add(.error, n, "nested", "A comment inside a comment; \(name) can't read nested parentheses.") } }
                if ch == ")" { depth -= 1 }
            }
            if depth != 0 { add(.error, n, "unclosed", "A comment isn't closed.") }

            let code = GCodeParser.stripComments(raw).uppercased().trimmingCharacters(in: .whitespaces)
            if code.isEmpty || code.hasPrefix("%") { continue }
            guard let words = try? GCodeParser.tokenize(code, lineNo: n) else {
                add(.error, n, "unreadable", "Can't read “\(raw)”.")
                continue
            }
            if ended { add(.warning, n, "afterEnd", "Comes after the program end (M30 or M2), so it won't run.") }

            var gs: [Double] = [], ms: [Int] = []
            var v: [Character: Double] = [:]
            for (letter, value) in words {
                if Self.rotaryLetters.contains(letter) {
                    if !dialect.rotaryAxes.contains(letter) {
                        add(.error, n, "rotary \(letter)", "\(name) has no \(letter) axis, so it can't run the rotary moves "
                            + "(\(letter) words) in this file.")
                    } else if machine.rotary?.letter.rawValue != String(letter) {
                        add(.warning, n, "rotary \(letter)", "This file turns a rotary \(letter) axis, but "
                            + (machine.rotary.map { "the machine's rotary axis is \($0.letter.rawValue)." }
                                ?? "the machine has no rotary axis set up."))
                    }
                } else if !dialect.allowedLetters.contains(letter) {
                    add(unsupported, n, "letter \(letter)", "\(name) doesn't accept \(letter) words.")
                }
                switch letter {
                case "G": gs.append(value)
                case "M": ms.append(Int(value))
                default: v[letter] = value
                }
            }
            for g in gs where dialect.allowedG?.contains(g) == false {
                add(unsupported, n, "G\(gNumber(g))", "\(name) doesn't support G\(gNumber(g))\(dialect.strict ? " and stops with an error" : "").")
            }
            // M6 on a controller that doesn't run it gets its own, more useful, message below.
            for m in ms where dialect.allowedM?.contains(m) == false && (m != 6 || dialect.m6 == .macro) {
                add(unsupported, n, "M\(m)", "\(name) doesn't support M\(m)\(dialect.strict ? " and stops with an error" : "").")
            }

            for g in gs {
                switch g {
                case 0, 1, 2, 3: motion = Int(g)
                case 20, 21:
                    let u: LengthUnit = g == 20 ? .inch : .mm
                    units = u
                    if u != expected {
                        add(.error, n, "units", "Switches to \(u.symbol) (G\(gNumber(g))), but the machine is set up for \(expected.symbol).")
                    }
                    if !dialect.acceptedUnits.contains(u) {
                        add(.error, n, "units accepted", "\(name) only runs in \(dialect.acceptedUnits.map(\.symbol).sorted().joined(separator: " or ")).")
                    }
                case 90: absolute = true
                case 91: absolute = false
                case 90.1: incrementalArcs = false
                case 91.1: incrementalArcs = true
                default: break
                }
            }
            let u = units ?? expected

            if let line = v["N"], let limit = dialect.maxLineNumber, line > Double(limit) {
                add(.error, n, "N", "Line number N\(Int(line)) is above \(limit), the highest \(name) accepts.")
            }
            if let t = v["T"] {
                if t < 0 || t != t.rounded() { add(.error, n, "T", "T\(t) isn't a tool number.") }
                if let limit = dialect.maxToolNumber, t > Double(limit) {
                    add(.error, n, "T max", "Tool number T\(Int(t)) is above \(limit), the highest \(name) accepts.")
                }
            }
            if v["H"] != nil && !gs.contains(43) { add(.error, n, "H", "An H word without G43.") }
            if let f = v["F"] {
                if f <= 0 { add(.error, n, "F zero", "Feed F\(f) can't move the machine.") }
                feed = u.toMM(f)
                if u.toMM(f) > machine.maxFeedRate + 1e-6 {
                    add(.warning, n, "F max", "Feed F\(f) is above the machine's maximum of \(length(machine.maxFeedRate))/min.")
                }
            }
            if let s = v["S"], machine.spindle == .vfdSpindle, s < machine.minRPM - 0.5 || s > machine.maxRPM + 0.5 {
                add(.warning, n, "S", "Spindle speed S\(Int(s)) is outside the spindle's \(Int(machine.minRPM))–\(Int(machine.maxRPM)) RPM.")
            }

            for m in ms {
                switch m {
                case 3, 4: spindleOn = true
                case 5: spindleOn = false
                case 6:
                    spindleOn = false
                    awaitingLift = true; lifted = false; afterChange = true
                    rotaryZ = nil
                    switch dialect.m6 {
                    case .macro: break
                    case .rejected:
                        add(.error, n, "M6", "\(name) rejects M6 and keeps running the lines after it, so the next tool's "
                            + "cuts would run with the old bit. Use a pause (M0) for tool changes.")
                    case .recordsOnly:
                        add(.error, n, "M6", "\(name) only records the tool number on M6 and doesn't stop, so the next tool's "
                            + "cuts would run with the old bit. Use a pause (M0) for tool changes.")
                    case .senderDependent:
                        add(.warning, n, "M6", "Whether M6 stops for the tool change depends on the program sending the file. "
                            + "Make sure yours pauses on M6.")
                    case .none:
                        add(.error, n, "M6", "\(name) can't change tools within a file, so the next tool's cuts would run with the "
                            + "old bit. Save one file per tool.")
                    }
                case 0, 1:
                    awaitingLift = true; lifted = false; afterChange = true
                    rotaryZ = nil
                case 2, 30: ended = true
                default: break
                }
            }

            if gs.contains(4) {
                let written = GCodeParser.wordText("P", in: code) ?? ""
                let p = v["P"] ?? 0
                switch dialect.dwell {
                case .secondsWithDecimal where !written.contains("."):
                    add(.error, n, "dwell", "Write dwells with a decimal point (G04 P\(written).0): Mach4 builds differ on whether "
                        + "a bare P\(written) is seconds or milliseconds.")
                case .milliseconds where written.contains("."):
                    add(.error, n, "dwell", "\(name) reads G04 P in whole milliseconds; P\(written) would be a fraction of a millisecond.")
                case .seconds where !written.contains(".") && p >= 100:
                    add(.warning, n, "dwell", "G04 P\(written) dwells \(Int(p)) seconds on \(name).")
                default: break
                }
                continue
            }

            if rotaryJob {
                let target = v["Z"].map { absolute ? u.toMM($0) : (rotaryZ ?? 0) + u.toMM($0) }
                if v["A"] != nil {
                    let low = { (z: Double) in z < safeZ - 1e-3 }
                    if rotaryZ.map(low) ?? true || target.map(low) ?? false {
                        add(.error, n, "A below safe Z", "Turns the rotary axis below safe Z, or before the tool has lifted to "
                            + "it, so the blank could swing into the tool.")
                    }
                }
                if let target { rotaryZ = absolute || rotaryZ != nil ? target : nil }
            }

            let arcWords = v["I"] != nil || v["J"] != nil || v["K"] != nil || v["R"] != nil
            if arcWords && motion != 2 && motion != 3 {
                add(.error, n, "IJ", "I, J, K or R words on a line that isn't an arc.")
            }
            let hasAxis = v["X"] != nil || v["Y"] != nil || v["Z"] != nil
            guard hasAxis else { continue }
            if units == nil { add(.error, n, "no units", "Moves before G20 or G21 sets the units.") }

            func axis(_ c: Character, _ current: Double?) -> Double? {
                guard let w = v[c] else { return current }
                return absolute ? u.toMM(w) : (current ?? 0) + u.toMM(w)
            }
            let tx = axis("X", pos?.x), ty = axis("Y", pos?.y), tz = axis("Z", pos?.z)
            let movesXY = (v["X"] != nil && tx != pos?.x) || (v["Y"] != nil && ty != pos?.y)

            if motion != 0 {
                if feed == nil { add(.error, n, "no feed", "A feed move before any F word sets the feed rate.") }
                if !spindleOn { add(.error, n, "spindle", "Cuts with the spindle stopped.") }
            }
            if awaitingLift {
                if movesXY {
                    if !lifted {
                        add(.error, n, "lift", afterChange
                            ? "Moves sideways after a tool change before lifting to safe Z."
                            : "Moves sideways before lifting to safe Z.")
                    }
                    awaitingLift = false
                } else if let z = tz, v["Z"] != nil, z >= safeZ - 1e-3 {
                    lifted = true
                }
            }
            if motion == 2 || motion == 3 {
                if let start = pos, let ex = tx, let ey = ty {
                    if let r = v["R"] {
                        if abs(ex - start.x) < 1e-9 && abs(ey - start.y) < 1e-9 {
                            add(.error, n, "R circle", "An R-format arc can't describe a full circle (R\(r)).")
                        }
                    } else if v["I"] != nil || v["J"] != nil {
                        let i = u.toMM(v["I"] ?? 0), j = u.toMM(v["J"] ?? 0)
                        let c = incrementalArcs ? Vec2(start.x + i, start.y + j) : Vec2(i, j)
                        let r1 = hypot(start.x - c.x, start.y - c.y), r2 = hypot(ex - c.x, ey - c.y)
                        if dialect.arcCheck.rejects(startRadius: r1, endRadius: r2) {
                            add(.error, n, "arc", "Arc start and end radii differ by \(String(format: "%.4f", abs(r1 - r2))) mm, "
                                + "more than \(name) accepts.")
                        }
                    } else {
                        add(.error, n, "arc words", "Arc without I, J or R.")
                    }
                }
            }
            pos = Vec3(tx ?? 0, ty ?? 0, tz ?? 0)
        }
        if units == nil { add(.error, nil, "no units at all", "The file never sets its units with G20 or G21.") }
        if !ended { add(.error, nil, "no end", "The program doesn't end with M30 or M2.") }
        if spindleOn { add(.warning, nil, "spindle at end", "The spindle is still on at the end of the program.") }

        for (key, i) in first where counts[key, default: 0] > 1 {
            let more = counts[key]! - 1
            issues[i].message += " (\(more) more line\(more == 1 ? "" : "s") like this.)"
        }
        return issues
    }

    /// OpenSBP part files: a units check, a speed before the first cut, the spindle on before cutting, a lift to
    /// safe Z before moving across at the start and after each tool change, and an END.
    public static func lintOpenSBP(_ text: String, project: Project, dialect: Dialect) -> [Issue] {
        var issues: [Issue] = []
        var reported = Set<String>()
        func add(_ severity: Severity, _ line: Int?, _ key: String, _ message: String) {
            if reported.insert(key).inserted { issues.append(Issue(severity, line: line, message)) }
        }
        let units = project.machine.outputUnits
        let safe = project.stock.toWork(Vec3(0, 0, project.stock.clearanceHeight)).z
        let known: Set<String> = ["SA", "SR", "MS", "JS", "J2", "J3", "JZ", "JX", "JY", "M2", "M3", "MZ", "MX", "MY", "CG", "TR",
                                  "C6", "C7", "C9", "PAUSE", "END", "IF", "GOTO", "SO"]
        var unitCheck = false, speedSet = false, spindle = false, ended = false, moved = false
        var awaitingLift = true, lifted = false
        var z: Double?
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let n = index + 1
            var line = raw
            if let q = line.firstIndex(of: "'") { line = String(line[..<q]) }
            line = line.trimmingCharacters(in: .whitespaces).uppercased()
            if line.isEmpty || line.hasSuffix(":") || line.hasPrefix("&") { continue }
            if line == "END" { ended = true; break }
            let (cmd, values) = OpenSBPParser.split(line)
            guard !cmd.isEmpty else { continue }
            if !known.contains(cmd) { add(.warning, n, "cmd \(cmd)", "\(dialect.name) command \(cmd) isn't one NativeCAM checks.") }
            if cmd == "IF", line.contains("%(25)") { unitCheck = true }
            if cmd == "MS" { speedSet = true }
            if cmd == "C6" || (cmd == "SO" && line.hasSuffix(",1")) { spindle = true }
            if cmd == "C7" || cmd == "C9" { spindle = false }
            if cmd == "C9" || (cmd == "PAUSE" && values.isEmpty) { awaitingLift = true; lifted = false }
            let moves: Set<String> = ["J2", "J3", "JZ", "JX", "JY", "M2", "M3", "MZ", "MX", "MY", "CG"]
            guard moves.contains(cmd) else { continue }
            if !moved && !unitCheck {
                add(.warning, n, "units", "The file doesn't check ShopBot's unit setting before moving.")
            }
            moved = true
            let axisZ: Double? = cmd.hasSuffix("Z") ? values.first ?? nil : (cmd.hasSuffix("3") && values.count > 2 ? values[2] : nil)
            if let v = axisZ { z = units.toMM(v) }
            let movesXY = cmd.hasSuffix("2") || cmd.hasSuffix("3") || cmd.hasSuffix("X") || cmd.hasSuffix("Y") || cmd == "CG"
            if cmd.first == "M" || cmd == "CG" {
                if !speedSet { add(.error, n, "speed", "A cut before MS sets the speed.") }
                if !spindle { add(.error, n, "spindle", "Cuts with the spindle stopped.") }
            }
            if awaitingLift {
                if movesXY {
                    if !lifted { add(.error, n, "lift", "Moves across before lifting to safe Z.") }
                    awaitingLift = false
                } else if let z, z >= safe - 1e-3 {
                    lifted = true
                }
            }
        }
        if !ended { add(.error, nil, "end", "The file doesn't finish with END.") }
        return issues
    }

    /// Address letters for rotary axes: A turns about X, B about Y, C about Z.
    static let rotaryLetters: Set<Character> = ["A", "B", "C"]

    static func gNumber(_ g: Double) -> String {
        g == g.rounded() ? String(Int(g)) : String(format: "%g", g)
    }

    // MARK: Read-back

    /// A cutting move or dwell the post writes for a toolpath, in work coordinates (mm).
    struct ExpectedMove {
        var kind: MotionKind
        var end: Vec3
        var start: Vec3
        var center: Vec2
        var feed: Double
        var tool: Int
        var rpm: Double
        var toolpath: String
        /// The A value the post writes for the toolpath's index angle (nil on a flat job).
        var a: Double?
    }

    /// The moves the post writes, in order: the same rule as the post, which leaves out a move whose rounded end
    /// is where the tool already is, starts each toolpath from its approach at safe Z, and dwells for the spindle
    /// to spin up after each tool change or speed change.
    static func expectedMoves(_ toolpaths: [Toolpath], project: Project, dialect: Dialect) -> [ExpectedMove] {
        let machine = project.machine, stock = project.stock, units = machine.outputUnits
        let scale = pow(10, Double(dialect.coordinateDecimals(units)))
        func r(_ mm: Double) -> Double {
            let v = (units.fromMM(mm) * scale).rounded() / scale
            return v == 0 ? 0 : v
        }
        let safe = stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z
        let rotary = RotaryOutput(project)
        var out: [ExpectedMove] = []
        var tool: Int?, speed: Double?
        for tp in toolpaths where !tp.isEmpty {
            let a = tp.indexAngle.flatMap { angle in rotary?.value(angle) }
            let rpm = machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM
            let s = stock.toWork(tp.start)
            if (tool != tp.tool.number || speed != rpm) && machine.spindleSpinUpDwell > 0 {
                out.append(ExpectedMove(kind: .dwell, end: s, start: s, center: .zero, feed: machine.spindleSpinUpDwell,
                                        tool: tp.tool.number, rpm: rpm, toolpath: tp.name, a: a))
            }
            tool = tp.tool.number
            speed = rpm
            var sx = r(s.x), sy = r(s.y), sz = r(safe)
            var position = tp.start
            for m in tp.motions {
                let e = stock.toWork(m.end)
                let ex = r(e.x), ey = r(e.y), ez = r(e.z)
                let move = ExpectedMove(kind: m.kind, end: e, start: stock.toWork(position),
                                        center: m.kind.isArc ? stock.toWork(Vec3(m.center, 0)).xy : .zero,
                                        feed: m.feed, tool: tp.tool.number, rpm: rpm, toolpath: tp.name, a: a)
                switch m.kind {
                case .dwell: out.append(move)
                case .rapid: break
                case .feed, .arcCW, .arcCCW:
                    if ex != sx || ey != sy || ez != sz { out.append(move) }
                }
                if m.kind != .dwell { sx = ex; sy = ey; sz = ez }
                position = m.end
            }
        }
        return out
    }

    public static func roundTrip(_ program: GCodeProgram, toolpaths: [Toolpath], project: Project, dialect: Dialect) -> [Issue] {
        let units = project.machine.outputUnits
        let step = units.toMM(pow(10, -Double(dialect.coordinateDecimals(units))))
        let tol = step / 2 + 1e-6
        let feedTol = (dialect.feedPerSecond ? 60 : 1) * units.toMM(pow(10, -Double(dialect.feedDecimals(units)))) / 2 + 1e-6
        let expected = expectedMoves(toolpaths, project: project, dialect: dialect).filter { dialect.comparesDwells || $0.kind != .dwell }
        var written: [(motion: Motion, start: Vec3, tool: Int, rpm: Double, line: Int)] = []
        for seg in program.segments {
            var p = seg.start
            for (k, m) in seg.motions.enumerated() {
                if m.kind != .rapid && (dialect.comparesDwells || m.kind != .dwell) {
                    written.append((m, p, seg.toolNumber, seg.spindleRPM, k < seg.lines.count ? seg.lines[k] : 0))
                }
                if m.kind != .dwell { p = m.end }
            }
        }

        var issues: [Issue] = []
        func fail(_ line: Int?, _ message: String) { if issues.filter({ $0.severity == .error }).count < 5 { issues.append(Issue(.error, line: line, message)) } }
        func near(_ a: Vec3, _ b: Vec3, _ t: Double) -> Bool { abs(a.x - b.x) <= t && abs(a.y - b.y) <= t && abs(a.z - b.z) <= t }
        func show(_ v: Vec3) -> String {
            let d = dialect.coordinateDecimals(units)
            return "X\(String(format: "%.\(d)f", units.fromMM(v.x))) Y\(String(format: "%.\(d)f", units.fromMM(v.y))) Z\(String(format: "%.\(d)f", units.fromMM(v.z)))"
        }

        if written.count != expected.count {
            issues.append(Issue(.error, "The file has \(written.count) cutting moves and dwells, but the toolpaths have \(expected.count)."))
        }
        // A file that pauses for tool changes (M0) has no T words to read back.
        var toolReported = !written.contains { $0.tool != 0 }, rpmReported = false
        for (w, e) in zip(written, expected) {
            let line = w.line
            if (w.motion.kind == .dwell) != (e.kind == .dwell) {
                fail(line, "Expected \(e.kind == .dwell ? "a dwell" : "a move") from “\(e.toolpath)” here.")
                break
            }
            if e.kind == .dwell {
                if abs(w.motion.feed - e.feed) > 0.006 {
                    fail(line, "Dwells \(w.motion.feed) s when read back, but “\(e.toolpath)” asks for \(e.feed) s.")
                }
                continue
            }
            if !near(w.motion.end, e.end, tol) {
                fail(line, "Ends at \(show(w.motion.end)), but “\(e.toolpath)” goes to \(show(e.end)).")
                break
            }
            if let a = e.a, w.motion.a.map({ abs($0 - a) > 5e-4 }) ?? true {
                let read = w.motion.a.map { "A\(String(format: "%.3f", $0))" } ?? "no A position"
                fail(line, "Cuts with \(read) where “\(e.toolpath)” is turned to A\(String(format: "%.3f", a)).")
                break
            }
            if abs(w.motion.feed - e.feed) > feedTol {
                fail(line, "Reads back at \(project.displayUnits.format(w.motion.feed))/min, but “\(e.toolpath)” cuts at "
                    + "\(project.displayUnits.format(e.feed))/min.")
            }
            switch (e.kind.isArc, w.motion.kind.isArc) {
            case (true, true):
                if w.motion.kind != e.kind {
                    fail(line, "Arc turns the wrong way (\(w.motion.kind == .arcCW ? "G02" : "G03") for a "
                        + "\(e.kind == .arcCW ? "clockwise" : "counterclockwise") arc in “\(e.toolpath)”).")
                } else if abs(w.motion.center.x - e.center.x) > 2 * step + 1e-6 || abs(w.motion.center.y - e.center.y) > 2 * step + 1e-6 {
                    fail(line, "Arc centre reads back away from “\(e.toolpath)”'s.")
                }
            case (true, false):
                // Fine when the arc is too short to matter, or its own radii disagree so a controller would reject it.
                let chord = hypot(e.end.x - e.start.x, e.end.y - e.start.y)
                let r1 = hypot(e.start.x - e.center.x, e.start.y - e.center.y), r2 = hypot(e.end.x - e.center.x, e.end.y - e.center.y)
                if chord <= 2 * step {
                    break
                } else if dialect.arcCheck.rejects(startRadius: r1, endRadius: r2) {
                    issues.append(Issue(.info, line: line, "An arc in “\(e.toolpath)” whose radii disagree is cut as a straight line."))
                } else {
                    fail(line, "An arc in “\(e.toolpath)” is written as a straight line.")
                }
            case (false, true):
                fail(line, "A straight move in “\(e.toolpath)” is written as an arc.")
            case (false, false):
                break
            }
            if w.tool != e.tool && !toolReported {
                toolReported = true
                fail(line, "Cuts with T\(w.tool) where “\(e.toolpath)” uses T\(e.tool).")
            }
            if abs(w.rpm - e.rpm) > 0.5 && !rpmReported {
                rpmReported = true
                fail(line, "Spindle reads back at \(Int(w.rpm)) RPM where “\(e.toolpath)” runs at \(Int(e.rpm)).")
            }
        }
        return issues
    }

    // MARK: Work area

    public static func envelope(_ program: GCodeProgram, toolpaths: [Toolpath], project: Project) -> [Issue] {
        var lo = Vec3(.infinity, .infinity, .infinity), hi = Vec3(-.infinity, -.infinity, -.infinity)
        for seg in program.segments {
            for m in seg.motions where m.kind != .dwell {
                lo = Vec3(min(lo.x, m.end.x), min(lo.y, m.end.y), min(lo.z, m.end.z))
                hi = Vec3(max(hi.x, m.end.x), max(hi.y, m.end.y), max(hi.z, m.end.z))
            }
        }
        guard lo.x.isFinite else { return [] }
        let travel = project.machine.travel, u = project.displayUnits
        func length(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var issues: [Issue] = []
        for (axis, span, limit) in [("X", hi.x - lo.x, travel.x), ("Y", hi.y - lo.y, travel.y)] where span > limit + 1e-3 {
            issues.append(Issue(.warning, "The program moves \(length(span)) in \(axis), retracts and park included, "
                + "more than the machine's \(length(limit)) of travel."))
        }
        let stickout = toolpaths.map(\.tool.stickout).max() ?? 0
        if hi.z - lo.z + stickout > travel.z + 1e-3 {
            issues.append(Issue(.warning, "The program spans \(length(hi.z - lo.z)) in Z; with \(length(stickout)) of tool "
                + "sticking out that's more than the machine's \(length(travel.z)) of Z travel."))
        }
        return issues
    }
}
