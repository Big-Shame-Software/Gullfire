import Foundation

/// One output event, in seconds from the start of the performance.
public struct TimedEvent: Sendable, Equatable {
    public enum Message: Sendable, Equatable {
        case noteOn(channel: UInt8, pitch: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, pitch: UInt8)
        case controller(channel: UInt8, number: UInt8, value: UInt8)
        /// A jump from one segment to another, for logs. A player ignores it.
        case jump(from: Int, to: Int)
    }

    public let seconds: Double
    public let message: Message

    public init(seconds: Double, message: Message) {
        self.seconds = seconds
        self.message = message
    }
}

/// Streams a plan as timed MIDI events. It is lazy: it expands one segment at a time, so memory holds only the events
/// of the current segment and whatever is ringing out. It never ends in endless and loop modes.
///
/// State at every jump: notes that were sounding are rung out for one beat, the sustain pedal is set to what the
/// destination expects, and notes that are still sounding at the destination's start are started there, so it doesn't
/// sound hollow. Their note-offs come later in the destination's own events. A note-off is only ever sent for a note
/// that was started, and every started note is stopped, so a stuck note cannot happen by construction.
public struct EventCursor: Sendable {
    struct NoteKey: Hashable, Sendable {
        let channel: UInt8
        let pitch: UInt8
    }

    struct Pending: Sendable {
        let seconds: Double
        let sequence: Int
        let event: TimedEvent
        /// Set on a ring-out note-off, so it can be cancelled if the same key is struck again first.
        let ringId: Int?
    }

    private let piece: MIDIPerformance
    private let map: LoopMap
    private var planner: Planner
    private let pedalChannels: [UInt8]
    private var heap: [Pending] = []
    private var sequence = 0
    /// Notes the output has started and not yet stopped, by note id (the index into `piece.notes`).
    private var active: Set<Int> = []
    /// Ring-out notes still waiting for their note-off, by note id.
    private var ringing: [Int: NoteKey] = [:]
    /// Every event before this time is already queued, so anything queued earlier can be sent.
    private var frontier = 0.0
    /// Added to a source tick to give output seconds.
    private var offset = 0.0
    private var lastSegment: Int? = nil

    public init(piece: MIDIPerformance, map: LoopMap, mode: Planner.Mode, seed: UInt64) {
        self.piece = piece
        self.map = map
        self.planner = Planner(map: map, mode: mode, seed: seed)
        self.pedalChannels = Array(Set(piece.controllers.filter { $0.number == 64 }.map(\.channel))).sorted()
    }

    /// The next event. Endless and loop plans never run out.
    public mutating func next() -> TimedEvent {
        while true {
            if let top = heap.first, top.seconds < frontier {
                let item = popFirst()
                if let id = item.ringId {
                    guard ringing.removeValue(forKey: id) != nil else { continue }
                }
                return item.event
            }
            expandNextStep()
        }
    }

    /// Stops the performance: returns everything still queued, in order, then note-offs for any note still sounding.
    /// Call it once; the cursor is spent afterwards.
    public mutating func finish() -> [TimedEvent] {
        var result: [TimedEvent] = []
        while !heap.isEmpty {
            let item = popFirst()
            if let id = item.ringId {
                guard ringing.removeValue(forKey: id) != nil else { continue }
            }
            result.append(item.event)
        }
        let last = result.last?.seconds ?? frontier
        for id in active.sorted() {
            let note = piece.notes[id]
            result.append(TimedEvent(seconds: last, message: .noteOff(channel: note.channel, pitch: note.pitch)))
        }
        for id in ringing.keys.sorted() {
            let key = ringing[id]!
            result.append(TimedEvent(seconds: last, message: .noteOff(channel: key.channel, pitch: key.pitch)))
        }
        active.removeAll()
        ringing.removeAll()
        return result
    }

    // MARK: - Expansion

    private mutating func expandNextStep() {
        let step = planner.next()
        let segment = map.segments[step.segment]
        let cutSeconds = frontier
        switch step.kind {
        case .start:
            offset = -piece.seconds(atTick: segment.startTick)
            rebuild(cutAt: 0, arriveAt: 0, cutTick: segment.startTick, into: segment)
        case .natural:
            break
        case .jump(let breath):
            let cutTick = lastSegment.map { map.segments[$0].endTick } ?? segment.startTick
            let arrival = cutSeconds + breath
            if let from = lastSegment {
                push(cutSeconds, .jump(from: from, to: step.segment))
            }
            offset = arrival - piece.seconds(atTick: segment.startTick)
            rebuild(cutAt: cutSeconds, arriveAt: arrival, cutTick: cutTick, into: segment)
        }
        lastSegment = step.segment
        emit(segment)
        frontier = piece.seconds(atTick: segment.endTick) + offset
    }

    /// The state change at a jump: the pedal for the destination, ring-out for what sounds now and is not needed,
    /// and starts for the notes the destination begins in the middle of.
    private mutating func rebuild(cutAt: Double, arriveAt: Double, cutTick: Int, into segment: LoopSegment) {
        let beat = piece.quarterSeconds(atTick: cutTick)
        for channel in pedalChannels {
            let value = piece.pedalValue(channel: channel, beforeTick: segment.startTick)
            push(cutAt, .controller(channel: channel, number: 64, value: value))
        }

        let arriving = carriedNotes(at: segment.startTick)
        let arrivingKeys = Set(arriving.map { noteKey($0) })
        for id in active.sorted() where !arriving.contains(id) {
            let key = noteKey(id)
            // A ring-out may not outlast the start of a new note on the same key.
            let when = arrivingKeys.contains(key) ? cutAt : cutAt + beat
            active.remove(id)
            ringing[id] = key
            push(when, .noteOff(channel: key.channel, pitch: key.pitch), ringId: id)
        }
        for id in arriving.sorted() where !active.contains(id) {
            let note = piece.notes[id]
            active.insert(id)
            push(arriveAt, .noteOn(channel: note.channel, pitch: note.pitch, velocity: note.velocity))
        }
    }

    /// The notes that begin before a tick and still sound at it.
    private func carriedNotes(at tick: Int) -> Set<Int> {
        var result: Set<Int> = []
        for (id, note) in piece.notes.enumerated() where note.start < tick && note.soundingEnd > tick {
            result.insert(id)
        }
        return result
    }

    private func noteKey(_ id: Int) -> NoteKey {
        let note = piece.notes[id]
        return NoteKey(channel: note.channel, pitch: note.pitch)
    }

    /// Queues every playback event of a segment, in its own time.
    private mutating func emit(_ segment: LoopSegment) {
        let offset = self.offset
        for event in piece.playbackEvents(from: segment.startTick, to: segment.endTick) {
            let when = piece.seconds(atTick: event.tick) + offset
            switch event.kind {
            case .controller(let controller):
                push(when, .controller(channel: controller.channel, number: controller.number, value: controller.value))
            case .noteOn(let id):
                let note = piece.notes[id]
                let key = NoteKey(channel: note.channel, pitch: note.pitch)
                // Stop a ring-out on this key first, so the new note starts clean.
                for ringId in ringing.keys.sorted() where ringing[ringId] == key {
                    ringing.removeValue(forKey: ringId)
                    push(when, .noteOff(channel: key.channel, pitch: key.pitch))
                }
                active.insert(id)
                push(when, .noteOn(channel: key.channel, pitch: key.pitch, velocity: note.velocity))
            case .noteOff(let id):
                guard active.remove(id) != nil else { continue }
                let note = piece.notes[id]
                push(when, .noteOff(channel: note.channel, pitch: note.pitch))
            }
        }
    }

    // MARK: - Queue (a binary heap ordered by time, then by the order events were queued)

    private func precedes(_ a: Pending, _ b: Pending) -> Bool {
        if a.seconds != b.seconds { return a.seconds < b.seconds }
        return a.sequence < b.sequence
    }

    private mutating func push(_ seconds: Double, _ message: TimedEvent.Message, ringId: Int? = nil) {
        sequence += 1
        heap.append(Pending(seconds: seconds, sequence: sequence, event: TimedEvent(seconds: seconds, message: message), ringId: ringId))
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func popFirst() -> Pending {
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, precedes(heap[left], heap[smallest]) { smallest = left }
            if right < heap.count, precedes(heap[right], heap[smallest]) { smallest = right }
            if smallest == parent { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
