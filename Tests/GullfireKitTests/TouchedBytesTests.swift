import Foundation
import Testing
@testable import GullfireKit

/// A headless upper bound on what the GPU can have touched: the package bytes of every tile that has come within the
/// draw distance of the aircraft so far (no page ever given back, no view cone). Env-gated: GULLFIRE_TOUCH_MINUTES=N.
@Suite("Touched package bytes", .enabled(if: EnginePackages.available && ProcessInfo.processInfo.environment["GULLFIRE_TOUCH_MINUTES"] != nil))
struct TouchedBytesTests {
    @Test(arguments: EnginePackages.dirs) func logTouchedBytes(dir: URL) throws {
        let minutes = Double(ProcessInfo.processInfo.environment["GULLFIRE_TOUCH_MINUTES"] ?? "") ?? 10
        let limit = Float(DrawDistancePolicy.metres)
        let tiles = try #require(try CityPackage.open(directory: dir).manifest.tiles)
        let boxes = tiles.entries.map { e -> (SIMD3<Float>, SIMD3<Float>, Double) in
            let bytes = Double(e.solidCount) * 12 + Double(e.lines.reduce(0) { $0 + $1.count }) * 24
            return (SIMD3<Float>(Float(e.min[0]), 0, Float(e.min[1])), SIMD3<Float>(Float(e.max[0]), 0, Float(e.max[1])), bytes)
        }
        for seed in EnginePackages.seeds.prefix(3) {
            var touched = [Bool](repeating: false, count: boxes.count)
            var total = 0.0
            var nextLog = 0.0
            var obstacleMB = 0.0
            _ = try ChainFlight.fly(dir: dir, seed: seed, seconds: minutes * 60, sample: { s, t in
                // Horizontal distance (the tile boxes' height is ignored, a slight over-count).
                let p = SIMD3<Float>(Float(s.east), 0, Float(s.north))
                for i in boxes.indices where !touched[i] {
                    if LevelOfDetail.distance(from: p, toBoxMin: boxes[i].0, max: boxes[i].1) <= limit {
                        touched[i] = true
                        total += boxes[i].2
                    }
                }
                if t >= nextLog {
                    let n = touched.lazy.filter { $0 }.count
                    print(String(format: "TOUCH %@ seed %llu t=%4.0f s tiles %d bytes %.0f MB obstacles %.0f MB", dir.lastPathComponent, seed, t, n, total / 1e6, obstacleMB))
                    nextLog += 30
                }
            }, observe: { city in obstacleMB = Self.resident(city.obstacles) }, finish: { city in
                print(String(format: "RESIDENT %@ seed %llu | obstacles %.0f MB | solids %.0f MB | lines %.0f MB", dir.lastPathComponent, seed,
                             Self.resident(city.obstacles), Self.resident(city.solids), Self.resident(city.lines)))
            })
        }
    }

    /// Pages of a mapped file that are mapped into this process right now, in MB (what the process has touched).
    static func resident(_ data: Data) -> Double {
        data.withUnsafeBytes { raw -> Double in
            guard let base = raw.baseAddress else { return 0 }
            var address = mach_vm_address_t(UInt(bitPattern: base))
            var size: mach_vm_size_t = 0
            var info = vm_region_extended_info()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_extended_info>.size / MemoryLayout<Int32>.size)
            var object: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region(mach_task_self_, &address, &size, VM_REGION_EXTENDED_INFO, $0, &count, &object)
                }
            }
            return kr == KERN_SUCCESS ? Double(info.pages_resident) * 16384.0 / 1e6 : -1
        }
    }
}
