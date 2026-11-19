import Foundation

/// A printable page for whoever runs the job: material and zero, the tools in the order they go in, each
/// toolpath with its run time, clamps to keep clear of, and the checks that are still open.
public enum SetupSheet {
    public static func html(project: Project, job: JobResult, gcodeFile: String? = nil, checks: [GCodeCheck.Issue] = [],
                            date: Date = Date()) -> String {
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
            setupRows = """
            <dt>Material</dt><dd>\(esc(stock.materialName)) rotary blank: \(shape), \(len(blank.length)) long</dd>
            <dt>XY zero</dt><dd>X at the \(RotaryOutput.xZero(stock)), Y on the rotation axis centreline</dd>
            <dt>Z zero</dt><dd class="error">On the rotation axis\(avid ? " (Avid: Rotary tab ▸ Z Axis Touch)" : ""), not the top of the blank</dd>
            <dt>Rotary</dt><dd>Turns on \(esc(machine.rotary?.letter.rawValue ?? "A")) between faces, with the tool at safe Z. Raise the tool clear of the chuck and tailstock before starting.</dd>
            <dt>Safe Z</dt><dd>\(len(stock.clearanceHeight)) above the top face (\(len(blank.radius + stock.clearanceHeight)) from the axis)</dd>
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
        let angleColumn = stock.rotary != nil

        var h = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>\(esc(project.name)) setup sheet</title>
        <style>
        body { font: 13px/1.4 -apple-system, "Helvetica Neue", sans-serif; color: #111; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 2px; } h2 { font-size: 15px; margin: 22px 0 6px; }
        .sub { color: #555; margin-bottom: 14px; }
        table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
        th { font-weight: 600; background: #f4f4f4; } td.num { text-align: right; font-variant-numeric: tabular-nums; }
        dl { display: grid; grid-template-columns: max-content 1fr; gap: 3px 16px; margin: 0; } dt { color: #555; } dd { margin: 0; }
        .change td { background: #fff7e0; } .error { color: #b00020; } .warning { color: #8a5a00; }
        @media print { body { margin: 0; } h2 { break-after: avoid; } tr { break-inside: avoid; } }
        </style></head><body>
        <h1>\(esc(project.name))</h1>
        <div class="sub">Setup sheet · \(esc(df.string(from: date)))\(gcodeFile.map { " · " + esc($0) } ?? "")</div>

        <h2>Job</h2>
        <dl>
        <dt>Machine</dt><dd>\(esc(machine.displayName)), \(esc(machine.controllerLabel)), \(esc(machine.spindle.label)), \(esc(machine.toolChange.label))</dd>
        \(setupRows)
        <dt>G-code units</dt><dd>\(machine.outputUnits == .inch ? "Inches (G20)" : "Millimetres (G21)")</dd>
        <dt>Run time</dt><dd>About \(time(job.estimatedSeconds))</dd>

        """
        if let ext = extents(job.toolpaths) {
            let lo = stock.toWork(ext.min), hi = stock.toWork(ext.max)
            h += "<dt>Cutting extents</dt><dd>X \(len(lo.x)) to \(len(hi.x)), Y \(len(lo.y)) to \(len(hi.y)), "
                + "Z \(len(lo.z)) to \(len(hi.z)) (work coordinates)</dd>\n"
        }
        h += "</dl>\n"

        // Tools in the order they go into the spindle.
        var order: [Tool] = []
        for tp in job.toolpaths where !tp.isEmpty && order.last?.number != tp.tool.number { order.append(tp.tool) }
        h += "<h2>Tools</h2>\n<table><tr><th>#</th><th>Tool</th><th>Type</th><th class=\"num\">Diameter</th><th class=\"num\">Cutting length</th><th class=\"num\">Stick-out</th></tr>\n"
        for (i, t) in order.enumerated() {
            var type = t.shape.label
            if t.shape.usesAngle { type += " \(Int(t.includedAngle.rounded()))°" }
            h += "<tr><td>\(i + 1)</td><td>T\(t.number) \(esc(t.name))</td><td>\(esc(type))</td><td class=\"num\">\(len(t.diameter))</td>"
                + "<td class=\"num\">\(len(t.fluteLength))</td><td class=\"num\">\(len(t.stickout))</td></tr>\n"
        }
        h += "</table>\n"

        h += "<h2>Run order</h2>\n<table><tr><th>#</th><th>Toolpath</th><th>Tool</th>\(angleColumn ? "<th class=\"num\">Angle</th>" : "")<th class=\"num\">RPM</th><th class=\"num\">Feed</th><th class=\"num\">Depth</th><th class=\"num\">Time</th></tr>\n"
        var current: Int?
        var step = 0
        for tp in job.toolpaths where !tp.isEmpty {
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
            step += 1
            let rpm = machine.spindle == .vfdSpindle ? machine.clampRPM(tp.spindleRPM) : tp.spindleRPM
            let maxFeed = tp.motions.filter { $0.kind == .feed || $0.kind.isArc }.map(\.feed).max() ?? 0
            let depth = tp.cuttingExtents.map { -$0.min.z } ?? 0
            let seconds = job.estimatedSeconds(toolpath: tp.id).map(time) ?? "–"
            let angle = angleColumn ? "<td class=\"num\">\(tp.indexAngle.map { esc(RotaryIndex.label($0)) } ?? "–")</td>" : ""
            h += "<tr><td>\(step)</td><td>\(esc(tp.name))</td><td>T\(tp.tool.number)</td>\(angle)<td class=\"num\">\(Int(rpm.rounded()))\(machine.spindle == .router ? " (dial)" : "")</td>"
                + "<td class=\"num\">\(feed(maxFeed))</td><td class=\"num\">\(len(max(0, depth)))</td><td class=\"num\">\(seconds)</td></tr>\n"
        }
        h += "</table>\n"

        let clamps = project.shapes.filter(\.isKeepOut)
        if !clamps.isEmpty {
            h += "<h2>Clamps and keep-out areas</h2>\n<ul>\n"
            for c in clamps {
                h += "<li>\(esc(c.name)): \(len(c.keepOutHeight ?? 0)) tall, near X \(len(stock.toWork(Vec3(c.position, 0)).x)), Y \(len(stock.toWork(Vec3(c.position, 0)).y))</li>\n"
            }
            h += "</ul>\n"
        }

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
        h += "</body></html>\n"
        return h
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
