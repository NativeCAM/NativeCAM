import Foundation
import simd

/// Which source axis points up (away from the table). CAD exports (STL, 3MF) are usually Z-up;
/// OBJ, USDZ and most 3D-art tools are Y-up.
public enum UpAxis: String, Codable, Sendable, CaseIterable, Identifiable {
    case z, y, x
    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() + " up" }
}

/// An imported triangle mesh. Positions are millimetres in the file's own orientation; re-orienting and placing
/// it on the stock is done by `ModelSpec`. Meshes are immutable after import, so identity is the `id`.
public struct MeshModel: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// x, y, z triples (mm).
    public var positions: [Float]
    /// Three vertex indices per triangle.
    public var indices: [UInt32]

    public init(id: UUID = UUID(), name: String, positions: [Float], indices: [UInt32]) {
        self.id = id
        self.name = name
        self.positions = positions
        self.indices = indices
    }

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    @inlinable public func vertex(_ i: Int) -> SIMD3<Float> {
        SIMD3(positions[3 * i], positions[3 * i + 1], positions[3 * i + 2])
    }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<vertexCount {
            let v = vertex(i)
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return vertexCount > 0 ? (lo, hi) : (.zero, .zero)
    }

    // Compact on disk: raw little-endian buffers (JSON encodes Data as base64).
    enum CodingKeys: String, CodingKey { case id, name, positions, indices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        positions = MeshModel.unpack(try c.decode(Data.self, forKey: .positions), as: Float.self)
        indices = MeshModel.unpack(try c.decode(Data.self, forKey: .indices), as: UInt32.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(positions.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .positions)
        try c.encode(indices.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .indices)
    }

    private static func unpack<T>(_ data: Data, as: T.Type) -> [T] {
        let n = data.count / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: n) { buf, count in
            _ = data.copyBytes(to: buf)
            count = n
        }
    }
}

extension MeshModel: Hashable {
    public static func == (a: MeshModel, b: MeshModel) -> Bool {
        a.id == b.id && a.positions.count == b.positions.count && a.indices.count == b.indices.count
    }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// What a 3D-model importer returns.
public struct MeshImportResult: Sendable {
    public var mesh: MeshModel
    public var warnings: [String]
    /// Best guess at the file's up axis (Z for STL/3MF, Y for OBJ/USD/PLY unless the file says otherwise).
    public var suggestedUpAxis: UpAxis
    /// Millimetres per file unit that was applied to `mesh.positions` (1 for mm, 25.4 for inch, 1000 for metres).
    public var unitScale: Double

    public init(mesh: MeshModel, warnings: [String] = [], suggestedUpAxis: UpAxis = .z, unitScale: Double = 1) {
        self.mesh = mesh
        self.warnings = warnings
        self.suggestedUpAxis = suggestedUpAxis
        self.unitScale = unitScale
    }
}
