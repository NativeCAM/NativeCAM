import Foundation

/// A filled area: one counter-clockwise outer boundary with zero or more clockwise holes.
public struct Region: Hashable, Codable, Sendable {
    public var outer: Polyline
    public var holes: [Polyline]

    public init(outer: Polyline, holes: [Polyline] = []) {
        self.outer = outer.oriented(counterClockwise: true)
        self.holes = holes.map { $0.oriented(counterClockwise: false) }
    }

    /// All boundary loops (outer first).
    public var loops: [Polyline] { [outer] + holes }
    public var area: Double { outer.area - holes.reduce(0) { $0 + $1.area } }
    public var bounds: Rect2 { outer.bounds }

    public func contains(_ p: Vec2) -> Bool {
        outer.contains(p) && !holes.contains { $0.contains(p) }
    }

    /// Offsets the region (negative = shrink) and regroups the result into regions.
    public func offset(by delta: Double, arcTolerance: Double = 0.005) -> [Region] {
        Region.build(from: Clipper.offset(loops, delta: delta, arcTolerance: arcTolerance), fill: .nonZero)
    }

    /// Groups closed loops into regions by nesting depth: even depth = outer boundary, odd = hole.
    /// `fill` is applied first so overlapping or self-intersecting input is resolved.
    public static func build(from loops: [Polyline], fill: Clipper.FillRule = .evenOdd) -> [Region] {
        let closed = loops.filter { $0.isClosed && $0.count >= 3 && $0.area > 1e-9 }
        guard !closed.isEmpty else { return [] }
        let cleaned = Clipper.union(closed, fill: fill)
        return nest(cleaned)
    }

    /// Nesting without any boolean clean-up (input must already be non-overlapping).
    public static func nest(_ loops: [Polyline]) -> [Region] {
        let sorted = loops.filter { $0.count >= 3 }.sorted { $0.area > $1.area }
        var parent = [Int](repeating: -1, count: sorted.count)
        var depth = [Int](repeating: 0, count: sorted.count)
        let probes = sorted.map { $0.interiorPoint() ?? $0.points[0] }
        let boxes = sorted.map(\.bounds)
        for i in sorted.indices {
            // Smallest earlier (larger) loop containing loop i is its parent.
            var j = i - 1
            while j >= 0 {
                if boxes[j].contains(probes[i]) && sorted[j].contains(sorted[i].points[0]) && sorted[j].contains(probes[i]) {
                    parent[i] = j
                    depth[i] = depth[j] + 1
                    break
                }
                j -= 1
            }
        }
        var regions: [Int: Region] = [:]
        var order: [Int] = []
        for i in sorted.indices where depth[i] % 2 == 0 {
            regions[i] = Region(outer: sorted[i])
            order.append(i)
        }
        for i in sorted.indices where depth[i] % 2 == 1 {
            let p = parent[i]
            if p >= 0, regions[p] != nil { regions[p]!.holes.append(sorted[i].oriented(counterClockwise: false)) }
        }
        return order.compactMap { regions[$0] }
    }
}
