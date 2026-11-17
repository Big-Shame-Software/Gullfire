import BSSImageOptimizer
import Foundation

let usage = """
usage: bss-optimize -o DIR [--quality maximum|high|balanced] [--format automatic|jpeg|png]
                    [--max PIXELS] [--jobs N] [--no-keep] [--no-vision] FILE...

Writes the smallest universally readable JPEG or PNG for each image into DIR.
Reads anything macOS can open (HEIC, RAW, JPEG XL, WebP, TIFF, PNG, JPEG…).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var options = ImageOptimizer.Options()
var outputDir: URL?
var jobs = 2
var files: [URL] = []

while !args.isEmpty {
    let arg = args.removeFirst()
    func value() -> String {
        if args.isEmpty { fail("\(arg) needs a value\n\n\(usage)") }
        return args.removeFirst()
    }
    func need<T>(_ v: T?) -> T {
        guard let v else { fail(usage) }
        return v
    }
    switch arg {
    case "-o", "--output": outputDir = URL(fileURLWithPath: value(), isDirectory: true)
    case "--quality": options.quality = need(ImageOptimizer.Quality(rawValue: value()))
    case "--format": options.format = need(ImageOptimizer.FormatPolicy(rawValue: value()))
    case "--max": options.maxPixelSize = need(Int(value()))
    case "--jobs": jobs = max(1, min(4, need(Int(value()))))
    case "--no-keep": options.keepOriginalIfSmaller = false
    case "--no-vision": options.visionCheck = false
    case "-h", "--help": print(usage); exit(0)
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        files.append(URL(fileURLWithPath: arg))
    }
}
guard let outputDir, !files.isEmpty else { fail(usage) }

let size: @Sendable (Int) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }

final class Totals: @unchecked Sendable {
    let lock = NSLock()
    var input = 0, output = 0, failures = 0
}
let totals = Totals()
let optimizer = ImageOptimizer(options: options)
let started = Date()

await optimizer.optimizeFiles(files, into: outputDir, maxConcurrent: jobs) { outcome in
    totals.lock.lock(); defer { totals.lock.unlock() }
    guard let r = outcome.result, let out = outcome.output else {
        totals.failures += 1
        print("✗ \(outcome.input.lastPathComponent): \(outcome.error ?? "failed")")
        return
    }
    totals.input += r.inputBytes
    totals.output += r.outputBytes
    let saved = String(format: "%+.0f%%", -r.savedFraction * 100)
    print("✓ \(outcome.input.lastPathComponent) → \(out.lastPathComponent)  \(size(r.inputBytes)) → \(size(r.outputBytes)) (\(saved))  \(r.width)×\(r.height)  \(r.method)")
    if let s = r.score { print("    \(s)") }
    if let v = r.vision { print("    \(v)") }
}

let saved = totals.input > 0 ? 100 * (1 - Double(totals.output) / Double(totals.input)) : 0
print(String(format: "\n%d file(s): %@ → %@ (%.0f%% smaller) in %.1fs%@",
             files.count - totals.failures, size(totals.input), size(totals.output), saved,
             Date().timeIntervalSince(started), totals.failures > 0 ? ", \(totals.failures) failed" : ""))
exit(totals.failures > 0 ? 1 : 0)
