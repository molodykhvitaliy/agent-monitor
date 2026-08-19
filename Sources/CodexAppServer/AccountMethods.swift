import Foundation

/// The three account calls, with their method names and parameter shapes in one
/// place.
///
/// Each was checked against the binary on 2026-08-19, and the parameter column
/// is not a detail: `account/read` is **rejected** without `params`
/// (`-32600 missing field params`), while the other two take none at all.
public enum AccountMethods {
    /// Subscription limits. The one call the refresh cycle makes.
    public static let rateLimits = "account/rateLimits/read"
    /// Which account is signed in. Asked only to explain a reading that came
    /// back empty — see `QuotaService`.
    public static let account = "account/read"
    /// Lifetime token counters. Implemented, tested, and **not called by the
    /// refresh cycle**: it reports what an account has spent rather than what it
    /// has left, the design has no surface for it, and AgentBar does not make a
    /// request whose answer nothing reads.
    public static let usage = "account/usage/read"

    public static func readRateLimits(
        on exchange: AppServerExchange
    ) async throws -> GetAccountRateLimitsResponse {
        try await exchange.call(
            method: rateLimits, params: .omitted, returning: GetAccountRateLimitsResponse.self)
    }

    /// Reads the signed-in account.
    ///
    /// The parameter object is deliberately empty. The schema offers one flag
    /// there, which asks Codex to renew a credential before answering, and
    /// AgentBar does not ask a provider's own tooling to touch a credential on
    /// its behalf — see docs/dev/tos-boundary.md. `JSONRPC.Parameters` cannot
    /// express it, so this is a property of the types rather than a habit.
    public static func readAccount(
        on exchange: AppServerExchange
    ) async throws -> GetAccountResponse {
        try await exchange.call(
            method: account, params: .empty, returning: GetAccountResponse.self)
    }

    public static func readTokenUsage(
        on exchange: AppServerExchange
    ) async throws -> GetAccountTokenUsageResponse {
        try await exchange.call(
            method: usage, params: .omitted, returning: GetAccountTokenUsageResponse.self)
    }
}

extension GetAccountResponse {
    /// Why limits are unavailable, when they are, in a form fit for a log line.
    ///
    /// Never rendered. The design's answer to absent data is absence, and a
    /// panel that explained every reason a number is missing would be the
    /// opposite of the restraint the brief asks for. This exists so the question
    /// "why is the Limits section empty?" has an answer in `log show`.
    var limitsUnavailableReason: String? {
        guard let account else { return "no account is signed in to Codex" }
        switch account {
        case .chatgpt: return nil
        case .apiKey: return "this Codex is authenticated with an API key, which has no plan limits"
        case .amazonBedrock:
            return "this Codex runs through Amazon Bedrock, which has no plan limits"
        case .unrecognised(let type):
            return "this Codex uses an account type AgentBar does not know (\(type))"
        }
    }
}
