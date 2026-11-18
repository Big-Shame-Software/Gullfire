import Testing
@testable import GullfireKit

@Suite("Mouse flight")
struct MouseFlightTests {
    @Test func movementInsideTheDeadZoneGivesNoInput() {
        var flight = MouseFlight()
        // 16 points is a stick value of 0.04, under the 0.05 dead zone.
        let out = flight.update(deltaX: 16, deltaY: -16, wheel: 0, dt: 0)
        #expect(out.roll == 0)
        #expect(out.pitch == 0)
    }

    @Test func movementOutsideTheDeadZonePassesThrough() {
        var flight = MouseFlight()
        // 24 points is a stick value of 0.06.
        let out = flight.update(deltaX: 24, deltaY: 0, wheel: 0, dt: 0)
        #expect(abs(out.roll - 0.06) < 1e-9)
    }

    @Test func stickClampsAtPlusAndMinusOne() {
        var flight = MouseFlight()
        let right = flight.update(deltaX: 100_000, deltaY: 0, wheel: 0, dt: 0)
        #expect(right.roll == 1)
        flight.reset()
        let left = flight.update(deltaX: -100_000, deltaY: 0, wheel: 0, dt: 0)
        #expect(left.roll == -1)
        flight.reset()
        let forward = flight.update(deltaX: 0, deltaY: -100_000, wheel: 0, dt: 0)
        #expect(forward.pitch == -1)
        flight.reset()
        let back = flight.update(deltaX: 0, deltaY: 100_000, wheel: 0, dt: 0)
        #expect(back.pitch == 1)
    }

    @Test func stickSpringsBackToZeroAfterOneSecondOfNoInput() {
        var flight = MouseFlight()
        _ = flight.update(deltaX: 100_000, deltaY: 100_000, wheel: 0, dt: 0)
        // A full deflection at 2.0 per second reaches zero in half a second, so after one second
        // of zero input the stick is centred.
        var out = flight.update(deltaX: 0, deltaY: 0, wheel: 0, dt: 0)
        for _ in 0..<1200 { out = flight.update(deltaX: 0, deltaY: 0, wheel: 0, dt: 0.01) }
        #expect(out.roll == 0)
        #expect(out.pitch == 0)
    }

    @Test func springStopsAtZeroAndDoesNotPassIt() {
        var flight = MouseFlight()
        _ = flight.update(deltaX: 40, deltaY: 0, wheel: 0, dt: 0)   // stick x = 0.1
        let out = flight.update(deltaX: 0, deltaY: 0, wheel: 0, dt: 1)
        #expect(out.roll == 0)
        // A later small move starts from zero, not from an overshoot on the other side.
        let next = flight.update(deltaX: -24, deltaY: 0, wheel: 0, dt: 0)
        #expect(abs(next.roll + 0.06) < 1e-9)
    }

    @Test func invertPitchFlipsPitchOnly() {
        var normal = MouseFlight()
        var inverted = MouseFlight()
        inverted.invertPitch = true
        let a = normal.update(deltaX: 80, deltaY: -80, wheel: 0, dt: 0)
        let b = inverted.update(deltaX: 80, deltaY: -80, wheel: 0, dt: 0)
        #expect(a.pitch != 0)
        #expect(abs(a.pitch + b.pitch) < 1e-9)
        #expect(a.roll == b.roll)
        #expect(a.throttleDelta == b.throttleDelta)
    }

    @Test func forwardMovementGivesNoseDownMatchingW() {
        // W is pitch -1 in FlightInput.control(dt:), which is nose down.
        let wPitch = -1.0
        var flight = MouseFlight()
        let out = flight.update(deltaX: 0, deltaY: -400, wheel: 0, dt: 0)
        #expect(out.pitch == wPitch)
        #expect(out.pitch < 0)
    }

    @Test func backwardMovementGivesNoseUpMatchingS() {
        var flight = MouseFlight()
        let out = flight.update(deltaX: 0, deltaY: 400, wheel: 0, dt: 0)
        #expect(out.pitch == 1)
    }

    @Test func sensitivityScalesStickTravel() {
        var flight = MouseFlight()
        flight.sensitivity = 2
        // 200 points at sensitivity 2 is a stick value of 1.
        let out = flight.update(deltaX: 200, deltaY: 0, wheel: 0, dt: 0)
        #expect(out.roll == 1)
    }

    @Test func wheelScalesThrottle() {
        var flight = MouseFlight()
        let up = flight.update(deltaX: 0, deltaY: 0, wheel: 5, dt: 0)
        #expect(abs(up.throttleDelta - 0.1) < 1e-9)
        let down = flight.update(deltaX: 0, deltaY: 0, wheel: -2, dt: 0)
        #expect(abs(down.throttleDelta + 0.04) < 1e-9)
    }

    @Test func resetCentresTheStick() {
        var flight = MouseFlight()
        _ = flight.update(deltaX: 100_000, deltaY: -100_000, wheel: 0, dt: 0)
        flight.reset()
        let out = flight.update(deltaX: 0, deltaY: 0, wheel: 0, dt: 0)
        #expect(out.roll == 0)
        #expect(out.pitch == 0)
    }
}

@Suite("Mouse flight: slow input")
struct MouseFlightSlowInputTests {
    @Test func aSlowSteadyTrackpadDragBuildsUpBankAt60Fps() {
        var flight = MouseFlight()
        var out = flight.update(deltaX: 0, deltaY: 0, wheel: 0, dt: 1.0 / 60)
        for _ in 0..<60 { out = flight.update(deltaX: 3, deltaY: 0, wheel: 0, dt: 1.0 / 60) }   // 3 points a frame for 1 s
        #expect(out.roll > 0.3)
    }
}
