import Foundation
import Metal
import Testing
import simd
@testable import GullfireKit

@Suite("Projection")
struct ProjectionTests {
    @Test func pointStraightAheadMapsToCentreWithReverseZDepth() {
        let camera = Camera(eye: SIMD3(0, 0, 0), target: SIMD3(0, 0, -1))
        let clip = camera.viewProjection(aspect: 16.0 / 9.0) * SIMD4<Float>(0, 0, -100, 1)
        #expect(abs(clip.x) < 1e-4)
        #expect(abs(clip.y) < 1e-4)
        let depth = clip.z / clip.w
        #expect(depth > 0 && depth <= 1)
        #expect(abs(depth - 0.01) < 1e-5)   // reverse-Z: depth is 1/distance
    }

    @Test func pointBehindTheEyeHasNonPositiveW() {
        let camera = Camera(eye: SIMD3(0, 0, 0), target: SIMD3(0, 0, -1))
        let clip = camera.viewProjection(aspect: 16.0 / 9.0) * SIMD4<Float>(0, 0, 50, 1)
        #expect(clip.w <= 0)
    }
}

@Suite("Render scale")
struct RenderScaleTests {
    /// The owner's 5K display: 2880 x 1620 points at 2x is 5760 x 3240 pixels.
    @Test func nativeIsTheFullPixelCount() {
        let size = RenderScale.native.pixelSize(pointWidth: 2880, pointHeight: 1620, backingScale: 2)
        #expect(size.width == 5760 && size.height == 3240)
    }

    @Test func halfIsAQuarterOfTheFullPixelCount() {
        let size = RenderScale.half.pixelSize(pointWidth: 2880, pointHeight: 1620, backingScale: 2)
        #expect(size.width == 2880 && size.height == 1620)
    }

    @Test func nativeIsTheDefaultAndToggleSwitchesBack() {
        #expect(RenderScale.native.toggled == .half)
        #expect(RenderScale.half.toggled == .native)
    }

    @Test func tinyViewsStillGetAPixel() {
        let size = RenderScale.half.pixelSize(pointWidth: 0, pointHeight: 0.2, backingScale: 1)
        #expect(size.width == 1 && size.height == 1)
    }
}

@Suite("Styles and palettes")
struct StyleTests {
    @Test func lineIntensityDefaults() {
        let style = LineStyle.standard
        #expect(style.buildings == 1.0)
        #expect(style.water == 0.7)
        #expect(style.roads == 0.35)
        #expect(style.intensity(for: .buildingsFloors) == 1.0)
        #expect(style.intensity(for: .water) == 0.7)
        #expect(style.intensity(for: .roads) == 0.35)
    }

    /// The brand values must equal the tokens in ../BestImage/BestImage/Brand/BSSBrand.swift.
    @Test func brandHexConstantsMatchTheBrandTokens() {
        #expect(BrandHex.phosphorGreen == 0x7DFF3A)
        #expect(BrandHex.crtGreen == 0x0E2E1C)
        let crt = Palette.brand.background * 255
        #expect(abs(crt.x - 0x0E) < 0.01 && abs(crt.y - 0x2E) < 0.01 && abs(crt.z - 0x1C) < 0.01)
        let phosphor = Palette.brand.line * 255
        #expect(abs(phosphor.x - 0x7D) < 0.01 && abs(phosphor.y - 0xFF) < 0.01 && abs(phosphor.z - 0x3A) < 0.01)
    }

    /// The lime candidate is #DDFF55 on pure black.
    @Test func limePaletteIsPaleLimeOnBlack() {
        #expect(BrandHex.paleLime == 0xDDFF55)
        let line = Palette.lime.line * 255
        #expect(abs(line.x - 0xDD) < 0.01 && abs(line.y - 0xFF) < 0.01 && abs(line.z - 0x55) < 0.01)
        #expect(Palette.lime.background == SIMD3<Float>(0, 0, 0))
        #expect(Palette(rawValue: "lime") == .lime)
    }

    /// Water is #007AFF (the system blue) in every palette.
    @Test func waterIsSystemBlueInEveryPalette() {
        #expect(BrandHex.water == 0x007AFF)
        for palette in Palette.allCases {
            let w = palette.water * 255
            #expect(abs(w.x - 0x00) < 0.01 && abs(w.y - 0x7A) < 0.01 && abs(w.z - 0xFF) < 0.01)
        }
    }

    @Test func standardPaletteIsGreenOnBlack() {
        #expect(Palette.standard.background == SIMD3<Float>(0, 0, 0))
        #expect(Palette.standard.line == SIMD3<Float>(0.15, 1.0, 0.35))
    }

    @Test func paletteNamesAreTheCommandLineNames() {
        #expect(Palette(rawValue: "default") == .standard)
        #expect(Palette(rawValue: "brand") == .brand)
    }
}

/// Whether the GPU tests can run: a Metal device and the built Chicago package.
enum RenderEnvironment {
    static var available: Bool {
        MTLCreateSystemDefaultDevice() != nil && PackageTests.built
    }
}

/// GPU tests. They are skipped when `RenderEnvironment.available` is false.
@Suite("Renders", .enabled(if: RenderEnvironment.available))
struct GPURenderTests {
    static let chicago = PackageTests.chicago

    /// A brand still's background sampled at the top-left corner, which is sky in the skyline view,
    /// must be CRT Green #0E2E1C within one step per channel. The bytes are BGRA.
    @Test func brandBackgroundIsCRTGreen() throws {
        let city = try CityPackage.open(directory: Self.chicago)
        let renderer = try Renderer(city: city, width: 640, height: 360)
        let frame = LocalFrame(lon0: city.manifest.origin.lon, lat0: city.manifest.origin.lat)
        try renderer.render(camera: StillView.skyline.camera(in: frame), palette: .brand)
        let pixels = renderer.pixels()
        #expect(abs(Int(pixels[0]) - 0x1C) <= 1, "blue")
        #expect(abs(Int(pixels[1]) - 0x2E) <= 1, "green")
        #expect(abs(Int(pixels[2]) - 0x0E) <= 1, "red")
    }

    /// Guards the residency trap: if the geometry is not resident, the frame is background only.
    @Test func skylineDrawsLines() throws {
        let city = try CityPackage.open(directory: Self.chicago)
        let renderer = try Renderer(city: city, width: 640, height: 360)
        let frame = LocalFrame(lon0: city.manifest.origin.lon, lat0: city.manifest.origin.lat)
        try renderer.render(camera: StillView.skyline.camera(in: frame), palette: .standard)
        let pixels = renderer.pixels()
        var lit = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 1] > 40 { lit += 1 }
        #expect(lit > 500)
    }
}
