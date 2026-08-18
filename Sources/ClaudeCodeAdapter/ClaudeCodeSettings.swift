import Foundation

/// A handler AgentBar found in a settings file, as it was written there.
public struct InstalledHookHandler: Sendable, Hashable {
    public let event: String
    public let matcher: String?
    public let url: String
    public let timeout: Int?
    public let authorization: String?
}

/// A hook somebody else installed, on an event AgentBar also watches or from a
/// family AgentBar is about to duplicate.
///
/// Reported and never touched. The user's machine already runs a notifier on
/// `Stop` and a power assertion on `UserPromptSubmit`; AgentBar's job is to make
/// the resulting double notification explainable, not to take the other tool's
/// hooks away.
public struct ForeignHookOverlap: Sendable, Hashable {
    public enum Family: String, Sendable, Hashable {
        /// A `claude-notifier-*.js` handler: notifies about the same events.
        case notifier
        /// A `caffeine.sh` handler: keeps the Mac awake, as AgentBar will.
        case caffeine
        case other
    }

    public let event: String
    public let matcher: String?
    /// The handler's `command`, `url` or type, shortened for display.
    public let summary: String
    public let family: Family
}

/// Reading and rewriting `settings.json` as a value.
///
/// Every operation here is a pure function of the parsed document, so the merge
/// rules are testable without a filesystem — and `ClaudeCodeInstaller` is left
/// owning only the parts that can fail for filesystem reasons.
enum ClaudeCodeSettings {
    static let hooksKey = "hooks"
    static let allowedURLsKey = "allowedHttpHookUrls"

    // MARK: - Reading

    /// Every AgentBar handler in the document.
    static func installedHandlers(in root: JSONValue) -> [InstalledHookHandler] {
        var found: [InstalledHookHandler] = []
        forEachHandler(in: root) { event, matcher, handler in
            guard isOurs(handler) else { return }
            found.append(
                InstalledHookHandler(
                    event: event,
                    matcher: matcher,
                    url: handler["url"]?.string ?? "",
                    timeout: handler["timeout"]?.integer,
                    authorization: handler["headers"]?.object?["Authorization"]?.string))
        }
        return found
    }

    /// Foreign handlers worth telling the user about: anything on an event
    /// AgentBar installs on, plus the two families it is about to duplicate
    /// wherever they appear.
    static func foreignOverlaps(in root: JSONValue) -> [ForeignHookOverlap] {
        let watched = Set(ClaudeCodeHookHandler.monitoring.map(\.event.rawValue))
        var found: [ForeignHookOverlap] = []
        forEachHandler(in: root) { event, matcher, handler in
            guard !isOurs(handler) else { return }
            let summary = describe(handler)
            let family = family(of: summary)
            guard watched.contains(event) || family != .other else { return }
            found.append(
                ForeignHookOverlap(
                    event: event, matcher: matcher, summary: summary, family: family))
        }
        return found
    }

    /// The URL allow-list, when the document defines one.
    ///
    /// `nil` and `[]` are different answers and both matter: an absent key
    /// permits every http hook, an empty list permits none.
    static func allowedURLs(in root: JSONValue) -> [String]? {
        root.object?[allowedURLsKey]?.array?.compactMap(\.string)
    }

    // MARK: - Writing

    /// The document with AgentBar's handlers installed for `endpoint`.
    ///
    /// Built by removing everything AgentBar owns and adding it back, which is
    /// what makes the result depend only on the endpoint and not on how many
    /// times the installer has run before.
    /// `allowListExistsElsewhere` says whether another settings file this
    /// installer can read already defines `allowedHttpHookUrls`. Allow-lists
    /// merge across settings levels, so an entry written here counts towards one
    /// defined next door.
    static func installed(
        _ root: JSONValue,
        endpoint: ClaudeCodeEndpoint,
        allowListExistsElsewhere: Bool = false,
        handlers: [ClaudeCodeHookHandler] = ClaudeCodeHookHandler.monitoring
    ) -> JSONValue {
        var object = uninstalled(root).object ?? JSONObject()

        var hooks = object[hooksKey]?.object ?? JSONObject()
        for handler in handlers {
            var groups = hooks[handler.event.rawValue]?.array ?? []
            groups.append(.object(group(for: handler, endpoint: endpoint)))
            hooks[handler.event.rawValue] = .array(groups)
        }
        object[hooksKey] = .object(hooks)

        // The allow-list is extended, never created. An absent key permits every
        // http hook, so AgentBar's own handlers run without one — and *defining*
        // the key switches allow-listing on at every settings level at once,
        // which would silently stop http hooks in a project's own settings that
        // AgentBar cannot see, and would go on doing it after AgentBar was
        // uninstalled. Changing that policy is not the installer's to make.
        if var urls = object[allowedURLsKey]?.array?.compactMap(\.string) {
            let ours = endpoint.url.absoluteString
            if !urls.contains(ours) { urls.append(ours) }
            object[allowedURLsKey] = .array(urls.map(JSONValue.string))
        } else if allowListExistsElsewhere {
            object[allowedURLsKey] = .array([.string(endpoint.url.absoluteString)])
        }

        return .object(object)
    }

    /// The document with every trace of AgentBar removed, and nothing else
    /// touched.
    ///
    /// Containers AgentBar emptied are removed with it — a group left with no
    /// handlers, an event left with no groups — but only ever containers that
    /// held one of ours. A `"PreCompact": []` the user wrote themselves is not
    /// AgentBar's to tidy away.
    ///
    /// `allowedHttpHookUrls` keeps its key whatever happens to the entries,
    /// because AgentBar never creates it: whoever defined it wanted
    /// allow-listing on, and an uninstall that switched it off would be the same
    /// unasked-for policy change in the other direction.
    static func uninstalled(_ root: JSONValue) -> JSONValue {
        var object = root.object ?? JSONObject()

        if var hooks = object[hooksKey]?.object {
            var removedSomething = false
            for event in hooks.keys {
                guard let groups = hooks[event]?.array else { continue }
                var removedHere = false
                let kept: [JSONValue] = groups.compactMap { group in
                    guard let groupObject = group.object,
                        let handlers = groupObject["hooks"]?.array
                    else { return group }
                    let keptHandlers = handlers.filter { !isOurs($0.object) }
                    if keptHandlers.count == handlers.count { return group }
                    removedHere = true
                    removedSomething = true
                    guard !keptHandlers.isEmpty else { return nil }
                    var updated = groupObject
                    updated["hooks"] = .array(keptHandlers)
                    return .object(updated)
                }
                guard removedHere else { continue }
                hooks[event] = kept.isEmpty ? nil : .array(kept)
            }
            if removedSomething { object[hooksKey] = hooks.isEmpty ? nil : .object(hooks) }
        }

        if let urls = object[allowedURLsKey]?.array {
            let kept = urls.filter { !($0.string.map(ClaudeCodeEndpoint.isAgentBarURL) ?? false) }
            if kept.count != urls.count { object[allowedURLsKey] = .array(kept) }
        }

        return .object(object)
    }

    /// One matcher group holding one handler.
    ///
    /// AgentBar appends its own group rather than joining a foreign one. A group
    /// carries a matcher that belongs to whoever wrote it, and a handler added
    /// beside somebody else's inherits it; keeping ours separate means a foreign
    /// group survives install and uninstall without a single byte changing.
    private static func group(
        for handler: ClaudeCodeHookHandler, endpoint: ClaudeCodeEndpoint
    ) -> JSONObject {
        var entry = JSONObject()
        entry["type"] = .string("http")
        entry["url"] = .string(endpoint.url.absoluteString)
        entry["timeout"] = .number(String(handler.timeout))
        entry["headers"] = .object(
            JSONObject([("Authorization", .string(endpoint.authorizationHeader))]))

        var group = JSONObject()
        if let matcher = handler.matcher { group["matcher"] = .string(matcher) }
        group["hooks"] = .array([.object(entry)])
        return group
    }

    // MARK: - Recognition

    /// Whether a handler is one AgentBar wrote.
    ///
    /// The URL is the marker. A custom key would be a cleaner signature, but an
    /// unrecognised field in a settings file is a validation risk that buys
    /// nothing: no other tool posts to AgentBar's path on loopback.
    static func isOurs(_ handler: JSONObject?) -> Bool {
        guard let handler, handler["type"]?.string == "http",
            let url = handler["url"]?.string
        else { return false }
        return ClaudeCodeEndpoint.isAgentBarURL(url)
    }

    private static func isOurs(_ handler: JSONValue) -> Bool {
        isOurs(handler.object)
    }

    /// A foreign handler in one bounded line.
    ///
    /// Bounded and query-stripped for the same reason the row's tool line is:
    /// this text is destined for a panel and for whatever the user pastes into a
    /// bug report, and a hook command is somebody else's writing.
    private static func describe(_ handler: JSONObject) -> String {
        if let command = handler["command"]?.string { return ToolInvocation.condense(command) }
        if let url = handler["url"]?.string {
            return ToolInvocation.condense(ToolInvocation.stripQuery(url))
        }
        if let tool = handler["tool"]?.string { return ToolInvocation.condense(tool) }
        return handler["type"]?.string ?? "hook"
    }

    private static func family(of summary: String) -> ForeignHookOverlap.Family {
        if summary.contains("claude-notifier") { return .notifier }
        if summary.contains("caffeine") { return .caffeine }
        return .other
    }

    /// Visits every handler in the document, with the event and matcher it sits
    /// under. Anything that is not shaped like a hook configuration is skipped
    /// rather than reported: the file belongs to the user, and a key AgentBar
    /// does not understand is not a key AgentBar gets to complain about.
    private static func forEachHandler(
        in root: JSONValue, _ visit: (String, String?, JSONObject) -> Void
    ) {
        guard let hooks = root.object?[hooksKey]?.object else { return }
        for event in hooks.keys {
            guard let groups = hooks[event]?.array else { continue }
            for group in groups {
                guard let groupObject = group.object,
                    let handlers = groupObject["hooks"]?.array
                else { continue }
                let matcher = groupObject["matcher"]?.string
                for handler in handlers {
                    guard let handlerObject = handler.object else { continue }
                    visit(event, matcher, handlerObject)
                }
            }
        }
    }
}
