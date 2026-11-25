import CAMCore
import SwiftUI

/// File ▸ Export Restart… or the simulation bar's Restart Here…: a restart to set up, preset to a point.
struct RestartPreset: Identifiable {
    let id = UUID()
    var request: Restart.Request
}

/// The restart sheet: which file and toolpath, where in it, and the options, with what the restart file will do and
/// any refusal shown live. Export hands the checked restart to the window, which saves it.
struct ExportRestartSheet: View {
    let project: Project
    let job: JobResult
    let onExport: (Restart.Output) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var request: Restart.Request
    @State private var mode: Mode
    @State private var pass: Int
    @State private var lineText: String
    @State private var airCut = false
    @State private var airHeight: Double
    @State private var outcome: Outcome?
    private let files: [(name: String, toolpaths: [(name: String, passes: Int)])]

    enum Mode: Hashable { case toolpath, pass, line }

    enum Outcome {
        case ready(Restart.Output)
        case refused(String)
    }

    init(project: Project, job: JobResult, preset: Restart.Request, onExport: @escaping (Restart.Output) -> Void) {
        self.project = project
        self.job = job
        self.onExport = onExport
        var files: [(name: String, toolpaths: [(name: String, passes: Int)])] = []
        if let export = JobExport.files(project, job: job) {
            for (n, f) in export.files.enumerated() {
                let tps = f.toolpaths.filter { !$0.isEmpty }.map { ($0.name, Restart.passStarts($0, stock: f.project.stock).count) }
                files.append((f.suffix.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -")) } ?? "File \(n + 1)", tps))
            }
        }
        self.files = files
        _request = State(initialValue: preset)
        switch preset.start {
        case .toolpath:
            _mode = State(initialValue: .toolpath); _pass = State(initialValue: 1); _lineText = State(initialValue: "")
        case let .pass(n):
            _mode = State(initialValue: .pass); _pass = State(initialValue: n); _lineText = State(initialValue: "")
        case let .line(n):
            _mode = State(initialValue: .line); _pass = State(initialValue: 1); _lineText = State(initialValue: String(n))
        }
        _airHeight = State(initialValue: project.displayUnits == .inch ? 1 : 25)
        _outcome = State(initialValue: Self.make(project, job, preset))
    }

    static func make(_ project: Project, _ job: JobResult, _ request: Restart.Request) -> Outcome {
        do { return .ready(try Restart.make(project, job: job, request: request)) } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// The request the controls describe.
    private var current: Restart.Request {
        var r = request
        switch mode {
        case .toolpath: r.start = .toolpath
        case .pass: r.start = pass <= 1 ? .toolpath : .pass(pass)
        case .line: r.start = .line(Int(lineText.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        r.airCut = airCut ? project.displayUnits.toMM(airHeight) : nil
        return r
    }

    private var toolpaths: [(name: String, passes: Int)] { files.indices.contains(request.file) ? files[request.file].toolpaths : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Restart").font(.headline)
                Text("The rest of the job from part way through, after a broken bit, a power cut or an E-stop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])
            Form {
                Section {
                    if files.count > 1 {
                        Picker("File", selection: $request.file) {
                            ForEach(files.indices, id: \.self) { Text(files[$0].name).tag($0) }
                        }
                    }
                    Picker("Toolpath", selection: $request.toolpath) {
                        ForEach(toolpaths.indices, id: \.self) { i in Text("\(i + 1). \(toolpaths[i].name)").tag(i) }
                    }
                    .disabled(mode == .line)
                    Picker("Start at", selection: $mode) {
                        Text("Start of the toolpath").tag(Mode.toolpath)
                        Text("A pass").tag(Mode.pass)
                        Text("A line of the full file").tag(Mode.line)
                    }
                    if mode == .pass, toolpaths.indices.contains(request.toolpath) {
                        Stepper(value: $pass, in: 1...max(1, toolpaths[request.toolpath].passes)) {
                            Text("Pass \(pass) of \(toolpaths[request.toolpath].passes)").monospacedDigit()
                        }
                    }
                    if mode == .line {
                        TextField("Line (as Mach4 shows it)", text: $lineText)
                    }
                } footer: {
                    if mode == .line { Text("If you're not sure where the cut really stopped, pick an earlier line.").font(.caption) }
                }
                Section {
                    Toggle("Re-cut from the start of that pass", isOn: Binding(get: { !request.exact }, set: { request.exact = !$0 }))
                        .help("Off: restart at the move itself, fed straight down to it. Refused where that would cut material.")
                    Toggle("Stop above the restart point to check the position", isOn: $request.pauseAbove)
                    Toggle("Air cut", isOn: $airCut)
                    if airCut {
                        HStack {
                            TextField("Raise Z by", value: $airHeight, format: .number)
                            Text(project.displayUnits.symbol)
                        }
                    }
                }
                Section("The restart") { summary }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    if case let .ready(output) = outcome {
                        dismiss()
                        onExport(output)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .ready = outcome { return false } else { return true } }())
            }
            .padding()
        }
        .frame(width: 560, height: 640)
        .onChange(of: current) { _, new in outcome = Self.make(project, job, new) }
    }

    @ViewBuilder private var summary: some View {
        switch outcome {
        case .none:
            ProgressView()
        case let .refused(message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case let .ready(r):
            let tp = r.toolpaths[0]
            LabeledContent("Starts at") {
                Text("\(r.point.toolpath + 1). \(tp.name), " + (r.point.atToolpathStart ? "its start" : "pass \(r.point.pass) of \(r.point.passCount)")
                     + (r.point.exact ? ", exactly" : ""))
            }
            if let text = r.point.lineText, let line = r.point.line {
                LabeledContent("Line \(line)") { Text(text).font(.callout.monospaced()).lineLimit(1) }
            }
            LabeledContent("Load") { Text("T\(tp.tool.number) \(tp.tool.name)") }
            LabeledContent("Runs for") { Text("≈ \(formatDuration(r.remainingSeconds))") }
            if let a = r.expectedA { LabeledContent("A will read") { Text(String(format: "%.3f°", a)).monospacedDigit() } }
            ForEach(r.issues.filter { $0.severity != .info }, id: \.id) { issue in
                Label(issue.text, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
            }
            Text("After a power cut or E-stop, re-home and check the XY zero against the setup sheet. Re-zero Z with the touch "
                 + "plate at the tool change even if the bit didn't change, and jog Z clear of the work before Cycle Start.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
