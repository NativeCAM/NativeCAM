import CAMCore
import SwiftUI

/// Explains what the estimate includes.
func estimateHelp(_ job: JobResult) -> String {
    guard let e = job.estimate else { return "Estimated at programmed feeds" }
    return "Includes acceleration, corners and tool changes: cutting \(formatDuration(e.feedSeconds)), rapids \(formatDuration(e.rapidSeconds)), "
        + "tool changes and pauses \(formatDuration(e.overheadSeconds)). Distance ÷ feed alone would say \(formatDuration(e.constantVelocity)). "
        + "Set acceleration and tool-change time in Machine settings to match your Mach4 configuration."
}

/// Bottom bar: job summary when idle; play / scrub / speed controls while simulating.
struct SimulationBar: View {
    @Bindable var workspace: Workspace
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            if workspace.isSimulating {
                Button { workspace.isPlaying.toggle() } label: {
                    Image(systemName: workspace.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")
                Button { workspace.isPlaying = false; workspace.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Back to start")
                Button { workspace.jumpToEnd() } label: { Image(systemName: "forward.end.fill") }
                    .help("Show the finished part")
                Slider(value: Binding(get: { workspace.simTime }, set: { workspace.seek(to: $0) }),
                       in: 0...max(workspace.simDuration, 0.001))
                    .frame(minWidth: 200)
                Text("\(formatDuration(workspace.simTime)) / \(formatDuration(workspace.simDuration))")
                    .monospacedDigit().font(.callout)
                Picker("Speed", selection: $workspace.playbackSpeed) {
                    ForEach([1.0, 5, 20, 50, 200, 1000], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .labelsHidden().frame(width: 80)
                if let count = workspace.tileCount {
                    Menu {
                        ForEach(0..<count, id: \.self) { k in
                            Button("Start of Tile \(k + 1)") { workspace.seek(toTile: k) }
                        }
                        Divider()
                        Button("All Tiles Cut") { workspace.seek(toTile: count) }
                    } label: {
                        Label("Tiles", systemImage: "square.split.2x1")
                    }
                    .fixedSize()
                    .help("The simulation cuts the tiles one after another with the material in place; jump to any tile")
                }
                if project.sheetCount > 1 && workspace.externalProgramName == nil {
                    SheetStepper(workspace: workspace, project: project)
                        .help("The simulation cuts one sheet at a time; step through the sheets")
                }
                if let tool = workspace.simTool {
                    Text(tool.toolpathName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let name = workspace.externalProgramName {
                    Label(name, systemImage: "doc.text").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if workspace.rapidCollisionCount > 0 {
                    Label("Rapid through material", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout)
                }
                Spacer(minLength: 0)
                Button("Done") { workspace.stopSimulation(project) }
            } else {
                if let job = workspace.job {
                    let tools = Set(job.toolpaths.map(\.tool.number)).count
                    Label("\(job.toolpaths.count) toolpath\(job.toolpaths.count == 1 ? "" : "s"), \(tools) tool\(tools == 1 ? "" : "s")",
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label("≈ \(formatDuration(workspace.estimatedSeconds(project)))", systemImage: "clock")
                        .help(estimateHelp(job))
                    let errors = job.issues.filter { $0.severity == .error }.count
                    let warnings = job.issues.filter { $0.severity == .warning }.count
                    if errors > 0 { Label("\(errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                } else {
                    Text("Calculating…").foregroundStyle(.secondary)
                }
                Spacer()
                if project.sheetCount > 1 {
                    SheetStepper(workspace: workspace, project: project)
                        .help("This job is nested onto \(project.sheetCount) sheets, cut one after another; show another")
                }
                Button { workspace.startSimulation(project) } label: { Label("Simulate", systemImage: "play.circle.fill") }
                    .disabled(workspace.job?.toolpaths.isEmpty ?? true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// On a job nested onto several sheets: which sheet the canvas and the simulation show, with buttons to step through.
struct SheetStepper: View {
    @Bindable var workspace: Workspace
    let project: Project

    var body: some View {
        let count = project.sheetCount, k = min(workspace.sheet, count - 1)
        HStack(spacing: 4) {
            Button { workspace.show(sheet: k - 1, project: project) } label: { Image(systemName: "chevron.left") }
                .disabled(k == 0)
                .accessibilityLabel("Previous sheet")
            Menu {
                ForEach(0..<count, id: \.self) { i in
                    let size = project.sheetSize(i)
                    Button("Sheet \(i + 1), \(dimension(size.x)) × \(dimension(size.y)) \(project.displayUnits.symbol)") {
                        workspace.show(sheet: i, project: project)
                    }
                }
            } label: {
                Label("Sheet \(k + 1) of \(count)", systemImage: "square.stack")
                    .monospacedDigit()
            }
            .fixedSize()
            Button { workspace.show(sheet: k + 1, project: project) } label: { Image(systemName: "chevron.right") }
                .disabled(k >= count - 1)
                .accessibilityLabel("Next sheet")
        }
        .buttonStyle(.borderless)
    }

    private func dimension(_ mm: Double) -> String {
        let u = project.displayUnits
        return u.fromMM(mm).formatted(.number.precision(.fractionLength(0...(u == .inch ? 3 : 1))).grouping(.never))
    }
}
