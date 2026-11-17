import simd

/// The spike's three still views, re-expressed in the package frame.
///
/// The spike's local frame is anchored at (-87.6295, 41.8855); the package at (-87.635, 41.885).
/// The spike's camera coordinates are therefore shifted by the spike origin's position in the
/// package frame (about +456 m east and +55 m north), computed by `LocalFrame` rather than typed.
public enum StillView: String, CaseIterable, Sendable {
    case skyline, river, above

    /// Spike frame origin.
    public static let spikeOriginLon = -87.6295
    public static let spikeOriginLat = 41.8855

    /// Eye and target in the spike's own render space.
    var spikeEye: SIMD3<Float> {
        switch self {
        case .skyline: SIMD3(1500, 260, 900)
        case .river: SIMD3(650, 70, -330)
        case .above: SIMD3(0, 1400, 500)
        }
    }

    var spikeTarget: SIMD3<Float> {
        switch self {
        case .skyline: SIMD3(-200, 120, -100)
        case .river: SIMD3(-400, 60, -330)
        case .above: SIMD3(0, 0, 0)
        }
    }

    /// The camera in the package frame. Render-space x shifts by east, and z by minus north.
    public func camera(in frame: LocalFrame) -> Camera {
        let shift = frame.metres(lon: Self.spikeOriginLon, lat: Self.spikeOriginLat)
        let offset = SIMD3<Float>(Float(shift.x), 0, -Float(shift.y))
        return Camera(eye: spikeEye + offset, target: spikeTarget + offset)
    }
}

/// The orbit used for the timing test, centred on the package origin.
public enum Orbit {
    public static func camera(frame: Int, of total: Int) -> Camera {
        let a = Float(frame) / Float(total) * 2 * .pi
        return Camera(eye: SIMD3(900 * cos(a), 120 + 80 * sin(3 * a), 900 * sin(a)), target: SIMD3(0, 80, 0))
    }
}
