---
tool: capture_allow
description: Manage the capture ALLOWLIST. When non-empty, only requests matching a host/path glob are captured; everything else is dropped.
when_to_use: For focused debugging — "I only care about /stock/*". The inverse of ignored_hosts.
---

## DO NOT USE THIS TOOL WHEN

- You only want to drop a few noisy things — that's `ignored_hosts` (a denylist). The allowlist drops EVERYTHING that doesn't match.
- You want to filter at READ time — use `network_list pathContains:` / `hostContains:`. This drops requests at CAPTURE time; they never enter history.
- You expect already-captured rows to disappear — entries take effect on the next capture tick; existing rows stay.

## Use this when

- You care about one slice of traffic and the rest is noise ("just the `/stock-commodities/*` calls").
- A denylist would mean enumerating everything noisy — an allowlist is one line instead.

## How it works

`add`/`remove` write to the `capture_allow` table and refresh the writer's `CaptureFilter` immediately; `list` reads it. The effective allowlist is the **union** of this table and the `FLUTTER_NETWORK_MCP_CAPTURE_ALLOW` startup env var. A request is captured when `(allowlist empty OR it matches the allowlist) AND it is not matched by the ignored_hosts denylist` — so **deny still wins inside the allowed set**.

Patterns are host or `host/path` globs (`*` = any chars, `?` = one char), matched case-insensitively against `host + path`. Same syntax as `ignored_hosts`.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `pattern` (string, required for add/remove) — host or host/path glob. No scheme, no port.
- `reason` (string, optional, add only).

## Returns

```json
// add (allowlist becomes active)
{"action":"add", "summary":"Added \"api.example.com/stock/*\" to the capture allowlist. From now ONLY matching requests are captured.",
 "pattern":"api.example.com/stock/*", "inserted":true,
 "warnings":["The allowlist is now active: requests that do NOT match any allow pattern are dropped at capture time. Already-captured rows are unaffected."],
 "nextSteps":[...]}

// list
{"action":"list", "summary":"1 allowlist pattern(s) — ONLY matching requests are captured; everything else is dropped.",
 "count":1, "patterns":[{"pattern":"api.example.com/stock/*", "addedMs":..., "reason":"focus"}],
 "envNote":"FLUTTER_NETWORK_MCP_CAPTURE_ALLOW adds startup patterns too; both unions apply.", "nextSteps":[...]}
```

## Pairs well with

- `ignored_hosts` — the denylist counterpart; deny wins inside the allowed set. Both are surfaced in `ignored_hosts action:list` as `captureAllowlist`.
- `network_list` — confirm only allowed requests are appearing.

## Example

```
> capture_allow action:"add" pattern:"api.example.com/stock/*" reason:"only debugging stocks"
< {summary:"Added ... ONLY matching requests are captured", inserted:true}
> network_list
< {requests:[ ...only /stock/* ... ]}
> capture_allow action:"remove" pattern:"api.example.com/stock/*"
< {summary:"Removed ... all requests are captured again"}
```
