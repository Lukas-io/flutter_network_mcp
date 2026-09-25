---
tool: network_wait_for_app
description: Block until a Flutter app registers with a running DTD, then attach to it and return the attach result. Polls about once a second until the app attaches or the timeout passes.
when_to_use: When the app is still launching (or relaunching) and network_status does not list it yet.
---

## DO NOT USE THIS TOOL WHEN

- The app is already listed in `network_status.knownApps`. Call `network_attach` directly; it answers without waiting.
- Several apps are running and you have not picked one. Without `appNameContains` this returns straight away with the list instead of waiting.
- The session cap (`FLUTTER_NETWORK_MCP_MAX_ATTACH`) is reached. Waiting cannot free a slot; this returns straight away. Detach a session first.
- The app is a release / profile build. It never registers a VM service, so this only ends at the timeout.
- You only want history. Use `session_list` + `session_open`.

## Use this when

- The user just started `flutter run` and the app is still building or booting.
- The app exited and you expect it back (for example, `network_status` says it "has exited" and suggests this tool).
- You would otherwise poll `network_status` in a loop.

## How it works

1. Clamps `timeoutMs` to 1000 to 300000 (default 30000). The tool is exempt from the per-tool deadline (`FLUTTER_NETWORK_MCP_TOOL_TIMEOUT_MS`), so the wait is not cut short.
2. On each poll (about once a second) it drops the DTD probe cache, so a newly registered app is seen straight away.
3. Without `appNameContains`: lists the apps of EVERY running DTD, not only the startup default one.
   - No app yet: waits and polls again.
   - Exactly one app: attaches to it by its VM service URI.
   - Several apps: returns at once with `errorKind: bad_argument`, the `apps` list, and one `network_wait_for_app appNameContains:"..."` step per app.
4. With `appNameContains`: runs the same attach as `network_attach appNameContains:"..."`, matched across every running DTD. No matching app yet: waits and polls again.
5. The attach succeeds, or the app is already attached (`alreadyAttached:true`, with that session's id): returns the attach result plus `waitedMs` and `polls`.
6. Answers that waiting cannot change (several apps match, session cap reached; the attach marks them `retryable:false`) return at once as `errorKind: bad_argument`, with the attach result's `apps` or `attached` list and `nextSteps`.
7. Any other failed attempt (no app yet, attach in progress, a failed connect) is retried until the deadline. Then the call returns `errorKind: timeout` with the last attempt's error as `lastAttempt`.

The tool sends no progress notifications while it waits; a long `timeoutMs` blocks the call for that long.

## Args

- `timeoutMs` (int, optional, default 30000): how long to wait, in ms. Clamped to 1000 to 300000.
- `appNameContains` (string, optional): attach only an app whose name contains this (case-insensitive). Pass it when several apps may register at once.

The attach uses the server's default DTD settings; there is no `dtdUri`, `vmServiceUri`, `logBufferSize`, `reattach` or `nativeLogs` arg here. Use `network_attach` when you need those.

## Returns

Success: the full `network_attach` reply (see [`network_attach`](network_attach.md)) plus two fields:
```json
{
  "attached": true,
  "summary": "Attached to sanga_mobile, capturing HTTP+sockets+logs into session 14.",
  "scope": {"sessionId": 14, "appName": "sanga_mobile", "isLive": true},
  "liveSessionId": 14,
  "waitedMs": 7420,
  "polls": 8,
  "nextSteps": ["Drive the app to generate traffic", "Then call network_list / logs_tail"]
}
```

Already attached (success):
```json
{
  "attached": true,
  "alreadyAttached": true,
  "summary": "Already attached to sanga_mobile in session 14; reusing it, nothing new was started.",
  "liveSessionId": 14,
  "waitedMs": 30,
  "polls": 1
}
```

Error (several apps, no `appNameContains`):
```json
{
  "error": "2 apps are running; pass appNameContains to pick one.",
  "errorKind": "bad_argument",
  "apps": [{"name": "Kind: Flutter - Device: iPhone 17 - Package: app_a", "uri": "ws://..."},
           {"name": "Kind: Flutter - Device: Pixel 8 - Package: app_b", "uri": "ws://..."}],
  "nextSteps": ["network_wait_for_app appNameContains:\"Kind: Flutter - Device: iPhone 17 - Package: app_a\"",
                "network_wait_for_app appNameContains:\"Kind: Flutter - Device: Pixel 8 - Package: app_b\""],
  "waitedMs": 12,
  "polls": 1
}
```

With `appNameContains` matching several apps, the error is the attach's "Multiple apps across DTDs match ..." message, also as `bad_argument`. With the session cap reached, it is the attach's "Reached max attached sessions ..." message with `attached` and `maxAttach`.

Error (timeout):
```json
{
  "error": "No app attached within 30000ms (polled 30 time(s)). Waited for a name containing \"sanga\".",
  "errorKind": "timeout",
  "waitedMs": 30012,
  "polls": 30,
  "lastAttempt": "No app name contains \"sanga\" on any running DTD. Visible apps: ...",
  "nextSteps": ["launch the app, or check it is not crashing on start",
                "network_status ..."]
}
```

Without `appNameContains`, the timeout `nextSteps` also suggest passing it when several apps may run.

## Pairs well with

- `network_status`: its `nextSteps` suggest this tool when a previously attached app has exited.
- `network_attach`: the non-blocking version, with the full set of args.
- `network_list` / `logs_tail`: read the new session once attached.

## Example

App still building:
```
> network_wait_for_app appNameContains:"sanga_mobile" timeoutMs:120000
< {attached:true, liveSessionId:14, waitedMs:41200, polls:42}
```

Two apps up, no name given:
```
> network_wait_for_app
< {errorKind:"bad_argument", error:"2 apps are running; pass appNameContains to pick one.", apps:[...]}
> network_wait_for_app appNameContains:"app_a"
< {attached:true, appName:"...app_a", liveSessionId:15}
```
