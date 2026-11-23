import Foundation
import Testing
@testable import CAMCore

/// Tapered ball nose, form (roundover, cove, ogee, custom) and dovetail bits (#82): their geometry against the
/// circles and cones they're made of, the exact drop onto planes, spheres, cylinders, walls and random triangles, the
/// simulators carving their profiles, and the toolpaths that take or refuse them.
struct BitShapeTests {
    static let cutting = CuttingData(spindleRPM: 18000, feedRate: 2000, plungeRate: 500, stepdown: 3, stepoverFraction: 0.1)

    /// A tapered ball nose like the common 1/32" tip radius, 1.79° per side, 1" flute, 1/4" shank carving bit.
    static func taperedBall(tipRadius: Double = 0.03125.inch, perSide: Double = 1.79, flute: Double = 1.inch,
                            shank: Double = 0.25.inch) -> Tool {
        var t = Tool(number: 60, name: "Tapered ball", shape: .taperedBallNose, diameter: shank, shankDiameter: shank,
                     fluteLength: flute, includedAngle: 2 * perSide, tipDiameter: 2 * tipRadius, cutting: cutting)
        t.fitDiameterToShape()
        return t
    }

    static func form(_ kind: FormProfile.Kind, radius: Double = 6.35, upper: Double = 3.175, pilot: Double = 12.7,
                     flute: Double? = nil, points: [Vec2] = []) -> Tool {
        let f = FormProfile(kind: kind, radius: radius, upperRadius: upper, pilotDiameter: pilot, points: points)
        var t = Tool(number: 61, name: "\(kind.label) bit", shape: .form, fluteDirection: .straight, diameter: 1, shankDiameter: 6.35,
                     fluteLength: flute ?? f.profileHeight + 2, cutting: cutting, form: f)
        t.fitDiameterToShape()
        return t
    }

    static func dovetail(perSide: Double = 14, diameter: Double = 12.7, height: Double = 12.7) -> Tool {
        Tool(number: 62, name: "Dovetail", shape: .dovetail, fluteDirection: .straight, diameter: diameter, shankDiameter: 6.35,
             fluteLength: height, includedAngle: 2 * perSide, cutting: cutting)
    }

    /// A custom profile that narrows above a wide foot (a lollipop-like undercut).
    static let undercutCustom = form(.custom, flute: 8, points: [Vec2(2, 0), Vec2(5, 2), Vec2(3, 5), Vec2(4, 8)])

    // MARK: Geometry

    @Test func taperedBallNoseIsABallRunningIntoACone() throws {
        let t = Self.taperedBall(tipRadius: 0.5, perSide: 5, flute: 20, shank: 6.35)
        let rho = 0.5, a = 5 * Double.pi / 180
        let rt = rho * cos(a), ht = rho * (1 - sin(a))
        #expect(t.geometryProblem == nil)
        // Diameter at the top of the flutes: the cone's there (it hasn't reached the shank yet).
        let top = rt + (20 - ht) * tan(a)
        #expect(abs(t.diameter - 2 * top) < 1e-9)
        for r in stride(from: 0.0, through: top, by: 0.05) {
            let want = r <= rt ? rho - (rho * rho - r * r).squareRoot() : ht + (r - rt) / tan(a)
            let got = try #require(t.profileHeight(atRadius: r))
            #expect(abs(got - want) < 1e-9, "r \(r)")
            #expect(abs(t.radius(atHeight: want) - r) < 1e-7, "h \(want)")
        }
        #expect(t.profileHeight(atRadius: top + 0.01) == nil)
        // Stepover is a share of the tip, the chart's diameter widens with the depth.
        #expect(abs(t.stepoverBasis - 1) < 1e-12 && abs(t.stepover - 0.1) < 1e-12)
        #expect(abs(t.cuttingDiameter(atDepth: 5) - 2 * t.radius(atHeight: 5)) < 1e-12)
        #expect(t.cuttingDiameter(atDepth: 50) == t.diameter)
        // A short taper meets the shank below the top of the flutes: the diameter is the shank's.
        let steep = Self.taperedBall(tipRadius: 0.5, perSide: 15, flute: 20, shank: 6.35)
        #expect(abs(steep.diameter - 6.35) < 1e-9)
        // The drawing runs from the tip up the cone to the shank and up the shank.
        let sil = t.silhouette()
        #expect(sil.first == Vec2(0, 0) && sil.last?.x == t.shankDiameter / 2 && sil.last?.y == t.stickout)
        for (p, q) in zip(sil, sil.dropFirst()) { #expect(q.y >= p.y - 1e-9) }
    }

    /// The presets' cutting edges lie on their circles: a roundover is a concave quarter circle from the pilot out and
    /// up, a cove a convex one, an ogee a cove running into a roundover.
    @Test func formPresetsFollowTheirCircles() throws {
        let p = 6.35, r1 = 6.35, r2 = 3.175
        let round = Self.form(.roundover, radius: r1, pilot: 2 * p)
        let cove = Self.form(.cove, radius: r1, pilot: 2 * p)
        let ogee = Self.form(.ogee, radius: r1, upper: r2, pilot: 2 * p)
        #expect(abs(round.diameter - 2 * (p + r1)) < 1e-9 && abs(ogee.diameter - 2 * (p + r1 + r2)) < 1e-9)
        for t in [round, cove, ogee] { #expect(t.geometryProblem == nil && !t.hasUndercut, "\(t.name)") }
        // Every point of each circle is within the chord tolerance of the edge, and every edge point is on a circle.
        func off(_ q: Vec2, _ edge: [Vec2]) -> Double {
            Polyline(edge, closed: false).closestPoint(to: q).point.distance(to: q)
        }
        let (re, ce, oe) = (round.cuttingEdge, cove.cuttingEdge, ogee.cuttingEdge)
        for i in 0...90 {
            let a = Double(i) * .pi / 180
            let onRound = Vec2(p + r1 - r1 * sin(a), r1 * cos(a))
            let onCove = Vec2(p + r1 * sin(a), r1 - r1 * cos(a))
            let onOgee = Vec2(p + r1 + r2 - r2 * cos(a), r1 + r2 * sin(a))
            #expect(off(onRound, re) < 0.0025, "roundover at \(i)°")
            #expect(off(onCove, ce) < 0.0025, "cove at \(i)°")
            #expect(off(onCove, oe) < 0.0025, "ogee's cove at \(i)°")
            #expect(off(onOgee, oe) < 0.0025, "ogee's roundover at \(i)°")
        }
        for q in re where q.y <= r1 + 1e-9 && q.x > p - 1e-9 {
            #expect(abs(Vec2(p + r1, 0).distance(to: q) - r1) < 1e-9, "roundover edge point \(q)")
        }
        // Above the profile the edge runs straight up to the top of the flutes.
        #expect(abs(round.radius(atHeight: r1 + 1) - (p + r1)) < 1e-9)
        // From below, a cove bit is a bull nose: flat out to the pilot, then its corner.
        for r in stride(from: 0.0, through: p + r1, by: 0.25) {
            let want = r <= p ? 0 : r1 - (max(0, r1 * r1 - (r - p) * (r - p))).squareRoot()
            let got = try #require(cove.profileHeight(atRadius: r))
            #expect(abs(got - want) < 0.03, "cove from below at \(r)")
        }
    }

    @Test func dovetailsNarrowAndOverhang() {
        let t = Self.dovetail(perSide: 14, diameter: 12.7, height: 12.7)
        let k = tan(14 * Double.pi / 180)
        #expect(t.geometryProblem == nil && t.hasUndercut && t.isFlatBottomed)
        #expect(abs(t.dovetailSmallDiameter - (12.7 - 2 * 12.7 * k)) < 1e-9)
        #expect(abs(t.radius(atHeight: 5) - (6.35 - 5 * k)) < 1e-9)
        #expect(t.profileHeight(atRadius: 6) == 0)
        #expect(abs(t.undercut(toDepth: 8) - 8 * k) < 1e-9)
        // Past the flutes the narrower shank overhangs further.
        #expect(abs(t.undercut(toDepth: 20) - (6.35 - 3.175)) < 1e-9)
        #expect(Self.undercutCustom.hasUndercut && Self.undercutCustom.geometryProblem == nil)
        #expect(abs(Self.undercutCustom.undercut(toDepth: 5) - 2) < 1e-9)
        // Too steep for its height: no neck left.
        #expect(Self.dovetail(perSide: 30, diameter: 10, height: 12).geometryProblem != nil)
        var bad = Self.form(.custom, points: [Vec2(2, 0), Vec2(4, 3), Vec2(5, 1)])
        bad.fitDiameterToShape()
        #expect(bad.geometryProblem != nil)
    }

    @Test func sameBitComparesShapeDimensions() {
        let a = Self.taperedBall(), b = Self.taperedBall(perSide: 3)
        #expect(a.isSameBit(as: a) && !a.isSameBit(as: Tool(number: 1, name: "x", shape: .taperedBallNose, diameter: a.diameter,
                                                                fluteLength: a.fluteLength, cutting: Self.cutting)))
        var c = b
        c.id = UUID()
        #expect(!a.isSameBit(as: c) && !a.sameGeometry(as: b))
        let r = Self.form(.roundover), o = Self.form(.cove)
        var r2 = r
        r2.id = UUID()
        #expect(r.isSameBit(as: r2) && r.sameGeometry(as: r2) && !r.isSameBit(as: o))
    }

    // MARK: Dropping

    struct Bit: CustomStringConvertible, Sendable {
        var tool: Tool
        var description: String { tool.name }
        var radius: Double { tool.radius }
    }

    static let ringBits: [Bit] = [
        Bit(tool: form(.roundover, radius: 4, pilot: 3)), Bit(tool: form(.cove, radius: 3, pilot: 4)),
        Bit(tool: form(.ogee, radius: 3, upper: 2, pilot: 2)), Bit(tool: dovetail()), Bit(tool: undercutCustom),
    ]

    /// The lower envelope's height at r, from the cutting edge (independently of the drop-cutter's rings).
    static func envelopeHeight(_ edge: [Vec2], _ r: Double) -> Double { ToolProfile.lowerEnvelope(edge, atRadius: r) }

    /// The most a surface whose height varies along one line through the axis asks the tip to rise: dense samples of
    /// z(ρ) − h(|ρ|) over [from, to] within reach, then zooming in on the best (the profile needn't be convex).
    static func dense(_ h: (Double) -> Double, reach: Double, from: Double, to: Double, _ z: (Double) -> Double) -> Double {
        let lo = max(-reach, from), hi = min(reach, to)
        guard lo <= hi else { return -.infinity }
        var best = -Double.infinity, at = lo
        let n = 20000
        for i in 0...n {
            let rho = lo + (hi - lo) * Double(i) / Double(n)
            let v = z(rho) - h(abs(rho))
            if v > best { best = v; at = rho }
        }
        var span = (hi - lo) / Double(n)
        for _ in 0..<10 {
            let c = at
            for j in -20...20 {
                let rho = min(hi, max(lo, c + span * Double(j) / 20))
                let v = z(rho) - h(abs(rho))
                if v > best { best = v; at = rho }
            }
            span /= 4
        }
        return best
    }

    @Test(arguments: ringBits) func formBitsDropOntoPlanesAndSlopes(_ bit: Bit) throws {
        let edge = bit.tool.cuttingEdge
        for a in [0.0, 0.4] {
            for degrees in [0.0, 20, 45, 70] {
                let slope = tan(degrees * .pi / 180)
                let cutter = try #require(TriangleDropCutter(tool: bit.tool, allowance: a, triangles: DropCutterTests.plane(z0: -5, slope: slope)))
                #expect(cutter.kind == .rings)
                for x in [-7.0, 0, 3.3] {
                    let got = cutter.z(at: Vec2(x, 1.5))
                    let want = Self.dense({ Self.envelopeHeight(edge, $0) }, reach: bit.radius, from: -.infinity, to: .infinity) {
                        -5 + slope * (x + $0)
                    } + a
                    #expect(abs(got - want) < 1e-6, "\(bit) allowance \(a) slope \(degrees)° at x \(x): \(got) vs \(want)")
                }
            }
        }
    }

    @Test(arguments: ringBits) func formBitsDropOntoASphereAndACylinder(_ bit: Bit) throws {
        let edge = bit.tool.cuttingEdge
        func h(_ r: Double) -> Double { Self.envelopeHeight(edge, r) }
        let s = 20.0, c = SIMD3(0.0, 0, -25)
        let ball = DropCutterTests.hemisphere(s, at: c, rings: 90, segments: 360)
        let cutter = try #require(TriangleDropCutter(tool: bit.tool, allowance: 0, triangles: ball.triangles))
        for d in [0.0, 5, 12, 19, 21.5, 24] {
            let got = cutter.z(at: Vec2(d * cos(0.3), d * sin(0.3)))
            func ref(_ s: Double) -> Double {
                Self.dense(h, reach: bit.radius, from: d - s, to: d + s) { c.z + max(0, s * s - (d - $0) * (d - $0)).squareRoot() }
            }
            let high = ref(s), low = ref(s - ball.sag)
            if high == -.infinity {
                #expect(got == -.infinity, "\(bit) sphere at \(d): \(got)")
            } else {
                #expect(got <= high + 1e-6, "\(bit) sphere at \(d): \(got) above \(high)")
                #expect(got >= low - 1e-6, "\(bit) sphere at \(d): \(got) below \(low)")
            }
        }
        let zc = -20.0
        let tube = DropCutterTests.cylinder(15, zc: zc, segments: 360)
        let onTube = try #require(TriangleDropCutter(tool: bit.tool, allowance: 0, triangles: tube.triangles))
        for x in [0.0, 4, 10, 14.5, 17] {
            let got = onTube.z(at: Vec2(x, 3))
            func ref(_ s: Double) -> Double {
                Self.dense(h, reach: bit.radius, from: -x - s, to: -x + s) { zc + max(0, s * s - (x + $0) * (x + $0)).squareRoot() }
            }
            let high = ref(15), low = ref(15 - tube.sag)
            if high == -.infinity {
                #expect(got == -.infinity, "\(bit) cylinder at \(x): \(got)")
            } else {
                #expect(got <= high + 1e-6, "\(bit) cylinder at \(x): \(got) above \(high)")
                #expect(got >= low - 1e-6, "\(bit) cylinder at \(x): \(got) below \(low)")
            }
        }
    }

    /// Beside a vertical wall the profile meets its top edge: tip Z = top − h(distance).
    @Test(arguments: ringBits + [Bit(tool: taperedBall(tipRadius: 0.5, perSide: 5, flute: 20, shank: 6.35))])
    func everyNewShapeDropsBesideAVerticalWall(_ bit: Bit) throws {
        let top = -3.0
        let cutter = try #require(TriangleDropCutter(tool: bit.tool, allowance: 0, triangles: DropCutterTests.block(top: top)))
        let reach = bit.radius
        for d in [reach + 0.5, reach - 0.05, reach * 0.7, reach * 0.3, 0.02, 0, -2, -10] {
            let got = cutter.z(at: Vec2(-d, 0))
            if d > reach {
                #expect(got == -.infinity, "\(bit) at \(d): \(got)")
            } else {
                let want = top - (bit.tool.profileHeight(atRadius: max(0, d)) ?? .infinity)
                #expect(abs(got - want) < 1e-7, "\(bit) at \(d): \(got) vs \(want)")
            }
        }
    }

    /// The most any point of a triangle asks the tip to rise at the origin, by brute force: a dense grid over it, dense
    /// samples along its edges, and round every circle where the profile bends (where a concave profile's peaks can
    /// sit), each point asking z − h(distance).
    static func bruteForce(_ t: ArraySlice<Double>, reach: Double, radii: [Double], _ h: (Double) -> Double) -> Double {
        let i = t.startIndex
        let A = SIMD3(t[i], t[i + 1], t[i + 2]), B = SIMD3(t[i + 3], t[i + 4], t[i + 5]), C = SIMD3(t[i + 6], t[i + 7], t[i + 8])
        var best = -Double.infinity
        func ask(_ q: SIMD3<Double>) {
            let r = (q.x * q.x + q.y * q.y).squareRoot()
            if r <= reach { best = max(best, q.z - h(r)) }
        }
        let n = 150
        for j in 0...n {
            for k in 0...(n - j) { ask(A + Double(j) / Double(n) * (B - A) + Double(k) / Double(n) * (C - A)) }
        }
        for (u, w) in [(A, B), (B, C), (C, A)] {
            for k in 0...4000 { ask(u + Double(k) / 4000 * (w - u)) }
        }
        // Points on circles about the axis inside the triangle (in XY), lifted onto its plane.
        let e1 = B - A, e2 = C - A
        let det = e1.x * e2.y - e1.y * e2.x
        guard abs(det) > 1e-12 else { return best }
        for rho in radii where rho > 0 && rho <= reach {
            for k in 0..<1440 {
                let a = Double(k) / 1440 * 2 * .pi
                let x = rho * cos(a) - A.x, y = rho * sin(a) - A.y
                let s = (x * e2.y - y * e2.x) / det, u = (e1.x * y - e1.y * x) / det
                guard s >= 0, u >= 0, s + u <= 1 else { continue }
                ask(A + s * e1 + u * e2)
            }
        }
        return best
    }

    /// Random triangles: never below what any sampled point asks for, and within a whisker of the most.
    @Test(arguments: ringBits) func formBitsAgreeWithBruteForceOnRandomTriangles(_ bit: Bit) throws {
        let edge = bit.tool.cuttingEdge
        let reach = bit.radius
        let radii = ToolProfile.envelope(edge).map(\.x)
        func h(_ r: Double) -> Double { Self.envelopeHeight(edge, r) }
        var rng = SplitMix(seed: 82)
        var checked = 0
        for scene in 0..<20 {
            var triangles: [Double] = []
            for _ in 0..<4 {
                let centre = SIMD3(rng.next(-reach - 1, reach + 1), rng.next(-reach - 1, reach + 1), rng.next(-3, 3))
                let size = rng.next(0.5, 2 * reach)
                for _ in 0..<3 {
                    triangles += [centre.x + rng.next(-size, size), centre.y + rng.next(-size, size), centre.z + rng.next(-size, size)]
                }
            }
            let cutter = try #require(TriangleDropCutter(tool: bit.tool, allowance: 0, triangles: triangles))
            let got = cutter.z(at: .zero)
            var want = -Double.infinity
            for t in 0..<4 { want = max(want, Self.bruteForce(triangles[(t * 9)..<(t * 9 + 9)], reach: reach, radii: radii, h)) }
            guard want > -.infinity else { continue }
            checked += 1
            #expect(got >= want - 1e-9, "\(bit) scene \(scene): \(got) cuts below \(want)")
            #expect(got <= want + (bit.tool.shape == .dovetail ? 1e-2 : 2e-3), "\(bit) scene \(scene): \(got) well above \(want)")
            // From below a dovetail is a flat bottom: exactly the flat end mill's own test.
            if bit.tool.shape == .dovetail {
                var flat = -Double.infinity
                for t in 0..<4 {
                    let i = t * 9
                    flat = max(flat, TriangleDropCutter.flatTip(SIMD3(triangles[i], triangles[i + 1], triangles[i + 2]),
                                                                SIMD3(triangles[i + 3], triangles[i + 4], triangles[i + 5]),
                                                                SIMD3(triangles[i + 6], triangles[i + 7], triangles[i + 8]),
                                                                .zero, radius: reach, allowance: 0))
                }
                #expect(abs(got - flat) < 1e-9, "\(bit) scene \(scene): \(got) vs flat \(flat)")
            }
        }
        #expect(checked >= 10, "\(bit): only \(checked) scenes in reach")
    }

    // MARK: Simulation

    static let simStock = Stock(width: 60, height: 60, thickness: 30)

    /// A plunge stamps the bit's profile from below; a level move sweeps it.
    @Test(arguments: ringBits + [Bit(tool: taperedBall(tipRadius: 0.5, perSide: 5, flute: 20, shank: 6.35))])
    func theSimulatorCarvesEachProfile(_ bit: Bit) throws {
        let t = bit.tool
        let depth = 6.0
        var sim = MaterialSimulator(stock: Self.simStock, cellSize: 0.1)
        let c = Vec2(20, 30)
        sim.apply(.feed(Vec3(c, -depth), 500), from: Vec3(c, 5), tool: t)
        sim.apply(.feed(Vec3(c.x + 15, c.y, -depth), 500), from: Vec3(c, -depth), tool: t)
        var worst = 0.0
        var worstAt = Vec2.zero
        let g = sim.grid
        for row in 0..<g.rows {
            for col in 0..<g.columns {
                let p = Vec2(g.origin.x + Double(col) * g.cellSize, g.origin.y + Double(row) * g.cellSize)
                // Distance to the swept segment.
                let x = min(max(p.x, c.x), c.x + 15)
                let d = Vec2(x, c.y).distance(to: p)
                // Allow for the profile's steep parts: anywhere it reaches within a few microns sideways.
                func want(_ d: Double) -> Double {
                    d <= t.radius ? min(0, -depth + (t.profileHeight(atRadius: max(0, d)) ?? 0)) : 0
                }
                let got = Double(g.heights[g.index(col, row)])
                let range = [-0.03, -0.015, 0, 0.015, 0.03].map { want(d + $0) }
                let err = max(0, range.min()! - got, got - range.max()!)
                if err > worst { worst = err; worstAt = p }
            }
        }
        // Float heights, and the table for form bits: within a few microns of the profile, measured sideways or up.
        #expect(worst < 0.01, "\(bit) off by \(worst) at \(worstAt)")
    }

    /// The radial simulator stamps the same profile on a rotary blank, measured out from the axis.
    @Test func theRadialSimulatorCarvesADovetailAndATaperedBall() throws {
        var stock = Stock()
        stock.setRotary(RotaryStock(shape: .cylinder, diameter: 50, length: 100))
        for t in [Self.dovetail(perSide: 10, diameter: 8, height: 8), Self.taperedBall(tipRadius: 1, perSide: 10, flute: 15, shank: 8)] {
            var sim = RadialSimulator(stock: stock, cellSize: 0.1)
            let y0 = sim.grid.centerY
            sim.apply(.feed(Vec3(50, y0, -3), 500), from: Vec3(50, y0, 5), tool: t)
            for d in [0.0, 0.5, 1.5, 2.5, 3.5] {
                let got = try #require(sim.grid.radius(at: 50 + d, angle: 0))
                let want = min(25, 22 + (t.profileHeight(atRadius: d) ?? .infinity))
                #expect(abs(Double(got) - want) < 0.05, "\(t.name) at \(d): \(got) vs \(want)")
            }
        }
    }

    // MARK: 3D

    /// Finishing the demo relief with a tapered ball nose (after its end-mill roughing) never cuts into the model.
    @Test func aTaperedBallFinishOnTheDemoReliefDoesntGouge() throws {
        var p = Project.demoRelief()
        let tb = Self.taperedBall()
        for i in p.operations.indices {
            guard case var .finish3D(f) = p.operations[i].kind else { continue }
            f.stepoverFraction = 0.4
            p.operations[i].kind = .finish3D(f)
            p.operations[i].tool = tb
        }
        // Not the cut-out: only the relief is compared.
        p.operations.removeAll { if case .profile = $0.kind { return true } else { return false } }
        #expect(p.formatVersion == 14)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let finish = try #require(job.toolpaths.first { $0.tool.shape == .taperedBallNose })
        #expect(!finish.motions.isEmpty)
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 10000, cellSize: 0.3)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        let grid = s.grid
        // The model's height at each cell centre: a hair-thin flat end mill dropped on it.
        var probe = Tool(number: 99, name: "probe", shape: .flatEndMill, diameter: 0.002, fluteLength: 50, cutting: Self.cutting)
        probe.shankDiameter = 0.002
        let model = try #require(TriangleDropCutter(tool: probe, allowance: 0, triangles: DropCutterTests.reliefTriangles()))
        var gouge = 0.0, compared = 0
        var worstAt = Vec2.zero
        for row in stride(from: 0, to: grid.rows, by: 2) {
            for col in stride(from: 0, to: grid.columns, by: 2) {
                let q = Vec2(grid.origin.x + Double(col) * grid.cellSize, grid.origin.y + Double(row) * grid.cellSize)
                let m = model.z(at: q)
                guard m.isFinite else { continue }
                compared += 1
                let h = Double(grid.heights[grid.index(col, row)])
                if m - h > gouge { gouge = m - h; worstAt = q }
            }
        }
        #expect(compared > 1000)
        #expect(gouge < 0.08, "gouged \(gouge) mm at \(worstAt)")
    }

    // MARK: Toolpaths

    static func square(_ side: Double = 40, at o: Vec2 = Vec2(30, 30)) -> DesignShape {
        DesignShape(name: "Square", kind: .rectangle(width: side, height: side, cornerRadius: 0), position: o)
    }

    static func project(_ shapes: [DesignShape], _ ops: [CAMOperation]) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputArcs = false
        return Project(name: "Bits", displayUnits: .mm, stock: Stock(width: 100, height: 100, thickness: 25), machine: machine,
                       shapes: shapes, operations: ops)
    }

    static func profile(_ side: CutSide, depth: Double, tabs: Bool = false, ramp: Bool = false) -> OperationKind {
        var p = ProfileParams(side: side, depth: DepthSettings(startDepth: 0, cutDepth: depth))
        p.tabs.enabled = tabs
        if ramp { p.entry = EntrySettings(kind: .ramp, rampLength: 10) }
        return .profile(p)
    }

    /// A roundover rides the line with its pilot and steps down as usual.
    @Test func aRoundoverProfileRidesTheLineWithItsPilot() throws {
        let shape = Self.square()
        let bit = Self.form(.roundover, radius: 6.35, pilot: 12.7)
        let op = CAMOperation(kind: Self.profile(.outside, depth: 6.35), shapeIDs: [shape.id], tool: bit)
        let p = Self.project([shape], [op])
        #expect(p.formatVersion == 14)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        let ext = try #require(tp.cuttingExtents)
        // The square spans 10–50; the pilot's radius (6.35) out from it.
        #expect(abs(ext.min.x - (10 - 6.35)) < 0.02 && abs(ext.max.x - (50 + 6.35)) < 0.02)
        #expect(abs(ext.min.z + 6.35) < 1e-9)
        var levels = Set<Double>()
        tp.forEachMotion { _, m in if m.kind != .rapid { levels.insert((m.end.z * 1000).rounded() / 1000) } }
        #expect(levels.count >= 3) // 3 mm stepdown: three passes
    }

    /// A dovetail cuts once at full depth, comes in and leaves square to the wall from far enough off it to lift out,
    /// and drops ramps and tabs.
    @Test func aDovetailCutsOnceAndLeavesSquareToTheWall() throws {
        let shape = Self.square()
        let bit = Self.dovetail(perSide: 14, diameter: 12.7, height: 12.7)
        let depth = 10.0
        let op = CAMOperation(kind: Self.profile(.outside, depth: depth, tabs: true, ramp: true), shapeIDs: [shape.id], tool: bit)
        let tp = try #require(CAMEngine.generate(Self.project([shape], [op])).toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("can't ramp") })
        #expect(tp.warnings.contains { $0.contains("tabs were left off") })
        #expect(tp.warnings.contains { $0.contains("one pass at full depth") })
        // Every cutting move below the top is at full depth (no steps, no ramps, no tabs).
        var depths = Set<Double>()
        var lifts: [Vec2] = []
        var plunges: [Vec2] = []
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            if s.xy.distance(to: m.end.xy) > 1e-6 { depths.insert((m.end.z * 1e6).rounded() / 1e6) }
            if m.end.z > s.z + 1e-6, s.z < -1e-6 { lifts.append(s.xy) }
            if m.end.z < s.z - 1e-6, m.end.z < -1e-6 { plunges.append(m.end.xy) }
        }
        tp.forEachMotion { s, m in
            if m.kind == .rapid, m.end.z > s.z + 1e-6, s.z < -1e-6 { lifts.append(s.xy) }
        }
        #expect(depths == [-depth])
        #expect(!lifts.isEmpty && !plunges.isEmpty)
        // Where it lifts out and plunges in, the bit is at least its undercut (plus spare) further off the part than
        // when cutting: the tool centre is 6.35 + undercut from the square.
        let need = 6.35 + bit.undercut(toDepth: depth)
        let square = Polyline([Vec2(10, 10), Vec2(50, 10), Vec2(50, 50), Vec2(10, 50)], closed: true)
        for q in lifts + plunges {
            let off = square.closestPoint(to: q).point.distance(to: q)
            #expect(off >= need - 1e-6, "lifts or plunges \(off) from the part, needs \(need)")
        }
        var s = SimulationSession(toolpaths: [tp], stock: Self.project([shape], [op]).stock, rapidRate: 10000, cellSize: 0.5)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
    }

    /// On the line a dovetail only cuts a slot whose ends are off the material.
    @Test func aDovetailOnTheLineNeedsBothEndsOffTheMaterial() throws {
        let across = DesignShape(name: "Slot", kind: .paths([Polyline([Vec2(-10, 50), Vec2(110, 50)], closed: false)]), position: .zero)
        let short = DesignShape(name: "Short", kind: .paths([Polyline([Vec2(20, 20), Vec2(80, 20)], closed: false)]), position: .zero)
        let ring = Self.square(20, at: Vec2(70, 70))
        let op = CAMOperation(kind: Self.profile(.on, depth: 8), shapeIDs: [across.id, short.id, ring.id], tool: Self.dovetail())
        let tp = try #require(CAMEngine.generate(Self.project([across, short, ring], [op])).toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("2 vectors were skipped") })
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.min.y - 50) < 1e-6 && abs(ext.max.y - 50) < 1e-6)
    }

    /// Toolpaths that can't use a shape say why and cut nothing; the ones that can, do.
    @Test func toolpathsRefuseShapesTheyCantUse() throws {
        let shape = Self.square()
        let pocket = OperationKind.pocket(PocketParams(depth: DepthSettings(startDepth: 0, cutDepth: 5)))
        let cases: [(OperationKind, Tool, Bool)] = [
            (pocket, Self.form(.roundover), false),
            (pocket, Self.taperedBall(), false),
            (pocket, Self.dovetail(), false),
            (.vcarve(VCarveParams()), Self.taperedBall(), false),
            (.finish3D(Finish3DParams()), Self.dovetail(), false),
            (.rough3D(Rough3DParams()), Self.form(.cove), false),
            (.fluting(FlutingParams(depth: 2)), Self.taperedBall(), true),
            (Self.profile(.on, depth: 2), Self.taperedBall(), true),
            (Self.profile(.inside, depth: 6), Self.form(.cove, radius: 3, pilot: 4), true),
        ]
        for (kind, tool, cuts) in cases {
            let op = CAMOperation(kind: kind, shapeIDs: [shape.id], tool: tool)
            let refusal = op.toolRefusal
            #expect((refusal == nil) == cuts, "\(kind.label) with \(tool.name): \(refusal ?? "accepted")")
            let tps = CAMEngine.generate(Self.project([shape], [op])).toolpaths
            let empty = tps.allSatisfy { $0.motions.isEmpty }
            #expect(empty != cuts, "\(kind.label) with \(tool.name)")
            if let refusal { #expect(tps.contains { $0.warnings.contains(refusal) }) }
        }
        // A dovetail with no neck is refused everywhere, saying what's wrong.
        let bad = CAMOperation(kind: Self.profile(.outside, depth: 5), shapeIDs: [shape.id], tool: Self.dovetail(perSide: 30, diameter: 10, height: 12))
        #expect(bad.toolRefusal?.contains("narrows to nothing") == true)
        // A V-carve's flat-area clearance tool can't be a form bit.
        var v = VCarveParams(flatDepth: 3)
        v.clearanceTool = Self.form(.roundover)
        let carve = CAMOperation(kind: .vcarve(v), shapeIDs: [shape.id], tool: ToolLibrary.starter.tool(number: 6)!)
        #expect(carve.toolRefusal?.contains("clearance tool") == true)
    }

    /// The chip-load chart is read at the diameter that cuts: a tapered ball nose's at its depth.
    @Test func chipLoadUsesTheDiameterAtTheCuttingDepth() {
        let t = Self.taperedBall()
        let d = ChipLoad.chartDiameter(t, depth: 3)
        #expect(abs(d - 2 * t.radius(atHeight: 3)) < 1e-12 && d < t.diameter)
        #expect(ChipLoad.chartDiameter(t, depth: nil) == t.diameter)
        #expect(ChipLoad.chartDiameter(ToolLibrary.starter.tool(number: 7)!, depth: 3) == 0.25.inch)
        let dt = Self.dovetail()
        #expect(ChipLoad.chartDiameter(dt, depth: 4) == dt.diameter)
        #expect(ChipLoad.applies(to: t) && ChipLoad.applies(to: dt))
    }

    // MARK: File format

    /// The project these shapes take: format 14 only when a toolpath uses one, and it reads back the same.
    static func savedBits() -> Project {
        let square = DesignShape(id: UUID(uuidString: "B1750000-0000-4000-8000-000000000001")!, name: "Square",
                                 kind: .rectangle(width: 40, height: 40, cornerRadius: 0), position: Vec2(30, 30))
        let line = DesignShape(id: UUID(uuidString: "B1750000-0000-4000-8000-000000000002")!, name: "Flute",
                               kind: .paths([Polyline([Vec2(15, 80), Vec2(85, 80)], closed: false)]), position: .zero)
        var round = form(.roundover, radius: 6.35, pilot: 12.7)
        round.id = UUID(uuidString: "B1750000-0000-4000-8000-000000000011")!
        round.number = 11
        var tail = dovetail()
        tail.id = UUID(uuidString: "B1750000-0000-4000-8000-000000000012")!
        tail.number = 12
        var tb = taperedBall()
        tb.id = UUID(uuidString: "B1750000-0000-4000-8000-000000000013")!
        tb.number = 13
        var ogee = form(.ogee, radius: 4, upper: 3, pilot: 6)
        ogee.id = UUID(uuidString: "B1750000-0000-4000-8000-000000000014")!
        ogee.number = 14
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "B1750000-0000-4000-8000-%012d", 100 + n))! }
        let ops = [
            CAMOperation(id: id(1), name: "Flute", kind: .fluting(FlutingParams(depth: 2)), shapeIDs: [line.id], tool: tb),
            CAMOperation(id: id(2), name: "Dovetail pin", kind: profile(.outside, depth: 10), shapeIDs: [square.id], tool: tail),
            CAMOperation(id: id(3), name: "Round over", kind: profile(.outside, depth: 6.35), shapeIDs: [square.id], tool: round),
            CAMOperation(id: id(4), name: "Ogee", enabled: false, kind: profile(.outside, depth: 7), shapeIDs: [square.id], tool: ogee),
        ]
        return project([square, line], ops)
    }

    @Test func newShapesTakeFormat14OnlyWhenUsedAndRoundTrip() throws {
        let p = Self.savedBits()
        #expect(p.formatVersion == 14)
        let back = try Project.decode(p.encoded())
        #expect(back == p)
        #expect(back.operations.map(\.tool) == p.operations.map(\.tool))
        // Without them the file stays as old as it was, and old tools encode exactly as before (no "form" key).
        #expect(Project.demoSign().formatVersion == 1)
        let json = try String(decoding: JSONEncoder().encode(ToolLibrary.starter.tools[0]), as: UTF8.self)
        #expect(!json.contains("form"))
        // A pocket whose clearance tool is a new shape needs the new format too.
        var pp = PocketParams(depth: DepthSettings(startDepth: 0, cutDepth: 3))
        pp.clearanceTool = Self.dovetail()
        #expect(CAMOperation(kind: .pocket(pp), shapeIDs: [], tool: ToolLibrary.starter.tool(number: 2)!).requiredFormatVersion == 14)
    }

    @Test func bitShapesSavedByFormat14StillDecodeAndPost() throws {
        let p = try GoldenPostTests.savedProject("bit-shapes-v14", make: Self.savedBits)
        #expect(p.formatVersion == 14)
        let made = Self.savedBits()
        #expect(p.operations == made.operations)
        #expect(p.shapes == made.shapes)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        try GoldenPostTests.check(GoldenPostTests.post(p), golden: "decoded-bit-shapes-v14")
    }
}
