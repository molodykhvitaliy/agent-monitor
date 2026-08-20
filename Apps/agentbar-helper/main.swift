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
import os

// Read to EOF first, always. Codex writes the payload into a pipe, and a helper
// that exits before draining it hands the writer EPIPE — a visible effect on the
// agent, from a tool that is supposed to leave no trace.
//
// To EOF, but not for ever: the drain carries its own deadline. A hook process
// that can wait indefinitely for a writer is a hook process that accumulates,
// one per tool call, orphaned to launchd in the session's working directory.
let received = StandardInput.drain(limit: CodexHelperRelay.maximumPayloadBytes)

let outcome: CodexRelayOutcome
switch received.outcome {
case .complete where received.total == 0:
    // Codex always sends a payload, so this is a helper run by hand with Ctrl-D,
    // or a hook invoked in a way nobody anticipated. Neither is a fault.
    outcome = .nothingToSend
case .complete where received.total > CodexHelperRelay.maximumPayloadBytes:
    outcome = .payloadTooLarge(bytes: received.total)
case .complete:
    if let discoveryURL = CodexHelperRelay.defaultDiscoveryURL() {
        outcome = CodexHelperRelay(discoveryURL: discoveryURL).relay(received.data)
    } else {
        outcome = .endpointUnknown
    }
case .expired where received.total == 0 && isatty(STDIN_FILENO) == 1:
    // A terminal on standard input is a person running the helper by hand and
    // typing nothing; since the drain gained a ceiling, that is what waiting
    // used to be. Not a fault, and no fragment to report.
    //
    // The `isatty` is the whole of the distinction, and it has to be made: Codex
    // gives the hook a **pipe**, so a pipe that produced nothing before the
    // ceiling is Codex not having written yet — a lost event, and precisely the
    // case the first-byte exemption exists to stretch. Calling that "nothing on
    // stdin" would file the one drop the ceiling can cause as a non-event.
    outcome = .nothingToSend
case .expired where received.total == 0:
    outcome = .payloadIncomplete(bytes: 0, reason: "nothing was written before the ceiling")
case .expired:
    outcome = .payloadIncomplete(bytes: received.total, reason: "the writer never closed its end")
case .failed(let code):
    // Reported even with nothing in hand: a `read` that failed is a fault worth
    // a log line, where an empty stdin is not.
    outcome = .payloadIncomplete(
        bytes: received.total, reason: String(cString: strerror(code)))
}

// A dropped payload has to leave a trace somewhere a person can find. `os_log`
// is that somewhere: it reaches Console and `log show` without touching either
// stream Codex reads, so it stays invisible to the agent while the failure stops
// being invisible to us. Only the two faults are logged — "AgentBar is not
// running" is the overwhelmingly common outcome and is not news, and logging it
// on every tool call would be its own kind of noise.
switch outcome {
case .payloadIncomplete, .payloadTooLarge:
    Logger(subsystem: "com.molodykhvitalii.AgentBar", category: "helper")
        .error("codex payload dropped: \(outcome.description, privacy: .public)")
case .delivered, .nothingToSend, .endpointUnknown, .undelivered:
    break
}

// Opt-in, and stderr rather than stdout: this is for a person holding a terminal
// and running the helper by hand, never for Codex to read.
if ProcessInfo.processInfo.environment["AGENTBAR_HELPER_DEBUG"] != nil {
    fputs("agentbar-helper: \(outcome)\n", stderr)
}

exit(EXIT_SUCCESS)
