import Foundation
import Testing
import simd
@testable import CAMCore

/// A surface of revolution about Z: `profile` from the axis outward (r, z), down its outside to z = 0 and closed with
/// a base disk there.
func revolvedMesh(_ profile: [(r: Float, z: Float)], segments: Int, id: UUID = UUID(), name: String = "Revolved") -> MeshModel {
    var pos: [Float] = []
    var idx: [UInt32] = []
    func add(_ x: Float, _ y: Float, _ z: Float) -> UInt32 { pos += [x, y, z]; return UInt32(pos.count / 3 - 1) }
    func ring(_ r: Float, _ z: Float) -> [UInt32] {
        (0..<segments).map { j in
            let a = Float(j) / Float(segments) * 2 * .pi
            return add(r * cos(a), r * sin(a), z)
        }
    }
    let apex = add(0, 0, profile[0].z)
    var rings = profile.dropFirst().map { ring($0.r, $0.z) }
    if let last = profile.last, last.z > 1e-6 { rings.append(ring(last.r, 0)) }
    for j in 0..<segments { idx += [apex, rings[0][j], rings[0][(j + 1) % segments]] }
    for i in 0..<(rings.count - 1) {
        for j in 0..<segments {
            let a = rings[i][j], b = rings[i][(j + 1) % segments], c = rings[i + 1][(j + 1) % segments], d = rings[i + 1][j]
            idx += [a, d, c, a, c, b]
        }
    }
    let foot = rings[rings.count - 1]
    let centre = add(0, 0, 0)
    for j in 0..<segments { idx += [centre, foot[(j + 1) % segments], foot[j]] }
    return MeshModel(id: id, name: name, positions: pos, indices: idx)
}

/// Constant scallop, spiral and radial 3D finishing (#88): the scallop they leave on a dome against a raster's, that
/// they don't gouge the demo relief or a coin, that they stay inside the boundary, how they link, and the bits'
/// scallop-height stepovers.
struct FinishingPatternsTests {
    static let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose

    // MARK: Bits

    /// Each bit's scallop comes from its rounded tip: a ball nose's ball, a tapered ball nose's tip ball, a bull nose's
    /// corner beside its flat. A flat end mill has none, so a scallop height can't set its stepover.
    @Test func scallopStepoverFollowsEachBitsRoundedTip() {
        let tapered = ToolLibrary.template(for: .taperedBallNose)
        var bull = ToolLibrary.template(for: .bullNose)
        bull.diameter = 0.5.inch
        bull.cornerRadius = 0.0625.inch
        let flat = ToolLibrary.starter.tool(number: 1)!
        #expect(Self.ball.scallopRadius == Self.ball.radius)
        #expect(tapered.scallopRadius == tapered.tipDiameter / 2)
        #expect(bull.scallopRadius == bull.cornerRadius)
        #expect(flat.scallopRadius == nil)
        #expect(flat.stepover(forScallop: 0.05) == nil)
        for tool in [Self.ball, tapered, bull] {
            for h in [0.005, 0.02, 0.05, 0.1] {
                let s = tool.stepover(forScallop: h)!
                let back = tool.scallopHeight(stepover: s)
                #expect(abs(back - h) < 1e-9, "\(tool.name): \(h) mm → \(s) mm → \(back) mm")
            }
        }
        // 0.05 mm with a 1/4" ball: 2√(2Rh − h²).
        let r = Self.ball.radius
        #expect(abs(Self.ball.stepover(forScallop: 0.05)! - 2 * (2 * r * 0.05 - 0.0025).squareRoot()) < 1e-9)
        // Passes no farther apart than a bull nose's flat leave no scallop.
        #expect(bull.scallopHeight(stepover: bull.diameter - 2 * bull.cornerRadius) == 0)
        // The stepover a target gives is only used by the strategies that hold one.
        let target = Finish3DParams(strategy: .constantScallop, scallopHeight: 0.05)
        #expect(abs(target.stepoverInUse(tool: Self.ball) - Self.ball.stepover(forScallop: 0.05)!) < 1e-12)
        var raster = target
        raster.strategy = .raster
        #expect(raster.stepoverInUse(tool: Self.ball) == Self.ball.diameter * raster.stepoverFraction)
    }

    // MARK: The 100 mm dome

    /// A spherical cap 100 mm across and 25 mm tall (a sphere of 62.5 mm radius), so its slope runs from flat at the top
    /// to 53° at the foot.
    static let domeRho = 62.5, domeHeight = 25.0, domeRadius = 50.0
    static let domeCentre = Vec2(75, 75)

    static func domeMesh(rings: Int = 96, segments: Int = 360) -> MeshModel {
        let phiMax = asin(domeRadius / domeRho)
        let profile = (0...rings).map { i -> (r: Float, z: Float) in
            let phi = phiMax * Double(i) / Double(rings)
            return (Float(domeRho * sin(phi)), Float(domeRho * cos(phi) - (domeRho - domeHeight)))
        }
        return revolvedMesh(profile, segments: segments, name: "Dome")
    }

    /// The 1/4" ball nose with flutes long enough for the dome.
    static var longBall: Tool {
        var t = ball
        t.fluteLength = 30
        return t
    }

    /// The dome on a 150 mm square board, finished inside its own outline (the tool centre stays over the dome).
    static func domeProject(_ params: Finish3DParams, tool: Tool = longBall) -> Project {
        let dome = DesignShape(name: "Dome", kind: .model(ModelSpec(mesh: domeMesh(), depth: domeHeight)), position: domeCentre)
        let outline = DesignShape(name: "Outline", kind: .circle(radius: domeRadius), position: domeCentre)
        let op = CAMOperation(name: params.strategy.label, kind: .finish3D(params), shapeIDs: [dome.id, outline.id], tool: tool)
        var machine = MachineProfile.avidPRO6060
        machine.outputArcs = false
        return Project(name: "Dome", displayUnits: .mm, stock: Stock(width: 150, height: 150, thickness: 30, clearanceHeight: 10, plungeHeight: 2),
                       machine: machine, shapes: [dome, outline], operations: [op])
    }

    /// The exact sphere's surface above plan point p (its top at the material top, Z = 0).
    static func domeSurface(_ p: Vec2) -> SIMD3<Double> {
        let d = p.distance(to: domeCentre)
        return SIMD3(p.x, p.y, (domeRho * domeRho - d * d).squareRoot() - domeRho)
    }

    /// The scallop the toolpath's ball leaves on the dome, simulated by sweeping the ball along its feed moves: the
    /// material left square to the surface at points 0.02 mm apart along 72 radial lines, out to `r` from the centre
    /// (past that the ball touches the floor round the dome too). The worst over each fifth of the radius.
    static func scallops(_ tp: Toolpath, out r: Double) -> [Double] {
        let sweep = BallSweep([tp], radius: tp.tool.radius)
        var bands = [Double](repeating: 0, count: 5)
        for k in 0..<72 {
            let u = Vec2.fromAngle(Double(k) * 5 * .pi / 180 + 0.01)
            var d = 0.0
            while d <= r {
                let band = min(4, Int(d / r * 5))
                bands[band] = max(bands[band], sweep.residual(at: domeSurface(domeCentre + u * d)))
                d += 0.02
            }
        }
        return bands
    }

    static let target = 0.05

    static func domeScallops(_ params: Finish3DParams) throws -> (bands: [Double], toolpath: Toolpath, job: JobResult) {
        let job = CAMEngine.generate(Self.domeProject(params))
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        return (Self.scallops(tp, out: 47), tp, job)
    }

    /// On the dome, constant scallop at 0.05 mm keeps the scallop within 1.5× of it from the flat top to the 53° foot.
    /// A raster at the same stepover leaves 0.05 mm on top but twice that and more on the steep flanks, where its rows
    /// are a stepover apart in plan but much farther apart along the surface.
    @Test func constantScallopHoldsItsTargetOverTheDomeWhereARasterDoesNot() throws {
        let params = Finish3DParams(boundary: .vectors, boundaryMargin: 0, strategy: .constantScallop, scallopHeight: Self.target)
        let stepover = params.stepoverInUse(tool: Self.longBall)
        let cs = try Self.domeScallops(params)
        #expect(cs.toolpath.warnings.isEmpty, "\(cs.toolpath.warnings)")
        let csWorst = cs.bands.max()!, csLeast = cs.bands.min()!
        #expect(csWorst <= 1.5 * Self.target, "constant scallop leaves \(cs.bands) mm")
        #expect(csLeast >= 0.5 * Self.target, "constant scallop leaves \(cs.bands) mm")

        let raster = try Self.domeScallops(Finish3DParams(stepoverFraction: stepover / Self.longBall.diameter, boundary: .vectors,
                                                          boundaryMargin: 0))
        let rasterWorst = raster.bands.max()!, rasterLeast = raster.bands.min()!
        #expect(rasterWorst > 1.8 * Self.target, "raster leaves \(raster.bands) mm")
        // The raster's scallop varies over the dome at least three times as much as constant scallop's.
        let csSpread = csWorst / csLeast, rasterSpread = rasterWorst / rasterLeast
        #expect(rasterSpread - 1 > 3 * (csSpread - 1), "spread: raster \(rasterSpread), constant scallop \(csSpread)")
        // Both get run times from the planner, and constant scallop's are no slower for being even.
        let csTime = try #require(cs.job.estimatedSeconds(toolpath: cs.toolpath.id))
        let rasterTime = try #require(raster.job.estimatedSeconds(toolpath: raster.toolpath.id))
        #expect(csTime > 30 && csTime < rasterTime * 1.2, "constant scallop \(csTime) s, raster \(rasterTime) s")
    }

    /// A spiral holding the scallop closes its turns up on the flanks, keeping within 1.5× of the target; a plain
    /// spiral (a constant stepover in plan) leaves more there, and Checks says so.
    @Test func aSpiralHoldingTheScallopKeepsItEvenOverTheDome() throws {
        let held = try Self.domeScallops(Finish3DParams(boundary: .vectors, boundaryMargin: 0, strategy: .spiral,
                                                        scallopHeight: Self.target, spiralHoldsScallop: true))
        #expect(held.bands.max()! <= 1.5 * Self.target, "held spiral leaves \(held.bands) mm")
        #expect(held.toolpath.warnings.isEmpty, "\(held.toolpath.warnings)")
        let plain = try Self.domeScallops(Finish3DParams(boundary: .vectors, boundaryMargin: 0, strategy: .spiral, scallopHeight: Self.target))
        #expect(plain.bands.max()! > 1.5 * Self.target, "plain spiral leaves \(plain.bands) mm")
        let warning = plain.toolpath.warnings.first { $0.contains("farther apart than the stepover") }
        #expect(warning?.contains("Hold scallop") == true, "\(plain.toolpath.warnings)")
        // One continuous cut: a single plunge, ramping in to the centre (from a ball radius behind it).
        #expect(Self.plunges(held.toolpath).count == 1)
        let start = try #require(Self.plunges(held.toolpath).first)
        #expect(start.xy.distance(to: Self.domeCentre) < Self.ball.radius + 0.1, "starts at \(start)")
    }

    /// Radial spokes on the dome run down the slope, so across them the spacing is in plan; with the automatic step
    /// and spacing they're between half a stepover and a stepover apart all the way out, and the scallop stays within
    /// 1.5× of what the stepover leaves.
    @Test func radialSpokesKeepTheScallopOverTheDome() throws {
        let stepover = Self.longBall.stepover(forScallop: Self.target)!
        let radial = try Self.domeScallops(Finish3DParams(stepoverFraction: stepover / Self.longBall.diameter, boundary: .vectors,
                                                          boundaryMargin: 0, strategy: .radial))
        #expect(radial.bands.max()! <= 1.5 * Self.target, "radial leaves \(radial.bands) mm")
        #expect(radial.toolpath.warnings.isEmpty, "\(radial.toolpath.warnings)")
        // A coarse step is flagged in Checks.
        let coarse = CAMEngine.generate(Self.domeProject(Finish3DParams(stepoverFraction: stepover / Self.longBall.diameter, boundary: .vectors,
                                                                        boundaryMargin: 0, strategy: .radial, radialStep: 4)))
        let tp = try #require(coarse.toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("between the spokes far from the centre") }, "\(tp.warnings)")
    }

    /// The spoke thinning: no two spokes are ever closer than the minimum spacing, and none stops farther out than it
    /// needs to (each is within twice the spacing of a neighbour that runs on in).
    @Test func spokesThinOutTowardsTheCentre() {
        for (n, spacing) in [(64, 1.0), (100, 0.5), (281, 0.56), (7, 2.0)] {
            let start = Model3DGenerator.spokeStarts(count: n, spacing: spacing)
            let step = 2 * Double.pi / Double(n)
            #expect(start[0] == 0)
            var closest = Double.infinity
            for r in stride(from: 0.25, through: 60, by: 0.25) {
                let visible = (0..<n).filter { start[$0] <= r }
                for (x, i) in visible.enumerated() {
                    let j = visible[(x + 1) % visible.count]
                    guard i != j else { continue }
                    let d = (j - i + n) % n
                    closest = min(closest, 2 * r * sin(Double(d) * step / 2))
                }
            }
            #expect(closest >= spacing * (1 - 1e-9), "\(n) spokes: \(closest) apart, wanted \(spacing)")
            // Every spoke but the first starts where it's just the spacing from one already running.
            for k in 1..<n {
                let others = (0..<n).filter { $0 != k && start[$0] <= start[k] + 1e-9 }
                let gap = others.map { j -> Int in let d = abs(j - k); return min(d, n - d) }.min()!
                #expect(abs(2 * start[k] * sin(Double(gap) * step / 2) - spacing) < 1e-6)
            }
        }
        // Unevenly spaced spokes (the automatic angles on an oval) keep the spacing too.
        let angles = (0..<200).map { k -> Double in let t = 2 * Double.pi * Double(k) / 200; return t + 0.2 * sin(2 * t) }
        let start = Model3DGenerator.spokeStarts(angles: angles, spacing: 0.5)
        var closest = Double.infinity
        for r in stride(from: 0.25, through: 60, by: 0.25) {
            let visible = angles.indices.filter { start[$0] <= r }
            for (x, i) in visible.enumerated() {
                let j = visible[(x + 1) % visible.count]
                guard i != j else { continue }
                let d = (angles[j] - angles[i] + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
                closest = min(closest, 2 * r * sin(d / 2))
            }
        }
        #expect(closest >= 0.5 * (1 - 1e-9), "uneven spokes: \(closest) apart")
    }

    /// On the demo relief's oval (#127) a spiral's turns run off the boundary at both ends. Past the first, the arcs
    /// left inside are cut each from its nearer end, linking along the surface, instead of lifting over the outside of
    /// every turn; the radial's automatic spokes are a stepover apart where each meets the boundary rather than at its
    /// farthest point, and are cut in rings, so their inner ends don't link half the oval apart. (Before: the spiral
    /// lifted 230-odd times and ran 5:54, the radial 9:59, against the raster's 4:51.)
    @Test func spiralAndRadialFitTheOvalDemoRelief() throws {
        var p = Project.demoRelief()
        let id = p.operations[1].id
        guard case var .finish3D(fp) = p.operations[1].kind else { Issue.record("not a finish"); return }
        let raster = try #require(CAMEngine.generate(p).estimatedSeconds(toolpath: id))
        fp.strategy = .spiral
        p.operations[1].kind = .finish3D(fp)
        var job = CAMEngine.generate(p)
        var tp = try #require(job.toolpaths.first { $0.id == id })
        let spiral = try #require(job.estimatedSeconds(toolpath: id))
        #expect(Self.plunges(tp).count < 10, "spiral plunges \(Self.plunges(tp).count) times")
        #expect(spiral < raster, "spiral \(spiral) s, raster \(raster) s")
        fp.strategy = .radial
        p.operations[1].kind = .finish3D(fp)
        job = CAMEngine.generate(p)
        tp = try #require(job.toolpaths.first { $0.id == id })
        let radial = try #require(job.estimatedSeconds(toolpath: id))
        #expect(Self.plunges(tp).count < 4, "radial plunges \(Self.plunges(tp).count) times")
        #expect(radial < 1.8 * raster, "radial \(radial) s, raster \(raster) s")
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
    }

    // MARK: Helpers

    /// Where the toolpath plunges: each feed down straight after a rapid.
    static func plunges(_ tp: Toolpath) -> [Vec3] {
        var out: [Vec3] = []
        var lastRapid = false
        tp.forEachMotion { s, m in
            if m.kind != .rapid, m.kind != .dwell, lastRapid, m.end.z < s.z - 1e-6 { out.append(m.end) }
            lastRapid = m.kind == .rapid
        }
        return out
    }

    /// Points along the cutting moves (feeds and arcs) below the material top, every `step` mm.
    static func cuts(_ tp: Toolpath, step: Double = 0.25) -> [Vec3] {
        var out: [Vec3] = []
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            out += ([s] + m.samples(from: s, maxStep: step)).filter { $0.z < 0 }
        }
        return out
    }

    /// The cutting moves' farthest reach outside `regions` (the tool centre), mm; 0 when every one is inside.
    static func farthestOutside(_ tp: Toolpath, _ regions: [Region]) -> Double {
        var worst = 0.0
        let loops = regions.flatMap(\.loops)
        for q in cuts(tp) where !regions.contains(where: { $0.contains(q.xy) }) {
            worst = max(worst, loops.map { $0.closestPoint(to: q.xy).distance }.min() ?? .infinity)
        }
        return worst
    }

    // MARK: The demo relief

    /// The demo relief finished with each pattern instead of its raster: none cuts below the model, checked against
    /// the exact drop-cutter along every move and in simulation (0.2 mm cells, against the raster's own figure there,
    /// which is the simulator's sampling of the mesh), and each finishes in a reasonable time.
    @Test(arguments: [Finish3DStrategy.constantScallop, .spiral, .radial])
    func patternsDontGougeTheDemoRelief(_ strategy: Finish3DStrategy) throws {
        var p = Project.demoRelief()
        let finishID = p.operations[1].id
        guard case var .finish3D(fp) = p.operations[1].kind else { Issue.record("not a finish"); return }
        let rasterJob = CAMEngine.generate(p)
        fp.strategy = strategy
        p.operations[1].kind = .finish3D(fp)
        let started = Date()
        let job = CAMEngine.generate(p)
        let seconds = Date().timeIntervalSince(started)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        #expect(seconds < 30, "\(strategy) took \(seconds) s to work out")
        let tp = try #require(job.toolpaths.first { $0.id == finishID })
        #expect(!tp.isEmpty)
        let gouge = RestFinishingTests.pathGouge(tp, project: p)
        #expect(gouge < 0.002, "\(strategy) cuts \(gouge) mm below the drop-cutter surface")
        let runTime = try #require(job.estimatedSeconds(toolpath: finishID))
        #expect(runTime > 60 && runTime < 3600, "\(strategy) runs \(runTime) s")
        // In simulation, after the roughing, no deeper into the model than the raster finish.
        func deepest(_ j: JobResult) -> Double {
            let grids = RestFinishingTests.simulate(Array(j.toolpaths.prefix(2)), stock: p.stock, cell: 0.2)
            let g = grids[1]
            let model = RestFinishingTests.modelSurface(p, on: g)
            var worst = 0.0
            for i in g.heights.indices where model.covered[i] { worst = max(worst, Double(model.heights[i]) - Double(g.heights[i])) }
            return worst
        }
        let mine = deepest(job), raster = deepest(rasterJob)
        #expect(mine <= raster + 0.01, "\(strategy) cuts \(mine) mm below the model in simulation, the raster \(raster) mm")
    }

    // MARK: A coin

    /// A spiral on the coin inside its round boundary is one continuous cut from the centre out; a radial is linked
    /// spoke to spoke, mostly along the surface. Both stay inside the boundary and don't gouge, with every bit.
    @Test(arguments: [ToolShape.ballNose, .taperedBallNose, .bullNose, .flatEndMill])
    func spiralAndRadialOnTheCoin(_ shape: ToolShape) throws {
        var tool = shape == .ballNose ? Self.ball : ToolLibrary.template(for: shape)
        if shape == .bullNose { tool.diameter = 0.25.inch; tool.cornerRadius = 1 }
        for strategy in [Finish3DStrategy.spiral, .radial, .constantScallop] {
            let p = FinishingPatternsCatalogTests.coinProject(Finish3DParams(stepoverFraction: 0.2, boundary: .vectors, strategy: strategy),
                                                              tool: tool)
            let job = CAMEngine.generate(p)
            #expect(!job.hasErrors, "\(job.issues.map(\.message))")
            let tp = try #require(job.toolpaths.first)
            #expect(!tp.isEmpty, "\(strategy) with \(shape)")
            let gouge = RestFinishingTests.pathGouge(tp, project: p)
            #expect(gouge < 0.002, "\(strategy) with \(shape) cuts \(gouge) mm into the coin")
            let regions = try FinishingPatternsCatalogTests.regions(p, p.operations[0])
            let outside = Self.farthestOutside(tp, regions)
            #expect(outside < 0.01, "\(strategy) with \(shape) goes \(outside) mm outside the boundary")
            let plunges = Self.plunges(tp).count
            switch strategy {
            case .spiral: #expect(plunges == 1, "spiral with \(shape): \(plunges) plunges")
            case .radial: #expect(plunges < 12, "radial with \(shape): \(plunges) plunges")
            default: #expect(plunges < 6, "constant scallop with \(shape): \(plunges) plunges")
            }
            if shape == .flatEndMill { #expect(tp.warnings.contains { $0.contains("smoother 3D finish") }) }
        }
    }

    /// A scallop height set with a flat end mill can't be held: the stepover sets the spacing, and Checks says so.
    @Test func aScallopTargetWithAFlatEndMillFallsBackToTheStepover() throws {
        let flat = ToolLibrary.starter.tool(number: 1)!
        let params = Finish3DParams(stepoverFraction: 0.2, boundary: .vectors, strategy: .constantScallop, scallopHeight: 0.05)
        #expect(params.stepoverInUse(tool: flat) == flat.diameter * 0.2)
        let job = CAMEngine.generate(FinishingPatternsCatalogTests.coinProject(params, tool: flat))
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("no rounded tip to hold a scallop height") }, "\(tp.warnings)")
    }
}
