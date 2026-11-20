import Foundation
import simd

/// Run-time estimate that models how the controller (Mach4, or the Grbl family) actually moves the machine.
public struct CycleTimeEstimate: Sendable, Hashable {
    /// Whole job, seconds, including tool changes and links between toolpaths.
    public var total: Double
    /// Time in feed moves (cutting, ramps, plunges, links at depth).
    public var feedSeconds: Double
    /// Time in rapid (G0) moves.
    public var rapidSeconds: Double
    /// Dwells, tool changes, spin-up and turns of a rotary blank.
    public var overheadSeconds: Double
    /// Seconds for each toolpath's own motions (same order as the toolpaths).
    public var toolpathSeconds: [Double]
    /// Seconds for every motion of every toolpath, aligned with `Toolpath.motions` (drives realistic playback).
    public var motionSeconds: [[Double]]
    /// What the old distance ÷ feed estimate would say, for comparison.
    public var constantVelocity: Double
}

/// Trapezoidal-velocity planner over the job's moves.
///
/// - Each move is limited by its feed, by every axis's velocity and acceleration projected onto the move's
///   direction, and on arcs by the centripetal limit √(a·R).
/// - Corners use a junction-deviation speed (as in Grbl): v² = a·δ·sin(θ/2) / (1 − sin(θ/2)).
/// - Dwells, tool changes and spindle changes stop the machine. Rapids (G0) stop too on Mach4, which runs them in
///   exact stop; Grbl blends them like feeds.
/// - On a rotary job each turn of the blank stops the machine for as long as the axis takes to turn at its turn
///   speed, or for the time allowed for a turn by hand, where the spindle also stops and spins up again.
/// - The planner can only see `lookahead` moves ahead, so it must be able to stop within them.
/// Equations follow Grbl's planner and Klipper's trapezoid moves (reimplemented, no code copied).
public enum CycleTimeEstimator {
    struct Block {
        var length: Double
        var vMax: Double       // mm/s
        var accel: Double      // mm/s²
        var startDir: SIMD3<Double>
        var endDir: SIMD3<Double>
        var stopBefore: Bool
        var stopAfter: Bool
        var fixedSeconds: Double = 0
        var isRapid: Bool
        /// (toolpath, motion) this block times, if any.
        var ref: (Int, Int)?
    }

    public static func estimate(_ toolpaths: [Toolpath], project: Project) -> CycleTimeEstimate {
        let machine = project.machine
        let stock = project.stock
        let acc = machine.axisAcceleration
        let rapid = machine.axisRapid
        let delta = machine.cornerDeviation
        let rapidsStop = machine.planner.rapidsExactStop
        var blocks: [Block] = []
        var position: Vec3?
        var currentTool: Int?
        var currentRPM: Double?
        var constantVelocity = 0.0
        let clearance = max(stock.clearanceHeight, stock.plungeHeight)
        // Rotary: where the blank is (A as the post writes it, from A0) and, turned by hand, the angle last asked for.
        let rotary = RotaryOutput(project)
        let axis = machine.rotary ?? RotaryAxis()
        var blankAt = 0.0
        var dial: Double?

        func lineBlock(from a: Vec3, to b: Vec3, feed: Double?, ref: (Int, Int)?) -> Block? {
            let d = SIMD3(b.x - a.x, b.y - a.y, b.z - a.z)
            let len = simd_length(d)
            guard len > 1e-9 else { return nil }
            let u = d / len
            var v = feed.map { $0 / 60 } ?? .infinity
            var aMax = Double.infinity
            for (k, (axisV, axisA)) in [(rapid.x, acc.x), (rapid.y, acc.y), (rapid.z, acc.z)].enumerated() {
                let c = abs(u[k])
                guard c > 1e-9 else { continue }
                v = min(v, axisV / 60 / c)
                aMax = min(aMax, axisA / c)
            }
            let stop = feed == nil && rapidsStop
            return Block(length: len, vMax: v, accel: aMax, startDir: u, endDir: u,
                         stopBefore: stop, stopAfter: stop, isRapid: feed == nil, ref: ref)
        }

        func addRapid(_ a: Vec3, _ b: Vec3) {
            if let blk = lineBlock(from: a, to: b, feed: nil, ref: nil) {
                blocks.append(blk)
                constantVelocity += blk.length / (machine.rapidRateForEstimates / 60)
            }
        }

        /// A move of a wrapped toolpath, from sheet coordinates: X and the distance from the axis move at their own
        /// axes' limits, and the turn at no limit NativeCAM knows (Mach4's A acceleration isn't modelled), except a
        /// rapid's, which turns at the axis's turn speed. A feed is capped exactly as the post caps its inverse time.
        func wrappedBlock(from a: Vec3, to b: Vec3, feed: Double?, radius: Double, ref: (Int, Int)) -> Block? {
            let cy = stock.originPoint.y
            let r0 = radius + a.z, r1 = radius + b.z
            let d0 = (a.y - cy) / radius * 180 / .pi, d1 = (b.y - cy) / radius * 180 / .pi
            let length = RotaryWrap.tipLength(x0: a.x, r0: r0, degrees0: d0, x1: b.x, r1: r1, degrees1: d1)
            guard length > 1e-9 else { return nil }
            let around = (r0 + r1) / 2 * (d1 - d0) * .pi / 180
            let d = SIMD3(b.x - a.x, around, b.z - a.z)
            let u = simd_length(d) > 1e-12 ? simd_normalize(d) : SIMD3(0, 1, 0)
            var v = Double.infinity
            if let feed {
                // The post's inverse time, capped: never faster than its F word allows.
                v = min(feed / 60, length * RotaryWrap.maxInverseTime / 60)
            } else if abs(d1 - d0) > 1e-9 {
                v = length / (abs(d1 - d0) / ((axis.drivenTurnSpeed ?? RotaryAxis.nominalTurnSpeed) / 60))
            }
            var aMax = Double.infinity
            for (k, (axisV, axisA)) in [(0, (rapid.x, acc.x)), (2, (rapid.z, acc.z))] {
                let c = abs(u[k])
                guard c > 1e-9 else { continue }
                v = min(v, axisV / 60 / c)
                aMax = min(aMax, axisA / c)
            }
            if !aMax.isFinite { aMax = min(acc.x, acc.z) }
            let stop = feed == nil && rapidsStop
            return Block(length: length, vMax: v, accel: aMax, startDir: u, endDir: u, stopBefore: stop, stopAfter: stop,
                         isRapid: feed == nil, ref: ref)
        }

        func addPause(_ seconds: Double) {
            guard seconds > 0 else { return }
            blocks.append(Block(length: 0, vMax: 0, accel: 1, startDir: .zero, endDir: .zero, stopBefore: true, stopAfter: true,
                                fixedSeconds: seconds, isRapid: false, ref: nil))
            constantVelocity += seconds
        }

        for (ti, tp) in toolpaths.enumerated() where !tp.isEmpty {
            // What the post does between toolpaths: retract, tool change, spindle, rapid over to the start.
            if let p = position, p.z < clearance { addRapid(p, Vec3(p.xy, clearance)); position = Vec3(p.xy, clearance) }
            if currentTool != tp.tool.number {
                if currentTool != nil { addPause(machine.toolChangeTime) }
                currentTool = tp.tool.number
                currentRPM = nil
            }
            // A wrapped toolpath's start is at the angle its first point's Y gives; the blank turns there first.
            func wrappedAngle(_ y: Double) -> Double? {
                tp.wrapDiameter.flatMap { d in rotary?.value(RotaryWrap.angle(y: y, centerY: stock.originPoint.y, diameter: d)) }
            }
            let turnTo = wrappedAngle(tp.start.y) ?? tp.indexAngle.flatMap { rotary?.position($0) }
            if let rotary, rotary.manual, let to = turnTo, to != dial {
                // The program stops with the spindle off while the blank is turned by hand.
                addPause(axis.turnSeconds(from: blankAt, to: to))
                dial = to
                blankAt = to
                currentRPM = nil
            }
            if currentRPM != tp.spindleRPM {
                addPause(machine.spindleSpinUpDwell)
                // An S word breaks constant velocity even without a dwell.
                addPause(1e-9)
                currentRPM = tp.spindleRPM
            }
            if let p = position { addRapid(p, Vec3(tp.start.xy, max(p.z, tp.start.z))) }
            position = tp.start
            if let to = turnTo, to != blankAt {
                addPause(axis.turnSeconds(from: blankAt, to: to))
                blankAt = to
            }

            var p = tp.start
            for (mi, m) in tp.motions.enumerated() {
                // A wrapped move: the tool tip's path round the blank, at the feed the post's inverse time gives it.
                if let d = tp.wrapDiameter, m.kind == .rapid || m.kind == .feed {
                    if let blk = wrappedBlock(from: p, to: m.end, feed: m.kind == .feed ? m.feed : nil, radius: d / 2, ref: (ti, mi)) {
                        blocks.append(blk)
                        constantVelocity += blk.length / (m.kind == .feed ? max(m.feed / 60, 1e-6) : machine.rapidRateForEstimates / 60)
                    }
                    p = m.end
                    continue
                }
                // A move read back in inverse time takes the time its F word gives.
                if let f = m.inverseTime, f > 0, m.kind != .rapid, m.kind != .dwell {
                    let length = m.length(from: p)
                    let seconds = 60 / f
                    if length > 1e-9, var blk = lineBlock(from: p, to: m.end, feed: length / seconds * 60, ref: (ti, mi)) {
                        blk.ref = (ti, mi)
                        blocks.append(blk)
                    } else {
                        blocks.append(Block(length: 0, vMax: 0, accel: 1, startDir: .zero, endDir: .zero, stopBefore: true, stopAfter: true,
                                            fixedSeconds: seconds, isRapid: false, ref: (ti, mi)))
                    }
                    constantVelocity += seconds
                    p = m.end
                    continue
                }
                switch m.kind {
                case .rapid:
                    if var blk = lineBlock(from: p, to: m.end, feed: nil, ref: (ti, mi)) {
                        blk.ref = (ti, mi)
                        blocks.append(blk)
                        constantVelocity += blk.length / (machine.rapidRateForEstimates / 60)
                    }
                case .feed:
                    if let blk = lineBlock(from: p, to: m.end, feed: m.feed, ref: (ti, mi)) {
                        blocks.append(blk)
                        constantVelocity += blk.length / max(m.feed / 60, 1e-6)
                    }
                case .arcCW, .arcCCW:
                    let r = p.xy.distance(to: m.center)
                    let length = m.length(from: p)
                    guard length > 1e-9 else { break }
                    let sweep = m.arcSweep(from: p)
                    let planar = abs(sweep) * r
                    let dz = m.end.z - p.z
                    func tangent(at q: Vec2) -> SIMD3<Double> {
                        let radial = (q - m.center).normalized
                        let t = m.kind == .arcCCW ? radial.perpLeft : radial.perpRight
                        let v = SIMD3(t.x * planar, t.y * planar, dz)
                        return simd_length(v) > 0 ? simd_normalize(v) : .zero
                    }
                    let axy = min(acc.x, acc.y)
                    let v = min(m.feed / 60, (axy * r).squareRoot(), min(rapid.x, rapid.y) / 60)
                    blocks.append(Block(length: length, vMax: v, accel: axy, startDir: tangent(at: p.xy), endDir: tangent(at: m.end.xy),
                                        stopBefore: false, stopAfter: false, isRapid: false, ref: (ti, mi)))
                    constantVelocity += length / max(m.feed / 60, 1e-6)
                case .dwell:
                    blocks.append(Block(length: 0, vMax: 0, accel: 1, startDir: .zero, endDir: .zero, stopBefore: true, stopAfter: true,
                                        fixedSeconds: max(0, m.feed), isRapid: false, ref: (ti, mi)))
                    constantVelocity += max(0, m.feed)
                }
                p = m.end
            }
            position = p
            if let end = wrappedAngle(p.y) { blankAt = end }
        }
        // Footer: retract, turn a driven axis back to A0, and park.
        if let p = position {
            let park = stock.parkPosition
            addRapid(p, Vec3(p.xy, max(p.z, park.z)))
            if rotary?.manual == false { addPause(axis.turnSeconds(from: blankAt, to: 0)) }
            addRapid(Vec3(p.xy, max(p.z, park.z)), park)
        }

        let times = plan(blocks, deviation: delta, lookahead: machine.plannerLookahead)
        var motionSeconds = toolpaths.map { [Double](repeating: 0, count: $0.motions.count) }
        var feedT = 0.0, rapidT = 0.0, overheadT = 0.0
        for (blk, t) in zip(blocks, times) {
            if let (ti, mi) = blk.ref { motionSeconds[ti][mi] += t }
            if blk.length == 0 { overheadT += t } else if blk.isRapid { rapidT += t } else { feedT += t }
        }
        let total = times.reduce(0, +)
        return CycleTimeEstimate(total: total, feedSeconds: feedT, rapidSeconds: rapidT, overheadSeconds: overheadT,
                                 toolpathSeconds: motionSeconds.map { $0.reduce(0, +) }, motionSeconds: motionSeconds,
                                 constantVelocity: constantVelocity)
    }

    /// Plans entry speeds (backward then forward pass) and returns each block's duration.
    static func plan(_ b: [Block], deviation: Double, lookahead: Int) -> [Double] {
        let n = b.count
        guard n > 0 else { return [] }
        // Entry-speed limits from corners, stops and the look-ahead window.
        var limit = [Double](repeating: 0, count: n + 1) // limit[i] = max speed entering block i; limit[n] = 0
        var windowLength = 0.0
        var suffix = [Double](repeating: 0, count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            windowLength += b[i].length
            if i + lookahead < n { windowLength -= b[i + lookahead].length }
            suffix[i] = windowLength
        }
        for i in 0..<n {
            if i == 0 || b[i].stopBefore || b[i - 1].stopAfter || b[i].length == 0 || b[i - 1].length == 0 {
                limit[i] = 0
                continue
            }
            let a = min(b[i - 1].accel, b[i].accel)
            let cosTheta = -simd_dot(b[i - 1].endDir, b[i].startDir)
            var vj: Double
            if cosTheta > 0.999999 {
                vj = 0 // reversal
            } else if cosTheta < -0.999999 {
                vj = .infinity // straight on
            } else {
                let s = (0.5 * (1 - cosTheta)).squareRoot() // sin(θ/2)
                vj = (a * deviation * s / (1 - s)).squareRoot()
            }
            vj = min(vj, b[i - 1].vMax, b[i].vMax)
            // Must be able to stop within the moves the controller can see.
            vj = min(vj, (2 * b[i].accel * suffix[i]).squareRoot())
            limit[i] = vj
        }
        // Backward pass: each entry speed must allow decelerating to the next one.
        var entry = limit
        entry[n] = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            let exit = b[i].stopAfter ? 0 : entry[i + 1]
            entry[i] = min(entry[i], (exit * exit + 2 * b[i].accel * b[i].length).squareRoot())
        }
        // Forward pass: and accelerating from the previous one.
        for i in 0..<n {
            let reachable = (entry[i] * entry[i] + 2 * b[i].accel * b[i].length).squareRoot()
            entry[i + 1] = b[i].stopAfter ? 0 : min(entry[i + 1], reachable)
        }
        var times = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let blk = b[i]
            if blk.length == 0 { times[i] = blk.fixedSeconds; continue }
            let v0 = entry[i], v1 = blk.stopAfter ? 0 : entry[i + 1]
            times[i] = trapezoid(length: blk.length, v0: v0, v1: v1, vMax: blk.vMax, accel: blk.accel)
        }
        return times
    }

    /// Time to cover `length` starting at v0 and ending at v1, accelerating at most `accel` up to `vMax`.
    static func trapezoid(length L: Double, v0 v0In: Double, v1 v1In: Double, vMax: Double, accel a: Double) -> Double {
        let v0 = min(v0In, vMax), v1 = min(v1In, vMax)
        guard a.isFinite, a > 0 else { return L / max(vMax, 1e-9) }
        let peak = min(vMax, ((2 * a * L + v0 * v0 + v1 * v1) / 2).squareRoot())
        let dAcc = max(0, (peak * peak - v0 * v0) / (2 * a))
        let dDec = max(0, (peak * peak - v1 * v1) / (2 * a))
        let cruise = max(0, L - dAcc - dDec)
        return (peak - v0) / a + (peak - v1) / a + cruise / max(peak, 1e-9)
    }
}
