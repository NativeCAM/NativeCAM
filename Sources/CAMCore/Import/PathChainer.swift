import Foundation

// Shared types for the vector importers (DXF, SVG): the import result, errors, extension dispatch,
// and the end-to-end chaining of loose open pieces into longer (ideally closed) polylines.

/// Geometry read from a vector file, in millimetres with Y up.
public struct ImportResult: Sendable, Hashable {
    /// Flattened outlines. Closed loops have `isClosed == true` and do not repeat their first point.
    public var polylines: [Polyline]
    /// Isolated points (DXF POINT entities), e.g. drilling locations.
    public var points: [Vec2]
    /// Human-readable notes: skipped entities, chains left open, unit guesses, and so on.
    public var warnings: [String]
    /// The unit the file declared, if it declared one. Metric declarations other than mm (cm, m, ...)
    /// report `.mm`; imperial ones other than inches (feet, mils, pt, ...) report `.inch`.
    public var sourceUnits: LengthUnit?
    /// Millimetres per file unit that was applied (DXF drawing unit, or SVG root user unit).
    public var unitScale: Double
    /// The layer each polyline is on, parallel to `polylines` (nil = none: a DXF's layer 0, or an SVG path outside any
    /// layer). Empty when the file has no layers to read.
    public var polylineLayers: [String?]
    /// The layer each point is on, parallel to `points`; empty when the file has no layers to read.
    public var pointLayers: [String?]

    public init(polylines: [Polyline] = [], points: [Vec2] = [], warnings: [String] = [],
                sourceUnits: LengthUnit? = nil, unitScale: Double = 1, polylineLayers: [String?] = [], pointLayers: [String?] = []) {
        self.polylines = polylines
        self.points = points
        self.warnings = warnings
        self.sourceUnits = sourceUnits
        self.unitScale = unitScale
        self.polylineLayers = polylineLayers.count == polylines.count ? polylineLayers : []
        self.pointLayers = pointLayers.count == points.count ? pointLayers : []
    }

    /// The geometry on one layer.
    public struct LayerGroup: Sendable, Hashable {
        public var layer: String?
        public var polylines: [Polyline]
        public var points: [Vec2]
    }

    /// The polylines and points layer by layer, in the order the layers first appear (polylines before points).
    public var layerGroups: [LayerGroup] {
        var groups: [LayerGroup] = []
        func add(_ layer: String?, polyline: Polyline? = nil, point: Vec2? = nil) {
            let i = groups.firstIndex { $0.layer == layer } ?? {
                groups.append(LayerGroup(layer: layer, polylines: [], points: []))
                return groups.count - 1
            }()
            if let polyline { groups[i].polylines.append(polyline) }
            if let point { groups[i].points.append(point) }
        }
        for (i, p) in polylines.enumerated() { add(polylineLayers.isEmpty ? nil : polylineLayers[i], polyline: p) }
        for (i, p) in points.enumerated() { add(pointLayers.isEmpty ? nil : pointLayers[i], point: p) }
        return groups
    }

    /// Bounds of all polylines and points.
    public var bounds: Rect2 { points.reduce(polylines.bounds) { $0.union($1) } }
    public var closedPolylines: [Polyline] { polylines.filter(\.isClosed) }
    public var openPolylines: [Polyline] { polylines.filter { !$0.isClosed } }
}

public enum VectorImportError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFileType(String)
    case binaryDXFNotSupported
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(ext):
            "Unsupported vector file type “\(ext)”. NativeCAM imports vectors (.dxf, .svg, .pdf, .ai) and 3D models (.stl, .obj, .3mf, .usdz, .ply)."
        case .binaryDXFNotSupported:
            "This is a binary DXF file. Re-save it from your CAD program as an ASCII DXF and import that."
        case let .malformed(detail):
            "The file could not be read: \(detail)"
        }
    }
}

/// Imports a vector file, choosing the importer from the file extension.
public enum VectorImporter {
    public static let supportedExtensions = ["dxf", "svg", "pdf", "ai"]

    public static func importFile(at url: URL, tolerance: Double = 0.01,
                                  defaultDXFUnit: LengthUnit = .inch) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "dxf":
            return try DXFImporter.importDXF(data: Data(contentsOf: url), tolerance: tolerance, defaultUnit: defaultDXFUnit)
        case "svg":
            return try SVGImporter.importSVG(data: Data(contentsOf: url), tolerance: tolerance)
        case "pdf", "ai":
            // Illustrator .ai files saved with "Create PDF Compatible File" are PDFs.
            return try PDFImporter.importPDF(data: Data(contentsOf: url), tolerance: tolerance)
        default:
            throw VectorImportError.unsupportedFileType(ext.isEmpty ? url.lastPathComponent : ext)
        }
    }
}

/// Joins open polylines whose endpoints coincide into longer chains, closing chains whose ends meet.
/// CAD exports often write a rectangle as four separate LINEs; CAM needs it as one closed loop.
/// Exact duplicates (same vertices within the tolerance, either direction, any start for closed loops) are
/// removed first: overlapping copies would otherwise chain into a zero-area loop or be cut twice.
public enum PathChainer {
    public struct Result: Sendable, Hashable {
        /// Closed inputs (in input order) followed by the chains, in order of their first piece.
        public var polylines: [Polyline]
        /// Chains that are still open after joining.
        public var openCount: Int
        /// Chains that became closed (including single open pieces whose ends met).
        public var closedByChaining: Int
        /// Inputs dropped because they duplicated an earlier input.
        public var duplicatesRemoved: Int
    }

    /// Chains each layer's pieces on their own (pieces on different layers are never joined), the layers in the order
    /// they first appear. Returns the polylines with the layer of each. With one layer it's `chain(_:tolerance:)`.
    public static func chainByLayer(_ input: [Polyline], layers: [String?], tolerance: Double) -> (Result, layers: [String?]) {
        guard layers.count == input.count else { return (chain(input, tolerance: tolerance), []) }
        var order: [String?] = []
        for l in layers where !order.contains(l) { order.append(l) }
        var total = Result(polylines: [], openCount: 0, closedByChaining: 0, duplicatesRemoved: 0)
        var out: [String?] = []
        for layer in order {
            let r = chain(zip(input, layers).filter { $0.1 == layer }.map(\.0), tolerance: tolerance)
            total.polylines += r.polylines
            total.openCount += r.openCount
            total.closedByChaining += r.closedByChaining
            total.duplicatesRemoved += r.duplicatesRemoved
            out += Array(repeating: layer, count: r.polylines.count)
        }
        return (total, out)
    }

    /// Default endpoint-matching distance (mm) for a flattening tolerance.
    public static func joinTolerance(for tolerance: Double) -> Double { max(tolerance, 1e-3) }

    /// - Parameter tolerance: maximum endpoint gap that still counts as connected (same units as the points).
    public static func chain(_ input: [Polyline], tolerance: Double) -> Result {
        let eps = max(tolerance, 1e-12)
        var cleaned: [Polyline] = []
        for p in input {
            guard p.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            let d = p.deduplicated(tolerance: min(1e-9, eps * 1e-3))
            if d.isClosed && d.count >= 3 {
                cleaned.append(d)
            } else if d.count >= 2 {
                cleaned.append(Polyline(d.points, closed: false))
            }
        }
        let unique = removeDuplicates(cleaned, tolerance: eps)
        let duplicatesRemoved = cleaned.count - unique.count
        var output = unique.filter(\.isClosed)
        let pieces = unique.filter { !$0.isClosed }.map(\.points)

        struct Cell: Hashable { var x: Int; var y: Int }
        func cell(_ p: Vec2) -> Cell {
            func c(_ v: Double) -> Int { Int(Swift.max(-1e15, Swift.min(1e15, (v / eps).rounded(.down)))) }
            return Cell(x: c(p.x), y: c(p.y))
        }
        // Endpoint id e: piece e / 2, start when e is even, end when odd.
        var grid: [Cell: [Int]] = [:]
        for (i, pts) in pieces.enumerated() {
            grid[cell(pts[0]), default: []].append(2 * i)
            grid[cell(pts[pts.count - 1]), default: []].append(2 * i + 1)
        }
        var used = [Bool](repeating: false, count: pieces.count)

        func endpoint(_ e: Int) -> Vec2 {
            let pts = pieces[e / 2]
            return e % 2 == 0 ? pts[0] : pts[pts.count - 1]
        }
        func nearestFree(_ q: Vec2) -> Int? {
            let c = cell(q)
            var best: Int?
            var bestD = Double.infinity
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let ids = grid[Cell(x: c.x + dx, y: c.y + dy)] else { continue }
                    for e in ids where !used[e / 2] {
                        let d = endpoint(e).distance(to: q)
                        if d <= eps, d < bestD { bestD = d; best = e }
                    }
                }
            }
            return best
        }

        var openCount = 0
        var closedByChaining = 0
        for i in pieces.indices where !used[i] {
            used[i] = true
            var chain = pieces[i]
            func closes() -> Bool { chain.count >= 4 && chain[0].distance(to: chain[chain.count - 1]) <= eps }
            var closed = closes()
            // Grow forward from the tail, then reverse and grow from the (former) head.
            for pass in 0..<2 {
                if pass == 1 { chain.reverse() }
                while !closed, let e = nearestFree(chain[chain.count - 1]) {
                    used[e / 2] = true
                    let next = e % 2 == 0 ? pieces[e / 2] : pieces[e / 2].reversed()
                    chain.append(contentsOf: next.dropFirst())
                    closed = closes()
                }
                if pass == 1 { chain.reverse() }
            }
            if closed {
                chain.removeLast()
                output.append(Polyline(chain, closed: true))
                closedByChaining += 1
            } else {
                output.append(Polyline(chain, closed: false))
                openCount += 1
            }
        }
        return Result(polylines: output, openCount: openCount, closedByChaining: closedByChaining,
                      duplicatesRemoved: duplicatesRemoved)
    }

    /// Drops polylines that repeat an earlier one within `tolerance` (keeps the first, preserves order).
    static func removeDuplicates(_ polys: [Polyline], tolerance eps: Double) -> [Polyline] {
        guard polys.count > 1 else { return polys }
        let bounds = polys.map(\.bounds)
        // Candidates share closedness and vertex count and have matching bounds; sort by min x to scan a window.
        let order = polys.indices.sorted { bounds[$0].min.x < bounds[$1].min.x }
        var dropped = [Bool](repeating: false, count: polys.count)
        for (k, i) in order.enumerated() where !dropped[i] {
            var m = k + 1
            while m < order.count, bounds[order[m]].min.x - bounds[i].min.x <= eps {
                let j = order[m]
                m += 1
                guard !dropped[j], polys[j].isClosed == polys[i].isClosed, polys[j].count == polys[i].count,
                      abs(bounds[j].min.y - bounds[i].min.y) <= eps, abs(bounds[j].max.x - bounds[i].max.x) <= eps,
                      abs(bounds[j].max.y - bounds[i].max.y) <= eps,
                      same(polys[i], polys[j], eps) else { continue }
                // Keep whichever came first in the input.
                dropped[max(i, j)] = true
                if max(i, j) == i { break }
            }
        }
        return polys.indices.filter { !dropped[$0] }.map { polys[$0] }
    }

    private static func same(_ a: Polyline, _ b: Polyline, _ eps: Double) -> Bool {
        let n = a.count
        let p = a.points, q = b.points
        func close(_ u: Vec2, _ v: Vec2) -> Bool { abs(u.x - v.x) <= eps && abs(u.y - v.y) <= eps }
        if !a.isClosed {
            if (0..<n).allSatisfy({ close(p[$0], q[$0]) }) { return true }
            return (0..<n).allSatisfy { close(p[$0], q[n - 1 - $0]) }
        }
        for j in 0..<n where close(p[0], q[j]) {
            if (0..<n).allSatisfy({ close(p[$0], q[(j + $0) % n]) }) { return true }
            if (0..<n).allSatisfy({ close(p[$0], q[(j - $0 + n) % n]) }) { return true }
        }
        return false
    }
}

/// Small geometry helpers shared by the importers.
enum ImportGeometry {
    /// Largest singular value of the linear part: the most a transform can stretch a length.
    static func maxStretch(_ t: Transform2D) -> Double {
        let s = t.a * t.a + t.b * t.b + t.c * t.c + t.d * t.d
        let det = t.determinant
        let disc = Swift.max(0, s * s - 4 * det * det)
        return ((s + disc.squareRoot()) / 2).squareRoot()
    }

    /// Flattening tolerance to use in local coordinates so the deviation after `t` stays within `tolerance`.
    static func localTolerance(_ tolerance: Double, for t: Transform2D) -> Double {
        let k = maxStretch(t)
        return k > 1e-12 ? tolerance / k : tolerance
    }

    /// Points on a (possibly rotated) ellipse arc `center + u cos θ + v sin θ`, θ from `start` by `sweep`,
    /// both ends included. `u` and `v` need not be perpendicular (an affine image of a circle).
    static func ellipseArc(center: Vec2, u: Vec2, v: Vec2, start: Double, sweep: Double, tolerance: Double) -> [Vec2] {
        let r = Swift.max(u.length, v.length)
        let n = Curves.arcSegments(radius: r, sweep: sweep, tolerance: tolerance)
        return (0...n).map { i in
            let t = start + sweep * Double(i) / Double(n)
            return center + u * cos(t) + v * sin(t)
        }
    }

    /// Cubic Bézier segments of a chord-length Hermite spline through `points` (C1, passes through every point).
    static func interpolatingCubics(through points: [Vec2], closed: Bool) -> [(Vec2, Vec2, Vec2, Vec2)] {
        var pts = points
        if closed, pts.count > 2, pts[0].isApprox(pts[pts.count - 1], tolerance: 1e-12) { pts.removeLast() }
        let n = pts.count
        guard n >= 2 else { return [] }
        if n == 2 {
            let a = pts[0], b = pts[1]
            return [(a, a.lerp(to: b, 1.0 / 3), a.lerp(to: b, 2.0 / 3), b)]
        }
        func p(_ i: Int) -> Vec2 { closed ? pts[(i % n + n) % n] : pts[Swift.max(0, Swift.min(n - 1, i))] }
        func tangent(_ i: Int) -> Vec2 {
            if !closed && i == 0 {
                return (p(1) - p(0)) / Swift.max(p(1).distance(to: p(0)), 1e-12)
            }
            if !closed && i == n - 1 {
                return (p(n - 1) - p(n - 2)) / Swift.max(p(n - 1).distance(to: p(n - 2)), 1e-12)
            }
            let d0 = p(i).distance(to: p(i - 1)), d1 = p(i + 1).distance(to: p(i))
            return (p(i + 1) - p(i - 1)) / Swift.max(d0 + d1, 1e-12)
        }
        let segCount = closed ? n : n - 1
        return (0..<segCount).map { i in
            let a = p(i), b = p(i + 1)
            let d = a.distance(to: b)
            return (a, a + tangent(i) * (d / 3), b - tangent(i + 1) * (d / 3), b)
        }
    }
}
