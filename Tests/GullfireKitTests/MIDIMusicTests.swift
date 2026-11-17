import AVFoundation
import Foundation
import Testing
@testable import GullfireKit

/// A four-bar MIDI piece made in code (no real score), written to a temporary folder.
private func writeGeneratedMIDI(_ url: URL) throws {
    let division = 480
    var events: [(tick: Int, bytes: [UInt8])] = [
        (0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]),
        (0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]),
    ]
    for bar in 0..<4 {
        for pitch: UInt8 in [60, 64, 67] {
            events.append((bar * 4 * division, [0x90, pitch, 80]))
            events.append((bar * 4 * division + 4 * division - 1, [0x80, pitch, 0]))
        }
    }
    var body: [UInt8] = []
    var last = 0
    for event in events.sorted(by: { $0.tick < $1.tick }) {
        body += variableLength(event.tick - last)
        body += event.bytes
        last = event.tick
    }
    body += [0x00, 0xFF, 0x2F, 0x00]
    var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
    bytes += Array("MTrk".utf8) + [0, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    try Data(bytes).write(to: url)
}

private func variableLength(_ value: Int) -> [UInt8] {
    var groups = [UInt8(value & 0x7F)]
    var rest = value >> 7
    while rest > 0 {
        groups.insert(UInt8((rest & 0x7F) | 0x80), at: 0)
        rest >>= 7
    }
    return groups
}

/// The MIDI piece as a music source. Each start replaces the one before, so the engine keeps exactly one MIDI player.
@Suite(.serialized) @MainActor struct MIDIMusicTests {
    @Test func startStopStartLeavesOneMIDIPlayerOnTheEngine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gullfire-midi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let midi = folder.appendingPathComponent("piece.mid")
        try writeGeneratedMIDI(midi)
        let sidecar = MIDIMusic.sidecarURL(for: midi)

        let engine = AVAudioEngine()
        let output = AVAudioMixerNode()
        engine.attach(output)
        engine.connect(output, to: engine.mainMixerNode, format: nil)
        let before = engine.attachedNodes.count

        let music = try MIDIMusic(engine: engine, output: output)
        // One source node and one reverb: the player's two nodes.
        #expect(engine.attachedNodes.count == before + 2)

        try music.start(midi: midi, sidecar: sidecar, mode: .endless, seed: 1)
        #expect(music.isOn)
        #expect(engine.attachedNodes.count == before + 2)

        music.stop()
        #expect(!music.isOn)

        try music.start(midi: midi, sidecar: sidecar, mode: .loop, seed: 2)
        #expect(music.isOn)
        #expect(engine.attachedNodes.count == before + 2)

        music.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}
