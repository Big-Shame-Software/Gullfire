import AVFoundation
import Foundation

/// Finds the playable music files in a folder. No AppKit; it only reads files.
public enum MusicLibrary {
    /// File types the system opens for reading.
    public static let extensions: Set<String> = ["wav", "aif", "aiff", "aifc", "caf", "m4a", "aac", "mp3", "flac", "opus"]

    public struct Result: Sendable {
        /// Playable files, in path order.
        public var tracks: [URL]
        /// Files with a music extension that could not be opened (for example copy-protected), with the reason.
        public var skipped: [(url: URL, reason: String)]
    }

    /// Every playable file in `folder` and its subfolders. Hidden files and the insides of packages
    /// are not looked at. A file that will not open is skipped and reported, never an error.
    public static func scan(folder: URL) -> Result {
        var tracks: [URL] = []
        var skipped: [(url: URL, reason: String)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return Result(tracks: [], skipped: [])
        }
        for case let url as URL in walker {
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            autoreleasepool {
                do {
                    let file = try AVAudioFile(forReading: url)
                    if file.length > 0 { tracks.append(url) } else { skipped.append((url, "empty")) }
                } catch {
                    skipped.append((url, "\(error.localizedDescription)"))
                }
            }
        }
        tracks.sort { $0.path < $1.path }
        return Result(tracks: tracks, skipped: skipped)
    }

    /// Every playable file in the folders, with its length. A folder is walked once, and a file
    /// reached twice (overlapping folders) is listed once. Files that will not open are left out.
    public static func lengths(in folders: [URL]) -> [CathedralFinder.Length] {
        var seen = Set<String>()
        var found: [CathedralFinder.Length] = []
        for folder in folders {
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                guard extensions.contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                if let seconds = length(of: url) { found.append(CathedralFinder.Length(url: url, seconds: seconds)) }
            }
        }
        return found
    }

    /// The length of a playable file in seconds, or nil if it will not open or is empty.
    public static func length(of url: URL) -> Double? {
        autoreleasepool {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }
    }

    /// A random order, using the caller's generator so tests can fix it.
    public static func shuffled<G: RandomNumberGenerator>(_ tracks: [URL], using generator: inout G) -> [URL] {
        tracks.shuffled(using: &generator)
    }
}
