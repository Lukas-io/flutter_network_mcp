# Comparing or reproducing requests

- [`network_diff`](network_diff.md): structural diff of two captured requests in one session (status, method, url, response headers, response body hunks).
- [`network_diff_session`](network_diff_session.md): diff two sessions endpoint by endpoint (new, gone, and error-rate / p95 shifts).
- [`network_drift`](network_drift.md): JSON response-shape drift for one endpoint over a session (fields added, removed, or changed type).
- [`network_replay`](network_replay.md): emit a runnable curl command. Auth-like headers redacted by default; body truncated by default.
- [`network_replay_as_test`](network_replay_as_test.md): emit a runnable Dart test that replays a request and asserts its status. Auth headers commented out by default.
