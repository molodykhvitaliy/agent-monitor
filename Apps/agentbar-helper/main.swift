// agentbar-helper
//
// Codex executes only `command` hooks, so a process bridge is unavoidable. This
// binary is that bridge, and it is an entry point and nothing else: the relay it
// calls lives in `CodexAdapter`, where `swift test` can exercise the code the
// hook actually runs rather than a copy of it.
//
// It takes no arguments, on purpose. Codex records hook trust against a hash of
// the hook definition, the definition is this executable's path, and an argument
// added later would send every user back to `/hooks` to review a hook they had
// already trusted.
//
// Everything it does resolves to exit code 0. Codex reads a non-zero exit from
// `PreToolUse`, `PostToolUse` or `UserPromptSubmit` as a *block* — a monitor
// that could block a tool call is the failure this project is built to avoid —
// and stdout is parsed as hook output, so both streams stay empty unless
// `AGENTBAR_HELPER_DEBUG` asks for a line on stderr.

import CodexAdapter
import Darwin
import Foundation

// Read to EOF first, always. Codex writes the payload into a pipe, and a helper
// that exits before draining it hands the writer EPIPE — a visible effect on the
// agent, from a tool that is supposed to leave no trace.
let received = StandardInput.drain(limit: CodexHelperRelay.maximumPayloadBytes)

let outcome: CodexRelayOutcome
if received.total > CodexHelperRelay.maximumPayloadBytes {
    outcome = .payloadTooLarge(bytes: received.total)
} else if let discoveryURL = CodexHelperRelay.defaultDiscoveryURL() {
    outcome = CodexHelperRelay(discoveryURL: discoveryURL).relay(received.data)
} else {
    outcome = .endpointUnknown
}

// Opt-in, and stderr rather than stdout: this is for a person holding a terminal
// and running the helper by hand, never for Codex to read.
if ProcessInfo.processInfo.environment["AGENTBAR_HELPER_DEBUG"] != nil {
    fputs("agentbar-helper: \(outcome)\n", stderr)
}

exit(EXIT_SUCCESS)
