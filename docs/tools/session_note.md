---
tool: session_note
description: Set a freeform note on a session. Helps future-you find the right session later.
when_to_use: At the end of an investigation, before detach — annotate what the session was about.
---

## DO NOT USE THIS TOOL WHEN

- You haven't done anything useful in the session yet — wait until there's something worth noting.
- You want structured metadata — this is a single text field. Use SQL UPDATE on `sessions` for richer schemas.
- You want the note to apply to one request inside a session — it doesn't. Notes are session-wide.
- You're putting secrets in the note — they're stored unencrypted in the DB.

## Use this when

- Wrapping up: "remember this was the auth-token regression on 2026-05-21".
- Tagging release smoke tests by version.
- Marking which sessions correspond to which bug ticket.

## How it works

`UPDATE sessions SET note = ? WHERE id = ?`. Empty string clears the note (stored as NULL).

## Args

- `id` (int, required).
- `note` (string, required) — pass empty string to clear.

## Returns

```json
{"sessionId": 14, "note": "auth bug 2026-05-21"}
```

## Pairs well with

- `session_list` — the note is visible in list output.

## Example

```
> network_detach
> session_note id:14 note:"auth-bug repro for #1842"
> session_list limit:5
< [{id:14, note:"auth-bug repro for #1842"}]
```
