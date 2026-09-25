---
tool: redacted_headers
description: Manage the header names masked as <redacted> in network_get, network_replay, network_replay_as_test, network_diff and redacted session exports. Adds to a built-in set; safe by default.
when_to_use: When the project has custom auth/sensitive headers (X-Tenant-Key, X-Internal-Auth) that should be masked in shared curls.
---

## DO NOT USE THIS TOOL WHEN

- The header is one of the built-in defaults (`authorization`, `cookie`, `proxy-authorization`, `set-cookie`, `x-api-key`, `x-auth-token`): always redacted. Adding one is a no-op (success with a warning); removing one is refused.
- You want to redact bodies: this only affects headers. Bodies cannot be edited in place (`network_query` is read-only); `bodies_purge` deletes stored bodies.
- You want capture-time redaction: this applies when a tool renders headers. Original header values stay in the DB.
- Local debugging with `redact:false` on `network_get`, `network_replay` or `network_replay_as_test`: that bypasses redaction entirely; this list is irrelevant.

## Use this when

- The project uses custom auth headers you don't want in shared replays.
- Onboarding a new MCP install on a project with non-standard auth.

## How it works

Names are trimmed and lowercased before storing and before the built-in check, and matched case-insensitively. Every consumer reads `redactedHeaderSet()` (built-ins + extras) on each call, so changes take effect immediately:
- `network_get`, `network_replay`, `network_replay_as_test`: redact by default; `redact:false` shows real values.
- `network_diff`: always redacts in the header diff.
- `session_export`: only when called with `redact:true` (its default is false).

Extras persist in the DB across restarts. The tool exists only when the `admin` capability is enabled.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `name` (string, required for add/remove) — case-insensitive.
- `reason` (string, optional, add only).

## Returns

```json
// list
{"action":"list",
 "summary":"7 redacted header name(s): 6 built-in, 1 project-specific.",
 "builtins":["authorization","cookie","proxy-authorization","set-cookie","x-api-key","x-auth-token"],
 "extras":[{"name":"x-tenant-key", "addedMs":..., "reason":"internal"}],
 "total":7,
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

Attempting to add a built-in returns success with `inserted:false` and a `warnings` array noting the no-op. Re-adding an existing extra returns `inserted:false` and refreshes its reason and timestamp. Removing a name that is not stored succeeds with `removed:false`. `reason` is omitted from extras that have none.

Errors: `bad_argument` for a missing `name` on add/remove, an unknown `action`, or an attempt to remove a built-in (its nextSteps point at `redact:false` for local debugging); `internal` for anything else.

## Pairs well with

- `network_replay` — verify the new header is masked.

## Example

```
> redacted_headers action:"add" name:"X-Tenant-Key" reason:"multi-tenant token"
< {summary:"Added \"x-tenant-key\"...", inserted:true}
> network_replay id:abc
< {curl: "... -H 'X-Tenant-Key: <redacted>' ..."}
```
