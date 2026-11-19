import Foundation
import Testing
@testable import CAMCore

/// Stage 5 of machine support: the built-in catalogue and the setup summary.
struct MachineCatalogueTests {
    let catalogue = MachineCatalogue.builtIn
    let families = Set(ControllerFamily.known.map(\.rawValue))
    let fields: Set<String> = ["travel", "minRPM", "maxRPM", "rapidXY", "rapidZ", "maxFeed", "accelerationXY", "accelerationZ",
                               "junctionDeviation", "controllers"]

    @Test func catalogueIsComplete() {
        #expect(catalogue.schemaVersion == 1)
        #expect(catalogue.entries.count >= 25)
        #expect(Set(catalogue.entries.map(\.vendor)).count >= 15)
        #expect(Set(catalogue.entries.map(\.id)).count == catalogue.entries.count, "duplicate IDs")
    }

    @Test func everyEntryIsSourcedAndValid() {
        for e in catalogue.entries {
            #expect(e.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil, "\(e.id)")
            #expect(e.travel.count == 3 && e.travel.allSatisfy { $0 > 0 }, "\(e.id) travel")
            #expect(!e.controllers.isEmpty && e.controllers.allSatisfy { families.contains($0.family) }, "\(e.id) controllers")
            #expect(e.controllers.filter { $0.isDefault == true }.count <= 1, "\(e.id) defaults")
            #expect(e.spindle == "router" || e.spindle == "vfdSpindle", "\(e.id) spindle")
            #expect(e.sources["travel"]?.url?.hasPrefix("http") == true, "\(e.id) travel source")
            let present: [(String, Double?)] = [("minRPM", e.minRPM), ("maxRPM", e.maxRPM), ("rapidXY", e.rapidXY), ("rapidZ", e.rapidZ),
                                                ("maxFeed", e.maxFeed), ("accelerationXY", e.accelerationXY),
                                                ("accelerationZ", e.accelerationZ), ("junctionDeviation", e.junctionDeviation)]
            for (key, value) in present where value != nil {
                #expect(e.sources[key] != nil, "\(e.id) has \(key) without a source")
            }
            for (key, s) in e.sources {
                #expect(fields.contains(key), "\(e.id) source for unknown field \(key)")
                #expect(["vendor", "controllerSettings", "measured", "estimated", "user"].contains(s.kind), "\(e.id) \(key) kind")
                if s.kind == "vendor" { #expect(s.url?.hasPrefix("http") == true, "\(e.id) \(key) vendor source without a URL") }
            }
            if let u = e.units { #expect(u == "inch" || u == "mm", "\(e.id) units") }
            if let t = e.toolChange { #expect(ToolChangeMode(rawValue: t) != nil, "\(e.id) tool change") }
        }
        // Only the developer's own machine is marked tested.
        #expect(catalogue.entries.filter(\.verified).map(\.id) == ["avid-pro6060"])
    }

    @Test func avidEntriesUseTheBuiltInPresets() throws {
        for (id, model) in [("avid-pro4848", AvidModel.pro4848), ("avid-pro4896", .pro4896), ("avid-pro6060", .pro6060)] {
            let e = try #require(catalogue.entries.first { $0.id == id }, "\(id)")
            let m = e.profile()
            #expect(m.model == model, "\(id)")
            #expect(m.isLegacyAvidMach4, "\(id): Mach4 is Avid's profile, format 1")
            #expect(m.libraryID == id)
            let ex = try #require(e.controllers.first { $0.family == "centroid" }, "\(id) EX option")
            let exMachine = e.profile(controller: ex)
            #expect(exMachine.controller?.family == .centroid)
        }
    }

    @Test func grblEntriesGetTheGrblPostAndSources() throws {
        let grbl = catalogue.entries.filter { $0.defaultController.map { ["grbl", "grblHAL", "fluidNC", "carbideMotion"].contains($0.family) } ?? false }
        #expect(grbl.count >= 8)
        for e in grbl {
            let m = e.profile()
            #expect(PostProcessors.post(for: Project(machine: m)) is GenericGCodePost, "\(e.id)")
            #expect(m.source(of: .travel) != nil, "\(e.id)")
            if e.accelerationXY != nil { #expect(m.source(of: .accelerationXY) != nil, "\(e.id)") }
            if e.rapidZ != nil { #expect(m.source(of: .rapidRateZ) != nil, "\(e.id) rapid Z source") }
            // No published rapid: estimates use the machine's own maximum feed, not NativeCAM's 800 in/min default.
            if e.rapidXY == nil, let feed = e.maxFeed {
                #expect(m.rapidRateForEstimates == feed && m.source(of: .rapidRateForEstimates)?.kind == .estimated, "\(e.id)")
            }
            #expect(m.model == .custom)
        }
    }

    @Test func summaryDescribesWhatTheOperatorDoes() {
        let avid = MachineProfile().summary
        #expect(avid[0].contains("Avid Mach4 G-code in inches (G20)"))
        #expect(avid.contains { $0.contains("Avid's M6 macro") })
        #expect(avid.contains { $0.contains("M7") })
        #expect(avid.last?.contains("NativeCAM's default, a guess") == true)

        var grbl = MachineProfile(model: .custom, outputUnits: .mm)
        grbl.controller = ControllerProfile(family: .grbl)
        grbl.accelerationXY = 500
        grbl.setSource(ValueSource(.estimated, note: "belt-drive class default"), for: .accelerationXY)
        let s = grbl.summary
        #expect(s[0].contains("millimetres (G21)") && s[0].contains(".nc"))
        #expect(s.contains { $0.contains("one file per tool") })
        #expect(s.contains { $0.contains("M8") })
        #expect(s.last?.contains("500 mm/s²") == true && s.last?.contains("belt-drive class default") == true)

        grbl.controller?.sender = "gSender"
        #expect(grbl.summary.contains { $0.contains("gSender is set to pause on M6") })

        var other = MachineProfile()
        other.controller = ControllerProfile(family: .winCNC)
        #expect(other.summary.count == 1 && other.summary[0].contains("can't write G-code for WinCNC yet"))
    }
}
