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

    @Test func newHeightMouseAndEndlessKeysAreActionKeys() {
        #expect(KeyLegend.actionKeys.contains("t"))
        #expect(KeyLegend.actionKeys.contains("v"))
        #expect(KeyLegend.actionKeys.contains("j"))
        #expect(KeyLegend.actionKeys.contains("u"))
        #expect(KeyLegend.actionKeys.contains("i"))
    }

    @Test func newHeightMouseAndEndlessKeysAreNamedInTheLegend() {
        let names = KeyLegend.namedKeys
        #expect(names.contains("t"))
        #expect(names.contains("v"))
        #expect(names.contains("j"))
        #expect(names.contains("u"))
        let flight = KeyLegend.groups.first { $0.title == "FLIGHT" }
        #expect(flight?.entries.contains { $0.key == "T V" && $0.label == "HEIGHT" } == true)
        #expect(flight?.entries.contains { $0.key == "U" && $0.label == "ENDLESS" && !$0.manualOnly } == true)
        #expect(flight?.entries.contains { $0.key == "I" && $0.label == "PICK STREET" && !$0.manualOnly } == true)
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

@Suite("Choose Map")
struct ChooseMapTests {
    @Test func shortcutIsCommandOAndIsListedInTheKeyList() {
        #expect(ChooseMap.shortcutKey == "o")
        #expect(KeyLegend.chooseMapKey == "⌘O")
        let flight = KeyLegend.groups(glider: false).first { $0.title == "FLIGHT" }
        #expect(flight?.entries.contains { $0.key == "⌘O" && $0.label == "CHOOSE MAP" && !$0.manualOnly } == true)
        // It is a menu shortcut, so the flight view's key handler does not answer to it.
        #expect(!KeyLegend.actionKeys.contains("o"))
        #expect(!KeyLegend.heldKeys.contains("o"))
    }

    @Test func keyListHidesTheRowWithOneMap() {
        let one = KeyLegend.groups(glider: false, chooseMap: false).flatMap(\.entries).map(\.key)
        let two = KeyLegend.groups(glider: false, chooseMap: true).flatMap(\.entries).map(\.key)
        #expect(!one.contains("⌘O"))
        #expect(two.contains("⌘O"))
        #expect(two.count == one.count + 1)
    }

    @Test func commandIsEnabledOnlyInFlightWithTwoOrMoreMaps() {
        #expect(ChooseMap.isAvailable(inFlight: true, mapCount: 2))
        #expect(ChooseMap.isAvailable(inFlight: true, mapCount: 4))
        #expect(!ChooseMap.isAvailable(inFlight: true, mapCount: 1))
        #expect(!ChooseMap.isAvailable(inFlight: true, mapCount: 0))
        #expect(!ChooseMap.isAvailable(inFlight: false, mapCount: 4))
    }

    @Test func pickerButtonSaysFlyAndTheIntroSaysDoubleClickWorks() {
        #expect(ChooseMap.pickerButtonTitle == "Fly")
        #expect(ChooseMap.pickerIntro == "Double-click a map, or select it and press Fly.")
        #expect(ChooseMap.menuTitle == "Choose Map…")
    }
}

@Suite("Choose Map availability")
@MainActor
struct ChooseMapAvailabilityTests {
    @Test func followsTheRuleAsTheWindowStateChanges() {
        let state = ChooseMapAvailability()
        #expect(!state.isAvailable)                                  // picker showing at launch
        state.update(inFlight: true, mapCount: 1)
        #expect(!state.isAvailable)                                  // one map in flight: greyed out
        state.update(inFlight: true, mapCount: 4)
        #expect(state.isAvailable)                                   // two or more maps in flight
        state.update(inFlight: false, mapCount: 4)
        #expect(!state.isAvailable)                                  // back at the picker
    }
}

@Suite("Endless flight and the mouse")
struct ModeExclusionTests {
    @Test func turningEndlessOnGivesTheMouseBack() {
        #expect(ModeExclusion.givesBackMouse(endlessTurningOn: true, mouseOn: true))
        #expect(!ModeExclusion.givesBackMouse(endlessTurningOn: true, mouseOn: false))
        #expect(!ModeExclusion.givesBackMouse(endlessTurningOn: false, mouseOn: true))   // U turning endless off leaves the mouse alone
    }

    @Test func takingTheMouseLeavesEndless() {
        #expect(ModeExclusion.leavesEndless(mouseTurningOn: true, endlessOn: true))
        #expect(!ModeExclusion.leavesEndless(mouseTurningOn: true, endlessOn: false))
        #expect(!ModeExclusion.leavesEndless(mouseTurningOn: false, endlessOn: true))
    }
}
