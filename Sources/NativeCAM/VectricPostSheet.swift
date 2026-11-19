import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

/// Controls in the G-code Output section for using an imported Vectric post in place of NativeCAM's own.
struct VectricPostControls: View {
    @Binding var machine: MachineProfile
    @State private var pending: PendingPost?
    @State private var error: String?

    struct PendingPost: Identifiable {
        let id = UUID()
        var pp: VectricPost
    }

    var body: some View {
        Group {
            if let pp = machine.customPost {
                LabeledContent("Post") {
                    HStack {
                        Text(pp.name.isEmpty ? "Imported Vectric post" : pp.name).lineLimit(1).truncationMode(.middle)
                        Button("Details…") { pending = PendingPost(pp: pp) }.controlSize(.small)
                        Button("Stop Using") { machine.customPost = nil }.controlSize(.small)
                    }
                }
            } else {
                LabeledContent("Post") {
                    HStack {
                        Text(machine.postLabel).foregroundStyle(.secondary)
                        Button("Use a Vectric Post…") { choose() }
                            .controlSize(.small)
                            .help("Write this machine's G-code with your own Vectric .pp file, for controllers NativeCAM has no post for")
                    }
                }
            }
        }
        .sheet(item: $pending) { p in
            VectricPostSheet(pp: p.pp, machine: machine, applied: machine.customPost == p.pp) { pp in
                machine.customPost = pp
                machine.outputUnits = pp.units
            }
        }
        .alert("Can't use this post", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pp") ?? .plainText, .plainText]
        panel.message = "Choose your Vectric post processor (.pp). NativeCAM keeps a copy in the project and never shares it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                error = "The file can't be read as text."
                return
            }
            pending = PendingPost(pp: try VectricPost.parse(text))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What an imported post does, what NativeCAM ignores in it, and how its output compares with NativeCAM's own post
/// on the acceptance test program.
struct VectricPostSheet: View {
    let pp: VectricPost
    let machine: MachineProfile
    let applied: Bool
    let apply: (VectricPost) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pp.name.isEmpty ? "Imported Vectric post" : pp.name).font(.headline)
            Form {
                Section("What it writes") {
                    Text("\(pp.units == .inch ? "Inches" : "Millimetres"), .\(pp.fileExtension) files, \(pp.lineEnding == "\r\n" ? "CRLF" : "LF") line endings.")
                    Text(pp.usesArcs ? "Arcs as \(pp.usesAbsoluteArcCentres ? "absolute" : "incremental") I/J." : "No arc blocks: arcs are written as short lines.")
                    Text(pp.changesTools ? "Tool changes with its TOOLCHANGE block." : "No tool-change block: a job with several tools is saved as one file per tool.")
                    if !pp.writesGCode {
                        Text("It doesn't write G-code NativeCAM can read back, so exported files can't be checked. Air-cut them first.")
                            .foregroundStyle(.orange)
                    }
                }
                Section("Compared with NativeCAM's post") { comparisonView }
                let ignored = pp.report.filter { $0.status == .ignored }
                if !ignored.isEmpty {
                    Section("Ignored") {
                        ForEach(ignored, id: \.item) { item in
                            LabeledContent(item.item) { Text(item.note).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    Text("NativeCAM runs this post as a template and checks every file it writes. The project keeps its own copy of the post; NativeCAM never shares or bundles it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                if applied {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Use This Post") { apply(pp); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }

    @ViewBuilder private var comparisonView: some View {
        var base = machine
        let _ = (base.customPost = nil)
        let (project, toolpaths) = AcceptanceTest.job(machine: base)
        if let builtIn = PostProcessors.post(for: project, date: Date(timeIntervalSince1970: 0)) {
            var withPost = project
            let _ = (withPost.machine.customPost = pp)
            let imported = VectricTemplatePost(project: withPost, pp: pp, date: Date(timeIntervalSince1970: 0))
            let c = PostComparison.compare(imported: imported.files(toolpaths).map(\.gcode).joined(),
                                           builtIn: builtIn.files(toolpaths).map(\.gcode).joined(), units: pp.units)
            if c.sameMoves {
                Label("Same moves as NativeCAM's \(builtIn.name) post on the acceptance test.", systemImage: "checkmark.circle")
            } else {
                Label(c.firstDifference ?? "The moves differ.", systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            }
            if !c.onlyInImported.isEmpty {
                LabeledContent("Only this post writes") {
                    Text(c.onlyInImported.prefix(6).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).multilineTextAlignment(.trailing)
                }
            }
            if !c.onlyInBuiltIn.isEmpty {
                LabeledContent("Only NativeCAM's writes") {
                    Text(c.onlyInBuiltIn.prefix(6).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).multilineTextAlignment(.trailing)
                }
            }
        } else {
            Text("NativeCAM has no post of its own for \(machine.controllerLabel) to compare with.").foregroundStyle(.secondary)
        }
    }
}
