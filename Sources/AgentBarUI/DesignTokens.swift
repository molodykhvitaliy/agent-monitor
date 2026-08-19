import SwiftUI

/// The design system, as the views consume it.
///
/// Every number a view draws with comes from here, and every colour comes from
/// `ColorToken` — the two rules `docs/dev/design-system.md` closes with. A view
/// that needs a value not in this file changes this file; it does not spell a
/// literal.
///
/// The measurements are the ones the panel was drawn and reviewed at, several
/// of which sit off the 4-point spacing scale on purpose (9 pt row padding,
/// 3 pt line gaps, 6 pt shape gaps). They are normative — see
/// `docs/dev/design-spec.md`.
nonisolated public enum DesignTokens {

    /// The general scale. New layout uses it; the panel's own measurements
    /// below are what was designed and win where they differ.
    public enum Space {
        public static let tiny: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 20
        public static let xxLarge: CGFloat = 24
    }

    public enum Radius {
        public static let iconButton: CGFloat = 6
        public static let compactButton: CGFloat = 7
        public static let button: CGFloat = 8
        public static let row: CGFloat = 10
        public static let card: CGFloat = 12
        public static let panel: CGFloat = 18
    }

    /// The panel's fixed width. 380 CSS pixels on the canvas, 380 points here —
    /// the design system reads the two one for one.
    public static let panelWidth: CGFloat = 380

    /// How tall the scrolling session list may grow before it scrolls. The
    /// footer and the Limits section never scroll.
    public static let listMaximumHeight: CGFloat = 340

    /// The fade hinting at rows below the cut. A mask, never an overlay: on
    /// glass there is no colour to fade to.
    public static let listFadeHeight: CGFloat = 36

    public enum Row {
        public static let verticalPadding: CGFloat = 9
        public static let horizontalPadding: CGFloat = 4
        /// Provider badge to the text column.
        public static let badgeGap: CGFloat = 10
        /// State shape to its label.
        public static let shapeGap: CGFloat = 6
        /// Top line to the detail line.
        public static let detailGap: CGFloat = 3
        public static let badgeSize: CGFloat = 26
        public static let badgeRadius: CGFloat = 7
        /// Focus ring width, inset on the row bounds.
        public static let focusRingWidth: CGFloat = 2
    }

    public enum Group {
        public static let topPadding: CGFloat = 12
        public static let sidePadding: CGFloat = 16
        public static let bottomPadding: CGFloat = 8
        public static let headerBottomMargin: CGFloat = 6
        /// Folder glyph to the project name.
        public static let glyphGap: CGFloat = 6
        public static let dividerInset: CGFloat = 16
        public static let dividerMargin: CGFloat = 6
    }

    public enum Limits {
        public static let sidePadding: CGFloat = 16
        public static let bottomPadding: CGFloat = 10
        public static let labelMargin: CGFloat = 8
        public static let bucketSpacing: CGFloat = 10
        public static let barHeight: CGFloat = 4
        public static let barSpacing: CGFloat = 4
        public static let infoGlyphSize: CGFloat = 13
        public static let infoGlyphGap: CGFloat = 8
        /// The Claude Code caveat row is the quietest thing in the panel.
        public static let caveatOpacity: Double = 0.7
    }

    public enum Footer {
        public static let verticalPadding: CGFloat = 9
        public static let horizontalPadding: CGFloat = 16
        /// The indicator's bounding box. The state shapes are scaled into it.
        public static let indicatorSize: CGFloat = 6
        public static let indicatorGap: CGFloat = 6
        public static let buttonSize: CGFloat = 22
        public static let buttonSpacing: CGFloat = 2
    }

    public enum Card {
        public static let topPadding: CGFloat = 20
        public static let sidePadding: CGFloat = 18
        public static let bottomPadding: CGFloat = 6
        public static let rowVerticalPadding: CGFloat = 10
        public static let buttonVerticalPadding: CGFloat = 6
        public static let buttonHorizontalPadding: CGFloat = 12
    }

    public enum Empty {
        public static let topPadding: CGFloat = 44
        public static let sidePadding: CGFloat = 24
        public static let bottomPadding: CGFloat = 36
        public static let outerRing: CGFloat = 40
        public static let innerRing: CGFloat = 22
        public static let ringStroke: CGFloat = 1.6
        public static let ringsToText: CGFloat = 16
    }

    /// Type roles. System font throughout — no bundled face. Named `Text`
    /// rather than `Type`, which Swift reserves for `foo.Type`.
    ///
    /// 13 and 11 are AppKit's own `controlContentFontSize` and
    /// `smallSystemFontSize`, so the panel matches every system control it sits
    /// beside; they are also the design system's declared scale, and 11 is its
    /// accessibility floor. The canvas renders a step tighter and loses to both.
    public enum Text {
        public static let panelTitle = Font.system(size: 17, weight: .semibold)
        public static let rowTitle = Font.system(size: 13, weight: .medium)
        public static let body = Font.system(size: 13)
        public static let buttonLabel = Font.system(size: 13, weight: .medium)
        public static let sectionLabel = Font.system(size: 11, weight: .semibold)
        public static let caption = Font.system(size: 11)
        public static let mono = Font.system(size: 12, design: .monospaced)

        /// Tracking for the uppercase section label, in points at 11 pt.
        public static let sectionLabelTracking: CGFloat = 11 * 0.06
    }

    /// The separator between a state and its context, from one constant so it
    /// cannot drift into a hyphen somewhere.
    public static let separator = " · "
}
