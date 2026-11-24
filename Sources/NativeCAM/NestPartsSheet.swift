import CAMCore
import Foundation
import Observation
import SwiftUI

/// Toolpaths ▸ Nest Parts…: finds the parts, searches for a layout in the background (the best so far shows as it
/// improves), and moves them on Apply.
@MainActor
@Observable
final class NestSession {
    enum Phase: Equatable {
        case preparing
        case refused(String)
        case ready
    }

    let project: Project
    let selection: Set<UUID>
    private(set) var phase: Phase = .preparing
    private(set) var job: NestJob?
    /// Every vector of each part to nest and of each part that stays put (design coordinates, where they are now),
    /// for drawing.
    private(set) var partLines: [[Polyline]] = []
    private(set) var fixedLines: [[Polyline]] = []
    private(set) var result: Nesting.Result?
    private(set) var searching = false
    private(set) var searchStarted = Date()
    var settings: Nesting.Settings {
        didSet {
            guard settings != oldValue, phase == .ready else { return }
            if remembersSettings { NestSession.remember(settings) }
            restart()
        }
    }
    /// Off in snapshot checks, so they don't change the turns, grain and search time the user last chose.
    @ObservationIgnored var remembersSettings = true
    /// How many times the layout shown has changed (snapshot checks look for the search's progress).
    @ObservationIgnored private(set) var updates = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stop = StopFlag()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resultGeneration = -1

    init(project: Project, selection: Set<UUID>) {
        self.project = project
        self.selection = selection
        settings = Nesting.Settings(spacing: 0, edgeMargin: 0)
    }

    /// Generates the job's toolpaths (for how far each one cuts outside its shapes), finds the parts and starts the
    /// search.
    func start() {
        let p = project, sel = selection
        task = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<NestJob, NestJob.Refusal> in
                do throws(NestJob.Refusal) {
                    return .success(try NestJob.prepare(p, selection: sel))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case let .success(job): ready(job)
            case let .failure(refusal): phase = .refused(refusal.localizedDescription)
            }
        }
    }

    /// For snapshot checks: prepares and nests synchronously, with a fixed number of layouts (and sheets, when given).
    func runNow(evaluations: Int, sheets: Int? = nil) {
        do {
            let job = try NestJob.prepare(project, selection: selection)
            self.job = job
            draw(job)
            var s = Self.recalled(job.defaultSettings)
            s.maxEvaluations = evaluations
            if let sheets { s.maxSheets = sheets }
            settings = s
            phase = .ready
            result = job.nest(s)
        } catch {
            phase = .refused(error.localizedDescription)
        }
    }

    private func ready(_ job: NestJob) {
        self.job = job
        draw(job)
        settings = Self.recalled(job.defaultSettings)
        phase = .ready
        restart()
    }

    private func draw(_ job: NestJob) {
        func lines(_ part: NestJob.Part) -> [Polyline] {
            part.pieces.flatMap { piece -> [Polyline] in
                guard let shape = project.shape(id: piece.shapeID) else { return [] }
                let all = shape.polylines(tolerance: 0.1)
                guard let paths = piece.paths else { return all }
                return paths.filter { $0 < all.count }.map { all[$0] }
            }
        }
        partLines = job.parts.map(lines)
        fixedLines = job.fixed.map(lines)
    }

    /// Starts the search again with the current settings, a moment after the last change.
    private func restart() {
        guard let job else { return }
        stop.set()
        let flag = StopFlag()
        stop = flag
        generation += 1
        let mine = generation
        let s = settings
        task?.cancel()
        searching = true
        searchStarted = Date()
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searchStarted = Date()
            let me = self
            let final = await Task.detached(priority: .userInitiated) {
                job.nest(s, progress: { r in
                    Task { @MainActor in me.update(r, generation: mine) }
                }, shouldStop: { flag.isSet })
            }.value
            update(final, generation: mine)
            if mine == generation { searching = false }
        }
    }

    /// The best layout of the latest search (an earlier search's stays up until the new one has one).
    private func update(_ r: Nesting.Result, generation g: Int) {
        guard g == generation else { return }
        if resultGeneration == g, let current = result, current.evaluations > r.evaluations { return }
        result = r
        resultGeneration = g
        updates += 1
    }

    /// Ends the search, keeping the best layout found.
    func finish() { stop.set() }

    func cancel() {
        stop.set()
        task?.cancel()
    }

    /// The project with the parts moved where the current layout puts them, once the layout passes the check with the
    /// parts' exact outlines; otherwise why not.
    func applied() -> Result<NestJob.Applied, NestCheckFailure>? {
        guard let job, let result else { return nil }
        let problems = job.check(result, settings: settings)
        guard problems.isEmpty else { return .failure(NestCheckFailure(problems: problems)) }
        return .success(job.apply(result, to: project, settings: settings))
    }

    // MARK: Remembered settings

    /// The turns, grain, search time, sheet limit and part in part last used (spacing and margin follow each job's
    /// cut-out bit, and the other sheets' size the job's).
    static func recalled(_ base: Nesting.Settings) -> Nesting.Settings {
        var s = base
        let d = UserDefaults.standard
        let sheets = d.integer(forKey: "NestSheets")
        s.maxSheets = max(base.maxSheets, sheets > 0 ? sheets : defaultSheetLimit)
        s.partInPart = d.object(forKey: "NestPartInPart") as? Bool ?? true
        switch d.integer(forKey: "NestTurnSteps") {
        case 0, 4: s.rotation = .quarterTurns
        case 1: s.rotation = .none
        case let n: s.rotation = .steps(n)
        }
        s.keepGrain = d.bool(forKey: "NestKeepGrain")
        let seconds = d.double(forKey: "NestSeconds")
        s.timeLimit = seconds > 0 ? seconds : 5
        return s
    }

    static func remember(_ s: Nesting.Settings) {
        let d = UserDefaults.standard
        switch s.rotation {
        case .none: d.set(1, forKey: "NestTurnSteps")
        case .quarterTurns: d.set(4, forKey: "NestTurnSteps")
        case let .steps(n): d.set(n, forKey: "NestTurnSteps")
        }
        d.set(s.keepGrain, forKey: "NestKeepGrain")
        d.set(s.timeLimit, forKey: "NestSeconds")
        d.set(s.maxSheets, forKey: "NestSheets")
        d.set(s.partInPart, forKey: "NestPartInPart")
    }

    /// Sheets parts may go on until the user sets a limit.
    static let defaultSheetLimit = NestJob.defaultSheetLimit
}

/// A layout that didn't pass the final check (it never should): nothing is moved.
struct NestCheckFailure: Error {
    var problems: [String]
}

/// Set from the main thread, read by the search between generations.
final class StopFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

struct NestPartsSheet: View {
    @State private var session: NestSession
    let onApply: (Result<NestJob.Applied, NestCheckFailure>) -> Void
    var height: CGFloat = 640
    /// Snapshot checks draw a finished search: no live search, no timer.
    var isStatic = false
    @Environment(\.dismiss) private var dismiss

    init(session: NestSession, height: CGFloat = 640, isStatic: Bool = false,
         onApply: @escaping (Result<NestJob.Applied, NestCheckFailure>) -> Void) {
        _session = State(initialValue: session)
        self.height = height
        self.isStatic = isStatic
        self.onApply = onApply
    }

    private var units: LengthUnit { session.project.displayUnits }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch session.phase {
            case .preparing:
                ProgressView("Finding the parts…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .refused(message):
                ContentUnavailableView("Can't Nest These Parts", systemImage: "square.dashed", description: Text(message))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                HStack(alignment: .top, spacing: 0) {
                    settingsForm.frame(width: 320)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        NestPreview(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        summary
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(width: 940, height: height)
        .onAppear { if !isStatic && session.phase == .preparing { session.start() } }
        .onDisappear { session.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nest Parts").font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        let stock = session.project.stock
        let size = "\(length(stock.width)) × \(length(stock.height)) \(units.symbol)"
        guard let job = session.job else { return "Arranges the parts on the \(size) sheet to use as little of it as it can." }
        let which = session.selection.isEmpty ? "every part" : "the selected \(job.parts.count == 1 ? "part" : "parts")"
        let more = session.settings.sheetLimit > 1 ? ", then on more sheets," : ","
        return "Arranges \(which) (\(job.parts.count)) on the \(size) sheet\(more) packed toward the \(alongX ? "left" : "bottom") edge so what's left is one piece."
    }

    private var alongX: Bool { session.result?.alongX ?? (session.project.stock.width >= session.project.stock.height) }

    // MARK: Settings

    private var settingsForm: some View {
        Form {
            Section {
                LengthField(title: "Spacing", mm: $session.settings.spacing, units: units,
                            help: "Least gap between parts, and between a part and a clamp or a part that stays put", minimum: 0)
                LengthField(title: "Edge margin", mm: $session.settings.edgeMargin, units: units,
                            help: "Least gap between a part and the sheet's edge", minimum: 0)
            } header: {
                Text("Gaps")
            } footer: {
                Text(spacingNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Stepper(value: Binding(get: { session.settings.sheetLimit }, set: { session.settings.maxSheets = max(1, min(50, $0)) }),
                        in: 1...50) {
                    LabeledContent("Sheets", value: session.settings.sheetLimit == 1 ? "1 only" : "Up to \(session.settings.sheetLimit)")
                }
                .help("Parts that don't fit on a sheet go on the next, up to this many")
                if session.settings.sheetLimit > 1 {
                    Picker("Next sheets", selection: sameSize) {
                        Text("Same size").tag(true)
                        Text("Another size").tag(false)
                    }
                    if let size = session.settings.nextSheetSize {
                        LengthField(title: "Width", mm: Binding(get: { size.x }, set: { session.settings.nextSheetSize = Vec2($0, size.y) }),
                                    units: units, help: "Width of every sheet after the first", minimum: 1)
                        LengthField(title: "Height", mm: Binding(get: { size.y }, set: { session.settings.nextSheetSize = Vec2(size.x, $0) }),
                                    units: units, help: "Height of every sheet after the first", minimum: 1)
                    }
                }
                Toggle("Put small parts in holes", isOn: $session.settings.partInPart)
                    .help("A part may go in another part's hole, with the spacing all round, when the hole is cut right through and the part is cut out before it")
            } header: {
                Text("Sheets and holes")
            } footer: {
                Text(holesNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Turning parts") {
                Picker("Turns", selection: turnsChoice) {
                    Text("Keep as drawn").tag(0)
                    Text("90° steps").tag(4)
                    Text("Finer steps").tag(-1)
                }
                if case let .steps(n) = session.settings.rotation {
                    Stepper(value: Binding(get: { n }, set: { session.settings.rotation = .steps(max(2, min(72, $0))) }), in: 2...72) {
                        LabeledContent("Steps", value: "\(n) (\(formatted(360 / Double(n)))° apart)")
                    }
                }
                Toggle("Keep the grain direction", isOn: $session.settings.keepGrain)
                    .disabled(session.settings.rotation == .none)
                    .help("Only turn parts end for end (0° or 180°), so the grain runs the way they're drawn")
            }
            Section {
                Picker("Search for", selection: $session.settings.timeLimit) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
            } header: {
                Text("Search")
            } footer: {
                Text("Tries other orders and turns, keeping the best layout. Changing a setting starts again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Whether the sheets after the first are the first's size.
    private var sameSize: Binding<Bool> {
        Binding(get: { session.settings.nextSheetSize == nil }, set: { same in
            let stock = session.project.stock
            session.settings.nextSheetSize = same ? nil : (session.job?.nextSheetSize ?? Vec2(stock.width, stock.height))
        })
    }

    private var holesNote: String {
        guard let job = session.job else { return "" }
        let n = job.partsWithHoles, closed = job.partsWithClosedHoles
        if !session.settings.partInPart { return "Parts stay out of other parts' holes." }
        var note = n == 0 ? "No part has a hole other parts can go in."
            : "\(n == 1 ? "1 part has a hole" : "\(n) parts have holes") other parts can go in: each is cut out before the hole "
                + "it sits in, and keeps the spacing (or the hole's own cut) from its edge."
        if let first = closed.first {
            // One hole: "The hole in “Top” is…"; otherwise they.
            let one = closed.count == 1 && first.holes.count == 1
            let who = closed.count > 1 ? "\(closed.count) parts' holes are"
                : one ? "The hole in “\(first.name)” is" : "The holes in “\(first.name)” are"
            note += " \(who) cut free before the other parts are cut out, so \(one ? "it stays" : "they stay") empty: "
                + "cut those parts earlier, or in the same profile, to use \(one ? "it" : "them")."
        }
        return note
    }

    /// 0 keep as drawn, 4 quarter turns, -1 finer steps.
    private var turnsChoice: Binding<Int> {
        Binding(get: {
            switch session.settings.rotation {
            case .none: 0
            case .quarterTurns: 4
            case .steps: -1
            }
        }, set: { choice in
            switch choice {
            case 0: session.settings.rotation = .none
            case 4: session.settings.rotation = .quarterTurns
            default: session.settings.rotation = .steps(8)
            }
        })
    }

    private var spacingNote: String {
        guard let job = session.job else { return "" }
        let margin = length(NestJob.spacingMargin(units))
        var note = job.cutOutTool.map { "Starts at the \($0.name)'s diameter plus \(margin) \(units.symbol)." }
            ?? "No toolpath cuts these parts out yet: starts at a 1/4\" bit's diameter plus \(margin) \(units.symbol)."
        let wider = job.parts.filter { $0.reach > session.settings.spacing + 1e-6 }
        if let widest = wider.max(by: { $0.reach < $1.reach }) {
            note += " “\(widest.reachToolpath ?? "A toolpath")” cuts \(length(widest.reach)) \(units.symbol) outside "
                + (wider.count == 1 ? "“\(widest.name)”" : "\(wider.count) parts") + ", so they keep that far from the others."
        }
        let leads = job.parts.filter { ($0.leadReach ?? 0) > max(session.settings.spacing, $0.reach) + 1e-6 }
        if let longest = leads.max(by: { ($0.leadReach ?? 0) < ($1.leadReach ?? 0) }) {
            note += " Lead-ins on “\(longest.leadToolpath ?? "a profile")” reach \(length(longest.leadReach ?? 0)) \(units.symbol): "
                + "nearer another part they're shortened or left off, and Checks lists any left off."
        }
        return note
    }

    private func formatted(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }

    /// A length in the job's units, without trailing zeros: 48, 31.05, 0.375 (in) or 1219, 9.4 (mm).
    private func length(_ mm: Double) -> String {
        units.fromMM(mm).formatted(.number.precision(.fractionLength(0...(units == .inch ? 3 : 1))).grouping(.never))
    }

    /// A measured length, roughly: 31.4 in, 797 mm.
    private func rough(_ mm: Double) -> String {
        units.fromMM(mm).formatted(.number.precision(.fractionLength(0...(units == .inch ? 1 : 0))).grouping(.never))
    }

    // MARK: Results

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let r = session.result, let job = session.job {
                let placed = r.placedCount
                let sheets = r.sheetCount > 1 ? " on \(r.sheetCount) sheets" : ""
                let holes = r.inHoles.isEmpty ? "" : " (\(r.inHoles.count) in other parts' holes)"
                let last = r.sheetCount > 1 ? "the last sheet" : "the sheet"
                Text("\(placed) of \(job.parts.count) part\(job.parts.count == 1 ? "" : "s") placed\(sheets)\(holes). "
                     + String(format: "They fill %.0f%% of the %@ %@ of %@ they use (%.0f%% of %@).",
                              r.utilization * 100, rough(r.usedLength), units.symbol, last,
                              r.sheetUtilization * 100, r.sheetCount > 1 ? "all the sheets' area" : "the sheet"))
                if placed > 0, r.sheetLength - r.usedLength > session.settings.spacing, let use = r.sheets.last {
                    let left = r.sheetLength - r.usedLength - session.settings.spacing
                    let across = r.alongX ? use.sheet.height : use.sheet.width
                    Text("About \(rough(left)) × \(rough(across)) \(units.symbol) of \(last) is left in one piece.")
                        .foregroundStyle(.secondary)
                }
                if !r.unplaced.isEmpty {
                    let names = r.unplaced.map { job.parts[$0].name }
                    let why = r.sheetCount >= session.settings.sheetLimit
                        ? (session.settings.sheetLimit == 1 ? "Allow more sheets to nest them on another." : "Allow more sheets to nest them too.")
                        : "They're too big for a sheet, or for the room between clamps."
                    Label("Didn't fit: \(names.prefix(8).joined(separator: ", "))\(names.count > 8 ? " and \(names.count - 8) more" : ""). "
                          + "Each stays where it is, or goes beside its sheet if a nested part now takes its place. \(why)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let job = session.job {
                let others = job.fixed.filter(\.isClosed).count
                if others > 0 || !job.keepOuts.isEmpty {
                    Text(stayNote(others: others, clamps: job.keepOuts.count)).foregroundStyle(.secondary)
                }
                ForEach(job.notes, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stayNote(others: Int, clamps: Int) -> String {
        var things: [String] = []
        if others > 0 { things.append(others == 1 ? "1 part that stays put" : "\(others) parts that stay put") }
        if clamps > 0 { things.append(clamps == 1 ? "1 clamp or keep-out" : "\(clamps) clamps and keep-outs") }
        return "Parts keep clear of " + things.joined(separator: " and ") + "."
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            if session.searching && !isStatic {
                Button("Stop") { session.finish() }
                    .help("Stop searching and keep the best layout so far")
            }
            Button("Cancel", role: .cancel) {
                session.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Apply") {
                session.finish()
                if let applied = session.applied() { onApply(applied) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled((session.result?.placedCount ?? 0) == 0)
            .help("Move the parts to the layout shown (Edit ▸ Undo puts them back)")
        }
        .padding(16)
    }

    @ViewBuilder
    private var status: some View {
        if let r = session.result {
            if session.searching && !isStatic {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let elapsed = context.date.timeIntervalSince(session.searchStarted)
                    HStack(spacing: 8) {
                        ProgressView(value: min(1, elapsed / max(session.settings.timeLimit, 0.1)))
                            .frame(width: 120)
                        Text("Searching… \(r.evaluations.formatted()) layouts tried").foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Best of \(r.evaluations.formatted()) layout\(r.evaluations == 1 ? "" : "s")"
                     + (isStatic ? "" : String(format: ", %.1f s", r.elapsed)))
                    .foregroundStyle(.secondary)
            }
        } else if session.phase == .ready {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Nesting…").foregroundStyle(.secondary)
            }
        }
    }
}

/// The sheets with the layout so far, side by side (in rows when there are many): the margin, clamps (on every sheet)
/// and parts that stay put, and each nested part where it goes, those in another part's hole a shade darker.
struct NestPreview: View {
    let session: NestSession

    var body: some View {
        Canvas { ctx, size in
            let project = session.project
            let first = Rect2(x: 0, y: 0, width: project.stock.width, height: project.stock.height)
            let used = max(session.result?.sheetCount ?? 1, session.job?.sheetCount ?? 1, 1)
            let sheets = (0..<used).map { k in
                session.result.flatMap { k < $0.sheets.count ? $0.sheets[k].sheet : nil } ?? session.settings.sheet(k, first: first)
            }
            // A grid of sheets, a gap apart, laid out in sheet units.
            let columns = used <= 3 ? used : Int(Double(used).squareRoot().rounded(.up))
            let rows = (used + columns - 1) / columns
            let cellW = sheets.map(\.width).max() ?? first.width, cellH = sheets.map(\.height).max() ?? first.height
            let gap = max(cellW, cellH) * 0.06
            let labelRoom: CGFloat = used > 1 ? 16 : 0
            let totalW = Double(columns) * cellW + Double(columns - 1) * gap
            let totalH = Double(rows) * cellH + Double(rows - 1) * gap
            let pad: CGFloat = 8
            let scale = min((size.width - 2 * pad) / totalW, (size.height - 2 * pad - CGFloat(rows) * labelRoom) / totalH)
            let drawnW = totalW * scale, drawnH = totalH * scale + CGFloat(rows) * labelRoom
            let origin0 = CGPoint(x: (size.width - drawnW) / 2, y: (size.height - drawnH) / 2)
            func originOf(_ k: Int) -> CGPoint {
                let c = k % columns, r = k / columns
                // Each sheet's lower-left corner, rows from the top.
                return CGPoint(x: origin0.x + Double(c) * (cellW + gap) * scale,
                               y: origin0.y + CGFloat(r) * labelRoom + (Double(r) * (cellH + gap) + sheets[k].height) * scale)
            }
            func pt(_ p: Vec2, _ k: Int) -> CGPoint {
                let o = originOf(k)
                return CGPoint(x: o.x + p.x * scale, y: o.y - p.y * scale)
            }
            func path(_ lines: [Polyline], _ k: Int) -> Path {
                var path = Path()
                for line in lines where line.count >= 2 {
                    path.move(to: pt(line.points[0], k))
                    for p in line.points.dropFirst() { path.addLine(to: pt(p, k)) }
                    if line.isClosed { path.closeSubpath() }
                }
                return path
            }
            func rect(_ r: Rect2, _ k: Int) -> Path {
                path([Polyline([r.min, Vec2(r.max.x, r.min.y), r.max, Vec2(r.min.x, r.max.y)], closed: true)], k)
            }
            let margin = session.settings.edgeMargin
            for (k, sheet) in sheets.enumerated() {
                ctx.fill(rect(sheet, k), with: .color(Color(red: 0.93, green: 0.86, blue: 0.72)))
                ctx.stroke(rect(sheet, k), with: .color(Color(red: 0.55, green: 0.45, blue: 0.3)), lineWidth: 1)
                if margin > 0, margin * 2 < min(sheet.width, sheet.height) {
                    ctx.stroke(rect(sheet.insetBy(margin), k), with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
                }
                if used > 1 {
                    let o = originOf(k)
                    let labelX: CGFloat = o.x + CGFloat(sheet.width) * scale / 2
                    let labelY: CGFloat = o.y + labelRoom / 2 + 2
                    ctx.draw(Text("Sheet \(k + 1)").font(.caption).foregroundStyle(.secondary),
                             at: CGPoint(x: labelX, y: labelY), anchor: .center)
                }
                for outline in session.job?.keepOuts ?? [] {
                    let p = path([outline], k)
                    ctx.fill(p, with: .color(.red.opacity(0.3)))
                    ctx.stroke(p, with: .color(.red), lineWidth: 1)
                }
            }
            for (i, lines) in session.fixedLines.enumerated() {
                let k = session.job.map { i < $0.fixed.count ? $0.fixed[i].sheet : 0 } ?? 0
                guard k < used else { continue }
                let p = path(lines, k)
                ctx.fill(p, with: .color(.gray.opacity(0.35)), style: FillStyle(eoFill: true))
                ctx.stroke(p, with: .color(.gray), lineWidth: 0.75)
            }
            guard let result = session.result else { return }
            for (i, placement) in result.placements.enumerated() where i < session.partLines.count {
                guard let placement, placement.sheet < used else { continue }
                let p = path(session.partLines[i].map(placement.apply), placement.sheet)
                let inHole = i < result.insideOf.count && result.insideOf[i] != nil
                ctx.fill(p, with: .color(.accentColor.opacity(inHole ? 0.5 : 0.28)), style: FillStyle(eoFill: true))
                ctx.stroke(p, with: .color(.accentColor), lineWidth: 1)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Preview of the nested parts on the sheets")
    }
}
