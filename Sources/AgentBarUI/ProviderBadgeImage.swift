import AgentBarCore
import AppKit
import SwiftUI

/// Renders the provider badge to a bitmap, for surfaces that cannot host a
/// SwiftUI view.
///
/// The notification attachment is the only one today. `UNNotificationAttachment`
/// takes a **file**, so the badge has to leave SwiftUI and land on disk before a
/// banner can show it — which is also why this returns an image rather than
/// writing one: where the file goes is the app assembly's business, not the
/// design system's.
///
/// > **Deviation from `docs/dev/design-spec.md` § Notifications.** The canvas
/// > specifies a Messages-style composite — a 38 pt provider avatar with a 16 pt
/// > AgentBar badge in its corner. On macOS the app's own icon already occupies
/// > the banner's leading slot and the attachment is rendered as a separate
/// > thumbnail beside it, so the corner badge would repeat the app icon three
/// > centimetres from itself. What the composite was for — "which agent is this
/// > from" — is carried by the provider tile alone. The spec's own instruction
/// > for this case is to match the intent, not the pixel.
public enum ProviderBadgeImage {
    /// The size the design specifies for the notification badge.
    public static let notificationSize: CGFloat = 38

    /// A rendered badge, or `nil` if the renderer produced nothing — in which
    /// case the notification names the provider in its title instead.
    ///
    /// Rendered at 2× so the thumbnail is not soft on a Retina display, and in
    /// the light appearance deliberately: a notification banner draws its own
    /// material and an attachment is not re-rendered when the system theme
    /// changes, so a dark-appearance badge would be wrong half the time. Both
    /// provider colours carry `onAccent` white glyphs and read correctly on
    /// either banner.
    @MainActor
    public static func png(for provider: Provider, size: CGFloat = notificationSize) -> Data? {
        let renderer = ImageRenderer(
            content:
                ProviderBadge(provider: provider, size: size)
                .environment(\.colorScheme, .light)
                .frame(width: size, height: size)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
