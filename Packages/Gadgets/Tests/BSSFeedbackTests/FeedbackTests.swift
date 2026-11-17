import Foundation
import Testing
import BSSFeedback

/// A fresh temporary folder for one test.
private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bss-feedback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A folder that is a git repository, with an `info` directory for the exclude file.
private func repoFolder() throws -> URL {
    let folder = try tempFolder()
    try FileManager.default.createDirectory(at: folder.appending(path: ".git/info"), withIntermediateDirectories: true)
    return folder
}

private let app = AppInfo(name: "TestApp", version: "1.0", build: "1", configuration: "Debug")

// MARK: Inbox

@Suite struct InboxTests {
    @Test func appendAndLoadRoundTrip() throws {
        let url = try tempFolder().appending(path: Inbox.fileName)
        let note = try Inbox.append("Pause all from the menu bar\nOne click.", to: url, stamp: "2026-11-13T14:30:00Z")
        #expect(note != nil)
        let inbox = try Inbox.load(at: url)
        #expect(inbox.format == "statusque-inbox/1")
        #expect(inbox.notes.count == 1)
        #expect(inbox.notes.first?.text == "Pause all from the menu bar\nOne click.")
    }

    @Test func blankTextIsNotAdded() throws {
        let url = try tempFolder().appending(path: Inbox.fileName)
        #expect(try Inbox.append("   \n ", to: url) == nil)
        #expect(try Inbox.load(at: url).notes.isEmpty)
    }

    @Test func ideaCarriesKindAndSource() throws {
        let url = try tempFolder().appending(path: Inbox.fileName)
        try Inbox.append("Batch pause", to: url, kind: "idea",
                         from: Inbox.Source(app: "SampleApp", version: "1.2.0", build: "34"))
        let note = try #require(try Inbox.load(at: url).notes.first)
        #expect(note.kind == "idea")
        #expect(note.from == Inbox.Source(app: "SampleApp", version: "1.2.0", build: "34"))
    }

    @Test func clearRemovesOnlyTheGivenIDs() throws {
        let url = try tempFolder().appending(path: Inbox.fileName)
        let first = try #require(try Inbox.append("first", to: url))
        let second = try #require(try Inbox.append("second", to: url))
        try Inbox.clear(ids: [first.id], at: url)
        let left = try Inbox.load(at: url).notes
        #expect(left.map(\.id) == [second.id])
    }

    /// A reader from before `kind` and `from` existed must still decode a new file.
    @Test func decodesNotesWithUnknownKeys() throws {
        let json = """
        { "format": "statusque-inbox/1", "notes": [
          { "id": "note-a-1", "text": "hi", "createdAt": "2026-11-13T14:30:00Z",
            "kind": "idea", "from": { "app": "X", "version": "1", "build": "2" }, "futureKey": 3 } ] }
        """
        let inbox = try Inbox.decode(Data(json.utf8))
        #expect(inbox.notes.count == 1)
        #expect(inbox.notes.first?.text == "hi")
    }

    @Test func noteWithBlankTextIsDroppedNotFatal() throws {
        let json = """
        { "format": "statusque-inbox/1", "notes": [
          { "id": "a", "text": "  ", "createdAt": "x" }, { "id": "b", "text": "kept", "createdAt": "x" } ] }
        """
        let inbox = try Inbox.decode(Data(json.utf8))
        #expect(inbox.notes.map(\.id) == ["b"])
    }
}

// MARK: Compatibility with StatusQué's current reader

/// A private copy of the Note and Inbox shape StatusQué reads today (`Inbox.swift` in StatusQué).
/// It has no `kind` or `from`, so this proves what an un-updated StatusQué does with a new idea.
private struct LegacyInboxNote: Codable {
    var id: String
    var text: String
    var createdAt: String
}

private struct LegacyInbox: Codable {
    var format: String
    var notes: [LegacyInboxNote]
}

@Suite struct InboxCompatibilityTests {
    @Test func oldReaderReadsAnIdeaButLosesKindAndSource() throws {
        var inbox = Inbox()
        inbox.append("Pause all from the menu bar", stamp: "2026-11-13T14:30:00Z", kind: "idea",
                     from: Inbox.Source(app: "SampleApp", version: "1.2.0", build: "34"))
        let newFile = try inbox.encoded()

        // The old reader decodes the new file without error.
        let old = try JSONDecoder().decode(LegacyInbox.self, from: newFile)
        #expect(old.notes.count == 1)
        #expect(old.notes.first?.text == "Pause all from the menu bar")

        // What it writes back has no kind or source: they are lost.
        let oldWritten = try JSONEncoder().encode(old)
        let back = try Inbox.decode(oldWritten)
        #expect(back.notes.count == 1)
        #expect(back.notes.first?.text == "Pause all from the menu bar")
        #expect(back.notes.first?.kind == nil)
        #expect(back.notes.first?.from == nil)
        // The loss is expected. StatusQué must switch to this Inbox before any app ships Suggest an Idea.
    }
}

// MARK: Concurrent writers

@Suite struct InboxConcurrencyTests {
    /// Final collector for failures from the worker threads.
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Two workers in one process, each appending 50 notes to the same file. The method is threads, not processes:
    /// `Process` would need a second executable target that exists only for tests.
    @Test func concurrentAppendsKeepEveryNote() throws {
        let url = try tempFolder().appending(path: Inbox.fileName)
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for i in 0..<50 {
                do {
                    try Inbox.append("worker \(worker) note \(i)", to: url)
                } catch {
                    failures.add("worker \(worker) note \(i): \(error)")
                }
            }
        }
        #expect(failures.all.isEmpty)
        let notes = try Inbox.load(at: url).notes
        #expect(notes.count == 100)
        #expect(Set(notes.map(\.id)).count == 100)
    }
}

// MARK: Git exclude

@Suite struct GitExcludeTests {
    @Test func notARepositoryDoesNothing() throws {
        let folder = try tempFolder()
        #expect(try GitExclude.ensure(".statusque/", in: folder) == false)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) == false)
    }

    @Test func addsEntryOnceInPlainRepository() throws {
        let folder = try repoFolder()
        #expect(try GitExclude.ensure(".statusque/", in: folder))
        #expect(try GitExclude.ensure(".statusque/", in: folder))
        let text = try String(contentsOf: folder.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(text.components(separatedBy: ".statusque/").count == 2)
    }

    @Test func followsAWorktreeToTheSharedGitDir() throws {
        let folder = try tempFolder()
        let shared = try tempFolder().appending(path: "shared.git")
        try FileManager.default.createDirectory(at: shared.appending(path: "info"), withIntermediateDirectories: true)
        let gitDir = shared.appending(path: "worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "../..".write(to: gitDir.appending(path: "commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(gitDir.path)\n".write(to: folder.appending(path: ".git"), atomically: true, encoding: .utf8)

        try GitExclude.ensure(".statusque/", in: folder)
        let text = try String(contentsOf: shared.appending(path: "info/exclude"), encoding: .utf8)
        #expect(text.contains(".statusque/"))
    }

    /// When the exclude file can't be written, the error is thrown. Silence would let reports reach git.
    @Test func unwritableExcludeThrows() throws {
        let folder = try repoFolder()
        // A directory where the exclude file should be: it can't be read or replaced as a file.
        try FileManager.default.createDirectory(at: folder.appending(path: ".git/info/exclude"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try GitExclude.ensure(".statusque/", in: folder)
        }
    }
}

// MARK: Scrubbing

@Suite struct FeedbackTextTests {
    /// The home path comes from the running system, so no real home path is written into the source.
    @Test func homeFoldersBecomeTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(FeedbackText.scrub("saved in \(home)/Documents/x.json") == "saved in ~/Documents/x.json")
    }

    @Test func webAddressCredentialsAreRemoved() {
        let out = FeedbackText.scrub("see https://example.com/cb?access_token=abc123secret&page=2")
        #expect(!out.contains("abc123secret"))
        #expect(out.hasPrefix("see https://example.com/cb"))
    }

    @Test func plainTextIsUnchanged() {
        #expect(FeedbackText.scrub("Queue stalls after a resume.") == "Queue stalls after a resume.")
    }
}

// MARK: Problem reports

@Suite struct ProblemWriterTests {
    @Test func writesAReportThatGitIgnores() throws {
        let project = try repoFolder()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let report = try ProblemWriter.write(title: "Queue stalls after a resume", body: "Saved in \(home)/x",
                                             app: app, macOS: "27.0", to: project,
                                             now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(report.format == "statusque-bug/1")
        #expect(report.status == "open")
        #expect(report.body == "Saved in ~/x")
        #expect(report.attachments.isEmpty)

        let bugs = project.appending(path: ".statusque/bugs")
        let files = try FileManager.default.contentsOfDirectory(atPath: bugs.path)
        #expect(files.count == 1)
        #expect(files.first?.hasSuffix(".json") == true)
        let exclude = try String(contentsOf: project.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".statusque/"))
    }

    @Test func savesScreenshotBesideTheReport() throws {
        let project = try repoFolder()
        let report = try ProblemWriter.write(title: "Shot", body: "", app: app, macOS: "27.0",
                                             screenshot: Data([0x89, 0x50, 0x4E, 0x47]), to: project)
        #expect(report.attachments.count == 1)
        #expect(report.attachments.first?.hasSuffix(".png") == true)
    }

    /// If git can't be told to ignore `.statusque/`, nothing may be written there.
    @Test func exclusionFailureWritesNothing() throws {
        let project = try repoFolder()
        try FileManager.default.createDirectory(at: project.appending(path: ".git/info/exclude"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try ProblemWriter.write(title: "Should not be saved", body: "", app: app, macOS: "27.0", to: project)
        }
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".statusque").path))
    }

    @Test func emptyTitleIsRefused() throws {
        let project = try repoFolder()
        #expect(throws: ProblemWriter.Failure.emptyTitle) {
            try ProblemWriter.write(title: "  ", body: "x", app: app, macOS: "27.0", to: project)
        }
    }

    @Test func slugIsSafeAndNeverEmpty() {
        #expect(ProblemWriter.slug("Queue stalls, after a resume!") == "queue-stalls-after-a-resume")
        #expect(ProblemWriter.slug("!!!") == "report")
    }
}

// MARK: Source folder link

@MainActor
@Suite struct ProjectFolderLinkTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "bss-feedback-test-\(UUID().uuidString)")!
    }

    @Test func rejectsAFolderThatIsNotTheProject() throws {
        let link = ProjectFolderLink(appName: "TestApp", defaults: defaults(), sandboxed: false)
        #expect(throws: ProjectFolderLink.Failure.notAProjectFolder("TestApp")) {
            try link.link(to: try tempFolder())
        }
        #expect(link.isLinked == false)
    }

    @Test func linksAProjectAndStoresOnlyBookmarkData() throws {
        let store = defaults()
        let project = try tempFolder()
        try "name: TestApp".write(to: project.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        let link = ProjectFolderLink(appName: "TestApp", defaults: store, sandboxed: false)
        try link.link(to: project)

        #expect(link.isLinked)
        // The defaults hold data (a bookmark), never a path string.
        #expect(store.object(forKey: ProjectFolderLink.defaultsKey) is Data)
        let resolved = try link.withFolder { $0 }
        #expect(resolved.standardizedFileURL.path == project.standardizedFileURL.path)
    }

    @Test func withFolderWithoutLinkThrows() throws {
        let link = ProjectFolderLink(appName: "TestApp", defaults: defaults(), sandboxed: false)
        #expect(throws: ProjectFolderLink.Failure.noLinkedFolder) {
            try link.withFolder { _ in }
        }
    }
}

// MARK: Save path (no UI)

@Suite struct FeedbackSaverTests {
    private let sampleApp = AppInfo(name: "SampleApp", version: "1.2.0", build: "34", configuration: "Debug")

    @Test func ideaWritesAnInboxNoteAndExcludesStatusque() throws {
        let project = try repoFolder()
        let result = try FeedbackSaver.save(kind: .idea, title: "", text: "Pause all from the menu bar",
                                            screenshot: nil, app: sampleApp, macOS: "27.0", folder: project)
        #expect(result == "idea")
        let inbox = try Inbox.load(at: project.appending(path: ".statusque/inbox.json"))
        #expect(inbox.notes.count == 1)
        let note = try #require(inbox.notes.first)
        #expect(note.kind == "idea")
        #expect(note.from == Inbox.Source(app: "SampleApp", version: "1.2.0", build: "34"))
        let exclude = try String(contentsOf: project.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".statusque/"))
    }

    @Test func problemWritesReportAndScreenshot() throws {
        let project = try repoFolder()
        let id = try FeedbackSaver.save(kind: .problem, title: "Queue stalls", text: "Details",
                                        screenshot: Data([0x89, 0x50, 0x4E, 0x47]), app: sampleApp,
                                        macOS: "27.0", folder: project)
        let bugs = project.appending(path: ".statusque/bugs")
        #expect(FileManager.default.fileExists(atPath: bugs.appending(path: "\(id).json").path))
        #expect(FileManager.default.fileExists(atPath: bugs.appending(path: "\(id).png").path))
    }

    @Test func blankIdeaSavesNothing() throws {
        let project = try repoFolder()
        let result = try FeedbackSaver.save(kind: .idea, title: "", text: "  \n ", screenshot: nil,
                                            app: sampleApp, macOS: "27.0", folder: project)
        #expect(result == "")
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".statusque").path))
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".git/info/exclude").path))
    }

    /// A read-only `.git/info` means the exclude line can't be written, so nothing may be saved.
    @Test func excludeFailureWritesNothingForAnIdea() throws {
        let project = try repoFolder()
        let info = project.appending(path: ".git/info").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: info)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: info) }
        #expect(throws: (any Error).self) {
            try FeedbackSaver.save(kind: .idea, title: "", text: "Should not be saved", screenshot: nil,
                                   app: sampleApp, macOS: "27.0", folder: project)
        }
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".statusque").path))
    }

    @Test func excludeFailureWritesNothingForAProblem() throws {
        let project = try repoFolder()
        let info = project.appending(path: ".git/info").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: info)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: info) }
        #expect(throws: (any Error).self) {
            try FeedbackSaver.save(kind: .problem, title: "Should not be saved", text: "", screenshot: nil,
                                   app: sampleApp, macOS: "27.0", folder: project)
        }
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: ".statusque").path))
    }
}
