import Foundation

/// How far flutes that follow a 3D model reach down through the material actually left above them (#203).
///
/// A flute on a model goes its depth below the model's surface, which is all the bit's reach has to cover once a 3D
/// finish has cleared the stock over the model (#139). Nothing makes sure one has: cut before the finish, or on a model
/// sunk below the material's top, the bit goes down through whatever stock is still over the model as well. So the job
/// measures, before the flutes cut, how thick the stock still over the model is under each of their moves: the material
/// model's cell there (on a flat job its coarse material model, on a wrapped rotary job a coarse radial one carved by the
/// wrapped toolpaths before them, 3D rotary roughing, finishing and rounding included) less the model's own surface
/// under the cell's centre (`FlutingGenerator.Surface`'s probe, which has no width). The flute's reach is its depth plus
/// the thickest of that; the tool-reach check in `CAMEngine.validate` takes it in place of the flute depth alone. Both
/// heights are taken at the same point, so where a finish has cleared the model, the model's slope and the grid's
/// coarseness leave only the finish's allowance and scallops.
enum FluteReach {
    /// Whether `op` is flutes that follow a 3D model.
    static func follows(_ op: CAMOperation) -> Bool {
        if case let .fluting(f) = op.kind { return f.surfaceModelID != nil }
        return false
    }

    /// Stock this thick over the model or less is taken as cleared (a finish's allowance and scallops): the reach stays
    /// the flute depth, as it was before #203. mm.
    static let slack = 0.5

    /// The wrapped job's radial material model: its cell size (mm) and most cells.
    static let radialCell = 1.5
    static let radialCells = 120_000

    /// Spacing of the points measured along the flutes' feed moves, mm (at least the material model's cell).
    static let spacing = 0.5

    /// Visits points along the feed moves of `tp` (lines and arcs, not rapids), at most `step` apart.
    static func forEachCuttingPoint(_ tp: Toolpath, step: Double, _ body: (Vec3) -> Void) {
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            if m.kind.isArc {
                body(s)
                for q in m.samples(from: s, maxStep: step) { body(q) }
            } else {
                let n = max(1, Int((s.distance(to: m.end) / step).rounded(.up)))
                for k in 0...n { body(s + (m.end - s) * (Double(k) / Double(n))) }
            }
        }
    }

    /// The surface of the model the flutes of `op` follow, or nil (not following one, or it's refused).
    static func surface(_ op: CAMOperation, project: Project) -> FlutingGenerator.Surface? {
        guard case let .fluting(f) = op.kind, let id = f.surfaceModelID,
              case let .success(s) = FlutingGenerator.Surface.make(modelID: id, tool: op.tool, project: project, stock: project.stock)
        else { return nil }
        return s
    }

    /// The thickest stock over the model under the feed moves of `tp` on a flat job's material model as it was before
    /// `tp` cut, mm. nil when no move is over the model.
    static func stockOver(_ tp: Toolpath, surface: FlutingGenerator.Surface, grid g: HeightGrid) -> Double? {
        var best = -Double.infinity
        var hint: Int32 = -1
        var last = -1
        forEachCuttingPoint(tp, step: max(spacing, g.cellSize / 2)) { q in
            let c = Int(((q.x - g.origin.x) / g.cellSize).rounded()), r = Int(((q.y - g.origin.y) / g.cellSize).rounded())
            guard c >= 0, r >= 0, c < g.columns, r < g.rows else { return }
            let i = g.index(c, r)
            guard i != last else { return }
            last = i
            let model = surface.modelZ(at: Vec2(g.origin.x + Double(c) * g.cellSize, g.origin.y + Double(r) * g.cellSize), hint: &hint)
            if model.isFinite { best = max(best, Double(g.heights[i]) - model) }
        }
        return best.isFinite ? best : nil
    }

    /// The same on a wrapped rotary job, whose moves are on the unrolled sheet, on the radial material model as it was
    /// before `tp` cut: the cell's distance from the axis less the model's under the cell's centre.
    static func stockOver(_ tp: Toolpath, surface: FlutingGenerator.Surface, radial g: RadialGrid) -> Double? {
        var best = -Double.infinity
        var hint: Int32 = -1
        var last = -1
        forEachCuttingPoint(tp, step: max(spacing, g.cellSize / 2)) { q in
            guard let c = g.column(at: q.x) else { return }
            let j = g.row(atAngle: (q.y - g.centerY) / g.radius)
            let i = j * g.columns + c
            guard i != last else { return }
            last = i
            let model = surface.modelRadius(x: g.originX + Double(c) * g.cellSize, angle: g.angle(row: j), hint: &hint)
            if model.isFinite { best = max(best, Double(g.radii[i]) - model) }
        }
        return best.isFinite ? best : nil
    }
}
