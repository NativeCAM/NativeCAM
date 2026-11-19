import Foundation

/// Turns toolpaths into a controller's G-code. Each controller dialect gets its own compiled, tested emitter;
/// `PostProcessors.post(for:)` picks the one for a project's machine.
public protocol PostProcessor: Sendable {
    /// Shown when exporting, e.g. "Avid CNC Mach4".
    var name: String { get }
    /// File extension without the dot.
    var fileExtension: String { get }
    /// The controller dialect the post writes, which `GCodeCheck` reads the file back against.
    var dialect: Dialect { get }
    func post(_ toolpaths: [Toolpath]) -> String
    /// The files to save for a job. One, unless the controller can't stop for a tool change, in which case each
    /// tool gets its own complete program.
    func files(_ toolpaths: [Toolpath]) -> [PostedFile]
}

/// One file of an export.
public struct PostedFile: Sendable {
    /// Added to the file name when a job is split, e.g. " 2 of 3 - T5"; nil for a single file.
    public var suffix: String?
    /// The toolpaths this file cuts, for checking it.
    public var toolpaths: [Toolpath]
    public var gcode: String

    public init(suffix: String?, toolpaths: [Toolpath], gcode: String) {
        self.suffix = suffix
        self.toolpaths = toolpaths
        self.gcode = gcode
    }
}

public extension PostProcessor {
    func files(_ toolpaths: [Toolpath]) -> [PostedFile] {
        [PostedFile(suffix: nil, toolpaths: toolpaths, gcode: post(toolpaths))]
    }
}

extension AvidMach4Post: PostProcessor {
    public var name: String { "Avid CNC Mach4" }
    public var fileExtension: String { AvidMach4Post.fileExtension }
    public var dialect: Dialect { .avidMach4 }
}

public enum PostProcessors {
    /// The post for the project's machine, or nil when NativeCAM can't write that controller's G-code yet.
    /// Avid's Mach4 profile (no controller set) always gets `AvidMach4Post`, unchanged; the Grbl family gets
    /// `GenericGCodePost` with its dialect.
    public static func post(for project: Project, date: Date = Date()) -> (any PostProcessor)? {
        if let pp = project.machine.customPost { return VectricTemplatePost(project: project, pp: pp, date: date) }
        if project.machine.isLegacyAvidMach4 { return AvidMach4Post(project: project, date: date) }
        guard let dialect = Dialect.for(project.machine) else { return nil }
        if dialect.language == .openSBP { return OpenSBPPost(project: project, date: date) }
        return GenericGCodePost(project: project, dialect: dialect, date: date)
    }

    /// Why `post(for:)` has nothing for this machine; nil when it has a post.
    public static func unavailableReason(for machine: MachineProfile) -> String? {
        guard Dialect.for(machine) == nil else { return nil }
        return "NativeCAM can't write G-code for \(machine.controllerLabel) yet, so this job can't be exported. "
            + "Supported so far: Avid's Mach4 profile, Grbl, grblHAL, FluidNC, Carbide Motion, LinuxCNC, Masso, Centroid CNC12, "
            + "Buildbotics, ShopBot (OpenSBP) and RichAuto, or your own Vectric post."
    }
}
