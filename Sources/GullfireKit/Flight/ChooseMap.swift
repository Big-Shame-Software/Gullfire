import Foundation

/// Getting between the map picker and flight: the words and rules the app and its tests share, so the menu, the key list
/// and the picker cannot drift apart.
public enum ChooseMap {
    /// The menu item, Flight ▸ Choose Map…
    public static let menuTitle = "Choose Map…"
    /// Its shortcut is Command plus this key. It is a menu key equivalent, so it works in full screen (where the menu bar is
    /// hidden) as well as in a window.
    public static let shortcutKey: Character = "o"
    /// The picker's default button (Return presses it).
    public static let pickerButtonTitle = "Fly"
    /// The picker's first line of help.
    public static let pickerIntro = "Double-click a map, or select it and press \(pickerButtonTitle)."

    /// The command does something only in flight, with a second map to choose. With one map installed it does nothing.
    public static func isAvailable(inFlight: Bool, mapCount: Int) -> Bool {
        inFlight && mapCount >= 2
    }
}

/// What the Flight ▸ Choose Map… menu item reads. A menu command that read the app model directly never saw it change, so the
/// window copies the rule's inputs here and the menu observes this object, which does invalidate it.
@MainActor
public final class ChooseMapAvailability: ObservableObject {
    @Published public private(set) var isAvailable = false

    public init() {}

    /// Called whenever the window's state changes.
    public func update(inFlight: Bool, mapCount: Int) {
        let now = ChooseMap.isAvailable(inFlight: inFlight, mapCount: mapCount)
        if now != isAvailable { isAvailable = now }
    }
}
