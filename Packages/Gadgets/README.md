<p align="center"><img src=".github/big-shame-logo.png" alt="Big Shame Software" width="360"></p>

# Gadgets: Drop-in Tools for Big Shame Apps

Gadgets is a Swift package of small background tools that any Big Shame Software app can drop in.

There are four gadgets. One is an image optimizer, which turns any picture macOS can open into the smallest plain JPEG or PNG that still looks like the original. The other three came out of a forum reader that didn't make it: a reader for saved web pages, a credential scrubber for web addresses, and an asset store that keeps each image once. They're libraries, not apps: source only, Swift only, no dependencies beyond macOS 27. The plural in the name has finally been earned.

| Gadget | What it does |
|---|---|
| [BSSImageOptimizer](#bssimageoptimizer) | Any image in, the smallest plain JPEG or PNG that still looks right out |
| [BSSSavedHTML](#bsssavedhtml) | Reads saved web pages, valid or not, without running or fetching anything |
| [BSSRedact](#bssredact) | Takes passkeys, session tokens and member numbers out of web addresses |
| [BSSAssetStore](#bssassetstore) | Stores images, stylesheets and fonts once each, shrinks images to AVIF, removes their metadata |

## BSSImageOptimizer

Reads **any image macOS can open** (HEIC, DNG and other RAW, JPEG XL, WebP, TIFF, PNG, JPEG, …) and writes the
**smallest plain JPEG or PNG** that still looks like the original, so Plex, browsers, TVs and old software all show it.

How it decides:

| Image | Output |
|---|---|
| Photograph | Progressive JPEG at the lowest quality that passes the check (binary search) |
| ≤ 256 colours | Lossless palette PNG (1/2/4/8-bit) |
| Flat art, UI, screenshots (≤ 32 768 colours) | Smallest of: palette PNG at 256/128/64/32 colours that passes the check, lossless PNG, JPEG |
| Transparency | PNG (palette if it passes, otherwise lossless RGBA) |
| Already a JPEG/PNG and nothing smaller is possible | The original bytes, untouched |

Every lossy candidate is decoded again and compared with the original: SSIM at full and half size, the worst
64 × 64 tile (catches local blockiness or ringing a plain average hides) and colour SSIM. Presets: `maximum`,
`high` (default), `balanced`.

**Apple Vision second opinion (the ladder).** Every lossy result that passes SSIM is also shown to Apple Vision
(image feature print + aesthetics score). Vision's distance jumps to an image-specific plateau for *any* lossy change,
even a q98 JPEG, then stays flat until real damage starts. So the limit is relative to each image: no further from the
original than that image as a q98 JPEG (× 1.5 + 0.005 for `high`), and no aesthetics drop beyond the q98 drop + 0.02.
If a result fails, the optimiser climbs: next JPEG quality (+4, up to q98), the next larger palette, then lossless PNG.
Both sides are scored from decoded pixels, never the original file, because Vision reads TIFF, WebP and RAW containers
differently from the same pixels in a PNG. On the 20-file sample it raised two JPEGs (an avatar q70 → q82, an AI
portrait q70 → q74) and one screenshot palette (64 → 127 colours), and cost about 5 % more time. `visionCheck = false`
or `--no-vision` turns it off; `swift run -c release vision-calibrate FILE…` prints the curve the limits came from.

Pixels are always made upright (EXIF orientation applied), converted to sRGB and stripped of metadata; PNGs carry
only a 13-byte `sRGB` chunk. The PNG writer is our own: it picks the smallest colour type and bit depth and tries
several filter/deflate strategies.

```swift
import BSSImageOptimizer

let optimizer = ImageOptimizer(options: .init(quality: .high, maxPixelSize: 3840))
let (result, url) = try optimizer.optimizeFile(at: input, into: outputFolder)
print(result.method, result.outputBytes, result.score as Any)

// Many files, two at a time, each written as soon as it is done:
await optimizer.optimizeFiles(urls, into: outputFolder) { outcome in … }
```

Command line:

```
swift build -c release
.build/release/bss-optimize -o ~/Desktop/optimized --quality high --max 3840 *.heic
```

### Things to know

- HEIC, JPEG XL and WebP are more efficient than JPEG, so converting them can make a file *bigger*.
  That is the price of universal. Use `--max` to bring size down if that matters.
- Very wide-gamut (Display P3) colours are mapped into sRGB.
- Memory: about 450 MB per 12-megapixel photo, about 1.2 GB for a 36-megapixel scan. Keep it to two at a time
  (the batch API does that).

### Icon

`ImageOptimizerGadget.iconURL(scale:)` gives the gadget's pixel icon (32 × 32 at 1×, 2×, 4×, 8×), and
`ImageOptimizerGadget.credit` a one-line credit, for About windows and empty states. It is Big Shame pixel art
(styleguide §6–7): plum outline, three colours from the Media family. Draw it at whole-number scales with no smoothing.
`python3 Art/make-icon.py` rebuilds the SVG and PNGs from the grid in that script.

## BSSSavedHTML

Two ways to read a saved web page (a SingleFile download, or any `.html`). Neither runs a script, loads an image or
fetches anything. Scripts and styles are skipped, and garbage goes in without a crash: both are fuzzed with 3,000
seeded cases on every test run.

- **`HTMLScanner`**: one pass over the bytes, no tree. You get `PageFacts`: title, SingleFile's saved address and
  date, canonical address, generator, tag and class counts, ids, links, RSS and Atom feeds, comments and the visible
  text. SingleFile pages can be tens of megabytes of inlined images, so long attribute values are cut, not copied.
- **`HTMLTree`**: a forgiving tree when you need structure. It closes what a page leaves open, ignores stray end tags,
  and gives you `elements(where:)`, `textContent` and `outerHTML`. Hard caps (512 levels deep, 200,000 nodes, 256
  attributes, 2 MiB per attribute) stop a hostile page, and `HTMLDocument.limit` says which cap it hit. If `limit`
  is set, don't use the tree.

```swift
import BSSSavedHTML

let facts = try HTMLScanner.scan(fileAt: page)
print(facts.title, facts.pageURL ?? "no address", facts.feeds)

let doc = HTMLTree.parse(html)
guard doc.limit == nil else { return }
let posts = doc.root.elements { $0.hasClass("post") }.map(\.textContent)
```

## BSSRedact

`Redact.url(_:)` takes credentials out of a web address, or out of text with addresses in it, and puts `REDACTED`
where they were. Private sites put passkeys, session ids and member numbers in feed and download links, so run it
before you show, log or share an address.

- Parameters named like a credential (`passkey`, `token`, `PHPSESSID`, `user`, `sid`, `api_key`, …) are redacted,
  in the query and in the fragment. Lookalikes such as `keyword`, `monkey` and `author` aren't.
- `code` is redacted only in an OAuth redirect (one that also carries `state`, `client_id` or `redirect_uri`).
- Runs of 24 or more hex digits are redacted inside parameter values and after words like `token/` or `download.php/`.
  A bare commit hash in a path is left alone.

It's a word list and some patterns, not a guarantee. If it misses a credential your site uses, that's an issue
worth opening.

## BSSAssetStore

A folder where each asset is stored once, named by the SHA-256 of what is stored (`ab/ab12….avif`). Storing the
same thing twice writes nothing the second time.

- Still images over 4 KB are scaled to fit 1600 px on the long side and written as AVIF, but only if that saves at
  least 25%.
- Every image loses its EXIF, GPS, XMP and IPTC metadata, whether or not it became AVIF.
- Animated images, SVG, CSS and fonts are kept exactly as given.
- If the Mac can't write AVIF, images keep their own format with the metadata removed.

```swift
import BSSAssetStore

let store = AssetStore(root: assetsFolder, options: .init(maxPixelSize: 1600, quality: 0.8))
let stored = try store.store(data, contentType: "image/png")
print(stored.path, stored.change, stored.bytes, stored.originalBytes)
```

## Requirements

- macOS 27 or later
- Xcode [TODO: confirm version] or a Swift toolchain that builds the package

No prebuilt binaries are published.

## How to help

If the optimizer makes an image look worse, please open an issue with what kind of image it was and which preset you used. We don't take pull requests, so an issue is the way in. We'd rather know.

## Credits and thanks

- Similarity checks use SSIM; the second opinion is Apple's [Vision](https://developer.apple.com/documentation/vision) framework.
- [TODO: confirm AI disclosure for Gadgets.] Written mostly with Claude, with some consulting from ChatGPT and occasional help from Gemini or an on-device Qwen model. No Grok was used.

## Licence

N©! Big Shame Software 2026. Public domain, via [the Unlicense](LICENSE).

a Big Shame Software package
