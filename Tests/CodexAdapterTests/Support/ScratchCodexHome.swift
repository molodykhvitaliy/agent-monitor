import Foundation

/// A `~/.codex` of its own, deleted when the test ends.
///
/// Every installer suite runs against one of these. The real one is the
/// developer's own configuration, holding their `notify` entry and their
/// `caffeine.sh` hooks, and a test that wrote to it would be the exact failure
/// the installer rules exist to prevent.
final class ScratchCodexHome {
    let directory: URL

    var hooksURL: URL { directory.appending(path: "hooks.json") }
    var configURL: URL { directory.appending(path: "config.toml") }

    init(hooks: String? = nil, config: String? = nil) throws {
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "agentbar-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let hooks { try Data(hooks.utf8).write(to: hooksURL) }
        if let config { try Data(config.utf8).write(to: configURL) }
    }

    var hooksText: String? {
        guard let data = try? Data(contentsOf: hooksURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var hooksData: Data { (try? Data(contentsOf: hooksURL)) ?? Data() }

    var hooksExist: Bool {
        FileManager.default.fileExists(atPath: hooksURL.path(percentEncoded: false))
    }

    /// An executable file standing in for the helper, so a report can tell
    /// "installed and present" from "installed and gone".
    @discardableResult
    func makeHelper(named name: String = "agentbar-helper") throws -> URL {
        let url = directory.appending(path: name)
        FileManager.default.createFile(
            atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        return url
    }

    func backups() -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.contains(".bak.") }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
