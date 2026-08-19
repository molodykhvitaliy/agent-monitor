import Foundation

/// Everything a client needs to reach the endpoint, except the secret.
///
/// The omission is deliberate. A discovery file is the first thing anybody
/// pastes into a bug report, and a token in it would be a token in a public
/// issue. It sits beside the token file, in the same `0700` directory, and
/// names its path instead of its contents.
public struct EndpointDescriptor: Sendable, Hashable, Codable {
    /// Bumped when a reader would misunderstand an older file. A reader that
    /// finds a version it does not know must treat the file as absent rather
    /// than guess.
    public static let currentVersion = 1

    public let version: Int
    public let host: String
    public let port: UInt16
    public let socketPath: String?
    public let tokenPath: String
    /// Who published it, so a reader can tell a live endpoint from a file left
    /// behind by a process that was killed.
    public let processIdentifier: Int32
    public let startedAt: Date

    public init(
        version: Int = EndpointDescriptor.currentVersion,
        host: String = IngestConfiguration.host,
        port: UInt16,
        socketPath: String?,
        tokenPath: String,
        processIdentifier: Int32,
        startedAt: Date
    ) {
        self.version = version
        self.host = host
        self.port = port
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
    }

    /// The prefix a provider's hook URL is built from. Always a literal
    /// address: see `IngestConfiguration.host`.
    public var hookURLPrefix: String { "http://\(host):\(port)/v1/hooks" }
}

/// Publishes where the endpoint can be reached.
public protocol EndpointPublishing: Sendable {
    func publish(_ descriptor: EndpointDescriptor) throws
    /// Removes the published description. A file that outlives its endpoint
    /// sends the helper at a port nobody is listening on.
    func retract() throws
}

/// The description as a JSON file beside the token.
public struct EndpointDiscoveryFile: EndpointPublishing {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Where the description is read from. The Codex helper needs it to check
    /// that the token file the description names sits beside the description
    /// itself, rather than anywhere on the disk.
    public var fileURL: URL { url }

    /// Reached for rather than stored: `FileManager` is not `Sendable`.
    private var fileManager: FileManager { .default }

    public func publish(_ descriptor: EndpointDescriptor) throws {
        try FileCredentialStore.prepareDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(descriptor).write(to: url, options: [.atomic])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    public func retract() throws {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Reads a published description, or `nil` if there is none this reader
    /// understands. Used by the installer and, from step 09, by the helper.
    public func read() -> EndpointDescriptor? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let descriptor = try? decoder.decode(EndpointDescriptor.self, from: data),
            descriptor.version == EndpointDescriptor.currentVersion
        else { return nil }
        return descriptor
    }
}
