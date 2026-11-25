import Foundation

/// Endless flight (U) and mouse flight (J) are two ways of choosing who flies, and never run together: turning one on turns
/// the other off. The rules are here so the app and its tests share them.
public enum ModeExclusion {
    /// U turning endless flight on while the mouse is taken: the mouse is given back first.
    public static func givesBackMouse(endlessTurningOn: Bool, mouseOn: Bool) -> Bool {
        endlessTurningOn && mouseOn
    }

    /// J taking the mouse while endless flight is on: endless flight is left first (the aircraft returns to the routes).
    public static func leavesEndless(mouseTurningOn: Bool, endlessOn: Bool) -> Bool {
        mouseTurningOn && endlessOn
    }
}
