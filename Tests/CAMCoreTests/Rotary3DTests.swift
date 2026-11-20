import Foundation
import simd
import Testing
@testable import CAMCore

/// R3, 3D rotary finishing: a model laid along the rotation axis, finished all the way round as the blank turns
/// (research_notes/Rotary milling/rotary_milling.md §2.2, §2.3, §4 and §5.3).
struct Rotary3DTests {
    static let lib = ToolLibrary.starter
    static let ball = lib.tool(number: 7)!

    /// r(x) of the turned test part, mm from the axis, for x from 0 to 100 along it.
    static func wave(_ x: Double) -> Double { 15 + 5 * sin(2 * .pi * x / 40) }

    /// The part's surface with `allowance` left on it, mm from the axis: the allowance is measured square to the
    /// surface, so on a slope it reaches allowance × √(1 + r′²) out from the axis.
    static func wave(_ x: Double, allowance a: Double) -> Double {
        let slope = 5 * 2 * .pi / 40 * cos(2 * .pi * x / 40)
        return wave(x) + a * (1 + slope * slope).squareRoot()
    }

    /// A surface of revolution with profile `r` over `length`, as a mesh along its X axis.
    static func turned(_ r: (Double) -> Double, length: Double, samples: Int, segments: Int) -> MeshModel {
        let profile = (0...samples).map { i -> (x: Double, r: Double) in
            let x = length * Double(i) / Double(samples)
            return (x, r(x))
        }
        return MeshModel.revolved(name: "Turned", profile: profile, segments: segments)
    }

    /// A rotary job in mm on Avid's Mach4 profile: `mesh` along X in the middle of a round blank, finished with the 1/4"
    /// ball nose.
    static func job(mesh: MeshModel, blank: RotaryStock = RotaryStock(diameter: 50, length: 140),
                    params: RotaryFinishParams = RotaryFinishParams(), tool: Tool = ball,
                    _ configure: (inout Project) -> Void = { _ in }) -> Project {
        var stock = Stock(materialName: "Maple", materialKind: .hardwood)
        stock.setRotary(blank)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 100)
        machine.outputUnits = .mm
        let spec = ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(alongAxis: .x))
        let shape = DesignShape(name: "Part", kind: .model(spec), position: Vec2(blank.length / 2, stock.height / 2))
        let op = CAMOperation(name: "Finish", kind: .rotaryFinish(params), shapeIDs: [shape.id], tool: tool)
        var p = Project(name: "Rotary finish", displayUnits: .mm, stock: stock, machine: machine, shapes: [shape], operations: [op])
        configure(&p)
        return p
    }

    static func waveJob(_ params: RotaryFinishParams = RotaryFinishParams(allowance: 0.25), segments: Int = 256) -> Project {
        job(mesh: turned(wave, length: 100, samples: 400, segments: segments), params: params)
    }

    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }
    func messages(_ job: JobResult, _ severity: Severity) -> [String] { job.issues.filter { $0.severity == severity }.map(\.message) }

    /// The feed moves of a wrapped toolpath as (x, angle in radians, radius from the axis).
    func polar(_ tp: Toolpath, stock: Stock) -> [(x: Double, a: Double, r: Double, feed: Double)] {
        let top = stock.topRadius ?? 0, cy = stock.originPoint.y
        return tp.motions.filter { $0.kind == .feed }.map { ($0.end.x, ($0.end.y - cy) / top, top + $0.end.z, $0.feed) }
    }

    /// How far the simulated surface is outside (+) and inside (−) the part with its allowance, at every angle,
    /// between `from` and `to` along the part (which starts 20 mm along the blank), and the mean outside per row.
    func deviation(_ g: RadialGrid, allowance: Double, from: Double = 25, to: Double = 95) -> (inside: Double, outside: Double, rows: [Double]) {
        var inside = 0.0, outside = 0.0
        var rows = [Double](repeating: 0, count: g.rows)
        for j in 0..<g.rows {
            var n = 0
            for c in 0..<g.columns {
                let x = g.originX + Double(c) * g.cellSize - 20
                guard x >= from, x <= to else { continue }
                let d = Double(g.radii[j * g.columns + c]) - Self.wave(x, allowance: allowance)
                inside = max(inside, -d)
                outside = max(outside, d)
                rows[j] += d
                n += 1
            }
            rows[j] /= Double(max(n, 1))
        }
        return (inside, outside, rows)
    }

    // MARK: Placement

    /// A box 40 long in Y, 10 in X, 6 in Z.
    static func box() -> MeshModel { cuboids([(SIMD3(0, 0, 0), SIMD3(10, 40, 6))]) }

    /// Boxes from `lo` to `hi`, 12 triangles each, facing out.
    static func cuboids(_ boxes: [(lo: SIMD3<Float>, hi: SIMD3<Float>)]) -> MeshModel {
        var pos: [Float] = [], idx: [UInt32] = []
        let faces: [[Int]] = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [2, 3, 7], [2, 7, 6], [1, 2, 6], [1, 6, 5], [0, 4, 7], [0, 7, 3]]
        for (lo, hi) in boxes {
            let n = UInt32(pos.count / 3)
            let c: [SIMD3<Float>] = [SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
                                     SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z)]
            pos += c.flatMap { [$0.x, $0.y, $0.z] }
            idx += faces.flatMap { $0.map { UInt32($0) + n } }
        }
        return MeshModel(name: "Boxes", positions: pos, indices: idx)
    }

    @Test func aModelLiesAlongTheAxisCentredOnIt() {
        let mesh = Self.box()
        // Its longest axis (Y) along the blank by default.
        #expect(RotaryPlacement(longestOf: mesh).alongAxis == .y)
        for along in UpAxis.allCases {
            let m = ModelGeometry.rotary(mesh, placement: RotaryPlacement(alongAxis: along))
            let expected: Float = along == .x ? 10 : (along == .y ? 40 : 6)
            #expect(abs(m.length - expected) < 1e-4)
            // Centred along its length and on the axis.
            let xs = m.positions.map(\.x), ys = m.positions.map(\.y), zs = m.positions.map(\.z)
            #expect(abs(xs.min()! + xs.max()!) < 1e-4 && abs(ys.min()! + ys.max()!) < 1e-4 && abs(zs.min()! + zs.max()!) < 1e-4)
        }
        // Along Y, the cross-section is 6 (Z) by 10 (X): the far corner is √(3² + 5²) out.
        let m = ModelGeometry.rotary(mesh, placement: RotaryPlacement(alongAxis: .y))
        #expect(abs(Double(m.maxRadius) - (34.0).squareRoot()) < 1e-4)
        #expect(m.profile.allSatisfy { abs(Double($0) - (34.0).squareRoot()) < 1e-3 })
        // Placed on a shape: scaled, turned and moved along the blank.
        var spec = ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(alongAxis: .y, turn: 90))
        var shape = DesignShape(kind: .model(spec), position: Vec2(100, 0), scale: 2)
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        shape.forEachBlankTriangle { a, b, c in
            for p in [a, b, c] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        }
        #expect(abs(lo.x - 60) < 1e-6 && abs(hi.x - 140) < 1e-6)
        // Along Y the model's own Z (6 tall) is the blank's y and its X (10) the blank's z; turned 90° the 10 lies
        // along y: z → −y.
        #expect(abs(hi.y - lo.y - 20) < 1e-5 && abs(hi.z - lo.z - 12) < 1e-5)
        let e = shape.rotaryExtent!
        #expect(abs(e.minX - 60) < 1e-6 && abs(e.maxX - 140) < 1e-6 && abs(e.radius - 2 * (34.0).squareRoot()) < 1e-4)
        // End for end keeps it on the axis and the same length.
        spec.rotary?.reversed = true
        shape.kind = .model(spec)
        #expect(abs(shape.rotaryExtent!.maxX - 140) < 1e-6)
        // Its outline on the sheet is the side view: as long as the model, as wide as it reaches round the axis.
        let b = shape.bounds
        #expect(abs(b.width - 80) < 0.1 && abs(b.height - 4 * (34.0).squareRoot()) < 0.1)
    }

    @Test func placingModelsOnABlankFitsThemAndIsFormatSeven() throws {
        var p = Project(displayUnits: .mm)
        let flat = ModelSpec(mesh: Self.box(), depth: 5)
        p.shapes = [DesignShape(kind: .model(flat), position: Vec2(50, 50), rotation: 30)]
        #expect(p.formatVersion == 1)
        p.stock.setRotary(RotaryStock(diameter: 50, length: 300))
        p.placeModelsOnBlank()
        let shape = p.shapes[0]
        let spec = try #require(shape.modelSpec)
        #expect(spec.rotary?.alongAxis == .y)
        #expect(shape.position.x == 150 && shape.position.y == p.stock.height / 2 && shape.rotation == 0)
        // As wide as the blank is round (it's short, so the diameter decides).
        let e = try #require(shape.rotaryExtent)
        #expect(abs(e.radius - 25) < 1e-6)
        #expect(p.formatVersion == 7)
        // A long model is fitted to the blank's length less the clearance at each end.
        let long = RotaryPlacement.fitScale(ModelGeometry.rotary(Self.box(), placement: RotaryPlacement(alongAxis: .y)),
                                            blank: RotaryStock(diameter: 200, length: 30))
        #expect(abs(long * 40 - (30 - 2 * RotaryPlacement.endClearance)) < 1e-9)
        // Back on a flat sheet it lies flat again, and the file goes back to format 3 (rotary stock, no rotary model).
        p.stock.setRotary(nil)
        p.placeModelsOnBlank()
        #expect(p.shapes[0].modelSpec?.rotary == nil)
    }

    // MARK: Drop-cutter

    /// On a cylinder of radius ρ a ball sits with its tip on the surface at every angle: r_tip = ρ (less the faceting),
    /// and a flat end mill of radius R sits on the facets' highest points across its width.
    @Test func theDropCutterSitsOnACylinderAtEveryAngle() throws {
        let mesh = Self.turned({ _ in 12 }, length: 60, samples: 60, segments: 720)
        var triangles: [Double] = []
        let shape = DesignShape(kind: .model(ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement())), position: Vec2(30, 0))
        shape.forEachBlankTriangle { a, b, c in triangles += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        let cutter = try #require(RotaryDropCutter(tool: Self.ball, allowance: 0.5, triangles: triangles))
        let facet = 12 * (1 - cos(Double.pi / 720))
        for k in 0..<36 {
            let a = Double(k) * 10 * .pi / 180 + 0.01
            let r = cutter.tipRadius(x: 30, angle: a)
            #expect(r <= 12.5 + 1e-9 && r >= 12.5 - facet - 1e-9, "\(r)")
            // Any number of turns round is the same direction.
            #expect(abs(cutter.tipRadius(x: 30, angle: a + 6 * .pi) - r) < 1e-9)
        }
        // Beyond the ends, nothing is in reach.
        #expect(cutter.tipRadius(x: 30 + 30 + Self.ball.radius + 1, angle: 0) == -.infinity)
        // A ray from the axis crosses a solid cylinder once.
        let probe = try #require(RotaryDropCutter(probe: triangles))
        let hit = probe.crossings(x: 30, angle: 1)
        #expect(hit.count == 1 && abs((hit.outer ?? 0) - 12) < facet + 1e-9)
    }

    /// The rotary drop-cutter agrees with turning the mesh by hand and running the 3-axis one at y = 0.
    @Test func itMatchesTheFlatDropCutterOnTheTurnedMesh() throws {
        let mesh = MeshModel.revolved(name: "Pawn", profile: MeshModel.pawnProfile(samples: 120), segments: 40)
        var triangles: [Double] = []
        let spec = ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(turn: 7))
        DesignShape(kind: .model(spec), position: Vec2(60, 0), scale: 1.1).forEachBlankTriangle { a, b, c in
            triangles += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]
        }
        let rotary = try #require(RotaryDropCutter(tool: Self.ball, allowance: 0.1, triangles: triangles))
        for angle in [0.0, 0.7, 2.0, -2.9, 4.4] {
            let c = cos(angle), s = sin(angle)
            var turned = triangles
            for i in stride(from: 0, to: turned.count, by: 3) {
                let y = triangles[i + 1], z = triangles[i + 2]
                turned[i + 1] = y * c - z * s
                turned[i + 2] = y * s + z * c
            }
            let flat = try #require(TriangleDropCutter(tool: Self.ball, allowance: 0.1, triangles: turned))
            for x in stride(from: 10.0, through: 110, by: 3.7) {
                let a = rotary.tipRadius(x: x, angle: angle), b = flat.z(at: Vec2(x, 0))
                #expect(abs(a - b) < 1e-9 || (a == -.infinity && b < 0), "x \(x) angle \(angle): \(a) vs \(b)")
            }
        }
    }

    // MARK: The turned profile

    /// Acceptance: a part with an analytic profile r(x), finished from a round blank (layers, then the finish).
    /// Simulated, every angle comes out at r(x) + allowance within a scallop, and nowhere inside it.
    @Test func aTurnedProfileComesOutTrueAllTheWayRound() throws {
        let p = Self.waveJob()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.wrapDiameter == 50)
        // From 25 mm round in to 10 mm, 3.175 mm a layer: the finish follows four layers.
        let radii = polar(tp, stock: p.stock).map(\.r)
        for layer in 1...4 {
            let rho = 25 - Double(layer) * Self.ball.cutting.stepdown
            #expect(radii.contains { abs($0 - rho) < 1e-6 }, "layer at \(rho)")
        }
        #expect(!radii.contains { abs($0 - (25 - 5 * Self.ball.cutting.stepdown)) < 1e-6 })
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.25)
        s.runToEnd()
        let g = try #require(s.radialGrid)
        let d = deviation(g, allowance: 0.25)
        // Inside: the mesh's facets (0.0015 mm at 20 mm) and the simulation's own sampling. Outside: the scallops between
        // turns, 0.016 mm on a level surface at this stepover, up to about 0.035 mm from the axis on the slopes (where
        // the turns land farther apart along the surface) and in the hollows (where the ball's contact moves farther
        // than its centre).
        #expect(d.inside < 0.02, "gouge \(d.inside)")
        #expect(d.outside < 0.05, "left \(d.outside)")
        #expect(s.rapidCollisions.isEmpty)
    }

    /// A spiral has no seam: the rows of the simulation either side of A0, where it starts, come out like every other.
    /// Rings step along the blank at their start angle, which shows there.
    @Test func theSpiralHasNoSeamAndRingsAndLinesFinishToo() throws {
        func rows(_ pattern: RotaryFinishParams.Pattern) throws -> (seam: Double, rest: Double, inside: Double) {
            let p = Self.waveJob(RotaryFinishParams(pattern: pattern, stepoverFraction: 0.2, allowance: 0.25, passDepth: 20), segments: 192)
            let job = CAMEngine.generate(p)
            #expect(!job.hasErrors, "\(messages(job, .error))")
            var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.25)
            s.runToEnd()
            let g = try #require(s.radialGrid)
            let d = deviation(g, allowance: 0.25)
            let near = (0..<g.rows).filter { abs(g.angle(row: $0)) < 0.6 * .pi / 180 }
            let far = (0..<g.rows).filter { abs(g.angle(row: $0)) > 10 * .pi / 180 }
            let mean = { (rs: [Int]) in rs.map { d.rows[$0] }.reduce(0, +) / Double(rs.count) }
            return (mean(near), mean(far), d.inside)
        }
        let spiral = try rows(.spiral)
        #expect(abs(spiral.seam - spiral.rest) < 0.002, "\(spiral)")
        #expect(spiral.inside < 0.02)
        let rings = try rows(.rings)
        #expect(rings.inside < 0.02)
        #expect(rings.rest - rings.seam > 0.01, "\(rings)")
        let lines = try rows(.lines)
        #expect(lines.inside < 0.02, "\(lines)")
    }

    // MARK: Patterns

    /// A shallow cylinder-ish part (no layers), to look at one finishing pass on its own.
    static func shallow(_ pattern: RotaryFinishParams.Pattern, _ configure: (inout Project) -> Void = { _ in }) -> Project {
        job(mesh: turned({ 19 + 0.5 * sin($0 / 5) }, length: 60, samples: 120, segments: 180),
            blank: RotaryStock(diameter: 42, length: 100), params: RotaryFinishParams(pattern: pattern, stepoverFraction: 0.25)) { p in
            // Slow enough for the rotary to keep up at this radius, so only the A-rate test sees the clamp.
            p.operations[0].tool.cutting.feedRate = 1500
            configure(&p)
        }
    }

    @Test func eachPatternMovesAsDescribed() throws {
        let s = 0.25 * Self.ball.diameter
        // Spiral: A only ever increases; a full turn at the start, then X advances a stepover per turn, then a full turn.
        do {
            let p = Self.shallow(.spiral)
            let tp = try #require(CAMEngine.generate(p).toolpaths.first)
            let c = polar(tp, stock: p.stock)
            #expect(zip(c, c.dropFirst()).allSatisfy { $1.a >= $0.a - 1e-9 && $1.x >= $0.x - 1e-9 })
            let x0 = try #require(c.first?.x), x1 = try #require(c.last?.x)
            #expect(abs(x0 - 20) < 1e-6 && abs(x1 - 80) < 1e-6)
            // Moves within the tolerance of one line are joined, so the end turns can take in the first and last few
            // thousandths of the helix.
            let helix = c.filter { $0.x > x0 + 0.01 && $0.x < x1 - 0.01 }
            for (a, b) in zip(helix, helix.dropFirst()) {
                #expect(abs((b.x - a.x) / (b.a - a.a) * 2 * .pi - s) < s * 0.01, "pitch")
            }
            let first = c.filter { abs($0.x - x0) < 0.01 }.map(\.a), last = c.filter { abs($0.x - x1) < 0.01 }.map(\.a)
            #expect(first.max()! - first.min()! >= 2 * .pi - 0.02 && last.max()! - last.min()! >= 2 * .pi - 0.02)
        }
        // Rings: full turns at fixed X a stepover apart, stepping along the blank at the start angle.
        do {
            let p = Self.shallow(.rings)
            let tp = try #require(CAMEngine.generate(p).toolpaths.first)
            let c = polar(tp, stock: p.stock)
            #expect(zip(c, c.dropFirst()).allSatisfy { $1.a >= $0.a - 1e-9 })
            let stations = Array(Set(c.map { ($0.x * 1e6).rounded() / 1e6 })).sorted()
            let rings = stations.filter { x in
                let a = c.filter { abs($0.x - x) < 1e-6 }.map(\.a)
                return a.max()! - a.min()! >= 2 * .pi - 1e-6
            }
            #expect(rings.count == Int((60 / s).rounded(.up)) + 1)
            #expect(zip(rings, rings.dropFirst()).allSatisfy { abs($1 - $0 - 60 / Double(rings.count - 1)) < 1e-6 })
            // Between rings the angle stays put.
            for (a, b) in zip(c, c.dropFirst()) where abs(a.x - b.x) > 1e-9 { #expect(abs(a.a - b.a) < 1e-9) }
        }
        // Along X: lines at fixed angles Δθ = stepover ÷ the largest radius apart, alternating along the blank.
        do {
            let p = Self.shallow(.lines)
            let tp = try #require(CAMEngine.generate(p).toolpaths.first)
            let c = polar(tp, stock: p.stock)
            #expect(zip(c, c.dropFirst()).allSatisfy { $1.a >= $0.a - 1e-9 })
            var lines: [(a: Double, from: Double, to: Double)] = []
            for (a, b) in zip(c, c.dropFirst()) where abs(a.a - b.a) < 1e-12 && abs(a.x - b.x) > 1e-9 {
                if let l = lines.last, abs(l.a - a.a) < 1e-12 { lines[lines.count - 1].to = b.x } else { lines.append((a.a, a.x, b.x)) }
            }
            let count = Int((2 * .pi * 19.5 / s).rounded(.up))
            #expect(lines.count == count, "\(lines.count) vs \(count)")
            #expect(zip(lines, lines.dropFirst()).allSatisfy { abs($1.a - $0.a - 2 * .pi / Double(count)) < 1e-6 })
            #expect(zip(lines, lines.dropFirst()).allSatisfy { ($0.to > $0.from) != ($1.to > $1.from) })
        }
    }

    // MARK: Feeds

    /// The rotary axis can only turn so fast: near the axis the feed comes down so the A rate never exceeds the turn
    /// speed, and the job says so.
    @Test func theARateIsClampedAtTheTurnSpeed() throws {
        let p = Self.shallow(.spiral) {
            $0.machine.rotary?.turnSpeed = 1800
            var t = Self.ball
            t.cutting.feedRate = 3000
            $0.operations[0].tool = t
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        var at = tp.start
        let top = p.stock.topRadius!, cy = p.stock.originPoint.y
        var clamped = 0
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .feed else { continue }
            let d0 = (at.y - cy) / top * 180 / .pi, d1 = (m.end.y - cy) / top * 180 / .pi
            let length = RotaryWrap.tipLength(x0: at.x, r0: top + at.z, degrees0: d0, x1: m.end.x, r1: top + m.end.z, degrees1: d1)
            guard length > 1e-9 else { continue }
            let rate = abs(d1 - d0) * m.feed / length
            #expect(rate <= 1800 * 1.0001, "\(rate)°/min")
            if m.feed < 3000 { clamped += 1 }
        }
        #expect(clamped > 0)
        // At 19 mm a full-speed cut would need 3000 × 360 / (2π × 19) ≈ 9,000°/min.
        let note = try #require(messages(job, .warning).first { $0.contains("rotary axis turns at most 1,800°/min") })
        #expect(note.contains("down to") && !note.contains("isn't set"))
        // The estimate times every move at the feed the post's inverse time gives it.
        let seconds = try #require(job.estimatedSeconds(toolpath: tp.id))
        #expect(seconds > tp.cuttingLength / 3000 * 60 * 2)
    }

    /// The post's inverse-time F for a known move: a quarter turn round a cylinder at one station is r·π/2 long, so F is
    /// the feed over that.
    @Test func inverseTimeMatchesTheFormulaForAKnownMove() throws {
        let p = Self.job(mesh: Self.turned({ _ in 15 }, length: 40, samples: 8, segments: 1440), blank: RotaryStock(diameter: 32, length: 80),
                         params: RotaryFinishParams(pattern: .rings, stepoverFraction: 1)) {
            $0.machine.rotary?.turnSpeed = 1_000_000
            var t = Self.ball
            t.cutting.feedRate = 2000
            $0.operations[0].tool = t
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let g = GoldenPostTests.post(p, job.toolpaths)
        let text = String(decoding: g, as: UTF8.self)
        let program = try GCodeParser.parse(text)
        var checked = 0
        var x: Double?, z: Double?, a: Double?
        for m in program.segments.flatMap(\.motions) {
            defer { x = m.end.x; z = m.end.z; a = m.a ?? a }
            guard let f = m.inverseTime, let a0 = a, let a1 = m.a, m.end.x == x, m.end.z == z, let r = z else { continue }
            let expected = 2000 / (r * abs(a1 - a0) * .pi / 180)
            #expect(abs(f - (expected * 10000).rounded() / 10000) < 1e-4, "F\(f) vs \(expected)")
            checked += 1
        }
        #expect(checked > 8)
        #expect(text.contains("G93 G01") && text.contains("\r\nG94\r\n"))
        #expect(problems(GCodeCheck.run(text, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
    }

    // MARK: Checks

    @Test func checksCoverTheBlankTheModelAndTheTool() throws {
        func issues(_ configure: (inout Project) -> Void) -> [JobIssue] { CAMEngine.generate(Self.shallow(.spiral, configure)).issues }
        // Chip loads aren't what's checked here.
        func serious(_ all: [JobIssue]) -> [JobIssue] { all.filter { $0.severity != .info && !$0.message.contains("Chip load") } }
        func has(_ text: String, _ severity: Severity = .warning, _ configure: (inout Project) -> Void) {
            let all = issues(configure)
            #expect(all.contains { $0.severity == severity && $0.message.contains(text) }, "\(text): \(all.map(\.message))")
        }
        // Clean as set up.
        let clean = serious(issues { _ in })
        #expect(clean.isEmpty, "\(clean.map(\.message))")
        has("isn't one", .error) { $0.stock.setRotary(nil) }
        has("Starts from a square bar") { p in
            p.stock.setRotary(RotaryStock(shape: .squareBar, diameter: 42, length: 100))
            p.placeModelsOnBlank()
        }
        has("bigger across than the stock") { $0.shapes[0].scale = 1.2 }
        has("runs past the end of the blank") { $0.shapes[0].position.x = 20 }
        has("collet nut could hit") { $0.operations[0].tool.stickout = 2 }
        has("more than the cutting length") { p in
            p.operations[0].tool.fluteLength = 0.5
            p.operations[0].tool.stickout = 50
        }
        has("as if it were a flat end mill") { $0.operations[0].tool = Self.lib.tool(number: 5)! }
        has("no inverse-time feed (G93)", .error, ControllerPostTests.controller(.centroid, units: .mm))
        has("can't be done by hand", .error) { $0.machine.rotary?.turnsByHand = true }
        has("index angles don't apply", .error) { $0.operations[0].indexAngles = [0, 90] }
        // A rounding first takes the blank down: the finish cuts from what it leaves, and a square bar is fine.
        let rounded = Self.shallow(.spiral) { p in
            p.stock.setRotary(RotaryStock(shape: .squareBar, diameter: 42, length: 100))
            p.operations.insert(CAMOperation(name: "Round", kind: .rounding(RoundingParams(finishedDiameter: 40)), shapeIDs: [],
                                             tool: Self.lib.tool(number: 1)!), at: 0)
        }
        let left = serious(CAMEngine.generate(rounded).issues)
        #expect(left.isEmpty, "\(left.map(\.message))")
        // Round, then finish (Optimize Run Order would put the rounding first).
        var late = rounded
        late.operations.reverse()
        #expect(CAMEngine.generate(late).issues.contains { $0.message.contains("Runs before the blank is rounded") })
    }

    /// Undercuts a tool coming in toward the axis can't reach, and a model whose cross-sections don't contain the axis.
    @Test func hiddenSurfacesAreReported() {
        // A mushroom: a stem with a cap that overhangs it, cut by its own end face. Seen from the axis, the cap's
        // underside is hidden behind its top.
        let profile: [(x: Double, r: Double)] = [(0, 6), (20, 6), (20, 14), (30, 14), (30, 0.001)]
        let mushroom = MeshModel.revolved(name: "Mushroom", profile: profile, segments: 64)
        let job = CAMEngine.generate(Self.job(mesh: mushroom, blank: RotaryStock(diameter: 32, length: 80)))
        let w = messages(job, .warning)
        // A solid of revolution is star-shaped about its axis: nothing hidden, even under the cap's rim.
        #expect(!w.contains { $0.contains("hidden from the tool") || $0.contains("isn't inside the model") }, "\(w)")
        // A ring round the axis (a washer standing off it) has the axis outside it.
        let washer = MeshModel.revolved(name: "Washer", profile: [(0, 8), (10, 8), (10, 14), (0, 14), (0, 8.0001)], segments: 64)
        let jw = CAMEngine.generate(Self.job(mesh: washer, blank: RotaryStock(diameter: 32, length: 80)))
        #expect(messages(jw, .warning).contains { $0.contains("isn't inside the model") }, "\(messages(jw, .warning))")
        // An undercut: a bar round the axis with a second one standing off it on top, so the ray straight up leaves the
        // first, crosses the gap and goes through the second. The tool can't reach the gap's floor or the second bar's
        // underside.
        let undercut = Self.cuboids([(SIMD3(0, -3, -8), SIMD3(40, 3, 3)), (SIMD3(0, -3, 6), SIMD3(40, 3, 9))])
        let ju = CAMEngine.generate(Self.job(mesh: undercut, blank: RotaryStock(diameter: 32, length: 80)))
        #expect(messages(ju, .warning).contains { $0.contains("hidden from the tool") }, "\(messages(ju, .warning))")
    }

    // MARK: Output

    /// A small finish for the goldens: a bead 20 mm long on a 22 mm blank, sampled coarsely so the file stays short.
    static func smallFinish() -> Project {
        let bead = turned({ 8 + 2 * sin(.pi * $0 / 20) }, length: 20, samples: 20, segments: 36)
        return job(mesh: bead, blank: RotaryStock(diameter: 22, length: 40),
                   params: RotaryFinishParams(stepoverFraction: 0.5, angleStep: 15, passDepth: 10))
    }

    @Test func avidMach4Golden() throws {
        let p = Self.smallFinish()
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.severity == .error }, "\(job.issues.map(\.message))")
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: "rotary-finish-mm")
        let text = String(decoding: data, as: UTF8.self)
        #expect(problems(GCodeCheck.run(text, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
        // The setup sheet says what it follows and how.
        let html = SetupSheet.html(project: p, job: job)
        #expect(html.contains("<h2>3D rotary</h2>") && html.contains("its X axis along the blank") && html.contains("all round"))
    }

    /// A rotary finish saved by format 7 keeps loading and posting the same bytes.
    static func savedFinish() -> Project {
        var p = smallFinish()
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "3D3D0000-0000-0000-0000-%012d", n))! }
        guard case var .model(spec) = p.shapes[0].kind else { return p }
        spec.mesh.id = id(1)
        spec.rotary = RotaryPlacement(alongAxis: .x, reversed: true, turn: 15)
        p.shapes[0].id = id(2)
        p.shapes[0].kind = .model(spec)
        p.operations[0].id = id(3)
        p.operations[0].shapeIDs = [id(2)]
        p.operations[0].kind = .rotaryFinish(RotaryFinishParams(pattern: .rings, stepoverFraction: 0.5, allowance: 0.1, startX: 12,
                                                                angleStep: 20, passDepth: 1.5, layerStepoverFraction: 0.6))
        p.notes = "Saved by format 7: a 3D rotary finish of a model placed on a round blank."
        return p
    }

    @Test func rotaryFinishSavedByFormatSevenStillDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("rotary-finish-v7", make: Self.savedFinish)
        #expect(p.formatVersion == 7)
        #expect(p == Self.savedFinish())
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.severity == .error }, "\(job.issues.map(\.message))")
        let data = GoldenPostTests.post(p)
        try GoldenPostTests.check(data, golden: "decoded-rotary-finish-v7")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(issues.map(\.text))")
    }

    @Test func theDemoPawnFinishesCleanly() throws {
        let p = Project.demoPawn()
        #expect(p.formatVersion == 7)
        let job = CAMEngine.generate(p)
        let unexpected = job.issues.filter { $0.severity == .error || ($0.severity == .warning && !$0.message.contains("rotary axis turns at most")) }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.message))")
        #expect(job.toolpaths.map(\.name) == ["Round to 1.55\"", "Finish pawn"])
        let text = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(problems(GCodeCheck.run(text, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
        // The finished pawn simulates without gouging the model.
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.3)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        let g = try #require(s.radialGrid)
        let profile = MeshModel.pawnProfile()
        let start = p.shapes[0].rotaryExtent!.minX
        var gouge = 0.0
        for c in 0..<g.columns {
            let x = g.originX + Double(c) * g.cellSize - start
            guard x > 1, x < 85 else { continue }
            let i = min(profile.count - 2, Int(x / 86 * Double(profile.count - 1)))
            let f = (x - profile[i].x) / (profile[i + 1].x - profile[i].x)
            let r = profile[i].r + (profile[i + 1].r - profile[i].r) * f
            for j in 0..<g.rows { gouge = max(gouge, r - Double(g.radii[j * g.columns + c])) }
        }
        #expect(gouge < 0.05, "\(gouge)")
    }

    // MARK: Performance

    /// A 100k-triangle model at 0.5° and 0.25 mm (stepover and sample spacing) generates in reasonable time.
    @Test func aHundredThousandTriangleModelGeneratesQuickly() throws {
        let mesh = Self.turned({ 22 + 4 * sin($0 / 9) + 1.5 * sin($0 * 1.3) }, length: 150, samples: 399, segments: 128)
        #expect(mesh.triangleCount >= 100_000)
        let p = Self.job(mesh: mesh, blank: RotaryStock(diameter: 60, length: 200),
                         params: RotaryFinishParams(stepoverFraction: 0.25 / Self.ball.diameter, sampleSpacing: 0.25, angleStep: 0.5))
        let t0 = Date()
        let job = CAMEngine.generate(p)
        let seconds = Date().timeIntervalSince(t0)
        let tp = try #require(job.toolpaths.first)
        let report = "100k-triangle rotary finish: \(mesh.triangleCount) triangles, \(tp.motions.count) moves, \(String(format: "%.2f", seconds)) s"
        print(report)
        try? report.write(to: GoldenPostTests.actualOutput.deletingLastPathComponent().appendingPathComponent("rotary-performance.txt"),
                          atomically: true, encoding: .utf8)
        #expect(seconds < 120, "\(report)")
    }
}
