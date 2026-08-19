import Foundation
import Testing

@testable import CodexAppServer

/// What the App Server said, and what the panel is allowed to draw from it.
///
/// The rule under every test here: **absent data renders as unavailable, never
/// as zero.** A window that arrives without a percentage must produce no
/// percentage — a bar at 0 % would claim the user has spent none of a limit
/// nobody measured.
@Suite("Rate limit mapping")
struct RateLimitMappingTests {

    static func windows(_ fixture: String) throws -> [QuotaWindow] {
        RateLimitMapping.windows(
            from: try Fixtures.decode(GetAccountRateLimitsResponse.self, fixture))
    }

    @Test("The live reading is one weekly window at 80%")
    func mapsTheLiveReading() throws {
        let windows = try Self.windows("rate-limits-live")
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.limitId == "codex")
        // Null in every reading taken so far, which is the whole reason the
        // label falls back to the window's length.
        #expect(window.limitName == nil)
        #expect(window.fractionUsed == 0.8)
        #expect(window.windowDuration == .seconds(10080 * 60))
        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_787_200_207))
    }

    /// The back-compat `rateLimits` field and the `rateLimitsByLimitId` map
    /// carried the *same* snapshot in the live reading. Rendering both would
    /// draw every row twice, which is the failure this test exists to catch.
    @Test("The single-bucket view is not rendered alongside the map")
    func doesNotDoubleCountTheBackCompatView() throws {
        #expect(try Self.windows("rate-limits-live").count == 1)
        #expect(try Self.windows("rate-limits-two-windows").count == 2)
    }

    @Test("A bucket with both windows renders both, primary first")
    func rendersBothWindowsInOrder() throws {
        let windows = try Self.windows("rate-limits-two-windows")
        #expect(windows.map(\.fractionUsed) == [0.34, 0.72])
        #expect(windows.map(\.windowDuration) == [.seconds(300 * 60), .seconds(10080 * 60)])
    }

    /// Never a fixed two-slot layout, and never an assumption that a five-hour
    /// bucket exists: the count is whatever came back.
    @Test("Several buckets each render their own windows, in a stable order")
    func rendersEveryBucket() throws {
        let windows = try Self.windows("rate-limits-many-buckets")
        // agent (2 windows), codex (1), shipped-in-a-later-codex (1) — sorted by
        // limitId so the list does not reshuffle between refreshes.
        #expect(windows.map(\.limitId) == ["agent", "agent", "codex", "shipped-in-a-later-codex"])
        #expect(windows.map(\.fractionUsed) == [0.05, 0.99, 0.12, 0.03])
        // The one bucket that named itself keeps its name verbatim.
        #expect(windows[2].limitName == "Codex")
    }

    @Test("A field this build has never heard of costs nothing")
    func toleratesUnknownFields() throws {
        let windows = try Self.windows("rate-limits-many-buckets")
        let future = try #require(windows.first { $0.limitId == "shipped-in-a-later-codex" })
        #expect(future.fractionUsed == 0.03)
    }

    /// The documented all-null case: a `self_serve_business_usage_based` account
    /// returns empty `primary`, `secondary`, `credits` and `rateLimitReachedType`.
    @Test(
        "Every nullable field null at once produces no windows and no error",
        arguments: ["rate-limits-all-null", "rate-limits-absent-fields"])
    func degradesToNothing(fixture: String) throws {
        #expect(try Self.windows(fixture).isEmpty)
    }

    @Test("Unknown enum values and unreadable buckets degrade rather than throw")
    func survivesSchemaDrift() throws {
        let response = try Fixtures.decode(
            GetAccountRateLimitsResponse.self, "rate-limits-drifted")
        // A plan and a reached-type nobody has shipped are carried, not refused.
        #expect(response.rateLimits.planType == .unrecognised("an_entirely_new_plan"))
        #expect(
            response.rateLimits.rateLimitReachedType
                == .unrecognised("something_nobody_has_shipped_yet"))
        // Two of the three map entries are unreadable — one has no `usedPercent`,
        // one is not an object at all — and they cost only themselves.
        let windows = RateLimitMapping.windows(from: response)
        #expect(windows.map(\.limitId) == ["codex"])
        #expect(windows.first?.fractionUsed == 0.41)
    }

    @Test("A credit list keeps what it can read and drops the rest")
    func dropsUnreadableCredits() throws {
        let response = try Fixtures.decode(
            GetAccountRateLimitsResponse.self, "rate-limits-drifted")
        let credits = try #require(response.rateLimitResetCredits)
        // The bad entries sit *between* the good ones on purpose. With them at
        // the end, a `drain` that failed to advance its cursor past a bad
        // element would still produce the right answer — the failure this
        // arrangement exists to catch is one good entry being eaten by the
        // step over the bad one before it.
        #expect(credits.availableCount == 2)
        #expect(credits.credits?.map(\.id) == ["a", "b", "c"])
        #expect(credits.credits?[1].resetType == .unrecognised("somethingNew"))
    }

    /// Reading `resetsAt` as milliseconds would put the reset fifty thousand
    /// years out and the row would say so rather than fail, which is why the
    /// unit is pinned by a test.
    @Test("resetsAt is Unix seconds")
    func readsResetAsSeconds() throws {
        let window = try #require(try Self.windows("rate-limits-live").first)
        let reset = try #require(window.resetsAt)
        // 2026-08-20, not the year 58 000.
        #expect(reset > Date(timeIntervalSince1970: 1_780_000_000))
        #expect(reset < Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The number came from the backend by way of the user's `codex`, and an
    /// overflow in Swift is a **trap** — it would abort the process past every
    /// `catch`. The rule this pins is the one docs/dev/architecture.md already
    /// records under "Arithmetic on numbers a caller chose".
    @Test("A window length that cannot be converted to seconds is absent, not a crash")
    func survivesAnAbsurdWindowLength() throws {
        let response = GetAccountRateLimitsResponse(
            rateLimits: RateLimitSnapshot(
                limitId: "codex",
                primary: RateLimitWindow(
                    resetsAt: 1_787_200_207, usedPercent: 40,
                    windowDurationMins: Int64.max),
                secondary: RateLimitWindow(
                    resetsAt: 1_787_200_207, usedPercent: 50,
                    windowDurationMins: Int64.max / 61)))
        let windows = RateLimitMapping.windows(from: response)
        #expect(windows.count == 2)
        // The unconvertible one loses its duration and keeps everything else:
        // the row still says 40% and still says when it resets.
        #expect(windows[0].windowDuration == nil)
        #expect(windows[0].fractionUsed == 0.4)
        // Just inside the range still converts, so the guard is not a blanket
        // rejection of large windows.
        #expect(windows[1].windowDuration != nil)
    }

    @Test("Numbers outside their range are clamped, and non-values are absent")
    func handlesNonsenseNumbers() throws {
        let windows = try Self.windows("rate-limits-nonsense-numbers")
        #expect(windows.count == 2)
        // 250 % and −8 % are the server saying something odd about a real
        // window; the nearest true statement is all of it and none of it.
        #expect(windows.map(\.fractionUsed) == [1.0, 0.0])
        // A zero epoch is how "no value" reaches a field with no null, and a
        // window of zero or negative minutes is not a window.
        #expect(windows.allSatisfy { $0.resetsAt == nil })
        #expect(windows.allSatisfy { $0.windowDuration == nil })
        // A name of nothing but spaces is not a name.
        #expect(windows.allSatisfy { $0.limitName == nil && $0.limitId == nil })
    }

    /// A row with neither a percentage nor a reset would occupy space to say
    /// nothing, so it is not rendered at all.
    @Test("A window that says nothing is dropped")
    func dropsUninformativeWindows() {
        let silent = QuotaWindow(limitId: "codex")
        #expect(silent.isInformative == false)
        let response = GetAccountRateLimitsResponse(
            rateLimits: RateLimitSnapshot(
                limitId: "codex",
                primary: RateLimitWindow(usedPercent: 0)))
        // A zero percentage is a real reading, unlike an absent one.
        #expect(RateLimitMapping.windows(from: response).first?.fractionUsed == 0)
    }
}
