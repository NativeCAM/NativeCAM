import Foundation
import simd

/// A moulding's surface: a profile (cross-section) swept along rails (`MouldingParams`), as a triangle mesh in design
/// coordinates whose top surface the 3D toolpaths cut.
///
/// Each straight piece of a flattened rail carries the profile square to it, between the mitre lines at its ends. A
/// mitre line runs from the rail vertex along the bisector of the two pieces' normals, stretched so a point on it is
/// the same distance from both pieces' lines: at a sharp corner the two pieces meet on it as a picture frame's sides do,
/// and along a curve (many short pieces) the surface sweeps round smoothly. An open rail's ends are cut square.
///
/// Where the rail turns toward the profile more tightly than the profile is wide, the mitre lines at the two ends of a
/// piece would cross before the profile's far edge and the surface would fold over itself. There the profile is cut
/// back to the width at which they meet (`clampedWidth`); the material beyond is left standing.
public struct MouldingSweep: Sendable {
    /// Why a profile or rail can't be swept.
    public struct Refusal: Error, Sendable, Equatable {
        public var message: String
    }

    /// Mesh vertices (design XY, Z relative to the material top) and three indices per triangle.
    public var positions: [SIMD3<Double>]
    public var indices: [UInt32]
    /// Width of the profile across, mm.
    public var profileWidth: Double
    /// Height of the profile, mm: how deep the moulding goes below the material top.
    public var depth: Double
    /// The narrowest the profile was cut back to where the rail turns too tightly for it, mm; nil when it never was.
    public var clampedWidth: Double?

    /// The profile as (across, Z) points from its start on the rail (across 0) outward, with its highest point at Z 0.
    public static func crossSection(_ profile: Polyline, flipped: Bool, mirrored: Bool) throws(Refusal) -> [Vec2] {
        guard !profile.isClosed else {
            throw Refusal(message: "The profile has to be an open cross-section, with its start on the rail; the one chosen is "
                + "closed. Draw the profile as an open line from the rail outward.")
        }
        let line = (mirrored ? profile.reversed : profile).deduplicated(tolerance: 1e-6)
        guard line.count >= 2, let start = line.points.first, let end = line.points.last else {
            throw Refusal(message: "The profile has no length.")
        }
        // Across is drawn X, away from the rail: toward the profile's far end.
        var away = end.x - start.x
        if abs(away) < 1e-6 { away = line.points.map { $0.x - start.x }.max { abs($0) < abs($1) } ?? 0 }
        let dir: Double = away < 0 ? -1 : 1
        var pts = line.points.map { Vec2(($0.x - start.x) * dir, ($0.y - start.y) * (flipped ? -1 : 1)) }
        let widest = pts.map(\.x).max() ?? 0, behind = pts.map(\.x).min() ?? 0
        guard widest > 0.1 else {
            throw Refusal(message: "The profile has no width across: draw it with its width along X and its height along Y.")
        }
        guard behind > -0.01 else {
            throw Refusal(message: "The profile runs back past its start, behind the rail. Draw it so it moves away from the "
                + "rail across its width (its start is the point on the rail), or mirror it.")
        }
        let top = pts.map(\.y).max() ?? 0, bottom = pts.map(\.y).min() ?? 0
        guard top - bottom > 0.01 else {
            throw Refusal(message: "The profile is flat: draw its height along Y.")
        }
        for i in pts.indices { pts[i] = Vec2(max(0, pts[i].x), pts[i].y - top) }
        return pts
    }

    /// The cross-section cut back at `width` across: the points up to where it first reaches that width, then that point
    /// repeated (so every vertex keeps its index and the mesh stays one strip per profile segment).
    static func truncated(_ section: [Vec2], at width: Double) -> [Vec2] {
        var out = section
        var cut: Vec2?
        for k in section.indices {
            if let c = cut { out[k] = c; continue }
            guard section[k].x > width else { continue }
            let a = section[max(0, k - 1)], b = section[k]
            let t = b.x - a.x > 1e-12 ? (width - a.x) / (b.x - a.x) : 0
            let c = Vec2(width, a.y + (b.y - a.y) * max(0, min(1, t)))
            cut = c
            out[k] = c
        }
        return out
    }

    /// Sweeps `section` (from `crossSection`) along each rail on `side`.
    public static func sweep(section: [Vec2], rails: [Polyline], side: MouldingParams.Side) throws(Refusal) -> MouldingSweep {
        let width = section.map(\.x).max() ?? 0
        let depth = -(section.map(\.y).min() ?? 0)
        var positions: [SIMD3<Double>] = []
        var indices: [UInt32] = []
        var narrowest = Double.infinity
        let k = section.count
        for raw in rails {
            var rail = raw.deduplicated(tolerance: 1e-6)
            if rail.isClosed {
                guard rail.count >= 3 else { continue }
                rail = rail.oriented(counterClockwise: true)
            } else if rail.count < 2 {
                continue
            }
            let v = rail.points
            let n = v.count
            let segs = rail.isClosed ? n : n - 1
            var t = [Vec2](), nor = [Vec2](), len = [Double]()
            for i in 0..<segs {
                let d = v[(i + 1) % n] - v[i]
                len.append(d.length)
                let u = d.normalized
                t.append(u)
                nor.append(side == .left ? u.perpLeft : u.perpRight)
            }
            // Each vertex's mitre direction and stretch (distance along it per unit across).
            var mitre = [Vec2](repeating: .zero, count: n), stretch = [Double](repeating: 1, count: n)
            for j in 0..<n {
                let incoming = rail.isClosed ? (j + segs - 1) % segs : (j > 0 ? j - 1 : nil)
                let outgoing = rail.isClosed || j < segs ? j % segs : nil
                switch (incoming, outgoing) {
                case let (a?, b?):
                    let sum = nor[a] + nor[b]
                    // A rail that doubles back on itself has no bisector: square to the incoming piece.
                    let m = sum.length < 1e-9 ? nor[a] : sum.normalized
                    mitre[j] = m
                    // Kept from running out further than five times the width at a corner sharper than about 157°.
                    stretch[j] = 1 / max(0.2, m.dot(nor[b]))
                case let (a?, nil): mitre[j] = nor[a]
                case let (nil, b?): mitre[j] = nor[b]
                case (nil, nil): break
                }
            }
            // How wide each piece's strip can be before the mitre lines at its ends cross; each vertex takes the
            // narrower of its two pieces'.
            var limit = [Double](repeating: .infinity, count: n)
            for i in 0..<segs {
                let j0 = i, j1 = (i + 1) % n
                let b = stretch[j0] * mitre[j0].dot(t[i]), e = stretch[j1] * mitre[j1].dot(t[i])
                let closing = max(b, 0) + max(-e, 0)
                guard closing > 1e-12 else { continue }
                let w = len[i] / closing
                limit[j0] = min(limit[j0], w)
                limit[j1] = min(limit[j1], w)
            }
            let base = UInt32(positions.count)
            for j in 0..<n {
                let c = limit[j]
                if c < width - 1e-6 { narrowest = min(narrowest, c) }
                let pts = c < width ? truncated(section, at: c) : section
                for p in pts {
                    let xy = v[j] + mitre[j] * (stretch[j] * p.x)
                    positions.append(SIMD3(xy.x, xy.y, p.y))
                }
            }
            for i in 0..<segs {
                let j0 = UInt32(i), j1 = UInt32((i + 1) % n)
                for q in 0..<UInt32(k - 1) {
                    let a = base + j0 * UInt32(k) + q, b = a + 1
                    let d = base + j1 * UInt32(k) + q, c = d + 1
                    indices += [a, b, c, a, c, d]
                }
            }
        }
        guard !indices.isEmpty else {
            throw Refusal(message: "The moulding needs a rail: select the vector the profile follows with it.")
        }
        return MouldingSweep(positions: positions, indices: indices, profileWidth: width, depth: depth,
                             clampedWidth: narrowest.isFinite ? max(0, narrowest) : nil)
    }

    /// The surface as a placed 3D model, so the 3D toolpaths, the preview and the simulator take it like any other: a
    /// mesh centred on its bounds, on a shape at their centre, carved to the profile's depth from the material top. The
    /// mesh's ID comes from its points, so the same surface is the same model (and hits the same cached geometry).
    public func modelShape(name: String) -> DesignShape {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let centre = Vec2((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
        var flat: [Float] = []
        flat.reserveCapacity(positions.count * 3)
        for p in positions {
            flat.append(Float(p.x - centre.x))
            flat.append(Float(p.y - centre.y))
            flat.append(Float(p.z - lo.z))
        }
        let mesh = MeshModel(id: Self.contentID(flat, indices), name: name, positions: flat, indices: indices)
        let spec = ModelSpec(mesh: mesh, upAxis: .z, depth: max(1e-3, hi.z - lo.z), topOffset: max(0, -hi.z))
        return DesignShape(id: mesh.id, name: name, kind: .model(spec), position: centre)
    }

    /// A UUID made from the mesh's bytes (two FNV-1a hashes).
    static func contentID(_ positions: [Float], _ indices: [UInt32]) -> UUID {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325, h2: UInt64 = 0x8422_2325_cbf2_9ce4
        func mix(_ x: UInt32) {
            h1 = (h1 ^ UInt64(x)) &* 0x0000_0100_0000_01b3
            h2 = (h2 ^ UInt64(x ^ 0x9e37_79b9)) &* 0x0000_0100_0000_01b3
        }
        for p in positions { mix(p.bitPattern) }
        for i in indices { mix(i) }
        var u = UUID().uuid
        withUnsafeMutableBytes(of: &u) { raw in
            for b in 0..<8 {
                raw[b] = UInt8(truncatingIfNeeded: h1 >> (8 * UInt64(b)))
                raw[8 + b] = UInt8(truncatingIfNeeded: h2 >> (8 * UInt64(b)))
            }
        }
        u.6 = (u.6 & 0x0f) | 0x80 // version 8 (custom)
        u.8 = (u.8 & 0x3f) | 0x80
        return UUID(uuid: u)
    }
}
