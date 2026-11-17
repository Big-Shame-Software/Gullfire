import Foundation

/// A scripted flight for the headless tool and the tests.
public enum FlightScript {
    public struct Result: Sendable {
        public var track: [(east: Double, north: Double)] = []
        public var minClearance = Double.infinity
        public var maxBankDegrees = 0.0
        public var maxTurnRateDegreesPerSecond = 0.0
        public var largestJumpMetres = 0.0
        public var proximitySeconds = 0.0
        public var boundarySeconds = 0.0
        public var nudges = 0
        public var seconds = 0.0
        /// Side view: distance along the flown path, altitude, and the building under the aircraft.
        public var profile: [(distance: Double, altitude: Double, building: Double)] = []

        public var summaryLines: [String] {
            [
                String(format: "fly: %.0f s simulated", seconds),
                String(format: "min clearance above obstacles %.1f m", minClearance),
                String(format: "max bank %.1f deg, max turn rate %.1f deg/s", maxBankDegrees, maxTurnRateDegreesPerSecond),
                String(format: "largest position jump per step %.2f m", largestJumpMetres),
                String(format: "seconds in proximity avoidance %.1f, in boundary return %.1f", proximitySeconds, boundarySeconds),
                "collision nudges \(nudges)",
            ]
        }
    }

    /// Starts 800 m from `tower` at mid-height, heading at it at 85 kt, and flies `seconds` with no pilot input.
    public static func towerApproach(city: CityPackage, tower: Landmark, seconds: Double) throws -> Result {
        let dE = tower.east, dN = tower.north
        let len = (dE * dE + dN * dN).squareRoot()
        let ux = dE / len, uy = dN / len
        let start = FlightState(east: tower.east - 800 * ux, north: tower.north - 800 * uy,
                                altitude: tower.heightM / 2, heading: atan2(ux, uy), speed: 85 * FlightTuning.knotsToMetresPerSecond)
        return fly(start: start, control: ControlInput(throttle: 0.5), city: city, seconds: seconds)
    }

    /// Flies a fixed control from `start` and collects the statistics.
    public static func fly(start: FlightState, control: ControlInput, city: CityPackage, seconds: Double) -> Result {
        let tuning = FlightTuning()
        var sim = Simulation(start: start, tuning: tuning)
        var r = Result()
        let extent = city.manifest.extentM
        let steps = Int(seconds / tuning.fixedStep)
        var lastHeading = start.heading
        r.track.append((start.east, start.north))
        for _ in 0..<steps {
            let before = sim.current
            sim.tick(control: control, obstacles: city, extent: extent)
            let s = sim.current
            r.track.append((s.east, s.north))
            r.minClearance = min(r.minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            r.maxBankDegrees = max(r.maxBankDegrees, abs(s.bank) * 180 / .pi)
            let turn = abs(wrapPi(s.heading - lastHeading)) / tuning.fixedStep
            r.maxTurnRateDegreesPerSecond = max(r.maxTurnRateDegreesPerSecond, turn * 180 / .pi)
            lastHeading = s.heading
            r.largestJumpMetres = max(r.largestJumpMetres, ((s.east - before.east) * (s.east - before.east) + (s.north - before.north) * (s.north - before.north)).squareRoot())
            if sim.proximityWarning { r.proximitySeconds += tuning.fixedStep }
            if sim.boundaryWarning { r.boundarySeconds += tuning.fixedStep }
        }
        r.nudges = sim.nudges
        r.seconds = Double(steps) * tuning.fixedStep
        return r
    }
}

/// The tallest building within 20 m of the aircraft, metres.
func buildingNear(_ s: FlightState, city: CityPackage) -> Double {
    var tallest = 0.0
    for dx in stride(from: -20.0, through: 20.0, by: 5.0) {
        for dy in stride(from: -20.0, through: 20.0, by: 5.0) where dx * dx + dy * dy <= 400 {
            tallest = max(tallest, Double(city.obstacleHeight(east: s.east + dx, north: s.north + dy)))
        }
    }
    return tallest
}

extension FlightScript {
    /// Flies a cruise route on the autopilot for `seconds`, from the route's first sample.
    /// `onStep`, when given, is called after each fixed step with the new state and the simulated time.
    public static func routeFlight(city: CityPackage, route: Route, seconds: Double,
                                   onStep: ((FlightState, Double) -> Void)? = nil) -> Result {
        let tuning = FlightTuning()
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: tuning)
        var hint: Int? = 0
        var r = Result()
        let extent = city.manifest.extentM
        let steps = Int(seconds / tuning.fixedStep)
        var lastHeading = start.heading
        var distance = 0.0
        r.track.append((start.east, start.north))
        for step in 0..<steps {
            let before = sim.current
            sim.advance(by: tuning.fixedStep, obstacles: city, extent: extent) { s, _ in
                let c = Autopilot.control(for: s, route: route, hint: hint, tuning: tuning)
                hint = c.index
                return c.control
            }
            let s = sim.current
            onStep?(s, Double(step + 1) * tuning.fixedStep)
            r.track.append((s.east, s.north))
            distance += ((s.east - before.east) * (s.east - before.east) + (s.north - before.north) * (s.north - before.north)).squareRoot()
            if Int((distance / 10).rounded()) != Int(((distance - 1) / 10).rounded()) {
                r.profile.append((distance, s.altitude, buildingNear(s, city: city)))
            }
            r.minClearance = min(r.minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            r.maxBankDegrees = max(r.maxBankDegrees, abs(s.bank) * 180 / .pi)
            let turn = abs(wrapPi(s.heading - lastHeading)) / tuning.fixedStep
            r.maxTurnRateDegreesPerSecond = max(r.maxTurnRateDegreesPerSecond, turn * 180 / .pi)
            lastHeading = s.heading
            r.largestJumpMetres = max(r.largestJumpMetres, ((s.east - before.east) * (s.east - before.east) + (s.north - before.north) * (s.north - before.north)).squareRoot())
            if sim.proximityWarning { r.proximitySeconds += tuning.fixedStep }
            if sim.boundaryWarning { r.boundarySeconds += tuning.fixedStep }
        }
        r.nudges = sim.nudges
        r.seconds = Double(steps) * tuning.fixedStep
        return r
    }
}
