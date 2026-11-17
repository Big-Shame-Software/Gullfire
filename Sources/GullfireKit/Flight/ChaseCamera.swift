import Foundation

/// The camera that follows the aircraft. It sits behind and above, looks ahead, and
/// rolls about 70 % of the aircraft's bank, low-pass filtered so the horizon is not queasy.
/// With Reduce Motion on, the roll is zero.
public struct ChaseCamera: Sendable {
    /// Seconds for the roll to reach most of its target.
    public var rollTimeConstant = 0.25
    public private(set) var roll = 0.0
    /// Metres behind the aircraft, metres above it, and how far ahead the camera looks. The defaults are the original, distant
    /// view of an aircraft that is not drawn; `close` frames the drawn glider (6.5 m long) like a 3D shooter.
    public var distanceBehind = 150.0
    public var heightAbove = 60.0
    public var lookAhead = 250.0

    public init() {}

    public init(distanceBehind: Double, heightAbove: Double, lookAhead: Double) {
        self.distanceBehind = distanceBehind
        self.heightAbove = heightAbove
        self.lookAhead = lookAhead
    }

    /// Two to three body lengths behind and a little above the glider, looking well ahead of it.
    public static let close = ChaseCamera(distanceBehind: 16, heightAbove: 4.5, lookAhead: 100)

    public mutating func update(_ s: FlightState, dt: Double, reduceMotion: Bool) -> Camera {
        let target = reduceMotion ? 0 : s.bank * 0.7
        roll += (target - roll) * (1 - exp(-dt / rollTimeConstant))
        let fwdE = sin(s.heading), fwdN = cos(s.heading)
        let cp = cos(s.pitch), sp = sin(s.pitch)
        let eye = SIMD3(Float(s.east - fwdE * distanceBehind), Float(s.altitude + heightAbove), Float(-(s.north - fwdN * distanceBehind)))
        let target3 = SIMD3(Float(s.east + fwdE * cp * lookAhead), Float(s.altitude + sp * lookAhead),
                            Float(-(s.north + fwdN * cp * lookAhead)))
        return Camera(eye: eye, target: target3, roll: Float(roll))
    }
}
