---
tool: network_attach
description: Connect to a running Flutter/Dart app via DTD or VM service. Opens a capture session and starts the writer.
when_to_use: When the user wants live data from a running app and you're not already attached.
---

## DO NOT USE THIS TOOL WHEN

- You're already attached — check `network_status.attached` first. Calling attach again silently detaches the prior session.
- The user only wants to query history — use `session_list` + `session_open` instead, no attach needed.
- The app isn't running, or it's a release/profile build — the VM service is stripped and this will fail.
- The DTD URI is older than ~2 hours — attach may hang or be rejected with a zombie-DTD error. Tell the user to restart the Flutter app.
- The user has disabled the `http` capability and you're attaching just to "see what's there" — nothing useful will run.

## Use this when

- The user asks to inspect or debug live HTTP/socket/log activity.
- After `network_status` reports `attached:false` and `knownApps` is non-empty.
- The user gave a fresh DTD URI from their IDE console.

## How it works

1. Connects to DTD (or VM service directly) and probes with `getVersion()` in a 5-second timeout window.
2. Picks the main isolate that exposes `ext.dart.io.getHttpProfile`.
3. Enables HTTP timeline logging and socket profiling (if `sockets` capability is on).
4. Subscribes to `Logging`/`Stdout`/`Stderr` streams (if `logs` capability is on).
5. Inserts a new row in `sessions` and kicks off the 2-second capture writer.

## Args

- `dtdUri` (string, optional) — overrides the default DTD URI.
- `vmServiceUri` (string, optional) — bypasses DTD entirely. Use when DTD can't see the app.

If neither is provided, falls back to `FLUTTER_NETWORK_MCP_DTD_URI` and the `--dtd-uri` startup flag.

## Returns

```json
{
  "attached": true,
  "appName": "...",
  "vmServiceUri": "...",
  "isolateId": "...",
  "httpProfilingEnabled": true,
  "socketProfilingEnabled": true,
  "logStreamActive": true,
  "liveSessionId": 14,
  "capturesDbPath": "/Users/me/.local/share/flutter_network_mcp/captures.db"
}
```

## Pairs well with

- `network_status` — confirm before attaching.
- `network_list` / `logs_tail` — the read tools that work against the live session.
- `network_detach` — when investigation is over.

## Example

```
> network_status
< {attached:false, dtd:{defaultUri:"ws://..."}}
> network_attach
< {attached:true, liveSessionId:14, ...}
> network_list
```
