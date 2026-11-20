import CryptoKit
import Foundation

/// Indexed (3+1) rotary work: the blank turns to a fixed angle, ordinary toolpaths cut the face under the spindle,
/// then it turns to the next angle. These helpers name and identify the toolpath for each angle and check that a
/// rotary job can be cut safely before anything is posted.
public enum RotaryIndex {
    /// The angle as a direction, 0 ≤ result < 360 (−90 and 270 are the same face).
    public static func normalized(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let n = r < 0 ? r + 360 : r
        // Round off float noise so 90.0000000001 and 90 are one face.
        let snapped = (n * 1e6).rounded() / 1e6
        return snapped >= 360 ? 0 : snapped
    }

    /// "90°", "22.5°".
    public static func label(_ degrees: Double) -> String {
        let rounded = (degrees * 1000).rounded() / 1000
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
        return text + "°"
    }

    /// The ID of the toolpath an operation cuts at its `position`-th angle (1 and up; the first angle keeps the
    /// generator's own ID). `role` tells apart the toolpaths one operation makes at one angle. It is stable from
    /// run to run, and can't equal a random (version 4) UUID, a hand-written fixture ID or an ID made by flipping
    /// bits of one, because it carries version 8 in byte 6.
    public static func toolpathID(operation: UUID, role: Int, position: Int) -> UUID {
        var bytes = withUnsafeBytes(of: operation.uuid) { Array($0) }
        bytes.append(contentsOf: Array("rotary-index".utf8))
        withUnsafeBytes(of: UInt32(role).littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(position).littleEndian) { bytes.append(contentsOf: $0) }
        var d = Array(SHA256.hash(data: Data(bytes)).prefix(16))
        d[6] = (d[6] & 0x0F) | 0x80
        d[8] = (d[8] & 0x3F) | 0x80
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    /// The letter the post writes for the rotary axis.
    static let letter: Character = "A"

    /// Why this job can't be cut as an indexed rotary job, and what to watch for. Empty on a flat job with no
    /// index angles.
    static func issues(_ project: Project, toolpaths: [Toolpath]) -> [JobIssue] {
        let stock = project.stock, machine = project.machine, u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var issues: [JobIssue] = []
        let ops = project.operations.filter(\.enabled)
        guard let blank = stock.rotary else {
            for op in ops where op.indexAngles != nil {
                issues.append(JobIssue(.error, "Has index angles, but the material isn't a rotary blank. Set up rotary stock "
                    + "or clear the angles.", operation: op.name))
            }
            return issues
        }

        if !stock.matchesRotaryBlank {
            issues.append(JobIssue(.error, "The material size doesn't match the rotary blank: on rotary stock the design sheet is "
                + "one face, \(fmt(blank.length)) long × \(fmt(blank.diameter)) across, \(fmt(blank.radius)) to the axis. "
                + "Set the blank again to resize it."))
        }
        // The machine has to be able to turn the blank, and the post has to be able to say so: with A moves, or
        // with a stop (M0) for each turn when the blank is turned by hand.
        let manual = machine.rotary?.turnsByHand ?? false
        if let axis = machine.rotary {
            if axis.alignment != .x {
                issues.append(JobIssue(.error, "NativeCAM can only cut rotary stock on a rotary axis that runs along X so far."))
            }
            if !manual, axis.letter.rawValue != String(letter) {
                issues.append(JobIssue(.error, "NativeCAM can only turn a rotary axis driven by A words so far; this machine's "
                    + "is \(axis.letter.rawValue)."))
            }
        } else {
            issues.append(JobIssue(.error, "The material is a rotary blank, but the machine has no rotary axis set up."))
        }
        if machine.customPost != nil {
            issues.append(JobIssue(.error, "An imported Vectric post can't turn the rotary axis. Use NativeCAM's own post for "
                + "rotary jobs."))
        } else if let dialect = Dialect.for(machine) {
            if manual {
                if dialect.language != .gcode {
                    issues.append(JobIssue(.error, "NativeCAM can't write the stops for turning the blank by hand in "
                        + "\(dialect.name) files yet."))
                } else if !dialect.writesComments {
                    issues.append(JobIssue(.error, "\(dialect.name) files carry no comments, so a stop can't say which angle to "
                        + "turn the blank to."))
                } else if dialect.allowedM?.contains(0) == false {
                    issues.append(JobIssue(.error, "\(dialect.name) can't stop the program (M0) for you to turn the blank."))
                }
            } else if dialect.language != .gcode || !dialect.rotaryAxes.contains(letter) {
                issues.append(JobIssue(.error, "\(dialect.name) has no A axis NativeCAM can write rotary moves for."
                    + (dialect.language == .gcode ? " If you turn the blank by hand or with an indexer, turn on Turn by hand "
                        + "under Rotary Axis." : "")))
            }
        }
        // Every turn happens at safe Z, which has to clear the blank's corners.
        if let least = stock.minimumRotaryClearance, stock.clearanceHeight < least - 1e-6 {
            issues.append(JobIssue(.error, "Safe Z is \(fmt(stock.clearanceHeight)) above the blank, but the blank turns at safe Z "
                + "and needs at least \(fmt(least)) to clear \(blank.shape == .squareBar ? "its corners" : "it") with margin."))
        }
        if project.shapes.contains(where: { $0.keepOutHeight != nil }) {
            issues.append(JobIssue(.error, "Clamps and keep-out zones aren't supported on rotary stock: they're drawn on the "
                + "flat sheet and would apply to every face."))
        }

        for op in ops {
            switch op.kind {
            case .rough3D, .finish3D:
                issues.append(JobIssue(.error, "3D toolpaths aren't supported on rotary stock yet.", operation: op.name))
            default: break
            }
            let angles = op.rotaryAngles
            if angles.isEmpty {
                issues.append(JobIssue(.error, "Has no index angles to cut at.", operation: op.name))
            }
            if Set(angles.map(normalized)).count < angles.count {
                issues.append(JobIssue(.error, "Lists the same face twice (angles that differ by whole turns).", operation: op.name))
            }
            if blank.shape == .squareBar, let odd = angles.first(where: { normalized($0).truncatingRemainder(dividingBy: 90) > 1e-6 }) {
                issues.append(JobIssue(.error, "Indexes a square bar to \(label(odd)). Square bars can only be cut at multiples of "
                    + "90°, where a face is square to the spindle; at other angles the bar's corner stands above the face "
                    + "and the tool would plunge into it.", operation: op.name))
            }
        }

        // On a round blank only the top line of a face is at Z = 0; the surface falls away to either side. Each
        // operation is reported once, for the farthest any of its toolpaths reaches (a V-carve's flat clearing and
        // its V-bit, say; every angle cuts the same).
        if blank.shape == .cylinder {
            var order: [UUID] = []
            var reach: [UUID: (dy: Double, name: String, carve: Bool)] = [:]
            for tp in toolpaths {
                let opID = tp.sourceOperationID
                guard let dy = reachFromTopLine(tp, centre: stock.height / 2) else { continue }
                if let r = reach[opID] {
                    reach[opID]?.dy = max(r.dy, dy)
                } else {
                    order.append(opID)
                    let carve = project.operations.first { $0.id == opID }.map { if case .vcarve = $0.kind { true } else { false } } ?? false
                    reach[opID] = (dy, tp.name, carve)
                }
            }
            for opID in order {
                guard let (dy, name, carve) = reach[opID] else { continue }
                let r = blank.radius
                let sag = dy >= r ? r : r - (r * r - dy * dy).squareRoot()
                if sag > 0.1 {
                    issues.append(JobIssue(.warning, "Reaches \(fmt(dy)) from the top line of the round blank, where its surface is "
                        + "\(fmt(sag)) lower, so cuts there are that much shallower than set"
                        + (carve ? ", and the carve is narrower than drawn." : "."), operation: name))
                }
            }
        }

        if manual {
            issues.append(JobIssue(.info, "The blank is turned by hand: the program stops with the spindle off before each new "
                + "angle and says which angle to turn it to."))
        }
        if machine.rotary != nil, machine.rotary?.centerHeight == nil {
            issues.append(JobIssue(.info, "Measure the rotary's centre height above the spoilboard so NativeCAM can check that the "
                + "job fits under the Z travel."))
        }
        return issues
    }

    /// How far across the face (from its top line, in Y) the cutter reaches into the surface. A V-bit is only as
    /// wide as it is deep, so it's measured at each point of the cut rather than at the bit's full diameter.
    static func reachFromTopLine(_ tp: Toolpath, centre: Double) -> Double? {
        let tool = tp.tool
        guard tool.shape.isTapered else {
            guard let e = tp.cuttingExtents else { return nil }
            return max(abs(e.min.y - centre), abs(e.max.y - centre)) + tool.radius
        }
        var far: Double?
        tp.forEachMotion { s, m in
            guard m.kind != .rapid, m.kind != .dwell else { return }
            for p in [s, m.end] where p.z < 0 {
                let r = min(tool.radius, tool.tipDiameter / 2 + -p.z * tool.halfAngleTangent)
                far = max(far ?? 0, abs(p.y - centre) + r)
            }
        }
        return far
    }
}

/// What a post writes for an indexed rotary job: the A word for each toolpath's angle and the setup notes in the
/// header. nil on a flat job, which writes nothing new.
struct RotaryOutput {
    var letter: String
    var reversed: Bool
    /// Nothing drives the axis: the post stops the program (M0) with the spindle off and asks for each turn, in
    /// place of an A move.
    var manual: Bool

    init?(_ project: Project) {
        guard project.stock.rotary != nil else { return nil }
        letter = project.machine.rotary?.letter.rawValue ?? String(RotaryIndex.letter)
        reversed = project.machine.rotary?.reversed ?? false
        manual = project.machine.rotary?.turnsByHand ?? false
    }

    /// The A value for a toolpath turned to `angle` (degrees, right-hand rule), rounded as written: flipped when the
    /// machine's rotary turns the other way.
    func value(_ angle: Double) -> Double {
        let v = ((reversed ? -angle : angle) * 1000).rounded() / 1000
        return v == 0 ? 0 : v
    }

    func word(_ angle: Double) -> String { "\(letter)\(String(format: "%.3f", value(angle)))" }

    /// Where the blank has to be for a toolpath turned to `angle`: the A value, or on a blank turned by hand the
    /// reading on the indexer's dial, 0 ≤ reading < 360.
    func position(_ angle: Double) -> Double { manual ? RotaryIndex.normalized(value(angle)) : value(angle) }

    /// The comment before the stop that asks for a turn by hand. `resume` is how the controller carries on.
    func turnMessage(_ angle: Double, resume: String) -> String {
        "Turn the blank to \(RotaryIndex.label(position(angle))), then \(resume)"
    }

    /// The dial reading a stop's message asks for, when it's one of `turnMessage`'s (as written in a comment, with
    /// ° spelled "deg").
    static func manualTurn(in message: String) -> Double? {
        let text = message.uppercased()
        guard let lead = text.range(of: "TURN THE BLANK TO ") else { return nil }
        let number = text[lead.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(number)
    }

    /// Where X zero is on the blank.
    static func xZero(_ stock: Stock) -> String {
        switch stock.xyOrigin {
        case .lowerLeft, .upperLeft: "left end of the blank"
        case .lowerRight, .upperRight: "right end of the blank"
        case .center: "middle of the blank"
        }
    }

    /// Header comments for the blank and the zeros, in place of the flat job's material and zero lines.
    static func header(_ stock: Stock, units: LengthUnit, num: (Double) -> String, avid: Bool, axis: RotaryAxis? = nil) -> [String] {
        guard let blank = stock.rotary else { return [] }
        let shape = blank.shape == .cylinder ? "round, D=\(num(blank.diameter))" : "square bar, \(num(blank.diameter)) across"
        var lines = [
            "Material: \(stock.materialName) rotary blank, \(shape), L=\(num(blank.length)) \(units.symbol)",
            "Z ZERO = CENTRE OF ROTATION" + (avid ? " (Avid: Rotary tab > Z Axis Touch)" : ""),
            "Y ZERO = AXIS CENTRELINE   X ZERO = \(xZero(stock).uppercased())",
            "Raise the tool clear of the chuck and tailstock before Cycle Start",
        ]
        if let axis, axis.turnsByHand {
            lines += [
                "TURN THE BLANK BY HAND AT EACH STOP (M0)",
                "Angles count up as the top of the blank rolls toward \(axis.reversed ? "+Y" : "-Y")",
            ]
        }
        return lines
    }

    /// The setup sheet's line for how the blank turns.
    static func setupNote(_ machine: MachineProfile) -> String {
        guard let axis = machine.rotary, axis.turnsByHand else {
            return "Turns on \(machine.rotary?.letter.rawValue ?? String(RotaryIndex.letter)) between faces, with the tool at safe Z."
        }
        return "Turned by hand. The program stops with the spindle off and the tool at safe Z before each new angle, and "
            + "says which angle to turn the blank to. Angles count up as the top of the blank rolls toward "
            + "\(axis.reversed ? "+Y" : "−Y"). Start with the blank at 0°."
    }

    /// The re-zero instruction after a tool change.
    static func rezero(_ stock: Stock, avid: Bool) -> String {
        stock.rotary == nil ? "" : "re-zero Z on the rotation axis" + (avid ? " (Avid: Rotary tab > Z Axis Touch)" : "")
    }
}
