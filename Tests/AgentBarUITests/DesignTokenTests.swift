import AgentBarCore
import AppKit
import Testing

@testable import AgentBarUI

/// The token set is only real if every case has a value. A token with none
/// resolves to a loud magenta at runtime, which is visible to whoever opens the
/// panel and to nobody else — so it is checked here instead.
@MainActor
@Suite("Design tokens")
struct DesignTokenTests {

    @Test("Every token has a value")
    func everyTokenResolves() {
        for token in ColorToken.allCases {
            #expect(
                ColorToken.values[token] != nil,
                "\(token.rawValue) has no entry in the token table")
            #expect(token.nsColor != NSColor.magenta, "\(token.rawValue) fell back")
        }
    }

    /// Twenty, per `docs/dev/design-system.md` § How this reaches the code.
    /// `stateIdle` and `focusRing` are deliberately not among them: idle borrows
    /// `ink400` and the focus ring is the system accent, which is the user's
    /// choice and not ours.
    @Test("The catalog holds exactly the tokens the design system names")
    func tokenCountMatchesTheDesignSystem() {
        #expect(ColorToken.allCases.count == 20)
    }

    @Test("Every token has a distinct light and dark value")
    func lightAndDarkDiffer() {
        for token in ColorToken.allCases {
            let light = token.nsColor.resolved(dark: false)
            let dark = token.nsColor.resolved(dark: true)
            #expect(light != dark, "\(token.rawValue) does not change between appearances")
        }
    }

    /// Idle is the resting state and must not draw the eye, so it is the one
    /// state with no accent of its own.
    @Test("Only idle has no accent")
    func idleHasNoAccent() {
        #expect(SessionStateKindAccents.withoutAccent == [.idle])
    }

    /// A `working` or `idle` row takes no wash. Everything else does, in both
    /// appearances and at both contrast settings — a tint that vanished under
    /// Increase Contrast would remove half of how a waiting row is recognised.
    @Test("Row tints exist for exactly the three states that take one")
    func rowTints() {
        for dark in [false, true] {
            for contrast in [false, true] {
                #expect(
                    SessionStateKind.allCases.filter {
                        $0.tintOpacity(dark: dark, increasedContrast: contrast) != nil
                    } == [.waiting, .failed, .unknown])
            }
        }
    }

    @Test("Increase Contrast raises every tint rather than removing it")
    func contrastRaisesTints() {
        for kind in [SessionStateKind.waiting, .failed, .unknown] {
            for dark in [false, true] {
                let plain = kind.tintOpacity(dark: dark, increasedContrast: false) ?? 0
                let raised = kind.tintOpacity(dark: dark, increasedContrast: true) ?? 0
                #expect(raised > plain, "\(kind) at dark=\(dark)")
            }
        }
    }
}

/// Motion is a token set like colour is, for the same reason: a duration spelled
/// in a view is a duration that drifts from the one beside it.
@MainActor
@Suite("Motion tokens")
struct MotionTokenTests {

    /// Every prohibition in the design's motion rules, as a bound on the tokens
    /// rather than as a paragraph nobody re-reads.
    @Test("No token breaks the motion rules")
    func tokensObeyTheRules() {
        let decorative: [Duration] = [
            DesignTokens.Motion.rise,
            DesignTokens.Motion.stateInto,
            DesignTokens.Motion.stateBack,
            DesignTokens.Motion.micro,
            DesignTokens.Motion.crossFade,
        ]
        for duration in decorative {
            #expect(duration.seconds > 0)
            // "Nothing decorative longer than 400 ms."
            #expect(duration.seconds <= 0.4)
        }

        let cycles: [Duration] = [
            DesignTokens.Motion.waitingPulse,
            DesignTokens.Motion.workingChase,
            DesignTokens.Motion.hairlineSweep,
            DesignTokens.Motion.meterSweep,
            DesignTokens.Motion.dashCrawl,
            DesignTokens.Motion.breathe,
        ]
        for cycle in cycles {
            // "No flashing faster than 2 Hz" — with a wide margin, because these
            // are cycles a user sees out of the corner of an eye all day.
            #expect(cycle.seconds >= 1)
        }
    }

    /// The Reduce Motion substitute is deliberately the same 150 ms the row
    /// animation already uses, so a cross-fade is one duration in the app rather
    /// than two that nearly agree.
    @Test("The cross-fade matches the existing row animation")
    func crossFadeMatchesRows() {
        #expect(DesignTokens.Motion.crossFade.seconds == 0.15)
    }

    @Test("Durations convert to seconds exactly")
    func durationConversion() {
        #expect(Duration.milliseconds(600).seconds == 0.6)
        #expect(Duration.seconds(2).seconds == 2)
        #expect(Duration.milliseconds(0).seconds == 0)
    }

    /// The curves have to actually curve: a bezier typed in wrongly still
    /// compiles and still animates, just linearly.
    @Test("Every curve is a curve")
    func curvesAreCurves() {
        for curve in [
            DesignTokens.Motion.entrance, DesignTokens.Motion.settle, DesignTokens.Motion.pulse,
        ] {
            #expect(curve.value(at: 0) == 0)
            #expect(curve.value(at: 1) == 1)
            // Every one of these front-loads: half the travel is done well
            // before half the time.
            #expect(curve.value(at: 0.5) > 0.5)
        }
    }

    /// Under Reduce Motion an entrance is a cross-fade and a cycle does not run
    /// at all — the rule lives here so no view has to remember it.
    @Test("Reduce Motion answers both helpers")
    func reduceMotionHelpers() {
        let preferences = AccessibilityPreferences.shared
        // Whatever the machine running the suite is set to, the two helpers must
        // agree with each other rather than with a constant.
        #expect(preferences.runsCyclicalMotion == !preferences.reduceMotion)
        #expect(
            (preferences.rowAnimation == nil) == preferences.reduceMotion,
            "the two motion rules disagree about the same setting")
    }
}

enum SessionStateKindAccents {
    static var withoutAccent: [SessionStateKind] {
        SessionStateKind.allCases.filter { $0.accent == nil }
    }
}

extension NSColor {
    /// The value this dynamic colour takes in one appearance.
    func resolved(dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var resolved = self
        appearance?.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
    }
}
