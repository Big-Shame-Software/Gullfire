import Foundation

/// The app that wrote a report, as the build sees it.
public struct AppInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var build: String
    public var configuration: String

    public init(name: String, version: String, build: String, configuration: String) {
        self.name = name
        self.version = version
        self.build = build
        self.configuration = configuration
    }

    /// Reads the bundle's name, version and build. `configuration` is "Debug" or "Release" for this compile.
    public static func current(bundle: Bundle = .main) -> AppInfo {
        let info = bundle.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return AppInfo(
            name: info["CFBundleName"] as? String ?? "App",
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            configuration: configuration
        )
    }
}

/// `statusque-bug/1`: one problem report, saved as `.statusque/bugs/<stamp>-<slug>.json`.
public struct ProblemReport: Codable, Equatable, Sendable {
    public static let format = "statusque-bug/1"

    public var format: String = ProblemReport.format
    public var id: String
    public var createdAt: String
    public var status: String = "open"
    public var app: AppInfo
    public var macOS: String
    public var title: String
    public var body: String
    public var attachments: [String]
    public var resolvedAt: String?
    public var resolution: String?

    public init(id: String, createdAt: String, app: AppInfo, macOS: String, title: String, body: String,
                attachments: [String] = [], resolvedAt: String? = nil, resolution: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.app = app
        self.macOS = macOS
        self.title = title
        self.body = body
        self.attachments = attachments
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }
}
