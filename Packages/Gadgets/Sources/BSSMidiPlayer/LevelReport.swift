import Foundation

/// Level measures for a stretch of rendered or tapped audio (mono: the left channel). The tap test and the render command
/// both use it, so a listening check and a file check give the same numbers.
///
/// Windows are 50 ms of RMS. The steady level is the 75th percentile of the window levels from the first sound on.
/// A gap is a window under half the steady level, counted from the point where the level first reaches half the steady
/// level (the fade-in at the start is not a gap). A quiet run is excused only when all three hold:
/// (a) it starts at the end of the piece (within `breathStartTolerance` of an end-of-piece time),
/// (b) it lasts no more than `breathLimit` seconds, and (c) its quietest window stays above `silenceFloor`.
/// Any other quiet run is a gap. The raw count of quiet windows is always reported too.
public struct LevelReport: Sendable {
    /// A span of time, in seconds from the first sound.
    public struct Span: Sendable, Equatable {
        public let start: Double
        public let seconds: Double
    }

    /// A sample step that stands out from the sound around it, for real pieces.
    public struct RelativeClick: Sendable, Equatable {
        public let time: Double
        public let step: Float
        /// The step divided by the median step over the surrounding 10 ms.
        public let ratio: Float
    }

    public static let window = 0.05
    /// The block for the relative click measure: each block's median step is the reference for its steps.
    public static let clickBlock = 0.01
    /// A relative click: a step over this many times the median, and over the silence floor.
    public static let relativeClickRatio: Float = 4
    public static let breathLimit = 1.5
    /// How far before and after an end-of-piece time a breath may begin.
    public static let breathStartTolerance = (before: 0.2, after: 1.0)
    /// The RMS floor. Below it a window is true silence; an excused breath must stay above it.
    public static let silenceFloor: Float = 0.001
    /// A sample step above this is a click.
    public static let clickLimit: Float = 0.03

    /// Seconds from the first sample to the first sound (a sample above the silence floor).
    public private(set) var firstSound = 0.0
    public private(set) var steady: Float = 0
    /// The quietest window in the measured span.
    public private(set) var quietest: Float = 0
    /// Every window under half the steady level in the measured span, excused or not.
    public private(set) var rawQuietWindows = 0
    /// Quiet windows that are not an excused breath.
    public private(set) var gapWindows = 0
    /// Start times (seconds from the first sound) of the gaps that count.
    public private(set) var gapStarts: [Double] = []
    /// Start times of the excused breaths.
    public private(set) var excusedBreaths: [Double] = []
    public private(set) var largestStep: Float = 0
    public private(set) var clicks = 0
    /// The longest run of true silence, in seconds, anywhere from the first sound to the last.
    public private(set) var longestSilence = 0.0
    /// Where the longest run of true silence starts, in seconds from the first sound.
    public private(set) var longestSilenceStart = 0.0
    /// Every run of true silence longer than one second, with where it starts and how long it lasts.
    public private(set) var longSilences: [Span] = []
    /// The excused breaths, with their start and length.
    public private(set) var breaths: [Span] = []
    /// Steps over 4 times the median step of the surrounding 10 ms (and over the silence floor). Count.
    public private(set) var relativeClickCount = 0
    /// The five worst relative clicks, worst first.
    public private(set) var worstRelativeClicks: [RelativeClick] = []
    public private(set) var peak: Float = 0
    public private(set) var durationSeconds = 0.0

    /// - Parameters:
    ///   - samples: mono samples at `rate`.
    ///   - rate: the sample rate.
    ///   - pieceEnds: the end-of-piece times, in seconds from the first sound, where a breath may begin.
    public init(samples: [Float], rate: Double, pieceEnds: [Double]) {
        peak = samples.reduce(0) { max($0, abs($1)) }
        durationSeconds = Double(samples.count) / rate
        guard let first = samples.firstIndex(where: { abs($0) > LevelReport.silenceFloor }),
              let last = samples.lastIndex(where: { abs($0) > LevelReport.silenceFloor }), last > first else { return }
        firstSound = Double(first) / rate
        let w = max(1, Int(LevelReport.window * rate))
        let count = (last - first + 1) / w
        guard count > 0 else { return }

        var levels = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var sum: Float = 0
            let start = first + i * w
            for k in start..<(start + w) { sum += samples[k] * samples[k] }
            levels[i] = (sum / Float(w)).squareRoot()
        }

        steady = levels.sorted()[count * 3 / 4]
        let half = steady / 2
        var silentRun = 0
        var longestRun = 0
        var longestAt = 0
        for (i, level) in levels.enumerated() {
            silentRun = level < LevelReport.silenceFloor ? silentRun + 1 : 0
            if silentRun > longestRun {
                longestRun = silentRun
                longestAt = i - silentRun + 1
            }
            if silentRun == 20 {
                longSilences.append(Span(start: Double(i - 19) * LevelReport.window, seconds: 0))
            }
        }
        // Each long silence: its start (already recorded at its 20th window) and its full length.
        longSilences = longSilences.map { span in
            var end = Int(span.start / LevelReport.window)
            while end < levels.count, levels[end] < LevelReport.silenceFloor { end += 1 }
            return Span(start: span.start, seconds: Double(end - Int(span.start / LevelReport.window)) * LevelReport.window)
        }
        longestSilence = Double(longestRun) * LevelReport.window
        longestSilenceStart = Double(longestAt) * LevelReport.window

        let measuredStart = levels.firstIndex(where: { $0 >= half }) ?? 0
        let measured = levels[measuredStart...]
        quietest = measured.min() ?? 0
        rawQuietWindows = measured.filter { $0 < half }.count

        var index = measuredStart
        while index < count {
            guard levels[index] < half else {
                index += 1
                continue
            }
            var end = index
            var runMinimum = levels[index]
            while end < count, levels[end] < half {
                runMinimum = min(runMinimum, levels[end])
                end += 1
            }
            let start = Double(index) * LevelReport.window
            let length = Double(end - index) * LevelReport.window
            let excused = pieceEnds.contains { time in
                start >= time - LevelReport.breathStartTolerance.before
                    && start <= time + LevelReport.breathStartTolerance.after
            } && length <= LevelReport.breathLimit + LevelReport.window
                && runMinimum >= LevelReport.silenceFloor
            if excused {
                excusedBreaths.append(start)
                breaths.append(Span(start: start, seconds: length))
            } else {
                gapWindows += end - index
                gapStarts.append(start)
            }
            index = end
        }

        for i in (first + 1)...last {
            let step = abs(samples[i] - samples[i - 1])
            largestStep = max(largestStep, step)
            if step > LevelReport.clickLimit { clicks += 1 }
        }
        relativeClicks(samples: samples, first: first, last: last, rate: rate)
    }

    /// Steps over 4 times the median step of their 10 ms block, and over the silence floor. The block is 10 ms
    /// (not a sliding window), so the measure is fast enough for a 10-minute file.
    mutating func relativeClicks(samples: [Float], first: Int, last: Int, rate: Double) {
        let block = max(2, Int(LevelReport.clickBlock * rate))
        var found: [RelativeClick] = []
        var start = first + 1
        while start <= last {
            let end = min(last, start + block - 1)
            var steps: [Float] = []
            steps.reserveCapacity(end - start + 1)
            for i in start...end { steps.append(abs(samples[i] - samples[i - 1])) }
            let median = steps.sorted()[steps.count / 2]
            let reference = max(median, 0.0001)
            for (offset, step) in steps.enumerated() where step > LevelReport.silenceFloor && step > LevelReport.relativeClickRatio * reference {
                relativeClickCount += 1
                found.append(RelativeClick(time: Double(start + offset) / rate - Double(first) / rate, step: step, ratio: step / reference))
            }
            start = end + 1
        }
        worstRelativeClicks = Array(found.sorted { $0.ratio > $1.ratio }.prefix(5))
    }
}
