import AppKit
import SwiftUI

/// The window's content: the flight view, with the HUD over it. The keys are handled by the Metal
/// view, which is the window's first responder (see FlightInput.swift).
struct FlightView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            MetalView(model: model)
            if model.showHUD {
                HUDView(model: model)
            } else if model.mouseFlight || model.pickMode || model.notice != nil || !model.hud.endless.isEmpty {
                ModeNoticeView(model: model)
            }
            if model.showKeys {
                KeyLegendView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            // Last, so the route list draws over the rest, at the bottom centre. It shows on its own after C, whatever H is set to.
            RouteListView(model: model)
        }
        .ignoresSafeArea()
        .onAppear {
            model.timing.mark("window appeared")
            model.timing.checkpoint("mark 5 window shown")
            #if DEBUG
            // Test hook for the layout captures, Debug builds only: GULLFIRE_WINDOW_SIZE=WxH sets the window's content size.
            if let size = ProcessInfo.processInfo.environment["GULLFIRE_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2 {
                DispatchQueue.main.async {
                    let window = NSApplication.shared.windows.first(where: { $0.isVisible })
                    window?.setContentSize(NSSize(width: size[0], height: size[1]))
                    // GULLFIRE_WINDOW_CORNER=bottomright|bottomleft|topright|topleft puts the window in that corner of the main screen
                    // (the visible frame, so clear of the Dock and menu bar): a memory run that keeps the window uncovered.
                    if let corner = ProcessInfo.processInfo.environment["GULLFIRE_WINDOW_CORNER"], let window, let screen = NSScreen.main {
                        let v = screen.visibleFrame, f = window.frame
                        let x = corner.hasSuffix("right") ? v.maxX - f.width : v.minX
                        let y = corner.hasPrefix("top") ? v.maxY - f.height : v.minY
                        window.setFrameOrigin(NSPoint(x: x, y: y))
                    }
                }
            }
            #endif
            // Start full screen unless asked not to (GULLFIRE_WINDOWED=1 for a window).
            guard ProcessInfo.processInfo.environment["GULLFIRE_WINDOWED"] == nil else { return }
            #if DEBUG
            // The capture hook (SnapshotHook) sets the window's size itself and never goes full screen.
            guard ProcessInfo.processInfo.environment["GULLFIRE_SNAPSHOT_TO"] == nil else { return }
            #endif
            DispatchQueue.main.async {
                // Toggle only when not already full screen: macOS can restore the window in full
                // screen, and an unconditional toggle would then take it out again.
                if let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
                   !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
    }
}
