import Foundation
import Testing
@testable import CAMCore

/// Timings for the drop-cutters on the demo jobs. Off unless `NATIVECAM_BENCH=1`:
/// `NATIVECAM_BENCH=1 scripts/test.sh --filter DropCutterBenchmark`. Each figure is the best of three runs; the results
/// are printed and written to `.build/dropcutter-bench.txt`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NATIVECAM_BENCH"] != nil))
struct DropCutterBenchmark {
    static func best(_ runs: Int = 3, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let t = Date()
            body()
            best = min(best, Date().timeIntervalSince(t))
        }
        return best
    }

    static func context(_ p: Project) -> GenerationContext {
        GenerationContext(stock: p.stock, machine: p.machine, flattenTolerance: 0.01,
                          arcTolerance: min(0.005, p.machine.arcFitTolerance / 2))
    }

    static func shapes(_ p: Project, _ op: CAMOperation) -> [DesignShape] {
        p.shapes.filter { op.shapeIDs.contains($0.id) }
    }

    @Test func demoJobs() throws {
        var lines: [String] = []
        func report(_ s: String) {
            print(s)
            lines.append(s)
        }

        // The demo relief: its 1/4" ball finish, then the same finish with other bits.
        let relief = Project.demoRelief()
        let finish = try #require(relief.operations.first { if case .finish3D = $0.kind { true } else { false } })
        let ctx = Self.context(relief)
        let shapes = Self.shapes(relief, finish)
        var moves = 0
        let ballTime = Self.best {
            moves = CAMEngine.generate(finish, shapes: shapes, context: ctx).first?.motions.count ?? 0
        }
        report(String(format: "relief finish, 1/4\" ball: %.3f s (%d moves)", ballTime, moves))
        let lib = ToolLibrary.starter
        var bull = lib.tool(number: 7)!
        bull.shape = .bullNose
        bull.cornerRadius = 1.5
        bull.name = "1/4\" bull nose r1.5"
        for tool in [lib.tool(number: 5)!, lib.tool(number: 6)!, bull] {
            var op = finish
            op.tool = tool
            var n = 0
            let t = Self.best { n = CAMEngine.generate(op, shapes: shapes, context: ctx).first?.motions.count ?? 0 }
            report(String(format: "relief finish, %@: %.3f s (%d moves)", tool.name, t, n))
        }
        // The same finish with each strategy (pencil with a 1/8" ball, as it would follow the main finish).
        for (label, change) in [("cross-hatched raster", { (p: inout Finish3DParams) in p.crossHatch = true }),
                                ("waterline", { $0.strategy = .waterline }), ("steep and shallow", { $0.strategy = .steepShallow }),
                                ("pencil, 1/8\" ball", { $0.strategy = .pencil })] as [(String, (inout Finish3DParams) -> Void)] {
            var op = finish
            guard case var .finish3D(params) = op.kind else { continue }
            change(&params)
            op.kind = .finish3D(params)
            if params.strategy == .pencil { op.tool.diameter = 0.125.inch }
            var n = 0
            let t = Self.best { n = CAMEngine.generate(op, shapes: shapes, context: ctx).first?.motions.count ?? 0 }
            report(String(format: "relief finish, %@: %.3f s (%d moves)", label, t, n))
        }
        let reliefJob = Self.best(1) { _ = CAMEngine.generate(relief) }
        report(String(format: "relief whole job: %.3f s", reliefJob))

        // The demo pawn: its rotary finish.
        let pawn = Project.demoPawn()
        let rotary = try #require(pawn.operations.first { if case .rotaryFinish = $0.kind { true } else { false } })
        let pctx = Self.context(pawn)
        let pshapes = Self.shapes(pawn, rotary)
        var pmoves = 0
        let pawnTime = Self.best { pmoves = CAMEngine.generate(rotary, shapes: pshapes, context: pctx).first?.motions.count ?? 0 }
        report(String(format: "pawn rotary finish (no rounding first), 1/4\" ball: %.3f s (%d moves)", pawnTime, pmoves))
        let pawnJob = Self.best(1) { _ = CAMEngine.generate(pawn) }
        report(String(format: "pawn whole job: %.3f s", pawnJob))

        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/dropcutter-bench.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
