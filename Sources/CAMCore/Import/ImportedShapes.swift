import Foundation

extension ImportResult {
    /// The design shapes an import adds: one per layer, named "<name> – <layer>" and on that layer, when the file has
    /// more than one; otherwise one shape, on the file's layer if it has one. Points (DXF POINTs) become a separate
    /// shape of small circles beside their layer's, ready for a Drill toolpath. Shapes keep their file coordinates
    /// when the whole drawing fits on `stock`; otherwise they move together so the drawing is centred on it.
    public func shapes(name: String, stock: Stock) -> [DesignShape] {
        func marks(_ pts: [Vec2]) -> [Polyline] {
            pts.map { Polyline(Curves.circle(center: $0, radius: 0.5, tolerance: 0.01), closed: true) }
        }
        let all = polylines + marks(points)
        guard !all.isEmpty else { return [] }
        let b = all.bounds
        let fits = stock.bounds.insetBy(-0.001).contains(b.min) && stock.bounds.insetBy(-0.001).contains(b.max)
        let shift = fits ? Vec2.zero : Vec2(stock.width / 2, stock.height / 2) - b.center
        func place(_ polys: [Polyline], _ name: String, _ layer: String) -> DesignShape? {
            guard !polys.isEmpty else { return nil }
            let c = polys.bounds.center
            return DesignShape(name: name, kind: .paths(polys.transformed(.translation(-c))), position: c + shift, layer: layer)
        }
        let groups = layerGroups
        guard groups.count > 1 else {
            let layer = groups.first?.layer ?? "Default"
            return [place(polylines, name, layer), place(marks(points), "\(name) points", layer)].compactMap { $0 }
        }
        return groups.flatMap { g -> [DesignShape] in
            let layer = g.layer ?? "Default"
            let title = "\(name) – \(layer)"
            return [place(g.polylines, title, layer), place(marks(g.points), "\(title) points", layer)].compactMap { $0 }
        }
    }
}
