---
tool: auto_attach_config
description: Reads + mutates the persistent auto-attach config at `<data-dir>/auto-attach.json`. Lets the agent honor `autoAttachSuggestion` (from `network_attach` since 0.6.2) without asking the user to edit shell rc — confirm with the user, then call this tool to persist.
when_to_use: After `network_attach` returns `autoAttachSuggestion` and the user has CONFIRMED they want the app added. Don't call without explicit user confirmation — this is a persistent config change.
---

## DO NOT USE THIS TOOL WHEN

- The user hasn't confirmed — the `autoAttachSuggestion` field's `agentAction` is explicit: "ASK THE USER" first. Persisting without confirmation is a trust violation.
- You're trying to change the allowlist for THIS process. The auto-attach watcher reads its allowlist at startup, so `add` / `remove` / `clear` take effect at the next MCP-host launch; env vars / CLI flags override per-launch. (`action:"set"` is different: `logBufferSize` / `nativeLogs` apply to the next attach in this process too.)
- The user wants per-machine fine-grained control they want versioned in their dotfiles — the JSON file is per-user-data-dir. Direct them to set `FLUTTER_NETWORK_MCP_AUTO_ATTACH` in shell rc instead.

## Use this when

- `network_attach` returned `autoAttachSuggestion` and the user said "yes, add it."
- The user explicitly wants to see / clean up their current allowlist (`action:"list"` or `action:"clear"`).
- Removing an app the user no longer debugs.
- The user wants a bigger log buffer or the native device log on every attach, auto or manual (`action:"set"`).

## How it works

The file lives at `<data-dir>/auto-attach.json`:

```jsonc
{
  "allowed": ["sanga_mobile", "sanga_driver"],
  "denied": ["iPhone 7"],
  "logBufferSize": 8000,
  "nativeLogs": true,
  "writtenAtMs": 1780462000000
}
```

Resolution order at the next MCP-host launch:

1. Read `<data-dir>/auto-attach.json` as the BASE.
2. Apply `FLUTTER_NETWORK_MCP_AUTO_ATTACH` / `FLUTTER_NETWORK_MCP_AUTO_ATTACH_DENY` env vars (if set) as overrides.
3. Apply `--auto-attach` / `--auto-attach-deny` CLI flags (if set) as final overrides.

Step 3 wins over step 2 wins over step 1. The file is the persistent default; env vars + flags are per-launch overrides.

This closes the `claude mcp remove + claude mcp add --auto-attach=...` friction the user complained about in 0.6.2 — the agent just calls this tool on confirmation.

## Args

- `action` (string, default `"list"`): `"list"` | `"add"` | `"remove"` | `"clear"` | `"set"`. Any other value errors with `errorKind: bad_argument`.
- `app` (string) — required for `"add"` and `"remove"`. Case-insensitive substring matched against DTD app names.
- `deny` (string) — optional, supplied alongside `app` on an `"add"` to also extend the denylist.
- `logBufferSize` (int, 50 to 20000): with `action:"set"`, the log ring capacity every attach uses unless the call passes its own. Without it, attaches use `FLUTTER_NETWORK_MCP_LOG_BUFFER` or 2000. Out of range errors with `bad_argument`.
- `nativeLogs` (bool): with `action:"set"`, also stream the device's native log (`simctl log stream` / `adb logcat`) on every attach.

`action:"set"` needs at least one of `logBufferSize` / `nativeLogs` (else `bad_argument`). `add` / `remove` without `app` error with `bad_argument`. `clear` empties `allowed` and `denied` but keeps `logBufferSize` and `nativeLogs`.

## Returns

**`action:"list"`:**
```jsonc
{
  "enabled": true,
  "allowed": ["sanga_mobile"],
  "denied": [],
  "logBufferSize": 8000,
  "nativeLogs": true,
  "filePath": "/Users/me/Library/Application Support/flutter_network_mcp/auto-attach.json",
  "nextSteps": [...]
}
```

**`action:"add"`:**
```jsonc
{
  "action": "add",
  "app": "sanga_mobile",
  "alreadyPresent": false,
  "allowed": ["sanga_mobile"],
  "denied": [],
  "persisted": true,
  "filePath": "/Users/me/.../auto-attach.json",
  "nextSteps": [
    "Tell the user: \"sanga_mobile\" added to auto-attach. Effective on next MCP-host restart unless an env var or CLI flag overrides.",
    "auto_attach_config action:\"list\" — verify current state"
  ]
}
```

`logBufferSize` / `nativeLogs` appear in the `list` reply only when set.

**`action:"set"`:**
```jsonc
{
  "action": "set",
  "logBufferSize": 8000,
  "persisted": true,
  "filePath": "/Users/me/.../auto-attach.json",
  "summary": "Applies to the next attach (auto or manual); sessions already attached keep their current buffer.",
  "nextSteps": ["network_status ..."]
}
```

`remove` returns `{action, app, removed, allowed, denied, persisted, filePath, nextSteps}`; `clear` returns `{action, allowed:[], denied:[], persisted, filePath, nextSteps}`.

`persisted:false` means the in-memory state was updated but the write failed (filesystem permissions, full disk, etc.) — the change reverts at next process restart.

## Pairs well with

- `network_attach` — the autoAttachSuggestion field on its response is the upstream trigger for this tool.
- `network_status` — confirm `attachedCount > 0` before suggesting auto-attach (no point persisting for an app that isn't running).
- `report_issue` — if this tool fails with `persisted:false`, file a bug.

## Example flow

```
> network_attach
< {attached:true, autoAttachSuggestion:{
    appName:"Flutter - iPhone 17 - Package: sanga_mobile",
    pattern:"sanga_mobile",
    agentAction:"ASK THE USER..."}}
> # agent to user: "Would you like flutter_network_mcp to auto-attach to sanga_mobile on future launches?"
> # user: "yes"
> auto_attach_config action:"add" app:"sanga_mobile"
< {persisted:true, allowed:["sanga_mobile"]}
> # agent: "Done. sanga_mobile will auto-attach next time you launch the MCP."
```
