---
tool: network_drift
description: Response-shape drift for an endpoint. Compares the JSON structure of its captured responses over time and reports fields added, removed, or changed type.
when_to_use: When you suspect the API contract changed mid-session (a field disappeared, a number became a string) and want the first response where the shape differs.
---

## DO NOT USE THIS TOOL WHEN

- You have not narrowed to one endpoint: without `pathContains` (and `hostContains`), responses from different endpoints are compared with each other, and almost any mix reports drift. Always pass a `pathContains` that matches one endpoint.
- You want value changes, not shape changes: two responses with the same keys and types but different values count as no drift. Use `network_diff` on two ids.
- You want to compare two runs: use `network_diff_session`. This tool reads one session.
- The endpoint returns non-JSON bodies: only JSON responses are compared.

## Use this when

- A screen broke partway through a session and you suspect the backend changed a response shape.
- Checking whether a field is sometimes missing or sometimes a different type across calls to one endpoint.
- Confirming an endpoint's contract stayed stable (`drifted:false`) over a session.

## How it works

1. Reads up to the 10,000 newest requests of the session from the DB, filtered by `hostContains` (case-insensitive) and `sinceMs`.
2. Keeps rows whose content type contains `json` and whose path contains `pathContains` (case-insensitive), sorted oldest first.
3. If more than `limit` rows match, samples both ends: the oldest `limit/2` and the newest `limit - limit/2`, so the earliest shape is always included.
4. Loads each sample's stored response body and parses it as JSON; bodies that are missing or do not parse are skipped.
5. Flattens each body into a `path -> type` map: keys joined with `.`, array elements as `[]` (only the first element is walked), types `object` / `array` / `string` / `number` / `bool` / `null`. Integers and doubles are both `number`.
6. Compares the oldest sample with each later one in time order and stops at the first that differs. A change to or from `null` is not counted as a type change.

Only the first drift point is reported, relative to the oldest sample. Later changes after that point are not listed.

`sinceMs` counts back from now (wall-clock time), so on a session that ended hours ago a small `sinceMs` matches nothing.

Body decryption: when `session_configure bodyDecryption:{...}` is on, each response body is decrypted before parsing, and the content-type filter is skipped (encrypted bodies can carry any content type; bodies that are not JSON after decryption are skipped). This tool does not emit `decrypted` / `decryptionFailed` flags; call `network_get` on an id to see them.

## Args

- `hostContains` (string, optional): host substring to match.
- `pathContains` (string, optional): path substring to narrow to one endpoint. Effectively required for a meaningful result.
- `sessionId` (int, optional): session to read. Omit to auto-resolve (the sole attached session, or the one you opened).
- `appNameContains` (string, optional): pick the attached session by app-name substring.
- `sinceMs` (int, default 0): only requests that started within the last `sinceMs` milliseconds. 0 or omitted means the whole session.
- `limit` (int, default 100, cap 1000): max responses to decode. 0 or negative means the default.

## Returns

```json
{
  "summary": "Response shape DRIFTED across 12 sample(s): 1 added, 1 removed, 1 type-changed field(s).",
  "sessionId": 14,
  "scanned": 12,
  "matchedTotal": 12,
  "drifted": true,
  "added": ["data.discount"],
  "removed": ["data.price_cents"],
  "changed": [{"field": "data.id", "before": "number", "now": "string"}],
  "firstDriftAt": {"id": "req-9", "path": "/v1/cart", "startTimeMs": 1779414305402},
  "nextSteps": [
    "network_get id:\"req-9\" (inspect the response that changed)",
    "network_drift pathContains:\"...\" (narrow to a single endpoint)"
  ]
}
```

- `scanned`: samples that parsed as JSON and were compared.
- `matchedTotal`: rows that passed the filters, before sampling.
- `added` / `removed` / `changed`: present only when `drifted` is true. Field paths use `.` for keys and `[]` for array elements (`items[].price`); a top-level array is `[]`, a top-level scalar `(root)`.
- With no drift: `drifted:false`, no field lists, and a `network_summarize` next step instead of `network_get`.
- With fewer than 2 JSON responses: a normal reply with `summary` "Not enough JSON responses to compare", `scanned`, and `nextSteps`, but no `drifted` field.

The `nextSteps` wording above is shortened. There is no `scope` block.

Errors: `internal` (the DB query failed). Scope failures return `error` + `nextSteps` without an `errorKind`.

## Pairs well with

- `network_summarize`: find the endpoint and its path to pass as `pathContains`.
- `network_get`: open the response at `firstDriftAt.id`, and the one before it.
- `network_diff`: compare the last good response with the first drifted one.

## Example

```
> network_summarize
< {endpoints:[{endpoint:"GET api.example.com/v1/cart", count:12, ...}]}
> network_drift pathContains:"/v1/cart"
< {drifted:true, removed:["data.price_cents"], added:["data.discount"],
   firstDriftAt:{id:"req-9", path:"/v1/cart", startTimeMs:1779414305402}}
> network_get id:"req-9"
```
