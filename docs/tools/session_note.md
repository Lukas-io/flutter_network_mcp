---
tool: session_note
description: Set or clear a freeform note on a capture session.
when_to_use: At the end of an investigation (or right after attach) — annotate what the session is about.
---

## DO NOT USE THIS TOOL WHEN

- The session has nothing useful in it yet — wait until there's something worth noting.
- You want structured metadata — this is a single text field. Use SQL UPDATE on `sessions` for richer schemas.
- You want the note to apply to one request — it doesn't. Notes are session-wide.
- You're storing secrets — notes are stored unencrypted in the DB.

## Use this when

- Wrapping up: "remember this was the auth-token regression on 2026-05-21".
- Tagging release smoke tests by version.
- Marking which sessions correspond to which bug ticket.

## How it works

`UPDATE sessions SET note = ? WHERE id = ?`. Empty string clears the note (stored as NULL).

## Args

- `id` (int, required).
- `note` (string, required) — empty to clear.

## Returns

```json
{
  "summary": "Set note on session 14: \"auth bug 2026-05-21\".",
  "sessionId": 14,
  "note": "auth bug 2026-05-21",
  "nextSteps": [
    "session_list — confirm the note shows up",
    "session_export id:14 format:\"har\" outPath:\"...\" — share with the note as context"
  ]
}
```

## Pairs well with

- `session_list` — the note is visible there.
- `session_export` — note travels with future-you.

## Example

```
> network_detach
> session_note id:14 note:"auth-bug repro for #1842"
< {summary:"Set note on session 14: \"auth-bug repro for #1842\"."}
```
