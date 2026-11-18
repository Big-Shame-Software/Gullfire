import AppKit
import GullfireKit
import SwiftUI

/// The route list (D1), at the bottom centre in a box that catches the eye: a bright border, a dark fill in the
/// palette's ink, and bright text. Shown at launch and after C for 4 s, with the hint line under the routes (D4 to D6),
/// then faded over 0.5 s (dropped at once with Reduce Motion). The route that flies is marked `▶`, the word NOW and full opacity; the others are dimmer.
/// The marks carry the meaning, not the colour.
struct RouteListView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The key legend's width (its text, padding and a gap), points.
    private let legendWidth: CGFloat = 300
    /// Narrower than this, a centred list would run into the key legend, so it moves left of the legend (K on).
    /// Two legend widths plus the list's own width and a margin.
    private let narrowWidth: CGFloat = 860

    private func color(_ c: SIMD3<Float>) -> Color {
        Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var body: some View {
        GeometryReader { proxy in
            // Redraws at 30 Hz only while the list is on screen; the timing lives in RouteList.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                if let list = model.routeList {
                    let opacity = list.opacity(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
                    if opacity > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(list.header)
                            ForEach(list.items.indices, id: \.self) { index in
                                Text(list.row(at: index))
                                    .opacity(index == list.current ? 1 : 0.7)
                            }
                            // D4, D5: the hint is on every showing, so the list always says how the route changes.
                            Text(RouteList.hintLine)
                                .padding(.top, 8)
                        }
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(color(model.palette.line))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(color(model.palette.line * 0.2), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color(model.palette.line), lineWidth: 2))
                        .opacity(opacity)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(list.announcement)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.trailing, model.showKeys && proxy.size.width < narrowWidth ? legendWidth : 0)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
    }
}
