import Foundation

/// One city package found on disk, described from its manifest and file sizes alone. The binary
/// files are not mapped, so listing packages costs next to nothing.
public struct CityEntry: Sendable, Identifiable, Equatable {
    public enum SizeClass: String, Sendable, Equatable {
        case small, medium, large
    }

    public var id: String { name }
    public let directory: URL
    public let name: String
    public let origin: Manifest.Origin
    public let bbox: Manifest.BBox
    /// The footprint in metres from the origin (the Loop), as the package's manifest gives it.
    public let extent: Manifest.Extent
    public let extentWidthM: Double
    public let extentHeightM: Double
    public let areaKm2: Double
    public let segmentCount: Int
    public let solidCount: Int
    /// Sum of solids.bin, lines.bin and obstacles.bin.
    public let sizeOnDiskBytes: Int64
    /// Route keys present in routes/: scenic, river, then street-N by number (the order C cycles them).
    public let routeKeys: [String]
    public let sizeClass: SizeClass
    /// Packages over 200 km² or over 1.5 M segments draw with a 5 km draw distance by default (`DrawDistancePolicy`).
    public let usesDrawDistance: Bool
    /// Names of the other packages whose bounding box contains this one (same origin).
    public var containedIn: [String] = []
    /// Names of the packages inside this one.
    public var contains: [String] = []
    /// Area divided by the smallest area in this package's family (packages linked by containment).
    public var ratioToSmallest: Double = 1
}

/// Finds city packages in a list of folders and says how they nest.
public enum CityCatalog {
    /// Segment counts below which a package is Small, and below which it is Medium (larger is Large).
    public static let mediumSegments = 3_000_000
    public static let largeSegments = 20_000_000

    /// Lists the packages in each root, in the order given. A name already found in an earlier root is
    /// skipped, so the first root wins. Folders without a readable manifest, or with a missing binary
    /// file, are not listed.
    public static func scan(roots: [URL]) -> [CityEntry] {
        var seen = Set<String>()
        var found: [CityEntry] = []
        for root in roots {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let entry = describe(folder), !seen.contains(entry.name) else { continue }
                seen.insert(entry.name)
                found.append(entry)
            }
        }
        return relate(found)
    }

    /// Describes one package folder from its manifest. Nil when it is not a usable package.
    public static func describe(_ folder: URL) -> CityEntry? {
        let fm = FileManager.default
        let binaries = ["solids.bin", "lines.bin", "obstacles.bin"]
        guard binaries.allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }),
              let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.formatVersion == 1 else { return nil }

        let e = manifest.extentM
        let width = e.maxEast - e.minEast
        let height = e.maxNorth - e.minNorth
        let area = width * height / 1e6
        let size = binaries.reduce(Int64(0)) { total, name in
            let bytes = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
            return total + (bytes ?? 0)
        }
        let sizeClass: CityEntry.SizeClass = manifest.segmentCount < mediumSegments ? .small
            : manifest.segmentCount < largeSegments ? .medium : .large

        return CityEntry(directory: folder, name: manifest.name, origin: manifest.origin, bbox: manifest.bbox,
                         extent: e, extentWidthM: width, extentHeightM: height, areaKm2: area,
                         segmentCount: manifest.segmentCount, solidCount: manifest.solidCount,
                         sizeOnDiskBytes: size, routeKeys: routeKeys(in: folder.appendingPathComponent("routes")),
                         sizeClass: sizeClass, usesDrawDistance: DrawDistancePolicy.applies(areaKm2: area, segments: manifest.segmentCount))
    }

    /// The route keys in a routes folder, in the order the app cycles them (mirrors App/MetalView.swift).
    public static func routeKeys(in routesFolder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: routesFolder.path)) ?? []
        var keys: [String] = []
        if files.contains("scenic.json") { keys.append("scenic") }
        if files.contains("river.json") { keys.append("river") }
        let streets = files
            .filter { $0.hasPrefix("street-") && $0.hasSuffix(".json") && !$0.hasSuffix(".report.json") }
            .map { String($0.dropLast(5)) }
            .sorted { (Int($0.dropFirst(7)) ?? 0) < (Int($1.dropFirst(7)) ?? 0) }
        return keys + streets
    }

    /// Fills `contains`, `containedIn` and `ratioToSmallest`. Two packages are related when they share an
    /// origin and one bounding box lies inside the other; a family is every package linked that way.
    static func relate(_ input: [CityEntry]) -> [CityEntry] {
        var entries = input
        var parent = Array(input.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in input.indices {
            for j in input.indices where i != j {
                guard input[i].origin == input[j].origin, bboxContains(outer: input[j].bbox, inner: input[i].bbox) else { continue }
                entries[i].containedIn.append(input[j].name)
                entries[j].contains.append(input[i].name)
                parent[find(i)] = find(j)
            }
        }
        var smallest: [Int: Double] = [:]
        for i in input.indices {
            let root = find(i)
            smallest[root] = min(smallest[root] ?? .infinity, input[i].areaKm2)
        }
        for i in input.indices {
            entries[i].ratioToSmallest = input[i].areaKm2 / (smallest[find(i)] ?? input[i].areaKm2)
        }
        return entries
    }

    /// True when `inner` lies within `outer` and the two boxes are not equal.
    static func bboxContains(outer: Manifest.BBox, inner: Manifest.BBox) -> Bool {
        guard outer != inner else { return false }
        let eps = 1e-9
        return outer.minLon <= inner.minLon + eps && inner.maxLon <= outer.maxLon + eps
            && outer.minLat <= inner.minLat + eps && inner.maxLat <= outer.maxLat + eps
    }
}
