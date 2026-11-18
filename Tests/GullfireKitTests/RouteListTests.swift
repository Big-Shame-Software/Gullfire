import Testing
@testable import GullfireKit

@Suite("Route list")
struct RouteListTests {
    private func sample(current: Int = 2, inManual: Bool = false) -> RouteList {
        var list = RouteList(items: [
            .init(name: "Scenic", lengthKm: 9.8),
            .init(name: "River", lengthKm: 7.1),
            .init(name: "Street 3", lengthKm: 4.2),
        ], current: current, inManual: inManual)
        list.show(current: current, at: 100, inManual: inManual)
        return list
    }

    @Test func hiddenBeforeAnyCycle() {
        let list = RouteList(items: [.init(name: "Scenic", lengthKm: 9.8)])
        #expect(!list.visible(at: 0))
        #expect(list.opacity(at: 1000) == 0)
    }

    @Test func fullOpacityWhileHeld() {
        let list = sample()
        #expect(list.opacity(at: 100) == 1)
        #expect(list.opacity(at: 100 + RouteList.holdSeconds - 0.01) == 1)
        #expect(list.visible(at: 103.9))
    }

    @Test func fadesOverHalfASecondAfterTheHold() {
        let list = sample()
        let mid = 100 + RouteList.holdSeconds + 0.25
        #expect(abs(list.opacity(at: mid) - 0.5) < 1e-9)
        #expect(list.opacity(at: 100 + RouteList.holdSeconds + RouteList.fadeSeconds) == 0)
        #expect(!list.visible(at: 105))
    }

    @Test func reduceMotionDropsAtOnceWithoutFade() {
        let list = sample()
        #expect(list.opacity(at: 100 + RouteList.holdSeconds - 0.01, reduceMotion: true) == 1)
        #expect(list.opacity(at: 100 + RouteList.holdSeconds + 0.01, reduceMotion: true) == 0)
    }

    @Test func aNewCycleRestartsTheHold() {
        var list = sample(current: 0)
        list.show(current: 1, at: 110, inManual: false)
        #expect(list.opacity(at: 113) == 1)
        #expect(list.current == 1)
    }

    @Test func markerAndNowCarryTheCurrentRouteWithoutColour() {
        let list = sample(current: 2)
        #expect(list.row(at: 2).hasPrefix("▶ STREET 3"))
        #expect(list.row(at: 2).hasSuffix("NOW"))
        #expect(!list.row(at: 0).contains("NOW"))
        #expect(list.row(at: 0).hasPrefix("  SCENIC"))
    }

    @Test func lengthsAreShownInKilometres() {
        let list = sample()
        #expect(list.row(at: 0).hasSuffix("9.8 KM"))
        #expect(list.row(at: 2).contains("4.2 KM"))
    }

    @Test func headerSaysWhatCruiseWillFlyInManual() {
        #expect(sample(inManual: false).header == "ROUTES")
        #expect(sample(inManual: true).header == "ROUTES (CRUISE WILL FLY)")
    }

    @Test func announcesTheCurrentRouteWithItsPosition() {
        #expect(sample(current: 2).announcement == "Route Street 3, 3 of 3")
    }

    @Test func launchHintWaitsForFullScreenWhileWithinTheWindow() {
        // Going full screen, not yet settled, under 3 s: wait.
        #expect(!RouteList.launchHintDue(fullScreenSettled: false, goesFullScreen: true, secondsSinceFirstFrame: 0.5))
        #expect(!RouteList.launchHintDue(fullScreenSettled: false, goesFullScreen: true, secondsSinceFirstFrame: 2.99))
    }

    @Test func launchHintShowsOnceFullScreenHasSettled() {
        #expect(RouteList.launchHintDue(fullScreenSettled: true, goesFullScreen: true, secondsSinceFirstFrame: 0.2))
    }

    @Test func launchHintShowsAtOnceWhenTheWindowStaysWindowed() {
        #expect(RouteList.launchHintDue(fullScreenSettled: false, goesFullScreen: false, secondsSinceFirstFrame: 0))
    }

    @Test func launchHintShowsAfterTheWaitWhenFullScreenNeverSettles() {
        // Refused, failed, or in a Space that is not showing: the hint must still appear.
        #expect(RouteList.launchHintDue(fullScreenSettled: false, goesFullScreen: true, secondsSinceFirstFrame: 3.0))
        #expect(RouteList.launchHintDue(fullScreenSettled: false, goesFullScreen: true, secondsSinceFirstFrame: 12))
    }

    @Test func launchAnnouncementGivesTheRouteThenTheHint() {
        #expect(sample(current: 0).launchAnnouncement == "Route Scenic, 1 of 3. Press C for the next route.")
    }

    @Test func launchAnnouncementIsEmptyWithNoRoutes() {
        let list = RouteList(items: [])
        #expect(list.launchAnnouncement == "")
    }
}
