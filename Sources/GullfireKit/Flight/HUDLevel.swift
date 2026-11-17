import Foundation

/// What H shows, in the order it cycles: nothing, the flight readout, then the flight readout with the
/// performance and session lines under it.
public enum HUDLevel: Sendable, Equatable {
    case off
    case flight
    case full

    /// The next state for H: off, flight, full, and back to off.
    public var next: HUDLevel {
        switch self {
        case .off: .flight
        case .flight: .full
        case .full: .off
        }
    }
}
