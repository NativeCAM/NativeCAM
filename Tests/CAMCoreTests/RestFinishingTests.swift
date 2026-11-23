import Foundation
import Testing
import simd
@testable import CAMCore

/// 3D rest finishing (#83): a smaller ball or tapered ball nose after a larger ball's finish, cutting only where the
/// larger ball couldn't reach, worked out exactly with the drop-cutter rather than from its passes.
struct RestFinishingTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "2E570000-0000-4000-8000-%012d", n))! }

    /// The tool library's tapered ball nose template (1/32" tip radius, 1.79° per side, 1/4" shank) as T12.
    static var tapered: Tool {
        var t = ToolLibrary.template(for: .taperedBallNose)
        t.id = id(900)
        t.number = 12
        t.name = "1/16\" Tapered Ball Nose"
        return t
    }

    static let ball = ToolLibrary.starter.tool(number: 7)! // 1/4" ball nose

    /// A 1/8" ball nose as T11.
    static var eighthBall: Tool {
        var t = ball
        t.id = id(901)
        t.diameter = 0.125.inch
        t.name = "1/8\" Ball Nose"
        t.number = 11
        return t
    }

    static func restParams(stepover: Double = 0.1, angle: Double = 45, boundary: ModelBoundary = .vectors,
                           rest: RestSettings = RestSettings()) -> Finish3DParams {
        Finish3DParams(stepoverFraction: stepover, rasterAngle: angle, boundary: boundary, strategy: .rest, rest: rest)
    }

    // MARK: Fixtures

    /// The demo relief with a tapered-ball rest pass after its 1/4" ball finish (before the cut-out).
    static func reliefRest() -> Project {
        var p = Project.demoRelief()
        let finish = p.operations[1]
        let op = CAMOperation(id: id(1), name: "Rest relief", kind: .finish3D(restParams(rest: .defaults(for: .inch))),
                              shapeIDs: finish.shapeIDs, tool: tapered)
        p.operations.insert(op, at: 2)
        return p
    }

    /// A valley covering a 30 × 20 mm board: faces of 28° and 25° meeting in a crease along Y at x = 13, 8 mm below
    /// the board's top at its deepest. A 1/4" ball can't reach within about 1.6 mm of the crease.
    static func valley(meshID: UUID = id(10), shapeID: UUID = id(11)) -> DesignShape {
        let mesh = extrudedProfile([(0, 8), (13, 1), (30, 9)], width: 20, id: meshID)
        return DesignShape(id: shapeID, name: "Valley", kind: .model(ModelSpec(mesh: mesh, depth: 9)), position: Vec2(15, 10))
    }

    static let valleyStock = Stock(width: 30, height: 20, thickness: 12, clearanceHeight: 10, plungeHeight: 2)

    /// The valley finished with the 1/4" ball (raster across the crease), then rested with `restTool`.
    static func valleyProject(ballStepover: Double = 0.25, restTool: Tool = tapered, rest: RestSettings = RestSettings(),
                              restStepover: Double = 0.2, units: LengthUnit = .mm, name: String = "Valley rest") -> Project {
        let shape = valley()
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = units
        let finish = CAMOperation(id: id(2), name: "Finish valley",
                                  kind: .finish3D(Finish3DParams(stepoverFraction: ballStepover, rasterAngle: 0, boundary: .material)),
                                  shapeIDs: [shape.id], tool: ball)
        let restOp = CAMOperation(id: id(3), name: "Rest valley",
                                  kind: .finish3D(restParams(stepover: restStepover, angle: 90, boundary: .material, rest: rest)),
                                  shapeIDs: [shape.id], tool: restTool)
        return Project(name: name, displayUnits: units, stock: valleyStock, machine: machine, shapes: [shape], operations: [finish, restOp])
    }

    /// Material after each toolpath in turn, on a grid of `cell`.
    static func simulate(_ toolpaths: [Toolpath], stock: Stock, cell: Double) -> [HeightGrid] {
        var sim = MaterialSimulator(stock: stock, cellSize: cell)
        var out: [HeightGrid] = []
        for tp in toolpaths {
            tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
            out.append(sim.grid)
        }
        return out
    }

    /// The models' top surface at the grid's cell centres (uncovered off the models).
    static func modelSurface(_ project: Project, on g: HeightGrid) -> SurfaceGrid {
        let area = Rect2(min: g.origin, max: g.origin + Vec2(Double(g.columns - 1), Double(g.rows - 1)) * g.cellSize)
        return ModelRaster.surface(of: project.shapes.filter { $0.modelSpec != nil }, over: area, cellSize: g.cellSize)
    }

    /// How far below the exact drop-cutter surface a toolpath's feed moves go, sampled every `step` mm.
    static func pathGouge(_ tp: Toolpath, project: Project, step: Double = 0.02) -> Double {
        let models = project.shapes.filter { $0.modelSpec != nil }
        guard let cutter = TriangleDropCutter(tool: tp.tool, allowance: 0, triangles: Model3DGenerator.triangles(of: models)) else { return 0 }
        var worst = 0.0
        var hint: Int32 = -1
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            for q in [s] + m.samples(from: s, maxStep: step) {
                let z = cutter.z(at: q.xy, hint: &hint)
                if z.isFinite { worst = max(worst, z - q.z) }
            }
        }
        return worst
    }

    // MARK: The demo relief

    /// A 1/4" ball finish, then a tapered-ball rest pass on the demo relief, checked in simulation (0.1 mm cells): the
    /// rest pass cuts nothing below the model, touches nothing beyond its rest areas (plus its bit's reach), only skims
    /// where the ball had already finished (its scallops), and cleans up nearly all of what the ball left. On this relief
    /// that's the band round its foot, where it meets the floor cleared round it: the ripples and rim are gentle enough
    /// for the ball.
    @Test func reliefRestTouchesOnlyLeftOverMaterial() throws {
        var p = Self.reliefRest()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let rest = try #require(job.toolpaths.first { $0.id == Self.id(1) })
        #expect(rest.warnings.isEmpty, "\(rest.warnings)")
        #expect(!rest.isEmpty)
        let areas = Region.nest(try #require(rest.restAreas))
        let restArea = areas.reduce(0) { $0 + $1.area }
        // A small part of what the finish covers (the outline's ellipse).
        let outline = Double.pi * 76.5 * 51.5
        #expect(restArea > 100 && restArea < 0.12 * outline, "rest areas \(restArea) mm²")

        // The path itself never goes below the exact surface (arc fitting can add its tolerance).
        p.machine.outputArcs = false
        let straight = try #require(CAMEngine.generate(p).toolpaths.first { $0.id == Self.id(1) })
        #expect(Self.pathGouge(straight, project: p) < 1e-6)
        // Arc fitting merges moves within its tolerance, which on a steep wall is a little more than that in Z.
        #expect(Self.pathGouge(rest, project: p) < 3 * p.machine.arcFitTolerance)

        let tps = Array(job.toolpaths.prefix(3))
        #expect(tps.map(\.name) == ["Rough relief", "Finish relief", "Rest relief"])
        let grids = Self.simulate(tps, stock: p.stock, cell: 0.1)
        let afterBall = grids[1], afterRest = grids[2]
        let model = Self.modelSurface(p, on: afterBall)
        try #require(model.columns == afterBall.columns && model.rows == afterBall.rows)
        // Where the rest bit could touch: within its tip's radius of the areas its centre goes, or of the ramps into them
        // (along a row, a tool radius long), and a cell or two spare.
        let ramp = max(1, Self.tapered.radius)
        let reach = Model3DGenerator.Mask(areas.flatMap { $0.offset(by: ramp + Self.tapered.tipDiameter / 2 + 0.2) }, pitch: 0.1)
        let tol = RestSettings.defaults(for: .inch).tolerance
        let scallop = 0.032 // the ball's, at a 10% stepover
        var deepest = 0.0, strayCut = 0.0, skim = 0.0
        var left = 0, cleaned = 0, cut = 0
        for r in 0..<afterBall.rows {
            for c in 0..<afterBall.columns {
                let i = r * afterBall.columns + c
                guard model.covered[i] else { continue }
                let m = Double(model.heights[i])
                let l1 = Double(afterBall.heights[i]) - m, l2 = Double(afterRest.heights[i]) - m
                let removed = l1 - l2
                deepest = max(deepest, -l2)
                if removed > 0.002 { cut += 1 }
                if !reach.contains(afterBall.origin + Vec2(Double(c), Double(r)) * afterBall.cellSize) { strayCut = max(strayCut, removed) }
                if l1 <= tol { skim = max(skim, removed - max(0, l1)) }
                if l1 > 0.1 {
                    left += 1
                    if l2 < tol { cleaned += 1 }
                }
            }
        }
        // No cut below the model beyond the simulator's own sampling on the mesh's jagged edge (the ball's finish
        // measures 0.02 mm there too).
        #expect(deepest < 0.04, "cuts \(deepest) mm below the model")
        #expect(strayCut < 1e-4, "cuts \(strayCut) mm outside its areas")
        // Where the ball had finished it only takes the tops off its scallops (and the simulator's slack).
        #expect(skim < scallop + 0.04, "removes \(skim) mm where the ball had finished")
        #expect(cut > 1000)
        #expect(Double(cleaned) > 0.9 * Double(left), "cleans \(cleaned) of \(left) cells the ball left over 0.1 mm on")
    }

    /// The rest pass estimates far faster than finishing the whole relief with the tapered ball.
    @Test func reliefRestEstimatesFasterThanAFullTaperedFinish() throws {
        let p = Self.reliefRest()
        let job = CAMEngine.generate(p)
        let restTime = try #require(job.estimatedSeconds(toolpath: Self.id(1)))
        var full = p
        guard case var .finish3D(fp) = full.operations[2].kind else { Issue.record("not a finish"); return }
        fp.strategy = .raster
        full.operations[2].kind = .finish3D(fp)
        let fullJob = CAMEngine.generate(full)
        let fullTime = try #require(fullJob.estimatedSeconds(toolpath: Self.id(1)))
        #expect(restTime > 0)
        #expect(restTime < fullTime / 2, "rest \(restTime) s, full finish \(fullTime) s")
        #expect(job.estimatedSeconds < fullJob.estimatedSeconds)
    }

    // MARK: What counts as left over

    /// The ball's own scallops don't count, however tall: with a 40% stepover (scallops about 0.27 mm tall, far over the
    /// tolerance) the rest areas are still only the band along the crease the ball couldn't reach into.
    @Test func restAreasFollowTheCreaseNotTheScallops() throws {
        let p = Self.valleyProject(ballStepover: 0.4)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let rest = try #require(job.toolpaths.first { $0.id == Self.id(3) })
        let loops = try #require(rest.restAreas)
        #expect(!loops.isEmpty)
        // Model x = design x here (the board is the model). The ball's tangent points are 1.6 mm from the crease; the
        // areas are where the tapered ball's centre goes, grown by the 0.5 mm margin.
        var far = 0.0
        for loop in loops { for q in loop.points { far = max(far, abs(q.x - 13)) } }
        #expect(far < 1.6 + 0.5 + 0.5, "a rest area reaches \(far) mm from the crease")
        let regions = Region.nest(loops)
        for y in stride(from: 1.0, through: 19.0, by: 2) {
            #expect(regions.contains { $0.contains(Vec2(13, y)) }, "the crease at y = \(y) isn't in a rest area")
            #expect(!regions.contains { $0.contains(Vec2(5, y)) || $0.contains(Vec2(22, y)) }, "an open face at y = \(y) is")
        }
        // Every rest cut is near the crease.
        var stray: [Vec3] = []
        rest.forEachMotion { s, m in
            guard m.kind == .feed, m.end.z < -1e-6, abs(m.end.x - 13) > 3 else { return }
            stray.append(m.end)
        }
        #expect(stray.isEmpty, "rest cuts at \(stray.prefix(4))")
    }

    /// Simulated, the tapered ball cleans the crease the ball left: from about 0.38 mm thick to within the tolerance.
    @Test func valleyRestCleansTheCrease() throws {
        let p = Self.valleyProject()
        let job = CAMEngine.generate(p)
        let grids = Self.simulate(job.toolpaths, stock: p.stock, cell: 0.05)
        let model = Self.modelSurface(p, on: grids[0])
        func left(_ g: HeightGrid, at q: Vec2) -> Double {
            let c = Int(((q.x - g.origin.x) / g.cellSize).rounded()), r = Int(((q.y - g.origin.y) / g.cellSize).rounded())
            let i = r * g.columns + c
            return Double(g.heights[i]) - Double(model.heights[i])
        }
        for y in stride(from: 3.0, through: 17.0, by: 2) {
            let q = Vec2(13, y)
            #expect(left(grids[0], at: q) > 0.3, "the ball left \(left(grids[0], at: q)) mm at y = \(y)")
            #expect(left(grids[1], at: q) < 0.13, "the rest pass left \(left(grids[1], at: q)) mm at y = \(y)")
            #expect(left(grids[1], at: q) > -0.01)
        }
    }

    /// A reference that's itself a rest pass counts only where it cut. In a sharp V (faces at 50°), a 3/16" ball rest
    /// after the 1/4" ball, then the tapered ball resting on both, which leaves it a narrower band than resting on the
    /// 1/4" ball alone. (In the shallower valley the 3/16" ball finds nothing left over the tolerance, so it would cut
    /// nothing and count for nothing.)
    @Test func aRestPassCanFollowAnotherRestPass() throws {
        let mesh = extrudedProfile([(0, 13), (10, 1), (20, 13)], width: 20, id: Self.id(12))
        let vee = DesignShape(id: Self.id(11), name: "Vee", kind: .model(ModelSpec(mesh: mesh, depth: 13)), position: Vec2(10, 10))
        func project(middle: Bool) -> Project {
            var p = Self.valleyProject()
            p.shapes = [vee]
            p.stock = Stock(width: 20, height: 20, thickness: 16, clearanceHeight: 10, plungeHeight: 2)
            if middle {
                var op = p.operations[1]
                op.id = Self.id(4)
                op.name = "Rest with 3/16\" ball"
                op.tool = Self.eighthBall
                op.tool.diameter = 0.1875.inch
                op.tool.name = "3/16\" Ball Nose"
                p.operations.insert(op, at: 1)
            }
            return p
        }
        let p = project(middle: true)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let refs = RestMachining.references(for: p.operations[2], in: p)
        #expect(refs.operations.map(\.id) == [Self.id(2), Self.id(4)])
        let middle = try #require(job.toolpaths.first { $0.id == Self.id(4) })
        #expect(!middle.isEmpty)
        let last = try #require(job.toolpaths.first { $0.id == Self.id(3) })
        let alone = try #require(CAMEngine.generate(project(middle: false)).toolpaths.first { $0.id == Self.id(3) })
        let area = Region.nest(last.restAreas ?? []).reduce(0) { $0 + $1.area }
        let areaAlone = Region.nest(alone.restAreas ?? []).reduce(0) { $0 + $1.area }
        #expect(area > 10 && area < 0.85 * areaAlone, "\(area) mm² after the 3/16\" ball, \(areaAlone) mm² without")
    }

    /// The pencil option adds passes along the crease inside the rest areas.
    @Test func pencilOptionRunsAlongTheCrease() throws {
        let plain = try #require(CAMEngine.generate(Self.valleyProject()).toolpaths.first { $0.id == Self.id(3) })
        var rest = RestSettings()
        rest.pencil = true
        let p = Self.valleyProject(rest: rest)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first { $0.id == Self.id(3) })
        #expect(tp.cuttingLength > plain.cuttingLength + 15, "\(tp.cuttingLength) vs \(plain.cuttingLength)")
        // Along the crease at the tapered ball's tip height there: its centre 0.79 mm off both faces.
        var along: [Double] = []
        tp.forEachMotion { _, m in
            if m.kind == .feed, abs(m.end.x - 13) < 0.3, m.end.z < -7 { along.append(m.end.y) }
        }
        #expect((along.max() ?? 0) - (along.min() ?? 0) > 15, "the pencil pass covers \(along.min() ?? 0)…\(along.max() ?? 0)")
    }

    // MARK: References and checks

    @Test func automaticReferencesAreEarlierLargerFinishesOfTheSameModel() throws {
        var p = Self.valleyProject()
        // A pencil pass and a later finish don't count; nor does a finish of another model, or a roughing.
        let other = DesignShape(id: Self.id(20), name: "Other", kind: .model(ModelSpec(mesh: hemisphereMesh(radius: 5), depth: 3)),
                                position: Vec2(5, 5))
        p.shapes.append(other)
        let pencil = CAMOperation(id: Self.id(21), name: "Pencil", kind: .finish3D(Finish3DParams(strategy: .pencil)),
                                  shapeIDs: [Self.id(11)], tool: Self.ball)
        let elsewhere = CAMOperation(id: Self.id(22), name: "Other finish", kind: .finish3D(Finish3DParams()), shapeIDs: [other.id], tool: Self.ball)
        let rough = CAMOperation(id: Self.id(23), name: "Rough", kind: .rough3D(Rough3DParams()), shapeIDs: [Self.id(11)],
                                 tool: ToolLibrary.starter.tool(number: 1)!)
        let later = CAMOperation(id: Self.id(24), name: "Later", kind: .finish3D(Finish3DParams()), shapeIDs: [Self.id(11)], tool: Self.ball)
        p.operations.insert(contentsOf: [pencil, elsewhere, rough], at: 1)
        p.operations.append(later)
        let refs = RestMachining.references(for: p.operations[4], in: p)
        #expect(refs.isAutomatic)
        #expect(refs.operations.map(\.id) == [Self.id(2)])
        #expect(refs.warnings.isEmpty && refs.refusal == nil)
        // Off, it doesn't count, and with nothing else there's nothing to rest from: the rest pass cuts nothing and says so.
        p.operations[0].enabled = false
        let none = RestMachining.references(for: p.operations[4], in: p)
        #expect(none.operations.isEmpty)
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first { $0.id == Self.id(3) })
        #expect(tp.isEmpty)
        #expect(tp.warnings.contains { $0.contains("nothing to rest from") })
        #expect(!job.issues.contains { $0.operation == "Rest valley" && $0.message == "Toolpath is empty." })
    }

    @Test func aDeletedReferenceIsReported() {
        var p = Self.valleyProject()
        guard case var .finish3D(fp) = p.operations[1].kind else { return }
        fp.rest?.references = [Self.id(2), Self.id(99)]
        p.operations[1].kind = .finish3D(fp)
        let refs = RestMachining.references(for: p.operations[1], in: p)
        #expect(!refs.isAutomatic)
        #expect(refs.operations.map(\.id) == [Self.id(2)])
        #expect(refs.warnings == ["One of its references has been deleted, so it isn't counted."])
    }

    @Test func onlyBallAndTaperedBallNosesRest() throws {
        let p = Self.valleyProject(restTool: ToolLibrary.starter.tool(number: 2)!)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first { $0.id == Self.id(3) })
        #expect(tp.isEmpty)
        #expect(tp.warnings.contains { $0.contains("needs a ball nose or a tapered ball nose") })
    }

    // MARK: Format

    @Test func restRaisesTheFormatTo17OnlyWhenUsedAndRoundTrips() throws {
        let p = Self.valleyProject()
        #expect(p.formatVersion == 17)
        let back = try Project.decode(p.encoded())
        #expect(back == p)
        // The same finish without the rest pass stays as old as it was.
        var plain = p
        plain.operations.removeLast()
        #expect(plain.formatVersion < 17)
        #expect(Project.demoRelief().formatVersion == 1)
        // Settings for rest finishing on another strategy are kept, but don't raise the format.
        guard case var .finish3D(fp) = p.operations[1].kind else { return }
        fp.strategy = .raster
        #expect(fp.requiredFormatVersion == 1)
        // A plain finish encodes exactly as before: no "rest" key.
        let json = String(decoding: try JSONEncoder().encode(Finish3DParams()), as: UTF8.self)
        #expect(!json.contains("rest"))
        let every = Finish3DParams(stepoverFraction: 0.2, rasterAngle: 30, boundary: .vectors, strategy: .rest, crossHatch: true,
                                   rest: RestSettings(references: [Self.id(2)], tolerance: 0.03, margin: 0.8, pencil: true))
        #expect(try JSONDecoder().decode(Finish3DParams.self, from: JSONEncoder().encode(every)) == every)
        #expect(abs(RestSettings.defaults(for: .inch).tolerance - 0.0508) < 1e-9 && abs(RestSettings.defaults(for: .inch).margin - 0.508) < 1e-9)
    }
}
