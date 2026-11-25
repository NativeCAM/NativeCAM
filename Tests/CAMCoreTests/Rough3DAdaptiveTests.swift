import Foundation
import Testing
@testable import CAMCore

/// Adaptive layered 3D roughing (#89): each layer of 3D roughing cleared by `AdaptiveClearing` at a constant load,
/// measured on the demo relief with its 1/4" end mill.
struct Rough3DAdaptiveTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "89AD0000-0000-4000-8000-%012d", n))! }

    /// The demo relief roughed with `clearing` (and nothing else: no finish, no cut-out).
    static func relief(_ clearing: Rough3DClearing?, adaptive: AdaptiveSettings? = nil) -> Project {
        var p = Project.demoRelief()
        p.operations = [p.operations[0]]
        guard case var .rough3D(r) = p.operations[0].kind else { return p }
        r.clearing = clearing
        r.adaptive = adaptive
        p.operations[0].kind = .rough3D(r)
        return p
    }

    /// The demo relief carved 0.9" deep (rather than 0.4") into 1.25" maple.
    static func deepRelief(_ clearing: Rough3DClearing?) -> Project {
        var p = relief(clearing)
        p.stock.thickness = 1.25.inch
        if case var .model(spec) = p.shapes[0].kind {
            spec.depth = 0.9.inch
            p.shapes[0].kind = .model(spec)
        }
        return p
    }

    static func roughParams(_ p: Project) -> Rough3DParams {
        if case let .rough3D(r) = p.operations[0].kind { return r }
        return Rough3DParams()
    }

    static func context(_ p: Project) -> GenerationContext {
        GenerationContext(stock: p.stock, machine: p.machine, units: p.displayUnits)
    }

    /// The least height of `tp`'s feed moves above the exact drop-cutter surface of the project's models, sampled
    /// every `step` mm (+∞ off the models).
    static func clearance(_ tp: Toolpath, project: Project, step: Double = 0.05) -> Double {
        let models = project.shapes.filter { $0.modelSpec != nil }
        guard let cutter = TriangleDropCutter(tool: tp.tool, allowance: 0, triangles: Model3DGenerator.triangles(of: models)) else {
            return .infinity
        }
        var least = Double.infinity
        var hint: Int32 = -1
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            for q in [s] + m.samples(from: s, maxStep: step) {
                let z = cutter.z(at: q.xy, hint: &hint)
                if z.isFinite { least = min(least, q.z - z) }
            }
        }
        return least
    }

    // MARK: The demo relief

    /// The load each cut of one level's walk takes, measured on a fine raster of its own as
    /// `AdaptiveClearingTests.replay` measures a pocket's, starting from what the level counts as cleared already (a
    /// step-up's deeper clearing): per window of at least 1 mm, leaving out the first and last two bit radii of each pass.
    static func loads(_ entry: (layer: Model3DGenerator.AdaptiveLayer, plan: AdaptiveClearing.Plan), settings s: AdaptiveClearing.Settings)
        -> [(load: Double, length: Double)] {
        guard let level = entry.plan.levels.first else { return [] }
        let bounds = entry.layer.boundary.reduce(Rect2.empty) { $0.union($1.bounds) }.insetBy(-2 * s.toolRadius)
        var raster = AdaptiveClearingTests.Raster(bounds: bounds, cell: 0.03)
        // Scanline fill of the seed (even-odd over its loops) at the raster's cell centres.
        let edges = entry.layer.seed.flatMap { loop in (0..<loop.segmentCount).map { loop.segment($0) } }
        for j in 0..<raster.h where !edges.isEmpty {
            let y = raster.origin.y + (Double(j) + 0.5) * raster.cell
            var xs: [Double] = []
            for (a, b) in edges where (a.y <= y) != (b.y <= y) { xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let i0 = max(0, Int(((xs[k] - raster.origin.x) / raster.cell - 0.5).rounded(.up)))
                let i1 = min(raster.w - 1, Int(((xs[k + 1] - raster.origin.x) / raster.cell - 0.5).rounded(.down)))
                if i0 <= i1 { for i in i0...i1 { raster.cut[j * raster.w + i] = true } }
                k += 2
            }
        }
        var out: [(load: Double, length: Double)] = []
        for move in level.moves {
            switch move {
            case let .helix(c, rho, _, _):
                _ = raster.sweep(c, c + Vec2(1e-6, 0), rho + s.toolRadius)
            case let .ramp(p, q):
                _ = raster.sweep(p, q, s.toolRadius)
            case let .cut(pts, _):
                let total = zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                var along = 0.0, area = 0.0, length = 0.0
                for k in 1..<pts.count {
                    let d = pts[k - 1].distance(to: pts[k])
                    let a = raster.sweep(pts[k - 1], pts[k], s.toolRadius)
                    along += d
                    guard along > 2 * s.toolRadius, along < total - 2 * s.toolRadius else { continue }
                    area += a
                    length += d
                    if length >= 1 {
                        out.append((area / length / s.load, length))
                        area = 0
                        length = 0
                    }
                }
            case let .link(pts, _):
                for k in 1..<pts.count { _ = raster.sweep(pts[k - 1], pts[k], s.toolRadius) }
            case .lift:
                break
            }
        }
        return out
    }

    /// Measured on a raster of its own, every level's walk on the demo relief holds the optimal load: most of its
    /// length within 15% of it, and nothing past 1.4×, once in. (A level whose area is too narrow for the walk's loops,
    /// such as the band round the relief's foot, is cleared at the stepdown instead, and has no walk to measure.)
    @Test func holdsTheLoadOnEveryLayerOfTheDemoRelief() throws {
        let p = Self.relief(.adaptive)
        let op = p.operations[0]
        let plans = Model3DGenerator.adaptivePlans(op: op, params: Self.roughParams(p), shapes: p.shapes(for: op), context: Self.context(p))
        #expect(plans.count >= 2)
        let s = AdaptiveClearing.Settings(tool: op.tool, params: try #require(plans.first).layer.params, machine: p.machine,
                                          arcTolerance: 0.005)
        var measured = 0.0
        for (k, entry) in plans.enumerated() {
            let loads = Self.loads(entry, settings: s)
            let total = loads.reduce(0) { $0 + $1.length }
            let inBand = loads.filter { abs($0.load - 1) <= 0.15 }.reduce(0) { $0 + $1.length }
            let worst = loads.map(\.load).max() ?? 0
            let share = inBand / max(total, 1)
            print("#89 level \(k + 1) at \(entry.layer.z)\(entry.layer.stepUp ? " (step-up)" : ""): \(Int(total)) mm measured, "
                + "\(Int(100 * share))% within 15%, worst \(worst)")
            guard total > 100 else { continue }
            measured += total
            // A short level is mostly the ends of passes running out into narrow terraces, light rather than heavy.
            let wanted = total > 2000 ? 0.85 : 0.6
            #expect(share >= wanted, "level \(k + 1): \(Int(100 * share))% of \(Int(total)) mm within 15% of the load")
            #expect(worst <= 1.4, "level \(k + 1): worst \(worst)")
        }
        #expect(measured > 3000)
    }

    /// Simulated against the model, adaptive roughing leaves the allowance everywhere (it never cuts into it), and leaves
    /// no more than offset roughing does.
    @Test func leavesTheAllowanceAndClearsWhatOffsetRoughingDoes() throws {
        let adaptive = Self.relief(.adaptive), offset = Self.relief(nil)
        let allowance = Self.roughParams(adaptive).allowance
        func run(_ p: Project) throws -> (job: JobResult, grid: HeightGrid, seconds: Double) {
            let start = Date()
            let job = CAMEngine.generate(p)
            let seconds = Date().timeIntervalSince(start)
            #expect(!job.hasErrors, "\(job.issues.map(\.message))")
            return (job, Fixture.simulate(job.toolpaths, stock: p.stock, cell: 0.3), seconds)
        }
        let a = try run(adaptive), o = try run(offset)
        let tp = try #require(a.job.toolpaths.first)
        #expect(tp.radialLoad == AdaptiveSettings.defaultLoad)
        // The toolpath itself: never closer to the model than the allowance (less the grid's sampling), measured with
        // the exact drop-cutter.
        let clearance = Self.clearance(tp, project: adaptive)
        #expect(clearance >= allowance - 0.03, "comes within \(clearance) mm of the model")
        // The material it leaves: nowhere lower than offset roughing leaves it, and at most a hair higher.
        let model = RestFinishingTests.modelSurface(adaptive, on: a.grid)
        var below = 0, compared = 0, more = 0
        var worst = 0.0
        for i in a.grid.heights.indices where model.covered[i] {
            compared += 1
            let h = Double(a.grid.heights[i]), oh = Double(o.grid.heights[i])
            worst = max(worst, oh - h)
            if h < oh - 0.05 { below += 1 }
            if h > oh + 0.05 { more += 1 }
        }
        let ta = a.job.estimatedSeconds, to = o.job.estimatedSeconds
        print("#89 demo relief: adaptive \(Int(ta)) s run, \(String(format: "%.1f", a.seconds)) s to generate; offset \(Int(to)) s run, "
            + "\(String(format: "%.1f", o.seconds)) s to generate; worst into the allowance \(worst) mm; \(more) of \(compared) cells left higher")
        #expect(compared > 50_000)
        #expect(below == 0, "\(below) cells cut into the allowance (worst \(worst) mm)")
        #expect(more < compared / 200, "\(more) of \(compared) cells left higher than offset roughing leaves them")
    }

    /// Run times (the planner's estimate) and generation times for each clearing, on the demo relief and on it carved
    /// 0.9" deep, written to `.build/rough3d-adaptive-times.txt` for the PR and the docs.
    @Test func runTimesAgainstOffsetRoughing() throws {
        var lines: [String] = []
        let reliefs: [(String, (Rough3DClearing?) -> Project)] = [
            ("demo relief (0.4\")", { Self.relief($0) }), ("deep relief (0.9\")", { Self.deepRelief($0) }),
        ]
        for (name, make) in reliefs {
            var row = [name]
            for (clearing, load) in [(Rough3DClearing.offset, nil), (.raster, nil), (.adaptive, nil), (.adaptive, 0.2)] as [(Rough3DClearing, Double?)] {
                var p = make(clearing == .offset ? nil : clearing)
                if let load, case var .rough3D(r) = p.operations[0].kind {
                    r.adaptive = AdaptiveSettings(optimalLoad: load)
                    p.operations[0].kind = .rough3D(r)
                }
                let start = Date()
                let job = CAMEngine.generate(p)
                let generation = Date().timeIntervalSince(start)
                #expect(!job.hasErrors, "\(job.issues.map(\.message))")
                #expect(job.toolpaths.first.map { !$0.isEmpty } == true)
                // And at the feed and speed Use Recommended gives it (the chart's, thinned and derated as the toolpath is).
                let op = p.operations[0]
                let rec = ChipLoad.recommend(for: op.tool, material: .hardwood, machine: p.machine,
                                             thinning: op.kind.adaptiveClearing.map { ChipLoad.radialThinning(load: $0.load) } ?? 1,
                                             feedLimit: op.kind.adaptiveClearing?.loopFeedLimit(tool: op.tool, machine: p.machine),
                                             passDepth: op.kind.deepestPass(op.tool))
                p.operations[0].tool.cutting.feedRate = rec.feed
                p.operations[0].tool.cutting.spindleRPM = rec.rpm
                let recommended = CAMEngine.generate(p)
                func time(_ s: Double) -> String { "\(Int(s.rounded()) / 60) min \(Int(s.rounded()) % 60) s" }
                let label = clearing.label + (load.map { " at \(Int(100 * $0))%" } ?? "")
                row.append("\(label) \(time(job.estimatedSeconds)), \(time(recommended.estimatedSeconds)) at its recommended "
                    + "\(Int((rec.feed / 25.4).rounded())) in/min (generated in \(String(format: "%.1f", generation)) s)")
            }
            lines.append(row.joined(separator: "; "))
        }
        print(lines.map { "#89 " + $0 }.joined(separator: "\n"))
        let url = GoldenPostTests.fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/rough3d-adaptive-times.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
