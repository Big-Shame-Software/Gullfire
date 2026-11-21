import Foundation

/// The source of endless loops for one package. Value type, Sendable.
///
/// Each call to `nextLoop()` walks one loop from the next seed. The seed for loop `k` (counting from 1) is `seed + k - 1`,
/// so the same starting seed always gives the same sequence of loops.
public struct EndlessFlight: Sendable {
    /// Seeds tried in a row before `nextLoop()` gives up.
    static let maxSeedsInARow = 12

    /// The first seed; the flight is repeatable from it.
    public let seed: UInt64
    /// How many loops have been made (0 before the first).
    public private(set) var loopNumber: Int = 0

    private let city: CityPackage
    private let graph: StreetGraph
    private let joinSettings: JoinSettings

    /// nil when the package has no street graph (`StreetGraph.load` returns nil) or when loading it throws.
    public init?(city: CityPackage, seed: UInt64) {
        guard let graph = try? StreetGraph.load(from: city.directory) else { return nil }
        self.seed = seed
        self.city = city
        self.graph = graph
        self.joinSettings = JoinSettings.standard(for: city.manifest)
    }

    /// The next loop, as an ordinary Route plus the plan it came from. Tries seeds seed+loopNumber, seed+loopNumber+1, ...
    /// (skipping seeds the walker cannot make a loop for, at most 12 seeds in a row) and advances loopNumber past the one used.
    /// nil only when 12 seeds in a row fail; loopNumber is then left as it was.
    private var lastStretchIDs: [String] = []

    public mutating func nextLoop() -> (route: Route, plan: RoutePlan)? {
        var offset = loopNumber
        for _ in 0..<Self.maxSeedsInARow {
            let trySeed = seed &+ UInt64(offset)
            if let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: trySeed, joinSettings: joinSettings) {
                // Back-to-back loops must differ: on a small package adjacent seeds can make the same loop.
                let ids = plan.stretches.map { $0.stretch.id }
                if ids == lastStretchIDs { offset += 1; continue }
                lastStretchIDs = ids
                loopNumber = offset + 1
                let file = RouteFile(name: "Endless \(loopNumber)", closed: true, waypoints: plan.assembly.waypoints)
                return (Route(file: file).prepared(obstacles: city), plan)
            }
            offset += 1
        }
        return nil
    }

    /// The next loop, chained from `plan` (the loop being flown): its first stretch is plan's second stretch, in the same
    /// orientation, so the aircraft at `swapIndex(route:plan:)` is already on it when it takes over. Seeds are tried as in
    /// `nextLoop()`, at most 12 in a row; loopNumber advances past the one used. When all 12 fail, nil is returned and
    /// loopNumber advances by 12, so a retry from the same plan tries seeds it has not tried yet.
    public mutating func nextLoop(after plan: RoutePlan) -> (route: Route, plan: RoutePlan)? {
        guard plan.stretches.count >= 2 else { return nil }
        let second = plan.stretches[1]
        let start: (id: String, reversed: Bool) = (second.stretch.id, second.reversed)
        var offset = loopNumber
        for _ in 0..<Self.maxSeedsInARow {
            let trySeed = seed &+ UInt64(offset)
            if let next = RouteWalker.loop(graph: graph, obstacles: city, seed: trySeed, joinSettings: joinSettings,
                                           startingWith: start) {
                let ids = next.stretches.map { $0.stretch.id }
                if ids == lastStretchIDs { offset += 1; continue }
                lastStretchIDs = ids
                loopNumber = offset + 1
                let file = RouteFile(name: "Endless \(loopNumber)", closed: true, waypoints: next.assembly.waypoints)
                return (Route(file: file).prepared(obstacles: city), next)
            }
            offset += 1
        }
        // All 12 seeds failed for this plan. A retry from the same plan would walk the same seeds and fail the same way,
        // so loopNumber advances by 12: the next attempt uses 12 seeds not yet tried.
        loopNumber += Self.maxSeedsInARow
        return nil
    }

    /// The first loop of a pick: a loop whose first stretch is the street `id`, flown in the direction `reversed`. Tries
    /// seeds seed+loopNumber, seed+loopNumber+1, ... (at most 12 in a row) as `nextLoop()` does; loopNumber advances past
    /// the one used. When all 12 fail, nil is returned and loopNumber advances by 12, so a retry tries seeds not yet tried.
    public mutating func firstLoop(startingWith id: String, reversed: Bool) -> (route: Route, plan: RoutePlan)? {
        var offset = loopNumber
        for _ in 0..<Self.maxSeedsInARow {
            let trySeed = seed &+ UInt64(offset)
            if let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: trySeed, joinSettings: joinSettings,
                                           startingWith: (id: id, reversed: reversed)) {
                lastStretchIDs = plan.stretches.map { $0.stretch.id }
                loopNumber = offset + 1
                let file = RouteFile(name: "Endless \(loopNumber)", closed: true, waypoints: plan.assembly.waypoints)
                return (Route(file: file).prepared(obstacles: city), plan)
            }
            offset += 1
        }
        loopNumber += Self.maxSeedsInARow
        return nil
    }

    /// The first loop of a pick from a list of candidate streets, in order (the clicked street first, then the nearest
    /// others). Each is tried as `firstLoop(startingWith:reversed:)` does, so a failed candidate advances loopNumber by 12.
    /// Returns the first loop that is made, with the index in `candidates` of the street it starts with. nil when none is.
    public mutating func firstLoop(trying candidates: [(id: String, reversed: Bool)])
        -> (route: Route, plan: RoutePlan, usedIndex: Int)? {
        for (index, candidate) in candidates.enumerated() {
            if let loop = firstLoop(startingWith: candidate.id, reversed: candidate.reversed) {
                return (loop.route, loop.plan, index)
            }
        }
        return nil
    }

    /// The sample index of `route` (built from `plan`) nearest the start of the plan's second stretch: where a chained
    /// loop built by `nextLoop(after:)` takes over. Whole-route search, no hint.
    public static func swapIndex(route: Route, plan: RoutePlan) -> Int {
        guard plan.stretches.count >= 2 else { return 0 }
        let s = plan.stretches[1].start
        return route.nearestIndex(east: s.x, north: s.y)
    }

    /// The street names or classes along a plan, for the HUD: e.g. "STATE ST / WABASH AVE" (uppercased, up to 3 names from
    /// the plan's first stretch, else its class uppercased).
    public static func label(for plan: RoutePlan) -> String {
        guard let first = plan.stretches.first else { return "ROUTE" }
        let names = first.stretch.names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
        if !names.isEmpty {
            return names.map { $0.uppercased() }.joined(separator: " / ")
        }
        let streetClass = first.stretch.streetClass.trimmingCharacters(in: .whitespaces).uppercased()
        return streetClass.isEmpty ? "ROUTE" : streetClass
    }
}

/// Fires once per loop when the route index reaches `swapIndex`: true on the first update at or past it that follows an
/// update before it. Index jitter around the swap point, a route that starts past it, and the lap wrap do not fire it
/// again; `reset` re-arms it for the next loop. Pure.
public struct SwapTrigger: Sendable {
    public private(set) var swapIndex: Int
    public private(set) var count: Int
    private var seenBelow = false
    private var fired = false

    public init(swapIndex: Int, count: Int) {
        self.swapIndex = swapIndex
        self.count = count
    }

    /// Feeds one route index. Returns true on the one call that fires the trigger.
    public mutating func update(index: Int) -> Bool {
        guard !fired else { return false }
        if index < swapIndex {
            seenBelow = true
            return false
        }
        guard seenBelow else { return false }
        fired = true
        return true
    }

    /// Re-arms the trigger for a new loop.
    public mutating func reset(swapIndex: Int, count: Int) {
        self.swapIndex = swapIndex
        self.count = count
        seenBelow = false
        fired = false
    }
}

/// Counts laps of a closed route from the route-index stream the autopilot reports. A lap is a wrap: the index falls by
/// more than half the route length. Pure.
public struct LapCounter: Sendable {
    public private(set) var laps = 0
    private var last: Int?

    public init() {}

    /// Feeds one index. Returns true on the call that completes a lap.
    public mutating func update(index: Int, count: Int) -> Bool {
        let previous = last
        last = index
        guard let previous, count > 0, previous - index > count / 2 else { return false }
        laps += 1
        return true
    }

    public mutating func reset() {
        laps = 0
        last = nil
    }
}
