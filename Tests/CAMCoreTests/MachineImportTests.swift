import Foundation
import Testing
@testable import CAMCore

/// Stage 4 of machine support: machine limits from controller settings. Fixtures are written here in each
/// format's layout with made-up values, not copied from anyone's machine.
struct MachineImportTests {
    func value(_ i: MachineImport, _ key: MachineImport.Key) -> Double? { i.setting(key)?.value }
    func near(_ a: Double?, _ b: Double, _ tol: Double = 0.01) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    @Test func grblSettingsDump() throws {
        let dump = """
        $0=10
        $11=0.010
        $13=0
        $20=0
        $30=24000
        $31=0
        $32=0
        $100=40.000
        $101=40.000
        $102=200.000
        $110=5000.000
        $111=4500.000
        $112=1500.000
        $120=500.000
        $121=400.000
        $122=200.000
        $130=830.000
        $131=830.000
        $132=100.000
        ok
        """
        let i = try MachineSettingsImporter.read(dump)
        #expect(i.format == .grbl && i.controller?.family == .grbl)
        #expect(near(value(i, .travelX), 830) && near(value(i, .travelZ), 100))
        #expect(near(value(i, .rapidXY), 4500) && near(value(i, .maxFeed), 4500) && near(value(i, .rapidZ), 1500))
        #expect(near(value(i, .accelerationXY), 400) && near(value(i, .accelerationZ), 200))
        #expect(near(value(i, .junctionDeviation), 0.01) && near(value(i, .maxRPM), 24000))
        #expect(value(i, .minRPM) == nil) // 0 isn't a limit
        #expect(i.setting(.accelerationXY)?.source.note?.contains("$120") == true)
        #expect(i.notes.contains { $0.contains("Soft limits are off") })
    }

    @Test func grblHALAndOldGrbl() throws {
        let hal = try MachineSettingsImporter.read("$110=6000\n$111=6000\n$120=800\n$121=800\n$341=4\n$342=30\n")
        #expect(hal.controller?.family == .grblHAL)
        #expect(hal.notes.contains { $0.contains("ignores M6") })
        #expect(throws: MachineImportError.self) { try MachineSettingsImporter.read("$0=250\n$1=250\n$2=250\n$3=10\n") }
    }

    @Test func mach4MachineIniInCounts() throws {
        // 2000 counts per inch: 20000 counts/s = 10 in/s = 600 in/min; 30000 counts/s² = 15 in/s².
        let ini = """
        [Preferences]
        setupunits=200
        [DefaultMode]
        unitsmode=G20
        [SpindleRange0]
        maxrpm=18000.000000
        minrpm=0.000000
        [Axis0]
        enabled = 1
        ChildMotor0=Motor0
        [Axis1]
        enabled = 1
        ChildMotor0=Motor1
        ChildMotor1=Motor3
        [Axis2]
        enabled = 1
        ChildMotor0=Motor2
        [Motor0]
        Enabled=1
        CountsPerUnit=2000.000000
        MaxVelocity=20000.000000
        MaxAccel=30000.000000
        SoftMaxLimit=96000.000000
        SoftMinLimit=0.000000
        [Motor1]
        Enabled=1
        CountsPerUnit=2000.000000
        MaxVelocity=20000.000000
        MaxAccel=30000.000000
        SoftMaxLimit=194000.000000
        SoftMinLimit=0.000000
        [Motor3]
        Enabled=1
        CountsPerUnit=2000.000000
        MaxVelocity=18000.000000
        MaxAccel=28000.000000
        SoftMaxLimit=192000.000000
        SoftMinLimit=0.000000
        [Motor2]
        Enabled=1
        CountsPerUnit=5000.000000
        MaxVelocity=16000.000000
        MaxAccel=100000.000000
        SoftMaxLimit=0.000000
        SoftMinLimit=-40000.000000
        """
        let i = try MachineSettingsImporter.read(ini)
        #expect(i.format == .mach4 && i.controller == nil && i.outputUnits == .inch)
        #expect(near(value(i, .travelX), 48.inch) && near(value(i, .travelY), 96.inch) && near(value(i, .travelZ), 8.inch))
        // The slaved Y motor (Motor3) is slower, so it sets the X/Y limits.
        #expect(near(value(i, .rapidXY), 540.inch) && near(value(i, .accelerationXY), 14.inch))
        #expect(near(value(i, .rapidZ), 192.inch) && near(value(i, .accelerationZ), 20.inch))
        #expect(near(value(i, .maxRPM), 18000) && value(i, .minRPM) == nil)
        #expect(i.setting(.accelerationXY)?.source.note?.contains("Motor0/Motor1/Motor3 MaxAccel ÷ CountsPerUnit") == true)
    }

    @Test func linuxCNCIni() throws {
        let ini = """
        [EMC]
        MACHINE = Bench router
        [TRAJ]
        LINEAR_UNITS = mm
        MAX_LINEAR_VELOCITY = 100
        [AXIS_X]
        MIN_LIMIT = -1
        MAX_LIMIT = 600
        MAX_VELOCITY = 100
        MAX_ACCELERATION = 750
        [AXIS_Y]
        MIN_LIMIT = 0
        MAX_LIMIT = 900
        MAX_VELOCITY = 80
        MAX_ACCELERATION = 600
        [AXIS_Z]
        MIN_LIMIT = -120
        MAX_LIMIT = 0.001
        MAX_VELOCITY = 25
        MAX_ACCELERATION = 400
        [SPINDLE_0]
        MAX_FORWARD_VELOCITY = 24000
        MIN_FORWARD_VELOCITY = 6000
        """
        let i = try MachineSettingsImporter.read(ini)
        #expect(i.format == .linuxCNC && i.machineName == "Bench router" && i.controller?.family == .linuxCNC)
        #expect(near(value(i, .travelX), 601) && near(value(i, .travelY), 900))
        #expect(near(value(i, .rapidXY), 4800) && near(value(i, .rapidZ), 1500)) // per second × 60
        #expect(near(value(i, .accelerationXY), 600) && near(value(i, .accelerationZ), 400))
        #expect(near(value(i, .minRPM), 6000) && near(value(i, .maxRPM), 24000))
    }

    @Test func fluidNCConfig() throws {
        let yaml = """
        name: "Garage router"
        board: 6 Pack
        stepping:
          engine: RMT
        axes:
          shared_stepper_disable_pin: NO_PIN
          x:
            steps_per_mm: 80.000
            max_rate_mm_per_min: 8000.000
            acceleration_mm_per_sec2: 300.000
            max_travel_mm: 1200.000
            homing:
              cycle: 2
              mpos_mm: 0.000
          y:
            steps_per_mm: 80.000
            max_rate_mm_per_min: 7000.000 # gantry
            acceleration_mm_per_sec2: 250.000
            max_travel_mm: 1200.000
          z:
            steps_per_mm: 400.000
            max_rate_mm_per_min: 2000.000
            acceleration_mm_per_sec2: 150.000
            max_travel_mm: 150.000
        10V:
          forward_pin: gpio.4
          speed_map: 0=0.000% 1000=0.000% 24000=100.000%
        """
        let i = try MachineSettingsImporter.read(yaml)
        #expect(i.format == .fluidNC && i.machineName == "Garage router" && i.controller?.family == .fluidNC)
        #expect(near(value(i, .travelX), 1200) && near(value(i, .travelZ), 150))
        #expect(near(value(i, .rapidXY), 7000) && near(value(i, .rapidZ), 2000))
        #expect(near(value(i, .accelerationXY), 250) && near(value(i, .accelerationZ), 150))
        #expect(near(value(i, .maxRPM), 24000))
    }

    @Test func fusionMachineDefinition() throws {
        let mch = """
        {"general": {"vendor": "Example", "model": "Router 4x4"},
         "kinematics": {"default": {"units": {"length": "mm"}, "parts": [
            {"id": "X", "type": "linear", "min": -600, "max": 600, "parts": [
              {"id": "Y", "type": "linear", "min": 0, "max": 1220, "parts": [
                {"id": "Z", "type": "linear", "min": -150, "max": 0, "spindle": {"max_speed": 24000, "min_speed": 8000}}]}]}]}},
         "controller": {"synced_configuration": {"parts": {"x": {"max_normal_speed": 7500, "max_rapid_speed": 15000},
                                                           "y": {"max_normal_speed": 7000, "max_rapid_speed": 14000},
                                                           "z": {"max_normal_speed": 3000, "max_rapid_speed": 5000}}}},
         "machining": {"default": {"tool_change_time": 15, "feedrate_ratio": 1}},
         "tooling": {"default": {"has_tool_changer": true, "number_of_tools": 8}}}
        """
        let i = try MachineSettingsImporter.read(mch)
        #expect(i.format == .fusion && i.machineName == "Example Router 4x4")
        #expect(near(value(i, .travelX), 1200) && near(value(i, .travelY), 1220) && near(value(i, .travelZ), 150))
        #expect(near(value(i, .rapidXY), 14000) && near(value(i, .maxFeed), 7000) && near(value(i, .rapidZ), 5000))
        #expect(near(value(i, .maxRPM), 24000) && near(value(i, .minRPM), 8000) && near(value(i, .toolChangeSeconds), 15))
        #expect(value(i, .accelerationXY) == nil && i.hasToolChanger == true)
        #expect(i.setting(.travelX)?.source.kind == .vendor)
    }

    @Test func applyingRecordsSourcesAndOnlyChosenValues() throws {
        let i = try MachineSettingsImporter.read("$110=5000\n$111=5000\n$112=1500\n$120=500\n$121=500\n$122=200\n$130=800\n$131=800\n$132=100\n")
        var m = MachineProfile()
        i.apply(to: &m, keys: [.accelerationXY, .travelX, .travelY], controller: true)
        #expect(m.accelerationXY == 500 && m.travel.x == 800 && m.travel.y == 800)
        #expect(m.rapidRateZ == nil) // not chosen
        #expect(m.model == .custom)   // travel no longer matches the PRO6060
        #expect(m.controller?.family == .grbl)
        #expect(m.source(of: .accelerationXY)?.kind == .controllerSettings)
        #expect(m.source(of: .travel)?.note?.contains("$13") == true)
        // A Mach4 import leaves the controller (Avid's profile) alone.
        var avid = MachineProfile()
        let ini = try MachineSettingsImporter.read("[Axis0]\nChildMotor0=Motor0\n[Motor0]\nCountsPerUnit=2000\nMaxVelocity=20000\nMaxAccel=30000\n")
        ini.apply(to: &avid, keys: Set(ini.settings.map(\.key)))
        #expect(avid.isLegacyAvidMach4 && avid.model == .pro6060)
        #expect(abs(avid.axisAcceleration.x - 15.inch) < 0.01)
    }

    @Test func formatsNativeCAMCantReadSayWhy() {
        #expect(throws: MachineImportError.self) { try MachineSettingsImporter.read("<profile><Preferences><Vel0>12</Vel0></Preferences></profile>") }
        #expect(throws: MachineImportError.self) { try MachineSettingsImporter.read("just some text\nwith nothing in it") }
    }
}
