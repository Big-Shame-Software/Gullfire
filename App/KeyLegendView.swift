import GullfireKit
import SwiftUI

/// The key command legend, bottom right (K shows or hides it). Same type and ink as the HUD. Its panel is black, which
/// is invisible on the black palettes; where the palette's background is not black (Brand) the panel takes the route
/// list's fill (the ink at 20 per cent), so the two boxes match. While the autopilot flies, the hand-flying keys say so in words, never by colour alone.
/// In a window too short for all of it, the rows scroll instead of running off the window.
struct KeyLegendView: View {
    let model: AppModel

    private var ink: Color {
        let c = model.palette.line
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// Black on the black palettes; the route list's fill where the background is coloured.
    private var panel: Color {
        let bg = model.palette.background
        // "The background isn't black" stands for Brand, the only palette with a coloured background today. Revisit this if a
        // palette is added: decide for it whether its panel is black or the route list's fill.
        guard bg.x > 0 || bg.y > 0 || bg.z > 0 else { return .black }
        let c = model.palette.line * 0.2
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// The rows, sized to their content. Tall enough for them, this is the whole legend.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(KeyLegend.groups(glider: model.hasGlider, chooseMap: model.catalog.count >= 2), id: \.title) { group in
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
        .background(panel)
    }

    var body: some View {
        // The plain rows when they fit the window's height; otherwise a vertical scroll of the same rows,
        // at the same width.
        ViewThatFits(in: .vertical) {
            rows
            ScrollView(.vertical) {
                rows
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Key commands")
    }
}
