// render-pdf.swift: renders the Validation Handbook's HTML to a paginated PDF
// with macOS's own WebKit and PDFKit (no third-party tools).
//
//   swift docs/validation/tools/render-pdf.swift <in.html> <out.pdf> [letter|a4]
//
// Two passes. The first prints the page and reads back, from each page's text,
// the invisible markers the HTML carries ("@@S:<id>@@" for a section, "@@T:<id>@@"
// for a test). The second fills the table of contents' page numbers from them and
// prints again. Then every page but the cover gets a running header (the test IDs
// on the page, or the section) and a "page n of m" footer, and the markers are
// left as invisible text.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PDFKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: render-pdf.swift <in.html> <out.pdf> [letter|a4]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1]).standardizedFileURL
let output = URL(fileURLWithPath: args[2]).standardizedFileURL
let paper = args.count > 3 ? args[3] : "letter"
let pageSize = paper == "a4" ? NSSize(width: 595.28, height: 841.89) : NSSize(width: 612, height: 792)

let marginTop: CGFloat = 50, marginBottom: CGFloat = 46, marginSide: CGFloat = 46

func log(_ s: String) { if ProcessInfo.processInfo.environment["VH_DEBUG"] != nil { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var loaded: CheckedContinuation<Void, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: pageSize.width - 2 * marginSide, height: 1000),
                        configuration: config)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 1000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        web.navigationDelegate = self
        window.contentView = web
    }

    func load() async {
        await withCheckedContinuation { c in
            loaded = c
            web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent().deletingLastPathComponent())
        }
        // Let images decode and fonts settle.
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("didFinish")
        loaded?.resume(); loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail \(error)"); loaded?.resume(); loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("didFailProvisional \(error)"); loaded?.resume(); loaded = nil
    }

    var printed: CheckedContinuation<Void, Never>?

    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        log("printed: \(success)")
        printed?.resume(); printed = nil
    }

    // WebKit prints asynchronously in its content process, so the operation has to
    // run modally for a window (NSPrintOperation.run() would block the run loop it needs).
    func printPDF(to url: URL) async {
        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = marginTop
        info.bottomMargin = marginBottom
        info.leftMargin = marginSide
        info.rightMargin = marginSide
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        await withCheckedContinuation { c in
            printed = c
            op.runModal(for: window, delegate: self,
                        didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }
}

/// Page index → markers of each kind found in its text, in order.
func readMarkers(_ doc: PDFDocument) -> [(sections: [String], tests: [String])] {
    let re = try! NSRegularExpression(pattern: "@@([ST]):([^@]+)@@")
    var out: [(sections: [String], tests: [String])] = []
    for i in 0..<doc.pageCount {
        // PDFKit reads ligatures back as single characters ("ﬀ"): undo them.
        var text = doc.page(at: i)?.string ?? ""
        for (lig, plain) in [("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl")] {
            text = text.replacingOccurrences(of: lig, with: plain)
        }
        var s: [String] = [], t: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let kind = (text as NSString).substring(with: m.range(at: 1))
            let id = (text as NSString).substring(with: m.range(at: 2))
            if kind == "S" { s.append(id) } else { t.append(id) }
        }
        out.append((s, t))
    }
    return out
}

func stamp(_ doc: PDFDocument, markers: [(sections: [String], tests: [String])], titles: [String: String], to url: URL) {
    var box = CGRect(origin: .zero, size: pageSize)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, [
        kCGPDFContextTitle as String: "NativeCAM Validation Handbook",
        kCGPDFContextCreator as String: "NativeCAM docs/validation/build-kit.sh",
    ] as CFDictionary) else { fatalError("can't write \(url.path)") }
    let n = doc.pageCount
    var lastSection = "", lastTest = ""
    let font = NSFont(name: "Helvetica", size: 8) ?? NSFont.systemFont(ofSize: 8)
    let bold = NSFont(name: "Helvetica-Bold", size: 8) ?? NSFont.boldSystemFont(ofSize: 8)
    for i in 0..<n {
        guard let page = doc.page(at: i) else { continue }
        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)
        let m = markers[i]
        if let s = m.sections.last { lastSection = s; if m.tests.isEmpty { lastTest = "" } }
        if let t = m.tests.last { lastTest = t }
        if i > 0 {
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let left = "NativeCAM Validation Handbook"
            var right: String
            if !m.tests.isEmpty {
                right = m.tests.joined(separator: " · ")
            } else if !lastTest.isEmpty && m.sections.isEmpty {
                right = "\(lastTest) (continued)"
            } else {
                right = titles[lastSection] ?? ""
            }
            let y = pageSize.height - 30
            NSAttributedString(string: left, attributes: [.font: font, .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: marginSide, y: y))
            let r = NSAttributedString(string: right, attributes: [.font: bold, .foregroundColor: NSColor.black])
            r.draw(at: NSPoint(x: pageSize.width - marginSide - r.size().width, y: y))
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: marginSide, y: y - 4))
            ctx.addLine(to: CGPoint(x: pageSize.width - marginSide, y: y - 4))
            ctx.strokePath()
            let f = NSAttributedString(string: "Page \(i + 1) of \(n)", attributes: [.font: font, .foregroundColor: NSColor.black])
            f.draw(at: NSPoint(x: (pageSize.width - f.size().width) / 2, y: 22))
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

@MainActor
func run() async {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let r = Renderer()
    log("loading")
    await r.load()
    log("loaded")
    let tmp1 = FileManager.default.temporaryDirectory.appendingPathComponent("vh-pass1-\(getpid()).pdf")
    let tmp2 = FileManager.default.temporaryDirectory.appendingPathComponent("vh-pass2-\(getpid()).pdf")
    await r.printPDF(to: tmp1)
    log("pass 1 printed")
    guard let d1 = PDFDocument(url: tmp1) else { fatalError("pass 1 wrote no PDF") }
    let m1 = readMarkers(d1)
    var firstPage: [String: Int] = [:]
    for (i, m) in m1.enumerated() {
        for id in m.sections + m.tests where firstPage[id] == nil { firstPage[id] = i + 1 }
    }
    let json = String(data: try! JSONSerialization.data(withJSONObject: firstPage), encoding: .utf8)!
    let titlesAny = try? await r.web.evaluateJavaScript("""
        (function(){ var map = \(json); var t = {};
          document.querySelectorAll('[data-page-of]').forEach(function(e){
            var p = map[e.getAttribute('data-page-of')]; e.textContent = p ? String(p) : '?'; });
          document.querySelectorAll('[data-section-title]').forEach(function(e){
            t[e.getAttribute('data-section-id')] = e.getAttribute('data-section-title'); });
          return JSON.stringify(t); })()
        """)
    let titles = (try? JSONSerialization.jsonObject(with: ((titlesAny as? String) ?? "{}").data(using: .utf8)!)) as? [String: String] ?? [:]
    try? await Task.sleep(nanoseconds: 300_000_000)
    await r.printPDF(to: tmp2)
    guard let d2 = PDFDocument(url: tmp2) else { fatalError("pass 2 wrote no PDF") }
    let m2 = readMarkers(d2)
    var moved = 0
    var second: [String: Int] = [:]
    for (i, m) in m2.enumerated() { for id in m.sections + m.tests where second[id] == nil { second[id] = i + 1 } }
    for (k, v) in firstPage where second[k] != v { moved += 1 }
    stamp(d2, markers: m2, titles: titles, to: output)
    let tests = Set(m2.flatMap { $0.tests }).count
    print("Wrote \(output.path): \(d2.pageCount) pages, \(tests) tests, \(paper)\(moved > 0 ? ", WARNING: \(moved) TOC entries moved in pass 2" : "")")
    try? FileManager.default.removeItem(at: tmp1)
    try? FileManager.default.removeItem(at: tmp2)
}

Task { @MainActor in
    await run()
    exit(0)
}
RunLoop.main.run()
