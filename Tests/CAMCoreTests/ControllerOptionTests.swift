import Foundation
import Testing
@testable import CAMCore

/// #207: the command line's `--controller` (on `acceptance`, `calibrate` and `surface`, through
/// `MachineProfile.onController`). `mach4` is Avid's Mach4 profile: it keeps the machine's model and writes exactly what
/// leaving the option out writes, even over a project on another controller. Any other family sets the model to Custom.
/// The projects are in `Fixtures/controller-option` (see its README).
struct ControllerOptionTests {
    static let fixtures = GoldenPostTests.fixtures.appendingPathComponent("controller-option")

    static func grblProject() throws -> Project {
        try Project.decode(Data(contentsOf: fixtures.appendingPathComponent("grbl-machine.nativecam")))
    }

    static func pro4896Project() throws -> Project {
        try Project.decode(Data(contentsOf: fixtures.appendingPathComponent("pro4896-machine.nativecam")))
    }

    // MARK: The machine

    @Test func mach4IsAvidsMach4ProfileAndKeepsTheModel() throws {
        // The default machine: unchanged.
        #expect(MachineProfile().onController("mach4") == MachineProfile())

        // An Avid PRO4896: still a PRO4896, on Avid's Mach4 profile.
        let pro4896 = try Self.pro4896Project().machine
        #expect(pro4896.model == .pro4896)
        let kept = pro4896.onController("mach4", sender: "gSender")
        #expect(kept == pro4896)
        #expect(kept.controller == nil)

        // A project on Grbl: back to Avid's Mach4 profile, with its own model and travel.
        let grbl = try Self.grblProject().machine
        #expect(grbl.controller?.family == .grbl)
        let mach4 = grbl.onController("mach4")
        #expect(mach4.controller == nil)
        #expect(mach4.isLegacyAvidMach4)
        #expect(mach4.model == grbl.model)
        #expect(mach4.travel == grbl.travel)
        #expect(mach4.controllerLabel == "Avid Mach4")
    }

    @Test func otherFamiliesSetTheModelToCustom() throws {
        let grbl = MachineProfile().onController("grbl", sender: "gSender")
        #expect(grbl.model == .custom)
        #expect(grbl.controller == ControllerProfile(family: .grbl, sender: "gSender"))
        #expect(grbl.travel == MachineProfile().travel)

        // Families without a post are still refused, with the documented message.
        let mach3 = MachineProfile().onController("mach3")
        #expect(mach3.controller?.family == .mach3)
        #expect(mach3.model == .custom)
        let reason = try #require(PostProcessors.unavailableReason(for: mach3))
        #expect(reason.hasPrefix("NativeCAM can't write G-code for Mach3 yet"))

        // `mach4` is a ControllerFamily raw value, so a misspelling isn't taken for it.
        #expect(MachineProfile().onController("Mach4").controller?.family == .unknown("Mach4"))
    }

    /// `acceptance --controller mach4` posts the Avid Mach4 acceptance program byte for byte (the existing golden), on the
    /// default machine and over a project on Grbl.
    @Test func mach4PostsTheAvidMach4AcceptanceProgram() throws {
        let golden = try Data(contentsOf: GoldenPostTests.goldens.appendingPathComponent("acceptance-avid.tap"))
        let (project, toolpaths) = AcceptanceTest.job(machine: MachineProfile().onController("mach4"))
        var post = try #require(PostProcessors.post(for: project, date: GoldenPostTests.date) as? AvidMach4Post)
        post.timeZone = TimeZone(identifier: "UTC")!
        #expect(Data(post.post(toolpaths).utf8) == golden)

        let (fromGrbl, grblToolpaths) = AcceptanceTest.job(machine: try Self.grblProject().machine.onController("mach4"))
        let grblPost = try #require(PostProcessors.post(for: fromGrbl, date: GoldenPostTests.date))
        #expect(grblPost is AvidMach4Post)
        #expect(grblPost.name == "Avid CNC Mach4")
        #expect(PostProcessors.unavailableReason(for: fromGrbl.machine) == nil)
        #expect(!grblToolpaths.isEmpty)
    }

    /// Writes the project fixtures when goldens are being updated.
    @Test func projectFixtures() throws {
        guard GoldenPostTests.updating else { return }
        try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        var grbl = Project(name: "Grbl machine via gSender")
        grbl.machine = MachineProfile(model: .custom, travel: Vec3(30.inch, 30.inch, 4.inch), outputUnits: .mm)
        grbl.machine.controller = ControllerProfile(family: .grbl, sender: "gSender")
        try grbl.encoded().write(to: Self.fixtures.appendingPathComponent("grbl-machine.nativecam"))
        var pro4896 = Project(name: "Avid PRO4896 on Mach4")
        pro4896.machine = MachineProfile(model: .pro4896)
        try pro4896.encoded().write(to: Self.fixtures.appendingPathComponent("pro4896-machine.nativecam"))
    }
}

/// `--controller mach4` on the command line, run as a user runs it: the same files as leaving it out, for every command
/// that takes `--controller`.
struct ControllerOptionCommandLineTests {
    /// The file without its "(Created: …)" line, which carries the minute it was written.
    static func undated(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .ascii).components(separatedBy: "\n").filter { !$0.hasPrefix("(Created: ") }
            .joined(separator: "\n")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func mach4WritesWhatLeavingItOutWrites() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let commands: [(name: String, args: [String], printed: String)] = [
            ("acceptance", ["acceptance"], "Avid CNC Mach4 acceptance test -> "),
            ("timing", ["calibrate", "timing"], "Avid Mach4 timing suite -> "),
            ("rotary", ["calibrate", "rotary"], "Avid Mach4 rotary check -> "),
            ("ladder", ["calibrate", "ladder", "--rungs", "3"], "Avid Mach4 chip-load ladder -> "),
            ("surface", ["surface", "--area", "12x12"], "Avid Mach4 spoilboard surfacing -> "),
        ]
        var outputs: [(String, Int32, String)] = []
        var mismatched: [String] = []
        for c in commands {
            let plain = try CommandLineTests.run(c.args + ["-o", dir.appendingPathComponent(c.name + "-plain").path])
            let mach4 = try CommandLineTests.run(c.args + ["--controller", "mach4", "-o", dir.appendingPathComponent(c.name + "-mach4").path])
            outputs.append((c.name + " plain", plain.status, plain.output))
            outputs.append((c.name + " mach4", mach4.status, mach4.output))
            let a = dir.appendingPathComponent(c.name + "-plain.tap"), b = dir.appendingPathComponent(c.name + "-mach4.tap")
            var same = false
            if FileManager.default.fileExists(atPath: b.path) { same = try Self.undated(a) == Self.undated(b) }
            if !same { mismatched.append(c.name) }
        }
        for (name, status, output) in outputs {
            #expect(status == 0, "\(name): \(output)")
            #expect(!output.contains("can't write G-code for Mach4"), "\(name): \(output)")
        }
        for (c, i) in zip(commands, stride(from: 1, to: outputs.count, by: 2)) {
            #expect(outputs[i].2.contains(c.printed), "\(c.name): \(outputs[i].2)")
        }
        #expect(mismatched.isEmpty, "--controller mach4 wrote a different file for \(mismatched)")
        let header = try String(contentsOf: dir.appendingPathComponent("acceptance-mach4.tap"), encoding: .ascii)
        #expect(header.contains("(Machine: PRO6060 {5 x 5 ft}"), "the model is kept")
    }

    /// Over a project on Grbl, `--controller mach4` writes the Avid Mach4 program; over an Avid PRO4896 it keeps the model.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)))
    func mach4OverAProjectsController() throws {
        let dir = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let grbl = ControllerOptionTests.fixtures.appendingPathComponent("grbl-machine.nativecam").path
        let onGrbl = try CommandLineTests.run(["acceptance", grbl, "-o", dir.appendingPathComponent("grbl").path])
        #expect(onGrbl.status == 0, "\(onGrbl.output)")
        #expect(onGrbl.output.contains("Grbl via gSender acceptance test -> "), "\(onGrbl.output)")
        let onMach4 = try CommandLineTests.run(["acceptance", grbl, "--controller", "mach4", "-o", dir.appendingPathComponent("mach4").path])
        #expect(onMach4.status == 0, "\(onMach4.output)")
        #expect(onMach4.output.contains("Avid CNC Mach4 acceptance test -> "), "\(onMach4.output)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mach4.tap").path))

        let pro4896 = ControllerOptionTests.fixtures.appendingPathComponent("pro4896-machine.nativecam").path
        let kept = try CommandLineTests.run(["acceptance", pro4896, "--controller", "mach4", "-o", dir.appendingPathComponent("pro4896").path])
        #expect(kept.status == 0, "\(kept.output)")
        let text = try String(contentsOf: dir.appendingPathComponent("pro4896.tap"), encoding: .ascii)
        #expect(text.contains("(Machine: PRO4896 {4 x 8 ft}"), "\(text.prefix(300))")

        // A family with no post is still refused, and writes nothing.
        let mach3 = try CommandLineTests.run(["acceptance", "--controller", "mach3", "-o", dir.appendingPathComponent("mach3").path])
        #expect(mach3.status == 1)
        #expect(mach3.output.contains("NativeCAM can't write G-code for Mach3 yet"), "\(mach3.output)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mach3.tap").path))
    }
}
