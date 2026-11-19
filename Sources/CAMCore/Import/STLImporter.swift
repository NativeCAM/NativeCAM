import Foundation

/// Reads binary and ASCII STL into a welded mesh. STL has no units (`assumedUnit` applies) and is normally Z-up.
public enum STLImporter {
    public static func importSTL(data: Data, name: String, assumedUnit: LengthUnit = .mm) throws -> MeshImportResult {
        guard !data.isEmpty else { throw MeshImportError.emptyFile(name) }
        let scale = assumedUnit.mmPerUnit
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MeshImportResult in
            let count = raw.count
            let bytes = raw.bindMemory(to: UInt8.self)
            let base = bytes.baseAddress!
            var warnings: [String] = []

            let declared: Int? = count >= 84 ? Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) : nil
            let looksASCII = startsWithSolid(base, count) && !containsNUL(base, min(count, 512))

            // An exact size match is conclusive, even when the 80-byte header starts with "solid".
            if let n = declared, n > 0, 84 + 50 * n == count {
                return try readBinary(raw, triangles: n, name: name, scale: scale, warnings: warnings)
            }
            if looksASCII {
                let welder = MeshWelder(expectedTriangles: count / 250)
                let facets = readASCII(base, count, welder: welder, scale: scale)
                if facets > 0 || welder.triangleCount > 0 {
                    return try welder.result(name: name, warnings: warnings, upAxis: .z, unitScale: scale,
                                             emptyDetail: "the ASCII STL has no valid facets")
                }
                // "solid" header but no ASCII facets: fall through and try binary.
            }
            guard count >= 84 else {
                throw MeshImportError.malformed(looksASCII ? "the ASCII STL contains no facets"
                                                            : "the file is too short to be an STL (\(count) bytes)")
            }
            let available = (count - 84) / 50
            guard available > 0 else {
                throw MeshImportError.noTriangles("the STL file has no facets")
            }
            let n: Int
            if let d = declared, d > 0, d <= available {
                n = d
                warnings.append("The STL has \(count - 84 - 50 * d) bytes of extra data after its \(d) triangles; it was ignored.")
            } else {
                n = available
                warnings.append("The STL header says \(declared ?? 0) triangles but the file holds \(available); read \(available).")
            }
            return try readBinary(raw, triangles: n, name: name, scale: scale, warnings: warnings)
        }
    }

    private static func startsWithSolid(_ base: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var i = 0
        while i < count && (ByteScanner.isSpace(base[i]) || base[i] == 0x0A) { i += 1 }
        guard count - i >= 5 else { return false }
        let s: [UInt8] = Array("solid".utf8)
        for j in 0..<5 where (base[i + j] | 0x20) != s[j] { return false }
        return true
    }

    private static func containsNUL(_ base: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        for i in 0..<count where base[i] == 0 { return true }
        return false
    }

    /// 80-byte header, UInt32 count, then per triangle: normal (3 floats), 3 vertices (9 floats), UInt16 attributes.
    private static func readBinary(_ raw: UnsafeRawBufferPointer, triangles n: Int, name: String, scale: Double,
                                   warnings: [String]) throws -> MeshImportResult {
        let welder = MeshWelder(expectedTriangles: n)
        let s = Float(scale)
        let first = raw.baseAddress! + 84 + 12
        for t in 0..<n {
            let p = first + 50 * t
            welder.triangle(load(p, 0, s), load(p, 4, s), load(p, 8, s),
                            load(p, 12, s), load(p, 16, s), load(p, 20, s),
                            load(p, 24, s), load(p, 28, s), load(p, 32, s))
        }
        return try welder.result(name: name, warnings: warnings, upAxis: .z, unitScale: scale,
                                 emptyDetail: "every triangle in the STL is degenerate")
    }

    @inline(__always) private static func load(_ p: UnsafeRawPointer, _ offset: Int, _ scale: Float) -> Float {
        Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) * scale
    }

    /// Scans `facet … outer loop / vertex x y z … / endloop / endfacet` blocks (any number of solids).
    /// Facets with more than three vertices are fan-triangulated. Returns the number of facets seen.
    private static func readASCII(_ base: UnsafePointer<UInt8>, _ count: Int, welder: MeshWelder, scale: Double) -> Int {
        var s = ByteScanner(base, count: count)
        var loop: [UInt32] = []
        loop.reserveCapacity(8)
        var facets = 0
        func flush() {
            if loop.count >= 3 {
                for i in 1..<(loop.count - 1) { welder.triangle(loop[0], loop[i], loop[i + 1]) }
            }
            loop.removeAll(keepingCapacity: true)
        }
        while true {
            s.skipWhitespace()
            if s.atEnd { break }
            let first = s.peek() | 0x20
            let w = s.word()
            if first != 0x76 && first != 0x66 && first != 0x65 { continue }  // not v…, f… or e…
            if s.matches(w, "vertex") {
                s.skipInlineSpace()
                guard let x = s.number() else { continue }
                s.skipInlineSpace()
                guard let y = s.number() else { continue }
                s.skipInlineSpace()
                guard let z = s.number() else { continue }
                loop.append(welder.vertex(Float(x * scale), Float(y * scale), Float(z * scale)))
            } else if s.matches(w, "facet") {
                facets += 1
                loop.removeAll(keepingCapacity: true)
            } else if s.matches(w, "endloop") || s.matches(w, "endfacet") {
                flush()
            } else if s.matches(w, "endsolid") {
                flush()
            }
        }
        flush()
        return facets
    }
}
