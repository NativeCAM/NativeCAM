import Foundation
import simd

/// 3D rest finishing (`Finish3DStrategy.rest`): a smaller ball or tapered ball nose finishes only where the earlier 3D
/// finishing toolpaths it follows (`RestMachining.references`) left material.
///
/// What a reference left is worked out from where its bit could have touched the model, exactly, with its own
/// drop-cutter, not from the passes it made: the scallops between its passes don't count. At each node of a grid over
/// the boundary the rest bit is dropped onto the model, and the point it touches (with the model's normal there) is
/// checked against every reference:
/// - the reference's bit is put where it would touch that point square to the surface, and dropped there; when nothing
///   holds it up it touches the point, and the point is finished;
/// - otherwise something else holds it off (the far wall of a crevice, the other face of a crease), and the point is
///   as far from the bit as its nearest position leaves it: positions round the point are tried, then the closest
///   refined, until one comes within the tolerance or none can.
/// Nodes whose point is further than the tolerance from every reference (with what each left on purpose, its allowance)
/// are the rest areas, worked out where the rest bit's centre goes. Specks smaller than a circle of half the bit's tip
/// radius are dropped, the rest grown by the margin and kept inside the boundary, and the raster cut inside them, with
/// the optional pencil pass along their creases.
extension Model3DGenerator {
    /// Where one reference's bit could reach.
    struct Reach: Sendable {
        let name: String
        let profile: CutterProfile
        /// Its bit, on its own models' triangles, leaving nothing.
        let cutter: TriangleDropCutter
        /// Where its tool centre went (a rest reference's own rest areas).
        let centres: Mask
        /// The lowest its tip went: its models' base plus its allowance.
        let floor: Double
        /// What it left on purpose beyond what the rest pass leaves (its allowance less the rest pass's), mm.
        let left: Double

        /// How thick the material this reference left is at model point q (upward normal n), mm: the distance from q to
        /// the nearest position of its bit, plus what it left on purpose. Stops looking once it's within `enough`.
        func thickness(at q: SIMD3<Double>, normal n: SIMD3<Double>, enough: Double) -> Double {
            let R = profile.radius
            let qxy = Vec2(q.x, q.y)
            var hint: Int32 = -1
            func gap(_ p: Vec2) -> Double {
                guard centres.contains(p) else { return .infinity }
                let tip = cutter.z(at: p, hint: &hint)
                let z = max(floor, min(0, tip.isFinite ? tip : floor))
                return profile.distance(radial: qxy.distance(to: p), height: q.z - z) + left
            }
            // Square to the surface: the bit's axis is out along the normal, where its own slope matches the surface's.
            let h = Vec2(n.x, n.y), hl = h.length
            let rho = hl < 1e-9 ? 0 : (n.z < 1e-9 ? R : profile.facetRadius(hl / n.z))
            var at = hl < 1e-9 ? qxy : qxy + h * (rho / hl)
            var best = gap(at)
            if best <= enough { return best }
            for (k, f) in [0.25, 0.5, 0.75, 1.0].enumerated() {
                for j in 0..<8 {
                    let p = qxy + Vec2.fromAngle((Double(j) + (k % 2 == 0 ? 0 : 0.5)) * .pi / 4, length: f * R)
                    let g = gap(p)
                    if g < best { best = g; at = p }
                    if best <= enough { return best }
                }
            }
            guard best.isFinite else { return best }
            var step = R / 8
            var rounds = 0
            while step > R / 256, rounds < 48 {
                rounds += 1
                var moved = false
                for j in 0..<8 {
                    let p = at + Vec2.fromAngle(Double(j) * .pi / 4, length: step)
                    let g = gap(p)
                    if g < best - 1e-9 { best = g; at = p; moved = true }
                }
                if best <= enough { break }
                if !moved { step /= 2 }
            }
            return best
        }
    }

    /// Regions rasterized onto a grid, for quick point-in-area tests (to a cell).
    struct Mask: Sendable {
        let origin: Vec2
        let pitch: Double
        let columns: Int
        let rows: Int
        let bits: [Bool]

        init(_ regions: [Region], pitch: Double) {
            let bounds = regions.map(\.bounds).reduce(Rect2.empty) { $0.union($1) }
            let area = bounds.isEmpty ? Rect2(x: 0, y: 0, width: 0, height: 0) : bounds.insetBy(-2 * pitch)
            let grid = SurfaceGrid(area: area, cellSize: pitch)
            origin = grid.origin
            self.pitch = pitch
            columns = grid.columns
            rows = grid.rows
            bits = bounds.isEmpty ? [Bool](repeating: false, count: grid.columns * grid.rows) : Model3DGenerator.regionMask(regions, grid)
        }

        func contains(_ p: Vec2) -> Bool {
            let c = Int(((p.x - origin.x) / pitch).rounded()), r = Int(((p.y - origin.y) / pitch).rounded())
            guard c >= 0, r >= 0, c < columns, r < rows else { return false }
            return bits[r * columns + c]
        }
    }

    /// What a rest pass works from: its finishing setup, and where its bit's centre goes.
    struct RestPlan {
        var finishing: Finishing
        /// The rest areas, grown by the margin and inside the boundary.
        var areas: [Region]
        /// The tip heights at the grid's nodes, for the pencil pass's map.
        var z: [Double]
        var onModel: [Bool]
    }

    /// The rest pass's grid pitch (and finishing cell) for `tool` at `stepover`, mm.
    static func restCell(tool: Tool, stepover: Double) -> Double { max(0.08, min(0.25, stepover)) }

    /// Rest areas smaller than this (before the margin) aren't worth cutting, mm²: a circle of half the tip's radius.
    static func restMinimumArea(_ tool: Tool) -> Double {
        let r = RestMachining.tipRadius(tool) / 2
        return .pi * r * r
    }

    static func restFinish(op: CAMOperation, params: Finish3DParams, shapes: [DesignShape], context: GenerationContext) -> Toolpath {
        let tool = op.tool
        var b = ToolpathBuilder(stock: context.stock, tool: tool, startXY: nil)
        func empty(_ warnings: [String]) -> Toolpath {
            b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        }
        guard let project = context.project else {
            return empty(["Rest finishing follows the toolpaths before it in the job, so it can't be worked out on its own."])
        }
        let refs = RestMachining.references(for: op, in: project)
        if let why = refs.refusal { return empty(refs.warnings + [why]) }
        guard !refs.operations.isEmpty else { return empty(refs.warnings) }
        var visiting: Set<UUID> = [op.id]
        var warnings = refs.warnings
        guard let plan = restPlan(op: op, params: params, shapes: shapes, references: refs.operations, context: context,
                                  visiting: &visiting, warnings: &warnings) else {
            return empty(warnings)
        }
        guard !plan.areas.isEmpty else {
            warnings.append("Nothing left to cut: its references' bits reach everywhere this one does, to within the rest "
                + "tolerance (\(context.length(params.restSettings.toleranceInUse))), so it posts nothing.")
            var tp = empty(warnings)
            tp.restAreas = []
            return tp
        }
        let f = plan.finishing
        let area = plan.areas.flatMap(\.loops)
        _ = raster(over: area, f, &b)
        if params.restSettings.pencil {
            b.retract()
            let map = CLMap(dropper: f.dropper, floor: f.floor, grid: f.setup.surface, z: plan.z, onModel: plan.onModel)
            pencil(map, f, &b, warnings: &warnings, area: area)
        }
        b.retract()
        var tp = b.build(id: op.id, name: op.name, tool: tool, rpm: tool.cutting.spindleRPM, warnings: warnings)
        tp.restAreas = area
        return tp
    }

    /// The rest areas for the rest pass `op` following `references`. `visiting` holds the rest passes already being
    /// worked out, so references can't go round in a circle.
    static func restPlan(op: CAMOperation, params: Finish3DParams, shapes: [DesignShape], references: [CAMOperation],
                         context: GenerationContext, visiting: inout Set<UUID>, warnings: inout [String]) -> RestPlan? {
        let tool = op.tool
        let rest = params.restSettings
        let stepover = max(0.02, tool.stepoverBasis * params.stepoverFraction)
        let cell = restCell(tool: tool, stepover: stepover)
        guard let s = setup(shapes: shapes, boundary: params.boundary, margin: params.boundaryMargin ?? Finish3DParams.autoMargin(tool: tool),
                            reach: tool.radius + cell, tool: tool, stock: context.stock, preferredCell: cell, warnings: &warnings) else {
            return nil
        }
        var surface = targets(s, allowance: params.allowance)
        for i in surface.indices where surface[i] == .infinity { surface[i] = 0 }
        guard let exact = TriangleDropCutter(tool: tool, allowance: params.allowance, triangles: triangles(of: s.models)) else { return nil }
        for i in surface.indices where s.surface.covered[i] { surface[i] = -.infinity }
        let dropper = CombinedDrop(exact: exact, grid: DropCutter(grid: s.surface, surface: surface, tool: tool))
        let floor = s.baseZ + params.allowance
        let f = Finishing(setup: s, tool: tool, params: params, dropper: dropper, floor: floor, stepover: stepover, cell: cell,
                          ds: max(s.surface.cellSize, 0.15), tolerance: min(0.01, context.arcTolerance * 2), context: context)

        // Each reference's reach.
        var reaches: [Reach] = []
        var cache: [[UUID]: [Double]] = [:]
        for ref in references {
            guard case let .finish3D(rp) = ref.kind, let profile = CutterProfile(tool: ref.tool) else { continue }
            let refShapes = context.project.map { $0.shapes(for: ref).filter { !$0.isKeepOut } } ?? []
            var ignored: [String] = []
            guard let (models, regions, _) = boundaryRegions(shapes: refShapes, boundary: rp.boundary,
                                                             margin: rp.boundaryMargin ?? Finish3DParams.autoMargin(tool: ref.tool),
                                                             stock: context.stock, warnings: &ignored) else { continue }
            let key = models.map(\.id)
            let tris = cache[key] ?? triangles(of: models)
            cache[key] = tris
            guard let cutter = TriangleDropCutter(tool: ref.tool, allowance: 0, triangles: tris) else { continue }
            var centres = regions
            if rp.strategy == .rest {
                // A rest reference cut only its own rest areas.
                guard visiting.insert(ref.id).inserted, let project = context.project else {
                    warnings.append("“\(ref.name)” rests on this toolpath in turn, so it isn't counted.")
                    continue
                }
                defer { visiting.remove(ref.id) }
                let inner = RestMachining.references(for: ref, in: project)
                var ignoredToo: [String] = []
                guard inner.refusal == nil, !inner.operations.isEmpty,
                      let sub = restPlan(op: ref, params: rp, shapes: refShapes, references: inner.operations, context: context,
                                         visiting: &visiting, warnings: &ignoredToo) else { continue }
                centres = sub.areas
            }
            let base = models.compactMap { $0.modelSpec?.bottomZ }.min() ?? 0
            reaches.append(Reach(name: ref.name, profile: profile, cutter: cutter, centres: Mask(centres, pitch: max(0.05, cell / 2)),
                                 floor: base + rp.allowance, left: rp.allowance - params.allowance))
        }

        // Where the rest bit's contact is further than the tolerance from every reference.
        let g = s.surface
        let cols = g.columns, rws = g.rows
        let within = regionMask(s.boundary, g)
        let tol = rest.toleranceInUse
        let zs = ParallelResults<Double>(count: cols * rws, initial: floor)
        let model = ParallelResults<Bool>(count: cols * rws, initial: false)
        let flagged = ParallelResults<Bool>(count: cols * rws, initial: false)
        let all = reaches
        DispatchQueue.concurrentPerform(iterations: rws) { r in
            var hint: Int32 = -1
            for c in 0..<cols {
                let i = r * cols + c
                let p = g.center(c, r)
                let sample = CLMap.sample(dropper, floor: floor, p, hint: &hint)
                zs[i] = sample.z
                model[i] = sample.onModel
                guard within[i], sample.onModel, sample.winner >= 0,
                      let touch = exact.contact(at: p, tip: sample.exactZ, triangle: Int(sample.winner)),
                      touch.point.z < -1e-6 else { continue }
                var thickest = true
                for reach in all where reach.left <= tol {
                    if reach.thickness(at: touch.point, normal: touch.normal, enough: tol / 2) <= tol {
                        thickest = false
                        break
                    }
                }
                flagged[i] = thickest
            }
        }
        let mask = flagged.array
        var areas: [Region] = []
        if mask.contains(true) {
            let loops = GridContours.loops(mask: mask, columns: cols, rows: rws, origin: g.origin, cellSize: g.cellSize)
            // Gaps and pinholes a cell across closed, specks dropped, then grown by the margin and kept in the boundary.
            let d = g.cellSize
            let closed = Clipper.offset(Clipper.offset(Clipper.union(loops, fill: .nonZero), delta: d), delta: -d)
            let minimum = restMinimumArea(tool)
            let kept = Region.nest(closed).filter { $0.area >= minimum }.flatMap(\.loops)
            if !kept.isEmpty {
                let margin = rest.marginInUse
                let grown = margin > 1e-6 ? Clipper.offset(kept, delta: margin) : kept
                areas = Region.nest(Clipper.intersection(grown, s.boundary.flatMap(\.loops), fill: .nonZero))
                    .filter { $0.area > 1e-6 }
            }
        }
        return RestPlan(finishing: f, areas: areas, z: zs.array, onModel: model.array)
    }
}
