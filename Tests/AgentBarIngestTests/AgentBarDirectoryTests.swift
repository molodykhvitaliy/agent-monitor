import Foundation
import Testing

@testable import AgentBarIngest

/// The one recursive delete in the project, and the guard that decides what it
/// may reach.
///
/// The uninstaller calls this against `~/Library/Application Support/AgentBar`
/// and `~/Library/Caches/AgentBar`. Every claim below is about what happens when
/// it is called against something else.
@Suite("AgentBar's own directory")
struct AgentBarDirectoryTests {

    /// A scratch tree that removes itself.
    private struct Scratch: ~Copyable {
        let root: URL

        init() throws {
            root = URL(filePath: NSTemporaryDirectory())
                .appending(
                    path: "agentbar-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// A directory named `name`, with a file inside it so a removal has
        /// something to be recursive about.
        func directory(named name: String) throws -> URL {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appending(path: "inside"))
            return url
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("A directory AgentBar owns goes, contents and all")
    func removesItsOwn() throws {
        let scratch = try Scratch()
        let url = try scratch.directory(named: "AgentBar")
        #expect(try AgentBarDirectory.remove(at: url) == .removed)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("A directory that is not there is absent, not an error")
    func absentIsNotAFailure() throws {
        let scratch = try Scratch()
        let url = scratch.root.appending(path: "AgentBar", directoryHint: .isDirectory)
        #expect(try AgentBarDirectory.remove(at: url) == .absent)
    }

    /// The safety property. Every caller derives its URL by appending the name
    /// to a system directory, so this can only fire when a derivation changed —
    /// which is exactly when a recursive delete wants a second opinion.
    @Test(
        "Anything not named AgentBar is refused and left alone",
        arguments: ["Application Support", "AgentBar2", "agentbar", "Caches", "MyApp"]
    )
    func refusesWhatItDoesNotOwn(name: String) throws {
        let scratch = try Scratch()
        let url = try scratch.directory(named: name)
        #expect(try AgentBarDirectory.remove(at: url) == .notOwned)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// A file with the right name is not a directory AgentBar made, and deleting
    /// it on the strength of the name alone would be the guard being talked
    /// round.
    @Test("A plain file named AgentBar is refused")
    func refusesAFile() throws {
        let scratch = try Scratch()
        let url = scratch.root.appending(path: "AgentBar")
        try Data("not a directory".utf8).write(to: url)
        #expect(try AgentBarDirectory.remove(at: url) == .notOwned)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// The one way a name check can be made to lie: `fileExists` follows links,
    /// so a link called `AgentBar` pointing at somebody else's directory would
    /// pass a naive guard and take the target with it.
    @Test("A symbolic link named AgentBar is refused, and its target survives")
    func refusesASymbolicLink() throws {
        let scratch = try Scratch()
        let target = try scratch.directory(named: "SomebodyElse")
        let link = scratch.root.appending(path: "AgentBar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(try AgentBarDirectory.remove(at: link) == .notOwned)
        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        #expect(
            FileManager.default.fileExists(
                atPath: target.appending(path: "inside").path(percentEncoded: false)))
    }

    /// A trailing slash and a `..` are the same directory, and the guard reads
    /// the standardised name so neither smuggles anything past it.
    @Test("The name is read after standardising the path")
    func standardisesBeforeChecking() throws {
        let scratch = try Scratch()
        let url = try scratch.directory(named: "AgentBar")
        let roundabout = url.appending(path: "inside").deletingLastPathComponent()
        #expect(try AgentBarDirectory.remove(at: roundabout) == .removed)
    }
}
