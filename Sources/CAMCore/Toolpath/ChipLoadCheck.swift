import Foundation

/// The chip-load check: a toolpath's chip against the chart for the job's material (`ChipLoad`). Thin chips rub, burn
/// and dull the bit; very thick ones leave a rough edge.
extension CAMEngine {
    /// The chip at the toolpath's set feed, and at the lowest feed it keeps up over a stretch of cutting
    /// (`sustainedFeed`) when it lowers its own feed: an A-rate limit on a wrapped toolpath, feeds that follow the load.
    /// An adaptive toolpath's chip is thinned by its light radial cut (`Toolpath.radialLoad`), and the feed it's
    /// recommended keeps to what its loops can hold (`AdaptiveSettings.loopFeedLimit`, from `operation`'s settings).
    static func chipLoadIssues(_ tp: Toolpath, project: Project, operation: CAMOperation? = nil) -> [JobIssue] {
        let tool = tp.tool
        guard ChipLoad.applies(to: tool), tp.spindleRPM > 0, tool.fluteCount > 0 else { return [] }
        let material = project.stock.material
        let r = ChipLoad.range(material, diameter: tool.diameter)
        let z = Double(tool.fluteCount)
        let thin = tp.radialLoad.map { ChipLoad.radialThinning(load: $0) } ?? 1
        let set = tool.cutting.feedRate
        let chip = set / (tp.spindleRPM * z) * thin
        let inch = { (mm: Double) in String(format: "%.4f in", mm / LengthUnit.mmPerInch) }
        let units = project.displayUnits
        let range = "the \(inch(r.lowerBound))–\(inch(r.upperBound)) range for this bit in \(material.label.lowercased())"
        var loops: Double?
        if tp.radialLoad != nil, case let .pocket(p)? = operation?.kind, p.strategy == .adaptive {
            loops = p.adaptiveSettings.loopFeedLimit(tool: tool, machine: project.machine)
        }
        let rec = ChipLoad.recommend(for: tool, material: material, machine: project.machine, thinning: thin, feedLimit: loops)
        let held = loops.map { rec.feed >= $0 - 1e-6 && $0 < project.machine.maxFeedRate } ?? false
        let suggestion = "Try \(units.format(rec.feed, decimals: units == .inch ? 0 : 0)) \(units.feedSymbol) at \(Int(rec.rpm.rounded())) RPM"
            + (held ? ", as fast as its loops can run with this machine's acceleration." : ".")
        // What the chip is: thinned, at an adaptive toolpath's light cut.
        let what = thin < 1 ? "Chip load \(inch(chip)) at the \(Int((100 * (tp.radialLoad ?? 0)).rounded()))% adaptive load (a light cut thins "
            + "the chip to \(Int((100 * thin).rounded()))% of the feed per tooth)" : "Chip load \(inch(chip))"
        // Ball and bull noses finish at light engagement, so allow them a little below the end-mill floor.
        let floor = r.lowerBound * (tool.shape == .flatEndMill ? 0.9 : 0.8)
        if chip < floor {
            return [JobIssue(.warning, "\(what) is below \(range); thin chips rub, burn and dull the bit. \(suggestion)",
                             operation: tp.name)]
        }
        var issues: [JobIssue] = []
        if let low = sustainedFeed(tp), low.feed < set - 1e-6, low.feed / (tp.spindleRPM * z) * thin < floor {
            issues.append(JobIssue(.warning, loweredChipMessage(tp, low: low, range: r, floor: floor, rangeText: range, project: project),
                                   operation: tp.name))
        }
        if chip > r.upperBound * 1.25 {
            issues.append(JobIssue(.info, "\(what) is above \(range); expect a rougher edge. \(suggestion)",
                                   operation: tp.name))
        }
        return issues
    }

    /// The warning for a chip that's thin only where the toolpath slows itself: where and why, and the spindle speed
    /// that makes the chip right at that feed (the fix the set feed's recommendation can't give).
    static func loweredChipMessage(_ tp: Toolpath, low: (feed: Double, at: Vec3), range r: ClosedRange<Double>, floor: Double,
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
        // The speed that puts the chip a quarter into the range at that feed, as the set feed's recommendation does.
        let target = r.lowerBound + (r.upperBound - r.lowerBound) * 0.25
        let rpm = machine.clampRPM(low.feed * thin / (z * target))
        var fix: String
        if low.feed / (rpm * z) * thin >= floor - 1e-12 {
            fix = "At that feed, \(Int(rpm.rounded()).formatted()) RPM keeps the chip in range."
        } else {
            fix = "Even at \(Int(rpm.rounded()).formatted()) RPM, the spindle's slowest, the chip there would be \(inch(low.feed / (rpm * z) * thin))."
        }
        if tp.wrapDiameter != nil, machine.rotary?.drivenTurnSpeed == nil {
            fix += " The rotary axis's Turn speed isn't set, so NativeCAM assumes 90° a second; if it turns faster, set it and the cut keeps more of its feed."
        }
        return "Chip load comes down to \(inch(chip)) \(place), below \(rangeText); thin chips rub, burn and dull the bit. \(fix)"
    }

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
