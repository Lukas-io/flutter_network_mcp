---
tool: network_attach
description: Connect to a running Flutter/Dart app via DTD or VM service. Opens a capture session, enables HTTP/socket profiling, and starts the writer + log streams.
when_to_use: When the user wants live data from a running app and you're not already attached.
---

## DO NOT USE THIS TOOL WHEN

- You're already attached — by default attach REFUSES to re-attach. The response will include `currentApp` and `liveSessionId` plus `nextSteps`. Pass `force:true` only when you genuinely want to discard the current session and switch.
- The user only wants to query history — use `session_list` + `session_open`. No attach needed.
- The app is a release / profile build — the VM service is stripped and this fails with a clear error.
- The DTD URI is older than ~10 minutes on macOS — DDS often goes zombie. The 5s `getVersion()` probe will catch it and tell you to restart the Flutter app.
- The user has disabled the `http` capability and there's nothing else to capture — attach will succeed but do less than expected.
- You're attempting attach as a "discover what apps exist" call — that's what `network_status` is for. It auto-connects DTD and lists `knownApps` without the side effects of attach.

## Use this when

- The user asks to inspect or debug live HTTP/socket/log activity.
- `network_status` reports `attached:false` and `knownApps` is non-empty. Follow its `nextSteps` hint.
- The user gave a fresh DTD URI from their IDE console.
- One-shot orient+attach is desired: prefer `network_status attachIfOne:true` over a separate `network_attach` call.

## How it works

1. If currently attached and `force` is not true, returns an error (with `currentApp`, `liveSessionId`, `nextSteps`).
2. Connects to DTD (or VM service directly when `vmServiceUri` is set) and probes with `getVersion()` under a 5-second timeout. Zombie DDS instances fail fast here.
3. Discovers connected apps. If `appNameContains` is set, filters by case-insensitive substring on app name. If exactly one remains, picks it; otherwise errors with the candidate list.
4. Connects to the VM service WS URI, picks the main isolate (one that exposes `ext.dart.io.getHttpProfile`).
5. Enables HTTP timeline logging. Tries socket profiling (if `sockets` capability is on). Subscribes to `Logging` / `Stdout` / `Stderr` streams (if `logs` capability is on).
6. Inserts a new row in `sessions` (start time, app name, VM URI, isolate id, working dir) and starts the 2-second capture writer.

Stack traces from errors are written to stderr only — they never appear in the response payload, so error responses stay context-cheap.

## Args

- `dtdUri` (string, optional) — overrides the default DTD URI.
- `vmServiceUri` (string, optional) — bypasses DTD entirely. Takes priority over `dtdUri` and `appNameContains`.
- `appNameContains` (string, optional) — case-insensitive substring filter applied to `knownApps[].name`. Use when DTD has multiple apps.
- `force` (bool, optional, default false) — required to re-attach when already attached. Without it, the call errors instead of silently detaching.

If neither `dtdUri` nor `vmServiceUri` is provided, falls back to `--dtd-uri` / `FLUTTER_NETWORK_MCP_DTD_URI`.

## Returns

Success:
```json
{
  "attached": true,
  "summary": "Attached to sanga_mobile — capturing HTTP+sockets+logs into session 14.",
  "appName": "...",
  "vmServiceUri": "...",
  "isolateId": "...",
  "liveSessionId": 14,
  "socketProfilingEnabled": true,
  "nextSteps": ["Drive the app to generate traffic",
                "Then call network_list / logs_tail / alerts_drain"]
}
```

`summary` is a one-line synthesis the agent can echo to the user verbatim.
`nextSteps` is filtered against active capabilities — disabled tools never appear there.
A `warnings: [...]` array appears only when something was partially degraded (e.g., socket profiling unavailable on this isolate, log stream subscription failed).

Error (already attached):
```json
{
  "error": "Already attached to \"...\" (session 14). Pass `force:true` to detach and re-attach, or call network_detach first.",
  "currentApp": "...",
  "liveSessionId": 14,
  "nextSteps": ["network_detach (graceful, keeps existing session data)",
                "network_attach force:true (silently detaches first)"]
}
```

Error (multi-app DTD):
```json
{
  "error": "DTD has multiple matching apps; pass `appNameContains` or an explicit `vmServiceUri`.",
  "apps": [{"name":"...", "uri":"ws://..."}, ...],
  "nextSteps": ["network_attach appNameContains:\"<unique substring>\"",
                "network_attach vmServiceUri:\"<from apps[].uri>\""]
}
```

Error (zombie DTD):
```json
{
  "error": "Attach failed: Bad state: VM service at ws://... accepted the connection but did not respond to getVersion() within 5s. The DTD/DDS instance is likely stale — restart the Flutter app to spawn a fresh one.",
  "nextSteps": ["Restart the Flutter app to spawn a fresh DTD/DDS",
                "Re-check via network_status (new DTD URI will auto-populate knownApps)"]
}
```

## Pairs well with

- `network_status` — almost always called first. `attachIfOne:true` collapses both into one call when there's a clear single target.
- `network_detach` — the graceful counterpart. Prefer over `force:true` when switching apps.
- `network_list` / `logs_tail` / `alerts_drain` — the read tools that work against the live session after attach.

## Example

Single-app happy path:
```
> network_status
< {attached:false, knownApps:[{name:"sanga_mobile", uri:"ws://..."}]}
> network_attach
< {attached:true, liveSessionId:14}
```

Multi-app DTD:
```
> network_status
< {knownApps:[{name:"app_a"}, {name:"app_b"}]}
> network_attach appNameContains:"app_a"
< {attached:true, appName:"app_a"}
```

Switching attached app:
```
> network_attach appNameContains:"app_b"
< {error:"Already attached to ...", nextSteps:[...]}
> network_attach appNameContains:"app_b" force:true
< {attached:true, appName:"app_b"}
```
