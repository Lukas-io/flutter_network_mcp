---
tool: session_close
description: Revert the read pointer to live mode. No-op if not viewing history.
when_to_use: After you're done querying a historical session and want to read live again.
---

## DO NOT USE THIS TOOL WHEN

- You weren't viewing history — this is a no-op then. Not harmful, just unnecessary.
- You want to detach — that's `network_detach`. Closing the viewer doesn't disconnect.
- You want to switch to a different historical session — just `session_open id:<other>` directly. No need to close first.

## Use this when

- Investigation finished; switching back to live before triggering new actions.

## How it works

Sets `session.viewedSessionId` to null. Read tools fall back to live behavior.

## Args

None.

## Returns

```json
{"closed": true, "previousViewedSessionId": 13, "liveSessionId": 14}
```

## Pairs well with

- `session_open` — the inverse.

## Example

```
> session_close
< {previousViewedSessionId: 13, liveSessionId: 14}
> network_list
```
