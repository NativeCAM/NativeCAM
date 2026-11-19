import Foundation

/// A Vectric post processor (`.pp`), read from the user's own copy and run as a template. Vectric posts are plain
/// declarative files that nearly every router maker publishes, so they're the best specification of a controller
/// NativeCAM has no built-in post for. NativeCAM never ships one: the user imports the file they already have, the
/// project keeps a copy, and every file it writes goes through the export checks.
///
/// Supported: the global statements that shape output (POST_NAME, FILE_EXTENSION, UNITS, LINE_ENDING, line
/// numbers, SUBSTITUTE, MIN/MAX_ARC_RADIUS, FIRST_TOOLPATH_NEW_SEGMENT), `VAR` formats, and the blocks a router
/// job uses: HEADER, SPINDLE_ON, TOOLCHANGE, NEW_SEGMENT, rapids, feeds, plunges, retracts, arcs (incremental or
/// absolute I/J, or R), helical arcs, dwells and FOOTER. Rotary wrapping, inverse-time feeds and POST_BASE are
/// refused; laser, drill-bank and cutter-compensation blocks are ignored because NativeCAM never needs them.
public struct VectricPost: Hashable, Codable, Sendable {
    public struct Variable: Hashable, Codable, Sendable {
        public var name: String
        public var label: String
        /// Output every time (`A`) or only when the value changes (`C`).
        public var always: Bool
        public var prefix: String
        public var showPlus: Bool
        public var zeroPad: Bool
        public var width: Int
        public var decimals: Int
        public var alwaysPoint: Bool
        public var commaDecimal: Bool
        public var multiplier: Double
    }

    /// How an item in the file was handled, for the conversion report.
    public struct ReportItem: Hashable, Codable, Sendable {
        public enum Status: String, Codable, Sendable { case used, ignored, refused }
        public var item: String
        public var status: Status
        public var note: String
    }

    public var name: String
    public var fileExtension: String
    public var units: LengthUnit
    public var lineEnding: String
    public var lineNumberStart: Int?
    public var lineNumberIncrement: Int
    public var lineNumberMaximum: Int?
    /// SUBSTITUTE pairs: characters in text tokens swapped for others (often parentheses in names).
    public var substitutions: [String: String]
    public var minArcRadius: Double?
    public var maxArcRadius: Double?
    public var firstToolpathNewSegment: Bool
    public var variables: [String: Variable]
    public var blocks: [String: [String]]
    public var report: [ReportItem]
    /// The file as imported, kept so the project re-posts identically.
    public var source: String

    public var refused: [ReportItem] { report.filter { $0.status == .refused } }
    public var usesArcs: Bool { blocks["CW_ARC_MOVE"] != nil || blocks["CCW_ARC_MOVE"] != nil }
    public var usesAbsoluteArcCentres: Bool { blocks.values.joined().contains { $0.contains("[IA]") || $0.contains("[JA]") } }
    public var changesTools: Bool { blocks["TOOLCHANGE"] != nil }
    /// True when the post writes G-code that NativeCAM can read back (rather than, say, ShopBot's OpenSBP).
    public var writesGCode: Bool {
        let move = (blocks["FEED_MOVE"] ?? []).joined()
        return move.range(of: #"G0?1"#, options: .regularExpression) != nil
    }
}

public enum VectricPostError: Error, LocalizedError {
    case notAPost
    case refused([VectricPost.ReportItem])

    public var errorDescription: String? {
        switch self {
        case .notAPost: "This isn't a Vectric post processor (.pp): it has no POST_NAME or output blocks."
        case let .refused(items):
            "NativeCAM can't run this post: " + items.map { "\($0.item) (\($0.note))" }.joined(separator: "; ") + "."
        }
    }
}

public extension VectricPost {
    /// Tokens NativeCAM fills. Anything else in an output line refuses the post.
    static let knownTokens: Set<String> = [
        "X", "Y", "Z", "XH", "YH", "ZH", "I", "J", "IA", "JA", "RADIUS", "F", "FC", "FP", "FI", "S", "T", "TP", "TDIA", "N",
        "DWELL", "SAFEZ", "XLENGTH", "YLENGTH", "ZLENGTH", "XMIN", "XMAX", "YMIN", "YMAX", "ZMIN", "ZMAX", "TOOLNAME",
        "TOOLPATH_NAME", "TOOLPATH_NOTES", "TP_FILENAME", "TP_FILE_NAME", "PATHNAME", "TOOLS_USED", "FILE_NOTES", "DATE",
        "TIME", "PRODUCT", "XY_ORIGIN", "Z_ORIGIN", "P",
    ]
    static let blocksUsed: Set<String> = [
        "HEADER", "SPINDLE_ON", "TOOLCHANGE", "NEW_SEGMENT", "FOOTER", "INITIAL_RAPID_MOVE", "RAPID_MOVE", "FIRST_FEED_MOVE",
        "FEED_MOVE", "FEED_RATE_CHANGE", "FIRST_PLUNGE_MOVE", "PLUNGE_MOVE", "RETRACT_MOVE", "DWELL_MOVE", "FIRST_CW_ARC_MOVE",
        "CW_ARC_MOVE", "FIRST_CCW_ARC_MOVE", "CCW_ARC_MOVE", "FIRST_CW_HELICAL_ARC_MOVE", "CW_HELICAL_ARC_MOVE",
        "FIRST_CCW_HELICAL_ARC_MOVE", "CCW_HELICAL_ARC_MOVE", "FIRST_CW_HELICAL_ARC_PLUNGE_MOVE",
        "FIRST_CCW_HELICAL_ARC_PLUNGE_MOVE",
    ]

    /// Reads a `.pp`. Throws when it isn't a post, or uses something NativeCAM can't do safely.
    static func parse(_ text: String) throws -> VectricPost {
        var post = VectricPost(name: "", fileExtension: "tap", units: .inch, lineEnding: "\r\n", lineNumberStart: nil,
                               lineNumberIncrement: 10, lineNumberMaximum: nil, substitutions: [:], minArcRadius: nil,
                               maxArcRadius: nil, firstToolpathNewSegment: false, variables: [:], blocks: [:], report: [],
                               source: text)
        var current: String?
        func note(_ item: String, _ status: ReportItem.Status, _ why: String) {
            post.report.append(ReportItem(item: item, status: status, note: why))
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("+") || line.hasPrefix("|") { continue }
            if line.lowercased().hasPrefix("begin ") {
                let name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces).uppercased()
                current = name
                post.blocks[name] = post.blocks[name] ?? []
                continue
            }
            if line.hasPrefix("\""), let block = current {
                // An output line: the text between the outer quotes.
                var body = String(line.dropFirst())
                if let end = body.lastIndex(of: "\"") { body = String(body[..<end]) }
                post.blocks[block, default: []].append(body)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            current = nil
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key.uppercased().hasPrefix("VAR ") {
                let name = String(key.dropFirst(4)).trimmingCharacters(in: .whitespaces).uppercased()
                if let v = variable(name: name, spec: value) { post.variables[v.label.uppercased()] = v }
                continue
            }
            switch key.uppercased() {
            case "POST_NAME": post.name = unquoted
            case "FILE_EXTENSION": post.fileExtension = unquoted
            case "UNITS": post.units = unquoted.uppercased().hasPrefix("MM") ? .mm : .inch
            case "LINE_ENDING": post.lineEnding = unescape(unquoted)
            case "LINE_NUMBER_START": post.lineNumberStart = Int(unquoted)
            case "LINE_NUMBER_INCREMENT": post.lineNumberIncrement = Int(unquoted) ?? 10
            case "LINE_NUMBER_MAXIMUM": post.lineNumberMaximum = Int(unquoted)
            case "MIN_ARC_RADIUS": post.minArcRadius = Double(unquoted)
            case "MAX_ARC_RADIUS": post.maxArcRadius = Double(unquoted)
            case "FIRST_TOOLPATH_NEW_SEGMENT": post.firstToolpathNewSegment = unquoted.uppercased() == "YES"
            case "SUBSTITUTE":
                // Pairs of characters: each first one becomes the second ("([91])[93]" swaps ( for [ and ) for ]).
                let chars = Array(unescape(unquoted))
                var i = 0
                while i + 1 < chars.count { post.substitutions[String(chars[i])] = String(chars[i + 1]); i += 2 }
            case "ROTARY_WRAP_X", "ROTARY_WRAP_Y":
                if unquoted.uppercased() != "NO" { note(String(key), .refused, "rotary wrapping isn't supported") }
            case "INVERSE_TIME_MODE":
                if unquoted.uppercased() != "NO" { note(String(key), .refused, "inverse-time feeds aren't supported") }
            case "POST_BASE":
                note("POST_BASE", .refused, "the post builds on another post; open that post instead")
            case "LASER_SUPPORT", "DIRECT_OUTPUT", "PRINT_DIRECT", "TAPE_SPLITTING", "SPINDLE_SPEED_RANGE", "RAPID_PLUNGE_TO_STARTZ",
                 "MAXIMUM_ROTATION", "RAPID_SPEED", "MAXIMUM_LENGTH":
                note(String(key), .ignored, ignoredReason(String(key).uppercased()))
            default:
                note(String(key), .ignored, "not used by NativeCAM")
            }
        }
        guard !post.name.isEmpty || !post.blocks.isEmpty, post.blocks["FEED_MOVE"] != nil || post.blocks["HEADER"] != nil else {
            throw VectricPostError.notAPost
        }
        // Blocks and tokens.
        for (name, lines) in post.blocks.sorted(by: { $0.key < $1.key }) {
            guard blocksUsed.contains(name) else {
                note(name, .ignored, "NativeCAM never writes this kind of move")
                continue
            }
            for line in lines {
                for token in tokens(in: line) where Int(token) == nil {
                    let label = token.uppercased()
                    let known = knownTokens.contains(label) || post.variables[label] != nil
                    if label == "A" || label == "WRAP_DIA" {
                        note("[\(token)] in \(name)", .refused, "rotary axis output isn't supported")
                    } else if !known {
                        note("[\(token)] in \(name)", .refused, "NativeCAM doesn't know this token")
                    }
                }
            }
            note(name, .used, "\(lines.count) line\(lines.count == 1 ? "" : "s")")
        }
        if post.blocks["FEED_MOVE"] == nil { note("FEED_MOVE", .refused, "the post has no feed move block") }
        if !post.usesArcs { note("Arcs", .used, "no arc blocks, so arcs are written as short lines") }
        if !post.changesTools { note("TOOLCHANGE", .used, "no tool-change block, so each tool gets its own file") }
        if !post.refused.isEmpty { throw VectricPostError.refused(post.refused) }
        return post
    }

    private static func ignoredReason(_ key: String) -> String {
        switch key {
        case "LASER_SUPPORT": "laser output isn't used"
        case "DIRECT_OUTPUT", "PRINT_DIRECT": "NativeCAM saves files rather than sending them"
        case "TAPE_SPLITTING": "files aren't split by length"
        case "SPINDLE_SPEED_RANGE": "spindle speed codes aren't remapped; [S] is the RPM"
        case "MAXIMUM_LENGTH": "long moves aren't split"
        case "RAPID_SPEED": "rapids are written with the rapid block"
        default: "not used by NativeCAM"
        }
    }

    /// `[label|when|prefix|format|multiplier]`.
    static func variable(name: String, spec: String) -> Variable? {
        guard let open = spec.firstIndex(of: "["), let close = spec.lastIndex(of: "]"), open < close else { return nil }
        let parts = spec[spec.index(after: open)..<close].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        var format = parts[3].trimmingCharacters(in: .whitespaces)
        var showPlus = false, zeroPad = false, alwaysPoint = false
        while let f = format.first, "+-0#".contains(f) {
            if f == "+" { showPlus = true }
            if f == "0" { zeroPad = true }
            if f == "#" { alwaysPoint = true }
            format.removeFirst()
        }
        if format.hasSuffix("#") { alwaysPoint = true; format.removeLast() }
        let comma = format.contains(",")
        let pieces = format.split(whereSeparator: { $0 == "." || $0 == "," })
        let width = Int(pieces.first ?? "1") ?? 1
        let decimals = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
        let multiplier = parts.count > 4 ? Double(parts[4].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
        return Variable(name: name, label: parts[0].trimmingCharacters(in: .whitespaces),
                        always: parts[1].trimmingCharacters(in: .whitespaces).uppercased() != "C", prefix: parts[2],
                        showPlus: showPlus, zeroPad: zeroPad, width: width, decimals: decimals, alwaysPoint: alwaysPoint,
                        commaDecimal: comma, multiplier: multiplier)
    }

    /// `[13][10]` → CR LF, and so on.
    static func unescape(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "[") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "]"), let code = Int(rest[rest.index(after: open)..<close]),
                  let scalar = Unicode.Scalar(code) else {
                out.append("[")
                rest = rest[rest.index(after: open)...]
                continue
            }
            out.append(Character(scalar))
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// Token names in an output line (the text inside each `[...]`).
    static func tokens(in line: String) -> [String] {
        var out: [String] = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            out.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// Formats a number as a variable says.
    func format(_ value: Double, _ v: Variable) -> String {
        let x = value * v.multiplier
        var s = String(format: "%.\(v.decimals)f", abs(x))
        if v.decimals == 0 && v.alwaysPoint { s += "." }
        let intPart = s.split(separator: ".").first.map(String.init) ?? s
        if intPart.count < v.width, v.zeroPad { s = String(repeating: "0", count: v.width - intPart.count) + s }
        if v.commaDecimal { s = s.replacingOccurrences(of: ".", with: ",") }
        let negative = x < 0 && (Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0) != 0
        if negative { s = "-" + s } else if v.showPlus { s = "+" + s }
        return v.prefix + s
    }
}
