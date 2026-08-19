# Recorded hook payloads

Every file here is a payload Claude Code **actually sent**, captured on
2026-08-18 from Claude Code `2.1.233` by pointing `type: "http"` handlers at a
recorder that answered `200` with an empty body. The only edits are identity:
the home directory and the capture directory became `/Users/dev` and
`/Users/dev/projects/probe`, and `transcript_path` / `agent_transcript_path`
were rewritten to the same canonical shape Claude Code builds them in. Field
names, field presence, ordering and nesting are untouched.

`session-*.json` files are whole sessions in delivery order, which is what the
state-machine tests replay.

`vscode-*.json` was recorded from a live VS Code extension session; everything
else came from `claude -p` runs. The two shapes agree field for field, apart
from `effort`, which is present only when the model supports it.

Two exceptions, both marked here rather than in the files so the files stay
loadable as payloads:

- `notification-permission-prompt.json` is the example published in the
  [hooks reference](https://code.claude.com/docs/en/hooks#notification-input)
  with paths matched to the other fixtures. `permission_prompt` fires about six
  seconds after a permission request that nobody has answered, which a
  non-interactive capture cannot produce. Replace it with a recording the next
  time a live session raises one.
- `pre-tool-use-ask-user-question.json` has a real envelope and a real
  `tool_input` *shape* — `questions[].question` / `header` / `multiSelect` /
  `options[]`, confirmed on 2026-08-19 against seven `AskUserQuestion` calls
  recorded by Claude Code `2.1.233` in `~/.claude/projects/*.jsonl` — but the
  question and options are written rather than captured, because every recorded
  one belongs to a private session. Shape is what the decoder reads; the words
  are not.
- `stop-failure.json` was recorded from a real `authentication_failed` turn —
  a session started against a config directory with no credentials — rather
  than from a rate limit, because an API error cannot be provoked on demand.
