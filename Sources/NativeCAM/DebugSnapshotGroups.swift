import AppKit
import CAMCore
import SwiftUI

extension DebugSnapshot {
    /// Toolpath groups and hiding (#174), on a project that has them: logs the sidebar's run-order rows as drawn (each
    /// group's state and each toolpath's group, hidden and included), what Optimize Run Order finds across groups, and
    /// each group's export (Export Group…) with its header and checks, checking that it holds exactly the full job's
    /// toolpaths for the group and that hidden toolpaths are still in the full export. Draws each group's inspector
    /// (`inspector-group-<n>.png`).
    @MainActor
    static func groupsCheck(_ project: Project, workspace ws: Workspace, out: URL, log: (String) -> Void, spin: (Double) -> Void) {
        let hidden = project.operations.filter(\.isHidden)
        guard !project.toolpathGroups.isEmpty || !hidden.isEmpty else { return }
        func check(_ name: String, _ ok: Bool) { log("check \(ok ? "PASS" : "FAIL"): \(name)") }
        for row in project.runOrderRows() {
            switch row {
            case let .group(g):
                guard let group = project.toolpathGroup(id: g) else { continue }
                let members = project.members(ofGroup: g)
                log("groups row: group “\(group.name)” \(group.collapsed ? "folded" : "open"), \(members.count) toolpaths, "
                    + "include \(project.inclusion(ofGroup: g)), \(members.filter(\.isHidden).count) hidden")
            case let .operation(id):
                guard let op = project.operations.first(where: { $0.id == id }) else { continue }
                let group = op.groupID.flatMap { project.toolpathGroup(id: $0)?.name }
                log("groups row: toolpath “\(op.name)”\(group.map { " in “\($0)”" } ?? ""), "
                    + "\(op.enabled ? "included" : "not included")\(op.isHidden ? ", hidden" : "")")
            }
        }
        let order = OperationScheduler.optimize(project)
        for late in order.crossGroup {
            let a = project.operations.first { $0.id == late.operation }?.name ?? "?"
            let b = project.operations.first { $0.id == late.mustPrecede }?.name ?? "?"
            log("groups optimize: “\(a)” has to run before “\(b)”, in a group that runs earlier")
        }
        let kept = project.toolpathGroups.allSatisfy { g in
            let at = order.order.enumerated().filter { i in project.operations.first { $0.id == i.element }?.groupID == g.id }.map(\.offset)
            return at.isEmpty || at.last! - at.first! == at.count - 1
        }
        check("Optimize Run Order keeps every group in one piece", kept)
        guard let job = ws.job else { return log("groups: no job") }
        if !hidden.isEmpty, let full = JobExport.files(project, job: job) {
            let exported = Set(full.files.flatMap(\.toolpaths).map(\.sourceOperationID))
            check("hidden toolpaths are still exported", hidden.filter(\.enabled).allSatisfy { exported.contains($0.id) })
        }
        for (i, group) in project.toolpathGroups.enumerated() {
            guard let request = JobSubset.Request.group(group.id, in: project) else { continue }
            do {
                let subset = try JobSubset.make(project, job: job, request: request)
                log("groups export “\(group.name)”: " + subset.header.joined(separator: " | "))
                for issue in subset.issues where issue.severity != .info { log("groups export “\(group.name)” \(issue.severity.rawValue): \(issue.text)") }
                let ids = Set(subset.included.map(\.id))
                let expected = job.toolpaths.filter { ids.contains($0.sourceOperationID) && !$0.isEmpty }.map(\.motions)
                check("export of “\(group.name)” cuts the full job's toolpaths for it", subset.job.toolpaths.filter { !$0.isEmpty }.map(\.motions) == expected)
            } catch {
                log("groups export “\(group.name)” refused: \(error.localizedDescription)")
            }
            render(GroupInspector(project: .constant(project), workspace: ws, group: group.id), size: NSSize(width: 440, height: 900),
                   out: out, name: "inspector-group-\(i).png", spin: spin)
        }
    }
}
