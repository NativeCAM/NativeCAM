import Foundation
import Testing
@testable import CAMCore

/// Corner reliefs chosen corner by corner: each corner can have its own relief (dogbone, T-bone into either wall,
/// none) in place of the toolpath's setting, tied to its shape so it follows the shape around.
struct CornerChoiceTests {
    /// A 60 × 20 mortise: x 70…130, y 65…85.
    let mortise = Fixture.rect(60, 20, at: Vec2(100, 75))
    let corners: [(v: Vec2, u: Vec2)] = [(Vec2(70, 65), Vec2(1, 1)), (Vec2(130, 65), Vec2(-1, 1)),
                                         (Vec2(130, 85), Vec2(-1, -1)), (Vec2(70, 85), Vec2(1, -1))].map { ($0.0, $0.1.normalized) }
    let r = CutFixture.r
    let tee = CornerReliefSettings(style: .tBone, tBoneSide: .longer)

    func run(_ shapes: [DesignShape], _ op: CAMOperation) throws -> Toolpath {
        let (_, job) = CutFixture.job(shapes, [op])
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        return try #require(job.toolpaths.first)
    }

    func mortiseCut(_ relief: CornerReliefSettings, direction: CutDirection = .climb, shape: DesignShape? = nil) throws -> Toolpath {
        let s = shape ?? mortise
        return try run([s], CutFixture.profile([s], side: .inside, direction: direction, relief: relief))
    }

    func corner(_ tp: Toolpath, at p: Vec2) throws -> ReliefCorner {
        try #require(tp.reliefCorners?.first { $0.point.distance(to: p) < 0.05 }, "no corner at \(p)")
    }

    /// Spike tips in the motions (where a feed turns straight back), rounded to a micron.
    func spikeTips(_ tp: Toolpath) -> Set<String> {
        var out = Set<String>()
        var prev: Vec2?
        var pos = tp.start
        for m in tp.motions {
            defer { pos = m.end }
            guard m.kind == .feed else { prev = nil; continue }
            let d = m.end.xy - pos.xy
            guard d.length > 1e-6 else { continue }
            if let p = prev, p.dot(d.normalized) < -0.99 { out.insert(key(pos.xy)) }
            prev = d.normalized
        }
        return out
    }

    func key(_ p: Vec2) -> String { "\(Int((p.x * 1000).rounded())),\(Int((p.y * 1000).rounded()))" }

    /// Just past the long (horizontal) wall a bit radius along from the corner, and the same past the short wall.
    func notchCells(_ v: Vec2, _ u: Vec2) -> (pastLong: Vec2, pastShort: Vec2) {
        let sx = u.x > 0 ? 1.0 : -1.0, sy = u.y > 0 ? 1.0 : -1.0
        return (v + Vec2(sx * r, -sy * r * 0.5), v + Vec2(-sx * r * 0.5, sy * r))
    }

    func cut(_ g: HeightGrid, _ p: Vec2) -> Bool { CutFixture.height(g, p) <= -6 + 0.01 }

    @Test func flippingOneCornerMovesItsNotchToTheOtherWall() throws {
        let base = try mortiseCut(tee)
        let c = try corner(base, at: corners[0].v)
        guard case let .tBone(k) = c.relief else { Issue.record("expected a T-bone, got \(c.relief)"); return }
        let flipped = try mortiseCut(tee.setting(.tBone(wall: 1 - k), for: c))
        #expect(flipped.warnings.isEmpty, "\(flipped.warnings)")
        #expect(try corner(flipped, at: corners[0].v).isChanged)
        let grid = Fixture.simulate([flipped], stock: Fixture.stock, cell: 0.25)
        for (i, (v, u)) in corners.enumerated() {
            let cells = notchCells(v, u)
            let intoShort = i == 0
            #expect(cut(grid, cells.pastShort) == intoShort && cut(grid, cells.pastLong) == !intoShort, "corner \(v)")
            #expect(try corner(flipped, at: v).isChanged == intoShort)
        }
    }

    @Test func noneLeavesACornerAndDogboneReplacesATBone() throws {
        let base = try mortiseCut(tee)
        let c = try corner(base, at: corners[0].v)
        let (v, u) = corners[0]

        let left = try mortiseCut(tee.setting(.asCut, for: c))
        #expect(CutFixture.reversals(left) == 3 * 2, "three reliefs, two passes")
        let mark = try corner(left, at: v)
        #expect(mark.relief == .asCut && mark.tip == nil && mark.isChanged)
        let g1 = Fixture.simulate([left], stock: Fixture.stock, cell: 0.25)
        #expect(!cut(g1, v + u * 0.25) && !cut(g1, notchCells(v, u).pastLong))

        let dog = try mortiseCut(tee.setting(.dogbone, for: c))
        #expect(CutFixture.reversals(dog) == 4 * 2)
        let g2 = Fixture.simulate([dog], stock: Fixture.stock, cell: 0.25)
        #expect(cut(g2, v + u * 0.25), "the dogbone reaches the corner")
        #expect(!cut(g2, notchCells(v, u).pastLong), "no T-bone notch there")
    }

    @Test func climbAndConventionalAgreeWithChoices() throws {
        let base = try mortiseCut(tee)
        let c = try corner(base, at: corners[0].v)
        guard case let .tBone(k) = c.relief else { Issue.record("expected a T-bone"); return }
        var settings = tee.setting(.tBone(wall: 1 - k), for: c)
        settings = settings.setting(.asCut, for: try corner(base, at: corners[2].v))
        let climb = try mortiseCut(settings, direction: .climb)
        let conventional = try mortiseCut(settings, direction: .conventional)
        let a = Set((climb.reliefCorners ?? []).compactMap { $0.tip.map(key) })
        let b = Set((conventional.reliefCorners ?? []).compactMap { $0.tip.map(key) })
        #expect(a.count == 3)
        #expect(a == b)
        #expect(spikeTips(climb) == spikeTips(conventional))
    }

    @Test func choicesFollowTheShapeWhenItMovesTurnsAndScales() throws {
        let base = try mortiseCut(tee)
        let c = try corner(base, at: corners[0].v)
        guard case let .tBone(k) = c.relief else { Issue.record("expected a T-bone"); return }
        let settings = tee.setting(.tBone(wall: 1 - k), for: c)   // notch in the short (local-vertical) wall

        var moved = mortise
        moved.position = Vec2(120, 85)
        moved.rotation = 90
        moved.scale = 2
        let tp = try mortiseCut(settings, shape: moved)
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        // Local (-30, -10) → scaled (-60, -20) → turned 90° (20, -60) → moved (140, 25).
        let mark = try corner(tp, at: Vec2(140, 25))
        #expect(mark.isChanged)
        guard case let .tBone(wall) = mark.relief else { Issue.record("expected a T-bone, got \(mark.relief)"); return }
        #expect(abs(mark.walls[wall].direction.y) < 1e-6, "the short wall is horizontal now")
        let tip = try #require(mark.tip)
        #expect(abs(tip.y - 25) < 1e-6, "the bit centre sits on the bottom wall's line")
        #expect((tp.reliefCorners ?? []).filter(\.isChanged).count == 1)
    }

    @Test func choicesThatLoseTheirCornerAreReported() throws {
        let pts = [Vec2(70, 65), Vec2(130, 65), Vec2(130, 85), Vec2(70, 85)]
        var shape = DesignShape(kind: .paths([Polyline(pts, closed: true)]), position: .zero)
        let base = try mortiseCut(tee, shape: shape)
        var settings = tee.setting(.dogbone, for: try corner(base, at: Vec2(70, 65)))
        settings = settings.setting(.asCut, for: try corner(base, at: Vec2(130, 85)))
        #expect(settings.overrides?.count == 2)

        // Stretch the right-hand end: its corners move, the left ones don't.
        shape.kind = .paths([Polyline([Vec2(70, 65), Vec2(140, 65), Vec2(140, 85), Vec2(70, 85)], closed: true)])
        let tp = try mortiseCut(settings, shape: shape)
        #expect(try corner(tp, at: Vec2(70, 65)).relief == .dogbone)
        #expect(try !corner(tp, at: Vec2(140, 85)).isChanged)
        #expect(tp.warnings.contains("1 corner choice no longer matches a corner (its shape changed or left this toolpath), "
            + "so it's ignored. Reset it under Corners."), "\(tp.warnings)")

        // A choice for a shape that has left the toolpath.
        let other = Fixture.rect(30, 20, at: Vec2(100, 120))
        let both = try run([mortise, other], CutFixture.profile([mortise, other], side: .inside, relief: tee))
        let onOther = tee.setting(.asCut, for: try corner(both, at: Vec2(85, 110)))
        let alone = try mortiseCut(onOther)
        #expect(alone.warnings.contains { $0.hasPrefix("1 corner choice no longer matches a corner") }, "\(alone.warnings)")
    }

    @Test func cornerRecordsMatchWhatIsCut() throws {
        let tp = try mortiseCut(tee)
        let marks = try #require(tp.reliefCorners)
        #expect(marks.count == 4)
        #expect(marks.allSatisfy { !$0.isChanged && !$0.blocked && $0.shapeID == mortise.id && $0.walls.count == 2 })
        #expect(Set(marks.compactMap { $0.tip.map(key) }) == spikeTips(tp))
        // Each corner is in the shape's own coordinates (the rectangle is centred on its position).
        #expect(marks.contains { $0.localPoint.distance(to: Vec2(-30, -10)) < 1e-6 })

        // Pockets record their wall corners too, and take choices.
        let pocket = try run([mortise], CutFixture.pocket([mortise], relief: tee))
        let pmarks = try #require(pocket.reliefCorners)
        #expect(pmarks.count == 4)
        let skipped = try run([mortise], CutFixture.pocket([mortise], relief: tee.setting(.asCut, for: pmarks[0])))
        #expect(CutFixture.reversals(pocket) - CutFixture.reversals(skipped) == 2, "one corner fewer on each of two levels")

        // No reliefs, no records.
        let plain = try mortiseCut(CornerReliefSettings())
        #expect(plain.reliefCorners?.count == 4)
        let none = try run([mortise], CutFixture.profile([mortise], side: .inside))
        #expect(none.reliefCorners == nil)
    }

    @Test func settingAChoiceAddsReplacesAndRemovesIt() throws {
        let base = try mortiseCut(tee)
        let c = try corner(base, at: corners[0].v)
        guard case let .tBone(k) = c.relief else { Issue.record("expected a T-bone"); return }
        let flipped = tee.setting(.tBone(wall: 1 - k), for: c)
        #expect(flipped.overrides?.count == 1)
        if case let .tBone(angle) = flipped.overrides?.first?.choice {
            #expect(abs(angle - c.walls[1 - k].localAngle) < 1e-9)
        } else {
            Issue.record("expected a T-bone choice")
        }
        let dog = flipped.setting(.dogbone, for: c)
        #expect(dog.overrides?.count == 1 && dog.overrides?.first?.choice == .dogbone)
        #expect(dog.setting(c.standard, for: c).overrides == nil, "choosing the toolpath's own relief removes the choice")
        #expect(flipped.setting(nil, for: c).overrides == nil)

        // Clicking steps through dogbone, T-bone into each wall and none, then back.
        var stepped = c
        var seen: [ReliefCorner.Relief] = []
        for _ in 0..<4 {
            stepped.relief = stepped.nextRelief
            seen.append(stepped.relief)
        }
        #expect(stepped.relief == c.relief)
        #expect(Set(seen) == [.dogbone, .tBone(wall: 0), .tBone(wall: 1), .asCut])
    }

    @Test func choicesRoundTripAndAreOnlyWrittenWhenUsed() throws {
        let relief = CornerReliefSettings(style: .tBone, overrides: [
            CornerOverride(shapeID: mortise.id, point: Vec2(-30, -10), choice: .tBone(wallAngle: 90)),
            CornerOverride(shapeID: mortise.id, point: Vec2(30, 10), choice: .asCut),
        ])
        let p = Fixture.project(shapes: [mortise], ops: [CutFixture.profile([mortise], side: .inside, relief: relief),
                                                         CutFixture.pocket([mortise], relief: relief)])
        let back = try Project.decode(try p.encoded())
        #expect(back.operations == p.operations)
        let plain = String(decoding: try JSONEncoder().encode(CornerReliefSettings()), as: UTF8.self)
        #expect(!plain.contains("overrides"))
    }
}
