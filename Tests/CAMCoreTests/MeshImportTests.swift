import Compression
import Foundation
import ModelIO
import Testing
@testable import CAMCore

@Suite struct MeshImportTests {
    // MARK: Helpers

    typealias Tri = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    /// An axis-aligned cube from 0 to `s` as 12 outward-wound triangles (unindexed).
    static func cubeTriangles(_ s: Float = 10) -> [Tri] {
        func v(_ i: Int) -> SIMD3<Float> {
            SIMD3(i & 1 == 0 ? 0 : s, i & 2 == 0 ? 0 : s, i & 4 == 0 ? 0 : s)
        }
        let quads = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        return quads.flatMap { q in [(v(q[0]), v(q[1]), v(q[2])), (v(q[0]), v(q[2]), v(q[3]))] }
    }

    static func asciiSTL(_ tris: [Tri], name: String = "cube", lineEnding: String = "\n") -> Data {
        var s = "solid \(name)\(lineEnding)"
        for t in tris {
            s += "  facet normal 0 0 0\(lineEnding)    outer loop\(lineEnding)"
            for p in [t.0, t.1, t.2] { s += "      vertex \(p.x) \(p.y) \(p.z)\(lineEnding)" }
            s += "    endloop\(lineEnding)  endfacet\(lineEnding)"
        }
        s += "endsolid \(name)\(lineEnding)"
        return Data(s.utf8)
    }

    static func binarySTL(_ tris: [Tri], header: String = "binary STL") -> Data {
        var d = Data(count: 84 + 50 * tris.count)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let h = Array(header.utf8.prefix(80))
            for (i, b) in h.enumerated() { raw[i] = b }
            // Pad a "solid…" header with spaces so it really looks like ASCII.
            if header.hasPrefix("solid") { for i in h.count..<80 { raw[i] = 0x20 } }
            raw.storeBytes(of: UInt32(tris.count).littleEndian, toByteOffset: 80, as: UInt32.self)
            for (i, t) in tris.enumerated() {
                var o = 84 + 50 * i + 12
                for p in [t.0, t.1, t.2] {
                    for c in [p.x, p.y, p.z] {
                        raw.storeBytes(of: c.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                        o += 4
                    }
                }
            }
        }
        return d
    }

    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.z - b.z) <= tol
    }

    /// Signed volume (positive for a closed, outward-wound mesh).
    static func volume(_ m: MeshModel) -> Double {
        var v = 0.0
        for t in 0..<m.triangleCount {
            let a = SIMD3<Double>(m.vertex(Int(m.indices[3 * t])))
            let b = SIMD3<Double>(m.vertex(Int(m.indices[3 * t + 1])))
            let c = SIMD3<Double>(m.vertex(Int(m.indices[3 * t + 2])))
            v += simd_dot(a, simd_cross(b, c)) / 6
        }
        return v
    }

    static func expectCube(_ r: MeshImportResult, lo: SIMD3<Float> = .zero, size: Float = 10,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.mesh.triangleCount == 12, sourceLocation: sourceLocation)
        #expect(r.mesh.vertexCount == 8, sourceLocation: sourceLocation)
        let b = r.mesh.bounds
        #expect(near(b.min, lo), "min \(b.min)", sourceLocation: sourceLocation)
        #expect(near(b.max, lo + SIMD3(repeating: size)), "max \(b.max)", sourceLocation: sourceLocation)
        #expect(abs(volume(r.mesh) - Double(size * size * size)) < 1e-3 * Double(size * size * size),
                "volume \(volume(r.mesh))", sourceLocation: sourceLocation)
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MeshImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: STL

    @Test func asciiSTLCube() throws {
        let r = try ModelImporter.importData(Self.asciiSTL(Self.cubeTriangles()), fileExtension: "stl", name: "cube")
        Self.expectCube(r)
        #expect(r.suggestedUpAxis == .z)
        #expect(r.unitScale == 1)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.mesh.name == "cube")
    }

    @Test func asciiSTLVariants() throws {
        // CRLF, upper case keywords, exponents, two solids.
        let tris = Self.cubeTriangles()
        var text = String(decoding: Self.asciiSTL(Array(tris[0..<6]), lineEnding: "\r\n"), as: UTF8.self).uppercased()
        text += String(decoding: Self.asciiSTL(Array(tris[6...]), name: "second"), as: UTF8.self)
        text = text.replacingOccurrences(of: " 10.0", with: " 1.0E+01")
        let r = try ModelImporter.importData(Data(text.utf8), fileExtension: "STL", name: "variants")
        Self.expectCube(r)
    }

    @Test func binarySTLCube() throws {
        let r = try ModelImporter.importData(Self.binarySTL(Self.cubeTriangles()), fileExtension: "stl", name: "cube")
        Self.expectCube(r)
        #expect(r.suggestedUpAxis == .z)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func binarySTLWithSolidHeader() throws {
        let data = Self.binarySTL(Self.cubeTriangles(), header: "solid cube exported by a CAD program")
        #expect(data.starts(with: Array("solid".utf8)))
        let r = try ModelImporter.importData(data, fileExtension: "stl", name: "cube")
        Self.expectCube(r)
    }

    @Test func binarySTLWithBadCountAndTrailingBytes() throws {
        var data = Self.binarySTL(Self.cubeTriangles())
        data.replaceSubrange(80..<84, with: [0, 0, 0, 0])  // count field zeroed by a sloppy exporter
        let r = try ModelImporter.importData(data, fileExtension: "stl", name: "cube")
        Self.expectCube(r)
        #expect(!r.warnings.isEmpty)

        var padded = Self.binarySTL(Self.cubeTriangles())
        padded.append(contentsOf: [UInt8](repeating: 0, count: 17))
        let r2 = try ModelImporter.importData(padded, fileExtension: "stl", name: "cube")
        Self.expectCube(r2)
        #expect(r2.warnings.contains { $0.contains("extra data") }, "\(r2.warnings)")
    }

    @Test func stlInInches() throws {
        let r = try ModelImporter.importData(Self.binarySTL(Self.cubeTriangles(1)), fileExtension: "stl", name: "cube",
                                             assumedUnit: .inch)
        Self.expectCube(r, size: 25.4)
        #expect(r.unitScale == 25.4)
    }

    @Test func stlSkipsDegenerateAndInvalidTriangles() throws {
        var tris = Self.cubeTriangles()
        let p = SIMD3<Float>(3, 3, 3)
        tris.append((p, p, SIMD3(4, 4, 4)))                                   // repeated corner
        tris.append((SIMD3(20, 0, 0), SIMD3(21, 0, 0), SIMD3(22, 0, 0)))      // collinear
        tris.append((SIMD3(.nan, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)))     // NaN
        let r = try ModelImporter.importData(Self.binarySTL(tris), fileExtension: "stl", name: "cube")
        // The vertices only the dropped triangles used are dropped too.
        Self.expectCube(r)
        #expect(r.warnings.contains { $0.contains("2 degenerate") }, "\(r.warnings)")
        #expect(r.warnings.contains { $0.contains("NaN") }, "\(r.warnings)")
    }

    @Test func emptyAndGarbageFilesThrow() throws {
        for ext in ["stl", "obj", "3mf", "ply", "usda"] {
            #expect(throws: MeshImportError.self) {
                try ModelImporter.importData(Data(), fileExtension: ext, name: "empty")
            }
        }
        #expect(throws: MeshImportError.emptyFile("empty")) {
            try ModelImporter.importData(Data(), fileExtension: "stl", name: "empty")
        }
        #expect(throws: MeshImportError.self) {
            try ModelImporter.importData(Data("hello".utf8), fileExtension: "stl", name: "junk")
        }
        #expect(throws: MeshImportError.self) {
            try ModelImporter.importData(Data("solid x\nendsolid x\n".utf8), fileExtension: "stl", name: "nofacets")
        }
        #expect(throws: MeshImportError.self) {
            try ModelImporter.importData(Data("v 1 2 3\nv 4 5 6\n".utf8), fileExtension: "obj", name: "nofaces")
        }
        #expect(throws: MeshImportError.self) {
            try ModelImporter.importData(Data("not a zip at all".utf8), fileExtension: "3mf", name: "junk")
        }
        #expect(throws: MeshImportError.unsupportedFileType("step")) {
            try ModelImporter.importData(Data("x".utf8), fileExtension: "step", name: "part")
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).stl")
        let err = #expect(throws: MeshImportError.self) { try ModelImporter.importFile(at: missing) }
        #expect(err?.errorDescription?.contains("could not be opened") == true)
    }

    @Test func importFileUsesFileName() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Bracket v2.STL")
        try Self.binarySTL(Self.cubeTriangles()).write(to: url)
        let r = try ModelImporter.importFile(at: url)
        Self.expectCube(r)
        #expect(r.mesh.name == "Bracket v2")
    }

    // MARK: OBJ

    @Test func objQuadsSlashesAndNegativeIndices() throws {
        let obj = """
        # cube, 10 mm
        mtllib cube.mtl
        o first
        v 0 0 0
        v 10 0 0
        v 10 10 0
        v 0 10 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 -1
        g bottom
        usemtl wood
        s off
        f 1/1/1 4/4/1 3/3/1 2/2/1
        o second
        v 0 0 10
        v 10 0 10
        v 10 10 10
        v 0 10 10 # trailing comment
        f -4//1 -3//1 -2//1 -1//1
        f 1/1 2/2 6/2 5/1
        f 2 3 \\
          7 6
        f 3 4 -1 -2
        f 1 -4 -1 4
        """
        let r = try ModelImporter.importData(Data(obj.utf8), fileExtension: "obj", name: "cube")
        Self.expectCube(r)
        #expect(r.suggestedUpAxis == .y)
        #expect(r.unitScale == 1)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        // Positions are the file's vertices.
        let verts = Set((0..<r.mesh.vertexCount).map { r.mesh.vertex($0) })
        #expect(verts.contains(SIMD3(10, 10, 10)))
        #expect(verts.contains(SIMD3(0, 10, 0)))
    }

    @Test func objPolygonFanAndUnits() throws {
        // A pentagon (3 triangles) and a triangle in inches, with CRLF line endings and a bad face.
        let obj = "v 0 0 0\r\nv 2 0 0\r\nv 3 1 0\r\nv 1 2 0\r\nv -1 1 0\r\nv 0 0 1\r\n"
            + "f 1 2 3 4 5\r\nf 1 2 6\r\nf 1 2 99\r\nf 1 2\r\n"
        let r = try ModelImporter.importData(Data(obj.utf8), fileExtension: "obj", name: "fan", assumedUnit: .inch)
        #expect(r.mesh.triangleCount == 4)
        #expect(r.mesh.vertexCount == 6)
        #expect(r.unitScale == 25.4)
        let b = r.mesh.bounds
        #expect(Self.near(b.min, SIMD3(-25.4, 0, 0)))
        #expect(Self.near(b.max, SIMD3(76.2, 50.8, 25.4)))
        #expect(r.warnings.count == 2, "\(r.warnings)")  // out-of-range index, two-vertex face
    }

    @Test func objWeldsDuplicateVertices() throws {
        // Every face has its own copies of its corners, as some exporters write.
        var obj = ""
        var n = 0
        for t in Self.cubeTriangles() {
            for p in [t.0, t.1, t.2] { obj += "v \(p.x) \(p.y) \(p.z)\n" }
            obj += "f \(n + 1) \(n + 2) \(n + 3)\n"
            n += 3
        }
        let r = try ModelImporter.importData(Data(obj.utf8), fileExtension: "obj", name: "soup")
        Self.expectCube(r)
    }

    // MARK: 3MF

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func deflate(_ data: Data) -> Data {
        let cap = data.count + 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0)
        return out.prefix(n)
    }

    /// A ZIP archive of (name, contents, deflate?) entries.
    static func zip(_ files: [(String, Data, Bool)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var out = Data()
        var central = Data()
        for (name, content, deflate) in files {
            let payload = deflate ? Self.deflate(content) : content
            let method = deflate ? 8 : 0
            let crc = crc32(content)
            let nameBytes = Array(name.utf8)
            let offset = UInt32(out.count)
            out.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x21))
            out.append(contentsOf: le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(content.count)))
            out.append(contentsOf: le16(nameBytes.count) + le16(0) + nameBytes)
            out.append(payload)
            central.append(contentsOf: le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x21))
            central.append(contentsOf: le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(content.count)))
            central.append(contentsOf: le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count))
        out.append(contentsOf: le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
    </Types>
    """

    static func rels(_ target: String = "/3D/3dmodel.model") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Target="\(target)" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """
    }

    /// A unit cube (0…1) as 3MF <vertices>/<triangles>.
    static func cubeMeshXML() -> String {
        var verts = ""
        for i in 0..<8 {
            verts += "<vertex x=\"\(i & 1)\" y=\"\((i >> 1) & 1)\" z=\"\((i >> 2) & 1)\"/>\n"
        }
        let quads = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        var tris = ""
        for q in quads {
            tris += "<triangle v1=\"\(q[0])\" v2=\"\(q[1])\" v3=\"\(q[2])\"/>\n"
            tris += "<triangle v1=\"\(q[0])\" v2=\"\(q[2])\" v3=\"\(q[3])\"/>\n"
        }
        return "<mesh><vertices>\n\(verts)</vertices><triangles>\n\(tris)</triangles></mesh>"
    }

    static func model(unit: String?, resources: String, build: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <model \(unit.map { "unit=\"\($0)\" " } ?? "")xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <metadata name="Title">test</metadata>
        <resources>
        \(resources)
        </resources>
        <build>\(build)</build>
        </model>
        """
    }

    @Test(arguments: [false, true]) func threeMFInchWithTranslation(deflated: Bool) throws {
        let model = Self.model(unit: "inch",
                               resources: "<object id=\"1\" type=\"model\">\(Self.cubeMeshXML())</object>",
                               build: "<item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 10 20 30\"/>")
        let data = Self.zip([("[Content_Types].xml", Data(Self.contentTypes.utf8), deflated),
                             ("_rels/.rels", Data(Self.rels().utf8), deflated),
                             ("3D/3dmodel.model", Data(model.utf8), deflated)])
        let r = try ModelImporter.importData(data, fileExtension: "3mf", name: "cube")
        Self.expectCube(r, lo: SIMD3(254, 508, 762), size: 25.4)
        #expect(r.unitScale == 25.4)
        #expect(r.suggestedUpAxis == .z)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func threeMFComponentsRotationAndMirror() throws {
        // Object 2 = two instances of the cube; the build places object 2 twice and the bare cube once (mirrored).
        let resources = """
        <object id="1" type="model">\(Self.cubeMeshXML())</object>
        <object id="2" type="model"><components>
          <component objectid="1"/>
          <component objectid="1" transform="0 1 0 -1 0 0 0 0 1 5 0 0"/>
        </components></object>
        <object id="3" type="support">\(Self.cubeMeshXML())</object>
        """
        let build = """
        <item objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
        <item objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 10"/>
        <item objectid="1" transform="-1 0 0 0 1 0 0 0 1 -3 0 0"/>
        <item objectid="3"/>
        """
        // Custom root part name found through the relationship; no unit attribute means millimetres.
        let data = Self.zip([("[Content_Types].xml", Data(Self.contentTypes.utf8), true),
                             ("_rels/.rels", Data(Self.rels("/3D/Part%201.model").utf8), true),
                             ("3D/Part 1.model", Data(Self.model(unit: nil, resources: resources, build: build).utf8), true)])
        let r = try ModelImporter.importData(data, fileExtension: "3mf", name: "assembly")
        #expect(r.unitScale == 1)
        #expect(r.mesh.triangleCount == 12 * 5)
        let b = r.mesh.bounds
        // Rotated copy: x' = -y + 5 ∈ [4, 5], y' = x ∈ [0, 1]. Mirrored copy: x' = -x - 3 ∈ [-4, -3].
        #expect(Self.near(b.min, SIMD3(-4, 0, 0)), "\(b.min)")
        #expect(Self.near(b.max, SIMD3(5, 1, 11)), "\(b.max)")
        let positions = Set((0..<r.mesh.vertexCount).map { r.mesh.vertex($0) })
        #expect(positions.contains(SIMD3(4, 1, 10)))
        #expect(positions.contains(SIMD3(-4, 1, 1)))
        // Mirroring flipped the triangle order back, so all five cubes stay outward-facing.
        #expect(abs(Self.volume(r.mesh) - 5) < 1e-4, "volume \(Self.volume(r.mesh))")
        #expect(r.warnings.contains { $0.contains("support") }, "\(r.warnings)")
    }

    @Test func threeMFWithoutRelsUsesDefaultPath() throws {
        let model = Self.model(unit: "centimeter", resources: "<object id=\"7\">\(Self.cubeMeshXML())</object>",
                               build: "<item objectid=\"7\"/>")
        let data = Self.zip([("3D/3dmodel.model", Data(model.utf8), true)])
        let r = try ModelImporter.importData(data, fileExtension: "3mf", name: "cube")
        Self.expectCube(r, size: 10)
        #expect(r.unitScale == 10)
    }

    @Test func threeMFProductionExtensionPaths() throws {
        let p = "http://schemas.microsoft.com/3dmanufacturing/production/2015/06"
        let part = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <resources><object id="1">\(Self.cubeMeshXML())</object></resources><build/></model>
        """
        let root = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="\(p)" requiredextensions="p">
        <resources><object id="5"><components>
          <component p:path="/3D/Objects/object_1.model" objectid="1" transform="2 0 0 0 2 0 0 0 2 0 0 0"/>
        </components></object></resources>
        <build><item objectid="5" transform="1 0 0 0 1 0 0 0 1 1 1 1"/></build></model>
        """
        let data = Self.zip([("_rels/.rels", Data(Self.rels().utf8), false),
                             ("3D/3dmodel.model", Data(root.utf8), true),
                             ("3D/Objects/object_1.model", Data(part.utf8), true)])
        let r = try ModelImporter.importData(data, fileExtension: "3mf", name: "multi")
        Self.expectCube(r, lo: SIMD3(1, 1, 1), size: 2)
    }

    @Test func zipReaderStoredAndDeflated() throws {
        let big = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 * 7 / 3) })
        let data = Self.zip([("a.txt", Data("hello".utf8), false), ("dir/b.bin", big, true), ("empty", Data(), false)])
        let zip = try ZipArchive(data: data)
        #expect(zip.entries.map(\.name) == ["a.txt", "dir/b.bin", "empty"])
        #expect(try zip.extract(named: "a.txt") == Data("hello".utf8))
        #expect(try zip.extract(named: "/DIR/B.BIN") == big)
        #expect(try zip.extract(named: "empty") == Data())
        #expect(try zip.extract(named: "missing") == nil)
        // Works on a slice that doesn't start at index 0.
        let sliced = (Data([1, 2, 3]) + data).dropFirst(3)
        #expect(try ZipArchive(data: sliced).extract(named: "dir/b.bin") == big)
    }

    // MARK: Model I/O (PLY, USD)

    static func exportBox(extent: SIMD3<Float>, ext: String, translation: SIMD3<Float>? = nil, in dir: URL) throws -> URL? {
        guard MDLAsset.canExportFileExtension(ext) else { return nil }
        let alloc = MDLMeshBufferDataAllocator()
        let mesh = MDLMesh(boxWithExtent: extent, segments: [1, 1, 1], inwardNormals: false,
                           geometryType: .triangles, allocator: alloc)
        mesh.name = "box"
        if let translation {
            let t = MDLTransform()
            t.translation = translation
            mesh.transform = t
        }
        let asset = MDLAsset(bufferAllocator: alloc)
        asset.add(mesh)
        let url = dir.appendingPathComponent("box.\(ext)")
        try asset.export(to: url)
        return url
    }

    @Test func usdaBoxIsAssumedMetres() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let url = try Self.exportBox(extent: [0.1, 0.2, 0.3], ext: "usda", translation: [1, 0, 0], in: dir) else {
            print("Model I/O cannot export .usda here; skipping")
            return
        }
        let r = try ModelImporter.importFile(at: url)
        #expect(r.mesh.triangleCount == 12)
        #expect(r.mesh.vertexCount == 8)
        #expect(r.unitScale == 1000)
        #expect(r.suggestedUpAxis == .y)
        #expect(r.warnings.contains { $0.contains("metres") }, "\(r.warnings)")
        let b = r.mesh.bounds
        #expect(Self.near(b.min, SIMD3(950, -100, -150), 1e-2), "\(b.min)")
        #expect(Self.near(b.max, SIMD3(1050, 100, 150), 1e-2), "\(b.max)")
        #expect(abs(Self.volume(r.mesh) - 100 * 200 * 300) < 10)

        // From memory (goes through a temporary file).
        let r2 = try ModelImporter.importData(Data(contentsOf: url), fileExtension: "usda", name: "box")
        #expect(r2.mesh.triangleCount == 12)
        #expect(r2.mesh.name == "box")
    }

    @Test func usdcAndAbsurdlyLargeUSD() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let url = try Self.exportBox(extent: [100, 200, 300], ext: "usdc", in: dir) else {
            print("Model I/O cannot export .usdc here; skipping")
            return
        }
        // 300 m across would be absurd for a router: taken as millimetres.
        let r = try ModelImporter.importFile(at: url)
        #expect(r.mesh.triangleCount == 12)
        #expect(r.unitScale == 1)
        #expect(r.warnings.contains { $0.contains("millimetres") }, "\(r.warnings)")
        let b = r.mesh.bounds
        #expect(Self.near(b.min, SIMD3(-50, -100, -150)) && Self.near(b.max, SIMD3(50, 100, 150)), "\(b)")
    }

    @Test func plyBoxUsesAssumedUnit() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let url = try Self.exportBox(extent: [1, 2, 3], ext: "ply", in: dir) else {
            print("Model I/O cannot export .ply here; skipping")
            return
        }
        let r = try ModelImporter.importFile(at: url, assumedUnit: .inch)
        #expect(r.mesh.triangleCount == 12)
        #expect(r.mesh.vertexCount == 8)
        #expect(r.unitScale == 25.4)
        #expect(r.suggestedUpAxis == .y)
        let b = r.mesh.bounds
        #expect(Self.near(b.min, SIMD3(-12.7, -25.4, -38.1), 1e-3) && Self.near(b.max, SIMD3(12.7, 25.4, 38.1), 1e-3), "\(b)")
    }

    @Test func handWrittenPLYQuadAndJunk() throws {
        let ply = """
        ply
        format ascii 1.0
        element vertex 4
        property float x
        property float y
        property float z
        element face 1
        property list uchar int vertex_indices
        end_header
        0 0 0
        10 0 0
        10 5 0
        0 5 0
        4 0 1 2 3

        """
        let r = try ModelImporter.importData(Data(ply.utf8), fileExtension: "ply", name: "quad")
        #expect(r.mesh.triangleCount == 2)
        #expect(r.mesh.vertexCount == 4)
        #expect(r.unitScale == 1)
        #expect(Self.near(r.mesh.bounds.max, SIMD3(10, 5, 0)))
        let err = #expect(throws: MeshImportError.self) {
            try ModelImporter.importData(Data("this is not a ply file\n".utf8), fileExtension: "ply", name: "junk")
        }
        #expect(err?.errorDescription?.contains("junk.ply") == true, "\(String(describing: err))")
    }

    @Test func handWrittenUSDAWithUnitsAndUpAxis() throws {
        let usda = """
        #usda 1.0
        (
            defaultPrim = "plate"
            metersPerUnit = 0.01
            upAxis = "Z"
        )

        def Xform "plate"
        {
            double3 xformOp:translate = (0, 0, 5)
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def Mesh "quad"
            {
                int[] faceVertexCounts = [4, 3]
                int[] faceVertexIndices = [0, 1, 2, 3, 0, 1, 4]
                point3f[] points = [(0, 0, 0), (10, 0, 0), (10, 10, 0), (0, 10, 0), (5, 0, 2)]
            }
        }
        """
        let r = try ModelImporter.importData(Data(usda.utf8), fileExtension: "usda", name: "plate")
        #expect(r.mesh.triangleCount == 3)
        #expect(r.unitScale == 10)
        #expect(r.suggestedUpAxis == .z)
        let b = r.mesh.bounds
        #expect(Self.near(b.min, SIMD3(0, 0, 50), 1e-3) && Self.near(b.max, SIMD3(100, 100, 70), 1e-3), "\(b)")
    }

    // MARK: Performance

    @Test func largeBinarySTLIsFastAndWelds() throws {
        // A 400 × 250 grid of quads on a wavy surface = 200,000 triangles, 401 × 251 shared vertices.
        let nx = 400, ny = 250
        func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
            SIMD3(Float(i) * 0.5, Float(j) * 0.5, sin(Float(i) * 0.05) * cos(Float(j) * 0.07) * 4)
        }
        var tris: [Tri] = []
        tris.reserveCapacity(2 * nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                tris.append((p(i, j), p(i + 1, j), p(i + 1, j + 1)))
                tris.append((p(i, j), p(i + 1, j + 1), p(i, j + 1)))
            }
        }
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("grid.stl")
        try Self.binarySTL(tris).write(to: url)

        let clock = ContinuousClock()
        var result: MeshImportResult?
        let elapsed = try clock.measure { result = try ModelImporter.importFile(at: url) }
        let r = try #require(result)
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("200k-triangle binary STL imported in \(String(format: "%.1f", ms)) ms "
              + "(\(r.mesh.triangleCount) triangles, \(r.mesh.vertexCount) vertices)")
        #expect(r.mesh.triangleCount == 2 * nx * ny)
        #expect(r.mesh.vertexCount == (nx + 1) * (ny + 1))
        #expect(Self.near(r.mesh.bounds.max, SIMD3(200, 125, r.mesh.bounds.max.z)))
        #expect(elapsed < .seconds(1))
    }
}
