import Foundation
import ModelIO
import simd

/// Reads PLY, USD/USDA/USDC/USDZ and anything else Model I/O can open, by collecting every `MDLMesh` in the asset,
/// applying its world transform, and welding the triangles into one mesh.
///
/// Units: USD stages are assumed to be in metres (×1000) unless a text layer states `metersPerUnit`; if metres would
/// make the model absurdly large it is taken as millimetres. Other formats use `assumedUnit`.
public enum ModelIOImporter {
    static let usdExtensions: Set<String> = ["usd", "usda", "usdc", "usdz"]
    /// Beyond this size (mm) after assuming metres, a unitless USD is taken to be in millimetres instead.
    static let absurdSizeMM = 10_000.0

    public static func canImport(fileExtension ext: String) -> Bool {
        !ext.isEmpty && MDLAsset.canImportFileExtension(ext)
    }

    public static func importFile(at url: URL, name: String? = nil, assumedUnit: LengthUnit = .mm) throws -> MeshImportResult {
        let name = name ?? url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        guard let size else {
            throw MeshImportError.unreadable("“\(url.lastPathComponent)” does not exist or can't be read")
        }
        guard size > 0 else { throw MeshImportError.emptyFile(url.lastPathComponent) }

        var warnings: [String] = []
        var error: NSError?
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false, error: &error)
        if let error {
            // Model I/O puts its actual message (e.g. "Parse PLY: Bad format") under "MDLErrorKey".
            let detail = (error.userInfo["MDLErrorKey"] as? String) ?? error.localizedDescription
            throw MeshImportError.unreadable("\(url.lastPathComponent): \(detail)")
        }
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else {
            throw MeshImportError.noTriangles("Model I/O found no meshes in “\(url.lastPathComponent)”")
        }

        // Pass 1: world-space positions (file units) and triangles per mesh.
        struct Piece { var positions: [Float]; var triangles: [UInt32] }
        var pieces: [Piece] = []
        var skippedSubmeshes = 0
        var unreadableMeshes = 0
        for mesh in meshes {
            let world = worldTransform(mesh)
            guard let positions = worldPositions(mesh, world) else { unreadableMeshes += 1; continue }
            let vertexCount = positions.count / 3
            var tris: [UInt32] = []
            let submeshes = (mesh.submeshes as? [MDLSubmesh]) ?? []
            if submeshes.isEmpty && vertexCount >= 3 {
                // No index buffers: treat the vertices as a triangle list.
                tris = Array(0..<UInt32(vertexCount / 3 * 3))
            }
            for sub in submeshes where !appendTriangles(sub, vertexCount: vertexCount, to: &tris) {
                skippedSubmeshes += 1
            }
            if determinant(world) < 0 {
                // A mirroring transform turns the faces inside out; restore the winding.
                var i = 0
                while i + 2 < tris.count { tris.swapAt(i + 1, i + 2); i += 3 }
            }
            pieces.append(Piece(positions: positions, triangles: tris))
        }
        if unreadableMeshes > 0 {
            warnings.append("Skipped \(unreadableMeshes) mesh\(unreadableMeshes == 1 ? "" : "es") without readable vertex positions.")
        }
        if skippedSubmeshes > 0 {
            warnings.append("Skipped \(skippedSubmeshes) point, line or unreadable submesh\(skippedSubmeshes == 1 ? "" : "es").")
        }

        // Units and up axis.
        var scale = assumedUnit.mmPerUnit
        var upAxis = UpAxis.y
        if usdExtensions.contains(ext) {
            let meta = usdStageMetadata(url)
            if let axis = meta.upAxis { upAxis = axis }
            if let mpu = meta.metersPerUnit, mpu > 0, mpu.isFinite {
                scale = mpu * 1000
                warnings.append("The USD stage says \(formatNumber(mpu)) metres per unit; scaled ×\(formatNumber(scale)) to millimetres.")
            } else {
                let extent = largestExtent(pieces.map(\.positions))
                if extent * 1000 > absurdSizeMM {
                    scale = 1
                    warnings.append("USD files are usually in metres, but this model would then be \(formatNumber(extent)) m across; assumed millimetres instead.")
                } else {
                    scale = 1000
                    warnings.append("The USD file doesn't state its unit; assumed metres (×1000 to millimetres).")
                }
            }
        }

        // Pass 2: scale to mm and weld the vertices the triangles use.
        let totalTriangles = pieces.reduce(0) { $0 + $1.triangles.count / 3 }
        let welder = MeshWelder(expectedTriangles: max(totalTriangles, 16))
        for piece in pieces {
            var remap = [UInt32](repeating: MeshWelder.noVertex, count: piece.positions.count / 3)
            piece.positions.withUnsafeBufferPointer { v in
                remap.withUnsafeMutableBufferPointer { r in
                    @inline(__always) func welded(_ k: UInt32) -> UInt32 {
                        let i = Int(k)
                        if r[i] == MeshWelder.noVertex {
                            r[i] = welder.vertex(Float(Double(v[3 * i]) * scale), Float(Double(v[3 * i + 1]) * scale),
                                                 Float(Double(v[3 * i + 2]) * scale))
                        }
                        return r[i]
                    }
                    let t = piece.triangles
                    var i = 0
                    while i + 2 < t.count {
                        welder.triangle(welded(t[i]), welded(t[i + 1]), welded(t[i + 2]))
                        i += 3
                    }
                }
            }
        }
        return try welder.result(name: name, warnings: warnings, upAxis: upAxis, unitScale: scale,
                                 emptyDetail: "“\(url.lastPathComponent)” has no triangle faces")
    }

    // MARK: Geometry

    /// Local-to-world: the object's transform times every ancestor's.
    static func worldTransform(_ object: MDLObject) -> simd_float4x4 {
        var m = object.transform?.matrix ?? matrix_identity_float4x4
        var p = object.parent
        while let parent = p {
            if let t = parent.transform?.matrix { m = t * m }
            p = parent.parent
        }
        return m
    }

    private static func determinant(_ m: simd_float4x4) -> Float {
        let a = m.columns.0, b = m.columns.1, c = m.columns.2
        return a.x * (b.y * c.z - c.y * b.z) - b.x * (a.y * c.z - c.y * a.z) + c.x * (a.y * b.z - b.y * a.z)
    }

    /// Largest bounding-box side over all finite positions.
    private static func largestExtent(_ arrays: [[Float]]) -> Double {
        var lo = (Float.infinity, Float.infinity, Float.infinity), hi = (-Float.infinity, -Float.infinity, -Float.infinity)
        for a in arrays {
            var i = 0
            while i + 2 < a.count {
                let x = a[i], y = a[i + 1], z = a[i + 2]
                if x.isFinite && y.isFinite && z.isFinite {
                    lo = (min(lo.0, x), min(lo.1, y), min(lo.2, z))
                    hi = (max(hi.0, x), max(hi.1, y), max(hi.2, z))
                }
                i += 3
            }
        }
        guard lo.0 <= hi.0 else { return 0 }
        return Double(max(hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2))
    }

    /// World-space positions (file units) as x, y, z triples.
    private static func worldPositions(_ mesh: MDLMesh, _ m: simd_float4x4) -> [Float]? {
        let n = mesh.vertexCount
        guard n > 0, var attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition) else { return nil }
        var components = 3, half = false
        switch attr.format {
        case .float2: components = 2
        case .float3: components = 3
        case .float4: components = 4
        case .half2: components = 2; half = true
        case .half3: components = 3; half = true
        case .half4: components = 4; half = true
        default:
            // Ask Model I/O to convert anything else to float3.
            guard let converted = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                  converted.format == .float3 else { return nil }
            attr = converted
        }
        let width = components * (half ? 2 : 4)
        let stride = attr.stride
        guard stride >= width, attr.bufferSize == 0 || stride * (n - 1) + width <= attr.bufferSize else { return nil }

        let identity = m == matrix_identity_float4x4
        let c0 = SIMD4<Double>(m.columns.0), c1 = SIMD4<Double>(m.columns.1)
        let c2 = SIMD4<Double>(m.columns.2), c3 = SIMD4<Double>(m.columns.3)
        let (a00, a10, a20) = (c0.x, c0.y, c0.z), (a01, a11, a21) = (c1.x, c1.y, c1.z)
        let (a02, a12, a22) = (c2.x, c2.y, c2.z), (a03, a13, a23) = (c3.x, c3.y, c3.z)
        var out = [Float](repeating: 0, count: 3 * n)
        withExtendedLifetime(attr) {
            let start = UnsafeRawPointer(attr.dataStart)
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<n {
                    let p = start + i * stride
                    @inline(__always) func comp(_ c: Int) -> Double {
                        guard c < components else { return 0 }
                        if half { return Double(Float(Float16(bitPattern: p.loadUnaligned(fromByteOffset: 2 * c, as: UInt16.self)))) }
                        return Double(p.loadUnaligned(fromByteOffset: 4 * c, as: Float.self))
                    }
                    let x = comp(0), y = comp(1), z = comp(2)
                    if identity {
                        o[3 * i] = Float(x); o[3 * i + 1] = Float(y); o[3 * i + 2] = Float(z)
                    } else {
                        o[3 * i] = Float(a00 * x + a01 * y + a02 * z + a03)
                        o[3 * i + 1] = Float(a10 * x + a11 * y + a12 * z + a13)
                        o[3 * i + 2] = Float(a20 * x + a21 * y + a22 * z + a23)
                    }
                }
            }
        }
        return out
    }

    /// Appends the submesh's faces as triangles; false if it has no faces we can use.
    private static func appendTriangles(_ sub: MDLSubmesh, vertexCount: Int, to tris: inout [UInt32]) -> Bool {
        let count = sub.indexCount
        guard count > 0 else { return false }
        let width: Int
        switch sub.indexType {
        case .uInt8: width = 1
        case .uInt16: width = 2
        case .uInt32: width = 4
        default: return false
        }
        switch sub.geometryType {
        case .triangles, .triangleStrips, .quads, .variableTopology: break
        default: return false
        }
        let buffer = sub.indexBuffer
        guard count * width <= buffer.length else { return false }
        let map = buffer.map()
        return withExtendedLifetime(map) { () -> Bool in
            let raw = UnsafeRawPointer(map.bytes)
            func index(_ i: Int) -> UInt32 {
                switch width {
                case 1: UInt32(raw.load(fromByteOffset: i, as: UInt8.self))
                case 2: UInt32(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)))
                default: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
                }
            }
            let limit = UInt32(vertexCount)
            var added = false
            func add(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
                guard a < limit, b < limit, c < limit else { return }
                tris.append(a); tris.append(b); tris.append(c)
                added = true
            }
            switch sub.geometryType {
            case .triangles:
                tris.reserveCapacity(tris.count + count)
                var i = 0
                while i + 2 < count { add(index(i), index(i + 1), index(i + 2)); i += 3 }
            case .triangleStrips:
                // Alternating winding; an all-ones index restarts the strip.
                let restart: UInt32 = width == 1 ? 0xFF : (width == 2 ? 0xFFFF : 0xFFFF_FFFF)
                var stripStart = 0
                for i in 0..<count {
                    if index(i) == restart { stripStart = i + 1; continue }
                    let k = i - stripStart
                    if k >= 2 {
                        if k % 2 == 0 { add(index(i - 2), index(i - 1), index(i)) } else { add(index(i - 1), index(i - 2), index(i)) }
                    }
                }
            case .quads:
                var i = 0
                while i + 3 < count {
                    add(index(i), index(i + 1), index(i + 2))
                    add(index(i), index(i + 2), index(i + 3))
                    i += 4
                }
            default:  // .variableTopology: per-face corner counts in the topology's face buffer.
                guard let topo = sub.topology, let faceBuffer = topo.faceTopology, topo.faceCount > 0,
                      faceBuffer.length >= topo.faceCount else { return false }
                let faceMap = faceBuffer.map()
                withExtendedLifetime(faceMap) {
                    let faces = UnsafeRawPointer(faceMap.bytes)
                    var i = 0
                    for f in 0..<topo.faceCount {
                        let k = Int(faces.load(fromByteOffset: f, as: UInt8.self))
                        guard i + k <= count else { break }
                        if k >= 3 {
                            for j in 1..<(k - 1) { add(index(i), index(i + j), index(i + j + 1)) }
                        }
                        i += k
                    }
                }
            }
            return added
        }
    }

    // MARK: USD stage metadata

    /// `upAxis` and `metersPerUnit` from a text (usda) layer; USDZ packages are searched for a .usda root layer.
    /// Binary crate (usdc) layers are not parsed.
    static func usdStageMetadata(_ url: URL) -> (upAxis: UpAxis?, metersPerUnit: Double?) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (nil, nil) }
        var text: Data?
        if data.starts(with: Array("#usda".utf8)) {
            text = data
        } else if data.starts(with: [0x50, 0x4B, 0x03, 0x04]), let zip = try? ZipArchive(data: data),
                  let first = zip.entries.first, first.name.lowercased().hasSuffix(".usda") {
            text = try? zip.extract(first)
        }
        guard let text else { return (nil, nil) }
        // Stage metadata is in the layer header, before the first prim.
        let header = String(decoding: text.prefix(16_384), as: UTF8.self)
        let headerEnd = header.range(of: "\ndef ")?.lowerBound ?? header.range(of: "\nover ")?.lowerBound ?? header.endIndex
        let head = header[..<headerEnd]
        var axis: UpAxis?
        var mpu: Double?
        if let r = head.range(of: #"upAxis\s*=\s*"([XYZxyz])""#, options: .regularExpression) {
            let letter = head[r].dropLast().last.map { String($0).lowercased() }
            axis = letter.flatMap { UpAxis(rawValue: $0) }
        }
        if let r = head.range(of: #"metersPerUnit\s*=\s*[-+0-9.eE]+"#, options: .regularExpression) {
            let value = head[r].split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) }
            mpu = value.flatMap { Double($0) }
        }
        return (axis, mpu)
    }

    private static func formatNumber(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e9 { return String(Int(v)) }
        return String(format: "%.4g", v)
    }
}
