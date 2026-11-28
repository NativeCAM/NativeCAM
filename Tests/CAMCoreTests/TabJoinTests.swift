import Foundation
import Testing
@testable import CAMCore

/// How far a 3D cut-out's tab stands proud of the model where its strip joins it (#209): the lowest the model is across
/// the band from its outline to half a millimetre in, read off the model's own surface, not one sample half a
/// millimetre in. That sample landed wherever it did on a steep edge, so the deep relief's warning came and went with
/// #205's exact outline, the G-code the same either way. Fixtures in `Fixtures/tab-join` (listed in its README); the
/// deep relief is `Fixtures/part-hold/deep-relief.nativecam`.
struct TabJoinTests {
    static let dir = GoldenPostTests.fixtures.appendingPathComponent("tab-join")

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "209AB000-0000-4000-8000-%012d", n))! }

    /// Loads a fixture. Update mode writes a missing one from `make`, but never replaces one.
    static func fixture(_ name: String, make: () -> Project) throws -> Project {
        let url = dir.appendingPathComponent(name + ".nativecam")
        if GoldenPostTests.updating, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try make().encoded().write(to: url, options: .atomic)
        }
        return try Project.decode(Data(contentsOf: url))
    }

    static func warnings(_ p: Project, _ op: String) throws -> [String] {
        let o = try #require(p.operations.first { $0.name == op })
        return try #require(HoldingTabs.decide(o, in: p).strips, "\(op) leaves no strips").warnings
    }

    /// The demo relief made 0.75 in deep, cut out on four tabs: its edge falls steeply to the board's bottom at its
    /// outline, so every tab stands proud of it there, by up to 0.0934 in (its 0.105 in tab top less the relief's
    /// lowest at the join). Before #205 the probe half a millimetre in found tab 1 only (0.0344 in); after it, none.
    @Test func theDeepReliefsTabsStandProudOfItsEdge() throws {
        let url = GoldenPostTests.fixtures.appendingPathComponent("part-hold/deep-relief.nativecam")
        let p = try Project.decode(Data(contentsOf: url))
        let expected = "4 tabs of “Cut out medallion” stand up to 0.0934 in proud of the model's edge where they join it, so "
            + "there's a block to trim off there after the cut-out."
        for op in ["Rough relief", "Finish relief"] {
            #expect(try Self.warnings(p, op) == [expected], "\(op)")
        }
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        for op in ["Rough relief", "Finish relief"] {
            #expect(job.issues.contains { $0.severity == .warning && $0.operation == op && $0.message == expected }, "\(op)")
        }
    }

    /// The medallion whose edge is 2 mm high reads as its rim, 1.175 mm under the 3.175 mm tab top (0.0462 in, the
    /// rim a hair in from the outline), not as the paraboloid half a millimetre up from it (0.0335 in).
    @Test func aTabAboveTheModelsEdgeReadsTheRim() throws {
        let p = try HoldingTabsCatalogTests.fixture("tab-above-edge", make: HoldingTabsCatalogTests.proud)
        #expect(try Self.warnings(p, "Rough medallion").first?.contains("stand up to 0.0462 in proud") == true)
    }

    /// A solid round model with straight sides leaning `lean`° off vertical, out to `radius` mm at its foot, `height` mm
    /// tall with a flat top: its outline is its foot, at the bottom of the model.
    static func steepMesh(radius: Double = 45, height: Double = 19.05, lean: Double = 5, sectors: Int = 96, meshID: UUID) -> MeshModel {
        var pos: [Float] = []
        var idx: [UInt32] = []
        func add(_ x: Double, _ y: Double, _ z: Double) -> UInt32 {
            pos += [Float(x), Float(y), Float(z)]
            return UInt32(pos.count / 3 - 1)
        }
        let top = radius - height * tan(lean * .pi / 180)
        let up = add(0, 0, height), down = add(0, 0, 0)
        func ring(_ r: Double, _ z: Double) -> [UInt32] {
            (0..<sectors).map { j in
                let a = 2 * Double.pi * Double(j) / Double(sectors)
                return add(r * cos(a), r * sin(a), z)
            }
        }
        let t = ring(top, height), b = ring(radius, 0)
        for j in 0..<sectors {
            let n = (j + 1) % sectors
            idx += [up, t[j], t[n], t[j], b[j], b[n], t[j], b[n], t[n], down, b[n], b[j]]
        }
        return MeshModel(id: meshID, name: "Steep medallion", positions: pos, indices: idx)
    }

    /// The medallion job (`HoldingTabsCatalogTests.medallion`) with `steepMesh` as its model, as deep as the board.
    static func steepEdge() -> Project {
        var p = HoldingTabsCatalogTests.medallion("Steep edge", finish: nil)
        let mesh = steepMesh(meshID: id(1))
        p.shapes[0].kind = .model(ModelSpec(mesh: mesh, upAxis: .z, depth: HoldingTabsCatalogTests.thickness))
        return p
    }

    /// Its sides 5° off vertical: half a millimetre in from the foot the model is 5.7 mm up, above the tabs' 3.175 mm
    /// tops, which is all the probe saw; at the foot itself the model is at the board's bottom, so each tab stands its
    /// whole height proud there. It warns, and the strips are the same as ever.
    @Test func aSteepEdgeWarnsAtItsFoot() throws {
        let p = try Self.fixture("steep-edge", make: Self.steepEdge)
        let w = try Self.warnings(p, "Rough medallion")
        #expect(w.count == 1, "\(w)")
        #expect(w.first?.hasPrefix("4 tabs of “Cut out medallion” stand up to 0.1246 in proud") == true, "\(w)")
        let job = CAMEngine.generate(p)
        #expect(!job.hasErrors, "\(job.issues.map(\.message))")
        #expect(job.issues.contains { $0.severity == .warning && $0.operation == "Rough medallion" && $0.message == w.first })
    }
}
