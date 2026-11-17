import Foundation
import simd

/// Level of detail for distant tiles. Off unless a renderer sets it.
///
/// Distances are in metres, from the camera eye to the nearest point of a tile's box:
/// - level 1, nearer than `d1`: everything;
/// - level 2, from `d1` to `d2`: the three building groups draw only their `farCount` leading
///   segments (no base edges); water and roads as usual;
/// - level 3, beyond `d2`: as level 2, and the roads and the default-height buildings are skipped.
///
/// Solids are never reduced. They hide the lines behind them.
///
/// With `minScreenFraction` set (brief T4b), level 3 also cuts the building groups by height: a tile
/// at distance d draws only the buildings tall enough to cover at least that fraction of the screen
/// height, using the height cuts in the package's tile index.
public struct LevelOfDetail: Sendable, Equatable {
    public var d1: Float
    public var d2: Float
    /// Smallest on-screen height, as a fraction of the screen height, that a building needs at level 3.
    /// Nil keeps the T4 behaviour exactly.
    public var minScreenFraction: Float?

    public init(d1: Float, d2: Float, minScreenFraction: Float? = nil) {
        self.d1 = d1
        self.d2 = d2
        self.minScreenFraction = minScreenFraction
    }

    /// Height in metres that covers `minScreenFraction` of the screen height at `distance` metres, for a
    /// vertical field of view of `fovDegrees`: `s * d * 2 tan(fov / 2)`. Nil when the fraction is not set.
    public func minHeight(distance: Float, fovDegrees: Float) -> Float? {
        guard let s = minScreenFraction else { return nil }
        return s * distance * 2 * tan(fovDegrees * .pi / 360)
    }

    /// Index into `cuts` (ascending) of the largest cut at or below `height`, or nil when there is none.
    public static func heightCut(atOrBelow height: Float, cuts: [Double]) -> Int? {
        var best: Int? = nil
        for (i, cut) in cuts.enumerated() where Double(height) >= cut { best = i }
        return best
    }

    /// 1 nearer than `d1`, 2 from `d1` to `d2` inclusive, 3 beyond `d2`.
    public func level(distance: Float) -> Int {
        if distance < d1 { return 1 }
        if distance <= d2 { return 2 }
        return 3
    }

    /// Distance from `point` to the nearest point of the box, in the same units. Zero inside the box.
    public static func distance(from point: SIMD3<Float>, toBoxMin lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Float {
        simd_distance(point, simd_clamp(point, lo, hi))
    }
}
