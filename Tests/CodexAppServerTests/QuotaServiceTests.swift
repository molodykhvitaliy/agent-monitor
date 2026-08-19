import AgentBarCore
import Foundation
import Testing

@testable import CodexAppServer

/// When a reading is taken, and what happens to the last one when it fails.
@Suite("Quota refresh policy")
struct QuotaServiceTests {

    /// A clock the test moves by hand, so throttling is proven rather than
    /// waited out.
    final class Clock: TimeSource, @unchecked Sendable {
        private let lock = NSLock()
        private var instant = MonotonicInstant.origin
        var now: MonotonicInstant { lock.withLock { instant } }
        var wallTime: Date { Date(timeIntervalSince1970: 1_787_000_000) }
        func advance(by amount: Duration) {
            lock.withLock { instant = instant.advanced(by: amount) }
        }
    }

    /// Hands out a fresh scripted transport per reading and remembers them all,
    /// which is how "one child per reading, and no more" is checked.
    final class Spawns: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [ScriptedTransport] = []
        /// Called with the 1-based reading number, so a test can script the
        /// second child differently from the first without a captured counter.
        var configure: @Sendable (Int, ScriptedTransport) -> Void = { _, _ in }

        var all: [ScriptedTransport] { lock.withLock { made } }
        var count: Int { all.count }

        func make(_ url: URL) -> any AppServerTransport {
            let transport = ScriptedTransport()
            let reading = lock.withLock { made.count + 1 }
            configure(reading, transport)
            lock.withLock { made.append(transport) }
            return transport
        }
    }

    static func liveBody() throws -> String {
        String(data: try Fixtures.data("rate-limits-live"), encoding: .utf8) ?? "{}"
    }

    static let installed = CodexExecutable(url: URL(filePath: "/x/codex"))

    static func service(
        clock: Clock, spawns: Spawns, executable: CodexExecutable? = installed
    ) -> QuotaService {
        QuotaService(
            settings: QuotaSettings(interval: .seconds(3600)),
            clientVersion: "0.1.0",
            clock: clock,
            budget: .seconds(2),
            locate: { executable },
            transport: { spawns.make($0) })
    }

    @Test("A reading fills the windows the panel renders")
    func readsTheLimits() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }

        let service = Self.service(clock: clock, spawns: spawns)
        await service.refresh(reason: "test")

        let windows = await service.windows()
        #expect(windows.count == 1)
        #expect(windows.first?.fractionUsed == 0.8)
        #expect(spawns.count == 1)
    }

    /// A burst of turn completions is one reading. Without this each finishing
    /// agent would start its own `codex`.
    @Test("Two reads inside the throttle window are one child")
    func throttlesCloselySpacedReads() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }
        let service = Self.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "one")
        clock.advance(by: .seconds(5))
        await service.refresh(reason: "two")
        #expect(spawns.count == 1)

        clock.advance(by: QuotaSettings.minimumSpacing)
        await service.refresh(reason: "three")
        #expect(spawns.count == 2)
    }

    /// The throttle counts **attempts**, not successes: a Codex that fails every
    /// time must not be re-spawned on every turn completion.
    @Test("A failed read is throttled exactly like a successful one")
    func throttlesFailuresToo() async {
        let clock = Clock()
        let spawns = Spawns()
        spawns.configure = {
            $1.reactions[AccountMethods.rateLimits] = [.failure(code: -32000, message: "nope")]
        }
        let service = Self.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "one")
        clock.advance(by: .seconds(5))
        await service.refresh(reason: "two")
        #expect(spawns.count == 1)
    }

    /// A refresh that failed says nothing about the numbers it failed to fetch.
    /// Clearing them would turn a transient hiccup into the interface claiming
    /// the data does not exist.
    @Test("A failed read leaves the previous reading alone")
    func keepsTheLastGoodReading() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { reading, transport in
            transport.reactions[AccountMethods.rateLimits] =
                reading == 1 ? [.result(body)] : [.silence]
        }
        let service = Self.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "first")
        #expect(await service.windows().count == 1)

        clock.advance(by: .seconds(600))
        await service.refresh(reason: "second")
        #expect(await service.windows().count == 1, "a timeout must not empty the section")
        #expect(
            spawns.all.allSatisfy { $0.ended },
            "every child is ended, including the one that hung")
    }

    /// The version-awareness the step asks for, done by asking the server rather
    /// than by comparing against a floor somebody guessed.
    @Test("A Codex without the account API is asked once, not for ever")
    func remembersACodexWithoutTheAccountAPI() async {
        let clock = Clock()
        let spawns = Spawns()
        // An unscripted method is answered exactly as the real server answers
        // one it does not implement.
        let service = Self.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "first")
        clock.advance(by: .seconds(600))
        await service.refresh(reason: "second")

        #expect(spawns.count == 2, "the second attempt still spawns — the handshake is how we ask")
        // The second child was told not to bother: it handshook and asked
        // nothing further.
        #expect(spawns.all[0].methodsCalled.contains(AccountMethods.rateLimits))
        #expect(!spawns.all[1].methodsCalled.contains(AccountMethods.rateLimits))
    }

    @Test("An updated Codex is asked again")
    func forgetsWhenTheVersionMoves() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { reading, transport in
            if reading > 1 {
                let newer = "AgentBar/0.999.0 (Mac OS 27.0.0; arm64) unknown (AgentBar; 0.1.0)"
                let handshake = #"""
                    {"userAgent":"\#(newer)","codexHome":"/x","platformFamily":"unix",\#
                    "platformOs":"macos"}
                    """#
                transport.reactions["initialize"] = [.result(handshake)]
                transport.reactions[AccountMethods.rateLimits] = [.result(body)]
            }
        }
        let service = Self.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "old codex")
        clock.advance(by: .seconds(600))
        await service.refresh(reason: "new codex")
        #expect(await service.windows().count == 1)
    }

    /// Not a fault, and not worth a child process: a machine that only runs
    /// Claude Code has no `codex` to find, for ever.
    @Test("No codex binary means no child and no windows")
    func doesNothingWithoutCodex() async {
        let clock = Clock()
        let spawns = Spawns()
        let service = Self.service(clock: clock, spawns: spawns, executable: nil)
        await service.refresh(reason: "test")
        #expect(spawns.all.isEmpty)
        #expect(await service.windows().isEmpty)
    }

    /// The account read is the diagnostic, not the fast path: asking who is
    /// signed in before every successful refresh would put a second network
    /// round trip in front of a log line nobody reads when things work.
    @Test("The account is read only when there is nothing to draw")
    func explainsOnlyAnEmptyReading() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let live = try Self.liveBody()
        let empty = String(data: try Fixtures.data("rate-limits-all-null"), encoding: .utf8) ?? "{}"
        let account = String(data: try Fixtures.data("account-api-key"), encoding: .utf8) ?? "{}"
        spawns.configure = { reading, transport in
            transport.reactions[AccountMethods.rateLimits] = [
                .result(reading == 1 ? live : empty)
            ]
            transport.reactions[AccountMethods.account] = [.result(account)]
        }
        let service = Self.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "full")
        #expect(!spawns.all[0].methodsCalled.contains(AccountMethods.account))

        clock.advance(by: .seconds(600))
        await service.refresh(reason: "empty")
        #expect(spawns.all[1].methodsCalled.contains(AccountMethods.account))
    }

    /// `account/usage/read` is implemented and never called: it reports what an
    /// account has spent rather than what it has left, the design has no surface
    /// for it, and AgentBar does not make a request whose answer nothing reads.
    @Test("The refresh cycle never asks for token usage")
    func neverReadsTokenUsage() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }
        let service = Self.service(clock: clock, spawns: spawns)
        await service.refresh(reason: "test")
        #expect(spawns.all.allSatisfy { !$0.methodsCalled.contains(AccountMethods.usage) })
    }

    @Test("The interval cannot be configured below the floor")
    func clampsTheInterval() {
        let defaults = UserDefaults(suiteName: "quota-interval-\(UUID().uuidString)")
        defaults?.set(1, forKey: QuotaSettings.intervalDefaultsKey)
        #expect(
            QuotaSettings.load(from: defaults ?? .standard).interval
                == QuotaSettings.minimumInterval)

        defaults?.set(90, forKey: QuotaSettings.intervalDefaultsKey)
        #expect(QuotaSettings.load(from: defaults ?? .standard).interval == .seconds(90 * 60))

        // Nonsense is not worth a diagnostic; the documented default is the
        // honest answer to it.
        defaults?.set("half past three", forKey: QuotaSettings.intervalDefaultsKey)
        #expect(
            QuotaSettings.load(from: defaults ?? .standard).interval
                == QuotaSettings.defaultInterval)

        // An interval longer than a day is the feature switched off with extra
        // steps, and the ceiling keeps every downstream clock inside its range.
        defaults?.set(60 * 24 * 30, forKey: QuotaSettings.intervalDefaultsKey)
        #expect(
            QuotaSettings.load(from: defaults ?? .standard).interval
                == QuotaSettings.maximumInterval)
    }

    /// The twin of `survivesAnAbsurdWindowLength`. This multiplication is on a
    /// number a person can type into `defaults write`, and an overflow in Swift
    /// is a trap — a crash on every launch that they could never connect to what
    /// they typed.
    @Test("A defaults value that cannot become seconds falls back rather than trapping")
    func survivesAnAbsurdInterval() {
        let defaults = UserDefaults(suiteName: "quota-overflow-\(UUID().uuidString)")
        defaults?.set(Int.max, forKey: QuotaSettings.intervalDefaultsKey)
        #expect(
            QuotaSettings.load(from: defaults ?? .standard).interval
                == QuotaSettings.defaultInterval)

        // Just inside the overflow, and still clamped rather than accepted.
        defaults?.set(Int.max / 61, forKey: QuotaSettings.intervalDefaultsKey)
        #expect(
            QuotaSettings.load(from: defaults ?? .standard).interval
                == QuotaSettings.maximumInterval)
    }
}
