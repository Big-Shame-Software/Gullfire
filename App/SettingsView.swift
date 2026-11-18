import AppKit
import GullfireKit
import SwiftUI

/// The Settings window (Gullfire > Settings): a Music tab and a View tab, each a grouped form at a fixed width.
/// System controls, colours and type only; no brand styling inside the window. The choices are the
/// ones the keys already use, so nothing an install saved is lost.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = SettingsView.startTab

    enum Tab: Hashable { case music, view }

    #if DEBUG
    /// Test hook for the screenshots, Debug builds only: GULLFIRE_SETTINGS_TAB=view opens the View tab first.
    private static var startTab: Tab {
        ProcessInfo.processInfo.environment["GULLFIRE_SETTINGS_TAB"] == "view" ? .view : .music
    }
    #else
    private static var startTab: Tab { .music }
    #endif

    var body: some View {
        TabView(selection: $tab) {
            MusicSettingsTab(model: model)
                .tabItem { Label("Music", systemImage: "music.note") }
                .tag(Tab.music)
            ViewSettingsTab(model: model)
                .tabItem { Label("View", systemImage: "eye") }
                .tag(Tab.view)
        }
        .frame(width: 520)
    }
}

/// The Music tab: one Source choice (what M plays), what it needs, what is playing, the playback settings and the keys.
struct MusicSettingsTab: View {
    @Bindable var model: AppModel

    /// The four kinds of source the radio group offers. Demo and MIDI file share one MIDI mode, so the loop choice is
    /// separate from the kind.
    private enum Kind: Hashable { case demo, folder, cathedral, midiFile }

    private var kind: Kind {
        switch model.musicSource {
        case .demo: .demo
        case .folder: .folder
        case .cathedral: .cathedral
        case .midiFile: .midiFile
        }
    }

    private var loop: Bool { model.midiMode == .loop }

    private func source(for kind: Kind, loop: Bool) -> MusicSource {
        switch kind {
        case .demo: .demo(loop: loop)
        case .folder: .folder
        case .cathedral: .cathedral
        case .midiFile: .midiFile(loop: loop)
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: { kind }, set: { model.chooseSource(source(for: $0, loop: loop)) })
    }

    private var loopBinding: Binding<Bool> {
        Binding(get: { loop }, set: { model.chooseSource(source(for: kind, loop: $0)) })
    }

    private var nowPlaying: String {
        guard model.isMusicOn else { return "Off: press M to play" }
        return model.nowPlayingTitle.isEmpty ? "Playing" : model.nowPlayingTitle
    }

    private var keysLine: String {
        if kind == .folder {
            return "N next track, M music on or off, comma play or pause."
        }
        return "M music on or off, comma play or pause. N does nothing for this source."
    }

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: kindBinding) {
                    Text("Demo piece: Satie, Gymnopédie No. 1").tag(Kind.demo)
                    Text("My music folder").tag(Kind.folder)
                    Text("Cathedral track").tag(Kind.cathedral)
                    Text("A MIDI file").tag(Kind.midiFile)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("Source")
                details
            } header: {
                Text("Source")
            }

            Section {
                LabeledContent("Now playing") {
                    Text(nowPlaying).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if !model.musicStatus.isEmpty {
                    Text(model.musicStatus).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Now playing")
            }

            Section {
                if kind == .folder || kind == .cathedral {
                    LabeledContent("Crossfade") {
                        Stepper(value: $model.crossfadeSeconds, in: 1...12, step: 1) {
                            Text("\(Int(model.crossfadeSeconds)) seconds")
                        }
                    }
                }
                Toggle("Pause music while the window is hidden", isOn: $model.pauseMusicWhenHidden)
            } header: {
                Text("Playback")
            }

            Section {
                Text(keysLine).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Keys")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .sheet(isPresented: $model.showCathedralSheet) {
            CathedralSheet(model: model)
        }
    }

    /// What the chosen source needs: its loop choice, its folder, track or file, and the Debussy note for a MIDI file.
    @ViewBuilder
    private var details: some View {
        switch kind {
        case .demo:
            Picker("Play", selection: loopBinding) {
                Text("Endless").tag(false)
                Text("Loop").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Endless or loop")
        case .folder:
            LabeledContent("Folder") {
                HStack {
                    Text(model.musicFolder?.lastPathComponent ?? "None chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { model.chooseMusicFolder() }
                        .accessibilityLabel("Choose music folder")
                }
            }
        case .cathedral:
            LabeledContent("Track") {
                HStack {
                    Text(model.cathedralFile?.lastPathComponent ?? "None chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Find Track…") { model.findCathedral() }
                }
            }
            if !model.cathedralNotice.isEmpty {
                Text(model.cathedralNotice).font(.callout).foregroundStyle(.secondary)
            }
        case .midiFile:
            Picker("Play", selection: loopBinding) {
                Text("Endless").tag(false)
                Text("Loop").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Endless or loop")
            LabeledContent("File") {
                HStack {
                    Text(model.midiFile?.lastPathComponent ?? "None chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { model.chooseMIDIFile() }
                        .accessibilityLabel("Choose MIDI file")
                }
            }
            DisclosureGroup("Looking for the Debussy?") {
                Text("Debussy's La cathédrale engloutie is not in this app. Its MIDI file is yours to fetch and to check the terms of. The IMSLP page for Debussy's Préludes lists each file's licence.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("IMSLP: Préludes, Book 1 (Debussy)",
                     destination: URL(string: "https://imslp.org/wiki/Preludes_(Book_1)_(Debussy,_Claude)")!)
            }
        }
    }
}

/// The View tab: the settings the View menu and the keys already change, and that are saved.
struct ViewSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Palette", selection: $model.palette) {
                    Text("Default").tag(Palette.standard)
                    Text("Brand").tag(Palette.brand)
                    Text("Lime").tag(Palette.lime)
                }
                Picker("Resolution", selection: Binding(
                    get: { model.renderScale },
                    set: { model.setRenderScale($0) }
                )) {
                    Text("Native").tag(RenderScale.native)
                    Text("Half").tag(RenderScale.half)
                }
            } footer: {
                Text("Half resolution costs about a quarter as much to draw, and it is less sharp.")
            }

            Section {
                Toggle("Show key commands", isOn: $model.showKeys)
            }

            Section {
                LabeledContent("Sensitivity") {
                    HStack {
                        Slider(value: $model.mouseSensitivity, in: 0.25...4)
                            .frame(width: 200)
                            .accessibilityLabel("Mouse sensitivity")
                        Text(String(format: "%.2f", model.mouseSensitivity))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Invert pitch", isOn: $model.mouseInvert)
                LabeledContent("Try it") {
                    MouseDemoPad(sensitivity: model.mouseSensitivity, invert: model.mouseInvert)
                        .frame(width: 260, height: 130)
                }
            } header: {
                Text("Mouse flight")
            } footer: {
                Text("Press J in flight to fly with the mouse. Esc gives it back.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
    }
}


/// A little stick to try the mouse settings on. Move the pointer over the pad: the dot is the stick, driven by the same
/// `MouseFlight` that flies the aircraft, with the current sensitivity and invert. The words say what it would do, so
/// nothing depends on colour or on the dot alone.
struct MouseDemoPad: NSViewRepresentable {
    var sensitivity: Double
    var invert: Bool

    func makeNSView(context: Context) -> MouseDemoNSView { MouseDemoNSView() }

    func updateNSView(_ view: MouseDemoNSView, context: Context) {
        view.flight.sensitivity = sensitivity
        view.flight.invertPitch = invert
    }
}

final class MouseDemoNSView: NSView {
    var flight = MouseFlight()
    private var dx = 0.0, dy = 0.0
    private var roll = 0.0, pitch = 0.0
    private var timer: Timer?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        dx += Double(event.deltaX)
        dy += Double(event.deltaY)
    }

    private func tick() {
        let out = flight.update(deltaX: dx, deltaY: dy, wheel: 0, dt: 1.0 / 60)
        dx = 0
        dy = 0
        guard out.roll != roll || out.pitch != pitch else { return }
        roll = out.roll
        pitch = out.pitch
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let frame = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.separatorColor.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        let cx = box.midX, cy = box.midY
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: box.minX + 8, y: cy)); cross.line(to: NSPoint(x: box.maxX - 8, y: cy))
        cross.move(to: NSPoint(x: cx, y: box.minY + 8)); cross.line(to: NSPoint(x: cx, y: box.maxY - 8))
        NSColor.separatorColor.setStroke()
        cross.stroke()

        // Mouse forward (up the pad) is nose down, so pitch -1 sits at the top.
        let r = 7.0
        let x = cx + roll * (box.width / 2 - 14)
        let y = cy + pitch * (box.height / 2 - 14)
        let dot = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        NSColor.labelColor.setFill()
        dot.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let bank = abs(roll) < 0.05 ? "LEVEL" : (roll > 0 ? "BANK RIGHT" : "BANK LEFT")
        let nose = abs(pitch) < 0.05 ? "" : (pitch < 0 ? "NOSE DOWN" : "NOSE UP")
        "\(bank)  \(nose)".draw(at: NSPoint(x: box.minX + 10, y: box.maxY - 18), withAttributes: attrs)
        "Move the pointer here".draw(at: NSPoint(x: box.minX + 10, y: box.minY + 6), withAttributes: attrs)
    }

}
