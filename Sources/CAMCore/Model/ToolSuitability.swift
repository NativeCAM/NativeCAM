import Foundation

public extension OperationKind {
    /// Why this kind of toolpath can't cut with `tool`, or nil when it can. Only the tapered ball nose, form and dovetail
    /// shapes are checked here (the older shapes keep their generators' own warnings): form and dovetail bits cut
    /// edges, so only profiles take them (and edge profiles, form bits that only widen going up); a tapered ball nose
    /// carves 3D surfaces, flutes and profiles. An edge profile takes nothing but those form bits.
    func refusal(for tool: Tool) -> String? {
        let shape = tool.shape
        let bit = "'\(tool.name.isEmpty ? "T\(tool.number)" : tool.name)'"
        if case .edgeProfile = self, let why = Self.edgeProfileRefusal(tool, bit: bit) { return why }
        guard shape.requiredFormatVersion > 1 else { return nil }
        if let problem = tool.geometryProblem { return problem + " Fix it in the Tool Library." }
        let a = shape == .taperedBallNose ? "a tapered ball nose" : (shape == .form ? "a form bit" : "a dovetail bit")
        if shape.cutsEdgesOnly {
            switch self {
            case .profile, .edgeProfile: return nil
            default:
                return "\(label) can't use \(bit), \(a): form and dovetail bits only cut edges, with a Profile toolpath at depth "
                    + "(or an Edge Profile, for a form bit)."
            }
        }
        switch self {
        case .profile, .rough3D, .finish3D, .rotaryFinish, .rotaryRough, .fluting, .edgeProfile:
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

    /// Why an edge profile can't cut with `tool`: it takes roundover, cove, ogee and custom form bits whose profile only
    /// widens going up, so each pass can step in from the waste and lift straight out.
    private static func edgeProfileRefusal(_ tool: Tool, bit: String) -> String? {
        switch tool.shape {
        case .form:
            if let problem = tool.geometryProblem { return problem + " Fix it in the Tool Library." }
            if tool.hasUndercut {
                return "Edge Profile can't use \(bit): its profile is wider low down than higher up, so it can't step in from "
                    + "the waste or lift out of the cut without cutting into the edge above. Cut it with a Profile toolpath, "
                    + "which takes it in one pass at full depth."
            }
            return nil
        case .dovetail:
            return "Edge Profile can't use \(bit), a dovetail bit: it's wider at its tip than above it, so it can't step in "
                + "from the waste or lift out of the cut. Cut dovetails with a Profile toolpath, in one pass at full depth."
        case .flatEndMill, .surfacing:
            return "Edge Profile needs a form bit (roundover, cove, ogee or custom): \(bit), an end mill, has no profile to "
                + "cut into the edge. Use a Profile toolpath to cut along it."
        case .vBit, .engraving:
            return "Edge Profile needs a form bit (roundover, cove, ogee or custom), not \(bit), a V-bit. To bevel an edge, use "
                + "a Chamfer toolpath."
        case .ballNose, .bullNose, .taperedBallNose, .drill:
            return "Edge Profile needs a form bit (roundover, cove, ogee or custom), not \(bit), a "
                + "\(tool.shape.label.lowercased())."
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
