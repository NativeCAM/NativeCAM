import Foundation

/// Wrapped rotary work (research_notes/Rotary milling/rotary_milling.md §2.1 and §2.6): a flat design sheet rolled
/// around a round blank. Toolpaths are generated on the unrolled sheet as usual, and the posts turn each point into
/// machine words as they write it:
///
/// - X stays X, along the rotation axis.
/// - Y turns into the angle A = (y − y_c)·360/(π·D), where y_c is the middle of the sheet (the top of the blank at
///   A0) and D the wrap diameter. A is unwound: a spiral that goes three times round ends at 1080°.
/// - Z becomes a distance from the axis, R + z (Z zero is on the rotation axis), and the tool stays over the axis
///   (Y0).
///
/// With the right-hand rule about +X, a positive turn rolls the top of the blank toward −Y, so the material a
/// distance v on the +Y side of the top line comes under the tool at A = +v/R: the design reads the right way round
/// from above, as it does on a flat sheet. A machine whose rotary turns the other way is marked Reversed, and the
/// posts flip A for it (`RotaryOutput.value`).
///
/// That's the blank's own frame. On an axis along Y (`RotaryFrame`) the posts write the same moves turned a quarter
/// turn about Z: Y along the axis, X0 on its centreline, and the same A words, turning about +Y.
///
/// A straight line on the sheet becomes a helix on the blank, which the controller makes by moving X, A and Z
/// together, so no line needs splitting. Arcs do (no controller can arc in X and A), so wrapped toolpaths are cut
/// as lines. Feeds are written as inverse time (G93): F is one over the move's time in minutes, worked out from the
/// length of the path the tool tip traces, which makes the feed right whatever the controller does with degrees.
public enum RotaryWrap {
    /// Largest inverse-time F written, 1/min. A move too short for its feed is capped here and runs a little slow.
    /// Avid's own Fusion wrap posts cap at the same value.
    public static let maxInverseTime = 999_999.9999
    /// Decimal places of an inverse-time F word (as Avid's Fusion wrap posts write it).
    public static let inverseTimeDecimals = 4
    /// Largest turn in one move, degrees. Longer turns are split, as Vectric's rotary posts do by default
    /// (`MAXIMUM_ROTATION`), so a controller that takes the short way round (Mach4 with Rollover on) still turns the
    /// right way. The pieces lie on the same helix, so nothing about the cut changes.
    public static let maxTurnPerMove = 90.0

    /// The angle, degrees (right-hand rule about +X, before a reversed axis flips it), the blank turns to so that
    /// the sheet's line `y` is under the tool.
    public static func angle(y: Double, centerY: Double, diameter: Double) -> Double {
        (y - centerY) * 360 / (.pi * diameter)
    }

    /// Length of the path the tool tip traces, mm, when the controller moves X, the distance from the axis r and the
    /// angle A linearly from one point to the other: ∫ √(ẋ² + ṙ² + (r·θ̇)²). Exact when r doesn't change; Simpson's
    /// rule otherwise (the integrand is smooth, so eight intervals are plenty).
    public static func tipLength(x0: Double, r0: Double, degrees0: Double, x1: Double, r1: Double, degrees1: Double) -> Double {
        let dx = x1 - x0, dr = r1 - r0, dt = (degrees1 - degrees0) * .pi / 180
        func speed(_ t: Double) -> Double {
            let r = r0 + dr * t
            return (dx * dx + dr * dr + r * r * dt * dt).squareRoot()
        }
        if abs(dr) < 1e-12 || abs(dt) < 1e-12 { return speed(0) }
        let n = 8
        var sum = speed(0) + speed(1)
        for i in 1..<n { sum += speed(Double(i) / Double(n)) * (i % 2 == 1 ? 4 : 2) }
        return sum / Double(3 * n)
    }

    /// Inverse-time F for a move of `length` mm at `feed` mm/min: one over its time in minutes, capped.
    public static func inverseTime(length: Double, feed: Double) -> Double {
        guard length > 1e-9, feed > 0 else { return maxInverseTime }
        return min(feed / length, maxInverseTime)
    }

    /// Inverse-time F for a wrapped move whose tool tip traces `length` mm at `feed` mm/min while the blank turns
    /// `degrees`: one over its time in minutes, capped, and never faster than the rotary axis turns at `turnSpeed`
    /// (degrees per minute). The feeds already keep the turn within it (`turnLimitedFeed`); this is for a move whose tip
    /// path is too short for that, above all one that turns with the tip on the axis, whose path has no length and
    /// which would otherwise get the largest F. Its F is the turn's at the turn speed, rounded down to the decimals the
    /// post writes so the written F keeps within it too.
    public static func inverseTime(length: Double, feed: Double, degrees: Double, turnSpeed: Double) -> Double {
        let f = inverseTime(length: length, feed: feed)
        let turn = abs(degrees)
        guard turn > 1e-9, turnSpeed > 0, turnSpeed.isFinite else { return f }
        let p = pow(10, Double(inverseTimeDecimals))
        let byTurn = max(1 / p, (turnSpeed / turn * p).rounded(.down) / p)
        return min(f, byTurn)
    }

    /// Seconds a move of a wrapped toolpath takes at constant speed, from sheet coordinates (the sheet's line
    /// `centerY` at A0, Z measured from the sheet's `radius`): a feed, the time the post's inverse time gives it (the
    /// tool tip's path at its feed, and no less than its turn takes at `turnSpeed`); a rapid, the longer of turning at
    /// `turnSpeed` (degrees per second) and moving X and Z at `rapidRate` (mm/min).
    static func seconds(_ m: Motion, from a: Vec3, centerY: Double, radius: Double, rapidRate: Double, turnSpeed: Double) -> Double {
        let d0 = (a.y - centerY) / radius * 180 / .pi, d1 = (m.end.y - centerY) / radius * 180 / .pi
        switch m.kind {
        case .feed:
            let length = tipLength(x0: a.x, r0: radius + a.z, degrees0: d0, x1: m.end.x, r1: radius + m.end.z, degrees1: d1)
            return 60 / inverseTime(length: length, feed: m.feed, degrees: d1 - d0, turnSpeed: turnSpeed * 60)
        case .rapid:
            let linear = ((m.end.x - a.x) * (m.end.x - a.x) + (m.end.z - a.z) * (m.end.z - a.z)).squareRoot()
            return max(abs(d1 - d0) / max(turnSpeed, 1e-9), linear / max(rapidRate, 1) * 60)
        default:
            return m.duration(from: a, rapidRate: rapidRate)
        }
    }

    /// How a controller is given the feed for a wrapped move.
    public enum FeedMode: Hashable, Sendable {
        /// G93 inverse time on every move that turns the rotary axis (exact everywhere it's supported).
        case inverseTime
        /// An ordinary G94 feed worked out per move from what F means to the controller on a rotary move.
        case perMinute(Dialect.RotaryFeed)
    }

    /// How wrapped moves are fed on `dialect`: inverse time when it takes G93, otherwise per-minute feeds where its
    /// rotary feed rule is documented; nil when neither is (the job can't be fed right there).
    public static func feedMode(_ dialect: Dialect) -> FeedMode? {
        if dialect.inverseTime { return .inverseTime }
        switch dialect.rotaryFeed {
        case .allAxes, .linearAxesOnly: return .perMinute(dialect.rotaryFeed)
        case .degreesPerMinute, .unknown: return nil
        }
    }

    /// The G94 F (linear units per minute, or degrees per minute) that makes a wrapped move take `length` ÷ `feed`
    /// on a controller without G93 (research §2.6). `dx`, `dz`, `length` and `feed` share one linear unit; `da` is
    /// in degrees.
    ///
    /// - `.allAxes` (the Grbl family's planner): F spreads over the whole move with degrees counted as lengths.
    /// - `.linearAxesOnly` (NIST, LinuxCNC): F applies to X and Z when either moves; a move that only turns runs in
    ///   degrees per minute.
    ///
    /// Like the inverse time, the move takes no less than its turn does at `turnSpeed` (degrees per minute): a move
    /// with the tool tip on the axis turns at the turn speed.
    public static func perMinuteFeed(_ rule: Dialect.RotaryFeed, dx: Double, dz: Double, da: Double, length: Double, feed: Double,
                                     turnSpeed: Double = .infinity) -> Double {
        let linear = (dx * dx + dz * dz).squareRoot()
        let distance = rule == .linearAxesOnly ? (linear > 1e-9 ? linear : abs(da)) : (linear * linear + da * da).squareRoot()
        let turn = turnSpeed > 0 && turnSpeed.isFinite ? abs(da) / turnSpeed : 0
        if length > 1e-9, feed <= 0 || length / feed >= turn { return feed * distance / length }
        guard turn > 0 else { return feed }
        return distance / turn
    }

    /// How fast the machine's rotary axis can turn, degrees per minute: its turn speed, or the nominal 90° a second
    /// until it's set.
    static func turnSpeed(_ machine: MachineProfile) -> Double {
        machine.rotary?.drivenTurnSpeed ?? RotaryAxis.nominalTurnSpeed
    }

    /// The feed for a move that turns the blank from `degrees0` to `degrees1` while X and the tool tip's distance from
    /// the axis go linearly from `x0`, `r0` to `x1`, `r1` (mm): `feed` (mm/min), or less when the rotary axis would
    /// have to turn faster than `turnSpeed` (degrees per minute) to keep it, which happens near the axis (research
    /// §2.3). Rounded down to a whole mm/min, and kept half a percent under the limit so that joining moves and the
    /// post's rounding can't take them over it.
    ///
    /// The move is cut as `pieces` equal pieces (`split`), each at this feed. Where it comes in toward the axis, the
    /// piece nearest it is the shortest and so turns the fastest: the limit is that piece's.
    static func turnLimitedFeed(_ feed: Double, x0: Double, r0: Double, degrees0: Double, x1: Double, r1: Double, degrees1: Double,
                                pieces: Int, turnSpeed: Double) -> Double {
        let degrees = abs(degrees1 - degrees0)
        guard degrees > 1e-9 else { return feed }
        let n = max(1, pieces)
        var shortest = Double.infinity
        for k in 0..<n {
            let t0 = Double(k) / Double(n), t1 = Double(k + 1) / Double(n)
            let piece = tipLength(x0: x0 + (x1 - x0) * t0, r0: r0 + (r1 - r0) * t0, degrees0: degrees0 + (degrees1 - degrees0) * t0,
                                  x1: x0 + (x1 - x0) * t1, r1: r0 + (r1 - r0) * t1, degrees1: degrees0 + (degrees1 - degrees0) * t1)
            shortest = min(shortest, piece)
        }
        let limit = 0.995 * turnSpeed * shortest / (degrees / Double(n))
        guard limit < feed else { return feed }
        return max(1, limit.rounded(.down))
    }

    /// Where a wrapped toolpath's feed came down most for the rotary axis (`limitTurnRate`).
    struct Slowing {
        /// The feed it came down to, and the one it was set to, mm/min.
        var feed: Double
        var set: Double
        /// The tool tip's least distance from the axis on that move, mm.
        var radius: Double
    }

    /// The warning for a toolpath whose feed comes down where the rotary axis can't turn fast enough, in the project's
    /// units.
    static func slowingWarning(_ s: Slowing, context ctx: GenerationContext) -> String {
        let speed = Int(turnSpeed(ctx.machine).rounded())
        let assumed = " (its Turn speed isn't set, so NativeCAM assumes 90° a second: set it in Material & Machine ▸ Rotary Axis)"
        return "The rotary axis turns at most \(speed.formatted())°/min\(ctx.machine.rotary?.drivenTurnSpeed == nil ? assumed : ""), "
            + "so near the axis the cut slows to keep up: down to \(ctx.feed(s.feed)) "
            + "at \(ctx.length(s.radius)) from the axis, from the \(ctx.feed(s.set)) set. If the wood burns there, "
            + "lower the spindle speed."
    }

    /// Lowers the feed of each feed move on a sheet wrapped around `diameter` that would turn the blank faster than
    /// `turnSpeed` (degrees per minute), allowing for the equal pieces `split` cuts it into (at most `maxSpan` of the
    /// sheet each). Returns where the feed came down most, as a fraction of what it was set to.
    static func limitTurnRate(_ motions: inout [Motion], start: Vec3, diameter: Double, maxSpan: Double,
                              turnSpeed: Double) -> Slowing? {
        let radius = diameter / 2
        var slowest: Slowing?
        var p = start
        for i in motions.indices {
            defer { if motions[i].kind != .dwell { p = motions[i].end } }
            let m = motions[i]
            let span = abs(m.end.y - p.y)
            guard m.kind == .feed, span > 1e-12 else { continue }
            let f = turnLimitedFeed(m.feed, x0: p.x, r0: radius + p.z, degrees0: angle(y: p.y, centerY: 0, diameter: diameter),
                                    x1: m.end.x, r1: radius + m.end.z, degrees1: angle(y: m.end.y, centerY: 0, diameter: diameter),
                                    pieces: pieceCount(span: span, maxSpan: maxSpan), turnSpeed: turnSpeed)
            guard f < m.feed else { continue }
            motions[i].feed = f
            if slowest.map({ f / m.feed < $0.feed / $0.set }) ?? true {
                slowest = Slowing(feed: f, set: m.feed, radius: max(0, radius + min(p.z, m.end.z)))
            }
        }
        return slowest
    }

    /// Readies a toolpath generated on the unrolled sheet for wrapping around `diameter`:
    /// - arcs become lines within the context's flattening tolerance, since no controller can arc in X and A;
    /// - runs of short lines that lie within half the tolerance of one straight line become that line, so the
    ///   controller isn't fed thousands of tiny inverse-time moves (within `mergeTolerance` instead when it's given:
    ///   flutes that follow a model have already been joined so they never dip below their depth, and keep that);
    /// - a rapid that would turn the blank below `clearanceZ` goes up, across and back down, because the blank only
    ///   turns with the tool clear of it;
    /// - a feed that would need the blank to turn faster than the machine's turn speed comes down to what it can keep
    ///   (`turnLimitedFeed`), with a warning saying how far, unless `warns` is false (3D rotary finishing lowers its
    ///   own feeds and says so);
    /// - a move that turns the blank more than `maxTurnPerMove` is split into equal pieces.
    static func prepare(_ tp: Toolpath, diameter: Double, clearanceZ: Double, context ctx: GenerationContext,
                        warns: Bool = true, mergeTolerance: Double? = nil) -> Toolpath {
        let tolerance = ctx.flattenTolerance
        var lines: [Motion] = []
        var p = tp.start
        for m in tp.motions {
            defer { p = m.end }
            switch m.kind {
            case .arcCW, .arcCCW:
                lines += VectricTemplatePost.lines(for: m, from: p, tolerance: tolerance)
            case .rapid where abs(m.end.y - p.y) > 1e-9 && min(p.z, m.end.z) < clearanceZ - 1e-9:
                if p.z < clearanceZ - 1e-9 { lines.append(.rapid(Vec3(p.xy, clearanceZ))) }
                lines.append(.rapid(Vec3(m.end.xy, clearanceZ)))
                if m.end.z < clearanceZ - 1e-9 { lines.append(.rapid(m.end)) }
            default:
                lines.append(m)
            }
        }
        var t = tp
        let maxSpan = maxTurnPerMove / 360 * .pi * diameter
        var motions = merged(lines, start: tp.start, tolerance: mergeTolerance ?? tolerance / 2)
        let slowest = limitTurnRate(&motions, start: tp.start, diameter: diameter, maxSpan: maxSpan, turnSpeed: turnSpeed(ctx.machine))
        t.motions = split(motions, start: tp.start, maxSpan: maxSpan)
        t.wrapDiameter = diameter
        if warns, let slowest { t.warnings.append(slowingWarning(slowest, context: ctx)) }
        return t
    }

    /// How many equal pieces `split` cuts a move into that spans `span` of the sheet's Y, at most `maxSpan` each.
    static func pieceCount(span: Double, maxSpan: Double) -> Int {
        span > maxSpan + 1e-9 ? Int((span / maxSpan).rounded(.up)) : 1
    }

    /// Splits rapids and feed lines that span more than `maxSpan` of the sheet's Y into equal pieces.
    static func split(_ motions: [Motion], start: Vec3, maxSpan: Double) -> [Motion] {
        var out: [Motion] = []
        var p = start
        for m in motions {
            defer { if m.kind != .dwell { p = m.end } }
            let n = pieceCount(span: abs(m.end.y - p.y), maxSpan: maxSpan)
            guard m.kind == .rapid || m.kind == .feed, n > 1 else {
                out.append(m)
                continue
            }
            for i in 1...n {
                var piece = m
                if i < n {
                    let f = Double(i) / Double(n)
                    piece.end = Vec3(p.x + (m.end.x - p.x) * f, p.y + (m.end.y - p.y) * f, p.z + (m.end.z - p.z) * f)
                }
                out.append(piece)
            }
        }
        return out
    }

    /// Joins consecutive feed lines at one feed rate while every point dropped stays within `tolerance` of the
    /// joined line.
    static func merged(_ motions: [Motion], start: Vec3, tolerance: Double) -> [Motion] {
        var out: [Motion] = []
        var anchor = start
        var dropped: [Vec3] = []
        var position = start
        for m in motions {
            defer { position = m.kind == .dwell ? position : m.end }
            guard m.kind == .feed, let last = out.last, last.kind == .feed, last.feed == m.feed, dropped.count < 256 else {
                out.append(m)
                anchor = position
                dropped = []
                continue
            }
            let candidates = dropped + [last.end]
            if candidates.allSatisfy({ distance($0, toSegment: anchor, m.end) <= tolerance }) {
                out[out.count - 1] = m
                dropped = candidates
            } else {
                out.append(m)
                anchor = last.end
                dropped = []
            }
        }
        return out
    }

    static func distance(_ p: Vec3, toSegment a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
        guard len2 > 1e-24 else { return p.distance(to: a) }
        let ap = p - a
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / len2))
        return p.distance(to: Vec3(a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t))
    }
}

/// What the posts track between lines, so a wrapped toolpath can be written by the shared `WrappedWriter`.
protocol WrapModalState {
    var x: Double? { get set }
    var y: Double? { get set }
    var z: Double? { get set }
    var feed: Double? { get set }
    var a: Double? { get set }
}

extension WrapModalState {
    /// The position along the blank last written: X, or Y on an axis along Y.
    func along(_ frame: RotaryFrame) -> Double? { frame.alignment == .x ? x : y }
}

/// Writes a wrapped toolpath as words along the axis (X, or Y on an axis along Y), Z and A, for every G-code post, so
/// their inverse-time handling can't drift apart. Following Avid's own wrap posts:
/// - a move that turns the blank is `G93 G1 X.. Z.. A.. F<1/min>`, with F on every such line;
/// - other moves (plunges, moves along the blank) stay in G94 with an ordinary feed, restated after each switch back;
/// - G94 is back on before the toolpath ends, so tool changes and the program end never run in G93.
struct WrappedWriter {
    /// Where the blank lies on the machine: the tool stays over its centreline.
    let frame: RotaryFrame
    let rotary: RotaryOutput
    let units: LengthUnit
    let decimals: Int
    let feedDecimals: Int
    let feeds: RotaryWrap.FeedMode
    /// How fast the rotary axis turns, degrees per minute (`RotaryWrap.turnSpeed`): no move's F asks for a faster turn.
    let turnSpeed: Double
    /// "G00"/"G01" for Avid's posts, "G0"/"G1" for the rest.
    let rapidWord: String
    let feedWord: String
    let dwell: (Double) -> String

    func round(_ mm: Double) -> Double {
        let p = pow(10, Double(decimals))
        let r = (units.fromMM(mm) * p).rounded() / p
        return r == 0 ? 0 : r
    }

    func roundFeed(_ perMinute: Double) -> Double {
        let p = pow(10, Double(feedDecimals))
        return (perMinute * p).rounded() / p
    }

    func fmt(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }
    func fmtFeed(_ v: Double) -> String { String(format: "%.\(feedDecimals)f", v) }

    /// The A value written for the sheet's line `y`.
    func aValue(_ y: Double, diameter: Double) -> Double {
        rotary.value(RotaryWrap.angle(y: y, centerY: frame.stock.originPoint.y, diameter: diameter))
    }

    /// From safe Z: over the start along the blank with the tool on the axis centreline, then the turn that brings the
    /// start under it, the shorter way round from `last` (the A value last written) when it's more than a turn away.
    /// True when the blank turns; `offset` (whole turns) goes to `motions`. A restart part way through the toolpath
    /// passes the full program's `offset` for it (`RestartSeed.wrapOffset`), so every A word matches the full file's.
    func approach<S: WrapModalState>(_ tp: Toolpath, state: inout S, after last: Double?, offset forced: Double? = nil)
        -> (lines: [String], turned: Bool, offset: Double) {
        guard let d = tp.wrapDiameter else { return ([], false, 0) }
        let w = frame.overAxis(tp.start)
        let x = round(w.x), y = round(w.y)
        var lines = ["\(rapidWord) X\(fmt(x)) Y\(fmt(y))"]
        state.x = x
        state.y = y
        let start = aValue(tp.start.y, diameter: d)
        var a = RotaryOutput.nearestTurn(start, after: last)
        if let forced {
            a = forced == 0 ? start : ((start + forced) * 1000).rounded() / 1000
            if a == 0 { a = 0 }
        }
        let offset = forced ?? (a - start)
        guard state.a != a else { return (lines, false, offset) }
        lines.append("\(rapidWord) \(rotary.word(value: a))")
        state.a = a
        return (lines, true, offset)
    }

    /// The toolpath's moves, after `approach`, each A moved by `offset` (whole turns). True when the blank turns;
    /// `cutA` is the range of A values, as written, that its feed moves run between (nil when none is written).
    func motions<S: WrapModalState>(_ tp: Toolpath, state: inout S, offset: Double = 0)
        -> (lines: [String], turned: Bool, cutA: ClosedRange<Double>?) {
        guard let d = tp.wrapDiameter else { return ([], false, nil) }
        var lines: [String] = []
        var turned = false
        var inverse = false
        var cutA: ClosedRange<Double>?
        func cuts(_ a: Double?) {
            guard let a else { return }
            cutA = cutA.map { min($0.lowerBound, a)...max($0.upperBound, a) } ?? a...a
        }
        for m in tp.motions {
            if m.kind == .dwell {
                lines.append(dwell(m.feed))
                continue
            }
            let w = frame.overAxis(m.end)
            let ex = round(w.x), ey = round(w.y), ez = round(w.z)
            let ea = offset == 0 ? aValue(m.end.y, diameter: d) : ((aValue(m.end.y, diameter: d) + offset) * 1000).rounded() / 1000
            let turns = ea != state.a
            guard ex != state.x || ey != state.y || ez != state.z || turns else { continue }
            var words = ""
            if ex != state.x { words += " X\(fmt(ex))" }
            if ey != state.y { words += " Y\(fmt(ey))" }
            if ez != state.z { words += " Z\(fmt(ez))" }
            if turns { words += " \(rotary.letter)\(String(format: "%.3f", ea))" }
            if m.kind != .rapid {
                cuts(state.a)
                cuts(ea)
            }
            if m.kind == .rapid {
                lines.append(rapidWord + words)
            } else if turns, let sx = state.along(frame), let sz = state.z, let sa = state.a {
                // Along the blank: X, or Y on an axis along Y.
                let along = frame.alignment == .x ? ex : ey
                let length = RotaryWrap.tipLength(x0: units.toMM(sx), r0: units.toMM(sz), degrees0: sa,
                                                  x1: units.toMM(along), r1: units.toMM(ez), degrees1: ea)
                switch feeds {
                case .inverseTime:
                    let f = RotaryWrap.inverseTime(length: length, feed: m.feed, degrees: ea - sa, turnSpeed: turnSpeed)
                    let p = pow(10, Double(RotaryWrap.inverseTimeDecimals))
                    let written = String(format: "%.\(RotaryWrap.inverseTimeDecimals)f", (f * p).rounded() / p)
                    lines.append((inverse ? "" : "G93 ") + feedWord + words + " F" + written)
                    inverse = true
                    // The F words in G93 are times, not feeds: the next G94 move must give its feed again.
                    state.feed = nil
                case let .perMinute(rule):
                    let f = roundFeed(RotaryWrap.perMinuteFeed(rule, dx: along - sx, dz: ez - sz, da: ea - sa,
                                                               length: units.fromMM(length), feed: units.fromMM(m.feed),
                                                               turnSpeed: turnSpeed))
                    if f != state.feed { words += " F\(fmtFeed(f))"; state.feed = f }
                    lines.append(feedWord + words)
                }
            } else {
                var prefix = ""
                if inverse {
                    prefix = "G94 "
                    inverse = false
                    state.feed = nil
                }
                let f = roundFeed(units.fromMM(m.feed))
                if f != state.feed { words += " F\(fmtFeed(f))"; state.feed = f }
                lines.append(prefix + feedWord + words)
            }
            if turns { turned = true }
            state.x = ex
            state.y = ey
            state.z = ez
            state.a = ea
        }
        if inverse {
            lines.append("G94")
            state.feed = nil
        }
        return (lines, turned, cutA)
    }
}
