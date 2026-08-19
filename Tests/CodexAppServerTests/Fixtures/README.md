# App Server fixtures

What the account methods actually return, and the shapes the schema says they
are allowed to return.

`rate-limits-live.json`, `account-chatgpt.json` and `usage-live.json` are
**recordings**, taken on 2026-08-19 from `codex-cli 0.147.0` against a ChatGPT
Plus account, with the account's email replaced. Everything else is derived from
`schemas/appserver/v2` — a shape the contract permits that this account cannot
produce on demand.

| Fixture | What it pins |
|---|---|
| `rate-limits-live.json` | one bucket, `limitName: null`, `primary` only, weekly window, `credits` as an object |
| `rate-limits-two-windows.json` | a bucket with both windows — the case the design mocked and the live account has never shown |
| `rate-limits-many-buckets.json` | several buckets, one carrying a field this build has never heard of |
| `rate-limits-all-null.json` | every nullable field null at once, which is documented for `self_serve_business_usage_based` |
| `rate-limits-absent-fields.json` | `rateLimits: {}` — every field absent rather than null |
| `rate-limits-drifted.json` | unknown enum values, a bucket that is not an object, a credit missing a required field |
| `rate-limits-nonsense-numbers.json` | a percentage outside 0–100, a zero reset stamp, negative durations |
| `account-*.json` | each `Account` branch, plus none at all and a kind that does not exist yet |
| `usage-*.json` | the token counters, populated and entirely empty |

The rule every one of these exists to hold: **absent data renders as
"unavailable", never as zero and never as a crash.** A fixture that decodes into
a window with a bar at 0 % is a failing fixture even when nothing throws.
