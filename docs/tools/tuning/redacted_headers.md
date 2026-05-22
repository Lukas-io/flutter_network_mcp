---
tool: redacted_headers
description: Manage the header name allowlist that network_replay masks. Adds to a built-in set; safe by default.
when_to_use: When the project has custom auth/sensitive headers (X-Tenant-Key, X-Internal-Auth) that should be masked in shared curls.
---

## DO NOT USE THIS TOOL WHEN

- The header is one of the built-in defaults (`authorization`, `cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token`) — always redacted; the tool refuses to add or remove these.
- You want to redact bodies — this only affects headers. Use SQL UPDATE for bulk body redaction.
- You want capture-time redaction — this is replay-time. Original header values stay in the DB.
- Local debugging with `redact:false` on `network_replay` — that bypasses everything; this list is irrelevant.

## Use this when

- The project uses custom auth headers you don't want in shared replays.
- Onboarding a new MCP install on a project with non-standard auth.

## How it works

Names normalized to lowercase. `network_replay` reads `redactedHeaderSet()` (built-ins + extras) on every call — changes take effect immediately.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `name` (string, required for add/remove) — case-insensitive.
- `reason` (string, optional, add only).

## Returns

```json
// list
{"action":"list",
 "summary":"6 redacted header name(s): 5 built-in, 1 project-specific.",
 "builtins":["authorization","cookie","proxy-authorization","x-api-key","x-auth-token"],
 "extras":[{"name":"x-tenant-key", "addedMs":..., "reason":"internal"}],
 "total":6,
 "nextSteps":[...]}

// add
{"action":"add",
 "summary":"Added \"x-tenant-key\" to redacted headers. network_replay will mask it on next call.",
 "name":"x-tenant-key", "inserted":true,
 "nextSteps":["network_replay id:<id> — confirm the header now shows as <redacted>"]}

// remove
{"action":"remove",
 "summary":"Removed \"x-tenant-key\" from redacted headers. network_replay will now show its value.",
 "name":"x-tenant-key", "removed":true}
```

Attempting to add a built-in returns success with `inserted:false` and a `warnings` array noting the no-op. Attempting to remove a built-in returns an error with a clear explanation.

## Pairs well with

- `network_replay` — verify the new header is masked.

## Example

```
> redacted_headers action:"add" name:"X-Tenant-Key" reason:"multi-tenant token"
< {summary:"Added \"x-tenant-key\"...", inserted:true}
> network_replay id:abc
< {curl: "... -H 'X-Tenant-Key: <redacted>' ..."}
```
