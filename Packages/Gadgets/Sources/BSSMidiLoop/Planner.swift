import Foundation

/// SplitMix64: a small seeded generator. The same seed gives the same plan on every machine.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Chooses the order in which segments play. It never touches notes: the event cursor turns its steps into events.
///
/// - `.endless`: play in order; at each segment end, with probability 0.35, jump to one of the two best destinations,
///   weighted by score. A jump is never repeated within the last four jumps. At the end of the piece, jump to the best
///   destination for the last segment after a short breath.
/// - `.loop`: the whole piece in order, then the same end-of-piece jump, and the cycle repeats from there.
/// - `.script`: a fixed list of segments, repeated. For tests and checks.
public struct Planner: Sendable {
    public enum Mode: Sendable, Equatable {
        case endless
        case loop
        case script([Int])
    }

    public struct Step: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The first segment of the performance.
            case start
            /// The segment that follows the last one, in source order: nothing to rebuild.
            case natural
            /// A jump: ring out what sounds, then arrive after the breath.
            case jump(breathSeconds: Double)
        }

        public let segment: Int
        public let kind: Kind
    }

    public static let jumpChance = 0.35
    public static let recentJumps = 4
    public static let endBreathSeconds = 1.5
    /// The smallest weight a jump can have, so a score of zero still counts.
    static let minimumWeight = 0.01

    private let map: LoopMap
    private let mode: Mode
    private let script: [Int]
    private var random: SeededRandom
    private var current: Int? = nil
    private var recent: [JumpPair] = []
    private var scriptPosition = 0

    public init(map: LoopMap, mode: Mode, seed: UInt64) {
        self.map = map
        self.random = SeededRandom(seed: seed)
        let count = map.segments.count
        if case .script(let list) = mode {
            let valid = list.filter { $0 >= 0 && $0 < count }
            self.script = valid
            self.mode = valid.isEmpty ? .loop : mode
        } else {
            self.script = []
            self.mode = mode
        }
    }

    /// The next step of the performance. Never ends: the cursor asks for as many steps as it needs.
    public mutating func next() -> Step {
        guard let here = current else {
            let first = script.first ?? 0
            current = first
            scriptPosition = 1
            return Step(segment: first, kind: .start)
        }
        if case .script = mode {
            return scriptStep(from: here)
        }
        if here >= map.segments.count - 1 {
            return endStep(from: here)
        }
        if mode == .endless, let jump = randomJump(from: here) {
            return jump
        }
        current = here + 1
        return Step(segment: here + 1, kind: .natural)
    }

    private mutating func scriptStep(from here: Int) -> Step {
        let segment = script[scriptPosition % script.count]
        scriptPosition += 1
        current = segment
        let kind: Step.Kind = segment == here + 1 ? .natural : .jump(breathSeconds: 0)
        return Step(segment: segment, kind: kind)
    }

    private mutating func randomJump(from here: Int) -> Step? {
        guard uniform() < Planner.jumpChance else { return nil }
        let options = map.jumps(from: here).filter { option in
            option.to != here + 1 && !recent.contains(JumpPair(from: here, to: option.to))
        }
        guard !options.isEmpty else { return nil }
        let total = options.reduce(0) { $0 + max($1.score, Planner.minimumWeight) }
        var pick = uniform() * total
        var chosen = options[options.count - 1]
        for option in options {
            pick -= max(option.score, Planner.minimumWeight)
            if pick < 0 {
                chosen = option
                break
            }
        }
        remember(JumpPair(from: here, to: chosen.to))
        current = chosen.to
        return Step(segment: chosen.to, kind: .jump(breathSeconds: 0))
    }

    private mutating func endStep(from here: Int) -> Step {
        let options = map.jumps(from: here)
        let fresh = options.first { option in !recent.contains(JumpPair(from: here, to: option.to)) }
        let target = (fresh ?? options.first)?.to ?? 0
        remember(JumpPair(from: here, to: target))
        current = target
        return Step(segment: target, kind: .jump(breathSeconds: Planner.endBreathSeconds))
    }

    private mutating func remember(_ pair: JumpPair) {
        recent.append(pair)
        if recent.count > Planner.recentJumps {
            recent.removeFirst()
        }
    }

    private mutating func uniform() -> Double {
        return Double(random.next() >> 11) / Double(UInt64(1) << 53)
    }
}
