import Foundation

/// The fixed-step aircraft simulation: steps at 120 Hz on an accumulator, applies
/// avoidance, the boundary and the collision nudge at each step, and interpolates for drawing.
public struct Simulation: Sendable {
    public private(set) var previous: FlightState
    public private(set) var current: FlightState
    public var tuning: FlightTuning
    private var accumulator = 0.0
    /// Set during the last advance: avoidance and boundary are active.
    public private(set) var proximityWarning = false
    public private(set) var boundaryWarning = false
    /// Count of steps where the collision nudge lifted the aircraft clear of a building.
    public private(set) var nudges = 0

    public init(start: FlightState, tuning: FlightTuning = FlightTuning()) {
        previous = start
        current = start
        self.tuning = tuning
    }

    /// Advances by real time `dt`. `control` is constant over the frame.
    public mutating func advance(by dt: Double, control: ControlInput, obstacles: ObstacleSource, extent: Manifest.Extent) {
        accumulator += dt
        while accumulator >= tuning.fixedStep {
            accumulator -= tuning.fixedStep
            tick(control: control, obstacles: obstacles, extent: extent)
        }
    }

    /// Advances like `advance(by:control:...)`, but asks for the control at every fixed step, so the
    /// autopilot and the hand-over see the state they are flying from.
    public mutating func advance(by dt: Double, obstacles: ObstacleSource, extent: Manifest.Extent,
                                 controlAt: (FlightState, Double) -> ControlInput) {
        accumulator += dt
        while accumulator >= tuning.fixedStep {
            accumulator -= tuning.fixedStep
            tick(control: controlAt(current, tuning.fixedStep), obstacles: obstacles, extent: extent)
        }
    }

    /// One fixed step. Public so tests and the headless tool can run the simulation without real time.
    public mutating func tick(control: ControlInput, obstacles: ObstacleSource, extent: Manifest.Extent) {
        let dt = tuning.fixedStep
        let avoid = Avoidance.assess(current, obstacles: obstacles, tuning: tuning)
        let edge = BoundaryGuard.assess(current, extent: extent, tuning: tuning)

        var c = control
        c.pitch = clamp(c.pitch + avoid.pitch, -1, 1)
        if avoid.active { c.roll = avoid.roll }
        if edge.active && !avoid.active { c.roll = edge.roll }

        previous = current
        var next = step(current, c, dt: dt, tuning: tuning)

        // Stay inside the package, whatever the pilot does.
        next.east = clamp(next.east, extent.minEast + 1, extent.maxEast - 1)
        next.north = clamp(next.north, extent.minNorth + 1, extent.maxNorth - 1)

        // Collision nudge: never let the aircraft sit inside a building.
        let ground = Double(obstacles.height(east: next.east, north: next.north))
        if next.altitude < ground + 5 {
            next.altitude = ground + 5
            nudges += 1
        }

        current = next
        proximityWarning = avoid.active
        boundaryWarning = edge.active
    }

    /// Level off (the R key): bank and pitch go to zero at once, so the aircraft holds its heading.
    public mutating func levelOff() {
        current.bank = 0
        current.pitch = 0
        previous.bank = 0
        previous.pitch = 0
    }

    /// The state to draw: linear between the last two steps. `alpha` is the fraction of a step
    /// elapsed since the last tick.
    public func interpolated() -> FlightState {
        let a = accumulator / tuning.fixedStep
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * a }
        var out = current
        out.east = lerp(previous.east, current.east)
        out.north = lerp(previous.north, current.north)
        out.altitude = lerp(previous.altitude, current.altitude)
        out.speed = lerp(previous.speed, current.speed)
        out.pitch = lerp(previous.pitch, current.pitch)
        out.bank = lerp(previous.bank, current.bank)
        out.heading = wrapTau(previous.heading + wrapPi(current.heading - previous.heading) * a)
        return out
    }
}
