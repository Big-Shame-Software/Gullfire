import Foundation
import Testing
import simd
@testable import GullfireKit

@Suite("AutoOrbit")
struct AutoOrbitTests {
    let orbit = AutoOrbit(centre: SIMD2(0, 0))

    @Test func eyeStaysOnTheRadiusAtTheEyeAltitude() {
        for t in stride(from: 0.0, to: 240.0, by: 7.0) {
            let s = orbit.state(at: t)
            #expect(abs(simd_length(s.position) - orbit.radius) < 1e-6)
            #expect(s.altitude == orbit.eyeAltitude)
            #expect(abs(Double(s.camera.eye.y) - orbit.eyeAltitude) < 1e-4)
        }
    }

    @Test func headingIsAlwaysACompassBearing() {
        for t in stride(from: 0.0, to: 240.0, by: 3.0) {
            let h = orbit.state(at: t).headingDegrees
            #expect(h >= 0 && h < 360)
        }
    }

    @Test func speedIsAboutNinetyKnotsWithTheDefaults() {
        // radius 900 m over a 120 s lap: 2 pi 900 / 120 = 47.1 m/s, about 91.6 kt.
        let speed = orbit.state(at: 10).speedKnots
        #expect(abs(speed - 91.6) < 0.2)
    }

    @Test func cameraLooksAtTheCentre() {
        let s = orbit.state(at: 33)
        #expect(abs(s.camera.target.x) < 1e-4)
        #expect(abs(s.camera.target.z) < 1e-4)
        #expect(abs(s.camera.target.y - Float(orbit.targetAltitude)) < 1e-4)
    }
}
