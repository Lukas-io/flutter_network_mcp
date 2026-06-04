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
- You expect `attachIfOne:true` to attach across multiple apps — it only fires when DTD has exactly ONE app. Multi-app DTDs require explicit `network_attach appNameContains:"..."`.

## Use this when

- Starting a debugging conversation — call this first.
- Confirming what capabilities the server was started with (the `--capabilities` flag is visible in the response).
- Checking whether stale alerts are waiting from past sessions (`alerts.pendingTotal > 0`).
- Discovering known DTD apps without calling attach.
- "Orient and attach in one shot" — `attachIfOne:true` when you trust the heuristic.

## How it works

Reads in-process state. If `connectDtd:true` (default) and DTD isn't already connected and a default URI exists, opens DTD with a 5s timeout. Queries the alerts table for three counts (current scope / DB-wide / critical). Reads the DB path and session count. Synthesizes a 1–2 item `nextSteps` array based on state.

**Multi-DTD enumeration (0.6.2+).** `knownApps` lists apps across EVERY live DTD on the local machine, not just the one the primary connection is on. Each `flutter run` spawns its own DTD; this tool probes every discovered DTD via transient `DtdClient` connections (parallel, 1.5s per-probe timeout, 30s cache) so a user with three `flutter run`s in three terminals sees three apps. Each entry carries a `dtdUri` + `workspaceRoot` naming the source DTD — the agent can pass `dtdUri:"<that one>"` to `network_attach` to switch DTDs explicitly, though passing `vmServiceUri:` directly bypasses DTD entirely. Per-DTD probe errors surface under `dtdProbeErrors`.

When `attachIfOne:true` AND `attached:false` AND `knownApps.length == 1` AND `defaultDtdUri != null`, the call additionally runs the full attach flow (same as `network_attach` with no args). The attach result is returned under `autoAttached`, and the top-level `attached`/`vmService`/`liveSessionId` fields are refreshed in the same response.

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
  "attached": false,
  "capabilities": "all",
  "dtd": {"connected": true, "uri": "ws://...", "defaultUri": "ws://..."},
  "vmService": {"connected": false, "uri": null, "isolateId": null, "appName": null},
  "liveSessionId": null,
  "viewedSessionId": null,
  "dbPath": "/Users/me/.local/share/flutter_network_mcp/captures.db",
  "sessionCount": 0,
  "alerts": {"pendingTotal": 0, "pendingEvents": 0, "critical": 0},
  "knownApps": [
    {
      "name": "sanga_mobile - iPhone 17",
      "uri": "ws://127.0.0.1:54450/...",
      "dtdUri": "ws://127.0.0.1:56443/...",
      "workspaceRoot": "/Users/me/StudioProjects/sanga_mobile"
    }
  ],
  "dtdProbeErrors": [],
  "nextSteps": ["Call network_attach (one app available — will be auto-picked)"]
}
```

`capabilities` is the string `"all"` when every category is enabled, or an array of category keys when the user passed `--capabilities` / `--disable`. `dtd.connectError` appears (string) when the auto-connect attempt fails. `autoAttached` appears only when `attachIfOne:true` actually triggered an attach.

**The `mcp` block (0.6.2+)** carries `version`, `commit` (when the SHA is known — baked at install time or read via git rev-parse under JIT), `isAot` (true = native binary from `flutter_network_mcp install`, false = JIT wrapper), and `upgradeCommand`. When the daily background check has flagged a newer release, an additional `updateAvailable: { latest, checkedAtMs }` field appears — the agent should mention the upgrade to the user and offer to run `flutter_network_mcp update`.

**The `alerts` block (0.6.3+).** `pendingTotal` is the count of DISTINCT signatures — what you branch on for "should I drain?". `pendingEvents` is the SUM of `occurrence_count` across pending rows — what you'd quote when telling the user "there's a burst of 200 events queued, 1 distinct issue." They diverge whenever any single alert collapsed multiple source events into one row (the typical RenderFlex-overflow-in-a-list case). `critical` counts distinct signatures whose escalated severity has reached `critical`. The multi-attach `perAttached` block gets `pendingEvents` too, mirroring the same shape per-session.

## Pairs well with

- `network_attach` — `nextSteps` usually points here.
- `alerts_drain` — when `alerts.pendingTotal > 0`.
- `session_list` — when no live session and the user is asking about history.

## Example

```
> network_status
< {attached:false, capabilities:"all",
   dtd:{connected:true, uri:"ws://..."},
   knownApps:[{name:"Kind: Flutter - iPhone 17 - Package: sanga_mobile", uri:"ws://..."}],
   nextSteps:["Call network_attach (one app available — will be auto-picked)"]}
> network_attach
```

Or one-shot:

```
> network_status attachIfOne:true
< {attached:true, autoAttached:{liveSessionId:14, ...}, nextSteps:["Drive the app, then call network_list"]}
```
