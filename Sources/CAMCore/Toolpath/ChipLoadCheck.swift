import Foundation

/// The chip-load check: a toolpath's chip against the chart for the job's material (`ChipLoad`). Thin chips rub, burn
/// and dull the bit; very thick ones leave a rough edge. A form or dovetail bit set to turn faster than router-bit makers
/// allow for its diameter is warned about too.
extension CAMEngine {
    /// The chip at the toolpath's set feed, and at the lowest feed it keeps up over a stretch of cutting
    /// (`sustainedFeed`) when it lowers its own feed: an A-rate limit on a wrapped toolpath, feeds that follow the load.
    /// An adaptive toolpath's chip is thinned by its light radial cut (`Toolpath.radialLoad`), and the feed it's
    /// recommended keeps to what its loops can hold (`AdaptiveSettings.loopFeedLimit`, from `operation`'s settings).
    /// Each message names the chart and how it was read (`ChipLoad.Reading.source`).
    /// How the chart is read for `tp`: the depth that sets a changing bit's diameter (its deepest cut), the most one
    /// pass of a form bit takes when that's less than a full pass (an edge profile's or round-nose chamfer's heaviest
    /// lap), the deepest single pass for the depth derate (`OperationKind.deepestPass`, for the operation's own bit at a
    /// full-width cut), and the radial thinning of an adaptive toolpath's light cut.
    static func chipReadingInputs(_ tp: Toolpath, project: Project, operation: CAMOperation?)
        -> (depth: Double?, passArea: Double?, passDepth: Double?, thinning: Double) {
        let tool = tp.tool
        // A bit whose width changes with depth is read at the widest it cuts with (the toolpath's deepest cut).
        let depth = tp.cuttingExtents.map { max(0, -$0.min.z) }
        // An edge profile's passes each take a band of the profile: its heaviest lap's cross-section sets the feed.
        var passArea: Double?
        if case let .edgeProfile(p)? = operation?.kind {
            passArea = p.plan(tool: tool, thickness: project.stock.thickness).largestLap
        } else if case let .chamfer(c)? = operation?.kind, tool.shape == .form,
                  let d = EdgeProfileParams.formDepth(reaching: c.width, tool: tool) {
            // A round-nose chamfer's passes, as an edge profile's are.
            passArea = EdgeProfilePlan.fewestPasses(tool: tool, depth: d, thickness: max(0.01, project.stock.thickness - c.startDepth))
                .largestLap
        }
        let own = operation.map { $0.tool == tool } ?? false
        // (An adaptive pocket has no pass depth to derate; adaptive 3D roughing's layers do, as well as its thinning.)
        let passDepth = own ? operation?.kind.deepestPass(tool) : nil
        let thin = tp.radialLoad.map { ChipLoad.radialThinning(load: $0) } ?? 1
        return (depth, passArea, passDepth, thin)
    }

    /// Spindle ▸ Automatic (`CAMOperation.spindleSpeed`): `tp` with the speed that puts its chip at the chart's target
    /// at its feed (`ChipLoad.automaticSpindle`), and a warning when no speed the spindle and bit allow keeps the chip
    /// in range. A bit no chart covers keeps its tool's speed, with a note. Unchanged when the operation uses the
    /// tool's RPM.
    static func applyAutomaticSpindle(_ tp: Toolpath, operation op: CAMOperation, project: Project) -> Toolpath {
        guard op.usesAutomaticSpindle, !tp.isEmpty else { return tp }
        var tp = tp
        let inputs = chipReadingInputs(tp, project: project, operation: op)
        guard let auto = ChipLoad.automaticSpindle(for: tp.tool, material: project.stock.material, machine: project.machine,
                                                   feed: tp.tool.cutting.feedRate, thinning: inputs.thinning, depth: inputs.depth,
                                                   crossSection: inputs.passArea, passDepth: inputs.passDepth) else {
            tp.notes = (tp.notes ?? []) + ["Automatic spindle speed: no chip-load chart covers a \(tp.tool.shape.label.lowercased()), "
                + "so this toolpath runs at its tool's \(Int(tp.spindleRPM.rounded()).formatted()) RPM."]
            return tp
        }
        tp.spindleRPM = auto.rpm
        tp.automaticSpindle = auto
        if let warning = auto.warning(project.displayUnits) { tp.warnings.append(warning) }
        return tp
    }

    static func chipLoadIssues(_ tp: Toolpath, project: Project, operation: CAMOperation? = nil) -> [JobIssue] {
        let tool = tp.tool
        guard ChipLoad.applies(to: tool), tp.spindleRPM > 0, tool.fluteCount > 0 else { return [] }
        let material = project.stock.material
        let (depth, passArea, passDepth, thin) = chipReadingInputs(tp, project: project, operation: operation)
        let reading = ChipLoad.reading(tool, material: material, depth: depth, crossSection: passArea, passDepth: passDepth)
        let r = reading.range
        let z = Double(tool.fluteCount)
        // Automatic spindle speed works the chip out at the feed the machine reaches, and has warned already when it
        // can't keep it in range.
        let set = tp.automaticSpindle?.feed ?? tool.cutting.feedRate
        let warned = tp.automaticSpindle?.outOfRange == true
        let chip = set / (tp.spindleRPM * z) * thin
        let inch = { (mm: Double) in String(format: "%.4f in", mm / LengthUnit.mmPerInch) }
        let units = project.displayUnits
        let range = "the \(inch(r.lowerBound))–\(inch(r.upperBound)) range for this bit in \(material.label.lowercased()) "
            + "(\(reading.source(units)))"
        var loops: Double?
        if tp.radialLoad != nil, let a = operation?.kind.adaptiveClearing {
            loops = a.loopFeedLimit(tool: tool, machine: project.machine)
        }
        let rec = ChipLoad.recommendation(for: tool, material: material, machine: project.machine, thinning: thin, feedLimit: loops,
                                          depth: depth, crossSection: passArea, passDepth: passDepth)
        let held = loops.map { rec.feed >= $0 - 1e-6 && $0 < project.machine.maxFeedRate } ?? false
        let notes = reading.notes(units)
        let suggestion = "Try \(units.format(rec.feed, decimals: units == .inch ? 0 : 0)) \(units.feedSymbol) at \(Int(rec.rpm.rounded())) RPM"
            + (held ? ", as fast as its loops can run with this machine's acceleration." : ".")
            + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
        var issues: [JobIssue] = []
        if let speed = overSpeedMessage(tp, reading: reading, project: project) {
            issues.append(JobIssue(.warning, speed, operation: tp.name))
        }
        // What the chip is: thinned, at an adaptive toolpath's light cut.
        let what = thin < 1 ? "Chip load \(inch(chip)) at the \(Int((100 * (tp.radialLoad ?? 0)).rounded()))% adaptive load (a light cut thins "
            + "the chip to \(Int((100 * thin).rounded()))% of the feed per tooth)" : "Chip load \(inch(chip))"
        // Ball and bull noses finish at light engagement, so allow them a little below the end-mill floor; form and
        // dovetail bits too, whose chart's thin end is already half the thinnest a maker gives.
        let floor = r.lowerBound * (tool.shape == .flatEndMill ? 0.9 : 0.8)
        if chip < floor {
            if warned { return issues }
            issues.append(JobIssue(.warning, "\(what) is below \(range); thin chips rub, burn and dull the bit. \(suggestion)",
                                   operation: tp.name))
            return issues
        }
        if let low = sustainedFeed(tp), low.feed < set - 1e-6, low.feed / (tp.spindleRPM * z) * thin < floor {
            issues.append(JobIssue(.warning, loweredChipMessage(tp, low: low, reading: reading, floor: floor, rangeText: range,
                                                                project: project),
                                   operation: tp.name))
        }
        if chip > r.upperBound * 1.25 && !warned {
            issues.append(JobIssue(.info, "\(what) is above \(range); expect a rougher edge. \(suggestion)",
                                   operation: tp.name))
        }
        return issues
    }

    /// The warning for a form or dovetail bit (or one wider than every chart) set to turn faster than its speed limit
    /// (`ChipLoad.Reading.maxRPM`), or nil.
    static func overSpeedMessage(_ tp: Toolpath, reading: ChipLoad.Reading, project: Project) -> String? {
        guard let top = reading.maxRPM, tp.spindleRPM > top + 0.5 else { return nil }
        let size = ChipLoad.size(reading.fullDiameter, project.displayUnits)
        let rpm = { (v: Double) in "\(Int(v.rounded()).formatted()) RPM" }
        var s = "Spindle speed \(rpm(tp.spindleRPM)) is faster than "
        if reading.outsideChart {
            s += "the \(rpm(top)) NativeCAM allows a \(size) \(reading.bitName), wider than every chart"
        } else {
            s += "the \(rpm(top)) router-bit makers allow a bit \(size) across (\(reading.chart.label))"
        }
        s += "; a bit turned past its rated speed can break. Check the speed on its shank or packaging"
        if project.machine.minRPM > top + 1e-9 {
            s += ". This spindle can't turn that slowly (its slowest is \(rpm(project.machine.minRPM))): don't run this bit on it."
        } else {
            s += ", and set the spindle no faster."
        }
        return s
    }

    /// The warning for a chip that's thin only where the toolpath slows itself: where and why, and the spindle speed
    /// that makes the chip right at that feed (the fix the set feed's recommendation can't give).
    static func loweredChipMessage(_ tp: Toolpath, low: (feed: Double, at: Vec3), reading: ChipLoad.Reading, floor: Double,
                                   rangeText: String, project: Project) -> String {
        let tool = tp.tool, machine = project.machine
        let z = Double(tool.fluteCount)
        let thin = tp.radialLoad.map { ChipLoad.radialThinning(load: $0) } ?? 1
        let ctx = GenerationContext(stock: project.stock, machine: machine, units: project.displayUnits)
        let inch = { (mm: Double) in String(format: "%.4f in", mm / LengthUnit.mmPerInch) }
        let chip = low.feed / (tp.spindleRPM * z) * thin
        let units = project.displayUnits
        let point = { (v: Double) in units.format(v) }
        let place: String
        if let d = tp.wrapDiameter {
            place = "near the axis, where the rotary axis can't turn fast enough and the feed drops to \(ctx.feed(low.feed)) "
                + "(\(ctx.length(max(0, d / 2 + low.at.z))) from the axis, \(ctx.length(low.at.x)) along the blank)"
        } else if tp.loadFeeds?.varies == true {
            place = "where Adjust feeds for load slows the feed to \(ctx.feed(low.feed)) (from around X \(point(low.at.x)) Y \(point(low.at.y)) \(units.symbol))"
        } else {
            place = "where the toolpath slows to \(ctx.feed(low.feed)) (from around X \(point(low.at.x)) Y \(point(low.at.y)) \(units.symbol))"
        }
        // The speed that puts the chip at the chart's target at that feed, as the set feed's recommendation does (a quarter
        // into the end-mill chart's range, the router-bit chart's thin end), never past the bit's speed limit.
        let target = reading.target
        var rpm = machine.clampRPM(low.feed * thin / (z * target))
        if let top = reading.maxRPM { rpm = min(rpm, top) }
        var fix: String
        if low.feed / (rpm * z) * thin >= floor - 1e-12 {
            fix = "At that feed, \(Int(rpm.rounded()).formatted()) RPM keeps the chip in range."
        } else {
            fix = "Even at \(Int(rpm.rounded()).formatted()) RPM, the spindle's slowest, the chip there would be \(inch(low.feed / (rpm * z) * thin))."
        }
        if tp.wrapDiameter != nil, machine.rotary?.drivenTurnSpeed == nil {
            fix += " " + Self.assumedTurnSpeedNote
        }
        return "Chip load comes down to \(inch(chip)) \(place), below \(rangeText); thin chips rub, burn and dull the bit. \(fix)"
    }

    /// What a thin chip near the rotary axis comes from when no Turn speed is set (#74), and where to set it. A real
    /// speed keeps more of the feed, but not all: the tip's speed round the axis drops toward it however fast A turns.
    static let assumedTurnSpeedNote = "This slowdown comes from the 90° a second NativeCAM assumes, because the rotary axis's "
        + "Turn speed isn't set: enter your axis's real speed in Material & Machine ▸ Rotary Axis ▸ Turn speed (Mach4: "
        + "the A motor's velocity, or import Machine.ini). A faster axis keeps more of the feed, though close to the axis "
        + "the feed still drops however fast it turns."

    /// Shortest stretch of cutting a low feed has to last for the chip-load check to count it, mm: so a slowdown
    /// into a corner doesn't count, but a slowed slot or a pass near a rotary axis does.
    static func sustainedLength(_ tool: Tool) -> Double { max(4 * tool.diameter, 20) }

    /// The lowest feed the toolpath keeps up over a stretch of cutting at least `sustainedLength` long: of every such
    /// stretch, the one whose fastest move is slowest, and where it starts. Cutting moves are lines and arcs that move
    /// sideways (plunges and descents steeper than 45° have feeds of their own), measured along the tool tip's path on
    /// a wrapped toolpath (whose feeds are the tip's); an inside arc that "Adjust feeds for load" slowed at its centre
    /// counts at its edge's feed, which makes the chip. nil when no stretch of cutting is that long.
    static func sustainedFeed(_ tp: Toolpath) -> (feed: Double, at: Vec3)? {
        let minimum = sustainedLength(tp.tool)
        let arcs = tp.loadFeeds?.insideArcs ?? [:]
        struct Piece { var length: Double; var feed: Double; var start: Vec3 }
        var chains: [[Piece]] = []
        var chain: [Piece] = []
        var p = tp.start
        for (i, m) in tp.motions.enumerated() {
            defer { if m.kind != .dwell { p = m.end } }
            let d = m.end - p
            let sideways = Vec2(d.x, d.y).length
            let cuts = m.feed > 0 && (m.kind.isArc || (m.kind == .feed && sideways > 1e-6 && !(d.z < 0 && sideways < -d.z)))
            guard cuts else {
                if !chain.isEmpty { chains.append(chain); chain = [] }
                continue
            }
            var length = m.length(from: p)
            if let diameter = tp.wrapDiameter, m.kind == .feed {
                let radius = diameter / 2
                length = RotaryWrap.tipLength(x0: p.x, r0: radius + p.z, degrees0: RotaryWrap.angle(y: p.y, centerY: 0, diameter: diameter),
                                              x1: m.end.x, r1: radius + m.end.z,
                                              degrees1: RotaryWrap.angle(y: m.end.y, centerY: 0, diameter: diameter))
            }
            chain.append(Piece(length: length, feed: m.feed / (arcs[i] ?? 1), start: p))
        }
        if !chain.isEmpty { chains.append(chain) }
        // For each start, the shortest stretch from it that's long enough (its end only moves on as the start does),
        // with the fastest move in it from a queue of falling feeds.
        var best: (feed: Double, at: Vec3)?
        for c in chains {
            var queue: [Int] = [], head = 0
            var end = -1, length = 0.0
            for start in c.indices {
                while length < minimum - 1e-9 && end + 1 < c.count {
                    end += 1
                    length += c[end].length
                    while queue.count > head && c[queue[queue.count - 1]].feed <= c[end].feed { queue.removeLast() }
                    queue.append(end)
                }
                guard length >= minimum - 1e-9 else { break }
                let fastest = c[queue[head]].feed
                if best.map({ fastest < $0.feed - 1e-9 }) ?? true { best = (fastest, c[start].start) }
                length -= c[start].length
                if queue[head] == start { head += 1 }
            }
        }
        return best
    }
}

public extension OperationKind {
    /// The adaptive clearing settings of an adaptive pocket or adaptive 3D roughing, whose light cut thins the chip and
    /// whose loops limit the feed; nil for anything else.
    var adaptiveClearing: AdaptiveSettings? {
        switch self {
        case let .pocket(p): p.strategy == .adaptive ? p.adaptiveSettings : nil
        case let .rough3D(p): p.clearingInUse == .adaptive ? p.adaptiveSettings : nil
        default: nil
        }
    }
}
