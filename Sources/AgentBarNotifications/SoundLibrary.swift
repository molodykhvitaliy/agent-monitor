import Foundation
import os

/// Where a sound came from, which is the only thing that distinguishes two
/// files with the same name from the user's point of view.
public enum SoundOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    /// Shipped inside AgentBar.app and always present.
    case bundled
    /// The user's own `~/Library/Sounds`, which they may add to and empty.
    case user
}

/// One selectable sound.
public struct SoundFile: Sendable, Hashable, Identifiable {
    /// File name including the extension — what `UNNotificationSound` takes.
    public let name: String
    public let origin: SoundOrigin
    public let url: URL

    public var id: String { name }
    /// Without the extension, which is what a picker shows.
    public var displayName: String { (name as NSString).deletingPathExtension }

    public init(name: String, origin: SoundOrigin, url: URL) {
        self.name = name
        self.origin = origin
        self.url = url
    }
}

/// The sounds a notification may name, and the two directories they may live in.
///
/// > **The constraint that shapes this whole file.** `UNNotificationSound` looks
/// > in exactly two places: the app's own bundle, and `Library/Sounds` under the
/// > app's container — which for an unsandboxed app is `~/Library/Sounds`.
/// > `/System/Library/Sounds` is **not** one of them, so AgentBar deliberately
/// > does not offer `Glass.aiff` as a choice it cannot honour. What it offers
/// > instead is `install(from:)`, which copies any file — a system sound
/// > included — into the folder that does work, and validates it on the way.
/// > The result is that every selection in the matrix names a file AgentBar can
/// > stat, which is what makes "report a broken sound" possible at all.
public struct SoundLibrary: Sendable {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "sounds")

    /// Where AgentBar's own sounds live. Injected so a test can point at a
    /// directory it built rather than at an app bundle it has not got.
    private let bundledDirectory: URL?
    public let userDirectory: URL

    /// The default reads AgentBar's own bundle and the real Sounds folder.
    ///
    /// `Bundle.main.resourceURL` rather than a subdirectory: the notification
    /// centre resolves a bare file name against the bundle, and a sound filed
    /// under `Resources/Sounds/` is a sound it has not been shown to find.
    public init(bundle: Bundle = .main, userDirectory: URL? = nil) {
        bundledDirectory = bundle.resourceURL
        self.userDirectory =
            userDirectory
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            .appending(path: "Library/Sounds", directoryHint: .isDirectory)
    }

    /// Everything selectable, bundled sounds first in the order they were
    /// authored, then the user's own alphabetically.
    public func available() -> [SoundFile] {
        bundled() + user()
    }

    /// One reading of both directories, reusable.
    ///
    /// The settings window validates every cell of the matrix on every edit, and
    /// each `problem(with:)` otherwise re-enumerates `~/Library/Sounds`. Eight
    /// scans per keystroke today and sixteen after step 09 is not a correctness
    /// problem, but it is a scan per cell for an answer that cannot change
    /// between them.
    public func catalogue() -> SoundCatalogue {
        SoundCatalogue(files: available())
    }

    /// AgentBar's four, and only the ones actually present.
    ///
    /// Reading them from disk rather than trusting `BundledSound` is deliberate:
    /// a bundle whose resources were not copied should show four missing sounds
    /// in the settings window, not four choices that do nothing.
    public func bundled() -> [SoundFile] {
        guard let bundledDirectory else { return [] }
        return BundledSound.allCases.compactMap { sound in
            let url = bundledDirectory.appending(path: sound.fileName)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                return nil
            }
            return SoundFile(name: sound.fileName, origin: .bundled, url: url)
        }
    }

    public func user() -> [SoundFile] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: userDirectory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return
            contents
            .filter { SoundValidator.allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { SoundFile(name: $0.lastPathComponent, origin: .user, url: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The file a selection names, if it is still there.
    ///
    /// The bundle wins a name collision: a user who drops their own
    /// `AgentBar Question.aiff` into `~/Library/Sounds` has not replaced ours,
    /// because the notification centre's own search order is not ours to choose
    /// and guessing at it would make the picker lie.
    public func file(named name: String) -> SoundFile? {
        available().first { $0.name == name }
    }

    /// `nil` when the selection is usable right now.
    ///
    /// Called twice on purpose: when the picker is built, so an unusable choice
    /// is visible before it matters, and again when a notification is about to
    /// be sent, because a user can empty `~/Library/Sounds` between the two.
    public func problem(with selection: SoundSelection) -> SoundProblem? {
        catalogue().problem(with: selection)
    }

    /// Validates a file the user picked and copies it into `~/Library/Sounds`.
    ///
    /// A copy rather than a reference because the notification centre resolves
    /// names in its own two directories and nowhere else: a sound left in
    /// `~/Downloads` is a sound that plays as the default. The original is never
    /// touched, and an existing file of the same name is never overwritten — the
    /// copy takes a numbered name instead, because silently replacing a sound
    /// another notification is already using is not this function's decision.
    public func install(from source: URL) throws -> SoundFile {
        if let problem = SoundValidator.problem(with: source) { throw problem }

        let manager = FileManager.default
        try manager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let destination = availableName(for: source.lastPathComponent)
        try manager.copyItem(at: source, to: destination)
        Self.logger.notice(
            "installed notification sound \(destination.lastPathComponent, privacy: .public)")
        return SoundFile(name: destination.lastPathComponent, origin: .user, url: destination)
    }

    /// `Chime.aiff`, then `Chime 2.aiff`, and so on.
    private func availableName(for fileName: String) -> URL {
        let stem = (fileName as NSString).deletingPathExtension
        let suffix = (fileName as NSString).pathExtension
        var candidate = userDirectory.appending(path: fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = userDirectory.appending(path: "\(stem) \(counter).\(suffix)")
            counter += 1
        }
        return candidate
    }
}

/// One reading of the two directories a sound may live in.
///
/// A value, so a caller checking several selections at once — the settings
/// window has one per matrix cell — reads the filesystem once rather than once
/// per cell. Deliberately a snapshot: it goes stale the moment the user drops a
/// file into `~/Library/Sounds`, which is exactly why the router takes a fresh
/// one for every notification it sends.
public struct SoundCatalogue: Sendable {
    public let files: [SoundFile]

    public init(files: [SoundFile]) {
        self.files = files
    }

    public func file(named name: String) -> SoundFile? {
        files.first { $0.name == name }
    }

    /// `nil` when the selection is usable. The two selections that name no file
    /// — default and silent — can never be a problem.
    public func problem(with selection: SoundSelection) -> SoundProblem? {
        guard let name = selection.fileName else { return nil }
        guard let file = file(named: name) else { return .missing(name: name) }
        return SoundValidator.problem(with: file.url)
    }
}
