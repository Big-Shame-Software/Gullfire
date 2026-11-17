import AppKit
import SwiftUI

/// The empty state (PLAN 8A, styleguide 9): shown when no city package is found at launch. Pixel icon,
/// one plain line, and the one command that builds Chicago. This is also the only onboarding.
struct EmptyStateView: View {
    let looked: String
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { scheme == .dark ? BSSBrand.cream : BSSBrand.plumInk }

    var body: some View {
        VStack(spacing: 14) {
            Image("BrandIcon")
                .resizable()
                .interpolation(.none)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("No city package found")
                .font(.title2.bold())
                .foregroundStyle(ink)
            Text("Run this one command in the project folder to prepare Chicago:")
                .multilineTextAlignment(.center)
                .foregroundStyle(ink)
            Text(verbatim: "Tools/build_chicago.sh")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(ink)
            Text("Looked in: \((looked as NSString).abbreviatingWithTildeInPath)")
                .font(.caption)
                .foregroundStyle(ink.opacity(0.7))
        }
        .padding(32)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(BSSBrand.surface(scheme, category: .gamesTrail).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No city package found. Run the one command shown, Tools/build_chicago.sh, to prepare Chicago.")
    }
}
