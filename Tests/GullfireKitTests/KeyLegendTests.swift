import Testing
@testable import GullfireKit

@Suite("Key legend")
struct KeyLegendTests {
    @Test func legendNamesExactlyTheKeysTheHandlerAnswersTo() {
        #expect(KeyLegend.namedKeys.subtracting(KeyLegend.heldKeys) == KeyLegend.actionKeys.union(["shift", "ctrl"]))
    }

    @Test func handFlyingKeysAreMarkedManualOnly() {
        let fly = KeyLegend.groups.first { $0.title == "FLY" }?.entries ?? []
        // J (mouse flight on/off) is in FLY but is a toggle, not a hand-flying control.
        let handControls = fly.filter { $0.key != "J" }
        let mouseToggle = fly.filter { $0.key == "J" }
        let handsMarked = handControls.allSatisfy(\.manualOnly)
        let toggleUnmarked = mouseToggle.allSatisfy { !$0.manualOnly }
        #expect(handsMarked)
        #expect(mouseToggle.count == 1)
        #expect(toggleUnmarked)
        let others = KeyLegend.groups.filter { $0.title != "FLY" }.flatMap(\.entries)
        #expect(others.allSatisfy { !$0.manualOnly })
    }

    @Test func newHeightAndMouseKeysAreActionKeys() {
        #expect(KeyLegend.actionKeys.contains("t"))
        #expect(KeyLegend.actionKeys.contains("v"))
        #expect(KeyLegend.actionKeys.contains("j"))
    }

    @Test func newHeightAndMouseKeysAreNamedInTheLegend() {
        let names = KeyLegend.namedKeys
        #expect(names.contains("t"))
        #expect(names.contains("v"))
        #expect(names.contains("j"))
        let flight = KeyLegend.groups.first { $0.title == "FLIGHT" }
        #expect(flight?.entries.contains { $0.key == "T V" && $0.label == "HEIGHT" } == true)
        let fly = KeyLegend.groups.first { $0.title == "FLY" }
        #expect(fly?.entries.contains { $0.key == "J" && $0.label == "MOUSE" } == true)
    }

    @Test func gliderRowIsHiddenWithoutAModel() {
        let without = KeyLegend.groups(glider: false).flatMap(\.entries).map(\.key)
        let with = KeyLegend.groups(glider: true).flatMap(\.entries).map(\.key)
        #expect(!without.contains("G"))
        #expect(with.contains("G"))
        #expect(with.count == without.count + 1)
    }

    /// The C row says what C does (D1 A): it names the next route, not just the word ROUTE.
    @Test func cRowSaysItGoesToTheNextRoute() {
        let flight = KeyLegend.groups.first { $0.title == "FLIGHT" }
        #expect(flight?.entries.first { $0.key == "C" }?.label == "NEXT ROUTE")
    }

    @Test func noKeyIsBothHeldAndAction() {
        #expect(KeyLegend.heldKeys.isDisjoint(with: KeyLegend.actionKeys))
    }
}
