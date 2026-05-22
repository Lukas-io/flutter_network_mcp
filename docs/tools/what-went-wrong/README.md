# Surfacing "what went wrong"

The server runs detection rules on every capture and queues alerts. These tools surface that queue + raw log output.

- [`alerts_drain`](alerts_drain.md) — read AND clear pending alerts. Per-severity breakdown in the response.
- [`alerts_peek`](alerts_peek.md) — read without clearing (triage before committing).
- [`logs_tail`](logs_tail.md) — recent log / stdout / stderr records (filtered by severity, source, logger).
