import AgentBarJSON
import Foundation

/// A handler AgentBar found in `hooks.json`, as it was written there.
///
/// Carries its position as well as its content, because Codex's trust records
/// are keyed by position: `<source path>:<event>:<group>:<hook>`. Without the
/// two indices there is no way to ask whether *this* entry has been trusted.
public struct InstalledCodexHook: Sendable, Hashable {
    public let event: String
    public let matcher: String?
    public let command: String
    public let timeout: Int?
    /// Index of the matcher group within the event's array, and of the handler
    /// within that group's `hooks`.
    public let groupIndex: Int
    public let hookIndex: Int

    /// The `[hooks.state]` key Codex would record this entry's trust under.
    public func trustKey(source: URL) -> String? {
        guard let event = CodexHookEvent(rawValue: event) else { return nil }
        let path = source.path(percentEncoded: false)
        return "\(path):\(event.trustStateName):\(groupIndex):\(hookIndex)"
    }
}

/// A hook somebody else installed, wherever Codex resolves it from.
///
/// Reported and never touched. This machine already runs `caffeine.sh` on three
/// events, and AgentBar's job is to make a competing power assertion
/// explainable rather than to take the other tool's hooks away.
public struct CodexHookOverlap: Sendable, Hashable {
    /// Which of Codex's two hook layers the entry came from. Worth carrying:
    /// AgentBar can only ever repair entries in `hooks.json`, and a foreign
    /// entry in `config.toml` is in the file it must never write.
    public enum Source: String, Sendable, Hashable {
        case hooksFile
        case configToml
    }

    public enum Family: String, Sendable, Hashable {
        /// A notifier: announces the same events AgentBar announces.
        case notifier
        /// A `caffeine.sh` handler: keeps the Mac awake, as AgentBar does.
        case caffeine
        case other
    }

    public let event: String
    public let matcher: String?
    /// The handler's command, shortened and query-stripped for display.
    public let summary: String
    public let family: Family
    public let source: Source
}

/// Reading and rewriting `hooks.json` as a value.
///
/// Every operation here is a pure function of the parsed document, so the merge
/// rules are testable without a filesystem and `CodexInstaller` is left owning
/// only what can fail for filesystem reasons.
enum CodexHooksFile {
    static let hooksKey = "hooks"
    static let handlersKey = "hooks"
    static let matcherKey = "matcher"

    // MARK: - Reading

    /// Every AgentBar handler in the document, in file order.
    static func installedHooks(in root: JSONValue) -> [InstalledCodexHook] {
        var found: [InstalledCodexHook] = []
        forEachHandler(in: root) { position, handler in
            guard let command = handler["command"]?.string,
                CodexHookCommand.isAgentBarCommand(command)
            else { return }
            found.append(
                InstalledCodexHook(
                    event: position.event,
                    matcher: position.matcher,
                    command: command,
                    timeout: handler["timeout"]?.integer,
                    groupIndex: position.groupIndex,
                    hookIndex: position.hookIndex))
        }
        return found
    }

    /// Foreign handlers worth telling the user about.
    ///
    /// Everything that is not ours, on any event: a `hooks.json` is small and
    /// entirely about hooks, so unlike `settings.json` there is no reason to
    /// filter by event. The families are named for the two AgentBar duplicates.
    static func foreignHooks(in root: JSONValue) -> [CodexHookOverlap] {
        var found: [CodexHookOverlap] = []
        forEachHandler(in: root) { position, handler in
            let command = handler["command"]?.string ?? handler["type"]?.string ?? "hook"
            guard !CodexHookCommand.isAgentBarCommand(command) else { return }
            let summary = describe(command)
            found.append(
                CodexHookOverlap(
                    event: position.event,
                    matcher: position.matcher,
                    summary: summary,
                    family: family(of: summary),
                    source: .hooksFile))
        }
        return found
    }

    /// One bounded line for a foreign command.
    ///
    /// Bounded and query-stripped for the same reason the row's tool line is:
    /// this text is destined for a panel and for whatever the user pastes into
    /// a bug report, and a hook command is somebody else's writing.
    static func describe(_ command: String) -> String {
        CodexToolInvocation.condense(CodexToolInvocation.stripQuery(command))
    }

    static func family(of summary: String) -> CodexHookOverlap.Family {
        if summary.contains("caffeine") { return .caffeine }
        if summary.contains("notifier") || summary.contains("notify") { return .notifier }
        return .other
    }

    // MARK: - Writing

    /// The document with AgentBar's handlers installed for `endpoint`.
    ///
    /// Built by removing everything AgentBar owns and adding it back, which is
    /// what makes the result depend only on the endpoint and not on how many
    /// times the installer has run before.
    static func installed(
        _ root: JSONValue,
        endpoint: CodexEndpoint,
        handlers: [CodexHookHandler] = CodexHookHandler.monitoring
    ) -> JSONValue {
        var object = uninstalled(root).object ?? JSONObject()
        var hooks = object[hooksKey]?.object ?? JSONObject()
        for handler in handlers {
            var groups = hooks[handler.event.rawValue]?.array ?? []
            groups.append(.object(group(for: handler, endpoint: endpoint)))
            hooks[handler.event.rawValue] = .array(groups)
        }
        object[hooksKey] = .object(hooks)
        return .object(object)
    }

    /// The document with every trace of AgentBar removed, and nothing else
    /// touched.
    ///
    /// Containers AgentBar emptied are removed with it — a group left with no
    /// handlers, an event left with no groups — but only ever containers that
    /// held one of ours. A `"PreCompact": []` the user wrote themselves is not
    /// AgentBar's to tidy away.
    static func uninstalled(_ root: JSONValue) -> JSONValue {
        var object = root.object ?? JSONObject()
        guard var hooks = object[hooksKey]?.object else { return .object(object) }

        var removedSomething = false
        for event in hooks.keys {
            guard let groups = hooks[event]?.array else { continue }
            var removedHere = false
            let kept: [JSONValue] = groups.compactMap { group in
                guard let groupObject = group.object,
                    let handlers = groupObject[handlersKey]?.array
                else { return group }
                let keptHandlers = handlers.filter { !isOurs($0) }
                if keptHandlers.count == handlers.count { return group }
                removedHere = true
                removedSomething = true
                guard !keptHandlers.isEmpty else { return nil }
                var updated = groupObject
                updated[handlersKey] = .array(keptHandlers)
                return .object(updated)
            }
            guard removedHere else { continue }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        if removedSomething { object[hooksKey] = hooks.isEmpty ? nil : .object(hooks) }
        return .object(object)
    }

    /// Whether the document holds nothing but an empty shell AgentBar created.
    ///
    /// The installer uses this to decide whether an uninstall should leave the
    /// file behind. A `hooks.json` containing `{}` is not wrong, but it is a
    /// file the user did not have before AgentBar arrived.
    static func isVacant(_ root: JSONValue) -> Bool {
        guard let object = root.object else { return false }
        for (key, value) in object.pairs {
            guard key == hooksKey, value.object?.isEmpty ?? false else { return false }
        }
        return true
    }

    /// One matcher group holding one handler.
    ///
    /// AgentBar appends its own group rather than joining a foreign one, exactly
    /// as the Claude Code installer does: a group carries a matcher belonging to
    /// whoever wrote it, and a handler added beside somebody else's inherits it.
    ///
    /// `statusMessage` is deliberately absent — Codex shows it to the user while
    /// the hook runs, and a monitor that announces itself on every tool call is
    /// not a monitor. `async` is absent too: with a helper measured in
    /// milliseconds, synchronous delivery costs nothing and keeps `Stop` and
    /// `SessionEnd` in the order they happened.
    private static func group(
        for handler: CodexHookHandler, endpoint: CodexEndpoint
    ) -> JSONObject {
        var entry = JSONObject()
        entry["type"] = .string("command")
        entry["command"] = .string(endpoint.command)
        entry["timeout"] = .number(String(handler.timeout))

        var group = JSONObject()
        if let matcher = handler.matcher { group[matcherKey] = .string(matcher) }
        group[handlersKey] = .array([.object(entry)])
        return group
    }

    // MARK: - Traversal

    /// Where a handler sits: which event, which matcher group, which index.
    struct HandlerPosition {
        let event: String
        let matcher: String?
        let groupIndex: Int
        let hookIndex: Int
    }

    private static func isOurs(_ handler: JSONValue) -> Bool {
        guard let command = handler.object?["command"]?.string else { return false }
        return CodexHookCommand.isAgentBarCommand(command)
    }

    /// Visits every handler in the document with the position it occupies.
    ///
    /// Anything not shaped like a hook configuration is skipped rather than
    /// reported: the file belongs to the user, and a key AgentBar does not
    /// understand is not a key AgentBar gets to complain about. Skipped entries
    /// still consume their index, because Codex counts positions in the file and
    /// a key built from a different count would look up somebody else's trust.
    private static func forEachHandler(
        in root: JSONValue, _ visit: (HandlerPosition, JSONObject) -> Void
    ) {
        guard let hooks = root.object?[hooksKey]?.object else { return }
        for event in hooks.keys {
            guard let groups = hooks[event]?.array else { continue }
            for (groupIndex, group) in groups.enumerated() {
                guard let groupObject = group.object,
                    let handlers = groupObject[handlersKey]?.array
                else { continue }
                let matcher = groupObject[matcherKey]?.string
                for (hookIndex, handler) in handlers.enumerated() {
                    guard let handlerObject = handler.object else { continue }
                    visit(
                        HandlerPosition(
                            event: event, matcher: matcher, groupIndex: groupIndex,
                            hookIndex: hookIndex),
                        handlerObject)
                }
            }
        }
    }
}
