import Foundation
import Testing
@testable import CAMCore

/// #152: `nativecam-cli import`, `rebind`, `save` and `post/sim --rebind`, and the import they share with File ▸ Import
/// and snapshot mode (`Project.importFile(at:options:)`). Fixtures in `Fixtures/import` (the files imported) and
/// `Fixtures/projects/cli-*` (the projects imported into); the command line's output is compared with
/// `Fixtures/golden/cli-*.txt`, run from the fixtures folder so the paths in it are relative.
struct CLIImportTests {
    static let fixtures = GoldenPostTests.fixtures
    static let cliBuilt = FileManager.default.isExecutableFile(atPath: CommandLineTests.cli.path)

    static func file(_ name: String) -> URL { fixtures.appendingPathComponent("import/\(name)") }
    static func project(_ name: String) throws -> Project {
        try Project.decode(Data(contentsOf: fixtures.appendingPathComponent("projects/\(name).nativecam")))
    }

    /// A shape with its ID blanked, so two imports of the same file compare equal.
    static func blank(_ s: DesignShape) -> DesignShape {
        var s = s
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        s.id = zero
        if case var .model(spec) = s.kind {
            spec.mesh.id = zero
            s.kind = .model(spec)
        }
        return s
    }

    /// Each toolpath's shapes by name, which survive a save where IDs are compared across imports.
    static func bound(_ p: Project) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: p.operations.map { op in (op.name, op.shapeIDs.map { id in p.shape(id: id)?.name ?? "?" }) })
    }

    // MARK: Running the command line

    struct Transcript {
        var status: Int32
        var text: String
    }

    /// Runs the command line from the fixtures folder. `<out>` in an argument is a fresh folder, written as `<out>` in
    /// the transcript too.
    static func run(_ arguments: [String], out: URL) throws -> Transcript {
        let process = Process()
        process.executableURL = CommandLineTests.cli
        process.currentDirectoryURL = fixtures
        process.arguments = arguments.map { $0.replacingOccurrences(of: "<out>", with: out.path) }
        let o = Pipe(), e = Pipe()
        process.standardOutput = o
        process.standardError = e
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let text = "$ nativecam-cli \(arguments.joined(separator: " "))\n" + stdout + stderr + "exit \(process.terminationStatus)\n"
        return Transcript(status: process.terminationStatus, text: text.replacingOccurrences(of: out.path, with: "<out>"))
    }

    /// Compares text with `Fixtures/golden/<name>`; a mismatch leaves the new text in `.build/golden-actual`.
    static func checkText(_ text: String, golden name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = GoldenPostTests.goldens.appendingPathComponent(name)
        if GoldenPostTests.updating {
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try text.write(to: url, atomically: true, encoding: .utf8) }
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("No golden file \(name). Run with NATIVECAM_UPDATE_GOLDENS=1 to create it.", sourceLocation: sourceLocation)
            return
        }
        guard expected != text else { return }
        try FileManager.default.createDirectory(at: GoldenPostTests.actualOutput, withIntermediateDirectories: true)
        let saved = GoldenPostTests.actualOutput.appendingPathComponent(name)
        try text.write(to: saved, atomically: true, encoding: .utf8)
        Issue.record("\(name) changed. New output: \(saved.path)\n--- expected\n\(expected)--- got\n\(text)", sourceLocation: sourceLocation)
    }

    /// The file's G-code from the command line or the app, without its "Created:" date line.
    static func undated(_ gcode: String) -> String {
        gcode.components(separatedBy: "\n").filter { !$0.hasPrefix("(Created:") }.joined(separator: "\n")
    }

    /// The two-layer DXF and the points imported as File ▸ Import imports them, then bound as it binds them.
    static func appImport() throws -> Project {
        var p = try project("cli-import-target")
        for name in ["cli-two-layers-inch.dxf", "cli-points.dxf"] { try p.importFile(at: file(name)) }
        p.bindVectors()
        return p
    }

    // MARK: The shared import

    /// The shared import places a drawing as File ▸ Import did before it moved into CAMCore: one shape per layer, at
    /// the file's coordinates when it fits, else centred; and keeping the coordinates (the command line's default)
    /// gives the same shapes when it fits.
    @Test func sharedImportPlacesDrawingsAsFileImportDid() throws {
        let target = try Self.project("cli-import-target")
        for name in ["cli-two-layers-inch.dxf", "cli-points.dxf", "cli-mm-part.svg", "cli-off-material.dxf"] {
            let url = Self.file(name)
            let before = try VectorImporter.importFile(at: url, tolerance: 0.01)
                .shapes(name: url.deletingPathExtension().lastPathComponent, stock: target.stock)
            var app = target, kept = target
            let a = try app.importFile(at: url)
            let k = try kept.importFile(at: url, options: ImportOptions(unit: nil, placement: .keep))
            let appShapes = app.shapes.filter { a.shapeIDs.contains($0.id) }.map(Self.blank)
            #expect(appShapes == before.map(Self.blank), "\(name)")
            if name == "cli-off-material.dxf" {
                #expect(a.moved && a.fitsMaterial)
                #expect(!k.moved && !k.fitsMaterial)
            } else {
                #expect(!a.moved && a.fitsMaterial, "\(name)")
                #expect(kept.shapes.filter { k.shapeIDs.contains($0.id) }.map(Self.blank) == appShapes, "\(name)")
            }
        }
    }

    @Test func drawingsCanBeCentredOrPlaced() throws {
        let target = try Self.project("cli-import-target")
        var centred = target, placed = target
        let c = try centred.importFile(at: Self.file("cli-two-layers-inch.dxf"), options: ImportOptions(placement: .center))
        #expect(abs(c.placedBounds.center.x - target.stock.width / 2) < 1e-6 && abs(c.placedBounds.center.y - target.stock.height / 2) < 1e-6)
        let corner = Vec2(1.inch, (1.5).inch)
        let at = try placed.importFile(at: Self.file("cli-two-layers-inch.dxf"), options: ImportOptions(placement: .at(corner)))
        #expect((at.placedBounds.min - corner).length < 1e-6)
        #expect(abs(at.placedBounds.width - 6.inch) < 1e-6 && abs(at.placedBounds.height - 4.inch) < 1e-6)
    }

    /// A model is placed as File ▸ Import placed one (its code, before it moved into CAMCore), and never deeper than
    /// the material less 0.02 in, however thin the material.
    @Test func modelsArePlacedAsFileImportDidAndShallowerThanTheMaterial() throws {
        for thickness in [(0.75).inch, (0.25).inch, (0.05).inch] {
            var target = try Self.project("cli-import-target")
            target.stock.thickness = thickness
            for name in ["cli-cube-mm.stl", "cli-cube.3mf"] {
                let result = try ModelImporter.importFile(at: Self.file(name))
                // File ▸ Import's model placement as it was in the app.
                let spec = ModelSpec(mesh: result.mesh, upAxis: result.suggestedUpAxis, depth: 1)
                let scale = min(1, target.stock.width * 0.9 / spec.naturalSize.x, target.stock.height * 0.9 / spec.naturalSize.y)
                var p = target
                let file = try p.importFile(at: Self.file(name))
                let id = try #require(file.shapeIDs.first)
                let shape = try #require(p.shape(id: id))
                let model = try #require(shape.modelSpec)
                #expect(model.depth == max(0.1, min(spec.proportionalDepth(scale: scale), thickness - 0.02.inch)), "\(name)")
                #expect(model.depth <= thickness - 0.02.inch || model.depth == 0.1, "\(name)")
                #expect(shape.scale == scale && shape.position == Vec2(target.stock.width / 2, target.stock.height / 2))
                #expect(file.unit == .mm && file.unitSource == (name.hasSuffix("3mf") ? .file : .assumed))
            }
        }
        // An STL said to be in inches is 25.4 times the size.
        var p = try Self.project("cli-import-target")
        let file = try p.importFile(at: Self.file("cli-cube-mm.stl"), options: ImportOptions(unit: .inch))
        #expect(file.unit == .inch && file.unitSource == .given)
    }

    @Test func layerAndSheetOptions() throws {
        var p = try Self.project("cli-import-target")
        p.additionalSheets = [MaterialSheet(width: 300, height: 200)]
        let file = try p.importFile(at: Self.file("cli-off-material.dxf"), options: ImportOptions(layer: "Pocket", sheet: 1))
        let shapes = p.shapes.filter { file.shapeIDs.contains($0.id) }
        #expect(shapes.allSatisfy { $0.layer == "Pocket" && $0.sheet == 1 })
        // Centred on the second sheet, the one it went on.
        #expect(file.sheet == 1 && file.moved)
        #expect((file.placedBounds.center - Vec2(150, 100)).length < 1e-6)
        // A sheet past the last counts as the last.
        let past = try p.importFile(at: Self.file("cli-points.dxf"), options: ImportOptions(sheet: 7))
        #expect(past.sheet == 1)
        // --layer moves vector shapes only: a 3D model keeps its layer, so a profile on the layer doesn't pick it up.
        let model = try p.importFile(at: Self.file("cli-cube.3mf"), options: ImportOptions(layer: "Pocket"))
        #expect(p.shapes.filter { model.shapeIDs.contains($0.id) }.map(\.layer) == ["Default"])
    }

    @Test func unitsAreReportedAndGiven() throws {
        var p = try Self.project("cli-import-target")
        let inch = try p.importFile(at: Self.file("cli-two-layers-inch.dxf"))
        #expect(inch.unit == .inch && inch.unitSource == .file)
        let assumed = try p.importFile(at: Self.file("cli-no-units.dxf"))
        #expect(assumed.unit == .inch && assumed.unitSource == .assumed)
        let mm = try p.importFile(at: Self.file("cli-no-units.dxf"), options: ImportOptions(unit: .mm))
        #expect(mm.unit == .mm && mm.unitSource == .given)
        #expect(abs(assumed.placedBounds.width / mm.placedBounds.width - 25.4) < 1e-6)
        // A DXF that states its unit keeps it, whatever it's told.
        let stated = try p.importFile(at: Self.file("cli-two-layers-inch.dxf"), options: ImportOptions(unit: .mm))
        #expect(stated.unit == .inch && stated.unitSource == .file)
        let svg = try p.importFile(at: Self.file("cli-mm-part.svg"))
        #expect(svg.unit == .mm && svg.unitSource == .file && abs(svg.placedBounds.width - 80) < 1e-6)
    }

    /// `bindVectorChanges()` says which toolpaths' vectors changed and how; `bindVectors()` agrees, and toolpaths whose
    /// vectors were chosen by hand keep theirs.
    @Test func bindVectorChangesSaysWhatChanged() throws {
        let unbound = try Self.project("cli-unbound")
        var p = unbound, q = unbound
        let changes = p.bindVectorChanges()
        let changed = q.bindVectors()
        #expect(changed)
        #expect(p == q)
        #expect(changes.map(\.name) == ["Pocket", "Drill holes", "Cut out part"])
        let cut = try #require(changes.last)
        #expect(cut.rule == .layers(["Profile"]))
        #expect(cut.oldShapeIDs.map { unbound.shape(id: $0)?.name } == ["cli-two-layers-inch – Pocket"])
        #expect(cut.newShapeIDs.map { p.shape(id: $0)?.name } == ["cli-two-layers-inch – Profile"])
        let hand = try #require(unbound.operations.first { $0.name == "Hand-picked V-carve" })
        #expect(p.operations.first { $0.name == "Hand-picked V-carve" }?.shapeIDs == hand.shapeIDs)
        // Bound, nothing more changes.
        let more = p.bindVectorChanges()
        let changedAgain = p.bindVectors()
        #expect(more.isEmpty && !changedAgain)
    }

    // MARK: The command line

    /// The command line's import gives the shapes and bindings File ▸ Import gives (through the shared function).
    @Test(.enabled(if: cliBuilt)) func cliImportMatchesTheApp() throws {
        let out = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let files = ["import/cli-two-layers-inch.dxf", "import/cli-points.dxf", "import/cli-mm-part.svg", "import/cli-cube-mm.stl",
                     "import/cli-cube.3mf"]
        let run = try Self.run(["import", "projects/cli-import-target.nativecam"] + files + ["-o", "<out>/all.nativecam"], out: out)
        #expect(run.status == 0, "\(run.text)")
        let cli = try Project.decode(Data(contentsOf: out.appendingPathComponent("all.nativecam")))
        var app = try Self.project("cli-import-target")
        for f in files { try app.importFile(at: Self.fixtures.appendingPathComponent(f)) }
        app.bindVectors()
        #expect(cli.shapes.map(Self.blank) == app.shapes.map(Self.blank))
        #expect(Self.bound(cli) == Self.bound(app))
        #expect(Self.bound(cli)["Hand-picked V-carve"] == ["Hand-drawn square"])
    }

    @Test(.enabled(if: cliBuilt)) func importGoldens() throws {
        let out = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let target = "projects/cli-import-target.nativecam"
        // Two layers and drill points, bound by layer; the hand-picked toolpath kept.
        let two = try Self.run(["import", target, "import/cli-two-layers-inch.dxf", "import/cli-points.dxf", "-o", "<out>/two.nativecam"], out: out)
        #expect(two.status == 0)
        try Self.checkText(two.text, golden: "cli-import-two-layers.txt")
        // --units mm on the unitless DXF: 25.4 times smaller, so the size warning.
        let mm = try Self.run(["import", target, "import/cli-no-units.dxf", "--units", "mm", "-o", "<out>/mm.nativecam"], out: out)
        #expect(mm.status == 0 && mm.text.contains("under 1% of the material"))
        try Self.checkText(mm.text, golden: "cli-import-units-mm.txt")
        // --units in on it, and an SVG in mm, an STL assumed in mm and a 3MF in mm, onto one layer.
        let models = try Self.run(["import", target, "import/cli-no-units.dxf", "import/cli-mm-part.svg", "import/cli-cube-mm.stl",
                                   "import/cli-cube.3mf", "--units", "in", "--layer", "Profile", "-o", "<out>/models.nativecam"], out: out)
        #expect(models.status == 0)
        try Self.checkText(models.text, golden: "cli-import-units-and-models.txt")
    }

    /// Every refusal exits 1, says why, and writes nothing (the project is untouched too).
    @Test(.enabled(if: cliBuilt)) func refusalsWriteNothing() throws {
        let out = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let targetURL = Self.fixtures.appendingPathComponent("projects/cli-import-target.nativecam")
        let original = try Data(contentsOf: targetURL)
        let target = "projects/cli-import-target.nativecam"
        // The unit assumption: a DXF without $INSUNITS needs --units.
        let noUnits = try Self.run(["import", target, "import/cli-no-units.dxf", "-o", "<out>/x.nativecam"], out: out)
        try Self.checkText(noUnits.text, golden: "cli-import-no-units.txt")
        // Off the material in the file's coordinates: refused, then centred when asked.
        let off = try Self.run(["import", target, "import/cli-off-material.dxf", "-o", "<out>/x.nativecam"], out: out)
        let offExplicit = try Self.run(["import", target, "import/cli-off-material.dxf", "--keep-coords", "-o", "<out>/x.nativecam"], out: out)
        for r in [noUnits, off, offExplicit] { #expect(r.status == 1, "\(r.text)") }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("x.nativecam").path))
        let centred = try Self.run(["import", target, "import/cli-off-material.dxf", "--center", "-o", "<out>/centred.nativecam"], out: out)
        #expect(centred.status == 0)
        try Self.checkText(off.text + centred.text, golden: "cli-import-off-material.txt")

        let refused: [[String]] = [
            ["import", target, "import/cli-mm-part.svg", "-o", "<out>/x.nativecam", "--in-place"],
            ["import", target, "import/cli-mm-part.svg"],
            ["import", target, "import/cli-mm-part.svg", "-o", target],
            ["import", target, "import/cli-mm-part.svg", "--center", "--at", "1,1", "-o", "<out>/x.nativecam"],
            ["import", target, "import/cli-cube.3mf", "--depth", "0.74", "-o", "<out>/x.nativecam"],
            ["import", target, "import/cli-mm-part.svg", "--units", "cm", "-o", "<out>/x.nativecam"],
            ["import", target, "import/cli-mm-part.svg", "--sheet", "2", "-o", "<out>/x.nativecam"],
            ["import", target, "import/cli-mm-part.svg", "--force", "-o", "<out>/x.nativecam"],
            ["import", target, "projects/cli-unbound.nativecam", "-o", "<out>/x.nativecam"],
            ["import", target, "import/missing.dxf", "-o", "<out>/x.nativecam"],
            ["import", target, "-o", "<out>/x.nativecam"],
            ["rebind", target],
            ["rebind", target, "-o", "<out>/x.nativecam", "--in-place"],
            ["save", target],
            ["save", target, "-o", "./" + target],
            ["sim", "golden/sign-inch.tap", "--rebind"],
        ]
        for args in refused {
            let r = try Self.run(args, out: out)
            #expect(r.status == 1, "\(r.text)")
            #expect(!r.text.contains("Wrote"), "\(r.text)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["centred.nativecam"])
        #expect(try Data(contentsOf: targetURL) == original)
        let messages = try refused.prefix(5).map { try Self.run($0, out: out).text }
        #expect(messages[0].contains("Pass -o or --in-place, not both."))
        #expect(messages[1].contains("Say where to write the project"))
        #expect(messages[2].contains("-o names the project itself. Pass --in-place"))
        #expect(messages[3].contains("Pass one of --keep-coords, --center and --at x,y."))
        #expect(messages[4].contains("--depth 0.74 in is too deep"))
    }

    @Test(.enabled(if: cliBuilt)) func rebindAndSaveGoldens() throws {
        let out = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let rebind = try Self.run(["rebind", "projects/cli-unbound.nativecam", "-o", "<out>/bound.nativecam"], out: out)
        #expect(rebind.status == 0)
        // Nothing left to change: still written, and it says so.
        let again = try Self.run(["rebind", "<out>/bound.nativecam", "-o", "<out>/again.nativecam"], out: out)
        #expect(again.status == 0 && again.text.contains("No changes"))
        try Self.checkText(rebind.text + again.text, golden: "cli-rebind-diff.txt")
        let bound = try Project.decode(Data(contentsOf: out.appendingPathComponent("bound.nativecam")))
        #expect(Self.bound(bound) == Self.bound(try Self.appImport()))
        #expect(try Data(contentsOf: out.appendingPathComponent("again.nativecam")) == Data(contentsOf: out.appendingPathComponent("bound.nativecam")))

        // A file marked format 1 holding a format-28 finish pass is saved as format 28.
        let save = try Self.run(["save", "projects/cli-hand-edited-v1.nativecam", "-o", "<out>/saved.nativecam"], out: out)
        let unchanged = try Self.run(["save", "<out>/saved.nativecam", "--in-place"], out: out)
        #expect(save.status == 0 && unchanged.status == 0)
        try Self.checkText(save.text + unchanged.text, golden: "cli-save-format.txt")
        let saved = try Data(contentsOf: out.appendingPathComponent("saved.nativecam"))
        let json = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 28)
        #expect(try Project.decode(saved) == Self.project("cli-hand-edited-v1"))
    }

    /// `post --rebind` writes what an app import of the same files posts, as does posting the command line's import;
    /// plain `post` cuts exactly what the file lists.
    @Test(.enabled(if: cliBuilt)) func postRebindMatchesAnAppImport() throws {
        let out = try CommandLineTests.folder()
        defer { try? FileManager.default.removeItem(at: out) }
        let app = try Self.appImport()
        try GoldenPostTests.check(GoldenPostTests.post(app), golden: "cli-post-rebind")
        let job = CAMEngine.generate(app)
        let appGCode = try #require(JobExport.files(app, job: job)).files.map(\.gcode).joined()

        let rebound = try Self.run(["post", "projects/cli-unbound.nativecam", "--rebind", "-o", "<out>/rebound.tap"], out: out)
        #expect(rebound.status == 0, "\(rebound.text)")
        #expect(rebound.text.contains("Rebind:   Cut out part (Layer “Profile”): 1 → 1 vector (1 added, 1 removed)"))
        let imported = try Self.run(["import", "projects/cli-import-target.nativecam", "import/cli-two-layers-inch.dxf", "import/cli-points.dxf",
                                     "-o", "<out>/imported.nativecam"], out: out)
        #expect(imported.status == 0)
        let posted = try Self.run(["post", "<out>/imported.nativecam", "-o", "<out>/imported.tap"], out: out)
        #expect(posted.status == 0 && !posted.text.contains("Rebind"))
        let a = try String(contentsOf: out.appendingPathComponent("rebound.tap"), encoding: .ascii)
        let b = try String(contentsOf: out.appendingPathComponent("imported.tap"), encoding: .ascii)
        #expect(Self.undated(a) == Self.undated(appGCode))
        #expect(Self.undated(b) == Self.undated(appGCode))
        let decoded = try Project.decode(Data(contentsOf: out.appendingPathComponent("imported.nativecam")))
        try GoldenPostTests.check(GoldenPostTests.post(decoded), golden: "cli-post-rebind")

        // Without --rebind the file's own (stale) vectors are cut, and the project file is never saved.
        let before = try Data(contentsOf: Self.fixtures.appendingPathComponent("projects/cli-unbound.nativecam"))
        let plain = try Self.run(["post", "projects/cli-unbound.nativecam", "-o", "<out>/plain.tap"], out: out)
        #expect(plain.status == 0 && !plain.text.contains("Rebind"))
        let c = try String(contentsOf: out.appendingPathComponent("plain.tap"), encoding: .ascii)
        #expect(Self.undated(c) != Self.undated(appGCode))
        #expect(try Data(contentsOf: Self.fixtures.appendingPathComponent("projects/cli-unbound.nativecam")) == before)

        // sim --rebind simulates the rebound job without saving it.
        let sim = try Self.run(["sim", "projects/cli-unbound.nativecam", "--rebind"], out: out)
        #expect(sim.status == 0 && sim.text.contains("Rebind: Toolpaths whose vectors changed:"), "\(sim.text)")
        #expect(try Data(contentsOf: Self.fixtures.appendingPathComponent("projects/cli-unbound.nativecam")) == before)
    }
}
