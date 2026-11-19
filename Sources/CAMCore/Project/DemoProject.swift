import Foundation

public extension Project {
    /// A small sign job that exercises every operation: V-carved text, a pocket, drilled holes and a
    /// cut-out with tabs, on 24" × 18" × 3/4" plywood.
    static func demoSign(fontName: String = "Helvetica-Bold") -> Project {
        let lib = ToolLibrary.starter
        let endMill = lib.tool(number: 1)!
        let vBit = lib.tool(number: 5)!
        let stock = Stock(width: 24.inch, height: 18.inch, thickness: 0.75.inch, materialName: "Baltic birch plywood")

        let outline = DesignShape(name: "Sign outline", kind: .rectangle(width: 22.inch, height: 16.inch, cornerRadius: 1.inch),
                                  position: Vec2(12.inch, 9.inch))
        let text = DesignShape(name: "Title", kind: .text(TextSpec(string: "AVID", fontName: fontName, capHeight: 3.5.inch)),
                               position: Vec2(12.inch, 11.5.inch))
        let pocket = DesignShape(name: "Plaque pocket", kind: .rectangle(width: 10.inch, height: 2.5.inch, cornerRadius: 0.25.inch),
                                 position: Vec2(12.inch, 5.inch))
        let holes = [Vec2(2.5, 2.5), Vec2(21.5, 2.5), Vec2(2.5, 15.5), Vec2(21.5, 15.5)].enumerated().map { i, p in
            DesignShape(name: "Mounting hole \(i + 1)", kind: .circle(radius: 0.125.inch), position: Vec2(p.x.inch, p.y.inch))
        }

        let ops: [CAMOperation] = [
            CAMOperation(name: "V-Carve title", kind: .vcarve(VCarveParams()), shapeIDs: [text.id], tool: vBit),
            CAMOperation(name: "Pocket plaque",
                      kind: .pocket(PocketParams(depth: DepthSettings(cutDepth: 0.25.inch))),
                      shapeIDs: [pocket.id], tool: endMill),
            CAMOperation(name: "Drill mounting holes",
                      kind: .drill(DrillParams(depth: 0.77.inch, peckDepth: 0.25.inch)),
                      shapeIDs: holes.map(\.id), tool: endMill),
            CAMOperation(name: "Cut out sign",
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
        let endMill = lib.tool(number: 1)!
        let ball = lib.tool(number: 7)!
        let stock = Stock(width: 7.inch, height: 5.inch, thickness: 0.75.inch, materialName: "Hard maple")
        let center = Vec2(3.5.inch, 2.5.inch)
        let mesh = MeshModel.reliefMedallion(width: 150, height: 100)
        let spec = ModelSpec(mesh: mesh, upAxis: .z, depth: 0.4.inch)
        let relief = DesignShape(name: "Relief", kind: .model(spec), position: center)
        let outline = DesignShape(name: "Medallion outline", kind: .ellipse(radiusX: 76.5, radiusY: 51.5), position: center)
        let ops: [CAMOperation] = [
            CAMOperation(name: "Rough relief", kind: .rough3D(Rough3DParams(boundary: .vectors)),
                         shapeIDs: [relief.id, outline.id], tool: endMill),
            CAMOperation(name: "Finish relief",
                         kind: .finish3D(Finish3DParams(stepoverFraction: 0.1, rasterAngle: 45, boundary: .vectors)),
                         shapeIDs: [relief.id, outline.id], tool: ball),
            CAMOperation(name: "Cut out medallion",
                         kind: .profile(ProfileParams(side: .outside, depth: DepthSettings(cutDepth: 0.77.inch),
                                                      tabs: TabSettings(enabled: true, count: 4),
                                                      entry: EntrySettings(kind: .ramp, rampLength: 1.inch))),
                         shapeIDs: [outline.id], tool: endMill),
        ]
        return Project(name: "Demo relief", displayUnits: .inch, stock: stock, machine: .avidPRO6060,
                       shapes: [relief, outline], operations: ops)
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
