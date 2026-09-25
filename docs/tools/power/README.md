# Power user / ad-hoc queries

For when the structured tools can't express the question.

- [`network_query`](network_query.md) — read-only SQL escape hatch. Single SELECT / WITH...SELECT only. BLOB-safe, cell-capped, 500-row cap.
- [`network_correlate`](network_correlate.md): find requests in up to 8 sessions that contain the same string (a correlation id, URL fragment, error text) and pair them by start time.
- [`usage_stats`](usage_stats.md): how agents use this MCP's own tools. Per-tool counts, outcomes, latency, error kinds, and the tool to next-tool transition graph.

Reach for this only when [`finding/`](../finding/), [`history/`](../history/), or [`db-management/`](../db-management/) can't get the shape you need.
