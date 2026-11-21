import Foundation
import Testing
@testable import CAMCore

/// Nesting speed on a bigger job. Off unless `NATIVECAM_BENCH=1`:
/// `NATIVECAM_BENCH=1 scripts/test.sh --filter NestingBenchmark`. The results are printed and written to
/// `.build/nesting-bench.txt`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NATIVECAM_BENCH"] != nil))
struct NestingBenchmark {
    /// Four sets of the demo shelf's parts, six lines of text, a star and an ellipse (52 parts, 19 different outlines)
    /// on a 96" × 48" sheet: more than fits.
    static func bigJob() -> Project {
        var p = Project.demoNesting()
        p.stock.width = 96.inch
        let base = p.shapes
        for k in 1..<4 {
            for s in base where !s.isKeepOut {
                var c = s
                c.id = UUID()
                c.position.y += Double(k) * 50.inch
                p.shapes.append(c)
            }
        }
        for i in 0..<6 {
            p.shapes.append(DesignShape(kind: .text(TextSpec(string: "NC\(i)", capHeight: 3.inch)), position: Vec2(60.inch, Double(i) * 6.inch + 4.inch)))
        }
        p.shapes.append(DesignShape(kind: .star(points: 7, outerRadius: 5.inch, innerRadius: 2.5.inch), position: Vec2(80.inch, 30.inch)))
        p.shapes.append(DesignShape(kind: .ellipse(radiusX: 8.inch, radiusY: 4.inch), position: Vec2(80.inch, 10.inch)))
        return p
    }

    @Test func bigJob() throws {
        var lines: [String] = []
        func say(_ s: String) {
            print(s)
            lines.append(s)
        }
        let p = Self.bigJob()
        let t0 = Date()
        let toolpaths = CAMEngine.generate(p).toolpaths
        let job = try NestJob.prepare(p, selection: [], toolpaths: toolpaths)
        say(String(format: "%d parts, toolpaths and parts found in %.2f s", job.parts.count, Date().timeIntervalSince(t0)))
        var settings = job.defaultSettings
        settings.maxEvaluations = 1
        var t = Date()
        let first = job.nest(settings)
        say(String(format: "first layout: %.2f s, %d placed, %.1f%% of the %.1f in used", Date().timeIntervalSince(t),
                   first.placedCount, first.utilization * 100, first.usedLength / 25.4))
        for seconds in [2.0, 5.0] {
            settings.maxEvaluations = nil
            settings.timeLimit = seconds
            t = Date()
            let r = job.nest(settings)
            say(String(format: "%.0f s search: %d layouts in %.2f s, %d placed, %.1f%% of the %.1f in used", seconds, r.evaluations,
                       Date().timeIntervalSince(t), r.placedCount, r.utilization * 100, r.usedLength / 25.4))
            let problems = Nesting.violations(job.nestingParts, placements: r.placements, sheet: job.sheet, obstacles: job.obstacles,
                                              settings: settings)
            #expect(problems.isEmpty, "\(problems)")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/nesting-bench.txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
