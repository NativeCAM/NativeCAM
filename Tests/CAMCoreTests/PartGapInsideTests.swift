import Foundation
import Testing
@testable import CAMCore

/// #190: the #186 checks for inside and on-line profiles. An inside cut reaches its bit's width (plus any allowance) in
/// from the hole's wall, so a part nested in the hole nearer than that is cut into. An on-line cut reaches a bit radius
/// on each side of its line, into another toolpath's part or, a bit's width from it, another shape of the same profile's
/// cut. Each is refused, naming the parts and the gap. Saved projects in `Fixtures/part-gaps-inside` (listed in its
/// README).
struct PartGapInsideTests {
    static let folder = GoldenPostTests.fixtures.appendingPathComponent("part-gaps-inside")
    typealias Catalog = TabsStartPointCatalogTests
    typealias Gaps = PartGapTests

    static func saved(_ name: String, make: () -> Project) throws -> Project {
        let url = folder.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    // MARK: Inside cuts

    /// A 6 × 6 in frame with a 3 × 3 in hole cut by an inside profile, and a 2.4 × 2.4 in part nested in the hole,
    /// `gap` from its left wall (0.6 in less that from its right), cut out by its own outside profile.
    static func nested(gap: Double) -> Project {
        let frame = Gaps.box(1, "Frame", width: 6.inch, height: 6.inch, at: Vec2(150, 150))
        let hole = Gaps.box(2, "Hole", width: 3.inch, height: 3.inch, at: Vec2(150, 150))
        let part = Gaps.box(3, "Nested part", width: 2.4.inch, height: 2.4.inch, at: Vec2(150 - 1.5.inch + gap + 1.2.inch, 150))
        let cutHole = Catalog.profile(10, name: "Cut hole", shapes: [hole], side: .inside, tabs: TabSettings(enabled: true))
        let cutPart = Catalog.profile(11, name: "Cut out nested part", shapes: [part], tabs: TabSettings(enabled: true))
        let cutFrame = Catalog.profile(12, name: "Cut out frame", shapes: [frame], tabs: TabSettings(enabled: true))
        return Catalog.project("Part \(gap / 25.4) in inside a hole", shapes: [frame, hole, part], ops: [cutPart, cutHole, cutFrame],
                               width: 300, height: 300)
    }

    static let insideCases: [(name: String, gap: Double, refused: Bool)] = [
        ("nested-part-under-bit-width", 0.24.inch, true),
        ("nested-part-at-bit-width", 0.25.inch, false),
        ("nested-part-over-bit-width", 0.26.inch, false),
    ]

    @Test(arguments: insideCases.indices)
    func aHolesCutThatReachesAPartNestedInItIsRefused(_ k: Int) throws {
        let (name, gap, refused) = Self.insideCases[k]
        let p = try Self.saved(name) { Self.nested(gap: gap) }
        let job = CAMEngine.generate(p)
        let hole = try #require(job.toolpaths.first { $0.name == "Cut hole" })
        let errors = hole.errors ?? []
        #expect(!errors.isEmpty == refused, "\(name): \(errors)")
        if refused {
            #expect(errors.count == 1 && errors[0].contains("“Hole”") && errors[0].contains("“Cut out nested part”"), "\(errors)")
        }
        // The nested part's own cut reaches the hole's wall the same way: refused too, naming the hole's toolpath.
        let part = try #require(job.toolpaths.first { $0.name == "Cut out nested part" })
        #expect((part.errors ?? []).contains { $0.contains("“Nested part”") && $0.contains("“Cut hole”") } == refused, "\(part.errors ?? [])")
        // The frame's cut-out is far from both.
        #expect(job.toolpaths.first { $0.name == "Cut out frame" }?.errors == nil)
    }

    // MARK: On-line cuts

    /// A 3 in line cut on the line, `gap` from the edge of a 2 × 2 in pocket another toolpath cuts.
    static func lineBesidePocket(gap: Double) -> Project {
        let recess = Gaps.box(2, "Recess", width: 2.inch, height: 2.inch, at: Vec2(100, 100))
        let x = 100 + 1.inch + gap
        let line = DesignShape(id: Catalog.id(1), name: "Groove",
                               kind: .paths([Polyline([Vec2(x, 100 - 1.5.inch), Vec2(x, 100 + 1.5.inch)], closed: false)]), position: .zero)
        let pocket = CAMOperation(id: Catalog.id(10), name: "Pocket recess",
                                  kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))), shapeIDs: [recess.id],
                                  tool: Catalog.quarter)
        let groove = Catalog.profile(11, name: "Cut groove", shapes: [line], side: .on, depth: DepthSettings(cutDepth: 0.125.inch),
                                     tabs: TabSettings(enabled: false))
        return Catalog.project("Groove \(gap / 25.4) in from a pocket", shapes: [recess, line], ops: [pocket, groove], width: 250, height: 200)
    }

    static let lineCases: [(name: String, gap: Double, refused: Bool)] = [
        ("line-into-pocket", 0.115.inch, true),
        // Exactly a bit radius off, the bit only touches the pocket's wall, but the check keeps 0.1 mm clear of a part from
        // the material side (another toolpath's part is held as a 0.1 mm band inside its finished walls): refused.
        ("line-at-bit-radius-from-pocket", 0.125.inch, true),
        ("line-clear-of-pocket", 0.135.inch, false),
    ]

    @Test(arguments: lineCases.indices)
    func anOnLineCutThatReachesAnotherToolpathsPartIsRefused(_ k: Int) throws {
        let (name, gap, refused) = Self.lineCases[k]
        let p = try Self.saved(name) { Self.lineBesidePocket(gap: gap) }
        let job = CAMEngine.generate(p)
        let groove = try #require(job.toolpaths.first { $0.name == "Cut groove" })
        let errors = groove.errors ?? []
        #expect(!errors.isEmpty == refused, "\(name): \(errors)")
        if refused {
            #expect(errors.count == 1 && errors[0].contains("“Groove”") && errors[0].contains("“Pocket recess”"), "\(errors)")
        }
        #expect(job.toolpaths.first { $0.name == "Pocket recess" }?.errors == nil)
    }

    /// Two 3 × 2 in rectangles cut on the line by one profile, `gap` apart: their cuts reach a bit radius each way,
    /// so closer than the bit's width the material between their lines is cut away. An on-line cut has no finished
    /// side and that's often meant (small lettering, hatching), so it's a warning, not an error.
    static func linesApart(gap: Double) -> Project {
        let left = Gaps.box(1, "Left", width: 3.inch, height: 2.inch, at: Vec2(100, 100))
        let right = Gaps.box(2, "Right", width: 3.inch, height: 2.inch, at: Vec2(100 + 3.inch + gap, 100))
        let op = Catalog.profile(11, name: "Cut on the lines", shapes: [left, right], side: .on, depth: DepthSettings(cutDepth: 0.125.inch),
                                 tabs: TabSettings(enabled: false))
        return Catalog.project("Lines \(gap / 25.4) in apart", shapes: [left, right], ops: [op], width: 300, height: 200)
    }

    /// 0.24 in apart: warned. Exactly the bit's width, the two kerfs meet with nothing between them cut, so neither 0.25
    /// nor 0.26 in is warned about.
    static let pairCases: [(name: String, gap: Double, warned: Bool)] = [
        ("lines-under-bit-width", 0.24.inch, true),
        ("lines-at-bit-width", 0.25.inch, false),
        ("lines-over-bit-width", 0.26.inch, false),
    ]

    @Test(arguments: pairCases.indices)
    func onLineCutsCloserThanTheBitsWidthAreWarnedAbout(_ k: Int) throws {
        let (name, gap, warned) = Self.pairCases[k]
        let p = try Self.saved(name) { Self.linesApart(gap: gap) }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        // Never refused: the file is still written.
        #expect(tp.errors == nil && !job.hasErrors, "\(name): \(tp.errors ?? [])")
        let crowded = tp.warnings.filter { $0.contains("the material between them is cut away") }
        #expect(crowded.count == (warned ? 1 : 0), "\(name): \(tp.warnings)")
        if let w = crowded.first {
            #expect(w.contains("“Left”") && w.contains("“Right”") && w.contains(String(format: "%.4f in apart", gap / 25.4)), "\(w)")
        }
    }
}
