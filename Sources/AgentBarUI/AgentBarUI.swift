// AgentBarUI
//
// SwiftUI views, view models and the AppKit shell that hosts them. Views
// consume immutable snapshots from AgentBarCore; no view reaches into the
// store's mutable state or into an adapter.
//
// The module opts into MainActor as its default isolation in Package.swift.
//
// Its only permitted intra-package import is AgentBarCore, which is why the
// install status the panel renders is a UI-owned value type (`IntegrationStatus`)
// populated by the app target rather than a provider's own report. The colour
// tokens live in `ColorToken`, in code and not in an asset catalog — SwiftPM
// copies an `.xcassets` without running `actool`, so a catalog would resolve
// only under an Xcode build.
//
// Entry point: `MenuBarController`, given a `PanelServices` by the app target.
