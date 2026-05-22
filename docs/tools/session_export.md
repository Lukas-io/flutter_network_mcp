---
tool: session_export
description: Write a session to disk as HAR 1.2 (Chrome DevTools / Insomnia compatible) or NDJSON.
when_to_use: When the user wants to share a session, archive it outside the DB, or open it in another tool.
---

## DO NOT USE THIS TOOL WHEN

- The user wants you to inspect — open it via `session_open` and use read tools. Export is for offline handoff.
- The session is still live — export still works but is a snapshot. The tool warns and suggests detaching first.
- You want a partial export (one request) — there's no filter. Use `network_replay` for a single request as curl, or `network_query` to ndjson via SQL.
- The session has sensitive headers and you're sharing externally — HAR includes everything verbatim. Strip via SQL UPDATE before export, or set `redacted_headers` for future captures.

## Use this when

- "Send me a HAR of yesterday's session" — exactly this.
- Archiving a session before `session_delete`.
- Bridging into Postman / Insomnia / Chrome DevTools / har-analyzer.

## How it works

`format:"har"` — writes HAR 1.2 JSON. Per-entry: method, URL, headers, query string, postData (request body decoded as utf8 if possible, else base64), status, headers, content, timing.

`format:"ndjson"` — first line is the session row, then one JSON line per request. Useful for grep/jq.

Both formats create parent directories. Returns the file size and a `warnings` block when the session is still live OR the output file already existed.

## Args

- `id` (int, required).
- `format` (string, required) — `"har"` | `"ndjson"`.
- `outPath` (string, required) — absolute path.

## Returns

```json
{
  "summary": "Exported session 14 (38 http, 12 log(s), 3 socket(s)) to /tmp/auth-bug.har (har, 12435 bytes).",
  "exported": true,
  "sessionId": 14,
  "format": "har",
  "outPath": "/tmp/auth-bug.har",
  "sizeBytes": 12435,
  "counts": {"http":38, "sockets":3, "logs":12},
  "nextSteps": [
    "Open /tmp/auth-bug.har in Chrome DevTools (Network tab → Import HAR)",
    "session_note id:14 note:\"...\" — annotate before sharing"
  ]
}
```

`warnings: []` fires for: live session (snapshot), file overwritten, HAR with 0 requests.

## Pairs well with

- `session_list` — find the id.
- `network_detach` — call before export for a clean `ended_at`.
- `session_note` — annotate before sharing.

## Example

```
> session_export id:14 format:"har" outPath:"/tmp/auth-bug.har"
< {summary:"Exported session 14...", sizeBytes:12435}
```
