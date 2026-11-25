import SwiftUI
import GullfireKit

/// The map picker: shown at launch and from Flight ▸ Choose Map…. Lists the packages the catalog found.
/// The selected map's footprint is drawn to scale, with its area on a log bar and its size in words, so a
/// piece of a map (Chicago) is never mistaken for a bigger one (Cook County). Every difference is a word or
/// a shape; colour is never the only cue.
struct CityPickerView: View {
    @Bindable var model: AppModel
    @State private var selection: URL?

    private var selected: CityEntry? {
        model.catalog.first { $0.directory == selection }
    }

    /// The rows in order: the map flown last comes first, then the rest in the catalog's order.
    private var ordered: [CityEntry] {
        let last = model.lastCityPath
        return model.catalog.filter { $0.directory.path == last } + model.catalog.filter { $0.directory.path != last }
    }

    /// Every map's footprint is drawn on the same scale: the largest extent in the catalog.
    private var frameM: Double {
        model.catalog.map { max($0.extentWidthM, $0.extentHeightM) }.max() ?? 1
    }

    private func family(of entry: CityEntry) -> [CityEntry] {
        model.catalog.filter { $0.origin == entry.origin }
    }

    /// The name a person reads for a map: from the recipe list, or the folder name when the list has none.
    private func displayName(_ entry: CityEntry) -> String {
        model.recipes.displayName(forFolder: entry.directory.lastPathComponent)
    }

    /// The display name for a map given only its manifest name (the "contains" and "inside" lists).
    private func displayName(named name: String) -> String {
        if let entry = model.catalog.first(where: { $0.name == name }) { return displayName(entry) }
        return model.recipes.displayName(forFolder: name)
    }

    /// The map the picker starts on: the one flown last, or the first one.
    private var preselected: URL? {
        let last = model.lastCityPath
        return model.catalog.first { $0.directory.path == last }?.directory ?? model.catalog.first?.directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a map")
                .font(.title2.bold())
            Text(ChooseMap.pickerIntro + " Each map is a fixed package. A smaller map is a piece of a bigger one: Chicago lies inside Cook County. The diagrams share one scale.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(ordered) { entry in
                        row(for: entry)
                            .id(entry.directory)
                            .tag(entry.directory)
                            .onTapGesture(count: 2) { model.chooseCity(entry) }
                    }
                }
                .frame(minHeight: 150, maxHeight: .infinity)
                .onAppear {
                    // Scroll to the preselected row once the list has laid out its rows.
                    DispatchQueue.main.async {
                        if let target = preselected {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }

            if let entry = selected {
                detail(for: entry)
            }

            if let problem = model.problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Choose a Folder…") { model.chooseCityFolder() }
                Spacer()
                Button(ChooseMap.pickerButtonTitle) {
                    if let entry = selected { model.chooseCity(entry) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 900, minHeight: 420, idealHeight: 660)
        .onAppear {
            // Preselect the map flown last time, or the first one.
            selection = preselected
        }
    }

    /// A row: the footprint shape, the name, and the area and size on disk in words. The map flown last says
    /// "Last flown" in text and is listed first, so no colour is needed to tell it apart.
    private func row(for entry: CityEntry) -> some View {
        let lastFlown = entry.directory.path == model.lastCityPath
        return HStack(alignment: .center, spacing: 12) {
            CityFootprintView(family: family(of: entry), highlight: entry, frameM: frameM,
                              label: displayName, showsLabels: false)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayName(entry)).font(.headline)
                    if lastFlown {
                        Text("Last flown")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(.secondary))
                    }
                }
                Text("\(Self.area(entry)) · \(Self.disk(entry)) on disk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(displayName(entry)), \(Int(entry.areaKm2.rounded()).formatted()) square kilometres, \(Self.disk(entry))"
            + (lastFlown ? ", last flown" : ""))
    }

    private func detail(for entry: CityEntry) -> some View {
        let family = family(of: entry)
        return HStack(alignment: .top, spacing: 16) {
            CityFootprintView(family: family, highlight: entry, frameM: frameM, label: displayName)
                .frame(width: 240)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(displayName(entry)): \(entry.sizeClass.label)")
                    .font(.headline)
                Text("Extent \(Int((entry.extentWidthM / 1000).rounded())) × \(Int((entry.extentHeightM / 1000).rounded())) km, \(Self.area(entry))")
                Text("\(Self.segments(entry)) M segments · \(Self.solids(entry)) solids · \(Self.disk(entry)) on disk")
                if let ratio = Self.ratioText(entry, in: family, label: displayName) {
                    Text(ratio)
                }
                if !entry.contains.isEmpty {
                    Text("Includes \(entry.contains.map(displayName(named:)).sorted().joined(separator: ", "))")
                }
                if !entry.containedIn.isEmpty {
                    Text("Inside \(entry.containedIn.map(displayName(named:)).sorted().joined(separator: ", "))")
                }
                Text(entry.routeKeys.isEmpty
                     ? "Routes: none, so manual flight only"
                     : "Routes: \(entry.routeKeys.joined(separator: ", "))")
                if entry.usesDrawDistance {
                    Text("Over 200 km²: draws with a 5 km draw distance, so it fades at the edge.")
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Self.areaFraction(entry)) {
                    Text("Area on a log scale, \(Self.area(entry))")
                        .font(.caption)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Formatting

    static func area(_ entry: CityEntry) -> String {
        "\(Int(entry.areaKm2.rounded()).formatted()) km²"
    }

    static func segments(_ entry: CityEntry) -> String {
        String(format: "%.1f", Double(entry.segmentCount) / 1e6)
    }

    static func solids(_ entry: CityEntry) -> String {
        entry.solidCount.formatted()
    }

    static func disk(_ entry: CityEntry) -> String {
        ByteCountFormatter.string(fromByteCount: entry.sizeOnDiskBytes, countStyle: .file)
    }

    /// "× 106 the area of Chicago", naming the smallest map in the family. Nil for a map on its own.
    static func ratioText(_ entry: CityEntry, in family: [CityEntry], label: (CityEntry) -> String) -> String? {
        guard family.count > 1, let smallest = family.min(by: { $0.areaKm2 < $1.areaKm2 }) else { return nil }
        if smallest.name == entry.name { return "The smallest map of its family" }
        return "× \(Int(entry.ratioToSmallest.rounded())) the area of \(label(smallest))"
    }

    /// Log position of the area between 10 km² and 5,000 km², for the progress bar (0 to 1).
    static func areaFraction(_ entry: CityEntry) -> Double {
        let lo = log10(10.0), hi = log10(5000.0)
        return min(max((log10(max(entry.areaKm2, 10)) - lo) / (hi - lo), 0), 1)
    }
}

private extension CityEntry.SizeClass {
    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}
