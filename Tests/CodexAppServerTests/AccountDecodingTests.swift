import Foundation
import Testing

@testable import CodexAppServer

/// The generated models against the shapes the schema permits.
///
/// Their whole job is to degrade: an account kind nobody has shipped, a summary
/// with every counter missing, a bucket list with a bad entry in it. None of
/// those may throw, and none may turn into a zero.
@Suite("Account decoding")
struct AccountDecodingTests {

    @Test("Each account kind decodes to its own case")
    func decodesEveryAccountKind() throws {
        #expect(
            try Fixtures.decode(GetAccountResponse.self, "account-chatgpt").account
                == .chatgpt(ChatgptAccount(planType: .plus, type: "chatgpt")))
        #expect(
            try Fixtures.decode(GetAccountResponse.self, "account-api-key").account
                == .apiKey(ApiKeyAccount(type: "apiKey")))
        #expect(
            try Fixtures.decode(GetAccountResponse.self, "account-bedrock").account
                == .amazonBedrock(AmazonBedrockAccount(type: "amazonBedrock")))
        #expect(try Fixtures.decode(GetAccountResponse.self, "account-none").account == nil)
        #expect(
            try Fixtures.decode(GetAccountResponse.self, "account-unknown-kind").account
                == .unrecognised(type: "someFutureBroker"))
    }

    /// The generator drops `ChatgptAccount.email` by policy. A field that is
    /// never decoded is a field that cannot be logged, stored or leaked by a
    /// later change — and the recorded fixture carries one, so this is a real
    /// check rather than a restatement.
    @Test("The account's identity is not decoded at all")
    func neverHoldsTheEmail() throws {
        let raw = String(data: try Fixtures.data("account-chatgpt"), encoding: .utf8) ?? ""
        #expect(
            raw.contains("someone@example.com"),
            "the fixture must still carry what the generator declines to read")

        let response = try Fixtures.decode(GetAccountResponse.self, "account-chatgpt")
        guard case .chatgpt(let account) = response.account else {
            Issue.record("the recorded account is a ChatGPT one")
            return
        }
        let fields = Mirror(reflecting: account).children.compactMap(\.label)
        #expect(fields == ["planType", "type"], "no field may hold the account's identity")
        // The belt to that brace: whatever the fields are called, the address
        // itself must not survive anywhere in the decoded value.
        #expect(!String(describing: response).contains("@"))
    }

    /// Never rendered — the design's answer to absent data is absence — but the
    /// question "why is the Limits section empty?" has to have an answer in the
    /// log.
    @Test(
        "Each account kind explains itself when there are no limits to show",
        arguments: [
            ("account-chatgpt", nil as String?),
            ("account-none", "no account is signed in to Codex"),
        ])
    func explainsWhyLimitsAreUnavailable(fixture: String, expected: String?) throws {
        let response = try Fixtures.decode(GetAccountResponse.self, fixture)
        #expect(response.limitsUnavailableReason == expected)
    }

    @Test(
        "An account with no plan limits says so", arguments: ["account-api-key", "account-bedrock"])
    func explainsAnAccountWithoutPlanLimits(fixture: String) throws {
        let reason = try Fixtures.decode(GetAccountResponse.self, fixture).limitsUnavailableReason
        #expect(reason?.contains("no plan limits") == true)
    }

    @Test("Token usage decodes, populated and empty")
    func decodesTokenUsage() throws {
        let live = try Fixtures.decode(GetAccountTokenUsageResponse.self, "usage-live")
        #expect(live.summary.lifetimeTokens == 524_234_972)
        #expect(live.dailyUsageBuckets?.count == 3)

        let empty = try Fixtures.decode(GetAccountTokenUsageResponse.self, "usage-empty")
        // Absent, not zero. A lifetime of 0 tokens and a lifetime nobody
        // reported are different claims.
        #expect(empty.summary.lifetimeTokens == nil)
        #expect(empty.summary.currentStreakDays == nil)
        #expect(empty.dailyUsageBuckets == nil)
    }

    /// The generator drops `GetAccountTokenUsageResponse.threadUsage` by policy,
    /// for the reason it drops the account's email: AgentBar shows what a plan
    /// has left, never what a turn cost, and a field that is never decoded
    /// cannot be logged, stored or leaked by a later change.
    ///
    /// The fixture carries a fully populated one — a thread id, a dollar figure
    /// and a per-model token breakdown — so this pins two things at once: that
    /// the refusal holds, and that a response carrying it still decodes rather
    /// than throwing.
    @Test("A thread's spend is not decoded at all")
    func neverHoldsAThreadsSpend() throws {
        let raw = String(data: try Fixtures.data("usage-thread-spend"), encoding: .utf8) ?? ""
        #expect(
            raw.contains("estimatedUsageUsdMicros"),
            "the fixture must still carry what the generator declines to read")

        let usage = try Fixtures.decode(GetAccountTokenUsageResponse.self, "usage-thread-spend")
        // The rest of the response survives: an unfamiliar key is ignored by the
        // closed `CodingKeys` list, not treated as a malformed payload.
        #expect(usage.summary.lifetimeTokens == 524_234_972)
        #expect(usage.dailyUsageBuckets?.count == 1)

        let fields = Mirror(reflecting: usage).children.compactMap(\.label)
        #expect(
            fields == ["dailyUsageBuckets", "summary"],
            "no field may hold what a thread cost")
        // Whatever the fields end up called, no figure from the declined branch
        // may survive anywhere in the decoded value.
        let described = String(describing: usage)
        #expect(!described.contains("1873400"))
        #expect(!described.contains("41200000"))
        #expect(!described.contains("thr_"))
    }

    @Test("A plan this build has never heard of keeps its name")
    func toleratesAnUnknownPlan() {
        #expect(PlanType(rawValue: "plus") == .plus)
        #expect(PlanType(rawValue: "edu_plus") == .eduPlus)
        #expect(PlanType(rawValue: "edu_pro") == .eduPro)
        #expect(PlanType(rawValue: "not_a_plan") == .unrecognised("not_a_plan"))
        // `unknown` is a value the server sends; `unrecognised` is one we did
        // not recognise. Collapsing them would lose the difference.
        #expect(PlanType(rawValue: "unknown") == .unknown)
        #expect(PlanType.unrecognised("not_a_plan").rawValue == "not_a_plan")
    }
}
