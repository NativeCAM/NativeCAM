import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

/// Guided machine setup: pick the machine from the catalogue (or a generic one, or import a controller's
/// settings), then the controller and how it gets files, the units, tool changes, spindle and dust collector,
/// and finish on a plain-language summary with a preview of the acceptance test program.
struct MachineSetupView: View {
    /// Offer "Use in this document" (when opened from a document's Job Setup).
    let offerUseHere: Bool
    /// Developer captures: open on this catalogue ID (or "generic") at this step.
    var start: (selection: String, step: Step)?
    let onFinish: (_ setup: MachineSetup, _ useForNewDocuments: Bool, _ useHere: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable { case machine, controller, setup, summary }
    @State private var step = Step.machine
    @State private var search = ""
    @State private var selection: String? // catalogue ID, "generic", or "imported"
    @State private var imported: MachineImport?
    @State private var controllerIndex = 0
    @State private var sender = SenderChoice.notSure
    @State private var machine = MachineProfile()
    @State private var name = ""
    @State private var useForNew = true
    @State private var useHere = true
    @State private var error: String?

    private let catalogue = MachineCatalogue.builtIn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Set Up a Machine").font(.headline)
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)").foregroundStyle(.secondary).font(.callout)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch step {
                case .machine: machineStep
                case .controller: controllerStep
                case .setup: setupStep
                case .summary: summaryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step != .machine { Button("Back") { step = Step(rawValue: step.rawValue - 1)! } }
                if step == .summary {
                    Button("Finish") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Next") { next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .machine && selection == nil)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear {
            guard let start else { return }
            selection = start.selection
            while step.rawValue < start.step.rawValue { next() }
        }
        .alert("Can't import these settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var units: LengthUnit { machine.outputUnits }
    private var entry: MachineCatalogue.Entry? { catalogue.entries.first { $0.id == selection } }

    // MARK: Step 1: machine

    private var filtered: [(vendor: String, entries: [MachineCatalogue.Entry])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return catalogue.byVendor.compactMap { group in
            let hits = q.isEmpty ? group.entries : group.entries.filter { $0.displayName.lowercased().contains(q) }
            return hits.isEmpty ? nil : (group.vendor, hits.sorted { $0.displayName < $1.displayName })
        }
    }

    private var machineStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which machine is it? Pick your model and size, or start from a generic machine.")
                .padding(.horizontal, 20).padding(.top, 12)
            TextField("Search machines", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
            List(selection: $selection) {
                Section {
                    Label("Generic machine", systemImage: "cube.transparent").tag("generic")
                    if let imported {
                        Label("Imported: \(imported.machineName ?? imported.format.rawValue)", systemImage: "doc.text").tag("imported")
                    }
                }
                ForEach(filtered, id: \.vendor) { group in
                    Section(group.vendor) {
                        ForEach(group.entries) { e in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.model.isEmpty ? e.family : "\(e.family) \(e.model)")
                                    Text(entrySubtitle(e)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if e.verified {
                                    Text("Tested").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green.opacity(0.18)))
                                }
                            }
                            .tag(e.id)
                        }
                    }
                }
            }
            HStack {
                Button("Import Controller Settings…") { importFile() }
                    .help("Start from Grbl $$ output, Mach4's Machine.ini, a LinuxCNC INI, a FluidNC config or a Fusion 360 machine")
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private func entrySubtitle(_ e: MachineCatalogue.Entry) -> String {
        let u = LengthUnit(rawValue: e.units ?? "inch") ?? .inch
        let size = e.travel.count == 3 ? "\(u.format(e.travel[0], decimals: u == .inch ? 1 : 0)) × \(u.format(e.travel[1], decimals: u == .inch ? 1 : 0)) \(u.symbol)" : ""
        return [size, e.defaultController?.displayName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineSettingsImporter.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            imported = try MachineSettingsImporter.load(url: url)
            selection = "imported"
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Step 2: controller

    /// The controllers this machine can run: the catalogue's list, or every controller NativeCAM writes for.
    private var options: [MachineCatalogue.ControllerOption] {
        if let entry { return entry.controllers }
        var list: [MachineCatalogue.ControllerOption] = [
            .init(family: "grbl", label: "Grbl 1.1"), .init(family: "grblHAL"), .init(family: "fluidNC"),
            .init(family: "carbideMotion"), .init(family: "mach4", label: "Mach4 (Avid's profile)"),
        ]
        if let c = imported?.controller, let i = list.firstIndex(where: { $0.family == c.family.rawValue }) {
            list.insert(list.remove(at: i), at: 0)
        }
        return list
    }

    private var controllerStep: some View {
        Form {
            Section {
                Picker("Controller", selection: $controllerIndex) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                        let family = ControllerFamily(rawValue: o.family)
                        let supported = o.family == "mach4" || Dialect.for(profile(o)) != nil
                        Text(o.displayName + (supported ? "" : " (no post yet)")).tag(i)
                            .help(supported ? "" : "NativeCAM can't write G-code for \(family.label) yet")
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: controllerIndex) { _, _ in applyController() }
            } header: {
                Text("Which controller runs it?")
            } footer: {
                Text("A wrong choice here is the most common way to get G-code a machine misreads, so pick what's actually on your machine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isGrblWithSender {
                Section {
                    Picker("Sends files with", selection: $sender) {
                        ForEach(SenderChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: sender) { _, _ in applyController() }
                } header: {
                    Text("Which program sends files to it?")
                } footer: {
                    Text(sender.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let line = machine.summary.dropFirst().first {
                Section("Tool changes") { Text(line).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
    }

    private var isGrblWithSender: Bool {
        guard let f = machine.controller?.family else { return false }
        return f == .grbl || f == .grblHAL
    }

    private func profile(_ option: MachineCatalogue.ControllerOption) -> MachineProfile {
        var m = machine
        m.controller = option.profile(avid: isAvid)
        return m
    }

    private var isAvid: Bool { entry?.vendor == "Avid CNC" || (selection == "generic" && machine.model != .custom) }

    private func applyController() {
        guard options.indices.contains(controllerIndex) else { return }
        var option = options[controllerIndex]
        let family = ControllerFamily(rawValue: option.family)
        if family == .grbl || family == .grblHAL { option.sender = sender.senderName ?? option.sender }
        machine.controller = option.profile(avid: isAvid)
    }

    // MARK: Step 3: setup

    private var setupStep: some View {
        Form {
            Section {
                Picker("G-code units", selection: $machine.outputUnits) {
                    Text("Inches (G20)").tag(LengthUnit.inch)
                    Text("Millimetres (G21)").tag(LengthUnit.mm)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Controllers don't convert units: the file must match the units the controller is set up for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tool changes") {
                Picker("Tools change", selection: $machine.toolChange) {
                    Text("By hand, stopping on M6 (touch plate or tool setter)").tag(ToolChangeMode.manualM6)
                    Text("By hand, pausing with M0").tag(ToolChangeMode.manualPause)
                    Text("Automatic tool changer").tag(ToolChangeMode.atc)
                }
                .pickerStyle(.radioGroup)
                if let line = machine.summary.dropFirst().first {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Spindle and dust collector") {
                Picker("Spindle", selection: $machine.spindle) {
                    ForEach(SpindleKind.allCases) { Text($0.label).tag($0) }
                }
                if machine.spindle == .vfdSpindle {
                    NumberField(title: "Min RPM", value: $machine.minRPM, decimals: 0, range: 0...60000)
                    NumberField(title: "Max RPM", value: $machine.maxRPM, decimals: 0, range: 0...60000)
                }
                Toggle("Dust collector on an output (M\(Dialect.for(machine)?.dustOn ?? 8))", isOn: $machine.dustCollection)
            }
            if machine.model == .custom {
                Section("Travel") {
                    LengthField(title: "X travel", mm: $machine.travel.x, units: units, minimum: 10)
                    LengthField(title: "Y travel", mm: $machine.travel.y, units: units, minimum: 10)
                    LengthField(title: "Z travel", mm: $machine.travel.z, units: units, minimum: 10)
                }
            }
            Section {
                MachineImportButtons(machine: $machine, units: units)
            } header: {
                Text("Run-time estimates")
            } footer: {
                Text("Speeds and accelerations come from the maker where published and are estimates otherwise. Import your controller's settings for real numbers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Step 4: summary

    private var summaryStep: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            }
            Section("What NativeCAM will write") {
                ForEach(machine.summary, id: \.self) { line in
                    Label { Text(line).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "checkmark.circle") }
                }
            }
            Section {
                ScrollView(.vertical) {
                    Text(preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
                Button("Save Acceptance Test…") { saveAcceptance() }
                    .disabled(PostProcessors.post(for: Project(machine: machine)) == nil)
            } header: {
                Text("Acceptance test program")
            } footer: {
                Text("A short program with a square, circles from 1 to 50 mm, a helix, a dwell and two tool changes. Run it in check mode if your controller has one, then as an air cut, then 0.5 mm deep in scrap.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Use for new documents", isOn: $useForNew)
                if offerUseHere { Toggle("Use in this document", isOn: $useHere) }
            }
        }
        .formStyle(.grouped)
    }

    private var preview: String {
        let (p, toolpaths) = AcceptanceTest.job(machine: machine)
        guard let post = PostProcessors.post(for: p) else { return machine.summary.first ?? "" }
        let text = post.files(toolpaths).first?.gcode ?? ""
        return text.components(separatedBy: .newlines).prefix(40).joined(separator: "\n")
    }

    private func saveAcceptance() {
        let (p, toolpaths) = AcceptanceTest.job(machine: machine)
        guard let post = PostProcessors.post(for: p) else { return }
        let files = post.files(toolpaths)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: post.fileExtension, conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = "NativeCAM acceptance test.\(post.fileExtension)"
        if files.count > 1 { panel.message = "Saves \(files.count) files, one per tool, named after this one." }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stem = url.deletingPathExtension().lastPathComponent
        for file in files {
            let target = files.count == 1 ? url : url.deletingLastPathComponent().appendingPathComponent(stem + (file.suffix ?? "") + "." + post.fileExtension)
            try? file.gcode.data(using: .ascii, allowLossyConversion: true)?.write(to: target)
        }
    }

    // MARK: Navigation

    private func next() {
        switch step {
        case .machine:
            if let entry {
                machine = entry.profile()
                name = entry.displayName
            } else {
                var m = MachineProfile(model: .custom)
                if selection == "imported", let imported {
                    imported.apply(to: &m, keys: Set(imported.settings.map(\.key)))
                    name = imported.machineName ?? "My machine"
                } else {
                    name = "My machine"
                }
                machine = m
            }
            controllerIndex = options.firstIndex { $0.isDefault == true } ?? 0
            if let c = machine.controller, let i = options.firstIndex(where: { $0.family == c.family.rawValue }) { controllerIndex = i }
            sender = SenderChoice(named: machine.controller?.sender)
            applyController()
        case .controller, .setup, .summary:
            break
        }
        step = Step(rawValue: min(step.rawValue + 1, Step.summary.rawValue))!
    }

    private func finish() {
        let id = entry?.id ?? (selection == "imported" ? "imported-" : "custom-") + UUID().uuidString.lowercased()
        let setup = MachineSetup(id: id, name: name.trimmingCharacters(in: .whitespaces), profile: machine)
        onFinish(setup, useForNew, offerUseHere && useHere)
        dismiss()
    }
}

/// The program that streams files to a Grbl controller, which decides what M6 does.
enum SenderChoice: String, CaseIterable, Identifiable {
    case gSender, cncjs, ugs, easel, notSure
    var id: String { rawValue }

    init(named name: String?) {
        let n = name?.lowercased() ?? ""
        self = n.contains("gsender") ? .gSender : n.contains("cncjs") ? .cncjs : n.contains("ugs") || n.contains("universal") ? .ugs
            : n.contains("easel") ? .easel : .notSure
    }

    var label: String {
        switch self {
        case .gSender: "gSender"
        case .cncjs: "CNCjs"
        case .ugs: "Universal G-code Sender"
        case .easel: "Easel"
        case .notSure: "Another program, or not sure"
        }
    }

    /// The name stored with the controller; nil when M6 can't be relied on.
    var senderName: String? {
        switch self {
        case .gSender: "gSender"
        case .cncjs: "CNCjs"
        case .ugs: "UGS"
        case .easel: "Easel"
        case .notSure: nil
        }
    }

    var detail: String {
        switch self {
        case .gSender: "gSender can pause on M6: set Config ▸ Tool Changing to Pause (or a probing wizard), then NativeCAM writes T# M6 and keeps a job in one file."
        case .cncjs: "CNCjs 1.9.11 and later pause on M6 and run a tool-change macro, so NativeCAM writes T# M6."
        case .ugs: "Grbl rejects M6 and keeps running, so NativeCAM saves a file per tool instead."
        case .easel: "Easel runs one tool per file, so NativeCAM saves a file per tool."
        case .notSure: "Grbl rejects M6 and keeps running the lines after it, so NativeCAM saves a file per tool. Change the bit and re-zero Z between files."
        }
    }
}
