@_spi(Calibration) import BSSImageOptimizer
import Foundation

// vision-calibrate FILE... — prints Vision distance / aesthetics drop per JPEG quality (q0 = lossless).
let qualities = [0, 98, 95, 90, 85, 80, 75, 70, 60, 50, 35, 20, 10]
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    print("== \(url.lastPathComponent)")
    for r in try visionCalibration(fileAt: url, qualities: qualities) {
        print(String(format: "  q%-3d  ssim %.4f  tile %.4f  distance %.4f  drop %+.3f", r.quality, r.ssim, r.worstTile, r.distance, r.drop))
    }
}
