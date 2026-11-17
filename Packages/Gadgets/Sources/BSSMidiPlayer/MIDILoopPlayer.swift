import AVFAudio
import BSSMidiLoop
import Foundation
import Synchronization

/// Why the player could not be set up on the engine it was given.
public enum MIDIPlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedFormat

    public var description: String {
        switch self {
        case .unsupportedFormat: return "The output does not give a stereo format this player can use"
        }
    }
}

/// One event for the render thread, stamped with the sample it sounds at.
struct TimedSynthEvent: Sendable {
    var sample: Int64
    var event: SynthEvent
}

/// A single-producer, single-consumer ring. One thread writes (the scheduler), one reads (the render thread).
/// The slots are allocated once; the two indices are atomics, so neither side locks, waits or allocates.
final class SPSCRing: @unchecked Sendable {
    private let capacity: Int
    private let slots: UnsafeMutablePointer<TimedSynthEvent>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        slots = UnsafeMutablePointer<TimedSynthEvent>.allocate(capacity: capacity)
        slots.initialize(repeating: TimedSynthEvent(sample: 0, event: SynthEvent(offset: 0, kind: .controller(channel: 0, number: 0, value: 0))),
                         count: capacity)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    /// Writer only. False when the ring is full; the caller keeps the item and tries again.
    func push(_ item: TimedSynthEvent) -> Bool {
        let write = written.load(ordering: .relaxed)
        let read = consumed.load(ordering: .acquiring)
        guard write - read < capacity else { return false }
        slots[write % capacity] = item
        written.store(write + 1, ordering: .releasing)
        return true
    }

    /// Reader only. Moves up to `limit` items that sound before `end` into `out`, in order. Returns how many.
    func popDue(before end: Int64, into out: UnsafeMutablePointer<TimedSynthEvent>, limit: Int) -> Int {
        var read = consumed.load(ordering: .relaxed)
        let write = written.load(ordering: .acquiring)
        var taken = 0
        while read < write, taken < limit, slots[read % capacity].sample < end {
            out[taken] = slots[read % capacity]
            read += 1
            taken += 1
        }
        consumed.store(read, ordering: .releasing)
        return taken
    }
}

/// What the scheduler thread and the render thread share. Every field is an atomic: no locks anywhere on the audio path.
final class PlaybackState: @unchecked Sendable {
    let ring = SPSCRing(capacity: 16_384)
    private let rendered = Atomic<Int>(0)
    private let stopping = Atomic<Bool>(false)
    private let stallMilliseconds = Atomic<Int>(0)
    private let schedulerRunning = Atomic<Bool>(false)

    /// True while a scheduler thread is alive (it clears this only after its last flush).
    var isSchedulerRunning: Bool {
        return schedulerRunning.load(ordering: .acquiring)
    }

    func setSchedulerRunning(_ running: Bool) {
        schedulerRunning.store(running, ordering: .releasing)
    }

    /// Lets a stopped player play again: the next `play` starts with the stop flag clear.
    func clearStop() {
        stopping.store(false, ordering: .releasing)
    }
    private let voicesSounding = Atomic<Int>(0)
    /// The sample up to which the scheduler has queued every event. Render callbacks that run past it are underruns.
    private let queuedThrough = Atomic<Int>(Int.max)
    private let underrunCounter = Atomic<Int>(0)

    /// Callbacks where the render thread went past the events the scheduler had queued: the ring did not have an event
    /// that was due. Zero in normal play; above zero means the scheduler fell behind the audio clock.
    public var underruns: Int {
        return underrunCounter.load(ordering: .acquiring)
    }

    var queuedThroughSample: Int {
        return queuedThrough.load(ordering: .acquiring)
    }

    func setQueuedThrough(_ sample: Int64) {
        queuedThrough.store(Int(sample), ordering: .releasing)
    }

    func countUnderrun() {
        _ = underrunCounter.add(1, ordering: .relaxed)
    }

    /// How many synth voices are not idle, as of the last render block. Zero after stop means no note is stuck.
    var soundingVoices: Int {
        return voicesSounding.load(ordering: .acquiring)
    }

    func setSoundingVoices(_ count: Int) {
        voicesSounding.store(count, ordering: .releasing)
    }

    /// The sample the render thread has reached. The scheduler works ahead of this.
    var renderedSample: Int64 {
        return Int64(rendered.load(ordering: .acquiring))
    }

    func setRendered(_ sample: Int64) {
        rendered.store(Int(sample), ordering: .releasing)
    }

    var stopRequested: Bool {
        return stopping.load(ordering: .acquiring)
    }

    func requestStop() {
        stopping.store(true, ordering: .releasing)
    }

    /// Test hook: the scheduler sleeps this long before its next pass.
    func requestStall(milliseconds: Int) {
        stallMilliseconds.store(milliseconds, ordering: .releasing)
    }

    func takeStall() -> Int {
        return stallMilliseconds.exchange(0, ordering: .acquiringAndReleasing)
    }
}

/// The producer side: moves a cursor's events into a ring, up to a horizon. Used by the scheduler thread and by the
/// offline render, so both put events on the same path.
struct EventPump {
    private var held: TimedSynthEvent?
    private let origin: Int64
    private let rate: Double
    private let keepsJumps: Bool
    /// Jump messages, kept only when asked for (the offline render asks; the live scheduler does not, so it never grows).
    private(set) var jumps: [(seconds: Double, from: Int, to: Int)] = []
    /// Notes this producer has sent on and not yet off, by key (channel and pitch). On stop these get an immediate note-off.
    private var sounding: [UInt16: Int] = [:]
    /// Called with each jump as the scheduler reaches it (its performance time, and the segments it joins), for logs.
    private let onJump: (@Sendable (Double, Int, Int) -> Void)?

    init(origin: Int64, rate: Double, keepsJumps: Bool, onJump: (@Sendable (Double, Int, Int) -> Void)? = nil) {
        self.origin = origin
        self.rate = rate
        self.keepsJumps = keepsJumps
        self.onJump = onJump
    }

    /// Queues events until the next one sounds at or after `horizon`, or the ring is full. Returns true only when it
    /// reached the horizon, so every event before it is queued.
    @discardableResult
    mutating func pump(_ cursor: inout EventCursor, ring: SPSCRing, horizon: Int64) -> Bool {
        while true {
            let item: TimedSynthEvent
            if let waiting = held {
                item = waiting
                held = nil
            } else {
                let event = cursor.next()
                if case let .jump(from, to) = event.message {
                    if keepsJumps { jumps.append((event.seconds, from, to)) }
                    onJump?(event.seconds, from, to)
                    continue
                }
                guard let converted = MIDILoopPlayer.convert(event.message) else { continue }
                item = TimedSynthEvent(sample: origin + Int64((event.seconds * rate).rounded()), event: converted)
            }
            if item.sample >= horizon {
                held = item
                return true
            }
            guard ring.push(item) else {
                held = item
                return false
            }
            track(item.event.kind)
        }
    }

    private mutating func track(_ kind: SynthEvent.Kind) {
        switch kind {
        case let .noteOn(channel, pitch, _):
            sounding[UInt16(channel) << 8 | UInt16(pitch), default: 0] += 1
        case let .noteOff(channel, pitch):
            let key = UInt16(channel) << 8 | UInt16(pitch)
            if let count = sounding[key], count > 1 {
                sounding[key] = count - 1
            } else {
                sounding.removeValue(forKey: key)
            }
        case .controller:
            break
        }
    }

    /// On stop: note-offs now, for every note this producer started and has not ended. The cursor's queued events are
    /// in the future, so they are not sent; the render thread also drops any note-on that falls due after stop.
    /// Waits for room in the ring.
    mutating func flush(_ cursor: inout EventCursor, ring: SPSCRing, now: Int64) {
        held = nil
        _ = cursor.finish()
        for (key, count) in sounding where count > 0 {
            for _ in 0..<count {
                let item = TimedSynthEvent(sample: now, event: SynthEvent(offset: 0, kind: .noteOff(channel: UInt8(key >> 8), pitch: UInt8(key & 0xFF))))
                while !ring.push(item) { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        sounding.removeAll()
    }
}

/// Buffers for the render block, allocated once. The render thread reads and writes them through pointers only.
final class RenderBuffers: @unchecked Sendable {
    let capacity: Int
    let items: UnsafeMutablePointer<TimedSynthEvent>
    let events: UnsafeMutablePointer<SynthEvent>

    init(capacity: Int) {
        self.capacity = capacity
        items = UnsafeMutablePointer<TimedSynthEvent>.allocate(capacity: capacity)
        items.initialize(repeating: TimedSynthEvent(sample: 0, event: SynthEvent(offset: 0, kind: .controller(channel: 0, number: 0, value: 0))),
                         count: capacity)
        events = UnsafeMutablePointer<SynthEvent>.allocate(capacity: capacity)
        events.initialize(repeating: SynthEvent(offset: 0, kind: .controller(channel: 0, number: 0, value: 0)), count: capacity)
    }

    deinit {
        items.deinitialize(count: capacity)
        items.deallocate()
        events.deinitialize(count: capacity)
        events.deallocate()
    }
}

/// The synth, held for the render thread. Only the render block touches it.
final class PadSynthBox: @unchecked Sendable {
    var synth: PadSynth

    init(sampleRate: Double) {
        synth = PadSynth(sampleRate: sampleRate)
    }
}

/// Plays a `BSSMidiLoop` event cursor as a soft pad, through a reverb, on an engine the app supplies.
///
/// The player never makes its own engine. It attaches a source node and a reverb to the engine it is given, and
/// connects them to the output node it is given. A scheduler thread (not the main thread, not the audio thread) keeps
/// the next two seconds of events queued, each stamped with its sample. The render thread takes them from a
/// single-producer, single-consumer ring of atomics and plays each at its exact frame. No locks on the audio path.
/// Voices: 32, with stealing; one shared reverb (cathedral, 35 % wet). Stop sends every note off through the reverb's tail.
public final class MIDILoopPlayer: @unchecked Sendable {
    /// How far ahead the scheduler queues events, in seconds.
    public static let lookaheadSeconds = 2.0
    /// The reverb's wet share of the mix, in percent.
    public static let reverbWetPercent: Float = 35
    /// How long after `play` the first note sounds, so the scheduler has the first events queued.
    static let startDelaySeconds = 0.1

    private let source: AVAudioSourceNode
    private let reverb: AVAudioUnitReverb
    private let state: PlaybackState
    private let sampleRate: Double
    private var thread: Thread?

    /// Attaches the pad and the reverb to `engine` and connects them to `output`. The engine is not started here.
    public init(engine: AVAudioEngine, output: AVAudioNode) throws {
        let outputRate = output.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw MIDIPlayerError.unsupportedFormat
        }
        let state = PlaybackState()
        let synthBox = PadSynthBox(sampleRate: rate)
        let buffers = RenderBuffers(capacity: 16_384)

        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList -> OSStatus in
            let frames = Int(frameCount)
            let start = Int64(timestamp.pointee.mSampleTime)
            let end = start + Int64(frames)
            let count = state.ring.popDue(before: end, into: buffers.items, limit: buffers.capacity)
            let stopping = state.stopRequested
            if !stopping, Int(end) > state.queuedThroughSample {
                state.countUnderrun()
            }
            var used = 0
            for index in 0..<count {
                let item = buffers.items[index]
                // After stop, a note that was queued to start later must not start: its note-off has already been sent.
                if stopping, case .noteOn = item.event.kind { continue }
                let offset = min(max(0, Int(item.sample - start)), max(0, frames - 1))
                buffers.events[used] = SynthEvent(offset: offset, kind: item.event.kind)
                used += 1
            }
            let lists = UnsafeMutableAudioBufferListPointer(bufferList)
            if frames > 0, lists.count >= 2,
               let left = lists[0].mData?.assumingMemoryBound(to: Float.self),
               let right = lists[1].mData?.assumingMemoryBound(to: Float.self) {
                synthBox.synth.render(left: left, right: right, frames: frames,
                                      events: UnsafeBufferPointer(start: buffers.events, count: used))
            }
            state.setSoundingVoices(synthBox.synth.sounding)
            state.setRendered(end)
            return noErr
        }

        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = MIDILoopPlayer.reverbWetPercent

        engine.attach(source)
        engine.attach(reverb)
        try engine.connectNode(source, to: reverb, format: format)
        try engine.connectNode(reverb, to: output, format: format)

        self.source = source
        self.reverb = reverb
        self.state = state
        self.sampleRate = rate
    }

    /// The reverb, whose output carries the pad. Tests tap it, so output muting does not hide the sound.
    var reverbNode: AVAudioNode { reverb }

    /// The shared state, for the offline render, which feeds the same ring from its own thread.
    var playbackState: PlaybackState { state }

    /// Render callbacks where an event was due but the scheduler had not queued it. See `PlaybackState.underruns`.
    public var underruns: Int { state.underruns }

    /// Voices not idle, as of the last render block.
    public var soundingVoices: Int { state.soundingVoices }

    /// Called from the scheduler thread for each jump, with its performance time and the segments it joins.
    /// Set it before `play`. It runs off the main thread, so it must not touch UI state directly.
    public var onJump: (@Sendable (Double, Int, Int) -> Void)?

    /// Starts the scheduler. A stopped player may be played again: this waits for the last scheduler to finish its
    /// flush, then starts a new one. `stop` ends the current one.
    public func play(_ cursor: EventCursor) {
        var waited = 0
        while state.isSchedulerRunning, waited < 2_000 {
            Thread.sleep(forTimeInterval: 0.005)
            waited += 1
        }
        state.clearStop()
        state.setQueuedThrough(Int64.max)
        state.setSchedulerRunning(true)
        let origin = state.renderedSample + Int64(MIDILoopPlayer.startDelaySeconds * sampleRate)
        let state = self.state
        let rate = sampleRate
        let jumps = onJump
        let worker = Thread { [cursor] in
            var cursor = cursor
            MIDILoopPlayer.schedule(&cursor, state: state, origin: origin, rate: rate, onJump: jumps)
            state.setSchedulerRunning(false)
        }
        worker.name = "BSSMidiPlayer scheduler"
        thread = worker
        worker.start()
    }

    /// Stops after the queued events: every sounding note is released through the reverb's tail.
    public func stop() {
        state.requestStop()
    }

    /// Test hook: the scheduler thread sleeps for this long before its next pass.
    func stallScheduler(milliseconds: Int) {
        state.requestStall(milliseconds: milliseconds)
    }

    /// The scheduler: keeps `lookaheadSeconds` of events queued, and on stop sends the rest.
    static func schedule(_ cursor: inout EventCursor, state: PlaybackState, origin: Int64, rate: Double,
                         onJump: (@Sendable (Double, Int, Int) -> Void)? = nil) {
        let lookahead = Int64(lookaheadSeconds * rate)
        var pump = EventPump(origin: origin, rate: rate, keepsJumps: false, onJump: onJump)
        while !state.stopRequested {
            let stall = state.takeStall()
            if stall > 0 { Thread.sleep(forTimeInterval: Double(stall) / 1000) }
            let horizon = state.renderedSample + lookahead
            if pump.pump(&cursor, ring: state.ring, horizon: horizon) {
                state.setQueuedThrough(horizon)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        pump.flush(&cursor, ring: state.ring, now: state.renderedSample)
    }

    /// The events the synth plays. A jump is for logs and is not played.
    static func convert(_ message: TimedEvent.Message) -> SynthEvent? {
        switch message {
        case let .noteOn(channel, pitch, velocity):
            return SynthEvent(offset: 0, kind: .noteOn(channel: channel, pitch: pitch, velocity: velocity))
        case let .noteOff(channel, pitch):
            return SynthEvent(offset: 0, kind: .noteOff(channel: channel, pitch: pitch))
        case let .controller(channel, number, value):
            return SynthEvent(offset: 0, kind: .controller(channel: channel, number: number, value: value))
        case .jump:
            return nil
        }
    }
}
