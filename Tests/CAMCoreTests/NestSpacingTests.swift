import Foundation
import Testing
@testable import CAMCore

/// Nest Parts' default spacing (#193): two widths of the bit cutting the parts out plus 1/8 in (3 mm in a metric job),
/// and the same edge margin. At that spacing a neighbour's kerf never reaches a part's facing edges, so no tab is moved
/// or lost (#188). The spacing isn't saved: a project nested before keeps its layout. The projects are in
/// `Fixtures/nest-spacing` (see its README).
struct NestSpacingTests {
    static func fixture(_ name: String) throws -> Project {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "nativecam", subdirectory: "Fixtures/nest-spacing"),
                               "missing fixture \(name).nativecam")
        return try Project.decode(Data(contentsOf: url))
    }

    /// The least gap between any two parts' outlines, design coordinates.
    static func closestGap(_ job: NestJob) -> Double {
        func gap(_ a: [Polyline], _ b: [Polyline]) -> Double {
            var best = Double.infinity
            for p in a { for q in b {
                let n = q.points.count, segs = q.isClosed ? n : n - 1
                for v in p.points { for i in 0..<segs {
                    best = min(best, distancePointSegment(v, q.points[i], q.points[(i + 1) % n]))
                } }
            } }
            return best
        }
        var best = Double.infinity
        for i in job.parts.indices { for j in job.parts.indices where j > i {
            let a = job.parts[i].outlines, b = job.parts[j].outlines
            best = min(best, gap(a, b), gap(b, a))
        } }
        return best
    }

    @Test func theDefaultIsTwoBitWidthsAndTheMarginInInchesAndMillimetres() throws {
        for (name, bit, margin, expected) in [("shelf-unnested", 0.25.inch, 0.125.inch, 0.625.inch),
                                              ("metric-shelf-unnested", 6.0, 3.0, 15.0)] {
            let project = try Self.fixture(name)
            let job = try NestJob.prepare(project, selection: [])
            let tool = try #require(job.cutOutTool, "\(name)")
            #expect(abs(tool.diameter - bit) < 1e-9, "\(name)")
            #expect(abs(NestJob.spacingMargin(project.displayUnits) - margin) < 1e-9, "\(name)")
            #expect(job.defaultSpacing >= 2 * tool.diameter + margin - 1e-9, "\(name): \(job.defaultSpacing)")
            #expect(abs(job.defaultSpacing - expected) < 1e-9, "\(name): \(job.defaultSpacing)")
            #expect(job.defaultSettings.spacing == job.defaultSpacing)
            #expect(job.defaultSettings.edgeMargin == job.defaultSpacing)
        }
        // With nothing cutting the parts out yet, a 1/4" bit is assumed.
        #expect(abs(NestJob.defaultSpacing(bit: 0.25.inch, units: .inch) - 0.625.inch) < 1e-9)
        #expect(abs(NestJob.defaultSpacing(bit: 0.25.inch, units: .mm) - (12.7 + 3)) < 1e-9)
    }

    /// A shelf nested 0.375 in apart, as the default was before #193, opens with its layout unchanged: only a new nest
    /// starts at the new default.
    @Test func aProjectNestedBeforeKeepsItsSpacing() throws {
        let url = try #require(Bundle.module.url(forResource: "shelf-nested-old-default", withExtension: "nativecam",
                                                 subdirectory: "Fixtures/nest-spacing"))
        let data = try Data(contentsOf: url)
        let project = try Project.decode(data)
        let again = try Project.decode(project.encoded())
        #expect(again.shapes == project.shapes)
        let job = try NestJob.prepare(project, selection: [])
        let gap = Self.closestGap(job)
        #expect(abs(gap - 0.375.inch) < 0.05, "\(gap / 25.4) in")
        #expect(gap < job.defaultSpacing - 1)
        // Under two bit widths, #188 moves the facing tabs, and still every part keeps every tab.
        let issues = CAMEngine.generate(project).issues
        #expect(issues.contains { $0.message.contains("moved along their loops") })
        try NestedSheetTabsTests.checkEveryTab("shelf-nested-old-default", project)
    }

    /// The shelf nested at the new default, saved (inch and metric) and nested afresh: no tab is moved off a facing
    /// edge or cut away, and every part keeps every tab at its thickness.
    @Test func theShelfNestedAtTheDefaultKeepsEveryTab() throws {
        var projects: [(String, Project)] = try ["shelf-nested-new-default", "metric-shelf-nested-new-default"].map { ($0, try Self.fixture($0)) }
        for name in ["shelf-unnested", "metric-shelf-unnested"] {
            let p = try Self.fixture(name)
            let job = try NestJob.prepare(p, selection: [])
            var s = job.defaultSettings
            s.maxEvaluations = 20
            s.seed = 193
            let r = job.nest(s)
            #expect(r.placedCount == job.parts.count, "\(name)")
            #expect(job.check(r, settings: s).isEmpty, "\(name): \(job.check(r, settings: s))")
            projects.append(("\(name) nested", job.apply(r, to: p, settings: s).project))
        }
        for (name, project) in projects {
            let job = try NestJob.prepare(project, selection: [])
            #expect(Self.closestGap(job) >= job.defaultSpacing - 0.01, "\(name): \(Self.closestGap(job))")
            let generated = CAMEngine.generate(project)
            let messages = generated.issues.map(\.message) + generated.toolpaths.flatMap { $0.warnings + ($0.notes ?? []) }
            #expect(!messages.contains { $0.contains("moved along their loops") || $0.contains("cut away") }, "\(name): \(messages)")
            try NestedSheetTabsTests.checkEveryTab(name, project)
        }
    }
}
