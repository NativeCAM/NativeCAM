import Foundation
import Testing
@testable import CAMCore

/// R4, 3D rotary roughing: the stock round a 3D model on a rotary blank cleared in layers, from a square bar or a round
/// blank (research_notes/Rotary milling/rotary_milling.md §2.4 and §5.3).
struct Rotary3DRoughingTests {
    static let lib = ToolLibrary.starter
    static let endMill = lib.tool(number: 1)!
    static let ball = lib.tool(number: 7)!

    /// A rotary job in mm on Avid's Mach4 profile: `mesh` along X on the blank, `start` from its chuck end, roughed with
    /// the 1/4" end mill.
    static func job(mesh: MeshModel, blank: RotaryStock, start: Double, params: RotaryRoughParams = RotaryRoughParams(),
                    tool: Tool = endMill, _ configure: (inout Project) -> Void = { _ in }) -> Project {
        var stock = Stock(materialName: "Poplar", materialKind: .softwood)
        stock.setRotary(blank)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 100)
        machine.outputUnits = .mm
        let spec = ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(alongAxis: .x))
        let length = Double(spec.alongAxis.length)
        let shape = DesignShape(name: "Leg", kind: .model(spec), position: Vec2(start + length / 2, stock.height / 2))
        let op = CAMOperation(name: "Rough", kind: .rotaryRough(params), shapeIDs: [shape.id], tool: tool)
        var p = Project(name: "Rotary rough", displayUnits: .mm, stock: stock, machine: machine, shapes: [shape], operations: [op])
        configure(&p)
        return p
    }

    /// A table leg 90 mm long from a 30 mm square bar 110 mm long: a square pommel the bar's size at the chuck end, a
    /// collar, a bead, a cove, a taper down to 7.2 mm from the axis, and a foot.
    static func legJob(params: RotaryRoughParams = RotaryRoughParams(allowance: legAllowance), _ configure: (inout Project) -> Void = { _ in }) -> Project {
        job(mesh: MeshModel.tableLeg(width: 30, length: 90, segments: 64), blank: RotaryStock(shape: .squareBar, diameter: 30, length: 110),
            start: 10, params: params, configure)
    }

    /// More than the ridges the 1/4" end mill's flat bottom leaves on the round at the leg's narrowest (0.59 mm at 8.3).
    static let legAllowance = 0.75

    /// Warnings other than the rotary axis slowing the cut near the axis and the chip load (not what's tested here).
    func warnings(_ job: JobResult) -> [String] {
        messages(job, .warning).filter { !$0.contains("rotary axis turns at most") && !$0.contains("Chip load") }
    }

    /// The radii of a toolpath's layers: those many of its feed moves are at, outermost first.
    static func layers(_ tp: Toolpath, stock: Stock) -> [Double] {
        var count: [Double: Int] = [:]
        for q in polar(tp, stock: stock) { count[(q.r * 1e6).rounded() / 1e6, default: 0] += 1 }
        return count.filter { $0.value >= 20 }.keys.sorted(by: >)
    }

    /// A plain cylinder `radius` round and `length` long, as a mesh along X.
    static func cylinder(radius: Double, length: Double, segments: Int = 256) -> MeshModel {
        MeshModel.revolved(name: "Cylinder", profile: [(0, radius), (length, radius)], segments: segments)
    }

    static func triangles(_ p: Project) -> [Double] {
        var out: [Double] = []
        for s in p.shapes where s.modelSpec != nil {
            s.forEachBlankTriangle { a, b, c in out += [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] }
        }
        return out
    }

    func messages(_ job: JobResult, _ severity: Severity) -> [String] { job.issues.filter { $0.severity == severity }.map(\.message) }
    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }

    /// The feed moves of a wrapped toolpath as (x, angle in radians, radius from the axis).
    static func polar(_ tp: Toolpath, stock: Stock) -> [(x: Double, a: Double, r: Double)] {
        let top = stock.topRadius ?? 0, cy = stock.originPoint.y
        return tp.motions.filter { $0.kind == .feed }.map { ($0.end.x, ($0.end.y - cy) / top, top + $0.end.z) }
    }

    /// Simulates `toolpaths` on the radial grid.
    static func simulate(_ toolpaths: [Toolpath], _ p: Project, cell: Double = 0.25) throws -> (grid: RadialGrid, collisions: Int) {
        var s = SimulationSession(toolpaths: toolpaths, stock: p.stock, rapidRate: 5000, cellSize: cell)
        s.runToEnd()
        return (try #require(s.radialGrid), s.rapidCollisions.count)
    }

    // MARK: The table leg

    /// Acceptance: a table leg from a square bar. Simulated, the roughing never cuts into the model with its allowance
    /// on it anywhere (measured against the model grown by the allowance, as a tool pointed at the axis sees it), and on
    /// the leg's taper it leaves no more than the allowance, the ridges a flat bottom leaves on the round and what the
    /// slope puts under the tool's edge: no steps between layers.
    @Test func aTableLegFromASquareBarIsNeverCutInsideTheModel() throws {
        let p = Self.legJob()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        #expect(warnings(job).isEmpty, "\(warnings(job))")
        let rough = try #require(job.toolpaths.first)
        #expect(rough.wrapDiameter == 30)
        let sim = try Self.simulate([rough], p)
        #expect(sim.collisions == 0)
        let g = sim.grid
        let blank = try #require(p.stock.rotary)
        let tri = Self.triangles(p)
        let a = Self.legAllowance
        // The model grown by the allowance along each ray: a ball as small as can be, grown by it.
        var point = Self.ball
        point.diameter = 0.002
        let grown = try #require(RotaryDropCutter(tool: point, allowance: a, triangles: tri))
        let probe = try #require(RotaryDropCutter(probe: tri))
        let slope = 0.14 * 30 / (0.5 * 90) * Self.endMill.radius
        var gouge = 0.0, gougeAt = ""
        var left = 0.0, leftAt = ""
        for c in 0..<g.columns {
            let x = g.originX + Double(c) * g.cellSize
            guard x >= 10, x <= 100 else { continue }
            let local = x - 10
            for j in 0..<g.rows {
                let angle = g.angle(row: j)
                let r = Double(g.radii[j * g.columns + c])
                let limit = grown.tipRadius(x: x, angle: angle) + 0.001
                guard limit.isFinite else { continue }
                let stock = blank.surfaceRadius(atDegrees: angle * 180 / .pi)
                let inside = min(stock, limit) - r
                if inside > gouge {
                    gouge = inside
                    gougeAt = "x \(x) angle \(angle)"
                }
                // On the taper, more than a tool radius from its ends.
                guard local > 0.37 * 90 + 4, local < 0.87 * 90 - 4, let surface = probe.crossings(x: x, angle: angle).outer else { continue }
                let cusp = RotaryRoughParams.cusp(Self.endMill, radius: surface)
                let extra = r - (surface + a) - cusp - slope
                if extra > left {
                    left = extra
                    leftAt = "x \(x) angle \(angle): \(r) over \(surface)"
                }
            }
        }
        #expect(gouge < 0.02, "cuts \(gouge) inside the model with its allowance at \(gougeAt)")
        #expect(left < 0.05, "leaves \(left) more than the allowance and the ridges at \(leftAt)")
    }

    /// On a square bar the layers above the faces meet only the corners: they skip the air over the faces, so the
    /// roughing takes far less time than from the round bar the square fits in.
    @Test func theAirOverASquareBarsFacesIsSkipped() throws {
        let p = Self.legJob()
        let job = CAMEngine.generate(p)
        let rough = try #require(job.toolpaths.first)
        let square = try #require(job.estimatedSeconds(toolpath: rough.id))
        // The first layer is outside the faces (15 mm from the axis): material only near the corners there, and the
        // tool's centre at most a tool radius past it.
        let moves = Self.polar(rough, stock: p.stock)
        let rho = Self.layers(rough, stock: p.stock).first ?? 0
        let first = moves.filter { abs($0.r - rho) < 1e-6 }
        #expect(rho > 15.5 && first.count > 10, "\(rho)")
        let reach = .pi / 4 - acos(15 / rho) + Self.endMill.radius / rho
        let farFromCorners = first.filter { q in
            let off = abs((q.a - .pi / 4).remainder(dividingBy: .pi / 2))
            return off > reach + 3 * .pi / 180
        }
        #expect(farFromCorners.isEmpty, "\(farFromCorners.prefix(5))")
        // The round bar the square just fits in, roughed the same way.
        let round = Self.legJob { p in
            p.stock.setRotary(RotaryStock(shape: .cylinder, diameter: 30 * 2.0.squareRoot(), length: 110))
        }
        let roundJob = CAMEngine.generate(round)
        let roundTP = try #require(roundJob.toolpaths.first)
        let full = try #require(roundJob.estimatedSeconds(toolpath: roundTP.id))
        #expect(square < 0.8 * full, "\(square) s vs \(full) s")
    }

    /// After a Rounding, the roughing starts from the rounded size: nothing above it.
    @Test func itStartsFromWhatARoundingLeaves() throws {
        let p = Self.legJob { p in
            p.operations.insert(CAMOperation(name: "Round", kind: .rounding(RoundingParams(finishedDiameter: 29, startX: 40, endX: 106)),
                                             shapeIDs: [], tool: Self.endMill), at: 0)
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let rough = try #require(job.toolpaths.first { $0.name == "Rough" })
        // Where it's round (well past the pommel), nothing is cut farther out than 14.5 mm.
        let outer = Self.polar(rough, stock: p.stock).filter { $0.x > 45 }.map(\.r).max() ?? 0
        #expect(outer <= 14.5 + 1e-6, "\(outer)")
        let sim = try Self.simulate(job.toolpaths, p, cell: 0.4)
        #expect(sim.collisions == 0)
    }

    // MARK: Layers

    /// Each layer is cut in the blank unrolled at its own radius, so it's exact there: lines along the blank are a
    /// stepover apart on the layer's surface, lines round it are whole turns, every move is at a layer's radius, and
    /// the inverse time posted for a turn at one radius is the feed over the arc it really cuts.
    @Test func eachLayerIsExactAtItsRadius() throws {
        func rough(_ pattern: RotaryRoughParams.Pattern) -> Project {
            Self.job(mesh: Self.cylinder(radius: 8, length: 40), blank: RotaryStock(diameter: 40, length: 80), start: 20,
                     params: RotaryRoughParams(pattern: pattern, stepdown: 4, allowance: 0.5)) { p in
                p.machine.rotary?.turnSpeed = 10_000_000
            }
        }
        let stepover = RotaryRoughParams().stepover(Self.endMill)
        for pattern in [RotaryRoughParams.Pattern.along, .around] {
            let p = rough(pattern)
            let job = CAMEngine.generate(p)
            #expect(!job.hasErrors, "\(messages(job, .error))")
            let tp = try #require(job.toolpaths.first)
            let c = Self.polar(tp, stock: p.stock)
            // From 20 mm in to 8.5 (the cylinder, a hair less between its facets, and the allowance), three layers
            // evenly spaced. The last rides on the cylinder's facets, a thousandth or so out from it.
            let deepest = c.map(\.r).min() ?? 0
            let layers = Self.layers(tp, stock: p.stock).filter { $0 > deepest + 2e-3 } + [deepest]
            #expect(layers.count == 3 && abs(deepest - 8.5) < 2e-3, "\(layers)")
            guard layers.count == 3 else { continue }
            let spacing = 20 - layers[0]
            let second: Double = abs(layers[0] - layers[1] - spacing)
            let third: Double = abs(layers[1] - layers[2] - spacing)
            #expect(second < 1e-5, "\(layers)")
            #expect(third < 2e-3, "\(layers)")
            let off = c.filter { q in !layers.contains { abs(q.r - $0) < 2e-3 } && q.r < 20 }
            #expect(off.isEmpty, "\(pattern): \(off.prefix(5))")
            if pattern == .along {
                // Lines along the blank on the top layer, a stepover apart on its surface.
                let rho = layers[0]
                var angles: [Double] = []
                for (a, b) in zip(c, c.dropFirst()) where abs(a.r - rho) < 1e-5 && abs(b.r - rho) < 1e-5 && abs(a.a - b.a) < 1e-12 && abs(b.x - a.x) > 30 {
                    angles.append(a.a.remainder(dividingBy: 2 * .pi))
                }
                // (The pass round the area's edge also runs along the seam, at ±π.)
                let sorted = Array(Set(angles.map { ($0 * 1e9).rounded() / 1e9 })).filter { abs(abs($0) - .pi) > 1e-6 }.sorted()
                #expect(sorted.count > 20)
                let gaps = zip(sorted, sorted.dropFirst()).map { ($1 - $0) * rho }
                let wrong = gaps.filter { abs($0 - stepover) > 1e-6 }
                #expect(wrong.isEmpty, "\(wrong.prefix(5)) vs \(stepover)")
                // Across the seam they're no farther apart.
                let seam = ((sorted.first ?? 0) + 2 * .pi - (sorted.last ?? 0)) * rho
                #expect(seam <= stepover + 1e-6, "\(seam)")
            } else {
                // Lines round the blank: whole turns at one station.
                var turns = 0
                var run: (x: Double, from: Double, to: Double)?
                for q in c {
                    if let r = run, abs(r.x - q.x) < 1e-9 {
                        run = (r.x, min(r.from, q.a), max(r.to, q.a))
                    } else {
                        if let r = run, abs(r.to - r.from - 2 * .pi) < 1e-6 { turns += 1 }
                        run = (q.x, q.a, q.a)
                    }
                }
                #expect(turns > 10, "\(turns)")
                // The post's inverse time for a move that only turns: the feed over r·Δθ.
                let text = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
                let program = try GCodeParser.parse(text)
                var checked = 0
                var mismatches: [String] = []
                var x: Double?, z: Double?, a: Double?
                let feed = Self.endMill.cutting.feedRate
                for m in program.segments.flatMap(\.motions) {
                    defer { x = m.end.x; z = m.end.z; a = m.a ?? a }
                    guard let f = m.inverseTime, let a0 = a, let a1 = m.a, m.end.x == x, m.end.z == z, let r = z, abs(a1 - a0) > 1 else { continue }
                    let expected = feed / (r * abs(a1 - a0) * .pi / 180)
                    let written = (expected * 10000).rounded() / 10000
                    if abs(f - written) > 2e-4 { mismatches.append("F\(f) vs \(expected)") }
                    checked += 1
                }
                #expect(checked > 10)
                #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
            }
        }
    }

    /// On a wrapped job the sheet's radius is the wrap diameter's, not the blank's: the roughing comes out the same.
    @Test func itRoughsOnAWrappedJobToo() throws {
        let p = Self.job(mesh: Self.cylinder(radius: 8, length: 40), blank: RotaryStock(diameter: 40, length: 80), start: 20,
                         params: RotaryRoughParams(allowance: 0.5)) { p in
            var b = p.stock.rotary!
            b.layout = .wrapped
            b.wrapDiameter = 36
            p.stock.setRotary(b)
            p.placeModelsOnBlank()
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.wrapDiameter == 36)
        let sim = try Self.simulate([tp], p, cell: 0.3)
        #expect(sim.collisions == 0)
        let g = sim.grid
        var lo = Double.infinity, hi = 0.0
        for c in 0..<g.columns {
            let x = g.originX + Double(c) * g.cellSize
            guard x > 25, x < 55 else { continue }
            for j in 0..<g.rows {
                let r = Double(g.radii[j * g.columns + c])
                lo = min(lo, r)
                hi = max(hi, r)
            }
        }
        // Down to the cylinder and its allowance (less its facets), and no more than the ridges left above that.
        let floor: Double = 8.5 - 0.02
        let ceiling: Double = 8.5 + RotaryRoughParams.cusp(Self.endMill, radius: 8.5) + 0.05
        #expect(lo > floor, "\(lo)")
        #expect(hi < ceiling, "\(hi)")
    }

    // MARK: Run order

    /// Rounding, then roughing, then finishing: Optimize Run Order keeps it, and fixes a finish put before its roughing.
    @Test func roundingThenRoughingThenFinishing() throws {
        var p = Self.legJob()
        let rough = p.operations[0]
        let finish = CAMOperation(name: "Finish", kind: .rotaryFinish(RotaryFinishParams()), shapeIDs: rough.shapeIDs, tool: Self.ball)
        let round = CAMOperation(name: "Round", kind: .rounding(RoundingParams(finishedDiameter: 29, startX: 40, endX: 106)),
                                 shapeIDs: [], tool: Self.endMill)
        p.operations = [round, rough, finish]
        let kept = OperationScheduler.optimize(p)
        #expect(kept.outOfOrder.isEmpty)
        #expect(kept.order == [round.id, rough.id, finish.id])
        p.operations = [finish, rough, round]
        let fixed = OperationScheduler.optimize(p)
        #expect(fixed.order == [round.id, rough.id, finish.id], "\(fixed.order)")
        #expect(fixed.outOfOrder.contains { $0.operation == rough.id && $0.mustPrecede == finish.id })
        p.operations = [finish, rough]
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.operation == "Finish" && $0.message.contains("Runs before its roughing (“Rough”)") },
                "\(job.issues.map(\.message))")
    }

    // MARK: Finishing after it

    /// A 3D rotary finish after the roughing starts from what it left: no layers of its own, a much shorter run, and its
    /// rapids stop above the roughed stock. Simulated, the two never cut into the model.
    @Test func theFinishStartsFromWhatTheRoughingLeft() throws {
        var p = Self.legJob()
        p.operations.append(CAMOperation(name: "Finish", kind: .rotaryFinish(RotaryFinishParams(stepoverFraction: 0.2)),
                                         shapeIDs: p.operations[0].shapeIDs, tool: Self.ball))
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let finish = try #require(job.toolpaths.first { $0.name == "Finish" })
        let after = try #require(job.estimatedSeconds(toolpath: finish.id))
        var alone = p
        alone.operations[0].enabled = false
        let aloneJob = CAMEngine.generate(alone)
        let aloneFinish = try #require(aloneJob.toolpaths.first { $0.name == "Finish" })
        let before = try #require(aloneJob.estimatedSeconds(toolpath: aloneFinish.id))
        #expect(after < 0.6 * before, "\(after) s after the roughing vs \(before) s alone")
        // No square-bar warning: the roughing took the corners off.
        #expect(!job.issues.contains { $0.message.contains("Starts from a square bar") })
        let sim = try Self.simulate(job.toolpaths, p, cell: 0.3)
        #expect(sim.collisions == 0)
        let probe = try #require(RotaryDropCutter(probe: Self.triangles(p)))
        var gouge = 0.0
        let g = sim.grid
        for c in 0..<g.columns {
            let x = g.originX + Double(c) * g.cellSize
            guard x > 12, x < 98 else { continue }
            for j in 0..<g.rows {
                guard let surface = probe.crossings(x: x, angle: g.angle(row: j)).outer else { continue }
                gouge = max(gouge, surface - Double(g.radii[j * g.columns + c]))
            }
        }
        #expect(gouge < 0.05, "\(gouge)")
    }

    // MARK: Checks

    @Test func checksCoverTheToolTheAllowanceAndTheModel() throws {
        func issues(_ params: RotaryRoughParams = RotaryRoughParams(), _ configure: (inout Project) -> Void = { _ in }) -> [JobIssue] {
            CAMEngine.generate(Self.legJob(params: params, configure)).issues
        }
        func has(_ text: String, _ severity: Severity = .warning, _ params: RotaryRoughParams = RotaryRoughParams(),
                 _ configure: (inout Project) -> Void = { _ in }) {
            let all = issues(params, configure)
            #expect(all.contains { $0.severity == severity && $0.message.contains(text) }, "\(text): \(all.map(\.message))")
        }
        // The flat bottom leaves up to R²/2ρ on the round at the narrowest (7.2 mm + allowance): about 0.65 mm.
        has("is less than the ridges", .warning, RotaryRoughParams(allowance: 0.3))
        let r = Self.endMill.radius
        let cusp = RotaryRoughParams.cusp(Self.endMill, radius: 7.7)
        let edge: Double = (7.7 * 7.7 + r * r).squareRoot() - 7.7
        #expect(abs(cusp - edge) < 1e-9)
        // A bull nose's corners leave less.
        var bull = Self.endMill
        bull.shape = .bullNose
        bull.cornerRadius = 1.5
        let bullCusp: Double = RotaryRoughParams.cusp(bull, radius: 7.7)
        #expect(bullCusp < cusp - 0.3)
        // Near the axis the 1/4" end mill's feed needs A faster than its nominal 90° a second.
        has("rotary axis turns at most 5,400°/min")
        has("collet nut could hit") { $0.operations[0].tool.stickout = 5 }
        has("so its shank rubs") { p in
            p.operations[0].tool.fluteLength = 8
            p.operations[0].tool.stickout = 40
        }
        has("deep in one layer", .warning, RotaryRoughParams(stepdown: 14, allowance: Self.legAllowance))
        has("meant for a flat or bull-nose end mill") { $0.operations[0].tool = Self.ball }
        has("needs a 3D model") { p in
            p.shapes.append(DesignShape(name: "Box", kind: .rectangle(width: 5, height: 5, cornerRadius: 0), position: Vec2(50, 15)))
            p.operations[0].shapeIDs = [p.shapes[1].id]
        }
        has("turns the whole blank, so index angles don't apply", .error) { $0.operations[0].indexAngles = [0, 90] }
        has("no inverse-time feed (G93)", .error, RotaryRoughParams(), ControllerPostTests.controller(.centroid, units: .mm))
        // A bull nose roughs it cleanly.
        let clean = issues { $0.operations[0].tool = bull }.filter {
            $0.severity == .warning && !$0.message.contains("rotary axis turns at most") && !$0.message.contains("Chip load")
        }
        #expect(clean.isEmpty, "\(clean.map(\.message))")
        // A square pommel the bar's own size fits the bar: no warning that the model is bigger than the stock.
        #expect(!issues().contains { $0.message.contains("bigger across than the stock") })
        // Nothing to rough when the bar is already the model's size.
        let thin = CAMEngine.generate(Self.job(mesh: Self.cylinder(radius: 12, length: 40), blank: RotaryStock(diameter: 24.5, length: 80), start: 20))
        #expect(thin.issues.contains { $0.message.contains("Nothing to rough") }, "\(thin.issues.map(\.message))")
    }

    /// 3D roughing and finishing for flat sheets say what to use on a rotary blank.
    @Test func flatThreeDOnARotaryBlankPointsAtTheRotaryOnes() {
        let p = Self.legJob { p in
            p.operations[0].kind = .rough3D(Rough3DParams())
        }
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .error && $0.message.contains("use 3D Rotary Roughing and Finishing") })
    }

    // MARK: Output

    /// A small rough for the golden: a bead and a square end on a 20 mm square bar, sampled coarsely.
    static func smallRough() -> Project {
        let square: (Double) -> Double = { a in 10 / max(abs(cos(a)), abs(sin(a))) }
        var rings: [(x: Double, radius: (Double) -> Double)] = [(0, square), (8, square)]
        for i in 0...12 {
            let r = 6 + 2.5 * sin(.pi * Double(i) / 12)
            rings.append((8 + Double(i), { _ in r }))
        }
        let mesh = MeshModel.lofted(name: "Bead", rings: rings, segments: 32)
        return job(mesh: mesh, blank: RotaryStock(shape: .squareBar, diameter: 20, length: 30), start: 5,
                   params: RotaryRoughParams(stepdown: 3, stepoverFraction: 0.6, allowance: 0.5, sampleSpacing: 1))
    }

    @Test func avidMach4Golden() throws {
        let p = Self.smallRough()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: "rotary-rough-mm")
        let text = String(decoding: data, as: UTF8.self)
        #expect(problems(GCodeCheck.run(text, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
        #expect(text.contains("G93 G01") && text.contains("G94"))
        // The setup sheet says what it roughs and how.
        let html = SetupSheet.html(project: p, job: job)
        #expect(html.contains("<h2>3D rotary</h2>") && html.contains("roughs “Leg”"))
    }

    /// A 3D rotary roughing saved by format 12 keeps loading and posting the same bytes.
    static func savedRough() -> Project {
        var p = smallRough()
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "4D4D0000-0000-0000-0000-%012d", n))! }
        guard case var .model(spec) = p.shapes[0].kind else { return p }
        spec.mesh.id = id(1)
        p.shapes[0].id = id(2)
        p.shapes[0].kind = .model(spec)
        p.operations[0].id = id(3)
        p.operations[0].shapeIDs = [id(2)]
        // The end mill as format 12 saved it, spelled out rather than taken from today's starter library.
        p.operations[0].tool.cutting = CuttingData(spindleRPM: 16000, feedRate: 3000, plungeRate: 900, stepdown: 3, stepoverFraction: 0.4)
        p.operations[0].kind = .rotaryRough(RotaryRoughParams(pattern: .offset, stepdown: 2.5, stepoverFraction: 0.5, allowance: 0.4,
                                                              startX: 6, endX: 24, sampleSpacing: 0.8))
        p.notes = "Saved by format 12: a 3D rotary roughing of a bead with a square end on a square bar."
        return p
    }

    @Test func rotaryRoughSavedByFormatTwelveStillDecodesAndPosts() throws {
        #expect(Self.smallRough().formatVersion == 12)
        let p = try GoldenPostTests.savedProject("rotary-rough-v12", make: Self.savedRough)
        #expect(p.formatVersion == 12)
        #expect(p == Self.savedRough())
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(messages(job, .error))")
        let data = GoldenPostTests.post(p)
        try GoldenPostTests.check(data, golden: "decoded-rotary-rough-v12")
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(problems(issues).isEmpty, "\(issues.map(\.text))")
    }

    // MARK: The demo

    /// The demo table leg roughs and finishes cleanly, posts a file that reads back clean, and its estimate, simulation
    /// and program agree on the time.
    @Test func theDemoTableLegRoughsAndFinishesCleanly() throws {
        let p = Project.demoTableLeg()
        #expect(p.formatVersion == 12)
        let job = CAMEngine.generate(p)
        // Both slow near the axis for the rotary axis's assumed 90° a second, which the checks say, and which makes their
        // chip there too thin for softwood (#58), as on the pawn.
        let unexpected = job.issues.filter {
            $0.severity == .error || ($0.severity == .warning && !$0.message.contains("rotary axis turns at most")
                && !$0.message.contains("the rotary axis can't turn fast enough"))
        }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.message))")
        #expect(job.toolpaths.map(\.name) == ["Rough leg", "Finish leg"])
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let gcode = post.post(job.toolpaths)
        #expect(problems(GCodeCheck.run(gcode, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
        let estimate = try #require(job.estimate)
        let program = RotaryJobTimeTests.programSeconds(gcode, machine: p.machine, units: p.machine.outputUnits)
        // The estimate allows for acceleration, which the program's own time at constant speed doesn't: the roughing's
        // lines along the blank stop and turn back at each end.
        #expect(estimate.total >= program - 1 && estimate.total < program * 1.08, "\(estimate.total) vs \(program)")
        let sim = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: p.machine.rapidRateForEstimates,
                                    cellSize: 2, estimate: estimate, turnSpeed: p.machine.rotary?.drivenTurnSpeed)
        #expect(abs(sim.timeline.duration - estimate.total) < 0.5, "\(sim.timeline.duration) vs \(estimate.total)")
        // The feeds keep A within the turn speed.
        let rates = RotaryJobTimeTests.turnRates(gcode, from: "(Toolpath: Rough leg")
        let fastest = rates.max() ?? 0
        #expect(!rates.isEmpty && fastest <= RotaryAxis.nominalTurnSpeed * 1.0001, "\(fastest)")
    }

    // MARK: 3D rotary finishing on a square bar

    /// R3's rapids down stop above the most material under the tool, not just under its middle: off a square bar's
    /// face, a corner can be under the edge of the tool, higher than the plunge height above the face there. (The
    /// simulation checks rapids along the tool's axis only, so this measures the footprint itself.)
    @Test func aFinishOnASquareBarStopsItsRapidsAboveTheCorners() throws {
        let p = Self.legJob { p in
            // Layers whose first lines meet only the corners, each starting from safe Z beside a corner.
            p.operations[0].kind = .rotaryFinish(RotaryFinishParams(pattern: .lines, stepoverFraction: 0.6))
            p.operations[0].tool = Self.endMill
            p.stock.plungeHeight = 0.5
        }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let blank = try #require(p.stock.rotary)
        let top = blank.topRadius, cy = p.stock.originPoint.y, R = Self.endMill.radius
        let clearance = max(p.stock.clearanceHeight, p.stock.plungeHeight)
        /// The most of the bar under a tool pointed at the axis at `angle`, along its axis.
        func under(_ angle: Double) -> Double {
            var most = 0.0
            for i in -720...720 {
                let phi = angle + Double(i) / 720 * .pi / 2
                let d = blank.surfaceRadius(atDegrees: phi * 180 / .pi)
                if d * abs(sin(phi - angle)) <= R { most = max(most, d * cos(phi - angle)) }
            }
            return most
        }
        var checked = 0
        var low: [String] = []
        var at = tp.start
        for m in tp.motions {
            defer { at = m.end }
            guard m.kind == .rapid, m.end.z < clearance - 1e-9, m.end.z < at.z - 1e-9, abs(m.end.x - at.x) < 1e-9 else { continue }
            let angle = (m.end.y - cy) / top
            let gap = top + m.end.z - under(angle)
            if gap < 0.5 - 1e-3 { low.append("x \(m.end.x) angle \(angle * 180 / .pi)°: \(gap)") }
            checked += 1
        }
        #expect(checked > 3)
        #expect(low.isEmpty, "\(low.prefix(5))")
    }
}
