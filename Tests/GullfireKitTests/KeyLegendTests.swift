import Testing
@testable import GullfireKit

@Suite("Key legend")
struct KeyLegendTests {
    @Test func legendNamesExactlyTheKeysTheHandlerAnswersTo() {
        #expect(KeyLegend.namedKeys.subtracting(KeyLegend.heldKeys) == KeyLegend.actionKeys.union(["shift", "ctrl"]))
    }

    @Test func handFlyingKeysAreMarkedManualOnly() {
        let fly = KeyLegend.groups.first { $0.title == "FLY" }
        #expect(fly?.entries.allSatisfy(\.manualOnly) == true)
        let others = KeyLegend.groups.filter { $0.title != "FLY" }.flatMap(\.entries)
        #expect(others.allSatisfy { !$0.manualOnly })
    }

    @Test func gliderRowIsHiddenWithoutAModel() {
        let without = KeyLegend.groups(glider: false).flatMap(\.entries).map(\.key)
        let with = KeyLegend.groups(glider: true).flatMap(\.entries).map(\.key)
        #expect(!without.contains("G"))
        #expect(with.contains("G"))
        #expect(with.count == without.count + 1)
    }

    @Test func noKeyIsBothHeldAndAction() {
        #expect(KeyLegend.heldKeys.isDisjoint(with: KeyLegend.actionKeys))
    }
}
