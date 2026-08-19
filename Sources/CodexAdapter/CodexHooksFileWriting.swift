import AgentBarJSON
import Foundation

/// Everything the Codex installer does that can fail for a filesystem reason.
///
/// Split from the merge rules deliberately, exactly as on the Claude Code side:
/// those are pure functions of a parsed document and are tested without a disk,
/// while everything here needs one and fails in ways only a real directory
/// produces.
extension CodexInstaller {

    func requireCodexDirectory() throws {
        let directory = hooksURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CodexInstallerError.codexDirectoryMissing(directory)
        }
    }

    /// The file as a value, or an empty object when there is no file yet.
    func readDocument() throws -> JSONValue {
        guard fileManager.fileExists(atPath: hooksURL.path(percentEncoded: false)) else {
            return .object(JSONObject())
        }
        let data: Data
        do {
            data = try Data(contentsOf: hooksURL)
        } catch {
            throw CodexInstallerError.hooksUnreadable("\(error)")
        }
        // An empty file is one that was created and never written to, not a
        // broken one.
        guard data.contains(where: { $0 > 0x20 }) else { return .object(JSONObject()) }
        let value: JSONValue
        do {
            value = try JSONParser.parse(data)
        } catch {
            throw CodexInstallerError.hooksUnreadable("\(error)")
        }
        guard let object = value.object else { throw CodexInstallerError.hooksNotAnObject }
        // The merge reads this key through an optional cast, so a value of an
        // unexpected type would be quietly replaced rather than merged into.
        // "Never rewrite what it could not read" applies one level down too.
        if let hooks = object[CodexHooksFile.hooksKey], hooks.object == nil {
            throw CodexInstallerError.hooksShapeUnexpected(key: CodexHooksFile.hooksKey)
        }
        return value
    }

    func write(
        _ document: JSONValue, ifDifferentFrom original: JSONValue
    ) throws -> (changed: Bool, backupURL: URL?) {
        guard document != original else { return (false, nil) }
        let data = JSONWriter.data(document)
        let path = hooksURL.path(percentEncoded: false)

        guard fileManager.fileExists(atPath: path) else {
            // `0600`, which is what Codex gives its own files in this directory.
            // Nothing secret is in here — the point is to sit alongside
            // `config.toml` and `auth.json` rather than to be the one file in
            // `~/.codex` that anybody else on the Mac can read.
            guard
                fileManager.createFile(
                    atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            else {
                throw CodexInstallerError.writeFailed("could not create \(path)")
            }
            return (true, nil)
        }

        sweepAbandonedTemporaries()
        let backupURL = try makeBackup()
        let mode = existingPermissions() ?? 0o600
        let temporaryURL = hooksURL.deletingLastPathComponent()
            .appending(path: "\(Self.temporaryPrefix)\(UUID().uuidString).tmp")
        do {
            guard
                fileManager.createFile(
                    atPath: temporaryURL.path(percentEncoded: false), contents: data,
                    attributes: [.posixPermissions: mode])
            else {
                throw CodexInstallerError.writeFailed("could not create a temporary file")
            }
            _ = try fileManager.replaceItemAt(hooksURL, withItemAt: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: backupURL)
            throw CodexInstallerError.writeFailed("\(error)")
        }
        pruneBackups()
        return (true, backupURL)
    }

    static let temporaryPrefix = ".agentbar-hooks-"
    static let backupInfix = ".bak."
    /// Backups worth keeping. Unlike the Claude Code side these hold no secret,
    /// so the bound is only about not filling the user's directory with copies.
    static let backupsKept = 5

    /// Removes temporary files a killed process left behind. Nothing else ever
    /// writes this prefix.
    func sweepAbandonedTemporaries() {
        for url in siblings() where url.lastPathComponent.hasPrefix(Self.temporaryPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    func pruneBackups() {
        let name = hooksURL.lastPathComponent + Self.backupInfix
        let backups = siblings()
            .filter { $0.lastPathComponent.hasPrefix(name) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard backups.count > Self.backupsKept else { return }
        for url in backups.dropLast(Self.backupsKept) { try? fileManager.removeItem(at: url) }
    }

    func siblings() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: hooksURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    }

    /// A byte-for-byte copy of the file as it was, before anything is written.
    func makeBackup() throws -> URL {
        let stamp = Self.backupStamp(for: clock.wallTime)
        let base = hooksURL.path(percentEncoded: false) + Self.backupInfix + stamp
        var candidate = URL(filePath: base)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = URL(filePath: base + "-\(suffix)")
            suffix += 1
        }
        do {
            try fileManager.copyItem(at: hooksURL, to: candidate)
        } catch {
            throw CodexInstallerError.backupFailed("\(error)")
        }
        return candidate
    }

    func existingPermissions() -> Int? {
        let attributes = try? fileManager.attributesOfItem(
            atPath: hooksURL.path(percentEncoded: false))
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// UTC, so two backups taken either side of a daylight-saving change still
    /// sort the way they were made.
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
