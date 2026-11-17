import Foundation
import simd

/// A slow automatic orbit around a point on the ground, used until manual flight arrives (M3).
/// It is a pure function of time: the camera position, heading and speed at any instant follow
/// from the centre, radius, altitude and period alone.
public struct AutoOrbit: Sendable, Equatable {
    /// Centre in metres east and north of the package origin.
    public var centre: SIMD2<Double>
    public var radius: Double = 900
    /// Eye height above ground, metres.
    public var eyeAltitude: Double = 200
    /// Seconds per lap.
    public var period: Double = 120
    /// The height the camera looks at, metres.
    public var targetAltitude: Double = 60

    public init(centre: SIMD2<Double>) {
        self.centre = centre
    }

    public struct State: Sendable, Equatable {
        public var camera: Camera
        /// Metres east and north of the package origin.
        public var position: SIMD2<Double>
        public var altitude: Double
        /// Compass heading of travel, degrees in [0, 360).
        public var headingDegrees: Double
        public var speedKnots: Double
    }

    public static let metresPerSecondToKnots = 1.943_844

    /// The lowest eye altitude that clears every obstacle on the orbit circle, plus `margin`.
    /// Samples the circle once per degree, using the obstacle grid.
    public static func safeAltitude(package: CityPackage, centre: SIMD2<Double>, radius: Double,
                                    margin: Double = 50) -> Double {
        var tallest = 0.0
        for degree in 0..<360 {
            let angle = Double(degree) * Double.pi / 180
            let height = Double(package.obstacleHeight(east: centre.x + radius * cos(angle),
                                                       north: centre.y + radius * sin(angle)))
            tallest = max(tallest, height)
        }
        return tallest + margin
    }

    public func state(at time: Double) -> State {
        let omega = 2 * Double.pi / period
        let angle = omega * time
        let east = centre.x + radius * cos(angle)
        let north = centre.y + radius * sin(angle)
        // Velocity is the derivative of position: moving anticlockwise, so heading turns steadily.
        let velocityEast = -radius * omega * sin(angle)
        let velocityNorth = radius * omega * cos(angle)
        var heading = atan2(velocityEast, velocityNorth) * 180 / Double.pi
        if heading < 0 { heading += 360 }
        let speed = (velocityEast * velocityEast + velocityNorth * velocityNorth).squareRoot()
        let camera = Camera(
            eye: SIMD3(Float(east), Float(eyeAltitude), Float(-north)),
            target: SIMD3(Float(centre.x), Float(targetAltitude), Float(-centre.y)))
        return State(camera: camera, position: SIMD2(east, north), altitude: eyeAltitude,
                     headingDegrees: heading, speedKnots: speed * Self.metresPerSecondToKnots)
    }
}
