import AgentBarCore
import Foundation

/// How a request reached the endpoint.
///
/// Carried into diagnostics because the two transports fail in different ways
/// and "no events arriving" is a very different problem depending on which one
/// went quiet.
public enum IngestTransport: String, Sendable, Hashable {
    case loopback
    case unixSocket
}

/// A method and path the endpoint answers on.
///
/// Providers get a route each rather than sharing one with a discriminator in
/// the body: the Claude Code hook URL is written into the user's settings once
/// and never inspected again, so the URL is the only place the source can be
/// stated. Naming a provider here is not the same as knowing its payload — the
/// shape behind the route stays entirely inside its adapter.
public struct IngestRoute: Sendable, Hashable {
    public let method: String
    public let path: String

    public init(method: String, path: String) {
        self.method = method.uppercased()
        self.path = path
    }

    /// Liveness, and the installer's way of telling a live endpoint from a
    /// stale discovery file. Authenticated like everything else: an
    /// unauthenticated 401 already answers "something is listening".
    public static let health = IngestRoute(method: "GET", path: "/v1/health")

    /// AgentBar's own neutral event envelope — the shape `AgentEvent` is
    /// spelled in, with no provider behind it. It exists so the endpoint can be
    /// exercised without a provider, and so a future source that is not one of
    /// the two built-in adapters has somewhere to arrive.
    public static let events = IngestRoute(method: "POST", path: "/v1/events")

    /// Where a provider's own hook payloads arrive.
    public static func hooks(of provider: Provider) -> IngestRoute {
        IngestRoute(method: "POST", path: "/v1/hooks/\(slug(of: provider))")
    }

    /// The provider's name as it appears in a URL.
    ///
    /// Kept here rather than on `Provider` because it is a fact about this
    /// module's URLs, not about the domain.
    static func slug(of provider: Provider) -> String {
        switch provider {
        case .claudeCode: "claude-code"
        case .codex: "codex"
        }
    }
}

/// The statuses the endpoint can answer with.
///
/// There is no 5xx case, and the omission is the design. Claude Code treats any
/// non-2xx as a non-blocking error, so a 500 would not break an agent — it would
/// merely report our bug in the user's transcript, on a path where nothing we do
/// should be visible at all. Anything unexpected degrades to `ok` with an empty
/// body instead, which reads as "the hook had nothing to say".
public enum IngestStatus: Int, Sendable, Hashable {
    case ok = 200
    case badRequest = 400
    case unauthorized = 401
    case notFound = 404
    case methodNotAllowed = 405
    case payloadTooLarge = 413
    case uriTooLong = 414
    case headerFieldsTooLarge = 431

    var reasonPhrase: String {
        switch self {
        case .ok: "OK"
        case .badRequest: "Bad Request"
        case .unauthorized: "Unauthorized"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .payloadTooLarge: "Payload Too Large"
        case .uriTooLong: "URI Too Long"
        case .headerFieldsTooLarge: "Request Header Fields Too Large"
        }
    }
}

/// One request, after parsing and authentication, as a handler sees it.
public struct IngestRequest: Sendable {
    public let route: IngestRoute
    public let query: String?
    public let headers: HTTPHeaders
    public let body: Data
    public let transport: IngestTransport
    /// When the endpoint finished reading the request.
    ///
    /// The only clock an event may be stamped from. Neither provider puts a
    /// timestamp in its hook payload, and one taken from a body would let a
    /// caller poison the store's high-water mark, so receipt time is both the
    /// best available answer and the only safe one.
    public let receivedAt: Date

    public init(
        route: IngestRoute,
        query: String? = nil,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data = Data(),
        transport: IngestTransport,
        receivedAt: Date
    ) {
        self.route = route
        self.query = query
        self.headers = headers
        self.body = body
        self.transport = transport
        self.receivedAt = receivedAt
    }
}

/// What the endpoint sends back.
///
/// For the MVP this is always `noOpinion`. The type exists in this shape — a
/// status and a body a handler chooses — because the Approve/Deny backlog item
/// answers on this same path with a JSON decision, and Claude Code accepts a
/// decision only as a 2xx JSON body. Making that a later addition rather than a
/// later redesign is the whole reason the response is a value at all.
public struct IngestResponse: Sendable, Hashable {
    public let status: IngestStatus
    public let body: Data
    public let contentType: String?

    public init(status: IngestStatus, body: Data = Data(), contentType: String? = nil) {
        self.status = status
        self.body = body
        self.contentType = body.isEmpty ? nil : contentType
    }

    /// 200 with an empty body: received, and nothing to say about it.
    public static let noOpinion = IngestResponse(status: .ok)

    /// 200 with a JSON body, which is the only way an `http` hook can carry a
    /// decision. Unused by the MVP.
    public static func decision(_ body: Data) -> IngestResponse {
        IngestResponse(status: .ok, body: body, contentType: "application/json")
    }
}

/// Request headers, matched without regard to case.
///
/// Keeps every occurrence rather than collapsing duplicates: two `Content-Length`
/// headers that disagree is a request that must be refused, not one where the
/// first value wins.
public struct HTTPHeaders: Sendable, Hashable {
    private var fields: [(name: String, value: String)]

    public init() {
        fields = []
    }

    public init(_ pairs: [(String, String)]) {
        fields = pairs.map { (name: $0.0, value: $0.1) }
    }

    public var count: Int { fields.count }

    /// The first value for `name`, which is the right answer for every header
    /// this module reads.
    public subscript(name: String) -> String? {
        let wanted = name.lowercased()
        return fields.first { $0.name.lowercased() == wanted }?.value
    }

    public func values(for name: String) -> [String] {
        let wanted = name.lowercased()
        return fields.filter { $0.name.lowercased() == wanted }.map(\.value)
    }

    mutating func append(name: String, value: String) {
        fields.append((name: name, value: value))
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for field in fields {
            hasher.combine(field.name)
            hasher.combine(field.value)
        }
    }
}
