import Foundation
import simd

/// Position + normal vertex for lit meshes (layout matches `MeshIn` in ViewportShaders via a vertex descriptor).
struct ViewportMeshVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>

    init(_ position: SIMD3<Float>, _ normal: SIMD3<Float>) {
        self.position = position
        self.normal = normal
    }
}

// MARK: - Uniform blocks (must match the MSL structs in ViewportShaders.source)

struct ViewportFrameUniforms {
    var viewProj: simd_float4x4
    var eye: SIMD4<Float>
    var lightDir: SIMD4<Float>
    var params: SIMD4<Float>
}

struct ViewportMeshUniforms {
    var model: simd_float4x4
    var color: SIMD4<Float>
    /// x: specular strength, y: shininess, z: depth pull towards the eye (fraction of distance),
    /// w: grid spacing for distance fading of grid lines (0 = no fading).
    var params: SIMD4<Float>

    init(model: simd_float4x4 = matrix_identity_float4x4, color: SIMD4<Float> = SIMD4(1, 1, 1, 1),
         specular: Float = 0, shininess: Float = 16, depthPull: Float = 0, fadeSpacing: Float = 0) {
        self.model = model
        self.color = color
        self.params = SIMD4(specular, shininess, depthPull, fadeSpacing)
    }
}

struct ViewportHeightUniforms {
    var dims: SIMD4<Float>
    var origin: SIMD4<Float>
    var topColor: SIMD4<Float>
    var cutColor: SIMD4<Float>
    var deepColor: SIMD4<Float>
    var sideColor: SIMD4<Float>
}

struct ViewportRotaryUniforms {
    /// x: columns, y: rows, z: cell size (mm), w: floorZ of the face grids.
    var dims: SIMD4<Float>
    /// xy: world XY of cell (0, 0)'s centre, z: axis to the faces (mm), w: epsilon (mm).
    var origin: SIMD4<Float>
    /// xy: world Y and Z of the rotation axis, z: the blank's angle now (radians), w: 1 for a square bar.
    var axis: SIMD4<Float>
    /// x: number of faces.
    var counts: SIMD4<Float>
    var topColor: SIMD4<Float>
    var cutColor: SIMD4<Float>
    var deepColor: SIMD4<Float>
    var sideColor: SIMD4<Float>
}

struct ViewportBackgroundUniforms {
    var top: SIMD4<Float>
    var bottom: SIMD4<Float>
}

// MARK: - CPU-side geometry builders

enum ViewportMeshes {
    /// Bed-plane decorations: a faint fill, grid lines, axes, machine travel outline, and an origin triad.
    struct Bed {
        var fill: [LineVertex] = []      // triangle list
        var minor: [LineVertex] = []     // line list, fades out when `spacing` gets dense on screen
        var major: [LineVertex] = []     // line list, every 10th line, fades at 10 x `spacing`
        var overlay: [LineVertex] = []   // line list: axes and machine travel outline (never faded)
        var triad: [LineVertex] = []     // line list, drawn on top
        var spacing: Float = 25.4        // effective grid spacing
        var boundsMin: SIMD3<Float> = .zero
        var boundsMax: SIMD3<Float> = .zero
    }

    static func bed(stockSize: SIMD3<Float>, travel: SIMD2<Float>?, spacing rawSpacing: Float) -> Bed {
        let w = finitePositive(stockSize.x), h = finitePositive(stockSize.y), t = finitePositive(stockSize.z)
        let z = -t

        var lo = SIMD2<Float>(0, 0)
        var hi = SIMD2<Float>(w, h)
        var travelRect: SIMD2<Float>?
        if let tr = travel, finitePositive(tr.x) > 0, finitePositive(tr.y) > 0 {
            travelRect = tr
            hi = simd_max(hi, tr)
        }

        var spacing = (rawSpacing.isFinite && rawSpacing > 0) ? rawSpacing : 25.4
        let extent = max(hi.x - lo.x, hi.y - lo.y)
        let margin = max(2 * spacing, 0.06 * extent)
        lo -= SIMD2(repeating: margin)
        hi += SIMD2(repeating: margin)
        // Keep the line count sane for tiny spacings on large beds.
        while max(hi.x - lo.x, hi.y - lo.y) / spacing > 600 { spacing *= 10 }

        let i0 = Int((lo.x / spacing).rounded(.down)), i1 = Int((hi.x / spacing).rounded(.up))
        let j0 = Int((lo.y / spacing).rounded(.down)), j1 = Int((hi.y / spacing).rounded(.up))
        let gx0 = Float(i0) * spacing, gx1 = Float(i1) * spacing
        let gy0 = Float(j0) * spacing, gy1 = Float(j1) * spacing

        var bed = Bed()
        let fillColor = SIMD4<Float>(0.30, 0.32, 0.36, 0.22)
        let a = SIMD3(gx0, gy0, z), b = SIMD3(gx1, gy0, z), c = SIMD3(gx1, gy1, z), d = SIMD3(gx0, gy1, z)
        bed.fill = [a, b, c, a, c, d].map { LineVertex($0, fillColor) }

        let minorColor = SIMD4<Float>(0.78, 0.82, 0.90, 0.075)
        let majorColor = SIMD4<Float>(0.78, 0.82, 0.90, 0.17)
        bed.spacing = spacing
        bed.minor.reserveCapacity(((i1 - i0) + (j1 - j0) + 2) * 2)
        for i in i0...i1 where i != 0 {
            let x = Float(i) * spacing
            let isMajor = i % 10 == 0
            let a = LineVertex(SIMD3(x, gy0, z), isMajor ? majorColor : minorColor)
            let b = LineVertex(SIMD3(x, gy1, z), isMajor ? majorColor : minorColor)
            if isMajor { bed.major += [a, b] } else { bed.minor += [a, b] }
        }
        for j in j0...j1 where j != 0 {
            let y = Float(j) * spacing
            let isMajor = j % 10 == 0
            let a = LineVertex(SIMD3(gx0, y, z), isMajor ? majorColor : minorColor)
            let b = LineVertex(SIMD3(gx1, y, z), isMajor ? majorColor : minorColor)
            if isMajor { bed.major += [a, b] } else { bed.minor += [a, b] }
        }

        var lines: [LineVertex] = []

        if let tr = travelRect {
            let col = SIMD4<Float>(0.45, 0.65, 1.0, 0.45)
            let p = [SIMD3(0, 0, z), SIMD3(tr.x, 0, z), SIMD3(tr.x, tr.y, z), SIMD3(0, tr.y, z)]
            for k in 0..<4 {
                lines.append(LineVertex(p[k], col))
                lines.append(LineVertex(p[(k + 1) % 4], col))
            }
        }

        // Axes through the stock origin: bright on the positive side, dim on the negative side.
        let red = SIMD4<Float>(0.95, 0.30, 0.28, 0.85), redDim = SIMD4<Float>(0.95, 0.30, 0.28, 0.25)
        let green = SIMD4<Float>(0.35, 0.88, 0.38, 0.85), greenDim = SIMD4<Float>(0.35, 0.88, 0.38, 0.25)
        lines += [LineVertex(SIMD3(gx0, 0, z), redDim), LineVertex(SIMD3(0, 0, z), redDim),
                  LineVertex(SIMD3(0, 0, z), red), LineVertex(SIMD3(gx1, 0, z), red),
                  LineVertex(SIMD3(0, gy0, z), greenDim), LineVertex(SIMD3(0, 0, z), greenDim),
                  LineVertex(SIMD3(0, 0, z), green), LineVertex(SIMD3(0, gy1, z), green)]
        bed.overlay = lines

        // Small XYZ triad at the work origin (material top, lower-left).
        let len = (w > 0 || h > 0) ? min(max(0.07 * max(w, h), 0.5), 80) : 8
        let o = SIMD3<Float>(0, 0, 0)
        let blue = SIMD4<Float>(0.40, 0.60, 1.0, 1)
        bed.triad = [LineVertex(o, SIMD4(0.95, 0.30, 0.28, 1)), LineVertex(SIMD3(len, 0, 0), SIMD4(0.95, 0.30, 0.28, 1)),
                     LineVertex(o, SIMD4(0.35, 0.88, 0.38, 1)), LineVertex(SIMD3(0, len, 0), SIMD4(0.35, 0.88, 0.38, 1)),
                     LineVertex(o, blue), LineVertex(SIMD3(0, 0, len), blue)]

        bed.boundsMin = SIMD3(gx0, gy0, z)
        bed.boundsMax = SIMD3(gx1, gy1, max(0, len))
        return bed
    }

    /// Translucent stock box from (0,0,-thickness) to (w,h,0): outward CCW faces plus 12 edges.
    static func stockBox(size: SIMD3<Float>, edgeColor: SIMD4<Float>) -> (faces: [ViewportMeshVertex], edges: [LineVertex]) {
        let w = finitePositive(size.x), h = finitePositive(size.y), t = finitePositive(size.z)
        guard w > 0, h > 0 else { return ([], []) }
        let z0 = -t, z1: Float = 0
        var faces: [ViewportMeshVertex] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            for p in [a, b, c, a, c, d] { faces.append(ViewportMeshVertex(p, n)) }
        }
        quad(SIMD3(0, 0, z1), SIMD3(w, 0, z1), SIMD3(w, h, z1), SIMD3(0, h, z1), SIMD3(0, 0, 1))      // top
        if t > 0 {
            quad(SIMD3(0, 0, z0), SIMD3(0, h, z0), SIMD3(w, h, z0), SIMD3(w, 0, z0), SIMD3(0, 0, -1))  // bottom
            quad(SIMD3(0, 0, z0), SIMD3(w, 0, z0), SIMD3(w, 0, z1), SIMD3(0, 0, z1), SIMD3(0, -1, 0))  // front
            quad(SIMD3(w, h, z0), SIMD3(0, h, z0), SIMD3(0, h, z1), SIMD3(w, h, z1), SIMD3(0, 1, 0))   // back
            quad(SIMD3(0, h, z0), SIMD3(0, 0, z0), SIMD3(0, 0, z1), SIMD3(0, h, z1), SIMD3(-1, 0, 0))  // left
            quad(SIMD3(w, 0, z0), SIMD3(w, h, z0), SIMD3(w, h, z1), SIMD3(w, 0, z1), SIMD3(1, 0, 0))   // right
        }
        var edges: [LineVertex] = []
        let top = [SIMD3(0, 0, z1), SIMD3(w, 0, z1), SIMD3(w, h, z1), SIMD3(0, h, z1)]
        let bottom = top.map { SIMD3($0.x, $0.y, z0) }
        for k in 0..<4 {
            edges.append(LineVertex(top[k], edgeColor)); edges.append(LineVertex(top[(k + 1) % 4], edgeColor))
            if t > 0 {
                edges.append(LineVertex(bottom[k], edgeColor)); edges.append(LineVertex(bottom[(k + 1) % 4], edgeColor))
                edges.append(LineVertex(top[k], edgeColor)); edges.append(LineVertex(bottom[k], edgeColor))
            }
        }
        return (faces, edges)
    }

    /// The uncut surface of a rotary blank in its own frame: x along the axis from 0 to `length`, y and z across it
    /// from the axis, with 0° (straight up, +Z) square to a face of a square bar. Ends are closed with flat caps.
    /// The shader cuts away whatever the faces' height fields removed.
    static func rotaryBlank(square: Bool, radius r: Float, length l: Float, segments: Int = 160) -> [ViewportMeshVertex] {
        guard r > 0, l > 0 else { return [] }
        // Points round the cross-section, counter-clockwise seen from +X, each with its outward normal.
        var ring: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
        if square {
            let corners: [SIMD2<Float>] = [SIMD2(r, r), SIMD2(-r, r), SIMD2(-r, -r), SIMD2(r, -r)]
            for k in 0..<4 {
                let a = corners[k], b = corners[(k + 1) % 4]
                let n = simd_normalize((a + b) / 2)
                ring += [(a, n), (b, n)]
            }
        } else {
            for j in 0..<segments {
                let a0 = Float(j) / Float(segments) * 2 * .pi, a1 = Float(j + 1) / Float(segments) * 2 * .pi
                ring += [(SIMD2(cos(a0), sin(a0)) * r, SIMD2(cos(a0), sin(a0))), (SIMD2(cos(a1), sin(a1)) * r, SIMD2(cos(a1), sin(a1)))]
            }
        }
        var out: [ViewportMeshVertex] = []
        func v(_ x: Float, _ p: SIMD2<Float>, _ n: SIMD3<Float>) -> ViewportMeshVertex { ViewportMeshVertex(SIMD3(x, p.x, p.y), n) }
        for k in stride(from: 0, to: ring.count, by: 2) {
            let (a, na) = ring[k], (b, nb) = ring[k + 1]
            let n0 = SIMD3(0, na.x, na.y), n1 = SIMD3(0, nb.x, nb.y)
            out += [v(0, a, n0), v(l, a, n0), v(l, b, n1), v(0, a, n0), v(l, b, n1), v(0, b, n1)]
            // End caps: fans from the axis.
            out += [v(0, .zero, SIMD3(-1, 0, 0)), v(0, b, SIMD3(-1, 0, 0)), v(0, a, SIMD3(-1, 0, 0))]
            out += [v(l, .zero, SIMD3(1, 0, 0)), v(l, a, SIMD3(1, 0, 0)), v(l, b, SIMD3(1, 0, 0))]
        }
        return out
    }

    /// Revolve a right-half silhouette (radius, height above tip) about +Z into a lit triangle list.
    /// Normals are smoothed across profile vertices whose segments meet at less than ~40 degrees
    /// (so ball noses look round) and kept sharp elsewhere (flat bottoms, shank shoulders).
    static func revolve(_ silhouette: [SIMD2<Float>], segments: Int = 48) -> [ViewportMeshVertex] {
        var pts: [SIMD2<Float>] = []
        for p in silhouette where p.x.isFinite && p.y.isFinite {
            let q = SIMD2(max(p.x, 0), p.y)
            if let last = pts.last, simd_distance(last, q) < 1e-5 { continue }
            pts.append(q)
        }
        guard pts.count >= 2, segments >= 3 else { return [] }

        let segCount = pts.count - 1
        var segN: [SIMD2<Float>] = []
        segN.reserveCapacity(segCount)
        for i in 0..<segCount {
            let d = pts[i + 1] - pts[i]
            segN.append(simd_normalize(SIMD2(d.y, -d.x)))  // outward for a tip-to-shank outline
        }
        let smoothCos = cos(Float(40) * .pi / 180)
        func blended(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float>? {
            simd_dot(a, b) > smoothCos ? simd_normalize(a + b) : nil
        }

        var cosT = [Float](), sinT = [Float]()
        for j in 0...segments {
            let a = Float(j) / Float(segments) * 2 * .pi
            cosT.append(cos(a)); sinT.append(sin(a))
        }
        func pos(_ p: SIMD2<Float>, _ j: Int) -> SIMD3<Float> { SIMD3(p.x * cosT[j], p.x * sinT[j], p.y) }
        func nrm(_ n: SIMD2<Float>, _ j: Int) -> SIMD3<Float> { SIMD3(n.x * cosT[j], n.x * sinT[j], n.y) }

        var out: [ViewportMeshVertex] = []
        out.reserveCapacity(segCount * segments * 6 + segments * 6)
        for k in 0..<segCount {
            let p0 = pts[k], p1 = pts[k + 1]
            if p0.x < 1e-6 && p1.x < 1e-6 { continue }  // segment on the axis
            let n0 = (k > 0 ? blended(segN[k - 1], segN[k]) : nil) ?? segN[k]
            let n1 = (k + 1 < segCount ? blended(segN[k], segN[k + 1]) : nil) ?? segN[k]
            for j in 0..<segments {
                let a = ViewportMeshVertex(pos(p0, j), nrm(n0, j))
                let b = ViewportMeshVertex(pos(p0, j + 1), nrm(n0, j + 1))
                let c = ViewportMeshVertex(pos(p1, j + 1), nrm(n1, j + 1))
                let d = ViewportMeshVertex(pos(p1, j), nrm(n1, j))
                out += [a, b, c, a, c, d]
            }
        }
        // Close open ends with flat caps.
        if let first = pts.first, first.x > 1e-4 {
            let center = SIMD3<Float>(0, 0, first.y), n = SIMD3<Float>(0, 0, -1)
            for j in 0..<segments {
                out += [ViewportMeshVertex(center, n), ViewportMeshVertex(pos(first, j + 1), n), ViewportMeshVertex(pos(first, j), n)]
            }
        }
        if let last = pts.last, last.x > 1e-4 {
            let center = SIMD3<Float>(0, 0, last.y), n = SIMD3<Float>(0, 0, 1)
            for j in 0..<segments {
                out += [ViewportMeshVertex(center, n), ViewportMeshVertex(pos(last, j), n), ViewportMeshVertex(pos(last, j + 1), n)]
            }
        }
        return out
    }

    @inline(__always) static func finitePositive(_ v: Float) -> Float {
        v.isFinite && v > 0 ? v : 0
    }
}
