import Foundation

/// Fitting the machine's motion values to times measured with the calibration programs (`Calibration`).
///
/// The timing suite fits the X/Y and Z accelerations, the Z rapid rate and the corner tolerance (junction deviation) by
/// least squares on each section's relative error, against `CycleTimeEstimator` running the same sections; the rotary
/// check fits the turn speed. The F-change line with two feeds isn't fitted: its time against the single-feed line
/// says whether the controller kept constant velocity through the changes of F. Nothing changes a machine until
/// `FitResult.apply(to:date:)`, which writes the fitted values (marked as measured) into the profile it's given.
public extension Calibration {
    /// The share by which the F-change line with two feeds may run slower than the single-feed line, beyond what the
    /// estimates expect, and still count as keeping constant velocity: a few times what a stopwatch can tell.
    static let fChangeTolerance = 0.03
    /// The most a fitted section may still be off for the fit to stand.
    static let fitTolerance = 0.20

    // MARK: Times files

    /// Times measured on the machine for one program, as the times file holds them.
    struct Times: Hashable, Sendable {
        public var kind: Kind
        /// The dialect the program was posted for (`Dialect.id`).
        public var controller: String
        /// The timing suite's plan.
        public var plan: TimingPlan?
        /// The rotary check's axis letter.
        public var axisLetter: String?
        /// Seconds by section ID; a section left blank isn't here.
        public var measured: [String: Double]

        public init(kind: Kind, controller: String, plan: TimingPlan? = nil, axisLetter: String? = nil, measured: [String: Double] = [:]) {
            self.kind = kind
            self.controller = controller
            self.plan = plan
            self.axisLetter = axisLetter
            self.measured = measured
        }

        /// The times for `program`, with nothing measured yet.
        public init(_ program: Program, measured: [String: Double] = [:]) {
            self.init(kind: program.kind, controller: program.dialect.id, plan: program.plan, axisLetter: program.axisLetter,
                      measured: measured)
        }
    }

    /// The times file saved beside a program: what it's made of (so the fit can rebuild it exactly), then a row for each
    /// section with NativeCAM's estimate and a `measured_s` column for the stopwatch's seconds.
    static func timesCSV(_ program: Program, measured: [String: Double] = [:]) -> String {
        var lines = [
            "# NativeCAM calibration times for the \(program.kind.label.lowercased()) (\(program.fileName)).",
            "# Write the seconds you timed in measured_s, leaving a section blank to skip it. Then open this file in",
            "# File > Calibration Programs > Enter Times, or run: nativecam-cli calibrate fit <this file> [project.nativecam]",
            "program,\(program.kind.rawValue)",
            "controller,\(program.dialect.id)",
        ]
        if let plan = program.plan {
            lines += [
                "units,\(plan.units.rawValue)",
                "window_mm,\(plan.window.x),\(plan.window.y)",
                "air_height_mm,\(plan.airHeight)",
                "z_stroke_mm,\(plan.zStroke)",
                "feeds_mm_min,\(plan.feeds.map { "\($0)" }.joined(separator: ","))",
            ]
        }
        if let letter = program.axisLetter { lines.append("axis,\(letter)") }
        lines.append("section,count,name,estimate_s,measured_s")
        for s in program.sections {
            let m = measured[s.id].map { String(format: "%.1f", $0) } ?? ""
            lines.append([s.id, String(s.count), field(s.name), String(format: "%.1f", s.estimate), m].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func field(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// Splits one CSV line, honouring double quotes.
    private static func fields(_ line: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { current.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// Reads a times file (`timesCSV`, filled in). Refused with the line and the reason when it can't be read.
    static func readTimes(_ text: String) throws -> Times {
        var kind: Kind?, controller: String?, units: LengthUnit?, window: Vec2?, air: Double?, stroke: Double?, feeds: [Double]?
        var letter: String?
        var counts: [String: Int] = [:], measured: [String: Double] = [:]
        var inSections = false
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let n = index + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = fields(line)
            func numbers(_ count: Int) throws -> [Double] {
                let values = f.dropFirst().prefix(count).compactMap { Double($0) }
                guard values.count == count, f.count > count else { throw Refused("Line \(n): \(f[0]) needs \(count) number\(count == 1 ? "" : "s").") }
                return values
            }
            if inSections {
                guard f.count >= 2, let count = Int(f[1]), count > 0 else { throw Refused("Line \(n): “\(line)” isn't a section row.") }
                counts[f[0]] = count
                let value = f.count >= 5 ? f[4] : ""
                if !value.isEmpty {
                    guard let seconds = Double(value.replacingOccurrences(of: "s", with: "")), seconds.isFinite else {
                        throw Refused("Line \(n): “\(value)” isn't a number of seconds.")
                    }
                    measured[f[0]] = seconds
                }
                continue
            }
            switch f[0] {
            case "program":
                guard f.count > 1, let k = Kind(rawValue: f[1]), k != .ladder else { throw Refused("Line \(n): the ladder has no times to fit.") }
                kind = k
            case "controller": controller = f.count > 1 ? f[1] : nil
            case "units": units = f.count > 1 ? LengthUnit(rawValue: f[1]) : nil
            case "window_mm": let v = try numbers(2); window = Vec2(v[0], v[1])
            case "air_height_mm": air = try numbers(1)[0]
            case "z_stroke_mm": stroke = try numbers(1)[0]
            case "feeds_mm_min": feeds = try numbers(3)
            case "axis": letter = f.count > 1 ? f[1] : nil
            case "section": inSections = true
            default: throw Refused("Line \(n): “\(f[0])” isn't something a NativeCAM times file holds.")
            }
        }
        guard let kind else { throw Refused("This isn't a NativeCAM times file: it has no “program” line.") }
        guard let controller, !controller.isEmpty else { throw Refused("The times file doesn't say which controller its program was for.") }
        var times = Times(kind: kind, controller: controller, axisLetter: letter, measured: measured)
        if kind == .timing {
            guard let units, let window, let air, let stroke, let feeds else {
                throw Refused("The times file is missing the timing suite's units, window, air height, Z stroke or feeds.")
            }
            guard air >= minimumAirHeight - 1e-6, window.x > 0, window.y > 0, stroke > 0, feeds.allSatisfy({ $0 > 0 }) else {
                throw Refused("The times file's window, heights or feeds aren't ones NativeCAM writes.")
            }
            for kind in TimingKind.allCases where counts[kind.id] == nil {
                throw Refused("The times file has no row for “\(kind.id)”: save it again from Calibration Programs.")
            }
            times.plan = TimingPlan(units: units, window: window, airHeight: air, zStroke: stroke, feeds: feeds, counts: counts,
                                    controller: controller)
        }
        let known = Set(kind == .timing ? TimingKind.allCases.map(\.id) : rotarySections(RotaryAxis(), letter: "A").map(\.id))
        if let stray = counts.keys.sorted().first(where: { !known.contains($0) }) {
            throw Refused("“\(stray)” isn't a section of the \(kind.label.lowercased()).")
        }
        return times
    }

    // MARK: Fitting

    /// What a fit found: each value before and after, each section's error before and after, and the verdicts.
    struct FitResult: Sendable {
        public struct Value: Hashable, Sendable, Identifiable {
            public var field: MachineProfile.Field
            public var label: String
            public var before: Double
            public var after: Double
            /// The timed sections pin it down; when false it's left as it was.
            public var determined: Bool
            public var id: String { field.rawValue }

            /// A value of this field for display: "50.0 in/s²", "400 in/min", "0.0020 in", "5400°/min (90°/s)".
            public func text(_ v: Double, _ u: LengthUnit) -> String {
                switch field {
                case .accelerationXY, .accelerationZ:
                    return u == .inch ? String(format: "%.1f in/s²", u.fromMM(v)) : String(format: "%.0f mm/s²", v)
                case .junctionDeviation:
                    return u == .inch ? String(format: "%.4f in", u.fromMM(v)) : String(format: "%.3f mm", v)
                case .turnSpeed:
                    return String(format: "%.0f°/min (%.1f°/s)", v, v / 60)
                default:
                    return u == .inch ? String(format: "%.0f in/min", u.fromMM(v)) : String(format: "%.0f mm/min", v)
                }
            }

            /// The change, as a share of the old value.
            public var change: Double { before > 0 ? after / before - 1 : 0 }
        }

        public struct Row: Hashable, Sendable, Identifiable {
            public var id: String
            public var program: Kind
            public var name: String
            public var measured: Double?
            /// NativeCAM's estimate with the machine's values as they were, seconds.
            public var before: Double
            /// And with the fitted values.
            public var after: Double
            public var fitted: Bool
            public var errorBefore: Double? { measured.map { before / $0 - 1 } }
            public var errorAfter: Double? { measured.map { after / $0 - 1 } }
        }

        public struct Verdict: Hashable, Sendable {
            public var passed: Bool
            public var text: String
        }

        public var values: [Value]
        public var rows: [Row]
        /// Whether the F-change line ran as fast as the single-feed line; nil when the two weren't both timed.
        public var fChange: Verdict?
        /// Whether the inverse-time turn took its 6 s; nil when it wasn't timed.
        public var g93: Verdict?
        public var notes: [String]
        /// The programs fitted from.
        public var programs: [Kind]

        /// Values Apply would change.
        public var changes: [Value] { values.filter { $0.determined && abs($0.after - $0.before) > 1e-9 * max(1, abs($0.before)) } }

        /// Writes the fitted values into `machine`, each marked as measured. Values the times didn't pin down stay.
        public func apply(to machine: inout MachineProfile, date: Date = Date()) {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            for v in values where v.determined {
                let from = v.field == .turnSpeed ? "rotary check" : "timing suite"
                switch v.field {
                case .accelerationXY: machine.accelerationXY = v.after
                case .accelerationZ: machine.accelerationZ = v.after
                case .rapidRateZ: machine.rapidRateZ = v.after
                case .junctionDeviation: machine.junctionDeviation = v.after
                case .turnSpeed:
                    guard machine.rotary != nil else { continue }
                    machine.rotary?.turnSpeed = v.after
                default: continue
                }
                machine.setSource(ValueSource(.measured, note: "fitted from NativeCAM's \(from), \(df.string(from: date))"), for: v.field)
            }
        }

        /// The fit as lines of text, for the command line.
        public func report(_ u: LengthUnit) -> [String] {
            var out: [String] = []
            for v in values {
                let after = v.determined ? v.text(v.after, u) : "not timed, stays"
                out.append("  \(v.label): \(v.text(v.before, u)) -> \(after)")
            }
            out.append("Sections (NativeCAM's estimate before and after, against the time measured):")
            for r in rows {
                func pct(_ e: Double?) -> String { e.map { String(format: "%+.1f%%", 100 * $0) } ?? "" }
                let measured = r.measured.map { String(format: "%.1f s", $0) } ?? "not timed"
                out.append("  \(r.id)  \(r.name): measured \(measured), before \(String(format: "%.1f", r.before)) s \(pct(r.errorBefore)), "
                    + "after \(String(format: "%.1f", r.after)) s \(pct(r.errorAfter))\(r.fitted ? "" : " (not fitted)")")
            }
            if let fChange { out.append("F-change line: \(fChange.text)") }
            if let g93 { out.append("G93: \(g93.text)") }
            out += notes.map { "Note: \($0)" }
            return out
        }
    }

    /// The four planner values the timing suite fits.
    internal enum FitParameter: CaseIterable {
        case accelerationXY, accelerationZ, rapidRateZ, junctionDeviation

        var field: MachineProfile.Field {
            switch self {
            case .accelerationXY: .accelerationXY
            case .accelerationZ: .accelerationZ
            case .rapidRateZ: .rapidRateZ
            case .junctionDeviation: .junctionDeviation
            }
        }

        var label: String {
            switch self {
            case .accelerationXY: "X/Y acceleration"
            case .accelerationZ: "Z acceleration"
            case .rapidRateZ: "Z rapid rate"
            case .junctionDeviation: "Corner tolerance (junction deviation)"
            }
        }

        /// The widest plausible values (mm/s², mm/min, mm): a fit that runs into either end is refused.
        var range: ClosedRange<Double> {
            switch self {
            case .accelerationXY, .accelerationZ: 1.inch...1000.inch
            case .rapidRateZ: 10.inch...3000.inch
            case .junctionDeviation: 0.0005...5
            }
        }

        func value(_ m: MachineProfile) -> Double {
            switch self {
            case .accelerationXY: m.axisAcceleration.x
            case .accelerationZ: m.axisAcceleration.z
            case .rapidRateZ: m.axisRapid.z
            case .junctionDeviation: m.cornerDeviation
            }
        }

        func set(_ m: inout MachineProfile, _ v: Double) {
            switch self {
            case .accelerationXY: m.accelerationXY = v
            case .accelerationZ: m.accelerationZ = v
            case .rapidRateZ: m.rapidRateZ = v
            case .junctionDeviation: m.junctionDeviation = v
            }
        }
    }

    /// Fits `machine`'s values to the times measured with the timing suite and the rotary check (either or both). Refused
    /// with the reason when the times can't be right or can't be fitted.
    static func fit(_ times: [Times], machine: MachineProfile) throws -> FitResult {
        guard !times.isEmpty else { throw Refused("No times to fit.") }
        if times.filter({ $0.kind == .timing }).count > 1 || times.filter({ $0.kind == .rotary }).count > 1 {
            throw Refused("Give one times file for each program.")
        }
        var result = FitResult(values: [], rows: [], fChange: nil, g93: nil, notes: [], programs: times.map(\.kind))
        var m = machine
        m.customPost = nil
        let dialect = Dialect.for(m)
        for t in times where dialect?.id != t.controller {
            throw Refused("These times are for a program written for “\(t.controller)”, but this machine's post writes "
                + "\(dialect?.name ?? machine.controllerLabel). Fit them with the machine they were timed on.")
        }
        if let t = times.first(where: { $0.kind == .timing }) { try fitTiming(t, machine: machine, into: &result) }
        if let t = times.first(where: { $0.kind == .rotary }) { try fitRotary(t, machine: machine, into: &result) }
        if result.rows.allSatisfy({ $0.measured == nil }) { throw Refused("No times have been entered yet.") }
        return result
    }

    private static func fitTiming(_ times: Times, machine: MachineProfile, into result: inout FitResult) throws {
        guard let plan = times.plan else { throw Refused("The timing suite's times file has no plan.") }
        let built = timingSections(plan: plan, machine: machine)
        let u = plan.units
        let byID = Dictionary(uniqueKeysWithValues: zip(built.sections.map(\.id), zip(built.sections, built.toolpaths)))
        // Times that can't be right.
        for (id, seconds) in times.measured.sorted(by: { $0.key < $1.key }) {
            guard let (s, _) = byID[id] else { throw Refused("“\(id)” isn't a section of the timing suite.") }
            if seconds <= 0 { throw Refused("“\(s.name)” has a time of \(number(seconds)) s, which can't be.") }
            if seconds < s.minimum * 0.95 {
                throw Refused("“\(s.name)” was timed at \(String(format: "%.1f", seconds)) s, faster than its moves allow at their "
                    + "programmed feeds (at least \(String(format: "%.1f", s.minimum)) s). Check the time, that the overrides were at 100%, "
                    + "and the machine's rapid rate.")
            }
            if seconds > s.estimate * 5 {
                throw Refused("“\(s.name)” was timed at \(String(format: "%.0f", seconds)) s, where NativeCAM expects about "
                    + "\(String(format: "%.0f", s.estimate)) s. Was the feed override turned down, or is it another section's time?")
            }
        }
        let fitted = built.sections.indices.filter { built.sections[$0].fitted && times.measured[built.sections[$0].id] != nil }
        let params = FitParameter.allCases
        var start = params.map { $0.value(built.project.machine) }
        func profile(_ x: [Double]) -> MachineProfile {
            var mm = built.project.machine
            for (k, p) in params.enumerated() { p.set(&mm, x[k]) }
            return mm
        }
        func estimates(_ x: [Double], _ indices: [Int]) -> [Double] {
            var project = built.project
            project.machine = profile(x)
            return indices.map { sectionSeconds(built.toolpaths[$0], project: project) }
        }
        var after = start
        var determined = [Bool](repeating: false, count: params.count)
        if !fitted.isEmpty {
            let measured = fitted.map { times.measured[built.sections[$0].id]! }
            let solution = leastSquares(start: start, ranges: params.map(\.range)) { x in
                zip(estimates(x, fitted), measured).map { $0 / $1 - 1 }
            }
            after = solution.x
            determined = solution.determined
            for k in params.indices where !determined[k] { after[k] = start[k] }
            for (k, p) in params.enumerated() where determined[k] {
                let r = p.range
                if after[k] <= r.lowerBound * 1.0001 || after[k] >= r.upperBound * 0.9999 {
                    let v = FitResult.Value(field: p.field, label: p.label, before: start[k], after: after[k], determined: true)
                    throw Refused("These times can't be fitted: they'd need a \(p.label.lowercased()) "
                        + "\(after[k] <= r.lowerBound * 1.0001 ? "below" : "above") \(v.text(after[k], u)). Check the times against the sections they're for.")
                }
            }
            let errors = zip(estimates(after, fitted), measured).map { $0 / $1 - 1 }
            if let worst = errors.indices.max(by: { abs(errors[$0]) < abs(errors[$1]) }), abs(errors[worst]) > fitTolerance {
                let s = built.sections[fitted[worst]]
                throw Refused("These times can't be fitted: “\(s.name)” is still \(String(format: "%.0f", 100 * abs(errors[worst])))% "
                    + "\(errors[worst] > 0 ? "faster" : "slower") than NativeCAM's best fit. Time it again, or check that it's the right section's time.")
            }
        } else {
            result.notes.append("No timing suite sections that fit the planner were timed.")
        }
        start = params.map { $0.value(built.project.machine) }
        for (k, p) in params.enumerated() {
            result.values.append(FitResult.Value(field: p.field, label: p.label, before: start[k], after: after[k], determined: determined[k]))
        }
        let undetermined = params.indices.filter { !determined[$0] }.map { params[$0].label }
        if !undetermined.isEmpty, !fitted.isEmpty {
            result.notes.append("Not pinned down by the sections timed, so left as they are: \(undetermined.joined(separator: ", ")).")
        }
        let all = Array(built.sections.indices)
        let before = estimates(start, all), now = estimates(after, all)
        for i in all {
            let s = built.sections[i]
            result.rows.append(FitResult.Row(id: s.id, program: .timing, name: s.name, measured: times.measured[s.id], before: before[i],
                                             after: now[i], fitted: s.fitted))
        }
        // Sections the fit couldn't bring within 10%: a hint at what the planner model leaves out.
        let off = result.rows.filter { $0.fitted && abs($0.errorAfter ?? 0) > 0.10 }
        if !off.isEmpty {
            result.notes.append("Still more than 10% off after the fit: \(off.map { "\($0.name) (\(String(format: "%+.0f%%", 100 * ($0.errorAfter ?? 0))))" }.joined(separator: ", ")). "
                + "The zig-zag and the segments also depend on how many lines the controller looks ahead "
                + "(\(built.project.machine.plannerLookahead) assumed), which isn't fitted.")
        }
        // The F-change line.
        if let single = result.rows.first(where: { $0.id == TimingKind.fChangeSingle.id }),
           let alternating = result.rows.first(where: { $0.id == TimingKind.fChangeAlternating.id }),
           let ts = single.measured, let ta = alternating.measured {
            let expected = alternating.after / max(single.after, 1e-9)
            let slower = (ta / ts) / expected - 1
            let changes = built.toolpaths[TimingKind.allCases.firstIndex(of: .fChangeAlternating)!].motions
            let count = zip(changes, changes.dropFirst()).filter { $0.feed != $1.feed }.count
            let lost = (ta - ts * expected) / Double(max(1, count))
            let dialectName = Dialect.for(built.project.machine)?.name ?? machine.controllerLabel
            if slower <= fChangeTolerance {
                result.fChange = FitResult.Verdict(passed: true, text: "the line with two feeds took \(String(format: "%.1f", ta)) s against "
                    + "\(String(format: "%.1f", ts)) s at one feed (\(String(format: "%+.1f%%", 100 * slower)), within \(Int(100 * fChangeTolerance))%): "
                    + "\(dialectName) kept constant velocity through the changes of F, so “Adjust feeds for load” won't slow the machine at them.")
            } else {
                result.fChange = FitResult.Verdict(passed: false, text: "the line with two feeds took \(String(format: "%.1f", ta)) s against "
                    + "\(String(format: "%.1f", ts)) s at one feed, \(String(format: "%.0f%%", 100 * slower)) slower (more than "
                    + "\(Int(100 * fChangeTolerance))%): \(dialectName) slows at each change of F, about \(String(format: "%.2f", lost)) s a change. "
                    + "“Adjust feeds for load” would cost that at every change, and may mark the cut where it slows.")
            }
        }
    }

    private static func fitRotary(_ times: Times, machine: MachineProfile, into result: inout FitResult) throws {
        let axis = machine.rotary ?? RotaryAxis()
        if let letter = times.axisLetter, let own = machine.rotary?.letter.rawValue, letter != own {
            throw Refused("These times are for a rotary \(letter) axis, but this machine's rotary axis is \(own).")
        }
        let sections = rotarySections(axis, letter: axis.letter.rawValue)
        for (id, seconds) in times.measured where !sections.contains(where: { $0.id == id }) || seconds <= 0 {
            throw Refused(seconds <= 0 ? "A rotary time of \(number(seconds)) s can't be." : "“\(id)” isn't a section of the rotary check.")
        }
        let t360 = times.measured["rotary-360"], t720 = times.measured["rotary-720"]
        if let a = t360, let b = t720, b <= a {
            throw Refused("The 720° turn (\(number(b)) s) can't be quicker than the 360° turn (\(number(a)) s): check the two times.")
        }
        let before = axis.turnSpeed ?? RotaryAxis.nominalTurnSpeed
        var after = before
        let turns = [(360.0, t360), (720.0, t720)].compactMap { d, t in t.map { (d, $0) } }
        if !turns.isEmpty {
            // Least squares on the relative error of t = degrees / speed, as the estimator times a turn.
            let w = turns.map { $0.0 / $0.1 }.reduce(0, +) / turns.map { ($0.0 / $0.1) * ($0.0 / $0.1) }.reduce(0, +)
            after = 60 / w
            if after < 360 || after > 200_000 {
                throw Refused("These turn times would mean a turn speed of \(String(format: "%.0f", after))°/min, which can't be right.")
            }
        }
        let usable = machine.rotary != nil && machine.rotary?.turnsByHand != true
        result.values.append(FitResult.Value(field: .turnSpeed, label: "Turn speed", before: before, after: usable ? after : before,
                                             determined: usable && !turns.isEmpty))
        if !usable, !turns.isEmpty {
            result.notes.append("Turn on the machine's rotary axis (Material & Machine ▸ Rotary Axis) to keep the fitted turn speed of "
                + "\(String(format: "%.0f", after))°/min.")
        }
        var fittedAxis = axis
        fittedAxis.turnSpeed = after
        let now = rotarySections(fittedAxis, letter: axis.letter.rawValue)
        for (s, n) in zip(sections, now) {
            result.rows.append(FitResult.Row(id: s.id, program: .rotary, name: s.name, measured: times.measured[s.id], before: s.estimate,
                                             after: n.estimate, fitted: s.fitted))
        }
        if let t = times.measured["rotary-g93"] {
            let expected = max(rotaryExpectedSeconds, 360 / after * 60)
            let slack = max(0.5, 0.08 * expected)
            var m = machine
            m.customPost = nil
            let name = Dialect.for(m)?.name ?? machine.controllerLabel
            if abs(t - expected) <= slack {
                result.g93 = FitResult.Verdict(passed: true, text: "the inverse-time turn took \(String(format: "%.1f", t)) s, as expected "
                    + "(\(number(expected)) s): \(name) runs G93 as NativeCAM writes it.")
            } else if t < expected {
                result.g93 = FitResult.Verdict(passed: false, text: "the inverse-time turn took \(String(format: "%.1f", t)) s, faster than "
                    + "its F\(Int(rotaryInverseTime)) allows (\(number(expected)) s): \(name) isn't reading G93's F as a time. Don't cut wrapped jobs until that's sorted out.")
            } else if expected > rotaryExpectedSeconds + 1e-9 {
                result.g93 = FitResult.Verdict(passed: false, text: "the inverse-time turn took \(String(format: "%.1f", t)) s where the axis's "
                    + "turn speed allows \(number(expected)) s: \(name) may be running G93 slowly. Time it again.")
            } else {
                result.g93 = FitResult.Verdict(passed: false, text: "the inverse-time turn took \(String(format: "%.1f", t)) s where "
                    + "\(number(expected)) s was expected: \(name) isn't running G93's F as a time, or the axis can't turn 60°/s.")
            }
        }
    }

    /// Levenberg–Marquardt in the logarithms of the values, which keeps them positive and makes each step a share of the
    /// value. A value the residuals hardly depend on (a 10% change moving them by under 0.1%) isn't fitted.
    static func leastSquares(start: [Double], ranges: [ClosedRange<Double>],
                             residuals: ([Double]) -> [Double]) -> (x: [Double], determined: [Bool]) {
        let n = start.count
        let lo = ranges.map { log($0.lowerBound) }, hi = ranges.map { log($0.upperBound) }
        func clamp(_ x: [Double]) -> [Double] { (0..<n).map { min(max(x[$0], lo[$0]), hi[$0]) } }
        func eval(_ x: [Double]) -> [Double] { residuals(x.map(exp)) }
        func cost(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }
        var x = clamp(start.map(log))
        var r = eval(x), c = cost(r)
        var lambda = 1e-2
        var active = [Bool](repeating: true, count: n)
        func jacobian(_ x: [Double], _ r: [Double]) -> [[Double]] {
            (0..<n).map { k in
                var step = x
                let h = x[k] + 1e-3 > hi[k] ? -1e-3 : 1e-3
                step[k] += h
                return zip(eval(step), r).map { ($0 - $1) / h }
            }
        }
        func norm(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }
        for _ in 0..<60 {
            let j = jacobian(x, r)
            for k in 0..<n where norm(j[k]) < 0.01 { active[k] = false }
            let idx = (0..<n).filter { active[$0] }
            guard !idx.isEmpty else { break }
            let a = idx.map { p in idx.map { q in zip(j[p], j[q]).map(*).reduce(0, +) } }
            let g = idx.map { p in zip(j[p], r).map(*).reduce(0, +) }
            var accepted = false
            var gain = 0.0
            for _ in 0..<16 {
                var m = a
                for i in idx.indices { m[i][i] += lambda * max(a[i][i], 1e-12) }
                guard let delta = solve(m, g.map { -$0 }) else { lambda *= 4; continue }
                var trial = x
                for (i, k) in idx.enumerated() { trial[k] += delta[i] }
                trial = clamp(trial)
                let rt = eval(trial), ct = cost(rt)
                if ct < c {
                    gain = c - ct
                    x = trial; r = rt; c = ct
                    lambda = max(lambda / 3, 1e-9)
                    accepted = true
                    break
                }
                lambda *= 4
            }
            if !accepted || gain < 1e-14 || c < 1e-16 { break }
        }
        let j = jacobian(x, r)
        let determined = (0..<n).map { active[$0] && norm(j[$0]) >= 0.01 }
        return (x.map(exp), determined)
    }

    /// Solves a small dense linear system by Gaussian elimination with partial pivoting; nil when it's singular.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, v = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-300 else { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n where row < n {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = v[row]
            for k in (row + 1)..<n where k < n { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }
}
