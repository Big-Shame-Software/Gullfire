import AppKit
import GullfireKit
import Metal
import MetalKit
import QuartzCore
import SwiftUI

/// Drives the flight view: one frame per display refresh. Each frame it reads the pilot's input,
/// advances the simulation, follows the aircraft with the chase camera, and draws. It runs on the
/// main actor, as the window does.
@MainActor
final class FlightRenderer: NSObject, MTKViewDelegate {
    private let model: AppModel
    private let renderer: Renderer
    private let city: CityPackage
    private let frame: LocalFrame
    private let input: FlightInput
    private var simulation: Simulation
    private var chase = ChaseCamera()
    /// The Gullfire glider model is loaded (it is private, so it may be absent). The glider is drawn only when G has turned it on.
    private var gliderAvailable = false
    private var showsAircraft = false
    /// The two cruise routes (Scenic, River), in the order C cycles them.
    private let routes: [Route]
    /// The flight tuning. `GULLFIRE_FLOOR=10` (metres, 5 or more) lowers the floor and the avoidance clearance together, for
    /// flying the street routes lower; unset it is the usual 15 m.
    private let tuning: FlightTuning
    private var routeIndex = 0
    /// The file name of each route in `routes` (scenic, river, street-1, ...), for GULLFIRE_ROUTE.
    private var routeKeys: [String] = []
    private var pilot: Pilot
    private var autopilotHint: Int?
    /// The height the autopilot flies above (or below) the route, in metres: T raises it, V lowers it. Reset on a route change.
    private var heightOffset: Double = 0
    /// A hand-back below the roofs in progress (nil otherwise).
    private var handBack: HandBack?
    private var lastSimTime: Double?
    private var lastHUD = 0.0
    private var lastFrameTime: Double?
    private var windowStart = CACurrentMediaTime()
    private var windowFrames = 0
    private var windowWorst = 0.0
    private var recentGPU: [Double] = []
    private var lastPublish = 0.0
    private var lastFootprint = 0.0
    private var firstFrameMarked = false
    /// The launch hint (D6): the route list with its hint line, shown once. Waits for full screen to settle
    /// when the window is going full screen, so the switch does not use up the hold.
    private var launchHintPending = true
    private var fullScreenSettled = false
    /// When the first frame was presented (seconds, the frame clock), for the launch hint's wait.
    private var firstFrameAt: Double?
    /// The flight window, set when the view joins it, so the launch announcement goes to this window and not to whatever is key.
    weak var window: NSWindow?

    init(model: AppModel, city: CityPackage, view: MTKView, input: FlightInput, width: Int, height: Int) throws {
        self.model = model
        self.city = city
        self.input = input
        renderer = try Renderer(city: city, width: width, height: height, offscreen: false,
                                checkpoint: { name in MainActor.assumeIsolated { model.timing.checkpoint(name) } })
        // The wireframe glider: drawn and followed closely when the model file is there; without it the app
        // is as before (nothing drawn, the distant camera).
        if let glider = AircraftModel.installed(), (try? renderer.loadAircraft(glider)) != nil {
            gliderAvailable = true
            model.hasGlider = true
            model.timing.checkpoint("aircraft model loaded (\(glider.name))")
        }
        // Test hook for the tiles runs: GULLFIRE_NO_CULL=1 draws every tile.
        if ProcessInfo.processInfo.environment["GULLFIRE_NO_CULL"] == "1" { renderer.culling = false }
        // A draw distance for a very large package: 5 km when the package is over 200 km², else none.
        // GULLFIRE_DRAW_DISTANCE=metres overrides it (0 turns it off).
        let extent = city.manifest.extentM
        let areaKm2 = (extent.maxEast - extent.minEast) * (extent.maxNorth - extent.minNorth) / 1e6
        if let text = ProcessInfo.processInfo.environment["GULLFIRE_DRAW_DISTANCE"], let metres = Float(text) {
            renderer.drawDistance = metres > 0 ? metres : nil
        } else if areaKm2 > 200 {
            renderer.drawDistance = 5000
        }
        // Test hook for level of detail: GULLFIRE_LOD=d1,d2[,s] in metres, with the
        // optional minimum screen fraction s. Off by default.
        if let text = ProcessInfo.processInfo.environment["GULLFIRE_LOD"] {
            let v = text.split(separator: ",").compactMap { Float($0) }
            if v.count == 2 || v.count == 3, v[0] >= 0, v[0] <= v[1], v.count == 2 || v[2] > 0 {
                renderer.levelOfDetail = LevelOfDetail(d1: v[0], d2: v[1], minScreenFraction: v.count == 3 ? v[2] : nil)
            }
        }
        for milestone in renderer.startupTimes { model.timing.mark(milestone.name, at: milestone.t) }
        model.timing.drawableSize = "\(width)x\(height)"
        if let layer = view.layer as? CAMetalLayer { renderer.attach(layer: layer) }
        frame = LocalFrame(lon0: city.manifest.origin.lon, lat0: city.manifest.origin.lat)
        // The routes come from the package. Without them the app flies manually only.
        let dir = city.directory.appendingPathComponent("routes", isDirectory: true)
        // Scenic and River, then any street routes the route maker wrote (street-1.json, street-2.json, ...), in the
        // order C cycles them.
        let streetNames = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("street-") && $0.hasSuffix(".json") && !$0.hasSuffix(".report.json") }
            .map { String($0.dropLast(5)) }
            .sorted { (Int($0.dropFirst(7)) ?? 0) < (Int($1.dropFirst(7)) ?? 0) }
        // The routes in the order C cycles them: Scenic, River, then the street routes by number.
        let keys = ["scenic", "river"] + streetNames
        let loaded = keys.compactMap { key in (try? Route.load(dir.appendingPathComponent("\(key).json"))).map { (key, $0) } }
        routes = loaded.map { $0.1 }
        routeKeys = loaded.map { $0.0 }
        var flightTuning = FlightTuning()
        if let f = ProcessInfo.processInfo.environment["GULLFIRE_FLOOR"].flatMap(Double.init), f >= 5 {
            flightTuning.floor = f
            flightTuning.clearance = f
        }
        tuning = flightTuning
        // Start in cruise on Scenic, at the route's first sample.
        pilot = Pilot(mode: routes.isEmpty ? .manual : .auto)
        // Test hook for the M6 runs: GULLFIRE_ROUTE=river starts on River instead of Scenic.
        // GULLFIRE_ROUTE names the route to start on: scenic, river, or street-1, street-2, ... (a test hook; C cycles as before).
        if let name = ProcessInfo.processInfo.environment["GULLFIRE_ROUTE"], let i = routeKeys.firstIndex(of: name) { routeIndex = i }
        let startRoute = routes.indices.contains(routeIndex) ? routes[routeIndex] : nil
        let first = startRoute?.samples.first
        let second = startRoute.flatMap { $0.samples.count > 1 ? $0.samples[1] : nil }
        let start: FlightState
        if let a = first, let b = second {
            start = FlightState(east: a.east, north: a.north, altitude: a.altitude,
                                heading: atan2(b.east - a.east, b.north - a.north), speed: a.speed)
        } else {
            // No routes: start over the package origin, whichever city this is.
            start = FlightState(east: 0, north: 0, altitude: 350, heading: 0,
                                speed: 85 * FlightTuning.knotsToMetresPerSecond)
        }
        simulation = Simulation(start: start, tuning: flightTuning)
        super.init()
    }

    /// Level off (R): bank and pitch to zero at once.
    /// G: the glider on or off. On, it is drawn and the camera follows it close; off, the distant view of the aircraft.
    func toggleGlider() {
        guard gliderAvailable else { return }
        showsAircraft.toggle()
        chase = showsAircraft ? .close : ChaseCamera()
    }

    func levelOff() {
        simulation.levelOff()
    }

    /// J turning the mouse on: hand flying, so leave cruise (the autopilot ignores the mouse).
    func handFly() {
        if pilot.mode == .auto { toggleCruise() }
    }

    /// Space: toggle cruise and manual. Manual to cruise blends over 3 s.
    func toggleCruise() {
        guard !routes.isEmpty else { return }
        pilot.toggle()
        // Manual to cruise below the roofs (in a street): climb out and rejoin over the roofs, not straight across the
        // blocks. Above the roofs this is nil and nothing changes.
        handBack = pilot.mode == .auto ? Autopilot.startHandBack(simulation.current, obstacles: city) : nil
        if handBack != nil { autopilotHint = nil }
    }

    /// C: switch between Scenic and River. The autopilot searches the whole route once.
    func cycleRoute() {
        guard routes.count > 1 else { return }
        routeIndex = (routeIndex + 1) % routes.count
        autopilotHint = nil
        heightOffset = 0
        showRouteList()
    }

    /// T and V: the autopilot's height above the route, in steps of 10 m, between -60 and +120 m.
    func stepHeight(_ delta: Double) {
        heightOffset = min(max(heightOffset + delta, -60), 120)
    }

    /// The route list (D1): every route with its loop length, shown for 4 s after the press, and announced to VoiceOver.
    private func showRouteList() {
        let now = CACurrentMediaTime()
        var list = model.routeList ?? RouteList(items: routes.map { RouteList.Item(name: $0.name, lengthKm: $0.length / 1000) })
        list.show(current: routeIndex, at: now, inManual: pilot.mode == .manual)
        model.routeList = list
        if let window = NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: list.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Whether the window is going to full screen at launch: FlightView does that unless GULLFIRE_WINDOWED is set,
    /// and the Debug capture hook never does.
    static var launchGoesFullScreen: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["GULLFIRE_WINDOWED"] != nil { return false }
        #if DEBUG
        if env["GULLFIRE_SNAPSHOT_TO"] != nil { return false }
        #endif
        return true
    }

    /// Called when the window has finished entering full screen (from MetalView).
    func windowFinishedFullScreen() {
        fullScreenSettled = true
    }

    /// The launch hint (D6, D7): the route list with its hint line, held and faded as after C, and announced at low
    /// priority so it waits for the user rather than cutting across the window. Shown once, on the first frame after the
    /// window has settled.
    private func showLaunchHintIfReady(now: Double) {
        guard launchHintPending, !routes.isEmpty, let firstFrameAt else { return }
        guard RouteList.launchHintDue(fullScreenSettled: fullScreenSettled, goesFullScreen: Self.launchGoesFullScreen,
                                      secondsSinceFirstFrame: now - firstFrameAt) else { return }
        launchHintPending = false
        var list = model.routeList ?? RouteList(items: routes.map { RouteList.Item(name: $0.name, lengthKm: $0.length / 1000) })
        var shownAt = now
        #if DEBUG
        // D8: the Debug capture keeps the hint up, so it can be checked by eye in a capture.
        if ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_TO"] != nil { shownAt += 3600 }
        #endif
        list.show(current: routeIndex, at: shownAt, inManual: pilot.mode == .manual)
        model.routeList = list
        // The flight window, not whatever is key; NSApp when the view has no window (D7 follow-up).
        let target: Any = window.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(element: target, notification: .announcementRequested,
                             userInfo: [.announcement: list.launchAnnouncement, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    /// The mode line: manual, cruise on the current route, or a hand-over in progress.
    private func modeLine() -> String {
        switch pilot.mode {
        case .manual:
            return "FLIGHT MODE MANUAL"
        case .auto:
            let name = routes.isEmpty ? "" : routes[routeIndex].name.uppercased()
            if pilot.blend < 1 { return "MANUAL → AUTO" }
            return "FLIGHT MODE CRUISE — \(name)"
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { self.resize(view, to: size) }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { self.drawFrame(view) }
    }

    /// Sets the drawable to the window's pixel size times the render scale, and resizes the renderer
    /// when either changes. Checked every frame, so window moves take effect.
    private func applyDrawableSize(_ view: MTKView) {
        let scale = view.window?.backingScaleFactor ?? 2
        let size = model.renderScale.pixelSize(pointWidth: Double(view.bounds.width),
                                               pointHeight: Double(view.bounds.height),
                                               backingScale: Double(scale))
        guard size.width != renderer.width || size.height != renderer.height else { return }
        model.timing.checkpoint("drawable resize begins to \(size.width)x\(size.height)")
        model.timing.drawableSize = "\(size.width)x\(size.height)"
        view.drawableSize = CGSize(width: size.width, height: size.height)
        do { try renderer.resize(width: size.width, height: size.height) } catch { model.problem = "\(error)" }
        model.timing.checkpoint("drawable resize done")
    }

    private func resize(_ view: MTKView, to size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        do { try renderer.resize(width: w, height: h) } catch { model.problem = "\(error)" }
    }

    private func drawFrame(_ view: MTKView) {
        let entered = CACurrentMediaTime()
        defer { model.timing.recordDraw(ms: (CACurrentMediaTime() - entered) * 1000) }
        applyDrawableSize(view)
        let drawableStart = CACurrentMediaTime()   // measurement only
        guard let drawable = view.currentDrawable else { return }
        let drawableMs = (CACurrentMediaTime() - drawableStart) * 1000
        // The layer can still hand out a drawable of the previous size for a frame after a resize.
        // Encoding a pass with mismatched sizes is invalid (Metal validation: "texture and
        // resolveTexture size mismatch"), so skip that frame.
        guard drawable.texture.width == renderer.width && drawable.texture.height == renderer.height else { return }
        model.timing.recordWaits(drawableMs: drawableMs, inflightMs: renderer.lastInflightWaitMs,
                                 focused: (view.window?.isKeyWindow ?? false),
                                 visible: (view.window?.occlusionState.contains(.visible) ?? true))
        let now = CACurrentMediaTime()
        model.timing.recordFrame(at: now)

        // Fixed-step simulation, fed by the pilot's input for this frame.
        let dt = lastSimTime.map { min(0.1, now - $0) } ?? 0
        lastSimTime = now
        let manual = input.control(dt: dt)
        let routeNow: Route? = routes.isEmpty ? nil : routes[routeIndex]
        simulation.advance(by: dt, obstacles: city, extent: city.manifest.extentM) { s, stepDt in
            // Each fixed step: the autopilot sees the state it is flying from, and the pilot blends.
            pilot.advance(dt: stepDt)
            guard let route = routeNow else { return manual }
            // A hand-back in progress replaces the pilot's input: the autopilot climbs out of the street first.
            if handBack != nil, pilot.mode == .auto,
               let r = Autopilot.handBackControl(for: s, route: route, obstacles: city, state: &handBack, tuning: tuning) {
                autopilotHint = r.index
                return r.control
            }
            let auto = Autopilot.control(for: s, route: route, hint: autopilotHint, tuning: tuning,
                                         heightOffset: heightOffset, obstacles: city)
            autopilotHint = auto.index
            return pilot.blended(manual: manual, auto: auto.control)
        }
        let state = simulation.interpolated()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let camera = chase.update(state, dt: dt, reduceMotion: reduceMotion)
        renderer.aircraft = showsAircraft ? AircraftPose(state) : nil

        var gpu = 0.0
        do {
            gpu = try renderer.render(camera: camera, palette: model.palette, drawable: drawable)
        } catch {
            model.problem = "\(error)"
            model.timing.recordGPUError("\(error)")
            return
        }

        if let last = lastFrameTime {
            windowWorst = max(windowWorst, (now - last) * 1000)
            model.session.worstFrameMs = max(model.session.worstFrameMs, (now - last) * 1000)
        }
        model.timing.recordGPU(ms: gpu * 1000)
        model.timing.recordTiles(drawn: renderer.lastTilesDrawn, total: renderer.lastTilesTotal,
                                 segments: renderer.lastSegmentsDrawn)
        if !firstFrameMarked {
            firstFrameMarked = true
            firstFrameAt = now
            model.timing.mark("first frame presented")
            model.timing.checkpoint("mark 6 first frame presented")
        }
        showLaunchHintIfReady(now: now)
        lastFrameTime = now
        windowFrames += 1
        model.session.frames += 1
        model.session.gpuTotal += gpu
        recentGPU.append(gpu)
        if recentGPU.count > 60 { recentGPU.removeFirst() }

        // HUD text at 10 Hz, as the HUD design asks. Performance numbers at the same rate.
        if now - lastPublish >= 0.1 {
            let window = now - windowStart
            var perf = model.perf
            perf.fps = window > 0 ? Double(windowFrames) / window : 0
            perf.frameWorstMs = windowWorst
            perf.gpuMs = recentGPU.reduce(0, +) / Double(max(1, recentGPU.count)) * 1000
            if now - lastFootprint >= 1 {
                let mb = Footprint.megabytes()
                perf.footprintMB = mb
                model.session.peakFootprintMB = max(model.session.peakFootprintMB, mb)
                lastFootprint = now
            }
            perf.resolution = "\(renderer.width)x\(renderer.height)"
            model.perf = perf

            let geo = frame.coordinates(east: state.east, north: state.north)
            model.hud = HUDReadout(mode: modeLine(),
                                   altitudeFt: state.altitude * 3.280_84,
                                   speedKt: state.speed / FlightTuning.knotsToMetresPerSecond,
                                   headingDeg: wrapTau(state.heading) * 180 / Double.pi,
                                   latitude: geo.lat, longitude: geo.lon,
                                   proximityWarning: simulation.proximityWarning,
                                   boundaryWarning: simulation.boundaryWarning,
                                   cruising: pilot.mode == .auto && pilot.blend >= 1,
                                   heightOffsetM: heightOffset)
            windowStart = now
            windowFrames = 0
            windowWorst = 0
            lastPublish = now
        }
        lastHUD = now
    }
}

/// Hosts the flight view. The view pauses while its window is hidden or minimised.
struct MetalView: NSViewRepresentable {
    let model: AppModel

    @MainActor
    final class Coordinator {
        var flight: FlightRenderer?
        var input: FlightInput?
        var observedWindow: NSWindow?
        var occlusion: NSObjectProtocol?
        var fullScreen: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FlightMTKView {
        let view = FlightMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        // The drawable size follows the render scale, so it is set by hand (see drawFrame).
        view.autoResizeDrawable = false
        // Three drawables, as before: 60 fps needs them.
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 3
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Flight view")
        let input = FlightInput()
        input.model = model
        context.coordinator.input = input
        view.input = input
        view.model = model
        view.onWindowChange = { [coordinator = context.coordinator, weak view] in
            if let view { self.attach(view, coordinator: coordinator) }
        }
        view.onAction = { [weak model, weak view] key in
            MainActor.assumeIsolated {
                guard let model else { return }
                switch key {
                case "b": model.cyclePalette()
                case "p": model.showPerformance.toggle()
                case "h": model.cycleHUD()
                case "k": model.showKeys.toggle()
                case "g": model.flight?.toggleGlider()
                case "f":
                    model.timing.checkpoint("key F: toggle full screen")
                    NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                case "r": model.flight?.levelOff()
                case "c": model.flight?.cycleRoute()
                case "t": model.flight?.stepHeight(10)
                case "v": model.flight?.stepHeight(-10)
                case "space": model.flight?.toggleCruise()
                case "n": model.nextTrack()
                case "m": model.toggleMusic()
                case ",": model.togglePause()
                case "j":
                    if view?.input?.mouseOn == false { model.flight?.handFly() }
                    view?.toggleMouse()
                default: break
                }
            }
        }
        if let city = model.city, view.device != nil {
            do {
                let flight = try FlightRenderer(model: model, city: city, view: view, input: input,
                                                width: 1280, height: 720)
                context.coordinator.flight = flight
                model.flight = flight
                view.delegate = flight
                #if DEBUG
                // Test hooks for the route list screenshots, Debug builds only: GULLFIRE_HUD_AT_LAUNCH=1 starts with the
                // HUD on, and GULLFIRE_CYCLE_AT=<seconds> presses C once after that many seconds (as the key would).
                if ProcessInfo.processInfo.environment["GULLFIRE_HUD_AT_LAUNCH"] == "1" { model.showHUD = true }
                if let seconds = ProcessInfo.processInfo.environment["GULLFIRE_CYCLE_AT"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { flight.cycleRoute() }
                }
                #endif
            } catch {
                model.problem = "Could not start the renderer: \(error)"
            }
        }
        return view
    }

    func updateNSView(_ view: FlightMTKView, context: Context) {
        attach(view, coordinator: context.coordinator)
    }

    /// The flight view is being torn down: the mouse must not stay taken.
    static func dismantleNSView(_ view: FlightMTKView, coordinator: Coordinator) {
        view.releaseMouse()
    }

    /// Installs the occlusion pause once the view has a window. Called from the view's
    /// `viewDidMoveToWindow` (updateNSView alone can run before the view has a window and then
    /// never again, so the pause was never installed) and from updateNSView.
    private func attach(_ view: FlightMTKView, coordinator: Coordinator) {
        guard let window = view.window, coordinator.observedWindow !== window else { return }
        coordinator.observedWindow = window
        coordinator.flight?.window = window
        window.makeFirstResponder(view)
        coordinator.occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak view, weak window] _ in
            MainActor.assumeIsolated {
                guard let view, let window else { return }
                let paused = !window.occlusionState.contains(.visible)
                if view.isPaused != paused {
                    view.isPaused = paused
                    model.timing.viewPausedChanged(paused: paused)
                    model.windowVisibilityChanged(visible: !paused)
                    model.timing.checkpoint("isPaused becomes \(paused)")
                }
            }
        }
        // The launch hint waits for full screen to settle (D6). A window already in full screen (restored) is settled now.
        coordinator.fullScreen = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.flight?.windowFinishedFullScreen() }
        }
        if window.styleMask.contains(.fullScreen) { coordinator.flight?.windowFinishedFullScreen() }
        view.isPaused = !window.occlusionState.contains(.visible)
        scheduleTestHide(view: view)
        // Test only: a window restored in full screen, in a Space that is not showing, stays
        // hidden (and so paused) when launched from a script. Launching from Finder activates.
        if ProcessInfo.processInfo.environment["GULLFIRE_ACTIVATE"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
        }
        model.timing.checkpoint("window attached, isPaused \(view.isPaused), occlusion \(window.occlusionState.rawValue), key \(window.isKeyWindow), app active \(NSApp.isActive)")
    }

    /// Test only. `GULLFIRE_TEST_HIDE="<hideSec>,<showSec>"` hides the app at the first time and
    /// shows it again at the second, to check the pause when hidden and the resume (like
    /// `GULLFIRE_ROUTE`, it changes nothing when unset). `GULLFIRE_TEST_HIDE_MODE=miniaturize`
    /// uses the window's miniaturize instead of hiding the app.
    private func scheduleTestHide(view: FlightMTKView) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["GULLFIRE_TEST_HIDE"] else { return }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, !Self.testHideScheduled else { return }
        Self.testHideScheduled = true
        let mini = env["GULLFIRE_TEST_HIDE_MODE"] == "miniaturize"
        let timing = model.timing
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(parts[0]))
            timing.checkpoint("test hide called, isPaused \(view?.isPaused ?? false)")
            if mini { view?.window?.miniaturize(nil) } else { NSApp.hide(nil) }
            try? await Task.sleep(for: .seconds(0.5))
            timing.checkpoint("test hide 0.5 s later, isPaused \(view?.isPaused ?? false), occlusion \(view?.window?.occlusionState.rawValue ?? 0)")
            try? await Task.sleep(for: .seconds(max(0, parts[1] - parts[0] - 0.5)))
            timing.checkpoint("test show called, isPaused \(view?.isPaused ?? false)")
            if mini { view?.window?.deminiaturize(nil) } else { NSApp.unhide(nil) }
            NSApp.activate(ignoringOtherApps: true)
            view?.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            timing.checkpoint("test show 0.5 s later, isPaused \(view?.isPaused ?? false), occlusion \(view?.window?.occlusionState.rawValue ?? 0)")
        }
    }
    private static var testHideScheduled = false
}
