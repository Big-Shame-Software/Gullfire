import Foundation

/// `statusque-inbox/1` (`.statusque/inbox.json`): notes waiting to become quick cards in StatusQué.
///
/// Every read-modify-write goes through `NSFileCoordinator`, so Quick Note, a Big Shame app's
/// Suggest an Idea window and a StatusQué board never overwrite each other.
/// `kind` and `from` are optional. An older reader ignores them and still sees a plain quick card.
/// This is storage only. Turning notes into cards (`Plan.absorb`) stays in StatusQué.
public struct Inbox: Codable, Equatable, Sendable {
    public static let format = "statusque-inbox/1"
    public static let fileName = "inbox.json"

    public var format: String = Inbox.format
    public var notes: [Note] = []

    /// The app that wrote an idea.
    public struct Source: Codable, Equatable, Sendable {
        public var app: String
        public var version: String
        public var build: String

        public init(app: String, version: String, build: String) {
            self.app = app
            self.version = version
            self.build = build
        }
    }

    public struct Note: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var text: String
        public var createdAt: String
        /// `"idea"` for a note from Suggest an Idea. Nil for Quick Note.
        public var kind: String?
        public var from: Source?

        public init(id: String, text: String, createdAt: String, kind: String? = nil, from: Source? = nil) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.kind = kind
            self.from = from
        }
    }

    public init(notes: [Note] = []) { self.notes = notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? Inbox.format
        // A note with no text is dropped rather than failing the whole file.
        notes = (try c.decodeIfPresent([Note].self, forKey: .notes) ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func decode(_ data: Data) throws -> Inbox {
        try JSONDecoder().decode(Inbox.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Adds a note. Blank text is ignored. Returns the note, or nil when nothing was added.
    @discardableResult
    public mutating func append(_ raw: String, stamp: String, kind: String? = nil, from: Source? = nil) -> Note? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let note = Note(id: Inbox.noteID(text: text, stamp: stamp), text: text, createdAt: stamp, kind: kind, from: from)
        notes.append(note)
        return note
    }

    /// `note-<first words, slugged>-<random>`. The random part keeps two identical notes from sharing an id.
    public static func noteID(text: String, stamp: String) -> String {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: "-")
        let random = String(UUID().uuidString.prefix(8)).lowercased()
        return "note-\(words.isEmpty ? "untitled" : words)-\(random)"
    }

    // MARK: Coordinated file access

    /// Reads the inbox; a missing file is an empty inbox.
    public static func load(at url: URL) throws -> Inbox {
        try coordinate(url, writing: false) { try readFile($0) }
    }

    /// Adds one note under a coordinated read-modify-write. Returns the note, or nil for blank text.
    @discardableResult
    public static func append(_ text: String, to url: URL, stamp: String = Inbox.timestamp(),
                              kind: String? = nil, from: Source? = nil) throws -> Note? {
        try coordinate(url, writing: true) { target in
            var inbox = try readFile(target)
            guard let note = inbox.append(text, stamp: stamp, kind: kind, from: from) else { return nil }
            try inbox.write(to: target)
            return note
        }
    }

    /// Removes only the given ids. A note appended after the absorb is kept, because it re-reads the file first.
    public static func clear(ids: Set<String>, at url: URL) throws {
        try coordinate(url, writing: true) { target in
            var inbox = try readFile(target)
            inbox.notes.removeAll { ids.contains($0.id) }
            try inbox.write(to: target)
        }
    }

    /// Plain read, used only inside a coordinated block. Never coordinate again from inside one.
    private static func readFile(_ url: URL) throws -> Inbox {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return Inbox() }
        return try decode(Data(contentsOf: url))
    }

    /// Writes atomically, so a crash leaves either the old file or the new one.
    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            // Coordination needs the folder to exist: it writes its temporary file there.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { target in
                result = Result { try body(target) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
                result = Result { try body(target) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
