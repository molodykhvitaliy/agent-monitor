import AgentBarCore
import AppKit
import SwiftUI

/// Every colour the panel may use, by the name the design system gives it.
///
/// The values are `docs/dev/design-system.md` § Colour, transcribed once here.
/// Two rules from that document hold: a colour a view needs that is not in this
/// enum is a change to the token set, and colour never carries state on its own
/// — every accent is paired with a shape and a label.
///
/// > **Why not an asset catalog.** The design system's implementation note asks
/// > for one, and it does not survive contact with the build: SwiftPM copies an
/// > `.xcassets` into a resource bundle **without running `actool`**, so
/// > `NSColor(named:bundle:)` finds nothing under `swift test` and the tokens
/// > would resolve only in an Xcode build. ADR-0003 puts the logic in SPM
/// > modules precisely so the suite runs without Xcode, so the catalog loses.
/// > Everything it was for is kept: one place per token, a light and a dark
/// > value, and a test that walks every case.
///
/// The alpha-based dark values (`hairline`, `divider`, `fillQuiet`, `ringQuiet`,
/// `meterTrack`, `hoverOverlay`) are white or ink at a stated percentage rather
/// than a solid neutral, because they sit on glass whose backdrop is whatever is
/// behind the panel — a solid would band against it.
nonisolated public enum ColorToken: String, CaseIterable, Sendable {
    case canvas
    case surface
    case hairline
    case divider
    case fillQuiet
    case ringQuiet
    case ink900
    case ink600
    case ink400
    case stateWorking
    case stateWaiting
    case stateFailed
    case stateUnknown
    case onAccent
    case providerClaudeCode
    case providerCodex
    case connected
    case meterTrack
    case meterFill
    case hoverOverlay

    public var color: Color { Color(nsColor: nsColor) }

    /// A dynamic colour, so the panel follows a theme change while it is open
    /// without anything having to redraw deliberately.
    public var nsColor: NSColor { ColorToken.dynamic[self] ?? .magenta }

    /// The light and dark value of every token.
    ///
    /// `stateWorking` light and `stateUnknown` dark each sit one unit off their
    /// OKLCH conversion: these are the values `docs/dev/assets/logo-mark.svg`
    /// already ships, and a mark and a state dot meant to be the same blue have
    /// to be the same blue.
    ///
    /// `ringQuiet` light and `providerCodex` dark are the same hex. That is a
    /// coincidence of value, not of role; they are not merged.
    static let values: [ColorToken: (light: NSColor, dark: NSColor)] = [
        .canvas: (srgb(0xF5_F7_F9), srgb(0x12_14_16)),
        .surface: (srgb(0xFF_FF_FF), srgb(0x21_24_28)),
        .hairline: (srgb(0xDB_DE_E2), white(0.09)),
        .divider: (srgb(0xE2_E5_E8), white(0.08)),
        .fillQuiet: (srgb(0xE8_EB_EF), white(0.10)),
        .ringQuiet: (srgb(0xCB_CE_D2), white(0.16)),
        .ink900: (srgb(0x12_17_1B), srgb(0xF0_F2_F4)),
        .ink600: (srgb(0x54_59_5E), srgb(0xB4_B8_BB)),
        .ink400: (srgb(0x85_8A_8F), srgb(0x71_75_79)),
        .stateWorking: (srgb(0x40_7C_C5), srgb(0x6A_A7_F4)),
        .stateWaiting: (srgb(0xDA_95_0B), srgb(0xE8_AB_3E)),
        .stateFailed: (srgb(0xCF_40_40), srgb(0xEF_66_61)),
        .stateUnknown: (srgb(0x8C_69_A7), srgb(0xB1_8D_CD)),
        .onAccent: (srgb(0xFF_FF_FF), srgb(0x0A_0E_11)),
        .providerClaudeCode: (srgb(0xC1_6D_45), srgb(0xE1_8C_5F)),
        .providerCodex: (srgb(0x29_2E_34), srgb(0xCB_CE_D2)),
        .connected: (srgb(0x3B_95_55), srgb(0x53_BE_70)),
        .meterTrack: (srgb(0xDB_DE_E2), white(0.10)),
        .meterFill: (srgb(0x29_2E_34), srgb(0xCB_CE_D2)),
        .hoverOverlay: (srgb(0x12_17_1B, alpha: 0.06), white(0.08)),
    ]

    /// Built once, and shared. A dynamic colour is immutable after construction
    /// and resolves against whatever appearance is current on the calling
    /// thread, which is exactly what a token needs.
    private static let dynamic: [ColorToken: NSColor] =
        values.mapValues { pair in
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? pair.dark : pair.light
            }
        }

    private static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    private static func white(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }
}

/// The two gradient stops the notification attachment art is built from.
///
/// **No new base token.** Each pair is one existing `ColorToken`'s *light*
/// value moved ±12 % in OKLCH lightness, hue and chroma untouched — so an event
/// square, the row tint for the state it announces, and the settings matrix's
/// indicator are all visibly the same colour. The rule is written down here
/// rather than left in a design document because it is what makes these
/// regenerable: move a base token and these four pairs move with it, by
/// applying that one transformation again.
///
/// > **Both stops are derived from the light appearance, and that is not an
/// > oversight.** An attachment is a file the notification centre copies into
/// > its own store; it is not re-rendered when the system theme changes, so a
/// > dark-appearance square would be wrong half the time. White figures on
/// > these gradients read correctly on a light banner and on a dark one.
nonisolated public struct AttachmentRamp: Sendable, Hashable {
    /// The token these stops were derived from.
    public let base: ColorToken
    /// The 155° gradient's first stop — the base at +12 % OKLCH lightness.
    public let start: NSColor
    /// Its last stop — the base at −12 %.
    public let end: NSColor

    /// The ramp for a notification verb.
    ///
    /// > **Four, not five.** The handoff also specifies an `Unknown` square,
    /// > "for completeness". `NotificationPolicy.classify` returns `nil` for
    /// > `unknown` and that stays true — the absence of information is not worth
    /// > an interruption — so a fifth ramp would be a colour pair nothing can
    /// > ever ask for. The row tint and the menu-bar glyph carry `unknown`,
    /// > which is where a user actually meets it.
    public static func ramp(for verb: NotificationVerb) -> AttachmentRamp {
        switch verb {
        case .question:
            AttachmentRamp(base: .stateWaiting, start: srgb(0xEF_AF_2E), end: srgb(0xA8_70_0A))
        case .failed:
            AttachmentRamp(base: .stateFailed, start: srgb(0xE3_5C_5C), end: srgb(0x9E_2C_2C))
        case .finished:
            AttachmentRamp(base: .connected, start: srgb(0x52_B3_6E), end: srgb(0x2A_6E_3E))
        case .waiting:
            AttachmentRamp(base: .stateWorking, start: srgb(0x5E_9B_DE), end: srgb(0x2E_5D_97))
        }
    }

    /// What an indicator beside this event should take, so the settings matrix
    /// and the banner agree about what colour an event is.
    public var accent: Color { base.color }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension ShapeStyle where Self == Color {
    /// `.token(.ink600)` at a use site, so a view never spells a colour name
    /// twice.
    nonisolated public static func token(_ token: ColorToken) -> Color { token.color }
}

nonisolated extension SessionStateKind {
    /// The accent for this state, or `nil` for `idle` — which has none on
    /// purpose: it is the resting state and must not draw the eye.
    public var accent: ColorToken? {
        switch self {
        case .working: .stateWorking
        case .waiting: .stateWaiting
        case .failed: .stateFailed
        case .unknown: .stateUnknown
        case .idle: nil
        }
    }

    /// What the row's state label reads. Five words and no sixth.
    ///
    /// Resolved once per process rather than per row per frame. Every open panel
    /// rebuilds every row on its one-second clock, and each rebuild asked
    /// Foundation to look this string up in the bundle again — five constants
    /// that cannot change while the app is running, because macOS relaunches an
    /// app when its language changes.
    public var label: String { SessionStateKind.labels[self] ?? rawValue }

    private static let labels: [SessionStateKind: String] = [
        .idle: String(localized: "Idle", comment: "Session state"),
        .working: String(localized: "Working", comment: "Session state"),
        .waiting: String(localized: "Waiting", comment: "Session state"),
        .failed: String(localized: "Failed", comment: "Session state"),
        .unknown: String(localized: "Unknown", comment: "Session state"),
    ]

    /// The full-row wash a row of this state takes, as an opacity on `accent`.
    ///
    /// `working` and `idle` take none. The values rise under Increase Contrast
    /// rather than disappearing: the tint is half of how a waiting row is
    /// recognised, so removing it would cost more than it gained.
    public func tintOpacity(dark: Bool, increasedContrast: Bool) -> Double? {
        switch (self, dark, increasedContrast) {
        case (.waiting, false, false): 0.10
        case (.waiting, false, true): 0.16
        case (.waiting, true, false): 0.16
        case (.waiting, true, true): 0.24
        case (.failed, false, false): 0.07
        case (.failed, false, true): 0.12
        case (.failed, true, false): 0.14
        case (.failed, true, true): 0.20
        case (.unknown, false, false): 0.08
        case (.unknown, false, true): 0.12
        // The one figure in the design system that was designed rather than
        // extracted: the canvas never draws an unknown row in dark.
        case (.unknown, true, false): 0.12
        case (.unknown, true, true): 0.18
        default: nil
        }
    }
}

nonisolated extension Provider {
    /// The badge fill. The glyph on top is always `onAccent` — one rule, not a
    /// per-provider decision.
    public var badgeColor: ColorToken {
        switch self {
        case .claudeCode: .providerClaudeCode
        case .codex: .providerCodex
        }
    }
}
