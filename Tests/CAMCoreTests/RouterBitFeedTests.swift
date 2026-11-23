import Foundation
import Testing
@testable import CAMCore

/// Feeds and speeds for form and dovetail bits (#103): the router-bit chart and its speed limits, where each bit is
/// read, the end-mill chart past 1/2", what the recommendation and the chip-load check say about the chart they used,
/// and the CAM test catalog's goldens and fixtures for them (`Fixtures/golden/*-recommended-inch.tap`,
/// `Fixtures/router-bit-feeds`).
struct RouterBitFeedTests {
    static let machine = MachineProfile.avidPRO6060
    static let fixtures = GoldenPostTests.fixtures.appendingPathComponent("router-bit-feeds")

    static func cutting(_ rpm: Double) -> CuttingData {
        CuttingData(spindleRPM: rpm, feedRate: 100.inch, plungeRate: 30.inch, stepdown: 0.25.inch, stepoverFraction: 0.4)
    }

    /// A 1" roundover: 1/4" radius, 1/2" pilot, 1/4" shank.
    static func roundover(rpm: Double = 18000) -> Tool {
        var t = Tool(number: 21, name: "1\" Roundover", shape: .form, fluteDirection: .straight, diameter: 1.inch,
                     shankDiameter: 0.25.inch, fluteLength: 0.375.inch, cutting: cutting(rpm),
                     form: FormProfile(kind: .roundover, radius: 0.25.inch, pilotDiameter: 0.5.inch))
        t.fitDiameterToShape()
        return t
    }

    /// A 1-1/2" roundover: 1/2" radius, 1/2" pilot, 1/2" shank.
    static func bigRoundover(rpm: Double = 16000) -> Tool {
        var t = Tool(number: 25, name: "1-1/2\" Roundover", shape: .form, fluteDirection: .straight, diameter: 1.5.inch,
                     shankDiameter: 0.5.inch, fluteLength: 0.625.inch, cutting: cutting(rpm),
                     form: FormProfile(kind: .roundover, radius: 0.5.inch, pilotDiameter: 0.5.inch))
        t.fitDiameterToShape()
        return t
    }

    /// A 1/2" dovetail: 14° per side, 1/2" tall, on a 1/4" shank (a 1/4" neck).
    static func dovetail(rpm: Double = 18000) -> Tool {
        Tool(number: 22, name: "1/2\" Dovetail", shape: .dovetail, fluteDirection: .straight, diameter: 0.5.inch,
             shankDiameter: 0.25.inch, fluteLength: 0.5.inch, includedAngle: 28, cutting: cutting(rpm))
    }

    /// A 1-1/2" cove: 1/2" radius, 1/2" pilot.
    static func cove(rpm: Double = 24000, shank: Double = 0.5.inch) -> Tool {
        var t = Tool(number: 23, name: "1-1/2\" Cove", shape: .form, fluteDirection: .straight, diameter: 1.5.inch,
                     shankDiameter: shank, fluteLength: 0.625.inch, cutting: cutting(rpm),
                     form: FormProfile(kind: .cove, radius: 0.5.inch, pilotDiameter: 0.5.inch))
        t.fitDiameterToShape()
        return t
    }

    /// A 4" cove (1-1/2" radius, 1" pilot, 1/2" shank): wider than every chart.
    static func hugeCove(rpm: Double = 18000) -> Tool {
        var t = Tool(number: 26, name: "4\" Cove", shape: .form, fluteDirection: .straight, diameter: 4.inch,
                     shankDiameter: 0.5.inch, fluteLength: 1.625.inch, cutting: cutting(rpm),
                     form: FormProfile(kind: .cove, radius: 1.5.inch, pilotDiameter: 1.inch))
        t.fitDiameterToShape()
        return t
    }

    static func endMill(_ diameter: Double, rpm: Double = 18000) -> Tool {
        Tool(number: 24, name: "End mill", shape: .flatEndMill, diameter: diameter, fluteLength: 1.25.inch, cutting: cutting(rpm))
    }

    static func chip(_ rec: ChipLoad.Recommendation, _ tool: Tool) -> Double {
        rec.feed / (rec.rpm * Double(tool.fluteCount)) / LengthUnit.mmPerInch
    }

    /// The recommendation before #103, for every bit: a quarter into the end-mill chart's range at the chart diameter,
    /// read with the chart's old code, the feed held within the caps by lowering RPM.
    static func legacy(_ tool: Tool, _ material: MaterialKind, thinning: Double = 1, feedLimit: Double? = nil,
                       depth: Double? = nil) -> (rpm: Double, feed: Double) {
        let rows = ChipLoad.table[material]!
        let d = ChipLoad.chartDiameter(tool, depth: depth) / LengthUnit.mmPerInch
        let ds = ChipLoad.diameters
        let lo: Double, hi: Double
        if d <= ds[0] {
            (lo, hi) = rows[0]
        } else if d >= ds[ds.count - 1] {
            (lo, hi) = rows[rows.count - 1]
        } else {
            var k = 0
            while ds[k + 1] < d { k += 1 }
            let t = (d - ds[k]) / (ds[k + 1] - ds[k])
            lo = rows[k].0 + (rows[k + 1].0 - rows[k].0) * t
            hi = rows[k].1 + (rows[k + 1].1 - rows[k].1) * t
        }
        let r = (lo * LengthUnit.mmPerInch)...(hi * LengthUnit.mmPerInch)
        let target = r.lowerBound + (r.upperBound - r.lowerBound) * 0.25
        let z = Double(max(1, tool.fluteCount))
        let k = min(1, max(0.05, thinning))
        let cap = min(machine.maxFeedRate, feedLimit ?? .infinity)
        var rpm = machine.clampRPM(tool.cutting.spindleRPM)
        var feed = target * z * rpm / k
        if feed > cap {
            rpm = machine.clampRPM(cap * k / (z * target))
            feed = min(cap, target * z * rpm / k)
        }
        return (rpm, feed)
    }

    // MARK: Recommendations in maple on the default PRO6060

    /// #103: a 1" roundover in maple used to get 400 in/min at 10,667 RPM from the 1/2" end-mill row. Now it's read on
    /// the router-bit chart: never faster than the 24,000 RPM limit for a 1" bit, and a feed well under the cap,
    /// whatever the spindle was set to.
    @Test func aOneInchRoundoverStaysUnderItsSpeedLimitAndWellUnderTheCap() {
        let before = Self.legacy(Self.roundover(), .hardwood, depth: 0.25.inch)
        #expect(abs(before.feed - Self.machine.maxFeedRate) < 1e-6 && abs(before.rpm - 10667) < 1)
        for rpm in [8000.0, 12000, 18000, 24000, 30000] {
            let tool = Self.roundover(rpm: rpm)
            let rec = ChipLoad.recommendation(for: tool, material: .hardwood, machine: Self.machine, depth: 0.25.inch)
            #expect(rec.rpm <= 24000 + 1e-9, "\(rpm): \(rec.rpm)")
            #expect(rec.feed <= 0.6 * Self.machine.maxFeedRate, "\(rpm): \(rec.feed / 25.4) in/min")
            let chip = Self.chip(rec, tool)
            #expect(abs(chip - 0.0045) < 1e-9, "\(rpm): \(chip)")
            #expect(rec.reading.chart == .routerBit && rec.reading.maxRPM == 24000)
        }
        let rec = ChipLoad.recommendation(for: Self.roundover(), material: .hardwood, machine: Self.machine, depth: 0.25.inch)
        #expect(abs(rec.feed - 162.inch) < 1e-6 && rec.rpm == 18000)
        #expect(rec.reading.source(.inch) == "router-bit chart, 1\" roundover, 3/4\" row")
        #expect(rec.reading.source(.mm).hasPrefix("router-bit chart, 25.4 mm roundover, 19"))
        #expect(rec.reading.notes(.inch) == ["At most 24,000 RPM for a bit 1\" across."])
        #expect(rec.heldBy == nil && rec.reading.crossSectionShare == 1)
    }

    /// A dovetail is read at its widest point, the tip, at every depth, and gets a feed a maker's chart accepts: the chip
    /// is inside both Freud's carbide-tipped range (0.008–0.010" a tooth at 1/2" in hardwood) halved at its thin end.
    @Test func aHalfInchDovetailIsReadAtItsTip() {
        let tool = Self.dovetail()
        for depth in [1.27, 0.25.inch, 0.5.inch, 0.75.inch] {
            #expect(tool.cuttingDiameter(atDepth: depth) == tool.diameter)
            #expect(ChipLoad.chartDiameter(tool, depth: depth) == tool.diameter)
        }
        let rec = ChipLoad.recommendation(for: tool, material: .hardwood, machine: Self.machine, depth: 0.5.inch)
        let chip = Self.chip(rec, tool)
        #expect(chip >= 0.004 - 1e-9 && chip <= 0.010)
        #expect(rec.rpm == 18000 && abs(rec.feed - 144.inch) < 1e-6)
        #expect(rec.feed <= 0.5 * Self.machine.maxFeedRate)
        #expect(rec.reading.source(.inch) == "router-bit chart, 1/2\" dovetail")
        #expect(rec.reading.crossSection == nil && rec.reading.maxRPM == 24000)
        // The end-mill chart's 1/2" row asked for 400 in/min at 10,667 RPM.
        let before = Self.legacy(tool, .hardwood, depth: 0.5.inch)
        #expect(abs(before.feed - Self.machine.maxFeedRate) < 1e-6)
    }

    /// A 1-1/2" cove turns at most 18,000 RPM, however fast its spindle is set, and the chip-load check warns when the
    /// spindle is set faster.
    @Test func aOneAndAHalfInchCoveTurnsAtMost18000() throws {
        for rpm in [12000.0, 18000, 20000, 24000] {
            let rec = ChipLoad.recommendation(for: Self.cove(rpm: rpm), material: .hardwood, machine: Self.machine, depth: 0.5.inch)
            #expect(rec.rpm <= 18000 && rec.reading.maxRPM == 18000, "\(rpm): \(rec.rpm)")
            #expect(rec.feed <= 0.5 * Self.machine.maxFeedRate, "\(rpm): \(rec.feed / 25.4)")
        }
        let reading = ChipLoad.reading(Self.cove(), material: .hardwood, depth: 0.5.inch)
        #expect(reading.source(.inch) == "router-bit chart, 1-1/2\" cove, 3/4\" row")
        // On a 1/2" shank the cove's cut (π/4 × (1/2")²) is smaller than a 1/2" square slot: no cross-section cap.
        #expect(reading.crossSectionShare == 1)
        let area = try #require(reading.crossSection)
        #expect(abs(area - Double.pi / 4 * 12.7 * 12.7) < 0.05)

        let p = Self.job([Self.square()], [CAMOperation(kind: BitShapeTests.profile(.outside, depth: 0.5.inch), shapeIDs: [Self.square().id],
                                                        tool: Self.cove(rpm: 24000))])
        let warnings = CAMEngine.generate(p).issues.filter { $0.severity == .warning }.map(\.message)
        let speed = warnings.filter { $0.hasPrefix("Spindle speed 24,000 RPM is faster than the 18,000 RPM router-bit makers") }
        #expect(speed.count == 1, "\(warnings)")
        #expect(speed.first?.contains("1-1/2\" across") == true)
    }

    /// Form bits whose cut is bigger than a slot as wide and as deep as the shank have their feed cut in proportion,
    /// the spindle slowing to keep the chip: the same cove on a 1/4" shank cuts three times the slot's area.
    @Test func aLargeCrossSectionCapsTheFeedFurther() {
        let small = Self.cove(rpm: 18000, shank: 0.25.inch)
        let rec = ChipLoad.recommendation(for: small, material: .hardwood, machine: Self.machine, depth: 0.5.inch)
        let share = rec.reading.crossSectionShare
        #expect(abs(share - 0.0625 / (Double.pi / 4 * 0.25)) < 0.01)
        #expect(rec.heldBy == .crossSection)
        let full = ChipLoad.recommendation(for: Self.cove(rpm: 18000), material: .hardwood, machine: Self.machine, depth: 0.5.inch)
        #expect(full.heldBy == nil)
        #expect(rec.feed <= full.feed * share + 1e-6)
        // The spindle slows to keep the chip, down to its slowest.
        #expect(rec.rpm == Self.machine.minRPM)
        #expect(rec.reading.notes(.inch).contains { $0.hasPrefix("Feed held to 32% for the profile's cross-section") })
        // Half as deep, the cut is small enough again.
        let shallow = ChipLoad.reading(small, material: .hardwood, depth: 0.2.inch)
        #expect(shallow.crossSectionShare == 1)
    }

    /// End mills up to 1/2", and every other bit the end-mill chart covers, recommend exactly as before: the same
    /// numbers to the last bit, at any speed, material, thinning, loop limit and depth.
    @Test func endMillsAndOtherShapesRecommendExactlyAsBefore() {
        var tools = ToolLibrary.starter.tools.filter { ChipLoad.applies(to: $0) }
        for d in [0.0625, 0.125, 0.1875, 0.25, 0.3125, 0.375, 0.4375, 0.5, 0.625, 0.75, 1.0] {
            tools.append(Self.endMill(d.inch))
            var ball = Self.endMill(d.inch)
            ball.shape = .ballNose
            tools.append(ball)
            var bull = Self.endMill(d.inch)
            bull.shape = .bullNose
            bull.cornerRadius = d.inch / 4
            tools.append(bull)
        }
        tools.append(BitShapeTests.taperedBall())
        tools.append(BitShapeTests.taperedBall(tipRadius: 0.5, perSide: 5, flute: 15, shank: 6.35))
        var count = 0
        for tool in tools {
            for material in MaterialKind.allCases {
                for rpm in [6000.0, 13000, 18000, 24000] {
                    var t = tool
                    t.cutting.spindleRPM = rpm
                    for (thinning, limit) in [(1.0, nil), (0.65, nil), (0.65, 250.inch), (1, 120.inch)] as [(Double, Double?)] {
                        for depth in [nil, 2.0, 0.25.inch] as [Double?] {
                            let old = Self.legacy(t, material, thinning: thinning, feedLimit: limit, depth: depth)
                            let new = ChipLoad.recommend(for: t, material: material, machine: Self.machine, thinning: thinning,
                                                         feedLimit: limit, depth: depth)
                            #expect(new.rpm == old.rpm && new.feed == old.feed, "\(t.name) \(t.shape) \(material) \(rpm)")
                            count += 1
                        }
                    }
                }
            }
        }
        #expect(count > 5000)
        // V-bits, engravers, drills and surfacing bits still have no chart.
        for tool in ToolLibrary.starter.tools where [.vBit, .engraving, .surfacing, .drill].contains(tool.shape) {
            #expect(!ChipLoad.applies(to: tool))
        }
    }

    /// The end-mill chart covers bits up to 1": past 1/2" it holds the 1/2" row (never extrapolated) and says so; wider
    /// than 1" is outside every chart.
    @Test func theEndMillChartHoldsItsHalfInchRowTo1Inch() {
        let half = ChipLoad.range(.hardwood, diameter: 0.5.inch)
        for d in [0.625, 0.75, 1.0] {
            let reading = ChipLoad.reading(Self.endMill(d.inch), material: .hardwood, depth: nil)
            #expect(reading.range == half && !reading.outsideChart && reading.maxRPM == nil)
        }
        let r = ChipLoad.reading(Self.endMill(0.75.inch), material: .hardwood, depth: nil)
        #expect(r.source(.inch) == "end-mill chart, 3/4\" end mill, 1/2\" row")
        let quarter = ChipLoad.reading(ToolLibrary.starter.tool(number: 1)!, material: .hardwood, depth: nil)
        #expect(quarter.source(.inch) == "end-mill chart, 1/4\" end mill")
        #expect(quarter.notes(.inch).isEmpty)
        let wide = ChipLoad.reading(Self.endMill(1.25.inch), material: .hardwood, depth: nil)
        #expect(wide.outsideChart && wide.range == ChipLoad.range(.hardwood, diameter: 1.inch))
    }

    /// Bits wider than every chart are read at the widest row and recommended conservatively, not at the cap: the thin
    /// end of the row, the speed limit (past 3-1/2", a 3-1/2" bit's rim speed at 12,000 RPM) and half the machine's
    /// cutting feed at most.
    @Test func bitsWiderThanEveryChartAreRecommendedConservatively() {
        let wide = Self.endMill(1.25.inch, rpm: 24000)
        let rec = ChipLoad.recommendation(for: wide, material: .mdf, machine: Self.machine)
        #expect(rec.reading.outsideChart && rec.rpm <= 18000)
        #expect(rec.feed <= 0.5 * Self.machine.maxFeedRate + 1e-6 && rec.heldBy == .outsideChart)
        #expect(rec.reading.source(.inch) == "no chart covers a 1-1/4\" end mill: read at the end-mill chart's 1/2\" row")
        let before = Self.legacy(wide, .mdf)
        #expect(abs(before.feed - Self.machine.maxFeedRate) < 1e-6)

        let huge = Self.hugeCove()
        let big = ChipLoad.recommendation(for: huge, material: .hardwood, machine: Self.machine, depth: 1.inch)
        #expect(big.reading.outsideChart && big.reading.maxRPM == 10500 && big.rpm <= 10500)
        #expect(big.feed <= 0.5 * Self.machine.maxFeedRate + 1e-6)
        #expect(ChipLoad.routerSpeedLimit(diameter: 3.5.inch) == 12000 && ChipLoad.routerSpeedLimit(diameter: 3.6.inch) < 12000)
        let notes = big.reading.notes(.inch)
        #expect(notes.first?.hasPrefix("Wider than every chart") == true)
    }

    /// The speed limits by diameter, and the router-bit chart's rows: Freud's carbide-tipped profile-bit maximum at the
    /// thick end, half its minimum at the thin end, never extrapolated past 3/4".
    @Test func theRouterBitChartsRowsAndSpeedLimits() {
        let limits: [(Double, Double)] = [(0.5, 24000), (1, 24000), (1.125, 18000), (1.5, 18000), (1.75, 16000), (2.25, 16000),
                                          (2.5, 14000), (3, 12000), (3.5, 12000)]
        for (d, rpm) in limits { #expect(ChipLoad.routerSpeedLimit(diameter: d.inch) == rpm, "\(d)") }
        let inches = { (r: ClosedRange<Double>) in (r.lowerBound / 25.4, r.upperBound / 25.4) }
        let maple = inches(ChipLoad.routerRange(.hardwood, diameter: 0.75.inch))
        #expect(abs(maple.0 - 0.0045) < 1e-12 && abs(maple.1 - 0.013) < 1e-12)
        let held = inches(ChipLoad.routerRange(.hardwood, diameter: 2.inch))
        #expect(abs(held.0 - maple.0) < 1e-12 && abs(held.1 - maple.1) < 1e-12)
        let ply = inches(ChipLoad.routerRange(.plywood, diameter: 0.5.inch))
        #expect(abs(ply.0 - 0.0035) < 1e-12 && abs(ply.1 - 0.009) < 1e-12)
        for material in MaterialKind.allCases {
            #expect(ChipLoad.routerThinnest[material]!.count == ChipLoad.routerDiameters.count)
            #expect(zip(ChipLoad.routerThinnest[material]!, ChipLoad.routerThickest[material]!).allSatisfy { $0 < $1 })
        }
    }

    /// The chip-load check stops calling ordinary form-bit feeds too thin (150 in/min at 18,000 RPM with a 1" roundover
    /// in maple warned before, against the 1/2" end-mill row), and its messages name the chart.
    @Test func theChipLoadCheckAcceptsOrdinaryFormBitFeeds() throws {
        var tool = Self.roundover()
        tool.cutting.feedRate = 150.inch
        let shape = Self.square()
        let op = CAMOperation(kind: BitShapeTests.profile(.outside, depth: 0.25.inch), shapeIDs: [shape.id], tool: tool)
        let job = CAMEngine.generate(Self.job([shape], [op]))
        let chips = job.issues.filter { $0.message.hasPrefix("Chip load") || $0.message.hasPrefix("Spindle speed") }
        #expect(chips.isEmpty, "\(chips.map(\.message))")
        let oldFloor = ChipLoad.range(.hardwood, diameter: 1.inch).lowerBound * 0.8
        #expect(tool.chipLoad < oldFloor)

        // Far too slow, it still warns, naming the chart and recommending from it.
        tool.cutting.feedRate = 40.inch
        tool.cutting.spindleRPM = 24000
        let slow = CAMOperation(kind: BitShapeTests.profile(.outside, depth: 0.25.inch), shapeIDs: [shape.id], tool: tool)
        let warned = CAMEngine.generate(Self.job([shape], [slow])).issues.map(\.message).filter { $0.hasPrefix("Chip load") }
        let w = try #require(warned.first)
        #expect(w.contains("range for this bit in hardwood (router-bit chart, 1\" roundover, 3/4\" row)"), "\(w)")
        #expect(w.contains("Try 216 in/min at 24000 RPM. At most 24,000 RPM for a bit 1\" across."), "\(w)")
    }

    /// A form bit whose widest point is above the depth cut is read at its widest at that depth (`cuttingDiameter`), but
    /// its speed limit is its full diameter's: the whole head turns, cutting or not.
    @Test func aFormBitIsReadAtItsWidestAtTheDepthButLimitedByItsFullDiameter() {
        let tool = Self.bigRoundover()
        let depth = 0.125.inch
        let r = 0.5.inch, h = depth
        let widest = 0.5.inch + 2 * (r - (r * r - h * h).squareRoot())
        #expect(abs(tool.cuttingDiameter(atDepth: depth) - widest) < 0.01)
        #expect(tool.cuttingDiameter(atDepth: 0.5.inch) == tool.diameter && tool.cuttingDiameter(atDepth: 2.inch) == tool.diameter)
        let reading = ChipLoad.reading(tool, material: .hardwood, depth: depth)
        #expect(abs(reading.diameter - widest) < 0.01 && reading.fullDiameter == tool.diameter)
        #expect(reading.maxRPM == 18000)
        #expect(reading.source(.inch).hasPrefix("router-bit chart, 1-1/2\" roundover read at 0.532\", its widest at this depth"))
    }

    // MARK: Catalog: goldens at recommended feeds (Avid Mach4)

    static func square(_ side: Double = 3.inch) -> DesignShape {
        DesignShape(id: BitShapeFixtureTests.id(60), name: "Board", kind: .rectangle(width: side, height: side, cornerRadius: 0),
                    position: Vec2(2.5.inch, 2.5.inch))
    }

    /// A job in maple on the default PRO6060, in inches.
    static func job(_ shapes: [DesignShape], _ ops: [CAMOperation], name: String = "Router bit feeds") -> Project {
        BitShapeFixtureTests.project(name, units: .inch,
                                     stock: Stock(width: 6.inch, height: 5.inch, thickness: 0.75.inch, materialName: "Maple", materialKind: .hardwood),
                                     shapes: shapes, ops: ops)
    }

    /// `tool` set to its recommendation for `depth` in maple.
    static func recommended(_ tool: Tool, depth: Double) -> Tool {
        var t = tool
        let rec = ChipLoad.recommendation(for: t, material: .hardwood, machine: machine, depth: depth)
        t.cutting.feedRate = rec.feed
        t.cutting.spindleRPM = rec.rpm
        return t
    }

    /// A 1" roundover round a 3" board, 1/4" deep, at Use Recommended's feed and speed.
    static func roundoverProfile() -> Project {
        let tool = BitShapeFixtureTests.numbered(recommended(roundover(), depth: 0.25.inch), 5, id: 61)
        let op = CAMOperation(id: BitShapeFixtureTests.id(62), name: "Round over", kind: BitShapeTests.profile(.outside, depth: 0.25.inch),
                              shapeIDs: [square().id], tool: tool)
        return job([square()], [op], name: "Roundover at recommended feeds")
    }

    /// A 1/2" dovetail pin round a 3" board, 3/8" deep, at Use Recommended's feed and speed.
    static func dovetailProfile() -> Project {
        let tool = BitShapeFixtureTests.numbered(recommended(dovetail(), depth: 0.375.inch), 4, id: 63)
        let op = CAMOperation(id: BitShapeFixtureTests.id(64), name: "Dovetail pin", kind: BitShapeTests.profile(.outside, depth: 0.375.inch),
                              shapeIDs: [square().id], tool: tool)
        return job([square()], [op], name: "Dovetail at recommended feeds")
    }

    /// The posted S and F words (cutting feeds only: the plunge has its own).
    static func words(_ gcode: Data, _ letter: Character) -> Set<String> {
        let text = String(decoding: gcode, as: UTF8.self)
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("(") {
            for word in line.split(separator: " ") where word.first == letter { out.insert(String(word.dropFirst())) }
        }
        return out
    }

    @Test func roundoverAtRecommendedFeedsGolden() throws {
        let p = Self.roundoverProfile()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors && job.toolpaths.allSatisfy { !$0.motions.isEmpty })
        let chips = job.issues.filter { $0.message.hasPrefix("Chip load") || $0.message.hasPrefix("Spindle speed") }
        #expect(chips.isEmpty, "\(chips.map(\.message))")
        let g = GoldenPostTests.post(p)
        #expect(Self.words(g, "S") == ["18000"])
        #expect(Self.words(g, "F").contains("162.0"), "\(Self.words(g, "F"))")
        try GoldenPostTests.check(g, golden: "roundover-recommended-inch")
    }

    @Test func dovetailAtRecommendedFeedsGolden() throws {
        let p = Self.dovetailProfile()
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors && job.toolpaths.allSatisfy { !$0.motions.isEmpty })
        let chips = job.issues.filter { $0.message.hasPrefix("Chip load") || $0.message.hasPrefix("Spindle speed") }
        #expect(chips.isEmpty, "\(chips.map(\.message))")
        let g = GoldenPostTests.post(p)
        #expect(Self.words(g, "S") == ["18000"])
        #expect(Self.words(g, "F").contains("144.0"), "\(Self.words(g, "F"))")
        try GoldenPostTests.check(g, golden: "dovetail-recommended-inch")
    }

    // MARK: Catalog: fixtures

    /// Loads a fixture, writing a missing one from `make` in update mode (never replacing one).
    static func fixture(_ name: String, make: () throws -> Data) throws -> Data {
        let url = fixtures.appendingPathComponent(name)
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            try make().write(to: url)
        }
        return try Data(contentsOf: url)
    }

    /// A tool library written for this test (NativeCAM's JSON, not a vendor's) holding a 1" roundover, a 1/2" dovetail,
    /// a 1-1/2" cove and a 3/4" end mill: imported, each gets its chart, speed limit and recommendation.
    @Test func aToolLibraryOfFormBitsImportsWithTheirCharts() throws {
        let data = try Self.fixture("form-bit-library.json") {
            let tools = [Self.roundover(), Self.dovetail(), Self.cove(), Self.endMill(0.75.inch)].enumerated().map { i, t in
                BitShapeFixtureTests.numbered(t, t.number, id: 70 + i)
            }
            return try ToolLibrary(tools: tools).encoded()
        }
        let imported = try ToolLibraryImporter.load(data: data)
        #expect(imported.format == .nativeCAM && imported.skipped.isEmpty)
        let tools = imported.tools.map(\.tool)
        #expect(tools.map(\.shape) == [.form, .dovetail, .form, .flatEndMill])
        let recs = tools.map { ChipLoad.recommendation(for: $0, material: .hardwood, machine: Self.machine) }
        let sources = recs.map { $0.reading.source(.inch) }
        #expect(sources == ["router-bit chart, 1\" roundover, 3/4\" row", "router-bit chart, 1/2\" dovetail",
                            "router-bit chart, 1-1/2\" cove, 3/4\" row", "end-mill chart, 3/4\" end mill, 1/2\" row"])
        #expect(recs[0].rpm <= 24000 && recs[0].feed <= 0.6 * Self.machine.maxFeedRate)
        #expect(recs[1].reading.diameter == tools[1].diameter && recs[1].feed <= 0.5 * Self.machine.maxFeedRate)
        #expect(recs[2].rpm <= 18000)
        let old = Self.legacy(tools[3], .hardwood)
        #expect(recs[3].rpm == old.rpm && recs[3].feed == old.feed)
    }

    /// Edge case: a 4" cove and a 1-1/4" end mill, wider than every chart. Each is recommended conservatively, the
    /// cove's 18,000 RPM is over the 10,500 its size allows, and the check says no chart covers them.
    @Test func bitsWiderThanEveryChartInAJob() throws {
        let data = try Self.fixture("wider-than-every-chart.nativecam") {
            let board = DesignShape(id: BitShapeFixtureTests.id(65), name: "Panel", kind: .rectangle(width: 8.inch, height: 6.inch, cornerRadius: 0),
                                    position: Vec2(6.inch, 5.inch))
            let cove = BitShapeFixtureTests.numbered(Self.hugeCove(rpm: 18000), 6, id: 66)
            var mill = BitShapeFixtureTests.numbered(Self.endMill(1.25.inch, rpm: 18000), 7, id: 67)
            mill.cutting.feedRate = 60.inch
            let ops = [
                CAMOperation(id: BitShapeFixtureTests.id(68), name: "Big cove", kind: BitShapeTests.profile(.outside, depth: 0.75.inch),
                             shapeIDs: [board.id], tool: cove),
                CAMOperation(id: BitShapeFixtureTests.id(69), name: "Wide mill", kind: BitShapeTests.profile(.outside, depth: 0.25.inch),
                             shapeIDs: [board.id], tool: mill),
            ]
            let p = BitShapeFixtureTests.project("Wider than every chart", units: .inch,
                                                 stock: Stock(width: 12.inch, height: 10.inch, thickness: 1.5.inch, materialName: "Maple", materialKind: .hardwood),
                                                 shapes: [board], ops: ops)
            return try p.encoded()
        }
        let p = try Project.decode(data)
        #expect(p.formatVersion == 15)
        for op in p.operations {
            let rec = ChipLoad.recommendation(for: op.tool, material: p.stock.material, machine: p.machine, depth: op.kind.requestedDepth)
            #expect(rec.reading.outsideChart, "\(op.name)")
            #expect(rec.feed <= 0.5 * p.machine.maxFeedRate + 1e-6, "\(op.name): \(rec.feed / 25.4)")
            #expect(rec.rpm <= (rec.reading.maxRPM ?? 0), "\(op.name)")
        }
        let messages = CAMEngine.generate(p).issues.map(\.message)
        let speed = messages.filter { $0.hasPrefix("Spindle speed 18,000 RPM is faster than the 10,500 RPM NativeCAM allows a 4\" cove") }
        #expect(speed.count == 1, "\(messages)")
        let chips = messages.filter { $0.hasPrefix("Chip load") }
        #expect(chips.contains { $0.contains("no chart covers a 1-1/4\" end mill") }, "\(chips)")
    }

    /// Edge case: a 1-1/2" roundover cut only 1/8" deep, so its widest point is above the cut. It's read at its widest at
    /// that depth (about 0.53") but kept to the 18,000 RPM of its full 1-1/2".
    @Test func aFormBitWhoseWidestIsAboveTheDepthCut() throws {
        let data = try Self.fixture("form-widest-above-depth.nativecam") {
            let shape = DesignShape(id: BitShapeFixtureTests.id(75), name: "Board", kind: .rectangle(width: 3.inch, height: 3.inch, cornerRadius: 0),
                                    position: Vec2(3.inch, 3.inch))
            let tool = BitShapeFixtureTests.numbered(Self.bigRoundover(rpm: 22000), 8, id: 76)
            let op = CAMOperation(id: BitShapeFixtureTests.id(77), name: "Light roundover", kind: BitShapeTests.profile(.outside, depth: 0.125.inch),
                                  shapeIDs: [shape.id], tool: tool)
            let p = BitShapeFixtureTests.project("Widest above the cut", units: .inch,
                                                 stock: Stock(width: 6.inch, height: 6.inch, thickness: 0.75.inch, materialName: "Maple", materialKind: .hardwood),
                                                 shapes: [shape], ops: [op])
            return try p.encoded()
        }
        let p = try Project.decode(data)
        let op = try #require(p.operations.first)
        let job = CAMEngine.generate(p)
        let tp = try #require(job.toolpaths.first)
        let deepest = try #require(tp.cuttingExtents.map { -$0.min.z })
        #expect(abs(deepest - 0.125.inch) < 1e-6)
        let reading = ChipLoad.reading(op.tool, material: .hardwood, depth: deepest)
        #expect(reading.diameter < 0.55.inch && abs(reading.fullDiameter - 1.5.inch) < 1e-9)
        #expect(reading.maxRPM == 18000)
        let rec = ChipLoad.recommendation(for: op.tool, material: .hardwood, machine: p.machine, depth: deepest)
        #expect(rec.rpm == 18000)
        let speed = job.issues.map(\.message).filter { $0.hasPrefix("Spindle speed 22,000 RPM is faster than the 18,000 RPM") }
        #expect(speed.count == 1)
    }
}
