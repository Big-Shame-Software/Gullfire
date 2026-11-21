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
    /// Endless flight (U). `endless` is the loop source; nil means endless is off. `endlessRoute` and `endlessPlan` are the
    /// loop being flown (nil until the first loop is built). `endlessPending` is the next loop, built from `endlessPlan`
    /// so it starts where the aircraft will be at the swap point. `swapTrigger` fires when the route index reaches the
    /// swap point; then the pending loop takes over. `buildingNext` is true while a build runs for the current
    /// `endlessGeneration`; U and OFF change the generation, so a build that finishes after a change is thrown away.
    private var endless: EndlessFlight?
    private var endlessRoute: Route?
    private var endlessPlan: RoutePlan?
    private var endlessPending: (route: Route, plan: RoutePlan, label: String)?
    private var endlessLabel = ""
    private var swapTrigger = SwapTrigger(swapIndex: 0, count: 1)
    private var buildingNext = false
    private var endlessGeneration = 0
    /// How many loops have been flown this run, for the HUD (the route's own name carries the seed offset, which jumps).
    private var endlessCount = 0
    /// After a forced hand-back onto a street loop ends, the aircraft flies high for a minute and settles onto the route.
    private var entryPending = false
    private var entryClock: Double?
    /// Pick mode (I): the street under the pointer is flown on a click. `lastCamera` is the last frame's camera, which the
    /// pick ray uses. `streetGraph` is loaded the first time it is needed. `pickTarget` is the picked street and its label,
    /// for the JOINING / ON line; it is cleared at the first swap to a new loop. `pickBuilding` is true while the first loop
    /// of a pick is built off the main thread.
    private var lastCamera = Camera(eye: SIMD3(0, 100, 0), target: SIMD3(0, 0, -1))
    private var streetGraph: StreetGraph?
    private var streetGraphLoaded = false
    private var pickTarget: (stretch: StreetStretch, label: String)?
    private var pickBuilding = false
    /// Pick-mode street overlays (updatePickOverlays). `pickAvailable` is the nearby streets' segments at 4 m, rebuilt when
    /// pick mode starts or the aircraft has moved 500 m from `pickAvailableCentre`. `pickHoverIndex` and `pickHoverSegments`
    /// are the street under the pointer at 5 m (nil and empty when none). `pickedLabel` and `pickedSegments`
    /// is the street flown by the last pick (its label and its segments at 6 m); they stay until I or Esc leaves pick mode.
    private var pickAvailable: [Float] = []
    private var pickAvailableCentre: SIMD2<Double>?
    private var pickHoverIndex: Int?
    private var pickHoverSegments: [Float] = []
    private var pickedLabel: String?
    private var pickedSegments: [Float] = []
    /// The Metal view, which takes the mouse off for pick mode the way J does (see togglePick).
    weak var mouseView: FlightMTKView?
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
        let loaded = keys.compactMap { key in (try? Route.load(dir.appendingPathComponent("\(key).json"))).map { (key, $0.preparedIfStreet(obstacles: city)) } }
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
        manualAltTarget = nil
        pilot.toggle()
        // Manual to cruise below the roofs (in a street): climb out and rejoin over the roofs, not straight across the
        // blocks. Above the roofs this is nil and nothing changes.
        handBack = pilot.mode == .auto ? Autopilot.startHandBack(simulation.current, obstacles: city) : nil
        if handBack != nil { autopilotHint = nil }
    }

    /// The seed for a new endless run: GULLFIRE_ENDLESS_SEED in a test run, else a random one.
    private static func newEndlessSeed() -> UInt64 {
        ProcessInfo.processInfo.environment["GULLFIRE_ENDLESS_SEED"].flatMap { UInt64($0) }
            ?? UInt64.random(in: 1...999_999)
    }

    /// U: endless flight on or off. On, the aircraft flies loops of the package's streets, each built in the background
    /// while the last one is flown. Off, it goes back to the package's routes.
    func toggleEndless() {
        if endless != nil { endlessOff(); return }
        guard let flight = EndlessFlight(city: city, seed: Self.newEndlessSeed()) else {
            showNotice("ENDLESS: NO STREET GRAPH IN THIS PACKAGE")
            return
        }
        // Endless starts from cruise, so the hand-back can climb out of a street first.
        if pilot.mode == .manual { toggleCruise() }
        endless = flight
        endlessGeneration += 1
        buildLoop(from: flight, after: nil)
    }

    /// U again, or C: endless off. The aircraft returns to the package's routes, climbing out of a street first if it is in one.
    private func endlessOff() {
        endless = nil
        endlessRoute = nil
        endlessPlan = nil
        endlessPending = nil
        endlessLabel = ""
        endlessCount = 0
        pickTarget = nil
        buildingNext = false
        endlessGeneration += 1
        autopilotHint = nil
        handBack = pilot.mode == .auto ? Autopilot.startHandBack(simulation.current, obstacles: city) : nil
    }

    /// Builds a loop from `flight` off the main thread, unless a build is already running. With `plan` nil it is the first
    /// loop (`nextLoop()`); otherwise it is chained from `plan` (`nextLoop(after:)`), so it starts where the plan's second
    /// stretch starts.
    private func buildLoop(from flight: EndlessFlight, after plan: RoutePlan?) {
        guard !buildingNext else { return }
        buildingNext = true
        let generation = endlessGeneration
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> (flight: EndlessFlight, route: Route?, plan: RoutePlan?, label: String) in
                var next = flight
                let loop: (route: Route, plan: RoutePlan)?
                if let plan {
                    loop = next.nextLoop(after: plan)
                } else {
                    loop = next.nextLoop()
                }
                guard let loop else { return (next, nil, nil, "") }
                return (next, loop.route, loop.plan, EndlessFlight.label(for: loop.plan))
            }.value
            self?.loopBuilt(made, generation: generation)
        }
    }

    /// Starts a build of the loop after the one being flown, if endless is on and nothing is being built.
    private func buildNextLoop() {
        guard let flight = endless else { return }
        buildLoop(from: flight, after: endlessPlan)
    }

    /// A build has finished. The first loop becomes the route flown at once and arms the swap trigger; the next one, chained
    /// from it, waits in `endlessPending` for the swap point.
    private func loopBuilt(_ made: (flight: EndlessFlight, route: Route?, plan: RoutePlan?, label: String), generation: Int) {
        guard generation == endlessGeneration else { return }
        buildingNext = false
        guard endless != nil else { return }
        endless = made.flight
        guard let route = made.route, let plan = made.plan else {
            if endlessRoute == nil {
                endlessOff()
                showNotice("ENDLESS: NO LOOP FOUND")
            }
            return
        }
        if endlessRoute == nil {
            endlessRoute = route
            endlessPlan = plan
            endlessLabel = made.label
            endlessCount = 1
            swapTrigger = SwapTrigger(swapIndex: EndlessFlight.swapIndex(route: route, plan: plan), count: route.count)
            autopilotHint = nil
            // Entering a street loop from anywhere else is always a hand-back, even above the roofs: chasing the nearest point
            // of the new loop dives at buildings (the run tests and a scripted run both showed it).
            handBack = pilot.mode == .auto ? HandBack(heading: simulation.current.heading) : nil
            entryPending = handBack != nil
            entryClock = nil
            buildNextLoop()
        } else {
            endlessPending = (route: route, plan: plan, label: made.label)
        }
    }

    /// The route the aircraft flies: the endless loop while endless is on and its first loop is ready, else the route C chose.
    private var flownRoute: Route? {
        endlessRoute ?? (routes.isEmpty ? nil : routes[routeIndex])
    }

    /// The endless line for the HUD and the notice view. Empty when endless is off. While a picked street is being joined it
    /// says JOINING until the aircraft (`aircraft`: east, north, metres) is within 30 m of that street, then ON.
    private func endlessLine(aircraft: SIMD2<Double>) -> String {
        guard endless != nil else { return "" }
        guard let route = endlessRoute else { return "ENDLESS: BUILDING A LOOP" }
        let number = String(max(1, endlessCount))
        // When the swap to the next loop is due: the route distance from the aircraft to the swap point, at its speed.
        let count = max(1, route.count)
        let here = autopilotHint ?? 0
        let metres = Double((((swapTrigger.swapIndex - here) % count) + count) % count) * route.spacing
        let seconds = Int((metres / max(simulation.current.speed, 1)).rounded())
        let next = endlessPending == nil ? "BUILDING THE NEXT LOOP" : String(format: "NEXT LOOP IN %d:%02d", seconds / 60, seconds % 60)
        if let target = pickTarget {
            let near = StreetPicker.distance(from: aircraft, to: target.stretch) <= 30
            return "ENDLESS LOOP \(number) / \(near ? "ON" : "JOINING") \(target.label) / \(next)"
        }
        return "ENDLESS LOOP \(number) / \(endlessLabel) / \(next)"
    }

    // MARK: Pick a street (I)

    /// The line shown while pick mode is armed, and again after a build that did not take.
    private static let pickArmedLine = "PICK A STREET: CLICK ONE / I OR ESC TO CANCEL"

    /// The line when the pointer is over no street: the flown street's line once a pick has flown, else the no-street line.
    private var pickIdleLine: String {
        if let label = pickedLabel { return "PICK: FLYING \(label) / CLICK ANOTHER / I OR ESC TO LEAVE" }
        return "PICK: NO STREET HERE / CLICK ONE / I OR ESC TO CANCEL"
    }

    /// The package's street graph, loaded the first time it is needed. Nil when the package has none.
    private func loadStreetGraph() -> StreetGraph? {
        if !streetGraphLoaded {
            streetGraphLoaded = true
            streetGraph = try? StreetGraph.load(from: city.directory)
        }
        return streetGraph
    }

    /// I: pick mode on or off. On, the pointer is free and a click flies the street under it. Mouse flight is given up first,
    /// since the two never run together. Without a street graph it says so and does nothing else.
    func togglePick() {
        if model.pickMode { cancelPick(); return }
        guard loadStreetGraph() != nil else {
            showNotice("PICK: NO STREET GRAPH IN THIS PACKAGE")
            return
        }
        if input.mouseOn { mouseView?.releaseMouse() }
        model.pickMode = true
        model.pickLine = Self.pickArmedLine
        pickAvailableCentre = nil
        window?.acceptsMouseMovedEvents = true
    }

    /// Leaves pick mode, if it is on. Called by I, Esc, J, losing focus, and by a pick that has flown.
    func cancelPick() {
        guard model.pickMode else { return }
        model.pickMode = false
        model.pickLine = ""
        pickAvailable = []
        pickAvailableCentre = nil
        pickHoverIndex = nil
        pickHoverSegments = []
        pickedLabel = nil
        pickedSegments = []
        if !input.mouseOn { window?.acceptsMouseMovedEvents = false }
    }

    /// The pointer moved in pick mode: the pick line names the street under it, and that street is highlighted.
    func pickHover(ndc: SIMD2<Double>, aspect: Double) {
        guard model.pickMode, !pickBuilding, let graph = loadStreetGraph() else { return }
        guard let pick = StreetPicker.pick(camera: lastCamera, ndc: ndc, aspect: aspect,
                                           aircraftHeading: simulation.current.heading, graph: graph, obstacles: city) else {
            pickHoverIndex = nil
            pickHoverSegments = []
            model.pickLine = pickedLabel == nil ? "PICK: NO STREET HERE / CLICK ONE / I OR ESC TO CANCEL" : pickIdleLine
            return
        }
        let stretch = graph.stretches[pick.stretchIndex]
        if pick.stretchIndex != pickHoverIndex {
            pickHoverIndex = pick.stretchIndex
            pickHoverSegments = StreetOverlay.segments(for: stretch, height: 5)
        }
        let kind = stretch.streetClass.isEmpty ? "" : " (\(stretch.streetClass.uppercased()))"
        model.pickLine = "PICK: \(StreetPicker.label(for: stretch))\(kind) / CLICK TO FLY IT"
    }

    /// The pick overlays for this frame, set on the renderer: the nearby streets (one layer, 2.5 px, dim), the street under the
    /// pointer (6 px), and the flown street (10 px). Empty when pick mode is off. The nearby list is rebuilt only when pick
    /// mode starts or the aircraft has moved more than 500 m since the last build.
    private func updatePickOverlays(aircraft: SIMD2<Double>) {
        guard model.pickMode, let graph = loadStreetGraph() else {
            renderer.overlays = []
            return
        }
        if pickAvailableCentre == nil || simd_distance(pickAvailableCentre ?? aircraft, aircraft) > 500 {
            pickAvailableCentre = aircraft
            let indices = StreetOverlay.available(in: graph, near: aircraft, radius: 4000, maxSegments: 30_000)
            var segments: [Float] = []
            for index in indices { segments += StreetOverlay.segments(for: graph.stretches[index], height: 4) }
            pickAvailable = segments
        }
        var layers = [LineOverlay(segments: pickAvailable, widthPx: 4, brightness: 0.35)]
        if !pickHoverSegments.isEmpty {
            layers.append(LineOverlay(segments: pickHoverSegments, widthPx: 7, brightness: 0.5))
        }
        if !pickedSegments.isEmpty {
            layers.append(LineOverlay(segments: pickedSegments, widthPx: 12, brightness: 0.5))
        }
        renderer.overlays = layers
    }

    /// A click in pick mode: the first loop from the street under the pointer is built off the main thread, then flown.
    /// Nothing under the pointer leaves pick mode on, with the line saying so.
    func pickClick(ndc: SIMD2<Double>, aspect: Double) {
        guard model.pickMode, !pickBuilding, let graph = loadStreetGraph() else { return }
        // The clicked street first, then the nearest others: a street that cannot start a loop falls through to the next.
        let picks = StreetPicker.candidates(camera: lastCamera, ndc: ndc, aspect: aspect,
                                            aircraftHeading: simulation.current.heading, graph: graph, obstacles: city,
                                            maxSnap: 1500, limit: 4)
        guard !picks.isEmpty else {
            model.pickLine = "PICK: NO STREET HERE / CLICK ONE / I OR ESC TO CANCEL"
            return
        }
        let streets = picks.map { graph.stretches[$0.stretchIndex] }
        // The flight to build from: the running endless flight, or a new one with a fresh seed.
        guard let base = endless ?? EndlessFlight(city: city, seed: Self.newEndlessSeed()) else {
            showNotice("PICK: NO STREET GRAPH IN THIS PACKAGE")
            cancelPick()
            return
        }
        let firstLabel = StreetPicker.label(for: streets[0])
        let choices = picks.map { (id: graph.stretches[$0.stretchIndex].id, reversed: $0.reversed) }
        let generation = endlessGeneration
        pickBuilding = true
        model.pickLine = "PICK: BUILDING A LOOP FROM \(firstLabel) / I OR ESC TO CANCEL"
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> (flight: EndlessFlight, route: Route?, plan: RoutePlan?, usedIndex: Int?) in
                var next = base
                let loop = next.firstLoop(trying: choices)
                return (next, loop?.route, loop?.plan, loop?.usedIndex)
            }.value
            self?.pickBuilt(made, generation: generation, streets: streets, firstLabel: firstLabel)
        }
    }

    /// The first loop of a pick is ready. It is flown if pick mode is still on and no U, C or Esc has changed the endless
    /// state since the click. It starts endless mode as the first loop does, but it is armed to join the picked street.
    /// Pick mode stays on after a pick that flies, so another street can be picked (I or Esc leaves it).
    private func pickBuilt(_ made: (flight: EndlessFlight, route: Route?, plan: RoutePlan?, usedIndex: Int?), generation: Int,
                           streets: [StreetStretch], firstLabel: String) {
        pickBuilding = false
        guard model.pickMode else { return }
        guard generation == endlessGeneration else {
            // The endless state changed during the build: the pick is void, and pick mode stays for another click.
            model.pickLine = pickIdleLine
            return
        }
        guard let route = made.route, let plan = made.plan, let usedIndex = made.usedIndex, usedIndex < streets.count else {
            model.pickLine = pickIdleLine
            showNotice("PICK: NO SAFE ROUTE FROM THAT STREET")
            return
        }
        // The stretch actually flown: the clicked one, or the first of the others that could start a loop.
        let stretch = streets[usedIndex]
        let label = StreetPicker.label(for: stretch)
        pickedLabel = label
        pickedSegments = StreetOverlay.segments(for: stretch, height: 6)
        model.pickLine = "PICK: FLYING \(label) / CLICK ANOTHER / I OR ESC TO LEAVE"
        if usedIndex > 0 {
            showNotice("PICK: NO LOOP FROM \(firstLabel); FLYING \(label)")
        }
        // Endless starts from cruise, as U does, so the hand-back can climb out of a street first.
        if pilot.mode == .manual { toggleCruise() }
        endlessGeneration += 1
        buildingNext = false
        endless = made.flight
        endlessRoute = route
        endlessPlan = plan
        endlessPending = nil
        endlessLabel = EndlessFlight.label(for: plan)
        endlessCount += 1
        swapTrigger = SwapTrigger(swapIndex: EndlessFlight.swapIndex(route: route, plan: plan), count: route.count)
        // The hint at the last sample: the nearest-point search then covers the closing join into the picked street.
        autopilotHint = route.count - 1
        // A forced hand-back (see the first loop), aimed at the closing join into the picked street, not the nearest point.
        handBack = pilot.mode == .auto ? HandBack(heading: simulation.current.heading, startIndex: max(0, route.count - 260)) : nil
        entryPending = handBack != nil
        entryClock = nil
        pickTarget = (stretch: stretch, label: label)
        buildNextLoop()
    }

    /// The route the aircraft flies: the endless loop while endless is on and its first loop is ready, else the route C chose.
    /// A line of text for a few seconds, in the HUD or the notice view, and announced to VoiceOver.
    private func showNotice(_ text: String) {
        model.notice = text
        model.noticeUntil = CACurrentMediaTime() + 4
        let target: Any = window.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(element: target, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// C: switch between Scenic and River. The autopilot searches the whole route once. C also leaves endless flight.
    func cycleRoute() {
        guard routes.count > 1 else { return }
        if endless != nil { endlessOff() }
        routeIndex = (routeIndex + 1) % routes.count
        autopilotHint = nil
        heightOffset = 0
        showRouteList()
    }

    /// The roof cache of each route flown lately (see RoofCache): lowering reads many of them ahead of the aircraft every step.
    private var roofCaches: [String: RoofCache] = [:]
    private func roofCache(for route: Route) -> RoofCache {
        let key = "\(route.name)#\(route.count)"
        if let cache = roofCaches[key] { return cache }
        if roofCaches.count > 8 { roofCaches.removeAll() }
        let cache = RoofCache(count: route.count)
        roofCaches[key] = cache
        return cache
    }

    /// The altitude (metres) a hand-flown aircraft is climbing or descending to after T or V; nil when none.
    private var manualAltTarget: Double?

    /// T and V. In cruise: the autopilot's height above the route, in steps of 10 m, between -60 and +120 m. Hand flying: a
    /// target altitude 10 m higher or lower than the aircraft (or than the last target), which the aircraft climbs or descends
    /// to and then holds off; touching the pitch controls drops it.
    func stepHeight(_ delta: Double) {
        if pilot.mode == .manual {
            let base = manualAltTarget ?? simulation.current.altitude
            manualAltTarget = min(max(base + delta, tuning.floor + 5), tuning.ceiling)
        } else {
            heightOffset = min(max(heightOffset + delta, -60), 120)
        }
    }

    /// The pitch to add to the hand-flown request to reach `manualAltTarget`, or nil (and the target cleared) when there is
    /// none, it is reached, or the pilot is pitching by hand or by mouse.
    private func manualAltitudeAssist(_ s: FlightState, manual: ControlInput) -> Double? {
        guard let target = manualAltTarget else { return nil }
        let error = target - s.altitude
        if abs(manual.pitch) > 0.1 || (abs(error) < 3 && abs(s.pitch) < 0.05) {
            manualAltTarget = nil
            return nil
        }
        return min(max(error / 40, -0.8), 0.8)
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
            if pilot.blend < 1 { return "MANUAL → AUTO" }
            let name = endless != nil ? "ENDLESS" : (routes.isEmpty ? "" : routes[routeIndex].name.uppercased())
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

    #if DEBUG
    // MARK: - Debug script (Debug builds only)
    // GULLFIRE_SCRIPT="u@10,pick@60,space@120,quit@200" calls the same functions the keys call, at those seconds after the
    // first frame (u, i, pick, space, c, t, v, quit), and GULLFIRE_SCRIPT_LOG=<file> gets a status line every 2 s. "pick"
    // clicks the nearest street ahead by projecting it into the view and calling pickClick, so the real picker runs. It
    // synthesises no keyboard or mouse events.
    private var scriptItems: [(at: Double, cmd: String)]?
    private var scriptStart: Double?
    private var scriptNext = 0
    private var scriptLastLog = -10.0

    private func debugScriptTick(now: Double) {
        let env = ProcessInfo.processInfo.environment
        if scriptItems == nil {
            scriptItems = (env["GULLFIRE_SCRIPT"] ?? "").split(separator: ",").compactMap { part in
                let bits = part.split(separator: "@")
                guard bits.count == 2, let t = Double(bits[1]) else { return nil }
                return (t, String(bits[0]))
            }.sorted { $0.at < $1.at }
        }
        guard let items = scriptItems, !items.isEmpty else { return }
        let t0 = scriptStart ?? now
        scriptStart = t0
        let t = now - t0
        while scriptNext < items.count, items[scriptNext].at <= t {
            let cmd = items[scriptNext].cmd
            scriptNext += 1
            debugScriptLog(t, "COMMAND \(cmd)")
            switch cmd {
            case "u": toggleEndless()
            case "i": togglePick()
            case "pick": debugScriptPick()
            case "space": toggleCruise()
            case "c": cycleRoute()
            case "t": stepHeight(10)
            case "v": stepHeight(-10)
            case "handfly": handFly()   // what J does before it takes the pointer (the pointer itself is not touched)
            case "quit": NSApplication.shared.terminate(nil)
            default: debugScriptLog(t, "unknown command \(cmd)")
            }
        }
        if t - scriptLastLog >= 2 {
            scriptLastLog = t
            let s = simulation.current
            let h = model.hud
            debugScriptLog(t, String(format: "mode=[%@] endless=[%@] pick=[%@] notice=[%@] pilot=%@ e=%.0f n=%.0f alt=%.0f m heading=%.0f nudges=%d proximity=%@ height=%+.0f target=%@",
                                     h.mode, h.endless, model.pickLine, model.notice ?? "", pilot.mode == .auto ? "auto" : "manual",
                                     s.east, s.north, s.altitude, s.heading * 180 / .pi, simulation.nudges,
                                     simulation.proximityWarning ? "yes" : "no", heightOffset,
                                     manualAltTarget.map { String(format: "%.0f", $0) } ?? "-"))
        }
    }

    private func debugScriptLog(_ t: Double, _ text: String) {
        guard let path = ProcessInfo.processInfo.environment["GULLFIRE_SCRIPT_LOG"] else { return }
        let line = String(format: "%7.1f ", t) + text + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Clicks the nearest stretch within 1500 m: its middle point goes through the camera's view-projection to a view
    /// position, and pickClick runs the real picker on it. Turns pick mode on first when it is off.
    private func debugScriptPick() {
        if !model.pickMode { togglePick() }
        guard let graph = loadStreetGraph() else { return }
        let a = simulation.current
        var best: (d: Double, p: SIMD2<Double>)?
        for st in graph.stretches {
            let line = st.polyline
            guard line.count > 2 else { continue }
            let m = line[line.count / 2]
            let d = hypot(m.x - a.east, m.y - a.north)
            let bearing = atan2(m.x - a.east, m.y - a.north)
            let ahead = abs(atan2(sin(bearing - a.heading), cos(bearing - a.heading))) < 1.0
            if d > 150, d < 1500, ahead, d < (best?.d ?? .infinity) { best = (d, m) }
        }
        guard let target = best else { debugScriptLog(scriptStart.map { CACurrentMediaTime() - $0 } ?? 0, "pick: no stretch ahead within 1500 m"); return }
        let aspect = Double(renderer.width) / Double(renderer.height)
        let vp = lastCamera.viewProjection(aspect: Float(aspect))
        let clip = vp * SIMD4<Float>(Float(target.p.x), 0, Float(-target.p.y), 1)
        guard clip.w != 0 else { return }
        let ndc = SIMD2<Double>(Double(clip.x / clip.w), Double(clip.y / clip.w))
        debugScriptLog(scriptStart.map { CACurrentMediaTime() - $0 } ?? 0, String(format: "pick: ndc %.2f %.2f for a stretch %.0f m away", ndc.x, ndc.y, best?.d ?? 0))
        pickHover(ndc: ndc, aspect: aspect)
        debugScriptLog(scriptStart.map { CACurrentMediaTime() - $0 } ?? 0, "hover: " + model.pickLine)
        pickClick(ndc: ndc, aspect: aspect)
    }
    #endif

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
        if model.notice != nil, now >= model.noticeUntil { model.notice = nil }
        #if DEBUG
        debugScriptTick(now: now)
        #endif

        // Fixed-step simulation, fed by the pilot's input for this frame.
        let dt = lastSimTime.map { min(0.1, now - $0) } ?? 0
        lastSimTime = now
        let manual = input.control(dt: dt)
        simulation.advance(by: dt, obstacles: city, extent: city.manifest.extentM) { s, stepDt in
            // Each fixed step: the autopilot sees the state it is flying from, and the pilot blends.
            pilot.advance(dt: stepDt)
            guard let route = flownRoute else { return manual }
            // A hand-back in progress replaces the pilot's input: the autopilot climbs out of the street first.
            if handBack != nil, pilot.mode == .auto,
               let r = Autopilot.handBackControl(for: s, route: route, obstacles: city, state: &handBack, tuning: tuning) {
                autopilotHint = r.index
                return r.control
            }
            // The hand-back onto a street loop has ended: fly high for the next minute and settle onto the route.
            if entryPending { entryPending = false; entryClock = 0 }
            if let clock = entryClock {
                entryClock = clock + stepDt
                if clock > 60 { entryClock = nil }
            }
            let boost = entryClock.map { Autopilot.entryBoost(secondsSinceHandBack: $0) } ?? 0
            let auto = Autopilot.control(for: s, route: route, hint: autopilotHint, tuning: tuning,
                                         heightOffset: heightOffset + boost, obstacles: city, roofs: roofCache(for: route))
            autopilotHint = auto.index
            // Endless: the next loop was built from this one, so it starts where the aircraft is at the swap point. When
            // the index reaches the swap point and a loop is ready, the aircraft is already on it: it takes over with no
            // hand-back. With nothing ready, this loop is flown on; the trigger re-arms and tries at the next pass.
            if endlessRoute != nil, swapTrigger.update(index: auto.index) {
                if let pending = endlessPending {
                    endlessRoute = pending.route
                    endlessPlan = pending.plan
                    endlessLabel = pending.label
                    endlessCount += 1
                    endlessPending = nil
                    pickTarget = nil
                    autopilotHint = 0
                    handBack = nil
                    swapTrigger.reset(swapIndex: EndlessFlight.swapIndex(route: pending.route, plan: pending.plan),
                                      count: pending.route.count)
                } else {
                    swapTrigger.reset(swapIndex: swapTrigger.swapIndex, count: route.count)
                }
                buildNextLoop()
            }
            var hand = manual
            if pilot.mode == .manual, let assist = manualAltitudeAssist(s, manual: manual) { hand.pitch = assist }
            return pilot.blended(manual: hand, auto: auto.control)
        }
        let state = simulation.interpolated()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let camera = chase.update(state, dt: dt, reduceMotion: reduceMotion)
        lastCamera = camera
        renderer.aircraft = showsAircraft ? AircraftPose(state) : nil
        updatePickOverlays(aircraft: SIMD2(state.east, state.north))

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
                                   heightOffsetM: heightOffset,
                                   heightTargetFt: pilot.mode == .manual ? manualAltTarget.map { $0 * 3.28084 } : nil,
                                   endless: endlessLine(aircraft: SIMD2(state.east, state.north)))
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
                case "u": model.flight?.toggleEndless()
                case "t": model.flight?.stepHeight(10)
                case "v": model.flight?.stepHeight(-10)
                case "space": model.flight?.toggleCruise()
                case "n": model.nextTrack()
                case "m": model.toggleMusic()
                case ",": model.togglePause()
                case "i": model.flight?.togglePick()
                case "j":
                    model.flight?.cancelPick()
                    if view?.input?.mouseOn == false { model.flight?.handFly() }
                    view?.toggleMouse()
                default: break
                }
            }
        }
        view.onPick = { [weak model] ndc, aspect, click in
            MainActor.assumeIsolated {
                guard let flight = model?.flight else { return }
                if click { flight.pickClick(ndc: ndc, aspect: aspect) } else { flight.pickHover(ndc: ndc, aspect: aspect) }
            }
        }
        if let city = model.city, view.device != nil {
            do {
                let flight = try FlightRenderer(model: model, city: city, view: view, input: input,
                                                width: 1280, height: 720)
                context.coordinator.flight = flight
                model.flight = flight
                flight.mouseView = view
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
