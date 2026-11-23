import Foundation

public extension OperationKind {
    /// Why this kind of toolpath can't cut with `tool`, or nil when it can. Only the tapered ball nose, form and dovetail
    /// shapes are checked here (the older shapes keep their generators' own warnings): form and dovetail bits cut
    /// edges, so only profiles take them; a tapered ball nose carves 3D surfaces, flutes and profiles.
    func refusal(for tool: Tool) -> String? {
        let shape = tool.shape
        guard shape.requiredFormatVersion > 1 else { return nil }
        let bit = "'\(tool.name.isEmpty ? "T\(tool.number)" : tool.name)'"
        if let problem = tool.geometryProblem { return problem + " Fix it in the Tool Library." }
        let a = shape == .taperedBallNose ? "a tapered ball nose" : (shape == .form ? "a form bit" : "a dovetail bit")
        if shape.cutsEdgesOnly {
            if case .profile = self { return nil }
            return "\(label) can't use \(bit), \(a): form and dovetail bits only cut edges, with a Profile toolpath at depth."
        }
        switch self {
        case .profile, .rough3D, .finish3D, .rotaryFinish, .rotaryRough, .fluting:
            return nil
        case .pocket:
            return "Pockets need an end mill: \(bit), \(a), would leave a ridged floor and sloping walls. Use it for 3D carving."
        case .drill:
            return "Drilling needs a drill or end mill, not \(bit), \(a)."
        case .vcarve:
            return "V-carving needs a V-bit or engraving bit: \(bit), \(a), carves the wrong depths with its round tip."
        case .chamfer:
            return "Chamfers need a V-bit or engraving bit, not \(bit), \(a)."
        case .prism:
            return "Prism carving needs a V-bit, not \(bit), \(a)."
        case .rounding:
            return "Rounding needs an end mill, not \(bit), \(a)."
        }
    }
}

public extension CAMOperation {
    /// Why this operation can't cut with its bit or its clearance tool (`OperationKind.refusal(for:)`), or nil.
    var toolRefusal: String? {
        if let why = kind.refusal(for: tool) { return why }
        let clearing: Tool?
        switch kind {
        case let .pocket(p): clearing = p.clearanceTool
        case let .vcarve(p): clearing = (p.carveFlatDepth ?? 0) > 0 ? p.clearanceTool : nil
        default: clearing = nil
        }
        guard let clear = clearing, clear.shape.requiredFormatVersion > 1 else { return nil }
        let name = clear.name.isEmpty ? "T\(clear.number)" : clear.name
        return "The clearance tool '\(name)' is a \(clear.shape.label.lowercased()), which can't clear flat areas. Use an end mill."
    }
}
