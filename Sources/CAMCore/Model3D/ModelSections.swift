import Foundation
import simd

/// Exact 2D sections of a model's mesh: what 2.5D toolpaths cut to.
///
/// `outline` is the model's footprint seen from above, the union of every triangle's XY projection, so it holds every
/// point of the mesh (open meshes too) to Clipper's 0.1 µm grid. It replaces a raster silhouette that was only good to
/// about half a cell (1/800 of the model across) and could put an outside profile inside the part (issue #202).
public enum ModelSections {
    /// Triangles unioned in one Clipper call before the pieces are merged.
    static let batchSize = 2048

    /// The footprint of a mesh seen from above, in its own XY: outer loops counter-clockwise, holes clockwise.
    public static func outline(positions: [SIMD3<Float>], indices: [UInt32]) -> [Polyline] {
        // Snap each corner to Clipper's integer grid first, so the winding used here is the one Clipper sees: a sliver
        // that turned over in rounding would count -1 under the non-zero rule and punch a hole in the outline.
        let s = Clipper.scale
        func snap(_ p: SIMD3<Float>) -> Vec2 {
            Vec2((Double(p.x) * s).rounded() / s, (Double(p.y) * s).rounded() / s)
        }
        var triangles: [Polyline] = []
        var centres: [Vec2] = []
        triangles.reserveCapacity(indices.count / 3)
        centres.reserveCapacity(indices.count / 3)
        var i = 0
        while i + 2 < indices.count {
            let a = snap(positions[Int(indices[i])]), b = snap(positions[Int(indices[i + 1])])
            let c = snap(positions[Int(indices[i + 2])])
            i += 3
            let cross = (b - a).cross(c - a)
            // Edge-on (a vertical wall): its shadow is a line on its neighbours' edges, so it adds no area.
            guard cross != 0 else { continue }
            triangles.append(Polyline(cross > 0 ? [a, b, c] : [a, c, b], closed: true))
            centres.append(Vec2((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3))
        }
        guard !triangles.isEmpty else { return [] }
        // Batches of neighbouring triangles union into a few compact loops each, so the merges stay small. Order them
        // along a Morton curve over the centres.
        var box = Rect2.empty
        for c in centres { box = box.union(c) }
        let span = max(box.width, box.height, 1e-9)
        func morton(_ p: Vec2) -> UInt64 {
            func spread(_ v: UInt32) -> UInt64 {
                var x = UInt64(v) & 0xFFFF_FFFF
                x = (x | (x << 16)) & 0x0000_FFFF_0000_FFFF
                x = (x | (x << 8)) & 0x00FF_00FF_00FF_00FF
                x = (x | (x << 4)) & 0x0F0F_0F0F_0F0F_0F0F
                x = (x | (x << 2)) & 0x3333_3333_3333_3333
                x = (x | (x << 1)) & 0x5555_5555_5555_5555
                return x
            }
            let q = Double(UInt32.max >> 1)
            let x = UInt32(max(0, min(q, (p.x - box.min.x) / span * q)))
            let y = UInt32(max(0, min(q, (p.y - box.min.y) / span * q)))
            return spread(x) | (spread(y) << 1)
        }
        let order = centres.indices.map { (morton(centres[$0]), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        var pieces: [[Polyline]] = stride(from: 0, to: order.count, by: batchSize).map { start in
            order[start..<min(order.count, start + batchSize)].map { triangles[$0] }
        }
        // Union each batch, then neighbouring pairs, until one is left.
        while true {
            let input = pieces
            let merged = Merged(count: input.count)
            DispatchQueue.concurrentPerform(iterations: input.count) { k in
                merged.set(k, Clipper.union(input[k], fill: .nonZero))
            }
            pieces = merged.values
            if pieces.count == 1 { break }
            pieces = stride(from: 0, to: pieces.count, by: 2).map { k in
                k + 1 < pieces.count ? pieces[k] + pieces[k + 1] : pieces[k]
            }
        }
        // Where two batches' outlines meet, each was rounded to Clipper's grid on its own, so a seam can open into a
        // hole a fraction of a micron across. A hole no wider than 2 µm anywhere is one of those (or a crack between
        // triangles that don't quite meet): fill it. Dropping a hole only makes the outline larger, never smaller.
        return pieces[0].filter { loop in
            guard loop.count >= 3 else { return false }
            guard loop.signedArea < 0 else { return true }
            return !Clipper.offset([loop.reversed], delta: -0.001, join: .miter).isEmpty
        }
    }

    /// Results written from `concurrentPerform`, each to its own slot.
    private final class Merged: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [[Polyline]]
        init(count: Int) { values = Array(repeating: [], count: count) }
        func set(_ k: Int, _ v: [Polyline]) { lock.lock(); values[k] = v; lock.unlock() }
    }
}
