import Foundation
import Testing
@testable import CAMCore

/// Chamfer options (#90): the V-bit's overcut, which leaves a flat at the bevel's foot, and round-nose chamfers cut with
/// a form bit at a set width. Also the edge profile's finishing pass sized by its cross-section (#118), whose placement
/// code the round-nose chamfer shares.
struct ChamferOptionsTests {
    static var vBit90: Tool { Fixture.vBit90 }
    static var engraving: Tool { ToolLibrary.starter.tool(number: 9)! }
    /// A 1/4" roundover on a 1/2" pilot.
    static let roundover = EdgeProfileTests.form(.roundover, radius: 0.25.inch, number: 5, id: 950)

    static func chamfer(_ params: ChamferParams, _ shapes: [DesignShape], tool: Tool = vBit90) -> CAMOperation {
        CAMOperation(name: "Chamfer", kind: .chamfer(params), shapeIDs: shapes.map(\.id), tool: tool)
    }

    static func job(_ shapes: [DesignShape], _ ops: [CAMOperation]) -> JobResult {
        CAMEngine.generate(Fixture.project(shapes: shapes, ops: ops))
    }

    static func height(_ grid: HeightGrid, _ x: Double, _ y: Double) -> Double {
        Double(grid.height(at: Vec2(x, y)) ?? .nan)
    }

    // MARK: Overcut

    /// A 90° V-bit chamfer 1/8" wide with a 0.02" overcut, round the top of a raised square: the bevel is the same face
    /// as without the overcut, and its foot is a 0.02" flat at the bevel's depth where the V-groove's bottom was.
    @Test func theOvercutCutsAFlatAndKeepsTheBevel() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let w = 0.125.inch, o = 0.02.inch
        func grid(_ overcut: Double?) throws -> HeightGrid {
            let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .outside, edge: .top, width: w, overcut: overcut), [shape])])
            #expect(!job.hasErrors)
            let tp = try #require(job.toolpaths.first)
            #expect(tp.warnings.isEmpty, "\(tp.warnings)")
            return Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.05)
        }
        let cut = try grid(o)
        let plain = try grid(nil)
        // Mid-edge, at x = 120: the bevel falls 1 mm per mm out to its width, with the overcut as without it.
        var worst = 0.0
        for delta in stride(from: 0.4, through: w - 0.4, by: 0.4) {
            let h = Self.height(cut, 120 + delta, 75)
            worst = max(worst, abs(h + delta), abs(h - Self.height(plain, 120 + delta, 75)))
        }
        #expect(worst < 0.1, "bevel off by \(worst) mm")
        #expect(Self.height(cut, 119.8, 75) == 0)
        // The flat: the bevel's depth all across the overcut.
        var flat = 0.0
        for delta in stride(from: w + 0.1, through: w + o - 0.1, by: 0.05) {
            flat = max(flat, abs(Self.height(cut, 120 + delta, 75) + w))
        }
        // Within the ridges the laps leave between them (V-carve flat clearing's 0.1 mm) and a cell of the simulation.
        #expect(flat < VCarveParams.flatClearingRidge + 0.05, "flat off by \(flat) mm")
        // Without the overcut the groove's far face is already rising there.
        let mid = w + o / 2
        let rising = Self.height(plain, 120 + mid, 75)
        #expect(rising > -w + 0.15, "\(rising)")
        // Past the flat the cone's far face rises from it, the overcut further out.
        let far = Self.height(cut, 120 + w + o + 1, 75)
        #expect(abs(far + w - 1) < 0.1, "\(far)")
    }

    /// No overcut (nil or 0) posts the same bytes, saved at format 8; a V-bit's flat is the overcut plus its tip.
    @Test func noOvercutPostsAsBeforeAndTheFlatIsTheOvercutPlusTheTip() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        func project(_ overcut: Double?) -> Project {
            Fixture.project(shapes: [shape], ops: [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 3, overcut: overcut), [shape])])
        }
        let none = GoldenPostTests.post(project(nil)), zero = GoldenPostTests.post(project(0))
        #expect(none == zero)
        #expect(project(0).formatVersion == 8)
        #expect(project(1).formatVersion == 19)
        #expect(GoldenPostTests.post(project(1)) != none)
        let p = ChamferParams(width: 2, overcut: 0.5)
        #expect(abs(p.flatWidth(with: Self.vBit90) - 0.5) < 1e-9)
        #expect(abs(p.flatWidth(with: Self.engraving) - (0.5 + Self.engraving.tipDiameter)) < 1e-9)
        #expect(ChamferParams(width: 2).flatWidth(with: Self.vBit90) == 0)
        // A bottom-edge bevel on both sides has no foot to run past.
        #expect(ChamferParams(side: .both, edge: .bottom, overcut: 0.5).overcut(with: Self.vBit90) == 0)
    }

    /// A bottom-edge chamfer's overcut runs on the waste side of the vector: its second lap is the overcut further out,
    /// at the bevel's depth, and the bevel rising into the part is unchanged.
    @Test func aBottomEdgeOvercutRunsIntoTheWaste() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 3, overcut: 1), [shape])])
        let tp = try #require(job.toolpaths.first)
        let right = Fixture.pointsAt(z: -3, tp).map(\.x)
        // The bevel's lap on the vector, the overcut's out to 1 mm past it in the waste.
        #expect(abs((right.max() ?? 0) - 121) < 0.01)
        #expect(right.contains { abs($0 - 120) < 0.01 })
        let g = Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.1)
        #expect(abs(Self.height(g, 118.5, 75) + 1.5) < 0.15)
        #expect(abs(Self.height(g, 120.5, 75) + 3) < 0.15)
    }

    /// Two squares 8 mm apart with a 3 mm top-edge bevel: a 0.5 mm overcut still fits between them (each flat ends
    /// 3.5 mm out), a 1.5 mm one runs into the other square's flat, and Checks says so.
    @Test func checksWarnWhenTheOvercutReachesTheNextShape() throws {
        let a = Fixture.rect(30, 30, at: Vec2(60, 75)), b = Fixture.rect(30, 30, at: Vec2(98, 75))
        func warnings(_ o: Double) throws -> [String] {
            let job = Self.job([a, b], [Self.chamfer(ChamferParams(side: .outside, edge: .top, width: 3, overcut: o), [a, b])])
            let tp = try #require(job.toolpaths.first)
            #expect(!tp.isEmpty)
            return job.issues.filter { $0.severity == .warning }.map(\.message)
        }
        #expect(try !warnings(0.5).contains { $0.contains("overcut") })
        #expect(try warnings(1.5).contains { $0.contains("The overcut reaches the next shape") })
        // A narrow strip's own other side counts too: 8 mm wide, bevelled inside.
        let strip = Fixture.rect(60, 8, at: Vec2(100, 75))
        let job = Self.job([strip], [Self.chamfer(ChamferParams(side: .inside, edge: .top, width: 3, overcut: 1.5), [strip])])
        #expect(job.issues.contains { $0.message.contains("The overcut reaches the next shape") })
    }

    @Test func aBothSidesBottomEdgeChamferIgnoresTheOvercut() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let with = Self.job([shape], [Self.chamfer(ChamferParams(side: .both, edge: .bottom, width: 2, overcut: 1), [shape])])
        let without = Self.job([shape], [Self.chamfer(ChamferParams(side: .both, edge: .bottom, width: 2), [shape])])
        let tp = try #require(with.toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("The overcut is ignored") })
        #expect(tp.motions == without.toolpaths.first?.motions)
    }

    // MARK: Overcut laps (#121)

    /// The issue's sign: a 9 × 5" board chamfered 1/4" wide on its bottom edge, inside, with the starter 90° V-bit (1/8"
    /// stepdown) and a 0.04" overcut. The bevel takes its two passes; each of the 6 laps after it shaves a 0.007" strip
    /// and runs once, at full depth, so the chamfer takes about the plain one's time plus one pass a lap (it took 7×).
    @Test func overcutLapsAfterTheBevelRunAtFullDepth() throws {
        let stock = Stock(width: 10.inch, height: 6.inch, thickness: 0.75.inch, clearanceHeight: 10, plungeHeight: 2)
        let shape = Fixture.rect(9.inch, 5.inch, at: Vec2(5.inch, 3.inch))
        let w = 0.25.inch
        func run(_ overcut: Double?) throws -> (tp: Toolpath, seconds: Double) {
            let op = Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: w, overcut: overcut), [shape])
            let job = CAMEngine.generate(Fixture.project(shapes: [shape], ops: [op], stock: stock))
            let tp = try #require(job.toolpaths.first)
            #expect(tp.warnings.isEmpty, "\(tp.warnings)")
            return (tp, try #require(job.estimatedSeconds(toolpath: op.id)))
        }
        let plain = try run(nil), cut = try run(0.04.inch)
        let d = w / Self.vBit90.halfAngleTangent
        // The bevel's first pass, half way down, is the only one there: no lap is stepped.
        let shallow = Fixture.pointsAt(z: -d / 2, cut.tp)
        let plainShallow = Fixture.pointsAt(z: -d / 2, plain.tp)
        #expect(!shallow.isEmpty)
        #expect(shallow.count == plainShallow.count)
        // The laps at full depth, out to the overcut past the vector on the right edge.
        let deep = Fixture.pointsAt(z: -d, cut.tp).map(\.x)
        #expect(abs((deep.max() ?? 0) - (9.5.inch + 0.04.inch)) < 0.01)
        let bevel = ChamferGenerator.Bevel(regions: [], side: .inside, edge: .bottom, width: w, startDepth: 0, passDepth: nil,
                                           sharpCorners: true, direction: .climb, overcut: 0.04.inch)
        let laps = try #require(ChamferGenerator.lapSpacing(bevel, tool: Self.vBit90))
        #expect(laps.count == 6)
        // The plain chamfer's two passes, plus one pass each for the 6 laps (a little longer than the bevel's, further
        // out), and the moves between them.
        let perPass = plain.seconds / 2
        let expected = plain.seconds + 6 * perPass
        #expect(cut.seconds < 1.1 * expected, "\(cut.seconds) s vs \(expected) s")
        #expect(cut.seconds > 0.9 * expected, "\(cut.seconds) s vs \(expected) s")
    }

    /// The same chamfer on a square: with its laps at full depth the bevel still rises 1 mm per mm from the vector into
    /// the part as without the overcut, and the foot is flat at the bevel's depth all across the overcut.
    @Test func fullDepthLapsKeepTheBevelAndTheFlat() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let w = 0.25.inch, o = 0.04.inch
        func grid(_ overcut: Double?) throws -> HeightGrid {
            let op = Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: w, overcut: overcut), [shape])
            let job = Self.job([shape], [op])
            #expect(!job.hasErrors)
            return Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.05)
        }
        let cut = try grid(o), plain = try grid(nil)
        // Mid-edge, at x = 120: inside the vector the bevel rises 1 mm per mm, as without the overcut.
        var worst = 0.0
        for delta in stride(from: 0.4, through: w - 0.4, by: 0.4) {
            let h = Self.height(cut, 120 - delta, 75)
            let want = -w + delta
            worst = max(worst, abs(h - want), abs(h - Self.height(plain, 120 - delta, 75)))
        }
        #expect(worst < 0.1, "bevel off by \(worst) mm")
        #expect(Self.height(cut, 120 - w - 0.2, 75) == 0)
        // The flat, in the waste: the bevel's depth out to the overcut.
        var flat = 0.0
        for delta in stride(from: 0.1, through: o - 0.1, by: 0.05) {
            flat = max(flat, abs(Self.height(cut, 120 + delta, 75) + w))
        }
        #expect(flat < VCarveParams.flatClearingRidge + 0.05, "flat off by \(flat) mm")
        // Past it the last lap's cone rises.
        let far = Self.height(cut, 120 + o + 1, 75)
        #expect(abs(far + w - 1) < 0.1, "\(far)")
    }

    /// Laps are stepped only as far as their strip needs: with a 0.02" stepdown the bevel 1/4" deep takes 13 passes,
    /// and each lap's 0.007" strip, taken in 5, stays within the V its first pass cuts. Each round of laps is cut after
    /// the one before it, so every lap only ever shaves the strip.
    @Test func lapsAreSteppedOnlyAsFarAsTheirStripNeeds() throws {
        var tool = Self.vBit90
        tool.cutting.stepdown = 0.02.inch
        let w = 0.25.inch, o = 0.04.inch
        let d = w / tool.halfAngleTangent
        let bevel = ChamferGenerator.Bevel(regions: [], side: .outside, edge: .top, width: w, startDepth: 0, passDepth: nil,
                                           sharpCorners: true, direction: .climb, overcut: o)
        let levels = DepthSettings(startDepth: 0, cutDepth: d).passLevels(toolStepdown: tool.cutting.stepdown)
        #expect(levels.count == 13)
        let laps = ChamferGenerator.lapLevels(bevel, tool: tool, bevelLevels: levels)
        #expect(laps.count == 5)
        #expect(abs((laps.last ?? 0) + d) < 1e-9)
        let spacing = try #require(ChamferGenerator.lapSpacing(bevel, tool: tool)).spacing
        let p = -levels[0]
        let firstPass = p * p * tool.halfAngleTangent
        let slice = spacing * d / Double(laps.count)
        #expect(slice <= firstPass + 1e-9, "\(slice) vs \(firstPass)")
        // No overcut, or a bevel in one pass: the bevel's own levels.
        var none = bevel
        none.overcut = 0
        #expect(ChamferGenerator.lapLevels(none, tool: tool, bevelLevels: levels) == levels)
        #expect(ChamferGenerator.lapLevels(bevel, tool: tool, bevelLevels: [-d]) == [-d])
        // Cut in rounds out from the bevel: each path between rapids reaches no less far out than the one before.
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let op = Self.chamfer(ChamferParams(side: .outside, edge: .top, width: w, overcut: o), [shape], tool: tool)
        let tp = try #require(Self.job([shape], [op]).toolpaths.first)
        var reach: [Double] = []
        var current = -Double.infinity
        for m in tp.motions {
            if m.kind == .rapid {
                if current > -.infinity { reach.append(current) }
                current = -.infinity
            } else {
                current = max(current, m.end.x)
            }
        }
        if current > -.infinity { reach.append(current) }
        #expect(reach.count == 7, "\(reach)")
        let outward = zip(reach, reach.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }
        #expect(outward, "\(reach)")
        let last = reach.last ?? 0
        #expect(abs(last - (120 + w + o)) < 0.01)
    }

    // MARK: Round-nose chamfers

    /// A 1/4" roundover at 3/16" wide rounds a part's top edge before its cut-out (bottom edge on the vector, inside):
    /// its tip runs deep enough for the profile to meet the top 3/16" in from the outline, its pilot on the outline.
    @Test func aRoundoverChamferMeetsTheTopAtItsWidth() throws {
        let tool = Self.roundover
        let w = 0.1875.inch, r = 0.25.inch
        let depth = try #require(EdgeProfileParams.formDepth(reaching: w, tool: tool))
        // On the roundover's arc: r(h) − pilot = R − √(R² − h²) = w.
        let expected = (r * r - (r - w) * (r - w)).squareRoot()
        // Within the cutting edge's polyline (0.002 mm of the arc), which a steep stretch magnifies in height.
        #expect(abs(depth - expected) < 0.01, "\(depth) vs \(expected)")
        let shape = Fixture.rect(60, 40, at: Vec2(100, 75))
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: w), [shape], tool: tool)])
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        let ext = try #require(tp.cuttingExtents)
        #expect(abs(ext.min.z + depth) < 1e-6)
        // The pilot on the outline: the axis a pilot's radius outside it, x = 130 + 1/4".
        let right = Fixture.pointsAt(z: -depth, tp).map(\.x).max() ?? 0
        #expect(abs(right - (130 + 0.25.inch)) < 0.01)
        // The finished edge follows the profile and meets the top at the width.
        let g = Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.1)
        var worst = 0.0
        for u in stride(from: 0.5, through: w - 0.5, by: 0.5) {
            let want = EdgeProfileTests.finished(u, tool: tool, depth: depth)
            worst = max(worst, abs(Self.height(g, 130 - u, 75) - want))
        }
        #expect(worst < 0.15, "profile off by \(worst) mm")
        #expect(Self.height(g, 130 - w - 0.3, 75) == 0)
        #expect(Self.height(g, 130 - w + 0.5, 75) < -0.01)
    }

    /// A top-edge round-nose chamfer outside the shape: the vector is where the profile meets the top, and its foot (the
    /// pilot's line) is the width outside it.
    @Test func aTopEdgeRoundNoseChamferPutsTheFootTheWidthOut() throws {
        let shape = Fixture.rect(60, 40, at: Vec2(100, 75))
        let w = 0.125.inch
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .outside, edge: .top, width: w), [shape], tool: Self.roundover)])
        let tp = try #require(job.toolpaths.first)
        let depth = try #require(EdgeProfileParams.formDepth(reaching: w, tool: Self.roundover))
        let right = Fixture.pointsAt(z: -depth, tp).map(\.x).max() ?? 0
        #expect(abs(right - (130 + w + 0.25.inch)) < 0.01)
        let g = Fixture.simulate(job.toolpaths, stock: Fixture.stock, cell: 0.1)
        #expect(Self.height(g, 129.7, 75) == 0)
        #expect(Self.height(g, 130 + 0.5, 75) < -0.01)
    }

    @Test func aWidthBeyondTheProfileIsRefused() throws {
        let shape = Fixture.rect(60, 40, at: Vec2(100, 75))
        #expect(EdgeProfileParams.formDepth(reaching: 0.3.inch, tool: Self.roundover) == nil)
        #expect(abs(EdgeProfileParams.profileReach(Self.roundover) - 0.25.inch) < 0.01)
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 0.3.inch), [shape], tool: Self.roundover)])
        let tp = try #require(job.toolpaths.first)
        #expect(tp.motions.isEmpty)
        #expect(tp.warnings.contains { $0.contains("needs more of the profile than the bit has") }, "\(tp.warnings)")
    }

    /// Dovetails, form bits that undercut and end mills are refused, each saying why; form bits that only widen going up
    /// are taken.
    @Test func chamfersRefuseDovetailsAndOtherBits() {
        let tail = Tool(number: 8, name: "1/2\" dovetail", shape: .dovetail, fluteDirection: .straight, diameter: 0.5.inch,
                        shankDiameter: 0.25.inch, fluteLength: 0.5.inch, includedAngle: 28, cutting: EdgeProfileTests.cutting)
        let kind = OperationKind.chamfer(ChamferParams())
        #expect(kind.refusal(for: tail)?.contains("a dovetail bit") == true)
        let narrowing = EdgeProfileTests.form(.custom, radius: 0, points: [Vec2(8, 0), Vec2(5, 6), Vec2(9, 10)])
        #expect(kind.refusal(for: narrowing)?.contains("wider low down") == true)
        #expect(kind.refusal(for: Self.roundover) == nil)
        #expect(kind.refusal(for: EdgeProfileTests.cove) == nil)
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let flat = Self.job([shape], [Self.chamfer(ChamferParams(), [shape], tool: Fixture.endMill)])
        #expect(flat.toolpaths.first?.warnings.contains { $0.contains("form bit") } == true)
    }

    /// A form bit can't rise on both sides of one vector.
    @Test func aBottomEdgeRoundNoseChamferOnBothSidesIsRefused() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .both, edge: .bottom, width: 3), [shape], tool: Self.roundover)])
        let tp = try #require(job.toolpaths.first)
        #expect(tp.motions.isEmpty)
        #expect(tp.warnings.contains { $0.contains("both sides of one vector") })
    }

    /// One pass, unless the router-bit chart's cross-section rule asks for more: a 1" roundover's whole profile on a
    /// 1/4" shank takes R²(1 − π/4) ≈ 0.215 in², more than three times the shank's 1/16 in².
    @Test func roundNosePassesFollowTheCrossSectionRule() throws {
        let small = EdgeProfilePlan.fewestPasses(tool: Self.roundover, depth: 0.25.inch, thickness: 0.75.inch)
        #expect(small.passes.count == 1)
        var big = EdgeProfileTests.form(.roundover, radius: 1.inch, number: 7, id: 951)
        big.shankDiameter = 0.25.inch
        let plan = EdgeProfilePlan.fewestPasses(tool: big, depth: 1.inch, thickness: 1.5.inch)
        #expect(plan.passes.count == 4)
        let shank = 0.25.inch * 0.25.inch
        #expect(plan.passes.allSatisfy { $0.crossSection <= shank + 1e-6 })
        #expect(plan.passes.last?.standoff == 0)
    }

    @Test func roundNoseChamfersAreFormat19() {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let p = Fixture.project(shapes: [shape], ops: [Self.chamfer(ChamferParams(width: 3), [shape], tool: Self.roundover)])
        #expect(p.formatVersion == 19)
        let plain = Fixture.project(shapes: [shape], ops: [Self.chamfer(ChamferParams(width: 3), [shape])])
        #expect(plain.formatVersion == 8)
    }

    // MARK: The edge profile's finishing pass (#118)

    /// On a 1/4" roundover the 0.02" finishing band ran the profile's whole depth at the edge, taking more than any of the
    /// three passes before it. The finish is now narrowed to at most a quarter of the heaviest pass, so it's the
    /// lightest cut, and the passes still take the whole profile.
    @Test func theFinishingPassHasTheSmallestCrossSection() throws {
        for (tool, passes) in [(Self.roundover, EdgeProfileParams.Passes.horizontal), (EdgeProfileTests.roundover, .horizontal),
                               (EdgeProfileTests.cove, .horizontal), (EdgeProfileTests.ogee, .horizontal), (Self.roundover, .vertical)] {
            let plan = EdgeProfileParams(passes: passes).plan(tool: tool, thickness: 0.75.inch)
            let finish = try #require(plan.passes.last)
            #expect(finish.isFinish, "\(tool.name)")
            let rough = plan.passes.dropLast().map(\.largestLap)
            let heaviest = rough.max() ?? 0
            #expect(finish.largestLap <= EdgeProfilePlan.finishShare * heaviest + 1e-6, "\(tool.name) \(passes): \(finish.largestLap) vs \(heaviest)")
            #expect(rough.allSatisfy { finish.crossSection < $0 }, "\(tool.name) \(passes)")
            #expect(finish.band <= EdgeProfileParams.defaultFinish + 1e-9)
            let total = plan.passes.reduce(0) { $0 + $1.crossSection }
            #expect(abs(total - plan.crossSection) < 1e-3 * max(1, plan.crossSection), "\(tool.name)")
        }
    }
}
