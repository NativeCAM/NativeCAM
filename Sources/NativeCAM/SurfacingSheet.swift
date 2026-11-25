import AppKit
import CAMCore
import SwiftUI

/// File ▸ Surface Spoilboard…: a standalone program that flattens the spoilboard (`Surfacing`), with an air-cut copy. The
/// document isn't changed, so the sheet remembers its last settings in the app's defaults instead.
struct SurfacingSheet: View {
    /// What the sheet remembers between uses, lengths in mm.
    struct Settings: Codable, Hashable, Sendable {
        var wholeBed = true
        var width = 24.inch
        var height = 24.inch
        var toolNumber: Int?
        var stepover = 0.5
        var depth: Double?
        var passes = 1
        var along: Surfacing.Along = .x
        var direction: Surfacing.Direction = .zigZag
        var clampOvershoot = false
        var clearance: Double?
        var boardThickness: Double?
        var airCut = true
    }

    static let settingsKey = "surfacingSettings"

    let machine: MachineProfile
    let tools: [Tool]
    var height: CGFloat = 760
    @Environment(\.dismiss) private var dismiss
    @State private var settings: Settings
    @State private var bedClear = false
    @State private var result: Result<Surfacing.Program, Surfacing.Refused>?
    @State private var saved: String?
    @State private var saveError: String?

    init(machine: MachineProfile, tools: [Tool], settings: Settings? = nil, height: CGFloat = 760, bedClear: Bool = false) {
        self.machine = machine
        self.tools = tools
        self.height = height
        _settings = State(initialValue: settings ?? Self.remembered())
        _bedClear = State(initialValue: bedClear)
    }

    static func remembered() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    private var units: LengthUnit { machine.outputUnits }
    private func len(_ mm: Double) -> String { Calibration.length(mm, units) }
    private var bits: [Tool] { Surfacing.bits(tools) }
    private var tool: Tool { bits.first { $0.number == settings.toolNumber } ?? bits[0] }

    static func options(_ s: Settings, tool: Tool, units: LengthUnit) -> Surfacing.Options {
        var o = Surfacing.Options.defaults(units, tool: tool)
        o.area = s.wholeBed ? .wholeBed : .custom(Vec2(s.width, s.height))
        o.stepover = s.stepover
        if let d = s.depth { o.depth = d }
        o.passes = s.passes
        o.along = s.along
        o.direction = s.direction
        o.clampOvershoot = s.clampOvershoot
        if let c = s.clearance { o.clearance = c }
        o.boardThickness = s.boardThickness
        return o
    }

    private var options: Surfacing.Options { Self.options(settings, tool: tool, units: units) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Surface Spoilboard").font(.headline)
                Text("Saves a program that flattens the spoilboard on \(machine.displayName) (\(machine.controllerLabel)), and an air-cut "
                     + "copy to run first. Z zero is the top of the spoilboard. Your document isn't changed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                areaSection
                cutSection
                previewSection
                checklistSection
                if let saved {
                    Section("Saved") { Text(saved).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                if let saveError {
                    Section { Text(saveError).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Toggle("Also save an air cut", isOn: $settings.airCut)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!bedClear || program == nil)
                    .help(bedClear ? "Save the surfacing program" : "Tick “Bed is clear” first")
            }
            .padding(16)
        }
        .frame(width: 640, height: height)
        .task(id: settings) { await rebuild() }
    }

    private var program: Surfacing.Program? {
        if case .success(let p) = result, p.passedChecks { return p }
        return nil
    }

    // MARK: Sections

    @ViewBuilder
    private var areaSection: some View {
        Section {
            Picker("Area", selection: $settings.wholeBed) {
                Text("Whole bed").tag(true)
                Text("Custom board").tag(false)
            }
            .pickerStyle(.segmented)
            if !settings.wholeBed {
                LengthField(title: "Width (X)", mm: $settings.width, units: units, minimum: 1)
                LengthField(title: "Depth (Y)", mm: $settings.height, units: units, minimum: 1)
                Toggle("Shorten the overshoot to fit the travel", isOn: $settings.clampOvershoot)
            }
            Picker("Bit", selection: Binding(get: { tool.number }, set: { settings.toolNumber = $0 })) {
                ForEach(bits) { t in Text("T\(t.number) \(t.name) (\(len(t.diameter)))").tag(t.number) }
            }
        } footer: {
            note(settings.wholeBed
                 ? "The machine's \(Calibration.size(machine.travel.xy, units)) travel less \(len(Surfacing.defaultInset(units))) on each side: "
                    + "every move stays that far inside the limits, and the bit surfaces its radius past the area's edges. "
                    + "XY zero is the area's front-left corner."
                 : "A board this size, zeroed at its front-left corner. The bit plunges just past its edge and runs "
                    + "\(len(tool.diameter / 2 + Surfacing.defaultOvershootMargin(units))) past each end, keeping "
                    + "\(len(Surfacing.defaultInset(units))) clear of the travel's limits.", problem: false)
        }
    }

    @ViewBuilder
    private var cutSection: some View {
        Section {
            NumberField(title: "Stepover", value: Binding(get: { settings.stepover * 100 }, set: { settings.stepover = $0 / 100 }),
                        suffix: "% (\(len(settings.stepover * tool.diameter)))", decimals: 0, range: 5...95)
            LengthField(title: "Depth per pass", mm: Binding(get: { settings.depth ?? options.depth }, set: { settings.depth = $0 }),
                        units: units, help: "At most \(len(Surfacing.maximumPass(tool, units))); \(len(Surfacing.deepPass(units))) or less is usual",
                        minimum: 0.01)
            IntField(title: "Passes", value: $settings.passes, range: 1...20)
            Picker("Lines", selection: $settings.along) {
                ForEach(Surfacing.Along.allCases) { Text($0.label).tag($0) }
            }
            Picker("Direction", selection: $settings.direction) {
                ForEach(Surfacing.Direction.allCases) { Text($0.label).tag($0) }
            }
            LengthField(title: "Clearance", mm: Binding(get: { settings.clearance ?? options.clearance }, set: { settings.clearance = $0 }),
                        units: units, help: "Rapids stay at least this far above the board", minimum: 1)
            OptionalLengthField(title: "Board thickness", mm: $settings.boardThickness, units: units, prompt: "Optional",
                                help: "Refused when less than \(len(Surfacing.minimumBoard(units))) would be left")
        } footer: {
            note("Feed \(Calibration.feed(tool.cutting.feedRate, units)) and \(Int(machine.clampRPM(tool.cutting.spindleRPM))) RPM from the "
                 + "tool library. One way cuts every line climb, for reading the spindle's tram: ridges between lines mean it's out of tram.",
                 problem: false)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section("Preview") {
            SurfacingPreview(travel: machine.travel.xy, program: currentProgram, inset: settings.wholeBed ? Surfacing.defaultInset(units) : 0)
                .frame(height: 220)
            switch result {
            case nil:
                Text("Working it out…").font(.callout).foregroundStyle(.secondary)
            case .failure(let refused):
                note("Can't be cut: \(refused.reason)", problem: true)
            case .success(let p):
                Text(summary(p)).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(p.issues + p.airIssues) { issue in
                    note("\(issue.severity == .error ? "Error" : "Warning"): \(issue.text)", problem: true)
                }
            }
        }
    }

    private var currentProgram: Surfacing.Program? {
        if case .success(let p) = result { return p }
        return nil
    }

    private func summary(_ p: Surfacing.Program) -> String {
        let plan = p.plan
        return "\(Calibration.size(plan.area, units)): \(plan.lines.count) lines \(len(plan.spacing)) apart, "
            + "\(settings.passes) × \(len(settings.depth ?? options.depth)) = \(len(plan.totalDepth)) off. "
            + (plan.entry == .ramp ? "Ramps in over \(len(plan.rampLength))." : "Plunges past the edge.")
            + " About \(Surfacing.time(p.estimatedSeconds)), the tool change included."
    }

    @ViewBuilder
    private var checklistSection: some View {
        Section("Before you save") {
            VStack(alignment: .leading, spacing: 4) {
                Text("• Remove every clamp, hold-down and stop from the bed.")
                Text("• Every screw head and T-nut at least \(len(units == .inch ? 0.125.inch : 3)) below the cut.")
                Text("• Dust shoe set high enough for the surfacing bit.")
                Text("• Z zero on the top of the spoilboard, with the touch plate on the board.")
                Text("• Run the air cut first and watch both far corners for a soft-limit stop.")
            }
            .font(.callout)
            Toggle("Bed is clear", isOn: $bedClear)
        }
    }

    private func note(_ text: String, problem: Bool) -> some View {
        Text(text).font(.caption).foregroundStyle(problem ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Work

    private func rebuild() async {
        let machine = machine, options = options
        let r: Result<Surfacing.Program, Surfacing.Refused> = await Task.detached {
            do { return .success(try Surfacing.program(machine: machine, options: options)) } catch let refused as Surfacing.Refused {
                return .failure(refused)
            } catch {
                return .failure(Surfacing.Refused(error.localizedDescription))
            }
        }.value
        result = r
    }

    /// Asks where to save, then writes the program and (when asked) its air cut beside it.
    private func save() {
        guard let program else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = program.fileName
        panel.message = "Save the surfacing program" + (settings.airCut ? " (the air cut is saved beside it)" : "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        let written = Self.write(program, to: url, airCut: settings.airCut)
        saved = written.written.isEmpty ? nil : "In \(url.deletingLastPathComponent().path):\n" + written.written.joined(separator: "\n")
        saveError = written.problems.isEmpty ? nil : written.problems.joined(separator: "\n")
    }

    /// Writes the program to `url` and its air cut beside it (`name-air.ext`).
    static func write(_ program: Surfacing.Program, to url: URL, airCut: Bool) -> (written: [String], problems: [String]) {
        var written: [String] = [], problems: [String] = []
        let ext = url.pathExtension.isEmpty ? program.fileExtension : url.pathExtension
        let main = url.deletingPathExtension().appendingPathExtension(ext)
        let air = url.deletingPathExtension().deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-air").appendingPathExtension(ext)
        for (file, text) in [(main, program.gcode)] + (airCut ? [(air, program.airGCode)] : []) {
            do {
                try text.write(to: file, atomically: true, encoding: .ascii)
                written.append(file.lastPathComponent)
            } catch {
                problems.append("Can't write \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (written, problems)
    }
}

/// The travel, the area and the lines, seen from above with the front-left at the bottom left.
struct SurfacingPreview: View {
    let travel: Vec2
    let program: Surfacing.Program?
    /// Where the area's front-left sits in the travel, mm (the whole bed's inset; 0 for a custom board).
    let inset: Double

    var body: some View {
        Canvas { ctx, size in
            guard travel.x > 0, travel.y > 0 else { return }
            let scale = min((size.width - 20) / travel.x, (size.height - 20) / travel.y)
            let ox = (size.width - travel.x * scale) / 2, oy = (size.height - travel.y * scale) / 2
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + (x + inset) * scale, y: size.height - oy - (y + inset) * scale) }
            let bed = CGRect(x: ox, y: oy, width: travel.x * scale, height: travel.y * scale)
            ctx.stroke(Path(bed), with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            guard let program else { return }
            let a = program.plan.area
            let area = Path(CGRect(origin: pt(0, a.y), size: CGSize(width: a.x * scale, height: a.y * scale)))
            ctx.fill(area, with: .color(.accentColor.opacity(0.12)))
            ctx.stroke(area, with: .color(.accentColor), lineWidth: 1.5)
            var lines = Path()
            for tp in program.toolpaths.prefix(1) {
                var p = tp.start
                for m in tp.motions {
                    if m.kind != .rapid, m.end.z < 0, p.z < 0 {
                        lines.move(to: pt(p.x, p.y))
                        lines.addLine(to: pt(m.end.x, m.end.y))
                    }
                    p = m.end
                }
            }
            ctx.stroke(lines, with: .color(.accentColor.opacity(0.7)), lineWidth: 0.75)
            ctx.fill(Path(ellipseIn: CGRect(x: pt(0, 0).x - 3, y: pt(0, 0).y - 3, width: 6, height: 6)), with: .color(.red))
            ctx.draw(Text("XY zero").font(.caption2), at: CGPoint(x: pt(0, 0).x + 4, y: pt(0, 0).y - 8), anchor: .leading)
        }
        .accessibilityLabel("Preview of the surfacing lines over the machine's travel")
    }
}
