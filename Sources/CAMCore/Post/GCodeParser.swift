import Foundation

/// Reads RS-274 style G-code (the subset routers use) back into motions.
///
/// Used to verify our own output (post → parse → compare) and to load `.tap`/`.nc` files from other CAM
/// programs into the simulator. Coordinates come back in millimetres in the program's work coordinates.
public struct GCodeProgram: Sendable {
    public struct Segment: Sendable {
        public var toolNumber: Int
        public var spindleRPM: Double
        public var start: Vec3
        public var motions: [Motion]
    }

    public var segments: [Segment]
    public var warnings: [String]
    public var units: LengthUnit

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

    public static func parse(_ text: String) throws -> GCodeProgram {
        var units: LengthUnit = .inch
        var absolute = true
        var arcIncremental = true // G91.1 is Mach4's default
        var motionMode = 0
        var feed = 0.0
        var rpm = 0.0
        var tool = 0
        var pos = Vec3.zero
        var warnings: [String] = []
        var warned = Set<String>()
        func warnOnce(_ s: String) { if warned.insert(s).inserted { warnings.append(s) } }

        var segments: [GCodeProgram.Segment] = []
        var current = GCodeProgram.Segment(toolNumber: 0, spindleRPM: 0, start: pos, motions: [])
        func newSegment() {
            if !current.motions.isEmpty { segments.append(current) }
            current = GCodeProgram.Segment(toolNumber: tool, spindleRPM: rpm, start: pos, motions: [])
        }

        var lineNo = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            lineNo += 1
            let line = stripComments(String(rawLine)).uppercased()
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("%") { continue }
            let words = try tokenize(line, lineNo: lineNo)

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
            var dwellRequested = false
            for g in gCodes {
                switch g {
                case 0, 1, 2, 3: motionMode = Int(g)
                case 4: dwellRequested = true
                case 20: units = .inch
                case 21: units = .mm
                case 90: absolute = true
                case 91: absolute = false
                case 90.1: arcIncremental = false
                case 91.1: arcIncremental = true
                case 17, 40, 49, 80, 94, 54, 43, 61, 64: break
                case 18, 19: warnOnce("Arcs outside the XY plane (G18/G19) aren't simulated.")
                case 28, 30, 53: warnOnce("Machine-coordinate moves (G28/G30/G53) are skipped in the simulation.")
                case 81, 82, 83, 73, 85: warnOnce("Canned drilling cycles (G8x) aren't expanded; holes won't show in the simulation.")
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

            if dwellRequested {
                let p = values["P"] ?? 0
                current.motions.append(Motion(kind: .dwell, end: pos, feed: p))
                continue
            }

            let hasAxis = values["X"] != nil || values["Y"] != nil || values["Z"] != nil
            guard hasAxis else { continue }
            func axis(_ c: Character, _ cur: Double) -> Double {
                guard let v = values[c] else { return cur }
                return absolute ? units.toMM(v) : cur + units.toMM(v)
            }
            let target = Vec3(axis("X", pos.x), axis("Y", pos.y), axis("Z", pos.z))
            switch motionMode {
            case 0:
                current.motions.append(.rapid(target))
            case 1:
                current.motions.append(.feed(target, feed))
            case 2, 3:
                var center: Vec2
                if let r = values["R"] {
                    center = arcCenterFromRadius(start: pos.xy, end: target.xy, r: units.toMM(r), cw: motionMode == 2)
                } else {
                    let i = units.toMM(values["I"] ?? 0), j = units.toMM(values["J"] ?? 0)
                    center = arcIncremental ? Vec2(pos.x + i, pos.y + j) : Vec2(i, j)
                }
                current.motions.append(Motion(kind: motionMode == 2 ? .arcCW : .arcCCW, end: target, center: center, feed: feed))
            default:
                break
            }
            pos = target
        }
        if !current.motions.isEmpty { segments.append(current) }
        return GCodeProgram(segments: segments, warnings: warnings, units: units)
    }

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
