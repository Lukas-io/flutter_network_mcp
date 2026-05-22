---
tool: network_status
description: Report attachment state, active capabilities, known apps, and pending alert count.
when_to_use: As the first call of any investigation, and as a passive periodic check to notice when alerts have accumulated.
---

## DO NOT USE THIS TOOL WHEN

- You're polling it more than once a minute — it's idempotent but not free. Prefer `alerts_peek` for alert-only checks.
- You need full alert details — this only returns a count. Use `alerts_drain` or `alerts_peek`.
- You expect it to attach for you — it doesn't. It only reports state. Call `network_attach` to attach.
- You've already attached this turn and the state can't have changed.

## Use this when

- Starting a session and need to know if you're attached, to what app, and which capabilities are enabled.
- Checking whether `alerts.pending > 0` before diving into other tools.
- Confirming a DTD URI was passed at startup (look at `dtd.defaultUri`).
- Listing what apps DTD knows about so you can pick a `vmServiceUri` to pass to `network_attach`.

## How it works

Reads in-process state (no VM service calls if not attached) and queries the alerts table for a pending count. Returns instantly.

## Args

None.

## Returns

```json
{
  "attached": false,
  "capabilities": ["http", "logs", "alerts", "sessions"],
  "dtd": {"connected": false, "uri": null, "defaultUri": "ws://..."},
  "vmService": {"connected": false, "uri": null, "isolateId": null, "appName": null},
  "liveSessionId": null,
  "viewedSessionId": null,
  "alerts": {"pending": 0, "critical": 0},
  "knownApps": [{"name": "...", "uri": "ws://..."}]
}
```

## Pairs well with

- `network_attach` — when `attached:false` and `knownApps` has entries.
- `alerts_drain` — when `alerts.pending > 0`.
- `session_list` — when no live session and the user is asking about history.

## Example

```
> network_status
< {attached:false, capabilities:[http,sessions], dtd:{defaultUri:"ws://..."}, alerts:{pending:0}}
> network_attach
```
