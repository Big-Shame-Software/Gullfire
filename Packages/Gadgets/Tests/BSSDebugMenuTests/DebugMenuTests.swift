#if DEBUG
import Testing
import BSSDebugMenu

@Suite struct DebugMenuTests {
    /// bss-check looks for this exact string in a built Debug app. Changing it means updating bss-check too.
    @Test func markerIsStable() {
        #expect(BSSDebugMenu.marker == "BSS-DEBUG-MENU")
        #expect(BSSDebugMenu.verboseKey == "debugLogging")
    }
}
#endif
