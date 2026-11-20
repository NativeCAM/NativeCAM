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
        // The machine has to be able to turn the blank, and the post has to be able to say so.
        if let axis = machine.rotary {
            if axis.alignment != .x {
                issues.append(JobIssue(.error, "NativeCAM can only cut rotary stock on a rotary axis that runs along X so far."))
            }
            if axis.letter.rawValue != String(letter) {
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
            if dialect.language != .gcode || !dialect.rotaryAxes.contains(letter) {
                issues.append(JobIssue(.error, "\(dialect.name) has no A axis NativeCAM can write rotary moves for."))
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
            case .vcarve: issues.append(JobIssue(.error, "V-carving isn't supported on rotary stock yet.", operation: op.name))
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

        // On a round blank only the top line of a face is at Z = 0; the surface falls away to either side.
        if blank.shape == .cylinder {
            var reported = Set<UUID>()
            for tp in toolpaths {
                let opID = tp.sourceOperationID
                guard !reported.contains(opID), let e = tp.cuttingExtents else { continue }
                reported.insert(opID)
                let dy = max(abs(e.min.y - stock.height / 2), abs(e.max.y - stock.height / 2)) + tp.tool.radius
                let r = blank.radius
                let sag = dy >= r ? r : r - (r * r - dy * dy).squareRoot()
                if sag > 0.1 {
                    issues.append(JobIssue(.warning, "Reaches \(fmt(dy)) from the top line of the round blank, where its surface is "
                        + "\(fmt(sag)) lower, so cuts there are that much shallower than set.", operation: tp.name))
                }
            }
        }

        if machine.rotary != nil, machine.rotary?.centerHeight == nil {
            issues.append(JobIssue(.info, "Measure the rotary's centre height above the spoilboard so NativeCAM can check that the "
                + "job fits under the Z travel."))
        }
        issues.append(JobIssue(.warning, "The simulation shows every face on one flat sheet; it doesn't turn the blank yet."))
        return issues
    }
}

/// What a post writes for an indexed rotary job: the A word for each toolpath's angle and the setup notes in the
/// header. nil on a flat job, which writes nothing new.
struct RotaryOutput {
    var letter: String
    var reversed: Bool

    init?(_ project: Project) {
        guard project.stock.rotary != nil else { return nil }
        letter = project.machine.rotary?.letter.rawValue ?? String(RotaryIndex.letter)
        reversed = project.machine.rotary?.reversed ?? false
    }

    /// The A value for a toolpath turned to `angle` (degrees, right-hand rule), rounded as written: flipped when the
    /// machine's rotary turns the other way.
    func value(_ angle: Double) -> Double {
        let v = ((reversed ? -angle : angle) * 1000).rounded() / 1000
        return v == 0 ? 0 : v
    }

    func word(_ angle: Double) -> String { "\(letter)\(String(format: "%.3f", value(angle)))" }

    /// Where X zero is on the blank.
    static func xZero(_ stock: Stock) -> String {
        switch stock.xyOrigin {
        case .lowerLeft, .upperLeft: "left end of the blank"
        case .lowerRight, .upperRight: "right end of the blank"
        case .center: "middle of the blank"
        }
    }

    /// Header comments for the blank and the zeros, in place of the flat job's material and zero lines.
    static func header(_ stock: Stock, units: LengthUnit, num: (Double) -> String, avid: Bool) -> [String] {
        guard let blank = stock.rotary else { return [] }
        let shape = blank.shape == .cylinder ? "round, D=\(num(blank.diameter))" : "square bar, \(num(blank.diameter)) across"
        return [
            "Material: \(stock.materialName) rotary blank, \(shape), L=\(num(blank.length)) \(units.symbol)",
            "Z ZERO = CENTRE OF ROTATION" + (avid ? " (Avid: Rotary tab > Z Axis Touch)" : ""),
            "Y ZERO = AXIS CENTRELINE   X ZERO = \(xZero(stock).uppercased())",
            "Raise the tool clear of the chuck and tailstock before Cycle Start",
        ]
    }

    /// The re-zero instruction after a tool change.
    static func rezero(_ stock: Stock, avid: Bool) -> String {
        stock.rotary == nil ? "" : "re-zero Z on the rotation axis" + (avid ? " (Avid: Rotary tab > Z Axis Touch)" : "")
    }
}
