import Foundation
import simd

/// A named building at least `landmarkMinHeight` tall, for route authoring and tests.
public struct Landmark: Codable, Sendable, Equatable {
    public var name: String
    public var east: Double
    public var north: Double
    public var heightM: Double
}

/// Turns a prepared city (`<city>/raw/`) into a city package.
/// Reads one feature at a time and writes binary buffers, so memory stays bounded.
public enum PackageWriter {
    public static let waterSubtypes: Set<String> = ["river", "lake", "water", "canal"]
    public static let roadClasses: Set<String> = ["motorway", "trunk", "primary", "secondary", "tertiary", "residential"]
    public static let landmarkMinHeight = 150.0
    public static let gridCellSize = 4.0
    public static let groundMargin = 2000.0
    /// Side of a tile, in metres.
    public static let tileSizeM = 500.0

    /// Tile of a building or building part: the centre of the bounding box of its first polygon's
    /// outer ring. Every polygon of the feature takes this tile.
    static func featureTile(_ polys: [[[SIMD2<Double>]]], _ grid: TileGrid) -> Int32 {
        guard let outer = polys.compactMap({ $0.first }).first(where: { !$0.isEmpty }) else { return -1 }
        let minP = outer.reduce(outer[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
        let maxP = outer.reduce(outer[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
        let centre = (minP + maxP) / 2
        return grid.tile(east: centre.x, north: centre.y)
    }

    struct SourceFile: Decodable {
        let city: String
        let bbox: Manifest.BBox
        let origin: Manifest.Origin
        let overtureRelease: String
        let attribution: String
        let licences: [Manifest.Licence]
    }

    /// Reads `<cityDirectory>/raw` and writes solids.bin, lines.bin, obstacles.bin,
    /// landmarks.json and manifest.json into `cityDirectory`.
    @discardableResult
    public static func write(cityDirectory: URL, outOfCore: Bool = false) throws -> Manifest {
        let raw = cityDirectory.appendingPathComponent("raw", isDirectory: true)
        let src = try JSONDecoder().decode(SourceFile.self,
                                           from: Data(contentsOf: raw.appendingPathComponent("source.json")))
        let frame = LocalFrame(lon0: src.origin.lon, lat0: src.origin.lat)
        let lo = frame.metres(lon: src.bbox.minLon, lat: src.bbox.minLat)
        let hi = frame.metres(lon: src.bbox.maxLon, lat: src.bbox.maxLat)
        let cols = Int(((hi.x - lo.x) / gridCellSize).rounded(.up))
        let rows = Int(((hi.y - lo.y) / gridCellSize).rounded(.up))

        var mesh = MeshBuilder(frame: frame)
        let tileGrid = TileGrid(extent: .init(minEast: lo.x, maxEast: hi.x, minNorth: lo.y, maxNorth: hi.y),
                                sizeM: tileSizeM)
        var grid = ObstacleGrid(minEast: lo.x, minNorth: lo.y, cellSize: gridCellSize, cols: cols, rows: rows)
        var heights = Manifest.HeightCounts(measured: 0, floors: 0, defaulted: 0)
        var solidCount = 0
        let spill = outOfCore ? try TileSpill(directory: cityDirectory.appendingPathComponent("spill", isDirectory: true), grid: tileGrid) : nil
        /// Out of core: move the mesh to disk once it holds about two million segments.
        func flushIfBig() throws {
            if let spill, mesh.lines.reduce(0, { $0 + $1.count }) > 12_000_000 { try spill.flush(&mesh) }
        }

        func count(_ kind: HeightKind) {
            switch kind {
            case .measured: heights.measured += 1
            case .floors: heights.floors += 1
            case .fallback: heights.defaulted += 1
            }
        }

        // Parts first: landmark towers keep their real heights here.
        var partTop: [String: Double] = [:]
        try GeoJSONLines.forEachFeature(at: raw.appendingPathComponent("building_part.geojsonl")) { feature in
            guard let p = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any] else { return }
            let rule = heightRule(p)
            let base = number(p["min_height"]) ?? 0
            let polys = polygons(geometry, frame)
            mesh.tile = featureTile(polys, tileGrid)
            for polygon in polys {
                mesh.extrude(rings: polygon, base: base, top: rule.top, group: rule.group)
                if let outer = polygon.first { grid.stamp(ring: outer, top: Float(rule.top)) }
            }
            solidCount += 1
            count(rule.kind)
            if let buildingID = p["building_id"] as? String {
                partTop[buildingID] = max(partTop[buildingID] ?? -.infinity, rule.top)
            }
            try flushIfBig()
        }

        // Buildings. Those with parts, and underground ones, are not drawn; the parts are.
        var landmarks: [Landmark] = []
        try GeoJSONLines.forEachFeature(at: raw.appendingPathComponent("building.geojsonl")) { feature in
            guard let p = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let id = feature["id"] as? String else { return }
            let hasParts = (p["has_parts"] as? Bool) == true
            let underground = (p["is_underground"] as? Bool) == true
            let rule = heightRule(p)
            if !hasParts && !underground {
                let polys = polygons(geometry, frame)
                mesh.tile = featureTile(polys, tileGrid)
                for polygon in polys {
                    mesh.extrude(rings: polygon, base: 0, top: rule.top, group: rule.group)
                    if let outer = polygon.first { grid.stamp(ring: outer, top: Float(rule.top)) }
                }
                solidCount += 1
                count(rule.kind)
                try flushIfBig()
            }
            let top = hasParts ? (partTop[id] ?? 0) : rule.top
            if top >= landmarkMinHeight,
               let names = p["names"] as? [String: Any],
               let name = names["primary"] as? String, !name.isEmpty,
               let outer = polygons(geometry, frame).first?.first, !outer.isEmpty {
                let minP = outer.reduce(outer[0]) { SIMD2(min($0.x, $1.x), min($0.y, $1.y)) }
                let maxP = outer.reduce(outer[0]) { SIMD2(max($0.x, $1.x), max($0.y, $1.y)) }
                let centre = (minP + maxP) / 2
                landmarks.append(Landmark(name: name, east: centre.x, north: centre.y,
                                          heightM: (top * 10).rounded() / 10))
            }
        }

        // Water: outlines of clipped polygons at ground level. River centrelines are not drawn.
        try GeoJSONLines.forEachFeature(at: raw.appendingPathComponent("water_clipped.geojsonl")) { feature in
            guard let p = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let subtype = p["subtype"] as? String, waterSubtypes.contains(subtype) else { return }
            for ring in lonLatRings(geometry) {
                addWaterOutline(ring, bbox: src.bbox, frame: frame, tiles: tileGrid, mesh: &mesh)
            }
            try flushIfBig()
        }

        // Roads: the listed classes only, at ground level.
        try GeoJSONLines.forEachFeature(at: raw.appendingPathComponent("segment.geojsonl")) { feature in
            guard let p = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  (geometry["type"] as? String) == "LineString",
                  let cls = p["class"] as? String, roadClasses.contains(cls),
                  let coords = geometry["coordinates"] as? [[Double]] else { return }
            let pts = coords.map { frame.metres(lon: $0[0], lat: $0[1]) }
            for i in 0..<max(0, pts.count - 1) {
                mesh.tile = tileGrid.tile(east: (pts[i].x + pts[i + 1].x) / 2, north: (pts[i].y + pts[i + 1].y) / 2)
                mesh.addSegment(.roads, frame.render(east: pts[i].x, north: pts[i].y, up: 0),
                                frame.render(east: pts[i + 1].x, north: pts[i + 1].y, up: 0))
            }
            try flushIfBig()
        }

        // Ground quad at y = -0.5, covering the box plus a margin.
        let x0 = lo.x - groundMargin, x1 = hi.x + groundMargin
        let y0 = lo.y - groundMargin, y1 = hi.y + groundMargin
        let a = frame.render(east: x0, north: y0, up: -0.5), b = frame.render(east: x1, north: y0, up: -0.5)
        let c = frame.render(east: x1, north: y1, up: -0.5), d = frame.render(east: x0, north: y1, up: -0.5)
        mesh.tile = -1
        mesh.addTriangle(a, b, c)
        mesh.addTriangle(a, c, d)
        if let spill { try spill.flush(&mesh) }

        // Re-order by tile. Each group keeps its size and its place in the file.
        var ranges: [Manifest.LineGroupRange] = []
        var segmentCount = 0
        var triangleTotal = 0
        var solidBytesCount = 0
        var lineBytesCount = 0
        var tileIndex: TileIndex
        if let spill {
            try spill.flush(&mesh)
            let result = try spill.assemble(solidsURL: cityDirectory.appendingPathComponent("solids.bin"),
                                            linesURL: cityDirectory.appendingPathComponent("lines.bin"))
            for group in LineGroup.allCases {
                let n = result.groupCounts[group.rawValue]
                ranges.append(.init(name: String(describing: group), first: segmentCount, count: n))
                segmentCount += n
            }
            triangleTotal = result.triangleCount
            solidBytesCount = result.solidBytes
            lineBytesCount = result.lineBytes
            tileIndex = result.index
        } else {
            let ordered = TileOrder.make(mesh, grid: tileGrid)
            for group in LineGroup.allCases {
                let n = mesh.lines[group.rawValue].count / 6
                ranges.append(.init(name: String(describing: group), first: segmentCount, count: n))
                segmentCount += n
            }
            let solidBytes = ordered.solids.withUnsafeBytes { Data($0) }
            let lineBytes = ordered.lines.withUnsafeBytes { Data($0) }
            try solidBytes.write(to: cityDirectory.appendingPathComponent("solids.bin"))
            try lineBytes.write(to: cityDirectory.appendingPathComponent("lines.bin"))
            triangleTotal = mesh.triangleCount
            solidBytesCount = solidBytes.count
            lineBytesCount = lineBytes.count
            tileIndex = ordered.index
        }
        let obstacleBytes = grid.heights.withUnsafeBytes { Data($0) }
        try obstacleBytes.write(to: cityDirectory.appendingPathComponent("obstacles.bin"))

        landmarks.sort { $0.heightM > $1.heightM }
        let landmarkData = try JSONEncoder.pretty.encode(LandmarkFile(formatVersion: 1,
                                                                       minHeightM: landmarkMinHeight,
                                                                       landmarks: landmarks))
        try landmarkData.write(to: cityDirectory.appendingPathComponent("landmarks.json"))

        let manifest = Manifest(
            formatVersion: 1,
            name: src.city,
            origin: src.origin,
            bbox: src.bbox,
            extentM: .init(minEast: lo.x, maxEast: hi.x, minNorth: lo.y, maxNorth: hi.y),
            overtureRelease: src.overtureRelease,
            attribution: src.attribution,
            licences: src.licences,
            files: [
                .init(name: "solids.bin", bytes: solidBytesCount, count: triangleTotal * 3),
                .init(name: "lines.bin", bytes: lineBytesCount, count: segmentCount),
                .init(name: "obstacles.bin", bytes: obstacleBytes.count, count: cols * rows),
                .init(name: "landmarks.json", bytes: landmarkData.count, count: landmarks.count),
            ],
            solidCount: solidCount,
            solidTriangleCount: triangleTotal,
            segmentCount: segmentCount,
            lineGroups: ranges,
            obstacleGrid: .init(cols: cols, rows: rows, cellSizeM: gridCellSize, minEast: lo.x, minNorth: lo.y),
            heights: heights,
            tiles: tileIndex)
        let manifestData = try JSONEncoder.pretty.encode(manifest)
        try manifestData.write(to: cityDirectory.appendingPathComponent("manifest.json"))
        return manifest
    }

    struct LandmarkFile: Codable {
        var formatVersion: Int
        var minHeightM: Double
        var landmarks: [Landmark]
    }

    enum HeightKind { case measured, floors, fallback }

    /// Height rule: measured, else floors × 3.4, else 6 m.
    static func heightRule(_ p: [String: Any]) -> (top: Double, group: LineGroup, kind: HeightKind) {
        if let h = number(p["height"]) { return (h, .buildingsMeasured, .measured) }
        if let f = number(p["num_floors"]) { return (f * 3.4, .buildingsFloors, .floors) }
        return (6, .buildingsDefault, .fallback)
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Polygons of a GeoJSON geometry as rings in metres. Other geometry types give nothing.
    static func polygons(_ geometry: [String: Any], _ frame: LocalFrame) -> [[[SIMD2<Double>]]] {
        func ring(_ raw: [[Double]]) -> [SIMD2<Double>] {
            raw.map { frame.metres(lon: $0[0], lat: $0[1]) }
        }
        switch geometry["type"] as? String {
        case "Polygon":
            guard let rings = geometry["coordinates"] as? [[[Double]]] else { return [] }
            return [rings.map(ring)]
        case "MultiPolygon":
            guard let polys = geometry["coordinates"] as? [[[[Double]]]] else { return [] }
            return polys.map { rings in rings.map(ring) }
        default:
            return []
        }
    }

    /// Rings of a GeoJSON polygon geometry in longitude and latitude, before any conversion.
    static func lonLatRings(_ geometry: [String: Any]) -> [[[Double]]] {
        switch geometry["type"] as? String {
        case "Polygon":
            guard let rings = geometry["coordinates"] as? [[[Double]]] else { return [] }
            return rings
        case "MultiPolygon":
            guard let polys = geometry["coordinates"] as? [[[[Double]]]] else { return [] }
            return polys.flatMap { $0 }
        default:
            return []
        }
    }

    /// Tolerance for "lies on the box edge", in degrees.
    static let boundaryTolerance = 1e-7

    /// True when both endpoints lie on the same side of the bbox. Clipping the water to the box
    /// leaves such edges along the box boundary, and they would draw as straight fake shores.
    static func onSameBoundarySide(_ a: [Double], _ b: [Double], bbox: Manifest.BBox) -> Bool {
        let t = boundaryTolerance
        func near(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= t }
        let sameWest = near(a[0], bbox.minLon) && near(b[0], bbox.minLon)
        let sameEast = near(a[0], bbox.maxLon) && near(b[0], bbox.maxLon)
        let sameSouth = near(a[1], bbox.minLat) && near(b[1], bbox.minLat)
        let sameNorth = near(a[1], bbox.maxLat) && near(b[1], bbox.maxLat)
        return sameWest || sameEast || sameSouth || sameNorth
    }

    /// Adds each edge of a water ring as a ground-level segment, except edges that lie on the box
    /// boundary (see `onSameBoundarySide`). Every other edge is kept.
    static func addWaterOutline(_ ring: [[Double]], bbox: Manifest.BBox, frame: LocalFrame, tiles: TileGrid,
                                mesh: inout MeshBuilder) {
        var pts = ring
        if pts.count > 1, pts.first == pts.last { pts.removeLast() }
        guard pts.count >= 2 else { return }
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            if onSameBoundarySide(a, b, bbox: bbox) { continue }
            let pa = frame.metres(lon: a[0], lat: a[1]), pb = frame.metres(lon: b[0], lat: b[1])
            mesh.tile = tiles.tile(east: (pa.x + pb.x) / 2, north: (pa.y + pb.y) / 2)
            mesh.addSegment(.water, frame.render(east: pa.x, north: pa.y, up: 0),
                            frame.render(east: pb.x, north: pb.y, up: 0))
        }
    }

    /// Adds each edge of a ring as a line segment at ground level.
    static func addOutline(_ ring: [SIMD2<Double>], frame: LocalFrame, mesh: inout MeshBuilder, group: LineGroup) {
        var pts = ring
        if pts.count > 1, pts.first == pts.last { pts.removeLast() }
        guard pts.count >= 2 else { return }
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            mesh.addSegment(group, frame.render(east: a.x, north: a.y, up: 0),
                            frame.render(east: b.x, north: b.y, up: 0))
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
