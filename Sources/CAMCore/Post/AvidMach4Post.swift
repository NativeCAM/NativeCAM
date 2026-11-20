import Foundation

/// G-code for Avid CNC routers running Avid's Mach4 profile.
///
/// The dialect follows Avid's own Vectric and Fusion 360 posts:
/// - `.tap` files with CRLF line endings, parenthesised comments (nested parens swapped for braces)
/// - safety line `G00 G94 G20|G21 G17 G90 G40 G49 G80`, then `G91.1` (incremental I/J arc centres) and `G64`
///   (constant velocity; on Avid's profile the mode only takes effect from the file, so it's restated after every M6)
/// - tool changes as `T#M6`, plus `G43 H#` for ATC machines
/// - `M07`/`M09` for the dust collector relay, `S#### M03` spindle start, optional `G04 P#` spin-up dwell
/// - arcs are G2/G3 with I/J, each under 180°
/// - footer: retract, park, `M05`, `M09`, `M30`
public struct AvidMach4Post: Sendable {
    public var project: Project
    public var date: Date
    /// Time zone for the header's "Created" line (local time by default; tests pin it).
    public var timeZone: TimeZone = .current
    public var version = "0.1"

    public init(project: Project, date: Date = Date()) {
        self.project = project
        self.date = date
    }

    public static let fileExtension = "tap"

    private var machine: MachineProfile { project.machine }
    private var stock: Stock { project.stock }
    private var units: LengthUnit { machine.outputUnits }

    public func post(_ toolpaths: [Toolpath]) -> String {
        var w = Writer(lineNumbers: machine.lineNumbers)
        let paths = toolpaths.filter { !$0.isEmpty }

        // Header comments
        w.comment("\(project.name)")
        w.comment("Post: Avid CNC Mach4 - NativeCAM \(version)")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = timeZone
        w.comment("Created: \(df.string(from: date))")
        w.comment("Machine: \(machine.displayName), \(machine.spindle == .vfdSpindle ? "spindle" : "router"), \(machine.toolChange.label)")
        let rotary = RotaryOutput(project)
        if rotary != nil {
            for line in RotaryOutput.header(stock, units: units, num: { num($0) }, avid: true, feeds: RotaryWrap.feedMode(.avidMach4),
                                            turnsWhileCutting: paths.contains { $0.wrapDiameter != nil }) { w.comment(line) }
        } else {
            w.comment("Material: \(stock.materialName) X=\(num(stock.width)) Y=\(num(stock.height)) Z=\(num(stock.thickness)) \(units.symbol)")
            w.comment("Z zero: \(stock.zZero.label)   XY zero: \(stock.xyOrigin.label)")
        }
        if let ext = extents(paths) {
            if let rotary, let blank = stock.rotary, blank.isWrapped {
                // Y stays on the axis centreline; the sheet's Y range is a range of A.
                let ends = [ext.min.y, ext.max.y].map {
                    rotary.value(RotaryWrap.angle(y: $0, centerY: 0, diameter: blank.wrapDiameterOrBlank))
                }
                let a = { (v: Double) in "\(rotary.letter)\(String(format: "%.3f", v))" }
                w.comment("Program extents: X\(num(ext.min.x)) to X\(num(ext.max.x))  \(a(ends.min()!)) to \(a(ends.max()!))  Z\(num(ext.min.z)) to Z\(num(ext.max.z))")
            } else {
                w.comment("Program extents: X\(num(ext.min.x)) to X\(num(ext.max.x))  Y\(num(ext.min.y)) to Y\(num(ext.max.y))  Z\(num(ext.min.z)) to Z\(num(ext.max.z))")
            }
        }
        w.comment("Safe Z = \(num(workZ(stock.clearanceHeight)))")
        w.comment("Tools used:")
        var seen = Set<Int>()
        for tp in paths where seen.insert(tp.tool.number).inserted {
            w.comment("  T\(tp.tool.number) \(tp.tool.name) - D\(num(tp.tool.diameter)) \(tp.tool.shape.label)")
        }
        w.comment("Toolpaths:")
        for (i, tp) in paths.enumerated() {
            w.comment("  \(i + 1). \(tp.name) - T\(tp.tool.number)")
        }

        // Safety block
        w.line("G00 G94 \(units == .inch ? "G20" : "G21") G17 G90 G40 G49 G80")
        w.line("G91.1")
        w.line("G64")

        var currentTool: Int?
        var currentRPM: Double?
        var state = ModalState()
        var turned = false
        // The A value last written, across tool changes (the change doesn't turn the blank).
        var lastA: Double?

        for tp in paths {
            let toolChanged = currentTool != tp.tool.number
            if toolChanged {
                toolChange(tp, first: currentTool == nil, writer: &w, state: &state)
                currentTool = tp.tool.number
                currentRPM = nil
            }
            let rpm = machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM
            if currentRPM != rpm || toolChanged {
                spindleOn(rpm: rpm, tool: tp.tool, writer: &w)
                currentRPM = rpm
            }
            w.comment("Toolpath: \(tp.name)  Tool: T\(tp.tool.number) \(tp.tool.name)")
            // Approach: up to safe Z first, then over to the start.
            let safe = workZ(stock.clearanceHeight)
            w.line("G00 Z\(num(safe, isZ: true))")
            state.z = round(safe)
            // Wrapped: the tool stays over the axis and the blank turns under it as it cuts.
            if let rotary, tp.wrapDiameter != nil {
                let writer = wrappedWriter(rotary)
                let approach = writer.approach(tp, state: &state, after: lastA)
                let cut = writer.motions(tp, state: &state, offset: approach.offset)
                for line in approach.lines + cut.lines { w.line(line) }
                if approach.turned || cut.turned { turned = true }
                lastA = state.a ?? lastA
                continue
            }
            let startWork = stock.toWork(tp.start)
            w.line("G00 X\(num(startWork.x)) Y\(num(startWork.y))")
            state.x = round(startWork.x)
            state.y = round(startWork.y)
            // Rotary: turn the blank at safe Z, over the start of the cut, whenever the angle isn't known to be right
            // (always after a tool change, since the macro or the operator may have turned it).
            if let rotary, let angle = tp.indexAngle, case let target = RotaryOutput.nearestTurn(rotary.value(angle), after: lastA),
               state.a != target {
                w.line("G00 \(rotary.word(value: target))")
                state.a = target
                lastA = target
                turned = true
            }
            emitMotions(tp, writer: &w, state: &state)
        }

        // Footer
        let home = stock.toWork(stock.parkPosition)
        w.line("G00 Z\(num(home.z, isZ: true))")
        if let rotary, turned {
            let home = RotaryOutput.home(after: lastA ?? 0)
            if let note = RotaryOutput.homeNote(home, avid: true) { w.comment(note) }
            w.line("G00 \(rotary.word(value: home))")
        }
        w.line("G00 X\(num(home.x)) Y\(num(home.y))")
        w.line("M05")
        w.line("M09")
        w.line("M30")
        return w.text
    }

    // MARK: Blocks

    private func toolChange(_ tp: Toolpath, first: Bool, writer w: inout Writer, state: inout ModalState) {
        let tool = tp.tool
        if !first {
            let safe = workZ(stock.clearanceHeight)
            w.line("G00 Z\(num(safe, isZ: true))")
            w.line("M05")
        }
        switch machine.toolChange {
        case .manualM6, .atc:
            w.comment("Change to Tool: T\(tool.number) \(tool.name)")
            if stock.rotary != nil, machine.toolChange == .manualM6 {
                w.comment("Rotary job: \(RotaryOutput.rezero(stock, avid: true)), not on the blank")
            }
            w.line("T\(tool.number)M6")
            if machine.toolChange == .atc { w.line("G43 H\(tool.number)") }
        case .manualPause:
            if first {
                w.comment("Load T\(tool.number) \(tool.name) and zero Z\(stock.rotary == nil ? "" : " on the rotation axis") before starting")
            } else {
                let park = stock.toWork(stock.parkPosition)
                w.line("G00 Z\(num(park.z, isZ: true))")
                w.line("G00 X\(num(park.x)) Y\(num(park.y))")
                w.comment("Change to T\(tool.number) \(tool.name), \(stock.rotary == nil ? "re-zero Z with the touch plate" : RotaryOutput.rezero(stock, avid: true)), then Cycle Start")
                w.line("M00")
            }
        }
        // The tool-change macro may leave other modes behind; restate absolute, I/J and constant velocity.
        if !first { w.line("G90 G91.1 G64") }
        if machine.dustCollection { w.line("M07") }
        state = ModalState()
    }

    private func spindleOn(rpm: Double, tool: Tool, writer w: inout Writer) {
        if machine.spindle == .router {
            w.comment("Set router speed dial to about \(Int(rpm.rounded())) RPM")
        }
        w.line("S\(Int(rpm.rounded())) M03")
        if machine.spindleSpinUpDwell > 0 {
            w.line("G04 P\(String(format: "%.2f", machine.spindleSpinUpDwell))")
        }
    }

    private func emitMotions(_ tp: Toolpath, writer w: inout Writer, state: inout ModalState) {
        var position = tp.start
        for m in tp.motions {
            let e = stock.toWork(m.end)
            let ex = round(e.x), ey = round(e.y), ez = round(e.z)
            switch m.kind {
            case .rapid:
                var words = "G00"
                if ex != state.x { words += " X\(fmt(ex))" }
                if ey != state.y { words += " Y\(fmt(ey))" }
                if ez != state.z { words += " Z\(fmt(ez))" }
                if words != "G00" { w.line(words) }
            case .feed:
                var words = "G01"
                if ex != state.x { words += " X\(fmt(ex))" }
                if ey != state.y { words += " Y\(fmt(ey))" }
                if ez != state.z { words += " Z\(fmt(ez))" }
                if words != "G01" {
                    let f = roundFeed(m.feed)
                    if f != state.feed { words += " F\(fmtFeed(f))"; state.feed = f }
                    w.line(words)
                }
            case .arcCW, .arcCCW:
                let s = stock.toWork(position)
                let c = stock.toWork(Vec3(m.center, 0))
                // I/J relative to the start point exactly as written, so Mach4's radius check sees consistent values.
                let sx = state.x ?? round(s.x), sy = state.y ?? round(s.y)
                let cx = round(c.x), cy = round(c.y)
                let f = roundFeed(m.feed)
                let feedWord = f != state.feed ? " F\(fmtFeed(f))" : ""
                if ex == sx && ey == sy {
                    // Rounding collapsed the arc: Mach4 would read identical endpoints as a full circle.
                    if ez != state.z { w.line("G01 Z\(fmt(ez))" + feedWord); state.feed = f }
                } else if abs(hypot(sx - cx, sy - cy) - hypot(ex - cx, ey - cy)) > arcRadiusTolerance {
                    // Rounded start and end radii disagree enough for Mach4 to reject the arc: cut it as a line.
                    var words = "G01 X\(fmt(ex)) Y\(fmt(ey))"
                    if ez != state.z { words += " Z\(fmt(ez))" }
                    w.line(words + feedWord)
                    state.feed = f
                } else {
                    var words = m.kind == .arcCW ? "G02" : "G03"
                    words += " X\(fmt(ex)) Y\(fmt(ey))"
                    if ez != state.z { words += " Z\(fmt(ez))" }
                    words += " I\(fmt(cx - sx)) J\(fmt(cy - sy))"
                    w.line(words + feedWord)
                    state.feed = f
                }
            case .dwell:
                w.line("G04 P\(String(format: "%.2f", m.feed))")
            }
            if m.kind != .dwell {
                state.x = ex
                state.y = ey
                state.z = ez
            }
            position = m.end
        }
    }

    /// Writes wrapped toolpaths in this post's number formats, fed in G93 inverse time.
    private func wrappedWriter(_ rotary: RotaryOutput) -> WrappedWriter {
        WrappedWriter(stock: stock, rotary: rotary, units: units, decimals: decimals, feedDecimals: feedDecimals,
                      feeds: .inverseTime, rapidWord: "G00", feedWord: "G01",
                      dwell: { "G04 P\(String(format: "%.2f", $0))" })
    }

    // MARK: Number formatting

    private var decimals: Int { units == .inch ? 4 : 3 }
    /// Largest start/end radius difference (output units) an emitted arc may have after rounding.
    private var arcRadiusTolerance: Double { units == .inch ? 0.0005 : 0.0127 }
    private var feedDecimals: Int { units == .inch ? 1 : 0 }

    /// Rounds an mm value to the output precision, returned in output units.
    private func round(_ mm: Double) -> Double {
        let v = units.fromMM(mm)
        let p = pow(10, Double(decimals))
        let r = (v * p).rounded() / p
        return r == 0 ? 0 : r // normalise -0
    }

    private func roundFeed(_ mmPerMin: Double) -> Double {
        let v = units.fromMM(mmPerMin)
        let p = pow(10, Double(feedDecimals))
        return (v * p).rounded() / p
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
    private func fmtFeed(_ v: Double) -> String { String(format: "%.\(feedDecimals)f", v) }
    /// Formats an mm quantity (length) in output units.
    private func num(_ mm: Double, isZ: Bool = false) -> String { fmt(round(mm)) }

    /// Material-relative height → work Z.
    private func workZ(_ zAboveTop: Double) -> Double { stock.toWork(Vec3(0, 0, zAboveTop)).z }

    private func extents(_ paths: [Toolpath]) -> Toolpath.Extents? {
        var lo: Vec3?
        var hi: Vec3?
        for tp in paths {
            guard let e = tp.cuttingExtents else { continue }
            let a = stock.toWork(e.min), b = stock.toWork(e.max)
            lo = lo.map { Vec3(min($0.x, a.x), min($0.y, a.y), min($0.z, a.z)) } ?? a
            hi = hi.map { Vec3(max($0.x, b.x), max($0.y, b.y), max($0.z, b.z)) } ?? b
        }
        guard let l = lo, let h = hi else { return nil }
        // Already in work coords (mm); `num` converts units.
        return Toolpath.Extents(min: l, max: h)
    }

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
        var n = 10
        var text = ""

        mutating func line(_ s: String) {
            if lineNumbers {
                text += "N\(n) "
                n += 10
            }
            text += s + "\r\n"
        }

        /// Mach4 comment; parentheses inside are swapped for braces (as Avid's posts do) and non-ASCII dropped.
        mutating func comment(_ s: String) {
            let cleaned = s.replacingOccurrences(of: "(", with: "{")
                .replacingOccurrences(of: ")", with: "}")
                .replacingOccurrences(of: "\"", with: "in")
                .replacingOccurrences(of: "×", with: "x")
                .replacingOccurrences(of: "°", with: "deg")
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
                .unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
                .map(String.init).joined()
            line("(\(cleaned))")
        }
    }
}
