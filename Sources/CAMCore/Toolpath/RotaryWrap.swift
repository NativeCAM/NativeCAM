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
    public static func perMinuteFeed(_ rule: Dialect.RotaryFeed, dx: Double, dz: Double, da: Double, length: Double, feed: Double) -> Double {
        guard length > 1e-9 else { return feed }
        let linear = (dx * dx + dz * dz).squareRoot()
        switch rule {
        case .linearAxesOnly:
            return feed * (linear > 1e-9 ? linear : abs(da)) / length
        default:
            return feed * (linear * linear + da * da).squareRoot() / length
        }
    }

    /// Readies a toolpath generated on the unrolled sheet for wrapping around `diameter`:
    /// - arcs become lines within `tolerance`, since no controller can arc in X and A;
    /// - runs of short lines that lie within half the tolerance of one straight line become that line, so the
    ///   controller isn't fed thousands of tiny inverse-time moves;
    /// - a rapid that would turn the blank below `clearanceZ` goes up, across and back down, because the blank only
    ///   turns with the tool clear of it.
    static func prepare(_ tp: Toolpath, diameter: Double, clearanceZ: Double, tolerance: Double) -> Toolpath {
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
        t.motions = merged(lines, start: tp.start, tolerance: tolerance / 2)
        t.wrapDiameter = diameter
        return t
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

/// Writes a wrapped toolpath as X, Z and A words, for every G-code post, so their inverse-time handling can't drift
/// apart. Following Avid's own wrap posts:
/// - a move that turns the blank is `G93 G1 X.. Z.. A.. F<1/min>`, with F on every such line;
/// - other moves (plunges, moves along X) stay in G94 with an ordinary feed, restated after each switch back;
/// - G94 is back on before the toolpath ends, so tool changes and the program end never run in G93.
struct WrappedWriter {
    let stock: Stock
    let rotary: RotaryOutput
    let units: LengthUnit
    let decimals: Int
    let feedDecimals: Int
    let feeds: RotaryWrap.FeedMode
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
        rotary.value(RotaryWrap.angle(y: y, centerY: stock.originPoint.y, diameter: diameter))
    }

    /// From safe Z: over the start along X with the tool on the axis centreline, then the turn that brings the start
    /// under it. True when the blank turns.
    func approach<S: WrapModalState>(_ tp: Toolpath, state: inout S) -> (lines: [String], turned: Bool) {
        guard let d = tp.wrapDiameter else { return ([], false) }
        let x = round(stock.toWork(tp.start).x)
        var lines = ["\(rapidWord) X\(fmt(x)) Y\(fmt(0))"]
        state.x = x
        state.y = 0
        let a = aValue(tp.start.y, diameter: d)
        guard state.a != a else { return (lines, false) }
        lines.append("\(rapidWord) \(rotary.letter)\(String(format: "%.3f", a))")
        state.a = a
        return (lines, true)
    }

    /// The toolpath's moves, after `approach`. True when the blank turns.
    func motions<S: WrapModalState>(_ tp: Toolpath, state: inout S) -> (lines: [String], turned: Bool) {
        guard let d = tp.wrapDiameter else { return ([], false) }
        var lines: [String] = []
        var turned = false
        var inverse = false
        for m in tp.motions {
            if m.kind == .dwell {
                lines.append(dwell(m.feed))
                continue
            }
            let w = stock.toWork(m.end)
            let ex = round(w.x), ez = round(w.z), ea = aValue(m.end.y, diameter: d)
            let turns = ea != state.a
            guard ex != state.x || ez != state.z || turns else { continue }
            var words = ""
            if ex != state.x { words += " X\(fmt(ex))" }
            if ez != state.z { words += " Z\(fmt(ez))" }
            if turns { words += " \(rotary.letter)\(String(format: "%.3f", ea))" }
            if m.kind == .rapid {
                lines.append(rapidWord + words)
            } else if turns, let sx = state.x, let sz = state.z, let sa = state.a {
                let length = RotaryWrap.tipLength(x0: units.toMM(sx), r0: units.toMM(sz), degrees0: sa,
                                                  x1: units.toMM(ex), r1: units.toMM(ez), degrees1: ea)
                switch feeds {
                case .inverseTime:
                    let f = RotaryWrap.inverseTime(length: length, feed: m.feed)
                    let p = pow(10, Double(RotaryWrap.inverseTimeDecimals))
                    let written = String(format: "%.\(RotaryWrap.inverseTimeDecimals)f", (f * p).rounded() / p)
                    lines.append((inverse ? "" : "G93 ") + feedWord + words + " F" + written)
                    inverse = true
                    // The F words in G93 are times, not feeds: the next G94 move must give its feed again.
                    state.feed = nil
                case let .perMinute(rule):
                    let f = roundFeed(RotaryWrap.perMinuteFeed(rule, dx: ex - sx, dz: ez - sz, da: ea - sa,
                                                               length: units.fromMM(length), feed: units.fromMM(m.feed)))
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
            state.z = ez
            state.a = ea
        }
        if inverse {
            lines.append("G94")
            state.feed = nil
        }
        return (lines, turned)
    }
}
