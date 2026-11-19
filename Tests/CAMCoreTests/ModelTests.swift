import Foundation
import Testing
@testable import CAMCore

struct GeometryTests {
    @Test func polylineAreaAndOrientation() {
        let sq = Polyline([Vec2(0, 0), Vec2(2, 0), Vec2(2, 2), Vec2(0, 2)], closed: true)
        #expect(sq.signedArea == 4)
        #expect(sq.isCounterClockwise)
        #expect(sq.reversed.signedArea == -4)
        #expect(sq.length == 8)
        #expect(sq.contains(Vec2(1, 1)))
        #expect(!sq.contains(Vec2(3, 1)))
        // Duplicate closing point is dropped.
        #expect(Polyline([Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(0, 0)], closed: true).count == 3)
    }

    @Test func regionNestingWithHolesAndIslands() {
        func square(_ c: Double, _ h: Double) -> Polyline {
            Polyline([Vec2(c - h, c - h), Vec2(c + h, c - h), Vec2(c + h, c + h), Vec2(c - h, c + h)], closed: true)
        }
        // Outer, hole, island inside the hole.
        let regions = Region.build(from: [square(50, 50), square(50, 30), square(50, 10)], fill: .evenOdd)
        #expect(regions.count == 2)
        let big = regions.max { $0.area < $1.area }!
        #expect(big.holes.count == 1)
        #expect(abs(big.area - (10000 - 3600)) < 1e-6)
        #expect(big.outer.isCounterClockwise)
        #expect(!big.holes[0].isCounterClockwise)
        #expect(!big.contains(Vec2(50, 50 + 20)))
        #expect(big.contains(Vec2(5, 5)))
    }

    @Test func simplifyKeepsCorners() {
        var pts: [Vec2] = []
        for i in 0...10 { pts.append(Vec2(Double(i), 0)) }
        for i in 1...10 { pts.append(Vec2(10, Double(i))) }
        let s = Polyline(pts, closed: false).simplified(tolerance: 0.01)
        #expect(s.points == [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)])
    }

    @Test func circleFlatteningTolerance() {
        let pts = Curves.circle(center: .zero, radius: 10, tolerance: 0.01)
        // Every chord midpoint within tolerance of the true circle.
        for i in 0..<pts.count {
            let mid = (pts[i] + pts[(i + 1) % pts.count]) * 0.5
            #expect(10 - mid.length <= 0.0100001)
        }
    }
}

struct ToolTests {
    let lib = ToolLibrary.starter

    @Test func vBitGeometry() throws {
        let v = try #require(lib.tool(number: 6)) // 90°, 1/2"
        #expect(abs(v.halfAngleTangent - 1) < 1e-12)
        #expect(abs(v.taperHeight - 0.25.inch) < 1e-9)
        #expect(abs(v.radius(atHeight: 1) - 1) < 1e-9)
        #expect(abs(try #require(v.profileHeight(atRadius: 2)) - 2) < 1e-9)
        #expect(v.profileHeight(atRadius: v.radius + 1) == nil)
    }

    @Test func ballNoseProfile() throws {
        let b = try #require(lib.tool(number: 7))
        let R = b.radius
        #expect(try #require(b.profileHeight(atRadius: 0)) == 0)
        #expect(abs(try #require(b.profileHeight(atRadius: R)) - R) < 1e-9)
        #expect(abs(b.radius(atHeight: R) - R) < 1e-9)
    }

    @Test func chipLoad() throws {
        let t = try #require(lib.tool(number: 1)) // 2 flutes
        #expect(abs(t.chipLoad - t.cutting.feedRate / (t.cutting.spindleRPM * 2)) < 1e-12)
        #expect(abs(t.feedRate(forChipLoad: t.chipLoad) - t.cutting.feedRate) < 1e-9)
    }

    @Test func silhouetteStartsAtTipAndEndsAtShank() throws {
        for tool in lib.tools {
            let s = tool.silhouette()
            #expect(s.first == Vec2(0, 0), "\(tool.name)")
            #expect(abs((s.last?.x ?? 0) - tool.shankDiameter / 2) < 1e-9, "\(tool.name)")
        }
    }
}

struct StockTests {
    @Test func workCoordinates() {
        var s = Stock(width: 100, height: 50, thickness: 20)
        s.xyOrigin = .center
        s.zZero = .materialTop
        #expect(s.toWork(Vec3(50, 25, -5)) == Vec3(0, 0, -5))
        s.zZero = .machineBed
        #expect(s.toWork(Vec3(0, 0, -5)) == Vec3(-50, -25, 15))
        #expect(s.fromWork(s.toWork(Vec3(12, 34, -7))) == Vec3(12, 34, -7))
    }

    @Test func passLevelsAreEvenAndEndAtDepth() {
        let d = DepthSettings(startDepth: 0, cutDepth: 10, passDepth: 3)
        let levels = d.passLevels(toolStepdown: 99)
        #expect(levels.count == 4)
        #expect(abs(levels.last! + 10) < 1e-12)
        #expect(abs(levels[0] + 2.5) < 1e-12)
    }

    @Test func projectRoundTripsThroughJSON() throws {
        let p = Project.demoSign()
        let back = try Project.decode(p.encoded())
        #expect(back == p)
    }

    @Test func textOutlinesFromCoreText() {
        let loops = TextOutliner.outlines(for: TextSpec(string: "HO", fontName: "Helvetica-Bold", capHeight: 50), tolerance: 0.01)
        // H = 1 loop, O = 2 loops.
        #expect(loops.count == 3)
        let b = loops.bounds
        #expect(abs(b.height - 50) < 4) // round letters overshoot the cap height top and bottom
        #expect(abs(b.center.x) < 1e-6 && abs(b.center.y) < 1e-6)
    }
}

struct ChipLoadTests {
    func inches(_ r: ClosedRange<Double>) -> (Double, Double) { (r.lowerBound / 25.4, r.upperBound / 25.4) }

    @Test func freudTableAndInterpolation() {
        let ply = inches(ChipLoad.range(.plywood, diameter: 0.25.inch))
        #expect(abs(ply.0 - 0.006) < 1e-9 && abs(ply.1 - 0.009) < 1e-9)
        // 3/16" sits halfway between the 1/8" and 1/4" rows.
        let mid = inches(ChipLoad.range(.mdf, diameter: 0.1875.inch))
        #expect(abs(mid.0 - 0.0085) < 1e-9 && abs(mid.1 - 0.012) < 1e-9)
        // Clamped beyond the table.
        #expect(inches(ChipLoad.range(.hardwood, diameter: 1.inch)) == inches(ChipLoad.range(.hardwood, diameter: 0.5.inch)))
    }

    @Test func recommendationLowersRPMWhenTheFeedCapBinds() {
        var bit = ToolLibrary.starter.tool(number: 1)!
        bit.diameter = 0.5.inch
        let machine = MachineProfile.avidPRO6060 // 400 IPM cutting cap
        let rec = ChipLoad.recommend(for: bit, material: .mdf, machine: machine)
        #expect(rec.feed <= machine.maxFeedRate + 1e-6)
        #expect(rec.rpm < 18000)
        let chip = rec.feed / (rec.rpm * 2) / 25.4
        #expect(chip >= 0.023 && chip <= 0.027)
        // A 1/4" bit in plywood fits under the cap at full speed.
        let small = ChipLoad.recommend(for: ToolLibrary.starter.tool(number: 1)!, material: .plywood, machine: machine)
        #expect(small.rpm == 18000)
    }

    @Test func compressionFirstPassClearsTheUpcutSection() {
        let d = DepthSettings(cutDepth: 0.77.inch)
        let levels = d.passLevels(toolStepdown: 0.25.inch, firstPassMinimum: 0.27.inch)
        #expect(abs(levels[0] + 0.27.inch) < 1e-9)
        #expect(abs(levels.last! + 0.77.inch) < 1e-9)
        #expect(levels.count == 3)
        // Without the rule the first pass would be shallower than the upcut section.
        #expect(abs(d.passLevels(toolStepdown: 0.25.inch)[0]) < 0.27.inch)
        let compression = ToolLibrary.starter.tool(number: 4)!
        #expect(compression.firstPassMinimum! > compression.upcutLength!)
    }

    @Test func underfedBitIsFlagged() {
        var slow = ToolLibrary.starter.tool(number: 1)!
        slow.cutting.feedRate = 100.inch // 0.0028 in/tooth at 18k
        let shape = DesignShape(kind: .rectangle(width: 50, height: 50, cornerRadius: 0), position: Vec2(100, 75))
        let op = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [shape.id], tool: slow)
        let job = CAMEngine.generate(Project(stock: Stock(width: 200, height: 150, thickness: 19), shapes: [shape], operations: [op]))
        #expect(job.issues.contains { $0.message.contains("below") && $0.message.contains("chip") || $0.message.hasPrefix("Chip load") })
        // The starter defaults are within the chart for plywood.
        let ok = CAMOperation(kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 3))), shapeIDs: [shape.id], tool: ToolLibrary.starter.tool(number: 1)!)
        let job2 = CAMEngine.generate(Project(stock: Stock(width: 200, height: 150, thickness: 19), shapes: [shape], operations: [ok]))
        #expect(!job2.issues.contains { $0.message.hasPrefix("Chip load") })
    }
}
