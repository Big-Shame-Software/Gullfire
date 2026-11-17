import Foundation
import Testing
@testable import GullfireKit

/// The generic example glider (D3): Examples/example-glider.json, made by Tools/make_example_glider.py. The README
/// tells users to copy it in to try G. Nothing copies it to Models/gullfire.json: the README and the plan say so, and no test checks it.
@Suite("Example glider")
struct ExampleGliderTests {
    /// The repository root, from this file's path (Tests/GullfireKitTests/ExampleGliderTests.swift).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let example = root.appendingPathComponent("Examples/example-glider.json")

    @Test func decodesAsAnAircraftModel() throws {
        let model = try AircraftModel.load(from: Self.example)
        #expect(model.name == "Example sailplane (generic)")
        #expect(!model.triangles.isEmpty)
        #expect(!model.lines.isEmpty)
    }

    @Test func arrayLengthsAreWholeTrianglesAndSegments() throws {
        let model = try AircraftModel.load(from: Self.example)
        #expect(model.triangles.count % 9 == 0)
        #expect(model.lines.count % 6 == 0)
    }

    @Test func spanIsAboutTenMetresAndLengthAboutFive() throws {
        let model = try AircraftModel.load(from: Self.example)
        #expect((9.5...10.5).contains(model.spanM))
        #expect((4.5...5.5).contains(model.lengthM))
    }
}
