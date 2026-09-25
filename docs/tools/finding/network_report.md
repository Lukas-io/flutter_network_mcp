---
tool: network_report
description: One-call HTTP health triage for a session. The top 3 error endpoints, the top 3 slowest endpoints, a one-line headline, and the next call to make. Built on the network_summarize digest.
when_to_use: Right after `network_status`, when the question is "is anything wrong with this app's HTTP?" and you want a verdict plus a next step instead of a table.
---

## DO NOT USE THIS TOOL WHEN

- You want every endpoint with its full status distribution and p50. Use `network_summarize`; the report keeps only 3 error and 3 slow rows.
- You need individual requests or ids. Use `network_list` (the report's next step already points there with the right filters).
- You need body content. The report is metadata only.
- You want the alerts themselves. The report only counts pending alerts; `alerts_drain` / `alerts_peek` read them.
- You need a host filter or a `minCount` cutoff. `network_summarize` has both; the report has neither.

## Use this when

- First look at a session: "is anything broken?" in one call.
- After a user reports "the app is slow" or "something fails": the headline names the worst endpoint.
- Re-checking a session after a fix: `sinceMs:300000` limits the verdict to the last 5 minutes.

## How it works

1. Resolves the session like the other read tools (`sessionId`, else `appNameContains`, else the `session_open` view, else the sole or default attached session).
2. Reads the newest 10 000 `http_requests` rows of that session from the capture DB (whole session by default, or requests that started within `sinceMs` of now). A live request is included once the capture writer has persisted it (~2s tick).
3. Groups them with the same digest as `network_summarize`: one bucket per `(method, host, pathTemplate)`, with count, p95 latency and error rate. Error rate counts status >= 400 and transport errors (no status code, but the request ended or carries an error) over the completed requests. Requests still in flight are not errors and are left out of the rate.
4. `errorHotspots`: endpoints with an error rate above zero, sorted by impact (`errorRate x count`), top 3.
5. `slowestEndpoints`: endpoints with a p95 latency, sorted by p95 desc, top 3.
6. When the alerts capability is on, counts the session's pending alerts.
7. Picks one headline and its next steps, in this order:
   - No requests: `No HTTP captured for session N yet.` (live app) or `No HTTP captured in session N (its capture is complete).`, with a state-aware hint (drive the app, or the capture is final) and, for a live app, `network_status`.
   - Any error hotspot: `Top problem: <endpoint> is failing <pct>% of <n> call(s).`, then `network_list statusMin:400 hostContains:"<host>"`, `alerts_drain` (when alerts are pending), and `network_drift hostContains:"<host>"`. When the endpoint has no host (a relative URL), `hostContains` is left out of both.
   - No errors, and the slowest p95 is over 1000 ms: `No errors; slowest endpoint <endpoint> at <p95>ms p95.`, then `network_summarize` and `alerts_drain` (when alerts are pending).
   - Otherwise: `Healthy: <n> request(s) across <m> endpoint(s), no error hotspots.`, then `alerts_drain` when alerts are pending, else `network_summarize`.

## Args

- `sessionId` (int, optional). Session to read. Omit to auto-resolve.
- `appNameContains` (string, optional). Pick the attached session by app-name substring instead of `sessionId`.
- `sinceMs` (int, default 0). Window in ms back from now, against request start times. `0` (or negative) means the whole session, for live and historical sessions alike.

## Returns

```json
{
  "summary": "Top problem: GET api.example.com/api/orders/N is failing 38% of 21 call(s).",
  "sessionId": 14,
  "totalRequests": 247,
  "distinctEndpoints": 9,
  "errorHotspots": [
    {"endpoint": "GET api.example.com/api/orders/N", "count": 21, "errorRate": 0.381, "p95LatencyMs": 640},
    {"endpoint": "POST api.example.com/api/login", "count": 3, "errorRate": 0.3333, "p95LatencyMs": 290}
  ],
  "slowestEndpoints": [
    {"endpoint": "GET cdn.example.com/img/H", "count": 12, "errorRate": 0.0, "p95LatencyMs": 2310},
    {"endpoint": "GET api.example.com/api/orders/N", "count": 21, "errorRate": 0.381, "p95LatencyMs": 640}
  ],
  "nextSteps": [
    "network_list statusMin:400 hostContains:\"api.example.com\" ...",
    "alerts_drain ... 2 pending alert(s)",
    "network_drift hostContains:\"api.example.com\" ..."
  ],
  "pendingAlerts": {"scope": "session", "sessionId": 14, "count": 2}
}
```

- `totalRequests` is the number of requests the digest covered (at most 10 000); `distinctEndpoints` is the number of endpoint buckets.
- `errorHotspots` and `slowestEndpoints` rows carry only `endpoint`, `count`, `errorRate` and `p95LatencyMs` (`null` when no request of that endpoint has a duration; such endpoints are left out of `slowestEndpoints`). An endpoint can appear in both lists.
- `pendingAlerts` is added automatically when the alerts capability is on and the session has undrained alerts (`critical` is included when some are critical).
- There is no `scope` block and no `count` field. A scope note (for example an open `session_open` view shadowing live sessions) is not copied to `warnings` here, unlike `network_summarize`.

Errors:

| Cause | `errorKind` |
|---|---|
| The DB read failed (`network_report query failed: ...`), with `network_status` and `network_summarize` as next steps | `internal` |
| No session could be resolved, or `appNameContains` matched no attached session | `no_session` |
| `appNameContains` matched several attached sessions | `bad_argument` |
| The call ran past the per-tool deadline | `timeout` |

## Pairs well with

- `network_status`: call first to see what is attached; then the report.
- `network_list statusMin:400 hostContains:"..."`: the failing requests behind the top hotspot.
- `network_summarize`: the full per-endpoint table the report is built on.
- `network_drift`: whether the failing host's response shape changed.
- `alerts_drain`: the pending alerts the report counted.

## Example

```
> network_status
< {attached:[{sessionId:14, ...}], ...}
> network_report
< {summary:"Top problem: GET api.example.com/api/orders/N is failing 38% of 21 call(s).",
   errorHotspots:[{endpoint:"GET api.example.com/api/orders/N", count:21, errorRate:0.381, p95LatencyMs:640}],
   nextSteps:["network_list statusMin:400 hostContains:\"api.example.com\" ...", ...]}
> network_list statusMin:400 hostContains:"api.example.com"
```
