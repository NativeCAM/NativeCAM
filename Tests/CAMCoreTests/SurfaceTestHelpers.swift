import Foundation
import simd
@testable import CAMCore

/// A profile z(x) extruded `width` along Y, closed with walls and a base at z = 0: every face is planar, so the model is
/// exactly the planes the profile describes.
func extrudedProfile(_ profile: [(x: Float, z: Float)], width: Float, id: UUID = UUID()) -> MeshModel {
    var pos: [Float] = []
    var idx: [UInt32] = []
    func add(_ x: Float, _ y: Float, _ z: Float) -> UInt32 { pos += [x, y, z]; return UInt32(pos.count / 3 - 1) }
    var f: [UInt32] = [], b: [UInt32] = [], f0: [UInt32] = [], b0: [UInt32] = []
    for p in profile {
        f.append(add(p.x, 0, p.z))
        b.append(add(p.x, width, p.z))
        f0.append(add(p.x, 0, 0))
        b0.append(add(p.x, width, 0))
    }
    let n = profile.count
    for i in 0..<(n - 1) {
        idx += [f[i], f[i + 1], b[i + 1], f[i], b[i + 1], b[i]]          // top
        idx += [f0[i], f[i + 1], f[i], f0[i], f0[i + 1], f[i + 1]]       // front
        idx += [b0[i], b[i], b[i + 1], b0[i], b[i + 1], b0[i + 1]]       // back
        idx += [f0[i], b0[i + 1], f0[i + 1], f0[i], b0[i], b0[i + 1]]    // base
    }
    idx += [f0[0], f[0], b[0], f0[0], b[0], b0[0]]
    idx += [f0[n - 1], b[n - 1], f[n - 1], f0[n - 1], b0[n - 1], b[n - 1]]
    return MeshModel(id: id, name: "Profile", positions: pos, indices: idx)
}

/// The ball-centre path of a toolpath's feed moves, for measuring what's left on (or cut into) an exact surface: the
/// material left at a surface point, along its normal, is its distance to the nearest ball centre less the radius.
struct BallSweep {
    let radius: Double
    private var segments: [(SIMD3<Double>, SIMD3<Double>)] = []
    private var cells: [SIMD2<Int32>: [Int32]] = [:]
    private let cell = 1.0

    init(_ toolpaths: [Toolpath], radius R: Double) {
        radius = R
        for tp in toolpaths {
            tp.forEachMotion { s, m in
                guard m.kind == .feed else { return }
                let a = SIMD3(s.x, s.y, s.z + R), b = SIMD3(m.end.x, m.end.y, m.end.z + R)
                let k = Int32(segments.count)
                segments.append((a, b))
                let reach = R + 0.5
                let x0 = Int32(((min(a.x, b.x) - reach) / cell).rounded(.down)), x1 = Int32(((max(a.x, b.x) + reach) / cell).rounded(.down))
                let y0 = Int32(((min(a.y, b.y) - reach) / cell).rounded(.down)), y1 = Int32(((max(a.y, b.y) + reach) / cell).rounded(.down))
                for x in x0...x1 { for y in y0...y1 { cells[SIMD2(x, y), default: []].append(k) } }
            }
        }
    }

    /// Material left at surface point p along the normal (negative: the ball cut into the surface there).
    func residual(at p: SIMD3<Double>) -> Double {
        let key = SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)))
        var best = Double.infinity
        for k in cells[key] ?? [] {
            let (a, b) = segments[Int(k)]
            let ab = b - a
            let l2 = simd_length_squared(ab)
            let t = l2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
            best = min(best, simd_distance(p, a + ab * t))
        }
        return best - radius
    }
}
