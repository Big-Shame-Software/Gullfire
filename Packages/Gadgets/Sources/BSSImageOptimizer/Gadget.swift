import Foundation

/// How the Image Optimizer presents itself in an app: its name, a one-line credit and its pixel icon
/// (32 × 32, drawn on the Big Shame pixel grid; scale it by whole numbers with no smoothing).
public enum ImageOptimizerGadget {
    public static let name = "Image Optimizer"
    public static let credit = "Image Optimizer, a Big Shame Software gadget: the smallest JPEG or PNG that still matches the original."

    /// The icon at 1×, 2×, 4× or 8× (32, 64, 128 or 256 px).
    public static func iconURL(scale: Int = 4) -> URL? {
        let suffix = [1: "", 2: "@2x", 4: "@4x", 8: "@8x"][scale] ?? "@4x"
        return Bundle.module.url(forResource: "ImageOptimizer\(suffix)", withExtension: "png", subdirectory: "Resources")
    }
}
