import Foundation
import Testing
@testable import CAMCore

/// Cut direction on the toolpaths whose passes run in rows, rings or a pattern (#137): every cutting move is checked
/// against the material side, by toolpath kind. Flat toolpaths are checked two ways: rows exactly (every move along the
/// raster goes the one way the direction asks), and every feed against the material a simulation of the cut so far
/// leaves either side of it (climbing keeps the higher side on the tool's right, M3). Loops are checked against the
/// model (waterline) or the centre they go round (spiral, constant scallop, spokes), and rotary toolpaths on the
/// unrolled blank.
struct CutDirectionTests {
    static var ball: Tool { ToolLibrary.starter.tool(number: 7)! } // 1/4" ball nose
    static var endMill: Tool { ToolLibrary.starter.tool(number: 1)! } // 1/4" end mill
    static var vBit: Tool { ToolLibrary.starter.tool(number: 6)! } // 90° V-bit

    // MARK: Measures

    /// Lengths of the feed moves along the raster at `angle` (degrees) that go forward (at the angle) and back.
    /// `within` limits it to moves whose middle it holds.
    static func rowTravel(_ tp: Toolpath, angle: Double, within: (Vec2) -> Bool = { _ in true }) -> (forward: Double, back: Double) {
        let dir = Vec2.fromAngle(angle.radians)
        var forward = 0.0, back = 0.0
        var at = tp.start
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .feed else { continue }
            let d = m.end.xy - at.xy
            let u = d.dot(dir), v = d.dot(dir.perpLeft)
            guard abs(v) < 1e-6, abs(u) > 0.01, within(at.xy.lerp(to: m.end.xy, 0.5)) else { continue }
            if u > 0 { forward += abs(u) } else { back += abs(u) }
        }
        return (forward, back)
    }

    /// Lengths of the feed moves that climb (the material left by the cut so far higher on the tool's right, `offset`
    /// out from its centre) and that go conventional (higher on its left), simulating the toolpaths in turn from the
    /// stock. Only `measured`'s moves are counted.
    static func sides(_ toolpaths: [Toolpath], measured: UUID, stock: Stock, offset: Double, cell: Double = 0.1)
        -> (climb: Double, conventional: Double) {
        var sim = MaterialSimulator(stock: stock, cellSize: cell)
        var climb = 0.0, conventional = 0.0
        for tp in toolpaths {
            var at = tp.start
            for m in tp.motions {
                if tp.id == measured, m.kind == .feed || m.kind.isArc {
                    // Arcs (the rings' rounded corners) as chords.
                    var from = at
                    for q in m.samples(from: at, maxStep: 0.5) {
                        defer { from = q }
                        let d = q.xy - from.xy
                        let length = d.length
                        guard length > 0.005 else { continue }
                        let u = d / length
                        let mid = from.xy.lerp(to: q.xy, 0.5)
                        if let r = sim.grid.height(at: mid + u.perpRight * offset), let l = sim.grid.height(at: mid + u.perpLeft * offset) {
                            let diff = Double(r - l)
                            if diff > 0.02 { climb += length } else if diff < -0.02 { conventional += length }
                        }
                    }
                }
                sim.apply(m, from: at, tool: tp.tool)
                at = m.end
            }
        }
        return (climb, conventional)
    }

    /// Lengths of a toolpath's feed moves going counter-clockwise and clockwise round `centre`, and out from it and in.
    static func turning(_ tp: Toolpath, about centre: Vec2) -> (ccw: Double, cw: Double, out: Double, in: Double) {
        var ccw = 0.0, cw = 0.0, out = 0.0, inward = 0.0
        var at = tp.start
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .feed else { continue }
            let d = m.end.xy - at.xy
            let length = d.length
            guard length > 0.02 else { continue }
            let r = at.xy.lerp(to: m.end.xy, 0.5) - centre
            guard r.length > 0.5 else { continue }
            let radial = d.dot(r.normalized), around = r.normalized.cross(d)
            if abs(radial) > 0.95 * length {
                if radial > 0 { out += length } else { inward += length }
            } else if abs(around) > 0.9 * length {
                if around > 0 { ccw += length } else { cw += length }
            }
        }
        return (ccw, cw, out, inward)
    }

    /// Lengths of a waterline's level moves with the model higher on their right (climb) and on their left.
    static func waterlineSides(_ tp: Toolpath, project p: Project) throws -> (climb: Double, conventional: Double) {
        let models = p.shapes.filter { $0.modelSpec != nil }
        let cutter = try #require(TriangleDropCutter(tool: tp.tool, allowance: 0, triangles: Model3DGenerator.triangles(of: models)))
        var climb = 0.0, conventional = 0.0
        var at = tp.start
        var hint: Int32 = -1
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .feed, abs(m.end.z - at.z) < 1e-6 else { continue }
            let d = m.end.xy - at.xy
            let length = d.length
            guard length > 0.1 else { continue }
            let u = d / length, mid = at.xy.lerp(to: m.end.xy, 0.5)
            let r = cutter.z(at: mid + u.perpRight * 0.3, hint: &hint), l = cutter.z(at: mid + u.perpLeft * 0.3, hint: &hint)
            let right = r.isFinite ? r : -.infinity, left = l.isFinite ? l : -.infinity
            if right > left + 1e-3 { climb += length } else if left > right + 1e-3 { conventional += length }
        }
        return (climb, conventional)
    }

    // MARK: Jobs

    static func dish() -> DesignShape { Rough3DAdaptiveCatalogTests.dish() }

    static func dishJob(_ kind: OperationKind, tool: Tool = ball, name: String = "Cut direction") -> Project {
        let d = dish()
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = .mm
        machine.outputArcs = false
        let op = CAMOperation(id: CutDirectionCatalogTests.id(1), name: name, kind: kind, shapeIDs: [d.id], tool: tool)
        return Project(name: name, displayUnits: .mm, stock: Rough3DAdaptiveCatalogTests.stock, machine: machine, shapes: [d],
                       operations: [op])
    }

    static func finish(_ direction: PassDirection?, strategy: Finish3DStrategy = .raster, angle: Double = 0, crossHatch: Bool = false)
        -> Project {
        dishJob(.finish3D(Finish3DParams(stepoverFraction: 0.25, rasterAngle: angle, strategy: strategy, crossHatch: crossHatch,
                                         cutDirection: direction)))
    }

    static func toolpath(_ p: Project) throws -> Toolpath {
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        return try #require(job.toolpaths.last)
    }

    // MARK: Settings

    /// Each toolpath offers what its passes can hold, defaults to the way it has always cut, and stores the default as
    /// nil, so the file saves as before.
    @Test func choicesAndDefaults() {
        #expect(Finish3DParams().defaultDirection == .both)
        #expect(Finish3DParams(strategy: .waterline).directionChoices == [.climb, .conventional])
        #expect(Finish3DParams(strategy: .waterline).defaultDirection == .climb)
        #expect(Finish3DParams(strategy: .constantScallop).defaultDirection == .climb)
        #expect(Finish3DParams(strategy: .spiral).defaultDirection == .both)
        #expect(Rough3DParams().defaultDirection == .climb)
        #expect(Rough3DParams(clearing: .raster).defaultDirection == .both)
        #expect(Rough3DParams(clearing: .adaptive).directionChoices == [.climb, .conventional])
        #expect(VCarveParams().defaultDirection == .climb)
        #expect(VCarveParams(flatDepth: 1, flatRaster: VCarveRaster()).defaultDirection == .both)
        #expect(RotaryRoughParams(pattern: .offset).defaultDirection == .climb)
        #expect(RotaryRoughParams().defaultDirection == .both)
        var kind = OperationKind.finish3D(Finish3DParams(strategy: .waterline))
        kind.passDirection = .climb
        #expect(kind == .finish3D(Finish3DParams(strategy: .waterline)))
        kind.passDirection = .conventional
        #expect(kind.passDirection == .conventional)
        // A direction the strategy can't take falls back to its default.
        #expect(Finish3DParams(strategy: .waterline, cutDirection: .both).directionInUse == .climb)
        #expect(OperationKind.profile(ProfileParams(depth: DepthSettings(cutDepth: 3))).passDirectionChoices == nil)
    }

    // MARK: 3D finishing

    /// Raster rows climb: every row runs back against the raster angle (up the raster, the next row's material on the
    /// right), and the material either side agrees; conventional runs every row forward. Both ways still zig-zags.
    @Test(arguments: [PassDirection.climb, .conventional, .both])
    func rasterRows(_ direction: PassDirection) throws {
        let p = Self.finish(direction)
        let tp = try Self.toolpath(p)
        let rows = Self.rowTravel(tp, angle: 0)
        let s = Self.sides([tp], measured: tp.id, stock: p.stock, offset: 0.75 * tp.tool.radius)
        switch direction {
        case .climb:
            #expect(rows.forward == 0 && rows.back > 500, "\(rows)")
            #expect(s.conventional < 0.05 * s.climb, "\(s)")
        case .conventional:
            #expect(rows.back == 0 && rows.forward > 500, "\(rows)")
            #expect(s.climb < 0.05 * s.conventional, "\(s)")
        case .both:
            #expect(rows.forward > 0.3 * rows.back && rows.back > 0.3 * rows.forward, "\(rows)")
        }
        // The links back never gouge the model.
        #expect(RestFinishingTests.pathGouge(tp, project: p) < 1e-6)
    }

    /// One way is timed against both ways with the planner, and takes longer.
    @Test func oneWayIsTimedAgainstBothWays() throws {
        let tp = try Self.toolpath(Self.finish(.climb))
        let time = try #require(tp.directionTime)
        #expect(time.extraSeconds > 0, "\(time)")
        #expect(try Self.toolpath(Self.finish(nil)).directionTime == nil)
    }

    /// Cross-hatching: both rasters hold the direction, each up its own raster.
    @Test func crossHatchHoldsTheDirection() throws {
        let tp = try Self.toolpath(Self.finish(.climb, angle: 30, crossHatch: true))
        for angle in [30.0, 120] {
            let rows = Self.rowTravel(tp, angle: angle)
            #expect(rows.forward == 0 && rows.back > 300, "\(angle)°: \(rows)")
        }
    }

    /// Steep and shallow: Conventional sets both the rows and the waterline loops.
    @Test func steepAndShallowGoesConventional() throws {
        let p = Self.finish(.conventional, strategy: .steepShallow)
        let tp = try Self.toolpath(p)
        let rows = Self.rowTravel(tp, angle: 0)
        // Its waterline loops' straight runs along X count too, a little.
        #expect(rows.forward > 100 && rows.back < 0.1 * rows.forward, "\(rows)")
        let w = try Self.waterlineSides(tp, project: p)
        #expect(w.conventional > 0 && w.climb < 0.1 * w.conventional, "\(w)")
    }

    /// Waterline loops climb by default (the model on their right), and Conventional turns every loop round.
    @Test(arguments: [PassDirection.climb, .conventional])
    func waterlineLoops(_ direction: PassDirection) throws {
        let p = FinishingPatternsCatalogTests.coinProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .waterline,
                                                                         cutDirection: direction))
        let tp = try Self.toolpath(p)
        let w = try Self.waterlineSides(tp, project: p)
        if direction == .climb {
            #expect(w.climb > 50 && w.conventional < 0.05 * w.climb, "\(w)")
        } else {
            #expect(w.conventional > 50 && w.climb < 0.05 * w.conventional, "\(w)")
        }
    }

    /// Constant scallop loops climb (clockwise, the higher ground inside them on the right); Conventional goes
    /// counter-clockwise.
    @Test(arguments: [PassDirection.climb, .conventional])
    func constantScallopLoops(_ direction: PassDirection) throws {
        let p = FinishingPatternsCatalogTests.coinProject(Finish3DParams(boundary: .vectors, strategy: .constantScallop, scallopHeight: 0.1,
                                                                         cutDirection: direction))
        let t = Self.turning(try Self.toolpath(p), about: FinishingPatternsCatalogTests.coinCentre)
        if direction == .climb {
            #expect(t.cw > 100 && t.ccw < 0.05 * t.cw, "\(t)")
        } else {
            #expect(t.ccw > 100 && t.cw < 0.05 * t.ccw, "\(t)")
        }
    }

    /// A spiral in the dish's rectangle: by default the arcs past where it first meets the boundary go both ways; Climb
    /// cuts every one counter-clockwise (and says what it costs), Conventional winds it all clockwise.
    @Test(arguments: [PassDirection.climb, .conventional, .both])
    func spiralArcs(_ direction: PassDirection) throws {
        let p = Self.finish(direction, strategy: .spiral)
        let tp = try Self.toolpath(p)
        let t = Self.turning(tp, about: Vec2(40, 30))
        switch direction {
        case .climb:
            #expect(t.ccw > 500 && t.cw < 0.03 * t.ccw, "\(t)")
            #expect((tp.directionTime?.extraSeconds ?? 0) > 0)
        case .conventional:
            #expect(t.cw > 500 && t.ccw < 0.03 * t.cw, "\(t)")
        case .both:
            #expect(t.cw > 0.05 * t.ccw, "\(t)")
        }
        #expect(RestFinishingTests.pathGouge(tp, project: p) < 1e-6)
    }

    /// Radial spokes one way: the next spoke round (counter-clockwise) is on the left going out, so climb comes in and
    /// conventional goes out.
    @Test(arguments: [PassDirection.climb, .conventional])
    func radialSpokes(_ direction: PassDirection) throws {
        let p = FinishingPatternsCatalogTests.coinProject(Finish3DParams(stepoverFraction: 0.25, boundary: .vectors, strategy: .radial,
                                                                         cutDirection: direction))
        let t = Self.turning(try Self.toolpath(p), about: FinishingPatternsCatalogTests.coinCentre)
        if direction == .climb {
            #expect(t.in > 100 && t.out < 0.03 * t.in, "\(t)")
        } else {
            #expect(t.out > 100 && t.in < 0.03 * t.out, "\(t)")
        }
    }

    /// Pencil passes run along creases with the model on both sides: Climb cuts them as both ways and says so.
    @Test func pencilCantHoldADirection() throws {
        let p = Self.finish(.climb, strategy: .pencil)
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let both = try #require(CAMEngine.generate(Self.finish(nil, strategy: .pencil)).toolpaths.first)
        #expect(tp.motions == both.motions)
        #expect(tp.warnings.contains { $0.hasPrefix("Pencil passes run along creases") })
        #expect(job.issues.contains { $0.message.hasPrefix("Pencil passes run along creases") })
        #expect(p.formatVersion < PassDirection.formatVersion)
    }

    // MARK: 3D roughing

    /// Raster 3D roughing one way: every line runs the same way, against the material it steps into.
    @Test(arguments: [PassDirection.climb, .conventional])
    func roughingRows(_ direction: PassDirection) throws {
        let p = Self.dishJob(.rough3D(Rough3DParams(allowance: 0.5, clearing: .raster, rasterAngle: 30, cutDirection: direction)),
                             tool: Self.endMill)
        let tp = try Self.toolpath(p)
        let rows = Self.rowTravel(tp, angle: 30)
        let s = Self.sides([tp], measured: tp.id, stock: p.stock, offset: tp.tool.radius + 0.3)
        #expect(s.climb + s.conventional > 100, "\(s)")
        if direction == .climb {
            #expect(rows.forward == 0 && rows.back > 150, "\(rows)")
            #expect(s.conventional < 0.05 * s.climb, "\(s)")
        } else {
            #expect(rows.back == 0 && rows.forward > 150, "\(rows)")
            #expect(s.climb < 0.05 * s.conventional, "\(s)")
        }
    }

    /// Offset 3D roughing's rings climb by default; Conventional turns them round.
    @Test func offsetRoughingGoesConventional() throws {
        let p = Self.dishJob(.rough3D(Rough3DParams(allowance: 0.5, cutDirection: .conventional)), tool: Self.endMill)
        let tp = try Self.toolpath(p)
        let s = Self.sides([tp], measured: tp.id, stock: p.stock, offset: tp.tool.radius + 0.3)
        #expect(s.conventional > 100 && s.climb < 0.1 * s.conventional, "\(s)")
        var climbing = p
        climbing.operations[0].kind = .rough3D(Rough3DParams(allowance: 0.5))
        let c = try Self.toolpath(climbing)
        let sc = Self.sides([c], measured: c.id, stock: p.stock, offset: c.tool.radius + 0.3)
        #expect(sc.climb > 100 && sc.conventional < 0.1 * sc.climb, "\(sc)")
    }

    // MARK: V-carve

    /// A 40 × 20 mm rectangle carved 1.5 mm deep, its flat cleared by the V-bit in raster lines at 45°.
    static func vcarve(_ direction: PassDirection?) -> Project {
        let r = DesignShape(id: CutDirectionCatalogTests.id(2), name: "Panel", kind: .rectangle(width: 40, height: 20, cornerRadius: 0),
                            position: Vec2(30, 20))
        let params = VCarveParams(flatDepth: 1.5, sampleSpacing: 0.5, flatRaster: VCarveRaster(stepover: 1, angle: 45),
                                  cutDirection: direction)
        var machine = MachineProfile.avidPRO6060
        machine.outputUnits = .mm
        let op = CAMOperation(id: CutDirectionCatalogTests.id(3), name: "V-carve", kind: .vcarve(params), shapeIDs: [r.id], tool: vBit)
        let stock = Stock(width: 60, height: 40, thickness: 10, clearanceHeight: 10, plungeHeight: 2)
        return Project(name: "V-carve", displayUnits: .mm, stock: stock, machine: machine, shapes: [r], operations: [op])
    }

    /// The raster lines go one way, and the carve and the flat's edge pass keep the wall they follow on the right
    /// climbing, on the left going conventional.
    @Test(arguments: [PassDirection.climb, .conventional])
    func vcarveHoldsTheDirection(_ direction: PassDirection) throws {
        let p = Self.vcarve(direction)
        let tp = try Self.toolpath(p)
        // Away from the corners, where the carve runs along the 45° bisector.
        let rows = Self.rowTravel(tp, angle: 45) { abs($0.x - 30) < 17 && abs($0.y - 20) < 7 }
        // The walls: moves along X or Y, each with its nearest edge of the rectangle on one side.
        var right = 0.0, left = 0.0
        var at = tp.start
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .feed else { continue }
            let d = m.end.xy - at.xy
            guard d.length > 0.2, abs(d.x) < 1e-6 || abs(d.y) < 1e-6 else { continue }
            let q = at.xy.lerp(to: m.end.xy, 0.5) - Vec2(30, 20)
            let toEdge = 20 - abs(q.x) < 10 - abs(q.y) ? Vec2(q.x > 0 ? 1 : -1, 0) : Vec2(0, q.y > 0 ? 1 : -1)
            if d.cross(toEdge) < 0 { right += d.length } else { left += d.length }
        }
        if direction == .climb {
            #expect(rows.forward == 0 && rows.back > 100, "\(rows)")
            #expect(right > 100 && left == 0, "right \(right), left \(left)")
        } else {
            #expect(rows.back == 0 && rows.forward > 100, "\(rows)")
            #expect(left > 100 && right == 0, "right \(right), left \(left)")
        }
    }

    /// Without raster clearing a V-carve climbs by default, and its rings and carve go conventional when asked.
    @Test func vcarveRingsGoConventional() throws {
        var p = Self.vcarve(.conventional)
        guard case var .vcarve(v) = p.operations[0].kind else { return }
        v.flatRaster = nil
        p.operations[0].kind = .vcarve(v)
        let tp = try Self.toolpath(p)
        var q = p
        v.cutDirection = nil
        q.operations[0].kind = .vcarve(v)
        let climb = try Self.toolpath(q)
        let a = Self.turning(tp, about: Vec2(30, 20)), b = Self.turning(climb, about: Vec2(30, 20))
        #expect(a.cw > 100 && a.ccw < 0.05 * a.cw, "\(a)")
        #expect(b.ccw > 100 && b.cw < 0.05 * b.ccw, "\(b)")
    }

    // MARK: Fluting

    /// A flute is a slot: Conventional cuts it as both ways and says why, without raising the format.
    @Test func flutesCantHoldADirection() throws {
        let line = DesignShape(id: CutDirectionCatalogTests.id(4), name: "Flute", kind: .paths([Polyline([Vec2(-20, 0), Vec2(20, 0)], closed: false)]),
                               position: Vec2(30, 20))
        func job(_ d: PassDirection?) -> Project {
            let op = CAMOperation(kind: .fluting(FlutingParams(depth: 3, passDepth: 1, cutDirection: d)), shapeIDs: [line.id], tool: Self.ball)
            return Fixture.project(shapes: [line], ops: [op])
        }
        let jobC = CAMEngine.generate(job(.conventional))
        let tp = try #require(jobC.toolpaths.first)
        let both = try #require(CAMEngine.generate(job(nil)).toolpaths.first)
        #expect(tp.motions == both.motions)
        #expect(jobC.issues.contains { $0.message.hasPrefix("A flute is a slot") })
        #expect(job(.conventional).formatVersion < PassDirection.formatVersion)
    }

    // MARK: Rotary

    /// Lengths of a wrapped toolpath's feeds along the blank (no turn) going +X and −X, and of its turning feeds that
    /// step +X and −X as the blank turns forward.
    static func rotaryMoves(_ tp: Toolpath) -> (plusX: Double, minusX: Double, stepPlus: Double, stepMinus: Double, backward: Double) {
        var plusX = 0.0, minusX = 0.0, stepPlus = 0.0, stepMinus = 0.0, backward = 0.0
        var at = tp.start
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .feed else { continue }
            let dx = m.end.x - at.x, dy = m.end.y - at.y
            if abs(dy) < 1e-6 {
                if dx > 0.01 { plusX += dx } else if dx < -0.01 { minusX -= dx }
            } else if dy > 0 {
                if dx > 1e-6 { stepPlus += dy } else if dx < -1e-6 { stepMinus += dy }
            } else {
                backward -= dy
            }
        }
        return (plusX, minusX, stepPlus, stepMinus, backward)
    }

    /// Rounding Around: turning forward, every layer steps +X climbing and −X going conventional; both ways they
    /// alternate. Along: every pass runs −X climbing, +X conventional.
    @Test(arguments: [PassDirection.climb, .conventional, .both])
    func rounding(_ direction: PassDirection) throws {
        for method in [RoundingParams.Method.radial, .raster] {
            let p = RoundingTests.job(method: method) { p in
                p.operations[0].kind = .rounding(RoundingParams(method: method, passDepth: 3, cutDirection: direction))
            }
            let tp = try Self.toolpath(p)
            let m = Self.rotaryMoves(tp)
            #expect(m.backward == 0, "\(method): \(m)")
            switch (method, direction) {
            case (.radial, .climb): #expect(m.stepPlus > 0 && m.stepMinus == 0, "\(m)")
            case (.radial, .conventional): #expect(m.stepMinus > 0 && m.stepPlus == 0, "\(m)")
            case (.radial, _): #expect(m.stepMinus > 0 && m.stepPlus > 0, "\(m)")
            case (_, .climb): #expect(m.minusX > 0 && m.plusX == 0, "\(m)")
            case (_, .conventional): #expect(m.plusX > 0 && m.minusX == 0, "\(m)")
            default: #expect(m.plusX > 0 && m.minusX > 0, "\(m)")
            }
        }
    }

    /// 3D rotary finishing: a spiral steps one way along the blank; lines along X all run one way.
    @Test(arguments: [PassDirection.climb, .conventional])
    func rotaryFinishing(_ direction: PassDirection) throws {
        let spiral = Rotary3DTests.shallow(.spiral) { p in
            p.operations[0].kind = .rotaryFinish(RotaryFinishParams(pattern: .spiral, stepoverFraction: 0.25, cutDirection: direction))
        }
        let s = Self.rotaryMoves(try Self.toolpath(spiral))
        let lines = Rotary3DTests.shallow(.lines) { p in
            p.operations[0].kind = .rotaryFinish(RotaryFinishParams(pattern: .lines, stepoverFraction: 0.25, cutDirection: direction))
        }
        let l = Self.rotaryMoves(try Self.toolpath(lines))
        if direction == .climb {
            #expect(s.stepPlus > 0 && s.stepMinus == 0, "\(s)")
            #expect(l.minusX > 0 && l.plusX == 0, "\(l)")
        } else {
            #expect(s.stepMinus > 0 && s.stepPlus == 0, "\(s)")
            #expect(l.plusX > 0 && l.minusX == 0, "\(l)")
        }
    }

    /// 3D rotary roughing along the blank: every line (a stroke that only runs along X) runs −X climbing, +X
    /// conventional.
    @Test(arguments: [PassDirection.climb, .conventional])
    func rotaryRoughingLines(_ direction: PassDirection) throws {
        var p = Rotary3DRoughingTests.smallRough()
        guard case var .rotaryRough(r) = p.operations[0].kind else { return }
        r.pattern = .along
        r.cutDirection = direction
        p.operations[0].kind = .rotaryRough(r)
        let tp = try Self.toolpath(p)
        var plus = 0, minus = 0
        var stroke: [(dx: Double, dy: Double)] = []
        var at = tp.start
        func close() {
            let along = stroke.filter { abs($0.dx) > 0.01 }
            if !along.isEmpty, stroke.allSatisfy({ abs($0.dy) < 1e-6 }) {
                if along.allSatisfy({ $0.dx > 0 }) { plus += 1 } else if along.allSatisfy({ $0.dx < 0 }) { minus += 1 }
            }
            stroke = []
        }
        for m in tp.motions {
            if m.kind == .feed { stroke.append((m.end.x - at.x, m.end.y - at.y)) } else { close() }
            at = m.end
        }
        close()
        if direction == .climb {
            #expect(minus > 5 && plus == 0, "\(minus) −X, \(plus) +X")
        } else {
            #expect(plus > 5 && minus == 0, "\(minus) −X, \(plus) +X")
        }
    }
}
