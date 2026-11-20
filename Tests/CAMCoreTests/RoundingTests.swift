import Foundation
import Testing
@testable import CAMCore

/// R2, rounding: turning a square bar round, or a round blank down to a smaller diameter, in layers all the way round.
struct RoundingTests {
    static let lib = ToolLibrary.starter
    static let bar = RotaryStock(shape: .squareBar, diameter: 50, length: 300)

    /// A 50 mm square bar on faces, on Avid's Mach4 profile in mm, rounded to the size across its faces.
    static func job(method: RoundingParams.Method = .radial, _ configure: (inout Project) -> Void = { _ in }) -> Project {
        var stock = Stock(materialName: "Maple")
        stock.setRotary(bar)
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 100)
        machine.outputUnits = .mm
        let op = CAMOperation(name: "Round", kind: .rounding(RoundingParams(method: method, passDepth: 3)), shapeIDs: [],
                              tool: lib.tool(number: 1)!)
        var p = Project(name: "Rounding", displayUnits: .mm, stock: stock, machine: machine, operations: [op])
        configure(&p)
        return p
    }

    func problems(_ issues: [GCodeCheck.Issue]) -> [String] { issues.filter { $0.severity != .info }.map(\.text) }
    func errors(_ p: Project) -> [String] { CAMEngine.generate(p).issues.filter { $0.severity == .error }.map(\.message) }

    /// The radius each feed move cuts at, and its angle, from the sheet coordinates.
    func cuts(_ tp: Toolpath, stock: Stock) -> [(r: Double, a: Double, x: Double)] {
        let top = stock.topRadius ?? 0, cy = stock.originPoint.y
        return tp.motions.filter { $0.kind == .feed }.map { (top + $0.end.z, ($0.end.y - cy) / top, $0.end.x) }
    }

    @Test func aSquareBarIsTurnedRoundInLayers() throws {
        let p = Self.job()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.wrapDiameter == 50)
        let c = cuts(tp, stock: p.stock)
        // Layers from the corners (35.36 mm out) in to 25 mm, none deeper than 3 mm: the radii of the moves that stay at
        // one radius (the ramps in between are split into quarter turns).
        let level = zip(c, c.dropFirst()).filter { abs($0.r - $1.r) < 1e-9 }.map { ($0.1.r * 1000).rounded() / 1000 }
        let layers = Array(Set(level)).sorted(by: >)
        let corner = 25 * 2.0.squareRoot()
        #expect(abs((layers.last ?? 0) - 25) < 1e-6 && layers.count == Int(((corner - 25) / 3).rounded(.up)))
        #expect(corner - layers[0] <= 3 + 1e-6 && zip(layers, layers.dropFirst()).allSatisfy { $0 - $1 <= 3 + 1e-6 })
        // The rotary only ever turns one way, and no move turns more than 90°.
        let a = c.map(\.a)
        #expect(zip(a, a.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 })
        var prev = tp.start
        for m in tp.motions {
            #expect(abs(m.end.y - prev.y) / 25 <= .pi / 2 + 1e-9)
            prev = m.end
        }
        // It cuts inside the blank's ends, and the post writes it in G93 with clean checks.
        #expect((c.map(\.x).min() ?? 0) >= Self.lib.tool(number: 1)!.radius - 1e-9)
        var post = AvidMach4Post(project: p, date: GoldenPostTests.date)
        post.timeZone = TimeZone(identifier: "UTC")!
        let g = post.post(job.toolpaths)
        #expect(g.contains("G93 G01") && g.contains("(Feeds: G93 inverse time on moves that turn A, G94 otherwise)"))
        #expect(problems(GCodeCheck.run(g, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)).isEmpty)
    }

    @Test func theSimulatedBarComesOutRound() throws {
        for method in RoundingParams.Method.allCases {
            let p = Self.job(method: method)
            let job = CAMEngine.generate(p)
            var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.5)
            s.runToEnd()
            let g = try #require(s.radialGrid)
            // Away from the ends, every angle is within a cusp of 25 mm: the corners are gone, the faces untouched.
            var high: Float = 0, low: Float = 99
            for j in 0..<g.rows {
                for c in 0..<g.columns {
                    let x = g.originX + Double(c) * g.cellSize
                    guard x > 15, x < 285 else { continue }
                    high = max(high, g.radii[j * g.columns + c])
                    low = min(low, g.radii[j * g.columns + c])
                }
            }
            #expect(high < 25.06 && low > 24.95, "\(method): \(low)–\(high)")
        }
    }

    @Test func passesAlongTheBlankSkipTheFacesOfASquareBar() throws {
        let p = Self.job(method: .raster)
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        // Passes along the blank, as (radius, angle): in the first layer only near the corners, at 45° + n·90°.
        let c = cuts(tp, stock: p.stock)
        var passes: [(r: Double, a: Double)] = []
        for (u, v) in zip(c, c.dropFirst()) where abs(v.x - u.x) > 100 && abs(v.a - u.a) < 1e-9 && abs(v.r - u.r) < 1e-9 {
            passes.append((v.r, v.a))
        }
        let first = try #require(passes.map(\.r).max())
        let near = passes.filter { abs($0.r - first) < 1e-6 }
        #expect(!near.isEmpty)
        for pass in near {
            let deg = (pass.a * 180 / .pi).truncatingRemainder(dividingBy: 90)
            #expect(abs(deg - 45) < 25, "\(deg)")
        }
        // The last layer is the size across the faces. A face's flanks stand proud of that circle (0.4 mm at 10° off its
        // middle), so passes either side still cut, but a pass right over the middle of a face would cut nothing.
        let last = passes.filter { abs($0.r - 25) < 1e-6 }
        #expect(!last.isEmpty)
        for pass in last {
            let deg = (pass.a * 180 / .pi).truncatingRemainder(dividingBy: 90)
            #expect(deg > 1e-3 && deg < 90 - 1e-3, "\(deg)")
        }
    }

    @Test func roundingGolden() throws {
        let p = Self.job { $0.stock.setRotary(RotaryStock(shape: .squareBar, diameter: 30, length: 60)) }
        let tps = CAMEngine.generate(p).toolpaths
        let data = GoldenPostTests.post(p, tps)
        try GoldenPostTests.check(data, golden: "rounding-square-mm")
        #expect(problems(GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: tps, project: p, dialect: .avidMach4)).isEmpty)
    }

    /// Round blank, wrapped job: turn it down to the wrap diameter, then engrave on it.
    @Test func aRoundingMakesASmallerWrapDiameterCuttable() throws {
        var p = RotaryWrapTests.engravedF { p in
            var blank = p.stock.rotary!
            blank.wrapDiameter = 44
            p.stock.setRotary(blank)
        }
        #expect(CAMEngine.generate(p).issues.contains { $0.message.contains("Turn the blank down to") })
        let round = CAMOperation(name: "Round", kind: .rounding(RoundingParams()), shapeIDs: [], tool: Self.lib.tool(number: 1)!)
        p.operations.insert(round, at: 0)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors && !job.issues.contains { $0.message.contains("Turn the blank down to") }, "\(job.issues.map(\.message))")
        let c = cuts(job.toolpaths[0], stock: p.stock)
        #expect(abs((c.map(\.r).min() ?? 0) - 22) < 1e-6)
        // Rounding has to come first; Optimize Run Order puts it there.
        p.operations.swapAt(0, 1)
        #expect(CAMEngine.generate(p).issues.contains { $0.message.contains("Runs before the blank is rounded") })
        #expect(OperationScheduler.optimize(p).order.first == p.operations[1].id)
    }

    /// A rounding pass winds A hundreds of turns on: what comes after starts from there, never winding back.
    @Test func nothingWindsBackTheTurnsARoundingMade() throws {
        var p = RotaryWrapTests.engravedF()
        p.operations.insert(CAMOperation(name: "Round", kind: .rounding(RoundingParams(finishedDiameter: 48)), shapeIDs: [],
                                         tool: Self.lib.tool(number: 1)!), at: 0)
        // On Avid's Mach4 profile, then on LinuxCNC.
        for configure in [{ (_: inout Project) in }, ControllerPostTests.controller(.linuxCNC, units: .mm)] {
            var q = p
            configure(&q)
            let tps = CAMEngine.generate(q).toolpaths
            let post = try #require(PostProcessors.post(for: q, date: GoldenPostTests.date))
            let g = post.post(tps)
            #expect(problems(GCodeCheck.run(g, toolpaths: tps, project: q, dialect: post.dialect)).isEmpty,
                    "\(problems(GCodeCheck.run(g, toolpaths: tps, project: q, dialect: post.dialect)))")
            let a: [Double] = try GCodeParser.parse(g).segments.flatMap(\.motions).compactMap(\.a)
            // A never steps back by more than a turn, and the program ends on a whole turn with a note to zero A.
            #expect(zip(a, a.dropFirst()).allSatisfy { $1 > $0 - 360 })
            let end: Double = a.last ?? 0
            #expect(end > 3600 && abs(end.remainder(dividingBy: 360)) < 1e-6 && g.contains("whole turns from where it started"))
        }
    }

    @Test func aSquareBarCanBeWrappedOnceRounded() throws {
        var p = RotaryWrapTests.engravedF { p in
            var blank = p.stock.rotary!
            blank.shape = .squareBar
            p.stock.setRotary(blank)
        }
        #expect(errors(p).contains { $0.contains("need a round blank") })
        p.operations.insert(CAMOperation(name: "Round", kind: .rounding(RoundingParams()), shapeIDs: [], tool: Self.lib.tool(number: 1)!), at: 0)
        #expect(errors(p).isEmpty, "\(errors(p))")
        // Simulated, the engraving is cut into the rounded bar.
        let job = CAMEngine.generate(p)
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.5)
        s.runToEnd()
        let g = try #require(s.radialGrid)
        #expect(try #require(g.radius(at: 140, angle: 0)) < 24.1)
        #expect(abs(Double(try #require(g.radius(at: 100, angle: .pi / 4))) - 25) < 0.06)
    }

    @Test func roundingOnFacesSimulatesWithTheFaces() throws {
        // Round the bar, then cut a pocket on its top face.
        let p = Self.job { p in
            let slot = DesignShape(kind: .rectangle(width: 30, height: 10, cornerRadius: 0), position: Vec2(150, 25))
            p.shapes = [slot]
            p.operations.append(CAMOperation(name: "Slot", kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))),
                                             shapeIDs: [slot.id], tool: Self.lib.tool(number: 2)!))
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.5)
        #expect(s.faces.count == 1 && s.radial != nil && s.isWrapped(toolpath: 0) && !s.isWrapped(toolpath: 1))
    }

    @Test func whatRoundingCantDoIsReported() {
        func has(_ text: String, _ configure: (inout Project) -> Void) {
            let issues = CAMEngine.generate(Self.job(configure)).issues
            #expect(issues.contains { $0.message.contains(text) }, "\(text): \(issues.map(\.message))")
        }
        has("isn't one. Set up rotary stock") { $0.stock.setRotary(nil) }
        has("index angles don't apply") { $0.operations[0].indexAngles = [0, 90] }
        has("no inverse-time feed (G93)", ControllerPostTests.controller(.centroid, units: .mm))
        has("can't be done by hand") { $0.machine.rotary?.turnsByHand = true }
        has("nothing to cut") { $0.operations[0].kind = .rounding(RoundingParams(finishedDiameter: 80)) }
        #expect(Self.job().formatVersion == 5)
    }
}
