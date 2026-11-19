import Foundation

/// Why a 3D model could not be imported.
public enum MeshImportError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFileType(String)
    /// The file has no bytes.
    case emptyFile(String)
    /// The file was read but contains no usable triangles.
    case noTriangles(String)
    /// The file is damaged or not in the format its extension says.
    case malformed(String)
    /// The file could not be opened or decoded at all.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(ext):
            "Unsupported 3D model type “\(ext)”. NativeCAM imports "
                + ModelImporter.supportedExtensions.map { "." + $0 }.joined(separator: ", ") + " files."
        case let .emptyFile(name):
            "“\(name)” is empty."
        case let .noTriangles(detail):
            "The model contains no triangles: \(detail)"
        case let .malformed(detail):
            "The model could not be read: \(detail)"
        case let .unreadable(detail):
            "The model could not be opened: \(detail)"
        }
    }
}

/// Imports a 3D model (STL, OBJ, 3MF natively; PLY, USD/USDZ and anything else Model I/O reads through Model I/O)
/// into a welded, indexed triangle mesh in millimetres.
public enum ModelImporter {
    public static let supportedExtensions = ["stl", "obj", "3mf", "ply", "usdz", "usd", "usda", "usdc"]

    /// - Parameter assumedUnit: unit of formats that carry none (STL, OBJ, PLY). 3MF and USD say their own unit.
    public static func importFile(at url: URL, assumedUnit: LengthUnit = .mm) throws -> MeshImportResult {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "stl", "obj", "3mf":
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw MeshImportError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            return try importData(data, fileExtension: ext, name: name, assumedUnit: assumedUnit)
        default:
            guard ModelIOImporter.canImport(fileExtension: ext) else {
                throw MeshImportError.unsupportedFileType(ext.isEmpty ? url.lastPathComponent : ext)
            }
            return try ModelIOImporter.importFile(at: url, name: name, assumedUnit: assumedUnit)
        }
    }

    /// Imports from memory. Formats read through Model I/O are written to a temporary file first.
    public static func importData(_ data: Data, fileExtension: String, name: String,
                                  assumedUnit: LengthUnit = .mm) throws -> MeshImportResult {
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch ext {
        case "stl":
            return try STLImporter.importSTL(data: data, name: name, assumedUnit: assumedUnit)
        case "obj":
            return try OBJImporter.importOBJ(data: data, name: name, assumedUnit: assumedUnit)
        case "3mf":
            return try ThreeMFImporter.import3MF(data: data, name: name)
        default:
            guard ModelIOImporter.canImport(fileExtension: ext) else {
                throw MeshImportError.unsupportedFileType(ext.isEmpty ? name : ext)
            }
            guard !data.isEmpty else { throw MeshImportError.emptyFile(name) }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("NativeCAM-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let url = dir.appendingPathComponent((safeName.isEmpty ? "model" : safeName) + "." + ext)
            try data.write(to: url)
            return try ModelIOImporter.importFile(at: url, name: name, assumedUnit: assumedUnit)
        }
    }
}

// MARK: - Welding mesh builder

/// Collects triangles into an indexed mesh, merging vertices that coincide to within `quantum` mm
/// (open-addressing hash on the quantized coordinates) and dropping degenerate and non-finite triangles.
/// Storage is manually managed so million-triangle files stay fast even in debug builds.
final class MeshWelder {
    /// Weld grid (mm).
    static let quantum: Double = 1e-5
    private static let inverseQuantum: Double = 1 / quantum
    static let noVertex = UInt32.max

    private(set) var vertexCount = 0
    private(set) var triangleCount = 0
    private(set) var degenerateCount = 0
    private(set) var nonFiniteCount = 0

    private var positions: UnsafeMutablePointer<Float>
    private var keys: UnsafeMutablePointer<Int64>
    private var vertexCapacity: Int
    private var table: UnsafeMutablePointer<UInt32>
    private var tableMask: Int
    private var indices: UnsafeMutablePointer<UInt32>
    private var indexCapacity: Int

    /// - Parameter expectedTriangles: sizing hint; storage grows as needed.
    init(expectedTriangles: Int = 1024) {
        let tris = max(16, min(expectedTriangles, 1 << 28))
        vertexCapacity = max(16, tris / 2 + 16)
        positions = .allocate(capacity: 3 * vertexCapacity)
        keys = .allocate(capacity: 3 * vertexCapacity)
        var size = 32
        while size < 2 * vertexCapacity { size <<= 1 }
        table = .allocate(capacity: size)
        table.initialize(repeating: MeshWelder.noVertex, count: size)
        tableMask = size - 1
        indexCapacity = 3 * tris
        indices = .allocate(capacity: indexCapacity)
    }

    deinit {
        positions.deallocate()
        keys.deallocate()
        table.deallocate()
        indices.deallocate()
    }

    @inline(__always) private static func quantize(_ v: Float) -> Int64 {
        let q = (Double(v) * inverseQuantum).rounded()
        return Int64(q < -9e18 ? -9e18 : (q > 9e18 ? 9e18 : q))
    }

    @inline(__always) private static func hash(_ x: Int64, _ y: Int64, _ z: Int64) -> Int {
        var h = UInt64(bitPattern: x) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: y) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bitPattern: z) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 31
        h = h &* 0xD6E8_FEB8_6659_FD93
        h ^= h >> 32
        return Int(truncatingIfNeeded: h)
    }

    /// The welded index of a vertex (mm), or `noVertex` if a coordinate is not finite.
    func vertex(_ x: Float, _ y: Float, _ z: Float) -> UInt32 {
        guard x.isFinite && y.isFinite && z.isFinite else { return MeshWelder.noVertex }
        let kx = MeshWelder.quantize(x), ky = MeshWelder.quantize(y), kz = MeshWelder.quantize(z)
        var slot = MeshWelder.hash(kx, ky, kz) & tableMask
        while true {
            let e = table[slot]
            if e == MeshWelder.noVertex { break }
            let k = keys + 3 * Int(e)
            if k[0] == kx && k[1] == ky && k[2] == kz { return e }
            slot = (slot + 1) & tableMask
        }
        if vertexCount == vertexCapacity { growVertices() }
        let i = vertexCount
        let p = positions + 3 * i
        p[0] = x; p[1] = y; p[2] = z
        let k = keys + 3 * i
        k[0] = kx; k[1] = ky; k[2] = kz
        vertexCount += 1
        if 2 * vertexCount > tableMask + 1 {
            growTable()
        } else {
            table[slot] = UInt32(i)
        }
        return UInt32(i)
    }

    /// Adds a triangle of welded indices; skips it if it is degenerate or references a non-finite vertex.
    func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        if a == MeshWelder.noVertex || b == MeshWelder.noVertex || c == MeshWelder.noVertex {
            nonFiniteCount += 1
            return
        }
        if a == b || b == c || a == c {
            degenerateCount += 1
            return
        }
        // Exactly collinear corners: zero area.
        let pa = positions + 3 * Int(a), pb = positions + 3 * Int(b), pc = positions + 3 * Int(c)
        let ux = Double(pb[0] - pa[0]), uy = Double(pb[1] - pa[1]), uz = Double(pb[2] - pa[2])
        let vx = Double(pc[0] - pa[0]), vy = Double(pc[1] - pa[1]), vz = Double(pc[2] - pa[2])
        let cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx
        if cx == 0 && cy == 0 && cz == 0 {
            degenerateCount += 1
            return
        }
        if 3 * (triangleCount + 1) > indexCapacity { growIndices() }
        let p = indices + 3 * triangleCount
        p[0] = a; p[1] = b; p[2] = c
        triangleCount += 1
    }

    @inline(__always) func triangle(_ x0: Float, _ y0: Float, _ z0: Float,
                                    _ x1: Float, _ y1: Float, _ z1: Float,
                                    _ x2: Float, _ y2: Float, _ z2: Float) {
        let a = vertex(x0, y0, z0), b = vertex(x1, y1, z1), c = vertex(x2, y2, z2)
        triangle(a, b, c)
    }

    /// Notes about dropped triangles, for `MeshImportResult.warnings`.
    var warnings: [String] {
        var w: [String] = []
        if degenerateCount > 0 {
            w.append("Skipped \(degenerateCount) degenerate (zero-area) triangle\(degenerateCount == 1 ? "" : "s").")
        }
        if nonFiniteCount > 0 {
            w.append("Skipped \(nonFiniteCount) triangle\(nonFiniteCount == 1 ? "" : "s") with invalid (NaN or infinite) coordinates.")
        }
        return w
    }

    /// The mesh; vertices referenced only by skipped triangles are dropped.
    func makeMesh(name: String) -> MeshModel {
        let indexBuffer = UnsafeMutableBufferPointer(start: indices, count: 3 * triangleCount)
        if degenerateCount > 0 || nonFiniteCount > 0 {
            var remap = [UInt32](repeating: MeshWelder.noVertex, count: vertexCount)
            var kept: UInt32 = 0
            remap.withUnsafeMutableBufferPointer { r in
                for i in 0..<indexBuffer.count {
                    let v = Int(indexBuffer[i])
                    if r[v] == MeshWelder.noVertex { r[v] = kept; kept += 1 }
                }
            }
            if Int(kept) < vertexCount {
                var compact = [Float](repeating: 0, count: 3 * Int(kept))
                compact.withUnsafeMutableBufferPointer { c in
                    for v in 0..<vertexCount where remap[v] != MeshWelder.noVertex {
                        let j = 3 * Int(remap[v])
                        c[j] = positions[3 * v]; c[j + 1] = positions[3 * v + 1]; c[j + 2] = positions[3 * v + 2]
                    }
                }
                let newIndices = indexBuffer.map { remap[Int($0)] }
                return MeshModel(name: name, positions: compact, indices: newIndices)
            }
        }
        return MeshModel(name: name,
                         positions: Array(UnsafeBufferPointer(start: positions, count: 3 * vertexCount)),
                         indices: Array(indexBuffer))
    }

    private func growVertices() {
        let newCap = vertexCapacity * 2
        let np = UnsafeMutablePointer<Float>.allocate(capacity: 3 * newCap)
        np.update(from: positions, count: 3 * vertexCount)
        positions.deallocate()
        positions = np
        let nk = UnsafeMutablePointer<Int64>.allocate(capacity: 3 * newCap)
        nk.update(from: keys, count: 3 * vertexCount)
        keys.deallocate()
        keys = nk
        vertexCapacity = newCap
    }

    /// Doubles the table and reinserts every vertex (including the one just appended).
    private func growTable() {
        let size = 2 * (tableMask + 1)
        table.deallocate()
        table = .allocate(capacity: size)
        table.initialize(repeating: MeshWelder.noVertex, count: size)
        tableMask = size - 1
        for i in 0..<vertexCount {
            let k = keys + 3 * i
            var slot = MeshWelder.hash(k[0], k[1], k[2]) & tableMask
            while table[slot] != MeshWelder.noVertex { slot = (slot + 1) & tableMask }
            table[slot] = UInt32(i)
        }
    }

    private func growIndices() {
        let newCap = indexCapacity * 2
        let ni = UnsafeMutablePointer<UInt32>.allocate(capacity: newCap)
        ni.update(from: indices, count: 3 * triangleCount)
        indices.deallocate()
        indices = ni
        indexCapacity = newCap
    }

    /// Wraps the welded mesh in a result, or throws if nothing usable was found.
    func result(name: String, warnings extra: [String], upAxis: UpAxis, unitScale: Double,
                emptyDetail: String) throws -> MeshImportResult {
        guard triangleCount > 0 else {
            var detail = emptyDetail
            if degenerateCount + nonFiniteCount > 0 {
                detail += " (\(degenerateCount + nonFiniteCount) degenerate or invalid triangles were skipped)"
            }
            throw MeshImportError.noTriangles(detail)
        }
        return MeshImportResult(mesh: makeMesh(name: name), warnings: extra + warnings,
                                suggestedUpAxis: upAxis, unitScale: unitScale)
    }
}

// MARK: - Byte scanning for text formats

/// A cursor over ASCII text for the STL and OBJ readers: whitespace, words, numbers.
struct ByteScanner {
    let base: UnsafePointer<UInt8>
    let end: Int
    var pos = 0

    init(_ base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.end = count
    }

    var atEnd: Bool { pos >= end }

    @inline(__always) func peek(_ offset: Int = 0) -> UInt8 {
        pos + offset < end ? base[pos + offset] : 0
    }

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0B || b == 0x0C
    }

    /// Skips spaces, tabs, newlines and other control bytes.
    mutating func skipWhitespace() {
        var p = pos
        while p < end && base[p] <= 0x20 { p += 1 }
        pos = p
    }

    /// Skips spaces and tabs (not newlines). With `continuations`, a backslash that ends a line also counts as space.
    mutating func skipInlineSpace(continuations: Bool = false) {
        while pos < end {
            let b = base[pos]
            if ByteScanner.isSpace(b) {
                pos += 1
            } else if continuations && b == 0x5C, let n = continuationLength(at: pos) {
                pos += n
            } else {
                break
            }
        }
    }

    /// Length of a `\` line continuation (backslash, optional spaces/CR, newline) at `i`, if there is one.
    @inline(__always) func continuationLength(at i: Int) -> Int? {
        var j = i + 1
        while j < end, base[j] == 0x20 || base[j] == 0x09 || base[j] == 0x0D { j += 1 }
        return j < end && base[j] == 0x0A ? j + 1 - i : (j >= end ? j - i : nil)
    }

    /// At a newline (or the end).
    var atLineEnd: Bool { pos >= end || base[pos] == 0x0A }

    /// Moves past the next newline.
    mutating func skipLine(continuations: Bool = false) {
        while pos < end {
            let b = base[pos]
            if b == 0x0A { pos += 1; return }
            if continuations && b == 0x5C, let n = continuationLength(at: pos) { pos += n; continue }
            pos += 1
        }
    }

    /// The next run of bytes up to a space or control byte.
    mutating func word() -> Range<Int> {
        let start = pos
        var p = pos
        while p < end && base[p] > 0x20 { p += 1 }
        pos = p
        return start..<p
    }

    /// Case-insensitive comparison of `range` with an ASCII keyword.
    func matches(_ range: Range<Int>, _ keyword: StaticString) -> Bool {
        guard range.count == keyword.utf8CodeUnitCount else { return false }
        let k = keyword.utf8Start
        for i in 0..<range.count where (base[range.lowerBound + i] | 0x20) != (k[i] | 0x20) { return false }
        return true
    }

    private static let powersOf10: [Double] = (0...22).map { pow(10, Double($0)) }

    /// Parses a decimal number (`-1.5`, `.5`, `2e-3`) at the cursor; nil (cursor unchanged) if there is none.
    mutating func number() -> Double? {
        var p = pos
        var negative = false
        if p < end && (base[p] == 0x2D || base[p] == 0x2B) {
            negative = base[p] == 0x2D
            p += 1
        }
        var mantissa: UInt64 = 0
        var significant = 0
        var exp10 = 0
        var digits = 0
        while p < end {
            let d = base[p] &- 0x30
            guard d < 10 else { break }
            if significant < 19 {
                mantissa = mantissa &* 10 &+ UInt64(d)
                if mantissa != 0 { significant += 1 }
            } else {
                exp10 += 1
            }
            digits += 1
            p += 1
        }
        if p < end && base[p] == 0x2E {
            p += 1
            while p < end {
                let d = base[p] &- 0x30
                guard d < 10 else { break }
                if significant < 19 {
                    mantissa = mantissa &* 10 &+ UInt64(d)
                    if mantissa != 0 { significant += 1 }
                    exp10 -= 1
                }
                digits += 1
                p += 1
            }
        }
        guard digits > 0 else { return nil }
        if p < end && (base[p] | 0x20) == 0x65 {
            var q = p + 1
            var expNegative = false
            if q < end && (base[q] == 0x2D || base[q] == 0x2B) {
                expNegative = base[q] == 0x2D
                q += 1
            }
            var e = 0
            var expDigits = 0
            while q < end {
                let d = base[q] &- 0x30
                guard d < 10 else { break }
                if e < 10_000 { e = e * 10 + Int(d) }
                expDigits += 1
                q += 1
            }
            if expDigits > 0 {
                exp10 += expNegative ? -e : e
                p = q
            }
        }
        pos = p
        var v = Double(mantissa)
        if mantissa != 0 && exp10 != 0 {
            if exp10 > 0 && exp10 <= 22 {
                v *= ByteScanner.powersOf10[exp10]
            } else if exp10 < 0 && exp10 >= -22 {
                v /= ByteScanner.powersOf10[-exp10]
            } else {
                v *= pow(10, Double(exp10))
            }
        }
        return negative ? -v : v
    }

    /// Parses a signed decimal integer at the cursor; nil (cursor unchanged) if there is none.
    mutating func integer() -> Int? {
        var p = pos
        var negative = false
        if p < end && (base[p] == 0x2D || base[p] == 0x2B) {
            negative = base[p] == 0x2D
            p += 1
        }
        var v = 0
        var digits = 0
        while p < end {
            let d = base[p] &- 0x30
            guard d < 10 else { break }
            if v < Int(Int32.max) { v = v * 10 + Int(d) }
            digits += 1
            p += 1
        }
        guard digits > 0 else { return nil }
        pos = p
        return negative ? -v : v
    }
}
