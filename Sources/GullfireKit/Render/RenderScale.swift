import Foundation

/// How many pixels the window renders, as a share of its full resolution.
///
/// `native` is the window's full pixel count (5760 x 3240 on the owner's 5K display). It is the
/// default. `half` renders a quarter of the pixels and lets the system scale the picture up, which
/// costs about a quarter of the memory and GPU time.
public enum RenderScale: String, CaseIterable, Sendable {
    case native
    case half

    public var factor: Double {
        switch self {
        case .native: 1
        case .half: 0.5
        }
    }

    public var toggled: RenderScale {
        self == .native ? .half : .native
    }

    /// Drawable pixel size for a view of `pointWidth` by `pointHeight` points on a display with
    /// `backingScale` pixels per point, at this scale. Never returns less than 1 x 1.
    public func pixelSize(pointWidth: Double, pointHeight: Double, backingScale: Double) -> (width: Int, height: Int) {
        let w = Int((pointWidth * backingScale * factor).rounded())
        let h = Int((pointHeight * backingScale * factor).rounded())
        return (max(1, w), max(1, h))
    }
}
