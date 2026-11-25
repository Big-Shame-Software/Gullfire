#if DEBUG
import AppKit
import GullfireKit
import ScreenCaptureKit
import SwiftUI

/// Debug-only capture hook. With GULLFIRE_SNAPSHOT_TO=<file.png> set, Gullfire shows one view, waits until it
/// has drawn, writes that one window to the PNG with ScreenCaptureKit (the window as it appears on screen, Metal
/// content included), and quits. GULLFIRE_SNAPSHOT_VIEW picks the view: "flight" (the main window, the default; with
/// GULLFIRE_CITIES set and more than one map installed it is the launch picker), "about", "empty" or "settings". Appearance comes from GULLFIRE_APPEARANCE, as elsewhere.
///
/// The hook never enters full screen and never switches Space. The flight window is set to a fixed 1280 x 720
/// content size, and FlightView skips its own full-screen start while the hook is on. The hook brings Gullfire to
/// the front (activate and orderFrontRegardless) so that its window is on screen for the capture.
/// The "about" view takes the loaded city's attribution, as the real About window does. The "empty" view is
/// EmptyStateView given the real default path from AppModel.cityDirectory(). Nothing is read, moved or written.
@MainActor
enum SnapshotHook {
    enum Failure: Error { case noWindow, fullScreen, notOnScreen, encode }

    static var outputPath: String? { ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_TO"] }
    private static var view: String { ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_VIEW"] ?? "flight" }
    /// The flight window's content size for the capture, in points. 1280 x 720 (16:9, a size that suits a README picture)
    /// unless GULLFIRE_SNAPSHOT_SIZE=WxH asks for another, e.g. 800x500 for the narrow-window check.
    static var flightSize: NSSize {
        let parts = (ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        if parts.count == 2, parts[0] >= 300, parts[1] >= 200 { return NSSize(width: parts[0], height: parts[1]) }
        return NSSize(width: 1280, height: 720)
    }

    /// Starts the capture when the hook is on. Both closures are read after the windows have drawn.
    static func run(attribution: @escaping @MainActor () -> String?, mainWindow: @escaping @MainActor () -> NSWindow?) {
        guard let path = outputPath else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            do {
                let window: NSWindow?
                switch view {
                case "about":
                    window = host(AboutView(attribution: attribution()), size: nil)
                case "empty":
                    window = host(EmptyStateView(looked: AppModel.cityDirectory().path), size: NSSize(width: 960, height: 640))
                case "settings":
                    // The Settings window, which GULLFIRE_SHOW_SETTINGS=1 opens; GULLFIRE_SETTINGS_TAB=maps picks the tab and
                    // GULLFIRE_FAKE_RAM_GB / GULLFIRE_FAKE_FREE_GB pretend to be a smaller Mac.
                    // A tabbed Settings window is titled with the selected tab ("Music", "View", "Maps"), not "Settings".
                    window = NSApp.windows.first { $0.isVisible && (["Music", "View", "Maps"].contains($0.title) || $0.title.localizedCaseInsensitiveContains("settings")) }
                    guard let settings = window else { throw Failure.noWindow }
                    switch ProcessInfo.processInfo.environment["GULLFIRE_APPEARANCE"] {
                    case "dark": settings.appearance = NSAppearance(named: .darkAqua)
                    case "light": settings.appearance = NSAppearance(named: .aqua)
                    default: break
                    }
                default:
                    window = mainWindow()
                    guard let main = window else { throw Failure.noWindow }
                    switch ProcessInfo.processInfo.environment["GULLFIRE_APPEARANCE"] {
                    case "dark": main.appearance = NSAppearance(named: .darkAqua)
                    case "light": main.appearance = NSAppearance(named: .aqua)
                    default: break
                    }
                    if main.styleMask.contains(.fullScreen) { throw Failure.fullScreen }
                    main.setContentSize(flightSize)
                    main.center()
                }
                try await capture(window: window, to: path)
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// GULLFIRE_CHOOSEMAP_PROOF=<folder>: the Choose Map… proof, in this process, with no desktop keys or clicks. Launched in flight
    /// (GULLFIRE_CITY), full screen as the app starts: logs the menu item's state, captures the flight with the key list,
    /// fires the menu item, captures the picker, chooses a map by name (GULLFIRE_CHOOSEMAP_TO, default Chicago) the way the
    /// picker's Fly button does, captures that flight, and quits. Writes proof.log and three PNGs in the folder.
    static func chooseMapProof(model: AppModel) {
        // GULLFIRE_QUIT_PROOF=<seconds>: an in-process terminate after that long, so the quit-source line can be read in the log.
        if let seconds = ProcessInfo.processInfo.environment["GULLFIRE_QUIT_PROOF"].flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.terminate(nil)
            }
            return
        }
        guard let folder = ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_PROOF"] else { return }
        let target = ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_TO"] ?? "Chicago"
        let logURL = URL(fileURLWithPath: folder).appendingPathComponent("proof.log")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            print("choosemap-proof: " + text)
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data((text + "\n").utf8)); try? h.close() }
        }
        func mainWindow() -> NSWindow? {
            NSApp.windows.filter(\.isVisible).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        func footprintMB() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
        }
        func menuItem() -> NSMenuItem? {
            NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Flight" }?.items.first { $0.title == ChooseMap.menuTitle }
        }
        func describeItem(_ label: String) {
            guard let item = menuItem() else { log("\(label): no \(ChooseMap.menuTitle) menu item found"); return }
            let flightMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Flight" }
            log("\(label): app active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) firstResponder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none") flight menu: " + (flightMenu?.items.map { "\($0.title)=\($0.isEnabled)" }.joined(separator: ", ") ?? "none"))
            log("\(label): menu item '\(item.title)' enabled=\(item.isEnabled) keyEquivalent='\(item.keyEquivalent)' command=\(item.keyEquivalentModifierMask.contains(.command)) maps=\(model.catalog.count) inFlight=\(model.city != nil)")
        }
        Task { @MainActor in
            do {
                // Start the way a person does: from the picker, choose the first map (GULLFIRE_CHOOSEMAP_FROM, default CookCounty).
                var waited = 0.0
                while model.catalog.isEmpty && model.city == nil && waited < 30 { try await Task.sleep(for: .seconds(1)); waited += 1 }
                if model.city == nil {
                    let from = ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_FROM"] ?? "CookCounty"
                    guard let first = model.catalog.first(where: { $0.directory.lastPathComponent == from }) else { log("FAIL: no map named \(from)"); NSApp.terminate(nil); return }
                    log("picker lists \(model.catalog.count) maps; choosing \(from) as the Fly button does")
                    model.chooseCity(first)
                }
                // Wait for flight, full screen and some seconds of flying.
                waited = 0
                let needsFullScreen = ProcessInfo.processInfo.environment["GULLFIRE_WINDOWED"] == nil
                while (model.city == nil || (needsFullScreen && !(mainWindow()?.styleMask.contains(.fullScreen) ?? false))) && waited < 90 {
                    try await Task.sleep(for: .seconds(1)); waited += 1
                }
                try await Task.sleep(for: .seconds(8))
                let w = mainWindow()
                log("flight: map=\(model.city?.manifest.name ?? "none") fullScreen=\(w?.styleMask.contains(.fullScreen) ?? false) window=\(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0)) footprint=\(footprintMB()) MB keysShown=\(model.showKeys)")
                // GULLFIRE_CHOOSEMAP_COLD=1: touch nothing of the menu before the first Command-O, as a person's first key press would.
                let cold = ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_COLD"] != nil
                describeItem("before")   // a plain read of the item's state; nothing is refreshed
                if let trips = ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_TRIPS"].flatMap(Int.init) {
                    // Round trips: first map, picker, second map, picker. The footprint at each picker must level off, not climb.
                    let first = ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_FROM"] ?? "CookCounty"
                    let second = target
                    for trip in 1...trips {
                        for (name, label) in [(second, "Chicago"), (first, "Cook")] {
                            _ = NSApp.mainMenu?.performKeyEquivalent(with: Self.commandO())
                            try await Task.sleep(for: .seconds(3))
                            let early = footprintMB()
                            try await Task.sleep(for: .seconds(5))
                            log("trip \(trip) picker after \(label == "Chicago" ? first : second): \(early) MB at 3 s, \(footprintMB()) MB at 8 s (inPicker=\(model.city == nil))")
                            guard let entry = model.catalog.first(where: { $0.directory.lastPathComponent == name }) else { log("FAIL: no map \(name)"); NSApp.terminate(nil); return }
                            model.chooseCity(entry)
                            try await Task.sleep(for: .seconds(8))
                            log("trip \(trip) flying \(model.city?.manifest.name ?? "none"): \(footprintMB()) MB")
                        }
                    }
                    log("done")
                    NSApp.terminate(nil)
                    return
                }
                model.showKeys = true
                // Music on, as the M key does, so the switch can be checked against it.
                if !model.isMusicOn { model.toggleMusic(reason: "choosemap proof") }
                try await Task.sleep(for: .seconds(3))
                @MainActor func music(_ label: String) { log("\(label): music on=\(model.isMusicOn) playing=\(model.isMusicPlaying) status='\(model.musicStatus)'") }
                music("flight")
                try await capture(window: mainWindow(), to: folder + "/1-flight-full-screen-key-list.png")
                log("captured 1-flight-full-screen-key-list.png")
                // Fire the menu item (the shortcut's own action), with the menu bar hidden by full screen.
                guard let item = menuItem(), let menu = item.menu, let index = Optional(menu.index(of: item)) else { log("FAIL: no menu item"); NSApp.terminate(nil); return }
                let enabled = cold ? true : item.isEnabled
                let handledByKey = NSApp.mainMenu?.performKeyEquivalent(with: Self.commandO()) ?? false
                log("performKeyEquivalent(Command-O) on the main menu: handled=\(handledByKey)")
                try await Task.sleep(for: .seconds(2))
                if model.city != nil { menu.performActionForItem(at: index) }
                try await Task.sleep(for: .seconds(4))
                var inPicker = model.city == nil
                if !inPicker, let action = item.action {
                    log("performActionForItem did not act; sending the action directly")
                    NSApp.sendAction(action, to: item.target, from: item)
                    try await Task.sleep(for: .seconds(4)); inPicker = model.city == nil
                }
                let w2 = mainWindow()
                log("after Choose Map…: enabled=\(enabled) inPicker=\(inPicker) fullScreen=\(w2?.styleMask.contains(.fullScreen) ?? false) footprint=\(footprintMB()) MB")
                describeItem("in picker")
                try await capture(window: mainWindow(), to: folder + "/2-picker-after-choose-map.png")
                log("captured 2-picker-after-choose-map.png")
                guard let entry = model.catalog.first(where: { $0.directory.lastPathComponent == target }) else { log("FAIL: no map named \(target)"); NSApp.terminate(nil); return }
                model.chooseCity(entry)
                try await Task.sleep(for: .seconds(12))
                log("after choosing \(target): map=\(model.city?.manifest.name ?? "none") footprint=\(footprintMB()) MB")
                describeItem("after")
                try await capture(window: mainWindow(), to: folder + "/3-flight-after-choosing.png")
                log("captured 3-flight-after-choosing.png")
                music("Chicago flight")
                // And back: Command-O again, the picker, then the first map.
                _ = NSApp.mainMenu?.performKeyEquivalent(with: Self.commandO())
                try await Task.sleep(for: .seconds(4))
                log("second Command-O: inPicker=\(model.city == nil) footprint=\(footprintMB()) MB")
                music("picker")
                try await capture(window: mainWindow(), to: folder + "/4-picker-again.png")
                if let first = model.catalog.first(where: { $0.directory.lastPathComponent == (ProcessInfo.processInfo.environment["GULLFIRE_CHOOSEMAP_FROM"] ?? "CookCounty") }) {
                    model.chooseCity(first)
                    try await Task.sleep(for: .seconds(12))
                    log("back on \(model.city?.manifest.name ?? "none") footprint=\(footprintMB()) MB")
                    music("back")
                    try await capture(window: mainWindow(), to: folder + "/5-flight-back.png")
                }
                log("done")
                NSApp.terminate(nil)
            } catch {
                log("FAIL: \(error)")
                exit(1)
            }
        }
    }

    /// A Command-O key-down event, as the main menu's key-equivalent search receives it. Built in this process; nothing is sent to the desktop.
    private static func commandO() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: "o", charactersIgnoringModifiers: "o",
                         isARepeat: false, keyCode: 31)!
    }

    /// Hosts a view in its own window. A nil size takes the view's own fitting size, as a real window would.
    private static func host<V: View>(_ content: V, size: NSSize?) -> NSWindow {
        let hosting: NSHostingView<AnyView>
        if let size {
            hosting = NSHostingView(rootView: AnyView(content.frame(width: size.width, height: size.height)))
        } else {
            hosting = NSHostingView(rootView: AnyView(content.fixedSize()))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        switch ProcessInfo.processInfo.environment["GULLFIRE_APPEARANCE"] {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func capture(window: NSWindow?, to path: String) async throws {
        guard let window else { throw Failure.noWindow }
        // GULLFIRE_SNAPSHOT_OFFSCREEN=1: draws the window's content view into a bitmap in this process. Gullfire is not
        // brought to the front, no screen is read and the display may be asleep. The title bar is not part of the picture.
        let noFocus = ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_OFFSCREEN"] == "2"
        if ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_OFFSCREEN"] == "1" {
            guard let content = window.contentView else { throw Failure.noWindow }
            content.layoutSubtreeIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw Failure.encode }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure.encode }
            try png.write(to: URL(fileURLWithPath: path))
            return
        }
        // Brings Gullfire to the front, so its window is on screen for the capture. It does not change Space.
        // GULLFIRE_SNAPSHOT_OFFSCREEN=2 skips both: the window is captured where it is, behind other windows if need be.
        if !noFocus {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
        }
        try await Task.sleep(for: .milliseconds(500))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mine = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let shot: SCWindow
        if let exact = mine.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
            shot = exact
        } else {
            // The window numbers differ between AppKit and ScreenCaptureKit here, so match our own window by size.
            let wanted = window.frame.size
            let candidates = mine.sorted {
                abs($0.frame.width - wanted.width) + abs($0.frame.height - wanted.height)
                    < abs($1.frame.width - wanted.width) + abs($1.frame.height - wanted.height)
            }
            guard let best = candidates.first else { throw Failure.notOnScreen }
            shot = best
        }
        let filter = SCContentFilter(desktopIndependentWindow: shot)
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(shot.frame.width * scale)
        config.height = Int(shot.frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure.encode
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
