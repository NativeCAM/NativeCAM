import Foundation
import Testing
import simd
@testable import CAMCore

/// A cone standing on its base (radius `base`, flank `slope` degrees from horizontal), apex up, with a base disk.
func coneMesh(base B: Float = 20, slope: Float = 60, segments: Int = 256) -> MeshModel {
    let h = B * tan(slope * .pi / 180)
    var pos: [Float] = [0, 0, h, 0, 0, 0]
    var idx: [UInt32] = []
    for j in 0..<segments {
        let a = Float(j) / Float(segments) * 2 * .pi
        pos += [B * cos(a), B * sin(a), 0]
    }
    for j in 0..<segments {
        let p = UInt32(2 + j), q = UInt32(2 + (j + 1) % segments)
        idx += [0, p, q, 1, q, p]
    }
    return MeshModel(name: "Cone", positions: pos, indices: idx)
}

struct Finish3DStrategyTests {
    static let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose
    static var smallBall: Tool {
        var t = ball
        t.diameter = 0.125.inch
        t.name = "1/8\" Ball Nose"
        t.number = 11
        return t
    }

    static func finish(_ params: Finish3DParams, _ shape: DesignShape, tool: Tool = ball, extra: [DesignShape] = []) throws -> Toolpath {
        let op = CAMOperation(kind: .finish3D(params), shapeIDs: [shape.id] + extra.map(\.id), tool: tool)
        var project = Model3DFixture.project(shape, ops: [op])
        project.shapes += extra
        let job = CAMEngine.generate(project)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        return try #require(job.toolpaths.first)
    }

    /// Runs of feed moves at one Z (waterline loops), as their points.
    static func levelRuns(_ tp: Toolpath, minimumLength: Double = 5) -> [(z: Double, points: [Vec2])] {
        var runs: [(z: Double, points: [Vec2])] = []
        var current: [Vec2] = []
        var z = Double.nan
        var length = 0.0
        func close() {
            if current.count >= 3, length >= minimumLength { runs.append((z, current)) }
            current = []
            length = 0
        }
        tp.forEachMotion { s, m in
            guard m.kind == .feed, abs(m.end.z - s.z) < 1e-9 else { close(); return }
            if current.isEmpty || abs(s.z - z) > 1e-9 { close(); current = [s.xy]; z = s.z }
            current.append(m.end.xy)
            length += s.xy.distance(to: m.end.xy)
        }
        close()
        return runs
    }

    // MARK: Waterline

    /// Every waterline loop on a hemisphere is a circle round its axis at the radius where a ball's tip is at that
    /// level: the ball's centre is on the sphere grown by the ball's radius.
    @Test func waterlineLoopsOnAHemisphereAreAtTheBallsOffsetRadius() throws {
        let rho = 30.0, R = Self.ball.radius
        var dome = DesignShape(name: "Dome", kind: .model(ModelSpec(mesh: hemisphereMesh(rings: 96, segments: 192), depth: 30)),
                               position: Model3DFixture.center)
        dome.id = UUID()
        let params = Finish3DParams(stepoverFraction: 0.2, boundary: .material, strategy: .waterline, smoothLinks: false)
        let tp = try Self.finish(params, dome)
        let runs = Self.levelRuns(tp)
        let step = params.waterlineStep(tool: Self.ball)
        #expect(runs.count >= Int(29 / step), "\(runs.count) loops")
        #expect(Set(runs.map { ($0.z * 1e6).rounded() }).count == runs.count, "one loop per level")
        var worstGap = 0.0, worstR = 0.0
        var open = 0
        for run in runs {
            if run.points.first!.distance(to: run.points.last!) > 1e-6 { open += 1 }
            let zc = run.z + R + rho // ball centre above the sphere's centre
            let expected = ((rho + R) * (rho + R) - zc * zc).squareRoot()
            for p in run.points {
                // How far the ball's centre is off the sphere grown by its radius (the facets sit up to 4 µm inside it).
                let d = p.distance(to: Model3DFixture.center)
                worstGap = max(worstGap, abs((d * d + zc * zc).squareRoot() - (rho + R)))
                if run.z > -29 { worstR = max(worstR, abs(d - expected)) }
            }
        }
        #expect(open == 0, "\(open) loops aren't closed")
        #expect(worstGap < 0.012, "ball centre off the offset sphere by \(worstGap) mm")
        #expect(worstR < 0.05, "radius off by \(worstR) mm")
        // Top down: each level lower than the last.
        let zs = runs.map(\.z)
        #expect(zs == zs.sorted(by: >))
    }

    /// On a 60° cone the loops are circles at (apex + R(1/cos 60° − 1) − z) / tan 60°.
    @Test func waterlineLoopsOnAConeAreAtTheFlanksOffsetRadius() throws {
        let R = Self.ball.radius, slope = 60.0.radians
        let height = 20 * tan(slope)
        var cone = DesignShape(name: "Cone", kind: .model(ModelSpec(mesh: coneMesh(), depth: height)), position: Model3DFixture.center)
        cone.id = UUID()
        let tp = try Self.finish(Finish3DParams(stepoverFraction: 0.2, boundary: .material, strategy: .waterline, smoothLinks: false), cone)
        let runs = Self.levelRuns(tp)
        #expect(runs.count >= 25, "\(runs.count) loops")
        var worst = 0.0
        var checked = 0
        for run in runs {
            let expected = (R * (1 / cos(slope) - 1) - run.z) / tan(slope)
            // On the flank: past the apex (contact R sin 60° in from the tool) and above the floor.
            guard expected > R * sin(slope) + 0.2, run.z > -height + 0.05 else { continue }
            checked += 1
            for p in run.points { worst = max(worst, abs(p.distance(to: Model3DFixture.center) - expected)) }
        }
        #expect(checked >= 25)
        #expect(worst < 0.01, "radius off by \(worst) mm")
    }

    // MARK: Steep and shallow

    /// 20° rising to a 60° wall and a flat top: z(x) in mm, extruded 40 mm along Y.
    static let wallProfile: [(x: Float, z: Float)] = {
        let t20 = Float(tan(20.0 * .pi / 180)), t60 = Float(tan(60.0 * .pi / 180))
        let z30 = 1 + 30 * t20, z40 = z30 + 10 * t60
        return [(0, 1), (30, z30), (40, z40), (55, z40)]
    }()
    static let wallHeight = Double(wallProfile.last!.z)
    static let wallCentre = Vec2(100, 75)

    static func wallShapes() -> (DesignShape, DesignShape) {
        var block = DesignShape(name: "Wall", kind: .model(ModelSpec(mesh: extrudedProfile(wallProfile, width: 40), depth: wallHeight)),
                                position: wallCentre)
        block.id = UUID()
        let outline = DesignShape(kind: .rectangle(width: 75, height: 60, cornerRadius: 0), position: wallCentre)
        return (block, outline)
    }

    /// The wall model's surface point over model x (y in model coordinates too), in design coordinates.
    static func wallPoint(x: Double, y: Double) -> SIMD3<Double> {
        let t20 = tan(20.0.radians), t60 = tan(60.0.radians)
        let z = x <= 30 ? 1 + x * t20 : (x <= 40 ? 1 + 30 * t20 + (x - 30) * t60 : 1 + 30 * t20 + 10 * t60)
        return SIMD3(wallCentre.x + x - 27.5, wallCentre.y + y - 20, z - wallHeight)
    }

    /// Largest material left along lines across the passes, over model x in `range`, at three places along Y.
    static func worstResidual(_ sweep: BallSweep, x range: ClosedRange<Double>, step: Double) -> (high: Double, low: Double) {
        var high = -Double.infinity, low = Double.infinity
        for y in [10.0, 20, 30] {
            var x = range.lowerBound
            while x <= range.upperBound {
                let r = sweep.residual(at: wallPoint(x: x, y: y))
                high = max(high, r)
                low = min(low, r)
                x += step
            }
        }
        return (high, low)
    }

    /// Raster rows along a slope's contour lines spread to s / cos θ across it, so on a 60° wall a single raster leaves
    /// scallops about 4× the flat ones. Steep and shallow puts waterline loops there instead, Δz = s · tan 40° apart, so
    /// on both sides of the seam the scallop stays within what s / cos 40° spacing leaves (and nothing is gouged).
    @Test func steepAndShallowKeepsTheScallopBoundOnBothSidesOfA60DegreeWall() throws {
        let (block, outline) = Self.wallShapes()
        let R = Self.ball.radius, s = Self.ball.diameter * 0.1
        func scallop(_ spacing: Double) -> Double { R - (R * R - spacing * spacing / 4).squareRoot() }
        let bound = scallop(s / cos(40.0.radians))
        let slack = 0.012 // simplification and chord tolerances
        let base = Finish3DParams(stepoverFraction: 0.1, rasterAngle: 90, boundary: .vectors)
        var split = base
        split.strategy = .steepShallow
        let sweep = BallSweep([try Self.finish(split, block, extra: [outline])], radius: R)
        let shallow = Self.worstResidual(sweep, x: 5...25, step: 0.02)
        let steep = Self.worstResidual(sweep, x: 32...38, step: 0.01)
        #expect(shallow.high < bound + slack, "shallow side left \(shallow.high) mm (bound \(bound))")
        #expect(steep.high < bound + slack, "steep side left \(steep.high) mm (bound \(bound))")
        let everywhere = Self.worstResidual(sweep, x: 0.5...54.5, step: 0.05)
        #expect(everywhere.low > -slack, "cut \(-everywhere.low) mm into the surface")

        // The raster alone breaks the bound on the wall; cross-hatching it (rows straight up the wall) doesn't.
        let raster = BallSweep([try Self.finish(base, block, extra: [outline])], radius: R)
        let rasterSteep = Self.worstResidual(raster, x: 32...38, step: 0.01)
        #expect(rasterSteep.high > bound + slack, "raster alone left \(rasterSteep.high) mm on the wall")
        var hatch = base
        hatch.crossHatch = true
        let hatched = BallSweep([try Self.finish(hatch, block, extra: [outline])], radius: R)
        #expect(Self.worstResidual(hatched, x: 32...38, step: 0.01).high < bound + slack)
        #expect(Self.worstResidual(hatched, x: 0.5...54.5, step: 0.05).low > -slack)
    }

    /// The split follows the slope: waterline loops only where it's steep (on and next to the wall, and the block's
    /// vertical sides), raster rows only on the rest.
    @Test func steepAndShallowSplitsAtTheSteepAngle() throws {
        let (block, outline) = Self.wallShapes()
        // Rows straight up the slopes, so only waterline loops are long runs at one Z: none over the middle of the 20° slope.
        let tp = try Self.finish(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 0, boundary: .vectors, strategy: .steepShallow),
                                 block, extra: [outline])
        for run in Self.levelRuns(tp, minimumLength: 20) {
            for p in run.points {
                let x = p.x - Self.wallCentre.x + 27.5, y = p.y - Self.wallCentre.y + 20
                #expect(!(x > 8 && x < 22 && y > 5 && y < 35), "waterline at model (\(x), \(y))")
            }
        }
    }

    /// Where a row crosses a vertical wall the tool's height jumps between two samples; the move between them mustn't
    /// clip the wall's top edge or face (it climbs at the bottom of the step instead).
    @Test(arguments: [true, false])
    func rowsDontClipVerticalWalls(_ smooth: Bool) throws {
        let (block, outline) = Self.wallShapes()
        let tp = try Self.finish(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 0, boundary: .vectors, smoothLinks: smooth),
                                 block, extra: [outline])
        let sweep = BallSweep([tp], radius: Self.ball.radius)
        var worst = Double.infinity
        var at = SIMD3<Double>.zero
        for y in stride(from: 5.0, through: 35.0, by: 0.25) {
            // Up the 29 mm wall at x = 55 and along its top edge.
            for z in stride(from: 0.25, through: Self.wallHeight, by: 0.25) {
                var p = Self.wallPoint(x: 55, y: y)
                p.z = z - Self.wallHeight
                let r = sweep.residual(at: p)
                if r < worst { worst = r; at = p }
            }
            for x in stride(from: 54.0, through: 55.0, by: 0.05) {
                let p = Self.wallPoint(x: x, y: y)
                let r = sweep.residual(at: p)
                if r < worst { worst = r; at = p }
            }
        }
        #expect(worst > -0.012, "cut \(-worst) mm into the wall at \(at)")
    }

    // MARK: Pencil

    /// A V-groove: a 30° plane down to a crease at x = 30, a 45° plane up from it, 40 mm long, turned 25°.
    static let grooveProfile: [(x: Float, z: Float)] = {
        let t30 = Float(tan(30.0 * .pi / 180))
        return [(0, 1 + 30 * t30), (30, 1), (50, 21)]
    }()
    static let grooveCentre = Vec2(100, 75)

    static func grooveShapes(meshID: UUID = UUID(), shapeID: UUID = UUID(), outlineID: UUID = UUID()) -> (DesignShape, DesignShape) {
        var groove = DesignShape(id: shapeID, name: "Groove", kind: .model(ModelSpec(mesh: extrudedProfile(grooveProfile, width: 40, id: meshID),
                                                                                      depth: 21)),
                                 position: grooveCentre)
        groove.rotation = 25
        var outline = DesignShape(id: outlineID, kind: .rectangle(width: 70, height: 60, cornerRadius: 0), position: grooveCentre)
        outline.rotation = 25
        return (groove, outline)
    }

    /// Pencil passes find the crease of two intersecting planes: along it, the ball's centre is a radius from both.
    @Test func pencilFollowsTheCreaseOfTwoPlanes() throws {
        let (groove, outline) = Self.grooveShapes()
        let tool = Self.smallBall, R = tool.radius
        let tp = try Self.finish(Finish3DParams(stepoverFraction: 0.1, boundary: .vectors, strategy: .pencil), groove, tool: tool, extra: [outline])
        // Planes in model (x, z): their upward normals and a point on both.
        let n1 = SIMD2(sin(30.0.radians), cos(30.0.radians)), n2 = SIMD2(-sin(45.0.radians), cos(45.0.radians))
        // Centre u, v from the crease point (30, 1): n1 · (u, v) = R and n2 · (u, v) = R.
        let det = n1.x * n2.y - n1.y * n2.x
        let u = (R * n2.y - n1.y * R) / det, v = (n1.x * R - R * n2.x) / det
        let lineX = 30 + u, tipZ = 1 + v - R - 21
        let back = Transform2D.rotation(-25.0.radians)
        var along: [Double] = []
        var worstXY = 0.0, worstZ = 0.0
        tp.forEachMotion { s, m in
            guard m.kind == .feed else { return }
            let n = max(1, Int((s.distance(to: m.end) / 0.5).rounded(.up)))
            for k in 0...n {
                let q = s.lerp(to: m.end, Double(k) / Double(n))
                let local = back.apply(q.xy - Self.grooveCentre) + Vec2(25, 20)
                guard abs(local.x - lineX) < 1, local.y > 6, local.y < 34 else { continue }
                along.append(local.y)
                worstXY = max(worstXY, abs(local.x - lineX))
                worstZ = max(worstZ, abs(q.z - tipZ))
            }
        }
        #expect(along.count >= 2, "no pencil pass along the crease")
        #expect((along.max() ?? 0) - (along.min() ?? 0) > 26, "the crease pass covers \(along.min() ?? 0)…\(along.max() ?? 0)")
        #expect(worstXY < 0.02, "off the crease by \(worstXY) mm")
        #expect(worstZ < 0.01, "tip off by \(worstZ) mm")
        // Nothing on the open faces of the planes: every pencil point is on the crease or at the foot of the block's
        // walls, where the floor meets them.
        var stray: [Vec2] = []
        tp.forEachMotion { _, m in
            guard m.kind == .feed else { return }
            let local = back.apply(m.end.xy - Self.grooveCentre) + Vec2(25, 20)
            let onCrease = abs(local.x - lineX) < 1
            let atFoot = local.x < 0.5 || local.x > 49.5 || local.y < 0.5 || local.y > 39.5
            if !(onCrease || atFoot || m.end.z > -0.5) { stray.append(local) }
        }
        #expect(stray.isEmpty, "pencil at model \(stray.prefix(5))")
    }

    @Test func pencilNeedsABallNose() throws {
        let (groove, outline) = Self.grooveShapes()
        let op = CAMOperation(kind: .finish3D(Finish3DParams(boundary: .vectors, strategy: .pencil)), shapeIDs: [groove.id, outline.id],
                              tool: ToolLibrary.starter.tool(number: 1)!)
        var project = Model3DFixture.project(groove, ops: [op])
        project.shapes.append(outline)
        let job = CAMEngine.generate(project)
        #expect(job.issues.contains { $0.message.contains("needs a ball-nose bit") })
    }

    // MARK: No gouges

    /// None of the strategies cuts into the exact dome: measured from the ball's path itself (finer than any
    /// simulation grid, so right down the steep sides to the floor), and simulated like the raster always was.
    @Test(arguments: [Finish3DStrategy.waterline, .steepShallow, .pencil, .raster])
    func strategiesDontGougeTheDome(_ strategy: Finish3DStrategy) throws {
        let tool = strategy == .pencil ? Self.smallBall : Self.ball
        let rho = 30.0
        var fine = DesignShape(name: "Dome", kind: .model(ModelSpec(mesh: hemisphereMesh(rings: 96, segments: 192), depth: 30)),
                               position: Model3DFixture.center)
        fine.id = UUID()
        let swept = try Self.finish(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 30, boundary: .material, strategy: strategy,
                                                   crossHatch: strategy == .raster), fine, tool: tool)
        #expect(!swept.isEmpty)
        let sweep = BallSweep([swept], radius: tool.radius)
        var deepest = 0.0
        var deepestAt = SIMD3<Double>.zero
        for i in 0..<60 {
            let lat = Double(i) / 60 * .pi / 2 * 0.995
            for j in 0..<180 {
                let lon = Double(j) / 180 * 2 * .pi
                let p = SIMD3(Model3DFixture.center.x + rho * cos(lat) * cos(lon), Model3DFixture.center.y + rho * cos(lat) * sin(lon),
                              -rho + rho * sin(lat))
                let r = sweep.residual(at: p)
                if r < deepest { deepest = r; deepestAt = p }
            }
        }
        // The facets sit up to 4 µm inside the sphere; passes are simplified to 0.01 mm.
        #expect(deepest > -0.015, "\(strategy) cut \(-deepest) mm into the dome at \(deepestAt)")

        var dome = Model3DFixture.shape()
        dome.id = UUID()
        let tp = try Self.finish(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 30, strategy: strategy, crossHatch: strategy == .raster),
                                 dome, tool: tool)
        #expect(!tp.isEmpty)
        var s = SimulationSession(toolpaths: [tp], stock: Model3DFixture.stock, rapidRate: 10000, cellSize: 0.25)
        s.runToEnd()
        #expect(s.rapidCollisions.isEmpty)
        let grid = s.grid
        var gouge = 0.0
        var worstAt = Vec2.zero
        for r in 0..<grid.rows {
            for c in 0..<grid.columns {
                let p = Vec2(grid.origin.x + Double(c) * grid.cellSize, grid.origin.y + Double(r) * grid.cellSize)
                guard let m = Model3DFixture.modelZ(p) else { continue }
                let h = Double(grid.heights[grid.index(c, r)])
                if m - h > gouge { gouge = m - h; worstAt = p }
            }
        }
        #expect(gouge < 0.08, "\(strategy) gouged \(gouge) mm at \(worstAt)")
    }

    // MARK: Cross-hatch

    @Test func crossHatchAddsASecondRasterAtRightAngles() throws {
        var dome = Model3DFixture.shape()
        dome.id = UUID()
        func longMoves(_ tp: Toolpath) -> (alongX: Int, alongY: Int) {
            var x = 0, y = 0
            tp.forEachMotion { s, m in
                guard m.kind == .feed else { return }
                let d = m.end.xy - s.xy
                if abs(d.x) > 3, abs(d.y) < 1e-6 { x += 1 }
                if abs(d.y) > 3, abs(d.x) < 1e-6 { y += 1 }
            }
            return (x, y)
        }
        let single = longMoves(try Self.finish(Finish3DParams(stepoverFraction: 0.2, boundary: .material), dome))
        let hatched = longMoves(try Self.finish(Finish3DParams(stepoverFraction: 0.2, boundary: .material, crossHatch: true), dome))
        #expect(single.alongX > 20 && single.alongY == 0)
        #expect(hatched.alongX == single.alongX && hatched.alongY > 20)
    }

    // MARK: Links

    /// Waterline loops start from their open side: with smooth links each pass comes down in the air beside the wall and
    /// arcs onto it, instead of plunging straight onto the model; and links never take the tool past the boundary.
    @Test func smoothLinksEnterOffTheModelAndStayInsideTheBoundary() throws {
        var dome = Model3DFixture.shape()
        dome.id = UUID()
        let outline = DesignShape(kind: .circle(radius: 40), position: Model3DFixture.center)
        let tp = try Self.finish(Finish3DParams(stepoverFraction: 0.2, boundary: .vectors, strategy: .steepShallow), dome, extra: [outline])
        let reach = 40 + Finish3DParams.autoMargin(tool: Self.ball)
        var plungesOnModel = 0
        var farthest = 0.0
        tp.forEachMotion { s, m in
            if m.kind != .rapid, m.end.z < 0 { farthest = max(farthest, m.end.xy.distance(to: Model3DFixture.center)) }
            // A straight-down feed that ends touching the dome.
            if m.kind == .feed, s.xy.isApprox(m.end.xy, tolerance: 1e-6), m.end.z < s.z,
               let zModel = Model3DFixture.modelZ(m.end.xy), m.end.z < zModel + Self.ball.radius {
                let d = m.end.xy.distance(to: Model3DFixture.center)
                // The tool's tip on the ball-offset dome: it would be resting on the model.
                let rho = 30.0, R = Self.ball.radius
                let tip = d < rho + R ? ((rho + R) * (rho + R) - d * d).squareRoot() - rho - R : -30
                if m.end.z < tip + 0.05 { plungesOnModel += 1 }
            }
        }
        #expect(farthest <= reach + 0.01, "cuts \(farthest) mm from the centre")
        #expect(plungesOnModel == 0, "\(plungesOnModel) plunges onto the dome")
    }

    // MARK: File format

    @Test func strategiesAndCrossHatchRaiseTheFormatOnlyWhenUsed() throws {
        #expect(Finish3DParams().requiredFormatVersion == 1)
        #expect(Finish3DParams(steepAngle: 30, overlap: 2, smoothLinks: false).requiredFormatVersion == 1)
        #expect(Finish3DParams(crossHatch: true).requiredFormatVersion == 10)
        for s in [Finish3DStrategy.waterline, .steepShallow, .pencil] {
            #expect(Finish3DParams(strategy: s).requiredFormatVersion == 10)
        }
        // A plain raster saves the keys it always had, plus smooth links when they're on.
        let plain = String(decoding: try JSONEncoder().encode(Finish3DParams(smoothLinks: false)), as: UTF8.self)
        #expect(!plain.contains("strategy") && !plain.contains("crossHatch") && !plain.contains("smoothLinks"))
        // A file from before reads as the raster it was, linked as before.
        let old = #"{"stepoverFraction":0.1,"rasterAngle":45,"allowance":0,"boundary":"vectors"}"#
        let decoded = try JSONDecoder().decode(Finish3DParams.self, from: Data(old.utf8))
        #expect(decoded == Finish3DParams(rasterAngle: 45, boundary: .vectors, smoothLinks: false))
        let every = Finish3DParams(stepoverFraction: 0.15, rasterAngle: 30, allowance: 0.1, boundary: .vectors, boundaryMargin: 2,
                                   strategy: .steepShallow, crossHatch: true, steepAngle: 45, overlap: 1.5, smoothLinks: true)
        #expect(try JSONDecoder().decode(Finish3DParams.self, from: JSONEncoder().encode(every)) == every)
    }

    // MARK: Goldens

    static func goldenProject(_ params: Finish3DParams, shapes: [DesignShape], tool: Tool) -> Project {
        let op = CAMOperation(id: UUID(uuidString: "F1A50000-0000-0000-0000-000000000001")!, name: params.strategy.label,
                              kind: .finish3D(params), shapeIDs: shapes.map(\.id), tool: tool)
        return Project(name: "3D finishing", displayUnits: .mm, stock: Model3DFixture.stock, machine: .avidPRO6060, shapes: shapes,
                       operations: [op])
    }

    static func goldenShapes(_ which: String) -> [DesignShape] {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "F1A50000-0000-0000-0001-%012d", n))! }
        switch which {
        case "dome":
            var mesh = hemisphereMesh(radius: 20, rings: 24, segments: 48)
            mesh.id = id(1)
            return [DesignShape(id: id(2), name: "Dome", kind: .model(ModelSpec(mesh: mesh, depth: 20)), position: Model3DFixture.center),
                    DesignShape(id: id(9), name: "Outline", kind: .circle(radius: 26), position: Model3DFixture.center)]
        case "wall":
            let mesh = extrudedProfile(wallProfile, width: 40, id: id(3))
            return [DesignShape(id: id(4), name: "Wall", kind: .model(ModelSpec(mesh: mesh, depth: wallHeight)), position: wallCentre),
                    DesignShape(id: id(5), name: "Outline", kind: .rectangle(width: 75, height: 60, cornerRadius: 0), position: wallCentre)]
        default:
            let (g, o) = grooveShapes(meshID: id(6), shapeID: id(7), outlineID: id(8))
            return [g, o]
        }
    }

    /// Posts `p` for Avid's Mach4 profile, compares it with the golden and runs the export checks on it.
    static func checkGolden(_ p: Project, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))", sourceLocation: sourceLocation)
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name, sourceLocation: sourceLocation)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))", sourceLocation: sourceLocation)
    }

    @Test func waterlineGolden() throws {
        let p = Self.goldenProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .waterline),
                                   shapes: Self.goldenShapes("dome"), tool: Self.ball)
        try Self.checkGolden(p, "finish-waterline")
    }

    @Test func steepAndShallowGolden() throws {
        let p = Self.goldenProject(Finish3DParams(stepoverFraction: 0.2, rasterAngle: 90, boundary: .vectors, strategy: .steepShallow),
                                   shapes: Self.goldenShapes("wall"), tool: Self.ball)
        try Self.checkGolden(p, "finish-steep-shallow")
    }

    @Test func pencilGolden() throws {
        let p = Self.goldenProject(Finish3DParams(boundary: .vectors, strategy: .pencil), shapes: Self.goldenShapes("groove"), tool: Self.smallBall)
        try Self.checkGolden(p, "finish-pencil")
    }

    @Test func crossHatchGolden() throws {
        let p = Self.goldenProject(Finish3DParams(stepoverFraction: 0.25, rasterAngle: 30, boundary: .vectors, crossHatch: true),
                                   shapes: Self.goldenShapes("dome"), tool: Self.ball)
        try Self.checkGolden(p, "finish-cross-hatch")
    }

    /// Every new setting away from its default, saved as format 10: the wall finished steep-and-shallow (cross-hatched,
    /// its own steep angle and overlap) and by waterline, the groove by pencil with a smaller ball.
    static func savedProject() -> Project {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "F1A50000-0000-0000-0002-%012d", n))! }
        let wall = goldenShapes("wall")
        var groove = goldenShapes("groove")
        var stock = Model3DFixture.stock
        stock.width = 300
        for i in groove.indices { groove[i].position.x += 110 }
        let ops = [
            CAMOperation(id: id(1), name: "Steep and shallow", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.2, rasterAngle: 90, allowance: 0.05, boundary: .vectors, boundaryMargin: 3, strategy: .steepShallow,
                crossHatch: true, steepAngle: 45, overlap: 1.2)), shapeIDs: wall.map(\.id), tool: ball),
            CAMOperation(id: id(2), name: "Waterline", kind: .finish3D(Finish3DParams(
                stepoverFraction: 0.3, boundary: .vectors, strategy: .waterline, steepAngle: 50, smoothLinks: false)),
                         shapeIDs: wall.map(\.id), tool: ball),
            CAMOperation(id: id(3), name: "Pencil", kind: .finish3D(Finish3DParams(boundary: .vectors, strategy: .pencil)),
                         shapeIDs: groove.map(\.id), tool: smallBall),
        ]
        return Project(name: "3D finishing (format 10)", displayUnits: .mm, stock: stock, machine: .avidPRO6060, shapes: wall + groove,
                       operations: ops, notes: "Saved by format 10 to pin the 3D finishing strategies.")
    }

    @Test func savedFinishingProjectDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("finishing-v10", make: Self.savedProject)
        #expect(p.formatVersion == 10)
        #expect(p == Self.savedProject())
        #expect(try Project.decode(p.encoded()) == p)
        let job = CAMEngine.generate(p)
        #expect(job.toolpaths.count == 3 && job.toolpaths.allSatisfy { !$0.isEmpty })
        try Self.checkGolden(p, "decoded-finishing-v10")
    }
}
