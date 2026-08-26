import AgentBarIngest
import AgentBarUI
import CodexAppServer
import Foundation
import ServiceManagement

/// The half of the uninstall that is about AgentBar's own footprint rather than
/// about a provider's configuration file.
///
/// Split from the provider half for length, and the split falls where the rules
/// change: everything here is a file or a registration AgentBar created, so
/// there is nothing to merge and nothing of anybody else's to preserve — only a
/// guard that the thing being deleted really is one of ours.
extension AgentBarRemoval {

    // MARK: - AgentBar's own footprint

    /// Unregisters the login item, if there is one.
    ///
    /// > **`status == .enabled` is not the question, and asking it was a bug.**
    /// > `SMAppService.Status` has four cases, and `.requiresApproval` means the
    /// > service **is** registered and waiting on the user in System Settings.
    /// > Treating it as `.notRegistered` skipped the `unregister()` and reported
    /// > `Nothing there` for a row the user can still see in Login Items — the
    /// > one answer this report may never give. Only the two cases that mean
    /// > *there is nothing registered* skip the call; everything else attempts
    /// > it, because attempting an unregister that was not needed costs nothing.
    ///
    /// The verdict is read back from `SMAppService` rather than from
    /// `LaunchAtLogin.isEnabled`, which is `status == .enabled` and would call
    /// `.requiresApproval` a success for the same reason.
    func removeLoginItem() -> RemovalStep {
        let title = String(localized: "Login item", comment: "Removal step")
        let location = String(
            localized: "System Settings › General › Login Items",
            comment: "Where the login item lives")
        guard Self.isRegistered(SMAppService.mainApp.status) else {
            return RemovalStep(
                id: "login-item", title: title, location: location, outcome: .nothingToRemove)
        }
        launchAtLogin.set(false)
        guard Self.isRegistered(SMAppService.mainApp.status) else {
            return RemovalStep(
                id: "login-item", title: title, location: location, outcome: .removed())
        }
        return RemovalStep(
            id: "login-item", title: title, location: location,
            outcome: .failed(
                reason: launchAtLogin.lastError
                    ?? String(
                        localized: "macOS still reports AgentBar as a login item",
                        comment: "The login item could not be unregistered"),
                remedy: String(
                    localized: """
                        Open System Settings › General › Login Items and remove AgentBar from \
                        "Open at Login".
                        """,
                    comment: "How to remove the login item by hand")))
    }

    /// Whether macOS has a registration for this app at all.
    ///
    /// Written as a denylist of the two cases that mean *nothing is registered*,
    /// so a status added to `SMAppService` later counts as registered and is
    /// acted on rather than silently skipped. That is the safe direction here:
    /// an unnecessary `unregister()` is a no-op, and a skipped one is a leftover
    /// reported as clean.
    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .notRegistered, .notFound: false
        default: true
        }
    }

    /// `~/Library/Application Support/AgentBar`, whole.
    ///
    /// The token, the discovery file, the Unix socket, the Codex trust baseline
    /// and the `bin` directory the helper was deployed into all live here and
    /// nothing else does — AgentBar created this directory and is the only
    /// writer of it.
    func removeApplicationSupport() -> RemovalStep {
        removeOwnedDirectory(
            id: "application-support",
            title: String(localized: "Application Support files", comment: "Removal step"),
            url: applicationSupport,
            fallback: "~/Library/Application Support/AgentBar")
    }

    /// The pre-rendered notification art, which is derived and re-creatable.
    func removeCaches() -> RemovalStep {
        let caches = try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return removeOwnedDirectory(
            id: "caches",
            title: String(localized: "Cached notification art", comment: "Removal step"),
            url: caches?.appending(path: "AgentBar", directoryHint: .isDirectory),
            fallback: "~/Library/Caches/AgentBar")
    }

    /// Removes a directory AgentBar owns, and turns the answer into a row.
    ///
    /// The delete itself, and the guard that decides what it may reach, are
    /// `AgentBarDirectory.remove(at:)` in `AgentBarIngest` — the module that
    /// defines where AgentBar's own directory is, and where `swift test` can
    /// drive a recursive delete against a scratch tree. What is left here is the
    /// mapping onto a report row.
    ///
    /// > **Neither refusal reports "nothing there".** A URL that could not be
    /// > resolved and a path the guard refused are both cases where AgentBar
    /// > does not *know* whether something is left behind, and the one answer
    /// > this report may never give for that is the reassuring one. `fallback`
    /// > is the conventional path, so the user gets an instruction even when
    /// > this code could not build a URL at all.
    func removeOwnedDirectory(
        id: String, title: String, url: URL?, fallback: String
    ) -> RemovalStep {
        func byHand(_ reason: String, at location: String) -> RemovalStep {
            RemovalStep(
                id: id, title: title, location: location,
                outcome: .failed(
                    reason: reason,
                    remedy: String(
                        localized: "Delete the folder \(fallback) by hand if it is there.",
                        comment: "How to remove one of AgentBar's own folders by hand")))
        }
        guard let url else {
            return byHand(
                String(
                    localized: "AgentBar could not work out where this folder lives",
                    comment: "A system directory could not be resolved"),
                at: fallback)
        }
        let location = Self.display(url)
        do {
            switch try AgentBarDirectory.remove(at: url) {
            case .removed:
                return RemovalStep(id: id, title: title, location: location, outcome: .removed())
            case .absent:
                return RemovalStep(
                    id: id, title: title, location: location, outcome: .nothingToRemove)
            case .notOwned:
                return byHand(
                    String(
                        localized: "\(location) is not a folder AgentBar recognises as its own",
                        comment: "The derived path failed its own ownership guard"),
                    at: location)
            }
        } catch {
            return byHand("\(error)", at: location)
        }
    }

    /// Every preference AgentBar has stored.
    ///
    /// The whole persistent domain rather than the five keys AgentBar writes:
    /// macOS keeps window frames and other per-application state in the same
    /// plist, and those are AgentBar's traces too. The five keys are then read
    /// back, so the step reports what actually happened instead of assuming the
    /// call worked — this process is still running and `cfprefsd` still has the
    /// domain open.
    func removePreferences() -> RemovalStep {
        let title = String(localized: "Stored settings", comment: "Removal step")
        let location = "~/Library/Preferences/\(bundleIdentifier).plist"
        let present = Self.ownedDefaultsKeys.filter { defaults.object(forKey: $0) != nil }
        // Removed unconditionally, and reported by whether any of *AgentBar's*
        // settings were in it: the same plist holds window frames and other
        // per-application state macOS put there, which are traces too and are
        // not something the row can sensibly count.
        defaults.removePersistentDomain(forName: bundleIdentifier)
        guard !present.isEmpty else {
            return RemovalStep(
                id: "preferences", title: title, location: location, outcome: .nothingToRemove)
        }
        let left = Self.ownedDefaultsKeys.filter { defaults.object(forKey: $0) != nil }
        guard left.isEmpty else {
            return RemovalStep(
                id: "preferences", title: title, location: location,
                outcome: .failed(
                    reason: String(
                        localized: "\(left.count) settings are still stored",
                        comment: "Preferences could not be removed"),
                    remedy: String(
                        localized: """
                            Quit AgentBar and run: defaults delete \(self.bundleIdentifier)
                            """,
                        comment: "How to remove the stored settings by hand")))
        }
        return RemovalStep(
            id: "preferences", title: title, location: location,
            outcome: .removed(
                detail: String(
                    localized: """
                        Changing a setting before you quit would write them again.
                        """,
                    comment: "Detail of the preferences removal step")))
    }

    // MARK: - Text

    /// A path as the user would type it, with the home directory abbreviated.
    nonisolated static func display(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// What a successful hook removal has to say for itself.
    ///
    /// Two things, and both are files AgentBar left behind under a summary that
    /// says nothing is left. The backup is one of possibly several — each
    /// installer keeps five — so the sentence names the pattern as well as the
    /// newest. `leftEmpty` covers the case only the Claude Code side has: its
    /// installer *creates* `settings.json` when there is none, and unlike the
    /// Codex side it does not remove a file it emptied, because a user's
    /// settings file is not AgentBar's to delete on a guess.
    nonisolated static func removedDetail(backupURL: URL?, leftEmpty: Bool = false) -> String? {
        var sentences: [String] = []
        if let backupURL {
            sentences.append(
                String(
                    localized: """
                        The file as it was is at \(display(backupURL)); earlier backups sit \
                        beside it under the same .bak. prefix.
                        """,
                    comment: "Names the backups a removal left behind"))
        }
        if leftEmpty {
            sentences.append(
                String(
                    localized: """
                        The file is empty now. AgentBar created it, so it is safe to delete.
                        """,
                    comment: "Says an AgentBar-created settings file was left empty"))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Whether the file at `url` now holds `{}` and nothing else.
    ///
    /// Read back after the write rather than reasoned about: the merge rules
    /// decide what survives, and asking the file is the only way to know that
    /// nothing did. A file that cannot be read is not empty as far as this is
    /// concerned — the reassuring answer again.
    nonisolated static func isNowAnEmptyObject(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else { return false }
        return object.isEmpty
    }
}
