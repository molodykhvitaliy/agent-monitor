// agentbar-helper
//
// Codex executes only `command` hooks, so a process bridge is unavoidable. This
// binary is that bridge: step 09 makes it read one JSON object from stdin and
// relay it to the loopback ingest endpoint.
//
// Two constraints govern every line that will be added here. Codex caps
// `SessionEnd` hooks at one second, so the whole run must finish in single-digit
// milliseconds — which is why this is a compiled executable and not a script.
// And the helper must never block the agent: an unreachable endpoint exits
// quickly and successfully rather than failing or waiting.
//
// Until then it does nothing at all, successfully.

import Darwin

exit(EXIT_SUCCESS)
