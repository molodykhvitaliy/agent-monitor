// AgentBarUI
//
// SwiftUI views, view models and the AppKit shell that hosts them. Views
// consume immutable snapshots from AgentBarCore; no view reaches into the
// store's mutable state or into an adapter.
//
// The module opts into MainActor as its default isolation in Package.swift.
//
// Step 06 replaces the placeholder menu below with the real status item and a
// non-activating SwiftUI panel.
