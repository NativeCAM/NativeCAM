import Foundation

/// Depths measured from the material's bottom rather than its top, so they follow the material thickness
/// (`DepthSettings.fromBottom`, `DrillParams.fromBottom`; `Project.fitDepthsToMaterial()` keeps them fitted).
public enum MaterialDepth {
    /// How far a through cut goes into the spoilboard unless told otherwise: 0.02 in.
    public static let defaultOvercut = 0.02.inch

    /// The depth below the top of material `thickness` thick that stops `fromBottom` above its bottom (never above
    /// the top).
    public static func depth(fromBottom: Double, thickness: Double) -> Double { max(0, thickness - fromBottom) }
}

extension DepthSettings {
    /// A depth through material `thickness` thick, `overcut` into the spoilboard, that keeps following the thickness.
    public static func through(_ thickness: Double, overcut: Double = MaterialDepth.defaultOvercut) -> DepthSettings {
        DepthSettings(cutDepth: MaterialDepth.depth(fromBottom: -overcut, thickness: thickness), fromBottom: -overcut)
    }

    /// Sets `cutDepth` from `fromBottom` for material `thickness` thick (nothing for a plain depth).
    public mutating func fit(thickness: Double) {
        if let b = fromBottom { cutDepth = MaterialDepth.depth(fromBottom: b, thickness: thickness) }
    }
}

extension DrillParams {
    /// Sets `depth` from `fromBottom` for material `thickness` thick (nothing for a plain depth).
    public mutating func fit(thickness: Double) {
        if let b = fromBottom { depth = MaterialDepth.depth(fromBottom: b, thickness: thickness) }
    }
}
