import Foundation

/// Orders pieces of work to shorten the air travel between them.
///
/// Nearest-neighbour first (what most CAM ships), then local search until nothing improves: Or-opt moves chains of
/// one to three pieces elsewhere in the sequence, and, when every piece starts where it ends (holes, the entry
/// points of closed loops), 2-opt reverses runs of the sequence. The tour is open: it starts at `origin` and
/// doesn't return. NN alone is typically 15–25% longer than optimal; this closes most of that gap.
enum TourOptimizer {
    /// Indices into the pieces in cutting order. `start(i)`/`end(i)` are where piece i begins and finishes.
    static func order(count n: Int, from origin: Vec2, start: (Int) -> Vec2, end: (Int) -> Vec2,
                      maxSearch: Int = 3000) -> [Int] {
        guard n > 1 else { return Array(0..<n) }
        let s = (0..<n).map(start), e = (0..<n).map(end)
        // Nearest neighbour.
        var used = [Bool](repeating: false, count: n)
        var tour: [Int] = []
        tour.reserveCapacity(n)
        var cursor = origin
        for _ in 0..<n {
            var best = -1, bestD = Double.infinity
            for i in 0..<n where !used[i] {
                let d = s[i].distanceSquared(to: cursor)
                if d < bestD { bestD = d; best = i }
            }
            used[best] = true
            tour.append(best)
            cursor = e[best]
        }
        guard n <= maxSearch else { return tour }
        let symmetric = (0..<n).allSatisfy { s[$0].isApprox(e[$0], tolerance: 1e-9) }
        improve(&tour, origin: origin, s: s, e: e, symmetric: symmetric)
        return tour
    }

    /// Length of the open tour's links.
    static func linkLength(_ tour: [Int], origin: Vec2, start: (Int) -> Vec2, end: (Int) -> Vec2) -> Double {
        var cursor = origin, total = 0.0
        for i in tour { total += cursor.distance(to: start(i)); cursor = end(i) }
        return total
    }

    private static func improve(_ tour: inout [Int], origin: Vec2, s: [Vec2], e: [Vec2], symmetric: Bool) {
        let n = tour.count
        // Link from the piece at position k-1 (or the origin) to the one at position k; nothing after the last.
        func endAt(_ k: Int) -> Vec2 { k < 0 ? origin : e[tour[k]] }
        func link(_ a: Vec2, _ k: Int) -> Double { k >= n ? 0 : a.distance(to: s[tour[k]]) }
        var improved = true
        var passes = 0
        while improved && passes < 50 {
            improved = false
            passes += 1
            if symmetric {
                // 2-opt: reverse tour[i...j].
                for i in 0..<(n - 1) {
                    for j in (i + 1)..<n {
                        let before = link(endAt(i - 1), i) + link(endAt(j), j + 1)
                        let after = endAt(i - 1).distance(to: s[tour[j]]) + (j + 1 < n ? s[tour[i]].distance(to: s[tour[j + 1]]) : 0)
                        if after < before - 1e-9 {
                            tour[i...j].reverse()
                            improved = true
                        }
                    }
                }
            }
            // Or-opt: move a chain of 1–3 pieces (kept in its direction) between two others.
            for k in 1...3 where k < n {
                var i = 0
                while i + k <= n {
                    let first = tour[i], last = tour[i + k - 1]
                    let prev = endAt(i - 1)
                    let removeGain = link(prev, i) + link(e[last], i + k) - link(prev, i + k)
                    var bestDelta = -1e-9
                    var bestJ: Int?
                    // Insert after position j (j = -1: at the front), with j outside the chain.
                    for j in -1..<n where j < i - 1 || j >= i + k {
                        let a = endAt(j)
                        let b: Vec2? = j + 1 < n ? s[tour[j + 1]] : nil
                        let added = a.distance(to: s[first]) + (b.map { e[last].distance(to: $0) } ?? 0) - (b.map { a.distance(to: $0) } ?? 0)
                        if added - removeGain < bestDelta { bestDelta = added - removeGain; bestJ = j }
                    }
                    if let j = bestJ {
                        let chain = Array(tour[i..<(i + k)])
                        tour.removeSubrange(i..<(i + k))
                        tour.insert(contentsOf: chain, at: j < i ? j + 1 : j + 1 - k)
                        improved = true
                    } else {
                        i += 1
                    }
                }
            }
        }
    }
}
