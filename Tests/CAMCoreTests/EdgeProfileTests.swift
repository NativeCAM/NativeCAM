import Foundation
import Testing
@testable import CAMCore

/// The Edge Profile toolpath (#84): a form bit's profile cut into the top edge of parts, in passes from the outside in.
struct EdgeProfileTests {
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "ED6E0000-0000-4000-8084-%012d", n))! }

    static let cutting = CuttingData(spindleRPM: 16000, feedRate: 120.inch, plungeRate: 30.inch, stepdown: 0.25.inch, stepoverFraction: 0.4)

    /// A form bit of `kind` on a 1/2" shank, its flutes a little taller than its profile.
    static func form(_ kind: FormProfile.Kind, radius: Double, upper: Double = 0, pilot: Double = 0.5.inch, number: Int = 5,
                     id n: Int = 900, points: [Vec2] = []) -> Tool {
        let f = FormProfile(kind: kind, radius: radius, upperRadius: upper, pilotDiameter: pilot, points: points)
        var t = Tool(id: id(n), number: number, name: "", shape: .form, fluteDirection: .straight, diameter: 1, shankDiameter: 0.5.inch,
                     fluteLength: f.profileHeight + 0.25.inch, cutting: cutting, form: f)
        t.fitDiameterToShape()
        t.name = "\(ChipLoad.size(t.diameter, .inch)) \(kind.label.lowercased())"
        return t
    }

    /// A 1/2" roundover: 1/2" radius on a 1/2" pilot, 1-1/2" across.
    static let roundover = form(.roundover, radius: 0.5.inch, number: 5, id: 901)
    /// A 3/8" cove on a 1/2" pilot.
    static let cove = form(.cove, radius: 0.375.inch, number: 6, id: 902)
    /// A Roman ogee: a 3/16" cove under a 3/16" roundover on a 1/2" pilot.
    static let ogee = form(.ogee, radius: 0.1875.inch, upper: 0.1875.inch, number: 7, id: 903)

    static var endMill: Tool {
        var t = Fixture.endMill
        t.id = id(904)
        return t
    }

    /// A 6 × 4" rectangle with 1/2" corner radii, in the middle of an 8 × 6 × 3/4" board.
    static func board(_ shapeID: UUID = EdgeProfileTests.id(1)) -> DesignShape {
        DesignShape(id: shapeID, name: "Board", kind: .rectangle(width: 6.inch, height: 4.inch, cornerRadius: 0.5.inch), position: Vec2(4.inch, 3.inch))
    }

    static let stock = Stock(width: 8.inch, height: 6.inch, thickness: 0.75.inch)

    static func project(_ name: String = "Edge profile", shapes: [DesignShape], ops: [CAMOperation], stock: Stock = stock,
                        arcs: Bool = false) -> Project {
        var machine = MachineProfile.avidPRO6060
        machine.outputArcs = arcs
        return Project(name: name, displayUnits: .inch, stock: stock, machine: machine, shapes: shapes, operations: ops)
    }

    static func edge(_ params: EdgeProfileParams = EdgeProfileParams(), tool: Tool = roundover, shapes: [UUID],
                     id opID: UUID = EdgeProfileTests.id(10), name: String = "Edge profile") -> CAMOperation {
        CAMOperation(id: opID, name: name, kind: .edgeProfile(params), shapeIDs: shapes, tool: tool)
    }

    /// An outside cut-out through the board, with tabs.
    static func cutOut(shapes: [UUID], id opID: UUID = EdgeProfileTests.id(11), tabs: Bool = true) -> CAMOperation {
        var p = ProfileParams(side: .outside, direction: .climb, depth: .through(stock.thickness), tabs: TabSettings(enabled: tabs),
                              entry: EntrySettings(kind: .ramp), leads: LeadSettings())
        p.tabs.thickness = 0.125.inch
        return CAMOperation(id: opID, name: "Cut out", kind: .profile(p), shapeIDs: shapes, tool: endMill)
    }

    /// Inward distance from the 6 × 4" board's outline (negative outside it), mm.
    static func inside(_ p: Vec2) -> Double {
        let half = Vec2(3.inch - 0.5.inch, 2.inch - 0.5.inch)
        let q = Vec2(abs(p.x - 4.inch) - half.x, abs(p.y - 3.inch) - half.y)
        let outside = Vec2(max(q.x, 0), max(q.y, 0)).length + min(max(q.x, q.y), 0) - 0.5.inch
        return -outside
    }

    /// The finished height the bit leaves `u` in from the edge, at its final position (design Z).
    static func finished(_ u: Double, tool: Tool, depth: Double, offset: Double = 0) -> Double {
        let c = tool.radius(atHeight: 0) + offset
        guard let h = tool.profileHeight(atRadius: c + u) else { return 0 }
        return min(0, -depth + h)
    }

    // MARK: The passes

    /// A full 1/2" roundover takes three passes of equal cross-section plus a light finish, from the outside in; together
    /// they take the whole profile, R²(1 − π/4).
    @Test func aFullRoundoverPlansThreeEqualPassesAndAFinish() throws {
        let tool = Self.roundover
        let plan = EdgeProfileParams().plan(tool: tool, thickness: 0.75.inch)
        let r = 0.5.inch
        #expect(abs(plan.depth - r) < 1e-9)
        #expect(abs(plan.reach - r) < 0.01)
        #expect(abs(plan.centreOffset - 0.25.inch) < 1e-9)
        #expect(plan.reveal == 0)
        #expect(abs(plan.crossSection - r * r * (1 - .pi / 4)) < 0.05)
        #expect(plan.passes.count == 4)
        #expect(plan.passes.last?.isFinish == true && plan.passes.last?.standoff == 0)
        let standoffs = plan.passes.map(\.standoff)
        #expect(zip(standoffs, standoffs.dropFirst()).allSatisfy { $0 > $1 })
        #expect(abs(standoffs[2] - EdgeProfileParams.defaultFinish) < 1e-9)
        let rough = plan.passes.prefix(3).map(\.crossSection)
        for a in rough { #expect(abs(a - rough[0]) < 0.02 * rough[0], "\(rough)") }
        let total = plan.passes.reduce(0) { $0 + $1.crossSection }
        #expect(abs(total - plan.crossSection) < 1e-6)
        // Each band is the step in from the pass before; together they're the profile's width.
        #expect(abs(plan.passes.reduce(0) { $0 + $1.band } - plan.reach) < 1e-9)
    }

    /// With a band width the passes step in evenly, as few as keep each step within it.
    @Test func aBandWidthStepsInEvenly() {
        let params = EdgeProfileParams(bandWidth: 0.2.inch)
        let plan = params.plan(tool: Self.roundover, thickness: 0.75.inch)
        let rough = plan.passes.filter { !$0.isFinish }
        #expect(rough.count == 3)
        for p in rough { #expect(abs(p.band - (plan.reach - EdgeProfileParams.defaultFinish) / 3) < 1e-9) }
    }

    /// Vertical passes step down at the finish's standoff, then the finish takes the rest at full depth.
    @Test func verticalPassesStepDownThenFinish() {
        let params = EdgeProfileParams(passes: .vertical, passDepth: 0.2.inch)
        let plan = params.plan(tool: Self.roundover, thickness: 0.75.inch)
        #expect(plan.passes.count == 2)
        let rough = plan.passes[0]
        #expect(rough.depths.count == 3)
        #expect(abs(rough.depths.last! - 0.5.inch) < 1e-9)
        #expect(abs(rough.standoff - EdgeProfileParams.defaultFinish) < 1e-9)
        let full = 0.5.inch
        #expect(plan.passes[1].isFinish)
        #expect(plan.passes[1].depths == [full])
        let total = plan.passes.reduce(0) { $0 + $1.crossSection }
        #expect(abs(total - plan.crossSection) < 1e-6)
    }

    /// Deeper than the profile leaves a step above it; an offset stands the bit off and cuts only part of the profile.
    @Test func depthAndOffsetSetHowMuchOfTheProfile() {
        let tool = Self.roundover
        let deeper = EdgeProfileParams(depth: 0.625.inch).plan(tool: tool, thickness: 0.75.inch)
        #expect(abs(deeper.reveal - 0.125.inch) < 1e-9)
        #expect(abs(deeper.reach - 0.5.inch) < 0.01)
        let partial = EdgeProfileParams(offset: 0.125.inch).plan(tool: tool, thickness: 0.75.inch)
        #expect(abs(partial.reach - 0.375.inch) < 0.01)
        #expect(partial.crossSection < EdgeProfileParams().plan(tool: tool, thickness: 0.75.inch).crossSection)
        let none = EdgeProfileParams(offset: 0.6.inch).plan(tool: tool, thickness: 0.75.inch)
        #expect(none.passes.isEmpty)
    }

    /// Each pass's feed comes from its own cross-section: a 1-1/2" cove on a 1/4" shank is held to about a third of the
    /// chart's feed in one pass, but its equal-share passes are under the shank's slot, so the chart's feed stands.
    @Test func eachPassIsReadAtItsOwnCrossSection() {
        var cove = Self.form(.cove, radius: 0.5.inch, pilot: 0.5.inch)
        cove.shankDiameter = 0.25.inch
        let plan = EdgeProfileParams().plan(tool: cove, thickness: 0.75.inch)
        let whole = ChipLoad.reading(cove, material: .hardwood, depth: plan.depth)
        let pass = ChipLoad.reading(cove, material: .hardwood, depth: plan.depth, crossSection: plan.largestLap)
        #expect(whole.crossSectionShare < 0.4)
        #expect(pass.crossSectionShare > 0.9)
        let one = ChipLoad.recommendation(for: cove, material: .hardwood, machine: .avidPRO6060, depth: plan.depth)
        let passes = ChipLoad.recommendation(for: cove, material: .hardwood, machine: .avidPRO6060, depth: plan.depth,
                                             crossSection: plan.largestLap)
        #expect(passes.feed > 2 * one.feed)
        // Checks reads the toolpath at its heaviest pass, so the cut that's right for it isn't called too thick.
        let board = Self.board()
        var tool = cove
        tool.cutting.feedRate = passes.feed
        tool.cutting.spindleRPM = passes.rpm
        let p = Self.project(shapes: [board], ops: [Self.edge(tool: tool, shapes: [board.id])])
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.message.contains("Chip load") }, "\(job.issues.map(\.message))")
    }

    // MARK: The toolpath

    /// The 1/2" roundover round the 6 × 4" board with 1/2" corner radii: four laps at full depth, each further in than the
    /// last and none inside the final one; simulated, the edge is the bit's profile all round (corners included), and
    /// nothing is cut past it.
    @Test func aFullRoundoverCutsTheBitsProfileRoundTheEdge() throws {
        let board = Self.board()
        let p = Self.project(shapes: [board], ops: [Self.edge(shapes: [board.id])])
        #expect(p.formatVersion == 18)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.warnings.isEmpty, "\(tp.warnings)")
        let plan = EdgeProfileParams().plan(tool: Self.roundover, thickness: Self.stock.thickness)
        let c = plan.centreOffset
        // Where the tool centre runs at full depth, off the board's outline.
        var off: [Double] = []
        var lowest = 0.0
        tp.forEachMotion { _, m in
            guard m.kind != .rapid else { return }
            lowest = min(lowest, m.end.z)
            if abs(m.end.z + plan.depth) < 1e-6 { off.append(-Self.inside(m.end.xy)) }
        }
        #expect(abs(lowest + plan.depth) < 1e-9)
        #expect(off.min()! > c - 0.01)
        for pass in plan.passes {
            let at = c + pass.standoff
            #expect(off.contains { abs($0 - at) < 0.01 }, "no lap \(at) off the edge")
        }
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.2)
        tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) }
        let grid = sim.grid
        // The simulator's resolution: it reads the bit's profile at 513 radii (every 0.037 mm on this bit), so where the
        // profile is steep (near the edge it's almost upright) its height can be off by the profile's rise over a step.
        func resolution(_ u: Double) -> Double {
            let step = Self.roundover.radius / 512
            return 0.01 + Self.finished(u + step, tool: Self.roundover, depth: plan.depth)
                - Self.finished(max(0, u - step), tool: Self.roundover, depth: plan.depth)
        }
        var worst = 0.0, overcut = 0.0, checked = 0
        var at = (Vec2.zero, 0.0)
        for row in 0..<grid.rows {
            for col in 0..<grid.columns {
                let q = Vec2(grid.origin.x + Double(col) * grid.cellSize, grid.origin.y + Double(row) * grid.cellSize)
                let u = Self.inside(q)
                guard u >= 0.2 else { continue }
                let want = Self.finished(u, tool: Self.roundover, depth: plan.depth)
                let got = Double(grid.heights[grid.index(col, row)])
                let past = want - got - resolution(u)
                if past > overcut { at = (q, u) }
                overcut = max(overcut, past)
                if u >= 0.5 {
                    worst = max(worst, abs(got - want) - resolution(u))
                    checked += 1
                }
            }
        }
        #expect(checked > 1000)
        #expect(worst < 0.01, "the edge is \(worst) mm further off the bit's profile than the simulator resolves")
        #expect(overcut <= 0, "cut \(overcut) mm past the profile at \(at.0), \(at.1) mm in")
    }

    /// Climb runs clockwise round the outside, as a profile does; conventional the other way.
    @Test func directionFollowsClimbAndConventional() throws {
        let board = Self.board()
        func signedArea(_ params: EdgeProfileParams) throws -> Double {
            let tp = try #require(CAMEngine.generate(Self.project(shapes: [board], ops: [Self.edge(params, shapes: [board.id])])).toolpaths.first)
            var pts: [Vec2] = []
            tp.forEachMotion { _, m in if m.kind == .feed, abs(m.end.z + 0.5.inch) < 1e-6 { pts.append(m.end.xy) } }
            return Polyline(Array(pts.prefix(400)), closed: true).signedArea
        }
        #expect(try signedArea(EdgeProfileParams()) < 0)
        #expect(try signedArea(EdgeProfileParams(direction: .conventional)) > 0)
    }

    /// Holes and outside edges are chosen apart: a cove round a frame's opening only, then round both.
    @Test func edgesChooseOutsideHolesOrBoth() throws {
        let frame = Self.board()
        let opening = DesignShape(id: Self.id(2), name: "Opening", kind: .rectangle(width: 3.inch, height: 2.inch, cornerRadius: 0.375.inch),
                                  position: Vec2(4.inch, 3.inch))
        func extents(_ edges: EdgeProfileParams.Edges) throws -> Toolpath.Extents {
            let op = Self.edge(EdgeProfileParams(edges: edges), tool: Self.cove, shapes: [frame.id, opening.id])
            let tp = try #require(CAMEngine.generate(Self.project(shapes: [frame, opening], ops: [op])).toolpaths.first)
            #expect(tp.warnings.isEmpty, "\(tp.warnings)")
            return try #require(tp.cuttingExtents)
        }
        let holes = try extents(.holes)
        #expect(holes.max.x < 4.inch + 1.5.inch && holes.min.x > 4.inch - 1.5.inch)
        let outside = try extents(.outside)
        #expect(outside.max.x > 7.inch && outside.min.x < 1.inch)
        let both = try extents(.both)
        #expect(abs(both.max.x - outside.max.x) < 1e-6)
    }

    /// A hole the bit's pilot can't fit in is skipped with a warning; the others are still cut.
    @Test func aHoleTooSmallForTheBitIsSkipped() throws {
        let board = Self.board()
        let small = DesignShape(id: Self.id(3), name: "Small", kind: .circle(radius: 0.2.inch), position: Vec2(2.5.inch, 3.inch))
        let big = DesignShape(id: Self.id(4), name: "Big", kind: .circle(radius: 0.75.inch), position: Vec2(5.inch, 3.inch))
        let op = Self.edge(EdgeProfileParams(edges: .holes), tool: Self.cove, shapes: [board.id, small.id, big.id])
        let tp = try #require(CAMEngine.generate(Self.project(shapes: [board, small, big], ops: [op])).toolpaths.first)
        #expect(tp.warnings.contains { $0.contains("1 hole is too small") }, "\(tp.warnings)")
        let ext = try #require(tp.cuttingExtents)
        #expect(ext.min.x > 5.inch - 0.75.inch)
    }

    /// An inside corner sharper than the bit can follow is noted as info, not warned about.
    @Test func anInsideCornerSharperThanTheBitIsNoted() throws {
        // A board with a square notch in its top edge: two inside corners.
        let outline = Polyline([Vec2(1, 1), Vec2(7, 1), Vec2(7, 5), Vec2(5, 5), Vec2(5, 4), Vec2(3, 4), Vec2(3, 5), Vec2(1, 5)].map { $0 * 25.4 },
                               closed: true)
        let shape = DesignShape(id: Self.id(5), name: "Notched", kind: .paths([outline]), position: .zero)
        let p = Self.project(shapes: [shape], ops: [Self.edge(shapes: [shape.id])])
        let job = CAMEngine.generate(p)
        let notes = job.issues.filter { $0.severity == .info && $0.message.contains("sharper than") }
        #expect(notes.count == 1 && notes[0].message.hasPrefix("2 inside corners"), "\(job.issues.map(\.message))")
        #expect(!job.issues.contains { $0.severity == .warning && $0.message.contains("sharper") })
    }

    // MARK: Bits

    /// Only roundover, cove, ogee and custom form bits that widen going up: the rest are refused, saying why, and cut
    /// nothing.
    @Test func edgeProfilesRefuseBitsTheyCantUse() throws {
        let board = Self.board()
        let dovetail = Tool(id: Self.id(905), number: 8, name: "1/2\" dovetail", shape: .dovetail, fluteDirection: .straight, diameter: 0.5.inch,
                            shankDiameter: 0.25.inch, fluteLength: 0.5.inch, includedAngle: 28, cutting: Self.cutting)
        var undercut = Self.form(.custom, radius: 0, number: 9, id: 906, points: [Vec2(2, 0), Vec2(5, 2), Vec2(3, 5), Vec2(4, 8)])
        undercut.fitDiameterToShape()
        let cases: [(Tool, String)] = [
            (dovetail, "a dovetail bit"), (Self.endMill, "an end mill"), (Fixture.vBit90, "a V-bit"), (undercut, "wider low down"),
        ]
        for (tool, why) in cases {
            let op = Self.edge(tool: tool, shapes: [board.id])
            #expect(op.toolRefusal?.contains(why) == true, "\(tool.name): \(op.toolRefusal ?? "accepted")")
            let tp = try #require(CAMEngine.generate(Self.project(shapes: [board], ops: [op])).toolpaths.first)
            #expect(tp.motions.isEmpty)
            #expect(tp.warnings.contains { $0.contains(why) })
        }
        for tool in [Self.roundover, Self.cove, Self.ogee] {
            #expect(Self.edge(tool: tool, shapes: [board.id]).toolRefusal == nil)
        }
        // Profiles still take every form bit and the dovetail; other toolpaths name the edge profile too.
        let profile = OperationKind.profile(ProfileParams(depth: DepthSettings(cutDepth: 5)))
        #expect(profile.refusal(for: dovetail) == nil && profile.refusal(for: undercut) == nil)
        let pocket = OperationKind.pocket(PocketParams(depth: DepthSettings(cutDepth: 5)))
        #expect(pocket.refusal(for: Self.roundover)?.contains("Edge Profile") == true)
    }

    // MARK: Order and tabs

    /// A new edge profile goes before the cut-out of its part, and Optimize Run Order keeps it there.
    @Test func aNewEdgeProfileGoesBeforeTheCutOut() {
        let board = Self.board()
        var p = Self.project(shapes: [board], ops: [Self.cutOut(shapes: [board.id])])
        let k = p.addOperation(Self.edge(shapes: [board.id]))
        #expect(k == 0)
        #expect(p.operations.map(\.kind.isEdgeProfile) == [true, false])
        let r = OperationScheduler.optimize(p)
        #expect(r.outOfOrder.isEmpty && !r.changed)
        // Anything else still goes at the end.
        p.addOperation(CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [board.id], tool: Self.endMill))
        #expect(p.operations.last.map { if case .pocket = $0.kind { true } else { false } } == true)
    }

    /// An edge profile and the cut-out of its part: the profile first, and the tabs the cut-out leaves are untouched.
    @Test func theProfileRunsFirstAndLeavesTheTabsAlone() throws {
        let board = Self.board()
        let p = Self.project(shapes: [board], ops: [Self.edge(shapes: [board.id]), Self.cutOut(shapes: [board.id])])
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        #expect(!job.issues.contains { $0.message.contains("tabs") }, "\(job.issues.map(\.message))")
        #expect(job.reorder == nil)
        // Simulated, the material along the cut-out's kerf stands at the tabs' tops where the tabs are, and nowhere lower
        // than the cut.
        var sim = MaterialSimulator(stock: p.stock, cellSize: 0.25)
        for tp in job.toolpaths { tp.forEachMotion { s, m in sim.apply(m, from: s, tool: tp.tool) } }
        guard case let .profile(cut) = p.operations[1].kind else { return }
        let tabTop = -OperationScheduler.tabTop(cut)
        // The middle of the kerf: the end mill's path.
        let kerf = try #require(Region(outer: board.polylines(tolerance: 0.05)[0]).offset(by: Self.endMill.radius).first?.outer)
        let along = LoopWalker(kerf)
        var highest = -Double.infinity
        for i in 0..<2000 {
            let q = along.point(at: along.length * Double(i) / 2000)
            if let h = sim.grid.height(at: q) { highest = max(highest, Double(h)) }
        }
        #expect(abs(highest - tabTop) < 0.05, "the kerf's highest is \(highest), the tabs' tops \(tabTop)")
    }

    /// After a cut-out whose tabs it clears, an edge profile may run (the tabs hold the part): no warning, and Optimize
    /// Run Order leaves it there. Deep enough to reach the tabs, it's warned about and Optimize puts it first.
    @Test func afterTheCutOutItsWarnedAboutOnlyWhenItReachesTheTabs() {
        let board = Self.board()
        let clear = Self.project(shapes: [board], ops: [Self.cutOut(shapes: [board.id]), Self.edge(shapes: [board.id])])
        let job = CAMEngine.generate(clear)
        #expect(!job.issues.contains { $0.message.contains("tabs") || $0.message.contains("cut its part free") },
                "\(job.issues.map(\.message))")
        #expect(OperationScheduler.optimize(clear).outOfOrder.isEmpty)

        // An ogee 0.7" deep reaches below the tabs' tops (0.77" − 0.125").
        let deep = Self.project(shapes: [board], ops: [Self.cutOut(shapes: [board.id]),
                                                       Self.edge(EdgeProfileParams(depth: 0.7.inch), tool: Self.form(.cove, radius: 0.5.inch,
                                                                                                                     number: 5, id: 907),
                                                                 shapes: [board.id])])
        let warned = CAMEngine.generate(deep)
        #expect(warned.issues.contains { $0.severity == .warning && $0.message.contains("reaches the tabs") }, "\(warned.issues.map(\.message))")
        let r = OperationScheduler.optimize(deep)
        #expect(r.outOfOrder.count == 1)
        #expect(r.order.first == Self.id(10))

        // Without tabs the cut-out frees the part, so the profile has to come first, as for any work inside it.
        let free = Self.project(shapes: [board], ops: [Self.cutOut(shapes: [board.id], tabs: false), Self.edge(shapes: [board.id])])
        #expect(CAMEngine.generate(free).issues.contains { $0.message.contains("cut its part free") })

        // Before the cut-out but deep enough to reach its tabs: it thins them.
        var before = deep
        before.applyRunOrder([Self.id(10), Self.id(11)])
        let thinned = CAMEngine.generate(before)
        #expect(thinned.issues.contains { $0.severity == .warning && $0.message.contains("below the tops of the tabs") },
                "\(thinned.issues.map(\.message))")
    }

    // MARK: File format

    /// Format 18: edge profiles round-trip; a project without one stays on its format.
    @Test func edgeProfilesAreFormat18AndRoundTrip() throws {
        let board = Self.board()
        let params = EdgeProfileParams(edges: .both, depth: 0.4.inch, offset: 0.05.inch, passes: .vertical, passCount: 4, bandWidth: 0.1.inch,
                                       passDepth: 0.15.inch, finish: 0.01.inch, direction: .conventional,
                                       entry: EntrySettings(kind: .plunge, rampLength: 1.inch), leads: nil)
        let p = Self.project(shapes: [board], ops: [Self.edge(params, shapes: [board.id])])
        #expect(p.formatVersion == 18)
        #expect(try Project.decode(p.encoded()) == p)
        let plain = Self.project(shapes: [board], ops: [Self.cutOut(shapes: [board.id])])
        #expect(plain.formatVersion == 1)
    }
}
