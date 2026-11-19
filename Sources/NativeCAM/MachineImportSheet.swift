import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

/// A machine-settings import waiting for the user to pick what to apply.
struct PendingMachineImport: Identifiable {
    let id = UUID()
    var found: MachineImport
}

/// Buttons that read a controller's settings into a machine profile, for the Machine section of Job Setup and
/// Settings.
struct MachineImportButtons: View {
    @Binding var machine: MachineProfile
    let units: LengthUnit
    @State private var pending: PendingMachineImport?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var error: String?

    var body: some View {
        HStack {
            Button("Import Controller Settings…") { chooseFile() }
                .help("Read speeds, accelerations, travel and spindle range from Grbl $$ output, Mach4's Machine.ini, a LinuxCNC INI, a FluidNC config or a Fusion 360 machine")
            Button("Paste Grbl $$…") { pasted = ""; pasting = true }
                .help("Paste the output of $$ from your sender's console")
        }
        .sheet(item: $pending) { p in
            MachineImportSheet(found: p.found, machine: machine, units: units) { machine = $0 }
        }
        .sheet(isPresented: $pasting) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste Grbl Settings").font(.headline)
                Text("Send $$ in your sender's console, copy everything it prints, and paste it here.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $pasted)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .border(Color(nsColor: .separatorColor))
                HStack {
                    Spacer()
                    Button("Cancel") { pasting = false }.keyboardShortcut(.cancelAction)
                    Button("Read Settings") {
                        pasting = false
                        read { try MachineSettingsImporter.read(pasted) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .alert("Can't import these settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineSettingsImporter.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]
        panel.message = "Choose Grbl $$ output (.txt), Mach4's Machine.ini, a LinuxCNC .ini, a FluidNC config.yaml or a Fusion 360 .mch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read { try MachineSettingsImporter.load(url: url) }
    }

    private func read(_ load: () throws -> MachineImport) {
        do {
            pending = PendingMachineImport(found: try load())
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lists what an import found, next to the current values, for the user to pick from.
struct MachineImportSheet: View {
    let found: MachineImport
    let machine: MachineProfile
    let units: LengthUnit
    let apply: (MachineProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keys: Set<MachineImport.Key>
    @State private var useController = true
    @State private var useUnits = true
    @State private var useToolChanger = true

    init(found: MachineImport, machine: MachineProfile, units: LengthUnit, apply: @escaping (MachineProfile) -> Void) {
        self.found = found
        self.machine = machine
        self.units = units
        self.apply = apply
        _keys = State(initialValue: Set(found.settings.map(\.key)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from \(found.format.rawValue)").font(.headline)
                if let name = found.machineName { Text(name).foregroundStyle(.secondary) }
            }
            Form {
                Section("Values") {
                    ForEach(found.settings) { s in
                        Toggle(isOn: Binding(get: { keys.contains(s.key) }, set: { on in if on { keys.insert(s.key) } else { keys.remove(s.key) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(s.key.label)
                                    Spacer()
                                    Text(current(s)).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).imageScale(.small)
                                    Text(s.display(units)).monospacedDigit()
                                }
                                if let note = s.source.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if found.controller != nil || found.outputUnits != nil || found.hasToolChanger == true {
                    Section("Machine") {
                        if let c = found.controller, c != machine.controller {
                            Toggle("Controller: \(c.family.label) (now \(machine.controllerLabel))", isOn: $useController)
                        }
                        if let u = found.outputUnits, u != machine.outputUnits {
                            Toggle("G-code units: \(u == .inch ? "inches (G20)" : "millimetres (G21)")", isOn: $useUnits)
                        }
                        if found.hasToolChanger == true, machine.toolChange != .atc {
                            Toggle("Tool changer (ATC)", isOn: $useToolChanger)
                        }
                    }
                }
                if !found.notes.isEmpty {
                    Section("Notes") {
                        ForEach(found.notes, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    var m = machine
                    found.apply(to: &m, keys: keys, controller: useController, units: useUnits, toolChanger: useToolChanger)
                    apply(m)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func current(_ s: MachineImport.Setting) -> String {
        var probe = s
        probe.value = s.current(machine)
        return probe.display(units)
    }
}
