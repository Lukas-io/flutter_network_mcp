---
tool: session_close
description: Revert the read pointer to live mode (or no-session if not attached).
when_to_use: After you're done querying a historical session.
---

## DO NOT USE THIS TOOL WHEN

- You weren't viewing history — this is a no-op (the response says so cleanly).
- You want to detach the live capture — that's `network_detach`. Close ≠ detach.
- You want to switch to a different historical session — `session_open id:<other>` directly. No need to close first.

## Use this when

- Investigation finished; switching back to live before triggering new actions.

## How it works

Sets `Session.instance.viewedSessionId` to null. Read tools fall back to live behavior. Reports `previousViewedSessionId` so the agent can confirm what they reverted from.

## Args

None.

## Returns

```json
{
  "closed": true,
  "summary": "Read pointer reverted from session 13 to live (14).",
  "previousViewedSessionId": 13,
  "liveSessionId": 14,
  "nextSteps": [
    "network_list — read live captures",
    "session_list — see what other sessions exist"
  ]
}
```

No-op: `summary` says "was not viewing history."

## Pairs well with

- `session_open` — the inverse.
- `network_list` — first thing to do after switching back to live.

## Example

```
> session_close
< {previousViewedSessionId:13, liveSessionId:14, summary:"Read pointer reverted from session 13 to live (14)."}
> network_list
```
