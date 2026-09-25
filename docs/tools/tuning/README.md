# Tuning what gets captured & analyzed

Reduce noise before it pollutes the DB or the alert queue.

- [`alerts_config`](alerts_config.md): toggle the built-in alert rules; set the slow-request threshold and the alert retention window.
- [`alert_patterns`](alert_patterns.md) — register project-specific regex patterns the detector evaluates against every log line.
- [`ignored_hosts`](ignored_hosts.md) — denylist: drop analytics / telemetry / noisy hosts or paths at capture time so they never enter the DB.
- [`capture_allow`](capture_allow.md) — allowlist: capture ONLY matching hosts/paths and drop the rest, for focused debugging. The inverse of `ignored_hosts`.
- [`redacted_headers`](redacted_headers.md): extend the header redaction set used by `network_get`, [`network_replay`](../comparing/network_replay.md), `network_replay_as_test`, `network_diff` and redacted session exports with project-specific names.
- [`session_configure`](session_configure.md): process-wide sticky default filters that `logs_tail` / `network_list` inherit, a per-response token budget (`maxResponseTokens`), and optional decryption of app-encrypted bodies on read (`bodyDecryption`). In memory; resets on restart.
