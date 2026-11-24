import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Calibration Programs…: optional programs that measure what NativeCAM otherwise estimates (`Calibration`), and the
/// times measured with them fitted into the machine (`Calibration.fit`). Making the programs changes nothing; the machine
/// changes only when Apply is clicked.
struct CalibrationSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programs"
        case times = "Enter Times"
        var id: String { rawValue }
    }

    let project: Project
    let tools: [Tool]
    /// The sheet's height (taller in snapshot checks, to show it all).
    var height: CGFloat
    /// Writes a fit into the document's machine and, when the flag is set, into its entry in the machine library.
    let onApply: (Calibration.FitResult, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
    @State private var window: Vec2
    @State private var airHeight: Double
    @State private var makeTiming = true
    @State private var makeRotary = true
    @State private var makeLadder = true
    @State private var ladderToolID: UUID?
    @State private var material: MaterialKind
    @State private var stepRPM = false
    @State private var timingSummary: String?
    @State private var saved: String?
    @State private var saveError: String?
    @State private var times: [Calibration.Times]
    @State private var sections: [Calibration.Kind: [Calibration.Section]]
    @State private var entries: [String: String]
    @State private var fit: Calibration.FitResult?
    @State private var fitError: String?
    @State private var fitting = false
    @State private var toLibrary = true
    @State private var applied = false

    static let windowKey = "calibrationWindow"
    static let airKey = "calibrationAirHeight"

    init(project: Project, tools: [Tool], tab: Tab = .programs, entries: [String: String] = [:], fit: Calibration.FitResult? = nil,
         height: CGFloat = 720, onApply: @escaping (Calibration.FitResult, Bool) -> Void) {
        self.project = project
        self.tools = tools
        self.height = height
        self.onApply = onApply
        let machine = project.machine
        var options = Calibration.TimingOptions.defaults(machine.outputUnits)
        if let saved = UserDefaults.standard.array(forKey: Self.windowKey) as? [Double], saved.count == 2 {
            options.window = Vec2(saved[0], saved[1])
        }
        let air = UserDefaults.standard.double(forKey: Self.airKey)
        if air >= Calibration.minimumAirHeight { options.airHeight = air }
        _tab = State(initialValue: tab)
        _window = State(initialValue: options.window)
        _airHeight = State(initialValue: options.airHeight)
        _material = State(initialValue: project.stock.material)
        let ladderTools = Self.ladderTools(tools)
        _ladderToolID = State(initialValue: (ladderTools.first { $0.shape == .flatEndMill } ?? ladderTools.first)?.id)
        let blank = Calibration.blankTimes(machine: machine, options: options)
        _times = State(initialValue: blank)
        _sections = State(initialValue: Dictionary(uniqueKeysWithValues: blank.map { ($0.kind, Calibration.sections($0, machine: machine)) }))
        _entries = State(initialValue: entries)
        _fit = State(initialValue: fit)
    }

    private var machine: MachineProfile { project.machine }
    private var units: LengthUnit { machine.outputUnits }
    private var options: Calibration.TimingOptions { Calibration.TimingOptions(window: window, airHeight: airHeight) }
    private func len(_ mm: Double) -> String { Calibration.length(mm, units) }

    /// Bits the ladder can test: the ones a chart covers, but not form bits (they cut an edge, not a slot).
    static func ladderTools(_ tools: [Tool]) -> [Tool] {
        let usable = tools.filter { ChipLoad.applies(to: $0) && $0.shape != .form }
        return usable.isEmpty ? [ToolLibrary.starter.tool(number: 1)!] : usable
    }

    private var ladderTool: Tool? { Self.ladderTools(tools).first { $0.id == ladderToolID } }
    private var ladderOptions: Calibration.LadderOptions? {
        ladderTool.map { Calibration.LadderOptions(tool: $0, material: material, stepRPM: stepRPM) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calibration Programs").font(.headline)
                Text("Optional programs that measure what NativeCAM otherwise estimates on \(machine.displayName) (\(machine.controllerLabel)): "
                     + "run times, the rotary axis's turn speed and G93, and whether a change of feed slows the machine. Run them "
                     + "whenever suits you. Nothing about the machine changes until you enter times and click Apply.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                switch tab {
                case .programs: programs
                case .times: timesForm
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if tab == .programs {
                    Button("Save Programs…") { savePrograms() }
                        .disabled(!(makeTiming || makeRotary || makeLadder))
                } else {
                    Button("Open Times File…") { openTimes() }
                    Button("Fit") { runFit() }
                        .disabled(fitting || parsedTimes().measuredCount == 0)
                }
                Spacer()
                if tab == .times {
                    Button("Apply to Machine") { apply() }
                        .disabled(fit?.changes.isEmpty ?? true || applied)
                        .help("Write the fitted values into this document's machine")
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: height)
        .task(id: options) { await summarizeTiming() }
    }

    // MARK: Programs

    @ViewBuilder
    private var programs: some View {
        Section {
            Toggle("Timing suite (air cut)", isOn: $makeTiming)
            if makeTiming {
                LengthField(title: "Window width (X)", mm: Binding(get: { window.x }, set: { window.x = $0 }), units: units, minimum: 1)
                LengthField(title: "Window depth (Y)", mm: Binding(get: { window.y }, set: { window.y = $0 }), units: units, minimum: 1)
                LengthField(title: "Air height", mm: $airHeight, units: units, help: "Every move stays at least this far above Z zero",
                            minimum: Calibration.minimumAirHeight)
            }
        } footer: {
            note(timingStatus)
        }
        Section {
            Toggle("Rotary check (A only, in the air)",
                   isOn: Binding(get: { makeRotary && Calibration.rotaryRefusal(machine) == nil }, set: { makeRotary = $0 }))
                .disabled(Calibration.rotaryRefusal(machine) != nil)
        } footer: {
            if let refused = Calibration.rotaryRefusal(machine) {
                note((refused.reason, true))
            } else {
                note(("Turns G93 G1 A360 F10, which should take 6 s, then rapid turns of 360° and 720°. Only A moves: take any stock "
                      + "out of the chuck.", false))
            }
        }
        Section {
            Toggle("Chip-load ladder (a real cut, in scrap)", isOn: $makeLadder)
            if makeLadder {
                Picker("Bit", selection: $ladderToolID) {
                    ForEach(Self.ladderTools(tools)) { t in Text("T\(t.number) \(t.name)").tag(Optional(t.id)) }
                }
                Picker("Material", selection: $material) {
                    ForEach(MaterialKind.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Also step the spindle speed", isOn: $stepRPM)
            }
        } footer: {
            note(ladderStatus)
        }
        if let saved {
            Section("Saved") { Text(saved).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        if let saveError {
            Section { Text(saveError).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func note(_ status: (text: String, problem: Bool)) -> some View {
        Text(status.text).font(.caption).foregroundStyle(status.problem ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var timingStatus: (text: String, problem: Bool) {
        do {
            _ = try Calibration.timingPlan(machine: machine, options: options)
        } catch {
            return (error.localizedDescription, true)
        }
        return (timingSummary ?? "Working out the sections…", false)
    }

    private func summarizeTiming() async {
        let machine = machine, options = options, u = units
        let text: String? = await Task.detached {
            guard let plan = try? Calibration.timingPlan(machine: machine, options: options) else { return nil }
            let sections = Calibration.sections(Calibration.Times(kind: .timing, controller: plan.controller, plan: plan), machine: machine)
            let minutes = Int((sections.map(\.estimate).reduce(0, +) / 60).rounded())
            return "\(sections.count) sections of about \(Int(Calibration.sectionTarget)) s each, about \(minutes) min of moves plus the stops, "
                + "in a \(Calibration.size(options.window, u)) window from at least \(Calibration.length(options.airHeight, u)) above Z zero "
                + "to \(Calibration.length(plan.topZ, u)). Zero X and Y at the window's front-left corner and Z on the work."
        }.value
        timingSummary = text
    }

    private var ladderStatus: (text: String, problem: Bool) {
        guard let options = ladderOptions else { return ("No bit in the library suits the ladder.", true) }
        if let refused = Calibration.ladderRefusal(options, machine: machine) { return (refused.reason, true) }
        do {
            let program = try Calibration.ladder(machine: machine, options: options)
            let chips = program.rungs.map(\.chipLoad)
            let window = program.window.map { Calibration.size($0, units) } ?? ""
            return ("\(program.rungs.count) slots from \(Calibration.chipText(chips.min() ?? 0, units)) to "
                    + "\(Calibration.chipText(chips.max() ?? 0, units)) in scrap at least \(window), with the machine's usual tool change.", false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    /// Asks for a folder, then saves each chosen program there with its recording sheet and times file.
    private func savePrograms() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for the calibration programs and their recording sheets"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set([window.x, window.y], forKey: Self.windowKey)
        UserDefaults.standard.set(airHeight, forKey: Self.airKey)
        let result = Self.save(machine: machine, timing: makeTiming ? options : nil, rotary: makeRotary && Calibration.rotaryRefusal(machine) == nil,
                               ladder: makeLadder ? ladderOptions : nil, to: folder)
        saved = result.written.isEmpty ? nil : "In \(folder.path):\n" + result.written.joined(separator: "\n")
        saveError = result.problems.isEmpty ? nil : result.problems.joined(separator: "\n")
        // The times to enter are for the programs just saved.
        let blank = Calibration.blankTimes(machine: machine, options: options)
        times = blank
        sections = Dictionary(uniqueKeysWithValues: blank.map { ($0.kind, Calibration.sections($0, machine: machine)) })
    }

    /// Writes the programs to `folder`: each file, its recording sheet and (timing and rotary) its times file.
    static func save(machine: MachineProfile, timing: Calibration.TimingOptions?, rotary: Bool, ladder: Calibration.LadderOptions?,
                     to folder: URL) -> (written: [String], problems: [String]) {
        var written: [String] = [], problems: [String] = []
        var programs: [Calibration.Program] = []
        do {
            if let timing { programs.append(try Calibration.timing(machine: machine, options: timing)) }
            if rotary { programs.append(try Calibration.rotary(machine: machine)) }
            if let ladder { programs.append(try Calibration.ladder(machine: machine, options: ladder)) }
        } catch {
            problems.append(error.localizedDescription)
        }
        for program in programs {
            guard program.passedChecks else {
                problems.append("\(program.kind.label) not saved: it failed its checks (\(program.issues.map(\.text).joined(separator: "; "))).")
                continue
            }
            let stem = program.kind.fileStem
            var files: [(String, String)] = [(program.fileName, program.gcode), (stem + ".html", RecordingSheet.html(program))]
            if program.kind != .ladder { files.append((stem + "-times.csv", Calibration.timesCSV(program))) }
            for (name, text) in files {
                do {
                    try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: name == program.fileName ? .ascii : .utf8)
                    written.append(name)
                } catch {
                    problems.append("Can't write \(name): \(error.localizedDescription)")
                }
            }
        }
        return (written, problems)
    }

    // MARK: Times

    @ViewBuilder
    private var timesForm: some View {
        if times.isEmpty {
            Section { Text("NativeCAM has no timing program for this machine's controller.").foregroundStyle(.secondary) }
        }
        ForEach(times, id: \.kind) { t in
            Section {
                ForEach(sections[t.kind] ?? []) { s in
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(s.id == "rotary-g93" ? "6 s expected" : String(format: "%.1f s", s.estimate))
                                .foregroundStyle(.secondary).monospacedDigit().frame(width: 90, alignment: .trailing)
                            TextField("Seconds", text: Binding(get: { entries[key(t.kind, s.id)] ?? "" },
                                                               set: { entries[key(t.kind, s.id)] = $0; fit = nil; fitError = nil; applied = false }))
                                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                            Text("s").foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(s.name)
                    }
                }
            } header: {
                Text(t.kind.label)
            } footer: {
                Text(t.kind == .timing
                     ? "Seconds from each section's first move until the machine stopped; leave a section blank to skip it. Times for the "
                        + "program these settings make: if the machine has changed since you saved it, open its times file instead."
                     : "The first turn is in inverse time and should take 6 s.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let fitError {
            Section { Text(fitError).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        if fitting {
            Section { ProgressView().controlSize(.small) }
        }
        if let fit { results(fit) }
    }

    private func key(_ kind: Calibration.Kind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

    /// The entries as times; a field that isn't a number of seconds makes the fit refuse with its name.
    private func parsedTimes() -> (times: [Calibration.Times], measuredCount: Int, problem: String?) {
        var out: [Calibration.Times] = [], count = 0
        var problem: String?
        for var t in times {
            t.measured = [:]
            for s in sections[t.kind] ?? [] {
                let text = (entries[key(t.kind, s.id)] ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                guard !text.isEmpty else { continue }
                if let v = Double(text.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)) {
                    t.measured[s.id] = v
                    count += 1
                } else if problem == nil {
                    problem = "“\(text)” isn't a number of seconds (\(s.name))."
                }
            }
            if !t.measured.isEmpty { out.append(t) }
        }
        return (out, count, problem)
    }

    private func runFit() {
        let parsed = parsedTimes()
        if let problem = parsed.problem { fitError = problem; fit = nil; return }
        fitting = true
        fitError = nil
        applied = false
        let machine = machine, measured = parsed.times
        Task {
            let result: Result<Calibration.FitResult, Error> = await Task.detached { Result { try Calibration.fit(measured, machine: machine) } }.value
            fitting = false
            switch result {
            case let .success(r): fit = r
            case let .failure(e): fit = nil; fitError = e.localizedDescription
            }
        }
    }

    private func openTimes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a times file saved with the calibration programs (…-times.csv)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try Calibration.readTimes(String(contentsOf: url, encoding: .utf8))
            times.removeAll { $0.kind == loaded.kind }
            times.append(loaded)
            times.sort { $0.kind == .timing && $1.kind != .timing }
            sections[loaded.kind] = Calibration.sections(loaded, machine: machine)
            entries = entries.filter { !$0.key.hasPrefix(loaded.kind.rawValue + ":") }
            for (id, v) in loaded.measured { entries[key(loaded.kind, id)] = Calibration.number(v) }
            fit = nil
            fitError = nil
            applied = false
        } catch {
            fitError = "Can't use \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func results(_ fit: Calibration.FitResult) -> some View {
        Section {
            ForEach(fit.values) { v in
                LabeledContent(v.label) {
                    HStack(spacing: 6) {
                        Text(v.text(v.before, units)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).imageScale(.small)
                        Text(v.determined ? v.text(v.after, units) : "not timed, stays").monospacedDigit()
                            .foregroundStyle(v.determined ? .primary : .secondary)
                    }
                }
            }
        } header: {
            Text("Fitted values")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fit.notes, id: \.self) { Text($0) }
                if libraryEntry != nil {
                    Toggle("Also save to “\(libraryEntry?.name ?? "")” in the machine library, for new documents", isOn: $toLibrary)
                        .toggleStyle(.checkbox)
                }
                Text(applied
                     ? "Applied to this document's machine\(toLibrary && libraryEntry != nil ? " and the machine library" : ""), marked as measured. "
                        + "NativeCAM's built-in machine defaults stay as they are."
                     : "Apply writes these into this document's machine, marked as measured. NativeCAM's built-in machine defaults stay as they are.")
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if fit.fChange != nil || fit.g93 != nil {
            Section("Verdicts") {
                if let v = fit.fChange { verdict("F-change line", v) }
                if let v = fit.g93 { verdict("G93", v) }
            }
        }
        Section {
            DisclosureGroup("Each section, before and after") {
                ForEach(fit.rows) { r in
                    HStack {
                        Text(r.name).lineLimit(1)
                        Spacer()
                        Text(r.measured.map { String(format: "%.1f s", $0) } ?? "not timed").foregroundStyle(.secondary).monospacedDigit()
                        Text(percent(r.errorBefore)).frame(width: 64, alignment: .trailing).foregroundStyle(.secondary).monospacedDigit()
                        Text(percent(r.errorAfter)).frame(width: 64, alignment: .trailing).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        } footer: {
            Text("NativeCAM's estimate against the time measured, before and after the fit.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func verdict(_ title: String, _ v: Calibration.FitResult.Verdict) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(v.text.prefix(1).uppercased() + v.text.dropFirst()).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: v.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(v.passed ? .green : .orange)
        }
    }

    private func percent(_ e: Double?) -> String { e.map { String(format: "%+.1f%%", 100 * $0) } ?? "" }

    private var libraryEntry: MachineSetup? { machine.libraryID.flatMap { MachineLibraryFile.library.machine(id: $0) } }

    private func apply() {
        guard let fit, !fit.changes.isEmpty else { return }
        onApply(fit, toLibrary && libraryEntry != nil)
        applied = true
    }
}
