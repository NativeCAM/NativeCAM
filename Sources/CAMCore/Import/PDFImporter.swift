import CoreGraphics
import Foundation

/// Reads the vector paths of one PDF page (or of a "PDF compatible" Adobe Illustrator .ai file) into flattened
/// polylines in millimetres, Y up, with the origin at the lower-left corner of the page's crop box.
///
/// Uses CoreGraphics' PDF parser and interprets the page's content stream: graphics state (`q`/`Q`/`cm`), path
/// construction (`m l c v y h re`), painting (`S s f F f* B B* b b*`; `n` discards, so clipping paths are not
/// imported) and Form XObjects (`Do`, recursively; Illustrator and CoreGraphics both nest artwork in forms).
/// Live text, raster images and shadings are skipped with a warning. Page `/Rotate` and `/UserUnit` are honoured,
/// so the geometry matches what a PDF viewer shows. Clipping is not applied: clipped artwork imports whole.
public enum PDFImporter {
    /// Millimetres per PDF point (1/72 inch).
    public static let millimetresPerPoint = 25.4 / 72

    /// Vector paths from one page (1-based) of a PDF or PDF-compatible .ai file, in mm, Y up.
    /// - Parameters:
    ///   - tolerance: maximum chord deviation (mm) when flattening curves.
    ///   - page: 1-based page number.
    public static func importPDF(data: Data, tolerance: Double = 0.01, page pageNumber: Int = 1) throws -> ImportResult {
        let tol = tolerance > 0 && tolerance.isFinite ? tolerance : 0.01
        let document = try openDocument(data)
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw VectorImportError.malformed("the PDF has no pages.") }
        guard pageNumber >= 1, pageNumber <= pageCount, let page = document.page(at: pageNumber) else {
            throw VectorImportError.malformed("page \(pageNumber) does not exist; the PDF has \(pageCount) " +
                                              "page\(pageCount == 1 ? "" : "s").")
        }

        var warnings: [String] = []
        if pageCount > 1 {
            warnings.append("The PDF has \(pageCount) pages; only page \(pageNumber) was imported.")
        }

        let userUnit = pageUserUnit(page)
        let mmPerUnit = millimetresPerPoint * userUnit
        let scanner = PDFContentScanner(device: pageTransform(page, mmPerUnit: mmPerUnit), tolerance: tol,
                                        pageResources: pageResources(page))
        scanner.scan(page)

        let tolJoin = PathChainer.joinTolerance(for: tol)
        let chained = PathChainer.chain(scanner.closed + scanner.open.map { closeIfEndsMeet($0, tolJoin) },
                                        tolerance: tolJoin)
        let fromIllustrator = isFromIllustrator(document, page)
        // A .ai saved without PDF compatibility is a PDF whose only page is a text notice saying so.
        if scanner.textLooksLikeIllustratorPlaceholder && (fromIllustrator || chained.polylines.isEmpty) {
            throw VectorImportError.malformed(
                "this Adobe Illustrator file was saved without PDF content. Open it in Illustrator, choose " +
                "File ▸ Save As, turn on “Create PDF Compatible File” in the Illustrator Options, and import it again.")
        }

        warnings.append(contentsOf: scanner.warningMessages())
        if chained.duplicatesRemoved > 0 {
            warnings.append("Removed \(chained.duplicatesRemoved) duplicate path\(chained.duplicatesRemoved == 1 ? "" : "s") " +
                "(drawn more than once on top of each other, e.g. filled and stroked separately).")
        }
        if chained.openCount > 0 {
            warnings.append("\(chained.openCount) open path\(chained.openCount == 1 ? "" : "s") left open " +
                "(endpoints do not meet within \(tolJoin) mm).")
        }
        if chained.polylines.isEmpty {
            if fromIllustrator {
                warnings.append("No vector paths found on page \(pageNumber). If this .ai file was saved without " +
                                "“Create PDF Compatible File”, re-save it from Illustrator with that option turned on.")
            } else {
                warnings.append("No vector paths found on page \(pageNumber) of the PDF.")
            }
        }
        return ImportResult(polylines: chained.polylines, points: [], warnings: warnings,
                            sourceUnits: nil, unitScale: mmPerUnit)
    }

    // MARK: Document and page

    static func openDocument(_ data: Data) throws -> CGPDFDocument {
        guard !data.isEmpty else { throw VectorImportError.malformed("the file is empty.") }
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages > 0 || document.isEncrypted else {
            if head.hasPrefix("%!PS") {
                throw VectorImportError.malformed(
                    "this is a PostScript file (an EPS, or an Adobe Illustrator file in a pre-PDF format), not a PDF. " +
                    "Re-save it from Illustrator as a .ai with “Create PDF Compatible File” turned on, or export a PDF.")
            }
            if !head.contains("%PDF-") {
                throw VectorImportError.malformed(
                    "this is not a PDF file. If it is an Adobe Illustrator (.ai) file, re-save it from Illustrator " +
                    "with “Create PDF Compatible File” turned on.")
            }
            throw VectorImportError.malformed("the PDF is damaged and could not be opened.")
        }
        if !document.isUnlocked && !document.unlockWithPassword("") {
            throw VectorImportError.malformed(
                "the PDF is password-protected. Open it with its password (in Preview or the program that made it), " +
                "save or export a copy without encryption, and import that copy.")
        }
        return document
    }

    /// Page space (user units) → mm relative to the crop box's lower-left corner, as displayed (honours `/Rotate`).
    static func pageTransform(_ page: CGPDFPage, mmPerUnit: Double) -> Transform2D {
        let crop = page.getBoxRect(.cropBox)
        let w = Double(crop.width), h = Double(crop.height)
        let toOrigin = Transform2D.translation(Vec2(-Double(crop.minX), -Double(crop.minY)))
        // `/Rotate` turns the page clockwise for display.
        let rotate: Transform2D
        switch ((Int(page.rotationAngle) % 360) + 360) % 360 {
        case 90: rotate = Transform2D(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: rotate = Transform2D(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: rotate = Transform2D(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: rotate = .identity
        }
        return toOrigin.then(rotate).then(.scale(mmPerUnit, mmPerUnit))
    }

    /// The page's `/UserUnit` (PDF 1.6: size of a user unit in points), 1 when absent or invalid.
    static func pageUserUnit(_ page: CGPDFPage) -> Double {
        guard let dict = page.dictionary else { return 1 }
        var unit: CGPDFReal = 1
        guard CGPDFDictionaryGetNumber(dict, "UserUnit", &unit), unit > 0, unit.isFinite else { return 1 }
        return Double(unit)
    }

    /// The page's resource dictionary, inherited from the page tree when the page has none of its own.
    static func pageResources(_ page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        for _ in 0..<64 {
            guard let dict = node else { return nil }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources { return resources }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Parent", &parent) else { return nil }
            node = parent
        }
        return nil
    }

    static func isFromIllustrator(_ document: CGPDFDocument, _ page: CGPDFPage) -> Bool {
        if let info = document.info {
            for key in ["Creator", "Producer"] {
                var s: CGPDFStringRef?
                if CGPDFDictionaryGetString(info, key, &s), let s, let text = CGPDFStringCopyTextString(s) as String?,
                   text.localizedCaseInsensitiveContains("Illustrator") {
                    return true
                }
            }
        }
        var pieceInfo: CGPDFDictionaryRef?
        var illustrator: CGPDFDictionaryRef?
        if let dict = page.dictionary, CGPDFDictionaryGetDictionary(dict, "PieceInfo", &pieceInfo), let pieceInfo,
           CGPDFDictionaryGetDictionary(pieceInfo, "Illustrator", &illustrator) {
            return true
        }
        return false
    }

    /// Marks an open polyline closed when its ends meet, so a stroked outline matches a filled copy of the same
    /// path during duplicate removal (PathChainer removes duplicates before it joins ends).
    static func closeIfEndsMeet(_ p: Polyline, _ eps: Double) -> Polyline {
        guard !p.isClosed, p.count >= 4, p.points[0].distance(to: p.points[p.count - 1]) <= eps else { return p }
        return Polyline(Array(p.points.dropLast()), closed: true)
    }
}

// MARK: - Content stream interpreter

/// Interprets PDF content streams through `CGPDFScanner`, collecting painted paths in mm.
/// Passed to the C operator callbacks through the scanner's `info` pointer.
final class PDFContentScanner {
    struct GraphicsState {
        /// User space → page space.
        var ctm: Transform2D = .identity
        var textRenderMode = 0
    }

    struct Subpath {
        var points: [Vec2]
        var closed: Bool
    }

    /// Page space → mm.
    let device: Transform2D
    let tolerance: Double
    let pageResources: CGPDFDictionaryRef?

    private(set) var closed: [Polyline] = []
    private(set) var open: [Polyline] = []

    private var state = GraphicsState()
    private var stateStack: [GraphicsState] = []
    // Current path, already in mm.
    private var subpaths: [Subpath] = []
    private var current: [Vec2] = []
    /// Where a segment operator without a preceding `m` starts (the start of the last closed subpath).
    private var reopenPoint: Vec2?

    private var table: CGPDFOperatorTableRef?
    /// Form XObject streams being scanned (recursion guard).
    private var activeForms: [CGPDFStreamRef] = []
    private var formInvocations = 0
    private static let maxFormDepth = 32
    private static let maxFormInvocations = 100_000

    private var notes: [String] = []
    private var noteSet: Set<String> = []
    private var visibleTextCount = 0
    private var imageCount = 0
    private var textSample = ""

    init(device: Transform2D, tolerance: Double, pageResources: CGPDFDictionaryRef?) {
        self.device = device
        self.tolerance = tolerance
        self.pageResources = pageResources
    }

    /// True when the page's text is Illustrator's "saved without PDF content" placeholder message.
    var textLooksLikeIllustratorPlaceholder: Bool {
        let squashed = textSample.lowercased().filter { !$0.isWhitespace }
        return squashed.contains("pdfcompatible") || squashed.contains("withoutpdfcontent")
    }

    func warningMessages() -> [String] {
        var out = notes
        if visibleTextCount > 0 {
            out.append("The PDF contains live text, which was skipped; convert text to outlines before exporting.")
        }
        if imageCount > 0 {
            out.append("Skipped \(imageCount) raster image\(imageCount == 1 ? "" : "s"); only vector paths can be imported.")
        }
        return out
    }

    func note(_ s: String) {
        if noteSet.insert(s).inserted { notes.append(s) }
    }

    func scan(_ page: CGPDFPage) {
        guard let table = Self.makeOperatorTable() else {
            note("The PDF content could not be read (no operator table).")
            return
        }
        self.table = table
        defer { CGPDFOperatorTableRelease(table); self.table = nil }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        withExtendedLifetime(self) {
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            if !CGPDFScannerScan(scanner) {
                note("The page content is damaged; only the part before the error was imported.")
            }
        }
    }

    // MARK: Graphics state

    func save() { stateStack.append(state) }

    func restore() {
        if let s = stateStack.popLast() { state = s }
    }

    func concat(_ m: Transform2D) { state.ctm = m.then(state.ctm) }

    func setTextRenderMode(_ mode: Int) { state.textRenderMode = mode }

    // MARK: Path construction

    private func map(_ x: Double, _ y: Double) -> Vec2 { device.apply(state.ctm.apply(Vec2(x, y))) }

    private func finishSubpath() {
        if current.count >= 2 { subpaths.append(Subpath(points: current, closed: false)) }
        current = []
    }

    /// Makes sure a subpath is open for a segment operator; false when there is no current point.
    private func beginSegment() -> Bool {
        if current.isEmpty, let p = reopenPoint { current = [p] }
        return !current.isEmpty
    }

    func moveTo(_ x: Double, _ y: Double) {
        finishSubpath()
        current = [map(x, y)]
        reopenPoint = nil
    }

    func lineTo(_ x: Double, _ y: Double) {
        guard beginSegment() else { return }
        current.append(map(x, y))
    }

    /// Cubic Bézier from the current point. `c1 == nil` means `v` (first control point is the current point).
    func curveTo(_ c1: (Double, Double)?, _ c2: (Double, Double), _ p: (Double, Double)) {
        guard beginSegment(), let start = current.last else { return }
        let a = c1.map { map($0.0, $0.1) } ?? start
        // Control points are transformed exactly (affine), so flattening in mm keeps the deviation within tolerance.
        Curves.flattenCubic(start, a, map(c2.0, c2.1), map(p.0, p.1), tolerance: tolerance, into: &current)
    }

    func closePath() {
        guard let start = current.first else { return }
        var pts = current
        if pts.count >= 2, pts[pts.count - 1].isApprox(start, tolerance: 1e-9) { pts.removeLast() }
        if pts.count >= 2 { subpaths.append(Subpath(points: pts, closed: true)) }
        current = []
        reopenPoint = start
    }

    func rectangle(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        finishSubpath()
        let p0 = map(x, y)
        subpaths.append(Subpath(points: [p0, map(x + w, y), map(x + w, y + h), map(x, y + h)], closed: true))
        reopenPoint = p0
    }

    // MARK: Painting

    /// Ends the path object. Filled subpaths are implicitly closed; `n` (no fill, no stroke) discards the path,
    /// which is how clipping paths (`W n`) end, so they are never emitted.
    func paint(close: Bool, fill: Bool, stroke: Bool) {
        if close { closePath() }
        finishSubpath()
        if fill || stroke {
            for sp in subpaths {
                let isClosed = sp.closed || fill
                var pts = sp.points
                if isClosed, pts.count >= 3, pts[pts.count - 1].isApprox(pts[0], tolerance: 1e-9) { pts.removeLast() }
                if isClosed && pts.count >= 3 {
                    closed.append(Polyline(pts, closed: true))
                } else if pts.count >= 2 {
                    open.append(Polyline(pts, closed: false))
                }
            }
        }
        subpaths = []
        current = []
        reopenPoint = nil
    }

    // MARK: Text and images

    func showText(_ strings: [CGPDFStringRef]) {
        guard state.textRenderMode != 3 && state.textRenderMode != 7 else { return } // invisible / clip-only text
        visibleTextCount += 1
        guard textSample.count < 4096 else { return }
        for s in strings {
            if let text = CGPDFStringCopyTextString(s) as String? { textSample += text }
        }
    }

    func sawInlineImage() { imageCount += 1 }

    // MARK: XObjects

    func drawXObject(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef) {
        let cs = CGPDFScannerGetContentStream(scanner)
        var stream: CGPDFStreamRef?
        guard let object = CGPDFContentStreamGetResource(cs, "XObject", name),
              CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else {
            note("Skipped a missing or invalid XObject “\(String(cString: name))”.")
            return
        }
        var subtype: UnsafePointer<CChar>?
        _ = CGPDFDictionaryGetName(dict, "Subtype", &subtype)
        switch subtype.map({ String(cString: $0) }) {
        case "Form": break
        case "Image":
            imageCount += 1
            return
        default:
            return
        }
        guard !activeForms.contains(stream) else {
            note("Skipped a Form XObject that draws itself (recursive PDF content).")
            return
        }
        guard activeForms.count < Self.maxFormDepth, formInvocations < Self.maxFormInvocations, let table else {
            note("Skipped Form XObjects nested or repeated too deeply.")
            return
        }
        formInvocations += 1

        var matrix = Transform2D.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            var m = [CGPDFReal](repeating: 0, count: 6)
            if (0..<6).allSatisfy({ CGPDFArrayGetNumber(array, $0, &m[$0]) }) {
                matrix = Transform2D(a: Double(m[0]), b: Double(m[1]), c: Double(m[2]), d: Double(m[3]),
                                     tx: Double(m[4]), ty: Double(m[5]))
            }
        }
        var ownResources: CGPDFDictionaryRef?
        // Without its own /Resources a form uses the page's; the parent content stream is a further fallback.
        let resources = CGPDFDictionaryGetDictionary(dict, "Resources", &ownResources) ? ownResources! :
            (pageResources ?? dict)

        // `Do` behaves like q, cm /Matrix, <form content>, Q, and appears only outside path objects.
        let savedPath = (subpaths, current, reopenPoint)
        subpaths = []; current = []; reopenPoint = nil
        let savedState = state, savedDepth = stateStack.count
        concat(matrix)
        activeForms.append(stream)

        let formStream = CGPDFContentStreamCreateWithStream(stream, resources, cs)
        let formScanner = CGPDFScannerCreate(formStream, table, Unmanaged.passUnretained(self).toOpaque())
        if !CGPDFScannerScan(formScanner) {
            note("A Form XObject's content is damaged; only the part before the error was imported.")
        }
        CGPDFScannerRelease(formScanner)
        CGPDFContentStreamRelease(formStream)

        activeForms.removeLast()
        stateStack.removeSubrange(min(savedDepth, stateStack.count)...)
        state = savedState
        (subpaths, current, reopenPoint) = savedPath
    }

    // MARK: Operator table

    private static func makeOperatorTable() -> CGPDFOperatorTableRef? {
        guard let t = CGPDFOperatorTableCreate() else { return nil }

        // Graphics state.
        CGPDFOperatorTableSetCallback(t, "q") { _, info in scannerContext(info)?.save() }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in scannerContext(info)?.restore() }
        CGPDFOperatorTableSetCallback(t, "cm") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 6) else { return }
            c.concat(Transform2D(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]))
        }

        // Path construction.
        CGPDFOperatorTableSetCallback(t, "m") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 2) else { return }
            c.moveTo(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(t, "l") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 2) else { return }
            c.lineTo(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 6) else { return }
            c.curveTo((v[0], v[1]), (v[2], v[3]), (v[4], v[5]))
        }
        CGPDFOperatorTableSetCallback(t, "v") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 4) else { return }
            c.curveTo(nil, (v[0], v[1]), (v[2], v[3]))
        }
        CGPDFOperatorTableSetCallback(t, "y") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 4) else { return }
            c.curveTo((v[0], v[1]), (v[2], v[3]), (v[2], v[3]))
        }
        CGPDFOperatorTableSetCallback(t, "h") { _, info in scannerContext(info)?.closePath() }
        CGPDFOperatorTableSetCallback(t, "re") { s, info in
            guard let c = scannerContext(info), let v = popNumbers(s, 4) else { return }
            c.rectangle(v[0], v[1], v[2], v[3])
        }

        // Painting. `W`/`W*` need no handling: the clip path is emitted only if the operator after it paints it.
        CGPDFOperatorTableSetCallback(t, "S") { _, info in scannerContext(info)?.paint(close: false, fill: false, stroke: true) }
        CGPDFOperatorTableSetCallback(t, "s") { _, info in scannerContext(info)?.paint(close: true, fill: false, stroke: true) }
        for op in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in scannerContext(info)?.paint(close: false, fill: true, stroke: false) }
        }
        for op in ["B", "B*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in scannerContext(info)?.paint(close: false, fill: true, stroke: true) }
        }
        for op in ["b", "b*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, info in scannerContext(info)?.paint(close: true, fill: true, stroke: true) }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, info in scannerContext(info)?.paint(close: false, fill: false, stroke: false) }

        // XObjects (forms are scanned recursively; images are skipped).
        CGPDFOperatorTableSetCallback(t, "Do") { s, info in
            var name: UnsafePointer<CChar>?
            guard let c = scannerContext(info), CGPDFScannerPopName(s, &name), let name else { return }
            c.drawXObject(named: name, scanner: s)
        }
        CGPDFOperatorTableSetCallback(t, "EI") { _, info in scannerContext(info)?.sawInlineImage() }

        // Text (skipped, but noted).
        CGPDFOperatorTableSetCallback(t, "Tr") { s, info in
            var mode: CGPDFInteger = 0
            guard let c = scannerContext(info), CGPDFScannerPopInteger(s, &mode) else { return }
            c.setTextRenderMode(mode)
        }
        CGPDFOperatorTableSetCallback(t, "Tj") { s, info in
            guard let c = scannerContext(info) else { return }
            c.showText(popString(s).map { [$0] } ?? [])
        }
        CGPDFOperatorTableSetCallback(t, "'") { s, info in
            guard let c = scannerContext(info) else { return }
            c.showText(popString(s).map { [$0] } ?? [])
        }
        CGPDFOperatorTableSetCallback(t, "\"") { s, info in
            guard let c = scannerContext(info) else { return }
            c.showText(popString(s).map { [$0] } ?? [])
        }
        CGPDFOperatorTableSetCallback(t, "TJ") { s, info in
            guard let c = scannerContext(info) else { return }
            var array: CGPDFArrayRef?
            var strings: [CGPDFStringRef] = []
            if CGPDFScannerPopArray(s, &array), let array {
                for i in 0..<CGPDFArrayGetCount(array) {
                    var str: CGPDFStringRef?
                    if CGPDFArrayGetString(array, i, &str), let str { strings.append(str) }
                }
            }
            c.showText(strings)
        }
        return t
    }
}

// Free functions so the operator callbacks (C function pointers) capture nothing.

private func scannerContext(_ info: UnsafeMutableRawPointer?) -> PDFContentScanner? {
    guard let info else { return nil }
    return Unmanaged<PDFContentScanner>.fromOpaque(info).takeUnretainedValue()
}

/// Pops `n` numeric operands (they come off the stack last first) and returns them in operand order.
private func popNumbers(_ scanner: CGPDFScannerRef, _ n: Int) -> [Double]? {
    var out = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &v), v.isFinite else { return nil }
        out[i] = Double(v)
    }
    return out
}

private func popString(_ scanner: CGPDFScannerRef) -> CGPDFStringRef? {
    var s: CGPDFStringRef?
    return CGPDFScannerPopString(scanner, &s) ? s : nil
}
