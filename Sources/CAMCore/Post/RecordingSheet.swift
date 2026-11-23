import Foundation

/// The printable page saved beside each calibration program (`Calibration`): how to set up, then a row for each
/// timed section with NativeCAM's estimate and a blank column for the stopwatch's time (on the ladder, for what each
/// rung's cut looked and sounded like).
public enum RecordingSheet {
    public static func html(_ program: Calibration.Program, date: Date = Date()) -> String {
        let p = program.project, m = p.machine, u = p.displayUnits
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        func esc(_ s: String) -> String { SetupSheet.esc(s) }
        func time(_ s: Double) -> String {
            let t = Int(s.rounded())
            return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t) s"
        }
        var h = SetupSheet.head(program.kind.label).replacingOccurrences(of: " setup sheet</title>", with: " recording sheet</title>")
        h += """
        <style>td.blank { min-width: 110px; border-bottom: 1px solid #999; } .note { color: #555; } ol li { margin-bottom: 3px; }</style>
        <h1>\(esc(p.name))</h1>
        <div class="sub">Recording sheet · \(esc(df.string(from: date))) · \(esc(program.fileName))</div>
        <dl>
        <dt>Machine</dt><dd>\(esc(m.displayName)), \(esc(program.dialect.name))</dd>

        """
        if let window = program.window {
            h += "<dt>Window</dt><dd>\(esc(Calibration.size(window, u))) from the XY zero at its front-left corner</dd>\n"
        }
        if let plan = program.plan {
            h += "<dt>Heights</dt><dd>At least \(esc(Calibration.length(plan.airHeight, u))) above Z zero, up to \(esc(Calibration.length(plan.topZ, u)))</dd>\n"
        }
        h += "<dt>Moves</dt><dd>About \(time(program.estimatedSeconds))\(program.kind == .ladder ? "" : ", plus the stops")</dd>\n</dl>\n"
        h += "<h2>Before you start</h2>\n<ol>\n" + program.setup.map { "<li>\(esc($0))</li>" }.joined(separator: "\n") + "\n</ol>\n"

        switch program.kind {
        case .timing, .rotary:
            h += """
            <h2>Times</h2>
            <p class="note">\(esc(Calibration.timingInstruction)) A stopwatch is good to about a quarter of a second, a few percent of each section.</p>
            <table><tr><th>#</th><th>Section</th><th>What it measures</th><th class="num">Repeats</th><th class="num">NativeCAM's estimate</th><th>Measured (s)</th></tr>

            """
            for (i, s) in program.sections.enumerated() {
                let estimate = s.id == "rotary-g93" ? "\(Calibration.number(Calibration.rotaryExpectedSeconds)) s expected" : String(format: "%.1f s", s.estimate)
                h += "<tr><td>\(i + 1)</td><td>\(esc(s.name))</td><td>\(esc(s.measures))</td><td class=\"num\">\(s.count)</td>"
                    + "<td class=\"num\">\(esc(estimate))</td><td class=\"blank\"></td></tr>\n"
            }
            h += "</table>\n"
            if program.kind == .timing {
                h += """
                <h2>The F-change line</h2>
                <p>The last two sections cut the same pieces of line, the first at one feed and the second alternating between two feeds \
                that take the same time. If the controller keeps constant velocity through a change of F, the two take the same time \
                (within \(Int(100 * Calibration.fChangeTolerance))%); if it slows at each change, the second takes longer. \
                That decides whether “Adjust feeds for load” is safe to turn on.</p>

                """
            } else {
                h += """
                <h2>Inverse time</h2>
                <p>The first turn is written as <code>G93 G1 \(esc(program.axisLetter ?? "A"))360 F\(Int(Calibration.rotaryInverseTime))</code>: \
                in inverse time, F\(Int(Calibration.rotaryInverseTime)) means the move takes a tenth of a minute, whatever its length. \
                If it takes \(Int(Calibration.rotaryExpectedSeconds)) s, wrapped rotary jobs are fed as NativeCAM means them to be.</p>

                """
            }
            h += """
            <h2>Then</h2>
            <p>Enter the times in <b>File ▸ Calibration Programs…</b> (Enter Times), or write them in the measured_s column of \
            <code>\(esc(program.kind.fileStem))-times.csv</code> and run <code>nativecam-cli calibrate fit \(esc(program.kind.fileStem))-times.csv \
            project.nativecam</code>. NativeCAM shows each value before and after; nothing changes until you click Apply.</p>

            """
        case .ladder:
            h += """
            <h2>Rungs</h2>
            <p class="note">Rung 1 is on the left. Feeds and chip loads are as written in the file; the chart's range is \
            \(esc(chartRange(program))).</p>
            <table><tr><th>Rung</th><th class="num">X</th><th class="num">Feed</th><th class="num">Speed</th><th class="num">Chip load</th>\
            <th>Chart</th><th>Finish</th><th>Sound</th><th>Chips</th></tr>

            """
            for r in program.rungs {
                let chart = r.chart.label + (r.recommended ? " (nearest the recommendation)" : "")
                h += "<tr><td>\(r.number)\(program.rungs.contains { $0.row > 1 } ? " (row \(r.row))" : "")</td>"
                    + "<td class=\"num\">\(esc(u.format(r.x, decimals: u == .inch ? 3 : 1)))</td>"
                    + "<td class=\"num\">\(esc(Calibration.feed(r.feed, u)))</td><td class=\"num\">\(Int(r.rpm)) RPM</td>"
                    + "<td class=\"num\">\(esc(Calibration.chipText(r.chipLoad, u)))</td><td>\(esc(chart))</td>"
                    + "<td class=\"blank\"></td><td class=\"blank\"></td><td class=\"blank\"></td></tr>\n"
            }
            h += """
            </table>
            <h2>Reading it</h2>
            <p>Too thin a chip rubs: dust instead of chips, heat, burn marks and a high whine. Too thick a chip tears the edge and \
            the machine labours. The best rung cuts cleanly with chips, not dust, and sounds steady. NativeCAM's chart stays as it \
            is: use what you find in the tool's own feeds and speeds.</p>

            """
        }
        if !program.issues.isEmpty {
            h += "<h2>Checks</h2>\n<ul>\n" + program.issues.map {
                "<li class=\"\($0.severity == .error ? "error" : "warning")\">\(esc($0.text))</li>"
            }.joined(separator: "\n") + "\n</ul>\n"
        }
        return h + "</body></html>\n"
    }

    private static func chartRange(_ program: Calibration.Program) -> String {
        guard let tool = program.toolpaths.first?.tool, let kind = program.project.stock.materialKind else { return "not known" }
        let depth = program.toolpaths.first.flatMap { tp in tp.motions.map(\.end.z).min().map { -$0 } }
        let reading = ChipLoad.reading(tool, material: kind, depth: depth)
        let u = program.project.displayUnits
        return "\(Calibration.chipText(reading.range.lowerBound, u)) to \(Calibration.chipText(reading.range.upperBound, u)) (\(reading.source(u)))"
    }
}
