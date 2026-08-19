// AgentBarPower
//
// IOPMAssertion lifecycle — Caffeine. Holds an assertion only while a session
// is genuinely working, which is why the watchdog in AgentBarCore is mandatory:
// a session stuck in `working` would keep the Mac awake for ever.
//
// The module reads `StoreSnapshot` and nothing else. It does not know that
// hooks exist, that Claude Code exists, or how an event reached the store; its
// only intra-package edge is AgentBarCore, and `ModuleBoundaryTests` fails the
// build if that changes. `IOKit` is restricted to this module by the same test,
// for the same reason `Network` is restricted to AgentBarIngest: a power
// assertion taken anywhere else would be one nothing here can release.
//
// The pieces, in the order a decision travels through them:
//
//   CaffeineSettings   what the user chose, and what a toggle restores
//   CaffeineDemand     mode x snapshot -> hold or release, and the reason
//   PowerAsserting     the seam over IOKit, so the decision is testable
//   CaffeineController the one stateful object: holds, renews, releases
//
// Never `/usr/bin/caffeinate`. That subprocess can be orphaned by a force-quit
// and then holds the Mac awake with nothing left to release it. A
// process-owned assertion is released by the kernel when the process dies,
// which is precisely the property this module is built around.
