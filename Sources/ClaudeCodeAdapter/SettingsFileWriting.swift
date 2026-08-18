import AgentBarCore
import Foundation

/// Everything the installer does that can fail for a filesystem reason.
///
/// Split from the merge rules deliberately: those are a pure function of a
/// parsed document and are tested without a disk, while everything here needs
/// one and fails in ways only a real directory produces.
extension ClaudeCodeInstaller {

    func requireClaudeDirectory() throws {
        let directory = settingsURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ClaudeCodeInstallerError.claudeDirectoryMissing(directory)
        }
    }

    /// The file as a value, or an empty object when there is no file yet.
    func readDocument() throws -> JSONValue {
        guard fileManager.fileExists(atPath: settingsURL.path(percentEncoded: false)) else {
            return .object(JSONObject())
        }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw ClaudeCodeInstallerError.settingsUnreadable("\(error)")
        }
        // An empty file is a settings file that was never written to, not a
        // broken one.
        guard data.contains(where: { $0 > 0x20 }) else { return .object(JSONObject()) }
        let value: JSONValue
        do {
            value = try JSONParser.parse(data)
        } catch {
            throw ClaudeCodeInstallerError.settingsUnreadable("\(error)")
        }
        guard let object = value.object else {
            throw ClaudeCodeInstallerError.settingsNotAnObject
        }
        // The merge reads these two keys through optional casts, so a value of
        // an unexpected type would be quietly replaced rather than merged into.
        // "Never rewrite what it could not read" applies one level down as well.
        if let hooks = object[ClaudeCodeSettings.hooksKey], hooks.object == nil {
            throw ClaudeCodeInstallerError.settingsShapeUnexpected(key: ClaudeCodeSettings.hooksKey)
        }
        if let allowed = object[ClaudeCodeSettings.allowedURLsKey],
            allowed.array?.allSatisfy({ $0.string != nil }) != true
        {
            throw ClaudeCodeInstallerError.settingsShapeUnexpected(
                key: ClaudeCodeSettings.allowedURLsKey)
        }
        return value
    }

    func write(
        _ document: JSONValue, ifDifferentFrom original: JSONValue
    ) throws -> (changed: Bool, backupURL: URL?) {
        guard document != original else { return (false, nil) }
        let data = JSONWriter.data(document)
        let path = settingsURL.path(percentEncoded: false)

        guard fileManager.fileExists(atPath: path) else {
            // A file AgentBar created holds AgentBar's token and is read by
            // nothing but this user's own tools, so it is born private.
            guard
                fileManager.createFile(
                    atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            else {
                throw ClaudeCodeInstallerError.writeFailed("could not create \(path)")
            }
            return (true, nil)
        }

        sweepAbandonedTemporaries()
        let backupURL = try makeBackup()
        let mode = (try existingPermissions())?.intValue ?? 0o600
        let temporaryURL = settingsURL.deletingLastPathComponent()
            .appending(path: "\(Self.temporaryPrefix)\(UUID().uuidString).tmp")
        do {
            // Created at 0600 and widened to the destination's mode afterwards.
            // `Data.write` would create it at the process umask — 0644 on a
            // default account — with the token already in it, and only narrow it
            // a moment later. The same window the Unix socket has, closed the
            // same way: never open in the first place.
            guard
                fileManager.createFile(
                    atPath: temporaryURL.path(percentEncoded: false), contents: data,
                    attributes: [.posixPermissions: 0o600])
            else {
                throw ClaudeCodeInstallerError.writeFailed("could not create a temporary file")
            }
            try fileManager.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: temporaryURL.path(percentEncoded: false))
            _ = try fileManager.replaceItemAt(settingsURL, withItemAt: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // A backup of a file that was never replaced is a copy of the token
            // and nothing else.
            try? fileManager.removeItem(at: backupURL)
            throw ClaudeCodeInstallerError.writeFailed("\(error)")
        }
        pruneBackups()
        return (true, backupURL)
    }

    static let temporaryPrefix = ".agentbar-settings-"
    static let backupInfix = ".bak."
    /// Backups worth keeping. Each one holds a bearer token, so they are AgentBar's
    /// to bound as well as to create.
    static let backupsKept = 5

    /// Removes temporary files a killed process left behind. Each one carries a
    /// token, and nothing else ever writes this prefix.
    func sweepAbandonedTemporaries() {
        for url in siblings() where url.lastPathComponent.hasPrefix(Self.temporaryPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    func pruneBackups() {
        let name = settingsURL.lastPathComponent + Self.backupInfix
        let backups = siblings()
            .filter { $0.lastPathComponent.hasPrefix(name) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard backups.count > Self.backupsKept else { return }
        for url in backups.dropLast(Self.backupsKept) { try? fileManager.removeItem(at: url) }
    }

    func siblings() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: settingsURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    }

    /// A byte-for-byte copy of the file as it was, before anything is written.
    ///
    /// Narrowed to `0600` afterwards even when the file it copies is not. The
    /// original's permissions are the user's decision (ADR-0004); a backup is
    /// AgentBar's own artefact, and it holds a live bearer token.
    func makeBackup() throws -> URL {
        let stamp = Self.backupStamp(for: clock.wallTime)
        let base = settingsURL.path(percentEncoded: false) + Self.backupInfix + stamp
        var candidate = URL(filePath: base)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = URL(filePath: base + "-\(suffix)")
            suffix += 1
        }
        do {
            try fileManager.copyItem(at: settingsURL, to: candidate)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: candidate.path(percentEncoded: false))
        } catch {
            throw ClaudeCodeInstallerError.backupFailed("\(error)")
        }
        return candidate
    }

    func existingPermissions() throws -> NSNumber? {
        let attributes = try? fileManager.attributesOfItem(
            atPath: settingsURL.path(percentEncoded: false))
        return attributes?[.posixPermissions] as? NSNumber
    }

    func permissionWarning() throws -> ClaudeCodeInstallWarning? {
        guard let mode = try existingPermissions()?.intValue else { return nil }
        guard mode & 0o077 != 0 else { return nil }
        return .settingsReadableByOthers(mode: mode)
    }

    /// UTC, so two backups taken either side of a daylight-saving change still
    /// sort the way they were made. Built from components rather than a
    /// `DateFormatter`, which is a non-`Sendable` class and cannot be a shared
    /// constant under strict concurrency.
    static func backupStamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
