import Foundation
import Testing
@testable import GullfireKit

/// Tests for the map picker's catalog, on the real packages in Cities/. They skip when a package has not
/// been built (the data is git-ignored and comes from Tools/fetch_city.py and gullfire-pack).
@Suite("City catalog")
struct CityCatalogTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let citiesFolder = root.appendingPathComponent("Cities", isDirectory: true)
    static let entries: [CityEntry] = CityCatalog.scan(roots: [citiesFolder])
    static func named(_ name: String) -> CityEntry? { entries.first { $0.name == name } }
    static var chicagoFamilyBuilt: Bool {
        ["Chicago", "ChicagoWide", "ChicagoWider", "ChicagoCity", "CookCounty"].allSatisfy { named($0) != nil }
    }

    @Test(.enabled(if: CityCatalogTests.chicagoFamilyBuilt))
    func listsOnlyPackagesWithAManifestAndBinaries() {
        // Paris, Prague and ChicagoWest are raw-only folders, so they must not appear.
        let names = Set(Self.entries.map(\.name))
        #expect(!names.contains("Paris") && !names.contains("Prague") && !names.contains("ChicagoWest"))
        #expect(names.contains("Chicago") && names.contains("CookCounty"))
    }

    @Test(.enabled(if: CityCatalogTests.chicagoFamilyBuilt))
    func chicagoFamilyNestsInOrder() throws {
        let chicago = try #require(Self.named("Chicago"))
        let cook = try #require(Self.named("CookCounty"))
        #expect(chicago.contains.isEmpty)
        #expect(chicago.containedIn.contains("ChicagoWide"))
        #expect(cook.contains.contains("ChicagoCity"))
        #expect(cook.containedIn.isEmpty)
        // Every map in the family shares one ratio to the smallest map (Chicago).
        #expect(chicago.ratioToSmallest == 1)
        #expect(cook.ratioToSmallest > 90 && cook.ratioToSmallest < 120)
    }

    @Test(.enabled(if: CityCatalogTests.chicagoFamilyBuilt))
    func viennaIsNotInsideAnyChicagoMap() throws {
        guard let vienna = Self.named("Vienna") else { return }
        #expect(vienna.containedIn.isEmpty)
        #expect(vienna.ratioToSmallest == 1)
        #expect(vienna.routeKeys.contains("scenic") && vienna.routeKeys.contains("river"))
    }

    @Test(.enabled(if: CityCatalogTests.chicagoFamilyBuilt))
    func drawDistanceFlagFollowsTheArea() throws {
        // Over 200 km² turns the 5 km draw distance on (App/MetalView.swift).
        #expect(try #require(Self.named("CookCounty")).usesDrawDistance)
        #expect(!(try #require(Self.named("Chicago")).usesDrawDistance))
    }

    @Test(.enabled(if: CityCatalogTests.chicagoFamilyBuilt))
    func sizeClassesFollowSegmentCounts() throws {
        #expect(try #require(Self.named("Chicago")).sizeClass == .small)
        #expect(try #require(Self.named("ChicagoCity")).sizeClass == .large)
        #expect(try #require(Self.named("CookCounty")).sizeClass == .large)
    }

    @Test(.enabled(if: CityCatalogTests.chicagoFamilyBuilt))
    func sizeOnDiskIsTheSumOfTheBinaries() throws {
        let chicago = try #require(Self.named("Chicago"))
        #expect(chicago.sizeOnDiskBytes > 0)
        #expect(try #require(Self.named("CookCounty")).sizeOnDiskBytes > chicago.sizeOnDiskBytes)
    }

    @Test func boxContainmentIsStrictAndInclusive() {
        let big = Manifest.BBox(minLon: -88, minLat: 41, maxLon: -87, maxLat: 42)
        let small = Manifest.BBox(minLon: -87.5, minLat: 41.2, maxLon: -87.2, maxLat: 41.8)
        #expect(CityCatalog.bboxContains(outer: big, inner: small))
        #expect(!CityCatalog.bboxContains(outer: small, inner: big))
        #expect(!CityCatalog.bboxContains(outer: big, inner: big))
        // Sharing an edge still counts as inside (Chicago's east edge is ChicagoWide's east edge).
        let edge = Manifest.BBox(minLon: -87.5, minLat: 41.2, maxLon: -87, maxLat: 41.8)
        #expect(CityCatalog.bboxContains(outer: big, inner: edge))
    }

    @Test func routeKeysFollowTheCycleOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("routekeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["street-10.json", "street-2.json", "river.json", "street-2.report.json", "scenic.json", "notes.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        #expect(CityCatalog.routeKeys(in: folder) == ["scenic", "river", "street-2", "street-10"])
    }
}
