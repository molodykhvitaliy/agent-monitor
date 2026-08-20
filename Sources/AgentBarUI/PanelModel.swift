import AgentBarCore
import Observation
import SwiftUI

/// Everything the panel needs from the app that assembled it.
///
/// A seam rather than a set of imports: `AgentBarUI` may reach only
/// `AgentBarCore`, so the store, the endpoint and every installer arrive through
/// this protocol, implemented in `Apps/AgentBar` where all of them are already
/// linked.
@MainActor
public protocol PanelServices: AnyObject {
    /// An immutable reading of the store.
    func snapshot() async -> StoreSnapshot
    /// Applies the watchdog: retires sessions whose agents have gone. Nothing
    /// else does, and `unknown` needs no sweep — it is derived on read.
    func sweep() async
    /// Reads every registered provider's install report.
    ///
    /// Disk I/O, so this is called on panel open and after an action — never on
    /// a timer.
    func integrationStatuses() async -> [IntegrationStatus]
    /// Performs a card action and says what it left behind.
    func perform(
        _ action: IntegrationAction, for provider: Provider
    ) async -> IntegrationActionResult
    /// Subscription usage windows, as the provider last reported them.
    ///
    /// A property read behind an actor hop and **never** a fetch, which is why
    /// the panel can ask for it on its open clock: whoever implements this
    /// refreshes on a schedule of their own. Empty is not an error and gets no
    /// error styling.
    func usageWindows() async -> [UsageWindow]

    /// Says that the user is looking at the panel, so whoever owns the reading
    /// can decide whether to take a fresh one.
    ///
    /// A *request*, not a fetch: it returns immediately and never waits for a
    /// reading, because the panel's clock runs once a second and a reading costs
    /// a child process. Throttling is the implementer's to do — the panel knows
    /// that somebody is watching and nothing about what that is worth.
    func requestUsageRefresh()

    /// The Caffeine indicator's state.
    ///
    /// Synchronous and cheap — a property read on the main actor, never I/O —
    /// because the footer redraws with every panel refresh. Reading it inside a
    /// view body is also what keeps it live without a clock of its own: the
    /// assembly's implementation reaches through to an observable controller, so
    /// SwiftUI re-renders when the assertion changes.
    func caffeine() -> CaffeineIndicator

    /// The footer button: turns Caffeine off, or back on to the mode the
    /// settings window last chose.
    func toggleCaffeine()
}

extension PanelServices {
    public func usageWindows() async -> [UsageWindow] { [] }
    /// A panel with no quota behind it has nothing to ask for.
    public func requestUsageRefresh() {}
}

/// The panel's state, refreshed from the store and from disk on different
/// schedules because the two cost different things.
///
/// Holds the snapshot **and** an integration status per provider. Neither alone
/// decides whether the panel shows the list, *All quiet* or the onboarding card.
@Observable
@MainActor
public final class PanelModel {
    public private(set) var snapshot: StoreSnapshot
    public private(set) var integrations: [IntegrationStatus] = []
    public private(set) var usage: [UsageWindow] = []
    /// What the last action on a provider's row left behind, shown as a
    /// transient second line until the next refresh replaces it.
    public private(set) var actionResults: [Provider: IntegrationActionResult] = [:]
    /// Whether an action is in flight, so its button can be disabled rather
    /// than pressed twice.
    public private(set) var busy: Set<Provider> = []
    /// Set when the footer status is pressed: the card in place of the list,
    /// reachable at any time and not only on first run.
    public var showsIntegrationCard = false

    @ObservationIgnored private let services: any PanelServices

    public init(services: any PanelServices, snapshot: StoreSnapshot = StoreSnapshot.empty) {
        self.services = services
        self.snapshot = snapshot
    }

    /// The list, *All quiet*, or the onboarding card — unless the user asked for
    /// the card, which overrides everything because they asked.
    public var content: PanelContent {
        guard !showsIntegrationCard else { return .onboarding }
        return PanelContent.decide(snapshot: snapshot, integrations: integrations)
    }

    public var footer: FooterStatus { FooterStatus.summarise(integrations) }

    /// The header's urgency pill, or `nil` when there is nothing urgent.
    ///
    /// The header says how many sessions need a human; the footer says whether
    /// the plumbing is healthy. Two summaries from two different sources, and
    /// neither is derived from the other.
    public var headerSummary: PanelHeaderSummary? {
        PanelHeaderSummary.summarise(snapshot)
    }

    /// Whether the panel wears its waiting wash.
    ///
    /// A `Bool` rather than a count, because that is the whole of what the wash
    /// needs and a count would invalidate the panel every time a second session
    /// started waiting for the same reason.
    public var isAnyoneWaiting: Bool { snapshot.waitingSessionCount > 0 }

    /// Computed rather than stored on purpose. The value comes from an
    /// observable object the assembly owns, so reading it here — inside the
    /// view body that renders it — is what makes the footer indicator live. A
    /// stored copy would need a clock of its own and would lag every change by
    /// up to a refresh.
    public var caffeine: CaffeineIndicator { services.caffeine() }

    public func toggleCaffeine() { services.toggleCaffeine() }

    /// One computed labelling for the whole snapshot, so the header, the
    /// tooltip and the accessibility label cannot disagree.
    public var labels: ProjectLabels {
        ProjectLabels(projects: snapshot.projects.map(\.project))
    }

    /// Re-reads the store. Cheap — an actor hop and a value copy — which is why
    /// it can run once a second while the panel is open.
    ///
    /// **Published only when the rendered part changed, and `@Observable` cannot
    /// work that out by itself here.** Observation already suppresses an
    /// assignment whose value is equal, so most of this model needs no help. A
    /// `StoreSnapshot` is the exception: `takenAt` is a fresh `Date` on every
    /// read, so no two readings are ever equal, and every one of them would
    /// invalidate the whole panel — sixty rebuilds a minute of every row, every
    /// localised string and every date format, to draw the same pixels. With
    /// nothing running, this guard is what takes the idle view-graph traffic to
    /// zero.
    ///
    /// **The comparison is `projects`, and that is now an invariant.** `takenAt`
    /// and the hundred-entry `finished` history are not rendered anywhere; a
    /// surface that ever *does* render one of them has to widen this comparison
    /// to match, or it will show a value from the last time the rows happened to
    /// change.
    public func refreshSnapshot() async {
        let reading = await services.snapshot()
        guard reading.projects != snapshot.projects else { return }
        snapshot = reading
    }

    /// The closed-panel tick: retire what the watchdog has given up on, then
    /// re-read.
    public func sweepAndRefresh() async {
        await services.sweep()
        await self.refreshSnapshot()
    }

    /// Re-reads every provider's report and the usage windows.
    ///
    /// Called on panel open, after any install action, and after a successful
    /// endpoint start — the moments at which a report can have changed. Never
    /// on a timer: it touches the disk.
    public func refreshIntegrations() async {
        // Clearing here is what makes the action lines transient. They are news
        // for a moment and noise thereafter, and a report that has just been
        // re-read already says whatever the action left behind — a
        // `Nothing to change` still pinned under a healthy row tomorrow would be
        // worse than never having shown it.
        actionResults.removeAll()
        integrations = await services.integrationStatuses()
        await refreshUsage()
    }

    /// Re-reads the usage windows alone.
    ///
    /// Separate from `refreshIntegrations` because it costs an actor hop rather
    /// than a disk read, so the open panel can run it on its one-second clock —
    /// otherwise a refresh landing while the panel is open would not appear
    /// until it was closed and opened again.
    /// No guard here, unlike `refreshSnapshot`: `[UsageWindow]` is `Equatable`
    /// and Observation suppresses an equal assignment by itself, so the windows
    /// this re-reads on the open panel's one-second clock publish only when they
    /// actually move — which is at most once every ten minutes.
    public func refreshUsage() async {
        usage = await services.usageWindows()
    }

    /// Asks for a fresh reading and then shows whatever is there now.
    ///
    /// The two halves are deliberately not the same reading: the request is for
    /// the *next* one and lands seconds later, while the display is of the last
    /// one to have landed. Anything else would make the open panel wait on a
    /// child process once a second.
    public func watchUsage() async {
        services.requestUsageRefresh()
        await refreshUsage()
    }

    /// Runs a card action and folds its result back into the row.
    ///
    /// The result survives only until the next refresh, which is the point: a
    /// `Nothing to change` is news for a moment and noise thereafter.
    public func perform(_ action: IntegrationAction, for provider: Provider) async {
        guard busy.insert(provider).inserted else { return }
        defer { busy.remove(provider) }
        let result = await services.perform(action, for: provider)
        // The report is re-read whatever happened: a failed write can still have
        // changed what the file says about itself.
        await refreshIntegrations()
        actionResults[provider] = result
    }

    /// What the row shows under its status line after an action.
    public func resultLine(for provider: Provider) -> (text: String, isFault: Bool)? {
        switch actionResults[provider] {
        case .unchanged:
            (
                String(
                    localized: "Nothing to change",
                    comment: "Shown after an install action that wrote nothing"), false
            )
        case .failed(let reason):
            (reason, true)
        case .changed, .acknowledged, nil:
            nil
        }
    }
}

extension StoreSnapshot {
    /// A reading of nothing, for the moment before the first refresh lands.
    public static var empty: StoreSnapshot {
        StoreSnapshot(takenAt: .distantPast, projects: [])
    }
}
