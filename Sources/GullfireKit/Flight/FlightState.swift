import Foundation

/// The aircraft's state. Metres in the local frame; angles in radians.
/// Heading is 0 for north, clockwise (so east is +pi/2). Bank and pitch are positive
/// for right bank and nose up. The dynamics never know who is flying.
public struct FlightState: Sendable, Equatable {
    public var east: Double
    public var north: Double
    public var altitude: Double
    public var heading: Double
    public var pitch: Double
    public var bank: Double
    /// Metres per second along the flight path.
    public var speed: Double

    public init(east: Double, north: Double, altitude: Double, heading: Double,
                pitch: Double = 0, bank: Double = 0, speed: Double) {
        self.east = east
        self.north = north
        self.altitude = altitude
        self.heading = heading
        self.pitch = pitch
        self.bank = bank
        self.speed = speed
    }
}

/// What a pilot asks for, each axis −1…1 except throttle 0…1. Positive pitch is nose up,
/// positive roll is right, positive yaw is right.
public struct ControlInput: Sendable, Equatable {
    public var pitch: Double
    public var roll: Double
    public var yaw: Double
    public var throttle: Double

    public init(pitch: Double = 0, roll: Double = 0, yaw: Double = 0, throttle: Double = 0.5) {
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw
        self.throttle = throttle
    }
}

/// Starting values. All of them are the owner's to tune at the M3 review.
public struct FlightTuning: Sendable, Equatable {
    public var gravity = 9.80665
    public var rollLimit = 45.0 * Double.pi / 180
    public var bankTimeConstant = 0.6
    public var pitchLimit = 20.0 * Double.pi / 180
    public var pitchTimeConstant = 0.5
    /// Flat rudder turn, radians per second at full yaw.
    public var rudderRate = 8.0 * Double.pi / 180
    public var speedMinKnots = 30.0
    public var speedRangeKnots = 110.0
    /// Maximum change of speed, m/s².
    public var accelLimit = 4.0
    public var floor = 15.0
    public var ceiling = 1500.0
    /// Fixed simulation step: 120 Hz.
    public var fixedStep = 1.0 / 120
    /// Avoidance: clearance below the aircraft that counts as blocked, metres.
    public var clearance = 15.0
    /// Avoidance: how far ahead to look, in seconds, at each sample. The starting look-ahead is 1, 2 and 3 seconds.
    public var avoidLookahead: [Double] = [1, 2, 3]
    /// Avoidance probes: half-angle either side of the heading, and how far ahead they look.
    public var probeAngle = 25.0 * Double.pi / 180
    public var probeDistance = 300.0
    /// Avoidance roll magnitude toward the clear side (0…1).
    public var avoidRoll = 0.8
    /// Avoidance pitch strength at the nearest sample (0…1 of full pitch).
    public var avoidPitch = 0.8
    /// Avoidance wing check: how far either side of the path to look, metres (0 turns it off). Buildings beside the
    /// path, not only on it, steer the aircraft away: needed in a street, where the walls are 9 to 12 m from the line.
    public var wingMargin = 6.0
    /// Avoidance roll for a wing-only block, as a fraction of `avoidRoll`: a nudge away from the wall, not a swerve.
    public var wingRoll = 0.5
    /// Boundary: how close to the package edge the aircraft turns back, metres.
    public var boundaryMargin = 400.0

    public init() {}

    public static let knotsToMetresPerSecond = 0.514_444

    public var speedMin: Double { speedMinKnots * Self.knotsToMetresPerSecond }
    public var speedRange: Double { speedRangeKnots * Self.knotsToMetresPerSecond }
}

@inline(__always)
func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}

/// Wraps an angle to [0, 2π).
public func wrapTau(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * Double.pi)
    if r < 0 { r += 2 * Double.pi }
    return r
}

/// Wraps an angle to (−π, π].
public func wrapPi(_ a: Double) -> Double {
    let r = wrapTau(a)
    return r > Double.pi ? r - 2 * Double.pi : r
}

/// One fixed step of the aircraft. Pure: the same inputs give the same output.
///
/// Bank and pitch ease toward their targets with exponential time constants, so with no input
/// they return to level. Turn rate is g·tan(bank)/speed plus flat rudder turn. Climb rate is
/// speed·sin(pitch). Speed moves toward its target at no more than `accelLimit`. Altitude is
/// held between the floor and the ceiling.
public func step(_ s: FlightState, _ c: ControlInput, dt: Double, tuning t: FlightTuning) -> FlightState {
    var n = s
    let roll = clamp(c.roll, -1, 1)
    let pitchIn = clamp(c.pitch, -1, 1)
    let yaw = clamp(c.yaw, -1, 1)
    let throttle = clamp(c.throttle, 0, 1)

    let kBank = 1 - exp(-dt / t.bankTimeConstant)
    n.bank = s.bank + (roll * t.rollLimit - s.bank) * kBank

    let turnRate = t.gravity * tan(n.bank) / max(s.speed, 1) + yaw * t.rudderRate
    n.heading = wrapTau(s.heading + turnRate * dt)

    let kPitch = 1 - exp(-dt / t.pitchTimeConstant)
    n.pitch = s.pitch + (pitchIn * t.pitchLimit - s.pitch) * kPitch

    let targetSpeed = t.speedMin + throttle * t.speedRange
    let dv = clamp(targetSpeed - s.speed, -t.accelLimit * dt, t.accelLimit * dt)
    n.speed = s.speed + dv

    let horizontal = n.speed * cos(n.pitch)
    n.east = s.east + horizontal * sin(n.heading) * dt
    n.north = s.north + horizontal * cos(n.heading) * dt
    n.altitude = clamp(s.altitude + n.speed * sin(n.pitch) * dt, t.floor, t.ceiling)
    return n
}
