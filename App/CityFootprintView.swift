import SwiftUI
import GullfireKit

/// The maps that share the highlighted map's origin, drawn to scale around the Loop. Every picker
/// diagram uses the same scale (`frameM`, the largest extent in the catalog), so Chicago looks as small
/// as it is next to Cook County. The highlighted map has a thick outline and its name in bold; the others
/// are thin and dashed. Shape and label carry the difference; colour is not used.
struct CityFootprintView: View {
    /// Maps sharing the highlighted map's origin, including the highlighted one.
    let family: [CityEntry]
    let highlight: CityEntry
    /// Metres across the longer side of the canvas at 100%: the largest extent of any map in the catalog.
    let frameM: Double
    /// The name a person reads for a map (the recipe list's display name), used for every label drawn here.
    let label: (CityEntry) -> String
    /// Whether each map's name is drawn on its outline. Rows turn it off: the name is printed beside them.
    var showsLabels = true

    /// Largest first: the order the outlines are drawn in, and the numbers the key lists.
    private var ranked: [CityEntry] { family.sorted(by: { $0.areaKm2 > $1.areaKm2 }) }

    var body: some View {
        if showsLabels {
            VStack(alignment: .leading, spacing: 6) {
                diagram
                    .frame(height: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                // The key: a number on each outline, its name here. The highlighted map is bold, as its outline is thick.
                ForEach(Array(ranked.enumerated()), id: \.offset) { index, entry in
                    Text("\(index + 1)  \(label(entry))")
                        .font(entry.name == highlight.name ? .caption.bold() : .caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            diagram
        }
    }

    private var diagram: some View {
        Canvas { context, size in
            // Rows share one scale around the Loop. The large diagram fits the maps it shows, whole, inside its box, with room at
            // the top and left for the numbers.
            var scale = min(size.width, size.height) * 0.92 / max(frameM, 1)
            var middle = (east: 0.0, north: 0.0)
            var inset = 0.0
            if showsLabels {
                let minE = family.map(\.extent.minEast).min() ?? 0, maxE = family.map(\.extent.maxEast).max() ?? 1
                let minN = family.map(\.extent.minNorth).min() ?? 0, maxN = family.map(\.extent.maxNorth).max() ?? 1
                inset = 18
                scale = min((size.width - 2 * inset) / max(maxE - minE, 1), (size.height - 2 * inset) / max(maxN - minN, 1))
                middle = ((minE + maxE) / 2, (minN + maxN) / 2)
            }
            func point(east: Double, north: Double) -> CGPoint {
                CGPoint(x: size.width / 2 + (east - middle.east) * scale, y: size.height / 2 - (north - middle.north) * scale)
            }
            // Largest first, so the smaller maps are drawn on top of the bigger ones.
            var marks: [CGPoint] = []
            for (rank, entry) in ranked.enumerated() {
                let e = entry.extent
                let topLeft = point(east: e.minEast, north: e.maxNorth)
                let bottomRight = point(east: e.maxEast, north: e.minNorth)
                let rect = CGRect(x: topLeft.x, y: topLeft.y,
                                  width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
                let isHighlight = entry.name == highlight.name
                // A map too small to see at this scale still gets a minimum mark, so it is never invisible.
                let drawn = rect.width < 3 || rect.height < 3 ? rect.insetBy(dx: -2, dy: -2) : rect
                let style = isHighlight
                    ? StrokeStyle(lineWidth: 3)
                    : StrokeStyle(lineWidth: 1, dash: [4, 3])
                context.stroke(Path(drawn), with: .color(.primary), style: style)
                if showsLabels {
                    // A number just outside the top left corner; where it would sit on an earlier one, it moves up.
                    var at = CGPoint(x: drawn.minX - 2, y: drawn.minY - 1)
                    while marks.contains(where: { abs($0.x - at.x) < 10 && abs($0.y - at.y) < 11 }) { at.y -= 11 }
                    marks.append(at)
                    let text = Text("\(rank + 1)").font(isHighlight ? .caption.bold() : .caption2)
                    // A plain backing, so an outline passing behind the number does not run through it.
                    context.fill(Path(CGRect(x: at.x - 9, y: at.y - 12, width: 11, height: 12)), with: .color(Color(nsColor: .windowBackgroundColor)))
                    context.draw(text, at: at, anchor: .bottomTrailing)
                }
            }
            // The Loop, the shared origin, as a small cross.
            let centre = point(east: 0, north: 0)
            var cross = Path()
            cross.move(to: CGPoint(x: centre.x - 4, y: centre.y))
            cross.addLine(to: CGPoint(x: centre.x + 4, y: centre.y))
            cross.move(to: CGPoint(x: centre.x, y: centre.y - 4))
            cross.addLine(to: CGPoint(x: centre.x, y: centre.y + 4))
            context.stroke(cross, with: .color(.primary), lineWidth: 1)
        }
        .accessibilityLabel("Footprint of \(label(highlight)) to scale, with the maps it sits inside or contains")
    }
}
