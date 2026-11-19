import Foundation

/// How the tool travels between cuts.
public enum RetractMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Lift only as high as the material under the move (plus a safe distance), stay down across cleared area,
    /// and rapid down to just above already-cut floors.
    case minimum
    /// Always go up to the safe Z between cuts (the conservative, classic behaviour).
    case full
    public var id: String { rawValue }
    public var label: String { self == .minimum ? "Minimum (above remaining material)" : "Full (to safe Z)" }
}

/// Where clamps and fixtures sit: no cutting inside, and links crossing them go over the top.
public struct KeepOut: Sendable {
    public var outline: Polyline
    /// Top of the clamp above the material top, mm.
    public var height: Double
}

/// Rewrites the moves between cuts using a model of the material already removed.
///
/// For every link (a run of rapids followed by a straight-down entry) it picks the cheapest safe option:
/// - **stay down**: feed straight across at depth when the whole swept path is already cleared to that depth,
///   it's short, and it doesn't run through a cut-through kerf (a freed part could have shifted);
/// - **minimum retract**: rise only to the highest remaining material under the swept path plus the safe
///   distance (tabs and uncut stock count), or over clamps; then rapid down to just above the floor already
///   cut at the entry point before feeding down.
/// Moves that cut are passed through unchanged and carved into the model as they go.
enum LinkOptimizer {
    struct Settings {
        var safeDistance: Double
        var clearanceZ: Double
        var stayDownLimit: Double
        var floorZ: Double
        var keepOuts: [KeepOut]
    }

    static func optimize(_ tp: Toolpath, model: inout MaterialSimulator, settings: Settings) -> Toolpath {
        let tool = tp.tool
        let reach = tool.radius + model.grid.cellSize // conservative: footprint grown by one cell
        var out: [Motion] = []
        out.reserveCapacity(tp.motions.count)
        var pos = tp.start
        let m = tp.motions
        var i = 0
        func emit(_ motion: Motion) {
            model.apply(motion, from: pos, tool: tool)
            out.append(motion)
            pos = motion.end
        }
        while i < m.count {
            guard m[i].kind == .rapid else {
                emit(m[i])
                i += 1
                continue
            }
            var j = i
            while j < m.count, m[j].kind == .rapid { j += 1 }
            let runEnd = m[j - 1].end
            // Only links that end with a straight-down feed into the next cut are rewritten.
            guard j < m.count, m[j].kind == .feed, m[j].end.xy.isApprox(runEnd.xy, tolerance: 1e-6), m[j].end.z < runEnd.z else {
                for k in i..<j { emit(m[k]) }
                i = j
                continue
            }
            let target = m[j].end
            let from = pos
            let travels = !from.xy.isApprox(runEnd.xy, tolerance: 1e-6)
            let entryFloor = Double(maxHeight(model.grid, around: runEnd.xy, radius: reach))
            // Over a floor this job already cut, rapid down to 1 mm above it (its height is known exactly);
            // over uncut material keep the configured plunge height (the sheet may be bowed).
            let entryZ = entryFloor < -0.05 ? max(target.z, min(runEnd.z, entryFloor + 1.0)) : runEnd.z

            if travels {
                let corridor = corridorHeights(model.grid, from: from.xy, to: runEnd.xy, radius: reach)
                let crossesClamp = settings.keepOuts.contains { crosses($0, from: from.xy, to: runEnd.xy, radius: tool.radius) }
                // Stay down: same depth, short, already cleared to this depth, not through a kerf, not near clamps.
                if abs(from.z - target.z) < 1e-6, from.xy.distance(to: target.xy) <= settings.stayDownLimit,
                   Double(corridor.max) <= target.z + 0.01, Double(corridor.min) > settings.floorZ + 0.05, !crossesClamp {
                    emit(.feed(target, tool.cutting.feedRate))
                    i = j + 1
                    continue
                }
                var height = Double(corridor.max) + settings.safeDistance
                if crossesClamp {
                    let clampTop = settings.keepOuts.filter { crosses($0, from: from.xy, to: runEnd.xy, radius: tool.radius) }
                        .map(\.height).max() ?? 0
                    height = max(height, settings.clearanceZ, clampTop + settings.safeDistance)
                } else {
                    height = min(height, settings.clearanceZ)
                }
                height = max(height, from.z, entryZ)
                if height > from.z + 1e-9 { emit(.rapid(Vec3(from.xy, height))) }
                emit(.rapid(Vec3(runEnd.xy, height)))
                if entryZ < height - 1e-9 { emit(.rapid(Vec3(runEnd.xy, entryZ))) }
            } else {
                // Vertical-only run (e.g. peck drilling): keep it, but continue the descent if the floor allows.
                for k in i..<j { emit(m[k]) }
                if entryZ < pos.z - 1e-9 { emit(.rapid(Vec3(pos.xy, entryZ))) }
            }
            i = j
        }
        var result = tp
        result.motions = out
        return result
    }

    /// Highest material within `radius` of `p`.
    static func maxHeight(_ g: HeightGrid, around p: Vec2, radius: Double) -> Float {
        let cs = g.cellSize
        let c0 = max(0, Int(((p.x - radius - g.origin.x) / cs).rounded(.down)))
        let c1 = min(g.columns - 1, Int(((p.x + radius - g.origin.x) / cs).rounded(.up)))
        let r0 = max(0, Int(((p.y - radius - g.origin.y) / cs).rounded(.down)))
        let r1 = min(g.rows - 1, Int(((p.y + radius - g.origin.y) / cs).rounded(.up)))
        guard c0 <= c1, r0 <= r1 else { return -.infinity }
        var best: Float = -.infinity
        let r2 = (radius + cs) * (radius + cs)
        for r in r0...r1 {
            let dy = g.origin.y + Double(r) * cs - p.y
            for c in c0...c1 {
                let dx = g.origin.x + Double(c) * cs - p.x
                if dx * dx + dy * dy <= r2 { best = max(best, g.heights[g.index(c, r)]) }
            }
        }
        return best
    }

    /// Highest and lowest material along the swept footprint of a straight move.
    static func corridorHeights(_ g: HeightGrid, from a: Vec2, to b: Vec2, radius: Double) -> (max: Float, min: Float) {
        let len = a.distance(to: b)
        let steps = max(1, Int((len / (g.cellSize * 0.5)).rounded(.up)))
        var hi: Float = -.infinity, lo: Float = .infinity
        for k in 0...steps {
            let p = a.lerp(to: b, Double(k) / Double(steps))
            hi = max(hi, maxHeight(g, around: p, radius: radius))
            // Lowest point under the tool centre line (detects running through a cut-through kerf).
            if let h = g.height(at: p) { lo = min(lo, h) }
        }
        return (hi, lo.isFinite ? lo : 0)
    }

    static func crosses(_ k: KeepOut, from a: Vec2, to b: Vec2, radius: Double) -> Bool {
        let o = k.outline
        guard o.isClosed, o.count >= 3 else { return false }
        if o.contains(a) || o.contains(b) { return true }
        for s in 0..<o.segmentCount {
            let (p, q) = o.segment(s)
            if segmentsIntersect(a, b, p, q) { return true }
            if distancePointSegment(p, a, b) <= radius || distancePointSegment(a, p, q) <= radius || distancePointSegment(b, p, q) <= radius {
                return true
            }
        }
        return false
    }
}
