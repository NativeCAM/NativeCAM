import Foundation
import Testing
@testable import CAMCore

/// The exact drop-cutter for V-bits, engraving bits, drills, bull noses and tapered ball noses (`CutterProfile`),
/// checked against references worked out independently from each bit's own profile (`Tool.profileHeight`), and the
/// speedups (pruning, hints) checked to leave ball and flat results exactly as they were.
struct DropCutterTests {
    /// A test bit: how to build its cutter, its radius, and its height above the tip at a distance from the axis,
    /// worked out independently of `CutterProfile`.
    struct Bit: CustomStringConvertible, Sendable {
        var description: String
        var radius: Double
        var make: @Sendable (_ allowance: Double, _ triangles: [Double]) -> TriangleDropCutter?
        var height: @Sendable (Double) -> Double
    }

    static func tool(_ shape: ToolShape, diameter: Double, angle: Double = 90, tip: Double = 0, corner: Double = 0) -> Tool {
        Tool(number: 50, name: "Test \(shape.label)", shape: shape, diameter: diameter, fluteLength: 25, cornerRadius: corner,
             includedAngle: angle, tipDiameter: tip,
             cutting: CuttingData(spindleRPM: 18000, feedRate: 2000, plungeRate: 500, stepdown: 3, stepoverFraction: 0.1))
    }

    static func bit(_ t: Tool) -> Bit {
        Bit(description: "\(t.shape.label) ⌀\(t.diameter) \(t.includedAngle)° tip \(t.tipDiameter) corner \(t.cornerRadius)",
            radius: t.radius, make: { TriangleDropCutter(tool: t, allowance: $0, triangles: $1) },
            height: { t.profileHeight(atRadius: min($0, t.radius)) ?? 0 })
    }

    /// A tapered ball nose: a ball of radius rho running into a cone of half-angle alpha that touches it.
    static func taperedBall(radius R: Double, ball rho: Double, halfAngle alpha: Double) -> Bit {
        let profile = CutterProfile.taperedBall(radius: R, ball: rho, halfAngle: alpha)
        return Bit(description: "tapered ball r\(rho) \(alpha * 180 / .pi)° R\(R)", radius: R,
                   make: { TriangleDropCutter(profile: profile, allowance: $0, triangles: $1) },
                   height: { r in
                       // The cone's flank is tangent to the ball where the ball's slope reaches 1 / tan(alpha).
                       let rt = rho * cos(alpha)
                       if r <= rt { return rho - (rho * rho - r * r).squareRoot() }
                       return rho - rho * sin(alpha) + (r - rt) / tan(alpha)
                   })
    }

    static let bits: [Bit] = [
        bit(ToolLibrary.starter.tool(number: 6)!), // 90° V-bit 1/2"
        bit(tool(.vBit, diameter: 12, angle: 60, tip: 1)),
        bit(ToolLibrary.starter.tool(number: 9)!), // 30° engraving bit, 0.010" tip
        bit(tool(.drill, diameter: 6, angle: 118)),
        bit(tool(.bullNose, diameter: 6.35, corner: 1.5)),
        bit(tool(.bullNose, diameter: 12.7, corner: 6.35)), // all corner: a ball
        taperedBall(radius: 3.175, ball: 0.5, halfAngle: 10 * .pi / 180),
    ]

    // MARK: References

    /// Golden-section search for the largest value of a function that is concave on [lo, hi].
    static func maximise(_ f: (Double) -> Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return f(lo) }
        let g = (5.0.squareRoot() - 1) / 2
        var a = lo, b = hi
        var x1 = b - g * (b - a), x2 = a + g * (b - a)
        var f1 = f(x1), f2 = f(x2)
        for _ in 0..<90 {
            if f1 < f2 {
                a = x1
                (x1, f1) = (x2, f2)
                x2 = a + g * (b - a)
                f2 = f(x2)
            } else {
                b = x2
                (x2, f2) = (x1, f1)
                x1 = b - g * (b - a)
                f1 = f(x1)
            }
        }
        return max(f(lo), f(hi), f1, f2)
    }

    /// The bit's height above its real tip at distance r once grown by `a` all round (the lowest point of the circles
    /// of radius a round its profile), or nil beyond its reach.
    static func grownHeight(_ bit: Bit, _ a: Double, _ r: Double) -> Double? {
        guard a > 0 else { return r <= bit.radius ? bit.height(r) : nil }
        guard r <= bit.radius + a else { return nil }
        let lo = max(-bit.radius, r - a), hi = min(bit.radius, r + a)
        // h(|x|) and −√(a² − (r − x)²) are both convex in x, so their sum has one minimum.
        return -maximise({ x in -(bit.height(abs(x)) - max(0, a * a - (r - x) * (r - x)).squareRoot()) }, lo, hi)
    }

    /// Tip Z over a surface whose height varies only along one line through the tool's axis, at signed distance ρ
    /// from it (planes along their slope, a sphere toward its centre, a cylinder across it): the most any point asks
    /// for, z(ρ) − h(|ρ|), over the part of [−reach, reach] where the surface is, [from, to].
    static func reference(_ bit: Bit, allowance a: Double, from: Double, to: Double, _ z: (Double) -> Double) -> Double {
        let reach = bit.radius + a
        let lo = max(-reach, from), hi = min(reach, to)
        guard lo <= hi else { return -.infinity }
        return maximise({ rho in z(rho) - (grownHeight(bit, a, abs(rho)) ?? .infinity) }, lo, hi)
    }

    // MARK: Meshes

    static func quad(_ p: [SIMD3<Double>]) -> [Double] {
        [p[0], p[1], p[2], p[0], p[2], p[3]].flatMap { [$0.x, $0.y, $0.z] }
    }

    /// The plane z = z0 + slope · x over a wide square.
    static func plane(z0: Double, slope: Double, half: Double = 60) -> [Double] {
        func v(_ x: Double, _ y: Double) -> SIMD3<Double> { SIMD3(x, y, z0 + slope * x) }
        return quad([v(-half, -half), v(half, -half), v(half, half), v(-half, half)])
    }

    /// The upper half of a sphere of radius s centred at c, with its largest gap below the true sphere.
    static func hemisphere(_ s: Double, at c: SIMD3<Double>, rings: Int = 180, segments: Int = 720) -> (triangles: [Double], sag: Double) {
        func v(_ i: Int, _ j: Int) -> SIMD3<Double> {
            let lat = Double(i) / Double(rings) * .pi / 2, lon = Double(j) / Double(segments) * 2 * .pi
            return c + s * SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        }
        var t: [Double] = []
        for i in 0..<rings {
            for j in 0..<segments { t += quad([v(i, j), v(i, j + 1), v(i + 1, j + 1), v(i + 1, j)]) }
        }
        let dLat = .pi / 2 / Double(rings), dLon = 2 * .pi / Double(segments)
        return (t, s * (1 - cos(dLat) * cos(dLon)))
    }

    /// The upper half of a cylinder of radius s along Y, its axis at x = 0, z = zc.
    static func cylinder(_ s: Double, zc: Double, segments: Int = 720) -> (triangles: [Double], sag: Double) {
        func v(_ j: Int, _ y: Double) -> SIMD3<Double> {
            let a = Double(j) / Double(segments) * .pi
            return SIMD3(s * cos(a), y, zc + s * sin(a))
        }
        var t: [Double] = []
        for j in 0..<segments { t += quad([v(j, -60), v(j + 1, -60), v(j + 1, 60), v(j, 60)]) }
        return (t, s * (1 - cos(.pi / Double(segments))))
    }

    /// A block whose top is at z = top for x ≥ 0, with its vertical wall at x = 0.
    static func block(top: Double) -> [Double] {
        quad([SIMD3(0, -60, top), SIMD3(60, -60, top), SIMD3(60, 60, top), SIMD3(0, 60, top)])
            + quad([SIMD3(0, -60, top - 40), SIMD3(0, -60, top), SIMD3(0, 60, top), SIMD3(0, 60, top - 40)])
    }

    // MARK: Analytic surfaces

    /// A level plane, a 30° and a 60° slope: exact contact heights, whichever part of the bit touches (its tip, its
    /// ball or corner, the flat of a 60° V lying on the 60° slope, the shoulder of a 90° V on it).
    @Test(arguments: bits) func planesAndSlopes(_ bit: Bit) throws {
        for a in [0.0, 0.4] {
            for degrees in [0.0, 30, 60] {
                let slope = tan(degrees * .pi / 180)
                let cutter = try #require(bit.make(a, Self.plane(z0: -5, slope: slope)))
                for x in [-7.0, 0, 3.3] {
                    let got = cutter.z(at: Vec2(x, 1.5))
                    let want = Self.reference(bit, allowance: a, from: -.infinity, to: .infinity) { -5 + slope * (x + $0) }
                    #expect(abs(got - want) < 1e-7, "\(bit) allowance \(a) slope \(degrees)° at x \(x): \(got) vs \(want)")
                }
            }
        }
    }

    /// A sphere: on top, on its shoulder and past its edge (where only a V's flank or shoulder reaches it).
    @Test(arguments: bits) func sphere(_ bit: Bit) throws {
        let s = 20.0, c = SIMD3(0.0, 0, -25)
        let mesh = Self.hemisphere(s, at: c)
        for a in [0.0, 0.4] {
            let cutter = try #require(bit.make(a, mesh.triangles))
            for d in [0.0, 5, 12, 19, 21.5, 24] {
                let p = Vec2(d * cos(0.3), d * sin(0.3))
                let got = cutter.z(at: p)
                func ref(_ s: Double) -> Double {
                    Self.reference(bit, allowance: a, from: d - s, to: d + s) { c.z + max(0, s * s - (d - $0) * (d - $0)).squareRoot() }
                }
                let high = ref(s), low = ref(s - mesh.sag)
                if high == -.infinity {
                    #expect(got == -.infinity, "\(bit) allowance \(a) at \(d): \(got)")
                } else {
                    #expect(got <= high + 1e-7, "\(bit) allowance \(a) at \(d): \(got) above \(high)")
                    #expect(got >= low - 1e-7, "\(bit) allowance \(a) at \(d): \(got) below \(low)")
                }
            }
        }
    }

    /// A cylinder lying along Y: on top, on its side and past it.
    @Test(arguments: bits) func cylinder(_ bit: Bit) throws {
        let s = 15.0, zc = -20.0
        let mesh = Self.cylinder(s, zc: zc)
        for a in [0.0, 0.4] {
            let cutter = try #require(bit.make(a, mesh.triangles))
            for x in [0.0, 4, 10, 14.5, 17] {
                let got = cutter.z(at: Vec2(x, 3))
                func ref(_ s: Double) -> Double {
                    Self.reference(bit, allowance: a, from: -x - s, to: -x + s) { zc + max(0, s * s - (x + $0) * (x + $0)).squareRoot() }
                }
                let high = ref(s), low = ref(s - mesh.sag)
                if high == -.infinity {
                    #expect(got == -.infinity, "\(bit) allowance \(a) at \(x): \(got)")
                } else {
                    #expect(got <= high + 1e-7, "\(bit) allowance \(a) at \(x): \(got) above \(high)")
                    #expect(got >= low - 1e-7, "\(bit) allowance \(a) at \(x): \(got) below \(low)")
                }
            }
        }
    }

    /// A vertical wall: beside it the bit's profile meets the top edge (tip Z = top − h(distance)), and past its reach
    /// nothing touches.
    @Test(arguments: bits) func verticalWall(_ bit: Bit) throws {
        let top = -3.0
        for a in [0.0, 0.4] {
            let cutter = try #require(bit.make(a, Self.block(top: top)))
            let reach = bit.radius + a
            for d in [reach + 0.5, reach - 0.05, reach * 0.7, reach * 0.3, 0.02, 0, -2, -10] {
                let got = cutter.z(at: Vec2(-d, 0))
                if d > reach {
                    #expect(got == -.infinity, "\(bit) allowance \(a) at \(d): \(got)")
                } else {
                    let want = top - (Self.grownHeight(bit, a, max(0, d)) ?? .infinity)
                    #expect(abs(got - want) < 1e-7, "\(bit) allowance \(a) at \(d): \(got) vs \(want)")
                }
            }
        }
    }

    // MARK: Random triangles

    /// The most any point of a triangle asks the tip to rise at the origin, by sampling the triangle densely (with the
    /// grown bit's heights from `coarse`) and zooming in on the best sample (with them from `exact`): never above the
    /// true answer, and close to it. Both height functions may only ever ask for at least what the bit needs.
    static func sampled(_ t: ArraySlice<Double>, coarse: (Double) -> Double?, exact: (Double) -> Double?) -> Double {
        let i = t.startIndex
        let A = SIMD3(t[i], t[i + 1], t[i + 2]), B = SIMD3(t[i + 3], t[i + 4], t[i + 5]), C = SIMD3(t[i + 6], t[i + 7], t[i + 8])
        func f(_ u: Double, _ v: Double, _ h: (Double) -> Double?) -> Double {
            let u = max(0, u), v = max(0, v), s = u + v
            let (uu, vv) = s > 1 ? (u / s, v / s) : (u, v)
            let q = A + uu * (B - A) + vv * (C - A)
            guard let hq = h((q.x * q.x + q.y * q.y).squareRoot()) else { return -.infinity }
            return q.z - hq
        }
        let n = 80
        var best = -Double.infinity, at = (0.0, 0.0)
        for j in 0...n {
            for k in 0...(n - j) {
                let u = Double(j) / Double(n), v = Double(k) / Double(n)
                let value = f(u, v, coarse)
                if value > best { best = value; at = (u, v) }
            }
        }
        guard best > -.infinity else { return best }
        var span = 2.0 / Double(n)
        for _ in 0..<6 {
            let (u0, v0) = at
            for j in -10...10 {
                for k in -10...10 {
                    let u = max(0, u0 + span * Double(j) / 10), v = max(0, v0 + span * Double(k) / 10)
                    let value = f(u, v, exact)
                    if value > best { best = value; at = (u + v > 1 ? u / (u + v) : u, u + v > 1 ? v / (u + v) : v) }
                }
            }
            span /= 4
        }
        return best
    }

    /// Random triangles round the tool, at random slopes: the exact cutter is never below what any sampled point of
    /// them asks for (it can't cut into them), and within a whisker of the most they ask for.
    @Test(arguments: bits) func randomTrianglesAgreeWithBruteForce(_ bit: Bit) throws {
        var rng = SplitMix(seed: 27)
        for a in [0.0, 0.3] {
            var checked = 0
            defer { #expect(checked >= 15, "\(bit) allowance \(a): only \(checked) scenes in reach") }
            let reach = bit.radius + a
            // Heights of the grown bit, tabled for the coarse search: straight lines between table points lie above a
            // convex profile, so the table never asks for less than the bit needs.
            let table = (0...4000).map { Self.grownHeight(bit, a, reach * Double($0) / 4000)! }
            func coarse(_ r: Double) -> Double? {
                guard r <= reach else { return nil }
                let x = r / reach * 4000
                let k = min(3999, Int(x))
                return table[k] + (table[k + 1] - table[k]) * (x - Double(k))
            }
            func exact(_ r: Double) -> Double? { Self.grownHeight(bit, a, r) }
            for scene in 0..<25 {
                var triangles: [Double] = []
                for _ in 0..<5 {
                    let centre = SIMD3(rng.next(-reach - 1, reach + 1), rng.next(-reach - 1, reach + 1), rng.next(-3, 3))
                    let size = rng.next(0.5, 2 * reach)
                    for _ in 0..<3 {
                        triangles += [centre.x + rng.next(-size, size), centre.y + rng.next(-size, size), centre.z + rng.next(-size, size)]
                    }
                }
                let cutter = try #require(bit.make(a, triangles))
                let got = cutter.z(at: .zero)
                var want = -Double.infinity
                for t in 0..<5 { want = max(want, Self.sampled(triangles[(t * 9)..<(t * 9 + 9)], coarse: coarse, exact: exact)) }
                guard want > -.infinity else { continue } // nothing sampled in reach
                checked += 1
                #expect(got >= want - 1e-9, "\(bit) allowance \(a) scene \(scene): \(got) cuts below \(want)")
                #expect(got <= want + 1e-3, "\(bit) allowance \(a) scene \(scene): \(got) well above \(want)")
            }
        }
    }

    // MARK: Ball and flat, and the speedups

    static func reliefTriangles() -> [Double] {
        var t: [Double] = []
        let relief = Project.demoRelief().shapes[0]
        relief.forEachModelTriangle { a, b, c in t += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        return t
    }

    /// Pruning by height, binning and hints leave ball and flat results exactly as testing every triangle gives them
    /// (a flat end mill leaving an allowance is dropped as its profile grown by it, and checked as that).
    @Test func ballAndFlatMatchTestingEveryTriangle() throws {
        let triangles = Self.reliefTriangles()
        let count = triangles.count / 9
        let lib = ToolLibrary.starter
        for (tool, a) in [(lib.tool(number: 7)!, 0.0), (lib.tool(number: 7)!, 0.3), (lib.tool(number: 1)!, 0.0), (lib.tool(number: 1)!, 0.2)] {
            let cutter = try #require(TriangleDropCutter(tool: tool, allowance: a, triangles: triangles))
            let grown = tool.shape == .flatEndMill && a > 0
            var kind = TriangleDropCutter.Kind.flat
            if tool.shape == .ballNose { kind = .ball } else if grown { kind = .profile }
            #expect(cutter.kind == kind, "\(tool.name) allowance \(a)")
            var hint: Int32 = -1
            var mismatches = 0
            for k in 0..<400 {
                // A row across the relief, so the hint is usually the right triangle and sometimes not.
                let p = Vec2(25 + Double(k) * 0.31, 70 + 30 * sin(Double(k) / 37))
                var reference = -Double.infinity
                for t in 0..<count {
                    let i = t * 9
                    let A = SIMD3(triangles[i], triangles[i + 1], triangles[i + 2])
                    let B = SIMD3(triangles[i + 3], triangles[i + 4], triangles[i + 5])
                    let C = SIMD3(triangles[i + 6], triangles[i + 7], triangles[i + 8])
                    let v: Double
                    if tool.shape == .ballNose {
                        v = TriangleDropCutter.ballTip(A, B, C, p, radius: tool.radius, allowance: a)
                    } else if grown {
                        v = CutterProfile.flat(radius: tool.radius).grown(by: a).tip(A, B, C, p, normal: TriangleDropCutter.upNormal(A, B, C))
                    } else {
                        v = TriangleDropCutter.flatTip(A, B, C, p, radius: tool.radius, allowance: a)
                    }
                    if v > reference { reference = v }
                }
                let plain = cutter.z(at: p), hinted = cutter.z(at: p, hint: &hint)
                if plain != reference || hinted != reference { mismatches += 1 }
            }
            #expect(mismatches == 0, "\(tool.name) allowance \(a)")
        }
    }

    /// A hint never changes the answer, whichever triangle it names.
    @Test func hintsDontChangeTheAnswer() throws {
        let triangles = Self.reliefTriangles()
        var rng = SplitMix(seed: 3)
        for bit in [Self.bits[0], Self.bits[4]] {
            let cutter = try #require(bit.make(0, triangles))
            for _ in 0..<300 {
                let p = Vec2(rng.next(0, 180), rng.next(0, 130))
                var hint = Int32(rng.next(0, Double(cutter.triangleCount)))
                #expect(cutter.z(at: p, hint: &hint) == cutter.z(at: p), "\(bit) at \(p)")
            }
        }
    }

    /// Profiles: a bull nose with no corner is a flat end mill, one with its corner the whole radius is a ball, and
    /// growing by an allowance keeps the profile joined up and convex.
    @Test func profilesAreJoinedUpAndConvex() {
        let shapes: [CutterProfile] = [
            .vBit(radius: 6.35, tip: 0, halfAngle: .pi / 4), .vBit(radius: 6, tip: 0.5, halfAngle: .pi / 6),
            .bullNose(radius: 3.175, corner: 1), .taperedBall(radius: 3.175, ball: 0.5, halfAngle: 0.15), .ball(radius: 2),
        ]
        for shape in shapes {
            for a in [0.0, 0.25] {
                let g = shape.grown(by: a)
                #expect(abs(g.radius - (shape.radius + a)) < 1e-9)
                #expect(abs(g.minHeight + a) < 1e-9)
                for (p, q) in zip(g.pieces, g.pieces.dropFirst()) {
                    #expect(abs(p.r1 - q.r0) < 1e-9)
                    #expect(abs(p.height(p.r1) - q.height(q.r0)) < 1e-9)
                    #expect(q.slope(q.r0) >= p.slope(p.r1) - 1e-9)
                }
            }
        }
        #expect(CutterProfile.bullNose(radius: 3, corner: 0) == .flat(radius: 3))
        let full = CutterProfile.bullNose(radius: 3, corner: 3)
        for r in stride(from: 0.0, through: 3, by: 0.25) {
            #expect(abs(full.height(r) - CutterProfile.ball(radius: 3).height(r)) < 1e-12)
        }
    }
}

/// A small deterministic random number generator for repeatable tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53) }
}
