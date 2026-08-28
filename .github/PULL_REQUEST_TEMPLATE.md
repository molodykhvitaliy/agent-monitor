## What this changes

<!-- One or two sentences. If it fixes an issue, link it. -->

## Why

<!-- The problem, not the patch. -->

## What was verified

<!-- Commands you actually ran, and their result. `make check` is the baseline. -->

- [ ] `make check` passes
- [ ] New behaviour has a test, or there is a reason here why it cannot

**Not verified:** <!-- Be exact. "Not tested against a real Codex session" is
useful; leaving it unsaid is not. -->

## Rules this touches

<!-- Delete what does not apply. -->

- [ ] Nothing here originates a network request to Anthropic or OpenAI, and
      nothing reads or forwards a provider credential
- [ ] No path added here can resolve into granting a permission
- [ ] Both tools still behave identically if AgentBar is absent or crashed
- [ ] An architectural decision here is recorded in `docs/adr/`
