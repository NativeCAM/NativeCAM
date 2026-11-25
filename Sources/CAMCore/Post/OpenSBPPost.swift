import Foundation

/// ShopBot part files in OpenSBP. Syntax from ShopBot's Command Reference (V3) and Programming Handbook: `'`
/// comments, `SA` absolute moves, `MS,xy,z` and `JS,xy,z` speeds in units per second, `M2`/`M3`/`MZ` feeds and
/// `J2`/`J3`/`JZ` jogs, `CG,,x,y,i,j,T,dir` arcs from the current point (1 clockwise, -1 counterclockwise),
/// `PAUSE n` in seconds, `END`, and a check of system variable 25 (the unit setting) at the top. The spindle
/// commands (`TR` speed, `C6` on, `C7` off) and tool change (`&Tool`, `C9`) follow ShopBot's own posts, as the
/// reference doesn't cover them.
///
/// Moves follow the same rules as NativeCAM's G-code posts, so `GCodeCheck` reads files back the same way: each
/// toolpath rises to safe Z and then moves across, and moves that round to nothing are left out. `CG` can't change Z
/// during an arc, so helical arcs are written as short lines. Without a tool changer, each tool gets its own file.
public struct OpenSBPPost: PostProcessor {
    public var project: Project
    /// Set on a restart file (`Restart`): the stop above the restart point, for the file's first toolpath. nil for
    /// every other file. (OpenSBP posts write no rotary axis, so its A state is unused.)
    public var restart: RestartSeed?
    public var date: Date
    public var timeZone: TimeZone = .current
    public var version = "0.1"
    public var part: (index: Int, count: Int)?

    public init(project: Project, date: Date = Date()) {
        self.project = project
        self.date = date
    }

    public var dialect: Dialect { .openSBP(toolChange: machine.toolChange) }
    public var name: String { dialect.name }
    public var fileExtension: String { "sbp" }

    private var machine: MachineProfile { project.machine }
    private var stock: Stock { project.stock }
    private var units: LengthUnit { machine.outputUnits }

    /// True when tools change inside the file (a tool changer, or a pause the user chose).
    var changesToolsInFile: Bool { machine.toolChange == .atc || machine.toolChange == .manualPause }

    public func files(_ toolpaths: [Toolpath]) -> [PostedFile] {
        let paths = prepared(toolpaths.filter { !$0.isEmpty })
        var groups: [[Toolpath]] = []
        for tp in paths {
            if let last = groups.last?.last, last.tool.number == tp.tool.number { groups[groups.count - 1].append(tp) } else { groups.append([tp]) }
        }
        guard !changesToolsInFile, groups.count > 1 else { return [PostedFile(suffix: nil, toolpaths: paths, gcode: post(paths))] }
        return groups.enumerated().map { i, g in
            var one = self
            one.part = (i + 1, groups.count)
            return PostedFile(suffix: " \(i + 1) of \(groups.count) - T\(g[0].tool.number)", toolpaths: g, gcode: one.post(g))
        }
    }

    /// Helical arcs become short lines: CG keeps Z constant during an arc.
    func prepared(_ toolpaths: [Toolpath]) -> [Toolpath] {
        toolpaths.map { tp in
            var t = tp
            var p = tp.start
            t.motions = tp.motions.flatMap { m -> [Motion] in
                defer { p = m.end }
                return m.kind.isArc && abs(m.end.z - p.z) > 1e-9 ? VectricTemplatePost.lines(for: m, from: p, tolerance: 0.01) : [m]
            }
            return t
        }
    }

    public func post(_ toolpaths: [Toolpath]) -> String {
        let paths = prepared(toolpaths.filter { !$0.isEmpty })
        var out = ""
        func line(_ s: String) { out += s + "\r\n" }
        func comment(_ s: String) {
            line("'" + s.replacingOccurrences(of: "\"", with: "in").replacingOccurrences(of: "°", with: "deg")
                .unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(String.init).joined())
        }
        let d = units == .inch ? 4 : 3
        let speedDecimals = dialect.feedDecimals(units)
        func f(_ v: Double) -> String { String(format: "%.\(d)f", v) }
        func round(_ mm: Double) -> Double {
            let p = pow(10, Double(d))
            let r = (units.fromMM(mm) * p).rounded() / p
            return r == 0 ? 0 : r
        }
        /// mm/min → units per second, rounded as written.
        func speed(_ mmPerMin: Double) -> Double {
            let p = pow(10, Double(speedDecimals))
            return (units.fromMM(mmPerMin) / 60 * p).rounded() / p
        }
        func sp(_ v: Double) -> String { String(format: "%.\(speedDecimals)f", v) }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = timeZone
        comment(project.name)
        comment("Post: ShopBot OpenSBP - NativeCAM \(version)")
        comment("Created: \(df.string(from: date))")
        if let part { comment("File \(part.index) of \(part.count): one file per tool") }
        comment("Material: \(stock.materialName) X\(f(round(stock.width))) Y\(f(round(stock.height))) Z\(f(round(stock.thickness))) \(units.symbol)")
        comment("Z zero: \(stock.zZero.label)  XY zero: \(stock.xyOrigin.label)")
        var seen = Set<Int>()
        for tp in paths where seen.insert(tp.tool.number).inserted { comment("T\(tp.tool.number) \(tp.tool.name)") }
        // Stop before moving if ShopBot is set to the other units (system variable 25: 0 inches, 1 millimetres).
        line("IF %(25)=\(units == .inch ? 1 : 0) THEN GOTO UNIT_ERROR")
        line("SA")
        let rapid = machine.axisRapid
        line("JS,\(sp(speed(rapid.x))),\(sp(speed(rapid.z)))")

        let safe = stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z
        var state: (x: Double, y: Double, z: Double)?
        var ms: (xy: Double, z: Double)?
        var currentTool: Int?
        var currentRPM: Double?

        func jog(_ e: Vec3) {
            let r = (round(e.x), round(e.y), round(e.z))
            guard let s = state else { return }
            switch (r.0 != s.x || r.1 != s.y, r.2 != s.z) {
            case (false, false): return
            case (false, true): line("JZ,\(f(r.2))")
            case (true, false): line("J2,\(f(r.0)),\(f(r.1))")
            case (true, true): line("J3,\(f(r.0)),\(f(r.1)),\(f(r.2))")
            }
            state = r
        }
        func setSpeed(xy: Bool, _ mmPerMin: Double) {
            let v = speed(mmPerMin)
            let current = ms ?? (v, v)
            let wanted = xy ? (v, current.z) : (current.xy, v)
            if ms == nil || wanted != current {
                line("MS,\(sp(wanted.0)),\(sp(wanted.1))")
                ms = wanted
            }
        }

        for (index, tp) in paths.enumerated() {
            let restarting = index == 0 ? restart : nil
            let rpm = machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM
            let changed = currentTool != tp.tool.number
            if changed {
                if currentTool != nil {
                    if let s = state, s.z < round(safe) { jog(Vec3(units.toMM(s.x), units.toMM(s.y), safe)) }
                    line("C7")
                }
                if machine.toolChange == .atc {
                    comment("Change to T\(tp.tool.number) \(tp.tool.name)")
                    line("&Tool = \(tp.tool.number)")
                    line("C9")
                } else if currentTool == nil {
                    comment("Load T\(tp.tool.number) \(tp.tool.name) and zero Z before starting")
                } else {
                    let park = stock.toWork(stock.parkPosition)
                    jog(Vec3(units.toMM(state?.x ?? 0), units.toMM(state?.y ?? 0), park.z))
                    jog(park)
                    comment("Change to T\(tp.tool.number) \(tp.tool.name), re-zero Z, then click OK")
                    line("PAUSE")
                }
                currentTool = tp.tool.number
                currentRPM = nil
                state = nil
            }
            // A stop the operator works at the material for (an individual tile's dowels): the tool at safe Z and the
            // spindle off. The spindle starts again below, with its spin-up pause.
            if let message = tp.spindleOffStop {
                if let s = state {
                    if s.z < round(safe) { jog(Vec3(units.toMM(s.x), units.toMM(s.y), safe)) }
                } else {
                    line("JZ,\(f(round(safe)))")
                }
                if currentRPM != nil {
                    line("C7")
                    currentRPM = nil
                }
                comment(message)
                line("PAUSE")
            }
            if currentRPM != rpm {
                if machine.spindle == .router { comment("Set the router speed dial to about \(Int(rpm.rounded())) RPM") }
                line("TR,\(Int(rpm.rounded()))")
                line("C6")
                if machine.spindleSpinUpDwell > 0 { line("PAUSE \(String(format: "%.2f", machine.spindleSpinUpDwell))") }
                currentRPM = rpm
            }
            comment("\(tp.name) T\(tp.tool.number)")
            // Approach: rise to safe Z on its own, then move across.
            let start = stock.toWork(tp.start)
            if let s = state {
                jog(Vec3(units.toMM(s.x), units.toMM(s.y), safe))
                jog(Vec3(start.x, start.y, safe))
            } else {
                line("JZ,\(f(round(safe)))")
                line("J2,\(f(round(start.x))),\(f(round(start.y)))")
                state = (round(start.x), round(start.y), round(safe))
            }
            // A restart: the spindle off and a stop over the restart point at safe Z, then the spindle and its spin-up
            // pause again.
            if let message = restarting?.pause {
                line("C7")
                comment(message)
                line("PAUSE")
                line("TR,\(Int(rpm.rounded()))")
                line("C6")
                if machine.spindleSpinUpDwell > 0 { line("PAUSE \(String(format: "%.2f", machine.spindleSpinUpDwell))") }
                line("JZ,\(f(round(safe)))")
            }
            // A calibration program's section: stop over its start with its message, then restate safe Z.
            if let message = tp.stopMessage {
                comment(message)
                line("PAUSE")
                line("JZ,\(f(round(safe)))")
            }

            for m in tp.motions {
                let e = stock.toWork(m.end)
                let r = (round(e.x), round(e.y), round(e.z))
                switch m.kind {
                case .dwell:
                    line("PAUSE \(String(format: "%.2f", m.feed))")
                case .rapid:
                    jog(e)
                case .feed, .arcCW, .arcCCW:
                    guard let s = state, s != r else { continue }
                    let xyChange = r.0 != s.x || r.1 != s.y
                    if m.kind.isArc && xyChange {
                        let c = stock.toWork(Vec3(m.center, 0))
                        let cx = round(c.x), cy = round(c.y)
                        let r1 = units.toMM(hypot(s.x - cx, s.y - cy)), r2 = units.toMM(hypot(r.0 - cx, r.1 - cy))
                        if !dialect.arcCheck.rejects(startRadius: r1, endRadius: r2) {
                            setSpeed(xy: true, m.feed)
                            line("CG,,\(f(r.0)),\(f(r.1)),\(f(cx - s.x)),\(f(cy - s.y)),T,\(m.kind == .arcCW ? 1 : -1)")
                            state = r
                            continue
                        }
                    }
                    setSpeed(xy: xyChange, m.feed)
                    switch (xyChange, r.2 != s.z) {
                    case (false, _): line("MZ,\(f(r.2))")
                    case (true, false): line("M2,\(f(r.0)),\(f(r.1))")
                    case (true, true): line("M3,\(f(r.0)),\(f(r.1)),\(f(r.2))")
                    }
                    state = r
                }
            }
        }

        let home = stock.toWork(stock.parkPosition)
        jog(Vec3(units.toMM(state?.x ?? 0), units.toMM(state?.y ?? 0), home.z))
        jog(home)
        line("C7")
        line("END")
        line("")
        line("UNIT_ERROR:")
        comment("This file is in \(units == .inch ? "inches" : "millimetres"); set ShopBot to \(units == .inch ? "inches" : "millimetres") and run it again.")
        line("PAUSE")
        line("END")
        return out
    }
}

/// Reads ShopBot part files back into moves, for the export checks and the simulator. Follows the file from the top
/// to the first `END`, which skips the unit-error section; `PAUSE n` is a dwell, a bare `PAUSE` a stop.
public enum OpenSBPParser {
    /// A command and its arguments: `M3,1,2,0.5` or `M3 1,2,0.5`; empty arguments are kept (`CG,,x,y,…`).
    static func split(_ line: String) -> (String, [Double?]) {
        guard let cut = line.firstIndex(where: { $0 == "," || $0 == " " }) else { return (line, []) }
        let cmd = String(line[..<cut])
        let rest = line[line.index(after: cut)...]
        let args = rest.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        return (cmd, args)
    }

    public static func parse(_ text: String, units given: LengthUnit? = nil) -> GCodeProgram {
        var units = given ?? .inch
        if given == nil, text.contains("IF %(25)=0") { units = .mm }
        var absolute = true
        var pos = Vec3.zero
        var msXY = 0.0, msZ = 0.0
        var tool = 0
        var rpm = 0.0
        var warnings: [String] = []
        var segments: [GCodeProgram.Segment] = []
        var current = GCodeProgram.Segment(toolNumber: 0, spindleRPM: 0, start: pos, motions: [])
        func newSegment() {
            if !current.motions.isEmpty { segments.append(current) }
            current = GCodeProgram.Segment(toolNumber: tool, spindleRPM: rpm, start: pos, motions: [])
        }
        var lineNo = 0
        for raw in text.components(separatedBy: .newlines) {
            lineNo += 1
            var line = raw
            if let q = line.firstIndex(of: "'") { line = String(line[..<q]) }
            line = line.trimmingCharacters(in: .whitespaces).uppercased()
            if line.isEmpty || line.hasSuffix(":") || line.hasPrefix("IF ") || line.hasPrefix("GOTO") { continue }
            if line == "END" { break }
            if line.hasPrefix("&TOOL") {
                tool = Int(line.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") ?? tool
                continue
            }
            let (cmd, args) = OpenSBPParser.split(line)
            guard !cmd.isEmpty else { continue }
            func arg(_ i: Int) -> Double? { i < args.count ? args[i] : nil }
            func axis(_ v: Double?, _ cur: Double) -> Double {
                guard let v else { return cur }
                return absolute ? units.toMM(v) : cur + units.toMM(v)
            }
            switch cmd {
            case "SA": absolute = true
            case "SR": absolute = false
            case "MS":
                if let v = arg(0) { msXY = units.toMM(v) * 60 }
                if let v = arg(1) { msZ = units.toMM(v) * 60 }
            case "TR":
                if let v = arg(0), v != rpm { rpm = v; if !current.motions.isEmpty { newSegment() } else { current.spindleRPM = rpm } }
            case "C9":
                newSegment()
            case "PAUSE":
                if let s = arg(0) {
                    current.motions.append(Motion(kind: .dwell, end: pos, feed: s))
                    current.lines.append(lineNo)
                }
            case "J2", "J3", "JZ", "JX", "JY", "M2", "M3", "MZ", "MX", "MY":
                var t = pos
                switch cmd.dropFirst() {
                case "2": t = Vec3(axis(arg(0), pos.x), axis(arg(1), pos.y), pos.z)
                case "3": t = Vec3(axis(arg(0), pos.x), axis(arg(1), pos.y), axis(arg(2), pos.z))
                case "Z": t = Vec3(pos.x, pos.y, axis(arg(0), pos.z))
                case "X": t = Vec3(axis(arg(0), pos.x), pos.y, pos.z)
                default: t = Vec3(pos.x, axis(arg(0), pos.y), pos.z)
                }
                if current.motions.isEmpty { current.toolNumber = tool; current.spindleRPM = rpm }
                if cmd.hasPrefix("J") {
                    current.motions.append(.rapid(t))
                } else {
                    let xy = t.x != pos.x || t.y != pos.y
                    current.motions.append(.feed(t, xy ? msXY : msZ))
                }
                current.lines.append(lineNo)
                pos = t
            case "CG":
                // CG, diameter, x, y, i, j, O/I/T, direction: centre offsets from the current point.
                guard let x = arg(1), let y = arg(2), let i = arg(3), let j = arg(4) else {
                    warnings.append("Line \(lineNo): CG without an end point and centre offsets isn't simulated.")
                    continue
                }
                let dir = arg(6) ?? 1
                let t = Vec3(absolute ? units.toMM(x) : pos.x + units.toMM(x), absolute ? units.toMM(y) : pos.y + units.toMM(y), pos.z)
                let c = Vec2(pos.x + units.toMM(i), pos.y + units.toMM(j))
                if current.motions.isEmpty { current.toolNumber = tool; current.spindleRPM = rpm }
                current.motions.append(Motion(kind: dir < 0 ? .arcCCW : .arcCW, end: t, center: c, feed: msXY))
                current.lines.append(lineNo)
                pos = t
            case "JS", "C6", "C7", "SO", "VN", "CN":
                break
            default:
                if !warnings.contains(where: { $0.contains(" \(cmd) ") }) { warnings.append("Unsupported \(cmd) ignored.") }
            }
        }
        if !current.motions.isEmpty { segments.append(current) }
        return GCodeProgram(segments: segments, warnings: warnings, units: units)
    }
}
