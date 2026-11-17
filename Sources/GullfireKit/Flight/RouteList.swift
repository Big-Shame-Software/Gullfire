import Foundation

/// The route list shown when C cycles the route (D1): every route with its loop length, the one that
/// flies marked by `▶`, the word NOW and full opacity. The timing is here so the tests can check it
/// without the app: the list holds for `holdSeconds` after the last cycle, then fades over
/// `fadeSeconds` (at once with Reduce Motion).
public struct RouteList: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let name: String
        public let lengthKm: Double

        public init(name: String, lengthKm: Double) {
            self.name = name
            self.lengthKm = lengthKm
        }
    }

    public static let holdSeconds = 4.0
    public static let fadeSeconds = 0.5

    public let items: [Item]
    /// Index of the route that flies (cruise) or will fly (manual).
    public private(set) var current: Int
    /// Whether the header says the cruise will fly this route (true in manual).
    public var inManual: Bool
    /// The time of the last C press, nil until the first press.
    public private(set) var shownAt: Double?

    public init(items: [Item], current: Int = 0, inManual: Bool = false) {
        self.items = items
        self.current = items.indices.contains(current) ? current : 0
        self.inManual = inManual
    }

    /// Records a route change at `now` (seconds, any monotonic clock).
    public mutating func show(current index: Int, at now: Double, inManual: Bool) {
        if items.indices.contains(index) { current = index }
        self.inManual = inManual
        shownAt = now
    }

    /// Opacity from 0 to 1 at `now`. Full while held, then a linear fade. With `reduceMotion`, 1 until
    /// the hold ends and 0 after, with no fade.
    public func opacity(at now: Double, reduceMotion: Bool = false) -> Double {
        guard let shownAt, !items.isEmpty else { return 0 }
        let elapsed = now - shownAt
        if elapsed < 0 { return 1 }
        if elapsed < Self.holdSeconds { return 1 }
        if reduceMotion { return 0 }
        let fade = (elapsed - Self.holdSeconds) / Self.fadeSeconds
        return max(0, 1 - fade)
    }

    /// Whether the list is on screen at `now` (any opacity above zero).
    public func visible(at now: Double, reduceMotion: Bool = false) -> Bool {
        opacity(at: now, reduceMotion: reduceMotion) > 0
    }

    /// The header line.
    public var header: String {
        inManual ? "ROUTES (CRUISE WILL FLY)" : "ROUTES"
    }

    /// The row text, with the marker and NOW word that carry the current route without colour.
    public func row(at index: Int) -> String {
        let item = items[index]
        let marker = index == current ? "▶" : " "
        let km = String(format: "%.1f KM", item.lengthKm)
        let now = index == current ? "   NOW" : ""
        return "\(marker) \(item.name.uppercased())  \(km)\(now)"
    }

    /// What VoiceOver says for the current route.
    public var announcement: String {
        guard items.indices.contains(current) else { return "" }
        return "Route \(items[current].name), \(current + 1) of \(items.count)"
    }
}
