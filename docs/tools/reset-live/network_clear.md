---
tool: network_clear
description: Wipe the LIVE in-VM HTTP profile on the attached isolate. Does NOT touch the persistent DB.
when_to_use: To isolate one user action's traffic, OR to reset the cursor without managing it manually.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes session history — it doesn't. The DB rows stay. Only the in-VM profile clears. Use `session_delete` / `bodies_purge` for DB cleanup.
- You're viewing history (`viewedSessionId` set) — irrelevant; this only affects the live VM.
- You're not attached — nothing to clear. The tool errors with that exact message.
- You want to delete sockets too — use `socket_clear`. They're separate VM profiles.

## Use this when

- About to trigger a specific user action and want isolated network output ("clear, then tap login, then `network_list`").
- The cursor has drifted and you want a fresh start without managing offsets.

## How it works

Calls `ext.dart.io.clearHttpProfile` on the attached isolate. Resets `lastHttpCursor` to null. The DB session row + all captured `http_requests` / `http_bodies` / `alerts` etc. stay intact.

## Args

None.

## Returns

```json
{
  "cleared": true,
  "summary": "Live VM HTTP profile cleared. Persistent DB session 14 is untouched (captured rows remain queryable).",
  "liveSessionId": 14,
  "warnings": ["The persistent DB is NOT cleared. Use session_delete or bodies_purge to remove historical rows."],
  "nextSteps": [
    "network_list — confirm the live profile is empty",
    "Drive the app, then network_list — fresh isolated capture"
  ]
}
```

## Pairs well with

- `network_list` — verify empty after clear.
- `bodies_purge` / `session_delete` — when you actually mean "delete data".
- `socket_clear` / `logs_clear` — the sibling clears for other live state.

## Example

```
> network_clear
< {cleared:true, summary:"Live VM HTTP profile cleared..."}
> # tap "Refresh" in the app
> network_list
< {count:1, requests:[<just the refresh call>]}
```
