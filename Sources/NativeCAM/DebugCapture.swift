import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Developer aid: saves PNGs of the app's own windows (exactly as composited on screen, Liquid Glass included)
/// when another process posts the distributed notification `com.nativecam.debug.capture`.
/// Images go to ~/Library/Caches/NativeCAM/Captures/. Capturing one's own windows needs no Screen Recording permission.
@MainActor
enum DebugCapture {
    static let notification = Notification.Name("com.nativecam.debug.capture")
    /// Posted locally so the focused window can put itself in a state (selection, simulation, view) before capture.
    static let command = Notification.Name("NativeCAMDebugCommand")

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeCAM/Captures", isDirectory: true)
    }

    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated {
                if !info.isEmpty { NotificationCenter.default.post(name: command, object: nil, userInfo: info) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (info.isEmpty ? 0.1 : 1.6)) {
                    MainActor.assumeIsolated {
                        captureAll(tag: info["tag"] as? String)
                        if info["views"] != nil { dumpScrollViews() }
                    }
                }
            }
        }
    }

    static func captureAll(tag: String? = nil) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970))" + (tag.map { "-\($0)" } ?? "")
        for (i, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
            guard let image = image(of: window) else { continue }
            let name = (window.title.isEmpty ? "window" : window.title).replacingOccurrences(of: "/", with: "-")
            let url = folder.appendingPathComponent("\(stamp)-\(i)-\(name).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    /// Writes each window's scroll views (frame, scroll offset, content size, table column widths) to views.txt in
    /// the captures folder, for layout problems a screenshot can't explain.
    static func dumpScrollViews() {
        var out = ""
        func visit(_ v: NSView, depth: Int) {
            if let sv = v as? NSScrollView {
                let f = sv.convert(sv.bounds, to: nil)
                let doc = sv.documentView.map { "\($0.className) \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "none"
                out += String(repeating: "  ", count: depth) + "NSScrollView x \(Int(f.minX))…\(Int(f.maxX)) "
                    + "offset \(Int(sv.contentView.bounds.minX)),\(Int(sv.contentView.bounds.minY)) insets \(sv.contentInsets) doc \(doc)"
                if let t = sv.documentView as? NSTableView {
                    out += " columns \(t.tableColumns.map { Int($0.width) })"
                }
                out += "\n"
            }
            for sub in v.subviews { visit(sub, depth: depth + 1) }
        }
        for window in NSApp.windows where window.isVisible {
            out += "== \(window.title) \(Int(window.frame.width))×\(Int(window.frame.height))\n"
            if let root = window.contentView?.superview ?? window.contentView { visit(root, depth: 0) }
        }
        try? out.write(to: folder.appendingPathComponent("views.txt"), atomically: true, encoding: .utf8)
    }

    /// CGWindowListCreateImage is hidden from the macOS 15+ SDK but still present at runtime; look it up dynamically.
    private static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }
}
