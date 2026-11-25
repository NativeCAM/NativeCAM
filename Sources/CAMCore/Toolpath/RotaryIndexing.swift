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
            for op in ops where op.kind.turnsWholeBlank {
                issues.append(JobIssue(.error, (op.kind.needsShapes ? "3D rotary finishing cuts a model on a rotary blank"
                    : "Rounding turns a rotary blank") + ", but the material isn't one. Set up rotary stock.", operation: op.name))
            }
            return issues
        }

        if !stock.matchesRotaryBlank {
            issues.append(JobIssue(.error, blank.isWrapped
                ? "The material size doesn't match the rotary blank: on a wrapped job the design sheet is the blank unrolled, "
                    + "\(fmt(blank.length)) long × \(fmt(blank.circumference)) round, \(fmt(blank.topRadius)) to the axis. "
                    + "Set the blank again to resize it."
                : "The material size doesn't match the rotary blank: on rotary stock the design sheet is "
                    + "one face, \(fmt(blank.length)) long × \(fmt(blank.diameter)) across, \(fmt(blank.radius)) to the axis. "
                    + "Set the blank again to resize it."))
        }
        // The machine has to be able to turn the blank, and the post has to be able to say so: with A moves, or
        // with a stop (M0) for each turn when the blank is turned by hand.
        let manual = machine.rotary?.turnsByHand ?? false
        if let axis = machine.rotary {
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
            } else if let axis = machine.rotary, !dialect.rotaryAlignments.contains(axis.alignment) {
                issues.append(JobIssue(.error, "NativeCAM writes moves for a rotary axis along \(axis.alignment.axisName) only for "
                    + "Avid Mach4, LinuxCNC and grblHAL so far, not \(dialect.name). If you turn the blank by hand or with an "
                    + "indexer, turn on Turn by hand under Rotary Axis."))
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

        if blank.isWrapped {
            issues += wrappedIssues(project, toolpaths: toolpaths)
            return issues + closingNotes(machine, manual: false)
        }

        issues += roundingIssues(project)
        for op in ops {
            switch op.kind {
            case .rough3D, .finish3D, .moulding:
                issues.append(JobIssue(.error, "3D Roughing and 3D Finishing cut flat sheets: on rotary stock, use 3D Rotary "
                    + "Roughing and Finishing.", operation: op.name))
            case .rounding, .rotaryFinish, .rotaryRough: continue
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
            for tp in toolpaths where tp.wrapDiameter == nil {
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

        return issues + closingNotes(machine, manual: manual)
    }

    /// The notes every rotary job ends with: how a blank turned by hand is asked for, and the centre height.
    static func closingNotes(_ machine: MachineProfile, manual: Bool) -> [JobIssue] {
        var issues: [JobIssue] = []
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

    /// Wrapped jobs: what the blank, the controller and each operation need for designs wrapped around the blank.
    static func wrappedIssues(_ project: Project, toolpaths: [Toolpath]) -> [JobIssue] {
        guard let blank = project.stock.rotary else { return [] }
        let u = project.displayUnits
        func fmt(_ mm: Double) -> String { "\(u.format(mm)) \(u.symbol)" }
        var issues: [JobIssue] = []
        let wrap = blank.wrapDiameterOrBlank
        // A rounding that turns the blank down to the wrap diameter (or less) makes it round there.
        let rounded = project.operations.contains { op in
            guard op.enabled, case let .rounding(p) = op.kind else { return false }
            return 2 * RoundingGenerator.finishedRadius(p, blank: blank) <= wrap + 1e-6
        }
        if blank.shape == .squareBar && !rounded {
            issues.append(JobIssue(.error, "Wrapped designs need a round blank: a square bar's faces aren't at the wrap diameter, "
                + "so cuts would come out deeper in the middle of each face than at its edges. Add a Rounding toolpath that turns "
                + "it down to the wrap diameter first, or lay the design out on faces."))
        }
        issues += roundingIssues(project)
        if wrap > blank.diameter + 1e-6 {
            issues.append(JobIssue(.error, "The wrap diameter (\(fmt(wrap))) is bigger than the blank (\(fmt(blank.diameter))), so "
                + "the shallow cuts would be in the air. Set it to the blank's diameter or less."))
        } else if wrap < blank.diameter - 1e-6 && !rounded {
            issues.append(JobIssue(.warning, "Designs wrap at \(fmt(wrap)), smaller than the \(fmt(blank.diameter)) blank, so every "
                + "cut starts \(fmt((blank.diameter - wrap) / 2)) below the blank's surface. Turn the blank down to \(fmt(wrap)) "
                + "first."))
        }
        if let problem = wrappedFeedIssue(project.machine) {
            issues.append(JobIssue(.error, problem + " Lay the design out on faces for this machine."))
        }
        for op in project.operations where op.enabled && op.kind.needsShapes && !op.kind.turnsWholeBlank {
            if op.indexAngles != nil {
                issues.append(JobIssue(.error, "Has index angles, but on a wrapped job each shape's place on the sheet sets the "
                    + "angle it's cut at. Clear the angles.", operation: op.name))
            }
            switch op.kind {
            case .rough3D, .finish3D, .moulding:
                issues.append(JobIssue(.error, "3D Roughing and 3D Finishing cut flat sheets: on rotary stock, use 3D Rotary "
                    + "Roughing and Finishing.", operation: op.name))
            default: break
            }
        }
        // A spiral climbs one sheet height per turn; laid out for another wrap diameter, its turns don't meet.
        for shape in project.shapes {
            guard case let .spiral(spec) = shape.kind, abs(spec.around - project.stock.height) > 1e-6 else { continue }
            issues.append(JobIssue(.warning, "The spiral “\(shape.name)” was laid out for a sheet \(fmt(spec.around)) high, but this "
                + "one is \(fmt(project.stock.height)), so its turns won't meet. Set the blank again to refit it."))
        }
        // A wrapped design is true to size only at the wrap diameter; deeper in, the same angle spans less.
        // A radial hole is a hole at any depth, so drilling is left out, and rounding cuts to its own diameter. Flutes
        // that follow a model are as deep as the model is, and spaced round it by angle, as a turning's flutes are.
        let radius = blank.topRadius
        var reported = Set(project.operations.filter { op in
            if case .drill = op.kind { return true }
            if case let .fluting(f) = op.kind, f.surfaceModelID != nil { return true }
            return op.kind.turnsWholeBlank
        }.map(\.id))
        for tp in toolpaths where tp.wrapDiameter != nil && !reported.contains(tp.sourceOperationID) {
            guard let e = tp.cuttingExtents else { continue }
            let depth = -e.min.z
            guard radius > 0, depth > Self.distortionWarning * radius else { continue }
            reported.insert(tp.sourceOperationID)
            let shrink = Int((min(depth / radius, 1) * 100).rounded())
            issues.append(JobIssue(.warning, "Cuts \(fmt(depth)) deep into a \(fmt(radius)) wrap radius. A wrapped design is true "
                + "to size only at the wrap diameter: at the bottom of this cut it comes out \(shrink)% narrower around the "
                + "blank.", operation: tp.name))
        }
        let mounting = project.machine.rotary?.alignment ?? .x
        issues.append(JobIssue(.info, "Before the first wrapped cut, jog the rotary axis positive: the top of the blank should "
            + "roll toward \(mounting.topRolls(reversed: false)). If it rolls toward \(mounting.topRolls(reversed: true)), tick "
            + "Reversed, or wrapped designs come out mirrored."))
        return issues
    }

    /// Why the machine's controller can't be given the right feed for moves that turn the blank; nil when it can.
    static func wrappedFeedIssue(_ machine: MachineProfile) -> String? {
        if machine.rotary?.turnsByHand == true {
            return "Cuts that turn the blank need a rotary axis the controller drives: the blank turns while the tool cuts, "
                + "which can't be done by hand. Turn off Turn by hand."
        }
        guard machine.customPost == nil, let dialect = Dialect.for(machine), dialect.rotaryAxes.contains(letter),
              RotaryWrap.feedMode(dialect) == nil else { return nil }
        return "\(dialect.name) has no inverse-time feed (G93), and what F means there when the rotary axis turns isn't "
            + "documented, so NativeCAM can't give cuts that turn the blank the right feed."
    }

    /// Rounding and 3D rotary roughing and finishing on a rotary job, on faces or wrapped: they cut all the way round the
    /// blank, so they take no index angles, and they turn the blank while cutting, so the controller has to be able to
    /// feed that.
    static func roundingIssues(_ project: Project) -> [JobIssue] {
        let whole = project.operations.filter { $0.enabled && $0.kind.turnsWholeBlank }
        guard !whole.isEmpty else { return [] }
        var issues: [JobIssue] = []
        for op in whole where op.indexAngles != nil {
            let what: String
            switch op.kind {
            case .rotaryFinish: what = "3D rotary finishing"
            case .rotaryRough: what = "3D rotary roughing"
            default: what = "Rounding"
            }
            issues.append(JobIssue(.error, "\(what) turns the whole blank, so index angles don't apply. Clear them.", operation: op.name))
        }
        if project.stock.rotary?.isWrapped != true, let problem = wrappedFeedIssue(project.machine) {
            issues.append(JobIssue(.error, problem, operation: whole[0].name))
        }
        return issues
    }

    /// Depth, as a fraction of the wrap radius, past which a wrapped cut is warned about (research §5.3).
    static let distortionWarning = 0.1

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

    /// The A word for a value as written.
    func word(value v: Double) -> String { "\(letter)\(String(format: "%.3f", v == 0 ? 0 : v))" }

    /// `a` (as written) moved by whole turns to within a turn of `last` when it's more than a turn away: the same
    /// orientation of the blank, without winding back every turn a long wrapped cut (a rounding pass) has made.
    static func nearestTurn(_ a: Double, after last: Double?) -> Double {
        guard let last, abs(last - a) > 360 else { return a }
        let v = ((a + 360 * ((last - a) / 360).rounded()) * 1000).rounded() / 1000
        return v == 0 ? 0 : v
    }

    /// Where the blank turns to at the end of the program: back to A0, unless that would wind back more than
    /// `maxUnwindTurns`; then on to the nearest whole turn, which is the same orientation.
    static func home(after last: Double) -> Double {
        guard abs(last) > 360 * Double(maxUnwindTurns) else { return 0 }
        let v = 360 * (last / 360).rounded()
        return v == 0 ? 0 : v
    }

    /// Turns the program end winds back at most, at A's rapid rate.
    static let maxUnwindTurns = 10

    /// The A values a program of `paths` cuts at, as the posts write them (the Avid post's program-extents comment): a
    /// wrapped toolpath's feed moves, each toolpath started a whole number of turns on from where the one before left
    /// the blank (`WrappedWriter.approach`), and the angle each face is cut at. nil when the program writes no A for a
    /// cut (a blank turned by hand). `units` and `decimals` are the post's coordinates', which decide the moves it
    /// writes.
    func cutRange(_ paths: [Toolpath], frame: RotaryFrame, units: LengthUnit, decimals: Int) -> ClosedRange<Double>? {
        struct State: WrapModalState { var x: Double?, y: Double?, z: Double?, feed: Double?, a: Double? }
        let stock = frame.stock
        let writer = WrappedWriter(frame: frame, rotary: self, units: units, decimals: decimals, feedDecimals: 1, feeds: .inverseTime,
                                   turnSpeed: .infinity, rapidWord: "G0", feedWord: "G1", dwell: { _ in "" })
        var state = State()
        var lastA: Double?
        var range: ClosedRange<Double>?
        func cuts(_ r: ClosedRange<Double>) {
            range = range.map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r
        }
        for tp in paths {
            // Every toolpath starts from safe Z.
            state.z = writer.round(stock.toWork(Vec3(0, 0, stock.clearanceHeight)).z)
            if tp.wrapDiameter != nil {
                let approach = writer.approach(tp, state: &state, after: lastA)
                if let a = writer.motions(tp, state: &state, offset: approach.offset).cutA { cuts(a) }
                lastA = state.a ?? lastA
                continue
            }
            if !manual, let angle = tp.indexAngle {
                let target = Self.nearestTurn(value(angle), after: lastA)
                state.a = target
                lastA = target
            }
            if let a = state.a, tp.motions.contains(where: { $0.kind != .rapid && $0.kind != .dwell }) { cuts(a...a) }
        }
        return range
    }

    /// The note before the end of a program that leaves A on a whole turn other than 0.
    static func homeNote(_ home: Double, avid: Bool) -> String? {
        guard home != 0 else { return nil }
        let turns = Int((abs(home) / 360).rounded())
        return "A finishes \(turns) whole turns from where it started, so it doesn't wind back: zero A"
            + (avid ? " (Avid: Rotary tab > Zero A)" : "") + " before the next job"
    }

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

    /// Where zero along the blank is: X zero, or Y zero on an axis along Y.
    static func xZero(_ stock: Stock, alignment: RotaryAxis.Alignment = .x) -> String {
        switch stock.xyOrigin {
        case .lowerLeft, .upperLeft: "\(alignment.endName(start: true)) end of the blank"
        case .lowerRight, .upperRight: "\(alignment.endName(start: false)) end of the blank"
        case .center: "middle of the blank"
        }
    }

    /// Header comments for the blank and the zeros, in place of the flat job's material and zero lines. A wrapped
    /// job also says how the sheet wraps and how its rotary moves are fed (`feeds`).
    static func header(_ stock: Stock, units: LengthUnit, num: (Double) -> String, avid: Bool, axis: RotaryAxis? = nil,
                       feeds: RotaryWrap.FeedMode? = nil, turnsWhileCutting: Bool = false) -> [String] {
        guard let blank = stock.rotary else { return [] }
        let mounting = axis?.alignment ?? .x
        let shape = blank.shape == .cylinder ? "round, D=\(num(blank.diameter))" : "square bar, \(num(blank.diameter)) across"
        var lines = [
            "Material: \(stock.materialName) rotary blank, \(shape), L=\(num(blank.length)) \(units.symbol)",
            "Z ZERO = CENTRE OF ROTATION" + (avid ? " (Avid: Rotary tab > Z Axis Touch)" : ""),
            mounting == .x
                ? "Y ZERO = AXIS CENTRELINE   X ZERO = \(xZero(stock).uppercased())"
                : "X ZERO = AXIS CENTRELINE   Y ZERO = \(xZero(stock, alignment: mounting).uppercased())",
        ]
        if mounting == .y { lines.append("Rotary axis along Y: A turns about +Y") }
        if blank.isWrapped {
            let sheet = mounting == .x ? "" : "sheet "
            lines.append("Wrapped: sheet Y wraps around D=\(num(blank.wrapDiameterOrBlank)), A = \(sheet)Y x 360 / (pi x D), A0 = middle of the sheet")
        }
        if blank.isWrapped || turnsWhileCutting {
            switch feeds {
            case .inverseTime?: lines.append("Feeds: G93 inverse time on moves that turn A, G94 otherwise")
            case .perMinute?: lines.append("Feeds: worked out per move for this controller's rotary feed rule")
            case nil: break
            }
        }
        lines.append("Raise the tool clear of the chuck and tailstock before Cycle Start")
        if let axis, axis.turnsByHand {
            lines += [
                "TURN THE BLANK BY HAND AT EACH STOP (M0)",
                "Angles count up as the top of the blank rolls toward \(axis.alignment.topRolls(reversed: axis.reversed, ascii: true))",
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
            + "\(axis.alignment.topRolls(reversed: axis.reversed)). Start with the blank at 0°."
    }

    /// The re-zero instruction after a tool change.
    static func rezero(_ stock: Stock, avid: Bool) -> String {
        stock.rotary == nil ? "" : "re-zero Z on the rotation axis" + (avid ? " (Avid: Rotary tab > Z Axis Touch)" : "")
    }
}
