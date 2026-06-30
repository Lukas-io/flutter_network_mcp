# Tuning what gets captured & analyzed

Reduce noise before it pollutes the DB or the alert queue.

- [`alerts_config`](alerts_config.md) — toggle the built-in alert rules; set the slow-request threshold.
- [`alert_patterns`](alert_patterns.md) — register project-specific regex patterns the detector evaluates against every log line.
- [`ignored_hosts`](ignored_hosts.md) — denylist: drop analytics / telemetry / noisy hosts or paths at capture time so they never enter the DB.
- [`capture_allow`](capture_allow.md) — allowlist: capture ONLY matching hosts/paths and drop the rest, for focused debugging. The inverse of `ignored_hosts`.
- [`redacted_headers`](redacted_headers.md) — extend [`network_replay`](../comparing/network_replay.md)'s header redaction set with project-specific names.
