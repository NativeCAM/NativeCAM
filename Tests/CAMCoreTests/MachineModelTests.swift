import Foundation
import Testing
@testable import CAMCore

/// Stage 1 of machine support: controller, provenance and library fields are optional additions, projects on
/// Avid's Mach4 profile keep format 1, anything else is format 2, and Avid output doesn't move.
struct MachineModelTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    func json(_ p: Project) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
    }

    var grblProject: Project {
        var p = Project.demoSign()
        p.machine.model = .custom
        p.machine.controller = ControllerProfile(family: .grbl, firmware: "1.1h", sender: "gSender")
        return p
    }

    @Test func avidProjectsStayFormatOne() throws {
        let p = Project.demoSign()
        let j = try json(p)
        #expect(j["formatVersion"] as? Int == 1)
        let machine = try #require(j["machine"] as? [String: Any])
        for key in ["controller", "libraryID", "libraryRevision", "provenance"] { #expect(machine[key] == nil, "\(key)") }
        #expect(try Project.decode(p.encoded()) == p)
    }

    @Test func savedProjectsResaveByteForByte() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/projects")
        for name in ["sign-v1", "setup-v1"] {
            let data = try Data(contentsOf: dir.appendingPathComponent(name + ".nativecam"))
            #expect(try Project.decode(data).encoded() == data, "\(name)")
        }
    }

    @Test func otherControllersWriteFormatTwo() throws {
        let p = grblProject
        #expect(try json(p)["formatVersion"] as? Int == 2)
        let back = try Project.decode(p.encoded())
        #expect(back == p)
        #expect(back.machine.controller?.family == .grbl && back.machine.controller?.sender == "gSender")
        // Back on Avid's Mach4 profile, the file is format 1 again.
        var avid = back
        avid.machine.controller = nil
        #expect(try json(avid)["formatVersion"] as? Int == 1)
    }

    @Test func newerFormatsAreRefused() throws {
        let text = try #require(String(data: grblProject.encoded(), encoding: .utf8))
        let future = Data(text.replacingOccurrences(of: "\"formatVersion\" : 2", with: "\"formatVersion\" : 3").utf8)
        #expect { try Project.decode(future) } throws: { ($0 as NSError).localizedDescription.contains("newer version") }
    }

    @Test func unknownControllersKeepTheirNameAndCantBePosted() throws {
        let text = try #require(String(data: grblProject.encoded(), encoding: .utf8))
        let future = Data(text.replacingOccurrences(of: "\"family\" : \"grbl\"", with: "\"family\" : \"acmeCNC\"").utf8)
        let p = try Project.decode(future)
        #expect(p.machine.controller?.family == .unknown("acmeCNC"))
        #expect(p.machine.controllerLabel == "acmeCNC")
        let resaved = try p.encoded()
        #expect(String(data: resaved, encoding: .utf8)?.contains("\"acmeCNC\"") == true)
        #expect(PostProcessors.post(for: p) == nil)
        let job = CAMEngine.generate(p)
        #expect(job.issues.contains { $0.severity == .error && $0.message.contains("can't write G-code for acmeCNC") })
    }

    @Test func avidMach4ProfileUsesTheUnchangedAvidPost() throws {
        let p = Project.demoSign()
        let toolpaths = CAMEngine.generate(p).toolpaths
        let post = try #require(PostProcessors.post(for: p, date: Self.date))
        #expect(post.name == "Avid CNC Mach4" && post.fileExtension == "tap")
        #expect(post.post(toolpaths) == AvidMach4Post(project: p, date: Self.date).post(toolpaths))
        #expect(PostProcessors.unavailableReason(for: p.machine) == nil)
        #expect(PostProcessors.post(for: grblProject) is GenericGCodePost)
        var masso = grblProject
        masso.machine.controller = ControllerProfile(family: .masso)
        #expect(PostProcessors.post(for: masso) == nil)
    }

    @Test func valueSourcesRoundTrip() throws {
        var m = MachineProfile()
        m.accelerationXY = 381
        m.setSource(ValueSource(.controllerSettings, note: "Machine.ini MaxAccel ÷ CountsPerUnit"), for: .accelerationXY)
        m.setSource(ValueSource(.estimated, note: "belt-drive default"), for: .accelerationZ)
        #expect(m.source(of: .accelerationXY)?.kind == .controllerSettings)
        var p = Project.demoSign()
        p.machine = m
        let back = try Project.decode(p.encoded())
        #expect(back.machine.source(of: .accelerationZ)?.note == "belt-drive default")
        #expect(back.formatVersion == 1) // provenance doesn't change what an older build posts
        m.setSource(nil, for: .accelerationXY)
        m.setSource(nil, for: .accelerationZ)
        #expect(m.provenance == nil)
        // A kind this build doesn't know survives.
        let kind = try JSONDecoder().decode(ValueSource.Kind.self, from: Data("\"probed\"".utf8))
        let reencoded = try JSONEncoder().encode(kind)
        #expect(kind == .unknown("probed") && String(data: reencoded, encoding: .utf8) == "\"probed\"")
    }

    @Test func libraryStampsSnapshotsAndCountsRevisions() throws {
        var lib = MachineLibrary.starter()
        let first = try #require(lib.defaultMachine)
        #expect(first.id == MachineLibrary.firstMachineID && first.revision == 1)
        #expect(first.snapshot.libraryID == first.id && first.snapshot.libraryRevision == 1)
        #expect(first.profile.libraryID == nil)
        // Writing back a stamped snapshot unchanged is not a change.
        lib.update(first.id, profile: first.snapshot)
        #expect(lib.defaultMachine?.revision == 1)
        var edited = first.snapshot
        edited.maxRPM = 18000
        lib.update(first.id, profile: edited)
        #expect(lib.defaultMachine?.revision == 2 && lib.defaultMachine?.profile.maxRPM == 18000)
        #expect(lib.defaultMachine?.profile.libraryID == nil)
        let updatedMissing = lib.update("missing", profile: edited)
        #expect(!updatedMissing)
        #expect(try MachineLibrary.decode(lib.encoded()) == lib)
    }

    @Test func newerLibrarySchemasAreRefused() throws {
        let text = try #require(String(data: MachineLibrary.starter().encoded(), encoding: .utf8))
        let future = Data(text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 9").utf8)
        #expect(throws: (any Error).self) { try MachineLibrary.decode(future) }
    }

    @Test func libraryKeepsControllersItDoesntKnow() throws {
        var m = MachineProfile()
        m.controller = ControllerProfile(family: .unknown("acmeCNC"))
        let lib = MachineLibrary(machines: [MachineSetup(id: "acme", name: "Acme", profile: m)])
        #expect(try MachineLibrary.decode(lib.encoded()).machines.first?.profile.controller?.family == .unknown("acmeCNC"))
    }
}
