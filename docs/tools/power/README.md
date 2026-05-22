# Power user / ad-hoc queries

For when the structured tools can't express the question.

- [`network_query`](network_query.md) — read-only SQL escape hatch. Single SELECT / WITH...SELECT only. BLOB-safe, cell-capped, 500-row cap.

Reach for this only when [`finding/`](../finding/), [`history/`](../history/), or [`db-management/`](../db-management/) can't get the shape you need.
