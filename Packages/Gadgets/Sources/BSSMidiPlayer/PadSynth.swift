import Foundation

/// One note the synth plays, with its place in the block being rendered.
struct SynthEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case noteOn(channel: UInt8, pitch: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, pitch: UInt8)
        case controller(channel: UInt8, number: UInt8, value: UInt8)
    }

    /// Frame offset inside the block, from 0.
    var offset: Int
    var kind: Kind
}

/// One pad voice: two slightly detuned triangles through a gentle low-pass, plus a quieter sine an octave up.
/// The envelope is a linear fade in from 0.0001 (so a gain never sits at exactly zero, which stops some mixers),
/// a hold, and a linear release. A stolen voice fades out in a few milliseconds instead of stopping dead.
struct PadVoice: Sendable {
    enum Stage: Sendable, Equatable {
        case idle
        case attack
        case sustain
        case release
        case steal
    }

    /// Envelope lengths and the filter, in samples.
    struct Timing: Sendable {
        let sampleRate: Double
        let attackSamples: Double
        let releaseSamples: Double
        let stealSamples: Double

        static func standard(sampleRate: Double) -> Timing {
            return Timing(sampleRate: sampleRate,
                          attackSamples: 0.25 * sampleRate,
                          releaseSamples: 1.5 * sampleRate,
                          stealSamples: 0.005 * sampleRate)
        }
    }

    /// Filter cutoff of the pad's low-pass, in hertz.
    static let cutoff = 1_800.0
    /// Gain of one voice before the output's soft clip.
    static let voiceGain = 0.2
    static let startLevel = 0.0001

    private(set) var stage: Stage = .idle
    private(set) var channel: UInt8 = 0
    private(set) var pitch: UInt8 = 0
    private(set) var age = 0
    private(set) var level = 0.0
    var sustained = false

    private var gain = 0.0
    private var phaseA = 0.0
    private var phaseB = 0.0
    private var phaseC = 0.0
    private var incrementA = 0.0
    private var incrementB = 0.0
    private var incrementC = 0.0
    private var lowpass = 0.0
    private var filter = 0.0
    private var attackStep = 0.0
    private var releaseStep = 0.0
    private var stealStep = 0.0

    mutating func start(channel: UInt8, pitch: UInt8, velocity: UInt8, timing: Timing) {
        self.channel = channel
        self.pitch = pitch
        stage = .attack
        age = 0
        level = PadVoice.startLevel
        sustained = false
        gain = Double(velocity) / 127 * PadVoice.voiceGain
        let frequency = 440 * pow(2, (Double(pitch) - 69) / 12)
        incrementA = frequency / timing.sampleRate
        incrementB = frequency * 1.0035 / timing.sampleRate
        incrementC = 2 * frequency / timing.sampleRate
        phaseA = 0
        phaseB = 0
        phaseC = 0
        lowpass = 0
        filter = 1 - exp(-2 * Double.pi * PadVoice.cutoff / timing.sampleRate)
        attackStep = (1 - PadVoice.startLevel) / max(1, timing.attackSamples)
        releaseStep = 1 / max(1, timing.releaseSamples)
        stealStep = 1 / max(1, timing.stealSamples)
    }

    /// Lets the note go: the release starts from wherever the envelope is.
    mutating func release() {
        guard stage == .attack || stage == .sustain else { return }
        stage = .release
    }

    /// Fades the voice out fast so a new note can take its place without a click.
    mutating func beginSteal() {
        guard stage != .idle else { return }
        stage = .steal
    }

    /// The next output sample. Returns 0 once the voice is idle.
    mutating func next() -> Double {
        switch stage {
        case .idle:
            return 0
        case .attack:
            level += attackStep
            if level >= 1 {
                level = 1
                stage = .sustain
            }
        case .sustain:
            break
        case .release:
            level -= releaseStep
            if level <= 0 { return finish() }
        case .steal:
            level -= stealStep
            if level <= 0 { return finish() }
        }
        age += 1
        phaseA = advance(phaseA, incrementA)
        phaseB = advance(phaseB, incrementB)
        phaseC = advance(phaseC, incrementC)
        let raw = 0.5 * (PadVoice.triangle(phaseA) + PadVoice.triangle(phaseB))
        lowpass += filter * (raw - lowpass)
        let octave = sin(2 * Double.pi * phaseC) * 0.25
        return (lowpass + octave) * level * gain
    }

    private mutating func finish() -> Double {
        level = 0
        stage = .idle
        sustained = false
        return 0
    }

    private func advance(_ phase: Double, _ increment: Double) -> Double {
        let next = phase + increment
        return next >= 1 ? next - 1 : next
    }

    /// A triangle wave at phase 0...1: +1 at 0, -1 at one half.
    static func triangle(_ phase: Double) -> Double {
        return 4 * abs(phase - 0.5) - 1
    }
}

/// The polyphonic pad: up to 32 voices, pedal handling, and stealing when every voice is busy.
/// It is owned by the render thread and is not thread-safe on its own.
struct PadSynth: Sendable {
    static let voiceLimit = 32
    static let pendingLimit = 64

    private(set) var voices: [PadVoice]
    private var pending: [(channel: UInt8, pitch: UInt8, velocity: UInt8)] = []
    private var pedalDown = [Bool](repeating: false, count: 16)
    let timing: PadVoice.Timing

    init(sampleRate: Double) {
        timing = .standard(sampleRate: sampleRate)
        voices = [PadVoice](repeating: PadVoice(), count: PadSynth.voiceLimit)
        pending.reserveCapacity(PadSynth.pendingLimit)
    }

    /// How many voices are not idle.
    var sounding: Int {
        return voices.reduce(0) { $0 + ($1.stage == .idle ? 0 : 1) }
    }

    /// Fills `left` and `right` for `frames` samples, applying each event at its own frame.
    /// Takes a pointer, not an array, so the render thread never allocates here.
    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                         events: UnsafeBufferPointer<SynthEvent>) {
        var next = 0
        for frame in 0..<frames {
            while next < events.count, events[next].offset <= frame {
                apply(events[next].kind)
                next += 1
            }
            var mix = 0.0
            for index in voices.indices where voices[index].stage != .idle {
                mix += voices[index].next()
            }
            startPending()
            let sample = Float(tanh(mix))
            left[frame] = sample
            right[frame] = sample
        }
    }

    /// The same as the pointer version, for tests and other callers that have an array.
    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, events: [SynthEvent]) {
        events.withUnsafeBufferPointer { render(left: left, right: right, frames: frames, events: $0) }
    }

    mutating func apply(_ kind: SynthEvent.Kind) {
        switch kind {
        case let .noteOn(channel, pitch, velocity):
            noteOn(channel: channel, pitch: pitch, velocity: velocity)
        case let .noteOff(channel, pitch):
            noteOff(channel: channel, pitch: pitch)
        case let .controller(channel, number, value):
            guard number == 64 else { return }
            setPedal(channel: channel, down: value >= 64)
        }
    }

    private mutating func noteOn(channel: UInt8, pitch: UInt8, velocity: UInt8) {
        if let index = voices.firstIndex(where: { $0.stage == .idle }) {
            voices[index].start(channel: channel, pitch: pitch, velocity: velocity, timing: timing)
            return
        }
        // Every voice is busy: the new note waits, and steals the quietest released voice, else the oldest.
        if pending.count < PadSynth.pendingLimit {
            pending.append((channel, pitch, velocity))
        }
        if let victim = stealCandidate() {
            voices[victim].beginSteal()
        }
    }

    /// Oldest-quietest: a released voice with the lowest level first, otherwise the oldest voice that is not already fading.
    private func stealCandidate() -> Int? {
        var best: Int? = nil
        for index in voices.indices where voices[index].stage != .steal && voices[index].stage != .idle {
            guard let current = best else {
                best = index
                continue
            }
            let candidate = voices[index]
            let chosen = voices[current]
            let candidateReleased = candidate.stage == .release
            let chosenReleased = chosen.stage == .release
            if candidateReleased != chosenReleased {
                if candidateReleased { best = index }
            } else if candidateReleased {
                if candidate.level < chosen.level { best = index }
            } else if candidate.age > chosen.age {
                best = index
            }
        }
        return best
    }

    private mutating func startPending() {
        guard !pending.isEmpty else { return }
        for index in voices.indices where voices[index].stage == .idle && !pending.isEmpty {
            let note = pending.removeFirst()
            voices[index].start(channel: note.channel, pitch: note.pitch, velocity: note.velocity, timing: timing)
        }
    }

    private mutating func noteOff(channel: UInt8, pitch: UInt8) {
        if let waiting = pending.firstIndex(where: { $0.channel == channel && $0.pitch == pitch }) {
            pending.remove(at: waiting)
            return
        }
        guard let index = voices.firstIndex(where: {
            $0.channel == channel && $0.pitch == pitch && ($0.stage == .attack || $0.stage == .sustain)
        }) else { return }
        if pedalDown[Int(channel) & 15] {
            voices[index].sustained = true
        } else {
            voices[index].release()
        }
    }

    private mutating func setPedal(channel: UInt8, down: Bool) {
        let slot = Int(channel) & 15
        pedalDown[slot] = down
        guard !down else { return }
        for index in voices.indices where voices[index].channel == channel && voices[index].sustained {
            voices[index].sustained = false
            voices[index].release()
        }
    }
}
