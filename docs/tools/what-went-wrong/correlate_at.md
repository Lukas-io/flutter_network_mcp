---
tool: correlate_at
description: Correlate logs and HTTP requests around a moment in time. Given an anchor timestamp, returns both sides within a window, tagged with signed deltaMs and sorted nearest-first.
when_to_use: When you have a timestamp (usually a log line) and want to know which HTTP request fired closest to it.
---

## DO NOT USE THIS TOOL WHEN

- You just want recent logs or requests with no timestamp anchor — use `logs_tail` / `network_list`.
- You want to match requests ACROSS sessions by a shared token (webhook id, correlation header) — that is `network_correlate`, which is a different kind of correlation (content, not time).
- You are anchoring on a *live* event that happened <2s ago: both sides are read from the DB, and HTTP requests are persisted on the capture writer's tick (default 2s), so the very newest requests may not be in the window yet. Logs are stored as they arrive. Wait a tick or re-run.

## Use this when

- You found a log line via `logs_tail` (e.g. `[EventTracker] aeon_transaction_started`) and want the HTTP request that fired around the same instant.
- You are tracing instrumentation: an analytics event, an FCM callback, a websocket subscription firing — and want the network activity next to it.
- You want both sides of a moment in one call instead of eyeballing two separate listings.

## How it works

Resolves one session like the other read tools (explicit `sessionId`, then `appNameContains`, then the `session_open` view, then the attached session), then runs two DB queries for it, never the live VM:
- logs whose `timestamp_ms` is within `tsMs ± windowMs` (records without a timestamp are skipped);
- HTTP requests whose START time is within the same window (a request that started earlier and finished inside the window is not included).

Both bounds are inclusive. Each side is sorted by `|deltaMs|` and cut to `limit`, so with many records the ones nearest the anchor win. `isolateId` filters both sides. The headline "Nearest" is the single closest item across both sides.

Log messages are cut at 512 characters: a cut entry has `truncated:true` (no `totalLength`). Log entries never include the record's `error` or `stackTrace`, even though those are stored in full. To read the whole message plus error and stack, use `logs_tail messageContains:"<distinctive text>" messageTruncateBytes:65536`.

## Args

- `tsMs` (int, required) — anchor timestamp in ms since epoch. Usually a log entry's `timestampMs` or a request's `startTimeMs`.
- `windowMs` (int, optional): half-width of the window (`anchor ± windowMs`). Default 1000, hard cap 30000; values <= 0 fall back to 1000.
- `sessionId` / `appNameContains` — scope (auto-resolves with one session attached).
- `isolateId` (string, optional) — restrict both sides to one isolate.
- `limit` (int, optional): max items returned PER SIDE. Default 20, hard cap 100; values <= 0 fall back to 20.

## Returns

```jsonc
{
  "scope": { "sessionId": 14, "appName": "eats_mobile", "isLive": true },
  "sessionId": 14,
  "summary": "2 log(s) + 1 request(s) within +/-1000ms of 1780462000000. Nearest: GET https://api/x (+45ms).",
  "anchorMs": 1780462000000,
  "windowMs": 1000,
  "logs":     [{ "id": 12, "timestampMs": ..., "deltaMs": -30, "source": "logging", "level": 800, "loggerName": "EventTracker", "isolateId": "isolates/123", "message": "...", "truncated": true }],
  "requests": [{ "id": "5320...", "timestampMs": ..., "deltaMs": 45, "method": "GET", "url": "...", "statusCode": 200, "durationMs": 180, "isolateId": "isolates/123" }],
  "nextSteps": ["network_get id:\"5320...\" ... full detail on the nearest request", "network_replay id:\"5320...\" ... reproduce the nearest request"]
}
```

`deltaMs` is signed: negative = before the anchor, positive = after. Each side is sorted nearest-first by `|deltaMs|`. A log's `id` is its DB row id; a request's `id` is the id `network_get` takes and its `timestampMs` is the request start. `level`, `loggerName`, `isolateId`, `statusCode` and `durationMs` are omitted when null; `truncated` appears only on cut messages.

When the `http` or `logs` capability is disabled, that side comes back as an empty array and `disabledSides` lists it (`"logs"` / `"http"`). The tool is not registered when both are disabled.

nextSteps: `network_get` for the nearest item when it is a request, and `network_replay` for the nearest request whenever any request was found. With nothing found the summary is `Nothing within +/-<windowMs>ms of <tsMs>.` and nextSteps suggests raising `windowMs`.

Errors: missing `tsMs` returns `errorKind: "bad_argument"` with nextSteps pointing at `logs_tail` / `network_list` for an anchor. A DB failure returns `errorKind: "internal"`. Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

## Pairs well with

- `logs_tail`: the usual source of the anchor `tsMs`, and the way to read a log's full message, `error` and `stackTrace`.
- `network_get` — drill into the nearest request the headline points at.
- `network_replay` — reproduce the nearest request.
