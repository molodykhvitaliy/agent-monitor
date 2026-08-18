import AgentBarCore
import Foundation

public enum ClaudeCodeInstallerError: Error, Sendable, Hashable, CustomStringConvertible {
    case claudeDirectoryMissing(URL)
    case settingsUnreadable(String)
    case settingsNotAnObject
    case settingsShapeUnexpected(key: String)
    case backupFailed(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .claudeDirectoryMissing(let url):
            "\(url.path(percentEncoded: false)) does not exist — Claude Code is not set up here"
        case .settingsUnreadable(let reason): "settings.json cannot be read: \(reason)"
        case .settingsNotAnObject: "settings.json does not contain a JSON object"
        case .settingsShapeUnexpected(let key):
            "settings.json has a \"\(key)\" that is not the shape Claude Code documents"
        case .backupFailed(let reason): "the backup could not be written: \(reason)"
        case .writeFailed(let reason): "settings.json could not be written: \(reason)"
        }
    }
}

/// Installs, inspects and removes AgentBar's hooks in `~/.claude/settings.json`.
///
/// The file belongs to the user, so three rules hold everywhere in here. It is
/// never overwritten wholesale — foreign keys and foreign hook entries come back
/// out exactly as they went in. It is never written at all unless the content
/// would change, which is what makes a second install a no-op. And it is never
/// written when it could not be parsed, because a file AgentBar cannot read is a
/// file AgentBar has no business rewriting.
/// Not `Sendable`: it holds a `FileManager`, which is not, and an installer is
/// a short-lived value created where the work happens rather than shared.
public struct ClaudeCodeInstaller {
    let settingsURL: URL
    let fileManager: FileManager
    let clock: any TimeSource

    public init(
        settingsURL: URL,
        fileManager: FileManager = .default,
        clock: any TimeSource = SystemTimeSource()
    ) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
        self.clock = clock
    }

    /// `~/.claude/settings.json`, or the same file under `CLAUDE_CONFIG_DIR`.
    ///
    /// A menu-bar app launched from the Finder inherits no shell environment, so
    /// the override is only seen when it was set for the login session. That is
    /// still worth honouring: writing hooks into a settings file Claude Code is
    /// not reading is a failure with no symptom at all.
    public static func defaultSettingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let directory =
            environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser.appending(
                path: ".claude", directoryHint: .isDirectory)
        return directory.appending(path: "settings.json")
    }

    public var settingsFileURL: URL { settingsURL }

    // MARK: - Status

    /// Reads the file and says where the integration stands.
    ///
    /// `endpoint` is the endpoint AgentBar has bound right now, or `nil` if it
    /// has none. Passing it in is what lets this answer "unreachable" without
    /// opening a connection to anything.
    public func report(for endpoint: ClaudeCodeEndpoint?) throws -> ClaudeCodeInstallReport {
        let root: JSONValue
        do {
            root = try readDocument()
        } catch let error as ClaudeCodeInstallerError {
            // A file that cannot be read is a state to render, not a failure to
            // throw at a status surface — and it is the state in which nothing
            // may be written over it.
            return ClaudeCodeInstallReport(
                settingsURL: settingsURL,
                state: .settingsUnreadable(reason: error.description),
                overlaps: [],
                warnings: [])
        }
        let installed = ClaudeCodeSettings.installedHandlers(in: root)
        let overlaps = ClaudeCodeSettings.foreignOverlaps(in: root)

        guard !installed.isEmpty else {
            return ClaudeCodeInstallReport(
                settingsURL: settingsURL, state: .notInstalled, overlaps: overlaps, warnings: [])
        }
        var warnings: [ClaudeCodeInstallWarning] = []
        if let mode = try permissionWarning() { warnings.append(mode) }
        if allowListIsInEffect(given: root) { warnings.append(.allowListInEffect) }

        guard let endpoint else {
            return ClaudeCodeInstallReport(
                settingsURL: settingsURL, state: .endpointUnavailable, overlaps: overlaps,
                warnings: warnings)
        }
        let drift = Self.drift(
            between: installed, allowedURLs: ClaudeCodeSettings.allowedURLs(in: root),
            and: endpoint)
        return ClaudeCodeInstallReport(
            settingsURL: settingsURL,
            state: drift.isEmpty ? .installed : .needsRepair(drift),
            overlaps: overlaps,
            warnings: warnings)
    }

    // MARK: - Writing

    @discardableResult
    public func install(_ endpoint: ClaudeCodeEndpoint) throws -> ClaudeCodeInstallOutcome {
        try requireClaudeDirectory()
        let root = try readDocument()
        let elsewhere = allowListExistsInSiblingSettings()
        let updated = ClaudeCodeSettings.installed(
            root, endpoint: endpoint, allowListExistsElsewhere: elsewhere)

        var warnings: [ClaudeCodeInstallWarning] = []
        let backup = try write(updated, ifDifferentFrom: root)
        if let mode = try permissionWarning() { warnings.append(mode) }
        if allowListIsInEffect(given: updated) { warnings.append(.allowListInEffect) }

        return ClaudeCodeInstallOutcome(
            changed: backup.changed,
            backupURL: backup.backupURL,
            overlaps: ClaudeCodeSettings.foreignOverlaps(in: updated),
            warnings: warnings)
    }

    @discardableResult
    public func uninstall() throws -> ClaudeCodeInstallOutcome {
        guard fileManager.fileExists(atPath: settingsURL.path(percentEncoded: false)) else {
            return ClaudeCodeInstallOutcome(
                changed: false, backupURL: nil, overlaps: [], warnings: [])
        }
        let root = try readDocument()
        let updated = ClaudeCodeSettings.uninstalled(root)
        let backup = try write(updated, ifDifferentFrom: root)
        return ClaudeCodeInstallOutcome(
            changed: backup.changed,
            backupURL: backup.backupURL,
            overlaps: ClaudeCodeSettings.foreignOverlaps(in: updated),
            warnings: [])
    }

    /// Whether any settings file this installer can read defines an allow-list.
    ///
    /// Allow-lists merge across settings levels, so a list living in
    /// `settings.local.json` still governs the handlers written here — and an
    /// entry written here still counts towards it. Reading the sibling costs one
    /// `stat` and removes a whole class of "installed, and nothing ever
    /// arrives".
    private func allowListExistsInSiblingSettings() -> Bool {
        let sibling = settingsURL.deletingLastPathComponent()
            .appending(path: "settings.local.json")
        guard let data = try? Data(contentsOf: sibling),
            let value = try? JSONParser.parse(data)
        else { return false }
        return ClaudeCodeSettings.allowedURLs(in: value) != nil
    }

    private func allowListIsInEffect(given root: JSONValue) -> Bool {
        ClaudeCodeSettings.allowedURLs(in: root) != nil || allowListExistsInSiblingSettings()
    }

    // MARK: - Comparison

    static func drift(
        between installed: [InstalledHookHandler],
        allowedURLs: [String]?,
        and endpoint: ClaudeCodeEndpoint
    ) -> [ClaudeCodeInstallDrift] {
        var drift: [ClaudeCodeInstallDrift] = []
        let expectedURL = endpoint.url.absoluteString
        let byEvent = Dictionary(grouping: installed, by: \.event)

        for handler in ClaudeCodeHookHandler.monitoring {
            let event = handler.event.rawValue
            guard let found = byEvent[event], let first = found.first else {
                drift.append(.missingHandler(event: event))
                continue
            }
            if found.count > 1 { drift.append(.duplicateHandler(event: event)) }
            if first.url != expectedURL {
                drift.append(.endpointChanged(found: first.url, expected: expectedURL))
            }
            if first.authorization != endpoint.authorizationHeader {
                drift.append(.tokenChanged)
            }
            if first.timeout != handler.timeout {
                drift.append(
                    .timeoutChanged(event: event, found: first.timeout, expected: handler.timeout))
            }
            if first.matcher != handler.matcher {
                drift.append(
                    .matcherChanged(event: event, found: first.matcher, expected: handler.matcher))
            }
        }
        let expectedEvents = Set(ClaudeCodeHookHandler.monitoring.map(\.event.rawValue))
        for event in byEvent.keys.sorted() where !expectedEvents.contains(event) {
            drift.append(.obsoleteHandler(event: event))
        }
        // An absent key allows every http hook, which is why only a present one
        // can be wrong.
        if let allowedURLs, !allowedURLs.contains(expectedURL) {
            drift.append(.urlNotAllowed)
        }
        // A moved port and a replaced token are one fact each, not one per
        // handler: ten identical lines is a status surface nobody reads.
        var seen: Set<ClaudeCodeInstallDrift> = []
        return drift.filter { seen.insert($0).inserted }
    }
}
