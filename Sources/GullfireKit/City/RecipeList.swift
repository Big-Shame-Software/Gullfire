import Foundation

/// The shipped list of map recipes (Resources/Recipes/recipes.json): one entry per map the build tools
/// know, with the name a person reads. The app takes its names from here, so no city is named in Swift.
public struct RecipeList: Codable, Sendable, Equatable {
    public struct Recipe: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        /// The package folder name the recipe builds (for example "Chicago"), which the catalog matches.
        public let folder: String
        public let displayName: String
        public let areaKm2: Double
        /// The data the build downloads, in MB.
        public let downloadMB: Int
        /// The package's disk use once built, in GB.
        public let diskGB: Double
        /// The free disk this Mac needs before building (the recipe's margin over diskGB), in GB.
        public let freeDiskGB: Double
        /// The least memory this Mac needs to build, in GB.
        public let minRamGB: Double
        /// The build's peak memory, in GB.
        public let buildPeakGB: Double
        /// The build's rough running time, in minutes.
        public let approxMinutes: Int
        /// Whether the build packs out of core (the wide maps).
        public let outOfCore: Bool

        /// Whether a Mac with this much memory and free disk can build the map. Both checks are `>=`, the same as
        /// Tools/build_city.sh's preflight.
        public func canBuild(memoryGB: Double, freeDiskGB: Double) -> Bool {
            memoryGB >= minRamGB && freeDiskGB >= self.freeDiskGB
        }

        /// The words for what a Mac lacks to build the map, or nil when it has enough of both.
        public func shortfall(memoryGB: Double, freeDiskGB: Double) -> String? {
            var parts: [String] = []
            if memoryGB < minRamGB {
                parts.append("needs \(Self.gigabytes(minRamGB)) GB of memory; this Mac has \(Self.gigabytes(memoryGB)) GB")
            }
            if freeDiskGB < self.freeDiskGB {
                parts.append("needs \(Self.gigabytes(self.freeDiskGB)) GB free disk; this Mac has \(Self.gigabytes(freeDiskGB)) GB free")
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }

        /// The command that builds the map, run from the project folder.
        public var command: String { "Tools/build_city.sh \(id)" }

        /// A GB figure for a person to read: a whole number without a decimal point, otherwise one decimal place.
        public static func gigabytes(_ value: Double) -> String {
            value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        }
    }

    public let format: Int
    public let recipes: [Recipe]

    public init(format: Int, recipes: [Recipe]) {
        self.format = format
        self.recipes = recipes
    }

    /// Reads a recipe list from a JSON file.
    public static func load(_ url: URL) throws -> RecipeList {
        try JSONDecoder().decode(RecipeList.self, from: Data(contentsOf: url))
    }

    /// The recipes this Mac can build that are not installed, in the list's order. Memory is always checked. Disk is
    /// checked with `canBuild` when known; when `freeDiskGB` is nil (the system could not say), every recipe whose
    /// memory need is met is listed and `diskUnknown` is true, so the person can judge the disk themselves.
    /// Installed folders are always excluded.
    public func buildable(memoryGB: Double, freeDiskGB: Double?, installedFolders: Set<String>)
        -> (recipes: [Recipe], diskUnknown: Bool) {
        let candidates = recipes.filter { !installedFolders.contains($0.folder) && memoryGB >= $0.minRamGB }
        guard let freeDiskGB else {
            return (candidates, true)
        }
        return (candidates.filter { $0.canBuild(memoryGB: memoryGB, freeDiskGB: freeDiskGB) }, false)
    }

    /// The name to show for a package folder: the recipe's display name, or the folder name itself when no
    /// recipe matches (a map the list does not know, or no list at all).
    public func displayName(forFolder folder: String) -> String {
        recipes.first { $0.folder == folder }?.displayName ?? folder
    }
}
