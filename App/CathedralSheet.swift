import GullfireKit
import SwiftUI

/// The cathedral sheet: the track the search found (or the one chosen by hand), its length, and the
/// fade. The fade starts at the longest the track allows, half its length.
struct CathedralSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var fade = 0.0

    private var chosen: CathedralFinder.Match? {
        model.cathedralOffers.indices.contains(index) ? model.cathedralOffers[index] : nil
    }

    private var longest: Double {
        chosen.map { CrossfadePlan.longestLoopFade(duration: $0.seconds) } ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let chosen {
                Text("Here's the song we found").font(.headline)
                if model.cathedralOffers.count > 1 {
                    Picker("Song", selection: $index) {
                        ForEach(model.cathedralOffers.indices, id: \.self) { i in
                            Text(model.cathedralOffers[i].title).tag(i)
                        }
                    }
                }
                Form {
                    LabeledContent("Title") {
                        Text(chosen.title).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Format") { Text(chosen.format) }
                    LabeledContent("Length") { Text(CathedralFinder.clock(chosen.seconds)) }
                    LabeledContent("Fade") {
                        HStack {
                            Slider(value: $fade, in: 1...max(1, longest))
                                .frame(width: 220)
                            Text("\(Int(fade)) seconds").monospacedDigit()
                        }
                    }
                }
                .formStyle(.grouped)
                Text("The fade starts at the longest the track allows, half its length. Drag it shorter for a quicker blend.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.cathedralSearchNote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose a File…") { model.chooseCathedralFile() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Play on Loop") {
                    if let chosen { model.useCathedralTrack(chosen, fade: fade) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { fade = longest }
        .onChange(of: index) { fade = longest }
        .onChange(of: model.cathedralOffers) {
            index = 0
            fade = longest
        }
    }
}
