import Foundation

public extension MachineProfile {
    /// What NativeCAM will write for this machine and what the operator does, in plain words: units, tool changes,
    /// spindle, dust collector and where the run-time estimate's numbers came from.
    var summary: [String] {
        guard let d = Dialect.for(self) else {
            return ["NativeCAM can't write G-code for \(controllerLabel) yet. You can set the machine up now; export will "
                + "say so until a post for it is added."]
        }
        let u = customPost?.units ?? outputUnits
        if let pp = customPost {
            var lines = ["G-code written by your Vectric post “\(pp.name)”, in \(u == .inch ? "inches" : "millimetres"), as .\(pp.fileExtension) files."]
            lines.append(pp.changesTools ? "Tool changes use the post's own tool-change block." : "The post has no tool-change block, so a job with several tools is saved as one file per tool.")
            lines.append(pp.writesGCode ? "Every file is read back and checked against the toolpaths before it's saved."
                : "The post doesn't write G-code NativeCAM can read back, so files aren't checked. Air-cut them first.")
            return lines
        }
        var lines = ["\(d.name) G-code in \(u == .inch ? "inches (G20)" : "millimetres (G21)"), saved as .\(d.fileExtension) files. "
            + "The controller won't convert units, so make sure it's set up for \(u == .inch ? "inches" : "millimetres")."]

        let post = PostProcessors.post(for: Project(machine: self))
        if isLegacyAvidMach4 {
            switch toolChange {
            case .manualM6: lines.append("Tool changes call T#M6: Avid's M6 macro stops for the change. Re-zero Z with the touch plate, then press Cycle Start.")
            case .atc: lines.append("Tool changes call T#M6 and G43 H#: the tool changer loads the tool and applies its measured length.")
            case .manualPause: lines.append("Tool changes stop the spindle and pause with M0: change the bit, re-zero Z, then press Cycle Start.")
            }
        } else if let g = post as? GenericGCodePost {
            if g.usesM6 {
                var line = d.m6 == .macro
                    ? "Tool changes call T# M6, which \(d.name) handles itself: it stops for the change."
                    : "Tool changes call T# M6. Make sure \(controller?.sender ?? "the program that sends your files") is set to pause on M6."
                if g.appliesLengthOffset {
                    line += " G43 H# then applies the tool's length from the controller's tool table: measure each tool there, or leave its length at 0 and re-zero Z."
                }
                lines.append(line)
            } else if g.splitsByTool {
                lines.append("\(d.name) can't stop for a tool change, so a job with several tools is saved as one file per tool. "
                    + "Change the bit and re-zero Z before running each.")
            } else {
                lines.append("Tool changes stop the spindle and pause with M0: change the bit, re-zero Z, then resume.")
            }
        }
        lines.append(spindle == .vfdSpindle
            ? "Spindle speed is set by the S word, \(Int(minRPM))–\(Int(maxRPM)) RPM."
            : "The router is switched with M3 and M5; set its speed dial by hand (the file says which speed).")
        lines.append(dustCollection
            ? "Dust collector on with M\(d.dustOn) at the start and after each tool change, off with M9 at the end."
            : "No dust collector output.")

        func accel(_ mm: Double) -> String { u == .inch ? String(format: "%.0f in/s²", mm / LengthUnit.mmPerInch) : String(format: "%.0f mm/s²", mm) }
        let source = self.source(of: .accelerationXY)
        let how: String
        switch source?.kind {
        case .controllerSettings?: how = "from the controller's settings"
        case .measured?: how = "measured"
        case .vendor?: how = "published by the maker"
        case .estimated?: how = "estimated" + (source?.note.map { ": \($0)" } ?? "")
        default: how = accelerationXY == nil ? "NativeCAM's default, a guess" : "entered by hand"
        }
        let own = source?.kind == .controllerSettings || source?.kind == .measured
        lines.append("Run-time estimates use \(accel(axisAcceleration.x)) X/Y acceleration (\(how)) and the controller's "
            + "\(plannerLookahead)-move look-ahead." + (own ? "" : " Import the controller's settings for better numbers."))
        return lines
    }
}
