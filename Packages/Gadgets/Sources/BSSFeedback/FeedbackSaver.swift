import Foundation

/// Writes one problem report or one idea into a project folder. No UI, so the save path can be tested directly.
/// The form calls this inside `ProjectFolderLink.withFolder`.
public enum FeedbackSaver {
    /// Returns what was written: the report id for a problem, or `"idea"` for an idea. Returns `""` when nothing was
    /// written (a blank idea). Blank text touches nothing on disk. `.statusque/` goes into the git exclude file first,
    /// so if that fails nothing is written.
    @discardableResult
    public static func save(kind: FeedbackKind, title: String, text: String, screenshot: Data?,
                            app: AppInfo, macOS: String, folder: URL, now: Date = Date()) throws -> String {
        switch kind {
        case .idea:
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return "" }
            try GitExclude.ensure(".statusque/", in: folder)
            let inbox = folder.appending(path: ".statusque").appending(path: Inbox.fileName)
            let note = try Inbox.append(FeedbackText.scrub(body), to: inbox, kind: "idea",
                                        from: Inbox.Source(app: app.name, version: app.version, build: app.build))
            return note == nil ? "" : "idea"
        case .problem:
            let report = try ProblemWriter.write(title: title, body: text, app: app, macOS: macOS,
                                                 screenshot: screenshot, to: folder, now: now)
            return report.id
        }
    }
}
