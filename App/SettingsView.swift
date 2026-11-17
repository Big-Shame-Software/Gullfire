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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
    }
}
