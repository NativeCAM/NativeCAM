import Foundation

/// Finds the points placed on shapes' outlines by hand (`ContourMark`: a profile's tabs placed by hand and its chosen
/// start points) on the design, and makes new ones.
public enum ContourMarks {
    /// How far a mark may be from its shape's drawn outline, design mm, and still be on it: max(1 mm, the bit's
    /// radius). A mark on an edge survives small edits to the shape (it slides to the nearest point of the new outline);
    /// one further off is no longer on its shape, and is kept in the file but left off the cut.
    public static func tolerance(toolRadius: Double) -> Double { max(1, toolRadius) }

    /// An operation's shapes with their drawn outlines, design coordinates.
    public struct Index: Sendable {
        struct Entry: Sendable {
            var shape: DesignShape
            var outlines: [Polyline]
            var bounds: Rect2
            var inverse: Transform2D?
        }
        let entries: [Entry]

        public init(_ shapes: [DesignShape], flatten: Double) {
            entries = shapes.filter { !$0.isKeepOut }.map { shape in
                let outlines = shape.polylines(tolerance: flatten).filter { $0.isClosed && $0.count >= 3 }
                return Entry(shape: shape, outlines: outlines, bounds: outlines.bounds, inverse: shape.transform.inverted)
            }
        }

        /// The point on the mark's shape's drawn outline nearest the mark (design XY), or nil when the shape isn't one
        /// of these or its outline is now further than `tolerance` from the mark.
        public func resolve(_ mark: ContourMark, tolerance: Double) -> Vec2? {
            guard let e = entries.first(where: { $0.shape.id == mark.shapeID }) else { return nil }
            let p = e.shape.transform.apply(mark.point)
            var best: (Vec2, Double)?
            for outline in e.outlines {
                let c = outline.closestPoint(to: p)
                if c.distance < (best?.1 ?? .infinity) { best = (c.point, c.distance) }
            }
            guard let best, best.1 <= tolerance + 1e-9 else { return nil }
            return best.0
        }

        /// Which of its shape's outlines a mark is on (an index into them), nil when it isn't on its shape.
        public func loop(of mark: ContourMark, tolerance: Double) -> Int? {
            guard let e = entries.first(where: { $0.shape.id == mark.shapeID }) else { return nil }
            let p = e.shape.transform.apply(mark.point)
            var best: (Int, Double)?
            for (i, outline) in e.outlines.enumerated() {
                let d = outline.closestPoint(to: p).distance
                if d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            guard let best, best.1 <= tolerance + 1e-9 else { return nil }
            return best.0
        }

        /// A mark at the drawn outline nearest `p` (design XY), if one is within `within`: on that outline, in its
        /// shape's own coordinates. With `snap`, on one of the outline's vertices when it's within `snap` of the point.
        /// `including` limits it to some shapes (by ID).
        public func mark(near p: Vec2, within: Double, snap: Double = 0, including: (UUID) -> Bool = { _ in true }) -> ContourMark? {
            var best: (ContourMark, Double)?
            for e in entries where including(e.shape.id) && e.bounds.contains(p, tolerance: within) {
                guard let inverse = e.inverse else { continue }
                for outline in e.outlines {
                    let c = outline.closestPoint(to: p)
                    if c.distance <= within, c.distance < (best?.1 ?? .infinity) - 1e-9 {
                        var at = c.point
                        if snap > 0, let v = outline.points.min(by: { $0.distance(to: c.point) < $1.distance(to: c.point) }),
                           v.distance(to: c.point) <= snap {
                            at = v
                        }
                        best = (ContourMark(shapeID: e.shape.id, point: inverse.apply(at)), c.distance)
                    }
                }
            }
            return best?.0
        }

        /// A point on each shape's drawn outline, by shape ID: the first point of its first outline.
        public var outlinePoints: [(id: UUID, point: Vec2)] {
            entries.compactMap { e in e.outlines.first?.points.first.map { (e.shape.id, $0) } }
        }

        /// The drawn outline nearest `p`, design XY, if one is within `within`.
        public func outline(near p: Vec2, within: Double) -> Polyline? {
            var best: (Polyline, Double)?
            for e in entries where e.bounds.contains(p, tolerance: within) {
                for outline in e.outlines {
                    let d = outline.closestPoint(to: p).distance
                    if d <= within, d < (best?.1 ?? .infinity) { best = (outline, d) }
                }
            }
            return best?.0
        }
    }

    /// How many of `marks` are on their shapes among `shapes`.
    public static func matchedCount(_ marks: [ContourMark], shapes: [DesignShape], toolRadius: Double, flatten: Double = 0.01) -> Int {
        guard !marks.isEmpty else { return 0 }
        let index = Index(shapes, flatten: flatten)
        let tol = tolerance(toolRadius: toolRadius)
        return marks.filter { index.resolve($0, tolerance: tol) != nil }.count
    }
}

// MARK: Editing (the canvas's clicks and drags)

public extension ProfileParams {
    /// The tabs placed by hand as marks, or, before the first edit, the evenly spaced ones the toolpath cut (`shown`):
    /// the first edit starts from what the user sees.
    func placedTabs(shown: [TabMark]) -> [ContourMark] { tabs.placed ?? shown.filter(\.cut).map(\.mark) }

    /// These settings with a tab placed at `mark` (tabs turn on and are placed by hand from now on).
    func addingTab(_ mark: ContourMark, shown: [TabMark]) -> ProfileParams {
        var q = self
        q.tabs.placed = placedTabs(shown: shown) + [mark]
        q.tabs.enabled = true
        return q
    }

    /// These settings without the placed tab nearest `tab` on its shape (within `tolerance`, shape coordinates).
    func removingTab(_ tab: TabMark, shown: [TabMark], tolerance: Double) -> ProfileParams {
        var list = placedTabs(shown: shown)
        let same = list.indices.filter { list[$0].shapeID == tab.shapeID }
        if let k = same.min(by: { list[$0].point.distance(to: tab.localPoint) < list[$1].point.distance(to: tab.localPoint) }),
           list[k].point.distance(to: tab.localPoint) <= tolerance {
            list.remove(at: k)
        }
        var q = self
        q.tabs.placed = list
        return q
    }

    /// These settings with `tab` slid to `mark`.
    func movingTab(_ tab: TabMark, to mark: ContourMark, shown: [TabMark], tolerance: Double) -> ProfileParams {
        removingTab(tab, shown: shown, tolerance: tolerance).addingTab(mark, shown: [])
    }

    /// These settings with evenly spaced tabs again.
    func resettingTabs() -> ProfileParams {
        var q = self
        q.tabs.placed = nil
        return q
    }

    /// These settings with the loop `mark` is on starting there, in place of any start already chosen on that loop
    /// (`clear`: just without one, so it starts nearest the tool again). `index` finds the loops.
    func settingStart(_ mark: ContourMark, clear: Bool = false, index: ContourMarks.Index, tolerance: Double) -> ProfileParams {
        let loop = index.loop(of: mark, tolerance: tolerance)
        var list = (startPoints ?? []).filter { m in
            !(m.shapeID == mark.shapeID && (loop == nil || index.loop(of: m, tolerance: tolerance) == loop))
        }
        if !clear { list.append(mark) }
        var q = self
        q.startPoints = list.isEmpty ? nil : list
        return q
    }
}
