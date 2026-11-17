import Foundation

/// The arithmetic of a crossfade, kept apart from the audio engine so it can be tested.
public enum CrossfadePlan {
    /// The fade actually used: the requested length, but never more than half of either track,
    /// so a short track still gets a start and an end of its own.
    public static func effectiveFade(requested: Double, outgoing: Double, incoming: Double) -> Double {
        max(0, min(requested, outgoing / 2, incoming / 2))
    }

    /// The longest fade one track can loop with: half its length, the same limit `effectiveFade`
    /// applies. Cathedral mode's slider stops here, and its default is here.
    public static func longestLoopFade(duration: Double) -> Double {
        max(0, duration / 2)
    }

    /// Seconds into a track of `duration` at which a fade of `fade` seconds should start, so that
    /// the track ends as the fade ends.
    public static func fadeStart(duration: Double, fade: Double) -> Double {
        max(0, duration - fade)
    }

    /// Equal-power gains at `progress` (0 at the start of the fade, 1 at the end). The two gains
    /// squared always add to 1, so two unrelated tracks keep a steady loudness through the fade.
    public static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let t = min(1, max(0, progress))
        return (Float(cos(t * .pi / 2)), Float(sin(t * .pi / 2)))
    }
}
