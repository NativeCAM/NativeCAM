import Foundation
import Testing
@testable import CAMCore

/// #186: an outside profile round parts closer together than the cut reaches from a wall (the bit's width, plus any
/// allowance) cuts into each part. So does one whose bit reaches a part another toolpath cuts. Both are refused,
/// naming the parts and the gap. Saved projects in `Fixtures/part-gaps` (listed in its README).
struct PartGapTests {
    static let folder = GoldenPostTests.fixtures.appendingPathComponent("part-gaps")
    typealias Catalog = TabsStartPointCatalogTests

    /// Loads a saved project. Update mode writes a missing one from `make`, but never replaces one.
    static func saved(_ name: String, make: () -> Project) throws -> Project {
        let url = folder.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try make().encoded().write(to: url)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func box(_ n: Int, _ name: String, width: Double, height: Double, at p: Vec2) -> DesignShape {
        DesignShape(id: Catalog.id(n), name: name, kind: .rectangle(width: width, height: height, cornerRadius: 0), position: p)
    }

    /// Two 3 × 2 in parts side by side, `gap` apart, one outside profile with a 1/4" end mill (no tabs).
    static func pair(gap: Double, allowance: Double = 0) -> Project {
        let left = box(1, "Left", width: 3.inch, height: 2.inch, at: Vec2(100, 100))
        let right = box(2, "Right", width: 3.inch, height: 2.inch, at: Vec2(100 + 3.inch + gap, 100))
        var op = Catalog.profile(1, shapes: [left, right], tabs: TabSettings(enabled: false))
        if case var .profile(p) = op.kind { p.allowance = allowance; op.kind = .profile(p) }
        return Catalog.project("Two parts \(gap / 25.4) in apart", shapes: [left, right], ops: [op], width: 300, height: 200)
    }

    static let pairs: [(name: String, gap: Double, allowance: Double, refused: Bool)] = [
        ("parts-under-bit-width", 0.24.inch, 0, true),
        ("parts-at-bit-width", 0.25.inch, 0, false),
        ("parts-over-bit-width", 0.26.inch, 0, false),
        ("parts-at-bit-width-with-allowance", 0.26.inch, 0.02.inch, true),
    ]

    @Test(arguments: pairs.indices)
    func partsCloserThanTheCutsReachAreRefused(_ k: Int) throws {
        let (name, gap, allowance, refused) = Self.pairs[k]
        let p = try Self.saved(name) { Self.pair(gap: gap, allowance: allowance) }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let errors = tp.errors ?? []
        #expect(job.hasErrors == refused, "\(name): \(errors)")
        if refused {
            let e = try #require(errors.first)
            #expect(errors.count == 1 && e.contains("“Left”") && e.contains("“Right”") && e.contains("cuts into the other"), "\(e)")
            #expect(e.contains(String(format: "%.4f in apart", gap / 25.4)), "\(e)")
        }
    }

    /// A 3 × 2 in part cut out next to a 2 × 2 in pocket `gap` from it, the pocket's own toolpath run first.
    static func besidePocket(gap: Double) -> Project {
        let part = box(1, "Part", width: 3.inch, height: 2.inch, at: Vec2(100, 100))
        let recess = box(2, "Recess", width: 2.inch, height: 2.inch, at: Vec2(100 + 2.5.inch + gap, 100))
        let pocket = CAMOperation(id: Catalog.id(10), name: "Pocket recess",
                                  kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))), shapeIDs: [recess.id],
                                  tool: Catalog.quarter)
        let cut = Catalog.profile(1, name: "Cut out part", shapes: [part], tabs: TabSettings(enabled: true))
        return Catalog.project("Part \(gap / 25.4) in from a pocket", shapes: [part, recess], ops: [pocket, cut], width: 300, height: 200)
    }

    @Test(arguments: [(0.15.inch, true), (0.3.inch, false)])
    func aCutThatReachesAnotherToolpathsPartIsRefused(gap: Double, refused: Bool) throws {
        let name = refused ? "part-into-pocket" : "part-clear-of-pocket"
        let p = try Self.saved(name) { Self.besidePocket(gap: gap) }
        let job = CAMEngine.generate(p)
        let cut = try #require(job.toolpaths.first { $0.name == "Cut out part" })
        let errors = cut.errors ?? []
        #expect(!errors.isEmpty == refused, "\(name): \(errors)")
        if refused {
            #expect(errors.count == 1 && errors[0].contains("“Part”") && errors[0].contains("“Pocket recess”"), "\(errors)")
        }
        // The pocket is never refused for the cut-out next to it.
        #expect(job.toolpaths.first { $0.name == "Pocket recess" }?.errors == nil)
    }
}
