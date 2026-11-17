import AppKit
import SwiftUI

/// The About window (styleguide 9): publisher attribution, the version from the bundle, one tagline,
/// the shelf line, and the N©! line (styleguide 2). Brand surface: Plum Ink in dark mode, Cream in light.
struct AboutView: View {
    /// The credit line of the city package on screen (its manifest's attribution), if a map is built.
    var attribution: String?
    @Environment(\.colorScheme) private var scheme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private var ink: Color { scheme == .dark ? BSSBrand.cream : BSSBrand.plumInk }

    var body: some View {
        VStack(spacing: 12) {
            BSSRainbowStripe()
                .frame(height: 6)
                .accessibilityHidden(true)
            Image("PublisherMark")
                .resizable()
                .aspectRatio(1200.0 / 800.0, contentMode: .fit)
                .frame(width: 220, height: 147)
                .accessibilityLabel("Big Shame Software")
            Image("BrandIcon")
                .resizable()
                .interpolation(.none)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text("Gullfire")
                .font(.title.bold())
                .foregroundStyle(ink)
            Text("Wireframe Flights Over Real Cities")
                .font(.headline)
                .foregroundStyle(ink)
            Text("Version \(version) (\(build))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(ink)
            Text("Flights over real cities. No pilot's license required.")
                .font(.body.italic())
                .multilineTextAlignment(.center)
                .foregroundStyle(ink)
                .accessibilityLabel("Tagline: Flights over real cities. No pilot's license required.")
            Text("Filed under: Aviation and Navigation")
                .font(.caption)
                .foregroundStyle(ink)
            if let attribution {
                Text(attribution)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)   // wrap the whole line, never truncate it
                    .foregroundStyle(ink)
                    .accessibilityLabel("Map credit: \(attribution)")
            }
            Text("N©! Big Shame Software 2026")
                .font(.caption)
                .foregroundStyle(ink)
            Text("a Big Shame Software app · public domain")
                .font(.caption)
                .foregroundStyle(ink)
        }
        .padding(28)
        .frame(width: 380)
        .background(scheme == .dark ? BSSBrand.plumInk : BSSBrand.cream)
    }
}
