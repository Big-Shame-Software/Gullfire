import Foundation

/// Adds a line to the repository's exclude file so `.statusque/` stays out of commits.
/// A plain repository uses `.git/info/exclude`. A linked worktree's `.git` is a file that points at its git dir,
/// and that dir's `commondir` names the shared git dir, where the exclude file lives.
///
/// Unlike StatusQué's old copy, a failed write throws. A report that git doesn't ignore must not be saved.
public enum GitExclude {
    public enum Failure: Error, Equatable {
        /// `.git` exists but doesn't name a git directory.
        case unreadableGitFile(URL)
        /// The line wasn't in the exclude file after writing it.
        case notWritten(URL)
    }

    /// The exclude file for `folder`, or nil when `folder` isn't a repository.
    public static func excludeFile(for folder: URL) throws -> URL? {
        let git = folder.appending(path: ".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path(percentEncoded: false), isDirectory: &isDir) else { return nil }

        var gitDir: URL
        if isDir.boolValue {
            gitDir = git
        } else {
            guard let text = try? String(contentsOf: git, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else {
                throw Failure.unreadableGitFile(git)
            }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = resolve(path, relativeTo: folder)
        }
        if let common = try? String(contentsOf: gitDir.appending(path: "commondir"), encoding: .utf8) {
            gitDir = resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
        }
        return gitDir.appending(path: "info").appending(path: "exclude")
    }

    /// Makes sure `entry` is in the exclude file. Returns false when `folder` isn't a repository (nothing to do:
    /// the global ignore covers it). Throws when the repository's exclude file can't be written.
    @discardableResult
    public static func ensure(_ entry: String, in folder: URL) throws -> Bool {
        guard let file = try excludeFile(for: folder) else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = fm.fileExists(atPath: file.path(percentEncoded: false))
            ? try String(contentsOf: file, encoding: .utf8)
            : ""
        if contains(entry, in: current) { return true }
        let base = current.isEmpty || current.hasSuffix("\n") ? current : current + "\n"
        try (base + entry + "\n").write(to: file, atomically: true, encoding: .utf8)
        // Read back, so a write that didn't land is an error rather than silence.
        let check = try String(contentsOf: file, encoding: .utf8)
        guard contains(entry, in: check) else { throw Failure.notWritten(file) }
        return true
    }

    private static func contains(_ entry: String, in text: String) -> Bool {
        text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == entry }
    }

    private static func resolve(_ path: String, relativeTo base: URL) -> URL {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : base.appending(path: path, directoryHint: .isDirectory)
        return url.standardizedFileURL
    }
}
