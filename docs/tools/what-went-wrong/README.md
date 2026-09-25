# Surfacing "what went wrong"

The server runs detection rules on every capture and queues alerts. These tools surface that queue, raw log output, and what happened around a given moment.

- [`alerts_drain`](alerts_drain.md) — read AND clear pending alerts. Per-severity breakdown in the response.
- [`alerts_peek`](alerts_peek.md) — read without clearing (triage before committing).
- [`logs_tail`](logs_tail.md): recent log / stdout / stderr records, plus native device logs when the attach requested them (filtered by level, source, logger, message text, isolate). Messages are stored whole, with `error` and `stackTrace`.
- [`correlate_at`](correlate_at.md): logs and HTTP requests within +/- windowMs of an anchor timestamp, nearest-first. "Which request fired closest to this log line?"
