// AgentBarCore
//
// Provider-neutral domain: events, the session state machine, the session
// store and the watchdog. Depends on nothing and must never import AppKit,
// UserNotifications, IOKit or SwiftUI, touch the filesystem, or open a socket.
//
// The entry points are `AgentEvent` going in, `SessionStore` holding the only
// mutable state, and `StoreSnapshot` coming out. Nothing here knows that Claude
// Code or Codex exist — see docs/dev/architecture.md.
