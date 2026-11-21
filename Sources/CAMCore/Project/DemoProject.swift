import Foundation

public extension Project {
    /// Fixed IDs for the demo projects, so regenerating them gives the same files (like the starter tool library's,
    /// with 01 in place of 00). IDs only need to be unique within a project; paste and duplicate assign new ones.
    private static func demoID(_ n: Int) -> UUID { UUID(uuidString: String(format: "4E415449-5645-4341-4D01-%012d", n))! }

    /// A small sign job that exercises every operation: V-carved text, a pocket, drilled holes and a
    /// cut-out with tabs, on 24" × 18" × 3/4" plywood.
    static func demoSign(fontName: String = "Helvetica-Bold") -> Project {
        let lib = ToolLibrary.starter
        let endMill = lib.tool(number: 1)!
        let vBit = lib.tool(number: 5)!
        let stock = Stock(width: 24.inch, height: 18.inch, thickness: 0.75.inch, materialName: "Baltic birch plywood")

        let outline = DesignShape(id: demoID(1), name: "Sign outline", kind: .rectangle(width: 22.inch, height: 16.inch, cornerRadius: 1.inch),
                                  position: Vec2(12.inch, 9.inch))
        let text = DesignShape(id: demoID(2), name: "Title", kind: .text(TextSpec(string: "AVID", fontName: fontName, capHeight: 3.5.inch)),
                               position: Vec2(12.inch, 11.5.inch))
        let pocket = DesignShape(id: demoID(3), name: "Plaque pocket", kind: .rectangle(width: 10.inch, height: 2.5.inch, cornerRadius: 0.25.inch),
                                 position: Vec2(12.inch, 5.inch))
        let holes = [Vec2(2.5, 2.5), Vec2(21.5, 2.5), Vec2(2.5, 15.5), Vec2(21.5, 15.5)].enumerated().map { i, p in
            DesignShape(id: demoID(4 + i), name: "Mounting hole \(i + 1)", kind: .circle(radius: 0.125.inch), position: Vec2(p.x.inch, p.y.inch))
        }

        let ops: [CAMOperation] = [
            CAMOperation(id: demoID(11), name: "V-carve title", kind: .vcarve(VCarveParams()), shapeIDs: [text.id], tool: vBit),
            CAMOperation(id: demoID(12), name: "Pocket plaque",
                      kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))),
                      shapeIDs: [pocket.id], tool: endMill),
            CAMOperation(id: demoID(13), name: "Drill mounting holes",
                      kind: .drill(DrillParams(depth: 0.77.inch, peckDepth: 0.25.inch)),
                      shapeIDs: holes.map(\.id), tool: endMill),
            CAMOperation(id: demoID(14), name: "Cut out sign",
                      kind: .profile(ProfileParams(side: .outside, direction: .climb,
                                                   depth: DepthSettings(cutDepth: 0.77.inch),
                                                   tabs: TabSettings(enabled: true, count: 6),
                                                   entry: EntrySettings(kind: .ramp, rampLength: 1.5.inch))),
                      shapeIDs: [outline.id], tool: endMill),
        ]
        return Project(name: "Demo sign", displayUnits: .inch, stock: stock, machine: .avidPRO6060,
                       shapes: [outline, text, pocket] + holes, operations: ops)
    }

    /// A 3D relief medallion (generated, no file needed) with 3D roughing, ball-nose finishing and a tabbed cut-out.
    /// The relief stands proud of the material around it, and 3D work stays inside the cut-out outline
    /// ("Selected vectors" boundary) so no time is spent machining the scrap the cut-out throws away.
    static func demoRelief() -> Project {
        let lib = ToolLibrary.starter
        let material = MaterialKind.hardwood
        // The starter feeds and speeds are inside the chart for hardwood as they are.
        let endMill = lib.tool(number: 1)!
        let ball = lib.tool(number: 7)!
        let stock = Stock(width: 7.inch, height: 5.inch, thickness: 0.75.inch, materialName: "Hard maple", materialKind: material)
        let center = Vec2(3.5.inch, 2.5.inch)
        var mesh = MeshModel.reliefMedallion(width: 150, height: 100)
        mesh.id = demoID(41)
        let spec = ModelSpec(mesh: mesh, upAxis: .z, depth: 0.4.inch)
        let relief = DesignShape(id: demoID(21), name: "Relief", kind: .model(spec), position: center)
        let outline = DesignShape(id: demoID(22), name: "Medallion outline", kind: .ellipse(radiusX: 76.5, radiusY: 51.5), position: center)
        let ops: [CAMOperation] = [
            CAMOperation(id: demoID(31), name: "Rough relief", kind: .rough3D(Rough3DParams(boundary: .vectors)),
                         shapeIDs: [relief.id, outline.id], tool: endMill),
            CAMOperation(id: demoID(32), name: "Finish relief",
                         kind: .finish3D(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 45, boundary: .vectors)),
                         shapeIDs: [relief.id, outline.id], tool: ball),
            CAMOperation(id: demoID(33), name: "Cut out medallion",
                         kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 0.77.inch),
                                                      tabs: TabSettings(enabled: true, count: 4),
                                                      entry: EntrySettings(kind: .ramp, rampLength: 1.inch))),
                         shapeIDs: [outline.id], tool: endMill),
        ]
        return Project(name: "Demo relief", displayUnits: .inch, stock: stock, machine: .avidPRO6060,
                       shapes: [relief, outline], operations: ops)
    }
}

public extension Project {
    /// A chess pawn turned on Avid's rotary from a 1.75" round blank (generated as a surface of revolution, no file
    /// needed): a rounding pass with the 1/4" end mill takes the blank down to just over the pawn's widest, then 3D
    /// rotary finishing with the 1/4" ball nose follows it all the way round, a spiral along the blank. The pawn keeps a
    /// short stub at each end, so it stays held between the chuck and the tailstock; part it off by hand.
    static func demoPawn() -> Project {
        let lib = ToolLibrary.starter
        var stock = Stock(materialName: "Poplar", materialKind: .softwood)
        stock.setRotary(RotaryStock(shape: .cylinder, diameter: 1.75.inch, length: 6.inch))
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis()
        var mesh = MeshModel.revolved(name: "Pawn", profile: MeshModel.pawnProfile(), segments: 96)
        mesh.id = demoID(42)
        let spec = ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(alongAxis: .x))
        let pawn = DesignShape(id: demoID(23), name: "Pawn", kind: .model(spec), position: Vec2(3.inch, stock.height / 2))
        var endMill = lib.tool(number: 1)!, ball = lib.tool(number: 7)!
        // Poplar wants a thicker chip than the plywood defaults: take the chart's recommendation.
        for i in [0, 1] {
            var t = i == 0 ? endMill : ball
            let rec = ChipLoad.recommend(for: t, material: .softwood, machine: machine)
            t.cutting.feedRate = rec.feed
            t.cutting.spindleRPM = rec.rpm
            if i == 0 { endMill = t } else { ball = t }
        }
        let ops: [CAMOperation] = [
            CAMOperation(id: demoID(34), name: "Round to 1.55\"",
                         kind: .rounding(RoundingParams(finishedDiameter: 1.55.inch, startX: 0.75.inch, endX: 5.25.inch)),
                         shapeIDs: [], tool: endMill),
            CAMOperation(id: demoID(35), name: "Finish pawn", kind: .rotaryFinish(RotaryFinishParams()), shapeIDs: [pawn.id], tool: ball),
        ]
        return Project(name: "Demo pawn", displayUnits: .inch, stock: stock, machine: machine, shapes: [pawn], operations: ops)
    }
}

// MARK: Table leg (3D rotary roughing)

public extension Project {
    /// A table leg turned on Avid's rotary from a 2" square bar, 10" long (generated, no file needed): a square pommel
    /// at the chuck end left at the bar's own size, then a collar, a bead, a long taper and a foot. 3D rotary roughing
    /// with the 1/4" end mill clears the bar round the turned part, layer by layer, skipping the air over the bar's
    /// faces; 3D rotary finishing with the 1/4" ball nose then follows the leg from what the roughing left. Half an inch
    /// of the bar stays square at the tailstock end; part it off by hand.
    static func demoTableLeg() -> Project {
        let lib = ToolLibrary.starter
        var stock = Stock(materialName: "Poplar", materialKind: .softwood)
        stock.setRotary(RotaryStock(shape: .squareBar, diameter: 2.inch, length: 10.inch))
        var machine = MachineProfile.avidPRO6060
        machine.rotary = RotaryAxis()
        let length = 9.inch
        var mesh = MeshModel.tableLeg(width: 2.inch, length: length)
        mesh.id = demoID(43)
        let spec = ModelSpec(mesh: mesh, depth: 1, rotary: RotaryPlacement(alongAxis: .x))
        let leg = DesignShape(id: demoID(24), name: "Leg", kind: .model(spec), position: Vec2(0.5.inch + length / 2, stock.height / 2))
        var endMill = lib.tool(number: 1)!, ball = lib.tool(number: 7)!
        // Poplar wants a thicker chip than the plywood defaults: take the chart's recommendation.
        for i in [0, 1] {
            var t = i == 0 ? endMill : ball
            let rec = ChipLoad.recommend(for: t, material: .softwood, machine: machine)
            t.cutting.feedRate = rec.feed
            t.cutting.spindleRPM = rec.rpm
            if i == 0 { endMill = t } else { ball = t }
        }
        let ops: [CAMOperation] = [
            CAMOperation(id: demoID(36), name: "Rough leg", kind: .rotaryRough(RotaryRoughParams()), shapeIDs: [leg.id], tool: endMill),
            CAMOperation(id: demoID(37), name: "Finish leg", kind: .rotaryFinish(RotaryFinishParams(stepoverFraction: 0.15)),
                         shapeIDs: [leg.id], tool: ball),
        ]
        return Project(name: "Demo table leg", displayUnits: .inch, stock: stock, machine: machine, shapes: [leg], operations: ops)
    }
}

public extension MeshModel {
    /// A closed solid along +X from cross-sections: at each ring's x (mm, in order; a station given twice makes a step
    /// there), `radius(θ)` is the surface's distance from the axis at angle θ (radians from +Z toward +Y, as the rotary
    /// blank's), sampled at `segments` angles, with flat ends. A square section, r = half its width ÷ max(|cos θ|,
    /// |sin θ|), comes out exact when `segments` is a multiple of 8, which puts its corners on vertices.
    static func lofted(name: String, rings: [(x: Double, radius: (Double) -> Double)], segments: Int) -> MeshModel {
        let n = max(3, segments)
        var pos: [Float] = []
        var idx: [UInt32] = []
        for ring in rings {
            for j in 0..<n {
                let a = 2 * Double.pi * Double(j) / Double(n)
                let r = ring.radius(a)
                pos += [Float(ring.x), Float(r * sin(a)), Float(r * cos(a))]
            }
        }
        func v(_ i: Int, _ j: Int) -> UInt32 { UInt32(i * n + (j % n)) }
        for i in 0..<(rings.count - 1) {
            for j in 0..<n {
                idx += [v(i, j), v(i + 1, j), v(i + 1, j + 1), v(i, j), v(i + 1, j + 1), v(i, j + 1)]
            }
        }
        for (i, outward) in [(0, -1.0), (rings.count - 1, 1.0)] {
            let c = UInt32(pos.count / 3)
            pos += [Float(rings[i].x), 0, 0]
            for j in 0..<n {
                idx += outward > 0 ? [c, v(i, j + 1), v(i, j)] : [c, v(i, j), v(i, j + 1)]
            }
        }
        return MeshModel(name: name, positions: pos, indices: idx)
    }

    /// A table leg `length` long for a square bar `width` across (mm), along +X from the pommel end: a square pommel
    /// the bar's own size for the first 28% of it, a step down to a collar, a bead, a cove, a long taper, a bead at
    /// the foot and the foot itself. The narrowest (the bottom of the taper) is 0.24 × the width from the axis.
    static func tableLeg(width w: Double, length L: Double, segments: Int = 96) -> MeshModel {
        let square: (Double) -> Double = { a in w / 2 / max(abs(cos(a)), abs(sin(a))) }
        func round(_ r: Double) -> (Double) -> Double { { _ in r } }
        let pommel = 0.28 * L
        var rings: [(x: Double, radius: (Double) -> Double)] = [(0, square), (pommel, square)]
        /// The turned part's radius at x past the pommel.
        func r(_ x: Double) -> Double {
            let t = x - pommel
            switch t {
            case ..<(0.02 * L): return 0.45 * w
            case ..<(0.07 * L): return 0.36 * w + 0.09 * w * sin(.pi * (t - 0.02 * L) / (0.05 * L))
            case ..<(0.09 * L): return 0.32 * w
            case ..<(L - pommel - 0.13 * L):
                let f = (t - 0.09 * L) / (L - pommel - 0.22 * L)
                return 0.38 * w - 0.14 * w * f
            case ..<(L - pommel - 0.08 * L): return 0.24 * w + 0.06 * w * sin(.pi * (t - (L - pommel - 0.13 * L)) / (0.05 * L))
            default: return 0.26 * w
            }
        }
        let steps = max(8, Int((L - pommel).rounded()))
        for i in 0...steps {
            let x = pommel + (L - pommel) * Double(i) / Double(steps)
            rings.append((x, round(r(x))))
        }
        return lofted(name: "Table leg", rings: rings, segments: segments)
    }
}

public extension MeshModel {
    /// A closed surface of revolution about +X: `profile` gives (x, distance from the axis) from one end to the other
    /// (mm), turned through `segments` steps round the axis, with flat ends where the profile doesn't meet the axis.
    /// Angles follow the rotary blank's (from +Z toward +Y), and the triangles face outward.
    static func revolved(name: String, profile: [(x: Double, r: Double)], segments: Int) -> MeshModel {
        let n = max(3, segments)
        var pos: [Float] = []
        var idx: [UInt32] = []
        for (x, r) in profile {
            for j in 0..<n {
                let a = 2 * Double.pi * Double(j) / Double(n)
                pos += [Float(x), Float(r * sin(a)), Float(r * cos(a))]
            }
        }
        func v(_ i: Int, _ j: Int) -> UInt32 { UInt32(i * n + (j % n)) }
        for i in 0..<(profile.count - 1) {
            for j in 0..<n {
                // Outward with x increasing: (i, j) → (i, j+1) → (i+1, j+1) turns from +Z toward +Y, so the normal is
                // the cross product of the two edges, pointing away from the axis.
                idx += [v(i, j), v(i + 1, j), v(i + 1, j + 1), v(i, j), v(i + 1, j + 1), v(i, j + 1)]
            }
        }
        // Flat ends.
        for (i, outward) in [(0, -1.0), (profile.count - 1, 1.0)] where profile[i].r > 1e-9 {
            let c = UInt32(pos.count / 3)
            pos += [Float(profile[i].x), 0, 0]
            for j in 0..<n {
                idx += outward > 0 ? [c, v(i, j + 1), v(i, j)] : [c, v(i, j), v(i, j + 1)]
            }
        }
        return MeshModel(name: name, positions: pos, indices: idx)
    }

    /// A chess pawn's outline (x along it from the base, distance from the axis, mm): a footed base, a concave body,
    /// a collar, the neck and a round head, with a 4 mm stub past the head for the tailstock end. 86 mm long, 38 mm
    /// across at the base.
    static func pawnProfile(samples: Int = 344) -> [(x: Double, r: Double)] {
        func r(_ x: Double) -> Double {
            switch x {
            case ..<5: return 19
            case ..<9: return 16 + 3 * cos((x - 5) / 4 * .pi / 2)
            case ..<14: return 16 - 2 * (x - 9) / 5
            case ..<55: return 7 + 7 * pow((55 - x) / 41, 1.6)
            case ..<60: return 7 + 4 * sin(.pi * (x - 55) / 5)
            case ..<63: return 6.5
            default:
                let head = 100 - (x - 71) * (x - 71)
                return max(4, head > 0 ? head.squareRoot() : 0, x < 64 ? 6.5 : 0)
            }
        }
        let length = 86.0
        return (0...samples).map { i in
            let x = length * Double(i) / Double(samples)
            return (x, r(x))
        }
    }
}

public extension MeshModel {
    /// Oval medallion surface: a dome with ripples and a raised rim, as a top-surface triangle grid (Z up, mm).
    static func reliefMedallion(width: Double, height: Double, resolution: Int = 240) -> MeshModel {
        let a = width / 2, b = height / 2
        let nx = resolution, ny = Int(Double(resolution) * height / width)
        var pos: [Float] = []
        var index = [Int32](repeating: -1, count: (nx + 1) * (ny + 1))
        func z(_ u: Double, _ v: Double) -> Double {
            let r2 = u * u + v * v
            let r = r2.squareRoot()
            let dome = 9 * (max(0, 1 - r2)).squareRoot()
            let ripple = 0.9 * sin(16 * r) * (1 - r2)
            let rim = 2.5 * exp(-pow((r - 0.93) / 0.05, 2))
            return 1.5 + dome + ripple + rim
        }
        for j in 0...ny {
            for i in 0...nx {
                let u = Double(i) / Double(nx) * 2 - 1, v = Double(j) / Double(ny) * 2 - 1
                guard u * u + v * v <= 1.0001 else { continue }
                index[j * (nx + 1) + i] = Int32(pos.count / 3)
                pos += [Float(u * a), Float(v * b), Float(z(u, v))]
            }
        }
        var idx: [UInt32] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let v00 = index[j * (nx + 1) + i], v10 = index[j * (nx + 1) + i + 1]
                let v01 = index[(j + 1) * (nx + 1) + i], v11 = index[(j + 1) * (nx + 1) + i + 1]
                if v00 >= 0 && v10 >= 0 && v11 >= 0 { idx += [UInt32(v00), UInt32(v10), UInt32(v11)] }
                if v00 >= 0 && v11 >= 0 && v01 >= 0 { idx += [UInt32(v00), UInt32(v11), UInt32(v01)] }
            }
        }
        return MeshModel(name: "Relief medallion", positions: pos, indices: idx)
    }
}

// MARK: Shelf parts (nesting)

public extension Project {
    /// Parts for a small wall shelf, laid out loosely on a 48" × 48" sheet of 3/4" plywood for trying Toolpaths ▸ Nest
    /// Parts: two sides with shelf-pin holes, two shelves, a top with a hand-hold slot, an arched apron, four curved
    /// brackets and a round tray. Two 3/4" clamps hold the sheet at its left edge, under a 1" safe Z. The pin holes are
    /// drilled, the slot cut out from inside and every part cut out with tabs, all with the 1/4" end mill.
    static func demoNesting() -> Project {
        let lib = ToolLibrary.starter
        let endMill = lib.tool(number: 1)!
        var stock = Stock(width: 48.inch, height: 48.inch, thickness: 0.75.inch, materialName: "Baltic birch plywood")
        // Safe Z clears the clamps.
        stock.clearanceHeight = 1.inch
        var shapes: [DesignShape] = []
        var n = 50
        @discardableResult
        func add(_ name: String, _ kind: ShapeKind, _ x: Double, _ y: Double) -> DesignShape {
            var s = DesignShape(id: demoID(n), name: name, kind: kind, position: Vec2(x.inch, y.inch))
            n += 1
            if case .paths = kind { s.layer = "Parts" }
            shapes.append(s)
            return s
        }
        func rect(_ w: Double, _ h: Double, _ r: Double = 0) -> ShapeKind { .rectangle(width: w.inch, height: h.inch, cornerRadius: r.inch) }
        // A bracket: a 5.5" square less a quarter circle, 1" thick along both legs.
        let a = 5.5.inch, t = 1.inch
        let arc = Curves.arc(center: Vec2(a, a), radius: a - t, startAngle: 1.5 * .pi, sweep: -.pi / 2, tolerance: 0.01)
        let bracket = Polyline([Vec2(0, 0), Vec2(a, 0)] + arc + [Vec2(0, a)], closed: true).deduplicated()
            .transformed(.translation(Vec2(-a / 2, -a / 2)))
        // The apron: 18" × 3.5" with a shallow arch cut from its bottom edge, leaving a 3" foot each end.
        let hw = 9.inch, hh = 1.75.inch
        let arch = (0...32).map { k -> Vec2 in
            let theta = Double.pi - .pi * Double(k) / 32
            return Vec2(6.inch * cos(theta), -hh + 1.5.inch * sin(theta))
        }
        let apron = Polyline([Vec2(-hw, -hh)] + arch + [Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)], closed: true).deduplicated()

        var outlines: [DesignShape] = []
        var holes: [DesignShape] = []
        for (i, y) in [6.0, 18.0].enumerated() {
            outlines.append(add("Side \(i + 1)", rect(24, 9.25), 15.5, y))
            for dx in [-9.0, 9.0] {
                for dy in [-3.0, 3.0] { holes.append(add("Pin hole", .circle(radius: 0.125.inch), 15.5 + dx, y + dy)) }
            }
        }
        outlines.append(add("Tray", .circle(radius: 5.5.inch), 38, 7))
        outlines.append(add("Top", rect(18, 10, 0.75), 38, 20.5))
        let slot = add("Hand hold", rect(4, 1, 0.5), 38, 20.5)
        outlines.append(add("Shelf 1", rect(18, 9), 13, 31))
        outlines.append(add("Shelf 2", rect(18, 9), 33, 31))
        outlines.append(add("Apron", .paths([apron]), 13, 41))
        for (i, x) in [26.5, 32.5, 38.5, 44.5].enumerated() { outlines.append(add("Bracket \(i + 1)", .paths([bracket]), x, 42.5)) }
        for (i, y) in [11.5, 36.5].enumerated() {
            var clamp = add("Clamp \(i + 1)", rect(2, 3), 1.25, y)
            clamp.keepOutHeight = 0.75.inch
            shapes[shapes.count - 1] = clamp
        }
        let ops: [CAMOperation] = [
            CAMOperation(id: demoID(80), name: "Drill shelf-pin holes", kind: .drill(DrillParams(depth: 0.4.inch, peckDepth: 0.2.inch)),
                         shapeIDs: holes.map(\.id), tool: endMill),
            CAMOperation(id: demoID(81), name: "Cut hand hold",
                         kind: .profile(ProfileParams(side: .inside, depth: DepthSettings(cutDepth: 0.77.inch),
                                                      entry: EntrySettings(kind: .ramp, rampLength: 1.inch))),
                         shapeIDs: [slot.id], tool: endMill),
            CAMOperation(id: demoID(82), name: "Cut out parts",
                         kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 0.77.inch),
                                                      tabs: TabSettings(enabled: true, count: 4),
                                                      entry: EntrySettings(kind: .ramp, rampLength: 1.5.inch))),
                         shapeIDs: outlines.map(\.id), tool: endMill),
        ]
        return Project(name: "Demo shelf parts", displayUnits: .inch, stock: stock, machine: .avidPRO6060, shapes: shapes,
                       operations: ops)
    }
}
