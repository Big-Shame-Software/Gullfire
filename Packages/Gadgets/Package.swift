// swift-tools-version: 6.0
import PackageDescription

/// Big Shame Software gadgets: small background tools any BSS app can drop in.
///
/// - `BSSImageOptimizer` reads any image macOS can open (HEIC, RAW, JPEG XL, WebP, TIFF…) and writes
///   the smallest plain JPEG or PNG that still passes a perceptual quality check against the original.
/// - `bss-optimize` is the same thing from the command line.
/// - `BSSSavedHTML` reads saved web pages without running or fetching anything: a one-pass scanner for facts and links,
///   and a tolerant tree with hard caps.
/// - `BSSRedact` removes passkeys, session tokens and other credentials from web addresses.
/// - `BSSAssetStore` stores images, stylesheets and fonts once each by SHA-256, shrinking images to AVIF and removing
///   their metadata.
/// - `BSSMidiLoop` reads a standard MIDI file and plans endless or looped playback of it by joining its passages at good
///   jumps. It makes no sound: it produces timed MIDI events for a player.
/// - `BSSMidiPlayer` plays those events as a soft pad on an `AVAudioEngine` the app supplies, through one reverb.
// macOS 27 is the floor for every Big Shame app.
let package = Package(
    name: "Gadgets",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BSSImageOptimizer", targets: ["BSSImageOptimizer"]),
        .executable(name: "bss-optimize", targets: ["bss-optimize"]),
        .library(name: "BSSSavedHTML", targets: ["BSSSavedHTML"]),
        .library(name: "BSSRedact", targets: ["BSSRedact"]),
        .library(name: "BSSAssetStore", targets: ["BSSAssetStore"]),
        .library(name: "BSSFeedback", targets: ["BSSFeedback"]),
        .library(name: "BSSDebugMenu", targets: ["BSSDebugMenu"]),
        .library(name: "BSSMidiLoop", targets: ["BSSMidiLoop"]),
        .library(name: "BSSMidiPlayer", targets: ["BSSMidiPlayer"]),
        .executable(name: "bss-midiloop", targets: ["bss-midiloop"]),
    ],
    targets: [
        // Resources: the gadget's pixel icon (Art/make-icon.py draws it).
        .target(name: "BSSImageOptimizer", resources: [.copy("Resources")], linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "bss-optimize", dependencies: ["BSSImageOptimizer"]),
        // Measures Vision's response to JPEG quality; used to set the Vision limits in `Quality`.
        .executableTarget(name: "vision-calibrate", dependencies: ["BSSImageOptimizer"]),
        .testTarget(name: "BSSImageOptimizerTests", dependencies: ["BSSImageOptimizer"]),
        // From TheRecord (archived 2026-11): Foundation only, nothing in a page runs and nothing is fetched.
        .target(name: "BSSSavedHTML"),
        .testTarget(name: "BSSSavedHTMLTests", dependencies: ["BSSSavedHTML"]),
        .target(name: "BSSRedact"),
        .testTarget(name: "BSSRedactTests", dependencies: ["BSSRedact"]),
        .target(name: "BSSAssetStore"),
        .testTarget(name: "BSSAssetStoreTests", dependencies: ["BSSAssetStore"]),
        // Help menu items, the problem writer, the idea inbox and the source-folder link. Every build.
        .target(name: "BSSFeedback", dependencies: ["BSSRedact"]),
        .testTarget(name: "BSSFeedbackTests", dependencies: ["BSSFeedback"]),
        // Debug menu. Every source file is inside #if DEBUG, so a Release build gets nothing from it.
        .target(name: "BSSDebugMenu", dependencies: ["BSSFeedback"]),
        .testTarget(name: "BSSDebugMenuTests", dependencies: ["BSSDebugMenu"]),
        // Foundation only: reads MIDI, analyses segments and jumps, plans and streams events. No audio.
        .target(name: "BSSMidiLoop"),
        .testTarget(name: "BSSMidiLoopTests", dependencies: ["BSSMidiLoop"]),
        // Plays a BSSMidiLoop cursor on an engine the app supplies: a pad voice, a scheduler thread, one reverb.
        .target(name: "BSSMidiPlayer", dependencies: ["BSSMidiLoop"]),
        .testTarget(name: "BSSMidiPlayerTests", dependencies: ["BSSMidiPlayer", "BSSMidiLoop"]),
        // Command line: analyze a MIDI file, or render it to a WAV for listening and checks.
        .executableTarget(name: "bss-midiloop", dependencies: ["BSSMidiLoop", "BSSMidiPlayer"]),
    ],
    swiftLanguageModes: [.v6]
)
