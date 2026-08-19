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
