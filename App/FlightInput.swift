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

    func keyDown(_ key: String) { held.insert(key) }
    func keyUp(_ key: String) { held.remove(key) }

    func setModifiers(shift: Bool, control: Bool) {
        self.shift = shift
        self.control = control
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
    /// Keys that are not held controls (KeyLegend.actionKeys).
    var onAction: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Called when the view joins a window, so the app can install its occlusion pause then.
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    override func keyDown(with event: NSEvent) {
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
}
