import Foundation

/// G-code for controllers described by a `Dialect`: today the Grbl family (Grbl 1.1, grblHAL, FluidNC, Carbide
/// Motion). It keeps `AvidMach4Post`'s structure (approach at safe Z, moves that round to nothing left out, a spin-up
/// dwell after each tool or speed change) so `GCodeCheck` can read its files back the same way, and lets the
/// dialect decide the rest:
///
/// - safety block `G90 G94 G17` and the units (`G20`/`G21`) on their own line; no `G64` or `G90.1`
/// - tool changes as `T# M6` only where the controller or its sender stops on M6. Otherwise each tool gets its own
///   complete program, as Vectric does for Grbl: a Grbl `M0` holds the machine in a state where many senders won't
///   jog or probe, so re-zeroing Z mid-file isn't safe to assume. Choosing "Pause (M0)" as the tool change writes
///   one file with `M0` pauses for senders that handle them.
/// - the dialect's dust-collector code (`M8` on Grbl), its dwell format, line endings and line-length limit (long
///   comments are shortened, never split)
/// - arcs cut as lines when their rounded radii would fail the controller's arc check (Grbl error 33)
public struct GenericGCodePost: PostProcessor {
    public var project: Project
    public var dialect: Dialect
    public var date: Date
    public var timeZone: TimeZone = .current
    public var version = "0.1"
    /// Set on each file of a split job: which file this is, and how many there are.
    public var part: (index: Int, count: Int)?

    public init(project: Project, dialect: Dialect, date: Date = Date()) {
        self.project = project
        self.dialect = dialect
        self.date = date
    }

    public var name: String { dialect.name }
    public var fileExtension: String { dialect.fileExtension }

    private var machine: MachineProfile { project.machine }
    private var stock: Stock { project.stock }
    /// The machine's units, unless the controller only runs in one (RichAuto: millimetres).
    private var units: LengthUnit { dialect.acceptedUnits.count == 1 ? dialect.acceptedUnits.first! : machine.outputUnits }

    /// True when tool changes are written as `T# M6`.
    public var usesM6: Bool {
        machine.toolChange != .manualPause && (dialect.m6 == .macro || dialect.m6 == .senderDependent)
    }

    /// True when a job with several tools is saved as one file per tool.
    public var splitsByTool: Bool { !usesM6 && machine.toolChange != .manualPause }

    /// Arcs become short lines for controllers whose arc handling isn't documented.
    func prepared(_ toolpaths: [Toolpath]) -> [Toolpath] {
        guard !dialect.writesArcs else { return toolpaths }
        return toolpaths.map { tp in
            var t = tp
            var p = tp.start
            t.motions = tp.motions.flatMap { m -> [Motion] in
                defer { p = m.end }
                return m.kind.isArc ? VectricTemplatePost.lines(for: m, from: p, tolerance: 0.01) : [m]
            }
            return t
        }
    }

    public func files(_ toolpaths: [Toolpath]) -> [PostedFile] {
        let paths = prepared(toolpaths.filter { !$0.isEmpty })
        var groups: [[Toolpath]] = []
        for tp in paths {
            if let last = groups.last?.last, last.tool.number == tp.tool.number { groups[groups.count - 1].append(tp) } else { groups.append([tp]) }
        }
        guard splitsByTool, groups.count > 1 else { return [PostedFile(suffix: nil, toolpaths: paths, gcode: post(paths))] }
        return groups.enumerated().map { i, group in
            var one = self
            one.part = (i + 1, groups.count)
            return PostedFile(suffix: " \(i + 1) of \(groups.count) - T\(group[0].tool.number)", toolpaths: group, gcode: one.post(group))
        }
    }

    public func post(_ toolpaths: [Toolpath]) -> String {
        var w = Writer(lineNumbers: machine.lineNumbers, ending: dialect.lineEnding, limit: dialect.maxLineLength,
                       comments: dialect.writesComments)
        let paths = prepared(toolpaths.filter { !$0.isEmpty })
        // Machine X and Y: the blank's own frame turned for an axis along Y.
        let frame = RotaryFrame(project)

        w.comment(project.name)
        w.comment("Post: \(dialect.name) - NativeCAM \(version)")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = timeZone
        w.comment("Created: \(df.string(from: date))")
        w.comment("Machine: \(machine.displayName), \(machine.spindle == .vfdSpindle ? "spindle" : "router")")
        if let part {
            w.comment("File \(part.index) of \(part.count): one file per tool")
        } else {
            w.comment(usesM6 ? "Tool changes: M6" : "Tool changes: M0 pause, change the bit, re-zero Z\(stock.rotary == nil ? "" : " on the rotation axis"), resume")
        }
        let rotary = RotaryOutput(project)
        if rotary != nil {
            for line in RotaryOutput.header(stock, units: units, num: { num($0) }, avid: false, axis: machine.rotary,
                                            feeds: RotaryWrap.feedMode(dialect),
                                            turnsWhileCutting: paths.contains { $0.wrapDiameter != nil }) { w.comment(line) }
        } else {
            w.comment("Material: \(stock.materialName) X\(num(stock.width)) Y\(num(stock.height)) Z\(num(stock.thickness)) \(units.symbol)")
            w.comment("Z zero: \(stock.zZero.label)  XY zero: \(stock.xyOrigin.label)")
        }
        w.comment("Safe Z \(num(workZ(stock.clearanceHeight)))")
        var seen = Set<Int>()
        for tp in paths where seen.insert(tp.tool.number).inserted {
            w.comment("T\(tp.tool.number) \(tp.tool.name) D\(num(tp.tool.diameter))")
        }

        w.line(dialect.safetyLine)
        w.line(units == .inch ? "G20" : "G21")
        if dialect.statesIncrementalArcs { w.line("G91.1") }
        if let blend = blendingLine { w.line(blend) }

        var currentTool: Int?
        var currentRPM: Double?
        var state = ModalState()
        var turned = false
        // The A value last written, across tool changes (the change doesn't turn the blank).
        var lastA: Double?
        // On a blank turned by hand, the angle the operator was last asked for; nil until the first stop.
        var dial: Double?
        for tp in paths {
            let toolChanged = currentTool != tp.tool.number
            if toolChanged {
                toolChange(tp, first: currentTool == nil, frame: frame, writer: &w)
                state = ModalState()
                currentTool = tp.tool.number
                currentRPM = nil
            }
            // Turned by hand: stop with the tool at safe Z and the spindle off, and say which angle to turn the blank
            // to. The first toolpath of each file always asks, so a file never assumes where the blank was left.
            if let rotary, rotary.manual, let angle = tp.indexAngle, dial != rotary.position(angle) {
                if currentRPM != nil {
                    let safe = round(workZ(stock.clearanceHeight))
                    if state.z != safe { w.line("G0 Z\(fmt(safe))") }
                    w.line("M5")
                    currentRPM = nil
                }
                w.comment(rotary.turnMessage(angle, resume: "resume"))
                w.line("M0")
                dial = rotary.position(angle)
            }
            let rpm = machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM
            if currentRPM != rpm || toolChanged {
                if machine.spindle == .router { w.comment("Set router speed dial to about \(Int(rpm.rounded())) RPM") }
                w.line("S\(Int(rpm.rounded())) M3")
                if machine.spindleSpinUpDwell > 0 { w.line(dwell(machine.spindleSpinUpDwell)) }
                currentRPM = rpm
            }
            w.comment("\(tp.name) T\(tp.tool.number)")
            let safe = workZ(stock.clearanceHeight)
            w.line("G0 Z\(fmt(round(safe)))")
            state.z = round(safe)
            // Wrapped: the tool stays over the axis and the blank turns under it as it cuts.
            if let rotary, tp.wrapDiameter != nil {
                guard let writer = wrappedWriter(rotary, frame: frame) else {
                    // The job checks report this as an error; never write the sheet's Y as if it were flat.
                    w.comment("SKIPPED: \(dialect.name) can't be given the right feed for wrapped moves")
                    continue
                }
                let approach = writer.approach(tp, state: &state, after: lastA)
                let cut = writer.motions(tp, state: &state, offset: approach.offset)
                for line in approach.lines + cut.lines { w.line(line) }
                if approach.turned || cut.turned { turned = true }
                lastA = state.a ?? lastA
                continue
            }
            let start = frame.toWork(tp.start)
            w.line("G0 X\(fmt(round(start.x))) Y\(fmt(round(start.y)))")
            state.x = round(start.x)
            state.y = round(start.y)
            // Rotary: turn the blank at safe Z, over the start of the cut, whenever the angle isn't known to be right.
            if let rotary, !rotary.manual, let angle = tp.indexAngle,
               case let target = RotaryOutput.nearestTurn(rotary.value(angle), after: lastA), state.a != target {
                w.line("G0 \(rotary.word(value: target))")
                state.a = target
                lastA = target
                turned = true
            }
            emitMotions(tp, frame: frame, writer: &w, state: &state)
        }

        let home = frame.toWork(stock.parkPosition)
        w.line("G0 Z\(fmt(round(home.z)))")
        if let rotary, turned {
            let home = RotaryOutput.home(after: lastA ?? 0)
            if let note = RotaryOutput.homeNote(home, avid: false) { w.comment(note) }
            w.line("G0 \(rotary.word(value: home))")
        }
        w.line("G0 X\(fmt(round(home.x))) Y\(fmt(round(home.y)))")
        w.line("M5")
        w.line("M9")
        w.line("M30")
        return w.text
    }

    private func toolChange(_ tp: Toolpath, first: Bool, frame: RotaryFrame, writer w: inout Writer) {
        let tool = tp.tool
        if !first {
            w.line("G0 Z\(fmt(round(workZ(stock.clearanceHeight))))")
            w.line("M5")
        }
        if usesM6 {
            w.comment("Change to T\(tool.number) \(tool.name)")
            if stock.rotary != nil { w.comment("Rotary job: \(RotaryOutput.rezero(stock, avid: false)), not on the blank") }
            w.line("T\(tool.number) M6")
            if appliesLengthOffset { w.line("G43 H\(tool.number)") }
        } else if first {
            w.comment("Load T\(tool.number) \(tool.name) and zero Z\(stock.rotary == nil ? "" : " on the rotation axis") before starting")
        } else {
            let park = frame.toWork(stock.parkPosition)
            w.line("G0 Z\(fmt(round(park.z)))")
            w.line("G0 X\(fmt(round(park.x))) Y\(fmt(round(park.y)))")
            w.comment("Change to T\(tool.number) \(tool.name), \(stock.rotary == nil ? "re-zero Z" : RotaryOutput.rezero(stock, avid: false)), then resume")
            w.line("M0")
        }
        // A tool-change macro or wizard may leave relative moves behind.
        if !first {
            w.line("G90 G94")
            if let blend = blendingLine { w.line(blend) }
        }
        if machine.dustCollection { w.line("M\(dialect.dustOn)") }
    }

    /// True when each tool change is followed by `G43 H#`.
    public var appliesLengthOffset: Bool {
        switch dialect.lengthOffset {
        case .never: false
        case .withATC: machine.toolChange == .atc
        case .always: true
        }
    }

    /// The corner-blending line for the safety block, if the controller takes one.
    private var blendingLine: String? {
        switch dialect.blending {
        case .none: nil
        case .g64: "G64"
        case .g64P: "G64 P\(fmt(max(units.fromMM(machine.arcFitTolerance), pow(10, -Double(decimals)))))"
        }
    }

    private func dwell(_ seconds: Double) -> String {
        switch dialect.dwell {
        case .milliseconds: "G4 P\(Int((seconds * 1000).rounded()))"
        case .seconds, .secondsWithDecimal: "G4 P\(String(format: "%.2f", seconds))"
        }
    }

    private func emitMotions(_ tp: Toolpath, frame: RotaryFrame, writer w: inout Writer, state: inout ModalState) {
        var position = tp.start
        for m in tp.motions {
            let e = frame.toWork(m.end)
            let ex = round(e.x), ey = round(e.y), ez = round(e.z)
            switch m.kind {
            case .rapid, .feed:
                var words = m.kind == .rapid ? "G0" : "G1"
                let bare = words
                if ex != state.x { words += " X\(fmt(ex))" }
                if ey != state.y { words += " Y\(fmt(ey))" }
                if ez != state.z { words += " Z\(fmt(ez))" }
                if words != bare {
                    if m.kind == .feed {
                        let f = roundFeed(m.feed)
                        if f != state.feed { words += " F\(fmtFeed(f))"; state.feed = f }
                    }
                    w.line(words)
                }
            case .arcCW, .arcCCW:
                let s = frame.toWork(position)
                let c = frame.toWork(Vec3(m.center, 0))
                let sx = state.x ?? round(s.x), sy = state.y ?? round(s.y)
                let cx = round(c.x), cy = round(c.y)
                let f = roundFeed(m.feed)
                let feedWord = f != state.feed ? " F\(fmtFeed(f))" : ""
                let r1 = units.toMM(hypot(sx - cx, sy - cy)), r2 = units.toMM(hypot(ex - cx, ey - cy))
                if ex == sx && ey == sy {
                    // Rounding collapsed the arc: identical endpoints would read as a full circle.
                    if ez != state.z { w.line("G1 Z\(fmt(ez))" + feedWord); state.feed = f }
                } else if dialect.arcCheck.rejects(startRadius: r1, endRadius: r2) {
                    var words = "G1 X\(fmt(ex)) Y\(fmt(ey))"
                    if ez != state.z { words += " Z\(fmt(ez))" }
                    w.line(words + feedWord)
                    state.feed = f
                } else {
                    var words = m.kind == .arcCW ? "G2" : "G3"
                    words += " X\(fmt(ex)) Y\(fmt(ey))"
                    if ez != state.z { words += " Z\(fmt(ez))" }
                    words += " I\(fmt(cx - sx)) J\(fmt(cy - sy))"
                    w.line(words + feedWord)
                    state.feed = f
                }
            case .dwell:
                w.line(dwell(m.feed))
            }
            if m.kind != .dwell {
                state.x = ex
                state.y = ey
                state.z = ez
            }
            position = m.end
        }
    }

    /// Writes wrapped toolpaths in this dialect's number formats; nil when the controller can't be given the
    /// right feed for them (the job checks report it).
    private func wrappedWriter(_ rotary: RotaryOutput, frame: RotaryFrame) -> WrappedWriter? {
        guard let feeds = RotaryWrap.feedMode(dialect) else { return nil }
        return WrappedWriter(frame: frame, rotary: rotary, units: units, decimals: decimals, feedDecimals: feedDecimals,
                             feeds: feeds, turnSpeed: RotaryWrap.turnSpeed(machine), rapidWord: "G0", feedWord: "G1",
                             dwell: { dwell($0) })
    }

    // MARK: Numbers

    private var decimals: Int { dialect.coordinateDecimals(units) }
    private var feedDecimals: Int { dialect.feedDecimals(units) }

    private func round(_ mm: Double) -> Double {
        let p = pow(10, Double(decimals))
        let r = (units.fromMM(mm) * p).rounded() / p
        return r == 0 ? 0 : r
    }

    private func roundFeed(_ mmPerMin: Double) -> Double {
        let p = pow(10, Double(feedDecimals))
        return (units.fromMM(mmPerMin) * p).rounded() / p
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
    private func fmtFeed(_ v: Double) -> String { String(format: "%.\(feedDecimals)f", v) }
    private func num(_ mm: Double) -> String { fmt(round(mm)) }
    private func workZ(_ zAboveTop: Double) -> Double { stock.toWork(Vec3(0, 0, zAboveTop)).z }

    struct ModalState: WrapModalState {
        var x: Double?
        var y: Double?
        var z: Double?
        var feed: Double?
        /// The rotary A value last written; nil when it isn't known.
        var a: Double?
    }

    struct Writer {
        var lineNumbers: Bool
        var ending: String
        var limit: Int?
        var comments = true
        var n = 10
        var text = ""

        mutating func line(_ s: String) {
            if lineNumbers {
                text += "N\(n) "
                n += 10
            }
            text += s + ending
        }

        /// A comment, cleaned for strict parsers (no nested parentheses, ASCII only) and shortened to fit the
        /// controller's line limit.
        mutating func comment(_ s: String) {
            guard comments else { return }
            var cleaned = s.replacingOccurrences(of: "(", with: "{")
                .replacingOccurrences(of: ")", with: "}")
                .replacingOccurrences(of: "\"", with: "in")
                .replacingOccurrences(of: "×", with: "x")
                .replacingOccurrences(of: "°", with: "deg")
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
                .unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
                .map(String.init).joined()
            if let limit {
                let room = limit - 2 - (lineNumbers ? "N\(n) ".count : 0)
                if cleaned.count > room { cleaned = String(cleaned.prefix(max(0, room))) }
            }
            line("(\(cleaned))")
        }
    }
}
