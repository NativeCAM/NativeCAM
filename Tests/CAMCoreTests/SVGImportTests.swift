import Foundation
import Testing
@testable import CAMCore

@Suite struct SVGImportTests {
    // MARK: Helpers

    static func load(_ name: String, tolerance: Double = 0.01, pixelsPerInch: Double? = nil) throws -> ImportResult {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Fixtures/svg"),
                               "missing fixture \(name).svg")
        return try SVGImporter.importSVG(data: Data(contentsOf: url), tolerance: tolerance, pixelsPerInch: pixelsPerInch)
    }

    /// Imports `body` inside a 100 x 100 mm document with 1 user unit = 1 mm (so Y-up y = 100 - y).
    static func svg(_ body: String, tolerance: Double = 0.01) throws -> ImportResult {
        let doc = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="100mm" height="100mm" viewBox="0 0 100 100">\(body)</svg>
        """
        return try SVGImporter.importSVG(data: Data(doc.utf8), tolerance: tolerance)
    }

    static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
    static func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }
    static func near(_ r: Rect2, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double, _ tol: Double = 1e-6) -> Bool {
        near(r.min.x, minX, tol) && near(r.min.y, minY, tol) && near(r.max.x, maxX, tol) && near(r.max.y, maxY, tol)
    }

    /// The polyline whose bounds match (Y-up mm), if exactly one does.
    static func find(_ r: ImportResult, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                     tol: Double = 0.02) -> Polyline? {
        let hits = r.polylines.filter { near($0.bounds, minX, minY, maxX, maxY, tol) }
        return hits.count == 1 ? hits[0] : nil
    }

    static func maxDistance(from samples: [Vec2], to poly: Polyline) -> Double {
        samples.map { poly.closestPoint(to: $0).distance }.max() ?? 0
    }

    // MARK: Units and viewBox

    @Test func viewBoxWithMillimetreSize() throws {
        let r = try Self.load("units_viewbox_mm")
        #expect(r.sourceUnits == .mm)
        #expect(Self.near(r.unitScale, 0.5))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.polylines.count == 1)
        let p = try #require(r.polylines.first)
        #expect(p.isClosed)
        #expect(Self.near(p.area, 600, 1e-9))
        // User (20..80, 20..60) * 0.5 mm, flipped about the 50 mm page height.
        #expect(Self.near(p.bounds, 10, 20, 40, 40))
    }

    @Test func inchSizedDocument() throws {
        let r = try Self.load("units_inch")
        #expect(r.sourceUnits == .inch)
        #expect(r.polylines.count == 2)
        let square = try #require(Self.find(r, 0, 25.4, 25.4, 50.8))
        #expect(Self.near(square.area, 645.16, 1e-6))
        let circle = try #require(Self.find(r, 76.2 - 12.7, 25.4 - 12.7, 76.2 + 12.7, 25.4 + 12.7))
        #expect(circle.isClosed)
        for p in circle.points { #expect(Self.near(p.distance(to: Vec2(76.2, 25.4)), 12.7, 1e-9)) }
        for i in 0..<circle.segmentCount {
            let (a, b) = circle.segment(i)
            #expect(12.7 - ((a + b) * 0.5).distance(to: Vec2(76.2, 25.4)) <= 0.01 + 1e-9)
        }
    }

    @Test func unitlessDocumentUses96PixelsPerInch() throws {
        let r = try Self.load("px_default")
        #expect(r.sourceUnits == nil)
        #expect(r.warnings.contains { $0.contains("96 px per inch") })
        let p = try #require(r.polylines.first)
        #expect(Self.near(p.bounds, 0, 12.7, 25.4, 25.4))
    }

    @Test func illustratorFilesUse72PixelsPerInch() throws {
        let r = try Self.load("illustrator_72dpi")
        #expect(r.warnings.contains { $0.contains("Illustrator") })
        #expect(Self.near(try #require(r.polylines.first).bounds, 0, 12.7, 25.4, 25.4))
        let forced = try Self.load("illustrator_72dpi", pixelsPerInch: 96)
        #expect(Self.near(try #require(forced.polylines.first).bounds, 0, 9.525, 19.05, 19.05))
    }

    @Test func preserveAspectRatioMeetCentres() throws {
        let doc = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="50mm" viewBox="0 0 100 100">\
        <rect width="100" height="100"/></svg>
        """
        let r = try SVGImporter.importSVG(data: Data(doc.utf8))
        #expect(Self.near(try #require(r.polylines.first).bounds, 25, 0, 75, 50))
        let none = doc.replacingOccurrences(of: "viewBox", with: "preserveAspectRatio=\"none\" viewBox")
        let s = try SVGImporter.importSVG(data: Data(none.utf8))
        #expect(Self.near(try #require(s.polylines.first).bounds, 0, 0, 100, 50))
    }

    @Test func percentLengthsAndMissingSize() throws {
        let doc = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200mm" height="100mm" viewBox="0 0 200 100">\
        <rect x="10%" width="50%" height="50%"/></svg>
        """
        let r = try SVGImporter.importSVG(data: Data(doc.utf8))
        #expect(Self.near(try #require(r.polylines.first).bounds, 20, 50, 120, 100))

        // No size and no viewBox: CSS px, flipped about the drawing's own extent.
        let bare = #"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="96" height="96"/></svg>"#
        let b = try SVGImporter.importSVG(data: Data(bare.utf8))
        #expect(Self.near(try #require(b.polylines.first).bounds, 0, 0, 25.4, 25.4))
    }

    // MARK: Path data

    @Test func pathCommandsFixture() throws {
        let r = try Self.load("path_commands")
        func y(_ user: Double) -> Double { 200 - user }

        for minX in [10.0, 50, 90, 130] {
            let sq = try #require(Self.find(r, minX, y(30), minX + 20, y(10)), "square at \(minX)")
            #expect(sq.isClosed && Self.near(sq.area, 400, 1e-9))
        }
        let tri = try #require(Self.find(r, 10, y(70), 30, y(50)))
        #expect(Self.near(tri.area, 200, 1e-9))
        let trap = try #require(Self.find(r, 50, y(70), 70, y(50)))
        #expect(Self.near(trap.area, 300, 1e-9))

        // Packed arc flags "1020 0" (sweep 0): the half disk bulges to user y = 110, i.e. below the chord once flipped.
        let halfDisk = try #require(Self.find(r, 10, y(110), 30, y(100)))
        #expect(halfDisk.isClosed)
        #expect(abs(halfDisk.area - .pi * 50) < 0.3)

        // Packed "0110 10": quarter circle about user (50,110).
        let quarter = try #require(Self.find(r, 50, y(110), 60, y(100)))
        #expect(!quarter.isClosed)
        #expect(abs(quarter.length - .pi * 5) < 0.01)
        for p in quarter.points { #expect(Self.near(p.distance(to: Vec2(50, y(110))), 10, 1e-9)) }

        // C + S (reflected control point), Q + T.
        let cubic = try #require(Self.find(r, 90, y(131.25), 130, y(108.75), tol: 0.011))
        #expect(!cubic.isClosed)
        let quad = try #require(Self.find(r, 140, y(130), 180, y(110), tol: 0.011))
        #expect(!quad.isClosed)
        #expect(Self.find(r, 10, y(165), 50, y(135), tol: 0.011) != nil) // relative c/s
        #expect(Self.find(r, 60, y(160), 100, y(140), tol: 0.011) != nil) // relative q/t

        // Full ellipse from two arcs.
        let ellipse = try #require(Self.find(r, 130, y(170), 170, y(150)))
        #expect(ellipse.isClosed)
        #expect(abs(ellipse.area - .pi * 200) < 0.6)

        // Two subpaths in one path element.
        #expect(Self.near(try #require(Self.find(r, 10, y(195), 40, y(180))).area, 450, 1e-9))
        #expect(Self.near(try #require(Self.find(r, 15, y(190), 20, y(185))).area, 25, 1e-9))

        #expect(r.closedPolylines.count == 10)
        #expect(r.openPolylines.count == 5)
        #expect(r.warnings.contains { $0.contains("5 open paths") })
    }

    @Test func cubicStaysWithinTolerance() throws {
        let r = try Self.svg(#"<path d="M10 90 C10 10 90 10 90 90"/>"#, tolerance: 0.005)
        let p = try #require(r.polylines.first)
        let p0 = Vec2(10, 10), c1 = Vec2(10, 90), c2 = Vec2(90, 90), p1 = Vec2(90, 10) // Y-up
        let reference = (0...4000).map { i -> Vec2 in
            let t = Double(i) / 4000, mt = 1 - t
            return p0 * (mt * mt * mt) + c1 * (3 * mt * mt * t) + c2 * (3 * mt * t * t) + p1 * (t * t * t)
        }
        #expect(Self.maxDistance(from: reference, to: p) <= 0.005 + 1e-4)
    }

    @Test func numberGrammar() throws {
        // "-.5.5" is two numbers; "1.5e-3" and "1E+1" are exponents.
        let r = try Self.svg(#"<path d="M0 0L-.5.5"/><path d="M20 20L1.5e-3,20L1E+1-1e1"/>"#)
        let a = try #require(r.polylines.first { $0.bounds.min.x < 0 })
        #expect(Self.near(a.points.last!, Vec2(-0.5, 99.5)) || Self.near(a.points.first!, Vec2(-0.5, 99.5)))
        let b = try #require(r.polylines.first { $0.count == 3 })
        #expect(b.points.contains { Self.near($0, Vec2(0.0015, 80)) })
        #expect(b.points.contains { Self.near($0, Vec2(10, 110)) })
    }

    @Test func arcFlagsWithoutSeparators() throws {
        // The example from the SVG spec style "a1 1 0 01 1 1": rx=ry=1, large=0, sweep=1, to (+1,+1).
        let r = try Self.svg(#"<path d="M10 10a1 1 0 01 1 1"/>"#)
        let p = try #require(r.polylines.first)
        #expect(abs(p.length - .pi / 2) < 0.01)
        // Centre at user (10,11) -> Y-up (10,89).
        for q in p.points { #expect(Self.near(q.distance(to: Vec2(10, 89)), 1, 1e-9)) }
        // Same arc written with separators gives the same points.
        let spaced = try Self.svg(#"<path d="M10 10 a 1,1 0 0,1 1,1"/>"#)
        #expect(spaced.polylines.first?.points == p.points)
    }

    @Test func closePathThenDrawStartsAtSubpathStart() throws {
        let r = try Self.svg(#"<path d="M10 10 h10 v10 z l5 5"/>"#)
        #expect(r.polylines.count == 2)
        let line = try #require(r.polylines.first { !$0.isClosed })
        #expect(Set(line.points.map { "\($0.x),\($0.y)" }) == ["10.0,90.0", "15.0,85.0"])
    }

    @Test func malformedPathDrawsUpToTheError() throws {
        let r = try Self.svg(#"<path d="M0 0 L10 0 L10 10 X 5 5"/>"#)
        let p = try #require(r.polylines.first)
        #expect(p.count == 3)
        #expect(r.warnings.contains { $0.contains("Path data error") })
        let noMove = try Self.svg(#"<path d="L10 10"/>"#)
        #expect(noMove.polylines.isEmpty)
    }

    // MARK: Transforms and structure

    @Test func transformsFixture() throws {
        let r = try Self.load("transforms")
        func y(_ user: Double) -> Double { 200 - user }
        #expect(r.polylines.count == 8)
        #expect(r.polylines.allSatisfy { $0.isClosed })
        #expect(Self.near(try #require(Self.find(r, 100, y(20), 120, y(0))).area, 400, 1e-9)) // nested groups
        #expect(Self.near(try #require(Self.find(r, 5, y(65), 15, y(45))).area, 200, 1e-9)) // rotate(a cx cy)
        #expect(Self.near(try #require(Self.find(r, 50, y(53), 52, y(50))).area, 6, 1e-9)) // list order
        #expect(Self.near(try #require(Self.find(r, 0, y(110), 30, y(100))).area, 200, 1e-9)) // skewX
        #expect(Self.find(r, 150, y(160), 160, y(150)) != nil) // matrix
        #expect(Self.near(try #require(Self.find(r, 150, y(40), 190, y(20))).area, 800, 1e-9)) // nested svg
        #expect(Self.near(try #require(Self.find(r, 100, y(190), 110, y(170))).area, 200, 1e-9)) // rotate(-90)
        #expect(Self.near(try #require(Self.find(r, 150, y(120), 160, y(100))).area, 100, 1e-9)) // skewY
    }

    @Test func nonUniformScaleKeepsToleranceInMillimetres() throws {
        // A circle squashed 1 x 4 by a transform must still be within tolerance of the true ellipse.
        let r = try Self.svg(#"<circle cx="10" cy="5" r="5" transform="scale(4,1)"/>"#, tolerance: 0.01)
        let p = try #require(r.polylines.first)
        let reference = (0..<20000).map { i -> Vec2 in
            let t = 2 * Double.pi * Double(i) / 20000
            return Vec2(40 + 20 * cos(t), 95 + 5 * sin(t))
        }
        #expect(Self.maxDistance(from: reference, to: p) <= 0.01 + 1e-4)
    }

    @Test func hiddenDefsAndUse() throws {
        let r = try Self.load("hidden_defs")
        func y(_ user: Double) -> Double { 100 - user }
        #expect(r.polylines.count == 4)
        #expect(Self.near(try #require(Self.find(r, 10, y(30), 30, y(10))).area, 400, 1e-9)) // plain rect
        #expect(Self.near(try #require(Self.find(r, 50, y(60), 60, y(50))).area, 100, 1e-9)) // use x/y
        #expect(Self.near(try #require(Self.find(r, 70, y(20), 80, y(10))).area, 50, 1e-9)) // use + transform, xlink:href
        #expect(Self.near(try #require(Self.find(r, 10, y(90), 30, y(70))).area, 400, 1e-9)) // symbol viewBox
        #expect(r.warnings.contains { $0.contains("#missing") })
        #expect(r.warnings.contains { $0.contains("<text>") })
    }

    @Test func basicShapes() throws {
        let r = try Self.load("shapes")
        func y(_ user: Double) -> Double { 100 - user }
        #expect(r.closedPolylines.count == 6)
        #expect(r.openPolylines.count == 2)

        let circle = try #require(Self.find(r, 10, y(30), 30, y(10)))
        #expect(abs(circle.area - .pi * 100) < 0.5)
        let ellipse = try #require(Self.find(r, 40, y(30), 80, y(10)))
        #expect(abs(ellipse.area - .pi * 200) < 0.6)
        let rounded = 800 - (4 - Double.pi) * 25
        #expect(abs(try #require(Self.find(r, 100, y(30), 140, y(10))).area - rounded) < 0.3) // rx only
        #expect(abs(try #require(Self.find(r, 150, y(30), 190, y(10))).area - rounded) < 0.3) // ry only
        #expect(Self.near(try #require(Self.find(r, 100, y(80), 140, y(50))).area, 600, 1e-9)) // polygon

        // Four separate <line>s chain into one closed rectangle.
        let chained = try #require(Self.find(r, 150, y(80), 190, y(50)))
        #expect(chained.isClosed && Self.near(chained.area, 1200, 1e-9))

        #expect(Self.near(try #require(Self.find(r, 10, y(50), 40, y(50))).length, 30, 1e-9)) // line
        #expect(Self.near(try #require(Self.find(r, 60, y(70), 80, y(50))).length, 40, 1e-9)) // polyline
    }

    @Test func displayNoneAndInvalidTransform() throws {
        let r = try Self.svg("""
        <g display="none"><rect width="10" height="10"/></g>\
        <rect style="display:none" width="10" height="10"/>\
        <rect x="20" y="20" width="10" height="10" transform="translate(5 nope)"/>
        """)
        #expect(r.polylines.count == 1)
        #expect(Self.near(try #require(r.polylines.first).bounds, 20, 70, 30, 80))
        #expect(r.warnings.contains { $0.contains("invalid transform") })
    }

    // MARK: Borrowed fixtures (linebender/resvg, MIT; see Fixtures/svg/resvg/SOURCE.md)

    /// resvg tests use viewBox 0 0 200 200 with no size: 96 px per inch, flipped about 200 px.
    static let px = 25.4 / 96
    static func mm(_ x: Double, _ y: Double) -> Vec2 { Vec2(x * px, (200 - y) * px) }

    /// Imports a resvg fixture and returns the result plus its polylines minus the 198 x 198 frame rectangle.
    static func loadResvg(_ name: String) throws -> (ImportResult, [Polyline]) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Fixtures/svg/resvg"),
                               "missing fixture resvg/\(name).svg")
        let r = try SVGImporter.importSVG(data: Data(contentsOf: url))
        let frame = 198 * px
        let content = r.polylines.filter { !(abs($0.bounds.width - frame) < 1e-6 && abs($0.bounds.height - frame) < 1e-6) }
        #expect(content.count == r.polylines.count - 1, "frame not found")
        return (r, content)
    }

    @Test func resvgPackedArcMatchesSpacedArc() throws {
        // path1 "A 5.5 0.3 -4 0 1 0 -0.1" and path2 "A5.5.3-4 010-.1" import identically, so one is a duplicate.
        let (r, content) = try Self.loadResvg("path-M-A-trimmed")
        #expect(content.count == 1)
        #expect(r.warnings.contains { $0.contains("Removed 1 duplicate") })
        let p = try #require(content.first)
        #expect(!p.isClosed)
        let ends = [p.points.first!, p.points.last!]
        #expect(ends.contains { Self.near($0, Self.mm(20, 20)) } && ends.contains { Self.near($0, Self.mm(10, 39.9)) })
        #expect(p.count > 10) // radii too small for the chord are scaled up, not replaced by a line
    }

    @Test func resvgArcFlagsWithoutSeparators() throws {
        let (r, content) = try Self.loadResvg("path-no-commawsp-between-and-after-arc-flags")
        #expect(content.count == 1)
        #expect(r.warnings.contains { $0.contains("Removed 1 duplicate") })
        let pie = try #require(content.first)
        #expect(pie.isClosed)
        #expect(abs(pie.area - 0.75 * .pi * 625 * Self.px * Self.px) < 0.3)
        #expect(pie.points.contains { Self.near($0, Self.mm(100, 100)) })
    }

    @Test func resvgMalformedArcFlagStopsThePath() throws {
        // "a 25 2501 025 -25": the large-arc flag position holds "-", so path2 stops after "h -25".
        let (r, content) = try Self.loadResvg("path-no-commawsp-before-arc-flags")
        #expect(content.count == 2)
        let pie = try #require(content.first { $0.isClosed })
        #expect(abs(pie.area - 0.75 * .pi * 625 * Self.px * Self.px) < 0.3)
        let stub = try #require(content.first { !$0.isClosed })
        #expect(stub.count == 2)
        #expect(Set(stub.points.map { "\(($0.x / Self.px).rounded()),\(200 - ($0.y / Self.px).rounded())" }) == ["100.0,100.0", "75.0,100.0"])
        #expect(r.warnings.contains { $0.contains("Path data error") })
    }

    @Test func resvgInvalidLinetoDataRendersUpToTheError() throws {
        let (r, content) = try Self.loadResvg("path-invalid-data-in-L")
        #expect(content.count == 1)
        let p = try #require(content.first)
        #expect(p.count == 2 && Self.near(p.points[0], Self.mm(30, 40)) && Self.near(p.points[1], Self.mm(110, 160)))
        #expect(r.warnings.contains { $0.contains("Path data error") })
        #expect(r.warnings.contains { $0.contains("Removed 1 duplicate") })
    }

    @Test func resvgNumericCharacterReferences() throws {
        let (r, content) = try Self.loadResvg("path-numeric-character-references")
        #expect(content.count == 1)
        let p = try #require(content.first)
        #expect(Self.near(p.points[0], Self.mm(10, 10)) && Self.near(p.points[1], Self.mm(190, 190)))
        #expect(r.warnings.contains { $0.contains("Removed 1 duplicate") })
    }

    @Test func resvgMatrixAndNestedTransformsMatchReferencePolygons() throws {
        let cases: [(String, [Vec2])] = [
            ("transform-matrix-no-commas",
             [Self.mm(87.756, 40.104), Self.mm(178.584, 65.268), Self.mm(108.024, 152.136), Self.mm(17.196, 126.972)]),
            ("transform-nested-transforms-1", [Self.mm(60, 20), Self.mm(140, 100), Self.mm(140, 180), Self.mm(60, 100)]),
        ]
        for (name, expected) in cases {
            // The transformed green rect coincides with the red reference polygon, so one is dropped as a duplicate.
            let (r, content) = try Self.loadResvg(name)
            #expect(content.count == 1, "\(name)")
            #expect(r.warnings.contains { $0.contains("Removed 1 duplicate") }, "\(name)")
            let quad = try #require(content.first)
            #expect(quad.isClosed && quad.count == 4)
            for e in expected { #expect(quad.points.contains { Self.near($0, e, 1e-6) }, "\(name) \(e)") }
        }
    }

    @Test func resvgRotateAboutAPoint() throws {
        let (_, content) = try Self.loadResvg("transform-rotate-at-position")
        // The red reference in this file has a 1-unit typo at its second vertex (183.85 instead of 184.85),
        // so both loops survive; check the rotated rect against hand-computed corners.
        #expect(content.count == 2)
        let r2 = 2.0.squareRoot()
        let corners = [Self.mm(100, 50 - 25 * r2), Self.mm(100 + 60 * r2, 50 + 35 * r2),
                       Self.mm(100, 50 + 95 * r2), Self.mm(100 - 60 * r2, 50 + 35 * r2)]
        let rotated = content.filter { poly in corners.allSatisfy { c in poly.points.contains { Self.near($0, c, 1e-6) } } }
        #expect(rotated.count == 1)
    }

    @Test func resvgZeroedMatrixRendersNothing() throws {
        let (_, content) = try Self.loadResvg("transform-zeroed-matrix")
        #expect(content.isEmpty)
    }

    @Test func notSVGOrBrokenXMLThrows() {
        #expect(throws: VectorImportError.self) {
            try SVGImporter.importSVG(data: Data("<html><body/></html>".utf8))
        }
        #expect(throws: VectorImportError.self) {
            try SVGImporter.importSVG(data: Data("not xml at all".utf8))
        }
    }
}
