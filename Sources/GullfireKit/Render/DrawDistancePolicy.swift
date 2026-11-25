import Foundation

/// When the renderer draws only what is within a distance of the eye (a draw distance), and how far.
/// A package gets it when it is large in area or heavy in line segments: a small box with a very dense city (ChicagoWide, 85 km²
/// and 1.7 M segments) costs as much per frame at street level as a big one, and had 30 to 38 ms of GPU time without it.
public enum DrawDistancePolicy {
    /// Area above which the draw distance is on (km²).
    public static let areaKm2 = 200.0
    /// Line segments above which the draw distance is on, whatever the area.
    public static let segments = 1_500_000
    /// The draw distance, in metres.
    public static let metres: Float = 5000

    /// The draw distance for a package, or nil for none. `override` is what GULLFIRE_DRAW_DISTANCE says, in metres: a value
    /// above 0 is used as given, 0 or less turns the draw distance off, nil means "decide from the package".
    public static func distance(areaKm2 area: Double, segments count: Int, override: Float? = nil) -> Float? {
        if let override { return override > 0 ? override : nil }
        return area > areaKm2 || count > segments ? metres : nil
    }

    /// Whether the policy gives this package a draw distance (no override).
    public static func applies(areaKm2 area: Double, segments count: Int) -> Bool {
        distance(areaKm2: area, segments: count) != nil
    }
}
