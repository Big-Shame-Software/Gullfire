import simd

/// The two palettes. Geometry and shaders are the same for both; only colours change.
public enum Palette: String, CaseIterable, Sendable {
    /// Spike green on black, the original palette. Raw value is the command-line name.
    case standard = "default"
    /// Phosphor Green lines on CRT Green, from the Big Shame brand.
    case brand
    /// Pale lime (#DDFF55) lines on black, the owner's pick from the yellow candidates.
    case lime

    /// Water colour. Written straight into the
    /// 8-bit target, as the line colours are. The HUD keeps the line colour, not this one.
    public var water: SIMD3<Float> {
        BrandHex.rgb(BrandHex.water)
    }

    /// Line colour, written straight into the 8-bit target (no colour conversion).
    public var line: SIMD3<Float> {
        switch self {
        case .standard: SIMD3(0.15, 1.0, 0.35)
        case .brand: BrandHex.rgb(BrandHex.phosphorGreen)
        case .lime: BrandHex.rgb(BrandHex.paleLime)
        }
    }

    public var background: SIMD3<Float> {
        switch self {
        case .standard: SIMD3(0, 0, 0)
        case .brand: BrandHex.rgb(BrandHex.crtGreen)
        case .lime: SIMD3(0, 0, 0)
        }
    }
}

/// Brand colour tokens. Source: `../BestImage/BestImage/Brand/BSSBrand.swift`, `phosphorGreen` and
/// `crtGreen`. The kit keeps its own copy; the app's BSSBrand.swift arrives in M5.
public enum BrandHex {
    public static let phosphorGreen: UInt32 = 0x7DFF3A
    public static let crtGreen: UInt32 = 0x0E2E1C
    /// Owner's pick from the yellow candidates. Not a brand token.
    public static let paleLime: UInt32 = 0xDDFF55
    /// Water in all three palettes: the macOS system blue (#007AFF, sRGB), taken from the keyboard
    /// focus ring as the owner measured it (Display P3 0.204 / 0.471 / 0.965). Replaces cyan #5CE1FF.
    public static let water: UInt32 = 0x007AFF

    public static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }
}

/// Per-group brightness multipliers for the line groups. Starting values; the owner
/// tunes them at the M1 review.
public struct LineStyle: Sendable, Equatable {
    public var buildings: Float = 1.0
    public var water: Float = 0.7
    public var roads: Float = 0.35

    public static let standard = LineStyle()

    public init(buildings: Float = 1.0, water: Float = 0.7, roads: Float = 0.35) {
        self.buildings = buildings
        self.water = water
        self.roads = roads
    }

    public func intensity(for group: LineGroup) -> Float {
        switch group {
        case .buildingsMeasured, .buildingsFloors, .buildingsDefault: buildings
        case .water: water
        case .roads: roads
        }
    }
}
