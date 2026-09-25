---
tool: network_diff_session
description: Diff two sessions (runs) endpoint by endpoint (method + host + path template), returning new endpoints, gone endpoints, and endpoints whose error rate or p95 latency shifted.
when_to_use: When the question is "what is different about today's run" compared with an earlier session, at the endpoint level.
---

## DO NOT USE THIS TOOL WHEN

- You want to compare two individual requests: use `network_diff` (status, headers, body).
- You want to know whether a response's JSON shape changed: use `network_drift`.
- You only have one session: there is nothing to compare. `session_list` shows past sessions.
- You need exact bodies or headers: this tool works on aggregate endpoint stats only.

## Use this when

- A flow worked in an earlier run and fails now, and you want the endpoints that appeared, disappeared, or started erroring.
- Checking a build for new or removed API calls against a known-good session.
- Spotting latency regressions per endpoint between two runs.

## How it works

Reads up to the 10,000 newest requests of each session from the DB and groups them into endpoints exactly like `network_summarize`: key `METHOD host + path template`, where numeric path segments become `N`, UUIDs `UUID`, and hex ids of 8+ chars `H` (query strings dropped). Endpoints with fewer than `minCount` requests are dropped from each side separately, so an endpoint below the threshold on one side only shows as new or gone.

- `newEndpoints`: endpoints only in the current session.
- `goneEndpoints`: endpoints only in the baseline.
- `changed`: endpoints in both where the error rate moved by 0.1 or more, or p95 latency more than doubled or more than halved (only when both p95 values exist and the baseline p95 is above 0). Sorted by the largest error-rate change first.

A request counts as an error when its status is 400 or above, or when it has no status and ended or carries an error. A request still in flight is not an error and is left out of the error rate.

The baseline must have captured HTTP: a baseline id that does not exist, or one with no captured requests, returns a `not_found` error instead of a diff (an empty baseline would report every current endpoint as new). A current session with no captured requests still returns the diff, with a warning that every baseline endpoint reads as gone.

## Args

- `baselineSessionId` (int, required): the older run to compare against (id from `session_list`). Must differ from the current session.
- `sessionId` (int, optional): the newer/current session. Omit to auto-resolve (the sole attached session, or the one you opened).
- `appNameContains` (string, optional): pick the current session by app-name substring.
- `minCount` (int, default 1): ignore endpoints with fewer than this many requests, applied to each side separately.

## Returns

```json
{
  "scope": {"sessionId": 21, "appName": "my_app", "isLive": true},
  "summary": "Session 21 vs baseline 14: 1 new, 0 gone, 1 changed endpoint(s).",
  "currentSessionId": 21,
  "baselineSessionId": 14,
  "newEndpoints": [
    {"endpoint": "GET api.example.com/v2/feed", "method": "GET", "host": "api.example.com",
     "pathTemplate": "/v2/feed", "count": 4, "statusDist": {"200": 4},
     "p50LatencyMs": 120, "p95LatencyMs": 180, "errorRate": 0.0}
  ],
  "goneEndpoints": [],
  "changed": [
    {"endpoint": "POST api.example.com/v1/login",
     "errorRate": {"now": 0.5, "baseline": 0.0, "delta": 0.5},
     "p95LatencyMs": {"now": 900, "baseline": 350},
     "count": {"now": 4, "baseline": 3}}
  ],
  "nextSteps": [
    "network_summarize (drill into the current session endpoint stats)",
    "network_list hostContains:\"...\" (inspect a new endpoint live)",
    "session_list (pick a different baseline session)"
  ]
}
```

`newEndpoints` and `goneEndpoints` entries have the same shape as `network_summarize` endpoints (`statusDist` uses the key `error` for failed requests with no status and `inFlight` for requests that have not ended). The `network_summarize` step appears only when `changed` is non-empty, the `network_list` step only when `newEndpoints` is non-empty. The `nextSteps` wording above is shortened. `scope` describes the current session (the one resolved from `sessionId` / `appNameContains` / the open view); a scope note (for example an open `session_open` view shadowing live sessions) is also copied to `warnings`.

Errors: `bad_argument` (missing `baselineSessionId`, or it equals the current session), `not_found` (the baseline does not exist or has no captured requests; `nextSteps` point at `session_list` to pick another), `internal` (the DB query failed). Scope failures return `no_session` (nothing attached or opened, or no attached session matches `appNameContains`) or `bad_argument` (several attached sessions match), with `nextSteps`.

## Pairs well with

- `session_list`: pick the baseline.
- `network_summarize`: full endpoint stats for one session.
- `network_list` / `network_diff`: drill from a changed endpoint to individual requests.
- `network_drift`: check whether a changed endpoint's response shape also changed.

## Example

```
> session_list
< {sessions:[{id:21, ...}, {id:14, ...}]}
> network_diff_session baselineSessionId:14 minCount:2
< {summary:"Session 21 vs baseline 14: 0 new, 1 gone, 1 changed endpoint(s).",
   goneEndpoints:[{endpoint:"GET api.example.com/v1/config", ...}],
   changed:[{endpoint:"POST api.example.com/v1/login", errorRate:{now:0.5, baseline:0.0, delta:0.5}, ...}]}
> network_list hostContains:"api.example.com" statusMin:400
```
