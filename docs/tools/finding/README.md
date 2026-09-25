# Finding a request

When you don't have an id yet. Returns summaries with ids you pass to tools in [`inspecting/`](../inspecting/).

- [`network_list`](network_list.md) — by metadata (host, method, status, time). Cursor-based, incremental by default.
- [`network_search`](network_search.md): by content (FTS5 over urls + text bodies of json/xml/text/javascript/graphql/form content types; over decrypted plaintext, in memory, when `session_configure bodyDecryption` is on). BM25-ranked.
- [`network_summarize`](network_summarize.md): one row per endpoint (count, status distribution, p50/p95, error rate) to see the shape of a session before picking requests.
- [`network_report`](network_report.md): one-call health triage. Worst error endpoints, slowest endpoints, pending alerts, and the next call to make.
