import Foundation

/// Why the embedded Codex helper could not be made available at its stable
/// AgentBar-owned path.
public enum CodexHelperDeploymentError: Error, Sendable, Hashable, CustomStringConvertible {
    case sourceMissing(URL)
    case sourceNotExecutable(URL)
    case deploymentFailed(String)
    case deployedHelperInvalid(URL)

    public var description: String {
        switch self {
        case .sourceMissing(let url):
            "AgentBar's bundled helper is missing at \(url.path(percentEncoded: false))"
        case .sourceNotExecutable(let url):
            "AgentBar's bundled helper is not executable at \(url.path(percentEncoded: false))"
        case .deploymentFailed(let reason):
            "AgentBar could not deploy its Codex helper: \(reason)"
        case .deployedHelperInvalid(let url):
            "AgentBar's deployed helper is not executable at \(url.path(percentEncoded: false))"
        }
    }
}

/// Installs the bundled helper at a path that does not move with the app.
///
/// Codex trusts the complete hook definition, including its command. Naming a
/// binary inside `AgentBar.app` therefore made Debug, distribution and installed
/// copies continuously invalidate one another. The deployed file is refreshed
/// atomically; an already-running hook keeps the old inode while the next one
/// opens the replacement at the same path.
public struct CodexHelperDeployment {
    public let sourceURL: URL
    public let destinationURL: URL
    private let fileManager: FileManager

    public init(sourceURL: URL, destinationURL: URL, fileManager: FileManager = .default) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/AgentBar/bin/agentbar-helper` when passed
    /// AgentBar's Application Support directory.
    public static func destination(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: CodexHookCommand.executableName)
    }

    /// Deploys or refreshes the helper. Returns `true` only when disk changed.
    @discardableResult
    public func deploy() throws -> Bool {
        let sourcePath = sourceURL.path(percentEncoded: false)
        let destinationPath = destinationURL.path(percentEncoded: false)
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            guard Self.isExecutableRegularFile(at: destinationURL, fileManager: fileManager) else {
                throw CodexHelperDeploymentError.deployedHelperInvalid(destinationURL)
            }
            return false
        }
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw CodexHelperDeploymentError.sourceMissing(sourceURL)
        }
        guard Self.isExecutableRegularFile(at: sourceURL, fileManager: fileManager) else {
            throw CodexHelperDeploymentError.sourceNotExecutable(sourceURL)
        }

        let sourceMode = try Self.mode(of: sourceURL, fileManager: fileManager)
        if try deployedHelperMatches(sourcePath: sourcePath, mode: sourceMode) {
            return false
        }

        let directory = destinationURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".agentbar-helper.tmp.\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.copyItem(at: sourceURL, to: temporary)
            try fileManager.setAttributes(
                [.posixPermissions: sourceMode], ofItemAtPath: temporary.path(percentEncoded: false)
            )
            guard Self.isExecutableRegularFile(at: temporary, fileManager: fileManager) else {
                throw CodexHelperDeploymentError.deployedHelperInvalid(temporary)
            }
            if fileManager.fileExists(atPath: destinationPath) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destinationURL)
            }
            guard Self.isExecutableRegularFile(at: destinationURL, fileManager: fileManager) else {
                throw CodexHelperDeploymentError.deployedHelperInvalid(destinationURL)
            }
            return true
        } catch let error as CodexHelperDeploymentError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CodexHelperDeploymentError.deploymentFailed("\(error)")
        }
    }

    /// Removes the helper at the exact destination derived from AgentBar's
    /// injected Application Support directory.
    ///
    /// This is public for `CodexInstaller`, which orders hook removal before
    /// file removal without accepting an arbitrary executable URL.
    @discardableResult
    public static func removeOwnedHelper(
        in agentBarApplicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let support = agentBarApplicationSupportDirectory.standardizedFileURL
        guard support.lastPathComponent == "AgentBar" else { return false }
        let url = destination(in: support).standardizedFileURL

        let path = url.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return false }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            throw CodexHelperDeploymentError.deploymentFailed("\(error)")
        }
    }

    private static func mode(of url: URL, fileManager: FileManager) throws -> NSNumber {
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        return attributes[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o755)
    }

    /// Whether the file already at the destination is the one that would be
    /// written.
    ///
    /// > **Size and mode before bytes.** `deploy()` runs on every status read,
    /// > and `contentsEqual` on a 2.2 MB binary is a full compare of both files.
    /// > Two files of different lengths cannot be equal, and the attributes are
    /// > one `stat` each — which this already needed for the mode check. The
    /// > byte compare stays as the answer, and is simply not reached in the case
    /// > where it could only say no.
    private func deployedHelperMatches(sourcePath: String, mode: NSNumber) throws -> Bool {
        let destinationPath = destinationURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: destinationPath),
            Self.isExecutableRegularFile(at: destinationURL, fileManager: fileManager),
            try Self.mode(of: destinationURL, fileManager: fileManager) == mode,
            let destinationSize = try Self.size(of: destinationPath, fileManager: fileManager),
            let sourceSize = try Self.size(of: sourcePath, fileManager: fileManager),
            destinationSize == sourceSize
        else { return false }
        return fileManager.contentsEqual(atPath: sourcePath, andPath: destinationPath)
    }

    /// The file's length in bytes, or `nil` when the attribute is not there to
    /// read. A `nil` fails the guard above and so redeploys — the safe
    /// direction, because a redeploy is an atomic copy and a wrong *match* is a
    /// stale helper Codex would go on running.
    private static func size(of path: String, fileManager: FileManager) throws -> Int? {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.intValue
    }

    private static func isExecutableRegularFile(at url: URL, fileManager: FileManager) -> Bool {
        let path = url.path(percentEncoded: false)
        guard fileManager.isExecutableFile(atPath: path),
            let attributes = try? fileManager.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return false }
        return true
    }
}
