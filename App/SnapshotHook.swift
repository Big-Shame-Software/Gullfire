#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Debug-only capture hook. With GULLFIRE_SNAPSHOT_TO=<file.png> set, Gullfire shows one view, waits until it
/// has drawn, writes that one window to the PNG with ScreenCaptureKit (the window as it appears on screen, Metal
/// content included), and quits. GULLFIRE_SNAPSHOT_VIEW picks the view: "flight" (the main window, the default),
/// "about" or "empty". Appearance comes from GULLFIRE_APPEARANCE, as elsewhere.
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
                default:
                    window = mainWindow()
                    guard let main = window else { throw Failure.noWindow }
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
        // Brings Gullfire to the front, so its window is on screen for the capture. It does not change Space.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
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
