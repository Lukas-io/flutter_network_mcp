---
tool: network_attach
description: Connect to a running Flutter/Dart app via DTD or VM service. Opens a capture session, enables HTTP/socket profiling, and starts the writer + log streams. Several apps can be attached at once.
when_to_use: When the user wants live data from a running app that is not attached yet.
---

## DO NOT USE THIS TOOL WHEN

- The app is still starting and not listed in `network_status.knownApps` yet. Use `network_wait_for_app`, which polls until the app registers and then attaches.
- The user only wants to query history. Use `session_list` + `session_open`. No attach needed.
- The app is a release / profile build. The VM service is stripped and this fails with a clear error.
- The DTD URI is older than ~10 minutes on macOS. DDS often goes zombie; the 5s `getVersion()` probe catches it and tells you to restart the Flutter app.
- The user has disabled the `http` capability and there's nothing else to capture. Attach will succeed but do less than expected.
- You're attempting attach as a "discover what apps exist" call. That's what `network_status` is for. It auto-connects DTD and lists `knownApps` without the side effects of attach.

## Use this when

- The user asks to inspect or debug live HTTP/socket/log activity.
- `network_status` lists the app under `knownApps`. Follow its `nextSteps` hint.
- The user gave a fresh DTD URI, or a VM service URI from the IDE console or `flutter run` output.
- You want a second app captured alongside the first. Each attach opens its own session; reads pick one with `sessionId` or `appNameContains`.
- One-shot orient+attach is desired: `network_status attachIfOne:true` does both when exactly one app is visible.

## How it works

1. Session cap: at most `FLUTTER_NETWORK_MCP_MAX_ATTACH` live sessions (1 to 32, default 8). When the cap is reached, a heartbeat first evicts dead sessions; if it is still full, the call errors with `retryable:false`, the `attached` list and `maxAttach`.
2. Resolves the target VM service URI:
   - `vmServiceUri` set: used directly. The app name is looked up across every running DTD (best effort; it stays null when no DTD lists that URI).
   - `appNameContains` set and no `dtdUri`: matched (case-insensitive substring) against the apps of EVERY running DTD, the same list `network_status.knownApps` shows. Zero matches or several matches error with the candidate `apps`.
   - Otherwise: connects the given `dtdUri` or the default DTD and lists its apps (filtered by `appNameContains` when set). Several apps error with the candidate list.
3. Canonicalises the URI (`lib/src/vm/vm_uri.dart`). `ws://host:port/<token>/ws` (the DTD spelling) and `http://host:port/<token>/` (the `flutter run` spelling) name the same VM, and both become `http://host:port/<token>/`. The reply's `vmServiceUri` and the stored session use this form.
4. If that VM is already attached, returns success straight away with `attached:true, alreadyAttached:true` and that session's id. Nothing new is started. A concurrent attach to the same target returns an "already in progress" error instead of opening a second session.
5. Connects to the VM service (5s `getVersion()` probe), finds every isolate that exposes `ext.dart.io.getHttpProfile`, and enables HTTP timeline logging on each. Tries socket profiling when the `sockets` capability is on. Subscribes to the `Logging` / `Stdout` / `Stderr` streams when the `logs` capability is on.
6. Creates a row in `sessions` (or, with `reattach:true`, reuses the matching session id) and starts the capture writer. Starts the native device log when `nativeLogs` is on.
7. When the app had been running for more than 5s before attach, adds a warning and `preAttachUptimeMs`: traffic before the attach was not recorded.
8. If a `session_open` history view was open, it is closed so reads target the new live session, and a warning says so.

Stack traces from errors are written to stderr only. They never appear in the response payload, so error responses stay context-cheap.

## Args

- `dtdUri` (string, optional): overrides the default DTD URI.
- `vmServiceUri` (string, optional): bypasses DTD. Takes priority over `dtdUri` and `appNameContains`. Either spelling of the VM URI works (`ws://.../ws` or `http://.../`).
- `appNameContains` (string, optional): case-insensitive substring of the app name (from `network_status.knownApps[].name`). Resolved across ALL running DTDs unless `dtdUri` is also passed.
- `logBufferSize` (int, optional): per-session log ring-buffer capacity, clamped to 50 to 20000. Default: `auto_attach_config logBufferSize` when set, else `FLUTTER_NETWORK_MCP_LOG_BUFFER`, else 2000. Raise it for chatty apps.
- `reattach` (bool, optional, default false): hot-restart continuity. When true and an attached session for the SAME app (same package + device) is bound to a different, now-stale VM URI, reuse its `sessionId`: captures continue under one session across the restart, and the stale session is torn down. It matches on the app name, so pair it with `appNameContains` (a raw `vmServiceUri` attach only has a name when a DTD lists that URI).
- `nativeLogs` (bool, optional): also stream the device's native log for this app (`simctl log stream` on an iOS simulator, `adb logcat` on Android) into `logs_tail` as `source:"native"`. Needs the `logs` capability. Default: `auto_attach_config nativeLogs` (false).

If none of `dtdUri`, `vmServiceUri` or `appNameContains` is provided, falls back to `--dtd-uri` / `FLUTTER_NETWORK_MCP_DTD_URI`.

## Returns

Success:
```json
{
  "attached": true,
  "summary": "Attached to eats_mobile, capturing HTTP+sockets+logs into session 14.",
  "scope": {"sessionId": 14, "appName": "...", "isLive": true},
  "appName": "...",
  "vmServiceUri": "http://127.0.0.1:54450/abc=/",
  "isolateId": "isolates/123",
  "liveSessionId": 14,
  "socketProfilingEnabled": true,
  "preAttachUptimeMs": 180000,
  "capabilities": {"http": "ok", "socket": "ok", "logs": "ok"},
  "attachedCount": 1,
  "nextSteps": ["Drive the app to generate traffic",
                "Then call network_list / logs_tail"]
}
```

`summary` is a one-line synthesis the agent can echo to the user verbatim. With 2+ sessions attached it also says how many are attached, and the second `nextSteps` line explains how bare reads pick a session (pass `sessionId` to be explicit).
`capabilities` maps `http` / `socket` / `logs` to `ok`, `unavailable` (enabled but the stream did not start) or `disabled` (off in the server config). `degraded` lists the `unavailable` ones, when there are any.
`nextSteps` is filtered against active capabilities. Disabled tools never appear there.
Optional fields: `warnings` (pre-attach traffic not recorded, HTTP logging or socket profiling or the log stream did not start, native log not started, history view closed), `nativeLogs: {active, platform, detail}` when the native stream started, `autoAttachSuggestion` (ask the user before adding the app to the auto-attach allowlist), `reattached:true` + `previousVmServiceUri` after a reattach, and `reattachRequested` / `reattachMatched:false` / `reattachMissReason` when `reattach:true` matched nothing and a new session was started.

Already attached (success, nothing new started):
```json
{
  "attached": true,
  "alreadyAttached": true,
  "summary": "Already attached to eats_mobile in session 14; reusing it, nothing new was started.",
  "scope": {"sessionId": 14, "appName": "eats_mobile", "isLive": true},
  "appName": "eats_mobile",
  "vmServiceUri": "http://127.0.0.1:54450/abc=/",
  "liveSessionId": 14,
  "attachedCount": 1,
  "nextSteps": ["network_list sessionId:14 ...",
                "network_detach sessionId:14 then attach again for a fresh session"]
}
```

Errors carry `error` and `nextSteps`, and no `errorKind`. Answers that retrying cannot change (several matching apps, session cap reached) also carry `retryable:false`.

Error (several matching apps):
```json
{
  "error": "Multiple apps across DTDs match \"eats\"; pass a more specific substring or an explicit `vmServiceUri`.",
  "retryable": false,
  "apps": [{"name":"...", "uri":"ws://...", "dtdUri":"ws://..."}],
  "nextSteps": ["network_attach appNameContains:\"<unique substring>\"",
                "network_attach vmServiceUri:\"<from apps[].uri>\""]
}
```

Error (session cap reached):
```json
{
  "error": "Reached max attached sessions (8 live). Detach one first (network_detach keep:true frees the slot without ending the session) or raise FLUTTER_NETWORK_MCP_MAX_ATTACH.",
  "attached": [{"sessionId": 14, "appName": "..."}],
  "maxAttach": 8,
  "retryable": false,
  "nextSteps": ["network_detach sessionId:14 keep:true  // ...", "network_detach all:true ..."]
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

Other errors: no app name matches (`apps` lists what is visible), the DTD has no apps yet, no DTD URI configured, an attach to the same target already in progress, and "No running isolate exposes dart:io HTTP profiling".

## Pairs well with

- `network_status`: almost always called first. `attachIfOne:true` collapses both into one call when there's a clear single target.
- `network_wait_for_app`: when the app is still launching.
- `network_detach`: the graceful counterpart. `keep:true` frees the slot without ending the session.
- `network_list` / `logs_tail` / `alerts_drain`: the read tools that work against the live session after attach.

## Example

Single-app happy path:
```
> network_status
< {attachedCount:0, knownApps:[{name:"eats_mobile", uri:"ws://..."}]}
> network_attach
< {attached:true, liveSessionId:14}
```

Two apps at once:
```
> network_attach appNameContains:"app_a"
< {attached:true, appName:"app_a", liveSessionId:14}
> network_attach appNameContains:"app_b"
< {attached:true, appName:"app_b", liveSessionId:15, attachedCount:2}
> network_list sessionId:15
```

The same app by another spelling of its URI:
```
> network_attach vmServiceUri:"http://127.0.0.1:54450/abc=/"
< {attached:true, alreadyAttached:true, liveSessionId:14}
```

After a hot restart (the VM URI rotated; old session is now stale):
```
> network_attach appNameContains:"iPhone 16 Pro" reattach:true
< {attached:true, reattached:true, liveSessionId:14,
   previousVmServiceUri:"http://old/",
   summary:"Reattached to ... after a hot restart; ... same session 14 ..."}
```
`sessionId` stays 14, captures before and after the restart share one
session, and the dead session is dropped from `network_status.attached`.
