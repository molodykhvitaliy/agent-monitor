import AgentBarCore
import AppKit
import SwiftUI
import Testing

@testable import AgentBarUI

/// How big the settings window opens.
///
/// The defect these pin is a window **narrower than the form inside it**: 620 pt
/// of window around 710 pt of form, which SwiftUI resolves by drawing the form
/// at 710 anyway and letting 45 pt hang off each side, clipped, with no
/// horizontal scroller. The verb labels were the half that went.
@MainActor
@Suite("Settings window layout")
struct SettingsWindowLayoutTests {

    /// The ordinary case: a screen with room to spare gets the ideal size.
    @Test("A large screen opens the window at its ideal size")
    func roomToSpare() {
        let available = NSSize(width: 1680, height: 1000)
        #expect(SettingsWindowLayout.contentSize(fitting: available) == SettingsWindowLayout.ideal)
    }

    /// The defect, in one assertion: the window may never be taller than the
    /// space it has to open into.
    @Test("A short screen shrinks the window rather than running off it")
    func shorterThanTheIdeal() {
        let available = NSSize(width: 1470, height: 520)
        let size = SettingsWindowLayout.contentSize(fitting: available)
        #expect(size.height == 520)
        #expect(size.width == SettingsWindowLayout.ideal.width)
    }

    @Test("A narrow screen shrinks it across as well")
    func narrowerThanTheIdeal() {
        let size = SettingsWindowLayout.contentSize(fitting: NSSize(width: 640, height: 1000))
        #expect(size == NSSize(width: 640, height: SettingsWindowLayout.ideal.height))
    }

    /// The resize floor is a floor for the *user*, not a promise the window can
    /// keep on a screen that small: a minimum larger than the screen would put
    /// the window back off the edge by another route.
    @Test("The resize minimum never exceeds the screen either")
    func minimumYieldsToTheScreen() {
        let available = NSSize(width: 500, height: 300)
        let minimum = SettingsWindowLayout.minimumContentSize(fitting: available)
        #expect(minimum == available)
        // And it stays a minimum: it may not come out larger than the size the
        // window is about to open at.
        let size = SettingsWindowLayout.contentSize(fitting: available)
        #expect(minimum.width <= size.width)
        #expect(minimum.height <= size.height)
    }

    /// `swift test` has no screen, and neither has a window that has not been
    /// placed on one yet. Zero is "nothing said", not "no space".
    @Test("No screen at all is not a reason to open a window of no size")
    func noScreen() {
        #expect(SettingsWindowLayout.contentSize(fitting: .zero) == SettingsWindowLayout.ideal)
        #expect(
            SettingsWindowLayout.minimumContentSize(fitting: .zero)
                == SettingsWindowLayout.minimum)
    }

    /// The matrix is the widest thing in the window and it grew a second column
    /// in step 09. The documented 620 pt predates that column, and below the
    /// width two columns need there is no graceful failure — the form is drawn
    /// at its own width and the overhang is cut off. Counted from every
    /// provider the domain has, not from the two the app registers today.
    @Test("No width the window allows can clip the matrix at any provider count")
    func fitsEveryProvider() {
        let needed =
            NotificationMatrixView.minimumWidth(providers: Provider.allCases.count)
            + SettingsWindowLayout.formChromeWidth
        #expect(SettingsWindowLayout.minimum.width >= needed)
        #expect(SettingsWindowLayout.ideal.width >= SettingsWindowLayout.minimum.width)
    }
}

/// The defect itself: the form's own minimum width, against the window's.
///
/// Nothing in SwiftUI reports an overflow. A form whose content cannot fit is
/// laid out at the width it wants, centred, and the overhang is simply not
/// drawn — no exception, no horizontal scroller, no diagnostic anywhere. What
/// *is* observable is what the form says it needs: give the hosting controller
/// `.minSize` and it publishes the SwiftUI minimum onto `contentMinSize`. That
/// number is the one the window has to be able to satisfy, and on the original
/// layout it was 710 against a 620 pt window.
///
/// The question is asked synchronously — `NSHostingController.sizeThatFits(in:)`
/// with a one-point width proposal, which is SwiftUI answering "how narrow can
/// I be" directly. An earlier version observed the same number by turning the
/// run loop until the controller published `contentMinSize`, and that blocked
/// the main thread for half a second: under `swift test --parallel` it starved
/// the power module's timing tests, which is a suite failing for a reason that
/// has nothing to do with it.
///
/// > **What this suite does and does not pin, checked by mutation.** It fails
/// > when the window's minimum is decoupled from the matrix and hand-picked
/// > below it (`minimum = 560` → `638 <= 560` fails), and it fails when the
/// > matrix stops costing a column per provider (`two - one` drops from 188 to
/// > 42 the moment a provider's cells go missing). It does **not** catch every
/// > conceivable wide element: not everything inside a grouped `Form`
/// > propagates a minimum out to `contentMinSize`, and a `Picker` widened to
/// > 400 pt in the Quiet Hours section does not move the number at all. The
/// > matrix is the widest thing in this window and the part that is derived
/// > from, so it is the part that is pinned; anything else stays the render
/// > proof's job.
@MainActor
@Suite("Settings window content fits its window")
struct SettingsWindowSizingTests {

    /// Both providers, **with their cells**.
    ///
    /// Setting `providers` alone is not enough and is the trap this measurement
    /// fell into once already: `NotificationMatrixView.cell(provider:verb:)`
    /// renders nothing when the preferences have no cell for that pair, so a
    /// second provider without cells contributes a header and no controls — a
    /// column roughly 100 pt narrower than the real one, which is most of what
    /// this suite is measuring. `RenderProof.renderSettings` learned the same
    /// thing by rendering a header over empty space.
    private func model(
        providers: [Provider] = [.claudeCode, .codex], userSounds: [SoundChoice] = []
    ) -> SettingsModel {
        let services = StubSettingsServices()
        services.providers = providers
        services.userSoundChoices = userSounds
        services.stored = NotificationPreferences(
            cells: providers.flatMap { provider in
                NotificationVerb.allCases.map { verb in
                    NotificationCell(
                        provider: provider, verb: verb, isEnabled: true,
                        soundID: "AgentBar \(verb.title).aiff")
                }
            })
        return SettingsModel(services: services)
    }

    /// The narrowest the settings form can be drawn, as SwiftUI itself reports
    /// it. Measured through a window, because `contentMinSize` is where a
    /// hosting controller publishes it and there is no other way to ask.
    private func reportedMinimumWidth(providers: [Provider] = [.claudeCode, .codex]) -> CGFloat {
        minimumWidth(
            of: SettingsView(model: model(providers: providers))
                .environment(\.accessibilityPreferences, AccessibilityPreferences.shared))
    }

    /// A sound file name long enough to be a problem, if one could be.
    private static let longSoundName =
        "My Very Long Custom Notification Sound For Testing Purposes"

    /// The matrix on its own, without the form's floor under it.
    ///
    /// `SettingsView` carries `.frame(minWidth: SettingsWindowLayout.minimum.width)`,
    /// which is the right thing for the window and the wrong thing to measure a
    /// column with: it floors every reading at 638 and hides what the matrix
    /// itself asked for. To see a column appear, look at the matrix.
    private func matrixMinimumWidth(
        providers: [Provider], userSounds: [SoundChoice] = []
    ) -> CGFloat {
        minimumWidth(
            of: NotificationMatrixView(
                model: model(providers: providers, userSounds: userSounds)
            )
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared))
    }

    /// What SwiftUI says a view's narrowest drawable width is.
    ///
    /// A one-point width proposal with height to spare: `sizeThatFits(in:)`
    /// returns what the view would take, and no view returns less than its
    /// minimum. Synchronous, so there is no window, no run loop and nothing to
    /// wait for — and `measuresSomething` is what turns an answer of zero red
    /// if a future SwiftUI declines to answer at all.
    private func minimumWidth(of view: some View) -> CGFloat {
        NSHostingController(rootView: view)
            .sizeThatFits(in: NSSize(width: 1, height: 10_000)).width
    }

    /// The regression, in one line: no size the window can be put at is one the
    /// form cannot be drawn whole at.
    @Test("The form fits at every width the window allows")
    func fitsAtEveryAllowedWidth() {
        let needed = reportedMinimumWidth()
        #expect(needed <= SettingsWindowLayout.minimum.width)
        #expect(needed <= SettingsWindowLayout.ideal.width)
    }

    /// The measurement has to be a measurement.
    ///
    /// `sizeThatFits(in:)` answers with a size whatever it is given, including
    /// a zero one — an empty view, a hosting controller that declines to
    /// measure, a future SwiftUI that treats a one-point proposal differently.
    /// Any of those makes the assertion above read `0 <= 638` and pass while
    /// observing nothing at all. That is the one way this suite can stop
    /// guarding the defect without anybody noticing, so the floor is asserted
    /// rather than assumed.
    @Test("Something was actually measured")
    func measuresSomething() {
        // Paired with the assertion above, this pins the reading to exactly the
        // window's minimum: the form asks for no more than the window allows,
        // and no less than the floor it was given. Zero — the value
        // `contentMinSize` holds when nothing published — fails here.
        #expect(reportedMinimumWidth() >= SettingsWindowLayout.minimum.width)
    }

    /// A long name is the one input to this layout whose length AgentBar does
    /// not control: it comes from the user's own `~/Library/Sounds`. Every
    /// width here is derived from constants, and a pop-up that grew to fit its
    /// longest item would put the matrix back over the window the moment
    /// somebody imported `My Very Long Custom Notification Sound.aiff`.
    /// Measured rather than assumed — the pop-up truncates.
    @Test("A long sound name does not widen the matrix")
    func longSoundNameChangesNothing() {
        let plain = matrixMinimumWidth(providers: [.claudeCode, .codex])
        let long = matrixMinimumWidth(
            providers: [.claudeCode, .codex],
            userSounds: [
                SoundChoice(
                    id: "long.aiff", name: Self.longSoundName, group: .user, isPlayable: true)
            ])
        #expect(long == plain)
    }

    /// And the thing being measured has to be the matrix the app builds.
    ///
    /// A second provider whose cells went missing still renders its header, so
    /// a two-column matrix with no cells looks like a matrix. What it cannot do
    /// is cost a whole column's floor more than a one-column matrix — which is
    /// also the number `SettingsWindowLayout.minimum` is derived from, so this
    /// is the join between the two halves of the fix.
    @Test("Each provider costs a column")
    func countsEveryColumn() {
        let one = matrixMinimumWidth(providers: [.claudeCode])
        let two = matrixMinimumWidth(providers: [.claudeCode, .codex])
        #expect(
            two - one
                >= NotificationMatrixView.cellMinimumWidth + NotificationMatrixView.columnSpacing)
    }

}

/// The screen arithmetic, against screens this machine has not got.
///
/// Every one of these is a display the window has to survive and none of them
/// can be produced on demand: the undocked laptop, the short screen under a tall
/// Dock, and the window that has not been placed on any screen yet. Pure
/// functions, so they need no window server and no display at all.
@MainActor
@Suite("Settings window against a screen")
struct SettingsWindowScreenTests {

    /// A 14-inch display with the menu bar and Dock taken out, less an ordinary
    /// title bar.
    private let laptop = SettingsWindowLayout.available(
        visibleFrame: NSSize(width: 1512, height: 891), chrome: NSSize(width: 0, height: 32))

    @Test("Chrome comes out of the room the window has, never out of the screen")
    func chromeIsSubtracted() {
        #expect(laptop == NSSize(width: 1512, height: 859))
    }

    /// A screen smaller than the window wants in *either* direction: neither is
    /// allowed to win on its own.
    @Test("A screen with less room than the window wants shrinks it, in both axes")
    func shrinksToTheScreen() {
        let cramped = SettingsWindowLayout.available(
            visibleFrame: NSSize(width: 600, height: 500), chrome: NSSize(width: 0, height: 32))
        let chosen = SettingsWindowLayout.contentSize(fitting: cramped)
        #expect(chosen.width == 600)
        #expect(chosen.height == 468)
        // And the resize floor yields too, or the window would be dragged back
        // off the screen through the one door left open.
        let floor = SettingsWindowLayout.minimumContentSize(fitting: cramped)
        #expect(floor.width <= chosen.width)
        #expect(floor.height <= chosen.height)
    }

    /// A visible frame smaller than the chrome is not a negative window.
    @Test("A screen with no room at all is zero, never negative")
    func neverNegative() {
        let none = SettingsWindowLayout.available(
            visibleFrame: NSSize(width: 10, height: 10), chrome: NSSize(width: 0, height: 32))
        #expect(none == NSSize(width: 10, height: 0))
        // Zero means "nothing said", so the window still opens at its ideal
        // height rather than at nothing.
        #expect(
            SettingsWindowLayout.contentSize(fitting: none).height
                == SettingsWindowLayout.ideal.height)
    }

    /// Reopening keeps the size the user chose.
    @Test("A window that still fits is left exactly as the user left it")
    func leavesAFittingWindowAlone() {
        #expect(SettingsWindowLayout.shrink(NSSize(width: 900, height: 800), toFit: laptop) == nil)
        #expect(SettingsWindowLayout.shrink(SettingsWindowLayout.minimum, toFit: laptop) == nil)
    }

    /// The undock: the window was sized on a large display and is reopened on a
    /// small one. It may not come back larger than the screen it is now on.
    @Test("A window larger than its new screen is shrunk to fit it")
    func shrinksOnUndock() throws {
        let small = SettingsWindowLayout.available(
            visibleFrame: NSSize(width: 1280, height: 600), chrome: NSSize(width: 0, height: 32))
        let shrunk = try #require(
            SettingsWindowLayout.shrink(NSSize(width: 1400, height: 1200), toFit: small))
        #expect(shrunk.width <= small.width)
        #expect(shrunk.height <= small.height)
    }

    /// One axis over is enough to act, and the axis that still fits is not
    /// disturbed while acting.
    @Test("Only the axis that overflows is changed")
    func shrinksOneAxis() throws {
        let short = SettingsWindowLayout.available(
            visibleFrame: NSSize(width: 1512, height: 500), chrome: NSSize(width: 0, height: 32))
        let shrunk = try #require(
            SettingsWindowLayout.shrink(NSSize(width: 700, height: 900), toFit: short))
        #expect(shrunk.width == 700)
        #expect(shrunk.height == 468)
    }
}
