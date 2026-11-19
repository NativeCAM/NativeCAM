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
        let t = try #require(lib.tool(number: 1)) // 150 ipm, 18k, 2 flutes
        #expect(abs(t.chipLoad - (150.0.inch / 36000)) < 1e-12)
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
