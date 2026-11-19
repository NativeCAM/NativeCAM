import Foundation
import Testing
@testable import CAMCore

struct CornerReliefTests {
    /// A 60 × 20 mortise: x 70…130, y 65…85.
    let mortise = Fixture.rect(60, 20, at: Vec2(100, 75))
    /// Its corners with the unit bisector pointing into the mortise.
    let corners: [(v: Vec2, u: Vec2)] = [(Vec2(70, 65), Vec2(1, 1)), (Vec2(130, 65), Vec2(-1, 1)),
                                         (Vec2(130, 85), Vec2(-1, -1)), (Vec2(70, 85), Vec2(1, -1))].map { ($0.0, $0.1.normalized) }
    let r = CutFixture.r

    func toolpath(_ shapes: [DesignShape], _ op: CAMOperation) throws -> Toolpath {
        let (_, job) = CutFixture.job(shapes, [op])
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        return try #require(job.toolpaths.first)
    }

    /// Spike tips in a toolpath (the point a feed reverses at), rounded to a micron.
    func tips(_ tp: Toolpath) -> Set<String> {
        var out = Set<String>()
        var prevDir: Vec2?
        var pos = tp.start
        for m in tp.motions {
            defer { pos = m.end }
            guard m.kind == .feed else { prevDir = nil; continue }
            let d = m.end.xy - pos.xy
            guard d.length > 1e-6 else { continue }
            if let p = prevDir, p.dot(d.normalized) < -0.99 {
                out.insert("\(Int((pos.x * 1000).rounded())),\(Int((pos.y * 1000).rounded()))")
            }
            prevDir = d.normalized
        }
        return out
    }

    @Test func dogbonesReachEveryCornerOfAMortiseAndCutNoMore() throws {
        let tp = try toolpath([mortise], CutFixture.profile([mortise], side: .inside, relief: CornerReliefSettings()))
        #expect(CutFixture.reversals(tp) == 4 * 2, "four corners, two passes")
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        for (v, u) in corners {
            #expect(CutFixture.height(grid, v + u * 0.25) <= -6 + 0.01, "corner \(v) not cut")
        }
        let centres = corners.map { $0.v + $0.u * r }
        let overcut = r * (1 - sin(Double.pi / 4))
        let bad = CutFixture.cells(grid).filter { p, h in
            let beyond = max(abs(p.x - 100) - 30, abs(p.y - 75) - 10)
            guard h < -1e-6, beyond > 0.13 else { return false }
            return !(centres.contains { $0.distance(to: p) <= r + 0.25 } && beyond <= overcut + 0.25)
        }
        #expect(bad.isEmpty, "\(bad.count) cells cut past the walls away from the dogbones")

        // Without reliefs the bit can't reach the corners.
        let plain = try toolpath([mortise], CutFixture.profile([mortise], side: .inside))
        let g2 = Fixture.simulate([plain], stock: Fixture.stock, cell: 0.25)
        #expect(corners.allSatisfy { CutFixture.height(g2, $0.v + $0.u * 0.25) > -1e-6 })
    }

    @Test(arguments: [(TBoneSide.longer, true), (.shorter, false), (.alongX, true), (.alongY, false)])
    func tBonesNotchTheChosenWall(side: TBoneSide, longWalls: Bool) throws {
        let relief = CornerReliefSettings(style: .tBone, tBoneSide: side)
        let tp = try toolpath([mortise], CutFixture.profile([mortise], side: .inside, relief: relief))
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        for (v, u) in corners {
            let sx = u.x > 0 ? 1.0 : -1.0, sy = u.y > 0 ? 1.0 : -1.0
            // Just past the long (horizontal) wall, a bit-radius along it from the corner; and the same past the short wall.
            let pastLong = v + Vec2(sx * r, -sy * r * 0.5)
            let pastShort = v + Vec2(-sx * r * 0.5, sy * r)
            let longCut = CutFixture.height(grid, pastLong) <= -6 + 0.01
            let shortCut = CutFixture.height(grid, pastShort) <= -6 + 0.01
            #expect(longCut == longWalls && shortCut == !longWalls, "\(side) at \(v): long \(longCut), short \(shortCut)")
        }
    }

    @Test(arguments: [CornerReliefSettings(), CornerReliefSettings(style: .tBone, tBoneSide: .longer),
                      CornerReliefSettings(style: .tBone, tBoneSide: .shorter), CornerReliefSettings(style: .tBone, tBoneSide: .alongY)])
    func climbAndConventionalCutTheSameReliefs(relief: CornerReliefSettings) throws {
        let climb = try toolpath([mortise], CutFixture.profile([mortise], side: .inside, direction: .climb, relief: relief))
        let conventional = try toolpath([mortise], CutFixture.profile([mortise], side: .inside, direction: .conventional, relief: relief))
        #expect(tips(climb).count == 4)
        #expect(tips(climb) == tips(conventional))
        for strategy in [PocketStrategy.offset, .raster] {
            let a = try toolpath([mortise], CutFixture.pocket([mortise], strategy: strategy, direction: .climb, relief: relief))
            let b = try toolpath([mortise], CutFixture.pocket([mortise], strategy: strategy, direction: .conventional, relief: relief))
            #expect(tips(a).isSuperset(of: tips(climb)) && tips(b).isSuperset(of: tips(climb)), "\(strategy)")
        }
    }

    @Test func plannedTipsMatchTheGeometry() {
        let loop = Polyline([Vec2(70 + r, 65 + r), Vec2(130 - r, 65 + r), Vec2(130 - r, 85 - r), Vec2(70 + r, 85 - r)], closed: true)
        let design = CornerRelief.Design(mortise.polylines())
        let dog = CornerRelief.plan(loop, wasteOnLeft: true, design: design, offset: r, settings: CornerReliefSettings())
        #expect(dog.reliefs.count == 4)
        for (v, u) in corners {
            #expect(dog.reliefs.contains { $0.tip.isApprox(v + u * r, tolerance: 1e-6) }, "dogbone at \(v)")
        }
        // T-bones on the longer side: the bit centre sits on the long wall's line, a radius in from the short wall.
        let tee = CornerRelief.plan(loop, wasteOnLeft: true, design: design, offset: r,
                                    settings: CornerReliefSettings(style: .tBone, tBoneSide: .longer))
        for (v, u) in corners {
            let expected = v + Vec2(u.x > 0 ? r : -r, 0)
            #expect(tee.reliefs.contains { $0.tip.isApprox(expected, tolerance: 1e-6) }, "T-bone at \(v)")
        }
        // A tiny chamfer from an imported drawing still counts as one corner.
        let chamfered = DesignShape(kind: .paths([Polyline([Vec2(70.03, 65), Vec2(130, 65), Vec2(130, 85), Vec2(70, 85), Vec2(70, 65.03)],
                                                           closed: true)]), position: .zero)
        let region = Region.build(from: chamfered.polylines())[0]
        let offsetLoop = region.offset(by: -r)[0].outer
        let plan = CornerRelief.plan(offsetLoop, wasteOnLeft: true, design: CornerRelief.Design(region.loops), offset: r,
                                     settings: CornerReliefSettings())
        #expect(plan.reliefs.count == 4)
    }

    @Test func outsideProfilesRelieveOnlyThePartsInsideCorners() throws {
        let l = DesignShape(kind: .paths([Polyline([Vec2(60, 40), Vec2(140, 40), Vec2(140, 70), Vec2(100, 70), Vec2(100, 110), Vec2(60, 110)],
                                                   closed: true)]), position: .zero)
        let tp = try toolpath([l], CutFixture.profile([l], relief: CornerReliefSettings()))
        #expect(CutFixture.reversals(tp) == 1 * 2)
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        #expect(CutFixture.height(grid, Vec2(100, 70) + Vec2(1, 1).normalized * 0.25) <= -6 + 0.01)

        // A finger comb: every inside corner between the fingers.
        var pts = [Vec2(40, 40), Vec2(160, 40), Vec2(160, 80)]
        for x in stride(from: 148.0, through: 52, by: -24) {
            pts += [Vec2(x, 80), Vec2(x, 60), Vec2(x - 12, 60), Vec2(x - 12, 80)]
        }
        pts.removeLast()   // the last gap is open to the left edge: (52, 60) is an inside corner, (40, 60) isn't
        let comb = DesignShape(kind: .paths([Polyline(pts, closed: true)]), position: .zero)
        let combPath = try toolpath([comb], CutFixture.profile([comb], relief: CornerReliefSettings()))
        #expect(CutFixture.reversals(combPath) == 9 * 2, "nine inside corners, two passes")
    }

    @Test(arguments: [PocketStrategy.offset, .raster])
    func pocketsRelieveWallAndIslandCorners(strategy: PocketStrategy) throws {
        let pocket = Fixture.rect(100, 80, at: Vec2(100, 75))
        let island = DesignShape(kind: .paths([Polyline([Vec2(80, 55), Vec2(120, 55), Vec2(120, 70), Vec2(95, 70), Vec2(95, 95), Vec2(80, 95)],
                                                        closed: true)]), position: .zero)
        let relieved = try toolpath([pocket, island], CutFixture.pocket([pocket, island], strategy: strategy, relief: CornerReliefSettings()))
        let plain = try toolpath([pocket, island], CutFixture.pocket([pocket, island], strategy: strategy))
        #expect(CutFixture.reversals(relieved) - CutFixture.reversals(plain) == 5 * 2, "four wall corners and the island's inside corner")
        let grid = Fixture.simulate([relieved], stock: Fixture.stock, cell: 0.25)
        let islandCorner = Vec2(95, 70)
        #expect(CutFixture.height(grid, islandCorner + Vec2(1, 1).normalized * 0.25) <= -6 + 0.01)
        for c in [Vec2(50, 35), Vec2(150, 35), Vec2(150, 115), Vec2(50, 115)] {
            let u = (Vec2(100, 75) - c).normalized
            #expect(CutFixture.height(grid, c + u * 0.25) <= -6 + 0.01, "pocket corner \(c)")
        }
        // Nothing else of the island, or past the walls, is cut beyond a dogbone's reach.
        let islandLoop = island.polylines()[0]
        let reach = r * (1 - sin(Double.pi / 4)) + 0.3
        let bad = CutFixture.cells(grid).filter { p, h in
            guard h < -1e-6 else { return false }
            if islandLoop.contains(p) {
                return islandLoop.closestPoint(to: p).distance > 0.13 && p.distance(to: islandCorner) > r * 1.5
            }
            let beyond = max(abs(p.x - 100) - 50, abs(p.y - 75) - 40)
            return beyond > reach
        }
        #expect(bad.isEmpty, "\(bad.count) cells cut where no relief should reach")
    }

    @Test func cornerAngleLimitLeavesFlatterCornersAlone() throws {
        let hex = DesignShape(kind: .polygon(sides: 6, radius: 20), position: Vec2(100, 75))
        let plain = try toolpath([hex], CutFixture.pocket([hex]))
        let at120 = try toolpath([hex], CutFixture.pocket([hex], relief: CornerReliefSettings(maxCornerAngle: 120)))
        let at110 = try toolpath([hex], CutFixture.pocket([hex], relief: CornerReliefSettings(maxCornerAngle: 110)))
        #expect(CutFixture.reversals(at120) - CutFixture.reversals(plain) == 6 * 2)
        #expect(at110.motions == plain.motions)
        let twelve = DesignShape(kind: .polygon(sides: 12, radius: 20), position: Vec2(100, 75))
        let p12 = try toolpath([twelve], CutFixture.pocket([twelve]))
        let r12 = try toolpath([twelve], CutFixture.pocket([twelve], relief: CornerReliefSettings()))
        #expect(r12.motions == p12.motions)
    }

    @Test func acuteCornersAreRelievedWithoutCuttingTheFarWalls() throws {
        let apex = Vec2(100, 40 + 20 / tan(15 * Double.pi / 180))
        let outline = Polyline([Vec2(80, 40), Vec2(120, 40), apex], closed: true)
        let triangle = DesignShape(kind: .paths([outline]), position: .zero)
        let tp = try toolpath([triangle], CutFixture.profile([triangle], side: .inside, relief: CornerReliefSettings()))
        #expect(CutFixture.reversals(tp) == 3 * 2)
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        #expect(CutFixture.height(grid, apex - Vec2(0, 0.3)) <= -6 + 0.01, "the 30° tip is cut")
        let allowed = r * (1 - sin(15 * Double.pi / 180)) + 0.3
        let bad = CutFixture.cells(grid).filter { p, h in
            h < -1e-6 && !outline.contains(p) && outline.closestPoint(to: p).distance > allowed
        }
        #expect(bad.isEmpty, "\(bad.count) cells cut too far past the walls")
    }

    @Test func roundedCornersSmallerThanTheBitAreRelievedLargerOnesAreNot() throws {
        let small = Fixture.rect(60, 20, at: Vec2(100, 75))
        var smallRounded = small
        smallRounded.kind = .rectangle(width: 60, height: 20, cornerRadius: 1)
        let tp = try toolpath([smallRounded], CutFixture.profile([smallRounded], side: .inside, relief: CornerReliefSettings()))
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.25)
        let u = Vec2(1, 1).normalized
        let deepest = Vec2(71, 66) - u * 1
        #expect(CutFixture.height(grid, deepest + u * 0.2) <= -6 + 0.01)
        let plain = try toolpath([smallRounded], CutFixture.profile([smallRounded], side: .inside))
        #expect(CutFixture.height(Fixture.simulate([plain], stock: Fixture.stock, cell: 0.25), deepest + u * 0.2) > -1e-6)

        var big = small
        big.kind = .rectangle(width: 60, height: 20, cornerRadius: 4)
        let a = try toolpath([big], CutFixture.profile([big], side: .inside, relief: CornerReliefSettings()))
        let b = try toolpath([big], CutFixture.profile([big], side: .inside))
        #expect(a.motions == b.motions)
    }

    @Test func noReliefWhereAnIslandPinchesTheWall() throws {
        let pocket = Fixture.rect(80, 50, at: Vec2(100, 75))
        let island = Fixture.rect(20, 20, at: Vec2(74, 75))   // 4 mm from the left wall: the bit can't pass
        let relieved = try toolpath([pocket, island], CutFixture.pocket([pocket, island], relief: CornerReliefSettings()))
        let plain = try toolpath([pocket, island], CutFixture.pocket([pocket, island]))
        #expect(CutFixture.reversals(relieved) - CutFixture.reversals(plain) == 4 * 2, "only the four wall corners")
        let grid = Fixture.simulate([relieved], stock: Fixture.stock, cell: 0.25)
        let gouged = CutFixture.cells(grid).filter { p, h in h < -1e-6 && abs(p.x - 74) < 10 - 0.13 && abs(p.y - 75) < 10 - 0.13 }
        #expect(gouged.isEmpty, "\(gouged.count) cells of the island were cut")
    }

    @Test func allowanceLeavesMaterialAtTheCorner() throws {
        let tp = try toolpath([mortise], CutFixture.profile([mortise], side: .inside, allowance: 0.5, relief: CornerReliefSettings()))
        let grid = Fixture.simulate([tp], stock: Fixture.stock, cell: 0.15)
        for (v, u) in corners {
            #expect(CutFixture.height(grid, v + u * 0.25) > -1e-6, "allowance left at \(v)")
            #expect(CutFixture.height(grid, v + u * 0.8) <= -6 + 0.01, "relieved up to the allowance at \(v)")
        }
    }

    @Test func entriesNeverLandOnAReliefTip() throws {
        let centres = corners.map { $0.v + $0.u * r }
        for leads in [nil, CutFixture.arc, CutFixture.line] {
            let tp = try toolpath([mortise], CutFixture.profile([mortise], side: .inside, leads: leads, relief: CornerReliefSettings()))
            #expect(!tp.warnings.contains { $0.contains("Leads") }, "\(tp.warnings)")
            for (_, e) in CutFixture.plunges(tp) {
                #expect(centres.allSatisfy { $0.distance(to: e.xy) > 1 }, "plunge at a relief tip: \(e)")
            }
            #expect(CutFixture.reversals(tp) == 4 * 2)
        }
    }
}
