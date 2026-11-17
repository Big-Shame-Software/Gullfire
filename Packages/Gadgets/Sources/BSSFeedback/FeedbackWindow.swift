import AppKit
import SwiftUI

public enum FeedbackKind: Sendable {
    case problem
    case idea
}

/// Help › Report a Problem… and Help › Suggest an Idea…. Included in every build.
public struct FeedbackCommands: Commands {
    private let appName: String
    private let link: ProjectFolderLink

    public init(app appName: String, defaults: UserDefaults = .standard) {
        self.appName = appName
        self.link = ProjectFolderLink(appName: appName, defaults: defaults)
    }

    public var body: some Commands {
        CommandGroup(after: .help) {
            Button("Report a Problem…") { FeedbackWindow.show(.problem, appName: appName, link: link) }
            Button("Suggest an Idea…") { FeedbackWindow.show(.idea, appName: appName, link: link) }
        }
    }
}

/// The one window behind both Help items.
@MainActor
enum FeedbackWindow {
    private static var window: NSWindow?

    static func show(_ kind: FeedbackKind, appName: String, link: ProjectFolderLink) {
        let behind = NSApp.keyWindow ?? NSApp.mainWindow
        let model = FeedbackModel(kind: kind, link: link, behind: behind)
        let w = NSWindow(contentViewController: NSHostingController(rootView: FeedbackForm(model: model)))
        w.title = kind == .problem ? "Report a Problem" : "Suggest an Idea"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        model.window = w
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
final class FeedbackModel: ObservableObject {
    let kind: FeedbackKind
    let link: ProjectFolderLink
    let behind: NSWindow?
    weak var window: NSWindow?

    @Published var title = ""
    @Published var text = ""
    @Published var attachScreenshot = false
    @Published var message = ""

    init(kind: FeedbackKind, link: ProjectFolderLink, behind: NSWindow?) {
        self.kind = kind
        self.link = link
        self.behind = behind
    }

    var canSave: Bool {
        // An idea is just its text. A problem needs a title; the body may be empty.
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .idea ? !body.isEmpty : !heading.isEmpty
    }

    func save() {
        do {
            if !link.isLinked { try chooseFolder() }
            let info = AppInfo.current()
            let macOS = ProcessInfo.processInfo.operatingSystemVersion
            let macVersion = "\(macOS.majorVersion).\(macOS.minorVersion)"
            let shot = attachScreenshot ? screenshotPNG() : nil
            let saved = try link.withFolder { folder in
                try FeedbackSaver.save(kind: kind, title: title, text: text, screenshot: shot,
                                       app: info, macOS: macVersion, folder: folder)
            }
            guard !saved.isEmpty else {
                message = "Nothing to save."
                return
            }
            window?.close()
        } catch let error as CocoaError where error.code == .userCancelled {
            // Cancelling the folder panel is not an error: stay open, say nothing.
            return
        } catch ProjectFolderLink.Failure.notAProjectFolder(let app) {
            message = "That folder has no \(app).xcodeproj or project.yml. Choose the app's source folder."
        } catch {
            message = "Not saved: \(error.localizedDescription)"
        }
    }

    func close() { window?.close() }

    /// Asks for the source folder. In a sandbox the chosen URL is the only way to get access, so it's kept as a bookmark.
    private func chooseFolder() throws {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose this app's source folder. Reports and ideas are saved in its .statusque folder."
        guard panel.runModal() == .OK, let url = panel.url else { throw CocoaError(.userCancelled) }
        try link.link(to: url)
    }

    /// The window behind this one, as a PNG. Nil when it can't be captured.
    private func screenshotPNG() -> Data? {
        guard let view = behind?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

struct FeedbackForm: View {
    @ObservedObject var model: FeedbackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.kind == .problem ? "Report a Problem" : "Suggest an Idea").font(.headline)
            if model.kind == .problem {
                TextField("Title", text: $model.title)
                    .accessibilityIdentifier("bss-feedback-title")
            }
            TextEditor(text: $model.text)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .accessibilityIdentifier("bss-feedback-text")
            if model.kind == .problem {
                Toggle("Attach a screenshot of the window behind this one", isOn: $model.attachScreenshot)
            }
            if !model.message.isEmpty {
                Text(model.message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("bss-feedback-cancel")
                // Return adds a line in the text box, so Save is Command-Return.
                Button("Save") { model.save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("bss-feedback-save")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
