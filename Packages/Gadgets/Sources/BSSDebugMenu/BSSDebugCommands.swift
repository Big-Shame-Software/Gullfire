#if DEBUG
import AppKit
import BSSFeedback
import OSLog
import SwiftUI

/// Debug builds only: every line of this module sits inside `#if DEBUG`, so linking it into a Release build adds nothing.
/// `marker` is logged when the menu is built, so it's in the binary; bss-check looks for it in a built app.
public enum BSSDebugMenu {
    public static let marker = "BSS-DEBUG-MENU"
    /// The shared Verbose Logging default (the name BestImage already uses).
    public static let verboseKey = "debugLogging"
}

/// Sample-data actions. `noun` completes the labels: "Create Scratch \(noun)" and "Remove Scratch \(noun)".
/// Each action gets the window-opening action, read from the Commands' own environment, so it can open a window.
public struct ScratchActions {
    public let noun: String
    public let create: @MainActor (OpenWindowAction) -> Void
    public let remove: @MainActor (OpenWindowAction) -> Void

    public init(noun: String = "Data",
                create: @escaping @MainActor (OpenWindowAction) -> Void,
                remove: @escaping @MainActor (OpenWindowAction) -> Void) {
        self.noun = noun
        self.create = create
        self.remove = remove
    }
}

/// The Debug menu. Standard items, then the optional hooks, then the app's own items after a divider.
public struct BSSDebugCommands<Items: View>: Commands {
    private let appName: String
    private let bundleID: String
    private let defaults: UserDefaults
    private let link: ProjectFolderLink
    private let scratch: ScratchActions?
    private let screenshot: (@MainActor () -> Void)?
    private let items: Items
    /// Read here, in a Commands value: an App struct's environment doesn't provide it.
    @Environment(\.openWindow) private var openWindow

    public init(appName: String, bundleID: String, defaults: UserDefaults = .standard,
                scratch: ScratchActions? = nil, screenshot: (@MainActor () -> Void)? = nil,
                @ViewBuilder items: () -> Items) {
        self.appName = appName
        self.bundleID = bundleID
        self.defaults = defaults
        self.link = ProjectFolderLink(appName: appName, defaults: defaults)
        self.scratch = scratch
        self.screenshot = screenshot
        self.items = items()
        Logger(subsystem: bundleID, category: "debug-menu")
            .debug("\(BSSDebugMenu.marker, privacy: .public) menu built for \(appName, privacy: .public)")
    }

    public var body: some Commands {
        CommandMenu("Debug") {
            Button(buildLine) {}
                .disabled(true)
            Divider()
            Button("Show App Data in Finder") { showAppData() }
            Button("Copy Log Command") { copyLogCommand() }
            VerboseToggle(defaults: defaults)
            if let scratch {
                Divider()
                Button("Create Scratch \(scratch.noun)") { scratch.create(openWindow) }
                Button("Remove Scratch \(scratch.noun)") { scratch.remove(openWindow) }
            }
            if let screenshot {
                Divider()
                Button("Screenshot Mode") { screenshot() }
            }
            Divider()
            Button("Reset Settings…") { resetSettings() }
            Button("Show Problem Reports in Finder") { showReports() }
                .disabled(!link.isLinked)
            if !(items is EmptyView) {
                Divider()
                items
            }
        }
    }

    private var info: AppInfo { AppInfo.current() }

    private var buildLine: String {
        "\(info.name) \(info.version) (\(info.build)) · \(info.configuration)"
    }

    /// Opens the app's Application Support folder. In a sandbox, that call already resolves inside the container.
    private func showAppData() {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return }
        let url = support.appending(path: bundleID)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func copyLogCommand() {
        let command = "log stream --level debug --predicate 'subsystem == \"\(bundleID)\"'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Clears the app's defaults after a confirmation. The source-folder bookmark is kept.
    private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset \(appName) settings?"
        alert.informativeText = "This clears the app's preferences. Your linked source folder is kept."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for key in defaults.persistentDomain(forName: bundleID)?.keys ?? [:].keys where key != ProjectFolderLink.defaultsKey {
            defaults.removeObject(forKey: key)
        }
    }

    private func showReports() {
        try? link.withFolder { folder in
            let bugs = folder.appending(path: ".statusque").appending(path: "bugs")
            try FileManager.default.createDirectory(at: bugs, withIntermediateDirectories: true)
            NSWorkspace.shared.open(bugs)
        }
    }
}

/// Verbose Logging as a menu checkmark. A View, so @AppStorage re-reads the default when it changes.
struct VerboseToggle: View {
    @AppStorage(BSSDebugMenu.verboseKey) private var verbose = false

    init(defaults: UserDefaults) {
        _verbose = AppStorage(wrappedValue: false, BSSDebugMenu.verboseKey, store: defaults)
    }

    var body: some View {
        Toggle("Verbose Logging", isOn: $verbose)
    }
}

extension BSSDebugCommands where Items == EmptyView {
    public init(appName: String, bundleID: String, defaults: UserDefaults = .standard,
                scratch: ScratchActions? = nil, screenshot: (@MainActor () -> Void)? = nil) {
        self.init(appName: appName, bundleID: bundleID, defaults: defaults,
                  scratch: scratch, screenshot: screenshot, items: { EmptyView() })
    }
}
#endif
