import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CAMCore

@Suite struct PDFImportTests {
    // MARK: Helpers

    /// Millimetres per PDF point.
    static let mm = 25.4 / 72

    /// Renders one page per closure with CoreGraphics' PDF context (US Letter unless `mediaBox` says otherwise).
    static func makePDF(mediaBox: CGRect = CGRect(x: 0, y: 0, width: 612, height: 792),
                        auxiliaryInfo: [CFString: Any]? = nil, pages: [(CGContext) -> Void]) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = mediaBox
        let ctx = CGContext(consumer: consumer, mediaBox: &box, auxiliaryInfo as CFDictionary?)!
        for draw in pages {
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func makePDF(mediaBox: CGRect = CGRect(x: 0, y: 0, width: 612, height: 792),
                        auxiliaryInfo: [CFString: Any]? = nil, _ draw: (CGContext) -> Void) -> Data {
        withoutActuallyEscaping(draw) { makePDF(mediaBox: mediaBox, auxiliaryInfo: auxiliaryInfo, pages: [$0]) }
    }

    /// A hand-written one-page PDF (612 x 792 pt) whose content stream is `content`. `extraObjects` are numbered
    /// from 5 (1 catalog, 2 page tree, 3 page, 4 content stream). Lets tests use operators CoreGraphics never writes.
    static func rawPDF(_ content: String, resources: String = "<< >>", pageExtras: String = "",
                       extraObjects: [String] = []) -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources \(resources) /Contents 4 0 R \(pageExtras) >>",
            stream(content),
        ] + extraObjects
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static func stream(_ content: String, dict: String = "") -> String {
        "<< \(dict) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    /// Number of XObjects in page 1's resources (to check a test really goes through `Do`).
    static func pageXObjectCount(_ data: Data) -> Int {
        guard let page = CGPDFDocument(CGDataProvider(data: data as CFData)!)?.page(at: 1), let dict = page.dictionary
        else { return 0 }
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return 0 }
        return CGPDFDictionaryGetCount(xobjects)
    }

    static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
    static func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }
    static func near(_ r: Rect2, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                     _ tol: Double = 1e-6) -> Bool {
        near(r.min.x, minX, tol) && near(r.min.y, minY, tol) && near(r.max.x, maxX, tol) && near(r.max.y, maxY, tol)
    }

    /// Bounds given in points, compared in mm.
    static func nearPt(_ r: Rect2, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                       _ tol: Double = 1e-6) -> Bool {
        near(r, minX * mm, minY * mm, maxX * mm, maxY * mm, tol)
    }

    /// True when every expected point (mm) is a vertex of `poly`.
    static func hasVertices(_ poly: Polyline, _ expected: [Vec2], _ tol: Double = 1e-6) -> Bool {
        expected.allSatisfy { e in poly.points.contains { near($0, e, tol) } }
    }

    // MARK: Basic shapes (CoreGraphics-generated)

    @Test func filledRectangleBecomesOneClosedLoop() throws {
        // 2in x 1in at (1in, 2in) from the page corner.
        let data = Self.makePDF { ctx in
            ctx.addRect(CGRect(x: 72, y: 144, width: 144, height: 72))
            ctx.fillPath()
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        let loop = try #require(r.polylines.first)
        #expect(loop.isClosed)
        #expect(loop.count == 4)
        #expect(Self.near(loop.area, 1290.32, 0.01)) // 50.8 mm x 25.4 mm
        #expect(Self.near(loop.bounds, 25.4, 50.8, 76.2, 76.2, 1e-6))
        #expect(r.sourceUnits == nil)
        #expect(Self.near(r.unitScale, 25.4 / 72, 1e-12))
        #expect(r.points.isEmpty)
    }

    @Test func circleIsFlattenedWithinTolerance() throws {
        let center = CGPoint(x: 306, y: 396)
        let data = Self.makePDF { ctx in
            ctx.addEllipse(in: CGRect(x: center.x - 72, y: center.y - 72, width: 144, height: 144))
            ctx.fillPath()
        }
        let r = try PDFImporter.importPDF(data: data, tolerance: 0.01)
        #expect(r.polylines.count == 1)
        let loop = try #require(r.polylines.first)
        #expect(loop.isClosed)
        let expected = Double.pi * 25.4 * 25.4
        #expect(abs(loop.area - expected) / expected < 0.002)
        let c = Vec2(306 * Self.mm, 396 * Self.mm)
        #expect(Self.near(loop.bounds.center, c, 0.01))
        // Vertices lie on the Bézier circle (which bulges up to 0.027% of r ≈ 0.007 mm outside the true circle).
        for p in loop.points { #expect(abs(p.distance(to: c) - 25.4) < 0.01) }
    }

    @Test func curveToleranceAccountsForTheCTM() throws {
        // A 1 pt circle scaled 100x: flattening must happen at the drawn size (35.3 mm radius), not the local one.
        let data = Self.makePDF { ctx in
            ctx.translateBy(x: 300, y: 400)
            ctx.scaleBy(x: 100, y: 100)
            ctx.addEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
            ctx.strokePath()
        }
        let tol = 0.01
        let r = try PDFImporter.importPDF(data: data, tolerance: tol)
        let loop = try #require(r.closedPolylines.first)
        let c = Vec2(300 * Self.mm, 400 * Self.mm)
        let radius = 100 * Self.mm
        var worstSag = 0.0
        for i in 0..<loop.count {
            let a = loop.points[i], b = loop.points[(i + 1) % loop.count]
            worstSag = max(worstSag, radius - ((a + b) * 0.5).distance(to: c))
        }
        #expect(worstSag <= tol + 1e-3)
        #expect(loop.points.allSatisfy { abs($0.distance(to: c) - radius) < 0.011 })
    }

    @Test func scaledRotatedCTMTransformsGeometry() throws {
        let data = Self.makePDF { ctx in
            ctx.translateBy(x: 200, y: 300)
            ctx.rotate(by: .pi / 6)
            ctx.scaleBy(x: 2, y: 0.5)
            ctx.addRect(CGRect(x: 0, y: 0, width: 72, height: 72))
            ctx.fillPath()
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        let loop = try #require(r.polylines.first)
        #expect(loop.isClosed)
        // Corners by hand: scale (2, 0.5), rotate 30° (cos 0.8660254, sin 0.5), translate (200, 300), then pt → mm.
        let s3 = 3.0.squareRoot() / 2
        let cornersPt = [
            Vec2(200, 300),
            Vec2(200 + 144 * s3, 300 + 72),
            Vec2(200 + 144 * s3 - 18, 300 + 72 + 36 * s3),
            Vec2(200 - 18, 300 + 36 * s3),
        ]
        // CoreGraphics writes the matrix with about six significant digits.
        #expect(Self.hasVertices(loop, cornersPt.map { $0 * Self.mm }, 1e-3))
        #expect(Self.near(loop.area, 645.16, 0.01)) // 2in x 0.5in = 1 in²
    }

    // MARK: Painting and clipping

    @Test func clippingPathIsNotImported() throws {
        let data = Self.makePDF { ctx in
            ctx.addRect(CGRect(x: 10, y: 10, width: 500, height: 700))
            ctx.clip()
            ctx.clip(to: CGRect(x: 20, y: 20, width: 400, height: 400))
            ctx.move(to: CGPoint(x: 100, y: 100))
            ctx.addLine(to: CGPoint(x: 300, y: 100))
            ctx.strokePath()
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.closedPolylines.isEmpty)
        #expect(r.polylines.count == 1)
        let line = try #require(r.openPolylines.first)
        #expect(line.count == 2)
        #expect(Self.nearPt(line.bounds, 100, 100, 300, 100))
    }

    @Test func fillAndStrokeOfTheSamePathCollapse() throws {
        let data = Self.makePDF { ctx in
            // One `B` operator.
            ctx.addRect(CGRect(x: 50, y: 50, width: 100, height: 100))
            ctx.drawPath(using: .fillStroke)
            // Filled, then stroked separately; the stroke returns to its start without a closepath.
            let pts = [CGPoint(x: 300, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 400),
                       CGPoint(x: 300, y: 400), CGPoint(x: 300, y: 300)]
            ctx.addLines(between: pts)
            ctx.fillPath()
            ctx.addLines(between: pts)
            ctx.strokePath()
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 2)
        #expect(r.polylines.allSatisfy { $0.isClosed })
        #expect(r.polylines.allSatisfy { Self.near($0.area, 100 * 100 * Self.mm * Self.mm, 1e-6) })
        #expect(r.warnings.contains { $0.contains("duplicate") })
    }

    @Test func strokedSegmentsChainIntoALoop() throws {
        let data = Self.makePDF { ctx in
            let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 244, y: 100), CGPoint(x: 244, y: 172), CGPoint(x: 100, y: 172)]
            for i in 0..<4 {
                ctx.move(to: corners[i])
                ctx.addLine(to: corners[(i + 1) % 4])
                ctx.strokePath()
            }
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        let loop = try #require(r.closedPolylines.first)
        #expect(Self.near(loop.area, 1290.32, 0.01))
        #expect(!r.warnings.contains { $0.contains("left open") })
    }

    @Test func openStrokeStaysOpenWithWarning() throws {
        let data = Self.makePDF { ctx in
            ctx.move(to: CGPoint(x: 100, y: 100))
            ctx.addCurve(to: CGPoint(x: 300, y: 100), control1: CGPoint(x: 150, y: 200), control2: CGPoint(x: 250, y: 200))
            ctx.strokePath()
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        #expect(r.openPolylines.count == 1)
        #expect(r.warnings.contains { $0.contains("1 open path left open") })
    }

    // MARK: Form XObjects

    @Test func nestedFormXObjectsAreTranslated() throws {
        // CoreGraphics inlines simple pages it draws into a PDF; a transparency layer makes it write a Form XObject.
        let a = Self.makePDF(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 200)) { ctx in
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addRect(CGRect(x: 10, y: 20, width: 50, height: 30))
            ctx.fillPath()
            ctx.endTransparencyLayer()
        }
        let pageA = try #require(CGPDFDocument(CGDataProvider(data: a as CFData)!)?.page(at: 1))
        let b = Self.makePDF { ctx in
            ctx.translateBy(x: 100, y: 150)
            ctx.drawPDFPage(pageA)
        }
        #expect(Self.pageXObjectCount(b) > 0)
        let rb = try PDFImporter.importPDF(data: b)
        #expect(rb.polylines.count == 1) // the clip paths CoreGraphics wraps around the form are not imported
        let loopB = try #require(rb.closedPolylines.first)
        #expect(Self.nearPt(loopB.bounds, 110, 170, 160, 200, 1e-6))

        // B drawn into C: a form inside a form.
        let pageB = try #require(CGPDFDocument(CGDataProvider(data: b as CFData)!)?.page(at: 1))
        let c = Self.makePDF { ctx in
            ctx.translateBy(x: -100, y: 10)
            ctx.drawPDFPage(pageB)
        }
        #expect(Self.pageXObjectCount(c) > 0)
        let rc = try PDFImporter.importPDF(data: c)
        #expect(rc.polylines.count == 1)
        let shape1 = try #require(rc.closedPolylines.first)
        #expect(Self.nearPt(shape1.bounds, 10, 180, 60, 210, 1e-6))
    }

    @Test func formMatrixAndInheritedResources() throws {
        // The form has a /Matrix and no /Resources of its own; it draws a nested form found in the page's resources.
        let data = Self.rawPDF(
            "q 1 0 0 1 100 0 cm /Outer Do Q",
            resources: "<< /XObject << /Outer 5 0 R /Inner 6 0 R >> >>",
            extraObjects: [
                Self.stream("0 0 10 10 re f /Inner Do",
                            dict: "/Type /XObject /Subtype /Form /BBox [0 0 1000 1000] /Matrix [2 0 0 2 0 50]"),
                Self.stream("q 1 0 0 1 20 0 cm 0 0 5 5 re f Q",
                            dict: "/Type /XObject /Subtype /Form /BBox [0 0 1000 1000]"),
            ])
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 2)
        // Outer square: (0..10) scaled 2, +(100, 50). Inner: (20..25) scaled 2, same offset.
        #expect(r.polylines.contains { Self.nearPt($0.bounds, 100, 50, 120, 70) })
        #expect(r.polylines.contains { Self.nearPt($0.bounds, 140, 50, 150, 60) })
    }

    @Test func recursiveFormXObjectTerminates() throws {
        // Form 5 draws a square and then itself twice: must not loop or blow up.
        let data = Self.rawPDF(
            "/X Do",
            resources: "<< /XObject << /X 5 0 R >> >>",
            extraObjects: [
                Self.stream("0 0 72 72 re f /X Do /X Do",
                            dict: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /XObject << /X 5 0 R >> >>"),
            ])
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        #expect(r.warnings.contains { $0.contains("recursive") })
    }

    // MARK: Hand-written operators

    @Test func pathOperators() throws {
        let data = Self.rawPDF("""
        10 10 m 110 10 l 110 100 l h S
        200 10 m 300 10 l 300 100 l s
        400 10 m 500 10 l 500 100 l f
        72 200 144 72 re n
        500 400 m 600 400 l 600 500 l b*
        100 600 m 100 700 200 700 v S
        300 600 m 300 700 400 700 y S
        """)
        let r = try PDFImporter.importPDF(data: data, tolerance: 0.001)
        // Triangles closed by h, s, the fill and b* (all 100 pt wide); the `re n` path is discarded.
        #expect(r.closedPolylines.count == 4)
        for (x0, height) in [(10.0, 90.0), (200, 90), (400, 90), (500, 100)] {
            let tri = try #require(r.closedPolylines.first { Self.near($0.bounds.min.x, x0 * Self.mm, 1e-6) })
            #expect(tri.count == 3)
            #expect(Self.near(tri.area, 100 * height / 2 * Self.mm * Self.mm, 1e-6))
        }
        #expect(!r.polylines.contains { Self.nearPt($0.bounds, 72, 200, 216, 272) })
        // `v`: first control = current point. B(0.5) = 0.5·P0 + 0.375·C2 + 0.125·P3 = (112.5, 650).
        let v = try #require(r.openPolylines.first { Self.near($0.bounds.min.x, 100 * Self.mm, 1e-6) })
        #expect(v.closestPoint(to: Vec2(112.5, 650) * Self.mm).distance < 0.002)
        #expect(Self.near(v.points.last!, Vec2(200, 700) * Self.mm))
        // `y`: second control = end point. B(0.5) = 0.125·P0 + 0.375·C1 + 0.5·P3 = (350, 687.5).
        let y = try #require(r.openPolylines.first { Self.near($0.bounds.min.x, 300 * Self.mm, 1e-6) })
        #expect(y.closestPoint(to: Vec2(350, 687.5) * Self.mm).distance < 0.002)
    }

    @Test func clipThenPaintWithoutNewMove() throws {
        // After `h` a segment operator starts a new subpath at the closed subpath's start point.
        let data = Self.rawPDF("0 0 612 792 re W n 100 100 m 200 100 l 200 200 l h 100 300 l S")
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.closedPolylines.count == 1)
        #expect(r.openPolylines.count == 1)
        let tail = try #require(r.openPolylines.first)
        #expect(Self.near(tail.points[0], Vec2(100, 100) * Self.mm))
        #expect(Self.near(tail.points[1], Vec2(100, 300) * Self.mm))
    }

    @Test func cropBoxRotationAndUserUnit() throws {
        // Relative to the crop box origin.
        let cropped = Self.rawPDF("36 72 72 72 re f", pageExtras: "/CropBox [36 72 576 720]")
        let rc = try PDFImporter.importPDF(data: cropped)
        let shape2 = try #require(rc.polylines.first)
        #expect(Self.near(shape2.bounds, 0, 0, 25.4, 25.4))

        // /Rotate 90 (clockwise): (x, y) → (y, 612 − x).
        let rotated = Self.rawPDF("0 0 72 144 re f", pageExtras: "/Rotate 90")
        let rr = try PDFImporter.importPDF(data: rotated)
        let shape3 = try #require(rr.polylines.first)
        #expect(Self.nearPt(shape3.bounds, 0, 540, 144, 612))

        // /UserUnit 2: one user unit is 2 pt.
        let big = Self.rawPDF("0 0 72 72 re f", pageExtras: "/UserUnit 2")
        let rb = try PDFImporter.importPDF(data: big)
        let shape4 = try #require(rb.polylines.first)
        #expect(Self.near(shape4.bounds, 0, 0, 50.8, 50.8))
        #expect(Self.near(rb.unitScale, 50.8 / 72, 1e-12))
    }

    // MARK: Text, images, pages

    @Test func liveTextIsSkippedWithWarning() throws {
        let data = Self.makePDF { ctx in
            ctx.addRect(CGRect(x: 72, y: 72, width: 72, height: 72))
            ctx.fillPath()
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributed = NSAttributedString(string: "Hello NativeCAM",
                                                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 72, y: 600)
            CTLineDraw(line, ctx)
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        #expect(r.warnings.contains { $0.contains("live text") && $0.contains("outlines") })
    }

    @Test func invisibleTextIsNotReported() throws {
        let data = Self.rawPDF("BT /F1 12 Tf 3 Tr 72 700 Td (scanned words) Tj ET 0 0 10 10 re f")
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        #expect(!r.warnings.contains { $0.contains("text") })
    }

    @Test func imagesAreSkippedWithWarning() throws {
        let data = Self.makePDF { ctx in
            let gray = CGColorSpaceCreateDeviceGray()
            let bitmap = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4, space: gray,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            bitmap.setFillColor(gray: 0.5, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            ctx.draw(bitmap.makeImage()!, in: CGRect(x: 100, y: 100, width: 72, height: 72))
            ctx.addRect(CGRect(x: 300, y: 300, width: 10, height: 10))
            ctx.fillPath()
        }
        let r = try PDFImporter.importPDF(data: data)
        #expect(r.polylines.count == 1)
        #expect(r.warnings.contains { $0.contains("1 raster image") })

        // An inline image (BI ... ID ... EI) in a hand-written stream.
        let inline = Self.rawPDF("q 72 0 0 72 100 100 cm BI /W 1 /H 1 /BPC 8 /CS /G ID 0 EI Q 0 0 10 10 re f")
        let ri = try PDFImporter.importPDF(data: inline)
        #expect(ri.polylines.count == 1)
        #expect(ri.warnings.contains { $0.contains("1 raster image") })
    }

    @Test func multiPagePDFImportsTheRequestedPage() throws {
        let data = Self.makePDF(pages: [
            { ctx in ctx.addRect(CGRect(x: 72, y: 72, width: 72, height: 72)); ctx.fillPath() },
            { ctx in ctx.addRect(CGRect(x: 144, y: 144, width: 144, height: 72)); ctx.fillPath() },
        ])
        let p2 = try PDFImporter.importPDF(data: data, page: 2)
        #expect(p2.polylines.count == 1)
        let shape5 = try #require(p2.polylines.first)
        #expect(Self.nearPt(shape5.bounds, 144, 144, 288, 216))
        #expect(p2.warnings.contains { $0.contains("2 pages") })

        let p1 = try PDFImporter.importPDF(data: data)
        let shape6 = try #require(p1.polylines.first)
        #expect(Self.nearPt(shape6.bounds, 72, 72, 144, 144))

        let error = #expect(throws: VectorImportError.self) { try PDFImporter.importPDF(data: data, page: 3) }
        #expect(error?.errorDescription?.contains("2 pages") == true)
    }

    @Test func emptyPageWarns() throws {
        let r = try PDFImporter.importPDF(data: Self.makePDF { _ in })
        #expect(r.polylines.isEmpty)
        #expect(r.warnings.contains { $0.contains("No vector paths") })
    }

    // MARK: Files and errors

    @Test func vectorImporterDispatchesAIAndPDF() throws {
        #expect(VectorImporter.supportedExtensions.contains("pdf"))
        #expect(VectorImporter.supportedExtensions.contains("ai"))
        let data = Self.makePDF { ctx in
            ctx.addRect(CGRect(x: 72, y: 144, width: 144, height: 72))
            ctx.fillPath()
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PDFImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["artwork.ai", "drawing.PDF"] {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            let r = try VectorImporter.importFile(at: url)
            #expect(r.polylines.count == 1)
            let shape7 = try #require(r.polylines.first)
            #expect(Self.near(shape7.area, 1290.32, 0.01))
        }
    }

    @Test func passwordProtectedPDFThrows() throws {
        let data = Self.makePDF(auxiliaryInfo: [kCGPDFContextUserPassword: "user", kCGPDFContextOwnerPassword: "owner"]) { ctx in
            ctx.addRect(CGRect(x: 72, y: 72, width: 72, height: 72))
            ctx.fillPath()
        }
        let error = #expect(throws: VectorImportError.self) { try PDFImporter.importPDF(data: data) }
        #expect(error?.errorDescription?.contains("password") == true)
    }

    @Test func nonPDFDataThrowsHelpfulErrors() throws {
        let junk = #expect(throws: VectorImportError.self) { try PDFImporter.importPDF(data: Data("hello".utf8)) }
        #expect(junk?.errorDescription?.contains("Create PDF Compatible File") == true)

        let legacyAI = Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 8.0\n%%EndComments\n".utf8)
        let ps = #expect(throws: VectorImportError.self) { try PDFImporter.importPDF(data: legacyAI) }
        #expect(ps?.errorDescription?.contains("PostScript") == true)

        #expect(throws: VectorImportError.self) { try PDFImporter.importPDF(data: Data()) }
    }

    @Test func illustratorFileWithoutPDFContentThrows() throws {
        let data = Self.rawPDF("""
        BT /F1 12 Tf 72 700 Td (This is an Adobe Illustrator File that was saved without PDF Content.) Tj
        0 -14 Td [(To place or open this file in other applications, it should be re-saved from Adobe Illustrator ) \
        (with the "Create PDF Compatible File" option turned on.)] TJ ET
        """)
        let error = #expect(throws: VectorImportError.self) { try PDFImporter.importPDF(data: data) }
        #expect(error?.errorDescription?.contains("Create PDF Compatible File") == true)

        // The same words as live text in an ordinary drawing do not trigger it.
        let drawing = Self.rawPDF("BT /F1 12 Tf 72 700 Td (Export as PDF compatible) Tj ET 0 0 72 72 re f")
        let r = try PDFImporter.importPDF(data: drawing)
        #expect(r.polylines.count == 1)
    }
}
