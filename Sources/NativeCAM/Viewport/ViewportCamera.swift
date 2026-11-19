import Foundation
import simd

/// Turntable orbit camera for the viewport. World Z is up.
///
/// `azimuth` rotates about +Z, `elevation` tilts above the XY plane (pi/2 = looking straight down).
/// At azimuth 0 the screen's right is +X: elevation 0 is the front view (looking along +Y) and
/// elevation pi/2 is the plan/top view with +X right and +Y up.
struct ViewportCamera: Equatable {
    var target: SIMD3<Float> = .zero
    var distance: Float = 1000
    var azimuth: Float = Float.pi / 4
    var elevation: Float = ViewportCamera.isoElevation
    var fovY: Float = 32 * Float.pi / 180

    /// True isometric elevation, atan(1/sqrt(2)) = 35.26 degrees.
    static let isoElevation: Float = atan(1 / Float(2).squareRoot())
    static let distanceRange: ClosedRange<Float> = 0.5...200_000

    // MARK: basis

    /// Unit vector from the eye towards the target.
    var forward: SIMD3<Float> {
        let ce = cos(elevation)
        return SIMD3(-sin(azimuth) * ce, cos(azimuth) * ce, -sin(elevation))
    }

    /// Screen-right direction (always horizontal, so the top view never degenerates).
    var right: SIMD3<Float> { SIMD3(cos(azimuth), sin(azimuth), 0) }

    /// Screen-up direction.
    var up: SIMD3<Float> { simd_cross(right, forward) }

    var eye: SIMD3<Float> { target - forward * distance }

    // MARK: matrices

    var viewMatrix: simd_float4x4 {
        let r = right, u = up, f = forward, e = eye
        return simd_float4x4(columns: (
            SIMD4(r.x, u.x, -f.x, 0),
            SIMD4(r.y, u.y, -f.y, 0),
            SIMD4(r.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(r, e), -simd_dot(u, e), simd_dot(f, e), 1)
        ))
    }

    /// Right-handed perspective with reversed Z: depth 1 at `near`, 0 at `far` (Metal clip space).
    static func projection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / max(aspect, 1e-4)
        let a = near / (far - near)
        let b = near * far / (far - near)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, a, -1),
            SIMD4(0, 0, b, 0)
        ))
    }

    /// World-space ray through a point in normalized device coordinates (-1...1, +y up).
    func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let t = tan(fovY * 0.5)
        let d = forward + right * (ndc.x * t * aspect) + up * (ndc.y * t)
        return (eye, simd_normalize(d))
    }

    // MARK: presets and fitting

    static func angles(for preset: ViewPreset) -> (azimuth: Float, elevation: Float) {
        switch preset {
        case .top: return (0, Float.pi / 2)
        case .front: return (0, 0)
        case .iso: return (Float.pi / 4, isoElevation)
        }
    }

    /// This camera's orientation, re-targeted and re-distanced so the box fills `margin` of the view.
    func fitted(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, aspect rawAspect: Float,
                margin: Float = 0.86) -> ViewportCamera {
        var lo = simd_min(boundsMin, boundsMax)
        var hi = simd_max(boundsMin, boundsMax)
        if !(lo.x.isFinite && lo.y.isFinite && lo.z.isFinite && hi.x.isFinite && hi.y.isFinite && hi.z.isFinite) {
            lo = SIMD3(-50, -50, -10)
            hi = SIMD3(50, 50, 0)
        }
        // Give degenerate boxes some size so zero-size stock still yields a usable view.
        let minExtent: Float = 10
        let ext = hi - lo
        for i in 0..<3 where ext[i] < minExtent {
            let c = (lo[i] + hi[i]) * 0.5
            lo[i] = c - minExtent * 0.5
            hi[i] = c + minExtent * 0.5
        }
        let aspect = (rawAspect.isFinite && rawAspect > 0) ? rawAspect : 1.5
        let tanV = tan(fovY * 0.5) * margin
        let tanH = tanV * aspect
        let center = (lo + hi) * 0.5
        let r = right, u = up, f = forward
        var needed: Float = 0
        for i in 0..<8 {
            let corner = SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
            let q = corner - center
            let x = abs(simd_dot(q, r)), y = abs(simd_dot(q, u)), z = simd_dot(q, f)
            needed = max(needed, x / tanH - z, y / tanV - z)
        }
        var c = self
        c.target = center
        c.distance = min(max(needed, Self.distanceRange.lowerBound * 10), Self.distanceRange.upperBound)
        return c
    }

    // MARK: animation

    static func interpolate(_ a: ViewportCamera, _ b: ViewportCamera, _ t: Float) -> ViewportCamera {
        var c = b
        c.target = simd_mix(a.target, b.target, SIMD3(repeating: t))
        c.distance = exp(log(max(a.distance, 1e-3)) * (1 - t) + log(max(b.distance, 1e-3)) * t)
        let dAz = remainder(b.azimuth - a.azimuth, 2 * Float.pi)
        c.azimuth = a.azimuth + dAz * t
        c.elevation = a.elevation + (b.elevation - a.elevation) * t
        c.fovY = a.fovY + (b.fovY - a.fovY) * t
        return c
    }

    mutating func normalizeAngles() {
        azimuth = remainder(azimuth, 2 * Float.pi)
        elevation = min(max(elevation, -Float.pi / 2), Float.pi / 2)
        distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
    }
}
