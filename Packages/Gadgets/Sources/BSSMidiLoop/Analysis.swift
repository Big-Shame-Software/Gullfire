import Foundation

/// Finds the segments of a piece and scores the jumps between them. Pure arithmetic on the notes: no audio.
///
/// Each bar gets a small feature vector (pitch-class content, note density, register). Segment boundaries come from
/// a novelty curve along the self-similarity matrix (a checkerboard kernel), plus every key change, which always wins.
/// A jump from the end of segment A to the start of segment B is scored by comparing the bars that would have followed
/// the cut with the bars that follow B's start, and the bars leading into each (tempo mismatches cost a little).
enum LoopAnalysis {
    /// Bars on each side of a boundary that the novelty kernel compares.
    static let noveltyWindow = 4
    /// Bars compared on each side of a seam.
    static let seamWindow = 4
    static let repeatThreshold = 0.95
    static let compatibleThreshold = 0.6
    /// How many destinations each segment end keeps, besides the natural next segment.
    static let destinationsPerEnd = 2

    static func analyze(_ piece: MIDIPerformance, style: LoopStyle) -> LoopMap {
        let bars = trimmedBars(piece)
        let count = bars.count - 1
        let features = barFeatures(piece, bars: bars)
        let similarity = similarityMatrix(features)
        let novelty = noveltyCurve(similarity, count: count, window: noveltyWindow)
        let boundaries = chooseBoundaries(piece, bars: bars, novelty: novelty, count: count, minimum: style.minimumBars)

        var segments: [LoopSegment] = []
        for k in 0..<(boundaries.count - 1) {
            segments.append(LoopSegment(index: k, startBar: boundaries[k], endBar: boundaries[k + 1],
                                        startTick: bars[boundaries[k]], endTick: bars[boundaries[k + 1]]))
        }

        let bpm = (0..<count).map { piece.beatsPerMinute(atTick: bars[$0]) }
        var transitions: [Transition] = []
        for segment in segments {
            let isLast = segment.index == segments.count - 1
            var options: [Transition] = []
            for other in segments where other.index != segment.index && (isLast || other.index != segment.index + 1) {
                let seam = seamScore(features, count: count, cut: segment.endBar, arrive: other.startBar)
                let cutBar = min(max(0, segment.endBar - 1), count - 1)
                let arriveBar = min(max(0, other.startBar), count - 1)
                let ratio = abs(log2(bpm[cutBar] / bpm[arriveBar]))
                let penalty = min(1, ratio) * 0.2
                let score = max(0, seam.combined - penalty)
                let rounded = (score * 10_000).rounded() / 10_000
                let kind: TransitionKind
                if let next = seam.next, next >= repeatThreshold {
                    kind = .repeated
                } else if rounded >= compatibleThreshold {
                    kind = .compatible
                } else {
                    kind = .bridge
                }
                options.append(Transition(from: segment.index, to: other.index, score: rounded, kind: kind))
            }
            options.sort { $0.score != $1.score ? $0.score > $1.score : $0.to < $1.to }
            transitions.append(contentsOf: options.prefix(destinationsPerEnd))
        }

        return LoopMap(fingerprint: piece.fingerprint, style: style, segments: segments, transitions: transitions)
    }

    /// The bar table, ending at the last bar that has a sounding note or a sustain-pedal change. Empty bars at the end of
    /// the piece are dropped, so the planner does not wait through them. Rests inside the piece are kept.
    static func trimmedBars(_ piece: MIDIPerformance) -> [Int] {
        let all = piece.barTicks
        var last = 0
        for note in piece.notes {
            last = max(last, note.start, note.soundingEnd - 1)
        }
        for controller in piece.controllers where controller.number == 64 {
            last = max(last, controller.tick)
        }
        let lastBar = barIndex(all, tick: last)
        return Array(all.prefix(lastBar + 2))
    }

    /// One vector per bar: the normalised pitch-class content, then density and register, both scaled small.
    static func barFeatures(_ piece: MIDIPerformance, bars: [Int]) -> [[Double]] {
        let count = bars.count - 1
        var chroma = [[Double]](repeating: [Double](repeating: 0, count: 12), count: count)
        var onsets = [Double](repeating: 0, count: count)
        var pitchSums = [Double](repeating: 0, count: count)

        for note in piece.notes {
            let first = barIndex(bars, tick: note.start)
            var k = first
            while k < count && bars[k] < note.soundingEnd {
                let low = max(note.start, bars[k])
                let high = min(note.soundingEnd, bars[k + 1])
                if high > low {
                    chroma[k][Int(note.pitch) % 12] += Double(high - low) * Double(note.velocity) / 127
                }
                k += 1
            }
            onsets[first] += 1
            pitchSums[first] += Double(note.pitch)
        }

        let peak = max(1, onsets.max() ?? 1)
        var features: [[Double]] = []
        features.reserveCapacity(count)
        for k in 0..<count {
            var vector = chroma[k]
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            if norm > 0 {
                vector = vector.map { $0 / norm }
            }
            let density = onsets[k] / peak * 0.3
            let register = onsets[k] > 0 ? min(0.3, max(-0.3, (pitchSums[k] / onsets[k] - 60) / 36 * 0.3)) : 0
            features.append(vector + [density, register])
        }
        return features
    }

    /// The bar that contains a tick, clamped to the piece.
    static func barIndex(_ bars: [Int], tick: Int) -> Int {
        let count = bars.count - 1
        let index = indexOfFirst(in: bars) { $0 > tick } - 1
        return min(max(0, index), count - 1)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / sqrt(normA * normB)
    }

    /// The bar-by-bar similarity matrix, flattened row by row.
    static func similarityMatrix(_ features: [[Double]]) -> [Double] {
        let n = features.count
        var matrix = [Double](repeating: 0, count: n * n)
        for a in 0..<n {
            for b in a..<n {
                let value = cosine(features[a], features[b])
                matrix[a * n + b] = value
                matrix[b * n + a] = value
            }
        }
        return matrix
    }

    /// Foote's checkerboard kernel: how much the bars just before a boundary differ from the bars just after it.
    /// Within-block similarity counts for, cross-block similarity counts against.
    static func noveltyCurve(_ matrix: [Double], count n: Int, window: Int) -> [Double] {
        var curve = [Double](repeating: 0, count: n)
        guard n > 2 else { return curve }
        for i in 1..<n {
            var within = 0.0
            var withinCount = 0.0
            var cross = 0.0
            var crossCount = 0.0
            for p in max(0, i - window)..<min(n, i + window) {
                for q in max(0, i - window)..<min(n, i + window) {
                    let value = matrix[p * n + q]
                    if (p < i) == (q < i) {
                        within += value
                        withinCount += 1
                    } else {
                        cross += value
                        crossCount += 1
                    }
                }
            }
            if withinCount > 0, crossCount > 0 {
                curve[i] = within / withinCount - cross / crossCount
            }
        }
        return curve
    }

    /// Key changes first (always boundaries), then the strongest novelty peaks that keep the minimum length from every other boundary.
    static func chooseBoundaries(_ piece: MIDIPerformance, bars: [Int], novelty: [Double], count n: Int, minimum: Int) -> [Int] {
        var chosen: Set<Int> = [0, n]
        for bar in keyChangeBars(piece, bars: bars, count: n) {
            chosen.insert(bar)
        }

        guard n > 2 else { return chosen.sorted() }
        let values = Array(novelty[1..<n])
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let threshold = mean + 0.5 * sqrt(variance)

        var peaks: [Int] = []
        for i in 1..<(n - 1) where novelty[i] >= novelty[i - 1] && novelty[i] > novelty[i + 1] && novelty[i] > threshold {
            peaks.append(i)
        }
        peaks.sort { novelty[$0] != novelty[$1] ? novelty[$0] > novelty[$1] : $0 < $1 }
        for peak in peaks where chosen.allSatisfy({ abs($0 - peak) >= minimum }) {
            chosen.insert(peak)
        }
        return chosen.sorted()
    }

    /// The bars where the key signature changes, each the bar the new key starts in.
    static func keyChangeBars(_ piece: MIDIPerformance, bars: [Int], count n: Int) -> [Int] {
        var result: [Int] = []
        var previous: MIDIPerformance.KeySignature? = nil
        for key in piece.keys {
            if let before = previous, before.sharps != key.sharps || before.minor != key.minor, key.tick > 0 {
                let bar = barIndex(bars, tick: key.tick)
                if bar > 0 && bar < n {
                    result.append(bar)
                }
            }
            previous = key
        }
        return result
    }

    /// How well the bars after a cut match the bars after the arrival (weighted 0.7), with the bars before each (0.3).
    /// Returns the next-bars score on its own too, when there are bars after the cut to compare.
    static func seamScore(_ features: [[Double]], count n: Int, cut: Int, arrive: Int) -> (combined: Double, next: Double?) {
        var nextSum = 0.0
        var nextCount = 0.0
        for k in 0..<seamWindow {
            let a = cut + k
            let b = arrive + k
            guard a < n, b < n else { break }
            nextSum += cosine(features[a], features[b])
            nextCount += 1
        }
        var leadSum = 0.0
        var leadCount = 0.0
        for k in 1...seamWindow {
            let a = cut - k
            let b = arrive - k
            guard a >= 0, b >= 0 else { break }
            leadSum += cosine(features[a], features[b])
            leadCount += 1
        }
        let next: Double? = nextCount > 0 ? nextSum / nextCount : nil
        let lead: Double? = leadCount > 0 ? leadSum / leadCount : nil
        let combined: Double
        switch (next, lead) {
        case let (nextValue?, leadValue?): combined = 0.7 * nextValue + 0.3 * leadValue
        case let (nextValue?, nil): combined = nextValue
        case let (nil, leadValue?): combined = leadValue
        case (nil, nil): combined = 0
        }
        return (combined, next)
    }
}
