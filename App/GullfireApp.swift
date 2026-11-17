import SwiftUI

@main
struct GullfireApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Test hook for the M5 screenshots only: GULLFIRE_APPEARANCE=light|dark forces a colour scheme on
    /// the new windows. Unset, the windows follow the system appearance.
    private var appearance: ColorScheme? {
        switch ProcessInfo.processInfo.environment["GULLFIRE_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup("Gullfire") {
            Group {
                if model.city == nil {
                    EmptyStateView(looked: AppModel.cityDirectory().path)
                } else {
                    FlightView(model: model)
                }
            }
            .frame(minWidth: 640, minHeight: 360)
            .preferredColorScheme(appearance)
            .onAppear {
                // Test hook for the M5 screenshots, Debug builds only: GULLFIRE_SHOW_ABOUT=1 opens the About window at launch.
                // Deferred by a second: opening a window inside the first onAppear stopped the main window appearing.
                #if DEBUG
                SnapshotHook.run(attribution: { model.city?.manifest.attribution }) { NSApp.windows.filter(\.isVisible).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } }
                if ProcessInfo.processInfo.environment["GULLFIRE_SHOW_ABOUT"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openWindow(id: "about") }
                }
                // Test hook for the Settings screenshots, Debug builds only: GULLFIRE_SHOW_SETTINGS=1 opens Settings at launch.
                if ProcessInfo.processInfo.environment["GULLFIRE_SHOW_SETTINGS"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSettings() }
                }
                #endif
            }
        }
        Window("About Gullfire", id: "about") {
            AboutView(attribution: model.city?.manifest.attribution)
                .preferredColorScheme(appearance)
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView(model: model)
                .preferredColorScheme(appearance)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Gullfire") { openWindow(id: "about") }
            }
            // Menu items for every flight key, so the app is usable without the README.
            // They carry no key equivalents: the keys belong to the flight view.
            CommandMenu("Flight") {
                Button("Level Off (R)") { model.flight?.levelOff() }
                Button("Cycle Route (C)") { model.flight?.cycleRoute() }
                Button("Toggle Cruise / Manual (Space)") { model.flight?.toggleCruise() }
            }
            CommandMenu("Music") {
                Button("Next Track (N)") { model.nextTrack() }
                Button("Play or Pause (,)") { model.togglePause() }
                Button("Music On or Off (M)") { model.toggleMusic() }
            }
            CommandMenu("View") {
                Button("Cycle Palette (B)") { model.cyclePalette() }
                Button("Show or Hide Performance (P)") { model.showPerformance.toggle() }
                Button("Cycle HUD (H)") { model.cycleHUD() }
                Button("Show or Hide Key Commands (K)") { model.showKeys.toggle() }
                if model.hasGlider {
                    Button("Show or Hide Glider (G)") { model.flight?.toggleGlider() }
                }
                Button("Toggle Resolution") { model.toggleResolutionFromMenu() }
            }
        }
    }
}
