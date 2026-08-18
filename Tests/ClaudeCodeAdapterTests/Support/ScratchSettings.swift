import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// A settings file in a directory of its own, deleted when the test ends.
final class ScratchSettings {
    let directory: URL
    let url: URL

    init(contents: Data? = nil, name: String = "settings.json") throws {
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "agentbar-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: name)
        if let contents { try contents.write(to: url) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    var data: Data { (try? Data(contentsOf: url)) ?? Data() }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    var backups: [URL] {
        let all =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.contains(".bak.") }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// Anything the installer left behind that is neither the file nor a backup.
    var strayFiles: [String] {
        let all =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.map(\.lastPathComponent)
            .filter { $0 != url.lastPathComponent && !$0.contains(".bak.") }
    }

    func installer(clock: any TimeSource = ManualClock()) -> ClaudeCodeInstaller {
        ClaudeCodeInstaller(settingsURL: url, clock: clock)
    }
}

/// Fails the write of the temporary file, which is the step nothing outside the
/// installer can provoke — a full disk, a revoked permission, a killed process.
final class FailingWriteFileManager: FileManager, @unchecked Sendable {
    override func createFile(
        atPath path: String, contents data: Data?, attributes: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        guard path.contains(ClaudeCodeInstaller.temporaryPrefix) else {
            return super.createFile(atPath: path, contents: data, attributes: attributes)
        }
        return false
    }
}

extension ClaudeCodeEndpoint {
    static func test(port: UInt16 = 47821, token: String = "test-token") throws -> Self {
        ClaudeCodeEndpoint(
            url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/hooks/claude-code")),
            token: token)
    }
}
