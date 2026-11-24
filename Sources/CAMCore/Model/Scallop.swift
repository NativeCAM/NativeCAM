import Foundation

/// The scallop (cusp) a bit leaves between neighbouring passes on a flat surface, from the rounded part of its tip: a
/// ball nose's ball, a tapered ball nose's tip ball, a bull nose's corner radius beside its flat. Passes closer than a
/// bull nose's flat leave none. A flat end mill (or any other bit) has no rounded tip, so it has no scallop to hold.
public extension Tool {
    /// The radius of the rounded tip that leaves the scallop, mm; nil when the bit has none.
    var scallopRadius: Double? {
        switch shape {
        case .ballNose: radius > 1e-9 ? radius : nil
        case .taperedBallNose: tipDiameter > 1e-6 ? min(tipDiameter, diameter) / 2 : (radius > 1e-9 ? radius : nil)
        case .bullNose: cornerRadius > 1e-6 ? min(cornerRadius, radius) : nil
        default: nil
        }
    }

    /// The flat across the bottom of the bit between its rounded corners, mm (a bull nose's; 0 for the others).
    private var scallopFlat: Double {
        guard shape == .bullNose, let r = scallopRadius else { return 0 }
        return max(0, diameter - 2 * r)
    }

    /// Scallop height left between passes `stepover` apart on a flat surface, mm; 0 when the bit has no rounded tip or
    /// the passes are closer than its flat.
    func scallopHeight(stepover s: Double) -> Double {
        guard let r = scallopRadius else { return 0 }
        let half = (s - scallopFlat) / 2
        guard half > 0 else { return 0 }
        guard half < r else { return r }
        return r - (r * r - half * half).squareRoot()
    }

    /// The stepover that leaves a scallop of `height` between passes on a flat surface, mm; nil when the bit has no
    /// rounded tip to hold one with. A height as tall as the tip's radius or more gives the passes the rounded tip's
    /// whole width apart.
    func stepover(forScallop height: Double) -> Double? {
        guard let r = scallopRadius, height > 0 else { return nil }
        let h = min(height, r)
        return scallopFlat + 2 * (max(0, 2 * r * h - h * h)).squareRoot()
    }
}
