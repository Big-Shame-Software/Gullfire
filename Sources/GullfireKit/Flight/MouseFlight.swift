import Foundation

/// Maps pointer movement and the scroll wheel to flight input.
///
/// The mouse drives a virtual stick. Moving the pointer right rolls right; moving it forward (up the
/// screen, negative `deltaY` in AppKit event terms) pitches the nose down, the same sign as W. The stick
/// eases back to centre slowly when the pointer stops. The spring must stay weaker than slow, steady
/// movement (a trackpad drag is a few points a frame), or gentle input never builds up.
public struct MouseFlight: Sendable {
    /// Stick travel per point of pointer movement is `sensitivity / 400`.
    public var sensitivity: Double = 1.0
    /// Flips the sign of pitch only.
    public var invertPitch: Bool = false

    /// Stick deflection in -1...1. Roll is x (right positive); pitch is y before inversion.
    private var stickX: Double = 0
    private var stickY: Double = 0

    /// Stick speed of the spring back to zero, per second.
    private static let springRate: Double = 0.1
    /// Output magnitudes below this are reported as zero.
    private static let deadZone: Double = 0.05
    /// Throttle change per unit of wheel input.
    private static let throttlePerWheel: Double = 0.02

    public init() {}

    /// Advances the stick by one frame and returns this frame's flight input.
    /// - Parameters:
    ///   - deltaX: pointer movement along x in points (right positive).
    ///   - deltaY: pointer movement along y in points (AppKit event sign: forward is negative).
    ///   - wheel: scroll wheel input (positive raises throttle).
    ///   - dt: seconds since the last update.
    public mutating func update(deltaX: Double, deltaY: Double, wheel: Double, dt: Double)
        -> (roll: Double, pitch: Double, throttleDelta: Double) {
        stickX = min(1, max(-1, stickX + deltaX * sensitivity / 400))
        stickY = min(1, max(-1, stickY + deltaY * sensitivity / 400))

        stickX = spring(stickX, by: Self.springRate * dt)
        stickY = spring(stickY, by: Self.springRate * dt)

        let roll = Self.deadZoned(stickX)
        let pitch = Self.deadZoned(invertPitch ? -stickY : stickY)
        return (roll: roll, pitch: pitch, throttleDelta: wheel * Self.throttlePerWheel)
    }

    /// Centres the stick, for example when the mouse is released or the window loses focus.
    public mutating func reset() {
        stickX = 0
        stickY = 0
    }

    /// Moves `value` toward zero by `step`, stopping at zero.
    private func spring(_ value: Double, by step: Double) -> Double {
        if value > 0 { return max(0, value - step) }
        if value < 0 { return min(0, value + step) }
        return 0
    }

    private static func deadZoned(_ value: Double) -> Double {
        abs(value) < deadZone ? 0 : value
    }
}
