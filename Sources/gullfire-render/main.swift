import Foundation
import GullfireKit

// Headless stills, timing orbits and comparison sheets.
//
//   gullfire-render still   --view skyline|river|above --size WxH --palette default|brand --out FILE [--city DIR] [--no-hidden] [--no-cull] [--draw-distance M] [--lod d1,d2[,s]]
//   (still also takes --aircraft e,n,alt,headingDeg[,pitchDeg,bankDeg] [--model FILE] to draw the Gullfire glider)
//   gullfire-render walk    --line FILE.json --alt M [--start S] [--step M] [--frames N] [--glider] --size WxH --out DIR [--city DIR]
//   gullfire-render orbit   --size WxH --frames N [--palette default|brand] [--city DIR] [--no-cull] [--draw-distance M] [--lod d1,d2[,s]]
//   gullfire-render route   --route scenic|river --seconds N --size WxH [--city DIR] [--no-cull] [--draw-distance M] [--lod d1,d2[,s]]
//   gullfire-render compare --left FILE --right FILE --out FILE
//   gullfire-render fly     --script tower|--route scenic|river --seconds N --out PREFIX [--city DIR]

extension LevelOfDetail {
    /// Label for the timing lines, e.g. " (lod 1500.0,3000.0,0.0025)".
    var tag: String {
        minScreenFraction.map { " (lod \(d1),\(d2),\($0))" } ?? " (lod \(d1),\(d2))"
    }
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) {
        var iterator = arguments.makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("--") else { fail("unexpected argument \(token)", status: 2) }
            let name = String(token.dropFirst(2))
            if name == "no-hidden" || name == "no-cull" || name == "glider" {
                flags.insert(name)
            } else if let value = iterator.next() {
                values[name] = value
            } else {
                fail("missing value for --\(name)", status: 2)
            }
        }
    }

    func required(_ name: String) -> String {
        guard let value = values[name] else { fail("missing --\(name)", status: 2) }
        return value
    }

    func size() -> (Int, Int) {
        let parts = required("size").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { fail("--size must look like 2560x1440", status: 2) }
        return (parts[0], parts[1])
    }

    func palette() -> Palette {
        guard let name = values["palette"] else { return .standard }
        guard let palette = Palette(rawValue: name) else { fail("--palette must be default or brand", status: 2) }
        return palette
    }

    /// `--lod d1,d2[,s]` in metres, with the optional minimum screen fraction s (brief T4b). Absent means off.
    func lod() -> LevelOfDetail? {
        guard let text = values["lod"] else { return nil }
        let v = text.split(separator: ",").compactMap { Float($0) }
        guard v.count == 2 || v.count == 3, v[0] >= 0, v[0] <= v[1], v.count == 2 || v[2] > 0 else {
            fail("--lod must look like d1,d2 or d1,d2,s with 0 <= d1 <= d2 and s > 0", status: 2)
        }
        return LevelOfDetail(d1: v[0], d2: v[1], minScreenFraction: v.count == 3 ? v[2] : nil)
    }

    func city() -> URL {
        URL(fileURLWithPath: values["city"] ?? "Cities/Chicago", isDirectory: true)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: gullfire-render still|orbit|compare [options]", status: 2)
}
let options = Options(arguments.dropFirst())

do {
    switch command {
    case "still":
        // `--eye e,n,alt --look e,n,alt` places the camera by hand in the package frame;
        // the named views are Chicago's and are used when those are absent.
        func point(_ key: String) -> SIMD3<Float>? {
            guard let text = options.values[key] else { return nil }
            let v = text.split(separator: ",").compactMap { Float($0) }
            guard v.count == 3 else { fail("--\(key) must look like east,north,alt", status: 2) }
            return SIMD3(v[0], v[2], -v[1])   // render space: x east, y up, z minus north
        }
        let eye = point("eye"), look = point("look")
        let view: StillView
        if eye != nil || look != nil {
            guard eye != nil, look != nil else { fail("--eye and --look go together", status: 2) }
            view = .skyline
        } else {
            guard let named = StillView(rawValue: options.required("view")) else {
                fail("--view must be skyline, river or above", status: 2)
            }
            view = named
        }
        let (width, height) = options.size()
        let package = try CityPackage.open(directory: options.city())
        let frame = LocalFrame(lon0: package.manifest.origin.lon, lat0: package.manifest.origin.lat)
        let renderer = try Renderer(city: package, width: width, height: height)
        renderer.culling = !options.flags.contains("no-cull")
        renderer.drawDistance = options.values["draw-distance"].flatMap { Float($0) }
        renderer.levelOfDetail = options.lod()
        if let text = options.values["aircraft"] {
            let v = text.split(separator: ",").compactMap { Double($0) }
            guard v.count >= 4, v.count <= 6 else { fail("--aircraft must look like east,north,alt,headingDeg[,pitchDeg,bankDeg]", status: 2) }
            let modelURL = options.values["model"].map { URL(fileURLWithPath: $0) } ?? AircraftModel.locate()
            guard let modelURL else { fail("no aircraft model: pass --model FILE, for example Examples/example-glider.json", status: 1) }
            try renderer.loadAircraft(try AircraftModel.load(from: modelURL))
            let d = Double.pi / 180
            renderer.aircraft = AircraftPose(east: v[0], north: v[1], altitude: v[2], heading: v[3] * d,
                                             pitch: (v.count > 4 ? v[4] : 0) * d, bank: (v.count > 5 ? v[5] : 0) * d)
        }
        let camera = eye.flatMap { e in look.map { Camera(eye: e, target: $0) } } ?? view.camera(in: frame)
        // `--repeat N` renders the same frame N times and reports the last. The first frame of a
        // run also pays for paging in the mapped package, so a single frame is not a fair timing.
        let repeats = max(1, Int(options.values["repeat"] ?? "1") ?? 1)
        var gpu = 0.0
        var warm: [Double] = []
        for _ in 0..<repeats {
            gpu = try renderer.render(camera: camera, palette: options.palette(),
                                      drawHidden: !options.flags.contains("no-hidden"))
            warm.append(gpu * 1000)
        }
        if repeats > 1 {
            print(String(format: "first frame %.2f ms; later frames avg %.2f ms", warm[0],
                         warm.dropFirst().reduce(0, +) / Double(repeats - 1)))
        }
        print("tiles drawn \(renderer.lastTilesDrawn) of \(renderer.lastTilesTotal), segments drawn \(renderer.lastSegmentsDrawn)")
        let out = URL(fileURLWithPath: options.required("out"))
        try renderer.writePNG(to: out)
        print(String(format: "%@ %dx%d %@: gpu %.2f ms", eye == nil ? view.rawValue : "custom", width, height,
                     options.palette().rawValue, gpu * 1000))
        print("eye \(camera.eye)  target \(camera.target)")
        print("wrote \(out.path)")

    case "walk":
        // Frames from a camera that moves along a street's centre line (a JSON array of [east, north] points) at a fixed
        // altitude, looking 60 m ahead: what a flight at that height looks like, to compare floors side by side.
        let line = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: options.required("line"))))
        guard line.count >= 2 else { fail("--line needs at least two points", status: 2) }
        let alt = Float(options.required("alt")) ?? 15
        let start = Double(options.values["start"] ?? "0") ?? 0
        let step = Double(options.values["step"] ?? "1.2") ?? 1.2
        let frames = Int(options.values["frames"] ?? "400") ?? 400
        let (width, height) = options.size()
        let package = try CityPackage.open(directory: options.city())
        let renderer = try Renderer(city: package, width: width, height: height)
        renderer.culling = !options.flags.contains("no-cull")
        renderer.drawDistance = options.values["draw-distance"].flatMap { Float($0) }
        let outDir = URL(fileURLWithPath: options.required("out"), isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var cumulative = [0.0]
        for i in 1..<line.count {
            cumulative.append(cumulative[i - 1] + ((line[i][0] - line[i - 1][0]) * (line[i][0] - line[i - 1][0])
                                                     + (line[i][1] - line[i - 1][1]) * (line[i][1] - line[i - 1][1])).squareRoot())
        }
        func along(_ d: Double) -> (Double, Double) {
            let s = max(0, min(cumulative.last!, d))
            var i = 0
            while i < cumulative.count - 2 && cumulative[i + 1] < s { i += 1 }
            let f = cumulative[i + 1] > cumulative[i] ? (s - cumulative[i]) / (cumulative[i + 1] - cumulative[i]) : 0
            return (line[i][0] + (line[i + 1][0] - line[i][0]) * f, line[i][1] + (line[i + 1][1] - line[i][1]) * f)
        }
        // `--glider`: the camera follows the Gullfire glider like the app's close chase camera (16 m behind, 4.5 m above), and the
        // glider is drawn at the street point; otherwise the camera itself is at the point.
        let glider = options.flags.contains("glider")
        if glider {
            guard let url = AircraftModel.locate() else { fail("no aircraft model (Models/gullfire.json)", status: 1) }
            try renderer.loadAircraft(try AircraftModel.load(from: url))
        }
        for k in 0..<frames {
            let d = start + Double(k) * step
            let here = along(d), ahead = along(d + 60)
            var eye = SIMD3<Float>(Float(here.0), alt, -Float(here.1))
            var target = SIMD3<Float>(Float(ahead.0), alt - 0.5, -Float(ahead.1))
            if glider {
                let behind = along(d - 16), far = along(d + 120), next = along(d + 2)
                eye = SIMD3<Float>(Float(behind.0), alt + 4.5, -Float(behind.1))
                target = SIMD3<Float>(Float(far.0), alt - 1, -Float(far.1))
                renderer.aircraft = AircraftPose(east: here.0, north: here.1, altitude: Double(alt),
                                                 heading: atan2(next.0 - here.0, next.1 - here.1), pitch: 0, bank: 0)
            }
            _ = try renderer.render(camera: Camera(eye: eye, target: target), palette: options.palette(), drawHidden: true)
            try renderer.writePNG(to: outDir.appendingPathComponent(String(format: "f%05d.png", k)))
        }
        print("wrote \(frames) frames to \(outDir.path)")

    case "orbit":
        let (width, height) = options.size()
        let frames = Int(options.values["frames"] ?? "300") ?? 300
        let package = try CityPackage.open(directory: options.city())
        let renderer = try Renderer(city: package, width: width, height: height)
        renderer.culling = !options.flags.contains("no-cull")
        renderer.drawDistance = options.values["draw-distance"].flatMap { Float($0) }
        renderer.levelOfDetail = options.lod()
        let lodTag = renderer.levelOfDetail?.tag ?? ""
        var times: [Double] = []
        times.reserveCapacity(frames)
        var tiles = 0, segments = 0, calls = 0, encode = 0.0
        for i in 0..<frames {
            times.append(try renderer.render(camera: Orbit.camera(frame: i, of: frames), palette: options.palette()))
            tiles += renderer.lastTilesDrawn
            segments += renderer.lastSegmentsDrawn
            calls += renderer.lastDrawCalls
            encode += renderer.lastEncodeMs
        }
        let ms = times.map { $0 * 1000 }.sorted()
        let average = ms.reduce(0, +) / Double(ms.count)
        let p95 = ms[min(ms.count - 1, Int((Double(ms.count) * 0.95).rounded(.up)) - 1)]
        print(String(format: "orbit %d frames %dx%d%@%@: gpu avg %.2f ms  p95 %.2f ms  max %.2f ms",
                     frames, width, height, renderer.culling ? "" : " (no cull)", lodTag, average, p95, ms.last ?? 0))
        let n = Double(frames)
        print(String(format: "per frame: tiles drawn %.1f of %d, segments drawn %.0f, draw calls %.1f, encode %.3f ms",
                     Double(tiles) / n, renderer.lastTilesTotal, Double(segments) / n, Double(calls) / n, encode / n))
    case "route":
        // Flies the route on the autopilot, as `fly --route` does, and renders one frame every 1/30 s of
        // simulated time with the app's chase camera (App/MetalView.swift).
        let (width, height) = options.size()
        let seconds = Double(options.values["seconds"] ?? "120") ?? 120
        let package = try CityPackage.open(directory: options.city())
        let routeName = options.required("route")
        let route = try Route.load(options.city().appendingPathComponent("routes/\(routeName).json"))
        var states: [FlightState] = []
        var nextFrame = 0.0
        let flight = FlightScript.routeFlight(city: package, route: route, seconds: seconds) { state, t in
            if t + 1e-9 >= nextFrame {
                states.append(state)
                nextFrame += 1.0 / 30
            }
        }
        print("route \(route.name), autopilot, \(states.count) frames")
        print(flight.summaryLines.joined(separator: "\n"))
        let renderer = try Renderer(city: package, width: width, height: height)
        renderer.culling = !options.flags.contains("no-cull")
        renderer.drawDistance = options.values["draw-distance"].flatMap { Float($0) }
        renderer.levelOfDetail = options.lod()
        let lodTag = renderer.levelOfDetail?.tag ?? ""
        var chase = ChaseCamera()
        var times: [Double] = []
        times.reserveCapacity(states.count)
        var tiles = 0, segments = 0, calls = 0, encode = 0.0
        for state in states {
            let camera = chase.update(state, dt: 1.0 / 30, reduceMotion: false)
            times.append(try renderer.render(camera: camera, palette: options.palette()))
            tiles += renderer.lastTilesDrawn
            segments += renderer.lastSegmentsDrawn
            calls += renderer.lastDrawCalls
            encode += renderer.lastEncodeMs
        }
        let ms = times.map { $0 * 1000 }.sorted()
        let average = ms.reduce(0, +) / Double(ms.count)
        let p95 = ms[min(ms.count - 1, Int((Double(ms.count) * 0.95).rounded(.up)) - 1)]
        print(String(format: "route %@ %dx%d%@%@: gpu avg %.2f ms  p95 %.2f ms  max %.2f ms",
                     routeName, width, height, renderer.culling ? "" : " (no cull)", lodTag, average, p95, ms.last ?? 0))
        let n = Double(states.count)
        print(String(format: "per frame: tiles drawn %.1f of %d, segments drawn %.0f, draw calls %.1f, encode %.3f ms",
                     Double(tiles) / n, renderer.lastTilesTotal, Double(segments) / n, Double(calls) / n, encode / n))

    case "compare":
        let left = URL(fileURLWithPath: options.required("left"))
        let right = URL(fileURLWithPath: options.required("right"))
        let out = URL(fileURLWithPath: options.required("out"))
        try Image.sideBySide(left: left, right: right, to: out)
        print("wrote \(out.path)")

    case "fly":
        let package = try CityPackage.open(directory: options.city())
        let seconds = Double(options.values["seconds"] ?? "60") ?? 60
        let prefix = options.required("out")
        if let routeName = options.values["route"] {
            let routeURL = options.city().appendingPathComponent("routes/\(routeName).json")
            let route = try Route.load(routeURL)
            let result = FlightScript.routeFlight(city: package, route: route, seconds: seconds)
            print("route \(route.name), autopilot")
            print(result.summaryLines.joined(separator: "\n"))
            let track = TrackPlot.render(track: result.track, centre: (0, 0), halfSize: max(package.manifest.extentM.maxEast, package.manifest.extentM.maxNorth) + 200, marker: nil, size: 1024)
            try Image.writePNG(bgra: track, width: 1024, height: 1024, to: URL(fileURLWithPath: prefix + "_track.png"))
            print("wrote \(prefix)_track.png")
            let side = ProfilePlot.render(points: result.profile, width: 2048, height: 512)
            try Image.writePNG(bgra: side, width: 2048, height: 512, to: URL(fileURLWithPath: prefix + "_profile.png"))
            print("wrote \(prefix)_profile.png")
            break
        }
        guard options.required("script") == "tower" else { fail("only --script tower or --route exists", status: 2) }
        let tower = try package.landmarks().first { $0.name == "Willis Tower" }
        guard let tower else { fail("no Willis Tower in landmarks.json", status: 1) }
        let ground = try FlightScript.towerApproach(city: package, tower: tower, seconds: seconds)
        print(ground.summaryLines.joined(separator: "\n"))
        let track = TrackPlot.render(track: ground.track, centre: (tower.east, tower.north), halfSize: 1500,
                                     marker: (tower.east, tower.north), size: 1024)
        try Image.writePNG(bgra: track, width: 1024, height: 1024, to: URL(fileURLWithPath: prefix + "_track.png"))
        print("wrote \(prefix)_track.png")

    default:
        fail("unknown command \(command)", status: 2)
    }
} catch {
    fail("gullfire-render: \(error)")
}
