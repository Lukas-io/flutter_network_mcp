---
tool: redacted_headers
description: Add project-specific header names to the redaction set used by network_replay.
when_to_use: When the project has custom auth headers (X-Tenant-Key, X-Internal-Auth) that should be hidden in shared curls.
---

## DO NOT USE THIS TOOL WHEN

- The header is one of the built-in defaults (`authorization`, `cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token`) — they're always redacted; this tool refuses to remove them.
- You want to redact request bodies — this only affects headers. Use SQL UPDATE for bulk body redaction.
- You're trying to redact at capture time — this happens at replay time. The original header values stay in the DB. If you need capture-time redaction, that's a different feature (not yet built).
- The user is debugging locally with `redact:false` — they're already opting out. This setting only applies when `redact:true` (the default).

## Use this when

- The project uses custom auth headers you don't want in shared replays.
- Onboarding a new MCP install on a project with non-standard auth.

## How it works

Names are normalized to lowercase. The `network_replay` tool reads `redacted_header_set()` on every call — changes take effect immediately. The built-in set is always returned regardless of DB state.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `name` (string) — header name (required for add/remove). Case-insensitive.
- `reason` (string, optional, add only).

## Returns

```json
// list
{"builtins":["authorization","cookie","proxy-authorization","x-api-key","x-auth-token"],
 "extras":[{"name":"x-tenant-key","addedMs":..., "reason":"internal"}],
 "total":6}

// add
{"action":"add", "name":"x-tenant-key", "inserted":true}

// remove
{"action":"remove", "name":"x-tenant-key", "removed":true}
```

## Pairs well with

- `network_replay` — verify the new header is masked.

## Example

```
> redacted_headers action:add name:"X-Tenant-Key" reason:"internal multi-tenant token"
< {inserted:true}
> network_replay id:abc
< {curl: "... -H 'X-Tenant-Key: <redacted>' ..."}
```
