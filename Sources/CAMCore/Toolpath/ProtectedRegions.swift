import Foundation

/// The finished material every toolpath in a job leaves, so one toolpath's leads and corner reliefs keep clear of the
/// parts the others cut, whatever their order in the sidebar.
///
/// Each toolpath's part is held as a thin band of the material it leaves along its finished walls, on the part side:
/// inside an outside profile's shapes (plus allowance), round an inside profile's holes, both sides of an "On" cut,
/// round a pocket (and inside its islands), round a V-carve's carved area, round each drilled hole, along a chamfer's
/// foot (on its vector for a bottom-edge bevel, as the profile cutting that vector has it), inside a prism's outline
/// and along both walls of a flute. A tool coming
/// from the waste cuts into the part exactly when it touches the band, so a band a fraction of a millimetre wide is
/// enough, and it never reaches material near a wall that is really scrap (beside a part, or in a hole). Bands are
/// clipped to the material: a pocket's edge on the material's edge isn't a wall.
///
/// Built once per generation pass, from every toolpath in the project, turned on or not (one that's turned off is
/// usually cut in another run). 3D toolpaths, roundings and 3D rotary finishes leave no band; an edge profile leaves the
/// band inside its part, as a prism does.
public struct ProtectedRegions: Sendable {
    /// Width of each band, mm.
    static let bandWidth = 0.1
    /// How far a tool may reach into a band: offsets of one curve made different ways disagree by their arc
    /// tolerance, mm.
    static let tolerance = 0.02
    /// Another toolpath's band this close to a toolpath's own drawn walls is on those same walls (a rough and its
    /// finish, a pocket and a profile of one recess), so it's that toolpath's own corner to relieve, mm.
    static let sameWall = bandWidth + 0.05

    struct Part: Sendable {
        var operation: UUID
        var name: String
        /// The shapes it cuts.
        var shapeIDs: Set<UUID> = []
        /// The faces of an indexed rotary job it's cut on (normalized angles); nil on a flat sheet or a wrapped blank.
        var faces: Set<Double>?
        var band: [Polyline]
        var bounds: Rect2
    }

    /// Where a tool's centre would cut into another toolpath's part.
    public struct Zone: Sendable {
        /// The toolpath that cuts the part.
        public var name: String
        var regions: [Region]
        var bounds: [Rect2]
        /// The shapes that toolpath cuts.
        var shapeIDs: Set<UUID> = []

        func contains(_ p: Vec2) -> Bool {
            for (i, region) in regions.enumerated() where bounds[i].contains(p) && region.contains(p) { return true }
            return false
        }

        /// Distance from a point outside the zone to its edge, if that's within `limit` (otherwise infinity).
        func distance(_ p: Vec2, within limit: Double) -> Double {
            var nearest = Double.infinity
            for (i, region) in regions.enumerated() where bounds[i].contains(p, tolerance: limit) {
                for loop in region.loops { nearest = min(nearest, loop.closestPoint(to: p).distance) }
            }
            return nearest
        }

        /// Whether the straight move a→b by the tool centre enters the zone (sampled at `spacing`).
        func crosses(from a: Vec2, to b: Vec2, spacing: Double) -> Bool {
            let n = max(1, Int((a.distance(to: b) / spacing).rounded(.up)))
            for k in 0...n where contains(a.lerp(to: b, Double(k) / Double(n))) { return true }
            return false
        }
    }

    var parts: [Part]

    /// Whether any operation in the project has leads or corner reliefs, which are what keep clear of other parts, or is
    /// a profile, which is checked against them. Only with another toolpath to keep clear of.
    static func needed(_ project: Project) -> Bool {
        project.operations.count > 1 && project.operations.contains { op in
            switch op.kind {
            // A profile is checked against the other toolpaths' parts too, for a bit that reaches into one.
            case .profile: true
            case let .pocket(p): p.cornerRelief != nil
            case let .edgeProfile(p): p.leads != nil
            default: false
            }
        }
    }

    init(parts: [Part]) { self.parts = parts }

    init(_ project: Project, flattenTolerance: Double, arcTolerance: Double) {
        let stock = project.stock
        // A wrapped sheet's Y goes round the blank, so only its ends along X bound the material.
        let clip = stock.rotary?.isWrapped == true
            ? Rect2(x: 0, y: -100_000, width: stock.width, height: 200_000) : stock.bounds
        let clipLoop = Polyline([clip.min, Vec2(clip.max.x, clip.min.y), clip.max, Vec2(clip.min.x, clip.max.y)], closed: true)
        let indexed = stock.rotary.map { !$0.isWrapped } ?? false
        parts = project.operations.compactMap { op in
            let shapes = project.shapes(for: op).filter { !$0.isKeepOut }
            guard !shapes.isEmpty else { return nil }
            let raw = Self.band(op, shapes: shapes, stock: stock, flattenTolerance: flattenTolerance, arcTolerance: arcTolerance)
            guard !raw.isEmpty else { return nil }
            let band = Clipper.intersection(raw, [clipLoop])
            guard !band.isEmpty else { return nil }
            let faces = indexed && !op.kind.turnsWholeBlank ? Set(op.rotaryAngles.map(RotaryIndex.normalized)) : nil
            return Part(operation: op.id, name: op.name, shapeIDs: Set(shapes.map(\.id)), faces: faces, band: band, bounds: band.bounds)
        }
    }

    /// The parts of every toolpath but `operation`, on the face at `angle` of an indexed rotary job (nil: one sheet).
    func excluding(_ operation: UUID, angle: Double?) -> ProtectedRegions {
        let face = angle.map(RotaryIndex.normalized)
        return ProtectedRegions(parts: parts.filter { part in
            part.operation != operation && (face == nil || part.faces.map { $0.contains(face!) } ?? true)
        })
    }

    /// The zones a tool of radius `r` keeps its centre out of: each part near `reach` grown by the radius, less what
    /// the toolpath asking cuts away itself (`cut`, closed loops: a finish cuts its rough's allowance) and less what
    /// lies on its own drawn `walls` (a rough's dogbone cuts past the same walls as its finish's).
    func zones(toolRadius r: Double, cut: [Polyline], walls: [Polyline], near reach: Rect2, arcTolerance: Double) -> [Zone] {
        let near = parts.filter { $0.bounds.intersects(reach.insetBy(-r)) }
        guard !near.isEmpty else { return [] }
        let own = walls.isEmpty ? cut
            : Clipper.union(cut + Clipper.offset(walls, delta: Self.sameWall, end: .joined, arcTolerance: arcTolerance))
        let cutBounds = own.bounds
        var out: [Zone] = []
        for part in near {
            var band = part.band
            if !own.isEmpty, cutBounds.intersects(part.bounds) {
                // Slivers left where the two were offset from the same curve aren't material.
                band = Clipper.difference(band, minus: own).filter { $0.area > 1e-4 }
            }
            guard !band.isEmpty else { continue }
            let regions = Region.nest(Clipper.offset(band, delta: max(0.01, r - Self.tolerance), arcTolerance: arcTolerance))
            guard !regions.isEmpty else { continue }
            out.append(Zone(name: part.name, regions: regions, bounds: regions.map { $0.bounds.insetBy(-0.01) }, shapeIDs: part.shapeIDs))
        }
        return out
    }

    // MARK: Bands

    /// The band of finished material along an operation's walls, before clipping to the material.
    static func band(_ op: CAMOperation, shapes: [DesignShape], stock: Stock, flattenTolerance: Double, arcTolerance tol: Double) -> [Polyline] {
        let w = bandWidth
        func closedRegions() -> [Region] {
            Region.build(from: shapes.flatMap { $0.polylines(tolerance: flattenTolerance) }.filter { $0.isClosed && $0.count >= 3 },
                         fill: .evenOdd)
        }
        func offset(_ regions: [Region], _ d: Double) -> [Region] {
            abs(d) < 1e-9 ? regions : regions.flatMap { $0.offset(by: d, arcTolerance: tol) }
        }
        /// The band outside `area` (round a hole or a pocket, and inside its islands).
        func outside(_ area: [Polyline]) -> [Polyline] {
            area.isEmpty ? [] : Clipper.difference(Clipper.offset(area, delta: w, arcTolerance: tol), minus: area)
        }
        /// The band just inside `area` (along a part's edges, and round its holes).
        func inside(_ area: [Polyline]) -> [Polyline] {
            area.isEmpty ? [] : Clipper.difference(area, minus: Clipper.offset(area, delta: -w, arcTolerance: tol))
        }
        switch op.kind {
        case let .profile(p):
            let tool = op.tool
            let r = tool.shape.isTapered ? tool.radius(atHeight: p.depth.cutDepth) : tool.radius
            switch p.side {
            case .outside: return inside(offset(closedRegions(), p.allowance).flatMap(\.loops))
            case .inside: return outside(offset(closedRegions(), -p.allowance).flatMap(\.loops))
            case .on:
                // Both walls of the groove the bit cuts along the line.
                let polys = shapes.flatMap { $0.polylines(tolerance: flattenTolerance) }
                let closed = polys.filter { $0.isClosed && $0.count >= 3 }, open = polys.filter { !$0.isClosed && $0.count >= 2 }
                guard r > 1e-6 else { return [] }
                let kerf = Clipper.union(Clipper.offset(closed, delta: r, end: .joined, arcTolerance: tol)
                    + Clipper.offset(open, delta: r, end: .round, arcTolerance: tol))
                return outside(kerf)
            }
        case let .pocket(p):
            return outside(offset(closedRegions(), -p.allowance).flatMap(\.loops))
        case let .vcarve(p):
            let regions: [Region]
            if let inlay = p.inlay, inlay.role == .plug {
                // A whole board's edge is the material's: the band past it is clipped away.
                regions = VCarveGenerator.plugRegions(inlay, shapes: shapes, stock: stock, edge: 0, tolerance: flattenTolerance,
                                                      arcTolerance: tol).regions
            } else {
                regions = closedRegions()
            }
            return outside(regions.flatMap(\.loops))
        case let .drill(p):
            // A bored hole's band is round its drawn size (Helical bore), a plunged one's round the bit.
            guard op.tool.radius > 1e-6 else { return [] }
            return DrillGenerator.cutHoles(shapes, params: p, tool: op.tool, tolerance: flattenTolerance).flatMap { c, r -> [Polyline] in
                let outer = circle(c, radius: r + w, tolerance: tol), hole = circle(c, radius: r, tolerance: tol)
                return [outer.oriented(counterClockwise: true), hole.oriented(counterClockwise: false)]
            }
        case let .chamfer(p):
            // Where the bevel meets the material below it: a bottom-edge bevel on the vector (the wall a profile on the
            // same vector leaves, so that profile counts it as its own), a top-edge one the bevel's width away.
            let regions = closedRegions()
            guard !regions.isEmpty else { return [] }
            switch (p.edge, p.side) {
            case (.bottom, .inside): return inside(regions.flatMap(\.loops))
            case (.bottom, .outside): return outside(regions.flatMap(\.loops))
            case (.bottom, .both):
                return outside(Clipper.offset(regions.flatMap(\.loops), delta: 0.01, end: .joined, arcTolerance: tol))
            case (.top, .outside): return inside(offset(regions, p.width).flatMap(\.loops))
            case (.top, .inside): return outside(offset(regions, -p.width).flatMap(\.loops))
            case (.top, .both):
                let grown = offset(regions, p.width).flatMap(\.loops), shrunk = offset(regions, -p.width).flatMap(\.loops)
                return inside(Clipper.difference(grown, minus: shrunk))
            }
        case .prism, .edgeProfile:
            // The prism's base is the drawn shape, as an outside profile's part is; an edge profile shapes the part's
            // own edge, the drawn shape too.
            return inside(closedRegions().flatMap(\.loops))
        case let .fluting(p):
            // Both walls of the groove, at their widest.
            let r = op.tool.radius(atHeight: p.depth)
            let polys = shapes.flatMap { $0.polylines(tolerance: flattenTolerance) }
            let closed = polys.filter { $0.isClosed && $0.count >= 3 }, open = polys.filter { !$0.isClosed && $0.count >= 2 }
            guard r > 1e-6 else { return [] }
            return outside(Clipper.union(Clipper.offset(closed, delta: r, end: .joined, arcTolerance: tol)
                + Clipper.offset(open, delta: r, end: .round, arcTolerance: tol)))
        case .rough3D, .finish3D, .rounding, .rotaryFinish, .rotaryRough, .moulding:
            return []
        }
    }

    static func circle(_ c: Vec2, radius r: Double, tolerance: Double) -> Polyline {
        let step = 2 * acos(max(-1, min(1, 1 - tolerance / max(r, tolerance))))
        let n = max(12, Int((2 * .pi / max(step, 1e-3)).rounded(.up)))
        return Polyline((0..<n).map { c + Vec2.fromAngle(2 * .pi * Double($0) / Double(n), length: r) }, closed: true)
    }

    /// What a profile cuts away itself: from its finished walls (the drawn shapes plus `allowance`) a tool diameter
    /// into the waste, with the corners the bit can't reach, so other toolpaths' bands there (a rough's allowance) don't
    /// count.
    static func profileCut(_ regions: [Region], side: CutSide, allowance: Double, toolRadius r: Double, arcTolerance tol: Double) -> [Polyline] {
        guard side != .on, !regions.isEmpty else { return [] }
        let walls = (abs(allowance) < 1e-9 ? regions : regions.flatMap { $0.offset(by: side == .outside ? allowance : -allowance, arcTolerance: tol) })
            .flatMap(\.loops)
        guard !walls.isEmpty else { return [] }
        return side == .outside
            ? Clipper.difference(Clipper.offset(walls, delta: 2 * r, arcTolerance: tol), minus: walls)
            : Clipper.difference(walls, minus: Clipper.offset(walls, delta: -2 * r, arcTolerance: tol))
    }
}
