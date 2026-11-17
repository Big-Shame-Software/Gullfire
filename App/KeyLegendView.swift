import GullfireKit
import SwiftUI

/// The key command legend, bottom right (K shows or hides it). Same type and ink as the HUD, no
/// panel. While the autopilot flies, the hand-flying keys say so in words, never by colour alone.
struct KeyLegendView: View {
    let model: AppModel

    private var ink: Color {
        let c = model.palette.line
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(KeyLegend.groups(glider: model.hasGlider), id: \.title) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).opacity(0.7)
                    ForEach(group.entries, id: \.key) { entry in
                        let idle = entry.manualOnly && model.hud.cruising
                        Text("\(entry.key)  \(entry.label)" + (idle ? "  (MANUAL ONLY)" : ""))
                            .opacity(idle ? 0.55 : 1)
                    }
                }
            }
        }
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(ink)
        .padding(16)
        .background(Color.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Key commands")
    }
}
