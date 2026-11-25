import AppKit
import Foundation
import GullfireKit
import Observation
import QuartzCore
import UniformTypeIdentifiers
import UniformTypeIdentifiers

/// What the HUD shows. Values come from the current pilot (the orbit until M3).
struct HUDReadout: Equatable {
    var mode = "FLIGHT MODE MANUAL"
    var altitudeFt = 0.0
    var speedKt = 0.0
    var headingDeg = 0.0
    var latitude = 0.0
    var longitude = 0.0
    var proximityWarning = false
    var boundaryWarning = false
    /// True while the autopilot has the aircraft (not during the hand-over blend). The key legend uses it.
    var cruising = false
    /// The autopilot's height above the route, in metres (T and V). Zero is the route itself.
    var heightOffsetM = 0.0
    /// While hand flying after T or V: the altitude being flown to, in feet. nil otherwise.
    var heightTargetFt: Double?
    /// The endless line ("ENDLESS LOOP 3 / STATE ST", or building), or "" while endless is off.
    var endless = ""
}

/// Live performance numbers for the overlay.
struct PerfReadout: Equatable {
    var resolution = ""
    var fps = 0.0
    var frameWorstMs = 0.0
    var gpuMs = 0.0
    var footprintMB = 0.0
}

/// Totals for the single log line printed on quit.
struct SessionLog {
    var started = Date()
    var frames = 0
    var worstFrameMs = 0.0
    var gpuTotal = 0.0
    var peakFootprintMB = 0.0

    func line(now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(started)
        let fps = seconds > 0 ? Double(frames) / seconds : 0
        let gpuAvg = frames > 0 ? gpuTotal / Double(frames) * 1000 : 0
        return String(format: "gullfire: ran %.1f s, %d frames, fps %.1f avg, worst frame %.1f ms, gpu %.2f ms avg, footprint peak %.0f MB",
                      seconds, frames, fps, worstFrameMs, gpuAvg, peakFootprintMB)
    }
}

/// App state shared by the window, the HUD and the renderer. Everything runs on the main actor.
@MainActor
@Observable
final class AppModel {
    var palette: Palette {
        didSet { Self.defaults.set(palette.rawValue, forKey: Self.paletteKey) }
    }
    /// The readout H cycles through (see HUDLevel): off at launch, then the flight info, then the performance lines too.
    /// P still shows or hides the performance lines on their own.
    var showPerformance = false
    var showHUD = false
    var hudLevel: HUDLevel { showHUD ? (showPerformance ? .full : .flight) : .off }

    /// H: off, flight info, flight info with performance, off.
    func cycleHUD() {
        let next = hudLevel.next
        showHUD = next != .off
        showPerformance = next == .full
    }
    private static let showKeysKey = "showKeyCommands"
    /// The key command legend (K). On by default; the choice is kept.
    var showKeys: Bool = true {
        didSet { Self.defaults.set(showKeys, forKey: Self.showKeysKey) }
    }
    private static let mouseSensitivityKey = "mouseSensitivity"
    private static let mouseInvertKey = "mouseInvert"
    /// Mouse flight (J) is on. Not saved: the app never starts with the mouse taken.
    var mouseFlight = false
    /// Pick mode (I) is on: the pointer is free, and a click flies the street under it. `pickLine` is its text (HUD and notice).
    var pickMode = false
    var pickLine = ""
    /// Stick travel per point of pointer movement, 0.25 to 4 (1 is the default). Saved.
    var mouseSensitivity: Double = 1.0 {
        didSet { Self.defaults.set(mouseSensitivity, forKey: Self.mouseSensitivityKey) }
    }
    /// Pitch inverted for the mouse, as on a joystick. Saved.
    var mouseInvert: Bool = false {
        didSet { Self.defaults.set(mouseInvert, forKey: Self.mouseInvertKey) }
    }
    /// The renderer, so menu items and keys can reach the flight (set when the view starts).
    weak var flight: FlightRenderer?
    /// Native 5K by default; half resolution trades sharpness for about a quarter of the cost.
    var renderScale: RenderScale
    var hud = HUDReadout()
    /// The route list shown when C cycles the route (D1). Nil until the first cycle.
    var routeList: RouteList?
    /// Whether the Gullfire glider model is installed. The G legend row and the View menu item appear only when it is.
    var hasGlider = false
    var perf = PerfReadout()
    var problem: String?
    /// A short line of text over the flight (such as endless being unavailable), shown until `noticeUntil`
    /// (CACurrentMediaTime seconds). The HUD shows it, or the notice view when the HUD is off.
    var notice: String?
    var noticeUntil = 0.0

    private(set) var city: CityPackage?
    /// The maps the picker lists. Empty when `GULLFIRE_CITY` chose the map, or when none were found.
    private(set) var catalog: [CityEntry] = []
    /// The display names for the picker, from the shipped recipe list. Empty if the file is missing, so
    /// the picker falls back to the folder names.
    let recipes: RecipeList = {
        guard let url = Bundle.main.url(forResource: "recipes", withExtension: "json"),
              let list = try? RecipeList.load(url) else { return RecipeList(format: 1, recipes: []) }
        return list
    }()
    private static let lastCityKey = "lastCity"
    /// The folder of the map flown last, so the picker can preselect it.
    var lastCityPath: String? { Self.defaults.string(forKey: Self.lastCityKey) }
    var session = SessionLog()
    let timing = PerfLog()

    /// Background music (Settings has the folder). Nothing plays at launch.
    let music = CrossfadePlayer()
    /// The MIDI piece, played as a pad through the same engine and bus as `music`. Nil if the pad could not attach.
    private(set) var midi: MIDIMusic?
    /// The MIDI piece the music keys play: endless or loop, and the file (nil: the bundled Satie). Saved like the
    /// other music settings.
    private static let midiModeKey = "midiMode"
    private static let midiFileKey = "midiFile"
    var midiMode: MIDIMusic.Mode? {
        didSet { Self.defaults.set(midiMode?.rawValue, forKey: Self.midiModeKey) }
    }
    var midiFile: URL? {
        didSet { Self.defaults.set(midiFile?.path, forKey: Self.midiFileKey) }
    }
    /// Where the app keeps its settings. Release always uses the standard domain. Debug builds can point test and
    /// automated runs at a separate suite named by an environment variable, so they never touch the owner's settings.
    static let defaults: UserDefaults = {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["GULLFIRE_DEFAULTS_SUITE"], let store = UserDefaults(suiteName: suite) {
            return store
        }
        #endif
        return .standard
    }()
    /// The bundled demo piece: Satie's Gymnopédie No. 1 and its loop map, both shipped in the app.
    static var bundledPiece: (midi: URL, sidecar: URL)? {
        guard let midi = Bundle.main.url(forResource: "gymnopedie_1", withExtension: "mid"),
              let sidecar = Bundle.main.url(forResource: "gymnopedie_1.loopmap", withExtension: "json") else { return nil }
        return (midi, sidecar)
    }
    private static let musicFolderKey = "musicFolder"
    private static let crossfadeKey = "crossfadeSeconds"
    var musicFolder: URL? {
        didSet { Self.defaults.set(musicFolder?.path, forKey: Self.musicFolderKey) }
    }
    var crossfadeSeconds: Double = 5 {
        didSet {
            Self.defaults.set(crossfadeSeconds, forKey: Self.crossfadeKey)
            music.fadeSeconds = crossfadeSeconds
        }
    }
    private static let pauseWhenHiddenKey = "pauseMusicWhenHidden"
    /// Pause the music while the window is hidden (another Space, minimised, covered). On by default.
    var pauseMusicWhenHidden: Bool = true {
        didSet { Self.defaults.set(pauseMusicWhenHidden, forKey: Self.pauseWhenHiddenKey) }
    }
    private var hiddenTask: Task<Void, Never>?
    private var musicPausedByHide = false
    /// What the last scan found, for Settings to show.
    var musicStatus = ""

    // MARK: Cathedral mode

    private static let cathedralPathKey = "cathedralPath"
    private static let cathedralFadeKey = "cathedralFade"
    private static let useCathedralKey = "useCathedral"
    /// The track cathedral mode loops, and the fade it uses. Kept between launches. `useCathedral`
    /// is kept apart from them, so "back to my music folder" loses nothing.
    var cathedralFile: URL? {
        didSet { Self.defaults.set(cathedralFile?.path, forKey: Self.cathedralPathKey) }
    }
    var cathedralFade: Double = 0 {
        didSet { Self.defaults.set(cathedralFade, forKey: Self.cathedralFadeKey) }
    }
    var useCathedral = false {
        didSet { Self.defaults.set(useCathedral, forKey: Self.useCathedralKey) }
    }
    /// What the cathedral sheet offers, best first. Empty while looking, or when nothing was found.
    var cathedralOffers: [CathedralFinder.Match] = []
    /// Why the sheet has no offer. Empty while looking.
    var cathedralSearchNote = ""
    /// Shown in Settings when cathedral mode could not start (the track moved or will not open).
    var cathedralNotice = ""
    var showCathedralSheet = false

    private static let paletteKey = "palette"
    private static let scaleKey = "renderScale"

    init() {
        timing.checkpoint("mark 0 process start")
        timing.mark("app model created")
        timing.startStartupSampler()
        let saved = Self.defaults.string(forKey: Self.paletteKey)
        palette = saved.flatMap(Palette.init(rawValue:)) ?? .standard
        renderScale = Self.defaults.string(forKey: Self.scaleKey).flatMap(RenderScale.init(rawValue:)) ?? .native
        if Self.defaults.object(forKey: Self.showKeysKey) != nil {
            showKeys = Self.defaults.bool(forKey: Self.showKeysKey)
        }
        if Self.defaults.object(forKey: Self.mouseSensitivityKey) != nil {
            mouseSensitivity = min(4, max(0.25, Self.defaults.double(forKey: Self.mouseSensitivityKey)))
        }
        mouseInvert = Self.defaults.bool(forKey: Self.mouseInvertKey)
        if ProcessInfo.processInfo.environment["GULLFIRE_CITY"] != nil {
            // A named map flies straight away, as before: no picker, so scripts and renders are unchanged.
            do {
                city = try CityPackage.open(directory: Self.cityDirectory())
                timing.mark("city package opened")
                timing.checkpoint("mark 1 CityPackage.open")
            } catch {
                problem = "Could not open the city package: \(error)"
            }
        } else {
            catalog = CityCatalog.scan(roots: Self.cityRoots())
            timing.mark("city catalog scanned")
            // One map installed (a 1.2 install): it flies straight away, with no picker.
            if catalog.count == 1, let only = catalog.first {
                chooseCity(only)
                timing.mark("city package opened")
                timing.checkpoint("mark 1 CityPackage.open")
            }
        }
        if let path = Self.defaults.string(forKey: Self.musicFolderKey) {
            musicFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        if Self.defaults.object(forKey: Self.crossfadeKey) != nil {
            crossfadeSeconds = Self.defaults.double(forKey: Self.crossfadeKey)
        }
        if Self.defaults.object(forKey: Self.pauseWhenHiddenKey) != nil {
            pauseMusicWhenHidden = Self.defaults.bool(forKey: Self.pauseWhenHiddenKey)
        }
        music.fadeSeconds = crossfadeSeconds
        if let path = Self.defaults.string(forKey: Self.cathedralPathKey) {
            cathedralFile = URL(fileURLWithPath: path)
        }
        if Self.defaults.object(forKey: Self.cathedralFadeKey) != nil {
            cathedralFade = Self.defaults.double(forKey: Self.cathedralFadeKey)
        }
        useCathedral = Self.defaults.bool(forKey: Self.useCathedralKey)
        if let raw = Self.defaults.string(forKey: Self.midiModeKey) { midiMode = MIDIMusic.Mode(rawValue: raw) }
        if let path = Self.defaults.string(forKey: Self.midiFileKey) { midiFile = URL(fileURLWithPath: path) }
        // Test only (like GULLFIRE_ROUTE): GULLFIRE_MUSIC_FOLDER plays that folder without saving it,
        // and GULLFIRE_MUSIC_MUTE=1 runs the engine with the output at zero, so a run makes no sound.
        let env = ProcessInfo.processInfo.environment
        if let folder = env["GULLFIRE_MUSIC_FOLDER"] { musicFolder = URL(fileURLWithPath: folder, isDirectory: true) }
        if env["GULLFIRE_MUSIC_MUTE"] == "1" { music.outputVolume = 0 }
        #if DEBUG
        // Test hooks, Debug builds only: the MIDI mode for this run, and an autostart that turns music on as M would.
        if let mode = env["GULLFIRE_MUSIC_MIDI"].flatMap(MIDIMusic.Mode.init(rawValue:)) { midiMode = mode }
        if env["GULLFIRE_MUSIC_AUTOSTART"] == "1" { DispatchQueue.main.async { self.toggleMusic(reason: "debug autostart") } }
        #endif
        // Silent at launch: nothing plays until M.
        print("gullfire[pid \(ProcessInfo.processInfo.processIdentifier)]: started")
        do {
            midi = try MIDIMusic(engine: music.sharedEngine, output: music.musicBus)
        } catch {
            midi = nil
            print("midiloop: the pad could not attach: \(error)")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                print("gullfire: quit requested: \((QuitSource.shared?.described ?? "menu or key"))")   // every quit, in every build
                guard let self, !self.logWritten else { return }
                self.writeLog(runSeconds: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timing.fullScreenAt = CACurrentMediaTime()
                self.timing.mark("entered full screen")
                self.timing.checkpoint("mark 7 full screen entered")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    self.timing.checkpoint("mark 8 5 s after full screen")
                    try? await Task.sleep(for: .seconds(15))
                    self.timing.checkpoint("mark 9 20 s after full screen")
                }
            }
        }
        // An offscreen run ends on its own frame clock instead (FlightRenderer.drawFrame), so a slow Mac does not shorten it.
        if !FlightRenderer.offscreenRun, let limit = ProcessInfo.processInfo.environment["GULLFIRE_SECONDS"].flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(limit))
                // Log before leaving full screen, so the quit transition is not in the run's numbers.
                self.writeLog(runSeconds: limit)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// The folders the picker searches, in order (the first copy of a map name wins): `GULLFIRE_CITIES`
    /// (a folder of packages, optional), then `~/Library/Application Support/Gullfire/Cities`, then the
    /// relative `Cities` folder when running from the project.
    static func cityRoots() -> [URL] {
        var roots: [URL] = []
        if let path = ProcessInfo.processInfo.environment["GULLFIRE_CITIES"] {
            roots.append(URL(fileURLWithPath: path, isDirectory: true))
            // Capture builds: GULLFIRE_CITIES_ONLY=1 searches that folder alone, so a capture shows the maps it names.
            #if DEBUG
            if ProcessInfo.processInfo.environment["GULLFIRE_CITIES_ONLY"] == "1" { return roots }
            #endif
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gullfire/Cities", isDirectory: true))
        roots.append(URL(fileURLWithPath: "Cities", isDirectory: true))
        return roots
    }

    /// Opens a map and flies it. On failure the picker stays up and says why.
    func chooseCity(_ entry: CityEntry) {
        do {
            city = try CityPackage.open(directory: entry.directory)
            problem = nil
            Self.defaults.set(entry.directory.path, forKey: Self.lastCityKey)
        } catch {
            problem = "Could not open \(entry.name): \(error)"
        }
    }

    /// Asks for any map folder and opens it, for maps outside the searched folders.
    func chooseCityFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a map folder: one that holds manifest.json and the solids, lines and obstacles files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let entry = CityCatalog.describe(url) {
            chooseCity(entry)
        } else {
            problem = "\(url.lastPathComponent) is not a map package: it needs manifest.json, solids.bin, lines.bin and obstacles.bin."
        }
    }

    /// Whether Flight ▸ Choose Map… (Command-O) does anything: in flight, with a second map to choose.
    var canChooseMap: Bool { ChooseMap.isAvailable(inFlight: city != nil, mapCount: catalog.count) }

    /// Flight ▸ Choose Map…: back to the picker. Dropping the city drops the flight view, and with it the
    /// renderer and its buffers, so two maps are never resident at once.
    func returnToPicker() {
        guard canChooseMap else { return }
        flight = nil
        city = nil
        problem = nil
        catalog = CityCatalog.scan(roots: Self.cityRoots())
    }

    /// Where the package is. `GULLFIRE_CITY` wins. Otherwise the first folder that holds a
    /// manifest: `~/Library/Application Support/Gullfire/Cities/Chicago` (a Finder launch has no
    /// project folder), then the relative `Cities/Chicago` (running from the project folder).
    /// If neither exists, the Application Support path, which the empty state names.
    static func cityDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["GULLFIRE_CITY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gullfire/Cities/Chicago", isDirectory: true)
        let relative = URL(fileURLWithPath: "Cities/Chicago", isDirectory: true)
        for candidate in [support, relative]
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            return candidate
        }
        return support
    }

    private(set) var logWritten = false

    /// Writes the run's summary once. Called when the run's timer fires, or at quit if no timer ran.
    func writeLog(runSeconds: Double?) {
        guard !logWritten else { return }
        logWritten = true
        timing.mark("log written")
        timing.printBucket()   // the final, partial 15 s bucket
        print(session.line())
        print("gullfire-gpu: errors \(timing.gpuErrorCount), first at \(timing.firstGPUErrorAt.map { String(format: "%.3f s", $0) } ?? "none")")
        for line in timing.phaseSummary(runSeconds: runSeconds) { print(line) }
        print("gullfire-perf: quit begins at epoch \(timing.wallClock(CACurrentMediaTime()))")  // exit peak is sampled after this
    }

    /// Toggles the resolution. Moved off the R key in M3, which is level off.
    func toggleResolutionFromMenu() {
        toggleRenderScale()
    }

    func toggleRenderScale() {
        renderScale = renderScale.toggled
        Self.defaults.set(renderScale.rawValue, forKey: Self.scaleKey)   // saved only on a user press
    }

    /// B cycles default, brand, lime and back to default.
    func cyclePalette() {
        switch palette {
        case .standard: palette = .brand
        case .brand: palette = .lime
        case .lime: palette = .standard
        }
    }

    // MARK: Music

    /// Scans the chosen folder off the main thread, then plays its tracks in a random order.
    /// Does nothing when no folder has been chosen. Files that will not open are logged and skipped.
    /// Whether any music source is on, and whether sound is coming out.
    var isMusicOn: Bool { music.isOn || (midi?.isOn ?? false) }
    var isMusicPlaying: Bool { music.isPlaying || (midi?.isPlaying ?? false) }
    /// The title of what is playing, for Settings.
    var nowPlayingTitle: String { midi?.isOn == true ? (midi?.title ?? "") : music.currentTitle }

    /// Stops every music source. Only one plays at a time.
    func stopAllMusic() {
        music.stop()
        midi?.stop()
    }

    /// The comma key: play or pause whichever source is on.
    func togglePause() {
        if midi?.isOn == true { midi?.togglePlayPause() } else { music.togglePlayPause() }
    }

    /// Starts the MIDI piece: the chosen file or the bundled Satie, endless or loop, with a new seed each start.
    func startMIDI(reason: String) {
        let mode = midiMode ?? .endless
        let chosenPiece: (midi: URL, sidecar: URL)? = midiFile.map { (midi: $0, sidecar: MIDIMusic.sidecarURL(for: $0)) } ?? Self.bundledPiece
        // D9 guard (4.2): the same piece already playing in this mode is ignored, so a stray second call cannot restart it.
        // Checked before anything stops. Logged with the reason, as the start is.
        if let chosenPiece, let midi, midi.isAlreadyPlaying(chosenPiece.midi, mode: mode) {
            print("midiloop[pid \(ProcessInfo.processInfo.processIdentifier)]: start ignored, already playing, reason \(reason)")
            return
        }
        stopAllMusic()
        guard let midi else { musicStatus = "The MIDI pad is not available."; return }
        guard let piece = chosenPiece else {
            musicStatus = "The demo piece is missing from the app."
            return
        }
        do {
            try midi.start(midi: piece.midi, sidecar: piece.sidecar, mode: mode, seed: UInt64.random(in: 1...UInt64.max), reason: reason)
            musicStatus = "MIDI piece, \(mode == .endless ? "endless" : "looping")"
        } catch {
            musicStatus = "The MIDI piece would not play: \(error)"
        }
    }

    func startMusic() {
        stopAllMusic()
        if useCathedral { startCathedral(); return }
        music.fadeSeconds = crossfadeSeconds
        guard let folder = musicFolder else { musicStatus = ""; return }
        musicStatus = "Looking for music…"
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { MusicLibrary.scan(folder: folder) }.value
            // The folder may have been changed while scanning.
            guard folder == self.musicFolder else { return }
            for skipped in result.skipped { print("gullfire-music: skipped \(skipped.url.lastPathComponent): \(skipped.reason)") }
            if result.tracks.isEmpty {
                self.musicStatus = "No playable music in this folder."
                return
            }
            var generator = SystemRandomNumberGenerator()
            let order = MusicLibrary.shuffled(result.tracks, using: &generator)
            self.musicStatus = "\(result.tracks.count) tracks" + (result.skipped.isEmpty ? "" : ", \(result.skipped.count) skipped")
            self.music.start(tracks: order)
        }
    }

    /// Plays the cathedral track alone on a loop with its fade. A track that has moved or will not
    /// open turns cathedral mode off and falls back to the music folder, with a note in Settings.
    private func startCathedral() {
        guard let url = cathedralFile else { useCathedral = false; startMusic(); return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cathedralNotice = "The cathedral track has moved. Playing your music folder instead."
            useCathedral = false
            startMusic()
            return
        }
        musicStatus = "Looking for the cathedral track…"
        Task { @MainActor in
            let seconds = await Task.detached(priority: .utility) { MusicLibrary.length(of: url) }.value
            // The mode may have been left, or another track chosen, while the file was opening.
            guard self.useCathedral, self.cathedralFile == url else { return }
            guard let seconds else {
                self.cathedralNotice = "The cathedral track will not open. Playing your music folder instead."
                self.useCathedral = false
                self.startMusic()
                return
            }
            let longest = CrossfadePlan.longestLoopFade(duration: seconds)
            self.music.fadeSeconds = self.cathedralFade > 0 ? min(self.cathedralFade, longest) : longest
            self.music.start(tracks: [url])
            if self.music.isOn {
                self.cathedralNotice = ""
                self.musicStatus = "Cathedral track, looping"
            } else {
                self.cathedralNotice = "The cathedral track would not play."
            }
        }
    }

    /// The cathedral button: looks for the track by its length in the music folder and the Music
    /// library. The sheet then offers what it finds.
    func findCathedral() {
        cathedralOffers = []
        cathedralSearchNote = "Looking…"
        showCathedralSheet = true
        let folders = searchFolders()
        Task { @MainActor in
            let lengths = await Task.detached(priority: .utility) { MusicLibrary.lengths(in: folders) }.value
            let matches = CathedralFinder.rank(lengths)
            self.cathedralOffers = matches
            self.cathedralSearchNote = matches.isEmpty
                ? "No track about \(CathedralFinder.clock(CathedralFinder.targetSeconds)) long was found in your music folder or your Music library. You can choose the file yourself."
                : ""
        }
    }

    /// The chosen music folder, then the Music library folder (skipped if it is missing).
    private func searchFolders() -> [URL] {
        var folders: [URL] = []
        if let musicFolder { folders.append(musicFolder) }
        if let library = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first {
            folders.append(library.appendingPathComponent("Music"))
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The sheet's "Choose a File…": any playable file, with its own length.
    func chooseCathedralFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Choose"
        panel.message = "Choose the track to loop. Its length sets the longest fade."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cathedralOffers = []
        cathedralSearchNote = "Looking…"
        Task { @MainActor in
            let seconds = await Task.detached(priority: .utility) { MusicLibrary.length(of: url) }.value
            if let seconds {
                self.cathedralOffers = [CathedralFinder.Match(url: url, seconds: seconds, nameHit: false)]
                self.cathedralSearchNote = ""
            } else {
                self.cathedralSearchNote = "That file will not open."
            }
        }
    }

    /// The sheet's "Play on Loop": the chosen track and fade start cathedral mode.
    func useCathedralTrack(_ match: CathedralFinder.Match, fade: Double) {
        midiMode = nil
        cathedralFile = match.url
        cathedralFade = fade
        useCathedral = true
        cathedralNotice = ""
        showCathedralSheet = false
        startMusic()
    }

    /// "Back to my music folder": the shuffle again. The track and fade are kept.
    func leaveCathedral() {
        useCathedral = false
        cathedralNotice = ""
        startMusic()
    }

    /// What M plays now, as the Settings radio shows it.
    var musicSource: MusicSource {
        MusicState(useCathedral: useCathedral, midiMode: midiMode,
                   hasMIDIFile: midiFile != nil, hasMusicFolder: musicFolder != nil).source
    }

    /// The Settings choice of what M plays. A source with nothing chosen yet (no folder, track or file) asks for it
    /// first and changes nothing until then. If music is on, the new choice starts at once.
    func chooseSource(_ source: MusicSource) {
        switch source {
        case .folder where musicFolder == nil:
            midiMode = nil
            useCathedral = false
            chooseMusicFolder()
            return
        case .cathedral where cathedralFile == nil:
            midiMode = nil
            findCathedral()
            return
        case .midiFile(let loop) where midiFile == nil:
            midiMode = loop ? .loop : .endless
            useCathedral = false
            chooseMIDIFile()
            return
        default:
            break
        }
        let wasOn = isMusicOn
        if wasOn { stopAllMusic() }
        switch source {
        case .demo(let loop):
            midiFile = nil
            midiMode = loop ? .loop : .endless
            useCathedral = false
        case .folder:
            midiMode = nil
            useCathedral = false
        case .cathedral:
            midiMode = nil
            useCathedral = true
        case .midiFile(let loop):
            midiMode = loop ? .loop : .endless
            useCathedral = false
        }
        cathedralNotice = ""
        if wasOn { toggleMusic(reason: "Settings: source change") }
    }

    /// The Settings resolution choice. Saved on each choice, as the View menu toggle is.
    func setRenderScale(_ scale: RenderScale) {
        renderScale = scale
        Self.defaults.set(scale.rawValue, forKey: Self.scaleKey)
    }

    /// N: the next track. A cathedral loop has only its one track, and the MIDI piece has none, so N does nothing there.
    func nextTrack() {
        if !useCathedral, midi?.isOn != true { music.next() }
    }

    /// Called when the window becomes visible or hidden. Hidden for more than 1.5 s pauses the music (if the
    /// setting is on); the short hide while entering full screen does not. Visible again resumes it, but only
    /// if it was this that paused it, never a pause the user chose.
    func windowVisibilityChanged(visible: Bool) {
        hiddenTask?.cancel()
        if visible {
            if musicPausedByHide {
                musicPausedByHide = false
                if isMusicOn, !isMusicPlaying { togglePause(); print("gullfire-music: resumed, window visible") }
            }
            return
        }
        guard pauseMusicWhenHidden else { return }
        hiddenTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.isMusicOn, self.isMusicPlaying else { return }
            self.togglePause()
            self.musicPausedByHide = true
            print("gullfire-music: paused, window hidden")
        }
    }

    /// M: music on or off. The last choice plays (the MIDI piece, the cathedral, or the folder). With nothing
    /// chosen, the bundled Satie plays endlessly.
    func toggleMusic(reason: String = "M key") {
        if isMusicOn { stopAllMusic(); return }
        if midiMode != nil { startMIDI(reason: reason); return }
        if useCathedral || musicFolder != nil { startMusic(); return }
        startMIDI(reason: reason)
    }

    /// Asks for a MIDI file and plays it endlessly.
    func chooseMIDIFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.prompt = "Choose"
        panel.message = "Choose a MIDI file. It plays as a soft pad, endlessly, with its loop map saved beside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        midiFile = url
        midiMode = midiMode ?? .endless
        useCathedral = false
        showCathedralSheet = false
        startMIDI(reason: "Choose MIDI File")
    }

    /// Asks for the music folder (folders only) and starts playing from it.
    func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your music. Subfolders are included."
        if panel.runModal() == .OK, let url = panel.url {
            musicFolder = url
            midiMode = nil
            startMusic()
        }
    }
}
