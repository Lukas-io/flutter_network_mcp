---
tool: capture_allow
description: Manage the capture ALLOWLIST. When non-empty, only requests matching a host/path glob are captured; everything else is dropped.
when_to_use: For focused debugging — "I only care about /stock/*". The inverse of ignored_hosts.
---

## DO NOT USE THIS TOOL WHEN

- You only want to drop a few noisy things — that's `ignored_hosts` (a denylist). The allowlist drops EVERYTHING that doesn't match.
- You want to filter at READ time: use `network_list hostContains:` (there is no path filter on `network_list`; `network_search` matches URL text). This drops requests at CAPTURE time; they never enter history.
- You expect already-captured rows to disappear — entries take effect on the next capture tick; existing rows stay.

## Use this when

- You care about one slice of traffic and the rest is noise ("just the `/stock-commodities/*` calls").
- A denylist would mean enumerating everything noisy — an allowlist is one line instead.

## How it works

`add`/`remove` write to the `capture_allow` table (persistent across restarts) and refresh the `CaptureFilter` of every attached session's capture writer immediately; `list` reads the table. The effective allowlist is the **union** of this table and the `FLUTTER_NETWORK_MCP_CAPTURE_ALLOW` startup env var (comma-separated). `list` here shows only the table entries; `ignored_hosts action:"list"` shows the full union under `captureAllowlist.patterns`. A request is captured when `(allowlist empty OR it matches the allowlist) AND it is not matched by the ignored_hosts denylist`, so **deny still wins inside the allowed set**.

Same pattern syntax as `ignored_hosts`, compared case-insensitively against `host + path` (no scheme, port or query):
- An entry with **no `/`** is an exact host match. Wildcards are not expanded there, so `*.example.com` matches nothing.
- An entry **with `/`** is a glob (`*` = any chars, `?` = one char) anchored to the whole `host + path`. `api.example.com/stock/*` matches every path under `/stock/`; `api.example.com/stock` matches only that exact path; `*.example.com/*` matches every subdomain.

The filter is checked on every capture tick before a request is stored, so a dropped request also skips alert detection and search indexing. Only HTTP requests are filtered; sockets and logs are unaffected. A request that was already stored but is still in flight when it becomes filtered stops receiving updates.

Patterns are stored as given. `remove` matches the stored string exactly, so pass it as `list` shows it.

## Args

- `action` (string, default `"list"`) — `"list"` | `"add"` | `"remove"`.
- `pattern` (string, required for add/remove) — host or host/path glob. No scheme, no port.
- `reason` (string, optional, add only): shown in list output. Re-adding an existing pattern replaces its reason and timestamp (`inserted:false`).

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

// remove
{"action":"remove", "summary":"Removed \"api.example.com/stock/*\" from the allowlist. If the allowlist is now empty, all requests are captured again.",
 "pattern":"api.example.com/stock/*", "removed":true, "nextSteps":[...]}
```

`add` always carries the warning, including when it only updated an existing entry. An empty `list` says every request is captured unless `ignored_hosts` skips it. Removing a pattern that is not in the table succeeds with `removed:false`.

Errors: `bad_argument` for a missing `pattern` on add/remove or an unknown `action`; `internal` for anything else. Both carry `nextSteps`.

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
