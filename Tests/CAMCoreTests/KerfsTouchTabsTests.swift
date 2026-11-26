import Foundation
import Testing
@testable import CAMCore

/// Tabs placed by hand on two parts cut by one outside profile, near enough that their kerfs touch or overlap (#182): a
/// 6 × 4 in lid and a 3 × 1 in divider above its back edge, four tabs on the lid's sides and front, two on the divider's
/// bottom edge, the one facing the lid. Saved projects in `Fixtures/tabs-start` (listed in its README).
///
/// Each tab must go on the loop round its own part, and must still hold its part once every loop is cut: closer than
/// two bit widths, the lid's kerf runs through the divider's tabs, so the lid's loop lifts over them too.
struct KerfsTouchTabsTests {
    typealias Catalog = TabsStartPointCatalogTests

    static let bit = Catalog.quarter

    static func lid() -> DesignShape {
        DesignShape(id: Catalog.id(1), name: "Lid", kind: .rectangle(width: 6.inch, height: 4.inch, cornerRadius: 0), position: Vec2(100, 75))
    }

    /// The divider with its bottom edge `gap` above the lid's back edge.
    static func divider(gap: Double) -> DesignShape {
        DesignShape(id: Catalog.id(2), name: "Divider", kind: .rectangle(width: 3.inch, height: 1.inch, cornerRadius: 0),
                    position: Vec2(100, 75 + 2.inch + gap + 0.5.inch))
    }

    static func project(gap: Double) -> Project {
        let lid = lid(), divider = divider(gap: gap)
        let tabs = [Catalog.mark(lid, -3.inch, 0), Catalog.mark(lid, 3.inch, 0), Catalog.mark(lid, -1.inch, -2.inch),
                    Catalog.mark(lid, 1.inch, -2.inch), Catalog.mark(divider, -0.75.inch, -0.5.inch), Catalog.mark(divider, 0.75.inch, -0.5.inch)]
        return Catalog.project("Lid and divider \(gap / 25.4) in apart", shapes: [lid, divider],
                               ops: [Catalog.profile(1, shapes: [lid, divider], tabs: TabSettings(enabled: true, placed: tabs))],
                               width: 300, height: 250)
    }

    /// The gaps: a bit width less 0.01 in, exactly one, one plus 0.01 in, and two plus 0.01 in (the kerfs apart).
    static let cases: [(name: String, gap: Double, shared: Bool)] = [
        ("kerfs-overlap-under-bit-width", 0.24.inch, true),
        ("kerfs-touch-at-bit-width", 0.25.inch, true),
        ("kerfs-overlap-over-bit-width", 0.26.inch, true),
        ("kerfs-apart-over-two-bit-widths", 0.51.inch, false),
    ]

    /// Each loop's lifts off the final pass's Z, by the loop's lowest Y at that Z (the lid's loop is the lower one).
    static func liftsByLoop(_ tp: Toolpath, level: Double) -> [(minY: Double, lifts: Int)] {
        var loops: [(minY: Double, lifts: Int)] = []
        var current: (minY: Double, lifts: Int)?
        tp.forEachMotion { s, m in
            if m.kind == .rapid {
                if let c = current, c.minY.isFinite { loops.append(c) }
                current = nil
                return
            }
            guard m.kind == .feed || m.kind.isArc else { return }
            var c = current ?? (.infinity, 0)
            if abs(s.z - level) < 1e-3 { c.minY = min(c.minY, s.y) }
            if abs(s.z - level) < 1e-4, m.end.z > level + 0.01 { c.lifts += 1 }
            current = c
        }
        if let c = current, c.minY.isFinite { loops.append(c) }
        return loops.sorted { $0.minY < $1.minY }
    }

    @Test(arguments: cases.indices)
    func tabsHoldBothParts(_ k: Int) throws {
        let (name, gap, shared) = Self.cases[k]
        let p = try Catalog.edgeCase(name) { Self.project(gap: gap) }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let level = -Catalog.through.cutDepth
        // No loop is left without tabs, so no "frees its part" warning.
        #expect(!tp.warnings.contains { $0.contains("no tabs") }, "\(name): \(tp.warnings)")
        let loops = Self.liftsByLoop(tp, level: level)
        #expect(loops.count == 2, "\(name)")
        // The lid's own four, and the divider's two where its kerf crosses theirs; the divider's two.
        #expect(loops.map(\.lifts) == [shared ? 6 : 4, 2], "\(name): \(loops)")
        #expect((tp.notes ?? []).contains { $0.contains("less than two bit widths") } == shared, "\(name): \(tp.notes ?? [])")
        // Each tab is marked on its own part: the divider's two on the divider, wherever the loops coincide.
        let marks = try #require(tp.tabMarks)
        #expect(marks.filter { $0.shapeID == Catalog.id(2) }.count == 2, "\(name)")
        #expect(marks.filter { $0.shapeID == Catalog.id(1) }.count == (shared ? 6 : 4), "\(name)")
        #expect(marks.allSatisfy { $0.placed && $0.cut && $0.flag == nil }, "\(name)")
        // The bridge under each of the divider's tabs, from its bottom edge to the far side of its kerf (or the lid's
        // back edge, nearer), stands to the tabs' top: no cut below it comes within a bit radius.
        let tabTop = level + TabSettings(enabled: true).thickness
        let lidBack = 75 + 2.inch, dividerBottom = lidBack + gap
        let low = Catalog.cutPoints(tp).filter { $0.z < tabTop - 0.05 }
        for x in [100 - 0.75.inch, 100 + 0.75.inch] {
            let reach = max(lidBack, dividerBottom - 2 * Self.bit.radius)
            let bridge = (0...10).map { Vec2(x, dividerBottom - (dividerBottom - reach) * Double($0) / 10) }
            let cut = low.filter { q in bridge.contains { q.xy.distance(to: $0) < Self.bit.radius - 0.05 } }
            #expect(cut.isEmpty, "\(name): the tab at x \(x) is cut away at \(cut.prefix(3))")
        }
    }

    // MARK: Evenly spaced tabs

    static func evenProject(gap: Double) -> Project {
        let lid = lid(), divider = divider(gap: gap)
        return Catalog.project("Lid and divider \(gap / 25.4) in apart, even tabs", shapes: [lid, divider],
                               ops: [Catalog.profile(1, shapes: [lid, divider], tabs: TabSettings(enabled: true, count: 4))],
                               width: 300, height: 250)
    }

    static let evenCases: [(name: String, gap: Double, moved: Bool)] = [
        ("even-tabs-kerfs-overlap-under-bit-width", 0.24.inch, true),
        ("even-tabs-kerfs-overlap-over-bit-width", 0.26.inch, true),
        ("even-tabs-just-under-two-bit-widths", 0.49.inch, true),
    ]

    /// The normal into the kerf at a tab: square to the chord between its ends on the wall, away from its shape's
    /// middle (towards it for the frame's hole, `Catalog.id(2)`). On a corner, across the corner.
    static func outward(_ shape: DesignShape, mark: TabMark) -> Vec2 {
        let along = mark.to - mark.from
        var n = along.length > 1e-9 ? Vec2(-along.y, along.x).normalized : (mark.point - shape.position).normalized
        let out = (n.x * (mark.point.x - shape.position.x) + n.y * (mark.point.y - shape.position.y)) > 0
        if out == (shape.id == Catalog.id(2)) { n = n * -1 }
        return n
    }

    /// The tabs whose bridge (from the drawn wall across the kerf, a bit width out) a cut below the tabs' top reaches.
    static func cutAway(_ tp: Toolpath, shapes: [DesignShape]) -> [TabMark] {
        let tabTop = -Catalog.through.cutDepth + TabSettings(enabled: true).thickness
        let low = Catalog.cutPoints(tp).filter { $0.z < tabTop - 0.05 }
        return (tp.tabMarks ?? []).filter { mark in
            guard let shape = shapes.first(where: { $0.id == mark.shapeID }) else { return true }
            let n = outward(shape, mark: mark)
            let bridge = (0...10).map { mark.point + n * (2 * bit.radius * Double($0) / 10) }
            return low.contains { q in bridge.contains { q.xy.distance(to: $0) < bit.radius - 0.05 } }
        }
    }

    @Test(arguments: evenCases.indices)
    func evenTabsMoveOffNeighboursKerfs(_ k: Int) throws {
        let (name, gap, moved) = Self.evenCases[k]
        let p = try Catalog.edgeCase(name) { Self.evenProject(gap: gap) }
        let tp = try #require(CAMEngine.generate(p).toolpaths.first)
        #expect(tp.errors == nil, "\(name): \(tp.errors ?? [])")
        #expect((tp.notes ?? []).contains { $0.contains("evenly spaced tabs") } == moved, "\(name): \(tp.notes ?? [])")
        let marks = try #require(tp.tabMarks)
        #expect(marks.filter { $0.shapeID == Catalog.id(1) }.count == 4 && marks.filter { $0.shapeID == Catalog.id(2) }.count == 4, "\(name)")
        let away = Self.cutAway(tp, shapes: p.shapes)
        #expect(away.isEmpty, "\(name): tabs cut away at \(away.map(\.point))")
        #expect(Self.liftsByLoop(tp, level: -Catalog.through.cutDepth).map(\.lifts) == [4, 4], "\(name)")
        // The part-hold checks count the cut-out as holding its parts.
        #expect(PartHold.holdsPart(p.operations[0], in: p))
    }

    /// A part inside a frame's hole, off centre, 0.275 in from it on two sides and 0.475 in on the others: every
    /// stretch of its loop is closer than two bit widths to the hole's. Placed tabs hold it to the frame (the hole's
    /// loop lifts over them too). With two evenly spaced tabs, the hole's kerf cuts both away: refused. With four, one
    /// is left: held, with a warning that the others are cut away.
    static func surroundedProject(tabs: String) -> Project {
        let outer = DesignShape(id: Catalog.id(1), name: "Frame", kind: .rectangle(width: 5.inch, height: 4.5.inch, cornerRadius: 0),
                                position: Vec2(100, 100))
        let hole = DesignShape(id: Catalog.id(2), name: "Frame hole", kind: .rectangle(width: 3.25.inch, height: 2.75.inch, cornerRadius: 0),
                               position: Vec2(100, 100))
        let island = DesignShape(id: Catalog.id(3), name: "Part", kind: .rectangle(width: 2.5.inch, height: 2.inch, cornerRadius: 0),
                                 position: Vec2(100 + 0.1.inch, 100 + 0.1.inch))
        let settings = tabs == "placed" ? TabSettings(enabled: true, placed: [Catalog.mark(outer, 2.5.inch, 0), Catalog.mark(outer, -2.5.inch, 0),
                                                                              Catalog.mark(island, 0, 1.inch), Catalog.mark(island, 0, -1.inch)])
            : TabSettings(enabled: true, count: tabs == "two" ? 2 : 4)
        return Catalog.project("Part in a frame, \(tabs) tabs", shapes: [outer, hole, island],
                               ops: [Catalog.profile(1, shapes: [outer, hole, island], tabs: settings)], width: 250, height: 250)
    }

    @Test(arguments: ["placed", "two", "four"])
    func surroundedPart(tabs: String) throws {
        let name = ["placed": "surrounded-part-placed-tabs", "two": "surrounded-part-two-even-tabs", "four": "surrounded-part-four-even-tabs"][tabs]!
        let p = try Catalog.edgeCase(name) { Self.surroundedProject(tabs: tabs) }
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let errors = tp.errors ?? []
        let lostWarning = tp.warnings.contains { $0.contains("cut away by the cut round another part") }
        switch tabs {
        case "two":
            #expect(errors.count == 1 && errors[0].contains("1 loop has no tabs left") && errors[0].contains("frees its part"), "\(errors)")
            #expect(job.hasErrors)
        case "four":
            #expect(errors.isEmpty, "\(errors)")
            #expect(lostWarning, "\(tp.warnings)")
        default:
            #expect(errors.isEmpty, "\(errors)")
            #expect(!lostWarning, "\(tp.warnings)")
            #expect(Self.cutAway(tp, shapes: p.shapes).isEmpty)
        }
    }
}
