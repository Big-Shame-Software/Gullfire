import Foundation
import Testing
@testable import GullfireKit

/// Long headless soak of every cruise route (release plan B3): flies each route on autopilot for
/// GULLFIRE_SOAK_MINUTES of simulated flight, with no rendering. Records laps (crossings of the
/// route's start point), nudges, the lowest altitude, time outside the package box, and resident
/// memory at the start, at 30 minutes and at the end. Off unless the variable is set:
///
///     GULLFIRE_SOAK_MINUTES=60 swift test --filter RouteSoak
enum SoakSetting {
    static var minutes: Double? {
        ProcessInfo.processInfo.environment["GULLFIRE_SOAK_MINUTES"].flatMap(Double.init)
    }
    /// Memory is flat when the end resident size is within this many MB of the 30-minute size.
    static let flatThresholdMB = 5.0
}

@Suite("RouteSoak", .serialized, .enabled(if: SoakSetting.minutes != nil && PackageTests.built))
struct RouteSoak {
    static let routeNames = ["scenic", "river", "street-1", "street-2", "street-3", "street-4", "street-5", "street-6"]

    /// Resident size of this process in MB, from ps (no Mach globals, so it compiles in Swift 6 mode).
    static func residentMB() -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", "\(getpid())"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let kb = Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return kb / 1024
    }

    @Test(arguments: routeNames) func soak(name: String) throws {
        let minutes = try #require(SoakSetting.minutes)
        let city = try CityPackage.open(directory: PackageTests.chicago)
        let route = try Route.load(PackageTests.chicago.appendingPathComponent("routes/\(name).json"))
        let t = FlightTuning()
        let a = route.samples[0], b = route.samples[1]
        let start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        var sim = Simulation(start: start, tuning: t)
        var hint: Int? = 0
        var laps = 0
        let extent = city.manifest.extentM
        let steps = Int(minutes * 60 / t.fixedStep)
        let sampleEvery = Int(300 / t.fixedStep)   // memory sample every 5 simulated minutes
        var minAltitude = Double.infinity
        var minClearance = Double.infinity
        var maxBank = 0.0
        var outside = 0.0
        var samples: [(minute: Double, mb: Double)] = [(0, Self.residentMB())]
        for k in 1...steps {
            sim.advance(by: t.fixedStep, obstacles: city, extent: extent) { s, _ in
                let r = Autopilot.control(for: s, route: route, hint: hint, tuning: t)
                // The route index wraps from its end back to its start: one lap.
                if let h = hint, r.index < h - route.count / 2 { laps += 1 }
                hint = r.index
                return r.control
            }
            let s = sim.current
            minAltitude = min(minAltitude, s.altitude)
            minClearance = min(minClearance, s.altitude - Double(city.obstacleHeight(east: s.east, north: s.north)))
            maxBank = max(maxBank, abs(s.bank) * 180 / .pi)
            if s.east < extent.minEast || s.east > extent.maxEast || s.north < extent.minNorth || s.north > extent.maxNorth {
                outside += t.fixedStep
            }
            if k % sampleEvery == 0 {
                samples.append((Double(k) * t.fixedStep / 60, Self.residentMB()))
            }
        }
        let nudges = sim.nudges
        let rssEnd = Self.residentMB()
        let rss0 = samples[0].mb
        let rss30 = samples.first { $0.minute >= 30 }?.mb ?? rssEnd
        let drift = rssEnd - rss30
        let trail = samples.map { String(format: "%.0f", $0.mb) }.joined(separator: " ")
        print(String(format: "SOAK %@ | minutes %.0f | laps %d | nudges %d | min alt %.1f m (floor %.0f) | min clearance %.1f m | max bank %.1f deg | outside %.1f s | RSS start %.0f 30min %.0f end %.0f MB | drift 30min to end %+.1f MB | RSS every 5 min: %@",
                     name, minutes, laps, nudges, minAltitude, t.floor, minClearance, maxBank, outside, rss0, rss30, rssEnd, drift, trail))
        #expect(minAltitude >= t.floor)
        #expect(outside == 0)
        #expect(minClearance > 0)
        #expect(nudges == 0, "\(name) must fly with zero collision nudges (\(nudges))")
        #expect(abs(drift) <= SoakSetting.flatThresholdMB, "resident memory moved \(drift) MB between 30 minutes and the end")
        #expect(laps >= 2, "\(name) completed \(laps) laps in \(minutes) minutes")
    }
}
