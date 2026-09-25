---
tool: network_diff
description: Structural diff of two captured HTTP requests in the same session.
when_to_use: When you have two captured ids and need to know what's different — status, method, URL, headers, response body hunks.
---

## DO NOT USE THIS TOOL WHEN

- The ids are in different sessions: the diff only operates within ONE session. To compare two runs endpoint by endpoint, use `network_diff_session`.
- You only need to know if status changed — `network_list` shows it in summaries.
- One of the bodies is binary — body diff is skipped (the response surfaces this in `warnings`).
- You want a semantic JSON diff: this compares line N of A with line N of B. Minified JSON is one line, so any change shows as one clipped `-`/`+` pair. For response-shape changes use `network_drift`; for field-level queries use `network_body_query` on each id.
- You want to compare request headers or request bodies: only response headers and the response body are diffed. Use `network_get` on both ids.
- `idA == idB` — the tool errors. You're not diffing anything.

## Use this when

- Same endpoint, working vs broken state ("yesterday vs today's auth call").
- Investigating a regression after a refactor ("did the response change?").
- Confirming a retry got an identical response.

## How it works

Pulls both `http_requests` rows and response bodies from the DB (live or history; the VM is never queried, so a request that is not persisted yet reports `not_found` or an uncomparable body). Computes a header diff (added / removed / changed) on the response headers, with names lowercased and auth-like headers (`authorization`, `cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token`, plus `redacted_headers` names) always shown as `<redacted>`. Decodes both response bodies; if both are UTF-8 text by content type, splits them on newlines and compares line N of A with line N of B (no alignment, so one inserted line shifts every later line into the hunks), up to `maxBodyLines` per side, clipping each line at `maxLineLength`. Status/method/URL diffs are reported only when changed.

Body decryption: when `session_configure bodyDecryption:{...}` is on, both response bodies are decrypted before diffing (a body that does not fit the scheme is diffed as captured). Each side's block (`a`, `b`) then carries the same flags `network_body` returns: `decrypted: true`, or `decrypted: false` with `decryptionFailed` giving the reason, and a warning names a side that did not decrypt. A side with no stored body carries no flag.

## Args

- `idA` (string, required).
- `idB` (string, required). Must differ from `idA`.
- `sessionId` (int, optional): session both ids belong to. Omit to auto-resolve (the sole attached session, or the one you opened).
- `appNameContains` (string, optional): pick the attached session by app-name substring.
- `maxBodyLines` (int, default 200, hard cap 1000): 0 or negative means the default.
- `maxLineLength` (int, default 2000, hard cap 8000): 0 or negative means the default.

## Returns

```json
{
  "scope": {"sessionId": 14, "isLive": false},
  "sessionId": 14,
  "summary": "POST https://api.example.com/v1/login → 500  vs  POST https://api.example.com/v1/login → 200  →  differs: status, 1 header, body.",
  "a": {"id":"x","method":"POST","url":"...","statusCode":500,"durationMs":180},
  "b": {"id":"y","method":"POST","url":"...","statusCode":200,"durationMs":4500},
  "statusDiff": {"a":500, "b":200},
  "responseHeaders": {"added":{}, "removed":{}, "changed":{"content-length":{"a":"40","b":"31"}}},
  "responseBody": {"comparable":true, "equal":false, "truncated":false, "lineTruncated":false,
                   "hunks":["- {\"error\":\"x\"}","+ {\"ok\":true}"]},
  "nextSteps": [
    "network_get id:\"x\" — full detail on request A",
    "network_get id:\"y\" — full detail on request B",
    "network_replay id:\"x\" / id:\"y\" — emit curls to reproduce both"
  ]
}
```

`statusDiff` / `methodDiff` / `urlDiff` only appear when changed. Identical bodies give `{"comparable":true, "equal":true, "hunks":[]}`. When a body is missing or either body is not UTF-8 text, `responseBody` is `{"comparable":false, "reason":"..."}` and a warning says so. `warnings` (omitted when empty) also surfaces a body that did not decrypt (decryption on), truncation at `maxBodyLines`, and clipped lines. The `network_replay` next step only appears when the bodies were comparable and differ.

Errors: `bad_argument` (an id missing, or `idA` equal to `idB`), `not_found` (either id not in the session), `internal` (unexpected failure). Scope failures return `error` + `nextSteps` without an `errorKind`.

## Pairs well with

- `network_list` — find the two ids.
- `network_search` — find ids by content match, then diff.
- `network_get` — full detail on either side.
- `network_replay` — reproduce both.
- `network_diff_session`: the same question across two whole runs, per endpoint.

## Example

```
> network_list hostContains:"auth" limit:5
< [{id:"before", statusCode:200}, {id:"after", statusCode:401}]
> network_diff idA:"before" idB:"after"
< {summary:"GET /me → 200 vs GET /me → 401 → differs: status, 1 header, body.",
   statusDiff:{a:200, b:401}, ...}
```
