import Foundation

/// The app's source folder, linked once. Only bookmark data is stored in the app's defaults, never a path string.
/// A sandboxed app stores a security-scoped bookmark and uses it under `withFolder`. Other apps store a plain one.
@MainActor
public final class ProjectFolderLink {
    /// The defaults key holding the bookmark data. The Debug menu's Reset Settings keeps this key.
    public static let defaultsKey = "BSSFeedback.sourceFolderBookmark"

    public enum Failure: Error, Equatable {
        /// The folder has neither `<App>.xcodeproj` nor `project.yml`.
        case notAProjectFolder(String)
        case noLinkedFolder
    }

    private let appName: String
    private let defaults: UserDefaults
    private let sandboxed: Bool

    public init(appName: String, defaults: UserDefaults = .standard, sandboxed: Bool = ProjectFolderLink.detectSandbox()) {
        self.appName = appName
        self.defaults = defaults
        self.sandboxed = sandboxed
    }

    /// True when the process runs in an app sandbox.
    nonisolated public static func detectSandbox() -> Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// True when `folder` holds this app's project: `<App>.xcodeproj` or `project.yml`.
    public static func isProjectFolder(_ folder: URL, appName: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appending(path: "\(appName).xcodeproj").path(percentEncoded: false))
            || fm.fileExists(atPath: folder.appending(path: "project.yml").path(percentEncoded: false))
    }

    public var isLinked: Bool {
        defaults.data(forKey: Self.defaultsKey) != nil
    }

    /// Links `folder` after checking it's this app's project. In a sandbox, `folder` must come from an open panel.
    public func link(to folder: URL) throws {
        guard Self.isProjectFolder(folder, appName: appName) else { throw Failure.notAProjectFolder(appName) }
        let data = try folder.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Runs `body` with the linked folder. In a sandbox the security scope is held for the duration.
    /// A stale bookmark is renewed while the scope is open.
    public func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { throw Failure.noLinkedFolder }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = sandboxed && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.defaultsKey)
        }
        return try body(url)
    }

    private var creationOptions: URL.BookmarkCreationOptions {
        sandboxed ? [.withSecurityScope] : []
    }

    private var resolutionOptions: URL.BookmarkResolutionOptions {
        sandboxed ? [.withSecurityScope] : []
    }
}
