import Foundation

/// The bearer token a caller must present.
///
/// Not `Hashable`, deliberately: a secret that can be a dictionary key is a
/// secret that ends up in one. Equality exists, and is constant-time, because
/// the whole point of the type is comparing it against something a caller sent.
public struct IngestToken: Sendable, Equatable {
    /// Bytes of entropy behind a generated token. 32 is well past anything
    /// brute-forceable across a loopback socket, and short enough to sit in a
    /// header without comment.
    public static let entropyBytes = 32

    /// What a stored token must look like to be usable. A token is carried in
    /// an HTTP header value, so anything outside printable ASCII, and anything
    /// that could end the header early, is not a token we wrote.
    static let lengthRange = 16...512

    public let value: String

    /// Fails rather than repairs: a token that needed repairing is a token the
    /// caller and the store no longer agree on, and guessing which one is right
    /// would be worse than saying so.
    public init?(_ value: String) {
        guard IngestToken.lengthRange.contains(value.count),
            value.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F })
        else { return nil }
        self.value = value
    }

    /// Skips validation for a value this type produced itself.
    private init(generated value: String) {
        self.value = value
    }

    /// A fresh token from the system's cryptographic generator.
    ///
    /// `SystemRandomNumberGenerator` is the platform CSPRNG, so this needs no
    /// dependency on CryptoKit — and AgentBar holding no cryptographic
    /// machinery at all is easier to reason about than AgentBar holding some.
    public static func generate() -> IngestToken {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(entropyBytes)
        for _ in 0..<entropyBytes {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return IngestToken(generated: encoded)
    }

    /// Compares in time that does not depend on where the first difference is.
    ///
    /// Loopback is not a network an attacker measures from comfortably, but the
    /// alternative costs four lines.
    public func matches(_ candidate: String) -> Bool {
        let stored = Array(value.utf8)
        let offered = Array(candidate.utf8)
        var difference: UInt8 = stored.count == offered.count ? 0 : 1
        for index in 0..<max(stored.count, offered.count) {
            let left = index < stored.count ? stored[index] : 0
            let right = index < offered.count ? offered[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }

    public static func == (lhs: IngestToken, rhs: IngestToken) -> Bool {
        lhs.matches(rhs.value)
    }
}

/// Where a token came from.
///
/// `replaced` is the case that matters: the endpoint is usable again, but every
/// hook configuration already installed is now pointing at the old secret, so
/// somebody has to be told to repair them.
public enum IngestCredentialOrigin: String, Sendable, Hashable {
    case loaded
    case created
    case replaced
}

public struct StoredCredential: Sendable, Equatable {
    public let token: IngestToken
    public let origin: IngestCredentialOrigin

    public init(token: IngestToken, origin: IngestCredentialOrigin) {
        self.token = token
        self.origin = origin
    }
}

/// Supplies the token the endpoint authenticates against.
public protocol IngestCredentialStoring: Sendable {
    func loadOrCreate() throws -> StoredCredential
}

public enum IngestCredentialError: Error, Sendable, Hashable, CustomStringConvertible {
    case directoryUnavailable(String)
    case unreadable(String)
    case unwritable(String)

    public var description: String {
        switch self {
        case .directoryUnavailable(let reason): "credential directory unavailable: \(reason)"
        case .unreadable(let reason): "credential unreadable: \(reason)"
        case .unwritable(let reason): "credential unwritable: \(reason)"
        }
    }
}

/// The token as a file in the app support directory, readable only by its owner.
///
/// Two permissions, not one. The file is written `0600`, and the directory it
/// sits in is created `0700` — the directory is what closes the window between
/// a file appearing and its mode being set, and it is the only protection the
/// Unix socket beside it can have at all.
public struct FileCredentialStore: IngestCredentialStoring {
    private let url: URL
    private let diagnostics: any IngestDiagnosticSink

    public init(url: URL, diagnostics: any IngestDiagnosticSink = SilentDiagnostics()) {
        self.url = url
        self.diagnostics = diagnostics
    }

    /// `FileManager` is not `Sendable`, so it is reached for inside a call
    /// rather than stored. Nothing here needs a configured instance, and tests
    /// exercise real directories — which is the only honest way to test a
    /// permission bit anyway.
    private var fileManager: FileManager { .default }

    public func loadOrCreate() throws -> StoredCredential {
        try FileCredentialStore.prepareDirectory(url.deletingLastPathComponent())
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            return StoredCredential(token: try write(IngestToken.generate()), origin: .created)
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw IngestCredentialError.unreadable(url.lastPathComponent)
        }
        guard let token = IngestToken(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            diagnostics.record(.credentialReplaced(reason: "stored value is not a usable token"))
            return StoredCredential(token: try write(IngestToken.generate()), origin: .replaced)
        }
        try tightenPermissionsIfNeeded()
        return StoredCredential(token: token, origin: .loaded)
    }

    /// Writes the token where only its owner can read it.
    ///
    /// Atomic, so a crash mid-write cannot leave a truncated secret that the
    /// next launch would replace — silently invalidating an installed hook.
    private func write(_ token: IngestToken) throws -> IngestToken {
        do {
            try Data(token.value.utf8).write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw IngestCredentialError.unwritable("\(url.lastPathComponent): \(error)")
        }
        return token
    }

    /// A token that anyone on the machine can read is not a secret.
    ///
    /// Tightened rather than rotated: rotating would break an installed hook
    /// configuration over a permission bit that is far more likely to be a
    /// migrated backup than an attack, and the diagnostic makes it visible.
    private func tightenPermissionsIfNeeded() throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
            let mode = attributes[.posixPermissions] as? NSNumber
        else { return }
        guard mode.intValue & 0o077 != 0 else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        diagnostics.record(.credentialPermissionsTightened(previousMode: mode.intValue))
    }

    private var path: String { url.path(percentEncoded: false) }

    /// Creates the directory `0700`, and tightens it if it already existed with
    /// looser permissions.
    static func prepareDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        let path = directory.path(percentEncoded: false)
        do {
            if !fileManager.fileExists(atPath: path) {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                return
            }
            guard
                let mode = try fileManager.attributesOfItem(atPath: path)[.posixPermissions]
                    as? NSNumber, mode.intValue & 0o077 != 0
            else { return }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            throw IngestCredentialError.directoryUnavailable("\(path): \(error)")
        }
    }
}
