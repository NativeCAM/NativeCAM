import Foundation

/// A printable page for whoever runs the job: material and zero, the tools in the order they go in, each
/// toolpath with its run time, clamps to keep clear of, and the checks that are still open.
public enum SetupSheet {
    public static func html(project: Project, job: JobResult, gcodeFile: String? = nil, checks: [GCodeCheck.Issue] = [],
                            date: Date = Date()) -> String {
        if let sheets = job.sheets {
            return head(project.name) + sheetsCover(project: project, job: job, sheets: sheets, gcodeFile: gcodeFile, checks: checks, date: date)
                + "</body></html>\n"
        }
        return head(project.name) + content(project: project, job: job, gcodeFile: gcodeFile, checks: checks, date: date)
            + "</body></html>\n"
    }

    /// The page's head and styles.
    static func head(_ title: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>\(esc(title)) setup sheet</title>
        <style>
        body { font: 13px/1.4 -apple-system, "Helvetica Neue", sans-serif; color: #111; background: #fff; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 2px; } h2 { font-size: 15px; margin: 22px 0 6px; }
        .sub { color: #555; margin-bottom: 14px; }
        table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
        th { font-weight: 600; background: #f4f4f4; } td.num { text-align: right; font-variant-numeric: tabular-nums; }
        dl { display: grid; grid-template-columns: max-content 1fr; gap: 3px 16px; margin: 0; } dt { color: #555; } dd { margin: 0; }
        .change td { background: #fff7e0; } tr.tilerow td { background: #e8f1ff; } .error { color: #b00020; } .warning { color: #8a5a00; }
        section.tile { break-before: page; margin-top: 28px; border-top: 2px solid #ccc; padding-top: 6px; }
        svg.preview { width: 100%; max-height: 520px; border: 1px solid #ddd; background: #fafafa; margin-top: 10px; }
        @media print { body { margin: 0; } h2 { break-after: avoid; } tr { break-inside: avoid; } section.tile { border-top: none; margin-top: 0; } }
        </style></head><body>

        """
    }

    /// A job nested onto several sheets: the job as a whole (the sheets, the bits, the checks), then a page for each
    /// sheet, as a setup sheet of its own for its files.
    static func sheetsCover(project: Project, job: JobResult, sheets: [SheetJob], gcodeFile: String?,
                            checks: [GCodeCheck.Issue], date: Date) -> String {
        let u = project.displayUnits, stock = project.stock, machine = project.machine
        func len(_ mm: Double) -> String { "\(u.format(mm, decimals: u == .inch ? 3 : 1)) \(u.symbol)" }
        func size(_ v: Vec2) -> String { "\(u.format(v.x, decimals: u == .inch ? 3 : 1)) × \(len(v.y))" }
        func time(_ s: Double) -> String {
            let t = Int(s.rounded())
            return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let export = JobExport.files(project, job: job, date: date)
        let base = gcodeFile ?? ((project.name.isEmpty ? "Untitled" : project.name) + "." + (export?.post.fileExtension ?? "tap"))
        let names = export.map { JobExport.fileNames($0.files, base: base, fileExtension: $0.post.fileExtension) } ?? []
        func files(ofSheet k: Int) -> [String] {
            guard let export else { return [] }
            return zip(export.files, names).filter { $0.0.sheet == k }.map(\.1)
        }
        let sizes = sheets.map { project.sheetSize($0.index) }
        let sameSize = sizes.allSatisfy { $0.isApprox(sizes[0], tolerance: 1e-6) }
        var h = """
        <h1>\(esc(project.name))</h1>
        <div class="sub">Setup sheet · \(esc(df.string(from: date)))\(gcodeFile.map { " · " + esc($0) } ?? "")</div>

        <h2>Job</h2>
        <dl>
        <dt>Machine</dt><dd>\(esc(machine.displayName)), \(esc(machine.controllerLabel)), \(esc(machine.spindle.label)), \(esc(machine.toolChange.label))</dd>
        <dt>Material</dt><dd>\(esc(stock.materialName)), \(len(stock.thickness)) thick: \(sheets.count) sheets\(sameSize ? " of \(size(sizes[0]))" : ""), cut one after another. A page for each follows.</dd>
        <dt>XY zero</dt><dd>\(esc(stock.xyOrigin.label)) of each sheet</dd>
        <dt>Z zero</dt><dd>\(esc(stock.zZero.label))</dd>
        <dt>Safe Z</dt><dd>\(len(stock.clearanceHeight)) above the material</dd>
        <dt>G-code units</dt><dd>\(machine.outputUnits == .inch ? "Inches (G20)" : "Millimetres (G21)")</dd>
        <dt>Run time</dt><dd>About \(time(job.estimatedSeconds)), all sheets</dd>
        </dl>

        """
        h += "<h2>Sheets</h2>\n<table><tr><th>#</th><th>Size</th><th class=\"num\">Parts</th><th>File</th><th class=\"num\">Time</th></tr>\n"
        for s in sheets {
            // As nesting counts them: a part in another's hole is a part of its own.
            let parts = NestJob.separateParts(of: s.project, toolpaths: s.job.toolpaths).filter(\.isClosed).count
            let file = s.cutsAnything ? files(ofSheet: s.index).map(esc).joined(separator: "<br>") : "Nothing to cut: no file"
            h += "<tr><td>\(s.index + 1)</td><td>\(size(sizes[s.index]))</td><td class=\"num\">\(parts)</td><td>\(file)</td>"
                + "<td class=\"num\">\(time(s.job.estimatedSeconds))</td></tr>\n"
        }
        h += "</table>\n"
        // Every bit the job uses, once, in the order they first go in.
        var order: [Tool] = []
        for tp in job.toolpaths where !tp.isEmpty && !order.contains(where: { $0.number == tp.tool.number && $0.isSameBit(as: tp.tool) }) {
            order.append(tp.tool)
        }
        h += "<h2>Tools</h2>\n<table><tr><th>#</th><th>Tool</th><th>Type</th><th class=\"num\">Diameter</th><th class=\"num\">Cutting length</th><th class=\"num\">Stick-out</th></tr>\n"
        for (i, t) in order.enumerated() {
            var type = t.shape.label
            if t.shape.usesAngle { type += " \(Int(t.includedAngle.rounded()))°" }
            h += "<tr><td>\(i + 1)</td><td>T\(t.number) \(esc(t.name))</td><td>\(esc(type))</td><td class=\"num\">\(len(t.diameter))</td>"
                + "<td class=\"num\">\(len(t.fluteLength))</td><td class=\"num\">\(len(t.stickout))</td></tr>\n"
        }
        h += "</table>\n"
        let open = job.issues.filter { $0.severity != .info }
        let fileChecks = checks.filter { $0.severity != .info }
        if !open.isEmpty || !fileChecks.isEmpty {
            h += "<h2>Checks</h2>\n<ul>\n"
            for i in open {
                h += "<li class=\"\(i.severity.rawValue)\">\(i.operation.map { esc($0) + ": " } ?? "")\(esc(i.message))</li>\n"
            }
            for i in fileChecks { h += "<li class=\"\(i.severity.rawValue)\">G-code: \(esc(i.text))</li>\n" }
            h += "</ul>\n"
        }
        // A page for each sheet: its own setup sheet, for its files (the checks are the job's, above).
        for s in sheets where s.cutsAnything {
            let mine = files(ofSheet: s.index)
            h += "<section class=\"tile\">\n"
            h += content(project: s.project, job: s.job, gcodeFile: mine.isEmpty ? nil : mine.joined(separator: ", "), checks: [],
                         date: date, listChecks: false)
            h += sheetPreview(project: s.project, job: s.job)
            h += "</section>\n"
        }
        return h
    }

    /// One sheet from above: the material, its shapes and its cuts, and the XY zero.
    static func sheetPreview(project: Project, job: JobResult) -> String {
        let stock = project.stock
        let pad = max(stock.width, stock.height) * 0.03
        let lo = Vec2(-pad, -pad), hi = Vec2(stock.width + pad, stock.height + pad)
        let size = hi - lo
        let stroke = max(size.x, size.y) / 500
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        // SVG's Y runs down: flip it so the sheet's lower-left is at the bottom left.
        func y(_ v: Double) -> Double { hi.y - v + lo.y }
        var s = "<svg class=\"preview\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(lo.x)) \(n(lo.y)) \(n(size.x)) \(n(size.y))\">\n"
        s += "<rect x=\"0\" y=\"\(n(y(stock.height)))\" width=\"\(n(stock.width))\" height=\"\(n(stock.height))\" fill=\"#f1ebdd\" stroke=\"#8a7f6a\" stroke-width=\"\(n(stroke))\"/>\n"
        var shapes = ""
        for shape in project.shapes {
            for line in shape.polylines(tolerance: 0.2) where line.count >= 2 {
                shapes += "M" + line.points.map { "\(n($0.x)) \(n(y($0.y)))" }.joined(separator: "L") + (line.isClosed ? "Z" : "")
            }
        }
        if !shapes.isEmpty { s += "<path d=\"\(shapes)\" fill=\"none\" stroke=\"#8a7f6a\" stroke-width=\"\(n(stroke))\"/>\n" }
        let step = max(1.0, max(size.x, size.y) / 800)
        var d = ""
        for tp in job.toolpaths {
            var last: Vec2?
            tp.forEachMotion { start, m in
                guard m.kind != .dwell else { return }
                if m.kind == .rapid || m.end.z >= 0 { last = nil; return }
                if last == nil { d += "M\(n(start.xy.x)) \(n(y(start.xy.y)))"; last = start.xy }
                for q in m.samples(from: start, maxStep: step) where q.xy.distance(to: last!) >= step {
                    d += "L\(n(q.x)) \(n(y(q.y)))"
                    last = q.xy
                }
            }
        }
        if !d.isEmpty { s += "<path d=\"\(d)\" fill=\"none\" stroke=\"#0b4fb3\" stroke-width=\"\(n(stroke * 1.5))\"/>\n" }
        let zero = stock.originPoint
        let arm = max(size.x, size.y) / 60
        s += "<path d=\"M\(n(zero.x - arm)) \(n(y(zero.y)))L\(n(zero.x + arm)) \(n(y(zero.y)))M\(n(zero.x)) \(n(y(zero.y - arm)))L\(n(zero.x)) \(n(y(zero.y + arm)))\" stroke=\"#000\" stroke-width=\"\(n(stroke * 2))\"/>\n"
        s += "</svg>\n"
        return s
    }

    /// The setup sheet's content for one job (a sheet's, on a nested job), from its title to the tile pages.
    static func content(project: Project, job: JobResult, gcodeFile: String?, checks: [GCodeCheck.Issue], date: Date,
                        listChecks: Bool = true) -> String {
        let u = project.displayUnits, stock = project.stock, machine = project.machine
        func len(_ mm: Double) -> String { "\(u.format(mm, decimals: u == .inch ? 3 : 1)) \(u.symbol)" }
        func feed(_ mmPerMin: Double) -> String { "\(u.format(mmPerMin, decimals: u == .inch ? 0 : 0)) \(u.feedSymbol)" }
        func time(_ s: Double) -> String {
            let t = Int(s.rounded())
            return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"

        // The material and zero rows: a flat sheet, or one face of a rotary blank with Z zero on the axis.
        let setupRows: String
        if let blank = stock.rotary {
            let avid = machine.isLegacyAvidMach4 || machine.controller?.family == .centroid
            let shape = blank.shape == .cylinder ? "round, \(len(blank.diameter)) diameter" : "square bar, \(len(blank.diameter)) across"
            func rotaryRow(_ blank: RotaryStock) -> String {
                let letter = esc(machine.rotary?.letter.rawValue ?? "A")
                guard blank.isWrapped else {
                    // Rounding and 3D rotary finishing turn the blank as they cut, on faces too.
                    let turning = job.toolpaths.contains { $0.wrapDiameter != nil }
                        ? " \(letter) also turns while the tool cuts the toolpaths marked “all round”." : ""
                    return "<dt>Rotary</dt><dd>\(esc(RotaryOutput.setupNote(machine)))\(turning) Raise the tool clear of the chuck and tailstock before starting.</dd>"
                }
                return "<dt>Rotary</dt><dd>Designs wrap around \(len(blank.wrapDiameterOrBlank)): the middle of the sheet is the top of the blank at \(letter)0, and \(letter) turns while the tool cuts. Raise the tool clear of the chuck and tailstock before starting.</dd>"
            }
            // On an axis along Y the blank's length runs along machine Y, and X zero is on the centreline.
            let mounting = RotaryFrame(project).alignment
            let zero = "\(mounting.axisName) at the \(RotaryOutput.xZero(stock, alignment: mounting)), "
                + "\(mounting.acrossName) on the rotation axis centreline"
            setupRows = """
            <dt>Material</dt><dd>\(esc(stock.materialName)) rotary blank: \(shape), \(len(blank.length)) long\(mounting == .x ? "" : ", along machine Y")</dd>
            <dt>XY zero</dt><dd>\(zero)</dd>
            <dt>Z zero</dt><dd class="error">On the rotation axis\(avid ? " (Avid: Rotary tab ▸ Z Axis Touch)" : ""), not the top of the blank</dd>
            \(rotaryRow(blank))
            <dt>Safe Z</dt><dd>\(len(stock.clearanceHeight)) above the \(blank.isWrapped ? "wrap diameter" : "top face") (\(len(blank.topRadius + stock.clearanceHeight)) from the axis)</dd>
            """
        } else if let tiled = job.tiling {
            let layout = tiled.layout
            setupRows = """
            <dt>Material</dt><dd>\(esc(stock.materialName)): \(len(stock.width)) × \(len(stock.height)) × \(len(stock.thickness))</dd>
            <dt>Tiles</dt><dd>\(layout.count), \(esc(layout.mode == .grid ? "individual tiles" : "fed through in \(layout.mode == .feedThroughX ? "X" : "Y")")): \(esc(Self.tileSummary(layout, len: len))). Each tile reaches \(len(layout.overlap)) past its tile lines. A page for each follows.</dd>
            <dt>XY zero</dt><dd>\(esc(stock.xyOrigin.label)) of the tile, \(len(layout.pitch.x)) × \(len(layout.pitch.y)): the same place on the machine for every tile</dd>
            <dt>Z zero</dt><dd>\(esc(stock.zZero.label))</dd>
            <dt>Safe Z</dt><dd>\(len(stock.clearanceHeight)) above the material</dd>
            \(Self.gridDowelStopRow(layout, machine: project.machine))
            """
        } else {
            setupRows = """
            <dt>Material</dt><dd>\(esc(stock.materialName)): \(len(stock.width)) × \(len(stock.height)) × \(len(stock.thickness))</dd>
            <dt>XY zero</dt><dd>\(esc(stock.xyOrigin.label)) of the material</dd>
            <dt>Z zero</dt><dd>\(esc(stock.zZero.label))</dd>
            <dt>Safe Z</dt><dd>\(len(stock.clearanceHeight)) above the material</dd>
            """
        }
        let zeroZ = stock.rotary == nil ? "zero Z (\(esc(stock.zZero.label.lowercased())))" : "zero Z on the rotation axis"
        let rezeroZ = stock.rotary == nil ? "re-zero Z with the touch plate" : "re-zero Z on the rotation axis"
        let angleColumn = stock.rotary.map { !$0.isWrapped } ?? false

        var h = """
        <h1>\(esc(project.name))</h1>
        <div class="sub">Setup sheet · \(esc(df.string(from: date)))\(gcodeFile.map { " · " + esc($0) } ?? "")</div>

        <h2>Job</h2>
        <dl>
        <dt>Machine</dt><dd>\(esc(machine.displayName)), \(esc(machine.controllerLabel)), \(esc(machine.spindle.label)), \(esc(machine.toolChange.label))</dd>
        \(setupRows)
        <dt>G-code units</dt><dd>\(machine.outputUnits == .inch ? "Inches (G20)" : "Millimetres (G21)")</dd>
        <dt>Run time</dt><dd>About \(time(job.estimatedSeconds))</dd>

        """
        if job.tiling == nil, let ext = extents(job.toolpaths) {
            let (lo, hi) = RotaryFrame(project).workBox(min: ext.min, max: ext.max)
            if let wrapped = wrappedExtents(project: project, job: job, len: len) {
                h += "<dt>Cutting extents</dt><dd>\(wrapped)</dd>\n"
            } else {
                h += "<dt>Cutting extents</dt><dd>X \(len(lo.x)) to \(len(hi.x)), Y \(len(lo.y)) to \(len(hi.y)), "
                    + "Z \(len(lo.z)) to \(len(hi.z)) (work coordinates)</dd>\n"
            }
        }
        h += "</dl>\n"

        // Tools in the order they go into the spindle.
        var order: [Tool] = []
        for tp in job.toolpaths where !tp.isEmpty && order.last?.number != tp.tool.number {
            // A tiled job lists each bit once: every tile's file goes through them again.
            if job.tiling != nil, order.contains(where: { $0.number == tp.tool.number && $0.isSameBit(as: tp.tool) }) { continue }
            order.append(tp.tool)
        }
        h += "<h2>Tools</h2>\n<table><tr><th>#</th><th>Tool</th><th>Type</th><th class=\"num\">Diameter</th><th class=\"num\">Cutting length</th><th class=\"num\">Stick-out</th></tr>\n"
        for (i, t) in order.enumerated() {
            var type = t.shape.label
            if t.shape.usesAngle { type += " \(Int(t.includedAngle.rounded()))°" }
            type += t.shapeDetail(len)
            h += "<tr><td>\(i + 1)</td><td>T\(t.number) \(esc(t.name))</td><td>\(esc(type))</td><td class=\"num\">\(len(t.diameter))</td>"
                + "<td class=\"num\">\(len(t.fluteLength))</td><td class=\"num\">\(len(t.stickout))</td></tr>\n"
        }
        h += "</table>\n"

        // Rest-machined pockets: what the larger bit leaves and what the smaller one then cuts.
        var rest: [String] = []
        for op in project.operations {
            guard case let .pocket(p) = op.kind, let large = p.clearanceTool else { continue }
            let cut = job.toolpaths.filter { $0.sourceOperationID == op.id && !$0.isEmpty }
            guard cut.contains(where: { $0.tool.number == op.tool.number && $0.tool.isSameBit(as: op.tool) }) else { continue }
            func bit(_ t: Tool) -> String { "T\(t.number) \(esc(t.name))" }
            let finish = p.allowance > 1e-9 ? ", leaving \(len(p.allowance)) for a finishing pass" : ""
            if cut.contains(where: { $0.id != op.id && $0.tool.number == large.number && $0.tool.isSameBit(as: large) }) {
                let margin = p.allowance + PocketParams.restMargin(for: op.tool)
                rest.append("<li>\(esc(op.name)): \(bit(large)) clears the pocket first, leaving \(len(margin)) on the walls. "
                    + "\(bit(op.tool)) then cuts only the corners and narrow parts the larger bit can't reach, and the final pass "
                    + "round the walls\(finish).</li>\n")
            } else {
                rest.append("<li>\(esc(op.name)): \(bit(large)) doesn't fit in the pocket, so \(bit(op.tool)) clears all of it\(finish).</li>\n")
            }
        }
        if !rest.isEmpty { h += "<h2>Rest machining</h2>\n<ul>\n" + rest.joined() + "</ul>\n" }

        h += "<h2>Run order</h2>\n<table><tr><th>#</th><th>Toolpath</th><th>Tool</th>\(angleColumn ? "<th class=\"num\">Angle</th>" : "")<th class=\"num\">RPM</th><th class=\"num\">Feed</th><th class=\"num\">Depth</th><th class=\"num\">Time</th></tr>\n"
        var current: Int?
        var step = 0
        var lastTile: Int?
        var loadFeedsNote = false
        // Spindle ▸ Automatic: each toolpath whose speed was picked, and why (after the table).
        var automatic: [(step: Int, name: String, why: String)] = []
        let export = job.tiling == nil ? nil : JobExport.files(project, job: job, date: date)
        let names = export.map { JobExport.fileNames($0.files, base: gcodeFile ?? ((project.name.isEmpty ? "Untitled" : project.name) + "." + $0.post.fileExtension), fileExtension: $0.post.fileExtension) } ?? []
        func files(ofTile t: Int) -> [String] {
            guard let export else { return [] }
            return zip(export.files, names).filter { $0.0.tile == t }.map(\.1)
        }
        // A blank turned by hand: the program stops before each new angle, as the post writes it.
        let rotary = RotaryOutput(project)
        var dial: Double?
        for tp in job.toolpaths where !tp.isEmpty {
            if let t = tp.tile, t != lastTile, let tiled = job.tiling {
                // Each tile is its own file, which starts by loading its first tool.
                lastTile = t
                current = nil
                let file = files(ofTile: t).map(esc).joined(separator: ", ")
                h += "<tr class=\"tilerow\"><td></td><td colspan=\"\(angleColumn ? 7 : 6)\"><b>Tile \(t + 1) of \(tiled.layout.count)</b>: "
                    + "\(esc(Self.moveText(tiled.layout, to: t, stock: stock, len: len)))\(file.isEmpty ? "" : " Run \(file).")</td></tr>\n"
            }
            if current != tp.tool.number {
                let what: String
                switch machine.toolChange {
                case .atc: what = "Tool changer loads T\(tp.tool.number)."
                case .manualM6, .manualPause:
                    what = current == nil
                        ? "Load T\(tp.tool.number) \(esc(tp.tool.name)) and \(zeroZ) before starting."
                        : "Change to T\(tp.tool.number) \(esc(tp.tool.name)) and \(rezeroZ), then press Cycle Start."
                }
                h += "<tr class=\"change\"><td></td><td colspan=\"\(angleColumn ? 7 : 6)\">\(what)</td></tr>\n"
                current = tp.tool.number
            }
            if let rotary, rotary.manual, let angle = tp.indexAngle, dial != rotary.position(angle) {
                dial = rotary.position(angle)
                h += "<tr class=\"change\"><td></td><td colspan=\"7\">The program stops: turn the blank to "
                    + "\(esc(RotaryIndex.label(rotary.position(angle)))) by hand, then press Cycle Start.</td></tr>\n"
            }
            step += 1
            let rpm = machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM
            let maxFeed = tp.motions.filter { $0.kind == .feed || $0.kind.isArc }.map(\.feed).max() ?? 0
            let depth = tp.cuttingExtents.map { -$0.min.z } ?? 0
            let seconds = job.estimatedSeconds(toolpath: tp.id).map(time) ?? "–"
            let angle = angleColumn
                ? "<td class=\"num\">\(tp.wrapDiameter != nil ? "all round" : tp.indexAngle.map { esc(RotaryIndex.label($0)) } ?? "–")</td>" : ""
            // Feeds that follow the load: the range, marked.
            var feedCell = feed(maxFeed)
            if let lf = tp.loadFeeds, lf.varies {
                feedCell = "\(u.format(lf.lowest, decimals: 0))–\(feed(maxFeed)) *"
                loadFeedsNote = true
            }
            var rpmMark = ""
            if let auto = tp.automaticSpindle {
                rpmMark = " †"
                automatic.append((step, tp.name, auto.reason(u)))
            }
            h += "<tr><td>\(step)</td><td>\(esc(tp.name))</td><td>T\(tp.tool.number)</td>\(angle)<td class=\"num\">\(Int(rpm.rounded()))\(machine.spindle == .router ? " (dial)" : "")\(rpmMark)</td>"
                + "<td class=\"num\">\(feedCell)</td><td class=\"num\">\(len(max(0, depth)))</td><td class=\"num\">\(seconds)</td></tr>\n"
        }
        h += "</table>\n"
        if loadFeedsNote {
            h += "<p>* Adjust feeds for load: the feed slows in full-width cuts, inside corners and tight inside arcs, and "
                + "runs at the higher feed elsewhere.</p>\n"
        }
        if !automatic.isEmpty {
            h += "<p>† Automatic spindle speed, picked from the chip-load chart (not yet calibrated on this machine) "
                + "instead of the tool's RPM:</p>\n<ul>\n"
            for a in automatic { h += "<li>\(a.step). \(esc(a.name)): \(esc(a.why))</li>\n" }
            h += "</ul>\n"
        }

        // 3D rotary roughing and finishing: the model each one works on, how it sits on the blank and how it's cut.
        let rotary3D = project.operations.filter { op in
            guard op.enabled, op.kind.is3D, op.kind.turnsWholeBlank else { return false }
            return job.toolpaths.contains { $0.sourceOperationID == op.id && !$0.isEmpty }
        }
        if !rotary3D.isEmpty {
            h += "<h2>3D rotary</h2>\n<ul>\n"
            for op in rotary3D {
                let models = project.shapes(for: op).filter { $0.modelSpec != nil }
                let placed = models.compactMap { m -> String? in
                    guard let e = m.rotaryExtent, let spec = m.modelSpec else { return nil }
                    let axis = (spec.rotary ?? RotaryPlacement(longestOf: spec.mesh)).alongAxis.rawValue.uppercased()
                    return "“\(esc(m.name))” (its \(axis) axis along the blank, X \(len(e.minX)) to \(len(e.maxX)), "
                        + "\(len(2 * e.radius)) across at most)"
                }.joined(separator: ", ")
                switch op.kind {
                case let .rotaryRough(p):
                    let how: String
                    switch p.pattern {
                    case .auto: how = "lines each area's longer way"
                    case .around: how = "lines round the blank"
                    case .along: how = "lines along the blank"
                    case .offset: how = "rings in from each area's edge"
                    }
                    h += "<li><b>\(esc(op.name))</b> roughs \(placed) with T\(op.tool.number) in layers \(len(p.stepdown(op.tool))) apart, "
                        + "as \(how) \(len(p.stepover(op.tool))) apart, leaving \(len(max(0, p.allowance))) for the finish. It clears only "
                        + "where there's stock left, so it skips the air over a square bar's faces. The blank turns while it cuts.</li>\n"
                case let .rotaryFinish(p):
                    let how: String
                    switch p.pattern {
                    case .spiral: how = "a spiral, \(len(p.stepover(op.tool))) along the blank per turn"
                    case .rings: how = "rings \(len(p.stepover(op.tool))) apart"
                    case .lines: how = "passes along the blank \(len(p.stepover(op.tool))) apart round it"
                    }
                    let layers = p.passDepth.map { " Cuts in layers no deeper than \(len($0)) first where the model is deeper." }
                        ?? " Cuts in layers no deeper than the bit's stepdown first where the model is deeper."
                    h += "<li><b>\(esc(op.name))</b> follows \(placed) with T\(op.tool.number), as \(how)"
                        + (p.allowance > 1e-9 ? ", leaving \(len(p.allowance))" : "") + ". The blank turns while it cuts.\(layers)</li>\n"
                default:
                    break
                }
            }
            h += "</ul>\n"
        }

        // Chamfers, flutes and prisms: the size of each bevel or flute, so it can be checked on the part.
        let cut = Set(job.toolpaths.filter { !$0.isEmpty }.map(\.sourceOperationID))
        let shaped = project.operations.filter { $0.kind.followsVectors && !$0.kind.isEdgeProfile && cut.contains($0.id) }
        if !shaped.isEmpty {
            h += "<h2>Chamfers, flutes and prisms</h2>\n<ul>\n"
            for op in shaped {
                let bit = op.tool.shape.isTapered ? "\(Int(op.tool.includedAngle.rounded()))° T\(op.tool.number)" : "T\(op.tool.number)"
                let from = { (start: Double) in start > 1e-9 ? ", from a start depth of \(len(start))" : "" }
                switch op.kind {
                case let .chamfer(p):
                    let side = p.side == .both ? "both sides of" : "\(p.side.rawValue)"
                    let edge = p.edge == .top ? "its top edge on the vector" : "its bottom edge on the vector"
                    if op.tool.shape == .form {
                        h += "<li><b>\(esc(op.name))</b>: a round-nose chamfer \(len(p.width)) wide, the tip \(len(p.depth(with: op.tool))) deep, "
                            + "\(side) the shapes, \(edge)\(from(p.startDepth)), with the T\(op.tool.number) \(esc(op.tool.name)).</li>\n"
                        break
                    }
                    let overcut = p.overcut(with: op.tool) > 1e-9 ? "; a \(len(p.overcut(with: op.tool))) overcut leaves a "
                        + "\(len(p.flatWidth(with: op.tool))) flat at its foot" : ""
                    h += "<li><b>\(esc(op.name))</b>: a bevel \(len(p.width)) wide and \(len(p.depth(with: op.tool))) deep \(side) the "
                        + "shapes, \(edge)\(from(p.startDepth)), with the \(bit)\(p.sharpCorners ? "; sharp corners" : "")\(overcut).</li>\n"
                case let .fluting(p):
                    let ramps: String
                    switch p.ramp {
                    case .both: ramps = "ramping in and out"
                    case .start: ramps = "ramping in at the start"
                    case .end: ramps = "ramping out at the end"
                    case .none: ramps = "full depth all along"
                    }
                    let length = p.ramp == .none ? ""
                        : p.rampPercent.map { " over \(Int(($0 * 100).rounded()))% of the length" } ?? " over \(len(p.rampLength))"
                    // Following a model, the depth is below its surface, not the stock's top (#139).
                    let measured: String
                    if let id = p.surfaceModelID {
                        let model = project.shapes.first { $0.id == id && $0.modelSpec != nil && !$0.isKeepOut }
                        measured = model.map { " below the surface of “\(esc($0.name))”" }
                            ?? " below the surface of a 3D model that isn't in the job"
                    } else {
                        measured = " deep\(from(p.startDepth))"
                    }
                    h += "<li><b>\(esc(op.name))</b>: flutes \(len(p.depth))\(measured), \(ramps)\(length)"
                        + "\(p.ramp == .none ? "" : " (\(p.rampShape.rawValue))"), with \(bit)."
                        + (p.ramp == .start || p.ramp == .end ? " Each starts at its vector's start point." : "") + "</li>\n"
                case let .prism(p):
                    let depth = p.depth.map { "\(len($0)) deep" } ?? "to a full ridge"
                    h += "<li><b>\(esc(op.name))</b>: prism carved \(depth)\(from(p.startDepth)) with the \(bit). Its bit cuts past "
                        + "the outline too; clear round it with a pocket or profile.</li>\n"
                default: break
                }
            }
            h += "</ul>\n"
        }

        // Edge profiles: the bit, the edges and how deep, so the profile can be checked on the part and the bit set up.
        let edges = project.operations.compactMap { op -> (CAMOperation, EdgeProfileParams)? in
            guard case let .edgeProfile(p) = op.kind, cut.contains(op.id) else { return nil }
            return (op, p)
        }
        if !edges.isEmpty {
            h += "<h2>Edge profiles</h2>\n<ul>\n"
            for (op, p) in edges {
                let plan = p.plan(tool: op.tool, thickness: project.stock.thickness)
                let which = p.edges == .both ? "outside edges and holes" : (p.edges == .holes ? "holes" : "outside edges")
                let bit = op.tool.name.isEmpty ? "T\(op.tool.number)" : "T\(op.tool.number) \(esc(op.tool.name))"
                let passes = plan.passes.filter { !$0.isFinish }.count
                let how = p.passes == .horizontal
                    ? "\(passes) pass\(passes == 1 ? "" : "es") stepping in from the waste"
                    : "stepping down in \(plan.passes.first?.depths.count ?? 1) pass\(plan.passes.first?.depths.count == 1 ? "" : "es")"
                let finish = plan.passes.contains(where: \.isFinish) ? ", then a \(len(p.finish)) finishing pass" : ""
                let reveal = plan.reveal > 1e-6 ? "; \(len(plan.reveal)) deeper than the profile, leaving that step above it" : ""
                let offset = p.offset > 1e-9 ? ", stood \(len(p.offset)) off the edge" : ""
                h += "<li><b>\(esc(op.name))</b>: the \(which) profiled \(len(plan.depth)) deep with \(bit)\(offset), \(how)\(finish)"
                    + "\(reveal). Its depth is to the bottom of the cutting edge: take any bearing off.</li>\n"
            }
            h += "</ul>\n"
        }

        // Profiles with a finishing pass: how far the roughing stays off the wall and how the finish cuts it, so the
        // operator knows the last lap is the one that sizes the part, and which way it runs.
        let finishing = project.operations.compactMap { op -> (CAMOperation, ProfileFinishPass)? in
            guard case let .profile(p) = op.kind, let f = p.finishPass, p.side != .on,
                  job.toolpaths.contains(where: { $0.sourceOperationID == op.id && $0.finishLaps != nil }) else { return nil }
            return (op, f)
        }
        if !finishing.isEmpty {
            h += "<h2>Finishing passes</h2>\n<ul>\n"
            for (op, f) in finishing {
                let depth = f.depth == .fullDepth ? "at full depth" : "at each pass depth"
                let rate = op.tool.cutting.feedRate * f.feedPercent
                let tabbed: Bool = { if case let .profile(p) = op.kind { return p.tabs.enabled && p.tabs.count > 0 } else { return false } }()
                let spring = f.springPass ? ", then a spring pass round it again" : ""
                h += "<li><b>\(esc(op.name))</b>: the roughing passes stop \(len(f.allowance)) off the wall, then a "
                    + "<b>\(f.direction.rawValue)</b> finishing pass \(depth) cuts it to size at \(Int((f.feedPercent * 100).rounded()))% feed "
                    + "(\(feed(rate)))\(spring).\(tabbed ? " It lifts over the same tabs as the roughing." : "")</li>\n"
            }
            h += "</ul>\n"
        }

        // Tabs: how many each profile leaves, their shape and size, so the operator knows the parts are held and how much
        // cleanup to expect.
        let tabbed = project.operations.compactMap { op -> (CAMOperation, ProfileParams, Int)? in
            guard case let .profile(p) = op.kind, p.cutsTabs else { return nil }
            // Once per toolpath: a tiled job's pieces of one toolpath share its ID and its tabs.
            var seen = Set<UUID>()
            let n = job.toolpaths.filter { $0.sourceOperationID == op.id && seen.insert($0.id).inserted }
                .reduce(0) { $0 + ($1.tabMarks?.filter(\.cut).count ?? 0) }
            return n > 0 ? (op, p, n) : nil
        }
        if !tabbed.isEmpty {
            h += "<h2>Tabs</h2>\n<ul>\n"
            let strips = HoldingTabs.setupSheetNotes(project, units: u)
            for (op, p, n) in tabbed {
                let held = strips.first { $0.cutOut == op.name }.map { " \(esc($0.text))" } ?? ""
                h += "<li><b>\(esc(op.name))</b>: \(tabsClause(p, count: n, units: u))\(held)</li>\n"
            }
            h += "</ul>\n"
        }

        // V-carve inlays: which side each toolpath cuts and the depths that make the two fit.
        let inlays = project.operations.compactMap { op -> (CAMOperation, VCarveParams, VCarveInlay)? in
            guard case let .vcarve(p) = op.kind, let inlay = p.inlay, cut.contains(op.id) else { return nil }
            return (op, p, inlay)
        }
        if !inlays.isEmpty {
            h += "<h2>Inlay</h2>\n<ul>\n"
            for (op, p, inlay) in inlays {
                let bit = "\(Int(op.tool.includedAngle.rounded()))° T\(op.tool.number)"
                switch inlay.role {
                case .pocket:
                    let flat = p.flatDepth.map { " to a flat depth of \(len($0))" } ?? " to full V depth"
                    let start = p.startDepth > 1e-9 ? " from a start depth of \(len(p.startDepth))" : ""
                    h += "<li>\(esc(op.name)): <b>pocket</b> (female), V-carved\(start)\(flat) with the \(bit). Cut the plug with the same bit.</li>\n"
                case .plug:
                    let board: String
                    if let rect = project.plugBoard(for: op) {
                        let corner = stock.toWork(Vec3(rect.min, 0))
                        board = inlay.boardSize == nil
                            ? "It's carved right out to the edges of its board: cut it from a board the size of the material, set up as the "
                                + "pocket's was, then glue"
                            : "It's carved right out to the edges of its board: cut it from a \(len(rect.width)) × \(len(rect.height)) board "
                                + "with its lower-left corner at X \(len(corner.x)), Y \(len(corner.y)), then glue"
                    } else {
                        board = "Cut it from its own board and saw it free inside the carved band, then glue"
                    }
                    h += "<li>\(esc(op.name)): <b>plug</b> (male), mirrored, with the \(bit): pocket depth \(len(inlay.pocketDepth)), "
                        + "glue gap \(len(inlay.glueGap)), surface clearance \(len(inlay.surfaceClearance)), so carved from "
                        + "\(len(inlay.plugStartDepth)) down to \(len(inlay.plugCutDepth)). \(board) it into the pocket face down and "
                        + "plane or sand it flush.</li>\n"
                }
            }
            h += "</ul>\n"
        }

        let clamps = project.shapes.filter(\.isKeepOut)
        if !clamps.isEmpty {
            h += "<h2>Clamps and keep-out areas</h2>\n<ul>\n"
            for c in clamps {
                h += "<li>\(esc(c.name)): \(len(c.keepOutHeight ?? 0)) tall, near X \(len(stock.toWork(Vec3(c.position, 0)).x)), Y \(len(stock.toWork(Vec3(c.position, 0)).y))</li>\n"
            }
            h += "</ul>\n"
        }

        let open = listChecks ? job.issues.filter { $0.severity != .info } : []
        let fileChecks = checks.filter { $0.severity != .info }
        if !open.isEmpty || !fileChecks.isEmpty {
            h += "<h2>Checks</h2>\n<ul>\n"
            for i in open {
                h += "<li class=\"\(i.severity.rawValue)\">\(i.operation.map { esc($0) + ": " } ?? "")\(esc(i.message))</li>\n"
            }
            for i in fileChecks { h += "<li class=\"\(i.severity.rawValue)\">G-code: \(esc(i.text))</li>\n" }
            h += "</ul>\n"
        }
        // A page for each tile: what to do before running its file, and what it cuts.
        if let tiled = job.tiling {
            for tile in tiled.layout.tiles {
                h += tilePage(project: project, job: job, tiled: tiled, tile: tile, files: files(ofTile: tile.index), len: len, time: time)
            }
        }
        return h
    }

    /// The cutting extents of a rotary job with toolpaths that turn the blank as they cut (every one on a wrapped job;
    /// rounding and 3D rotary roughing and finishing on faces), as the machine sees them: X along the blank, the range
    /// of A the program cuts at (as the posts write it, and the Avid post's program-extents comment gives it), and Z
    /// from the rotation axis. Their sheet Y is an angle, not a move: Y stays on the axis centreline, so Y is given
    /// only for the toolpaths cut on faces. On an axis along Y (`RotaryFrame`) the blank runs along Y and X is the
    /// axis across it. nil on any other job.
    /// A profile's tabs in a few words: "6 triangular, 0.375 × 0.125 in, placed by hand".
    static func tabsClause(_ p: ProfileParams, count: Int, units u: LengthUnit) -> String {
        let shape = p.tabs.shape == .triangular ? " triangular" : ""
        let size = "\(u.format(p.tabs.width, decimals: u == .inch ? 3 : 1)) × \(u.format(p.tabs.thickness, decimals: u == .inch ? 3 : 1)) \(u.symbol)"
        return "\(count)\(shape) \(count == 1 ? "tab" : "tabs"), \(size), \(p.tabs.isPlaced ? "placed by hand" : "evenly spaced")"
    }

    static func wrappedExtents(project: Project, job: JobResult, len: (Double) -> String) -> String? {
        let stock = project.stock, machine = project.machine
        let frame = RotaryFrame(project)
        let paths = job.toolpaths.filter { !$0.isEmpty }
        guard stock.rotary != nil, let rotary = RotaryOutput(project), let ext = extents(paths),
              paths.contains(where: { $0.wrapDiameter != nil && $0.cuttingExtents != nil }) else { return nil }
        // Along the blank and Z, in the blank's own frame: its X is the machine's along the axis either way.
        let lo = stock.toWork(ext.min), hi = stock.toWork(ext.max)
        var parts = ["\(frame.alignment.axisName) \(len(lo.x)) to \(len(hi.x)) along the blank"]
        if let flat = extents(paths.filter { $0.wrapDiameter == nil }) {
            let (a, b) = frame.workBox(min: flat.min, max: flat.max)
            let across = frame.alignment == .x ? (a.y, b.y) : (a.x, b.x)
            parts.append("\(frame.alignment.acrossName) \(len(across.0)) to \(len(across.1)) on the faces")
        }
        let units = machine.outputUnits
        let decimals = (Dialect.for(machine) ?? .avidMach4).coordinateDecimals(units)
        if let a = rotary.cutRange(paths, frame: frame, units: units, decimals: decimals) {
            func degrees(_ v: Double) -> String { String(format: "%.3f°", v == 0 ? 0 : v) }
            parts.append("\(esc(rotary.letter)) \(degrees(a.lowerBound)) to \(degrees(a.upperBound))")
        }
        parts.append("Z \(len(lo.z)) to \(len(hi.z)) from the rotation axis")
        return parts.joined(separator: ", ") + " (work coordinates)"
    }

    // MARK: Tiles

    /// How the tiles are laid out, in words.
    static func tileSummary(_ layout: TileLayout, len: (Double) -> String) -> String {
        switch layout.mode {
        case .feedThroughY: "the material moves \(len(layout.pitch.y)) along Y between tiles"
        case .feedThroughX: "the material moves \(len(layout.pitch.x)) along X between tiles"
        case .grid: "\(layout.columns) across and \(layout.rows) up, \(len(layout.pitch.x)) × \(len(layout.pitch.y)) apart"
        }
    }

    /// What to do with the material before tile `index`.
    static func moveText(_ layout: TileLayout, to index: Int, stock: Stock, len: (Double) -> String) -> String {
        guard index > 0 else {
            // Where the XY zero is on the material: the tile frame's corner (or centre), which is off the material when
            // the short tile comes first.
            let zero = layout.tileStock(stock).originPoint + layout.tiles[0].offset
            if zero.x.magnitude < 1e-6 && zero.y.magnitude < 1e-6 {
                return "Set the XY zero at the material's lower-left corner and keep it for every tile."
            }
            let note = layout.tiles[0].offset.y < -1e-6 || layout.tiles[0].offset.x < -1e-6
                ? " The short tile comes first, so the tile's frame starts before the material." : ""
            return "Set the XY zero at X \(len(zero.x)), Y \(len(zero.y)) from the material's lower-left corner (the "
                + "\(stock.xyOrigin.label.lowercased()) of the tile) and keep it for every tile.\(note)"
        }
        let d = layout.move(to: index)
        var parts: [String] = []
        if d.y.magnitude > 1e-6 { parts.append("\(len(d.y.magnitude)) toward Y\(d.y > 0 ? "−" : "+")") }
        if d.x.magnitude > 1e-6 { parts.append("\(len(d.x.magnitude)) toward X\(d.x > 0 ? "−" : "+")") }
        return "Move the material \(parts.joined(separator: " and ")); keep the XY zero."
    }

    /// One tile's page: the file, the move, the dowels, what it cuts and a picture of it.
    static func tilePage(project: Project, job: JobResult, tiled: TiledJob, tile: TileLayout.Tile, files: [String],
                         len: (Double) -> String, time: (Double) -> String) -> String {
        let layout = tiled.layout, stock = project.stock
        let tileStock = layout.tileStock(stock)
        func work(_ p: Vec2) -> String {
            let w = tileStock.toWork(Vec3(p, 0))
            return "X \(len(w.x)), Y \(len(w.y))"
        }
        let k = tile.index
        let tps = tiled.tiles[k].filter { !$0.isEmpty }
        var h = "<section class=\"tile\">\n<h2>Tile \(k + 1) of \(layout.count)</h2>\n<dl>\n"
        if !files.isEmpty {
            h += "<dt>File\(files.count > 1 ? "s" : "")</dt><dd>\(files.map(esc).joined(separator: "<br>"))</dd>\n"
        }
        h += "<dt>Before it</dt><dd>\(esc(moveText(layout, to: k, stock: stock, len: len)))</dd>\n"
        if let reg = layout.registration, !reg.holes.isEmpty {
            h += gridRegistration(reg, tile: k, layout: layout, machine: project.machine, work: work, len: len)
        } else if let reg = layout.registration {
            let dowels = reg.dowels[k], drilled = reg.drilled[k]
            if !dowels.isEmpty {
                h += "<dt>Dowels</dt><dd>Line the holes tile \(k) drilled up over the spoilboard holes and drop a \(len(2 * reg.radius)) "
                    + "dowel through each, at \(dowels.map(work).joined(separator: " and ")). Clamp the material, then tap the dowels "
                    + "flush or pull them out before starting.</dd>\n"
            }
            if !drilled.isEmpty {
                let spoil = Set(reg.spoilboard.map { "\($0.x),\($0.y)" })
                let fixed = drilled.filter { spoil.contains("\($0.x),\($0.y)") }, next = drilled.filter { !spoil.contains("\($0.x),\($0.y)") }
                var what: [String] = []
                if !fixed.isEmpty { what.append("the spoilboard holes in front of the material at \(fixed.map(work).joined(separator: " and "))") }
                if !next.isEmpty { what.append("the holes for tile \(k + 2)'s dowels at \(next.map(work).joined(separator: " and "))") }
                h += "<dt>Drills</dt><dd>\(what.joined(separator: ", then ").prefix(1).uppercased() + what.joined(separator: ", then ").dropFirst()), "
                    + "\(len(reg.depth)) deep, before it cuts.</dd>\n"
            }
        }
        let core = tile.core
        h += "<dt>Cuts</dt><dd>Its share of the material, X \(len(core.min.x)) to \(len(core.max.x)), Y \(len(core.min.y)) to \(len(core.max.y)) "
            + "from the material's lower-left corner, and up to \(len(layout.overlap)) past its tile lines.</dd>\n"
        if let ext = extents(tps) {
            let lo = tileStock.toWork(ext.min - Vec3(tile.offset, 0)), hi = tileStock.toWork(ext.max - Vec3(tile.offset, 0))
            h += "<dt>Cutting extents</dt><dd>X \(len(lo.x)) to \(len(hi.x)), Y \(len(lo.y)) to \(len(hi.y)), Z \(len(lo.z)) to \(len(hi.z)) "
                + "(work coordinates)</dd>\n"
        }
        let seconds = tps.reduce(0.0) { $0 + (job.estimatedSeconds(toolpath: $1.id) ?? $1.estimatedSeconds(rapidRate: project.machine.rapidRateForEstimates)) }
        h += "<dt>Run time</dt><dd>About \(time(seconds))</dd>\n</dl>\n"
        h += "<table><tr><th>#</th><th>Toolpath</th><th>Tool</th><th class=\"num\">Time</th></tr>\n"
        for (i, tp) in tps.enumerated() {
            let t = job.estimatedSeconds(toolpath: tp.id).map(time) ?? "–"
            h += "<tr><td>\(i + 1)</td><td>\(esc(tp.name))</td><td>T\(tp.tool.number) \(esc(tp.tool.name))</td><td class=\"num\">\(t)</td></tr>\n"
        }
        h += "</table>\n"
        h += preview(project: project, tiled: tiled, tile: tile)
        h += "</section>\n"
        return h
    }

    /// "1", "1 and 2", "1, 2 and 5".
    static func numberList(_ numbers: [Int]) -> String {
        let s = numbers.map(String.init)
        return s.count < 2 ? s.joined() : s.dropLast().joined(separator: ", ") + " and " + s[s.count - 1]
    }

    /// Individual tiles with registration holes: the job-wide row about the stop at the start of each tile's file
    /// (`TileSplitter.pinMessage`), which an imported Vectric post doesn't write. Empty for other tiling.
    static func gridDowelStopRow(_ layout: TileLayout, machine: MachineProfile) -> String {
        guard layout.mode == .grid, let reg = layout.registration, !reg.holes.isEmpty else { return "" }
        if machine.customPost != nil {
            return "<dt>Dowels</dt><dd>This machine's imported Vectric post doesn't write the stop NativeCAM's own posts make "
                + "at the start of each tile's file to name the holes its dowels go in: fit the dowels before starting each tile.</dd>"
        }
        return "<dt>Dowels</dt><dd>Each tile's file but the first stops at its start, spindle off, to name the holes its "
            + "dowels go in. Imported Vectric (.pp) posts don't write that stop: with one, fit the dowels before starting each tile.</dd>"
    }

    /// Individual tiles: the numbered holes a tile stands on dowels through, and the ones it drills. The dowel wording
    /// follows the file's stop (`TileSplitter.pinMessage`): fit the dowels, clamp, then resume; with an imported Vectric
    /// post, which writes no stop, before starting.
    static func gridRegistration(_ reg: RegistrationLayout, tile k: Int, layout: TileLayout, machine: MachineProfile,
                                 work: (Vec2) -> String, len: (Double) -> String) -> String {
        var h = ""
        let tile = layout.tiles[k]
        let pinned = reg.holes.filter { $0.pinnedFor == k }
        if !pinned.isEmpty {
            // Grouped by the tile that drilled them.
            let groups = Dictionary(grouping: pinned, by: \.drilledBy).sorted { $0.key < $1.key }
            let which = groups.map { "\(numberList($0.value.map(\.number))) (tile \($0.key + 1) drilled \($0.value.count == 1 ? "it" : "them"))" }
            let at = pinned.map { "\($0.number) at \(work($0.point - tile.offset))" }
            let dowel = "fit a \(len(2 * reg.radius)) dowel in each, through into the spoilboard hole under it"
            let steps = machine.customPost != nil
                ? "Before starting the file, \(dowel), then clamp the material. (This machine's imported Vectric post doesn't "
                    + "write the stop that names them.)"
                : "Start the file: it stops at its start, spindle off, and names them. At the stop, \(dowel), clamp the "
                    + "material, then resume."
            h += "<dt>Dowels</dt><dd>Line holes \(which.joined(separator: " and ")) up over the spoilboard holes: "
                + "\(at.joined(separator: ", ")). \(steps)</dd>\n"
        }
        let own = reg.numbered(drilledBy: k)
        var what: [String] = []
        if k == 0, !reg.spoilboard.isEmpty {
            what.append("the spoilboard holes in front of the material at \(reg.spoilboard.map(work).joined(separator: ", "))")
        }
        for (next, holes) in Dictionary(grouping: own, by: \.pinnedFor).sorted(by: { $0.key < $1.key }) {
            what.append("holes \(numberList(holes.map(\.number))) for tile \(next + 1)'s dowels at "
                + holes.map { work($0.point - tile.offset) }.joined(separator: " and "))
        }
        if !what.isEmpty {
            let text = what.joined(separator: ", then ")
            h += "<dt>Drills</dt><dd>\(esc(text.prefix(1).uppercased() + text.dropFirst())), \(len(reg.depth)) deep, before it cuts.</dd>\n"
        }
        return h
    }

    /// The whole material from above, with this tile's share and cuts picked out, the overlap bands, the dowels and the
    /// holes it drills, and its XY zero.
    static func preview(project: Project, tiled: TiledJob, tile: TileLayout.Tile) -> String {
        let layout = tiled.layout, stock = project.stock
        let o = layout.overlap
        let pad = max(stock.width, stock.height) * 0.03
        var lo = Vec2(min(0, tile.frame.min.x) - pad, min(0, tile.frame.min.y) - pad)
        var hi = Vec2(max(stock.width, tile.frame.max.x) + pad, max(stock.height, tile.frame.max.y) + pad)
        if let reg = layout.registration {
            for p in reg.spoilboard.map({ $0 + layout.tiles[0].offset }) {
                lo = Vec2(min(lo.x, p.x - pad), min(lo.y, p.y - pad))
                hi = Vec2(max(hi.x, p.x + pad), max(hi.y, p.y + pad))
            }
        }
        let size = hi - lo
        let stroke = max(size.x, size.y) / 500
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        // SVG's Y runs down: flip it so the material's lower-left is at the bottom left.
        func y(_ v: Double) -> Double { hi.y - v + lo.y }
        func rect(_ r: Rect2, _ style: String) -> String {
            "<rect x=\"\(n(r.min.x))\" y=\"\(n(y(r.max.y)))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" \(style)/>"
        }
        var s = "<svg class=\"preview\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(lo.x)) \(n(lo.y)) \(n(size.x)) \(n(size.y))\">\n"
        s += rect(stock.bounds, "fill=\"#f1ebdd\" stroke=\"#8a7f6a\" stroke-width=\"\(n(stroke))\"") + "\n"
        s += rect(tile.core, "fill=\"#d6e6ff\" stroke=\"#1e66d0\" stroke-width=\"\(n(stroke * 1.5))\"") + "\n"
        for x in layout.seamsX {
            s += rect(Rect2(min: Vec2(x - o, 0), max: Vec2(x + o, stock.height)), "fill=\"#ff3b30\" fill-opacity=\"0.18\"") + "\n"
        }
        for v in layout.seamsY {
            s += rect(Rect2(min: Vec2(0, v - o), max: Vec2(stock.width, v + o)), "fill=\"#ff3b30\" fill-opacity=\"0.18\"") + "\n"
        }
        func path(_ tps: [Toolpath], step: Double, _ style: String) -> String {
            var d = ""
            for tp in tps {
                var last: Vec2?
                tp.forEachMotion { start, m in
                    guard m.kind != .dwell else { return }
                    if m.kind == .rapid || m.end.z >= 0 { last = nil; return }
                    if last == nil { d += "M\(n(start.xy.x)) \(n(y(start.xy.y)))"; last = start.xy }
                    for q in m.samples(from: start, maxStep: step) where q.xy.distance(to: last!) >= step {
                        d += "L\(n(q.x)) \(n(y(q.y)))"
                        last = q.xy
                    }
                }
            }
            return d.isEmpty ? "" : "<path d=\"\(d)\" fill=\"none\" \(style)/>\n"
        }
        let step = max(1.0, max(size.x, size.y) / 800)
        let others = tiled.tiles.enumerated().filter { $0.offset != tile.index }.flatMap(\.element)
        s += path(others, step: step * 2, "stroke=\"#9a9a9a\" stroke-width=\"\(n(stroke))\"")
        s += path(tiled.tiles[tile.index], step: step, "stroke=\"#0b4fb3\" stroke-width=\"\(n(stroke * 1.5))\"")
        for x in layout.seamsX {
            s += "<line x1=\"\(n(x))\" y1=\"\(n(y(0)))\" x2=\"\(n(x))\" y2=\"\(n(y(stock.height)))\" stroke=\"#d4a000\" stroke-width=\"\(n(stroke * 1.5))\"/>\n"
        }
        for v in layout.seamsY {
            s += "<line x1=\"0\" y1=\"\(n(y(v)))\" x2=\"\(n(stock.width))\" y2=\"\(n(y(v)))\" stroke=\"#d4a000\" stroke-width=\"\(n(stroke * 1.5))\"/>\n"
        }
        if let reg = layout.registration {
            let r = max(reg.radius, stroke * 3)
            for p in reg.dowels[tile.index].map({ $0 + tile.offset }) {
                s += "<circle cx=\"\(n(p.x))\" cy=\"\(n(y(p.y)))\" r=\"\(n(r))\" fill=\"#222\"/>\n"
            }
            for p in reg.drilled[tile.index].map({ $0 + tile.offset }) {
                s += "<circle cx=\"\(n(p.x))\" cy=\"\(n(y(p.y)))\" r=\"\(n(r))\" fill=\"none\" stroke=\"#c0392b\" stroke-width=\"\(n(stroke * 1.5))\"/>\n"
            }
            // Individual tiles: the numbers of the holes this tile stands on or drills, as the page names them.
            let size = max(size.x, size.y) / 45
            for hole in reg.holes where hole.drilledBy == tile.index || hole.pinnedFor == tile.index {
                s += "<text x=\"\(n(hole.point.x + 1.5 * r))\" y=\"\(n(y(hole.point.y) - 1.5 * r))\" font-size=\"\(n(size))\" "
                    + "font-family=\"sans-serif\" fill=\"#222\">\(hole.number)</text>\n"
            }
        }
        // The XY zero: where the tile's frame puts the stock's origin.
        let zero = layout.tileStock(stock).originPoint + tile.offset
        let arm = max(size.x, size.y) / 60
        s += "<path d=\"M\(n(zero.x - arm)) \(n(y(zero.y)))L\(n(zero.x + arm)) \(n(y(zero.y)))M\(n(zero.x)) \(n(y(zero.y - arm)))L\(n(zero.x)) \(n(y(zero.y + arm)))\" stroke=\"#000\" stroke-width=\"\(n(stroke * 2))\"/>\n"
        s += "</svg>\n"
        return s
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func extents(_ toolpaths: [Toolpath]) -> Toolpath.Extents? {
        let all = toolpaths.compactMap(\.cuttingExtents)
        guard let f = all.first else { return nil }
        return all.dropFirst().reduce(f) {
            Toolpath.Extents(min: Vec3(min($0.min.x, $1.min.x), min($0.min.y, $1.min.y), min($0.min.z, $1.min.z)),
                             max: Vec3(max($0.max.x, $1.max.x), max($0.max.y, $1.max.y), max($0.max.z, $1.max.z)))
        }
    }
}
