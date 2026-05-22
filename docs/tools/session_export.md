---
tool: session_export
description: Write a session to disk as HAR 1.2 (Chrome DevTools format) or NDJSON.
when_to_use: When the user wants to share a session with a coworker, archive it outside the DB, or open it in another tool.
---

## DO NOT USE THIS TOOL WHEN

- The user wants you to inspect the session — open it with `session_open` and use the read tools. Export is for offline handoff.
- The session has no `ended_at` (still live) — export still works but you'll get a snapshot, not the full session. Detach first for a clean export.
- You want a partial export (just one request) — there's no filter. Use `network_replay` for a single request as curl, or write NDJSON via custom SQL.
- The session contains sensitive auth headers and you're sharing externally — HAR includes everything verbatim. Strip via SQL UPDATE before export if needed.

## Use this when

- "Send me a HAR file of yesterday's session" — exactly this.
- Archiving a session before deleting old data from the DB.
- Bridging into a tool that can ingest HAR (Postman, Insomnia, Chrome DevTools, har-analyzer).

## How it works

`format:"har"` — writes HAR 1.2 JSON. Per-entry includes request method, URL, headers, query string, postData (request body decoded as utf8 if possible, else base64), response status, headers, content (decoded body), timing.

`format:"ndjson"` — writes one JSON line per record: first line is the session row, then one line per request. Useful for grep/jq.

Both formats create parent directories as needed.

## Args

- `id` (int, required).
- `format` (string, required) — `"har"` or `"ndjson"`.
- `outPath` (string, required) — absolute path to write to.

## Returns

```json
{"exported": true, "sessionId": 14, "format": "har",
 "outPath": "/tmp/session-14.har"}
```

## Pairs well with

- `session_list` — find the id.
- `network_detach` — call before export for a clean `ended_at`.

## Example

```
> session_export id:14 format:har outPath:/tmp/auth-bug.har
< {exported:true}
```
