import AVFoundation
import Foundation
import Observation

/// Plays a list of files one after another, blending the end of each into the start of the next.
///
/// Each player feeds its own gain mixer, and both feed one music bus; all are connected once, in one
/// format, and the engine converts each file's sample rate and channel count. Files are streamed from
/// disk by `scheduleFile`, never decoded whole. Timing comes from the audio clock, not from timer ticks:
/// shortly before a fade is due (`lookahead`) the next file is started on the idle player, silent, with
/// its data placed at the exact sample where the fade begins, so the blend starts on time even if the main
/// thread stalls. The 20 Hz timer only ramps the two gain mixers (equal power, `CrossfadePlan`) from the
/// incoming player's own position. Everything runs on the main actor.
@MainActor
@Observable
public final class CrossfadePlayer {
    /// The title of the track now playing (file name without extension), empty when off.
    public private(set) var currentTitle = ""
    /// True from `start` until `stop`.
    public private(set) var isOn = false
    /// True while sound is meant to be coming out (on and not paused).
    public private(set) var isPlaying = false
    /// The requested crossfade, in seconds. A short track gets less (see `CrossfadePlan.effectiveFade`).
    public var fadeSeconds = 5.0
    /// Seconds before a fade is due at which the next track is scheduled on the audio clock.
    public var lookahead = 2.0
    /// Called with a line for anything worth logging (skipped files, engine trouble).
    @ObservationIgnored public var log: (String) -> Void = { print("gullfire-music: \($0)") }

    private static let silent: Float = 0.0001

    private struct Incoming {
        var node: Int
        var index: Int
        var title: String
        var duration: Double
        var fade: Double
        var announced = false
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    /// Both player nodes connect here, so a tap or a level meter sees the music before the output.
    @ObservationIgnored private let bus = AVAudioMixerNode()
    @ObservationIgnored private let nodes = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    /// One mixer after each player, whose output level is the fade. A player node's own `volume` was
    /// found to jump back to full when a scheduled start begins, which clicked; a mixer's level holds.
    @ObservationIgnored private let gains = [AVAudioMixerNode(), AVAudioMixerNode()]
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var activeDuration = 0.0
    @ObservationIgnored private var incoming: Incoming?
    /// Audio-clock sample at which the track on each node starts (or started).
    @ObservationIgnored private var startSample: [AVAudioFramePosition?] = [nil, nil]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {
        engine.attach(bus)
        for node in nodes { engine.attach(node) }
        for gain in gains { engine.attach(gain) }
        connectNodes()          // a tap can then be installed before the first track starts
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    /// The engine and the music bus, so another music source (the MIDI piece) plays through the same engine,
    /// bus, volume and pause. Only one source plays at a time.
    public var sharedEngine: AVAudioEngine { engine }
    public var musicBus: AVAudioNode { bus }

    /// Overall output level, 0 to 1. Tests set 0 so the engine runs without making sound.
    public var outputVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Test and metering hook: `block` gets a copy of the music as mixed, before the output level, on an
    /// audio thread. (`installAudioTap` is the macOS 27 form; its provider is `@Sendable`, so it is not
    /// bound to the main actor.)
    public func installTap(bufferSize: AVAudioFrameCount = 4096, _ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        do {
            try bus.installAudioTap(onBus: 0, bufferSize: bufferSize, format: nil) { readOnly, _ in
                block(AVAudioPCMBuffer(copying: readOnly))
            }
        } catch { log("could not install the tap: \(error)") }
    }

    public func removeTap() { bus.removeTap(onBus: 0) }

    /// The audio clock: the sample time of the active player's last render, and its rate. A scheduled
    /// start must be given in the players' own timeline, which is not the music bus's (starts scheduled
    /// from the bus clock came out late), so the active player is the reference. Nil when it is not
    /// rendering. (`playerTime(forNodeTime:)` raises an exception in some states, so positions are
    /// worked out from this clock and each track's recorded start instead.)
    private func clock() -> (sample: AVAudioFramePosition, rate: Double)? {
        guard engine.isRunning, nodes[active].isPlaying, let time = nodes[active].lastRenderTime,
              time.isSampleTimeValid, time.sampleRate > 0 else { return nil }
        return (time.sampleTime, time.sampleRate)
    }

    /// Seconds the track on node `i` has played, from the audio clock. Negative before its scheduled start,
    /// nil if its start is not known yet.
    private func position(ofNode i: Int) -> Double? {
        guard let c = clock(), let start = startSample[i] else { return nil }
        return Double(c.sample - start) / c.rate
    }

    // MARK: Control

    /// Starts playing `tracks` in the given order, looping when it reaches the end.
    public func start(tracks: [URL]) {
        stop()
        queue = tracks
        guard !tracks.isEmpty else { return }
        do { try engine.start() } catch { log("engine would not start: \(error)"); return }
        guard let first = openPlayable(from: 0) else { engine.stop(); return }
        active = 0
        index = first.index
        activeDuration = first.duration
        gains[0].outputVolume = 1
        nodes[0].scheduleFile(first.file, at: nil, completionHandler: nil)
        startSample = [nil, nil]
        startNode(nodes[0], at: nil)          // its start sample is taken from the clock at the first tick
        currentTitle = first.title
        log("playing \(first.title), \(Int(first.duration)) s")
        isOn = true
        isPlaying = true
        startTimer()
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        for node in nodes { node.stop() }
        if engine.isRunning { engine.stop() }
        incoming = nil
        isOn = false
        isPlaying = false
        currentTitle = ""
    }

    public func togglePlayPause() {
        guard isOn else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            do { try engine.start(); isPlaying = true } catch { log("could not resume: \(error)") }
        }
    }

    /// Blends into the next track now. Ignored while a fade is already running.
    public func next() {
        guard isOn, isPlaying else { return }
        if let inc = incoming {
            // Scheduled but not yet audible: replace it with an immediate one. A fade under way is left alone.
            guard (position(ofNode: inc.node) ?? 0) <= 0 else { return }
            nodes[inc.node].stop()
            incoming = nil
        }
        scheduleNext(immediate: true)
    }

    // MARK: Timer

    private func startTimer() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isOn, isPlaying else { return }
        if startSample[active] == nil, let c = clock() { startSample[active] = c.sample }
        if var inc = incoming {
            guard let played = position(ofNode: inc.node), played > 0 else {
                return
            }
            if !inc.announced {
                inc.announced = true
                currentTitle = inc.title
                incoming = inc
            }
            let level = CrossfadePlan.gains(progress: inc.fade > 0 ? played / inc.fade : 1)
            self.gains[active].outputVolume = level.outgoing
            self.gains[inc.node].outputVolume = level.incoming
            if played >= inc.fade {
                nodes[active].stop()
                startSample[1 - inc.node] = nil
                active = inc.node
                activeDuration = inc.duration
                index = inc.index
                self.gains[active].outputVolume = 1
                incoming = nil
            }
        } else if let played = position(ofNode: active) {
            let due = CrossfadePlan.fadeStart(duration: activeDuration, fade: fadeSeconds)
            if played >= due - lookahead { scheduleNext(immediate: false) }
        }
    }

    // MARK: Tracks

    private struct Opened {
        var file: AVAudioFile
        var index: Int
        var title: String
        var duration: Double
    }

    /// The first file at or after `position` in the queue that opens, skipping (and logging) the rest.
    private func openPlayable(from position: Int) -> Opened? {
        var i = position % max(queue.count, 1)
        for _ in 0..<queue.count {
            let url = queue[i]
            if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                return Opened(file: file, index: i, title: url.deletingPathExtension().lastPathComponent,
                              duration: Double(file.length) / file.processingFormat.sampleRate)
            }
            log("skipped \(url.lastPathComponent): will not open")
            i = (i + 1) % queue.count
        }
        return nil
    }

    /// Schedules the next track on the idle node to start on the audio clock when the fade is due,
    /// or at once (`immediate`).
    private func scheduleNext(immediate: Bool) {
        guard let c = clock(), let opened = openPlayable(from: index + 1) else { return }
        if startSample[active] == nil { startSample[active] = c.sample }     // pressed before the first tick
        guard let played = position(ofNode: active) else { return }
        let remaining = max(0, activeDuration - played)
        let fade = CrossfadePlan.effectiveFade(requested: fadeSeconds, outgoing: activeDuration, incoming: opened.duration)
        let usedFade = immediate ? min(fade, max(remaining, 0.05)) : fade
        let wait = immediate ? 0.05 : max(0.05, activeDuration - usedFade - played)
        let startAt = c.sample + AVAudioFramePosition(wait * c.rate)
        let other = 1 - active
        nodes[other].stop()
        // Not exactly zero: a mixer at zero stops pulling its input, so the track would not run to its
        // schedule. This is -80 dB, inaudible.
        self.gains[other].outputVolume = Self.silent
        // A player's times (for `scheduleFile(at:)` and `play(at:)`) count from its own play call, not from the
        // engine's clock, so the node is started now, silent, and its data placed `wait` seconds after that.
        // (`startSample` is the same moment on the engine clock; the call-to-render delay is a few ms.)
        startNode(nodes[other], at: nil)
        nodes[other].scheduleFile(opened.file, at: AVAudioTime(sampleTime: AVAudioFramePosition(wait * c.rate), atRate: c.rate), completionHandler: nil)
        startSample[other] = startAt
        incoming = Incoming(node: other, index: opened.index, title: opened.title, duration: opened.duration, fade: max(usedFade, 0.05))
        log("playing \(opened.title), \(Int(opened.duration)) s")
    }

    private func startNode(_ node: AVAudioPlayerNode, at when: AVAudioTime?) {
        do {
            if let when { try node.playAudio(at: when) } else { try node.playAudio() }
        } catch { log("could not start playback: \(error)") }
    }

    // MARK: Engine

    /// Connects both players to the music bus, and the bus to the main mixer, once, in one format
    /// (stereo at the output's sample rate). The engine converts each file to it.
    private func connectNodes() {
        let rate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44100, channels: 2) else { return }
        do {
            try engine.connectNode(bus, to: engine.mainMixerNode, format: format)
            for i in 0..<nodes.count {
                try engine.connectNode(nodes[i], to: gains[i], format: format)
                try engine.connectNode(gains[i], to: bus, format: format)
            }
        } catch {
            log("could not connect the players: \(error)")
        }
    }

    private func engineConfigurationChanged() {
        guard isOn else { return }
        log("audio output changed; restarting the current track")
        timer?.invalidate(); timer = nil
        for node in nodes { node.stop() }
        incoming = nil
        connectNodes()
        guard (try? engine.start()) != nil, let opened = openPlayable(from: index) else { isOn = false; isPlaying = false; return }
        active = 0
        index = opened.index
        activeDuration = opened.duration
        gains[0].outputVolume = 1
        nodes[0].scheduleFile(opened.file, at: nil, completionHandler: nil)
        startSample = [nil, nil]
        startNode(nodes[0], at: nil)
        currentTitle = opened.title
        if !isPlaying { engine.pause() }
        startTimer()
    }
}
