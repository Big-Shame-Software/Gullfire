import Foundation

/// The settings a route loop is walked with: the length it is walked to, how many assemble-and-check rounds a
/// picked loop gets, and the assembly it is built and checked with (the generator's command-line defaults).
public struct WalkSettings: Sendable {
    /// Kilometres of stretch and join the loop is walked to.
    public var targetKm = 12.0
    /// Assemble-and-check rounds before `RouteWalker.loop` gives up.
    public var tries = 12
    public var assembly = AssemblySettings.standard

    public static let standard = WalkSettings()

    public init() {}
}

/// SplitMix64, a small seeded generator: the same seed gives the same sequence on every run and machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in [0, 1), from the top 53 bits of the next output.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// Port of `pick_route` and `build_route` in Tools/make_street_routes.py: a seeded walk along the street graph that
/// joins stretch to stretch and closes into a loop, then assembles it and checks it.
public enum RouteWalker {
    /// Restarts from a new random first stretch before the walk gives up (the generator's 200).
    static let pickRestarts = 200
    /// Joins tried per step before the step gives up (the generator's 25).
    static let drawsPerStep = 25
    static let minJoin = 150.0
    /// Cell size of the spatial hash over stretch starts: the largest join, so a ring of cells covers every join.
    static let hashCell = 2500.0
    /// Cell size of the map cells the "already used here" rule counts in.
    static let mapCell = 1500.0

    /// A loop walked from `seed`. With `first`, every attempt starts with that stretch in that orientation instead of a
    /// random one (the rest of the walk is unchanged). The first stretch is never banned: if the checker names it as a
    /// failure, that attempt ends and a new walk is tried (still within `tries`); the id unknown or the stretch without a
    /// line gives nil.
    public static func loop(graph: StreetGraph, obstacles: ObstacleSource, seed: UInt64, joinSettings: JoinSettings,
                            settings: WalkSettings = .standard,
                            startingWith first: (id: String, reversed: Bool)? = nil) -> RoutePlan? {
        var rng = SplitMix64(seed: seed)
        let walk = Walk(graph: graph, obstacles: obstacles, joinSettings: joinSettings, settings: settings)
        return walk.build(&rng, starting: first)
    }
}

private struct WalkCell: Hashable {
    var x: Int
    var y: Int
}

private struct WalkJoinKey: Hashable {
    var ax: Int, ay: Int, bx: Int, by: Int, aDeg: Int, bDeg: Int
}

/// One stretch in one orientation, with its ends and headings worked out once.
private struct WalkEnd {
    var stretch: Int
    var id: String
    var planned: PlannedStretch
    var start: SIMD2<Double>
    var end: SIMD2<Double>
    var startDir: SIMD2<Double>
    var endDir: SIMD2<Double>
}

private func cellOf(_ p: SIMD2<Double>, size: Double) -> WalkCell {
    WalkCell(x: Int((p.x / size).rounded(.down)), y: Int((p.y / size).rounded(.down)))
}

/// A position in `weights` drawn with probability proportional to its weight. Falls back to uniform when all are zero.
private func weightedPosition(_ weights: [Double], _ rng: inout SplitMix64) -> Int {
    let total = weights.reduce(0, +)
    guard total > 0 else {
        return min(weights.count - 1, Int(rng.nextUnit() * Double(weights.count)))
    }
    let target = rng.nextUnit() * total
    var acc = 0.0
    var last = 0
    for (i, w) in weights.enumerated() where w > 0 {
        last = i
        acc += w
        if target < acc { return i }
    }
    return last
}

/// Fisher-Yates shuffle driven by the seeded generator.
private func shuffle<T>(_ a: inout [T], _ rng: inout SplitMix64) {
    guard a.count > 1 else { return }
    for i in stride(from: a.count - 1, to: 0, by: -1) {
        let j = min(i, Int(rng.nextUnit() * Double(i + 1)))
        a.swapAt(i, j)
    }
}

private final class Walk {
    private let graph: StreetGraph
    private let obstacles: ObstacleSource
    private let js: JoinSettings
    private let settings: WalkSettings
    /// Two entries per stretch: index 2 * stretch for the stored direction, 2 * stretch + 1 for reversed.
    private let ends: [WalkEnd]
    private let valid: [Bool]
    private let midCell: [WalkCell]
    /// Entries of `ends` by the cell their start lies in.
    private let hash: [WalkCell: [Int]]
    private let ringReach: Int
    private var banned: Set<String> = []
    private var joinCache: [WalkJoinKey: Join?] = [:]

    init(graph: StreetGraph, obstacles: ObstacleSource, joinSettings: JoinSettings, settings: WalkSettings) {
        self.graph = graph
        self.obstacles = obstacles
        self.js = joinSettings
        self.settings = settings
        var ends: [WalkEnd] = []
        var valid: [Bool] = []
        var midCell: [WalkCell] = []
        var hash: [WalkCell: [Int]] = [:]
        ends.reserveCapacity(2 * graph.stretches.count)
        for (i, s) in graph.stretches.enumerated() {
            let line = s.polyline
            let ok = line.count >= 2
            valid.append(ok)
            midCell.append(cellOf(line.isEmpty ? SIMD2(0, 0) : line[line.count / 2], size: RouteWalker.mapCell))
            for reversed in [false, true] {
                let p = PlannedStretch(stretch: s, reversed: reversed)
                let e = WalkEnd(stretch: i, id: s.id, planned: p, start: p.start, end: p.end,
                                startDir: p.startHeading, endDir: p.endHeading)
                if ok {
                    hash[cellOf(e.start, size: RouteWalker.hashCell), default: []].append(ends.count)
                }
                ends.append(e)
            }
        }
        self.ends = ends
        self.valid = valid
        self.midCell = midCell
        self.hash = hash
        self.ringReach = max(1, Int((joinSettings.maxJoin / RouteWalker.hashCell).rounded(.up)))
    }

    /// `build_route`: up to `tries` rounds of pick, assemble and check. A failed round bans the stretches it names.
    func build(_ rng: inout SplitMix64, starting: (id: String, reversed: Bool)?) -> RoutePlan? {
        var fixedEntry: Int? = nil
        if let starting {
            guard let k = graph.stretches.indices.first(where: { graph.stretches[$0].id == starting.id }), valid[k] else {
                return nil
            }
            fixedEntry = 2 * k + (starting.reversed ? 1 : 0)
        }
        for _ in 0..<settings.tries {
            guard let picked = pick(&rng, fixed: fixedEntry) else { return nil }
            let planned = picked.seq.map { ends[$0].planned }
            let asm = RouteAssembler.assemble(planned, joins: picked.joins, settings: settings.assembly)
            let plan = RoutePlan(stretches: planned, joins: picked.joins, assembly: asm)
            let fails = RouteChecker.check(plan, obstacles: obstacles, joinSettings: js, settings: settings.assembly)
            if fails.isEmpty { return plan }
            let n = picked.seq.count
            var namesFixed = false
            for f in fails {
                let named: Int
                switch f.owner {
                case .run(let i):
                    named = picked.seq[i]
                case .join(let i):
                    named = picked.seq[(i + 1) % n]
                }
                // The fixed first stretch is never banned. A failure naming it (its own run, or the closing join into it)
                // ends this attempt; the next attempt walks a new loop with new random choices. Other stretches are banned.
                if let fixedEntry, ends[named].id == ends[fixedEntry].id {
                    namesFixed = true
                    continue
                }
                banned.insert(ends[named].id)
            }
            if namesFixed { continue }
        }
        return nil
    }

    /// `pick_route`: a seeded sequence of entries (into `ends`) and the joins between them, closed into a loop. With
    /// `fixed`, the first entry is that one and no random first draw is made.
    private func pick(_ rng: inout SplitMix64, fixed: Int?) -> (seq: [Int], joins: [Join])? {
        let pool = graph.stretches.indices.filter { valid[$0] && !banned.contains(graph.stretches[$0].id) }
        guard pool.count >= 2 else { return nil }
        let poolWeights = pool.map { graph.stretches[$0].length }
        let target = settings.targetKm * 1000

        for _ in 0..<RouteWalker.pickRestarts {
            let firstEntry: Int
            if let fixed {
                firstEntry = fixed
            } else {
                let drawn = pool[weightedPosition(poolWeights, &rng)]
                let reversed = rng.nextUnit() < 0.5
                firstEntry = 2 * drawn + (reversed ? 1 : 0)
            }
            let firstStretch = ends[firstEntry].stretch
            var seq = [firstEntry]
            var joins: [Join] = []
            var used: Set<String> = [graph.stretches[firstStretch].id]
            var classes: [String: Int] = [graph.stretches[firstStretch].streetClass: 1]
            var cells: [WalkCell: Int] = [midCell[firstStretch]: 1]
            var total = graph.stretches[firstStretch].length

            while total < target {
                let cur = ends[seq[seq.count - 1]]
                var ordered = options(from: cur.end, used: used)
                shuffle(&ordered, &rng)
                let weights: [Double] = ordered.map { k in
                    let e = ends[k]
                    let st = graph.stretches[e.stretch]
                    let dist = hypot(e.start.x - cur.end.x, e.start.y - cur.end.y)
                    var w = st.length / (1.0 + dist / 1000.0)
                    let uses = classes[st.streetClass] ?? 0
                    w *= uses == 0 ? 2.0 : 1.0 / (1.0 + Double(uses))
                    w /= 1.0 + 1.5 * Double(cells[midCell[e.stretch]] ?? 0)
                    return w
                }

                // Weighted draw without replacement: try joins until one is feasible.
                var remaining = Array(ordered.indices)
                var chosen: (entry: Int, join: Join)? = nil
                var draws = 0
                while !remaining.isEmpty && draws < RouteWalker.drawsPerStep && chosen == nil {
                    let pos = weightedPosition(remaining.map { weights[$0] }, &rng)
                    let slot = remaining.remove(at: pos)
                    draws += 1
                    let k = ordered[slot]
                    if let j = join(from: cur.end, cur.endDir, ends[k].start, ends[k].startDir) {
                        chosen = (k, j)
                    }
                }
                guard let step = chosen else { break }
                let st = graph.stretches[ends[step.entry].stretch]
                seq.append(step.entry)
                joins.append(step.join)
                used.insert(st.id)
                classes[st.streetClass, default: 0] += 1
                cells[midCell[ends[step.entry].stretch], default: 0] += 1
                total += st.length + step.join.length
            }

            // Close the loop; drop stretches from the end until the closing join is feasible and the loop is long enough.
            while seq.count >= 2 {
                let last = ends[seq[seq.count - 1]]
                let first = ends[seq[0]]
                if let closing = join(from: last.end, last.endDir, first.start, first.startDir) {
                    let sum = seq.reduce(0.0) { $0 + graph.stretches[ends[$1].stretch].length }
                        + joins.reduce(0.0) { $0 + $1.length }
                    if sum + closing.length >= 0.6 * target {
                        return (seq, joins + [closing])
                    }
                }
                seq.removeLast()
                joins.removeLast()
            }
        }
        return nil
    }

    /// Entries (indices into `ends`) whose start lies 150 m to `maxJoin` from `end`, in a fixed order, skipping used and
    /// banned stretches. Only the spatial-hash cells around `end` are read.
    private func options(from end: SIMD2<Double>, used: Set<String>) -> [Int] {
        let c = cellOf(end, size: RouteWalker.hashCell)
        var out: [Int] = []
        for dx in -ringReach...ringReach {
            for dy in -ringReach...ringReach {
                guard let list = hash[WalkCell(x: c.x + dx, y: c.y + dy)] else { continue }
                for k in list {
                    let e = ends[k]
                    if used.contains(e.id) || banned.contains(e.id) { continue }
                    let d = hypot(e.start.x - end.x, e.start.y - end.y)
                    if d >= RouteWalker.minJoin && d <= js.maxJoin {
                        out.append(k)
                    }
                }
            }
        }
        return out.sorted()
    }

    /// `make_join` with the generator's cache: the same endpoints and headings (rounded as the generator rounds) give the
    /// same answer without a second search.
    private func join(from end: SIMD2<Double>, _ endDir: SIMD2<Double>,
                      _ start: SIMD2<Double>, _ startDir: SIMD2<Double>) -> Join? {
        let deg = 180.0 / Double.pi
        let key = WalkJoinKey(
            ax: Int(end.x.rounded(.toNearestOrEven)), ay: Int(end.y.rounded(.toNearestOrEven)),
            bx: Int(start.x.rounded(.toNearestOrEven)), by: Int(start.y.rounded(.toNearestOrEven)),
            aDeg: Int((atan2(endDir.y, endDir.x) * deg).rounded(.toNearestOrEven)),
            bDeg: Int((atan2(startDir.y, startDir.x) * deg).rounded(.toNearestOrEven)))
        if let hit = joinCache[key] { return hit }
        let result = JoinBuilder.build(from: end, heading: endDir, to: start, heading: startDir,
                                       obstacles: obstacles, settings: js)
        joinCache[key] = result
        return result
    }
}
