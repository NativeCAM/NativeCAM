import Foundation

/// Holes bored on a helix with a bit smaller than the hole: tiling's registration holes (`registrationHoles`) and a
/// Drill toolpath's Helical bore (`DrillParams.helix`, `cut`).
///
/// Both bore a hole wider than twice the bit in rings out from the middle (`rings`), so no core is left standing: the
/// innermost ring no more than 0.9 × the bit's radius from the centre bores a full disc, and the rings beyond it are at
/// most 0.8 × the bit's diameter apart. Each ring is a helix down to depth and a full lap round the bottom.
enum BoreHelix {
    /// The bit-centre radii of the rings a hole is bored in, inner first, when the bit's centre must reach `ring` from
    /// the hole's centre.
    static func rings(_ ring: Double, tool: Tool) -> [Double] {
        let inner = 0.9 * tool.radius
        guard ring > inner else { return [ring] }
        let n = Int(((ring - inner) / (0.8 * tool.diameter)).rounded(.up))
        return (0...n).map { k -> Double in inner + (ring - inner) * Double(k) / Double(n) }
    }

    // MARK: Registration holes

    /// Tiling's registration holes of `radius` to `depth` below the material top at `points`, in order, as `id`'s
    /// motions: plunged in pecks when the bit is the hole's size, otherwise bored in short straight moves (fitted to
    /// arcs later) on a helix no steeper than 10°.
    static func registrationHoles(_ points: [Vec2], radius: Double, depth: Double, tool: Tool, stock: Stock, id: UUID) -> [Motion] {
        var b = ToolpathBuilder(stock: stock, tool: tool, startXY: points.first)
        let r = tool.radius
        let ring = radius - r
        let step = max(0.1, tool.cutting.stepdown)
        for c in points {
            if ring < 0.05 {
                // The bit is the hole's size: plunge in pecks, clearing chips between them.
                var reached = 0.0
                b.enter(at: Vec3(c, b.plungeZ))
                while reached < depth - 1e-9 {
                    if reached > 0 { b.rapid(Vec3(c, -reached + 0.5)) }
                    reached = min(depth, reached + step)
                    b.feed(Vec3(c, -reached), rate: tool.cutting.plungeRate)
                    if reached < depth - 1e-9 { b.rapid(Vec3(c, b.plungeZ)) }
                }
                b.retract()
                continue
            }
            // Rings out from the middle (so no core is left standing in the spoilboard), each a helix down to depth
            // and a lap round the bottom.
            let feed = tool.cutting.feedRate
            for rho in rings(ring, tool: tool) {
                let circumference = 2 * Double.pi * rho
                let pitch = min(step, max(0.2, circumference * tan(10 * Double.pi / 180)))
                let segments = max(24, Int((circumference / 1.0).rounded(.up)))
                b.enter(at: Vec3(c + Vec2(rho, 0), 0))
                let total = max(1, Int((depth / pitch * Double(segments)).rounded(.up)))
                for k in 1...total {
                    let turn = Double(k) / Double(segments)
                    let p = c + Vec2.fromAngle(2 * Double.pi * turn, length: rho)
                    b.feed(Vec3(p, -min(depth, turn * pitch)), rate: feed)
                }
                let a0 = 2 * Double.pi * Double(total) / Double(segments)
                for k in 1...segments {
                    let p = c + Vec2.fromAngle(a0 + 2 * Double.pi * Double(k) / Double(segments), length: rho)
                    b.feed(Vec3(p, -depth), rate: feed)
                }
                b.feed(Vec3(c, -depth), rate: feed)
                b.retract()
            }
        }
        return b.build(id: id, name: "", tool: tool, rpm: tool.cutting.spindleRPM, warnings: []).motions
    }

    // MARK: Helical bore

    /// The pitch per turn of a helix on bit-centre radius `rho`: no more than the bit's stepdown, and no steeper than
    /// `rampDegrees`.
    static func pitch(radius rho: Double, tool: Tool, rampDegrees: Double) -> Double {
        let step = max(0.05, tool.cutting.stepdown)
        let ramp = 2 * Double.pi * rho * tan(rampDegrees * Double.pi / 180)
        return max(1e-4, min(step, ramp))
    }

    /// The bit-centre radius a bore of a hole of `diameter` reaches: (D_hole − D_bit)/2.
    static func reach(diameter: Double, tool: Tool) -> Double { max(0, (diameter - tool.diameter) / 2) }

    /// The feed on a circle of bit-centre radius `rho`: the bit's feed slowed so the wall, on the circle's outside,
    /// sees `feed`.
    static func circleFeed(_ feed: Double, radius rho: Double, tool: Tool) -> Double {
        max(1, feed * FeedScheduler.insideArcFactor(pathRadius: rho, toolRadius: tool.radius))
    }

    /// How much a move of a helical bore is slowed for its circle (`circleFeed`): the inside-arc factor for a move that
    /// starts and ends the same distance from a bored hole's centre, no farther than the hole lets the bit go (a turn of
    /// the helix or a lap, as an arc or as short lines); 1 for anything else.
    static func feedFactor(_ m: Motion, from p: Vec3, holes: [BoredHole], toolRadius r: Double) -> Double {
        guard m.kind == .feed || m.kind.isArc else { return 1 }
        for hole in holes where hole.bored {
            if m.kind.isArc, m.center.distance(to: hole.center) > 1e-6 { continue }
            let rho = p.xy.distance(to: hole.center)
            guard rho > 1e-6, rho <= hole.reach + 1e-6, abs(m.end.xy.distance(to: hole.center) - rho) < 1e-3 else { continue }
            let f = FeedScheduler.insideArcFactor(pathRadius: rho, toolRadius: r)
            return f > 1e-9 ? f : 1
        }
        return 1
    }

    /// Bores the hole of `diameter` at `center` to `depth` below the material top: each ring a helix from the
    /// material top down to depth in arcs of at most a quarter turn, then a full lap at depth; on the last, with a
    /// finishing allowance, the helix stops the allowance short of the wall and a lead and a lap at full depth cut the
    /// wall to size. Then a feed to the centre at depth, off the wall, and straight up. With `arcs` false (a machine
    /// that posts no arcs) each arc is cut as short straight moves instead, every one inside the hole.
    static func cut(_ b: inout ToolpathBuilder, center c: Vec2, diameter: Double, depth: Double, tool: Tool, settings: HelixBore,
                    arcs: Bool) -> BoredHole {
        let ccw = settings.counterClockwise
        let sense: Double = ccw ? 1 : -1
        let full = reach(diameter: diameter, tool: tool)
        // The allowance can't take the helix inside the middle.
        let allowance = min(settings.allowanceInUse, max(0, full - 0.01))
        let finishing = allowance > 1e-3
        let ring = full - allowance
        let rings = Self.rings(ring, tool: tool)
        let feed = tool.cutting.feedRate
        let quarter = Double.pi / 2

        func point(_ rho: Double, _ theta: Double, _ z: Double) -> Vec3 { Vec3(c + Vec2.fromAngle(sense * theta, length: rho), z) }
        func arc(to p: Vec3, about centre: Vec2, rate: Double) {
            if arcs {
                b.arc(to: p, center: centre, counterClockwise: ccw, rate: rate)
            } else {
                let m = Motion(kind: ccw ? .arcCCW : .arcCW, end: p, center: centre, feed: rate)
                for line in VectricTemplatePost.lines(for: m, from: b.position, tolerance: 0.005) { b.feed(line.end, rate: rate) }
            }
        }
        /// Quarter turns (the last part of one) round `rho` from `theta0` to `theta1`, Z going linearly from `z0` to `z1`.
        func turns(_ rho: Double, from theta0: Double, to theta1: Double, z0: Double, z1: Double, rate: Double) {
            let span = theta1 - theta0
            let n = max(1, Int((span / quarter - 1e-6).rounded(.up)))
            for k in 1...n {
                let theta = k == n ? theta1 : theta0 + Double(k) * quarter
                arc(to: point(rho, theta, z0 + (z1 - z0) * (theta - theta0) / span), about: c, rate: rate)
            }
        }

        var lastPitch = 0.0
        var theta = 0.0
        for rho in rings {
            let pitch = Self.pitch(radius: rho, tool: tool, rampDegrees: settings.rampInUse)
            lastPitch = pitch
            let rate = circleFeed(feed, radius: rho, tool: tool)
            b.enter(at: point(rho, 0, 0))
            // Down to depth, then a full lap at it, so the floor is flat.
            theta = 2 * Double.pi * depth / pitch
            turns(rho, from: 0, to: theta, z0: 0, z1: -depth, rate: rate)
            turns(rho, from: theta, to: theta + 2 * Double.pi, z0: -depth, z1: -depth, rate: rate)
            theta += 2 * Double.pi
            if rho != rings.last { b.feed(Vec3(c, -depth), rate: rate) }
        }
        if finishing {
            // Out to the wall on a half circle inside the hole that meets it going the lap's way, then a lap round it.
            let rate = circleFeed(feed * settings.finishFeedInUse, radius: full, tool: tool)
            let u = Vec2.fromAngle(sense * theta, length: 1)
            let leadCentre = c + u * (ring + allowance / 2)
            let side = Vec2(-u.y, u.x) * sense // the lap's direction where the lead meets the wall
            arc(to: Vec3(leadCentre - side * (allowance / 2), -depth), about: leadCentre, rate: rate)
            arc(to: point(full, theta, -depth), about: leadCentre, rate: rate)
            turns(full, from: theta, to: theta + 2 * Double.pi, z0: -depth, z1: -depth, rate: rate)
        }
        // Off the wall to the middle, at depth, then straight up.
        b.feed(Vec3(c, -depth), rate: feed)
        b.retract()
        return BoredHole(center: c, diameter: diameter, bored: true, counterClockwise: ccw, pitch: lastPitch, rings: rings.count,
                         finishLap: finishing, reach: full)
    }
}
