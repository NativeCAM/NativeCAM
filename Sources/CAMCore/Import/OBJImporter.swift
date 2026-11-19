import Foundation

/// Reads Wavefront OBJ geometry: `v` positions and `f` faces (`v`, `v/vt`, `v/vt/vn`, `v//vn`, negative relative
/// indices, polygons fan-triangulated). Everything else (texture coordinates, normals, groups, materials, smoothing,
/// free-form geometry) is ignored, and all objects are merged into one mesh. OBJ has no units and is normally Y-up.
public enum OBJImporter {
    public static func importOBJ(data: Data, name: String, assumedUnit: LengthUnit = .mm) throws -> MeshImportResult {
        guard !data.isEmpty else { throw MeshImportError.emptyFile(name) }
        let scale = assumedUnit.mmPerUnit
        var warnings: [String] = []

        // File vertices (mm) and face corners as absolute 0-based file-vertex indices, three per triangle.
        var vertices: [Float] = []
        var corners: [Int] = []
        var badVertexLines = 0
        var badFaces = 0
        var shortFaces = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            vertices.reserveCapacity(min(bytes.count / 10, 1 << 26))
            corners.reserveCapacity(min(bytes.count / 12, 1 << 26))
            var s = ByteScanner(base, count: bytes.count)
            var polygon: [Int] = []
            polygon.reserveCapacity(16)

            while !s.atEnd {
                s.skipInlineSpace(continuations: true)
                if s.atLineEnd { s.skipLine(); continue }
                let first = s.peek()
                if first == 0x23 { s.skipLine(continuations: true); continue }  // '#'
                let w = s.word()
                if w.count == 1 && (first | 0x20) == 0x76 {  // "v"
                    var xyz = (0.0, 0.0, 0.0)
                    var ok = true
                    for k in 0..<3 {
                        s.skipInlineSpace(continuations: true)
                        guard let v = s.number() else { ok = false; break }
                        switch k {
                        case 0: xyz.0 = v
                        case 1: xyz.1 = v
                        default: xyz.2 = v
                        }
                    }
                    if !ok { badVertexLines += 1 }
                    // Keep the slot even when malformed so later indices stay aligned.
                    vertices.append(Float(xyz.0 * scale))
                    vertices.append(Float(xyz.1 * scale))
                    vertices.append(Float(xyz.2 * scale))
                    s.skipLine(continuations: true)
                } else if w.count == 1 && (first | 0x20) == 0x66 {  // "f"
                    polygon.removeAll(keepingCapacity: true)
                    let defined = vertices.count / 3
                    var ok = true
                    while true {
                        s.skipInlineSpace(continuations: true)
                        if s.atLineEnd || s.peek() == 0x23 { break }
                        guard let ref = s.integer() else { ok = false; break }
                        // Skip "/vt/vn" up to the next separator.
                        while !s.atEnd {
                            let b = s.peek()
                            if ByteScanner.isSpace(b) || b == 0x0A || b == 0x5C { break }
                            s.pos += 1
                        }
                        if ref > 0 {
                            polygon.append(ref - 1)
                        } else if ref < 0 && defined + ref >= 0 {
                            polygon.append(defined + ref)
                        } else {
                            ok = false
                            break
                        }
                    }
                    s.skipLine(continuations: true)
                    if !ok {
                        badFaces += 1
                    } else if polygon.count < 3 {
                        shortFaces += 1
                    } else {
                        for i in 1..<(polygon.count - 1) {
                            corners.append(polygon[0])
                            corners.append(polygon[i])
                            corners.append(polygon[i + 1])
                        }
                    }
                } else {
                    s.skipLine(continuations: true)
                }
            }
        }

        if badVertexLines > 0 {
            warnings.append("\(badVertexLines) vertex line\(badVertexLines == 1 ? " was" : "s were") malformed and read as (0, 0, 0).")
        }
        if badFaces > 0 {
            warnings.append("Skipped \(badFaces) face\(badFaces == 1 ? "" : "s") with a missing or invalid vertex index.")
        }
        if shortFaces > 0 {
            warnings.append("Skipped \(shortFaces) face\(shortFaces == 1 ? "" : "s") with fewer than three vertices.")
        }
        guard !corners.isEmpty else {
            throw MeshImportError.noTriangles(vertices.isEmpty ? "the OBJ file has no vertices or faces"
                                                               : "the OBJ file has \(vertices.count / 3) vertices but no faces")
        }

        // Weld only the vertices faces actually use.
        let vertexCount = vertices.count / 3
        let welder = MeshWelder(expectedTriangles: corners.count / 3)
        var remap = [UInt32](repeating: MeshWelder.noVertex, count: vertexCount)
        var outOfRange = 0
        vertices.withUnsafeBufferPointer { v in
            remap.withUnsafeMutableBufferPointer { r in
                corners.withUnsafeBufferPointer { c in
                    @inline(__always) func welded(_ i: Int) -> UInt32? {
                        guard i < vertexCount else { return nil }
                        if r[i] == MeshWelder.noVertex {
                            r[i] = welder.vertex(v[3 * i], v[3 * i + 1], v[3 * i + 2])
                            // A non-finite vertex stays noVertex; the welder then rejects its triangles.
                        }
                        return r[i]
                    }
                    var t = 0
                    while t < c.count {
                        if let a = welded(c[t]), let b = welded(c[t + 1]), let d = welded(c[t + 2]) {
                            welder.triangle(a, b, d)
                        } else {
                            outOfRange += 1
                        }
                        t += 3
                    }
                }
            }
        }
        if outOfRange > 0 {
            warnings.append("Skipped \(outOfRange) triangle\(outOfRange == 1 ? "" : "s") referencing vertices that don't exist.")
        }
        return try welder.result(name: name, warnings: warnings, upAxis: .y, unitScale: scale,
                                 emptyDetail: "every face in the OBJ file is degenerate")
    }
}
