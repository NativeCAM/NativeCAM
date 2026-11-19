import Foundation

/// Runs an imported Vectric post (`VectricPost`) as a template over NativeCAM's toolpaths.
///
/// Moves follow the same rules as NativeCAM's own posts, so the export checks can read files back the same way:
/// each toolpath starts with a rapid to safe Z and then over to its start, and a move whose rounded end is where
/// the tool already is gets left out. Arcs the post can't write (it has no arc blocks, no helical blocks for an arc
/// that changes Z, or the radius is outside MIN/MAX_ARC_RADIUS) are turned into short lines first; the file's
/// toolpaths record that, so read-back compares against what was actually written.
public struct VectricTemplatePost: PostProcessor {
    public var project: Project
    public var pp: VectricPost
    public var date: Date
    public var timeZone: TimeZone = .current

    public init(project: Project, pp: VectricPost, date: Date = Date()) {
        var p = project
        p.machine.outputUnits = pp.units
        self.project = p
        self.pp = pp
        self.date = date
    }

    public var name: String { pp.name.isEmpty ? "Imported Vectric post" : pp.name }
    public var fileExtension: String { pp.fileExtension }
    public var dialect: Dialect { Dialect.template(pp, machine: project.machine) }

    private var machine: MachineProfile { project.machine }
    private var stock: Stock { project.stock }
    private var units: LengthUnit { pp.units }

    public func files(_ toolpaths: [Toolpath]) -> [PostedFile] {
        let ready = prepared(toolpaths.filter { !$0.isEmpty })
        var groups: [[Toolpath]] = []
        for tp in ready {
            if let last = groups.last?.last, last.tool.number == tp.tool.number { groups[groups.count - 1].append(tp) } else { groups.append([tp]) }
        }
        guard !pp.changesTools, groups.count > 1 else { return [PostedFile(suffix: nil, toolpaths: ready, gcode: render(ready))] }
        return groups.enumerated().map { i, g in
            PostedFile(suffix: " \(i + 1) of \(groups.count) - T\(g[0].tool.number)", toolpaths: g, gcode: render(g))
        }
    }

    public func post(_ toolpaths: [Toolpath]) -> String { render(prepared(toolpaths.filter { !$0.isEmpty })) }

    // MARK: Arcs the post can't write

    func prepared(_ toolpaths: [Toolpath]) -> [Toolpath] {
        let hasHelical = pp.blocks["CW_HELICAL_ARC_MOVE"] != nil || pp.blocks["CCW_HELICAL_ARC_MOVE"] != nil
        let arcHasZ = (pp.blocks["CW_ARC_MOVE"] ?? []).contains { $0.contains("[Z]") }
        return toolpaths.map { tp in
            var t = tp
            var out: [Motion] = []
            var p = tp.start
            for m in tp.motions {
                if m.kind.isArc {
                    let r = units.fromMM(p.xy.distance(to: m.center))
                    let helical = abs(m.end.z - p.z) > 1e-9
                    let writable = pp.usesArcs && (!helical || hasHelical || arcHasZ)
                        && r >= (pp.minArcRadius ?? 0) && r <= (pp.maxArcRadius ?? .infinity)
                    if !writable {
                        out += Self.lines(for: m, from: p, tolerance: 0.01)
                        p = m.end
                        continue
                    }
                }
                out.append(m)
                p = m.end
            }
            t.motions = out
            return t
        }
    }

    /// An arc as straight feed moves no further than `tolerance` (mm) from it.
    static func lines(for m: Motion, from start: Vec3, tolerance: Double) -> [Motion] {
        let r = start.xy.distance(to: m.center)
        let sweep = m.arcSweep(from: start)
        let maxStep = r > tolerance ? 2 * acos(max(-1, 1 - tolerance / r)) : .pi / 2
        let n = max(1, Int((abs(sweep) / max(maxStep, 1e-3)).rounded(.up)))
        let a0 = atan2(start.y - m.center.y, start.x - m.center.x)
        return (1...n).map { i in
            let f = Double(i) / Double(n)
            if i == n { return .feed(m.end, m.feed) }
            let a = a0 + sweep * f
            return .feed(Vec3(m.center.x + r * cos(a), m.center.y + r * sin(a), start.z + (m.end.z - start.z) * f), m.feed)
        }
    }

    // MARK: Rendering

    private struct Context {
        var tool: Tool
        var rpm: Double
        var toolpath: String
        var previousTool: Int?
        var end = Vec3.zero
        var center = Vec2.zero
        var start = Vec3.zero
        var feed = 0.0
        var dwell = 0.0
    }

    private func render(_ paths: [Toolpath]) -> String {
        var out = ""
        var lineNumber = pp.lineNumberStart ?? 10
        var last: [String: String] = [:]
        let decimals = pp.variables["X"]?.decimals ?? (units == .inch ? 4 : 3)
        let scale = pow(10, Double(decimals))
        func round(_ mm: Double) -> Double {
            let v = (units.fromMM(mm) * scale).rounded() / scale
            return v == 0 ? 0 : v
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        func text(_ s: String) -> String { s.map { pp.substitutions[String($0)] ?? String($0) }.joined() }
        var seen = Set<Int>()
        let toolsUsed = paths.filter { seen.insert($0.tool.number).inserted }.map { "T\($0.tool.number) \($0.tool.name)" }.joined(separator: ", ")

        func value(_ label: String, _ c: Context) -> (Double?, String?) {
            let home = stock.toWork(Vec3(stock.homePosition.xy, max(stock.homePosition.z, stock.clearanceHeight)))
            let lo = stock.toWork(Vec3(0, 0, -stock.thickness)), hi = stock.toWork(Vec3(stock.width, stock.height, 0))
            switch label {
            case "X": return (round(c.end.x), nil)
            case "Y": return (round(c.end.y), nil)
            case "Z": return (round(c.end.z), nil)
            case "XH": return (round(home.x), nil)
            case "YH": return (round(home.y), nil)
            case "ZH": return (round(home.z), nil)
            case "I": return (round(c.center.x) - round(c.start.x), nil)
            case "J": return (round(c.center.y) - round(c.start.y), nil)
            case "IA": return (round(c.center.x), nil)
            case "JA": return (round(c.center.y), nil)
            case "RADIUS": return (units.fromMM(c.start.xy.distance(to: c.center)), nil)
            case "F", "FC", "FP": return (units.fromMM(c.feed), nil)
            case "S": return (c.rpm, nil)
            case "T": return (Double(c.tool.number), nil)
            case "TP": return (Double(c.previousTool ?? c.tool.number), nil)
            case "TDIA": return (units.fromMM(c.tool.diameter), nil)
            case "DWELL": return (c.dwell, nil)
            case "SAFEZ": return (round(stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z), nil)
            case "XLENGTH": return (units.fromMM(stock.width), nil)
            case "YLENGTH": return (units.fromMM(stock.height), nil)
            case "ZLENGTH": return (units.fromMM(stock.thickness), nil)
            case "XMIN": return (units.fromMM(lo.x), nil)
            case "YMIN": return (units.fromMM(lo.y), nil)
            case "ZMIN": return (units.fromMM(lo.z), nil)
            case "XMAX": return (units.fromMM(hi.x), nil)
            case "YMAX": return (units.fromMM(hi.y), nil)
            case "ZMAX": return (units.fromMM(hi.z), nil)
            case "TOOLNAME": return (nil, text(c.tool.name))
            case "TOOLPATH_NAME": return (nil, text(c.toolpath))
            case "TOOLPATH_NOTES": return (nil, "")
            case "TP_FILENAME", "TP_FILE_NAME", "PATHNAME": return (nil, text(project.name + "." + pp.fileExtension))
            case "TOOLS_USED": return (nil, text(toolsUsed))
            case "FILE_NOTES": return (nil, text(project.notes))
            case "DATE": df.dateFormat = "yyyy-MM-dd"; return (nil, df.string(from: date))
            case "TIME": df.dateFormat = "HH:mm"; return (nil, df.string(from: date))
            case "PRODUCT": return (nil, "NativeCAM")
            case "XY_ORIGIN": return (nil, stock.xyOrigin.label)
            case "Z_ORIGIN": return (nil, stock.zZero.label)
            default: return (nil, nil)
            }
        }

        func emit(_ block: String, _ c: Context) {
            for template in pp.blocks[block] ?? [] {
                var line = ""
                var usedNumber = false
                var rest = Substring(template)
                while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                    line += rest[..<open]
                    let token = String(rest[rest.index(after: open)..<close])
                    rest = rest[rest.index(after: close)...]
                    if let code = Int(token), let scalar = Unicode.Scalar(code) { line.append(Character(scalar)); continue }
                    let label = token.uppercased()
                    if label == "N" {
                        let v = pp.variables["N"]
                        line += v.map { pp.format(Double(lineNumber), $0) } ?? "N\(lineNumber)"
                        usedNumber = true
                        continue
                    }
                    let (number, string) = value(label, c)
                    if let string { line += string; continue }
                    guard let number else { continue }
                    let formatted: String
                    if let v = pp.variables[label] {
                        formatted = pp.format(number, v)
                        if !v.always {
                            if last[label] == formatted { continue }
                            last[label] = formatted
                        }
                    } else {
                        formatted = label + String(format: "%.\(decimals)f", number)
                    }
                    line += formatted
                }
                line += rest
                if usedNumber {
                    lineNumber += pp.lineNumberIncrement
                    if let max = pp.lineNumberMaximum, lineNumber > max { lineNumber = pp.lineNumberStart ?? 10 }
                }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                out += line + pp.lineEnding
            }
        }

        guard let first = paths.first else { return "" }
        let safe = stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z
        func rpm(_ tp: Toolpath) -> Double { machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM }
        var c = Context(tool: first.tool, rpm: rpm(first), toolpath: first.name)
        var state: (x: Double, y: Double, z: Double)?
        emit("HEADER", c)
        var currentTool: Int?
        var currentRPM: Double?
        var lastMove = "rapid"

        func rapid(_ to: Vec3, initial: Bool) {
            let r = (round(to.x), round(to.y), round(to.z))
            if let s = state, s == r { return }
            c.end = to
            emit(initial && pp.blocks["INITIAL_RAPID_MOVE"] != nil ? "INITIAL_RAPID_MOVE" : "RAPID_MOVE", c)
            state = r
            lastMove = "rapid"
        }

        /// A post whose move block has no feed token writes feed changes on their own line.
        func emitFeedChange(_ block: String) {
            let lines = pp.blocks[block] ?? []
            guard !lines.contains(where: { $0.contains("[F]") || $0.contains("[FC]") || $0.contains("[FP]") }),
                  pp.blocks["FEED_RATE_CHANGE"] != nil else { return }
            emit("FEED_RATE_CHANGE", c)
        }

        for tp in paths {
            let speed = rpm(tp)
            c.tool = tp.tool
            c.rpm = speed
            c.toolpath = tp.name
            if currentTool == nil {
                emit("SPINDLE_ON", c)
                if pp.firstToolpathNewSegment { emit("NEW_SEGMENT", c) }
            } else if currentTool != tp.tool.number {
                if let s = state, s.z < round(safe) { rapid(Vec3(units.toMM(s.x), units.toMM(s.y), safe), initial: false) }
                c.previousTool = currentTool
                last = [:]
                emit("TOOLCHANGE", c)
                emit("SPINDLE_ON", c)
                state = nil
            } else {
                emit("NEW_SEGMENT", c)
                if currentRPM != speed, pp.blocks["NEW_SEGMENT"] == nil { emit("SPINDLE_ON", c) }
            }
            currentTool = tp.tool.number
            currentRPM = speed

            // Approach: up to safe Z, then over to the start.
            let start = stock.toWork(tp.start)
            let target = Vec3(start.x, start.y, safe)
            if let s = state {
                rapid(Vec3(units.toMM(s.x), units.toMM(s.y), safe), initial: false)
                rapid(target, initial: true)
            } else {
                // After the header or a tool change the tool could be anywhere: rise on its own, then move across.
                c.end = target
                for axis in ["X", "Y"] {
                    if let v = pp.variables[axis], !v.always { last[axis] = pp.format(axis == "X" ? round(target.x) : round(target.y), v) }
                }
                emit("RAPID_MOVE", c)
                last["X"] = nil
                last["Y"] = nil
                emit(pp.blocks["INITIAL_RAPID_MOVE"] != nil ? "INITIAL_RAPID_MOVE" : "RAPID_MOVE", c)
                state = (round(target.x), round(target.y), round(target.z))
            }
            lastMove = "rapid"

            var position = tp.start
            for m in tp.motions {
                let e = stock.toWork(m.end)
                let r = (round(e.x), round(e.y), round(e.z))
                c.start = stock.toWork(position)
                c.end = e
                c.feed = m.feed
                defer { position = m.end }
                switch m.kind {
                case .dwell:
                    c.dwell = m.feed
                    emit("DWELL_MOVE", c)
                case .rapid:
                    rapid(e, initial: false)
                case .feed, .arcCW, .arcCCW:
                    guard let s = state, s != r else { continue }
                    let zOnly = s.x == r.0 && s.y == r.1
                    var block = "FEED_MOVE"
                    var kind = "feed"
                    if m.kind.isArc && !zOnly {
                        let center = stock.toWork(Vec3(m.center, 0)).xy
                        let r1 = units.toMM(hypot(s.x - round(center.x), s.y - round(center.y)))
                        let r2 = units.toMM(hypot(r.0 - round(center.x), r.1 - round(center.y)))
                        if !dialect.arcCheck.rejects(startRadius: r1, endRadius: r2) {
                            c.center = center
                            c.start = Vec3(units.toMM(s.x), units.toMM(s.y), units.toMM(s.z))
                            let cw = m.kind == .arcCW ? "CW" : "CCW"
                            block = r.2 != s.z && pp.blocks["\(cw)_HELICAL_ARC_MOVE"] != nil ? "\(cw)_HELICAL_ARC_MOVE" : "\(cw)_ARC_MOVE"
                            kind = "arc"
                        }
                    } else if zOnly && r.2 < s.z, pp.blocks["PLUNGE_MOVE"] != nil || pp.blocks["FIRST_PLUNGE_MOVE"] != nil {
                        block = pp.blocks["PLUNGE_MOVE"] != nil ? "PLUNGE_MOVE" : "FIRST_PLUNGE_MOVE"
                        kind = "plunge"
                    } else if zOnly && r.2 > s.z && pp.blocks["RETRACT_MOVE"] != nil {
                        block = "RETRACT_MOVE"
                        kind = "retract"
                    }
                    if lastMove != kind, pp.blocks["FIRST_" + block] != nil { block = "FIRST_" + block }
                    lastMove = kind
                    emitFeedChange(block)
                    emit(block, c)
                    state = r
                }
            }
        }

        // Rise to safe Z before the footer, unless the footer lifts on its own.
        let footerLifts = (pp.blocks["FOOTER"] ?? []).first { $0.contains("[ZH]") || $0.contains("[SAFEZ]") || $0.contains("[Z]") } != nil
        if !footerLifts, let s = state, s.z < round(safe) { rapid(Vec3(units.toMM(s.x), units.toMM(s.y), safe), initial: false) }
        emit("FOOTER", c)
        return out
    }
}

public extension Dialect {
    /// The dialect for an imported Vectric post: the post's units, extension, line ending and decimals, with the
    /// controller's own rules when NativeCAM knows them (so a Grbl post is still checked against Grbl). For other
    /// controllers the checks are lenient, and a post that doesn't write G-code isn't read back.
    static func template(_ pp: VectricPost, machine: MachineProfile) -> Dialect {
        var base = machine
        base.customPost = nil
        var d: Dialect
        if base.controller != nil, let known = Dialect.for(base) {
            d = known
        } else if base.isLegacyAvidMach4 {
            d = .avidMach4
        } else {
            d = .avidMach4
            d.allowedG = nil
            d.allowedM = nil
            d.dwell = .seconds
            d.m6 = .macro
            d.verified = false
        }
        d.id = "vectric-pp"
        d.name = pp.name.isEmpty ? "Imported Vectric post" : pp.name
        d.lineEnding = pp.lineEnding
        d.fileExtension = pp.fileExtension
        d.acceptedUnits = [pp.units]
        d.coordinateDecimals = [pp.units: pp.variables["X"]?.decimals ?? (pp.units == .inch ? 4 : 3)]
        d.feedDecimals = [pp.units: pp.variables["F"]?.decimals ?? pp.variables["FC"]?.decimals ?? (pp.units == .inch ? 1 : 0)]
        d.comparesDwells = false
        d.readsBack = pp.writesGCode
        d.verified = false
        return d
    }
}
