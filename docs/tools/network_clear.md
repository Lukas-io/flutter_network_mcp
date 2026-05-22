---
tool: network_clear
description: Wipe the LIVE HTTP profile on the attached isolate. Does not touch the DB.
when_to_use: When you want a clean slate for new captures — e.g., before triggering a specific action to isolate its requests.
---

## DO NOT USE THIS TOOL WHEN

- You think this deletes session history — it doesn't. The DB row stays. Only the in-VM profile is cleared.
- You want to delete a past session — use `network_query` with `DELETE FROM sessions WHERE id=...` (cascades).
- You're not attached — there's no live profile to clear.
- You're viewing history (`viewedSessionId` set) — clearing the live profile is unrelated to what you're reading.

## Use this when

- About to trigger a specific action and want isolated network output (e.g., "tap login, then call network_list — I want to see only that request").
- The VM-side profile has grown stale and you want a fresh `since` cursor without managing it manually.

## How it works

Calls `ext.dart.io.clearHttpProfile` on the attached isolate, resets the session's `lastHttpCursor`. Already-persisted rows in `http_requests` stay intact.

## Args

None.

## Returns

```json
{"cleared": true}
```

## Pairs well with

- `network_list` — call immediately after to confirm 0 results.
- `network_attach` — already does a clean start; you usually don't need clear right after attach.

## Example

```
> network_attach
> # user taps "Sync" in the app
> network_list
< {count: 47, ...}
> network_clear
> # now tap the action you actually care about
> network_list
< {count: 2, requests:[...]}
```
