---
tool: session_export
description: Write a session to disk as HAR 1.2 (Chrome DevTools / Insomnia compatible) or NDJSON.
when_to_use: When the user wants to share a session, archive it outside the DB, or open it in another tool.
---

## DO NOT USE THIS TOOL WHEN

- The user wants you to inspect — open it via `session_open` and use read tools. Export is for offline handoff.
- The session is still live — export still works but is a snapshot. The tool warns and suggests detaching first.
- You want a partial export (one request): there's no filter. Use `network_replay` for a single request as curl, or `network_query` for a SQL-filtered row set (returned in the reply, not written to a file).
- You're sharing externally without `redact:true`: by default headers, cookies, and bodies are written verbatim. `redact:true` masks header values only (see below); bodies and URLs are never redacted.
- You want sockets or logs in a file: neither format includes them (only the `counts` block mentions them).

## Use this when

- "Send me a HAR of yesterday's session" — exactly this.
- Archiving a session before `session_delete`.
- Bridging into Postman / Insomnia / Chrome DevTools / har-analyzer.

## How it works

Reads the session's HTTP rows from the DB (up to 100,000, newest-first by start time) and writes them to `outPath`. Sockets and logs are not exported.

`format:"har"`: HAR 1.2 JSON. Per entry: method, URL, request/response headers, query string, `postData` (request body), status, reason phrase, `content` (response body), `redirectURL` (the Location of the last redirect hop, else empty), and `time`. Bodies with a text content type are written as UTF-8 `text`; others as base64 with `encoding:"base64"`. `httpVersion` is always `HTTP/1.1`, `cookies` arrays are empty, and `timings` puts the whole duration in `wait` (`-1` for in-flight requests). The app name goes in `log.browser.name`; the session note is not included.

`format:"ndjson"`: first line is the session row (`type:"session"`, including `note`), then one line per HTTP row (`type:"request"`) with the raw DB columns (headers as JSON strings). No bodies. Useful for grep/jq.

Bodies are exported exactly as captured. With `session_configure bodyDecryption` on, the HAR still carries the original (possibly encrypted) bytes; decryption applies only to the read tools.

`redact:true` replaces the values of the redacted header set with `<redacted>` in both formats: the built-ins (`authorization`, `cookie`, `proxy-authorization`, `set-cookie`, `x-api-key`, `x-auth-token`) plus names added with `redacted_headers`. Response cookies (`set-cookie`) are masked too.

Both formats create parent directories and overwrite an existing file. The tool runs without the per-tool deadline, so a large session does not time out.

## Args

- `id` (int, required).
- `format` (string, required): `"har"` or `"ndjson"`.
- `outPath` (string, required): absolute path to write to. A relative path is not rejected; it resolves against the server process's working directory.
- `redact` (bool, default false): mask auth header values (see above).

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

`warnings` fires for: the session is this process's sole live session (the file is a snapshot), an existing file was overwritten, a HAR with 0 requests, and any export with HTTP rows (unredacted headers and bodies without `redact:true`; bodies still unredacted with it). For NDJSON the first nextStep is a `jq` hint instead of the DevTools import.

Errors: missing `id` or `outPath`, or a `format` other than `"har"` / `"ndjson"`, returns `bad_argument`; an unknown id returns `not_found`; a write failure (for example an unwritable path) returns `internal` with `sessionId`, `outPath`, and nextSteps to check the directory and the id.

## Pairs well with

- `session_list` — find the id.
- `network_detach`: call before export for a clean `ended_at`. If another server process is still attached to the same session, the row stays open until that process detaches too.
- `session_note` — annotate before sharing.

## Example

```
> session_export id:14 format:"har" outPath:"/tmp/auth-bug.har"
< {summary:"Exported session 14...", sizeBytes:12435}
```
