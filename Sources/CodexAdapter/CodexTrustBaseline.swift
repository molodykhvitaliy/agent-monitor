import Foundation

/// What Codex had recorded at the moment AgentBar last wrote a hook definition.
///
/// Trust records are keyed by a hook's **position**, not by its content, so a
/// repair that rewrites the command leaves the old record standing at the same
/// key — looking exactly like consent, for a definition whose hash no longer
/// matches and which Codex will therefore skip. Reading the table alone cannot
/// tell the two apart. Remembering what was there when AgentBar wrote can: once
/// the user reviews the new definition, Codex replaces the record, and a value
/// that has *changed since the write* is consent for what is there now.
///
/// This is a note about AgentBar's own action, not a second copy of somebody
/// else's decision — which is the line ADR-0008 draws.
public struct CodexTrustBaseline: Sendable, Hashable, Codable {
    /// Bumped when a reader would misunderstand an older file. An unknown
    /// version is treated as no baseline at all, which is the pessimistic
    /// direction.
    public static let currentVersion = 1

    public var version: Int
    /// The hash observed at each of AgentBar's trust keys when it wrote. A key
    /// that had no record maps to the empty string, so "there was nothing" and
    /// "there was this" are both expressible.
    public var observed: [String: String]

    public init(version: Int = CodexTrustBaseline.currentVersion, observed: [String: String]) {
        self.version = version
        self.observed = observed
    }

    /// Whether the record now at `key` is consent for what AgentBar wrote.
    ///
    /// A record that is absent, or that still holds the hash seen at write time,
    /// is not. Anything else is: Codex writes a fresh hash when the user trusts
    /// the definition it now sees.
    public func isSatisfied(at key: String, by record: CodexTrustRecord?) -> Bool {
        guard let record, let hash = record.trustedHash else { return false }
        return hash != (observed[key] ?? "")
    }
}

/// The baseline as a file in AgentBar's own directory.
///
/// Nothing is written into `~/.codex`: this is AgentBar's memory of its own
/// write, and it belongs beside AgentBar's other state. A file that cannot be
/// read is no baseline, and no baseline means the trust table is read at face
/// value — which is why the caller also keeps the fact in memory for the launch
/// that wrote it.
struct CodexTrustBaselineFile: Sendable {
    let url: URL

    func read(fileManager: FileManager = .default) -> CodexTrustBaseline? {
        guard let data = fileManager.contents(atPath: url.path(percentEncoded: false)),
            let baseline = try? JSONDecoder().decode(CodexTrustBaseline.self, from: data),
            baseline.version == CodexTrustBaseline.currentVersion
        else { return nil }
        return baseline
    }

    func write(_ baseline: CodexTrustBaseline) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(baseline).write(to: url, options: [.atomic])
    }

    func clear(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}
