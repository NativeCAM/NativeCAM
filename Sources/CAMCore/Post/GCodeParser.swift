import Foundation

/// Reads RS-274 style G-code (the subset routers use) back into motions.
///
/// Used to verify our own output (post → parse → compare) and to load `.tap`/`.nc` files from other CAM
/// programs into the simulator. Coordinates come back in millimetres in the program's work coordinates, and a
/// rotary A position (once the program moves A) in degrees on each motion. Canned drilling cycles (G73, G81–G83,
/// G85, G86, G89) are expanded into the plain moves the controller makes, so their holes simulate.
public struct GCodeProgram: Sendable {
    public struct Segment: Sendable {
        public var toolNumber: Int
        public var spindleRPM: Double
        public var start: Vec3
        public var motions: [Motion]
        /// Source line (1-based) of each motion.
        public var lines: [Int] = []
    }

    /// A program stop (M0 or M1), with the comment that tells the operator what to do: the one on its line, or else
    /// on the line just before it.
    public struct Pause: Sendable, Hashable {
        /// Source line (1-based).
        public var line: Int
        public var message: String?
    }

    public var segments: [Segment]
    public var warnings: [String]
    public var units: LengthUnit
    /// Every M0 and M1 in the program, in order.
    public var pauses: [Pause] = []

    /// Converts the program into toolpaths using `tools` (matched by number) for geometry.
    /// `stock` maps work coordinates back into design space for the simulator.
    public func toolpaths(tools: [Tool], stock: Stock, fallback: Tool) -> [Toolpath] {
        segments.enumerated().compactMap { i, seg in
            guard !seg.motions.isEmpty else { return nil }
            var tool = tools.first { $0.number == seg.toolNumber } ?? fallback
            if tools.first(where: { $0.number == seg.toolNumber }) == nil { tool.number = seg.toolNumber }
            let motions = seg.motions.map { m -> Motion in
                var d = m
                d.end = stock.fromWork(m.end)
                if m.kind.isArc { d.center = stock.fromWork(Vec3(m.center, 0)).xy }
                return d
            }
            return Toolpath(id: UUID(), name: "Segment \(i + 1) (T\(seg.toolNumber))", tool: tool,
                            spindleRPM: seg.spindleRPM, start: stock.fromWork(seg.start), motions: motions)
        }
    }
}

public enum GCodeParser {
    public enum ParseError: Error, LocalizedError {
        case badWord(line: Int, text: String)
        public var errorDescription: String? {
            switch self {
            case let .badWord(line, text): "Line \(line): can't read '\(text)'"
            }
        }
    }

    /// What a `G4 P` value means. Controllers disagree: LinuxCNC and Mach4's manual read seconds, Masso reads
    /// milliseconds, and Fanuc-style controls read milliseconds unless the value has a decimal point.
    public enum DwellUnit: Sendable {
        case seconds
        case milliseconds
        /// A value with a decimal point is seconds (right under every reading). A whole number of 100 or more is
        /// milliseconds, since nobody dwells a router for minutes; smaller whole numbers are seconds.
        case automatic
    }

    /// `incrementalArcCenters` is the I/J mode before any G90.1/G91.1 (incremental on Mach4, Grbl and LinuxCNC).
    public static func parse(_ text: String, dwellUnit: DwellUnit = .automatic,
                             incrementalArcCenters: Bool = true) throws -> GCodeProgram {
        var units: LengthUnit = .inch
        var absolute = true
        var arcIncremental = incrementalArcCenters
        var motionMode = 0
        var feed = 0.0
        var rpm = 0.0
        var tool = 0
        var pos = Vec3.zero
        // Rotary A in degrees, unwound; nil until the program first moves it.
        var rotary: Double?
        // Canned cycles. R, Z, Q and P stay set through a run of cycle blocks; the initial Z is where the run started.
        var retractToR = false
        var cycleR: Double?
        var cycleZ: Double?
        var cycleQ = 0.0
        var cycleDwell = 0.0
        var cycleStartZ: Double?
        var warnings: [String] = []
        var warned = Set<String>()
        func warnOnce(_ s: String) { if warned.insert(s).inserted { warnings.append(s) } }

        var segments: [GCodeProgram.Segment] = []
        var current = GCodeProgram.Segment(toolNumber: 0, spindleRPM: 0, start: pos, motions: [])
        func newSegment() {
            if !current.motions.isEmpty { segments.append(current) }
            current = GCodeProgram.Segment(toolNumber: tool, spindleRPM: rpm, start: pos, motions: [])
        }

        var pauses: [GCodeProgram.Pause] = []
        // The comment on the last line that held nothing else, for a stop on the next line.
        var lastComment: String?

        var lineNo = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            lineNo += 1
            let line = stripComments(String(rawLine)).uppercased()
            let comment = commentText(String(rawLine))
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("%") {
                if comment != nil { lastComment = comment }
                continue
            }
            let words = try tokenize(line, lineNo: lineNo)
            if words.allSatisfy({ $0.0 == "N" || $0.0 == "O" }) {
                if comment != nil { lastComment = comment }
                continue
            }

            var gCodes: [Double] = []
            var mCodes: [Int] = []
            var values: [Character: Double] = [:]
            for (letter, value) in words {
                switch letter {
                case "G": gCodes.append(value)
                case "M": mCodes.append(Int(value))
                case "N", "O": break
                default: values[letter] = value
                }
            }
            if mCodes.contains(0) || mCodes.contains(1) {
                pauses.append(GCodeProgram.Pause(line: lineNo, message: comment ?? lastComment))
            }
            lastComment = nil
            var dwellRequested = false
            for g in gCodes {
                switch g {
                case 0, 1, 2, 3:
                    motionMode = Int(g)
                    cycleStartZ = nil
                case 4: dwellRequested = true
                case 20: units = .inch
                case 21: units = .mm
                case 90: absolute = true
                case 91: absolute = false
                case 90.1: arcIncremental = false
                case 91.1: arcIncremental = true
                case 80:
                    // Cancels a cycle; later axis words without a G0/G1 are read as rapids.
                    if Self.isCycle(motionMode) || motionMode == Self.skippedCycle { motionMode = 0 }
                    cycleStartZ = nil
                case 17, 40, 49, 94, 54, 43, 61, 64: break
                case 18, 19: warnOnce("Arcs outside the XY plane (G18/G19) aren't simulated.")
                case 28, 30, 53: warnOnce("Machine-coordinate moves (G28/G30/G53) are skipped in the simulation.")
                case 73, 81, 82, 83, 85, 86, 89:
                    if motionMode != Int(g) { cycleStartZ = nil }
                    motionMode = Int(g)
                case 98: retractToR = false
                case 99: retractToR = true
                case 74, 76, 84, 87, 88:
                    warnOnce("Tapping and boring cycles (G\(Int(g))) aren't simulated; their holes won't show.")
                    motionMode = Self.skippedCycle
                default: warnOnce("Unsupported G\(g) ignored.")
                }
            }
            if let f = values["F"] { feed = units.toMM(f) }
            if let s = values["S"] { rpm = s }
            if let t = values["T"] { tool = Int(t) }
            if mCodes.contains(6) || (values["T"] != nil && current.motions.isEmpty) {
                newSegment()
            } else if values["S"] != nil, !current.motions.isEmpty, current.spindleRPM != rpm {
                newSegment()
            }
            if current.motions.isEmpty { current.toolNumber = tool; current.spindleRPM = rpm }

            func dwellSeconds(_ p: Double) -> Double {
                switch dwellUnit {
                case .seconds: return p
                case .milliseconds: return p / 1000
                case .automatic:
                    let written = wordText("P", in: line) ?? ""
                    guard !written.contains("."), p >= 100 else { return p }
                    warnOnce("Read whole-number dwells of 100 or more (like P\(written)) as milliseconds, "
                        + "the way Masso and Fanuc-style controls do.")
                    return p / 1000
                }
            }
            func emit(_ kind: MotionKind, _ target: Vec3, feed f: Double = 0) {
                current.motions.append(Motion(kind: kind, end: target, feed: kind == .rapid ? 0 : f, a: rotary))
                current.lines.append(lineNo)
                pos = target
            }

            if dwellRequested {
                emit(.dwell, pos, feed: dwellSeconds(values["P"] ?? 0))
                continue
            }

            if Self.isCycle(motionMode) || motionMode == Self.skippedCycle {
                if let r = values["R"] { cycleR = units.toMM(r) }
                if let z = values["Z"] { cycleZ = units.toMM(z) }
                if let q = values["Q"] { cycleQ = abs(units.toMM(q)) }
                if let p = values["P"] { cycleDwell = dwellSeconds(p) }
                guard values["X"] != nil || values["Y"] != nil || values["Z"] != nil,
                      motionMode != Self.skippedCycle else { continue }
                guard let rWord = cycleR, let zWord = cycleZ else {
                    warnOnce("Line \(lineNo): a drilling cycle without its R or Z level was skipped.")
                    continue
                }
                if values["A"] != nil { warnOnce("A words in drilling cycles are ignored.") }
                let repeats = max(1, min(Int(values["L"] ?? 1), 1000))
                for _ in 0..<repeats {
                    if cycleStartZ == nil { cycleStartZ = pos.z }
                    // G91: R is measured from the Z the block starts at, and Z from the R level.
                    let rLevel = absolute ? rWord : pos.z + rWord
                    let bottom = absolute ? zWord : rLevel + zWord
                    let clear = retractToR ? rLevel : max(cycleStartZ ?? rLevel, rLevel)
                    func xy(_ c: Character, _ cur: Double) -> Double {
                        guard let v = values[c] else { return cur }
                        return absolute ? units.toMM(v) : cur + units.toMM(v)
                    }
                    let hole = Vec2(xy("X", pos.x), xy("Y", pos.y))
                    if pos.z < rLevel { emit(.rapid, Vec3(pos.x, pos.y, rLevel)) }
                    if hole != pos.xy { emit(.rapid, Vec3(hole, pos.z)) }
                    if pos.z != rLevel { emit(.rapid, Vec3(hole, rLevel)) }
                    guard bottom < rLevel else {
                        warnOnce("Line \(lineNo): a drilling cycle's Z is not below its R level, so it drills nothing.")
                        continue
                    }
                    switch motionMode {
                    case 83 where cycleQ > 0, 73 where cycleQ > 0:
                        // G83 rapids out to R after each peck and back down to just above the last depth; G73 only
                        // backs off a little to break the chip.
                        let backOff = 0.254
                        var depth = rLevel
                        while depth > bottom + 1e-9 {
                            let next = max(depth - cycleQ, bottom)
                            if motionMode == 83, depth < rLevel { emit(.rapid, Vec3(hole, depth + backOff)) }
                            emit(.feed, Vec3(hole, next), feed: feed)
                            depth = next
                            if depth > bottom + 1e-9 {
                                emit(.rapid, Vec3(hole, motionMode == 83 ? rLevel : depth + backOff))
                            }
                        }
                    default:
                        if motionMode == 83 || motionMode == 73 {
                            warnOnce("Line \(lineNo): a peck cycle without a Q depth was drilled in one pass.")
                        }
                        emit(.feed, Vec3(hole, bottom), feed: feed)
                        if motionMode == 82 || motionMode == 89 { emit(.dwell, pos, feed: cycleDwell) }
                        if motionMode == 85 || motionMode == 89 { emit(.feed, Vec3(hole, rLevel), feed: feed) }
                    }
                    if pos.z != clear { emit(.rapid, Vec3(hole, clear)) }
                }
                continue
            }

            // A is in degrees whatever the units (G20 doesn't scale it).
            if let a = values["A"] {
                warnOnce("This program turns a rotary axis (A words). Rotary moves aren't simulated yet, so the "
                    + "preview shows every cut as if the part never turned.")
                if motionMode <= 1 { rotary = absolute ? a : (rotary ?? 0) + a }
            }
            let hasAxis = values["X"] != nil || values["Y"] != nil || values["Z"] != nil
            guard hasAxis || (values["A"] != nil && motionMode <= 1) else { continue }
            func axis(_ c: Character, _ cur: Double) -> Double {
                guard let v = values[c] else { return cur }
                return absolute ? units.toMM(v) : cur + units.toMM(v)
            }
            let target = Vec3(axis("X", pos.x), axis("Y", pos.y), axis("Z", pos.z))
            switch motionMode {
            case 0:
                current.motions.append(Motion(kind: .rapid, end: target, a: rotary))
            case 1:
                current.motions.append(Motion(kind: .feed, end: target, feed: feed, a: rotary))
            case 2, 3:
                var center: Vec2
                if let r = values["R"] {
                    center = arcCenterFromRadius(start: pos.xy, end: target.xy, r: units.toMM(r), cw: motionMode == 2)
                } else {
                    let i = units.toMM(values["I"] ?? 0), j = units.toMM(values["J"] ?? 0)
                    center = arcIncremental ? Vec2(pos.x + i, pos.y + j) : Vec2(i, j)
                }
                if values["A"] != nil { warnOnce("A words on arcs (G2/G3) are ignored.") }
                current.motions.append(Motion(kind: motionMode == 2 ? .arcCW : .arcCCW, end: target, center: center,
                                              feed: feed, a: rotary))
            default:
                break
            }
            if current.lines.count < current.motions.count { current.lines.append(lineNo) }
            pos = target
        }
        if !current.motions.isEmpty { segments.append(current) }
        return GCodeProgram(segments: segments, warnings: warnings, units: units, pauses: pauses)
    }

    /// Motion modes for the drilling cycles the parser expands, and the one it reads but doesn't simulate.
    static func isCycle(_ mode: Int) -> Bool { [73, 81, 82, 83, 85, 86, 89].contains(mode) }
    static let skippedCycle = -84

    static func stripComments(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == ";" && depth == 0 { break }
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    /// The text of a line's comments (inside parentheses, or after a semicolon), joined; nil when it has none.
    static func commentText(_ s: String) -> String? {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for (i, ch) in s.enumerated() {
            if ch == ";" && depth == 0 { parts.append(String(s.dropFirst(i + 1))); break }
            if ch == "(" { depth += 1; if depth == 1 { continue } }
            if ch == ")" { depth = max(0, depth - 1); if depth == 0 { parts.append(current); current = ""; continue } }
            if depth > 0 { current.append(ch) }
        }
        let text = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// The number written after `letter` on a comment-stripped, uppercased line, as text.
    static func wordText(_ letter: Character, in line: String) -> String? {
        guard let at = line.firstIndex(of: letter) else { return nil }
        let rest = line[line.index(after: at)...].drop { $0 == " " }
        return String(rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" })
    }

    static func tokenize(_ line: String, lineNo: Int) throws -> [(Character, Double)] {
        var out: [(Character, Double)] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            guard c.isLetter else { throw ParseError.badWord(line: lineNo, text: String(c)) }
            i += 1
            var num = ""
            while i < chars.count, chars[i] == " " { i += 1 }
            while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "-" || chars[i] == "+" {
                num.append(chars[i])
                i += 1
            }
            guard let v = Double(num) else { throw ParseError.badWord(line: lineNo, text: "\(c)\(num)") }
            out.append((c, v))
        }
        return out
    }

    static func arcCenterFromRadius(start: Vec2, end: Vec2, r: Double, cw: Bool) -> Vec2 {
        let mid = (start + end) * 0.5
        let d = end - start
        let half = d.length / 2
        let h = (max(0, r * r - half * half)).squareRoot()
        let n = d.normalized.perpLeft
        // Positive R = minor arc. For CW the centre is to the right of start→end.
        let sign: Double = (cw ? -1 : 1) * (r >= 0 ? 1 : -1)
        return mid + n * (h * sign)
    }
}
