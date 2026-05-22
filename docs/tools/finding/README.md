# Finding a request

When you don't have an id yet. Returns summaries with ids you pass to tools in [`inspecting/`](../inspecting/).

- [`network_list`](network_list.md) — by metadata (host, method, status, time). Cursor-based, incremental by default.
- [`network_search`](network_search.md) — by content (FTS5 over urls + utf8-decoded bodies). BM25-ranked.
