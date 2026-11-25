import Testing
@testable import GullfireKit

@Suite("DrawDistancePolicy")
struct DrawDistancePolicyTests {
    @Test func aBigAreaGetsTheDrawDistance() {
        #expect(DrawDistancePolicy.distance(areaKm2: 1450, segments: 22_000_000) == 5000)
        #expect(DrawDistancePolicy.distance(areaKm2: 200.1, segments: 100_000) == 5000)
    }

    @Test func aDensePackageGetsItWhateverItsArea() {
        #expect(DrawDistancePolicy.distance(areaKm2: 85, segments: 1_685_164) == 5000)   // ChicagoWide
        #expect(DrawDistancePolicy.distance(areaKm2: 10, segments: 1_500_001) == 5000)
    }

    @Test func aSmallLightPackageDoesNot() {
        #expect(DrawDistancePolicy.distance(areaKm2: 48, segments: 563_689) == nil)       // Chicago
        #expect(DrawDistancePolicy.distance(areaKm2: 48, segments: 1_218_922) == nil)     // Vienna
        #expect(DrawDistancePolicy.distance(areaKm2: 200, segments: 1_500_000) == nil)    // both limits are exclusive
    }

    @Test func theOverrideWins() {
        #expect(DrawDistancePolicy.distance(areaKm2: 48, segments: 563_689, override: 3000) == 3000)
        #expect(DrawDistancePolicy.distance(areaKm2: 1450, segments: 22_000_000, override: 0) == nil)
        #expect(DrawDistancePolicy.distance(areaKm2: 1450, segments: 22_000_000, override: -1) == nil)
        #expect(DrawDistancePolicy.distance(areaKm2: 1450, segments: 22_000_000, override: 8000) == 8000)
    }

    @Test func appliesFollowsTheSameRule() {
        #expect(DrawDistancePolicy.applies(areaKm2: 85, segments: 1_685_164))
        #expect(!DrawDistancePolicy.applies(areaKm2: 48, segments: 563_689))
    }
}
