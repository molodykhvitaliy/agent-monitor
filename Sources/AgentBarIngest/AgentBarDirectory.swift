import Foundation

/// The directory AgentBar makes for itself, and the only way it is ever deleted.
///
/// > **Here because this module already owns the directory.** `IngestPaths`
/// > defines where `~/Library/Application Support/AgentBar` is, and
/// > `FileCredentialStore` and `EndpointDiscoveryFile` are what fill it. The
/// > uninstaller in the app target is the caller; the *rule about what may be
/// > deleted* belongs next to the code that decided what to create — and, not
/// > incidentally, where `swift test` can drive a recursive delete against a
/// > scratch tree rather than against a real home directory.
///
/// The same shape as `CodexHelperDeployment.removeOwnedHelper(in:)`, which
/// guards the one file inside this directory that a provider's hooks name.
public enum AgentBarDirectory {
    /// The last path component every directory AgentBar creates for itself ends
    /// in — under Application Support and under Caches alike.
    public static let name = "AgentBar"

    /// What a removal found. Three cases and no `throws` for the first two,
    /// because "there was nothing there" and "that is not ours" are answers
    /// rather than failures — and both have to be told apart from success by a
    /// caller whose whole job is reporting honestly.
    public enum Outcome: Sendable, Hashable {
        /// The directory was there and is gone.
        case removed
        /// There was no such directory.
        case absent
        /// The path does not name a directory AgentBar creates, so nothing was
        /// touched. **Never** to be reported as an absence: it means AgentBar
        /// did not look, not that it looked and found nothing.
        case notOwned
    }

    /// Removes `url` and everything under it, **only** if it is a directory
    /// AgentBar owns.
    ///
    /// > **The guard is on the name, and it is the whole safety property.** This
    /// > is a recursive delete taking a URL from a caller, so the one thing it
    /// > must never do is delete a directory somebody else made. Every caller
    /// > derives its URL by appending `name` to a system directory, so the guard
    /// > can only fire when one of those derivations has changed — which is
    /// > exactly the moment a recursive delete wants a second opinion.
    ///
    /// A symbolic link is `notOwned` however it is named: following one would
    /// delete whatever it points at, which is the one way a name check can be
    /// made to lie.
    public static func remove(
        at url: URL, fileManager: FileManager = .default
    ) throws -> Outcome {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent == name else { return .notOwned }
        let path = standardized.path(percentEncoded: false)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .absent
        }
        // `fileExists` follows symbolic links, so a link *to* a directory
        // answers `true` twice over. The attributes are read without following
        // it, which is what tells the two apart.
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard isDirectory.boolValue,
            attributes[.type] as? FileAttributeType == .typeDirectory
        else { return .notOwned }

        try fileManager.removeItem(at: standardized)
        return .removed
    }
}
