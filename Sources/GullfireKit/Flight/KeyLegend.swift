import Foundation

/// The keys the flight view answers to, grouped for the on-screen legend. One list, so the legend
/// and the key handler cannot drift apart (the tests check it).
public enum KeyLegend {
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let label: String
        /// True for keys that fly the aircraft by hand; the legend marks them while the autopilot flies.
        public let manualOnly: Bool
    }

    public struct Group: Equatable, Sendable {
        public let title: String
        public let entries: [Entry]
    }

    /// Keys held down to fly (W A S D Q E). The key handler treats exactly these as held controls.
    public static let heldKeys: Set<String> = ["w", "a", "s", "d", "q", "e"]

    /// Keys that act once on a press. Space is spelled "space".
    public static let actionKeys: Set<String> = ["b", "p", "h", "k", "g", "f", "r", "c", "t", "v", "j", "u", "i", "space", "n", "m", ","]

    public static let groups: [Group] = [
        Group(title: "FLY", entries: [
            Entry(key: "W S", label: "PITCH", manualOnly: true),
            Entry(key: "A D", label: "ROLL", manualOnly: true),
            Entry(key: "Q E", label: "YAW", manualOnly: true),
            Entry(key: "SHIFT CTRL", label: "THROTTLE", manualOnly: true),
            Entry(key: "J", label: "MOUSE", manualOnly: false),
        ]),
        Group(title: "FLIGHT", entries: [
            Entry(key: "SPACE", label: "CRUISE / MANUAL", manualOnly: false),
            Entry(key: "R", label: "LEVEL OFF", manualOnly: false),
            Entry(key: "C", label: "NEXT ROUTE", manualOnly: false),
            Entry(key: "T V", label: "HEIGHT", manualOnly: false),
            Entry(key: "U", label: "ENDLESS", manualOnly: false),
            Entry(key: "I", label: "PICK STREET", manualOnly: false),
        ]),
        Group(title: "VIEW", entries: [
            Entry(key: "B", label: "PALETTE", manualOnly: false),
            Entry(key: "P", label: "PERFORMANCE", manualOnly: false),
            Entry(key: "H", label: "HUD", manualOnly: false),
            Entry(key: "F", label: "FULL SCREEN", manualOnly: false),
            Entry(key: "K", label: "KEYS", manualOnly: false),
            Entry(key: "G", label: "GLIDER", manualOnly: false),
        ]),
        Group(title: "MUSIC", entries: [
            Entry(key: "N", label: "NEXT", manualOnly: false),
            Entry(key: "M", label: "ON / OFF", manualOnly: false),
            Entry(key: ",", label: "PLAY / PAUSE", manualOnly: false),
        ]),
    ]

    /// The legend's groups, without the G row when there is no glider model (D1): G does nothing without one.
    public static func groups(glider: Bool) -> [Group] {
        groups.map { group in
            Group(title: group.title, entries: group.entries.filter { glider || $0.key != "G" })
        }
    }

    /// Every single-letter key the legend names, lowercased, so a test can compare it with the handler.
    public static var namedKeys: Set<String> {
        var keys = Set<String>()
        for entry in groups.flatMap(\.entries) {
            for part in entry.key.split(separator: " ") {
                keys.insert(part == "SPACE" ? "space" : part.lowercased())
            }
        }
        return keys
    }
}
