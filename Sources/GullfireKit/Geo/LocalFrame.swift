import Foundation
import simd

/// A local tangent frame about an origin.
///
/// `metres` gives east and north in metres. `render` gives render space, where
/// x is east, y is up and z is minus north. The north-to-z flip happens only here.
public struct LocalFrame: Sendable, Equatable {
    public let lon0: Double
    public let lat0: Double
    private let kx: Double
    private let ky: Double = 110_574

    public init(lon0: Double, lat0: Double) {
        self.lon0 = lon0
        self.lat0 = lat0
        self.kx = cos(lat0 * .pi / 180) * 111_320
    }

    /// East and north in metres from the origin.
    public func metres(lon: Double, lat: Double) -> SIMD2<Double> {
        SIMD2((lon - lon0) * kx, (lat - lat0) * ky)
    }

    /// Longitude and latitude of a point given in metres east and north (the inverse of `metres`).
    public func coordinates(east: Double, north: Double) -> (lon: Double, lat: Double) {
        (lon0 + east / kx, lat0 + north / ky)
    }

    /// Render-space point: x = east, y = up, z = -north.
    public func render(east: Double, north: Double, up: Double) -> SIMD3<Float> {
        SIMD3(Float(east), Float(up), Float(-north))
    }
}
