import Foundation

/// Reads ASCII DXF files (R12 through current) into flattened polylines in millimetres.
///
/// Supported: LINE, ARC, CIRCLE, LWPOLYLINE and POLYLINE/VERTEX (with bulges), SPLINE (NURBS via de Boor,
/// or fit points), ELLIPSE, POINT, and INSERT/MINSERT of BLOCKS (nested). Loose open pieces are chained
/// end to end afterwards so that, e.g., a rectangle drawn as four LINEs becomes one closed loop, layer by layer: each
/// polyline and point keeps its layer (group code 8; a block's entities on layer 0 take the INSERT's layer, as in
/// AutoCAD), and layer 0, AutoCAD's default, counts as no layer.
public enum DXFImporter {
    /// - Parameters:
    ///   - tolerance: maximum chord deviation (mm) when flattening arcs and curves.
    ///   - defaultUnit: drawing unit assumed when the header has no (or a unitless) `$INSUNITS`.
    public static func importDXF(data: Data, tolerance: Double = 0.01, defaultUnit: LengthUnit = .inch) throws -> ImportResult {
        let tol = tolerance > 0 ? tolerance : 0.01
        let pairs = try DXFReader.readPairs(data)
        let doc = DXFDocument(pairs: pairs)

        var warnings: [String] = []
        let units = resolveUnits(doc: doc, defaultUnit: defaultUnit, warnings: &warnings)

        var builder = DXFGeometryBuilder(tolerance: tol, blocks: doc.blocks)
        var entities = doc.entities
        if entities.isEmpty, let model = doc.blocks["*MODEL_SPACE"], !model.entities.isEmpty {
            entities = model.entities
        }
        builder.process(entities, transform: .scale(units.mmPerUnit, units.mmPerUnit), depth: 0, stack: [])

        let (chained, layers) = PathChainer.chainByLayer(builder.pieces, layers: builder.pieceLayers,
                                                         tolerance: PathChainer.joinTolerance(for: tol))
        warnings.append(contentsOf: builder.warningMessages())
        if chained.duplicatesRemoved > 0 {
            warnings.append("Removed \(chained.duplicatesRemoved) duplicate path\(chained.duplicatesRemoved == 1 ? "" : "s") " +
                "(drawn more than once on top of each other).")
        }
        if chained.openCount > 0 {
            warnings.append("\(chained.openCount) open path\(chained.openCount == 1 ? "" : "s") left open " +
                "(endpoints do not meet within \(PathChainer.joinTolerance(for: tol)) mm).")
        }
        if chained.polylines.isEmpty && builder.points.isEmpty {
            warnings.append("No supported geometry found in the DXF file.")
        }
        return ImportResult(polylines: chained.polylines, points: builder.points, warnings: warnings,
                            sourceUnits: units.declared, unitScale: units.mmPerUnit, polylineLayers: layers,
                            pointLayers: builder.pointLayers)
    }

    /// `$INSUNITS` code → (mm per unit, name, nearest LengthUnit).
    static let insUnits: [Int: (Double, String, LengthUnit)] = [
        1: (25.4, "inches", .inch),
        2: (304.8, "feet", .inch),
        3: (1_609_344, "miles", .inch),
        4: (1, "millimetres", .mm),
        5: (10, "centimetres", .mm),
        6: (1000, "metres", .mm),
        7: (1_000_000, "kilometres", .mm),
        8: (25.4e-6, "microinches", .inch),
        9: (0.0254, "mils", .inch),
        10: (914.4, "yards", .inch),
        11: (1e-7, "ångströms", .mm),
        12: (1e-6, "nanometres", .mm),
        13: (1e-3, "microns", .mm),
        14: (100, "decimetres", .mm),
        15: (10_000, "decametres", .mm),
        16: (100_000, "hectometres", .mm),
    ]

    private static func resolveUnits(doc: DXFDocument, defaultUnit: LengthUnit,
                                     warnings: inout [String]) -> (mmPerUnit: Double, declared: LengthUnit?) {
        let code = doc.headerInt("$INSUNITS", 70)
        if let code, let (scale, name, unit) = insUnits[code] {
            if unit == .inch && code != 1 || unit == .mm && code != 4 {
                warnings.append("Drawing units are \(name) ($INSUNITS = \(code)); converted to mm.")
            }
            return (scale, unit)
        }
        let measurement = doc.headerInt("$MEASUREMENT", 70)
        var hint = ""
        if let measurement {
            let says: LengthUnit = measurement == 1 ? .mm : .inch
            if says != defaultUnit {
                hint = " (the file's $MEASUREMENT suggests \(says == .mm ? "metric" : "imperial") units)"
            }
        }
        let what = code == nil ? "No $INSUNITS in the DXF header" : "$INSUNITS = \(code!) is unitless or unsupported"
        warnings.append("\(what); assuming \(defaultUnit == .inch ? "inches" : "millimetres")\(hint).")
        return (defaultUnit.mmPerUnit, nil)
    }
}

// MARK: - Group-code reader

struct DXFPair: Sendable {
    var code: Int
    var value: String

    var double: Double? { DXFReader.parseDouble(value) }
    var int: Int? {
        if let i = Int(value) { return i }
        guard let d = DXFReader.parseDouble(value), d.isFinite, abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}

enum DXFReader {
    static func readPairs(_ data: Data) throws -> [DXFPair] {
        let bytes = [UInt8](data)
        let binarySentinel = Array("AutoCAD Binary DXF".utf8)
        if bytes.count >= binarySentinel.count, Array(bytes[0..<binarySentinel.count]) == binarySentinel {
            throw VectorImportError.binaryDXFNotSupported
        }
        var i = 0
        let n = bytes.count
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        // Lines end in LF or CRLF; very old Mac files use bare CR.
        let separator: UInt8 = bytes.contains(10) ? 10 : 13

        func nextLine() -> Range<Int>? {
            guard i < n else { return nil }
            var s = i
            while i < n, bytes[i] != separator { i += 1 }
            var e = i
            if i < n { i += 1 }
            while e > s, bytes[e - 1] == 13 || bytes[e - 1] == 32 || bytes[e - 1] == 9 { e -= 1 }
            while s < e, bytes[s] == 32 || bytes[s] == 9 { s += 1 }
            return s..<e
        }

        var pairs: [DXFPair] = []
        pairs.reserveCapacity(n / 12)
        var lineNumber = 0
        while let codeRange = nextLine() {
            lineNumber += 1
            if codeRange.isEmpty {
                if i >= n { break } // trailing blank line
                throw VectorImportError.malformed("DXF line \(lineNumber): expected a group code, found an empty line")
            }
            guard let code = parseInt(bytes, codeRange) else {
                let text = String(decoding: bytes[codeRange.prefix(40)], as: UTF8.self)
                throw VectorImportError.malformed("DXF line \(lineNumber): expected a group code, found “\(text)”")
            }
            guard let valueRange = nextLine() else { break }
            lineNumber += 1
            let value = String(decoding: bytes[valueRange], as: UTF8.self)
            pairs.append(DXFPair(code: code, value: value))
            if code == 0, value == "EOF" { break }
        }
        if pairs.isEmpty { throw VectorImportError.malformed("empty DXF file") }
        return pairs
    }

    private static func parseInt(_ b: [UInt8], _ r: Range<Int>) -> Int? {
        var k = r.lowerBound
        var negative = false
        if k < r.upperBound, b[k] == 45 || b[k] == 43 { negative = b[k] == 45; k += 1 }
        guard k < r.upperBound else { return nil }
        var v = 0
        while k < r.upperBound {
            let c = b[k]
            guard c >= 48, c <= 57 else { return nil }
            v = v &* 10 &+ Int(c - 48)
            k += 1
        }
        return negative ? -v : v
    }

    static func parseDouble(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = Double(t) { return d }
        // Some writers emit "1." or use a decimal comma.
        if t.hasSuffix("."), let d = Double(t + "0") { return d }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }
}

// MARK: - Document structure

struct DXFEntity: Sendable {
    var type: String
    var pairs: [DXFPair]
    /// VERTEX records of an old-style POLYLINE.
    var vertices: [DXFEntity] = []

    func value(_ code: Int) -> String? { pairs.first { $0.code == code }?.value }
    func double(_ code: Int, _ fallback: Double = 0) -> Double { pairs.first { $0.code == code }?.double ?? fallback }
    func int(_ code: Int, _ fallback: Int = 0) -> Int { pairs.first { $0.code == code }?.int ?? fallback }
    func point(_ xCode: Int) -> Vec2 { Vec2(double(xCode), double(xCode + 10)) }
    func point3(_ xCode: Int) -> (x: Double, y: Double, z: Double) {
        (double(xCode), double(xCode + 10), double(xCode + 20))
    }
    var extrusion: (x: Double, y: Double, z: Double) { (double(210, 0), double(220, 0), double(230, 1)) }
    var layer: String { value(8) ?? "0" }
}

struct DXFBlock: Sendable {
    var name: String
    var base: Vec2
    var flags: Int
    var entities: [DXFEntity]
}

struct DXFDocument {
    var header: [String: [DXFPair]] = [:]
    var blocks: [String: DXFBlock] = [:]
    var entities: [DXFEntity] = []

    init(pairs: [DXFPair]) {
        var idx = 0
        while idx < pairs.count {
            let p = pairs[idx]
            guard p.code == 0 else { idx += 1; continue }
            if p.value == "EOF" { break }
            guard p.value == "SECTION" else { idx += 1; continue }
            var bodyStart = idx + 1
            var name = ""
            if bodyStart < pairs.count, pairs[bodyStart].code == 2 {
                name = pairs[bodyStart].value.uppercased()
                bodyStart += 1
            }
            var end = bodyStart
            while end < pairs.count, !(pairs[end].code == 0 && (pairs[end].value == "ENDSEC" || pairs[end].value == "EOF")) {
                end += 1
            }
            let body = pairs[bodyStart..<end]
            switch name {
            case "HEADER": parseHeader(body)
            case "BLOCKS": parseBlocks(body)
            case "ENTITIES": entities.append(contentsOf: DXFDocument.parseEntityList(body))
            default: break
            }
            idx = end + 1
        }
    }

    func headerInt(_ name: String, _ code: Int) -> Int? {
        header[name]?.first { $0.code == code }?.int
    }

    private mutating func parseHeader(_ body: ArraySlice<DXFPair>) {
        var current: String?
        for p in body {
            if p.code == 9 {
                current = p.value.uppercased()
                header[current!] = []
            } else if let c = current {
                header[c]?.append(p)
            }
        }
    }

    private mutating func parseBlocks(_ body: ArraySlice<DXFPair>) {
        var current: DXFBlock?
        for e in DXFDocument.parseEntityList(body) {
            switch e.type {
            case "BLOCK":
                if let c = current { blocks[c.name.uppercased()] = c }
                current = DXFBlock(name: e.value(2) ?? e.value(3) ?? "", base: e.point(10), flags: e.int(70), entities: [])
            case "ENDBLK":
                if let c = current { blocks[c.name.uppercased()] = c }
                current = nil
            default:
                current?.entities.append(e)
            }
        }
        if let c = current { blocks[c.name.uppercased()] = c }
    }

    /// Splits a run of pairs into entities at each group 0, attaching VERTEX records to their POLYLINE
    /// and dropping SEQEND / ATTRIB records.
    static func parseEntityList(_ body: ArraySlice<DXFPair>) -> [DXFEntity] {
        var result: [DXFEntity] = []
        var i = body.startIndex
        while i < body.endIndex {
            guard body[i].code == 0 else { i += 1; continue }
            let type = body[i].value.uppercased()
            var j = i + 1
            while j < body.endIndex, body[j].code != 0 { j += 1 }
            let entity = DXFEntity(type: type, pairs: Array(body[(i + 1)..<j]))
            switch type {
            case "VERTEX":
                if let last = result.indices.last, result[last].type == "POLYLINE" {
                    result[last].vertices.append(entity)
                }
            case "SEQEND", "ATTRIB":
                break
            default:
                result.append(entity)
            }
            i = j
        }
        return result
    }
}

// MARK: - Geometry

struct DXFGeometryBuilder {
    let tolerance: Double
    let blocks: [String: DXFBlock]
    /// Output pieces in mm (open pieces are chained afterwards).
    var pieces: [Polyline] = []
    var points: [Vec2] = []
    /// The layer of each piece and point (nil for layer 0).
    var pieceLayers: [String?] = []
    var pointLayers: [String?] = []
    /// The layer of the entity being read.
    private var layer: String?
    private var skipped: [String: Int] = [:]
    private var notes: [String] = []
    private var noteSet: Set<String> = []
    private var paperSpaceCount = 0
    private var projectedCount = 0
    private var degenerateCount = 0

    init(tolerance: Double, blocks: [String: DXFBlock]) {
        self.tolerance = tolerance
        self.blocks = blocks
    }

    private mutating func note(_ s: String) {
        if noteSet.insert(s).inserted { notes.append(s) }
    }

    func warningMessages() -> [String] {
        var out = notes
        for (type, count) in skipped.sorted(by: { $0.key < $1.key }) {
            var msg = "Skipped \(count) \(type) entit\(count == 1 ? "y" : "ies") (not supported)"
            switch type {
            case "TEXT", "MTEXT", "ATTDEF": msg += "; explode text to curves in your CAD program to import it"
            case "HATCH", "SOLID", "TRACE": msg += "; fills are ignored, their boundaries are usually drawn separately"
            case "DIMENSION", "LEADER", "MLEADER": msg += "; annotations are ignored"
            default: break
            }
            out.append(msg + ".")
        }
        if paperSpaceCount > 0 {
            out.append("Skipped \(paperSpaceCount) paper-space entit\(paperSpaceCount == 1 ? "y" : "ies") (layout sheets); only model space is imported.")
        }
        if projectedCount > 0 {
            out.append("\(projectedCount) entit\(projectedCount == 1 ? "y lies" : "ies lie") on a tilted plane and \(projectedCount == 1 ? "was" : "were") projected onto XY.")
        }
        if degenerateCount > 0 {
            out.append("Ignored \(degenerateCount) zero-size entit\(degenerateCount == 1 ? "y" : "ies").")
        }
        return out
    }

    // MARK: Entity dispatch

    /// `inherited` is the layer of the INSERT whose block `entities` are, for those on layer 0.
    mutating func process(_ entities: [DXFEntity], transform: Transform2D, depth: Int, stack: [String], inherited: String? = nil) {
        for e in entities {
            if e.int(67) == 1 { paperSpaceCount += 1; continue }
            let own = e.layer.trimmingCharacters(in: .whitespaces)
            layer = own == "0" || own.isEmpty ? inherited : own
            switch e.type {
            case "LINE": line(e, transform)
            case "ARC": arc(e, transform)
            case "CIRCLE": circle(e, transform)
            case "LWPOLYLINE": lwPolyline(e, transform)
            case "POLYLINE": polyline(e, transform)
            case "SPLINE": spline(e, transform)
            case "ELLIPSE": ellipse(e, transform)
            case "POINT":
                points.append(transform.apply(e.point(10)))
                pointLayers.append(layer)
            case "INSERT": insert(e, transform, depth: depth, stack: stack)
            case "BLOCK", "ENDBLK": break
            default: skipped[e.type, default: 0] += 1
            }
        }
    }

    private mutating func emit(_ local: [Vec2], closed: Bool, _ t: Transform2D) {
        let poly = Polyline(local.map(t.apply), closed: closed).deduplicated(tolerance: 1e-9)
        let b = poly.bounds
        guard poly.count >= 2, !b.isEmpty, max(b.width, b.height) > 1e-9 else { degenerateCount += 1; return }
        if closed && poly.count < 3 {
            pieces.append(Polyline(poly.points, closed: false))
        } else {
            pieces.append(poly)
        }
        pieceLayers.append(layer)
    }

    /// Maps an entity's object coordinate system (OCS) onto the XY plane of the WCS.
    /// Extrusion (0,0,1) is the identity; (0,0,-1) mirrors X; anything else is projected.
    private mutating func ocs(_ e: DXFEntity, elevation: Double) -> Transform2D {
        let n = e.extrusion
        let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        guard len > 1e-12 else { return .identity }
        let az = (x: n.x / len, y: n.y / len, z: n.z / len)
        if abs(az.x) < 1e-9, abs(az.y) < 1e-9 {
            return az.z > 0 ? .identity : Transform2D(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        }
        projectedCount += 1
        let ax = DXFGeometryBuilder.arbitraryXAxis(az)
        let ay = DXFGeometryBuilder.normalize(DXFGeometryBuilder.cross(az, ax))
        return Transform2D(a: ax.x, b: ax.y, c: ay.x, d: ay.y, tx: elevation * az.x, ty: elevation * az.y)
    }

    typealias V3 = (x: Double, y: Double, z: Double)

    static func cross(_ a: V3, _ b: V3) -> V3 {
        (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func normalize(_ v: V3) -> V3 {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1e-15 ? (v.x / l, v.y / l, v.z / l) : (1, 0, 0)
    }

    /// DXF "arbitrary axis algorithm".
    static func arbitraryXAxis(_ az: V3) -> V3 {
        if abs(az.x) < 1.0 / 64 && abs(az.y) < 1.0 / 64 {
            return normalize(cross((0, 1, 0), az))
        }
        return normalize(cross((0, 0, 1), az))
    }

    // MARK: Entities

    private mutating func line(_ e: DXFEntity, _ t: Transform2D) {
        emit([e.point(10), e.point(11)], closed: false, t)
    }

    private mutating func circle(_ e: DXFEntity, _ parent: Transform2D) {
        let r = e.double(40)
        guard r > 0 else { degenerateCount += 1; return }
        let t = ocs(e, elevation: e.double(30)).then(parent)
        let pts = Curves.circle(center: e.point(10), radius: r, tolerance: ImportGeometry.localTolerance(tolerance, for: t))
        emit(pts, closed: true, t)
    }

    private mutating func arc(_ e: DXFEntity, _ parent: Transform2D) {
        let r = e.double(40)
        guard r > 0 else { degenerateCount += 1; return }
        let t = ocs(e, elevation: e.double(30)).then(parent)
        let start = e.double(50)
        var sweep = (e.double(51) - start).truncatingRemainder(dividingBy: 360)
        if sweep <= 1e-12 { sweep += 360 }
        let pts = Curves.arc(center: e.point(10), radius: r, startAngle: start.radians, sweep: sweep.radians,
                             tolerance: ImportGeometry.localTolerance(tolerance, for: t))
        emit(pts, closed: false, t)
    }

    private mutating func lwPolyline(_ e: DXFEntity, _ parent: Transform2D) {
        var verts: [(p: Vec2, bulge: Double)] = []
        for p in e.pairs {
            switch p.code {
            case 10: verts.append((Vec2(p.double ?? 0, 0), 0))
            case 20: if !verts.isEmpty { verts[verts.count - 1].p.y = p.double ?? 0 }
            case 42: if !verts.isEmpty { verts[verts.count - 1].bulge = p.double ?? 0 }
            default: break
            }
        }
        let closed = e.int(70) & 1 != 0
        let t = ocs(e, elevation: e.double(38)).then(parent)
        emitBulgePolyline(verts, closed: closed, t)
    }

    private mutating func polyline(_ e: DXFEntity, _ parent: Transform2D) {
        let flags = e.int(70)
        if flags & (16 | 64) != 0 {
            skipped["POLYLINE (mesh)", default: 0] += 1
            return
        }
        let closed = flags & 1 != 0
        let is3D = flags & 8 != 0
        var vertexRecords = e.vertices
        // Spline-fit polylines carry their frame control points (vertex flag 16) as well as the fitted
        // vertices; keep the fitted ones.
        let fitted = vertexRecords.filter { $0.int(70) & 16 == 0 }
        if !fitted.isEmpty { vertexRecords = fitted }
        let verts = vertexRecords.map { v in (p: v.point(10), bulge: is3D ? 0 : v.double(42)) }
        let t = is3D ? parent : ocs(e, elevation: e.double(30)).then(parent)
        emitBulgePolyline(verts, closed: closed, t)
    }

    private mutating func emitBulgePolyline(_ verts: [(p: Vec2, bulge: Double)], closed: Bool, _ t: Transform2D) {
        guard !verts.isEmpty else { return }
        guard verts.count > 1 else { degenerateCount += 1; return }
        let localTol = ImportGeometry.localTolerance(tolerance, for: t)
        var out = [verts[0].p]
        let segCount = closed ? verts.count : verts.count - 1
        for k in 0..<segCount {
            let a = verts[k], b = verts[(k + 1) % verts.count].p
            DXFGeometryBuilder.appendBulge(from: a.p, to: b, bulge: a.bulge, tolerance: localTol, into: &out)
        }
        emit(out, closed: closed, t)
    }

    /// Appends the segment from `p1` to `p2` (excluding `p1`). `bulge` = tan(θ/4), positive counter-clockwise.
    static func appendBulge(from p1: Vec2, to p2: Vec2, bulge b: Double, tolerance: Double, into out: inout [Vec2]) {
        let chord = p2 - p1
        let d = chord.length
        guard abs(b) > 1e-10, d > 1e-12 else { out.append(p2); return }
        let r = d * (1 + b * b) / (4 * abs(b))
        let center = (p1 + p2) * 0.5 + (chord / d).perpLeft * (d * (1 - b * b) / (4 * b))
        let sweep = 4 * atan(b)
        let start = (p1 - center).angle
        var pts = Curves.arc(center: center, radius: r, startAngle: start, sweep: sweep, tolerance: tolerance)
        pts[pts.count - 1] = p2
        out.append(contentsOf: pts.dropFirst())
    }

    private mutating func ellipse(_ e: DXFEntity, _ t: Transform2D) {
        let c = e.point3(10)
        let m = e.point3(11)
        let ratio = e.double(40, 1)
        let mLen = (m.x * m.x + m.y * m.y + m.z * m.z).squareRoot()
        guard mLen > 1e-12, ratio > 0 else { degenerateCount += 1; return }
        let n = e.extrusion
        let nz = DXFGeometryBuilder.normalize(n)
        let minor = DXFGeometryBuilder.cross(nz, m)
        if abs(nz.x) > 1e-9 || abs(nz.y) > 1e-9 || abs(m.z) > 1e-9 { projectedCount += 1 }
        let start = e.double(41, 0)
        var sweep = e.double(42, 2 * .pi) - start
        let full = 2 * Double.pi
        if sweep > full + 1e-9 { sweep = sweep.truncatingRemainder(dividingBy: full) }
        if sweep <= 1e-12 { sweep += full }
        let closed = abs(sweep - full) < 1e-9
        var pts = ImportGeometry.ellipseArc(center: Vec2(c.x, c.y), u: Vec2(m.x, m.y), v: Vec2(minor.x, minor.y) * ratio,
                                            start: start, sweep: sweep,
                                            tolerance: ImportGeometry.localTolerance(tolerance, for: t))
        if closed { pts.removeLast() }
        emit(pts, closed: closed, t)
    }

    private mutating func spline(_ e: DXFEntity, _ t: Transform2D) {
        let flags = e.int(70)
        let closedFlag = flags & 1 != 0
        let periodic = flags & 2 != 0
        let degree = e.int(71, 3)
        var knots: [Double] = []
        var weights: [Double] = []
        var control: [Vec2] = []
        var fit: [Vec2] = []
        for p in e.pairs {
            switch p.code {
            case 40: knots.append(p.double ?? 0)
            case 41: weights.append(p.double ?? 1)
            case 10: control.append(Vec2(p.double ?? 0, 0))
            case 20: if !control.isEmpty { control[control.count - 1].y = p.double ?? 0 }
            case 11: fit.append(Vec2(p.double ?? 0, 0))
            case 21: if !fit.isEmpty { fit[fit.count - 1].y = p.double ?? 0 }
            default: break
            }
        }
        let localTol = ImportGeometry.localTolerance(tolerance, for: t)
        var pts: [Vec2]
        if control.count >= 2 {
            guard let evaluated = NURBS.flatten(degree: degree, control: control, weights: weights, knots: knots,
                                                closed: closedFlag || periodic, tolerance: localTol) else {
                note("A SPLINE had inconsistent knot data and was approximated by its control polygon.")
                emit(control, closed: closedFlag, t)
                return
            }
            pts = evaluated
        } else if fit.count >= 2 {
            note("SPLINE without control points was interpolated through its fit points (shape may differ slightly from the CAD curve).")
            pts = [fit[0]]
            for (p0, c1, c2, p1) in ImportGeometry.interpolatingCubics(through: fit, closed: closedFlag) {
                Curves.flattenCubic(p0, c1, c2, p1, tolerance: localTol, into: &pts)
            }
        } else {
            degenerateCount += 1
            return
        }
        // A closed spline evaluates to a curve whose ends meet.
        if (closedFlag || periodic), pts.count > 3, pts[0].distance(to: pts[pts.count - 1]) <= max(localTol, 1e-9) {
            pts.removeLast()
            emit(pts, closed: true, t)
        } else {
            emit(pts, closed: false, t)
        }
    }

    private mutating func insert(_ e: DXFEntity, _ parent: Transform2D, depth: Int, stack: [String]) {
        let name = e.value(2) ?? ""
        let key = name.uppercased()
        guard let block = blocks[key] else {
            note("INSERT references missing block “\(name)”; skipped.")
            return
        }
        if block.flags & 4 != 0 {
            note("Block “\(name)” is an external reference (xref); its geometry is not in this file.")
        }
        guard depth < 32, !stack.contains(key) else {
            note("Block “\(name)” inserts itself (directly or nested); recursion stopped.")
            return
        }
        let ins = e.point3(10)
        var sx = e.double(41, 1), sy = e.double(42, 1)
        if sx == 0 { sx = 1 }
        if sy == 0 { sy = 1 }
        let rotation = e.double(50).radians
        let cols = max(1, min(e.int(70, 1), 1000))
        let rows = max(1, min(e.int(71, 1), 1000))
        let colSpacing = e.double(44), rowSpacing = e.double(45)
        let toWorld = Transform2D.rotation(rotation)
            .then(.translation(Vec2(ins.x, ins.y)))
            .then(ocs(e, elevation: ins.z))
            .then(parent)
        let local = Transform2D.translation(-block.base).then(.scale(sx, sy))
        let insertLayer = layer
        for r in 0..<rows {
            for c in 0..<cols {
                let cell = Transform2D.translation(Vec2(Double(c) * colSpacing, Double(r) * rowSpacing))
                process(block.entities, transform: local.then(cell).then(toWorld), depth: depth + 1, stack: stack + [key],
                        inherited: insertLayer)
            }
        }
    }
}

// MARK: - NURBS evaluation

enum NURBS {
    /// Flattens a (rational) B-spline. Returns nil if the data cannot be made consistent.
    static func flatten(degree pIn: Int, control ctrlIn: [Vec2], weights wIn: [Double], knots kIn: [Double],
                        closed: Bool, tolerance: Double) -> [Vec2]? {
        var ctrl = ctrlIn
        var w = wIn.count == ctrlIn.count && wIn.allSatisfy({ $0 > 0 }) ? wIn : [Double](repeating: 1, count: ctrlIn.count)
        let p = max(1, min(pIn, ctrl.count - 1))
        var knots = kIn
        var n = ctrl.count
        let monotone = zip(knots, knots.dropFirst()).allSatisfy { $0 <= $1 }

        if !monotone || knots.count != n + p + 1 {
            if monotone, knots.count == n + 2 * p + 1 {
                // Periodic spline stored without its wrapped control points.
                ctrl += ctrl[0..<p]
                w += w[0..<p]
            } else if closed {
                ctrl += ctrl[0..<p]
                w += w[0..<p]
                knots = (0..<(ctrl.count + p + 1)).map(Double.init)
            } else {
                // Uniform clamped knot vector.
                let interior = n - p - 1
                knots = [Double](repeating: 0, count: p + 1)
                if interior > 0 { knots += (1...interior).map(Double.init) }
                knots += [Double](repeating: Double(interior + 1), count: p + 1)
            }
            n = ctrl.count
            guard knots.count == n + p + 1 else { return nil }
        }
        guard knots[n] > knots[p] else { return nil }

        // Homogeneous control points.
        let hx = (0..<n).map { ctrl[$0].x * w[$0] }
        let hy = (0..<n).map { ctrl[$0].y * w[$0] }

        func eval(_ u: Double, span k: Int) -> Vec2 {
            var dx = [Double](repeating: 0, count: p + 1)
            var dy = dx, dw = dx
            for j in 0...p {
                dx[j] = hx[j + k - p]; dy[j] = hy[j + k - p]; dw[j] = w[j + k - p]
            }
            if p >= 1 {
                for r in 1...p {
                    var j = p
                    while j >= r {
                        let denom = knots[j + 1 + k - r] - knots[j + k - p]
                        let alpha = denom > 0 ? (u - knots[j + k - p]) / denom : 0
                        dx[j] = (1 - alpha) * dx[j - 1] + alpha * dx[j]
                        dy[j] = (1 - alpha) * dy[j - 1] + alpha * dy[j]
                        dw[j] = (1 - alpha) * dw[j - 1] + alpha * dw[j]
                        j -= 1
                    }
                }
            }
            let ww = abs(dw[p]) > 1e-300 ? dw[p] : 1
            return Vec2(dx[p] / ww, dy[p] / ww)
        }

        var out: [Vec2] = []
        let tol = max(tolerance, 1e-9)
        func refine(_ t0: Double, _ p0: Vec2, _ t1: Double, _ p1: Vec2, span k: Int, depth: Int) {
            let tm = 0.5 * (t0 + t1)
            let pm = eval(tm, span: k)
            if depth < 2 || (depth < 18 && distancePointSegment(pm, p0, p1) > tol) {
                refine(t0, p0, tm, pm, span: k, depth: depth + 1)
                refine(tm, pm, t1, p1, span: k, depth: depth + 1)
            } else {
                out.append(p1)
            }
        }
        for k in p..<n where knots[k + 1] > knots[k] {
            let t0 = knots[k], t1 = knots[k + 1]
            let p0 = eval(t0, span: k)
            if out.isEmpty { out.append(p0) }
            refine(t0, p0, t1, eval(t1, span: k), span: k, depth: 0)
        }
        return out.count >= 2 ? out : nil
    }
}
