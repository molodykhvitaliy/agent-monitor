import AgentBarCore
import Foundation
import os

/// Keeps the last reading of Codex's limits, and decides when to take another.
///
/// **The sidecar is spawned per reading, never kept running** — ADR-0009. The
/// alternative was a long-lived connection subscribed to
/// `account/rateLimits/updated`, and it buys nothing here: that notification is
/// a rolling update for turns made *on the connection that receives it*, and
/// AgentBar's connection never starts a thread. It would cost a permanent child
/// process for updates that would never arrive.
///
/// Three things ask for a reading, and they cover different failures: the
/// launch, because AgentBar is usually started while agents are already at work;
/// a turn finishing, because that is when the number has just moved; and the
/// interval, because a Codex session in another editor spends quota this process
/// never hears about.
public actor QuotaService {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "quota")

    /// How a transport is made for one reading. Injected so the suite drives the
    /// whole service without a `codex` binary anywhere near it.
    public typealias TransportFactory = @Sendable (URL) -> any AppServerTransport

    private let settings: QuotaSettings
    private let clientVersion: String
    private let clock: any TimeSource
    private let budget: Duration
    private let locate: @Sendable () -> CodexExecutable?
    private let makeTransport: TransportFactory

    private var reading = QuotaReading.empty
    /// When a read was last *attempted*, successful or not. Throttling on
    /// attempts rather than successes is what stops a failing Codex being
    /// re-spawned on every turn completion.
    private var lastAttempt: MonotonicInstant?
    private var refreshing = false
    private var ticker: Task<Void, Never>?

    /// Versions of Codex that answered "no such method".
    ///
    /// Remembered so an old Codex is asked once rather than twice an hour for
    /// ever, and keyed by version so an update clears the memory by itself. This
    /// is what "version-aware" means here: the server is asked what it supports
    /// instead of being compared against a floor somebody guessed.
    private var withoutAccountAPI: Set<String> = []

    public init(
        settings: QuotaSettings = QuotaSettings.load(),
        clientVersion: String,
        clock: any TimeSource = SystemTimeSource(),
        budget: Duration = AppServerExchange.defaultBudget,
        locate: @escaping @Sendable () -> CodexExecutable? = { CodexExecutable.locate() },
        transport: @escaping TransportFactory = { CodexProcessTransport(executable: $0) }
    ) {
        self.settings = settings
        self.clientVersion = clientVersion
        self.clock = clock
        self.budget = budget
        self.locate = locate
        makeTransport = transport
    }

    /// The last reading. A property read — never I/O, and never a wait for one
    /// in flight, because the panel opens faster than a child process starts.
    public func windows() -> [QuotaWindow] { reading.windows }

    // MARK: - Lifecycle

    /// Takes one reading now and then keeps taking them on the interval.
    public func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self, interval = settings.interval] in
            await self?.refresh(reason: "launch")
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refresh(reason: "interval")
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// A turn finished somewhere, which is the moment the number has just moved.
    ///
    /// Throttled hard: a burst of completions is one reading, and the caller
    /// does not have to know that. `nonisolated` so the push leg can call it and
    /// carry on — that leg runs on the main actor and must never wait on I/O.
    nonisolated public func turnFinished() {
        Task { [weak self] in await self?.refresh(reason: "turn finished") }
    }

    // MARK: - Reading

    /// Takes one reading, unless something else already did recently.
    func refresh(reason: String) async {
        guard !refreshing else { return }
        if let lastAttempt, clock.now - lastAttempt < QuotaSettings.minimumSpacing { return }
        guard let executable = locate() else {
            // Not a fault and not worth a log line on a timer: a machine that
            // only runs Claude Code has no codex to find, for ever.
            lastAttempt = clock.now
            return
        }

        refreshing = true
        lastAttempt = clock.now
        defer { refreshing = false }

        do {
            let windows = try await read(using: executable)
            reading = QuotaReading(windows: windows, takenAt: clock.wallTime)
            Self.logger.debug(
                """
                limits refreshed (\(reason, privacy: .public)): \
                \(windows.count, privacy: .public) window(s)
                """)
        } catch let error as AppServerError {
            report(error)
        } catch {
            Self.logger.error("limits could not be read: \(error, privacy: .public)")
        }
    }

    /// One exchange: handshake, limits, and — only when the limits came back
    /// with nothing in them — the account read that explains why.
    ///
    /// The order matters for latency. Asking who is signed in first would put a
    /// second network round trip in front of every successful refresh to produce
    /// a log line nobody reads when things work.
    private func read(using executable: CodexExecutable) async throws -> [QuotaWindow] {
        let transport = makeTransport(executable.url)
        return try await AppServerExchange.run(
            transport: transport, clientVersion: clientVersion, budget: budget
        ) { [weak self] exchange, version in
            if await self?.knowsHasNoAccountAPI(version) == true {
                throw AppServerError.unimplemented(method: AccountMethods.rateLimits)
            }
            do {
                let response = try await AccountMethods.readRateLimits(on: exchange)
                let windows = RateLimitMapping.windows(from: response)
                if windows.isEmpty { await self?.explainEmptyReading(on: exchange) }
                return windows
            } catch AppServerError.unimplemented(let method) {
                await self?.noteNoAccountAPI(version)
                throw AppServerError.unimplemented(method: method)
            }
        }
    }

    /// Asks who is signed in, purely so the log can say why there is nothing to
    /// draw. A failure here is swallowed: it is a diagnostic about a diagnostic.
    private func explainEmptyReading(on exchange: AppServerExchange) async {
        guard let account = try? await AccountMethods.readAccount(on: exchange) else {
            Self.logger.notice("Codex reported no usage windows")
            return
        }
        if let reason = account.limitsUnavailableReason {
            Self.logger.notice("Codex limits are unavailable: \(reason, privacy: .public)")
        } else {
            Self.logger.notice("Codex reported no usage windows for this account")
        }
    }

    private func knowsHasNoAccountAPI(_ version: CodexVersion) -> Bool {
        withoutAccountAPI.contains(version.raw)
    }

    private func noteNoAccountAPI(_ version: CodexVersion) {
        guard withoutAccountAPI.insert(version.raw).inserted else { return }
        Self.logger.notice(
            """
            codex \(version.raw, privacy: .public) does not implement the account API — \
            limits will stay unavailable until it is updated
            """)
    }

    /// One line per failure, and the reading is left alone.
    ///
    /// **The previous windows are not cleared.** A refresh that failed says
    /// nothing about the numbers it failed to fetch, and replacing a reading
    /// from ten minutes ago with an empty section would turn a transient
    /// hiccup into the interface claiming the data does not exist.
    private func report(_ error: AppServerError) {
        switch error {
        case .codexNotFound, .unimplemented:
            // Both are settled states rather than events. `unimplemented` is
            // logged once by `noteNoAccountAPI`; a missing binary is not news.
            break
        case .timedOut(let budget):
            Self.logger.error(
                "codex app-server was killed after \(budget, privacy: .public) without answering")
        default:
            Self.logger.error("limits could not be read: \(error, privacy: .public)")
        }
    }
}
