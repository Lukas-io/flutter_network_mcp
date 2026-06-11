---
tool: correlate_at
description: Correlate logs and HTTP requests around a moment in time. Given an anchor timestamp, returns both sides within a window, tagged with signed deltaMs and sorted nearest-first.
when_to_use: When you have a timestamp (usually a log line) and want to know which HTTP request fired closest to it.
---

## DO NOT USE THIS TOOL WHEN

- You just want recent logs or requests with no timestamp anchor — use `logs_tail` / `network_list`.
- You want to match requests ACROSS sessions by a shared token (webhook id, correlation header) — that is `network_correlate`, which is a different kind of correlation (content, not time).
- You are anchoring on a *live* event that happened <2s ago — the capture writer persists on a ~2s cycle, so the very newest requests may not be in the window yet. Wait a tick or re-run.

## Use this when

- You found a log line via `logs_tail` (e.g. `[EventTracker] aeon_transaction_started`) and want the HTTP request that fired around the same instant.
- You are tracing instrumentation: an analytics event, an FCM callback, a websocket subscription firing — and want the network activity next to it.
- You want both sides of a moment in one call instead of eyeballing two separate listings.

## Args

- `tsMs` (int, required) — anchor timestamp in ms since epoch. Usually a log entry's `timestampMs` or a request's `startTimeMs`.
- `windowMs` (int, optional) — half-width of the window (`anchor ± windowMs`). Default 1000, hard cap 30000.
- `sessionId` / `appNameContains` — scope (auto-resolves with one session attached).
- `isolateId` (string, optional) — restrict both sides to one isolate.
- `limit` (int, optional) — max items returned PER SIDE. Default 20, hard cap 100.

## Returns

```jsonc
{
  "summary": "2 log(s) + 1 request(s) within +/-1000ms of 1780462000000. Nearest: GET https://api/x (+45ms).",
  "anchorMs": 1780462000000,
  "windowMs": 1000,
  "logs":     [{ "id": 12, "timestampMs": ..., "deltaMs": -30, "source": "logging", "message": "..." }],
  "requests": [{ "id": "5320...", "timestampMs": ..., "deltaMs": 45, "method": "GET", "url": "...", "statusCode": 200 }],
  "nextSteps": ["network_get id:\"5320...\" — full detail on the nearest request"]
}
```

`deltaMs` is signed: negative = before the anchor, positive = after. Each side is sorted nearest-first by `|deltaMs|`. When the `http` or `logs` capability is disabled, that side is omitted and `disabledSides` lists it.

## Pairs well with

- `logs_tail` — the usual source of the anchor `tsMs`.
- `network_get` — drill into the nearest request the headline points at.
- `network_replay` — reproduce the nearest request.
