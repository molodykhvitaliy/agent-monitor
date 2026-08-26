import Foundation
import Testing

@testable import CodexAdapter

@Suite("Codex helper deployment")
struct HelperDeploymentTests {
    @Test("The helper is copied to the stable path and refreshed atomically")
    func deploysAndRefreshes() throws {
        let scratch = try ScratchCodexHome()
        let source = try scratch.makeHelper(at: "Debug.app/Contents/MacOS/agentbar-helper")
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let deployment = CodexHelperDeployment(sourceURL: source, destinationURL: destination)

        #expect(try deployment.deploy())
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        #expect(
            FileManager.default.isExecutableFile(atPath: destination.path(percentEncoded: false)))
        #expect(!(try deployment.deploy()))

        try Data("#!/bin/sh\necho refreshed\n".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path(percentEncoded: false))
        #expect(try deployment.deploy())
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(!leftovers.contains { $0.lastPathComponent.hasPrefix(".agentbar-helper.tmp.") })
    }

    /// The pre-check that keeps a status read from comparing 2.2 MB byte for
    /// byte. It has to answer *no* whenever the file would actually change —
    /// including the case where only the length differs, which is what the
    /// pre-check itself decides.
    @Test("A helper of a different length is redeployed without a byte compare")
    func aDifferentLengthIsNotAMatch() throws {
        let scratch = try ScratchCodexHome()
        let source = try scratch.makeHelper(at: "Debug.app/Contents/MacOS/agentbar-helper")
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let deployment = CodexHelperDeployment(sourceURL: source, destinationURL: destination)
        #expect(try deployment.deploy())
        #expect(!(try deployment.deploy()))

        // Longer, and still a valid executable: only the size distinguishes it.
        try Data("#!/bin/sh\necho a much longer helper than before\n".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path(percentEncoded: false))
        #expect(try deployment.deploy())
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
    }

    /// Same length, different bytes — the case the pre-check cannot answer and
    /// must therefore hand to the byte compare rather than call a match.
    @Test("A helper of the same length but different bytes is still redeployed")
    func sameLengthDifferentBytesIsNotAMatch() throws {
        let scratch = try ScratchCodexHome()
        let source = try scratch.makeHelper(at: "Debug.app/Contents/MacOS/agentbar-helper")
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let deployment = CodexHelperDeployment(sourceURL: source, destinationURL: destination)
        #expect(try deployment.deploy())

        let original = try Data(contentsOf: source)
        var replacement = original
        let last = replacement.count - 2
        replacement[last] = replacement[last] == 0x41 ? 0x42 : 0x41
        try replacement.write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path(percentEncoded: false))
        #expect(replacement.count == original.count)
        #expect(try deployment.deploy())
        #expect(try Data(contentsOf: destination) == replacement)
    }

    @Test("A deployment failure leaves the existing stable helper untouched")
    func failurePreservesDestination() throws {
        let scratch = try ScratchCodexHome()
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let original = try scratch.makeHelper(
            at: "Application Support/AgentBar/bin/agentbar-helper")
        let before = try Data(contentsOf: original)
        let missing = scratch.directory.appending(
            path: "Missing.app/Contents/MacOS/agentbar-helper")

        #expect(throws: CodexHelperDeploymentError.self) {
            try CodexHelperDeployment(sourceURL: missing, destinationURL: destination).deploy()
        }
        #expect(try Data(contentsOf: destination) == before)
    }

    @Test("A staging-copy failure preserves the existing helper")
    func stagingFailurePreservesDestination() throws {
        let scratch = try ScratchCodexHome()
        let source = try scratch.makeHelper(at: "Source.app/Contents/MacOS/agentbar-helper")
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let deployment = CodexHelperDeployment(sourceURL: source, destinationURL: destination)
        try deployment.deploy()
        let before = try Data(contentsOf: destination)
        try Data("replacement".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path(percentEncoded: false))

        let bin = destination.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: bin.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: bin.path(percentEncoded: false))
        }

        #expect(throws: CodexHelperDeploymentError.self) {
            try deployment.deploy()
        }
        #expect(try Data(contentsOf: destination) == before)
    }

    @Test("Different app copies refresh bytes without changing the trusted command")
    func appCopiesShareOneCommand() throws {
        let scratch = try ScratchCodexHome()
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let debug = try scratch.makeHelper(at: "Debug.app/Contents/MacOS/agentbar-helper")
        let distribution = try scratch.makeHelper(
            at: "dist/AgentBar.app/Contents/MacOS/agentbar-helper")
        try Data("distribution helper".utf8).write(to: distribution)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: distribution.path(percentEncoded: false))

        try CodexHelperDeployment(sourceURL: debug, destinationURL: destination).deploy()
        let endpoint = CodexEndpoint(helperURL: destination)
        let installer = CodexInstaller(home: scratch.directory)
        try installer.install(endpoint)
        let command = endpoint.command

        try CodexHelperDeployment(sourceURL: distribution, destinationURL: destination).deploy()
        #expect(CodexEndpoint(helperURL: destination).command == command)
        guard case .installedNotTrusted = installer.report(for: endpoint).state else {
            Issue.record("refreshing helper bytes must not create hook drift")
            return
        }
    }

    @Test("Uninstall removes only a canonical helper destination")
    func uninstallIsScoped() throws {
        let scratch = try ScratchCodexHome()
        let source = try scratch.makeHelper(at: "Source.app/Contents/MacOS/agentbar-helper")
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        let deployment = CodexHelperDeployment(sourceURL: source, destinationURL: destination)
        try deployment.deploy()
        #expect(try CodexHelperDeployment.removeOwnedHelper(in: support))
        #expect(!(try CodexHelperDeployment.removeOwnedHelper(in: support)))

        let foreign = try scratch.makeHelper(at: "Other/AgentBar/bin/agentbar-helper")
        #expect(!(try CodexHelperDeployment.removeOwnedHelper(in: scratch.directory)))
        #expect(FileManager.default.fileExists(atPath: foreign.path(percentEncoded: false)))
    }

    @Test("Installer removes hooks before the AgentBar-owned helper")
    func installerCoordinatesUninstall() throws {
        let scratch = try ScratchCodexHome()
        let source = try scratch.makeHelper(at: "Source.app/Contents/MacOS/agentbar-helper")
        let support = scratch.directory.appending(path: "Application Support/AgentBar")
        let destination = CodexHelperDeployment.destination(in: support)
        try CodexHelperDeployment(sourceURL: source, destinationURL: destination).deploy()
        let installer = CodexInstaller(home: scratch.directory)
        try installer.install(CodexEndpoint(helperURL: destination))

        let outcome = try installer.uninstall(agentBarApplicationSupportDirectory: support)

        #expect(outcome.changed)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(
            !FileManager.default.fileExists(
                atPath: installer.hooksFileURL.path(percentEncoded: false)))
    }
}
