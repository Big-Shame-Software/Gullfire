import Testing
@testable import GullfireKit

@Suite("HUD levels")
struct HUDLevelTests {
    @Test func hCyclesOffFlightFullOff() {
        #expect(HUDLevel.off.next == .flight)
        #expect(HUDLevel.flight.next == .full)
        #expect(HUDLevel.full.next == .off)
    }

    @Test func aFullCycleReturnsToOff() {
        var level = HUDLevel.off
        for _ in 0..<3 { level = level.next }
        #expect(level == .off)
    }
}
