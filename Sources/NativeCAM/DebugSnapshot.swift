import AppKit
import CAMCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Developer check:
///   NativeCAM -NativeCAMSnapshotProject <project.nativecam> -NativeCAMSnapshotOut <out-dir>
/// renders the main window and the finished simulation offscreen to PNGs, then quits. The `-Key value` form is read
/// from the user-defaults argument domain, so AppKit doesn't treat the paths as documents to open.
///
/// With `-NativeCAMSnapshotTemplate <template.nativecamtemplate>` it first applies that template to the project (with
/// its job setup when `-NativeCAMSnapshotTemplateSetup YES`), logs Toolpaths ▸ Apply Template's items (the templates
/// folder can be pointed elsewhere with `-NativeCAMTemplatesFolder <dir>`) and what each toolpath found, draws the
/// Apply Template sheet and the save panel's options, then snapshots the project with the template applied.
/// `-NativeCAMSnapshotImport <file.dxf|svg|pdf>` first imports vectors into the project as File ▸ Import does (one shape
/// per layer), logging each shape's layer.
///
/// With `-NativeCAMSnapshotNest YES` it nests every part as Toolpaths ▸ Nest Parts… does (300 layouts, or
/// `-NativeCAMSnapshotNestLayouts n`, so the result repeats), logs the layout and checks it with the parts' exact
/// outlines, draws the Nest Parts sheet (nest-sheet.png) and the toolpaths from above before and after
/// (nest-before.png, nest-after.png), then snapshots the project with the parts moved.
///
/// With `-NativeCAMSnapshotInlay YES` it makes an inlay pair from every closed vector as Add Toolpath ▸ Inlay… does,
/// with `-NativeCAMSnapshotInlayBoundary margin|vector|board` and, with `-NativeCAMSnapshotInlayRaster YES`, the V-bit
/// clearing the flats in raster lines. It draws the dialog for each boundary (inlay-sheet-*.png), logs the pair and its
/// checks, draws the plug's inspector with its pocket depth changed so the offer to update the pocket shows
/// (inspector-inlay-mismatch.png), then snapshots the project with the pair added.
enum DebugSnapshot {
    static var requested: (project: String, outDir: String)? {
        let d = UserDefaults.standard
        guard let project = d.string(forKey: "NativeCAMSnapshotProject"), let out = d.string(forKey: "NativeCAMSnapshotOut") else { return nil }
        return (project, out)
    }

    @MainActor
    static func run(projectPath: String, outDir: String) {
        // Called from App.init before any scene exists. Pumping the run loop here (outside any dispatch block)
        // lets SwiftUI updates and main-actor tasks run between steps.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let out = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: projectPath)),
              let loaded = try? Project.decode(data) else {
            print("snapshot: can't read \(projectPath)")
            exit(1)
        }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func log(_ s: String) { FileHandle.standardError.write(("snapshot: " + s + "\n").data(using: .utf8)!) }
        log("start")
        var project = loaded
        if let path = UserDefaults.standard.string(forKey: "NativeCAMSnapshotImport") {
            let url = URL(fileURLWithPath: path)
            do {
                let result = try VectorImporter.importFile(at: url)
                let shapes = result.shapes(name: url.deletingPathExtension().lastPathComponent, stock: project.stock)
                project.shapes += shapes
                project.bindVectors()
                for shape in shapes { log("import \(shape.name): layer “\(shape.layer)”") }
            } catch {
                log("import failed: \(error.localizedDescription)")
            }
        }
        if let path = UserDefaults.standard.string(forKey: "NativeCAMSnapshotTemplate") {
            project = applyTemplate(path, to: project, out: out, log: log, spin: spin)
        }
        if UserDefaults.standard.bool(forKey: "NativeCAMSnapshotNest") {
            project = nest(project, out: out, log: log, spin: spin)
        }
        if UserDefaults.standard.bool(forKey: "NativeCAMSnapshotInlay") {
            project = inlay(project, out: out, log: log, spin: spin)
        }

        // 1. The whole window (sidebar, viewport, inspector), as the window server composites it.
        captureWindow(project, out: out, log: log, spin: spin)

        // 2. The finished simulation through the real Metal renderer.
        let ws = Workspace()
        ws.regenerate(project, debounce: false)
        let deadline = Date().addingTimeInterval(30)
        while ws.job == nil && Date() < deadline { spin(0.05) }
        log("job ready: \(ws.job != nil)")
        ws.startSimulation(project)
        ws.jumpToEnd()
        let scene = ws.viewportScene(project)
        for preset in [ViewPreset.iso, .top] {
            if let img = ViewportRenderer.snapshot(scene: scene, width: 1600, height: 1000, preset: preset) {
                write(img, to: out.appendingPathComponent("sim-\(preset.rawValue).png"))
            }
        }
        // A tiled job just as its second tile starts, the first one cut in place.
        if let count = ws.tileCount, count > 1 {
            ws.seek(toTile: 1)
            if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(project), width: 1600, height: 1000, preset: .top) {
                write(img, to: out.appendingPathComponent("sim-tile-2.png"))
            }
            ws.jumpToEnd()
        }
        // A rotary job half way through its first turn of the blank.
        if let turn = ws.session?.timeline.steps.first(where: { $0.turn != nil }) {
            ws.seek(to: turn.startTime + turn.duration / 2)
            if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(project), width: 1600, height: 1000, preset: .iso) {
                write(img, to: out.appendingPathComponent("sim-turning.png"))
            }
        }
        // 3. Toolpaths (no simulation) from the iso view, then each toolpath with corner reliefs selected in the top
        // view, so its corner marks show (corners-op-N.png), with the reason for each one drawn in orange.
        ws.stopSimulation(project)
        if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(project), width: 1600, height: 1000, preset: .iso) {
            write(img, to: out.appendingPathComponent("toolpaths-iso.png"))
        }
        // A tiled job from above, with its tile lines, overlaps and registration holes, and its setup sheet.
        if let job = ws.job, job.tiling != nil {
            if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(project), width: 1600, height: 1000, preset: .top) {
                write(img, to: out.appendingPathComponent("tiles-top.png"))
            }
            try? Data(SetupSheet.html(project: project, job: job).utf8).write(to: out.appendingPathComponent("setup-sheet.html"))
        }
        for (i, op) in project.operations.enumerated() {
            guard let corners = ws.job?.toolpaths.first(where: { $0.sourceOperationID == op.id && $0.reliefCorners != nil })?.reliefCorners,
                  !corners.isEmpty else { continue }
            ws.selection = [.operation(op.id)]
            ws.rebuildLines(project)
            if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(project), width: 1600, height: 1000, preset: .top) {
                write(img, to: out.appendingPathComponent("corners-op-\(i).png"))
            }
            for corner in corners { if let reason = CanvasController.flagReason(corner) { log("corner \(op.name): \(reason)") } }
        }
        // Each rest toolpath selected in the top view, so its rest areas are shaded (rest-op-N.png).
        for (i, op) in project.operations.enumerated() {
            guard let areas = ws.job?.toolpaths.last(where: { $0.sourceOperationID == op.id && $0.restAreas != nil })?.restAreas else { continue }
            ws.selection = [.operation(op.id)]
            ws.rebuildLines(project)
            if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(project), width: 1600, height: 1000, preset: .top) {
                write(img, to: out.appendingPathComponent("rest-op-\(i).png"))
            }
            let regions = Region.nest(areas)
            log("rest \(op.name): \(regions.count) areas, \(String(format: "%.1f", regions.reduce(0) { $0 + $1.area })) mm²")
        }
        ws.selection = []
        ws.rebuildLines(project)
        // 4. Each inspector at full height, sections below the fold included, and the checks Export runs.
        renderInspectors(project, workspace: ws, out: out, spin: spin)
        exportCheck(project, job: ws.job, log: log)
        starterLibraryCheck(log: log)
        interactionSelfCheck(project, log: log)
        print("snapshot: wrote PNGs to \(out.path)")
        exit(0)
    }

    /// A window AppKit leaves where it's put, even almost entirely off the screen.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// The main window to window.png, once it has drawn a real frame.
    ///
    /// `cacheDisplay` and a Core Animation render can't draw the Metal viewport or the sidebar's and inspector's
    /// materials (they came out white and pink, #101), so the picture is the window server's, as
    /// `scripts/capture-window.sh` takes it. That needs the window opaque, on screen and drawn: it's put all but one
    /// column of points past the screen's right edge, so it's on screen (AppKit doesn't draw a window it thinks is
    /// hidden) without showing, and captured again until the frame passes `frameProblem` (up to a minute).
    @MainActor
    private static func captureWindow(_ project: Project, out: URL, log: (String) -> Void, spin: (Double) -> Void) {
        let host = NSHostingView(rootView: ContentView(document: .constant(NativeCAMDocument(project: project)))
            .environment(ToolLibraryStore.shared))
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                                     styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.frame.maxX - 1, y: screen.visibleFrame.minY))
        }
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        log("window created")
        let started = Date()
        spin(2)
        var image = DebugCapture.image(of: window)
        var problem = image.map(frameProblem) ?? "the window server gave no picture"
        while problem != nil, image != nil, Date().timeIntervalSince(started) < 60 {
            spin(0.5)
            image = DebugCapture.image(of: window)
            problem = image.map(frameProblem) ?? "the window server gave no picture"
        }
        let waited = String(format: "%.1f", Date().timeIntervalSince(started))
        if let image {
            write(image, to: out.appendingPathComponent("window.png"))
        } else if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            // No window server picture at all: the view as AppKit draws it, which may lack the viewport and materials.
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("window.png"))
        }
        log("window rendered after \(waited) s")
        log("check \(problem == nil ? "PASS" : "FAIL"): window.png is a real frame\(problem.map { ": \($0)" } ?? "")")
        window.close()
    }

    /// Why a capture of the main window isn't a real frame, or nil when it is: a sidebar or inspector with nothing drawn
    /// in it, the pink of a material that wasn't drawn, or a see-through window.
    static func frameProblem(_ image: CGImage) -> String? {
        let w = image.width, h = image.height
        guard w > 100, h > 100,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return "the picture is too small to read" }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var opaque = 0, pink = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2]), a = Int(px[i + 3])
            if a > 240 { opaque += 1 }
            if a > 240, r > 230, (90...170).contains(g), (90...170).contains(b), abs(g - b) < 30 { pink += 1 }
        }
        if Double(opaque) < 0.9 * Double(w * h) { return "the window is see-through" }
        if Double(pink) > 0.02 * Double(w * h) { return "a pink block where a material wasn't drawn" }
        // Text and controls in a column of the window: pixels well away from the column's typical brightness.
        func drawn(_ x0: Double, _ x1: Double) -> Bool {
            var lum: [Int] = []
            let ys = Int(Double(h) * 0.12)..<Int(Double(h) * 0.88), xs = Int(Double(w) * x0)..<Int(Double(w) * x1)
            for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 2) {
                for x in stride(from: xs.lowerBound, to: xs.upperBound, by: 2) {
                    let i = (y * w + x) * 4
                    lum.append((299 * Int(px[i]) + 587 * Int(px[i + 1]) + 114 * Int(px[i + 2])) / 1000)
                }
            }
            guard !lum.isEmpty else { return false }
            let median = lum.sorted()[lum.count / 2]
            return Double(lum.filter { abs($0 - median) > 60 }.count) > 0.003 * Double(lum.count)
        }
        if !drawn(0.01, 0.17) { return "nothing drawn in the sidebar" }
        if !drawn(0.80, 0.99) { return "nothing drawn in the inspector" }
        return nil
    }

    /// Draws `view` offscreen at `size` to `out/name`.
    @MainActor
    private static func render(_ view: some View, size: NSSize, out: URL, name: String, spin: (Double) -> Void) {
        let host = NSHostingView(rootView: view.environment(ToolLibraryStore.shared).background(Color(nsColor: .windowBackgroundColor)))
        // Borderless, so AppKit doesn't shrink the window to fit the screen.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        if let screen = NSScreen.main { window.setFrameOrigin(screen.visibleFrame.origin) }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        spin(1.5)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
        }
        window.close()
    }

    /// Applies the template at `path` as Toolpaths ▸ Apply Template does, logging the menu and what it found, and draws
    /// the Apply Template sheet (apply-template.png) and the save panel's options (save-template-options.png).
    @MainActor
    private static func applyTemplate(_ path: String, to project: Project, out: URL, log: (String) -> Void,
                                      spin: (Double) -> Void) -> Project {
        let templates = TemplateLibrary.shared
        templates.refresh()
        log("menu Toolpaths: Save Toolpaths as Template… | Apply Template ▸ "
            + (templates.entries.map(\.name) + ["Choose…", "Show Templates Folder"]).joined(separator: " | "))
        if #available(macOS 15, *) {
            // The submenu's SwiftUI items as AppKit builds them.
            let menu = NSHostingMenu(rootView: TemplateMenuItems(templates: templates, apply: { _ in }, choose: {}))
            menu.update()
            spin(0.2)
            log("menu Apply Template items: " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (disabled)") }
                .joined(separator: " | "))
        }
        let template: ToolpathTemplate
        do {
            template = try ToolpathTemplate.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            log("template refused: \(error.localizedDescription)")
            return project
        }
        let useSetup = UserDefaults.standard.bool(forKey: "NativeCAMSnapshotTemplateSetup")
        let library = ToolLibrary(tools: ToolLibraryStore.shared.tools)
        let result = template.apply(to: project, library: library, useJobSetup: useSetup)
        for row in result.rows {
            log("template toolpath \(row.name): \(row.rule?.label ?? "needs no vectors"), \(row.shapeCount) vectors\(row.isEmpty ? ", added empty" : "")")
        }
        for use in result.tools {
            log("template tool T\(use.tool.number) \(use.tool.name): \(use.inLibrary ? "in the library" : "new")"
                + (use.templateNumber.map { ", T\($0) in the template" } ?? "") + (use.feedsDiffer ? ", the template's feeds" : ""))
        }
        for change in result.setupChanges { log("template setup \(change.setting): \(change.from) → \(change.to)") }
        if let note = result.machineNote { log("template machine: \(note)") }
        render(ApplyTemplateSheet(template: template, project: project, library: library, selection: [], useJobSetup: useSetup, height: 940) { _, _ in },
               size: NSSize(width: 540, height: 940), out: out, name: "apply-template.png", spin: spin)
        let options = TemplateSaveOptions(selectedCount: 2, totalCount: max(3, project.operations.count))
        render(TemplateSaveAccessory(options: options), size: NSSize(width: 460, height: 120), out: out, name: "save-template-options.png", spin: spin)
        return result.project
    }

    /// Nests every part as Toolpaths ▸ Nest Parts… does, logs and checks the layout, draws the sheet and the toolpaths
    /// from above before and after, and returns the project with the parts moved.
    @MainActor
    private static func nest(_ project: Project, out: URL, log: (String) -> Void, spin: (Double) -> Void) -> Project {
        let layouts = UserDefaults.standard.integer(forKey: "NativeCAMSnapshotNestLayouts")
        let sheets = UserDefaults.standard.integer(forKey: "NativeCAMSnapshotNestSheets")
        let session = NestSession(project: project, selection: [])
        session.runNow(evaluations: layouts > 0 ? layouts : 300, sheets: sheets > 0 ? sheets : nil)
        guard let job = session.job, let result = session.result, case let .success(applied)? = session.applied() else {
            log("nest refused: \(session.phase)")
            return project
        }
        let u = project.displayUnits
        log("nest: \(result.placedCount) of \(job.parts.count) parts placed on \(result.sheetCount) sheet\(result.sheetCount == 1 ? "" : "s") "
            + "(\(result.sheets.map { String($0.partCount) }.joined(separator: " + "))), \(result.inHoles.count) in holes, "
            + "\(job.fixed.count) stay put, \(job.keepOuts.count) keep-outs; "
            + String(format: "utilization %.1f%% of %@ %@ used on the last sheet, %.1f%% of the sheets; %d layouts", result.utilization * 100,
                     u.format(result.usedLength), u.symbol, result.sheetUtilization * 100, result.evaluations))
        log("nest settings: spacing \(u.format(session.settings.spacing)) \(u.symbol), margin \(u.format(session.settings.edgeMargin)) \(u.symbol), "
            + "turns \(session.settings.angles.map { String(Int($0)) }.joined(separator: "/")), grain \(session.settings.keepGrain), "
            + "up to \(session.settings.sheetLimit) sheets, part in part \(session.settings.partInPart)")
        for (i, part) in job.parts.enumerated() {
            let where_ = result.placements[i].map { p in
                "sheet \(p.sheet + 1), turned \(Int(p.rotation))°, centre at \(u.format(p.position.x)), \(u.format(p.position.y))"
                    + (result.insideOf[i].map { ", in a hole of \(job.parts[$0].name)" } ?? "")
            } ?? "didn't fit"
            let holes = part.holes.isEmpty ? "" : ", \(part.holes.count) usable hole\(part.holes.count == 1 ? "" : "s")"
            log("nest part \(part.name): \(where_), reach \(u.format(part.reach)) \(u.symbol)\(part.reachToolpath.map { " (\($0))" } ?? "")\(holes)")
        }
        for note in job.notes { log("nest note: \(note)") }
        for name in applied.movedAside { log("nest moved aside: \(name)") }
        for name in applied.leftInPlace { log("nest left in place: \(name)") }
        let problems = Nesting.violations(job.nestingParts, placements: result.placements, sheet: job.sheet, obstacles: job.obstacles,
                                          settings: session.settings)
        log("check \(problems.isEmpty ? "PASS" : "FAIL"): nested parts keep their gaps, margin and clearances\(problems.isEmpty ? "" : ": " + problems.joined(separator: " "))")
        render(NestPartsSheet(session: session, height: 720, isStatic: true) { _ in }, size: NSSize(width: 940, height: 720),
               out: out, name: "nest-sheet.png", spin: spin)
        // The sheet's own path: toolpaths and parts found in the background, a timed search showing its progress, and a
        // new search when a setting changes.
        let live = NestSession(project: project, selection: [])
        live.remembersSettings = false
        live.start()
        func waitForSearch() -> Bool {
            let deadline = Date().addingTimeInterval(60)
            spin(0.5)
            while (live.phase == .preparing || live.searching) && Date() < deadline { spin(0.1) }
            return live.result != nil && !live.searching
        }
        let first = waitForSearch()
        let firstLayouts = live.result?.evaluations ?? 0, firstUpdates = live.updates
        live.settings.spacing += 0.0625.inch
        let second = waitForSearch()
        log("check \(first && second && firstUpdates > 0 && live.updates > firstUpdates ? "PASS" : "FAIL"): live search "
            + "\(firstLayouts) layouts in \(String(format: "%.1f", live.settings.timeLimit)) s (\(firstUpdates) updates), "
            + "then \(live.result?.evaluations ?? 0) after a spacing change")
        func top(_ p: Project, _ name: String) {
            let ws = Workspace()
            ws.regenerate(p, debounce: false)
            let deadline = Date().addingTimeInterval(30)
            while ws.job == nil && Date() < deadline { spin(0.05) }
            // Each sheet of a job nested onto several: nest-after.png, nest-after-sheet-2.png, …
            for k in 0..<p.sheetCount {
                ws.show(sheet: k, project: p)
                let file = k == 0 ? name : name.replacingOccurrences(of: ".png", with: "-sheet-\(k + 1).png")
                if let img = ViewportRenderer.snapshot(scene: ws.viewportScene(p), width: 1600, height: 1000, preset: .top) {
                    write(img, to: out.appendingPathComponent(file))
                }
            }
        }
        top(project, "nest-before.png")
        top(applied.project, "nest-after.png")
        if applied.sheetCount > 1 {
            // Each sheet's job keeps its toolpaths to its own parts, and each file stays in the machine's travel.
            let job = CAMEngine.generate(applied.project)
            let files = JobExport.files(applied.project, job: job)?.files ?? []
            let travel = applied.project.machine.travel
            let inTravel = files.allSatisfy { f in
                f.toolpaths.compactMap(\.cuttingExtents).allSatisfy { $0.min.x >= -1e-6 && $0.max.x <= travel.x && $0.min.y >= -1e-6 && $0.max.y <= travel.y }
            }
            log("check \(files.count >= applied.sheetCount && inTravel ? "PASS" : "FAIL"): \(applied.sheetCount) sheets export as "
                + "\(files.count) files (\(files.compactMap(\.suffix).joined(separator: ",")))\(inTravel ? ", each in travel" : ", one past the travel")")
        }
        return applied.project
    }

    /// Add Toolpath ▸ Inlay… on every closed vector (see the type's notes), returning the project with the pair added.
    @MainActor
    private static func inlay(_ project: Project, out: URL, log: (String) -> Void, spin: (Double) -> Void) -> Project {
        let d = UserDefaults.standard
        let ids = project.inlayShapes(project.shapes.map(\.id)).map(\.id)
        let tools = ToolLibraryStore.shared.tools
        // Each side's quickest end mill, as the dialog works it out, timed once for each set of settings drawn.
        var timed: [InlayPairSettings: InlayClearanceTimes] = [:]
        func times(_ s: InlayPairSettings) -> InlayClearanceTimes? {
            if let t = timed[s.timingKey] { return t }
            let t = project.inlayClearanceTimes(s, shapes: ids, tools: tools)
            timed[s.timingKey] = t
            return t
        }
        func quickest(_ s: InlayPairSettings) -> InlayPairSettings { times(s).map(s.withQuickestClearance) ?? s }
        var settings = InlaySheet.defaults(tools: tools)
        settings.boundary = VCarveInlay.Boundary(rawValue: d.string(forKey: "NativeCAMSnapshotInlayBoundary") ?? "") ?? .margin
        if let t = times(settings) {
            for side in VCarveInlay.Role.allCases {
                let each = t.times(side).map { "T\($0.tool.number) \(Self.duration($0.seconds))" }.joined(separator: ", ")
                log("inlay clearance times, \(side.rawValue) (\(settings.boundary.rawValue) boundary): \(each); "
                    + "quickest T\(t.quickest(side)?.number ?? 0)")
            }
        }
        if d.bool(forKey: "NativeCAMSnapshotInlayRaster") {
            settings.pickClearance(nil, for: .pocket)
            settings.pickClearance(nil, for: .plug)
            settings.flatRaster = VCarveRaster()
        }
        settings = quickest(settings)
        log("menu Add Toolpath: Profile (cut out / inside) | Pocket | Drill | V-carve | Inlay… | Chamfer | Fluting | Prism")
        // The dialog as it opens, and with each boundary (whole board both ways), the V-bit alone clearing in raster lines.
        var sheets: [(String, InlayPairSettings)] = [("inlay-sheet.png", quickest(InlaySheet.defaults(tools: tools)))]
        for boundary in VCarveInlay.Boundary.allCases {
            var s = settings
            s.boundary = boundary
            sheets.append(("inlay-sheet-\(boundary.rawValue).png", quickest(s)))
        }
        var custom = settings
        custom.boundary = .board
        custom.boardSize = Vec2(project.stock.width / 2, project.stock.height / 2)
        custom.pickClearance(nil, for: .pocket)
        custom.pickClearance(nil, for: .plug)
        custom.flatRaster = VCarveRaster(angle: 45)
        sheets.append(("inlay-sheet-board-size-raster.png", quickest(custom)))
        for (name, s) in sheets {
            render(InlaySheet(project: project, selection: ids, tools: tools, settings: s, times: times(s), height: 1000) { _ in },
                   size: NSSize(width: 520, height: 1000), out: out, name: name, spin: spin)
        }
        var result = project
        guard let pair = result.addInlay(settings, shapes: ids) else {
            log("inlay: no closed vectors to make one from")
            return project
        }
        let u = project.displayUnits
        for op in [pair.pocket, pair.plug] {
            guard case let .vcarve(p) = op.kind else { continue }
            log("inlay \(op.name): \(op.shapeIDs.count) vectors, T\(op.tool.number) \(op.tool.name), "
                + "P \(op.inlayPocketDepth.map { u.format($0) } ?? "-"), clearing \(p.clearanceTool.map { "T\($0.number)" } ?? "V-bit")"
                + (p.flatRaster.map { " raster \(u.format(p.vBitRasterStepover(op.tool), decimals: 4)) at \($0.angle)°" } ?? " rings")
                + (p.inlay.map { " \($0.role.rawValue) boundary \($0.boundary.rawValue)" } ?? "")
                + ", \(op.enabled ? "included" : "not included") in the output")
        }
        let job = CAMEngine.generate(result)
        for issue in job.issues { log("inlay check [\(issue.severity)] \(issue.operation ?? "job"): \(issue.message)") }
        log("inlay differences: \(pair.pocket.inlayDifferences(from: pair.plug).count)")
        // The plug's pocket depth changed: it offers to update the pocket.
        var plug = pair.plug
        if case var .vcarve(p) = plug.kind, var inlay = p.inlay {
            inlay.pocketDepth += 0.05.inch
            p.inlay = inlay
            plug.kind = .vcarve(p)
        }
        var mismatched = result
        if let i = mismatched.operations.firstIndex(where: { $0.id == plug.id }) { mismatched.operations[i] = plug }
        log("inlay differences after a new pocket depth on the plug: "
            + plug.inlayDifferences(from: pair.pocket).map { "\($0)" }.joined(separator: ", "))
        render(OperationInspector(op: .constant(plug), project: mismatched, workspace: Workspace()), size: NSSize(width: 440, height: 2000),
               out: out, name: "inspector-inlay-mismatch.png", spin: spin)
        return result
    }

    /// "3:23", or "1:02:05".
    static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Job Setup, each toolpath's inspector, the first shape's and the machine setup assistant's setup step, to inspector-*.png,
    /// and the tool editor for each bit the toolpaths use, to tool-T*.png.
    @MainActor
    private static func renderInspectors(_ project: Project, workspace ws: Workspace, out: URL, spin: (Double) -> Void) {
        func render(_ view: some View, size: NSSize, name: String) {
            Self.render(view, size: size, out: out, name: name, spin: spin)
        }
        let tall = NSSize(width: 440, height: 2600)
        render(SetupInspector(project: .constant(project)), size: tall, name: "inspector-setup.png")
        for (i, op) in project.operations.enumerated() {
            render(OperationInspector(op: .constant(op), project: project, workspace: ws), size: tall, name: "inspector-op-\(i).png")
        }
        if let shape = project.shapes.first {
            render(ShapeInspector(shape: .constant(shape), units: project.displayUnits, stock: project.stock, layers: project.layerNames,
                                  setLayer: { _ in }), size: NSSize(width: 440, height: 900), name: "inspector-shape-0.png")
        }
        render(MachineSetupView(offerUseHere: false, start: ("generic", .setup), height: 1100) { _, _, _ in },
               size: NSSize(width: 640, height: 1100), name: "inspector-machine-setup.png")
        // The Tool Library's editor for each bit the toolpaths use, with its live drawing (tool-T<number>.png).
        var seen = Set<UUID>()
        for op in project.operations where seen.insert(op.tool.id).inserted {
            render(ToolEditor(tool: .constant(op.tool), units: project.displayUnits), size: NSSize(width: 720, height: 1100),
                   name: "tool-T\(op.tool.number).png")
        }
    }

    /// Logs what the Tool Library's Reset to Starter Library… dialog and Add Missing Starter Tools report say, for a
    /// library saved before the 1/2" end mill joined the starter library, with an edited starter bit and a T10 of its
    /// own (the dialogs themselves can't be drawn offscreen). Changes no library.
    @MainActor
    private static func starterLibraryCheck(log: (String) -> Void) {
        var library = ToolLibrary(tools: ToolLibrary.starter.tools.filter { $0.number != 10 })
        library.tools[0].cutting.feedRate = 150.inch
        var own = ToolLibrary.starter.tools[6]
        own.id = UUID()
        own.number = 10
        own.diameter = 0.375.inch
        own.name = "3/8\" Ball Nose"
        library.tools.append(own)
        let reset = library.starterReset
        log("tool library reset dialog: \(StarterLibraryText.resetTitle(reset)) | \(StarterLibraryText.resetMessage(reset))")
        let report = StarterLibraryText.report(library.missingStarterTools())
        log("tool library add missing: \(report.title) | \(report.message.replacingOccurrences(of: "\n", with: " / "))")
        let none = StarterLibraryText.report(ToolLibrary.starter.missingStarterTools())
        log("tool library add missing (up to date): \(none.title) | \(none.message)")
    }

    /// Logs the job's issues and the export checks of every file the post writes, as Export would show them.
    @MainActor
    private static func exportCheck(_ project: Project, job: JobResult?, log: (String) -> Void) {
        guard let job, let output = JobExport.files(project, job: job) else { return log("export check: no job or no post") }
        for issue in job.issues { log("job \(issue.severity.rawValue): \(issue.operation.map { "\($0): " } ?? "")\(issue.message)") }
        var fileErrors = 0
        for file in output.files {
            if output.files.count > 1 { log("file\(file.suffix ?? ""): \(file.toolpaths.count) toolpaths") }
            for issue in GCodeCheck.run(file.gcode, toolpaths: file.toolpaths, project: file.project, dialect: output.post.dialect)
            where issue.severity != .info {
                log("G-code\(file.suffix ?? "") \(issue.severity.rawValue): \(issue.text)")
                if issue.severity == .error { fileErrors += 1 }
            }
        }
        log("export check: \(job.issues.filter { $0.severity == .error }.count) job errors, \(fileErrors) G-code errors")
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Drives CanvasController the way the Metal view does and reports what happened.
    @MainActor
    static func interactionSelfCheck(_ start: Project, log: (String) -> Void) {
        var doc = start
        let binding = Binding(get: { doc }, set: { doc = $0 })
        let ws = Workspace()
        let canvas = CanvasController(project: binding, workspace: ws)
        func check(_ name: String, _ ok: Bool) { log("check \(ok ? "PASS" : "FAIL"): \(name)") }
        guard let pocket = doc.shapes.first(where: { $0.name == "Plaque pocket" }) else { log("no pocket"); return }
        let tol = 0.05.inch
        // Click on the pocket outline (top edge) selects it.
        let edge = Vec2(pocket.position.x, pocket.position.y + 1.25.inch)
        let took = canvas.viewportMouseDown(at: edge, tolerance: tol, modifiers: [])
        check("click on outline selects shape", took && ws.selectedShapeIDs == [pocket.id])
        // Drag 1" right commits one move.
        canvas.viewportDragMoved(to: edge + Vec2(0.5.inch, 0))
        canvas.viewportDragEnded(at: edge + Vec2(1.inch, 0), moved: true, clickCount: 1, modifiers: [])
        let moved = doc.shape(id: pocket.id)!.position
        check("drag moves shape by 1in", abs(moved.x - (pocket.position.x + 1.inch)) < 1e-6 && abs(moved.y - pocket.position.y) < 1e-6)
        // Clicking inside a big outline (away from its lines) does not grab it: it's empty canvas and deselects.
        let inside = Vec2(6.inch, 8.inch)
        let insideHit = canvas.viewportMouseDown(at: inside, tolerance: tol, modifiers: [])
        if !insideHit { canvas.viewportClickedEmpty(modifiers: []) }
        check("click inside sign outline is empty canvas", !insideHit && ws.selection.isEmpty)
        // Clicking inside a letter selects the text.
        if let title = doc.shapes.first(where: { $0.name == "Title" }) {
            let letters = ws.outlines(title)
            let inLetter = letters.compactMap { $0.interiorPoint() }.first { p in letters.filter { $0.contains(p) }.count == 1 }
            if let pt = inLetter {
                _ = canvas.viewportMouseDown(at: pt, tolerance: tol, modifiers: [])
                canvas.viewportDragEnded(at: pt, moved: false, clickCount: 1, modifiers: [])
                check("click inside a letter selects text", ws.selectedShapeIDs == [title.id])
            }
        }
        // Marquee around the two left mounting holes.
        canvas.viewportMarquee([Vec2(1.inch, 1.inch), Vec2(4.inch, 1.inch), Vec2(4.inch, 17.inch), Vec2(1.inch, 17.inch)], modifiers: [])
        let holes = Set(doc.shapes.filter { $0.name.hasPrefix("Mounting hole") && $0.position.x < 5.inch }.map(\.id))
        check("marquee selects enclosed shapes", Set(ws.selectedShapeIDs) == holes && holes.count == 2)
        // Shift-click adds the pocket.
        let pocketEdge = Vec2(moved.x, moved.y + 1.25.inch)
        _ = canvas.viewportMouseDown(at: pocketEdge, tolerance: tol, modifiers: .shift)
        canvas.viewportDragEnded(at: pocketEdge, moved: false, clickCount: 1, modifiers: .shift)
        check("shift-click extends selection", ws.selectedShapeIDs.count == 3)
        // Arrow nudge (right, 1/16").
        let arrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let before = doc.shape(id: pocket.id)!.position.x
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: arrow, charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 124) {
            _ = canvas.viewportKeyDown(e)
        }
        check("right arrow nudges 1/16in", abs(doc.shape(id: pocket.id)!.position.x - before - 0.0625.inch) < 1e-6)
        // Copy + paste adds three offset copies; delete removes them again.
        let count = doc.shapes.count
        canvas.viewportPerform(.copy)
        canvas.viewportPerform(.paste)
        check("paste adds copies and selects them", doc.shapes.count == count + 3 && ws.selectedShapeIDs.count == 3)
        canvas.viewportPerform(.delete)
        check("delete removes selection", doc.shapes.count == count && ws.selection.isEmpty)
        canvas.viewportPerform(.selectAll)
        check("select all", ws.selectedShapeIDs.count == doc.shapes.count)
        canvas.viewportPerform(.duplicate)
        check("duplicate", doc.shapes.count == count * 2)
        // Deleting a shape also detaches it from operations.
        let opShape = doc.operations[0].shapeIDs[0]
        ws.selection = [.shape(opShape)]
        canvas.viewportPerform(.delete)
        check("delete detaches from toolpaths", !doc.operations.contains { $0.shapeIDs.contains(opShape) })
        check("context menu builds", canvas.viewportMenu(at: Vec2(12.inch, 5.inch), tolerance: tol)?.items.isEmpty == false)
    }
}
