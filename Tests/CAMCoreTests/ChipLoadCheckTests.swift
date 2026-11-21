import Foundation
import Testing
@testable import CAMCore

/// The chip-load check reads the feeds a toolpath actually cuts at, not only the tool's set feed (#58): the A-rate limit
/// on a wrapped rounding, feeds that follow the load.
struct ChipLoadCheckTests {
    static let endMill = ToolLibrary.starter.tool(number: 1)!

    /// A straight toolpath at 3 mm deep: `stretches` of (length, share of the set feed) end to end along X.
    static func line(_ stretches: [(Double, Double)], tool: Tool = endMill) -> Toolpath {
        var motions: [Motion] = [.feed(Vec3(10, 10, -3), tool.cutting.plungeRate)]
        var x = 10.0
        for (length, share) in stretches {
            x += length
            motions.append(.feed(Vec3(x, 10, -3), share * tool.cutting.feedRate))
        }
        return Toolpath(id: UUID(), name: "Line", tool: tool, spindleRPM: tool.cutting.spindleRPM, start: Vec3(10, 10, 5), motions: motions)
    }

    static func project(_ material: MaterialKind) -> Project {
        Project(name: "Chips", displayUnits: .inch, stock: Stock(width: 12.inch, height: 12.inch, thickness: 0.75.inch, materialKind: material),
                machine: .avidPRO6060)
    }

    static func chipWarnings(_ tp: Toolpath, _ p: Project) -> [String] {
        CAMEngine.chipLoadIssues(tp, project: p).filter { $0.severity == .warning }.map(\.message)
    }

    @Test func aSustainedSlowStretchIsCheckedButACornerDipIsnt() throws {
        // The starter 1/4" upcut's 0.0085 in chip is near hardwood's floor (0.0072 in): at 70% it's 0.0059 in.
        let p = Self.project(.hardwood)
        let minimum = CAMEngine.sustainedLength(Self.endMill)
        #expect(abs(minimum - 4 * 0.25.inch) < 1e-9)
        #expect(Self.chipWarnings(Self.line([(100, 1)]), p).isEmpty)
        // A dip shorter than the stretch that counts (a corner): nothing.
        #expect(Self.chipWarnings(Self.line([(60, 1), (minimum * 0.6, 0.7), (60, 1)]), p).isEmpty)
        // As long as it: the feed, the place and a spindle speed that fixes it.
        let warnings = Self.chipWarnings(Self.line([(60, 1), (minimum + 5, 0.7), (60, 1)]), p)
        #expect(warnings.count == 1)
        let w = try #require(warnings.first)
        #expect(w.hasPrefix("Chip load comes down to 0.0059 in"), "\(w)")
        let place = "X \(LengthUnit.inch.format(70)) Y \(LengthUnit.inch.format(10)) in"
        #expect(w.contains("154.0 in/min") && w.contains(place), "\(w)")
        #expect(w.contains("hardwood") && w.contains("RPM keeps the chip in range"), "\(w)")
        #expect(!w.contains("mm"), "\(w)")
        let sustained = try #require(CAMEngine.sustainedFeed(Self.line([(60, 1), (minimum + 5, 0.7), (60, 1)])))
        #expect(abs(sustained.feed - 0.7 * Self.endMill.cutting.feedRate) < 1e-6)
        // The spindle speed it suggests makes the chip at 154 in/min a quarter into the range.
        let r = ChipLoad.range(.hardwood, diameter: Self.endMill.diameter)
        let rpm = 0.7 * Self.endMill.cutting.feedRate / (2 * (r.lowerBound + (r.upperBound - r.lowerBound) * 0.25))
        #expect(w.contains("\(Int(rpm.rounded()).formatted()) RPM"), "\(w) \(rpm)")
        // Plunges and steep descents have feeds of their own and don't count.
        var plunging = Self.line([(100, 1)])
        plunging.motions.insert(.feed(Vec3(10.5, 10, -20), 0.2 * Self.endMill.cutting.feedRate), at: 1)
        #expect(Self.chipWarnings(plunging, p).isEmpty)
    }

    @Test func aToolpathThatKeepsItsFeedGetsTheSameCheckAsBefore() {
        // Set below the floor: the set feed's warning and its one-click recommendation, as before.
        var slow = Self.endMill
        slow.cutting.feedRate = 100.inch
        let w = Self.chipWarnings(Self.line([(100, 1)], tool: slow), Self.project(.plywood))
        #expect(w.count == 1 && w[0].hasPrefix("Chip load 0.0038 in is below") && w[0].contains("Try "))
    }

    @Test func aScheduledSlowdownIsChecked() throws {
        // A raster pocket's first row is a full-width slot across it. Scheduled without the chart's floor it slows to 70%
        // for all 3.75", too thin a chip for hardwood.
        var params = PocketParams(depth: DepthSettings(cutDepth: 0.125.inch))
        params.strategy = .raster
        let square = FeedSchedulingTests.square
        var op = CAMOperation(kind: .pocket(params), shapeIDs: [square.id], tool: Self.endMill)
        let p = FeedSchedulingTests.project([square], [op], material: .hardwood)
        let plain = CAMEngine.generate(p).toolpaths[0]
        let solid: (Vec2) -> Double? = { _ in 0 }
        let slowed = FeedScheduler.schedule(plain, material: solid, floorZ: -19.05, chipFloor: nil, maxFeed: 10_000, insideArcs: false)
        #expect(slowed.loadFeeds?.varies == true)
        #expect(Self.chipWarnings(plain, p).isEmpty)
        let w = Self.chipWarnings(slowed, p)
        #expect(w.count == 1, "\(w)")
        #expect(w.first?.contains("where Adjust feeds for load slows the feed to 154.0 in/min (from around X ") == true, "\(w)")
        // With the floor, as the job schedules it, nothing slows that far and nothing is flagged.
        op.adjustFeedsForLoad = true
        let job = CAMEngine.generate(FeedSchedulingTests.project([square], [op], material: .hardwood))
        #expect(!job.issues.contains { $0.message.hasPrefix("Chip load") }, "\(job.issues.map(\.message))")
    }

    @Test func anInsideArcCountsAtItsEdgesFeed() throws {
        // A 1" hole's wall finished with its centre slowed by the inside-arc rule: the edge, which makes the chip, moves
        // faster than the centre by 1 over the rule's share.
        let r = Self.endMill.radius, c = Vec2(100, 100), wall = 0.5.inch
        let scheduled = FeedScheduler.schedule(FeedSchedulingTests.lap(wall - r, ccw: true), material: { $0.distance(to: c) > wall - 0.5 ? 0 : -10 },
                                               floorZ: -20, chipFloor: nil, maxFeed: 10_000)
        let arcs = scheduled.motions.filter(\.kind.isArc)
        let factor = FeedScheduler.insideArcFactor(pathRadius: wall - r, toolRadius: r)
        #expect(arcs.count == 2 && arcs.allSatisfy { $0.feed < Self.endMill.cutting.feedRate - 1e-6 })
        #expect(scheduled.loadFeeds?.insideArcs.values.allSatisfy { abs($0 - factor) < 1e-9 } == true)
        #expect(scheduled.loadFeeds?.insideArcs.count == 2)
        // One lap (60 mm) is long enough to count, at the edge's feed.
        let sustained = try #require(CAMEngine.sustainedFeed(scheduled))
        #expect(abs(sustained.feed - arcs[0].feed / factor) < 1e-6, "\(sustained.feed)")
    }

    @Test func theAxisLimitedRoundingIsChecked() throws {
        // The pawn's rounding: its 1/4" end mill is set inside maple's range, but near the axis the rotary axis can't
        // turn fast enough (no Turn speed set: 90° a second) and the cut slows to well under half its feed.
        let p = Project.demoPawn()
        let job = CAMEngine.generate(p)
        let rounding = try #require(job.toolpaths.first)
        #expect(rounding.wrapDiameter != nil)
        let set = rounding.tool.cutting.feedRate
        let sustained = try #require(CAMEngine.sustainedFeed(rounding))
        #expect(sustained.feed < set * 0.5, "\(sustained.feed) of \(set)")
        let chip = sustained.feed / (rounding.spindleRPM * Double(rounding.tool.fluteCount))
        let floor = ChipLoad.range(p.stock.material, diameter: rounding.tool.diameter).lowerBound * 0.9
        #expect(chip < floor, "\(chip / LengthUnit.mmPerInch) in")
        let w = try #require(job.issues.first { $0.operation == rounding.name && $0.message.hasPrefix("Chip load comes down to") })
        #expect(w.severity == .warning)
        #expect(w.message.contains("near the axis, where the rotary axis can't turn fast enough"), "\(w.message)")
        #expect(w.message.contains(" in from the axis") && w.message.contains(" in along the blank") && !w.message.contains("mm"), "\(w.message)")
        #expect(w.message.contains("Turn speed isn't set"), "\(w.message)")
        // A turn speed fast enough for the set feed lets it keep it: no warning.
        var fast = p
        fast.machine.rotary?.turnSpeed = 100_000
        let quick = CAMEngine.generate(fast)
        #expect(!quick.issues.contains { $0.message.hasPrefix("Chip load comes down to") }, "\(quick.issues.map(\.message))")
    }
}
