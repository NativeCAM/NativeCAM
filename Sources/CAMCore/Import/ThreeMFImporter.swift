import Foundation

/// Reads 3MF packages: the ZIP's root model part (found through `_rels/.rels`), its `unit`, mesh objects,
/// components (resolved recursively, including Production-extension `p:path` references to other model parts)
/// and build items with their affine transforms. 3MF is Z-up.
public enum ThreeMFImporter {
    static let defaultModelPath = "3D/3dmodel.model"

    public static func import3MF(data: Data, name: String) throws -> MeshImportResult {
        guard !data.isEmpty else { throw MeshImportError.emptyFile(name) }
        let zip: ZipArchive
        do {
            zip = try ZipArchive(data: data)
        } catch {
            throw MeshImportError.malformed("3MF files are ZIP packages, but \((error as? LocalizedError)?.errorDescription ?? "the ZIP could not be read")")
        }
        var warnings: [String] = []
        let rootPath = try rootModelPath(zip, warnings: &warnings)

        var models: [String: ModelPart] = [:]
        func model(at path: String) throws -> ModelPart {
            let key = normalize(path)
            if let m = models[key] { return m }
            let bytes: Data
            do {
                guard let d = try zip.extract(named: key) else {
                    throw MeshImportError.malformed("the 3MF package has no model part “\(key)”")
                }
                bytes = d
            } catch let e as MeshImportError {
                throw e
            } catch {
                throw MeshImportError.malformed("3MF part “\(key)”: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            let m = try ModelPart.parse(bytes, path: key)
            models[key] = m
            warnings.append(contentsOf: m.warnings)
            return m
        }

        let root = try model(at: rootPath)
        let unitName = root.unit ?? "millimeter"
        let scale: Double
        switch unitName.lowercased() {
        case "micron": scale = 0.001
        case "millimeter": scale = 1
        case "centimeter": scale = 10
        case "inch": scale = 25.4
        case "foot": scale = 304.8
        case "meter": scale = 1000
        default:
            scale = 1
            warnings.append("Unknown 3MF unit “\(unitName)”; assumed millimetres.")
        }

        let totalTriangles = root.objects.values.reduce(0) { $0 + $1.triangles.count / 3 }
        let welder = MeshWelder(expectedTriangles: max(totalTriangles, 1024))
        var skippedSupports = 0
        var badReferences = 0
        var cycles = 0
        var badIndices = 0
        let unitTransform = Affine3.scale(scale)

        func emit(path: String, objectID: Int, transform: Affine3, depth: Int) throws {
            guard depth < 32 else { cycles += 1; return }
            let part = try model(at: path)
            guard let object = part.objects[objectID] else { badReferences += 1; return }
            if object.type == "support" || object.type == "solidsupport" {
                skippedSupports += 1
                return
            }
            if !object.triangles.isEmpty {
                let m = unitTransform.concatenating(transform)
                let flip = transform.determinant < 0
                let vCount = object.vertices.count / 3
                var remap = [UInt32](repeating: MeshWelder.noVertex, count: vCount)
                object.vertices.withUnsafeBufferPointer { v in
                    remap.withUnsafeMutableBufferPointer { r in
                        object.triangles.withUnsafeBufferPointer { t in
                            @inline(__always) func welded(_ i: UInt32) -> UInt32? {
                                let k = Int(i)
                                guard k < vCount else { return nil }
                                if r[k] == MeshWelder.noVertex {
                                    let x = v[3 * k], y = v[3 * k + 1], z = v[3 * k + 2]
                                    r[k] = welder.vertex(Float(m.m00 * x + m.m01 * y + m.m02 * z + m.m03),
                                                         Float(m.m10 * x + m.m11 * y + m.m12 * z + m.m13),
                                                         Float(m.m20 * x + m.m21 * y + m.m22 * z + m.m23))
                                }
                                return r[k]
                            }
                            var i = 0
                            while i < t.count {
                                if let a = welded(t[i]), let b = welded(t[i + 1]), let c = welded(t[i + 2]) {
                                    if flip { welder.triangle(a, c, b) } else { welder.triangle(a, b, c) }
                                } else {
                                    badIndices += 1
                                }
                                i += 3
                            }
                        }
                    }
                }
            }
            for c in object.components {
                // Components without p:path refer to objects in the same part as the parent object.
                try emit(path: c.path ?? path, objectID: c.objectID, transform: transform.concatenating(c.transform),
                         depth: depth + 1)
            }
        }

        if root.items.isEmpty {
            warnings.append("The 3MF has no build items; imported every mesh object instead.")
            for id in root.objects.keys.sorted() where !root.objects[id]!.triangles.isEmpty {
                try emit(path: rootPath, objectID: id, transform: .identity, depth: 0)
            }
        } else {
            for item in root.items {
                try emit(path: item.path ?? rootPath, objectID: item.objectID, transform: item.transform, depth: 0)
            }
        }

        if skippedSupports > 0 {
            warnings.append("Skipped \(skippedSupports) support object\(skippedSupports == 1 ? "" : "s").")
        }
        if badReferences > 0 {
            warnings.append("Ignored \(badReferences) reference\(badReferences == 1 ? "" : "s") to missing objects.")
        }
        if cycles > 0 {
            warnings.append("Stopped at components nested more than 32 deep (the file probably has a reference cycle).")
        }
        if badIndices > 0 {
            warnings.append("Skipped \(badIndices) triangle\(badIndices == 1 ? "" : "s") with out-of-range vertex indices.")
        }
        return try welder.result(name: name, warnings: warnings, upAxis: .z, unitScale: scale,
                                 emptyDetail: "the 3MF build has no mesh triangles")
    }

    /// Target of the package's 3D-model relationship, else the conventional path, else any `.model` part.
    private static func rootModelPath(_ zip: ZipArchive, warnings: inout [String]) throws -> String {
        if let rels = try? zip.extract(named: "_rels/.rels") {
            let finder = RelationshipFinder()
            let parser = XMLParser(data: rels)
            parser.shouldResolveExternalEntities = false
            parser.delegate = finder
            _ = parser.parse()
            if let target = finder.modelTarget {
                let path = normalize(target)
                if zip.entry(named: path) != nil { return path }
                warnings.append("The 3MF relationship points to a missing part “\(path)”.")
            }
        }
        if zip.entry(named: defaultModelPath) != nil { return defaultModelPath }
        if let any = zip.entries.first(where: { $0.name.lowercased().hasSuffix(".model") }) { return any.name }
        throw MeshImportError.malformed("the 3MF package has no 3D model part")
    }

    /// Package part name: no leading "/", percent-decoded.
    static func normalize(_ path: String) -> String {
        var p = path.removingPercentEncoding ?? path
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}

/// A 3×4 affine transform in column-vector form: p' = M·p.
struct Affine3: Sendable {
    var m00 = 1.0, m01 = 0.0, m02 = 0.0, m03 = 0.0
    var m10 = 0.0, m11 = 1.0, m12 = 0.0, m13 = 0.0
    var m20 = 0.0, m21 = 0.0, m22 = 1.0, m23 = 0.0

    static let identity = Affine3()

    static func scale(_ s: Double) -> Affine3 {
        var a = Affine3()
        a.m00 = s; a.m11 = s; a.m22 = s
        return a
    }

    /// From a 3MF `transform` attribute: "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32", a row-vector matrix
    /// (p' = [x y z 1]·M), so x' = x·m00 + y·m10 + z·m20 + m30.
    init?(threeMF string: String) {
        let v = string.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "," })
            .compactMap { Double($0) }
        guard v.count == 12, v.allSatisfy(\.isFinite) else { return nil }
        m00 = v[0]; m01 = v[3]; m02 = v[6]; m03 = v[9]
        m10 = v[1]; m11 = v[4]; m12 = v[7]; m13 = v[10]
        m20 = v[2]; m21 = v[5]; m22 = v[8]; m23 = v[11]
    }

    init() {}

    /// self ∘ b: applies `b` first, then `self`.
    func concatenating(_ b: Affine3) -> Affine3 {
        var r = Affine3()
        r.m00 = m00 * b.m00 + m01 * b.m10 + m02 * b.m20
        r.m01 = m00 * b.m01 + m01 * b.m11 + m02 * b.m21
        r.m02 = m00 * b.m02 + m01 * b.m12 + m02 * b.m22
        r.m03 = m00 * b.m03 + m01 * b.m13 + m02 * b.m23 + m03
        r.m10 = m10 * b.m00 + m11 * b.m10 + m12 * b.m20
        r.m11 = m10 * b.m01 + m11 * b.m11 + m12 * b.m21
        r.m12 = m10 * b.m02 + m11 * b.m12 + m12 * b.m22
        r.m13 = m10 * b.m03 + m11 * b.m13 + m12 * b.m23 + m13
        r.m20 = m20 * b.m00 + m21 * b.m10 + m22 * b.m20
        r.m21 = m20 * b.m01 + m21 * b.m11 + m22 * b.m21
        r.m22 = m20 * b.m02 + m21 * b.m12 + m22 * b.m22
        r.m23 = m20 * b.m03 + m21 * b.m13 + m22 * b.m23 + m23
        return r
    }

    var determinant: Double {
        m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20)
    }
}

/// One parsed `.model` XML part.
struct ModelPart {
    struct Component {
        var objectID: Int
        var path: String?
        var transform: Affine3
    }

    struct Object {
        var id: Int
        var type: String
        /// x, y, z in model units.
        var vertices: [Double] = []
        var triangles: [UInt32] = []
        var components: [Component] = []
    }

    struct Item {
        var objectID: Int
        var path: String?
        var transform: Affine3
    }

    var unit: String?
    var objects: [Int: Object] = [:]
    var items: [Item] = []
    var warnings: [String] = []

    static func parse(_ data: Data, path: String) throws -> ModelPart {
        let reader = ModelPartReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let ok = parser.parse()
        guard reader.sawModel else {
            let why = parser.parserError.map { " (\($0.localizedDescription))" } ?? ""
            throw MeshImportError.malformed("3MF part “\(path)” is not a 3D model\(why)")
        }
        var part = reader.part
        if !ok {
            let line = parser.lineNumber
            part.warnings.insert("3MF part “\(path)” is damaged near line \(line); only the part before the error was imported.", at: 0)
        }
        if reader.badVertices > 0 {
            part.warnings.append("\(reader.badVertices) vertices in “\(path)” had invalid coordinates and were read as (0, 0, 0).")
        }
        if reader.badTriangles > 0 {
            part.warnings.append("Skipped \(reader.badTriangles) malformed triangles in “\(path)”.")
        }
        if reader.badTransforms > 0 {
            part.warnings.append("Ignored \(reader.badTransforms) invalid transform\(reader.badTransforms == 1 ? "" : "s") in “\(path)”.")
        }
        return part
    }
}

/// XMLParser delegate that builds a `ModelPart`. Only core-namespace elements are read, so extension elements
/// with the same local names (slice `s:vertex`, …) are ignored.
private final class ModelPartReader: NSObject, XMLParserDelegate {
    var part = ModelPart()
    var sawModel = false
    var badVertices = 0
    var badTriangles = 0
    var badTransforms = 0
    private var current: ModelPart.Object?
    private var inMesh = false

    private static func isCore(_ ns: String?) -> Bool {
        guard let ns, !ns.isEmpty else { return true }
        return ns.hasPrefix("http://schemas.microsoft.com/3dmanufacturing/core/")
    }

    private func transform(_ attrs: [String: String]) -> Affine3 {
        guard let t = attrs["transform"] else { return .identity }
        if let a = Affine3(threeMF: t) { return a }
        badTransforms += 1
        return .identity
    }

    private static func path(_ attrs: [String: String]) -> String? {
        for (k, v) in attrs where k == "path" || k.hasSuffix(":path") {
            return ThreeMFImporter.normalize(v)
        }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        guard ModelPartReader.isCore(namespaceURI) else { return }
        switch elementName {
        case "vertex":
            guard inMesh, current != nil else { return }
            if let xs = attrs["x"], let ys = attrs["y"], let zs = attrs["z"],
               let x = Double(xs), let y = Double(ys), let z = Double(zs) {
                current!.vertices.append(x)
                current!.vertices.append(y)
                current!.vertices.append(z)
            } else {
                badVertices += 1
                current!.vertices.append(contentsOf: [0, 0, 0])
            }
        case "triangle":
            guard inMesh, current != nil else { return }
            if let a = attrs["v1"].flatMap({ UInt32($0) }), let b = attrs["v2"].flatMap({ UInt32($0) }),
               let c = attrs["v3"].flatMap({ UInt32($0) }) {
                current!.triangles.append(a)
                current!.triangles.append(b)
                current!.triangles.append(c)
            } else {
                badTriangles += 1
            }
        case "model":
            sawModel = true
            part.unit = attrs["unit"]
        case "object":
            current = ModelPart.Object(id: attrs["id"].flatMap { Int($0) } ?? -1, type: attrs["type"] ?? "model")
        case "mesh":
            inMesh = current != nil
        case "component":
            guard current != nil, let id = attrs["objectid"].flatMap({ Int($0) }) else { return }
            current!.components.append(.init(objectID: id, path: ModelPartReader.path(attrs), transform: transform(attrs)))
        case "item":
            guard let id = attrs["objectid"].flatMap({ Int($0) }) else { return }
            part.items.append(.init(objectID: id, path: ModelPartReader.path(attrs), transform: transform(attrs)))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard ModelPartReader.isCore(namespaceURI) else { return }
        switch elementName {
        case "mesh":
            inMesh = false
        case "object":
            if let o = current { part.objects[o.id] = o }
            current = nil
            inMesh = false
        default:
            break
        }
    }
}

/// Finds the 3D-model relationship target in `_rels/.rels`.
private final class RelationshipFinder: NSObject, XMLParserDelegate {
    var modelTarget: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        guard modelTarget == nil, elementName.hasSuffix("Relationship"), let target = attrs["Target"] else { return }
        if (attrs["Type"] ?? "").lowercased().hasSuffix("/3dmodel") { modelTarget = target }
    }
}
