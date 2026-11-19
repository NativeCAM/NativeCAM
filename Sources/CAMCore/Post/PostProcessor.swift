import Foundation

/// Turns toolpaths into a controller's G-code. Each controller dialect gets its own compiled, tested emitter;
/// `PostProcessors.post(for:)` picks the one for a project's machine.
public protocol PostProcessor: Sendable {
    /// Shown when exporting, e.g. "Avid CNC Mach4".
    var name: String { get }
    /// File extension without the dot.
    var fileExtension: String { get }
    func post(_ toolpaths: [Toolpath]) -> String
}

extension AvidMach4Post: PostProcessor {
    public var name: String { "Avid CNC Mach4" }
    public var fileExtension: String { AvidMach4Post.fileExtension }
}

public enum PostProcessors {
    /// The post for the project's machine, or nil when NativeCAM can't write that controller's G-code yet.
    /// Avid's Mach4 profile (no controller set) always gets `AvidMach4Post`, unchanged.
    public static func post(for project: Project, date: Date = Date()) -> (any PostProcessor)? {
        guard project.machine.isLegacyAvidMach4 else { return nil }
        return AvidMach4Post(project: project, date: date)
    }

    /// Why `post(for:)` has nothing for this machine; nil when it has a post.
    public static func unavailableReason(for machine: MachineProfile) -> String? {
        guard !machine.isLegacyAvidMach4 else { return nil }
        return "NativeCAM can't write G-code for \(machine.controllerLabel) yet, so this job can't be exported. "
            + "Avid's Mach4 profile is the only controller supported so far."
    }
}
