import Foundation
import SQLite3

/// A tool read from a tool library, with the folder it sat in there.
public struct ImportedTool: Sendable, Identifiable, Hashable {
    public var tool: Tool
    /// Folder path in the source library (for example "Amana Tool Master ▸ 1/4" Shank"); empty when it has none.
    public var group: String
    public var id: UUID { tool.id }

    public init(tool: Tool, group: String = "") {
        self.tool = tool
        self.group = group
    }
}

/// A tool the library had that NativeCAM can't represent (a form or thread tool, say), and why.
public struct SkippedTool: Sendable, Hashable {
    public var name: String
    public var reason: String
}

/// The tools found in one library file.
public struct ToolImport: Sendable {
    public enum Format: String, Sendable {
        case nativeCAM = "NativeCAM tool library"
        case fusion = "Fusion 360 tool library"
        case vectric = "Vectric tool database"
    }

    public var format: Format
    public var tools: [ImportedTool]
    public var skipped: [SkippedTool]
}

public enum ToolImportError: Error, LocalizedError {
    case unsupported(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(m), let .unreadable(m): m
        }
    }
}

/// Reads other CAM programs' tool libraries into NativeCAM tools:
/// - Fusion 360 tool libraries: `.tools` (a ZIP holding `tools.json`) or the exported `.json`;
/// - Vectric tool databases (`.vtdb`, VCarve and Aspire 10.5 and later; a SQLite file);
/// - NativeCAM's own exported `.json`.
///
/// Vendors publish their bits in these formats (Amana Tool, for example, ships both). Geometry, flute count and the
/// library's feeds and speeds come across; anything the file doesn't say (Vectric files carry no cutting or shank
/// length) is read from the tool's name where it follows the usual "D x cut length x shank" pattern, otherwise
/// estimated, and every estimate is written into the tool's notes. Tapered ball noses, roundover (radius) and dovetail
/// bits come across as those shapes; Vectric form tools whose names say what they are (roundover, cove, ogee, dovetail)
/// do too, with their profile read from the name and noted as such. Tools NativeCAM can't cut with (thread mills,
/// slot and lollipop cutters, other form tools, lasers) are listed as skipped instead of being approximated.
public enum ToolLibraryImporter {
    public static let fileExtensions = ["tools", "vtdb", "json"]

    public static func load(url: URL) throws -> ToolImport {
        let ext = url.pathExtension.lowercased()
        if ext == "tool" {
            throw ToolImportError.unsupported("Vectric's older .tool format isn't supported. Use the .vtdb version of the "
                + "library (the format VCarve and Aspire 10.5 and later use).")
        }
        if ext == "vtdb" { return try vectric(path: url.path) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ToolImportError.unreadable("Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
        if data.starts(with: Array("SQLite format 3".utf8)) { return try vectric(path: url.path) }
        return try load(data: data)
    }

    /// Fusion `.tools` / `.json` or NativeCAM `.json` contents.
    public static func load(data: Data) throws -> ToolImport {
        var json = data
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let zip = try ZipArchive(data: data)
            guard let entry = zip.entry(named: "tools.json") ?? zip.entries.first(where: { $0.name.lowercased().hasSuffix(".json") }) else {
                throw ToolImportError.unsupported("This archive doesn't hold a tool library (no tools.json inside).")
            }
            json = try zip.extract(entry)
        }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ToolImportError.unsupported("This file isn't a tool library NativeCAM can read.")
        }
        if root["tools"] != nil, let lib = try? ToolLibrary.decode(json) {
            return ToolImport(format: .nativeCAM, tools: lib.tools.map { ImportedTool(tool: $0) }, skipped: [])
        }
        if let items = root["data"] as? [[String: Any]] { return fusion(items) }
        throw ToolImportError.unsupported("This JSON file isn't a NativeCAM or Fusion 360 tool library.")
    }

    // MARK: Fusion 360

    static func fusion(_ items: [[String: Any]]) -> ToolImport {
        var tools: [ImportedTool] = [], skipped: [SkippedTool] = []
        for item in items {
            switch fusionTool(item) {
            case let .tool(t): tools.append(ImportedTool(tool: t))
            case let .skip(s): skipped.append(s)
            case .ignore: break
            }
        }
        return ToolImport(format: .fusion, tools: tools, skipped: skipped)
    }

    enum Outcome { case tool(Tool), skip(SkippedTool), ignore }

    static func fusionTool(_ t: [String: Any]) -> Outcome {
        let type = (t["type"] as? String ?? "").lowercased()
        if type == "holder" || type == "probe" || type.isEmpty { return .ignore }
        let scale = ((t["unit"] as? String) ?? "").lowercased().hasPrefix("inch") ? 25.4 : 1
        let g = t["geometry"] as? [String: Any] ?? [:]
        func len(_ key: String) -> Double? { number(g[key]).map { $0 * scale } }
        let product = (t["product-id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let vendor = (t["vendor"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var name = (t["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ") }
        if name.isEmpty { name = type.capitalized }
        if !product.isEmpty, !name.contains(product) { name = "\(product) \(name)" }

        guard let dc = len("DC"), dc > 0 else { return .skip(SkippedTool(name: name, reason: "no cutting diameter")) }
        let re = len("RE") ?? 0, tip = len("tip-diameter") ?? 0
        let taper = number(g["TA"]) ?? 0, sig = number(g["SIG"]) ?? 0
        var shape: ToolShape
        var corner = 0.0, angle = 90.0, tipDiameter = 0.0
        switch type {
        case "flat end mill":
            shape = surfacingName(name) ? .surfacing : .flatEndMill
        case "face mill":
            shape = .surfacing
        case "ball end mill":
            shape = .ballNose
        case "bull nose end mill":
            shape = re >= dc / 2 - 1e-6 ? .ballNose : (re > 1e-6 ? .bullNose : .flatEndMill)
            corner = re
        case "tapered mill":
            if taper < 1 { // "0.10° straight" carving bits: effectively straight
                shape = re >= dc / 2 - 1e-6 ? .ballNose : (re > 1e-6 ? .bullNose : .flatEndMill)
                corner = re
            } else if re > 1e-3 {
                shape = .taperedBallNose
                angle = 2 * taper
                tipDiameter = 2 * re
            } else {
                shape = .engraving
                angle = 2 * taper
                tipDiameter = tip > 0 ? tip : dc
            }
        case "chamfer mill", "counter sink", "engrave mill":
            // Chamfer mills give the taper per side (TA), countersinks the included point angle (SIG).
            angle = taper > 0 ? 2 * taper : (sig > 0 ? sig : 90)
            tipDiameter = tip
            shape = tip > 0.01 ? .engraving : .vBit
        case "drill", "spot drill":
            shape = .drill
            angle = sig > 0 ? sig : 118
        case "radius mill":
            guard re > 1e-6 else { return .skip(SkippedTool(name: name, reason: "roundover bit with no radius")) }
            shape = .form
        case "dovetail mill":
            guard taper > 1e-6 else { return .skip(SkippedTool(name: name, reason: "dovetail bit with no angle")) }
            shape = .dovetail
            // Wood dovetails lean 7–14° from upright; an angle past 45° is measured from the bottom face instead.
            angle = 2 * (taper > 45 ? 90 - taper : taper)
        default:
            return .skip(SkippedTool(name: name, reason: unsupportedReason(type)))
        }
        let preset = ((t["start-values"] as? [String: Any])?["presets"] as? [[String: Any]])?.first
        var notes = [vendor.isEmpty && product.isEmpty ? nil : "\(vendor) \(product)".trimmingCharacters(in: .whitespaces),
                     "Imported from a Fusion 360 tool library.",
                     t["product-link"] as? String].compactMap { $0?.isEmpty == false ? $0 : nil }
        let hints = ToolNameHints.parse(name, inches: scale > 1)
        var tool = Tool(id: UUID(uuidString: t["guid"] as? String ?? "") ?? stableID(name + type),
                        number: number((t["post-process"] as? [String: Any])?["number"]).map { Int($0) } ?? 0,
                        name: name, shape: shape,
                        fluteDirection: hints.direction ?? defaultDirection(shape),
                        fluteCount: max(1, Int(number(g["NOF"]) ?? 2)),
                        diameter: dc, shankDiameter: len("SFDM").flatMap { $0 > 0 ? $0 : nil },
                        fluteLength: len("LCF") ?? 0, cornerRadius: corner, includedAngle: angle, tipDiameter: tipDiameter,
                        cutting: CuttingData(spindleRPM: 0, feedRate: 0, plungeRate: 0, stepdown: 0, stepoverFraction: 0))
        if let lb = len("LB"), lb >= tool.fluteLength { tool.stickout = lb }
        switch shape {
        case .taperedBallNose:
            notes.append("Tapered ball nose: \(fmtMM(re)) mm tip radius, \(fmtMM(taper))° per side (Fusion's taper angle).")
            // Fusion's diameter is the tip's; the bit widens up its flutes to the shank.
            if len("SFDM").map({ $0 <= 0 }) ?? true {
                tool.shankDiameter = hints.shank ?? max(0.25.inch, dc)
                if hints.shank == nil { notes.append("⚠ Shank diameter estimated as \(fmtMM(tool.shankDiameter)) mm (the library doesn't give it): check it.") }
            }
            tool.diameter = tool.shankDiameter
        case .form:
            let pilot = len("tip-diameter").flatMap { $0 > 0 ? $0 : nil } ?? max(0, dc - 2 * re)
            tool.form = FormProfile(kind: .roundover, radius: re, pilotDiameter: pilot)
            if tool.fluteLength < re { tool.fluteLength = re }
            notes.append("⚠ Roundover: \(fmtMM(re)) mm radius, \(fmtMM(pilot)) mm pilot"
                + (len("tip-diameter") == nil ? " (the diameter less twice the radius)" : "") + ". Check the profile against the bit.")
        case .dovetail:
            notes.append("⚠ Dovetail: \(fmtMM(angle / 2))° per side, read from Fusion's taper angle\(taper > 45 ? " (measured from the bottom face)" : ""). "
                + "Check it against the bit.")
        default:
            break
        }
        var cutting = tool.cutting
        if let p = preset {
            cutting.spindleRPM = number(p["n"]) ?? 0
            cutting.feedRate = (number(p["v_f"]) ?? 0) * scale
            cutting.plungeRate = (number(p["v_f_plunge"]) ?? 0) * scale
            if p["use-stepdown"] as? Bool == true, let s = number(p["stepdown"]) { cutting.stepdown = s * scale }
            if p["use-stepover"] as? Bool == true, let s = number(p["stepover"]) {
                cutting.stepoverFraction = s * scale / (shape == .taperedBallNose ? max(tipDiameter, 1e-6) : dc)
            }
            if cutting.feedRate > 0, let pname = p["name"] as? String, !pname.isEmpty {
                notes.append("Feeds and speeds from its “\(pname)” preset.")
            }
        }
        tool.cutting = cutting
        finish(&tool, notes: &notes, hints: hints)
        tool.fitDiameterToShape()
        tool.notes = notes.joined(separator: "\n")
        if let problem = tool.geometryProblem { return .skip(SkippedTool(name: name, reason: problem)) }
        return .tool(tool)
    }

    static func fmtMM(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...3))) }

    // MARK: Vectric

    /// Vectric's tool types (`tool_geometry.tool_type`).
    enum VectricType: Int {
        case ballNose = 0, endMill = 1, radiusedEndMill = 2, vBit = 3, engraving = 4, taperedBallNose = 5, drill = 6,
             diamondDrag = 7, formTool = 8, threadMill = 9, laser = 10
    }

    static func vectric(path: String) throws -> ToolImport {
        var db: OpaquePointer?
        // Read-only and immutable: no journal or lock files are created next to the user's file.
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ToolImportError.unreadable("Couldn't open “\((path as NSString).lastPathComponent)” as a Vectric tool database.")
        }
        defer { sqlite3_close(db) }
        let reader = SQLiteReader(db: db)
        guard reader.columns("tool_geometry").contains("tool_type") else {
            throw ToolImportError.unsupported("This database doesn't contain Vectric tools.")
        }

        // Folder tree: entries with no geometry are groups; tools are leaves.
        struct Entry { var id: String; var parent: String?; var order: Int; var geometry: String?; var name: String? }
        let entries = reader.rows("tool_tree_entry", ["id", "parent_group_id", "sibling_order", "tool_geometry_id", "name"]).map {
            Entry(id: $0[0].text ?? "", parent: $0[1].text, order: Int($0[2].number ?? 0), geometry: $0[3].text, name: $0[4].text)
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func groupPath(_ e: Entry) -> String {
            var names: [String] = []
            var p = e.parent
            var guardCount = 0
            while let id = p, let parent = byID[id], guardCount < 64 {
                if let n = parent.name, !n.isEmpty { names.append(n) }
                p = parent.parent
                guardCount += 1
            }
            return names.reversed().joined(separator: " ▸ ")
        }
        // Depth-first in sibling order, so tools come out in the order Vectric shows them.
        let children = Dictionary(grouping: entries, by: { $0.parent ?? "" })
        var ordered: [Entry] = []
        func walk(_ parent: String, depth: Int) {
            guard depth < 64 else { return }
            for e in (children[parent] ?? []).sorted(by: { $0.order < $1.order }) {
                ordered.append(e)
                walk(e.id, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        var place: [String: (index: Int, group: String)] = [:]
        for (i, e) in ordered.enumerated() where e.geometry != nil { place[e.geometry!] = (i, groupPath(e)) }

        // Cutting data: prefer the generic entry (no material), else the first material with feeds.
        struct Cut { var material: String?; var rateUnits: Int; var lengthUnits: Int; var feed: Double?; var plunge: Double?
            var rpm: Double?; var stepdown: Double?; var stepover: Double?; var number: Int? }
        var cuts: [String: Cut] = [:]
        let cdCols = reader.columns("tool_cutting_data")
        let lengthUnitsCol = cdCols.contains("length_units") ? "cd.length_units" : "NULL"
        let numberCol = cdCols.contains("tool_number") ? "cd.tool_number" : "NULL"
        let cutRows = reader.query("""
            SELECT te.tool_geometry_id, m.name, cd.rate_units, \(lengthUnitsCol), cd.feed_rate, cd.plunge_rate, cd.spindle_speed,
                   cd.stepdown, cd.stepover, \(numberCol)
            FROM tool_entity te LEFT JOIN material m ON m.id = te.material_id
            JOIN tool_cutting_data cd ON cd.id = te.tool_cutting_data_id
            ORDER BY m.name
            """)
        for r in cutRows {
            guard let gid = r[0].text else { continue }
            let c = Cut(material: r[1].text, rateUnits: Int(r[2].number ?? 4), lengthUnits: Int(r[3].number ?? 0), feed: r[4].number,
                        plunge: r[5].number, rpm: r[6].number, stepdown: r[7].number, stepover: r[8].number, number: r[9].number.map { Int($0) })
            if let old = cuts[gid] {
                let oldHasFeed = (old.feed ?? 0) > 0, newHasFeed = (c.feed ?? 0) > 0
                if oldHasFeed && !(newHasFeed && c.material == nil) { continue }
                if !oldHasFeed && !newHasFeed { continue }
            }
            cuts[gid] = c
        }

        let gCols = reader.columns("tool_geometry")
        func col(_ name: String) -> String { gCols.contains(name) ? name : "NULL" }
        let geoRows = reader.query("""
            SELECT id, name_format, \(col("notes")), tool_type, units, \(col("diameter")), \(col("included_angle")),
                   \(col("flat_diameter")), \(col("num_flutes")), \(col("flute_length")), \(col("tip_radius"))
            FROM tool_geometry
            """)
        var tools: [(Int, ImportedTool)] = [], skipped: [SkippedTool] = []
        for r in geoRows {
            let gid = r[0].text ?? ""
            let name = (r[1].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let vendorNotes = (r[2].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let scale = r[4].number == 1 ? 25.4 : 1
            guard let type = VectricType(rawValue: Int(r[3].number ?? -1)) else {
                skipped.append(SkippedTool(name: name, reason: "unknown Vectric tool type \(Int(r[3].number ?? -1))"))
                continue
            }
            let d = (r[5].number ?? 0) * scale
            let angleIn = r[6].number ?? 0, flat = (r[7].number ?? 0) * scale, tipR = (r[10].number ?? 0) * scale
            var shape: ToolShape
            var corner = 0.0, angle = 90.0, tipDiameter = 0.0
            switch type {
            case .ballNose: shape = .ballNose
            case .endMill: shape = surfacingName(name) ? .surfacing : .flatEndMill
            case .radiusedEndMill:
                shape = tipR >= d / 2 - 1e-6 ? .ballNose : (tipR > 1e-6 ? .bullNose : .flatEndMill)
                corner = tipR
            case .vBit, .engraving:
                angle = angleIn > 0 ? angleIn : 90
                tipDiameter = flat
                shape = flat > 0.01 ? .engraving : .vBit
            case .drill:
                shape = .drill
                angle = (60...180).contains(angleIn) ? angleIn : 118
            case .taperedBallNose:
                // Vectric's angle for a tapered ball nose is its side angle (per side).
                shape = .taperedBallNose
                angle = 2 * angleIn
                tipDiameter = 2 * tipR
            case .diamondDrag:
                skipped.append(SkippedTool(name: name, reason: "diamond drag engraver")); continue
            case .formTool:
                // The profile itself isn't in the database in a form NativeCAM reads: only bits whose names say what
                // they are come across, shaped from the name.
                guard let guess = FormNameHints.parse(name, inches: scale > 1) else {
                    skipped.append(SkippedTool(name: name, reason: "form tool (custom profile)")); continue
                }
                shape = guess.shape
                angle = guess.angle.map { 2 * $0 } ?? 90
            case .threadMill:
                skipped.append(SkippedTool(name: name, reason: "thread mill")); continue
            case .laser:
                skipped.append(SkippedTool(name: name, reason: "laser")); continue
            }
            guard d > 0 else { skipped.append(SkippedTool(name: name, reason: "no cutting diameter")); continue }
            let hints = ToolNameHints.parse(name, inches: scale > 1)
            let formGuess = type == .formTool ? FormNameHints.parse(name, inches: scale > 1) : nil
            if shape == .taperedBallNose, tipR <= 0 {
                skipped.append(SkippedTool(name: name, reason: "tapered ball nose with no tip radius")); continue
            }
            if shape == .dovetail, formGuess?.angle == nil {
                skipped.append(SkippedTool(name: name, reason: "dovetail with no angle in its name")); continue
            }
            let cut = cuts[gid]
            var tool = Tool(id: UUID(uuidString: gid) ?? stableID(gid + name), number: cut?.number ?? 0, name: name, shape: shape,
                            fluteDirection: hints.direction ?? defaultDirection(shape),
                            fluteCount: max(1, Int(r[8].number ?? 2)), diameter: d, shankDiameter: nil,
                            fluteLength: (r[9].number ?? 0) * scale, cornerRadius: corner, includedAngle: angle, tipDiameter: tipDiameter,
                            cutting: CuttingData(spindleRPM: 0, feedRate: 0, plungeRate: 0, stepdown: 0, stepoverFraction: 0))
            var notes = ["Imported from a Vectric tool database."]
            switch shape {
            case .taperedBallNose:
                // Vectric's diameter is the top of the taper (or, in some vendors' files, the tip's): the shank, unless
                // the name gives one.
                if tool.shankDiameter <= 0 || tool.shankDiameter == d, hints.shank == nil, d <= 2 * tipR + 0.01 {
                    tool.shankDiameter = 0.25.inch
                    notes.append("⚠ Shank diameter estimated as 1/4\" (the library gives only the tip): check it.")
                }
                notes.append("Tapered ball nose: \(fmtMM(tipR)) mm tip radius, \(fmtMM(angleIn))° per side (Vectric's angle).")
            case .form, .dovetail:
                if let g = formGuess {
                    if let kind = g.kind {
                        let r = g.radius ?? 0
                        let pilot = max(0, d - 2 * (kind == .ogee ? 2 * r : r))
                        tool.form = FormProfile(kind: kind, radius: r, upperRadius: r, pilotDiameter: pilot)
                        if tool.fluteLength <= 0 { tool.fluteLength = tool.form!.profileHeight }
                    }
                    notes.append("⚠ " + g.note + " Check the profile against the bit before cutting.")
                }
            default:
                break
            }
            if let c = cut, (c.feed ?? 0) > 0 {
                let rate = rateScale(c.rateUnits)
                let lengthScale = c.lengthUnits == 1 ? 25.4 : 1
                tool.cutting.spindleRPM = c.rpm ?? 0
                tool.cutting.feedRate = (c.feed ?? 0) * rate
                tool.cutting.plungeRate = (c.plunge ?? 0) * rate
                tool.cutting.stepdown = (c.stepdown ?? 0) * lengthScale
                tool.cutting.stepoverFraction = (c.stepover ?? 0) * lengthScale / (shape == .taperedBallNose ? max(tipDiameter, 1e-6) : d)
                notes.append("Feeds and speeds from its \(c.material.map { "“\($0)”" } ?? "default") settings.")
            }
            finish(&tool, notes: &notes, hints: hints)
            tool.fitDiameterToShape()
            if let problem = tool.geometryProblem { skipped.append(SkippedTool(name: name, reason: problem)); continue }
            if !vendorNotes.isEmpty { notes.append(vendorNotes.replacingOccurrences(of: "\r\n", with: "\n")) }
            tool.notes = notes.joined(separator: "\n")
            let p = place[gid] ?? (Int.max, "")
            tools.append((p.index, ImportedTool(tool: tool, group: p.group)))
        }
        return ToolImport(format: .vectric, tools: tools.sorted { $0.0 < $1.0 }.map(\.1), skipped: skipped)
    }

    /// mm/min per unit of Vectric's `rate_units`: mm/s, mm/min, m/min, in/s, in/min, ft/min.
    static func rateScale(_ units: Int) -> Double {
        switch units {
        case 0: 60
        case 1: 1
        case 2: 1000
        case 3: 25.4 * 60
        case 5: 304.8
        default: 25.4
        }
    }

    // MARK: Shared

    /// Fills what the library didn't say (shank and cutting length from the name, else estimates; feeds from the chip
    /// load chart) and notes every guess. Estimated cutting lengths err short: the depth check then warns rather than
    /// staying quiet about a cut deeper than the flutes.
    static func finish(_ tool: inout Tool, notes: inout [String], hints: ToolNameHints.Hints) {
        let d = tool.diameter
        if tool.shankDiameter <= 0 || tool.shankDiameter == d, let s = hints.shank { tool.shankDiameter = s }
        if tool.fluteLength <= 0 {
            if tool.shape.isTapered {
                tool.fluteLength = max(tool.taperHeight, 1)
            } else if let c = hints.cutLength {
                tool.fluteLength = c
                notes.append("Cutting length read from the name.")
            } else {
                tool.fluteLength = tool.shape == .drill ? min(5 * d, 40) : min(3 * d, 1.inch)
                notes.append("Cutting length estimated (the library doesn't give it): check it before deep cuts.")
            }
        }
        tool.stickout = max(tool.stickout, tool.fluteLength + 0.5.inch)
        var c = tool.cutting
        var estimated: [String] = []
        if c.feedRate <= 0 {
            tool.cutting = c
            if ChipLoad.applies(to: tool) {
                let rec = ChipLoad.recommend(for: tool, material: .plywood, machine: MachineProfile())
                c.spindleRPM = rec.rpm
                c.feedRate = rec.feed
                estimated.append("feed rate and spindle speed (plywood chip-load chart)")
            } else {
                c.feedRate = tool.shape == .drill ? 30.inch : 100.inch
                estimated.append("feed rate")
            }
        }
        if c.spindleRPM <= 0 { c.spindleRPM = 18000; estimated.append("spindle speed") }
        if c.plungeRate <= 0 {
            // A drill's plunge is its cut.
            c.plungeRate = tool.shape == .drill ? c.feedRate : min(c.feedRate / 3, 60.inch)
            estimated.append("plunge rate")
        }
        if c.stepdown <= 0 {
            switch tool.shape {
            case .vBit, .engraving: c.stepdown = 0.125.inch
            case .ballNose: c.stepdown = 0.25 * d
            case .taperedBallNose: c.stepdown = max(0.5, tool.tipDiameter)
            case .drill: c.stepdown = d
            case .form: c.stepdown = max(1, tool.form?.profileHeight ?? 0.5 * d)
            case .dovetail: c.stepdown = max(1, tool.fluteLength)
            default: c.stepdown = 0.5 * d
            }
            estimated.append("stepdown")
        }
        if c.stepoverFraction <= 0 || c.stepoverFraction > 1 {
            c.stepoverFraction = tool.shape == .ballNose || tool.shape == .taperedBallNose ? 0.1 : 0.4
            estimated.append("stepover")
        }
        tool.cutting = c
        if !estimated.isEmpty {
            notes.append("Not in the library, so set to conservative defaults: \(estimated.joined(separator: ", ")). Cut-test before relying on them.")
        }
    }

    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func surfacingName(_ name: String) -> Bool {
        let u = name.uppercased()
        return u.contains("SURFAC") || u.contains("SPOILBOARD") || u.contains("FLY CUT") || u.contains("FLYCUT")
    }

    static func defaultDirection(_ shape: ToolShape) -> FluteDirection {
        shape == .vBit || shape == .engraving || shape == .drill || shape == .form || shape == .dovetail ? .straight : .upcut
    }

    static func unsupportedReason(_ type: String) -> String {
        switch type {
        case "slot mill": "slot cutter"
        case "form mill": "form tool (custom profile)"
        case "lollipop mill": "lollipop cutter"
        case "thread mill": "thread mill"
        default: "unsupported tool type “\(type)”"
        }
    }

    /// A UUID derived from text, so re-importing the same library gives the same IDs.
    static func stableID(_ text: String) -> UUID {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325, h2: UInt64 = 0x8422_2325_cbf2_9ce4
        for b in text.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x0000_0100_0000_01b3
            h2 = (h2 ^ UInt64(b)) &* 0x0000_0100_0000_01b3 &+ 0x9e37_79b9
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: h1 >> (8 * i)); bytes[8 + i] = UInt8(truncatingIfNeeded: h2 >> (8 * i)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Sizes and flute direction from a vendor's tool name ("1/4 DIA x 3/4 x 1/4 SHANK", "6MM SHK", "UPCUT").
enum ToolNameHints {
    struct Hints {
        var shank: Double?
        var cutLength: Double?
        var direction: FluteDirection?
    }

    private static let num = #"(\d+-\d+/\d+|\d+/\d+|\d*\.\d+|\d+)\s*(MM|"|IN(?:CH)?\b)?"#
    private static let shankPattern = try! NSRegularExpression(pattern: num + #"\s*(?:SHANK|SHK|SH\b)"#, options: .caseInsensitive)
    // "CH"/"CL" (cutting height/length), possibly run into the next "x" ("1-1/4"CHx3/8" shank").
    private static let cutPattern = try! NSRegularExpression(pattern: num + #"\s*(?:CH|CL|CEL)(?![A-WYZ])"#, options: .caseInsensitive)
    private static let dxcxsPattern = try! NSRegularExpression(
        pattern: #"(?:DIA\.?|D\b|DIAMETER)\s*X\s*"# + num + #"\s*X\s*"# + num + #"\s*(?:SHANK|SHK|SH\b)"#, options: .caseInsensitive)

    static func parse(_ name: String, inches: Bool) -> Hints {
        var h = Hints()
        let ns = name as NSString
        func value(_ m: NSTextCheckingResult, _ g: Int) -> Double? {
            let r = m.range(at: g)
            guard r.location != NSNotFound, let v = parseNumber(ns.substring(with: r)) else { return nil }
            let unitRange = m.range(at: g + 1)
            let unit = unitRange.location == NSNotFound ? "" : ns.substring(with: unitRange).uppercased()
            if unit == "MM" { return v }
            if unit == "\"" || unit.hasPrefix("IN") { return v * 25.4 }
            return inches ? v * 25.4 : v
        }
        let all = NSRange(location: 0, length: ns.length)
        if let m = dxcxsPattern.firstMatch(in: name, range: all) {
            h.cutLength = value(m, 1)
            h.shank = value(m, 3)
        }
        if h.shank == nil, let m = shankPattern.firstMatch(in: name, range: all) { h.shank = value(m, 1) }
        if h.cutLength == nil, let m = cutPattern.firstMatch(in: name, range: all) { h.cutLength = value(m, 1) }
        if let s = h.shank, !(1...32).contains(s) { h.shank = nil }
        if let c = h.cutLength, !(0.5...120).contains(c) { h.cutLength = nil }

        let u = name.uppercased()
        if u.contains("COMPRESSION") { h.direction = .compression }
        else if u.contains("DOWNCUT") || u.contains("DOWN-CUT") || u.contains("DOWN CUT") || u.contains("DOWN SPIRAL") { h.direction = .downcut }
        else if u.contains("UPCUT") || u.contains("UP-CUT") || u.contains("UP CUT") || u.contains("UP SPIRAL") { h.direction = .upcut }
        else if u.contains("STRAIGHT") { h.direction = .straight }
        return h
    }

    /// "1-1/4" → 1.25, "3/8" → 0.375, ".090" → 0.09.
    static func parseNumber(_ s: String) -> Double? {
        let parts = s.split(separator: "-")
        if parts.count == 2, let whole = Double(parts[0]), let frac = parseNumber(String(parts[1])) { return whole + frac }
        let f = s.split(separator: "/")
        if f.count == 2, let a = Double(f[0]), let b = Double(f[1]), b != 0 { return a / b }
        return Double(s)
    }
}

/// What a form tool is from its name ("1/4\" RADIUS ROUNDOVER", "COVE 3/8 R", "14° DOVETAIL"): Vectric's tool database
/// keeps a form tool's profile in a form NativeCAM doesn't read.
enum FormNameHints {
    struct Guess {
        /// The form preset, or nil for a dovetail.
        var kind: FormProfile.Kind?
        var radius: Double?
        /// A dovetail's angle per side, degrees.
        var angle: Double?
        var note: String
        var shape: ToolShape { kind == nil ? .dovetail : .form }
    }

    private static let num = #"(\d+-\d+/\d+|\d+/\d+|\d*\.\d+|\d+)\s*(MM|"|IN(?:CH)?\b)?"#
    private static let radiusAfter = try! NSRegularExpression(pattern: num + #"\s*(?:R\b|RAD\b|RADIUS)"#, options: .caseInsensitive)
    private static let radiusBefore = try! NSRegularExpression(pattern: #"(?:\bR|RADIUS)\s*"# + num, options: .caseInsensitive)
    private static let degrees = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(?:°|DEG)"#, options: .caseInsensitive)

    static func parse(_ name: String, inches: Bool) -> Guess? {
        let u = name.uppercased()
        let ns = name as NSString
        let all = NSRange(location: 0, length: ns.length)
        func value(_ m: NSTextCheckingResult) -> Double? {
            guard let v = ToolNameHints.parseNumber(ns.substring(with: m.range(at: 1))) else { return nil }
            let unitRange = m.range(at: 2)
            let unit = unitRange.location == NSNotFound ? "" : ns.substring(with: unitRange).uppercased()
            if unit == "MM" { return v }
            if unit == "\"" || unit.hasPrefix("IN") { return v * 25.4 }
            return inches ? v * 25.4 : v
        }
        if u.contains("DOVETAIL") || u.contains("DOVE TAIL") {
            let a = degrees.firstMatch(in: name, range: all).flatMap { Double(ns.substring(with: $0.range(at: 1))) }
            return Guess(kind: nil, angle: a.flatMap { (1...45).contains($0) ? $0 : nil },
                         note: "Dovetail read from the name\(a.map { ": \(ToolLibraryImporter.fmtMM($0))° per side" } ?? "").")
        }
        let kind: FormProfile.Kind
        if u.contains("ROUNDOVER") || u.contains("ROUND OVER") || u.contains("ROUND-OVER") || u.contains("CORNER ROUND") {
            kind = .roundover
        } else if u.contains("OGEE") {
            kind = .ogee
        } else if u.contains("COVE") {
            kind = .cove
        } else {
            return nil
        }
        guard let r = (radiusAfter.firstMatch(in: name, range: all) ?? radiusBefore.firstMatch(in: name, range: all)).flatMap(value),
              r > 0.1, r < 60 else { return nil }
        let what = kind == .ogee ? "Ogee read from the name: two \(ToolLibraryImporter.fmtMM(r)) mm radii"
            : "\(kind.label) read from the name: \(ToolLibraryImporter.fmtMM(r)) mm radius"
        return Guess(kind: kind, radius: r, note: what + ", pilot the diameter less the profile's width.")
    }
}

/// Just enough SQLite to read a Vectric tool database.
struct SQLiteReader {
    enum Value {
        case null, number(Double), text(String)
        var number: Double? { if case let .number(n) = self { return n }; if case let .text(t) = self { return Double(t) }; return nil }
        var text: String? { if case let .text(t) = self { return t }; if case let .number(n) = self { return String(n) }; return nil }
    }

    let db: OpaquePointer

    func columns(_ table: String) -> Set<String> {
        Set(query("PRAGMA table_info(\(table))").compactMap { $0.count > 1 ? $0[1].text : nil })
    }

    func rows(_ table: String, _ wanted: [String]) -> [[Value]] {
        let have = columns(table)
        guard !have.isEmpty else { return [] }
        return query("SELECT \(wanted.map { have.contains($0) ? $0 : "NULL" }.joined(separator: ", ")) FROM \(table)")
    }

    func query(_ sql: String) -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[Value]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Value] = []
            row.reserveCapacity(Int(n))
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER, SQLITE_FLOAT: row.append(.number(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                default: row.append(.null)
                }
            }
            out.append(row)
        }
        return out
    }
}
