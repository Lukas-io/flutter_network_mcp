# Tuning what gets captured & analyzed

Reduce noise before it pollutes the DB or the alert queue.

- [`alerts_config`](alerts_config.md) — toggle the built-in alert rules; set the slow-request threshold.
- [`alert_patterns`](alert_patterns.md) — register project-specific regex patterns the detector evaluates against every log line.
- [`ignored_hosts`](ignored_hosts.md) — drop analytics / telemetry / noisy services at capture time so they never enter the DB.
- [`redacted_headers`](redacted_headers.md) — extend [`network_replay`](../comparing/network_replay.md)'s header redaction set with project-specific names.
