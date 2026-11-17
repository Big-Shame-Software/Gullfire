import Foundation

/// Writes problem reports into a project's `.statusque/bugs/` folder.
public enum ProblemWriter {
    public enum Failure: Error, Equatable {
        case emptyTitle
    }

    /// Writes one report. `.statusque/` goes into the git exclude file first. If that fails, nothing is written.
    /// A screenshot, when given, is saved beside the report as a PNG and listed in `attachments`.
    @discardableResult
    public static func write(title: String, body: String, app: AppInfo, macOS: String, screenshot: Data? = nil,
                             to project: URL, now: Date = Date()) throws -> ProblemReport {
        let cleanTitle = FeedbackText.scrub(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw Failure.emptyTitle }

        try GitExclude.ensure(".statusque/", in: project)
        let bugs = project.appending(path: ".statusque").appending(path: "bugs")
        try FileManager.default.createDirectory(at: bugs, withIntermediateDirectories: true)

        let base = uniqueBase(in: bugs, "\(stamp(now))-\(slug(cleanTitle))")
        var attachments: [String] = []
        if let screenshot {
            let name = base + ".png"
            try screenshot.write(to: bugs.appending(path: name), options: .atomic)
            attachments.append(name)
        }
        let report = ProblemReport(
            id: base,
            createdAt: ISO8601DateFormatter().string(from: now),
            app: app,
            macOS: macOS,
            title: cleanTitle,
            body: FeedbackText.scrub(body),
            attachments: attachments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: bugs.appending(path: base + ".json"), options: .atomic)
        return report
    }

    /// Up to six words of the title, lowercased and joined with dashes. Never empty.
    public static func slug(_ title: String) -> String {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "report" : String(slug.prefix(60))
    }

    /// Local time as `YYYY-MM-DD-HHmm`.
    public static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    /// Adds `-2`, `-3`… when a report with the same name already exists, so nothing is overwritten.
    private static func uniqueBase(in folder: URL, _ base: String) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: folder.appending(path: candidate + ".json").path(percentEncoded: false)) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }
}
