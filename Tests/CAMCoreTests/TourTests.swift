import Foundation
import Testing
@testable import CAMCore

struct TourTests {
    /// Deterministic scattered points (a fixed LCG, so the test never flakes).
    func scatter(_ n: Int, seed: UInt64 = 7) -> [Vec2] {
        var x = seed
        func next() -> Double { x = x &* 6364136223846793005 &+ 1442695040888963407; return Double(x >> 11) / Double(1 << 53) }
        return (0..<n).map { _ in Vec2(next() * 600, next() * 400) }
    }

    @Test func holesTourBeatsNearestNeighbour() {
        let pts = scatter(150)
        let nn = nearestNeighborOrder(Array(pts.indices), from: .zero, start: { pts[$0] }, end: { pts[$0] })
        let opt = TourOptimizer.order(count: pts.count, from: .zero, start: { pts[$0] }, end: { pts[$0] })
        #expect(Set(opt) == Set(pts.indices) && opt.count == pts.count)
        let a = TourOptimizer.linkLength(nn, origin: .zero, start: { pts[$0] }, end: { pts[$0] })
        let b = TourOptimizer.linkLength(opt, origin: .zero, start: { pts[$0] }, end: { pts[$0] })
        #expect(b < a * 0.93, "NN \(a) mm, optimized \(b) mm")
    }

    @Test func directedPiecesKeepTheirDirectionAndGetShorter() {
        // Short strokes, each cut from its start to its end (like V-carve paths).
        let starts = scatter(120, seed: 3)
        let ends = starts.enumerated().map { i, p in p + Vec2.fromAngle(Double(i) * 0.7, length: 15) }
        let nn = nearestNeighborOrder(Array(starts.indices), from: .zero, start: { starts[$0] }, end: { ends[$0] })
        let opt = TourOptimizer.order(count: starts.count, from: .zero, start: { starts[$0] }, end: { ends[$0] })
        #expect(Set(opt) == Set(starts.indices) && opt.count == starts.count)
        let a = TourOptimizer.linkLength(nn, origin: .zero, start: { starts[$0] }, end: { ends[$0] })
        let b = TourOptimizer.linkLength(opt, origin: .zero, start: { starts[$0] }, end: { ends[$0] })
        #expect(b < a, "NN \(a) mm, optimized \(b) mm")
    }

    @Test func tinyInputsAndTheDemoHoles() {
        #expect(TourOptimizer.order(count: 0, from: .zero, start: { _ in .zero }, end: { _ in .zero }).isEmpty)
        #expect(TourOptimizer.order(count: 1, from: .zero, start: { _ in .zero }, end: { _ in .zero }) == [0])
        // Four corner holes from the home corner: the perimeter walk is already optimal.
        let holes = [Vec2(63.5, 63.5), Vec2(546, 63.5), Vec2(63.5, 393.7), Vec2(546, 393.7)]
        let t = TourOptimizer.order(count: 4, from: .zero, start: { holes[$0] }, end: { holes[$0] })
        let len = TourOptimizer.linkLength(t, origin: .zero, start: { holes[$0] }, end: { holes[$0] })
        #expect(abs(len - (89.8 + 330.2 + 482.5 + 330.2)) < 1) // up the short side, across, down
    }
}
