import AppKit
import GameController
import MetalKit
import GullfireKit
import QuartzCore

private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}

/// Held-key and modifier state. Keys are tracked from key-down and key-up, never from
/// key repeat, so a held key is one continuous input.
@MainActor
final class FlightInput {
    private(set) var held: Set<String> = []
    private var shift = false
    private var control = false
    /// Throttle is held, not set: Shift raises it and Control lowers it, 0.3 per second.
    var throttle = 0.5

    /// Mouse flight (J): the pointer drives roll and pitch, the scroll wheel the throttle.
    private var mouse = MouseFlight()
    /// The settings (sensitivity, invert pitch) are read from here each frame, so a change applies at once.
    weak var model: AppModel?
    /// True while the mouse is taken for flight. Turning it off discards the pending motion and centres the stick.
    var mouseOn = false {
        didSet {
            guard oldValue, !mouseOn else { return }
            mouseDX = 0
            mouseDY = 0
            mouseWheel = 0
            mouse.reset()
        }
    }
    private var mouseDX = 0.0
    private var mouseDY = 0.0
    private var mouseWheel = 0.0

    func keyDown(_ key: String) { held.insert(key) }
    func keyUp(_ key: String) { held.remove(key) }

    func setModifiers(shift: Bool, control: Bool) {
        self.shift = shift
        self.control = control
    }

    /// Pointer and wheel motion since the last frame. Ignored while mouse flight is off.
    /// - Parameters:
    ///   - dx: pointer movement along x in points (right positive).
    ///   - dy: pointer movement along y in points (AppKit event sign: forward is negative).
    ///   - wheel: scroll input (positive raises throttle).
    func addMouse(dx: Double, dy: Double, wheel: Double) {
        guard mouseOn else { return }
        mouseDX += dx
        mouseDY += dy
        mouseWheel += wheel
    }

    /// The pilot's request for this frame: keyboard, plus the controller if one is connected.
    func control(dt: Double) -> ControlInput {
        var c = ControlInput()
        let up: Double = held.contains("s") ? 1 : 0
        let down: Double = held.contains("w") ? 1 : 0
        let right: Double = held.contains("d") ? 1 : 0
        let left: Double = held.contains("a") ? 1 : 0
        let yawRight: Double = held.contains("e") ? 1 : 0
        let yawLeft: Double = held.contains("q") ? 1 : 0
        c.pitch = up - down
        c.roll = right - left
        c.yaw = yawRight - yawLeft
        let raise: Double = shift ? 0.3 * dt : 0
        let lower: Double = control ? 0.3 * dt : 0
        throttle = clamp(throttle + raise - lower, 0, 1)
        if mouseOn {
            mouse.sensitivity = model?.mouseSensitivity ?? 1
            mouse.invertPitch = model?.mouseInvert ?? false
            let m = mouse.update(deltaX: mouseDX, deltaY: mouseDY, wheel: mouseWheel, dt: dt)
            mouseDX = 0
            mouseDY = 0
            mouseWheel = 0
            c.roll = clamp(c.roll + m.roll, -1, 1)
            c.pitch = clamp(c.pitch + m.pitch, -1, 1)
            throttle = clamp(throttle + m.throttleDelta, 0, 1)
        }
        c.throttle = throttle
        addController(to: &c, dt: dt)
        return c
    }

    /// Game controller (`extendedGamepad`): left stick pitch and roll, triggers throttle, shoulder
    /// buttons rudder. Polled once per frame. UNVERIFIED on hardware (no controller has been tested).
    private func addController(to c: inout ControlInput, dt: Double) {
        guard let pad = GCController.controllers().first?.extendedGamepad else { return }
        func dead(_ v: Float) -> Double {
            let d = Double(v)
            return abs(d) < 0.15 ? 0 : d
        }
        let stickPitch = dead(pad.leftThumbstick.yAxis.value)
        let stickRoll = dead(pad.leftThumbstick.xAxis.value)
        let shoulders = Double(pad.rightShoulder.value) - Double(pad.leftShoulder.value)
        let triggers = (Double(pad.rightTrigger.value) - Double(pad.leftTrigger.value)) * 0.3 * dt
        c.pitch = clamp(c.pitch + stickPitch, -1, 1)
        c.roll = clamp(c.roll + stickRoll, -1, 1)
        c.yaw = clamp(c.yaw + shoulders, -1, 1)
        throttle = clamp(throttle + triggers, 0, 1)
        c.throttle = throttle
    }
}

/// The Metal view, and the window's first responder, so it receives the flight keys.
final class FlightMTKView: MTKView {
    var input: FlightInput?
    /// Holds the `mouseFlight` flag the HUD shows.
    weak var model: AppModel?
    /// Keys that are not held controls (KeyLegend.actionKeys).
    var onAction: ((String) -> Void)?

    /// Observers that give the mouse back: window lost key, app resigned active, app quitting, window gone.
    private var releaseObservers: [NSObjectProtocol] = []

    /// Mouse flight is on. The input owns this state.
    private var mouseOn: Bool { input?.mouseOn ?? false }

    override var acceptsFirstResponder: Bool { true }

    /// Called when the view joins a window, so the app can install its occlusion pause then.
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeReleaseEvents()
        onWindowChange?()
    }

    /// Watches the events that must give the mouse back. Replaces the observers of any earlier window.
    private func observeReleaseEvents() {
        for token in releaseObservers { NotificationCenter.default.removeObserver(token) }
        releaseObservers = []
        guard let window else {
            releaseMouse()   // left its window: the mouse must not stay taken
            return
        }
        releaseObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseMouse() }
        })
        releaseObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseMouse() }
        })
        releaseObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseMouse() }
        })
    }

    /// J: take the mouse for flight, or give it back.
    func toggleMouse() {
        if mouseOn { releaseMouse() } else { takeMouse() }
    }

    /// Takes the mouse: the pointer is hidden and frozen, and its motion becomes flight input.
    /// Does nothing if it is already taken, so hide and unhide stay balanced.
    private func takeMouse() {
        guard !mouseOn, let input else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        window?.acceptsMouseMovedEvents = true
        input.mouseOn = true
        model?.mouseFlight = true
    }

    /// Gives the mouse back: the pointer shows and moves freely again. Idempotent; does nothing unless
    /// mouse flight is on. Called by Esc, by losing key window or app focus, by quitting, and by leaving the window.
    func releaseMouse() {
        guard mouseOn else { return }
        input?.mouseOn = false
        model?.mouseFlight = false
        window?.acceptsMouseMovedEvents = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    override func keyDown(with event: NSEvent) {
        // Esc always gives the mouse back, and does nothing else.
        if event.keyCode == 53 { releaseMouse(); return }
        guard !event.isARepeat else { return }   // key repeat is ignored; held keys come from key-down/up
        if event.keyCode == 49 { onAction?("space"); return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if KeyLegend.heldKeys.contains(key) {
            input?.keyDown(key)
        } else if !key.isEmpty {
            onAction?(key)
        }
    }

    override func keyUp(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        input?.keyUp(key)
    }

    override func flagsChanged(with event: NSEvent) {
        input?.setModifiers(shift: event.modifierFlags.contains(.shift),
                            control: event.modifierFlags.contains(.control))
    }

    override func mouseMoved(with event: NSEvent) { addMouse(event) }
    override func mouseDragged(with event: NSEvent) { addMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { addMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { addMouse(event) }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report many small precise deltas; scale them down to the wheel's size.
        let wheel = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.1 : event.scrollingDeltaY
        input?.addMouse(dx: 0, dy: 0, wheel: Double(wheel))
    }

    private func addMouse(_ event: NSEvent) {
        input?.addMouse(dx: Double(event.deltaX), dy: Double(event.deltaY), wheel: 0)
    }
}
