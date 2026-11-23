import Foundation
import SQLite3
import Testing
@testable import CAMCore

/// Tool libraries from other programs. The fixtures are written here, in each program's format, rather than copied
/// from vendor files (which carry no redistribution licence).
struct ToolImportTests {
    // MARK: Fusion 360

    static func fusionLibrary() -> [String: Any] {
        func preset(_ n: Double, _ vf: Double, _ plunge: Double) -> [String: Any] {
            ["start-values": ["presets": [["name": "Hardwood", "n": n, "v_f": vf, "v_f_plunge": plunge, "use-stepdown": false]]]]
        }
        let tools: [[String: Any]] = [
            ["type": "flat end mill", "unit": "inches", "guid": "0022A200-E317-4DB7-B43B-8EACD93C3A66", "vendor": "Acme",
             "product-id": "1001", "description": "1001 Solid Carbide Down-Cut Spiral 1/4 Dia x 3/4 x 1/4 Shank",
             "geometry": ["DC": 0.25, "LCF": 0.75, "NOF": 2, "SFDM": 0.25, "LB": 1.25, "OAL": 2.5],
             "post-process": ["number": 7]].merging(preset(18000, 180, 60)) { a, _ in a },
            ["type": "chamfer mill", "unit": "inches", "description": "1002 45 Degree Engraving 0.025 Tip",
             "geometry": ["DC": 0.25, "LCF": 0.272, "NOF": 1, "TA": 22.5, "tip-diameter": 0.025, "SFDM": 0.25]],
            ["type": "counter sink", "unit": "inches", "description": "1003 60 Deg V",
             "geometry": ["DC": 0.5, "LCF": 0.5, "NOF": 2, "SIG": 60, "tip-diameter": 0, "SFDM": 0.25]],
            ["type": "bull nose end mill", "unit": "millimeters", "description": "1004 Bull 12mm R2",
             "geometry": ["DC": 12, "LCF": 30, "NOF": 2, "RE": 2, "SFDM": 12]].merging(preset(16000, 3000, 900)) { a, _ in a },
            ["type": "tapered mill", "unit": "inches", "description": "1005 Tapered Ball Tip",
             "geometry": ["DC": 0.06, "LCF": 1, "NOF": 2, "RE": 0.03, "TA": 5.4, "SFDM": 0.25]],
            ["type": "radius mill", "unit": "inches", "description": "1006 Roundover", "geometry": ["DC": 0.375, "RE": 0.1875]],
            ["type": "dovetail mill", "unit": "inches", "description": "1007 14 Deg Dovetail 1/2 Dia x 1/2 CH",
             "geometry": ["DC": 0.5, "LCF": 0.5, "NOF": 2, "TA": 14, "SFDM": 0.25]],
            ["type": "slot mill", "unit": "inches", "description": "1008 Slot cutter", "geometry": ["DC": 1]],
            ["type": "holder", "unit": "inches", "description": "ER20 holder"],
        ]
        return ["data": tools, "version": 18]
    }

    @Test func fusionToolsArchiveMapsGeometryFeedsAndSkips() throws {
        let json = try JSONSerialization.data(withJSONObject: Self.fusionLibrary())
        let archive = MeshImportTests.zip([("tools.json", json, true)])
        let r = try ToolLibraryImporter.load(data: archive)
        #expect(r.format == .fusion)
        #expect(r.tools.count == 7)
        #expect(r.skipped.map(\.reason) == ["slot cutter"])

        let flat = try #require(r.tools.first { $0.tool.name.hasPrefix("1001") }).tool
        #expect(flat.id == UUID(uuidString: "0022A200-E317-4DB7-B43B-8EACD93C3A66"))
        #expect(flat.shape == .flatEndMill && flat.fluteDirection == .downcut && flat.number == 7)
        #expect(abs(flat.diameter - 6.35) < 1e-9 && abs(flat.fluteLength - 19.05) < 1e-9 && abs(flat.stickout - 31.75) < 1e-9)
        #expect(abs(flat.cutting.feedRate - 180 * 25.4) < 1e-6 && abs(flat.cutting.plungeRate - 60 * 25.4) < 1e-6)
        #expect(flat.cutting.spindleRPM == 18000)
        #expect(flat.notes.contains("“Hardwood” preset") && flat.notes.contains("stepdown"))
        #expect(!flat.notes.contains("feed rate"))

        let chamfer = try #require(r.tools.first { $0.tool.name.hasPrefix("1002") }).tool
        #expect(chamfer.shape == .engraving && chamfer.includedAngle == 45 && abs(chamfer.tipDiameter - 0.635) < 1e-9)
        #expect(chamfer.fluteDirection == .straight)
        let vee = try #require(r.tools.first { $0.tool.name.hasPrefix("1003") }).tool
        #expect(vee.shape == .vBit && vee.includedAngle == 60)
        let bull = try #require(r.tools.first { $0.tool.name.hasPrefix("1004") }).tool
        #expect(bull.shape == .bullNose && bull.cornerRadius == 2 && bull.diameter == 12 && bull.cutting.feedRate == 3000)

        // Tapered ball nose: Fusion's diameter is its tip, its taper angle per side; it widens up the flutes.
        let tb = try #require(r.tools.first { $0.tool.name.hasPrefix("1005") }).tool
        #expect(tb.shape == .taperedBallNose)
        #expect(abs(tb.tipDiameter - 1.524) < 1e-9 && abs(tb.includedAngle - 10.8) < 1e-9)
        #expect(tb.geometryProblem == nil)
        #expect(tb.diameter > tb.tipDiameter && tb.diameter <= 6.35 + 1e-9)
        #expect(abs(tb.stepoverBasis - tb.tipDiameter) < 1e-12)
        // Roundover: the pilot is the diameter less twice the radius, and the note says it was worked out.
        let round = try #require(r.tools.first { $0.tool.name.hasPrefix("1006") }).tool
        let roundForm = try #require(round.form)
        #expect(round.shape == .form && roundForm.kind == .roundover)
        #expect(abs(roundForm.radius - 4.7625) < 1e-9 && roundForm.pilotDiameter == 0)
        #expect(abs(round.diameter - 9.525) < 1e-9 && round.notes.contains("⚠"))
        let tail = try #require(r.tools.first { $0.tool.name.hasPrefix("1007") }).tool
        #expect(tail.shape == .dovetail && abs(tail.includedAngle - 28) < 1e-9 && abs(tail.diameter - 12.7) < 1e-9)
        let neck = 12.7 - 2 * 12.7 * tan(14 * Double.pi / 180)
        #expect(abs(tail.dovetailSmallDiameter - neck) < 1e-9)
        #expect(tail.hasUndercut)
    }

    @Test func fusionJSONAndNativeCAMLibrariesLoad() throws {
        let json = try JSONSerialization.data(withJSONObject: Self.fusionLibrary())
        #expect(try ToolLibraryImporter.load(data: json).format == .fusion)
        let own = try ToolLibrary.starter.encoded()
        let r = try ToolLibraryImporter.load(data: own)
        #expect(r.format == .nativeCAM && r.tools.map(\.tool) == ToolLibrary.starter.tools)
        #expect(throws: ToolImportError.self) { try ToolLibraryImporter.load(data: Data("{\"x\": 1}".utf8)) }
        #expect(throws: ToolImportError.self) { try ToolLibraryImporter.load(url: URL(fileURLWithPath: "/tmp/old.tool")) }
    }

    // MARK: Vectric

    /// A small Vectric tool database: a folder tree, inch and mm tools, cutting data per material and a generic entry.
    static func makeVTDB(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw ToolImportError.unreadable("sqlite") }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE material (id TEXT, name TEXT);
            CREATE TABLE tool_geometry (id TEXT, name_format TEXT, notes TEXT, tool_type INTEGER, units INTEGER, diameter REAL,
                included_angle REAL, flat_diameter REAL, num_flutes INTEGER, flute_length REAL, tip_radius REAL);
            CREATE TABLE tool_cutting_data (id TEXT, rate_units INTEGER, feed_rate REAL, plunge_rate REAL, spindle_speed INTEGER,
                stepdown REAL, stepover REAL, length_units INTEGER, tool_number INTEGER);
            CREATE TABLE tool_entity (id TEXT, material_id TEXT, machine_id TEXT, tool_geometry_id TEXT, tool_cutting_data_id TEXT);
            CREATE TABLE tool_tree_entry (id TEXT, parent_group_id TEXT, sibling_order INTEGER, tool_geometry_id TEXT, name TEXT);
            INSERT INTO material VALUES ('m1', 'Hardwood');
            INSERT INTO tool_tree_entry VALUES ('root', NULL, 0, NULL, 'Acme Master');
            INSERT INTO tool_tree_entry VALUES ('g14', 'root', 1, NULL, '1/4" Shank');
            INSERT INTO tool_tree_entry VALUES ('g6', 'root', 0, NULL, '6mm Shank');
            -- 1/4" downcut end mill: cutting data for Hardwood only (inches, in/min).
            INSERT INTO tool_geometry VALUES ('11111111-1111-1111-1111-111111111111',
                '#2001 SC DOWNCUT SPIRAL 1/4 DIA x 3/4 x 1/4 SHANK', 'Recommended: 18,000 RPM', 1, 1, 0.25, NULL, NULL, 2, NULL, NULL);
            INSERT INTO tool_tree_entry VALUES ('t1', 'g14', 0, '11111111-1111-1111-1111-111111111111', NULL);
            INSERT INTO tool_cutting_data VALUES ('c1', 4, 200, 50, 18000, 0.125, 0.1, 1, 3);
            INSERT INTO tool_cutting_data VALUES ('c1g', 4, NULL, NULL, NULL, NULL, NULL, 1, 1);
            INSERT INTO tool_entity VALUES ('e1', 'm1', NULL, '11111111-1111-1111-1111-111111111111', 'c1');
            INSERT INTO tool_entity VALUES ('e1g', NULL, NULL, '11111111-1111-1111-1111-111111111111', 'c1g');
            -- 6 mm ball nose: a generic entry (preferred) and a Hardwood one, in mm and mm/min.
            INSERT INTO tool_geometry VALUES ('22222222-2222-2222-2222-222222222222',
                '#2002 BALLNOSE 6mm Dia x 6mm shank', NULL, 0, 0, 6, NULL, NULL, 2, NULL, NULL);
            INSERT INTO tool_tree_entry VALUES ('t2', 'g6', 0, '22222222-2222-2222-2222-222222222222', NULL);
            INSERT INTO tool_cutting_data VALUES ('c2', 1, 2000, 500, 16000, 1.5, 0.6, 0, NULL);
            INSERT INTO tool_cutting_data VALUES ('c2h', 1, 9999, 999, 9999, 9, 9, 0, NULL);
            INSERT INTO tool_entity VALUES ('e2', NULL, NULL, '22222222-2222-2222-2222-222222222222', 'c2');
            INSERT INTO tool_entity VALUES ('e2h', 'm1', NULL, '22222222-2222-2222-2222-222222222222', 'c2h');
            -- V-bit, engraving bit, radiused end mill, no cutting data at all.
            INSERT INTO tool_geometry VALUES ('33333333-3333-3333-3333-333333333333', '#2003 60° V GROOVE 1/2 DIA', NULL, 3, 1, 0.5, 60, NULL, 2, NULL, NULL);
            INSERT INTO tool_geometry VALUES ('44444444-4444-4444-4444-444444444444', '#2004 TAPERED FLAT BOTTOM 1/4 SHK', NULL, 4, 1, 0.25, 14, 0.125, 3, NULL, NULL);
            INSERT INTO tool_geometry VALUES ('55555555-5555-5555-5555-555555555555', '#2005 PLUNGE W RADIUS 1/2"x 1/2" Shank', NULL, 2, 1, 0.5, NULL, NULL, 2, NULL, 0.125);
            INSERT INTO tool_tree_entry VALUES ('t3', 'g14', 1, '33333333-3333-3333-3333-333333333333', NULL);
            INSERT INTO tool_tree_entry VALUES ('t4', 'g14', 2, '44444444-4444-4444-4444-444444444444', NULL);
            INSERT INTO tool_tree_entry VALUES ('t5', 'g14', 3, '55555555-5555-5555-5555-555555555555', NULL);
            -- A tapered ball nose (Vectric's angle is per side), form tools named for what they are, and one that isn't.
            INSERT INTO tool_geometry VALUES ('66666666-6666-6666-6666-666666666666', '#2006 Tapered Ball Nose', NULL, 5, 1, 0.125, 6.2, NULL, 2, NULL, 0.0156);
            INSERT INTO tool_geometry VALUES ('77777777-7777-7777-7777-777777777777', '#2007 Ogee', NULL, 8, 1, 1, NULL, NULL, 2, NULL, NULL);
            INSERT INTO tool_geometry VALUES ('88888888-8888-8888-8888-888888888888', '#2008 1/4" RADIUS ROUNDOVER 1-1/8 DIA', NULL, 8, 1, 1.125, NULL, NULL, 2, NULL, NULL);
            INSERT INTO tool_geometry VALUES ('99999999-9999-9999-9999-999999999999', '#2009 14° DOVETAIL 1/2 DIA x 1/2 CH', NULL, 8, 1, 0.5, NULL, NULL, 2, NULL, NULL);
            INSERT INTO tool_tree_entry VALUES ('t6', 'g14', 4, '66666666-6666-6666-6666-666666666666', NULL);
            INSERT INTO tool_tree_entry VALUES ('t8', 'g14', 5, '88888888-8888-8888-8888-888888888888', NULL);
            INSERT INTO tool_tree_entry VALUES ('t9', 'g14', 6, '99999999-9999-9999-9999-999999999999', NULL);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ToolImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
    }

    @Test func vectricDatabaseMapsTypesUnitsFeedsAndFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vtdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Acme.vtdb")
        try Self.makeVTDB(at: url)
        let r = try ToolLibraryImporter.load(url: url)
        #expect(r.format == .vectric)
        #expect(r.skipped.map(\.reason) == ["form tool (custom profile)"])
        // Folder order: "6mm Shank" (sibling 0) before "1/4" Shank" (sibling 1), tools in their order within.
        #expect(r.tools.map { $0.tool.name.prefix(5) } == ["#2002", "#2001", "#2003", "#2004", "#2005", "#2006", "#2008", "#2009"])
        #expect(r.tools[0].group == "Acme Master ▸ 6mm Shank" && r.tools[1].group == "Acme Master ▸ 1/4\" Shank")

        let ball = r.tools[0].tool
        #expect(ball.id == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(ball.shape == .ballNose && ball.diameter == 6 && ball.shankDiameter == 6)
        #expect(ball.cutting.feedRate == 2000 && ball.cutting.spindleRPM == 16000 && abs(ball.cutting.stepoverFraction - 0.1) < 1e-9)
        #expect(ball.notes.contains("default settings"))

        let end = r.tools[1].tool
        #expect(end.shape == .flatEndMill && end.fluteDirection == .downcut && end.number == 3)
        #expect(abs(end.diameter - 6.35) < 1e-9 && abs(end.fluteLength - 19.05) < 1e-9 && abs(end.shankDiameter - 6.35) < 1e-9)
        #expect(abs(end.cutting.feedRate - 200 * 25.4) < 1e-6 && abs(end.cutting.stepdown - 3.175) < 1e-9)
        #expect(abs(end.cutting.stepoverFraction - 0.4) < 1e-9)
        #expect(end.notes.contains("“Hardwood”") && end.notes.contains("Cutting length read from the name"))
        #expect(end.notes.contains("Recommended: 18,000 RPM"))

        let vee = r.tools[2].tool
        #expect(vee.shape == .vBit && vee.includedAngle == 60 && vee.fluteDirection == .straight)
        #expect(abs(vee.fluteLength - vee.taperHeight) < 1e-9)
        // No feeds in the file: chart values, and the note says which values were guessed.
        #expect(vee.cutting.feedRate > 0 && vee.notes.contains("feed rate"))
        let engraving = r.tools[3].tool
        #expect(engraving.shape == .engraving && engraving.includedAngle == 14 && abs(engraving.tipDiameter - 3.175) < 1e-9)
        let bull = r.tools[4].tool
        #expect(bull.shape == .bullNose && abs(bull.cornerRadius - 3.175) < 1e-9 && abs(bull.shankDiameter - 12.7) < 1e-9)
        // Unknown cutting length: a short estimate (the depth check then warns rather than missing a too-deep cut).
        #expect(abs(bull.fluteLength - 25.4) < 1e-9 && bull.notes.contains("Cutting length estimated"))
        #expect(ChipLoad.applies(to: bull) && bull.notes.contains("plywood chip-load chart"))

        let tb = r.tools[5].tool
        let tip = 2 * 0.0156 * 25.4
        #expect(tb.shape == .taperedBallNose && abs(tb.includedAngle - 12.4) < 1e-9)
        #expect(abs(tb.tipDiameter - tip) < 1e-9)
        #expect(abs(tb.shankDiameter - 3.175) < 1e-9 && tb.geometryProblem == nil)
        #expect(tb.notes.contains("per side"))
        let round = r.tools[6].tool
        let roundForm = try #require(round.form)
        #expect(round.shape == .form && roundForm.kind == .roundover)
        #expect(abs(roundForm.radius - 6.35) < 1e-9)
        #expect(abs(roundForm.pilotDiameter - 15.875) < 1e-9 && abs(round.diameter - 28.575) < 1e-9)
        #expect(round.notes.contains("⚠ Roundover read from the name"))
        let tail = r.tools[7].tool
        #expect(tail.shape == .dovetail && abs(tail.includedAngle - 28) < 1e-9 && abs(tail.fluteLength - 12.7) < 1e-9)
    }

    // MARK: Names

    @Test func sizesAndDirectionFromVendorNames() {
        let a = ToolNameHints.parse("#46114 SC 3FL UPCUT SPIRAL 3/8\" DIA.x1-1/4\"CHx3/8\" shank", inches: true)
        #expect(a.cutLength == 1.25 * 25.4 && a.shank == 0.375 * 25.4 && a.direction == .upcut)
        let b = ToolNameHints.parse("#48430-K SC FIBERGLASS 6MM DIA x 19 x 6MM SHANK", inches: false)
        #expect(b.cutLength == 19 && b.shank == 6 && b.direction == nil)
        let c = ToolNameHints.parse("#201005 CNC BORING 5mm D x 10mm SHK", inches: false)
        #expect(c.shank == 10 && c.cutLength == nil)
        let d = ToolNameHints.parse("46390 Solid Carbide Compression Spiral 1/4 Dia x 7/8 x 1/4 Inch Shank", inches: true)
        #expect(d.direction == .compression && d.cutLength == 0.875 * 25.4 && d.shank == 6.35)
        #expect(ToolNameHints.parse("#2001 DOWN-CUT", inches: true).direction == .downcut)
    }
}
