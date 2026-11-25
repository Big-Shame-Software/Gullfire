import GullfireKit
import SwiftUI

@main
struct GullfireApp: App {
    @State private var model = AppModel()
    @StateObject private var chooseMap = ChooseMapAvailability()
    /// Reads the quit request's sender for the log (`QuitSource`); it never refuses a quit.
    @NSApplicationDelegateAdaptor(QuitSource.self) private var quitSource
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
                if model.city != nil {
                    FlightView(model: model)
                } else if model.catalog.isEmpty {
                    EmptyStateView(looked: AppModel.cityDirectory().path)
                } else {
                    CityPickerView(model: model)
                }
            }
            .frame(minWidth: 640, minHeight: 360)
            // The Flight menu observes `chooseMap`, not the model, so the menu item is enabled exactly when it does something.
            .onChange(of: model.canChooseMap, initial: true) { _, _ in
                chooseMap.update(inFlight: model.city != nil, mapCount: model.catalog.count)
                FlightMenu.refresh()
            }
            .preferredColorScheme(appearance)
            .onAppear {
                // Test hook for the M5 screenshots, Debug builds only: GULLFIRE_SHOW_ABOUT=1 opens the About window at launch.
                // Deferred by a second: opening a window inside the first onAppear stopped the main window appearing.
                #if DEBUG
                SnapshotHook.chooseMapProof(model: model)
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
            // They carry no key equivalents, except Choose Map… (Command-O): the keys belong to the flight view.
            FlightCommands(model: model, availability: chooseMap)
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

/// The Flight menu. It is a `Commands` struct that observes `availability` (an ObservableObject), so Choose Map… is greyed out
/// unless it does something: in flight, with two or more maps. A command that read the `@Observable` model inside the
/// `.commands` closure, or a focused value, stayed disabled for good after the first map was chosen (measured in the app).
/// ⌘O is a key equivalent on the item, so it works in full screen, where the menu bar is hidden; it does nothing while the item is
/// greyed out.
private struct FlightCommands: Commands {
    let model: AppModel
    @ObservedObject var availability: ChooseMapAvailability

    var body: some Commands {
        CommandMenu("Flight") {
            Button("Level Off (R)") { model.flight?.levelOff() }
            Button("Cycle Route (C)") { model.flight?.cycleRoute() }
            Button("Toggle Cruise / Manual (Space)") { model.flight?.toggleCruise() }
            Divider()
            Button(ChooseMap.menuTitle) { model.returnToPicker() }
                .keyboardShortcut(KeyEquivalent(ChooseMap.shortcutKey), modifiers: .command)
                .disabled(!availability.isAvailable)
        }
    }
}

/// SwiftUI copies a command's enabled state into its menu item only when the menu opens, and Command-O never opens the menu (in
/// full screen the menu bar is hidden), so a first Command-O met the state from before. After the state changes this asks the
/// Flight menu to refresh through its own delegate, the call AppKit makes when a menu is about to open.
@MainActor
enum FlightMenu {
    static func refresh() {
        // Next turn of the run loop, after SwiftUI has rebuilt the commands from the new state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "Flight" }) else { return }
            menu.delegate?.menuNeedsUpdate?(menu)
        }
    }
}
