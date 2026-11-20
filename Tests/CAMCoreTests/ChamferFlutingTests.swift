import Foundation
import Testing
@testable import CAMCore

/// Chamfers, flutes and prisms (#25).
struct ChamferFlutingTests {
    static let lib = ToolLibrary.starter
    static var vBit60: Tool { lib.tool(number: 5)! }
    static var vBit90: Tool { lib.tool(number: 6)! }
    static var ball: Tool { lib.tool(number: 7)! }
    static var engraving: Tool { lib.tool(number: 9)! }

    static func job(_ shapes: [DesignShape], _ ops: [CAMOperation]) -> JobResult {
        CAMEngine.generate(Fixture.project(shapes: shapes, ops: ops))
    }

    static func chamfer(_ params: ChamferParams, _ shapes: [DesignShape], tool: Tool = vBit90) -> CAMOperation {
        CAMOperation(name: "Chamfer", kind: .chamfer(params), shapeIDs: shapes.map(\.id), tool: tool)
    }

    /// An L-shaped part: a 40 × 40 square at (80, 55)–(120, 95) less its top-right quarter, so it has one inside
    /// corner, at (100, 75).
    static func lShape() -> DesignShape {
        let pts = [(80, 55), (120, 55), (120, 75), (100, 75), (100, 95), (80, 95)].map { Vec2(Double($0.0), Double($0.1)) }
        return DesignShape(kind: .paths([Polyline(pts, closed: true)]), position: .zero)
    }

    static func height(_ grid: HeightGrid, _ x: Double, _ y: Double) -> Double {
        Double(grid.height(at: Vec2(x, y)) ?? .nan)
    }

    // MARK: Width and depth

    @Test func widthAndDepthAreLinkedThroughTheBitsAngle() {
        // 90°: as wide as it is deep. 60°: depth = width / tan 30°.
        #expect(abs(ChamferParams.depth(width: 3, tool: Self.vBit90) - 3) < 1e-9)
        let d60 = ChamferParams.depth(width: 3, tool: Self.vBit60)
        #expect(abs(d60 - 3 / tan(30.0 * .pi / 180)) < 1e-9)
        #expect(abs(ChamferParams.width(depth: d60, tool: Self.vBit60) - 3) < 1e-9)
        #expect(abs(ChamferParams(width: 2).depth(with: Self.vBit60) - 2 * 3.0.squareRoot()) < 1e-9)
        // A bit with no taper has no chamfer depth.
        #expect(ChamferParams.depth(width: 3, tool: Fixture.endMill) == 0)
    }

    @Test func theTipRunsAtTheChamferDepthOffsetByTheWidth() throws {
        // Top edge on the vector: tip width (+ tip radius) outside it, as deep as the bevel; bottom edge: on the vector.
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        for (edge, offset) in [(ChamferParams.Edge.top, 3.0), (.bottom, 0.0)] {
            let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .outside, edge: edge, width: 3), [shape])])
            let tp = try #require(job.toolpaths.first)
            let ext = try #require(tp.cuttingExtents)
            #expect(abs(ext.min.z + 3) < 1e-6)
            // The far side of the square at full depth, at the right edge: x = 120 + offset.
            let right = Fixture.pointsAt(z: -3, tp).map(\.x).max() ?? 0
            #expect(abs(right - (120 + offset)) < 0.01, "\(edge)")
        }
        // The engraving bit's flat tip moves the tip path out by its radius on a top-edge bevel.
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .outside, edge: .top, width: 1), [shape], tool: Self.engraving)])
        let ext = try #require(job.toolpaths.first?.cuttingExtents)
        let expected = 120 + 1 + Self.engraving.tipDiameter / 2
        #expect(abs(ext.max.x - expected) < 0.01)
    }

    // MARK: Simulated bevels

    /// A square part bevelled round its top edge (top edge on the vector, outside it), as a raised part's top: the
    /// faces are at 45° with a 90° bit, the bevel 3 mm wide, and with sharp corners the corner is a crisp hip; without,
    /// it's a cone.
    @Test func aSquarePartGetsAFortyFiveDegreeBevelWithSharpCorners() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let stock = Fixture.stock
        func grid(sharp: Bool) throws -> HeightGrid {
            let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .outside, edge: .top, width: 3, sharpCorners: sharp), [shape])])
            #expect(!job.hasErrors)
            return Fixture.simulate(job.toolpaths, stock: stock, cell: 0.1)
        }
        let g = try grid(sharp: true)
        // Mid-edge (the right side, x = 120): the face falls 1 mm per mm out to 3 mm, the part's top untouched.
        var worst = 0.0
        for delta in [0.5, 1.0, 1.5, 2.0, 2.5] {
            worst = max(worst, abs(Self.height(g, 120 + delta, 75) + delta))
        }
        #expect(worst < 0.15, "bevel off by \(worst) mm")
        #expect(Self.height(g, 119.7, 75) > -0.1)
        #expect(Self.height(g, 100, 75) == 0)
        // The bevel's foot is 3 mm deep, 3 mm out.
        #expect(abs(Self.height(g, 123, 75) + 3) < 0.15)
        // The corner (120, 95): on its diagonal a mm out each way, the faces meet at a mm deep (a crisp hip); a cone
        // would be √2·a deep there.
        var hip = 0.0
        for a in [0.5, 1.0, 1.5, 2.0] {
            hip = max(hip, abs(Self.height(g, 120 + a, 95 + a) + a))
        }
        #expect(hip < 0.15, "hip off by \(hip) mm")
        let rounded = try grid(sharp: false)
        let cone = Self.height(rounded, 121.5, 96.5)
        #expect(abs(cone + 1.5 * 2.0.squareRoot()) < 0.15, "\(cone)")
    }

    /// The part's own top edge bevelled before a profile cuts it out (bottom edge on the vector, inside it): an
    /// L-shaped part, whose inside corner the bit rises into along the bisector so the faces meet in a crisp valley.
    @Test func aBottomEdgeBevelRisesIntoInsideCornersWhenSharp() throws {
        let shape = Self.lShape()
        let stock = Fixture.stock
        func grid(sharp: Bool) throws -> HeightGrid {
            let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 3, sharpCorners: sharp), [shape])])
            #expect(!job.hasErrors)
            return Fixture.simulate(job.toolpaths, stock: stock, cell: 0.1)
        }
        let g = try grid(sharp: true)
        // Mid-edge (the bottom side, y = 55), inside the part: 3 mm deep at the vector, rising 1 mm per mm.
        var worst = 0.0
        for delta in [0.5, 1.0, 1.5, 2.0, 2.5] {
            worst = max(worst, abs(Self.height(g, 90, 55 + delta) + (3 - delta)))
        }
        #expect(worst < 0.15, "bevel off by \(worst) mm")
        #expect(Self.height(g, 90, 58.4) == 0)
        // Outside corner (80, 55): automatically crisp, a mm in each way is (3 − a) deep.
        var hip = 0.0
        for a in [0.5, 1.0, 2.0] { hip = max(hip, abs(Self.height(g, 80 + a, 55 + a) + (3 - a))) }
        #expect(hip < 0.15, "hip off by \(hip) mm")
        // Inside corner (100, 75): the valley runs into the part along the bisector, a mm in each way at (3 − a) deep.
        var valley = 0.0
        for a in [0.5, 1.0, 2.0, 2.7] { valley = max(valley, abs(Self.height(g, 100 - a, 75 - a) + (3 - a))) }
        #expect(valley < 0.15, "valley off by \(valley) mm")
        // The part's top beyond the valley is untouched.
        #expect(Self.height(g, 96.6, 71.6) > -0.1)
        // Without sharp corners the bit stays at depth: the valley is a cone, shallower there.
        let rounded = try grid(sharp: false)
        let cone = Self.height(rounded, 98, 73)
        #expect(abs(cone + (3 - 2 * 2.0.squareRoot())) < 0.15, "\(cone)")
    }

    @Test func aSharpCornerRiseIsUpAndBackDownTheBisector() throws {
        let shape = Self.lShape()
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 3), [shape])])
        let tp = try #require(job.toolpaths.first)
        // One rise, to the top of the bevel at (97, 72): the inside corner, 3 mm in along both edges.
        let tops = tp.motions.filter { $0.kind == .feed && $0.end.z > -1e-6 && $0.end.z < 0.01 }
        #expect(tops.count == 1)
        let top = try #require(tops.first)
        #expect(top.end.xy.distance(to: Vec2(97, 72)) < 0.02)
    }

    @Test func climbKeepsTheBevelOnTheToolsRight() throws {
        // Bevels on a part (a bottom-edge one inside it, a top-edge one outside it) climb clockwise round it, as the
        // outside profile that cuts it out does; a countersink round a hole's top runs the other way, as an inside one.
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        for (edge, side, clockwise) in [(ChamferParams.Edge.bottom, ChamferParams.Side.inside, true), (.top, .outside, true), (.top, .inside, false)] {
            let job = Self.job([shape], [Self.chamfer(ChamferParams(side: side, edge: edge, width: 2), [shape])])
            let tp = try #require(job.toolpaths.first)
            let loop = Polyline(Fixture.pointsAt(z: -2, tp), closed: true)
            #expect((loop.signedArea < 0) == clockwise, "\(edge) \(side)")
        }
    }

    @Test func passesStepDownToTheBevel() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let job = Self.job([shape], [Self.chamfer(ChamferParams(side: .inside, edge: .bottom, width: 5, passDepth: 2), [shape])])
        let tp = try #require(job.toolpaths.first)
        for z in [-5.0 / 3, -10.0 / 3, -5.0] { #expect(Fixture.pointsAt(z: z, tp).count >= 4, "pass at \(z)") }
    }

    @Test func bothSidesOfABottomEdgeIsOneGrooveAndOfATopEdgeTwo() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let groove = Self.job([shape], [Self.chamfer(ChamferParams(side: .both, edge: .bottom, width: 2), [shape])])
        let ridge = Self.job([shape], [Self.chamfer(ChamferParams(side: .both, edge: .top, width: 2), [shape])])
        // Rapids down to the plunge height, one per path.
        let plunges = { (tp: Toolpath) in tp.motions.filter { $0.kind == .rapid && abs($0.end.z - 2) < 1e-9 }.count }
        let g = try #require(groove.toolpaths.first), r = try #require(ridge.toolpaths.first)
        #expect(plunges(g) == 1)
        #expect(plunges(r) == 2)
        let ext = try #require(r.cuttingExtents)
        #expect(abs(ext.max.x - 122) < 0.01 && abs(ext.min.x - 78) < 0.01)
    }

    // MARK: Checks

    @Test func aChamferNeedsAVBitAndAVTallEnough() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let flat = Self.job([shape], [Self.chamfer(ChamferParams(), [shape], tool: Fixture.endMill)])
        #expect(flat.issues.contains { $0.message.contains("need a V-bit") })
        #expect(flat.toolpaths.first?.isEmpty == true)
        // 90° V-bit 1/2": its V is 6.35 mm tall.
        let deep = Self.job([shape], [Self.chamfer(ChamferParams(width: 8), [shape])])
        #expect(deep.issues.contains { $0.message.contains("only cuts") })
        let open = DesignShape(kind: .paths([Polyline([Vec2(10, 10), Vec2(60, 10)], closed: false)]), position: .zero)
        let skipped = Self.job([shape, open], [Self.chamfer(ChamferParams(), [shape, open])])
        #expect(skipped.issues.contains { $0.message.contains("open vector") })
    }

    static func withCutOut(_ chamfer: ChamferParams) -> JobResult {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let profile = CAMOperation(name: "Cut out", kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 20.5))),
                                   shapeIDs: [shape.id], tool: Fixture.endMill)
        return job([shape], [Self.chamfer(chamfer, [shape]), profile])
    }

    @Test func aBevelTheCutOutWouldRemoveIsFlagged() {
        let away = Self.withCutOut(ChamferParams(side: .outside, edge: .top))
        #expect(away.issues.contains { $0.operation == "Chamfer" && $0.message.contains("cuts the bevel away") })
        let lip = Self.withCutOut(ChamferParams(side: .inside, edge: .top))
        #expect(lip.issues.contains { $0.operation == "Chamfer" && $0.message.contains("sharp lip") })
        let right = Self.withCutOut(ChamferParams(side: .inside, edge: .bottom))
        #expect(!right.issues.contains { $0.operation == "Chamfer" && $0.message.contains("bevel") })
    }

    @Test func optimizeRunOrderPutsTheChamferBeforeTheCutOut() throws {
        // A 1/2" V-bit reaches further than the 1/4" end mill, but the chamfer is still on the part the profile frees.
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let profile = CAMOperation(name: "Cut out", kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 20.5))),
                                   shapeIDs: [shape.id], tool: Fixture.endMill)
        let chamfer = Self.chamfer(ChamferParams(side: .inside, edge: .bottom), [shape])
        let p = Fixture.project(shapes: [shape], ops: [profile, chamfer])
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.operation == "Chamfer" && $0.message.contains("cut its part free") })
        let r = OperationScheduler.optimize(p)
        #expect(r.order == [chamfer.id, profile.id])
    }

    @Test func aBottomEdgeChamferIsThePartOfTheProfileItBevels() throws {
        // The profile's dogbones and leads don't treat the chamfer on its own walls as another part to keep clear of.
        let shape = Self.lShape()
        let relief = CornerReliefSettings()
        let profile = CAMOperation(name: "Cut out", kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 20.5),
                                                                                  leads: LeadSettings(), cornerRelief: relief)),
                                   shapeIDs: [shape.id], tool: Fixture.endMill)
        let chamfer = Self.chamfer(ChamferParams(side: .inside, edge: .bottom), [shape])
        let alone = Self.job([shape], [profile])
        let both = Self.job([shape], [chamfer, profile])
        let cut = { (job: JobResult) in job.toolpaths.first { $0.sourceOperationID == profile.id } }
        let a = try #require(cut(alone)), b = try #require(cut(both))
        let corners = try #require(b.reliefCorners)
        #expect(!corners.isEmpty)
        #expect(corners == a.reliefCorners)
        #expect(!corners.contains { $0.isFlagged })
        #expect(a.warnings == b.warnings)
    }

    // MARK: Fluting

    static func line(_ from: Vec2, _ to: Vec2) -> DesignShape {
        DesignShape(kind: .paths([Polyline([from, to], closed: false)]), position: .zero)
    }

    /// Depth of a polyline of 3D points at x (linear in between).
    static func depth(at x: Double, _ pts: [Vec3]) -> Double? {
        for (a, b) in zip(pts, pts.dropFirst()) where (a.x - x) * (b.x - x) <= 0 && abs(b.x - a.x) > 1e-9 {
            return -(a.z + (b.z - a.z) * (x - a.x) / (b.x - a.x))
        }
        return nil
    }

    @Test func theFluteDepthProfileFollowsTheRamps() throws {
        let p = FlutingParams(depth: 5, ramp: .both, rampLength: 20)
        #expect(p.depth(at: 0, fluteLength: 100) == 0)
        #expect(abs(p.depth(at: 10, fluteLength: 100) - 2.5) < 1e-9)
        #expect(p.depth(at: 50, fluteLength: 100) == 5)
        #expect(abs(p.depth(at: 95, fluteLength: 100) - 1.25) < 1e-9)
        // Smooth eases in: half way down the ramp it's sin 45° of the way.
        var smooth = p
        smooth.rampShape = .smooth
        #expect(abs(smooth.depth(at: 10, fluteLength: 100) - 5 * sin(Double.pi / 4)) < 1e-9)
        // Ramp % of the longest ramp: half the flute each for both ends, all of it for one.
        var percent = p
        percent.rampPercent = 0.5
        #expect(abs(percent.rampLength(onFluteOf: 100) - 25) < 1e-9)
        percent.ramp = .start
        #expect(abs(percent.rampLength(onFluteOf: 100) - 50) < 1e-9)
        #expect(percent.depth(at: 100, fluteLength: 100) == 5)
        // A ramp longer than the flute allows stops in the middle.
        let long = FlutingParams(depth: 5, ramp: .both, rampLength: 80)
        #expect(abs(long.rampLength(onFluteOf: 100) - 50) < 1e-9)
        var end = p
        end.ramp = .end
        #expect(end.depth(at: 0, fluteLength: 100) == 5)
        #expect(end.depth(at: 100, fluteLength: 100) == 0)
    }

    @Test func aFluteToolpathRampsInAndOutOverItsLength() throws {
        let line = Self.line(Vec2(50, 75), Vec2(150, 75))
        let op = CAMOperation(name: "Flute", kind: .fluting(FlutingParams(depth: 5, ramp: .both, rampLength: 20, passDepth: 5)),
                              shapeIDs: [line.id], tool: Self.ball)
        let job = Self.job([line], [op])
        #expect(!job.hasErrors)
        let tp = try #require(job.toolpaths.first)
        let pts = tp.motions.filter { $0.kind == .feed }.map(\.end)
        // Starts at the vector's start, at the surface.
        #expect(pts.first.map { $0.xy.distance(to: Vec2(50, 75)) < 1e-6 && abs($0.z) < 1e-6 } == true)
        for (x, d) in [(50.0, 0.0), (60, 2.5), (70, 5), (100, 5), (130, 5), (140, 2.5), (150, 0)] {
            let got = try #require(Self.depth(at: x, pts))
            #expect(abs(got - d) < 0.01, "depth at x = \(x): \(got)")
        }
        // Deepest point 5 mm; never deeper.
        #expect(abs(try #require(tp.cuttingExtents).min.z + 5) < 1e-6)
    }

    @Test func fluteStartsAtEachVectorsStartAndOneEndedRampsFinishDeep() throws {
        let line = Self.line(Vec2(150, 75), Vec2(50, 75))
        let op = CAMOperation(name: "Flute", kind: .fluting(FlutingParams(depth: 4, ramp: .start, rampLength: 30, rampShape: .smooth, passDepth: 4)),
                              shapeIDs: [line.id], tool: Self.ball)
        let tp = try #require(Self.job([line], [op]).toolpaths.first)
        let pts = tp.motions.filter { $0.kind == .feed }.map(\.end)
        #expect(pts.first.map { abs($0.x - 150) < 1e-6 } == true)
        let smooth = try #require(Self.depth(at: 135, pts))
        #expect(abs(smooth - 4 * sin(Double.pi / 4)) < 0.02, "\(smooth)")
        #expect(abs(try #require(Self.depth(at: 51, pts)) - 4) < 1e-6)
    }

    @Test func passesScaleTheRampsSoTheLastRunsTheFullFlute() throws {
        // 6 mm in 3 passes of 2: each pass follows the whole flute at a third, two thirds and all of the depth, back and
        // forth (ramps at both ends are the same either way).
        let line = Self.line(Vec2(50, 75), Vec2(150, 75))
        let op = CAMOperation(name: "Flute", kind: .fluting(FlutingParams(depth: 6, ramp: .both, rampLength: 20, passDepth: 2)),
                              shapeIDs: [line.id], tool: Self.ball)
        let tp = try #require(Self.job([line], [op]).toolpaths.first)
        let deepest = tp.motions.map(\.end.z).min() ?? 0
        #expect(abs(deepest + 6) < 1e-6)
        for z in [-2.0, -4.0, -6.0] { #expect(Fixture.pointsAt(z: z, tp).count >= 2, "pass at \(z)") }
        // No retract between passes: one plunge from safe Z.
        let entries = tp.motions.filter { $0.kind == .rapid && $0.end.z > 5 }.count
        #expect(entries == 1)
        // The middle pass ends at the start, the last at the far end.
        #expect(abs((tp.motions.last { $0.kind == .feed }?.end.x ?? 0) - 150) < 1e-6)
    }

    @Test func flutesTheSameBothWaysStartFromTheNearerEnd() throws {
        // Two flutes drawn the same way: after the first (one pass) the tool is at x = 150, so the second is cut from its
        // x = 150 end. Ramped at the start only, both keep their direction.
        let a = Self.line(Vec2(50, 75), Vec2(150, 75)), b = Self.line(Vec2(50, 95), Vec2(150, 95))
        func starts(_ ramp: FlutingParams.Ramp) throws -> [Double] {
            let op = CAMOperation(name: "Flute", kind: .fluting(FlutingParams(depth: 3, ramp: ramp, rampLength: 20, passDepth: 3)),
                                  shapeIDs: [a.id, b.id], tool: Self.ball)
            let tp = try #require(Self.job([a, b], [op]).toolpaths.first)
            // Where each flute's plunge from the plunge height lands.
            return tp.motions.indices.filter { tp.motions[$0].kind == .rapid && abs(tp.motions[$0].end.z - 2) < 1e-9 }.map { tp.motions[$0].end.x }
        }
        #expect(try starts(.both) == [50, 150])
        #expect(try starts(.none) == [50, 150])
        #expect(try starts(.start) == [50, 50])
    }

    @Test func theSetupSheetDescribesEachBevelAndFlute() {
        let p = Self.chamferJob()
        let html = SetupSheet.html(project: p, job: CAMEngine.generate(p), date: GoldenPostTests.date)
        #expect(html.contains("Chamfers, flutes and prisms"))
        #expect(html.contains("a bevel 0.125 in wide and 0.125 in deep inside the shapes, its bottom edge on the vector"))
        let f = Self.flutingJob()
        let flutes = SetupSheet.html(project: f, job: CAMEngine.generate(f), date: GoldenPostTests.date)
        #expect(flutes.contains("flutes 0.100 in deep, ramping in and out over 1.000 in (smooth)"))
    }

    @Test func fluteWarnsForAFlatEndMill() {
        let line = Self.line(Vec2(50, 75), Vec2(150, 75))
        let op = CAMOperation(name: "Flute", kind: .fluting(FlutingParams()), shapeIDs: [line.id], tool: Fixture.endMill)
        #expect(Self.job([line], [op]).issues.contains { $0.message.contains("square-bottomed") })
    }

    /// Flutes on a column: lines along X on a wrapped dowel's sheet become flutes along the blank, ramping in and out,
    /// posted in inverse time where the blank turns and checked against the post.
    static func wrappedFlutes() -> Project {
        RotaryWrapTests.job { p in
            let c = RotaryWrapTests.middle, quarter = Double.pi * 50 / 4
            let lines = (0..<4).map { k in Self.line(Vec2(60, c + Double(k) * quarter - quarter * 1.5), Vec2(240, c + Double(k) * quarter - quarter * 1.5)) }
            p.shapes = lines
            p.operations = [CAMOperation(name: "Flutes", kind: .fluting(FlutingParams(depth: 3, ramp: .both, rampLength: 30, rampShape: .smooth)),
                                         shapeIDs: lines.map(\.id), tool: Self.ball)]
        }
    }

    @Test func flutesWrapRoundAColumn() throws {
        let p = Self.wrappedFlutes()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.filter { $0.severity == .error }.map(\.message))")
        let tp = try #require(job.toolpaths.first)
        #expect(tp.wrapDiameter == 50)
        // On the sheet, each flute keeps its depth profile.
        let c = RotaryWrapTests.middle, quarter = Double.pi * 50 / 4
        let onLine = tp.motions.filter { $0.kind == .feed && abs($0.end.y - (c + quarter * 0.5)) < 1e-6 }.map(\.end)
        let full = try #require(Self.depth(at: 150, onLine))
        #expect(abs(full - 3) < 1e-6)
        let ramp = try #require(Self.depth(at: 75, onLine))
        #expect(abs(ramp - 3 * sin(Double.pi / 4)) < 0.02, "\(ramp)")
        // Round the blank: the flute through the top line (A0 at half a quarter turn) is 3 mm deep in the middle of its
        // length and still at the surface past its ends.
        var s = SimulationSession(toolpaths: job.toolpaths, stock: p.stock, rapidRate: 5000, cellSize: 0.5)
        s.runToEnd()
        let g = try #require(s.radialGrid)
        let a = 0.5 * quarter / 25
        let middle = Double(try #require(g.radius(at: 150, angle: a)))
        #expect(abs(middle - 22) < 0.3, "\(middle)")
        let past = Double(try #require(g.radius(at: 50, angle: a)))
        #expect(abs(past - 25) < 0.05, "\(past)")
        // The post writes it in inverse time where A turns and passes its own checks.
        let gcode = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
        #expect(gcode.contains("G93"))
        let issues = GCodeCheck.run(gcode, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }

    // MARK: Prism

    @Test func aFullPrismRisesToARidgeAtTheBitsAngle() throws {
        // A 30 × 10 bar: full depth is its half width over tan 45° = 5. The ridge runs along the middle at the surface
        // and each slope rises 1 mm per mm from the outline at 5 mm deep.
        let shape = Fixture.rect(30, 10, at: Vec2(100, 75))
        let op = CAMOperation(name: "Prism", kind: .prism(PrismParams()), shapeIDs: [shape.id], tool: Self.vBit90)
        let p = Fixture.project(shapes: [shape], ops: [op])
        #expect(abs(p.fullPrismDepth(for: op) - 5) < 0.05)
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors)
        let tp = try #require(job.toolpaths.first)
        #expect(abs(try #require(tp.cuttingExtents).min.z + 5) < 0.05)
        let g = Fixture.simulate(job.toolpaths, stock: p.stock, cell: 0.1)
        var worst = 0.0
        for delta in [0.5, 1.5, 2.5, 3.5, 4.5] {
            worst = max(worst, abs(Self.height(g, 100, 70 + delta) + (5 - delta)))
        }
        #expect(worst < 0.15, "slope off by \(worst) mm")
        #expect(Self.height(g, 100, 75) > -0.15)
        // The ends are hips like a roof's: 1 mm in from the end on the centre line it's 4 mm down.
        #expect(abs(Self.height(g, 86, 75) + 4) < 0.15)
        // A 60° bit is steeper and deeper: 5 / tan 30°.
        var steep = op
        steep.tool = Self.vBit60
        #expect(abs(p.fullPrismDepth(for: steep) - 5 / tan(30.0 * .pi / 180)) < 0.05)
    }

    @Test func aPrismsInsideCornersRiseToTheRidgeAndNoFurther() throws {
        // An L with arms 8 wide (a 16 square less its top-right quarter, inside corner at (100, 75)). Its widest place is
        // the elbow, where a circle touching both outer edges and the inside corner is 8√2 / (1 + √2) across, so that's
        // the full prism depth. 4 deep, the arms' ridges are at the surface and the inside corner's valley rises from
        // the corner at 4 deep to where they meet, at (96, 71).
        let pts = [(92, 67), (108, 67), (108, 75), (100, 75), (100, 83), (92, 83)].map { Vec2(Double($0.0), Double($0.1)) }
        let shape = DesignShape(kind: .paths([Polyline(pts, closed: true)]), position: .zero)
        var op = CAMOperation(name: "Prism", kind: .prism(PrismParams()), shapeIDs: [shape.id], tool: Self.vBit90)
        let elbow = 8 * 2.0.squareRoot() / (1 + 2.0.squareRoot())
        #expect(abs(Fixture.project(shapes: [shape], ops: [op]).fullPrismDepth(for: op) - elbow) < 0.05)
        op.kind = .prism(PrismParams(depth: 4))
        let p = Fixture.project(shapes: [shape], ops: [op])
        let job = CAMEngine.generate(p)
        #expect(!job.issues.contains { $0.severity != .info }, "\(job.issues.map(\.message))")
        let g = Fixture.simulate(job.toolpaths, stock: p.stock, cell: 0.1)
        // On the valley, a mm in from the corner each way: 4 - a deep.
        for a in [0.5, 1.5, 3.0] {
            let h = Self.height(g, 100 - a, 75 - a)
            #expect(abs(h + (4 - a)) < 0.15, "valley at \(a): \(h)")
        }
        // The arms' ridges stay at the surface: along the bottom arm, and the left one.
        #expect(Self.height(g, 104, 71) > -0.15)
        #expect(Self.height(g, 96, 79) > -0.15)
        #expect(Self.height(g, 96, 71) > -0.15)
    }

    @Test func aShallowPrismHasAFlatTop() throws {
        let shape = Fixture.rect(30, 20, at: Vec2(100, 75))
        let op = CAMOperation(name: "Prism", kind: .prism(PrismParams(depth: 4)), shapeIDs: [shape.id], tool: Self.vBit90)
        let g = Fixture.simulate(Self.job([shape], [op]).toolpaths, stock: Fixture.stock, cell: 0.1)
        #expect(Self.height(g, 100, 75) == 0)
        #expect(abs(Self.height(g, 100, 67) + 2) < 0.15)
    }

    // MARK: Format

    @Test func chamfersFlutesAndPrismsAreFormatEightAndRoundTrip() throws {
        let shape = Fixture.rect(40, 40, at: Vec2(100, 75))
        let ops = [
            Self.chamfer(ChamferParams(side: .both, edge: .bottom, width: 2.5, startDepth: 1, passDepth: 1.5, sharpCorners: false,
                                       direction: .conventional), [shape]),
            CAMOperation(name: "Flute", kind: .fluting(FlutingParams(startDepth: 0.5, depth: 4, ramp: .end, rampLength: 12, rampPercent: 0.3,
                                                                     rampShape: .smooth, passDepth: 2)),
                         shapeIDs: [shape.id], tool: Self.ball),
            CAMOperation(name: "Prism", kind: .prism(PrismParams(startDepth: 1, depth: 3, passDepth: 1, direction: .conventional)),
                         shapeIDs: [shape.id], tool: Self.vBit60),
        ]
        for op in ops {
            #expect(op.requiredFormatVersion == 8)
            let p = Fixture.project(shapes: [shape], ops: [op])
            #expect(p.formatVersion == 8)
            #expect(try Project.decode(p.encoded()) == p)
        }
        // A project without them keeps its old format.
        #expect(Fixture.project(shapes: [shape], ops: []).formatVersion == 1)
    }

    // MARK: Golden G-code (Avid Mach4)

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "C4A3F000-0000-0000-0000-%012d", n))! }

    /// An L-shaped bracket 6 × 4 in with a 1 in hole, its top edge and the hole's rim bevelled 1/8 in with the 90°
    /// V-bit before it's cut out: straight edges, outside corners, an inside corner the bit rises into, and arcs.
    static func chamferJob() -> Project {
        let pts = [(1.0, 1.0), (7.0, 1.0), (7.0, 3.0), (4.0, 3.0), (4.0, 5.0), (1.0, 5.0)].map { Vec2($0.0.inch, $0.1.inch) }
        let bracket = DesignShape(id: id(1), name: "Bracket", kind: .paths([Polyline(pts, closed: true)]), position: .zero)
        let hole = DesignShape(id: id(2), name: "Hole", kind: .circle(radius: 0.5.inch), position: Vec2(2.5.inch, 3.inch))
        var bit = lib.tool(number: 6)!
        bit.cutting.spindleRPM = 18000
        let op = CAMOperation(id: id(11), name: "Chamfer edges", kind: .chamfer(ChamferParams(side: .inside, edge: .bottom)),
                              shapeIDs: [bracket.id, hole.id], tool: bit)
        return Project(name: "Chamfered bracket", displayUnits: .inch,
                       stock: Stock(width: 8.inch, height: 6.inch, thickness: 0.75.inch, materialName: "Maple"),
                       shapes: [bracket, hole], operations: [op])
    }

    /// Eight flutes along a 2 in column wrapped on the rotary, 0.1 in deep with smooth 1 in ramps at both ends.
    static func flutingJob() -> Project {
        var stock = Stock(materialName: "Poplar")
        stock.setRotary(RotaryStock(shape: .cylinder, diameter: 2.inch, length: 12.inch, layout: .wrapped))
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis(centerHeight: 4.inch)
        let around = Double.pi * 2.inch
        let lines = (0..<8).map { k in
            DesignShape(id: id(20 + k), name: "Flute \(k + 1)", kind: .paths([Polyline([Vec2(2.inch, 0), Vec2(10.inch, 0)], closed: false)]),
                        position: Vec2(0, around * (Double(k) + 0.5) / 8))
        }
        var ball = lib.tool(number: 7)!
        ball.cutting.spindleRPM = 15000
        let op = CAMOperation(id: id(12), name: "Flutes", kind: .fluting(FlutingParams(depth: 0.1.inch, ramp: .both, rampLength: 1.inch,
                                                                                       rampShape: .smooth)),
                              shapeIDs: lines.map(\.id), tool: ball)
        return Project(name: "Fluted column", displayUnits: .inch, stock: stock, machine: machine, shapes: lines, operations: [op])
    }

    /// A five-pointed star prism carved to a full ridge with the 90° V-bit: its points are hips, its inside corners
    /// valleys the bit rises up to the ridge.
    static func prismJob() -> Project {
        let star = DesignShape(id: id(3), name: "Star", kind: .star(points: 5, outerRadius: 0.75.inch, innerRadius: 0.2.inch),
                               position: Vec2(1.5.inch, 1.5.inch))
        var bit = lib.tool(number: 6)!
        bit.cutting.spindleRPM = 18000
        let op = CAMOperation(id: id(13), name: "Prism star", kind: .prism(PrismParams()), shapeIDs: [star.id], tool: bit)
        return Project(name: "Prism star", displayUnits: .inch,
                       stock: Stock(width: 3.inch, height: 3.inch, thickness: 0.5.inch, materialName: "Cherry"),
                       shapes: [star], operations: [op])
    }

    static func checkGolden(_ p: Project, _ name: String) throws {
        let job = CAMEngine.generate(p)
        let unexpected = job.issues.filter { $0.severity != .info && !$0.message.contains("rotary axis turns at most") }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.message))")
        let data = GoldenPostTests.post(p, job.toolpaths)
        try GoldenPostTests.check(data, golden: name)
        let issues = GCodeCheck.run(String(decoding: data, as: UTF8.self), toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
        #expect(issues.filter { $0.severity != .info }.isEmpty, "\(issues.map(\.text))")
    }

    @Test func chamferGolden() throws { try Self.checkGolden(Self.chamferJob(), "chamfer-inch") }
    @Test func wrappedFlutingGolden() throws { try Self.checkGolden(Self.flutingJob(), "fluting-wrapped-inch") }
    @Test func prismGolden() throws { try Self.checkGolden(Self.prismJob(), "prism-inch") }

    /// A sign blank with each of the three, saved by format 8: a top-edge chamfer round a raised panel, three flutes
    /// below it ramped at the start only, and a prism diamond, every setting away from its default somewhere.
    static func savedShaped() -> Project {
        let panel = DesignShape(id: id(40), name: "Panel", kind: .rectangle(width: 6.inch, height: 3.inch, cornerRadius: 0),
                                position: Vec2(5.inch, 5.inch))
        let flutes = (0..<3).map { k in
            DesignShape(id: id(41 + k), name: "Flute \(k + 1)", kind: .paths([Polyline([Vec2(0, 0), Vec2(4.inch, 0)], closed: false)]),
                        position: Vec2(3.inch, (1.25 + 0.5 * Double(k)).inch))
        }
        let diamond = DesignShape(id: id(45), name: "Diamond", kind: .polygon(sides: 4, radius: 0.5.inch), position: Vec2(9.inch, 2.inch))
        var v90 = lib.tool(number: 6)!, v60 = lib.tool(number: 5)!, ball = lib.tool(number: 7)!
        v90.cutting.spindleRPM = 18000
        v60.cutting.spindleRPM = 18000
        ball.cutting.spindleRPM = 15000
        let ops = [
            CAMOperation(id: id(50), name: "Panel bevel", kind: .chamfer(ChamferParams(side: .outside, edge: .top, width: 0.1.inch,
                                                                                       passDepth: 0.06.inch, direction: .conventional)),
                         shapeIDs: [panel.id], tool: v90),
            CAMOperation(id: id(51), name: "Flutes", kind: .fluting(FlutingParams(startDepth: 0.02.inch, depth: 0.08.inch, ramp: .start,
                                                                                  rampLength: 0.5.inch, rampPercent: 0.4)),
                         shapeIDs: flutes.map(\.id), tool: ball),
            CAMOperation(id: id(52), name: "Diamond", kind: .prism(PrismParams(depth: 0.2.inch, passDepth: 0.1.inch)),
                         shapeIDs: [diamond.id], tool: v60),
        ]
        return Project(name: "Shaped sign", displayUnits: .inch,
                       stock: Stock(width: 12.inch, height: 8.inch, thickness: 0.75.inch, materialName: "Walnut"),
                       shapes: [panel] + flutes + [diamond], operations: ops,
                       notes: "Saved by format 8: a chamfer, fluting and a prism.")
    }

    @Test func shapedSavedByFormatEightStillDecodesAndPosts() throws {
        let p = try GoldenPostTests.savedProject("shaped-v8", make: Self.savedShaped)
        #expect(p.formatVersion == 8)
        #expect(p == Self.savedShaped())
        try Self.checkGolden(p, "decoded-shaped-v8")
    }

    /// Lettering, with its curves, sharp corners and letters close together: every kind of chamfer and a prism
    /// generate without errors and pass the export checks.
    @Test func lettering() throws {
        let text = DesignShape(kind: .text(TextSpec(string: "NativeCAM", fontName: "Helvetica-Bold", capHeight: 1.inch)),
                               position: Vec2(100, 75))
        let stock = Stock(width: 200, height: 150, thickness: 20, clearanceHeight: 10, plungeHeight: 2)
        var ops: [CAMOperation] = []
        for side in ChamferParams.Side.allCases {
            for edge in ChamferParams.Edge.allCases {
                ops.append(Self.chamfer(ChamferParams(side: side, edge: edge, width: 1.5), [text]))
            }
        }
        ops.append(CAMOperation(name: "Prism", kind: .prism(PrismParams()), shapeIDs: [text.id], tool: Self.vBit60))
        let t0 = Date()
        for op in ops {
            let p = Fixture.project(shapes: [text], ops: [op], stock: stock)
            let job = CAMEngine.generate(p)
            #expect(!job.hasErrors, "\(job.issues.map(\.message))")
            let tp = try #require(job.toolpaths.first)
            #expect(!tp.isEmpty)
            let gcode = String(decoding: GoldenPostTests.post(p, job.toolpaths), as: UTF8.self)
            let issues = GCodeCheck.run(gcode, toolpaths: job.toolpaths, project: p, dialect: .avidMach4)
            #expect(issues.filter { $0.severity == .error }.isEmpty, "\(issues.map(\.text))")
        }
        print("lettering: \(ops.count) toolpaths in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        // A top-edge bevel never cuts past its vector: outside the letters, the letters' tops are untouched; inside
        // them, the material round the letters is.
        let regions = Region.build(from: text.polylines(tolerance: 0.01).filter(\.isClosed), fill: .evenOdd)
        let loops = regions.flatMap(\.loops)
        for side in [ChamferParams.Side.outside, .inside] {
            let p = Fixture.project(shapes: [text], ops: [Self.chamfer(ChamferParams(side: side, edge: .top, width: 1.5), [text])], stock: stock)
            let g = Fixture.simulate(CAMEngine.generate(p).toolpaths, stock: stock, cell: 0.1)
            var worst = 0.0
            let b = text.bounds.insetBy(-3)
            for i in stride(from: 0, to: g.columns, by: 2) {
                for j in stride(from: 0, to: g.rows, by: 2) {
                    let q = Vec2(g.origin.x + Double(i) * g.cellSize, g.origin.y + Double(j) * g.cellSize)
                    guard b.contains(q) else { continue }
                    let inside = regions.contains { $0.contains(q) }
                    guard inside == (side == .outside) else { continue }
                    guard loops.allSatisfy({ $0.closestPoint(to: q).distance > 0.15 }) else { continue }
                    worst = min(worst, Double(g.heights[g.index(i, j)]))
                }
            }
            #expect(worst > -0.05, "\(side): cut \(-worst) mm past the vector")
        }
    }
}
