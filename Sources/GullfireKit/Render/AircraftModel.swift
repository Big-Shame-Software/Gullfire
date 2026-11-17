import Foundation
import simd

/// The wireframe aircraft: triangles that only hide the lines behind them, and the line segments that are drawn.
/// In metres, x forward, y up, z to the right. The README's "Adding a glider" section says where a model file goes and
/// how to make one; `Examples/example-glider.json` is a generic model to start from. With no model file the app works
/// and draws no aircraft.
public struct AircraftModel: Decodable, Sendable {
    public var name: String
    public var spanM: Double
    public var lengthM: Double
    /// 9 floats per triangle (three vertices of x, y, z).
    public var triangles: [Float]
    /// 6 floats per segment (ax ay az bx by bz).
    public var lines: [Float]

    public static func load(from url: URL) throws -> AircraftModel {
        try JSONDecoder().decode(AircraftModel.self, from: Data(contentsOf: url))
    }

    /// The installed model, loaded: nil when there is no file or it is not a valid model. The glider is drawn, the
    /// G legend row and the View menu's glider item appear, only when this is not nil.
    public static func installed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AircraftModel? {
        guard let url = locate(environment: environment, home: home) else { return nil }
        return try? load(from: url)
    }

    /// `GULLFIRE_MODEL` if set, else `~/Library/Application Support/Gullfire/Models/gullfire.json`, else `Models/gullfire.json` in
    /// the current folder; nil when there is none.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let path = environment["GULLFIRE_MODEL"] {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let support = home.appendingPathComponent("Library/Application Support/Gullfire/Models/gullfire.json")
        for url in [support, URL(fileURLWithPath: "Models/gullfire.json")] where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
}

/// Where the aircraft is, in package metres and radians. Heading is clockwise from north, pitch is nose up, bank is right wing down
/// (the sign that turns the aircraft right).
public struct AircraftPose: Sendable, Equatable {
    public var east: Double, north: Double, altitude: Double
    public var heading: Double, pitch: Double, bank: Double

    public init(east: Double, north: Double, altitude: Double, heading: Double, pitch: Double, bank: Double) {
        self.east = east; self.north = north; self.altitude = altitude
        self.heading = heading; self.pitch = pitch; self.bank = bank
    }

    public init(_ s: FlightState) {
        self.init(east: s.east, north: s.north, altitude: s.altitude, heading: s.heading, pitch: s.pitch, bank: s.bank)
    }

    /// Model space (x forward, y up, z right) to render space (x east, y up, z minus north).
    public func matrix() -> simd_float4x4 {
        let fwd0 = SIMD3<Double>(sin(heading), 0, -cos(heading))
        let right0 = SIMD3<Double>(cos(heading), 0, sin(heading))
        let up0 = SIMD3<Double>(0, 1, 0)
        // Bank about the forward axis: the right wing goes down for a positive bank.
        let right1 = right0 * cos(bank) - up0 * sin(bank)
        let up1 = up0 * cos(bank) + right0 * sin(bank)
        // Pitch about the (banked) right axis: the nose goes up for a positive pitch.
        let fwd2 = fwd0 * cos(pitch) + up1 * sin(pitch)
        let up2 = up1 * cos(pitch) - fwd0 * sin(pitch)
        func f(_ v: SIMD3<Double>, _ w: Float = 0) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), w) }
        return simd_float4x4(columns: (f(fwd2), f(up2), f(right1),
                                       SIMD4(Float(east), Float(altitude), Float(-north), 1)))
    }
}
