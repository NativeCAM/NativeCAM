import Foundation
import Testing
@testable import CAMCore

@Suite struct DXFImportTests {
    // MARK: Helpers

    static func fixtureURL(_ name: String, _ ext: String = "dxf") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/\(ext)"),
                     "missing fixture \(name).\(ext)")
    }

    static func load(_ name: String, tolerance: Double = 0.01, defaultUnit: LengthUnit = .inch) throws -> ImportResult {
        try DXFImporter.importDXF(data: Data(contentsOf: fixtureURL(name)), tolerance: tolerance, defaultUnit: defaultUnit)
    }

    /// Builds a minimal DXF from group-code pairs (optionally with a $INSUNITS header).
    static func dxf(insunits: Int? = nil, _ entities: [(Int, String)]) -> Data {
        var lines: [String] = []
        func g(_ c: Int, _ v: String) { lines.append(String(c)); lines.append(v) }
        if let insunits {
            g(0, "SECTION"); g(2, "HEADER"); g(9, "$INSUNITS"); g(70, String(insunits)); g(0, "ENDSEC")
        }
        g(0, "SECTION"); g(2, "ENTITIES")
        for (c, v) in entities { g(c, v) }
        g(0, "ENDSEC"); g(0, "EOF")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> [(Int, String)] {
        [(0, "LINE"), (8, "0"), (10, "\(x1)"), (20, "\(y1)"), (11, "\(x2)"), (21, "\(y2)")]
    }

    static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
    static func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }
    static func near(_ r: Rect2, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double, _ tol: Double = 1e-6) -> Bool {
        near(r.min.x, minX, tol) && near(r.min.y, minY, tol) && near(r.max.x, maxX, tol) && near(r.max.y, maxY, tol)
    }

    /// The polyline whose bounds match, if exactly one does.
    static func find(_ r: ImportResult, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                     tol: Double = 0.02) -> Polyline? {
        let hits = r.polylines.filter { near($0.bounds, minX, minY, maxX, maxY, tol) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Largest distance from any of `samples` to the polyline.
    static func maxDistance(from samples: [Vec2], to poly: Polyline) -> Double {
        samples.map { poly.closestPoint(to: $0).distance }.max() ?? 0
    }

    /// Largest chord deviation of a polyline approximating a circle.
    static func maxSagitta(_ poly: Polyline, center: Vec2, radius: Double) -> Double {
        var worst = 0.0
        for i in 0..<poly.segmentCount {
            let (a, b) = poly.segment(i)
            let mid = (a + b) * 0.5
            worst = max(worst, abs(radius - mid.distance(to: center)), abs(radius - a.distance(to: center)))
        }
        return worst
    }

    /// Reference B-spline evaluation using the Cox–de Boor basis recursion (independent of the importer's de Boor).
    static func bspline(_ u: Double, degree p: Int, knots: [Double], control: [Vec2]) -> Vec2 {
        func basis(_ i: Int, _ k: Int, _ u: Double) -> Double {
            if k == 0 {
                let last = knots[knots.count - 1]
                if u == last { return knots[i] < u && knots[i + 1] == u ? 1 : (knots[i] <= u && u < knots[i + 1] ? 1 : 0) }
                return knots[i] <= u && u < knots[i + 1] ? 1 : 0
            }
            var v = 0.0
            let d1 = knots[i + k] - knots[i]
            if d1 > 0 { v += (u - knots[i]) / d1 * basis(i, k - 1, u) }
            let d2 = knots[i + k + 1] - knots[i + 1]
            if d2 > 0 { v += (knots[i + k + 1] - u) / d2 * basis(i + 1, k - 1, u) }
            return v
        }
        var p0 = Vec2.zero
        for (i, c) in control.enumerated() { p0 += c * basis(i, p, u) }
        return p0
    }

    // MARK: Lines, arcs, circles and chaining

    @Test func rectangleOfFourLinesInInchesBecomesOneClosedLoop() throws {
        let r = try Self.load("rect_lines_inch")
        #expect(r.sourceUnits == .inch)
        #expect(r.unitScale == 25.4)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.polylines.count == 1)
        let p = try #require(r.polylines.first)
        #expect(p.isClosed)
        #expect(p.count == 4)
        #expect(Self.near(p.area, 1290.32, 1e-3))
        #expect(Self.near(p.bounds, 0, 0, 50.8, 25.4, 1e-4))
    }

    @Test func circlesAndArcs() throws {
        let r = try Self.load("circle_arcs_mm")
        #expect(r.sourceUnits == .mm)
        #expect(r.polylines.count == 3)

        let circle = try #require(Self.find(r, 40, 40, 60, 60))
        #expect(circle.isClosed)
        #expect(abs(circle.area - .pi * 100) < 0.5)
        #expect(circle.area < .pi * 100)
        #expect(Self.maxSagitta(circle, center: Vec2(50, 50), radius: 10) <= 0.01 + 1e-9)

        // Two half-circle ARCs chain into one closed loop.
        let twoArcs = try #require(Self.find(r, 90, -10, 110, 10))
        #expect(twoArcs.isClosed)
        #expect(abs(twoArcs.area - .pi * 100) < 0.5)

        let arc = try #require(Self.find(r, 0, 0, 5, 5))
        #expect(!arc.isClosed)
        #expect(abs(arc.length - .pi * 5 / 2) < 0.01)
        let ends = [arc.points.first!, arc.points.last!]
        #expect(ends.contains { Self.near($0, Vec2(5, 0)) } && ends.contains { Self.near($0, Vec2(0, 5)) })
        #expect(r.warnings.contains { $0.contains("1 open path") })
    }

    @Test func roundedRectangleOfLinesAndArcsChainsClosed() throws {
        let r = try Self.load("rounded_rect_lines_arcs")
        #expect(r.polylines.count == 1)
        let p = try #require(r.polylines.first)
        #expect(p.isClosed)
        #expect(abs(p.area - (800 - (4 - .pi) * 25)) < 0.3)
        #expect(Self.near(p.bounds, 0, 0, 40, 20, 1e-6))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func toleranceControlsArcFlattening() throws {
        let fine = try Self.load("circle_arcs_mm", tolerance: 0.001)
        let coarse = try Self.load("circle_arcs_mm", tolerance: 0.1)
        let f = try #require(Self.find(fine, 40, 40, 60, 60, tol: 0.2))
        let c = try #require(Self.find(coarse, 40, 40, 60, 60, tol: 0.2))
        #expect(f.count > c.count * 5)
        #expect(Self.maxSagitta(c, center: Vec2(50, 50), radius: 10) <= 0.1 + 1e-9)
        #expect(Self.maxSagitta(f, center: Vec2(50, 50), radius: 10) <= 0.001 + 1e-9)
    }

    // MARK: Polylines

    @Test func lwPolylineBulges() throws {
        let r = try Self.load("lwpolyline_bulge")
        #expect(r.polylines.count == 3)

        // 20 x 10 rectangle with semicircular ends (bulge 1 on both short sides).
        let slot = try #require(Self.find(r, -5, 0, 25, 10))
        #expect(slot.isClosed)
        #expect(abs(slot.area - (200 + .pi * 25)) < 0.3)

        // Open semicircle (100,0) -> (110,0), counter-clockwise, so it dips below the chord.
        let semi = try #require(Self.find(r, 100, -5, 110, 0))
        #expect(!semi.isClosed)
        // A chord polyline with sagitta <= s is short by at most about π·s/3 per half turn.
        #expect(abs(semi.length - .pi * 5) < .pi * 0.01 / 3 + 1e-4)

        // Square with a clockwise (negative bulge) semicircular bite out of the top edge.
        let bite = try #require(Self.find(r, 200, 0, 210, 10))
        #expect(bite.isClosed)
        #expect(abs(bite.area - (100 - .pi * 12.5)) < 0.2)
        #expect(bite.contains(Vec2(205, 3)))
        #expect(!bite.contains(Vec2(205, 7)))
    }

    @Test func oldStylePolylineWithVertices() throws {
        let r = try Self.load("polyline_vertex")
        #expect(r.polylines.count == 2)
        let closed = try #require(Self.find(r, -5, 0, 10, 10))
        #expect(closed.isClosed)
        #expect(abs(closed.area - (100 + .pi * 12.5)) < 0.2)
        // 3D polyline: Z is ignored.
        let open = try #require(Self.find(r, 0, 20, 10, 30))
        #expect(!open.isClosed)
        #expect(Self.near(open.length, 20, 1e-9))
    }

    // MARK: Splines and ellipses

    @Test func splineQuadraticBezier() throws {
        let r = try Self.load("spline")
        let s = try #require(Self.find(r, 0, 0, 20, 10, tol: 0.011))
        #expect(!s.isClosed)
        #expect(Self.near(s.points.first!, Vec2(0, 0)) && Self.near(s.points.last!, Vec2(20, 0)))
        // B(t) = (1-t)^2 P0 + 2t(1-t) P1 + t^2 P2 has its peak y = 10 at t = 0.5.
        #expect(abs(s.bounds.max.y - 10) < 0.01)
        let reference = (0...4000).map { i -> Vec2 in
            let t = Double(i) / 4000
            return Vec2(0, 0) * ((1 - t) * (1 - t)) + Vec2(10, 20) * (2 * t * (1 - t)) + Vec2(20, 0) * (t * t)
        }
        #expect(Self.maxDistance(from: reference, to: s) <= 0.01 + 1e-4)
    }

    @Test func rationalSplineIsAnExactQuarterCircle() throws {
        let r = try Self.load("spline")
        let s = try #require(Self.find(r, 100, 0, 110, 10, tol: 0.011))
        for p in s.points { #expect(abs(p.distance(to: Vec2(100, 0)) - 10) < 1e-9) }
        let ends = [s.points.first!, s.points.last!]
        #expect(ends.contains { Self.near($0, Vec2(110, 0)) } && ends.contains { Self.near($0, Vec2(100, 10)) })
        #expect(Self.maxSagitta(s, center: Vec2(100, 0), radius: 10) <= 0.01 + 1e-9)
    }

    @Test func cubicSplineWithInteriorKnotsMatchesCoxDeBoor() throws {
        let r = try Self.load("spline")
        let s = try #require(r.polylines.first { $0.bounds.min.y > 39 && $0.bounds.max.y < 71 && $0.bounds.max.x < 60 })
        let control = [Vec2(0, 50), Vec2(10, 70), Vec2(20, 40), Vec2(30, 70), Vec2(40, 40), Vec2(50, 60)]
        let knots: [Double] = [0, 0, 0, 0, 1, 2, 3, 3, 3, 3]
        let reference = (0...3000).map { Self.bspline(3 * Double($0) / 3000, degree: 3, knots: knots, control: control) }
        #expect(Self.near(s.points.first!, control.first!) && Self.near(s.points.last!, control.last!))
        // Every flattened vertex lies on the curve, and the curve stays within tolerance of the polyline.
        let refPoly = Polyline(reference, closed: false)
        #expect(Self.maxDistance(from: s.points, to: refPoly) < 1e-3)
        #expect(Self.maxDistance(from: reference, to: s) <= 0.01 + 1e-4)
    }

    @Test func splineFromFitPointsOnly() throws {
        let r = try Self.load("spline")
        let s = try #require(r.polylines.first { $0.bounds.min.y > 95 && $0.bounds.max.y < 115 })
        for fit in [Vec2(0, 100), Vec2(10, 110), Vec2(20, 100), Vec2(30, 110)] {
            #expect(s.closestPoint(to: fit).distance < 1e-9)
        }
        #expect(r.warnings.contains { $0.contains("fit points") })
    }

    @Test func closedPeriodicSpline() throws {
        let r = try Self.load("spline")
        let s = try #require(r.polylines.first { $0.bounds.min.x >= 199 })
        #expect(s.isClosed)
        // Uniform cubic B-spline of a 20 x 20 square: extremes at (P_i + 23 P_i+1 + 23 P_i+2 + P_i+3) / 48.
        let inset: Double = 20.0 / 24
        let lo: Double = 200 + inset, hi: Double = 220 - inset
        #expect(Self.near(s.bounds, lo, inset, hi, 20 - inset, 0.01))
        #expect(r.polylines.count == 5)
    }

    @Test func ellipses() throws {
        let r = try Self.load("ellipse")
        #expect(r.polylines.count == 2)
        let full = try #require(Self.find(r, -20, -10, 20, 10))
        #expect(full.isClosed)
        #expect(abs(full.area - .pi * 200) < 0.6)
        // Half ellipse, vertical major axis from (100,20) through (90,0) to (100,-20).
        let half = try #require(Self.find(r, 90, -20, 100, 20))
        #expect(!half.isClosed)
        #expect(Self.near(half.points.first!, Vec2(100, 20)) && Self.near(half.points.last!, Vec2(100, -20)))
        for p in half.points {
            let q = (p - Vec2(100, 0))
            #expect(abs((q.x / 10) * (q.x / 10) + (q.y / 20) * (q.y / 20) - 1) < 1e-9)
        }
    }

    // MARK: Blocks, extrusion, points

    @Test func blocksAndInserts() throws {
        let r = try Self.load("blocks_insert")
        #expect(r.polylines.count == 11)
        #expect(r.polylines.allSatisfy { $0.isClosed })

        // SQ (10 x 10) scaled 2 and rotated 90 degrees about the insertion point (100,0).
        let rotated = try #require(Self.find(r, 80, 0, 100, 20))
        #expect(Self.near(rotated.area, 400, 1e-6))

        // PAIR at (0,100): SQ at its origin and a half-size SQ at (30,0).
        #expect(Self.find(r, 0, 100, 10, 110) != nil)
        let small = try #require(Self.find(r, 30, 100, 35, 105))
        #expect(Self.near(small.area, 25, 1e-6))

        // CIR has base point (5,5), so its circle is centred on the insertion point; its POINT too.
        #expect(Self.find(r, 195, 195, 205, 205) != nil)
        #expect(r.points.count == 1)
        #expect(Self.near(r.points[0], Vec2(200, 200)))

        // Mirrored insert (x scale -1).
        let tri = try #require(Self.find(r, 290, 0, 300, 10))
        #expect(Self.near(tri.area, 50, 1e-6))

        // MINSERT 3 columns x 2 rows, spacing 20 x 15.
        let grid = r.polylines.filter { $0.bounds.min.y >= 299 }
        #expect(grid.count == 6)
        let corners = Set(grid.map { "\(Int($0.bounds.min.x.rounded())),\(Int($0.bounds.min.y.rounded()))" })
        #expect(corners == ["0,300", "20,300", "40,300", "0,315", "20,315", "40,315"])

        #expect(r.warnings.contains { $0.contains("NOPE") })
    }

    @Test func negativeExtrusionMirrorsX() throws {
        let r = try Self.load("extrusion")
        #expect(r.polylines.count == 3)
        let arc = try #require(r.polylines.first { !$0.isClosed })
        let ends = [arc.points.first!, arc.points.last!]
        #expect(ends.contains { Self.near($0, Vec2(-15, 0)) } && ends.contains { Self.near($0, Vec2(-10, 5)) })
        for p in arc.points { #expect(abs(p.distance(to: Vec2(-10, 0)) - 5) < 1e-9) }
        #expect(Self.find(r, -23, 17, -17, 23) != nil)
        let tri = try #require(Self.find(r, -10, 0, 0, 10))
        #expect(Self.near(tri.area, 50, 1e-9))
    }

    @Test func r2000FileWithCRLFPointsTextAndPaperSpace() throws {
        let r = try Self.load("r2000_mixed")
        #expect(r.sourceUnits == .mm)
        #expect(r.polylines.count == 2)
        let rect = try #require(Self.find(r, 0, 0, 30, 20))
        #expect(rect.isClosed && Self.near(rect.area, 600, 1e-9))
        #expect(Self.find(r, 50, 0, 60, 10)?.isClosed == false)
        #expect(r.bounds.max.x <= 60) // paper-space line to (500,500) skipped
        #expect(r.points.count == 2)
        #expect(Set(r.points.map { "\($0.x),\($0.y)" }) == ["5.0,5.0", "25.0,15.0"])
        #expect(r.warnings.contains { $0.contains("TEXT") })
        #expect(r.warnings.contains { $0.contains("paper-space") })
        #expect(r.warnings.contains { $0.contains("1 open path") })
    }

    @Test func nestedInsertScaleTightensFlatteningTolerance() throws {
        // A unit circle in a block, inserted at scale 100 inside another block at scale 2 -> r = 200 mm.
        var pairs: [(Int, String)] = []
        pairs += [(0, "INSERT"), (8, "0"), (2, "OUTER"), (10, "0"), (20, "0"), (41, "2"), (42, "2")]
        var data = String(decoding: Self.dxf(insunits: 4, pairs), as: UTF8.self)
        let blocks = """
        0
        SECTION
        2
        BLOCKS
        0
        BLOCK
        2
        INNER
        10
        0
        20
        0
        0
        CIRCLE
        10
        0
        20
        0
        40
        1
        0
        ENDBLK
        0
        BLOCK
        2
        OUTER
        10
        0
        20
        0
        0
        INSERT
        2
        INNER
        10
        0
        20
        0
        41
        100
        42
        100
        0
        ENDBLK
        0
        ENDSEC

        """
        data = data.replacingOccurrences(of: "0\nSECTION\n2\nENTITIES", with: blocks + "0\nSECTION\n2\nENTITIES")
        let r = try DXFImporter.importDXF(data: Data(data.utf8))
        let c = try #require(r.polylines.first)
        #expect(Self.near(c.bounds, -200, -200, 200, 200, 0.01 + 1e-9))
        #expect(Self.maxSagitta(c, center: .zero, radius: 200) <= 0.01 + 1e-9)
    }

    // MARK: Units and errors

    @Test func insUnitsConversions() throws {
        let cases: [(Int, Double, LengthUnit)] = [(1, 25.4, .inch), (4, 1, .mm), (5, 10, .mm), (6, 1000, .mm), (2, 304.8, .inch)]
        for (code, mm, unit) in cases {
            let r = try DXFImporter.importDXF(data: Self.dxf(insunits: code, Self.line(0, 0, 1, 0)))
            let p = try #require(r.polylines.first)
            #expect(Self.near(p.length, mm, 1e-9), "INSUNITS \(code)")
            #expect(r.sourceUnits == unit)
            #expect(r.unitScale == mm)
        }
    }

    @Test func missingOrUnitlessInsUnitsFallsBackToDefaultWithWarning() throws {
        let noHeader = try DXFImporter.importDXF(data: Self.dxf(Self.line(0, 0, 1, 0)))
        #expect(Self.near(noHeader.polylines[0].length, 25.4, 1e-9))
        #expect(noHeader.sourceUnits == nil)
        #expect(noHeader.warnings.contains { $0.contains("$INSUNITS") && $0.contains("inches") })

        let mm = try DXFImporter.importDXF(data: Self.dxf(Self.line(0, 0, 1, 0)), defaultUnit: .mm)
        #expect(Self.near(mm.polylines[0].length, 1, 1e-9))

        let unitless = try DXFImporter.importDXF(data: Self.dxf(insunits: 0, Self.line(0, 0, 1, 0)), defaultUnit: .mm)
        #expect(Self.near(unitless.polylines[0].length, 1, 1e-9))
        #expect(unitless.warnings.contains { $0.contains("unitless") })
    }

    @Test func binaryDXFThrowsClearError() {
        var bytes = Array("AutoCAD Binary DXF\r\n".utf8)
        bytes += [0x1A, 0x00, 0x00, 0x00]
        #expect(throws: VectorImportError.binaryDXFNotSupported) {
            try DXFImporter.importDXF(data: Data(bytes))
        }
        #expect(VectorImportError.binaryDXFNotSupported.errorDescription?.contains("ASCII") == true)
    }

    @Test func malformedGroupCodeThrows() {
        let data = Data("0\nSECTION\n2\nENTITIES\nNOT_A_CODE\nLINE\n".utf8)
        #expect(throws: VectorImportError.self) { try DXFImporter.importDXF(data: data) }
    }

    @Test func unsupportedEntitiesAreReported() throws {
        let pairs: [(Int, String)] = [(0, "MTEXT"), (8, "0"), (10, "0"), (20, "0"), (1, "hi"),
                                      (0, "HATCH"), (8, "0")] + Self.line(0, 0, 1, 1)
        let r = try DXFImporter.importDXF(data: Self.dxf(insunits: 4, pairs))
        #expect(r.polylines.count == 1)
        #expect(r.warnings.contains { $0.contains("MTEXT") })
        #expect(r.warnings.contains { $0.contains("HATCH") })
    }

    // MARK: Borrowed fixtures (gdsestimating/dxf-parser, MIT; see Fixtures/dxf/dxf-parser/SOURCE.md)

    static func borrowedData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "dxf", subdirectory: "Fixtures/dxf/dxf-parser"),
                               "missing fixture dxf-parser/\(name).dxf")
        return try Data(contentsOf: url)
    }

    @Test func borrowedArcWithNegativeExtrusion() throws {
        let r = try DXFImporter.importDXF(data: Self.borrowedData("arc1"), defaultUnit: .mm)
        #expect(r.warnings.contains { $0.contains("$INSUNITS") })
        #expect(r.polylines.count == 1)
        let arc = try #require(r.polylines.first)
        #expect(!arc.isClosed)
        let cx = 650.0541823996996, cy = 347.5909732684974, radius = 0.7604262403327394
        let a0 = 338.8998819521181.radians, a1 = 355.0752244008874.radians
        // OCS points mirrored in X because the extrusion is (0,0,-1).
        let start = Vec2(-(cx + radius * cos(a0)), cy + radius * sin(a0))
        let end = Vec2(-(cx + radius * cos(a1)), cy + radius * sin(a1))
        #expect(Self.near(arc.points.first!, start, 1e-9) && Self.near(arc.points.last!, end, 1e-9))
        for p in arc.points { #expect(abs(p.distance(to: Vec2(-cx, cy)) - radius) < 1e-9) }
        #expect(abs(arc.length - radius * (a1 - a0)) < 1e-3)
    }

    @Test func borrowedRationalSplineCircles() throws {
        let r = try DXFImporter.importDXF(data: Self.borrowedData("arcs-as-splines"), defaultUnit: .mm)
        #expect(r.polylines.count == 3)
        let circles: [(Vec2, Double)] = [
            (Vec2(201.3461153580332, 180.0700474977344), 233.6663114494559 - 201.3461153580332),
            (Vec2(201.3461153580332, 243.2413398582423), 208.6916144697202 - 201.3461153580332),
        ]
        for (c, radius) in circles {
            let loop = try #require(r.polylines.first { $0.isClosed && Self.near($0.bounds.center, c, 0.01) })
            for p in loop.points { #expect(abs(p.distance(to: c) - radius) < 1e-6) }
            #expect(Self.maxSagitta(loop, center: c, radius: radius) <= 0.01 + 1e-6)
        }
        // Open rational quadratic arc: the end tangents point at the middle control point, so the centre is
        // where the end normals meet.
        let p0 = Vec2(280.7529837541637, 303.6705820088653), p1 = Vec2(258.47226626445, 317.9847757821756)
        let p2 = Vec2(232.5957563534457, 323.6179587245282)
        let n0 = (p1 - p0).perpLeft, n2 = (p1 - p2).perpLeft
        let center = p0 + n0 * ((p2 - p0).cross(n2) / n0.cross(n2))
        let radius = center.distance(to: p0)
        #expect(abs(center.distance(to: p2) - radius) < 1e-6)
        let arc = try #require(r.polylines.first { !$0.isClosed })
        for p in arc.points { #expect(abs(p.distance(to: center) - radius) < 1e-5) }
    }

    @Test func borrowedSplinesMatchCoxDeBoorAndFitPoints() throws {
        let data = try Self.borrowedData("splines")
        let r = try DXFImporter.importDXF(data: data, defaultUnit: .mm)
        #expect(r.polylines.count == 2)
        let entities = DXFDocument(pairs: try DXFReader.readPairs(data)).entities.filter { $0.type == "SPLINE" }
        #expect(entities.count == 2)
        for e in entities {
            let knots = e.pairs.filter { $0.code == 40 }.compactMap(\.double)
            let xs = e.pairs.filter { $0.code == 10 }.compactMap(\.double)
            let ys = e.pairs.filter { $0.code == 20 }.compactMap(\.double)
            let control = zip(xs, ys).map { Vec2($0, $1) }
            let degree = e.int(71)
            let lo = knots[degree], hi = knots[control.count]
            let reference = (0...4000).map {
                Self.bspline(lo + (hi - lo) * Double($0) / 4000, degree: degree, knots: knots, control: control)
            }
            let poly = try #require(r.polylines.first { Self.near($0.points.first!, control.first!, 1e-6) })
            #expect(Self.near(poly.points.last!, control.last!, 1e-6))
            #expect(Self.maxDistance(from: poly.points, to: Polyline(reference, closed: false)) < 1e-3)
            #expect(Self.maxDistance(from: reference, to: poly) <= 0.01 + 1e-3)

            // The fit points AutoCAD stored alongside the control points lie on the curve.
            let fx = e.pairs.filter { $0.code == 11 }.compactMap(\.double)
            let fy = e.pairs.filter { $0.code == 21 }.compactMap(\.double)
            for f in zip(fx, fy).map({ Vec2($0, $1) }) {
                #expect(poly.closestPoint(to: f).distance < 0.011)
            }
        }
    }

    @Test func borrowedEllipsesWithRatioAboveOne() throws {
        let r = try DXFImporter.importDXF(data: Self.borrowedData("ellipse"), defaultUnit: .mm)
        #expect(r.polylines.count == 2)
        // The end parameter is 6.283185, a hair short of 2π; the ~1e-5 mm gap is closed by chaining.
        #expect(r.polylines.allSatisfy { $0.isClosed })
        let tilted = try #require(r.polylines.first { $0.bounds.center.y > 0 })
        #expect(abs(tilted.area - .pi * 200 * 1.986299) < 1.5)
        let ext = (100 + (10 * 1.986299) * (10 * 1.986299)).squareRoot()
        #expect(Self.near(tilted.bounds, 10 - ext, 10 - ext, 10 + ext, 10 + ext, 0.011))
        let wide = try #require(r.polylines.first { $0.bounds.center.y < 0 })
        #expect(abs(wide.area - .pi * 100) < 0.5)
        #expect(Self.near(wide.bounds, -20, -10, 20, 0, 0.011))
    }

    @Test func duplicatesAreRemovedBeforeChaining() throws {
        let pairs = Self.line(0, 0, 10, 0) + Self.line(10, 0, 0, 0) + Self.line(10, 0, 10, 10)
            + [(0, "CIRCLE"), (10, "50"), (20, "50"), (40, "5"), (0, "CIRCLE"), (10, "50"), (20, "50"), (40, "5")]
        let r = try DXFImporter.importDXF(data: Self.dxf(insunits: 4, pairs))
        #expect(r.polylines.count == 2)
        #expect(r.polylines.filter { $0.isClosed }.count == 1)
        let open = try #require(r.polylines.first { !$0.isClosed })
        #expect(open.count == 3 && Self.near(open.length, 20, 1e-9))
        #expect(r.warnings.contains { $0.contains("Removed 2 duplicate") })
    }

    // MARK: Dispatch and chaining

    @Test func vectorImporterDispatchesOnExtension() throws {
        let dxf = try VectorImporter.importFile(at: Self.fixtureURL("rect_lines_inch"))
        #expect(dxf.polylines.count == 1)
        let svg = try VectorImporter.importFile(at: Self.fixtureURL("units_viewbox_mm", "svg"))
        #expect(svg.polylines.count == 1)
        #expect(throws: VectorImportError.unsupportedFileType("txt")) {
            try VectorImporter.importFile(at: URL(fileURLWithPath: "/tmp/nothing.txt"))
        }
    }

    @Test func chainerJoinsReversedPiecesAndLeavesGapsOpen() {
        let pieces = [
            Polyline([Vec2(0, 0), Vec2(10, 0)], closed: false),
            Polyline([Vec2(5, 8), Vec2(10, 0)], closed: false), // reversed
            Polyline([Vec2(5, 8), Vec2(0.0005, 0)], closed: false), // within 1e-3 of (0,0)
            Polyline([Vec2(100, 0), Vec2(110, 0)], closed: false),
            Polyline([Vec2(110.5, 0), Vec2(120, 0)], closed: false), // 0.5 gap: stays separate
            Polyline([Vec2(0, 50), Vec2(10, 50), Vec2(10, 60)], closed: true),
        ]
        let out = PathChainer.chain(pieces, tolerance: 1e-3)
        #expect(out.polylines.count == 4)
        #expect(out.openCount == 2)
        #expect(out.closedByChaining == 1)
        let tri = out.polylines.first { $0.isClosed && $0.bounds.max.y < 10 }
        #expect(tri?.count == 3)
        #expect(abs((tri?.area ?? 0) - 40) < 0.01)
        #expect(out.polylines[0] == pieces[5]) // closed inputs pass through first, unchanged
    }

    @Test func chainerJoinsLongShuffledChains() {
        // A 100-gon split into single segments, shuffled deterministically, half of them reversed.
        let n = 100
        let pts = (0..<n).map { Vec2.fromAngle(2 * .pi * Double($0) / Double(n), length: 50) }
        var segs = (0..<n).map { i in Polyline([pts[i], pts[(i + 1) % n]], closed: false) }
        segs = (0..<n).map { segs[($0 * 37) % n] }
        segs = segs.enumerated().map { $0.offset % 2 == 0 ? $0.element.reversed : $0.element }
        let out = PathChainer.chain(segs, tolerance: 1e-3)
        #expect(out.polylines.count == 1)
        #expect(out.polylines.first?.isClosed == true)
        #expect(out.polylines.first?.count == n)
    }
}
