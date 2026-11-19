import CAMCore
import SwiftUI

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
                        .help("Estimated at programmed feeds; real time is longer because of acceleration")
                    let errors = job.issues.filter { $0.severity == .error }.count
                    let warnings = job.issues.filter { $0.severity == .warning }.count
                    if errors > 0 { Label("\(errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    if warnings > 0 { Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                } else {
                    Text("Calculating…").foregroundStyle(.secondary)
                }
                Spacer()
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
