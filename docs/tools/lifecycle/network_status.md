---
tool: network_status
description: Auto-orienting first call — reports attachment state, active capabilities, DTD-known apps, DB-wide alert counts, session totals, and a context-aware `nextSteps` hint. Optionally attaches in one shot.
when_to_use: As the very first call of any investigation. It auto-connects DTD (if a default URI is set) so `knownApps` populates without a separate attach call.
---

## DO NOT USE THIS TOOL WHEN

- You're already attached AND the state can't have changed since last call. Spammy polling burns context.
- You need full alert details — this only returns counts. Use `alerts_drain` or `alerts_peek`.
- You explicitly want a passive read with no side effects — pass `connectDtd:false` so DTD isn't opened.
- You're hoping `nextSteps` will execute itself — it won't. The hint is a string for you to act on.
- You expect `attachIfOne:true` to pick one of several apps. It only fires when nothing is attached, `knownApps` has exactly ONE app, and a default DTD URI is configured. With several apps, call `network_attach appNameContains:"..."` for each app you want.
- The app is still launching and not in `knownApps` yet. `network_wait_for_app` blocks until it registers, then attaches.

## Use this when

- Starting a debugging conversation — call this first.
- Confirming what capabilities the server was started with (the `--capabilities` flag is visible in the response).
- Checking whether stale alerts are waiting from past sessions (`alerts.pendingTotal > 0`).
- Discovering known DTD apps without calling attach.
- "Orient and attach in one shot" — `attachIfOne:true` when you trust the heuristic.

## How it works

Reads in-process state. If `connectDtd:true` (default) and DTD isn't already connected and a default URI exists, opens DTD with a 5s timeout. When that fails, it rediscovers a live DTD and retries once (`dtd.rediscovered:true` on success); when both fail, `dtd.connectError` and `dtd.nextSteps` (pointing at `network_discover_dtd`) are set. Reads the DB path and session count. When the `alerts` capability is on, adds the DB-wide alert counts (see below). Synthesizes a short `nextSteps` array based on state.

**Multi-DTD enumeration (0.6.2+).** `knownApps` lists apps across EVERY live DTD on the local machine, not just the one the primary connection is on. Each `flutter run` spawns its own DTD; this tool probes every discovered DTD via transient `DtdClient` connections (parallel, 1.5s per-probe timeout, 30s cache) so a user with three `flutter run`s in three terminals sees three apps. Each entry carries a `dtdUri` + `workspaceRoot` naming the source DTD — the agent can pass `dtdUri:"<that one>"` to `network_attach` to switch DTDs explicitly, though passing `vmServiceUri:` directly bypasses DTD entirely. Per-DTD probe errors surface under `dtdProbeErrors`.

When `attachIfOne:true` AND `attachedCount == 0` AND `knownApps.length == 1` AND a default DTD URI is configured, the call additionally runs the attach flow (same as `network_attach` with no args, which attaches through the default DTD). The attach result, success or error, is returned under `autoAttached`. On success the top-level `attached` list and `attachedCount` are refreshed in the same response, and an open `session_open` view is closed with a warning.

## Args

- `connectDtd` (bool, default true) — opportunistically open DTD to populate `knownApps`. Set false for a pure in-process state read.
- `attachIfOne` (bool, default false) — auto-attach when exactly one app is visible.

## Returns

```json
{
  "mcp": {
    "version": "0.6.2",
    "commit": "d804c4d…",
    "isAot": true,
    "upgradeCommand": "flutter_network_mcp update"
  },
  "attachedCount": 0,
  "attached": [],
  "capabilities": "all",
  "captureBoundary": "Only dart:io traffic (HttpClient, package:http, dio) is captured; native SDK traffic ... is not visible here ...",
  "dtd": {"connected": true, "uri": "ws://...", "defaultUri": "ws://..."},
  "dbPath": "/Users/me/.local/share/flutter_network_mcp/captures.db",
  "sessionCount": 0,
  "alerts": {"pendingTotal": 0, "pendingEvents": 0, "critical": 0},
  "knownApps": [
    {
      "name": "eats_mobile - iPhone 17",
      "uri": "ws://127.0.0.1:54450/.../ws",
      "dtdUri": "ws://127.0.0.1:56443/...",
      "workspaceRoot": "/Users/me/StudioProjects/eats_mobile"
    }
  ],
  "nextSteps": ["Call network_attach (one app available — will be auto-picked)"]
}
```

Each `attached[]` entry (one per attached session) carries `sessionId`, `appName`, `vmServiceUri` (canonical `http://host:port/<token>/` form), `isolateId`, `isolates`, `attachedAtMs`, `httpProfilingEnabled`, `socketProfilingEnabled` (only when true), `capabilities` / `degraded` (same meaning as in `network_attach`), `nativeLogs` (when the native log stream is active), `logBufferUsed` / `logBufferCapacity`, and after a hot-restart reattach `reattachCount`, `lastReattachAtMs`, `previousVmServiceUri`.

`knownApps[].uri` is the URI as the DTD lists it (usually `ws://.../ws`). Pass it to `network_attach vmServiceUri:` as is; attach treats both spellings as the same app. `exposedUri` appears when the DTD reports one. When no DTD answers the multi-DTD probe but the primary DTD is connected, `knownApps` falls back to that DTD's list. `knownAppsError` appears when the listing itself failed.

Other optional fields: `viewedSessionId` (a `session_open` view is active), `stale` (sessions whose app died while attached: `sessionId`, `appName`, `vmServiceUri`, `diedAtMs`, `reason`, and `movedTo` when the app came back under another session), `recentlyEnded` (the last few sessions that ended because the app exited: `sessionId`, `appName`, `endedReason`, `diedAtMs`), `dtdProbeErrors` (DTDs that failed to answer the probe).

`capabilities` is the string `"all"` when every category is enabled, or an array of category keys when the user passed `--capabilities` / `--disable`. `dtd.connectError` appears (string) when the auto-connect attempt fails. `autoAttached` appears only when `attachIfOne:true` actually triggered an attach.

**The `mcp` block (0.6.2+)** carries `version`, `commit` (when the SHA is known — baked at install time or read via git rev-parse under JIT), `isAot` (true = native binary from `flutter_network_mcp install`, false = JIT wrapper), and `upgradeCommand`. When the daily background check has flagged a newer release, an additional `updateAvailable: { latest, checkedAtMs }` field appears — the agent should mention the upgrade to the user and offer to run `flutter_network_mcp update`.

**The `alerts` block (0.6.3+).** `pendingTotal` is the count of DISTINCT signatures: what you branch on for "should I drain?". `pendingEvents` is the SUM of `occurrence_count` across pending rows: what you'd quote when telling the user "there's a burst of 200 events queued, 1 distinct issue." They diverge whenever any single alert collapsed multiple source events into one row (the typical RenderFlex-overflow-in-a-list case). `critical` counts distinct signatures whose escalated severity has reached `critical`. With 2+ sessions attached, `alerts.perAttached` gives the same split per session: `{sessionId, appName, pending, pendingEvents}`.

**The `continuation` block (0.7.3+).** Appears only when `attachedCount == 0` AND a prior attachment was recorded by a previous MCP-host process. Shape:

```jsonc
"continuation": {
  "writtenAtMs": 1780462000000,
  "attachments": [
    {
      "vmServiceUri": "http://127.0.0.1:54450/abc=/",
      "appName": "eats_mobile",
      "attachedAtMs": 1780461000000
    }
  ]
}
```

When present, the FIRST `nextSteps` line is about that app. If it is still reachable: a `network_attach vmServiceUri:"..."` reattach hint with a coarse "attached ~47m ago". If it relaunched at a new URI (same package + device listed in `knownApps`): a `network_attach` hint with the new URI. If it is gone (this process saw it die, or the DTDs answered and none lists it): "<app> has exited ~2m ago; relaunch it and network_attach, or network_wait_for_app to block until it is back". A failed DTD probe is not taken as proof that the app exited. Picking up where the previous session left off is usually the right move. Explicit detach removes the continuation, so its presence means the prior session ended via host restart / crash / reload, not user intent. Multi-attach friendly: all previously-attached sessions appear in the array.

## Pairs well with

- `network_attach` — `nextSteps` usually points here.
- `alerts_drain` — when `alerts.pendingTotal > 0`.
- `session_list` — when no live session and the user is asking about history.

## Example

```
> network_status
< {attachedCount:0, attached:[], capabilities:"all",
   dtd:{connected:true, uri:"ws://..."},
   knownApps:[{name:"Kind: Flutter - iPhone 17 - Package: eats_mobile", uri:"ws://..."}],
   nextSteps:["Call network_attach (one app available — will be auto-picked)"]}
> network_attach
```

Or one-shot:

```
> network_status attachIfOne:true
< {attachedCount:1, attached:[{sessionId:14, ...}], autoAttached:{attached:true, liveSessionId:14, ...},
   nextSteps:["Drive the app, then call network_list (returns nextCursor for incremental polling)"]}
```
