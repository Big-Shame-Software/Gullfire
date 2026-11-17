import AVFAudio
import BSSMidiLoop
import Foundation

/// Renders a cursor to a WAV file, faster than real time, through the same path as the live player (pump, ring, pad,
/// reverb). It uses the engine's manual rendering mode, so no audio device is needed and nothing is played.
public enum OfflineRender {
    public struct Result: Sendable {
        public let sampleRate: Double
        public let frames: Int
        /// Every jump the plan made inside the render, with its time in seconds from the start.
        public let jumps: [Jump]
        /// The left channel, for measures. The file has both channels.
        public let samples: [Float]
        /// The largest absolute sample value (1.0 is 0 dBFS).
        public let peak: Float
    }

    public struct Jump: Sendable, Equatable {
        public let seconds: Double
        public let from: Int
        public let to: Int
    }

    public enum RenderError: Error, CustomStringConvertible {
        case format
        case engine(String)

        public var description: String {
            switch self {
            case .format: return "Could not make a stereo float format for the render"
            case let .engine(why): return "The offline engine failed: \(why)"
            }
        }
    }

    /// Renders `seconds` of the cursor's playback. `gain` scales the output (linear: 1 is unchanged). If `url` is given,
    /// the result is written there as a 16-bit stereo WAV; with no `url` it is only measured (a calibration pass).
    public static func render(cursor: inout EventCursor, seconds: Double, to url: URL? = nil, gain: Float = 1,
                              sampleRate: Double = 48_000) throws -> Result {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw RenderError.format
        }
        let chunk = 4_096
        let engine = AVAudioEngine()
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(chunk))
        } catch {
            throw RenderError.engine("manual rendering: \(error.localizedDescription)")
        }
        let player: MIDILoopPlayer
        do {
            player = try MIDILoopPlayer(engine: engine, output: engine.outputNode)
        } catch {
            throw RenderError.engine("player: \(error)")
        }
        do {
            try engine.start()
        } catch {
            throw RenderError.engine("start: \(error.localizedDescription)")
        }
        defer { engine.stop() }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try url.map { try AVAudioFile(forWriting: $0, settings: settings) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw RenderError.format
        }

        let state = player.playbackState
        let total = Int64((seconds * sampleRate).rounded())
        let lookahead = Int64(MIDILoopPlayer.lookaheadSeconds * sampleRate)
        var pump = EventPump(origin: 0, rate: sampleRate, keepsJumps: true)
        var rendered: Int64 = 0
        var peak: Float = 0
        var left: [Float] = []
        left.reserveCapacity(Int(total))

        while rendered < total {
            let frames = Int(min(Int64(chunk), total - rendered))
            pump.pump(&cursor, ring: state.ring, horizon: rendered + Int64(frames) + lookahead)
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
            } catch {
                throw RenderError.engine("render: \(error.localizedDescription)")
            }
            guard status == .success, let channels = buffer.floatChannelData else {
                throw RenderError.engine("render returned \(status.rawValue)")
            }
            for index in 0..<frames {
                channels[0][index] *= gain
                channels[1][index] *= gain
                let l = channels[0][index]
                let r = channels[1][index]
                peak = max(peak, abs(l), abs(r))
                left.append(l)
            }
            if let file { try file.write(from: buffer) }
            rendered += Int64(frames)
        }

        let jumps = pump.jumps.map { Jump(seconds: $0.seconds, from: $0.from, to: $0.to) }
        return Result(sampleRate: sampleRate, frames: Int(rendered), jumps: jumps, samples: left, peak: peak)
    }
}
