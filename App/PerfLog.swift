import AppKit
import QuartzCore

/// Timing for the M2 performance brief: start-up milestones, frame intervals, time spent in
/// `draw(in:)` on the main thread, and GPU time from commit feedback. Times are absolute
/// `CACurrentMediaTime()` values, so the renderer's own marks line up with the app's.
@MainActor
final class PerfLog {
    /// Start-up milestones, in the order they happened.
    private(set) var marks: [(name: String, t: Double)] = []
    /// Frame intervals in ms, each with the time of the frame that ended it.
    private(set) var intervals: [(t: Double, ms: Double)] = []
    private(set) var drawMs: [Double] = []
    private(set) var gpuMs: [Double] = []
    /// Set when `NSWindow.didEnterFullScreenNotification` fires.
    var fullScreenAt: Double?
    var drawableSize = "n/a"
    private var lastFrame: Double?
    private let started = CACurrentMediaTime()

    /// Start-up memory marks (M2_MEMORY_BRIEF): `phys_footprint` read in-process after each step.
    private(set) var checkpoints: [(name: String, t: Double, mb: Double)] = []

    /// Records the footprint now, with the time since launch, and prints it.
    func checkpoint(_ name: String) {
        let t = CACurrentMediaTime() - started
        let mb = Footprint.megabytes()
        checkpoints.append((name, t, mb))
        print(String(format: "gullfire-mem: %@ at %.3f s, footprint %.0f MB, drawable %@", name, t, mb, drawableSize))
        fflush(stdout)
    }

    /// Samples footprint every 50 ms for the first 3 s after launch. The peak is taken in-process,
    /// so it does not depend on an external sampler starting late.
    private(set) var startupSamples: [(t: Double, mb: Double)] = []

    func startStartupSampler() {
        Task { @MainActor in
            while CACurrentMediaTime() - started < 3 {
                startupSamples.append((CACurrentMediaTime() - started, Footprint.megabytes()))
                try? await Task.sleep(for: .milliseconds(50))
            }
            let peak = startupSamples.max { $0.mb < $1.mb }
            print(String(format: "gullfire-mem: in-process start-up peak %.0f MB at %.3f s (%d samples in the first 3 s)",
                         peak?.mb ?? 0, peak?.t ?? 0, startupSamples.count))
            fflush(stdout)
        }
    }

    func mark(_ name: String, at time: Double = CACurrentMediaTime()) {
        marks.append((name, time))
        print(String(format: "gullfire-perf: %@ at %.3f s", name, time - started))
        fflush(stdout)
    }

    /// The view stops drawing when hidden (isPaused). A gap while paused is not a slow frame, so the
    /// next frame after a resume sets a new baseline instead of being timed against the last one.
    func viewPausedChanged(paused: Bool) {
        if !paused { lastFrame = nil }
    }

    /// Records a frame at `time`. The first call only sets the baseline.
    func recordFrame(at time: Double) {
        if let last = lastFrame {
            let ms = (time - last) * 1000
            intervals.append((time, ms))
            if ms > 34 { bucketOver34 += 1 }
            if ms > 2000 {
                print(String(format: "gullfire-watch: frame interval %.0f ms ending at %.1f s", ms, time - started))
                fflush(stdout)
            }
        }
        lastFrame = time
        bucketFrames += 1
        let index = Int((time - started) / 15)
        if index != bucketIndex {
            printBucket()
            bucketIndex = index
        }
    }

    // 15-second buckets for the degradation run (brief step 3).
    private var bucketIndex = 0
    private var bucketFrames = 0
    private var bucketOver34 = 0
    private var bucketGPU: [Double] = []
    private(set) var gpuErrorCount = 0
    private(set) var firstGPUErrorAt: Double?

    private var bucketDrawableWait: [Double] = []
    private var bucketInflightWait: [Double] = []
    private var bucketNotKey = 0
    private var bucketOccluded = 0
    private var bucketTilesDrawn: [Double] = []
    private var bucketSegmentsDrawn: [Double] = []
    private var bucketTilesTotal = 0

    /// Per-frame waits and focus state, aggregated per bucket (Part B).
    func recordWaits(drawableMs: Double, inflightMs: Double, focused: Bool, visible: Bool) {
        bucketDrawableWait.append(drawableMs)
        bucketInflightWait.append(inflightMs)
        if !focused { bucketNotKey += 1 }
        if !visible { bucketOccluded += 1 }
    }

    /// Per-frame culling statistics from the renderer, aggregated per bucket (Tiles T3).
    func recordTiles(drawn: Int, total: Int, segments: Int) {
        bucketTilesDrawn.append(Double(drawn))
        bucketSegmentsDrawn.append(Double(segments))
        bucketTilesTotal = total
    }

    /// Prints the bucket that is closing, then starts the next.
    func printBucket() {
        let gpuAvg = bucketGPU.isEmpty ? 0 : bucketGPU.reduce(0, +) / Double(bucketGPU.count)
        let gpuMax = bucketGPU.max() ?? 0
        let drawAvg = bucketDrawableWait.isEmpty ? 0 : bucketDrawableWait.reduce(0, +) / Double(bucketDrawableWait.count)
        let flightAvg = bucketInflightWait.isEmpty ? 0 : bucketInflightWait.reduce(0, +) / Double(bucketInflightWait.count)
        let notKey = bucketFrames > 0 ? Double(bucketNotKey) / Double(bucketFrames) * 100 : 0
        let occluded = bucketFrames > 0 ? Double(bucketOccluded) / Double(bucketFrames) * 100 : 0
        let tilesAvg = bucketTilesDrawn.isEmpty ? 0 : bucketTilesDrawn.reduce(0, +) / Double(bucketTilesDrawn.count)
        let segmentsAvgK = bucketSegmentsDrawn.isEmpty ? 0 : bucketSegmentsDrawn.reduce(0, +) / Double(bucketSegmentsDrawn.count) / 1000
        print(String(format: "gullfire-bucket: %3d-%3d s: fps %.1f, over 34 ms %d, gpu avg %.2f ms max %.2f ms, drawable wait avg %.2f ms, in-flight wait avg %.2f ms, not key %.0f%%, occluded %.0f%%, footprint %.0f MB, GPU errors so far %d, drawable %@, tiles avg %.1f of %d, segments avg %.0f k",
                     bucketIndex * 15, bucketIndex * 15 + 15, Double(bucketFrames) / 15, bucketOver34,
                     gpuAvg, gpuMax, drawAvg, flightAvg, notKey, occluded, Footprint.megabytes(), gpuErrorCount, drawableSize,
                     tilesAvg, bucketTilesTotal, segmentsAvgK))
        fflush(stdout)
        bucketFrames = 0
        bucketOver34 = 0
        bucketGPU = []
        bucketDrawableWait = []
        bucketInflightWait = []
        bucketNotKey = 0
        bucketOccluded = 0
        bucketTilesDrawn = []
        bucketSegmentsDrawn = []
        bucketTilesTotal = 0
    }

    /// A GPU error from a frame. RenderError keeps only the message, so the domain and code are not available here.
    func recordGPUError(_ text: String, at time: Double = CACurrentMediaTime()) {
        gpuErrorCount += 1
        if firstGPUErrorAt == nil { firstGPUErrorAt = time - started }
        print(String(format: "gullfire-gpu-error: #%d at %.3f s: %@", gpuErrorCount, time - started, text))
        fflush(stdout)
    }

    func recordDraw(ms: Double) {
        drawMs.append(ms)
    }

    func recordGPU(ms: Double) {
        guard ms > 0 else { return }
        gpuMs.append(ms)
        bucketGPU.append(ms)
        if ms > 100 {
            print(String(format: "gullfire-gpu-slow: frame GPU time %.1f ms at %.1f s", ms, CACurrentMediaTime() - started))
            fflush(stdout)
        }
    }

    /// Wall-clock time (seconds since 1970) for a media time, so external `footprint` samples
    /// stamped with `date +%s.%N` can be matched to the phases below.
    func wallClock(_ media: Double) -> Double {
        Date().timeIntervalSince1970 - (CACurrentMediaTime() - media)
    }

    /// Phase summary. Steady state runs from 2 s after full screen
    /// to the end of the run; start-up is launch to 2 s after full screen; quit is written before
    /// leaving full screen.
    func phaseSummary(runSeconds: Double?) -> [String] {
        let fs = fullScreenAt ?? (started + 1.5)
        let steadyStart = fs + 2
        let end = runSeconds.map { started + $0 } ?? (intervals.last?.t ?? steadyStart)
        let steady = intervals.filter { $0.t >= steadyStart && $0.t <= end }
        let startup = intervals.filter { $0.t < steadyStart }
        let window = max(0.001, end - steadyStart)
        let fps = Double(steady.count) / window
        let under17 = steady.filter { $0.ms < 17 }.count
        let mid = steady.filter { $0.ms >= 17 && $0.ms <= 34 }.count
        let over34 = steady.filter { $0.ms > 34 }.count
        let worstSteady = steady.max { $0.ms < $1.ms }
        let worstStartup = startup.max { $0.ms < $1.ms }
        let drawSteady = drawMs.isEmpty ? 0 : drawMs.reduce(0, +) / Double(drawMs.count)
        let gpuSorted = gpuMs.sorted()
        let gpuAvg = gpuMs.isEmpty ? 0 : gpuMs.reduce(0, +) / Double(gpuMs.count)
        let gpuP95 = gpuSorted.isEmpty ? 0 : gpuSorted[min(gpuSorted.count - 1, Int((Double(gpuSorted.count) * 0.95).rounded(.up)) - 1)]
        return [
            String(format: "gullfire-perf: steady state [+2 s after full screen to end]: %.1f fps, under 17 ms %d, 17-34 ms %d, over 34 ms %d (of %d)",
                   fps, under17, mid, over34, steady.count),
            String(format: "gullfire-perf: steady worst interval %.1f ms at %.3f s (media)", worstSteady?.ms ?? 0, worstSteady?.t ?? 0),
            String(format: "gullfire-perf: start-up [launch to +2 s after full screen]: worst interval %.1f ms at %.3f s, first 5 ms %@",
                   worstStartup?.ms ?? 0, worstStartup?.t ?? 0, intervals.prefix(5).map { String(format: "%.1f", $0.ms) }.joined(separator: ", ")),
            String(format: "gullfire-perf: draw(in:) steady avg %.2f ms; gpu avg %.2f ms, p95 %.2f ms (drawable %@)", drawSteady, gpuAvg, gpuP95, drawableSize),
            String(format: "gullfire-perf: epochs launch %.3f full-screen %.3f end %.3f", wallClock(started), wallClock(fs), wallClock(end)),
        ]
    }
}
